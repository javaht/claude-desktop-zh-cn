#requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function New-InstallerStage {
    param([string]$SourceRoot, [string]$TempRoot)

    if (-not (Test-Path -LiteralPath (Join-Path $SourceRoot 'scripts\install_windows.ps1') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $SourceRoot 'resources') -PathType Container)) {
        throw '安装文件不完整：请重新解压整个项目，保留 scripts 和 resources 目录。'
    }
    # 每次使用独立目录，避免并行启动互相覆盖或删除上一轮安装文件。
    $stage = Join-Path $TempRoot ('ClaudeDesktopZhCnInstaller\' + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    foreach ($name in @('scripts', 'resources')) {
        Copy-Item -LiteralPath (Join-Path $SourceRoot $name) -Destination $stage -Recurse -Force
    }
    foreach ($name in @('install-windows.ps1', 'install-windows.bat', 'README.md')) {
        $file = Join-Path $SourceRoot $name
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            Copy-Item -LiteralPath $file -Destination $stage -Force
        }
    }
    return $stage
}

function New-InstallerEncodedCommand {
    param([string]$ScriptPath, [hashtable]$OriginalUser)

    $context = @{ ScriptPath = $ScriptPath; OriginalUser = $OriginalUser } | ConvertTo-Json -Compress
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($context))
    # 参数作为 JSON 数据传递，避免用户路径经过批处理和多层命令字符串转义。
    $command = @'
$ErrorActionPreference = 'Stop'
try {
    $context = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__PAYLOAD__')) | ConvertFrom-Json -AsHashtable
    $parameters = $context.OriginalUser
    & $context.ScriptPath -Interactive @parameters
}
catch {
    Write-Host "[启动失败] $($_.Exception.Message)" -ForegroundColor Red
    [void](Read-Host '按 Enter 关闭此窗口')
    exit 1
}
'@
    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command.Replace('__PAYLOAD__', $payload)))
}

function Test-UacCancellation {
    param([Exception]$Exception)

    for ($current = $Exception; $null -ne $current; $current = $current.InnerException) {
        if ($current -is [ComponentModel.Win32Exception] -and $current.NativeErrorCode -eq 1223) {
            return $true
        }
    }
    return $false
}

function Start-InstallerWindow {
    param([string]$PwshPath, [string]$StagePath, [hashtable]$OriginalUser, [string]$TerminalPath)

    $encoded = New-InstallerEncodedCommand (Join-Path $StagePath 'scripts\install_windows.ps1') $OriginalUser
    if ($TerminalPath) {
        try {
            $arguments = @('-w', 'new', 'new-tab', '-d', ('"{0}"' -f $StagePath), ('"{0}"' -f $PwshPath), '-NoProfile', '-EncodedCommand', $encoded)
            Start-Process -FilePath $TerminalPath -ArgumentList $arguments -WorkingDirectory $StagePath -Verb RunAs -ErrorAction Stop
            return
        }
        catch {
            if (Test-UacCancellation $_.Exception) { throw }
            Write-Warning "无法启动 Windows Terminal，改用 PowerShell 7：$($_.Exception.Message)"
        }
    }
    Start-Process -FilePath $PwshPath -ArgumentList @('-NoProfile', '-EncodedCommand', $encoded) -WorkingDirectory $StagePath -Verb RunAs -ErrorAction Stop
}

try {
    if (-not $IsWindows) { throw '此入口仅支持 Windows。' }
    $pwshPath = Join-Path $PSHOME 'pwsh.exe'
    $originalUser = @{
        OriginalUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        OriginalUserProfile = $env:USERPROFILE
        OriginalAppData = $env:APPDATA
        OriginalLocalAppData = $env:LOCALAPPDATA
    }
    Write-Host '正在暂存安装文件到本地临时目录……'
    $stage = New-InstallerStage $PSScriptRoot ([IO.Path]::GetTempPath())
    $terminal = Get-Command wt.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $terminalPath = if ($terminal) { $terminal.Source } else { $null }
    @{ script = (Join-Path $stage 'scripts\install_windows.ps1'); powershell = $pwshPath; terminal = $terminalPath } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage 'install-windows-launch.log') -Encoding utf8
    Write-Host '正在请求管理员权限，请在 UAC 提示中确认。'
    Start-InstallerWindow $pwshPath $stage $originalUser $terminalPath
    Write-Host "安装器已在新的管理员窗口启动，日志目录：$stage"
    exit 0
}
catch {
    if (Test-UacCancellation $_.Exception) {
        Write-Host '已取消管理员授权，安装未启动。' -ForegroundColor Yellow
    }
    else {
        Write-Host "[启动失败] $($_.Exception.Message)" -ForegroundColor Red
    }
    exit 1
}
