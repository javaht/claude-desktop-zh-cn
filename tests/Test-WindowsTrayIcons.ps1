$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Load-InstallerFunctions.ps1') -FunctionNames @(
    'Assert-WindowsIconBytes', 'Get-WindowsTrayIconBytes', 'Install-WindowsTrayIcons', 'Get-BackupRoot',
    'New-BackupSet', 'Get-RelativeResourcePath', 'Backup-ModifiedFile',
    'Restore-LatestBackup', 'Get-ClaudeAppPathFromResources'
)
$temp = Join-Path ([IO.Path]::GetTempPath()) ('claude-tray-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
$iconBytes = Get-WindowsTrayIconBytes
$script:OriginalLight = [byte[]]$iconBytes.Clone()
$script:OriginalDark = [byte[]]$iconBytes.Clone()
$script:OriginalLight[190] = 1
$script:OriginalDark[190] = 2
$names = @('Tray-Win32.ico', 'Tray-Win32-Dark.ico')
function New-TrayFixture {
    param([string]$Name)
    $path = Join-Path $temp $Name
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $path $names[0]), $script:OriginalLight)
    [IO.File]::WriteAllBytes((Join-Path $path $names[1]), $script:OriginalDark)
    [IO.File]::WriteAllBytes((Join-Path $path 'app.asar'), [byte[]]@(9, 10, 11))
    $script:CurrentBackupSetPath = $null
    return $path
}
function Assert-Bytes {
    param([string]$Path, [byte[]]$Expected)
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($Path)) -cne [Convert]::ToBase64String($Expected)) {
        throw "Unexpected bytes: $Path"
    }
}
try {
    $fixture = New-TrayFixture 'resources with spaces'
    if (-not (Install-WindowsTrayIcons $fixture $iconBytes)) { throw 'Tray installation did not report an update' }
    foreach ($name in $names) { Assert-Bytes (Join-Path $fixture $name) $iconBytes }
    $backup = New-BackupSet $fixture
    Assert-Bytes (Join-Path $backup $names[0]) ($script:OriginalLight)
    Assert-Bytes (Join-Path $backup $names[1]) ($script:OriginalDark)
    Assert-Bytes (Join-Path $fixture 'app.asar') ([byte[]]@(9, 10, 11))
    $timestamps = @($names | ForEach-Object { (Get-Item -LiteralPath (Join-Path $fixture $_)).LastWriteTimeUtc.Ticks })
    if (Install-WindowsTrayIcons $fixture $iconBytes) { throw 'Repeated installation reported an update' }
    for ($i = 0; $i -lt $names.Count; $i++) {
        if ((Get-Item -LiteralPath (Join-Path $fixture $names[$i])).LastWriteTimeUtc.Ticks -ne $timestamps[$i]) { throw 'Repeated installation rewrote an icon' }
    }
    Restore-LatestBackup $fixture
    Assert-Bytes (Join-Path $fixture $names[0]) ($script:OriginalLight)
    Assert-Bytes (Join-Path $fixture $names[1]) ($script:OriginalDark)
    [void](Install-WindowsTrayIcons $fixture $iconBytes)
    Assert-Bytes (Join-Path $backup $names[0]) ($script:OriginalLight)
    Assert-Bytes (Join-Path $backup $names[1]) ($script:OriginalDark)

    $fixture = New-TrayFixture 'missing variant'
    Remove-Item -LiteralPath (Join-Path $fixture $names[1])
    if (Install-WindowsTrayIcons $fixture $iconBytes) { throw 'Missing variant was accepted' }
    Assert-Bytes (Join-Path $fixture $names[0]) ($script:OriginalLight)
    if (Test-Path (Get-BackupRoot $fixture)) { throw 'Missing variant caused backup writes' }

    $fixture = New-TrayFixture 'backup failure'
    $backup = New-BackupSet $fixture
    New-Item -ItemType Directory -Path (Join-Path $backup $names[1]) | Out-Null
    $failed = $false
    try { Install-WindowsTrayIcons $fixture $iconBytes | Out-Null } catch { $failed = $true }
    if (-not $failed) { throw 'Backup failure was ignored' }
    Assert-Bytes (Join-Path $fixture $names[0]) ($script:OriginalLight)
    Assert-Bytes (Join-Path $fixture $names[1]) ($script:OriginalDark)

    foreach ($length in @(0, 4, 100, ($iconBytes.Length - 1))) {
        $fixture = New-TrayFixture ("truncated backup " + $length)
        $backup = New-BackupSet $fixture
        $damaged = [byte[]]::new($length)
        [Array]::Copy($iconBytes, $damaged, $length)
        $backupPath = Join-Path $backup $names[0]
        [IO.File]::WriteAllBytes($backupPath, $damaged)
        $failed = $false
        try { Install-WindowsTrayIcons $fixture $iconBytes | Out-Null } catch { $failed = $true }
        if (-not $failed) { throw "Truncated backup was accepted: $length" }
        Assert-Bytes (Join-Path $fixture $names[0]) $script:OriginalLight
        Assert-Bytes (Join-Path $fixture $names[1]) $script:OriginalDark
        Assert-Bytes $backupPath $damaged
    }

    $fixture = New-TrayFixture 'write failure'
    $locked = [IO.File]::Open((Join-Path $fixture $names[1]), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $failed = $false
        try { Install-WindowsTrayIcons $fixture $iconBytes | Out-Null } catch { $failed = $true }
        if (-not $failed) { throw 'Locked second icon was overwritten' }
        Assert-Bytes (Join-Path $fixture $names[0]) ($script:OriginalLight)
        Assert-Bytes (Join-Path $fixture $names[1]) ($script:OriginalDark)
    } finally { $locked.Dispose() }

    $script:InstallerScriptRoot = Join-Path $temp 'invalid-source/scripts'
    $sourceDir = Join-Path $temp 'invalid-source/resources'
    New-Item -ItemType Directory -Path $sourceDir -Force | Out-Null
    $source = Join-Path $sourceDir 'claude-tray-windows.ico'
    foreach ($bad in @(
        [byte[]]@(0, 0, 1, 0),
        [byte[]]@(0, 0, 1, 0, 0, 0),
        [byte[]]@(0, 0, 1, 0, 1, 0),
        ([byte[]]@(0, 0, 1, 0, 1, 0) + [byte[]]::new(16))
    )) {
        [IO.File]::WriteAllBytes($source, $bad)
        $failed = $false
        try { Get-WindowsTrayIconBytes | Out-Null } catch { $failed = $true }
        if (-not $failed) { throw 'Malformed ICO was accepted' }
    }

    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        Add-Type -AssemblyName System.Drawing
        Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class TrayIconRendering {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern IntPtr LoadImage(IntPtr instance, string path, uint type, int width, int height, uint flags);
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr icon);
}
'@
        $renderPath = Join-Path $temp 'render.ico'
        [IO.File]::WriteAllBytes($renderPath, $iconBytes)
        foreach ($size in @(16, 20, 24, 32, 40, 48, 64, 128, 256)) {
            $handle = [TrayIconRendering]::LoadImage([IntPtr]::Zero, $renderPath, 1, $size, $size, 0x10)
            if ($handle -eq [IntPtr]::Zero) { throw "Windows could not load icon size: $size" }
            $icon = [Drawing.Icon]::FromHandle($handle)
            $bitmap = $icon.ToBitmap()
            try {
                if ($bitmap.Width -ne $size -or $bitmap.Height -ne $size) { throw "Missing icon size: $size" }
                $orange = 0; $white = 0
                for ($y = 0; $y -lt $size; $y++) {
                    for ($x = 0; $x -lt $size; $x++) {
                        $pixel = $bitmap.GetPixel($x, $y)
                        if ($pixel.A -gt 128 -and $pixel.R -gt 170 -and $pixel.G -gt 60 -and $pixel.G -lt 180 -and $pixel.B -lt 160) { $orange++ }
                        if ($pixel.A -gt 128 -and $pixel.R -gt 220 -and $pixel.G -gt 210 -and $pixel.B -gt 180) { $white++ }
                    }
                }
                if ($orange -lt ($size * $size * 0.4) -or $white -lt ($size * $size * 0.05)) { throw "Not orange and white: $size" }
                if ($bitmap.GetPixel(0, 0).A -gt 64) { throw "Rounded corner transparency lost: $size" }
            } finally { $bitmap.Dispose(); $icon.Dispose(); [void][TrayIconRendering]::DestroyIcon($handle) }
        }
    }
    Write-Output 'PASS: both tray variants, original backups, repeat install, restore, safe skip, rollback, ICO validation and Windows color rendering'
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force
}
