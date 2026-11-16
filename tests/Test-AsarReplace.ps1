$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Load-InstallerFunctions.ps1') -FunctionNames @(
    'Test-FileReplaceable',
    'Assert-AsarReplaceable',
    'Move-FileWithRetry'
)

# Keep this file pure ASCII: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.
# A file held without FILE_SHARE_DELETE makes Move-Item -Force fail with
# "Cannot create a file when that file already exists"; the preflight and retry
# logic must turn that into a clear, early error (issue #244).

$temp = Join-Path ([IO.Path]::GetTempPath()) ('claude-desktop-asar-replace-' + [guid]::NewGuid().ToString('N'))
$onWindows = $env:OS -eq 'Windows_NT'

try {
    New-Item -ItemType Directory -Path $temp -Force | Out-Null

    $target = Join-Path $temp 'app.asar'
    [IO.File]::WriteAllText($target, 'old')

    if (-not (Test-FileReplaceable -Path $target -TimeoutSeconds 1)) {
        throw 'Test-FileReplaceable should report an idle file as replaceable.'
    }

    if ($onWindows) {
        $holder = [IO.File]::Open($target, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            if (Test-FileReplaceable -Path $target -TimeoutSeconds 1) {
                throw 'A file held without FILE_SHARE_DELETE must not be reported as replaceable.'
            }

            $threw = $false
            try {
                Assert-AsarReplaceable -Path $target -TimeoutSeconds 1
            }
            catch {
                $threw = $true
                if ($_.Exception.Message -notmatch 'app\.asar') {
                    throw "Unexpected error message: $($_.Exception.Message)"
                }
            }
            if (-not $threw) {
                throw 'Assert-AsarReplaceable should throw for a locked file.'
            }
        }
        finally {
            $holder.Dispose()
        }
    }

    if (-not (Test-FileReplaceable -Path $target -TimeoutSeconds 1)) {
        throw 'Test-FileReplaceable should recover after the handle is released.'
    }
    Assert-AsarReplaceable -Path $target -TimeoutSeconds 1

    $source = Join-Path $temp 'new.bin'
    [IO.File]::WriteAllText($source, 'new')

    if ($onWindows) {
        $holder = [IO.File]::Open($target, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $threw = $false
            try {
                Move-FileWithRetry -Source $source -Destination $target -Retries 2 -DelayMilliseconds 100
            }
            catch {
                $threw = $true
                if ($_.Exception.Message -notmatch 'app\.asar') {
                    throw "Unexpected error message: $($_.Exception.Message)"
                }
            }
            if (-not $threw) {
                throw 'Move-FileWithRetry should fail while the destination is locked.'
            }
            if (-not (Test-Path -LiteralPath $source)) {
                throw 'Move-FileWithRetry must keep the source when the move fails.'
            }
        }
        finally {
            $holder.Dispose()
        }
    }

    Move-FileWithRetry -Source $source -Destination $target -Retries 2 -DelayMilliseconds 100
    if (-not (Test-Path -LiteralPath $target)) {
        throw 'Target missing after Move-FileWithRetry.'
    }
    if ([IO.File]::ReadAllText($target) -ne 'new') {
        throw 'Target content was not replaced.'
    }
    if (Test-Path -LiteralPath $source) {
        throw 'Source should be gone after a successful move.'
    }

    Write-Host 'PASS: a locked asar is detected before the move and reported with a clear error.' -ForegroundColor Green
    Write-Host 'PASS: Move-FileWithRetry keeps the source on failure and succeeds once the lock is released.' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $temp) {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}