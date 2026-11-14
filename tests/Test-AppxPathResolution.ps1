$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Load-InstallerFunctions.ps1') -FunctionNames @(
    'Find-ClaudePath',
    'Get-ClaudeExePath',
    'Get-ClaudeExeProductVersion'
)

$temp = Join-Path ([IO.Path]::GetTempPath()) ('claude-desktop-appx-' + [guid]::NewGuid().ToString('N'))

try {
    New-Item -ItemType Directory -Path $temp -Force | Out-Null

    # --- Test 1: Find-ClaudePath sorts AppX packages by version descending ---
    $oldPkgDir = Join-Path $temp 'pkg_5_1231'
    $newPkgDir = Join-Path $temp 'pkg_5_11492'
    $oldestPkgDir = Join-Path $temp 'pkg_3_6556'
    New-Item -ItemType Directory -Path $oldPkgDir -Force | Out-Null
    New-Item -ItemType Directory -Path $newPkgDir -Force | Out-Null
    New-Item -ItemType Directory -Path $oldestPkgDir -Force | Out-Null

    # Mock Get-ClaudeAppxPackages returning in arbitrary order
    function script:Get-ClaudeAppxPackages {
        return @(
            [pscustomobject]@{
                Name = 'Claude'
                Version = '5.1231.2.0'
                InstallLocation = $oldPkgDir
            },
            [pscustomobject]@{
                Name = 'AnthropicPBC.Claude'
                Version = '5.11492.5.0'
                InstallLocation = $newPkgDir
            },
            [pscustomobject]@{
                Name = 'AnthropicPBC.Claude'
                Version = '3.6556.2.0'
                InstallLocation = $oldestPkgDir
            }
        )
    }

    $selectedPath = Find-ClaudePath
    if ($selectedPath -ne $newPkgDir) {
        throw "Find-ClaudePath failed to select newest package! Expected: $newPkgDir, Got: $selectedPath"
    }

    # --- Test 2: Get-ClaudeExePath & Get-ClaudeExeProductVersion in AppX layout (app\subdir) ---
    $appSubdir = Join-Path $newPkgDir 'app'
    New-Item -ItemType Directory -Path $appSubdir -Force | Out-Null
    $dummyExe = Join-Path $appSubdir 'Claude.exe'
    # Copy a real PE from system32 (e.g. notepad.exe) to verify FileVersion/ProductVersion reading
    $sourceExe = Join-Path $env:SystemRoot 'notepad.exe'
    if (Test-Path $sourceExe) {
        Copy-Item -LiteralPath $sourceExe -Destination $dummyExe -Force
        $expectedVersion = [string](Get-Item -LiteralPath $dummyExe).VersionInfo.ProductVersion
        if ($expectedVersion) {
            $expectedVersion = $expectedVersion.Trim()
        }

        $detectedExe = Get-ClaudeExePath $newPkgDir
        if ($detectedExe -ne $dummyExe) {
            throw "Get-ClaudeExePath failed to find exe in app subdir! Got: $detectedExe"
        }

        $detectedVersion = Get-ClaudeExeProductVersion $newPkgDir
        if ($detectedVersion -ne $expectedVersion) {
            throw "Get-ClaudeExeProductVersion returned unexpected version! Expected: $expectedVersion, Got: $detectedVersion"
        }
    }

    Write-Host "PASS: Find-ClaudePath correctly prioritizes newest AppX version."
    Write-Host "PASS: Get-ClaudeExePath and Get-ClaudeExeProductVersion support AppX app\ layout."
}
finally {
    if (Test-Path -LiteralPath $temp) {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}