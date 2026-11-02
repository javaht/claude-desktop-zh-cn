$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Load-InstallerFunctions.ps1') -FunctionNames @(
    'Test-WriteAccess',
    'Confirm-TakeOwnership',
    'Take-OwnershipAndGrant',
    'Grant-WriteAccess',
    'Enable-WriteAccess',
    'Assert-WriteAccess',
    'Get-ClaudeAppPathFromResources'
)

# Everything here runs against a throwaway temp directory. The point is to prove that
# permission handling is driven by an actual write probe rather than by reading the
# ACL, and that Grant-WriteAccess never escalates to takeown on writable targets.
# Keep this file pure ASCII: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.

$temp = Join-Path ([IO.Path]::GetTempPath()) ('claude-desktop-perm-' + [guid]::NewGuid().ToString('N'))
$isWindows = $env:OS -eq 'Windows_NT'

try {
    New-Item -ItemType Directory -Path $temp -Force | Out-Null

    # --- Test-WriteAccess: probe based on real I/O ---
    if (-not (Test-WriteAccess $temp)) {
        throw 'Test-WriteAccess should report a writable directory as writable.'
    }
    $file = Join-Path $temp 'probe.txt'
    [IO.File]::WriteAllText($file, 'x')
    if (-not (Test-WriteAccess $file)) {
        throw 'Test-WriteAccess should report a writable file as writable.'
    }
    if (Test-WriteAccess (Join-Path $temp 'does-not-exist')) {
        throw 'Test-WriteAccess should report a missing path as not writable.'
    }

    # The probe must not leave artifacts behind in the target directory.
    $leftovers = @(Get-ChildItem -LiteralPath $temp -Filter '.zh-cn-write-test-*' -Force -ErrorAction SilentlyContinue)
    if ($leftovers.Count -ne 0) {
        throw "Write probe left $($leftovers.Count) temp entr(ies) behind."
    }

    # --- Grant-WriteAccess: already writable means no ACL work at all ---
    $ownerBefore = $null
    if ($isWindows) {
        $ownerBefore = (Get-Acl -LiteralPath $temp).Owner
    }
    if (-not (Grant-WriteAccess $temp)) {
        throw 'Grant-WriteAccess should succeed on an already-writable directory.'
    }
    if ($isWindows) {
        $ownerAfter = (Get-Acl -LiteralPath $temp).Owner
        if ($ownerAfter -ne $ownerBefore) {
            throw "Grant-WriteAccess changed the owner of a writable directory ($ownerBefore -> $ownerAfter)."
        }
    }

    # Missing paths are "nothing to do", not failures.
    if (-not (Grant-WriteAccess (Join-Path $temp 'missing\path'))) {
        throw 'Grant-WriteAccess should treat a missing path as already satisfied.'
    }

    # --- Deny-write targets: probe says no, Grant restores it (current user owns them) ---
    if ($isWindows) {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

        $locked = Join-Path $temp 'locked.txt'
        [IO.File]::WriteAllText($locked, 'x')
        $acl = Get-Acl -LiteralPath $locked
        $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
                $identity, 'Write', 'None', 'None', 'Deny'))
        Set-Acl -LiteralPath $locked -AclObject $acl

        if (Test-WriteAccess $locked) {
            throw 'Test-WriteAccess should report a deny-write file as not writable.'
        }
        if (-not (Grant-WriteAccess $locked)) {
            throw 'Grant-WriteAccess should restore write access on a deny-write file it owns.'
        }
        if (-not (Test-WriteAccess $locked)) {
            throw 'Write access should be usable after Grant-WriteAccess.'
        }

        $lockedDir = Join-Path $temp 'locked-dir'
        New-Item -ItemType Directory -Path $lockedDir -Force | Out-Null
        $dirAcl = Get-Acl -LiteralPath $lockedDir
        $dirAcl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
                $identity, 'Write', 'ContainerInherit,ObjectInherit', 'None', 'Deny'))
        Set-Acl -LiteralPath $lockedDir -AclObject $dirAcl

        if (Test-WriteAccess $lockedDir) {
            throw 'Test-WriteAccess should report a deny-write directory as not writable.'
        }
        if (-not (Grant-WriteAccess $lockedDir)) {
            throw 'Grant-WriteAccess should restore write access on a deny-write directory it owns.'
        }
    }

    # --- Assert-WriteAccess: silent when everything is writable ---
    $resources = Join-Path $temp 'app\resources'
    New-Item -ItemType Directory -Path $resources -Force | Out-Null
    Assert-WriteAccess $resources 'install'

    # --- Assert-WriteAccess: must stop the run when access cannot be obtained ---
    # A genuine "cannot write" state is not portable to fabricate, so stub the
    # producer and assert the contract: false must turn into a hard stop.
    function Enable-WriteAccess {
        param([string]$ResourcesPath)
        return $false
    }
    $threw = $false
    try {
        Assert-WriteAccess $resources 'install'
    }
    catch {
        $threw = $true
    }
    if (-not $threw) {
        throw 'Assert-WriteAccess should throw when write access cannot be obtained.'
    }

    Write-Host 'PASS: write access is decided by a real probe, not by reading the ACL.' -ForegroundColor Green
    Write-Host 'PASS: Grant-WriteAccess leaves already-writable targets untouched.' -ForegroundColor Green
    Write-Host 'PASS: Assert-WriteAccess aborts instead of continuing without write access.' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $temp) {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
