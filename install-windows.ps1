[CmdletBinding(DefaultParameterSetName = 'Launch')]
param(
    [Parameter(Position = 0, ParameterSetName = 'Launch')]
    [ValidateSet('install', 'uninstall', 'disable-updates', 'enable-updates', 'sync-skills', 'unsync-skills')]
    [string]$Action = 'install',

    [Parameter(Position = 1, ParameterSetName = 'Launch')]
    [ValidateSet('zh-CN', 'zh-TW', 'zh-HK')]
    [string]$Language = 'zh-CN',

    [Parameter(ParameterSetName = 'Launch')][switch]$Interactive,
    [Parameter(ParameterSetName = 'Launch')][string]$ClaudePath,
    [Parameter(ParameterSetName = 'Launch')][switch]$AllowTakeOwnership,
    [Parameter(ParameterSetName = 'Launch')][switch]$NoTerminal,

    [Parameter(Mandatory, ParameterSetName = 'Staged', DontShow)][switch]$RunStaged
)

$ErrorActionPreference = 'Stop'

function Test-InstallerAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        return [Security.Principal.WindowsPrincipal]::new($identity).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    finally {
        $identity.Dispose()
    }
}

function Test-PowerShell7Version {
    param([string]$VersionText)

    return ($VersionText.Trim() -match '^PowerShell (\d+\.\d+\.\d+(?:\.\d+)?)$') -and
        ([version]$Matches[1] -ge [version]'7.6.0')
}

function Get-LaunchWin32Error {
    param([Exception]$Exception)

    while ($Exception) {
        if ($Exception -is [ComponentModel.Win32Exception]) {
            return $Exception.NativeErrorCode
        }
        $Exception = $Exception.InnerException
    }
    return -1
}

function Get-InstallerPowerShellVersion {
    param([string]$Path)

    $start = [Diagnostics.ProcessStartInfo]::new($Path, '-NoLogo -NoProfile -NonInteractive -Version')
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    try {
        $output = $process.StandardOutput.ReadToEndAsync()
        $null = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(5000)) {
            if (-not $process.HasExited) { $process.Kill() }
            return
        }
        if ($process.ExitCode -eq 0 -and $output.Wait(1000)) { return $output.Result }
    }
    finally {
        $process.Dispose()
    }
}

function Find-InstallerPowerShell7 {
    $programFiles = [Environment]::GetFolderPath('ProgramFiles')
    $paths = @(
        if ($programFiles) { Join-Path $programFiles 'PowerShell\7\pwsh.exe' }
        Get-Command -Name 'pwsh.exe' -CommandType Application -All -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Path }
        if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path $PSHOME 'pwsh.exe' }
    )
    foreach ($path in ($paths | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        try {
            if (Test-PowerShell7Version (Get-InstallerPowerShellVersion $path)) { return $path }
        }
        catch {
            # 损坏的 App Execution Alias 不算可用的运行时；应用控制或代码完整性策略拒绝则不重试。
            if ((Get-LaunchWin32Error $_.Exception) -in 577, 1260) {
                throw "PowerShell 7 被系统或组织策略阻止，请联系管理员：$($_.Exception.Message)"
            }
        }
    }
}

function Get-InstallerHosts {
    param([bool]$UseTerminal, [string]$StageDirectory)

    $pwsh = Find-InstallerPowerShell7
    if ($pwsh) {
        # wt 把分号解释成新命令。用户路径留在交接文件中；若暂存路径或解释器路径含分号，直接启动 pwsh。
        if ($UseTerminal -and $StageDirectory -notlike '*;*' -and $pwsh -notlike '*;*') {
            $terminal = Get-Command -Name 'wt.exe' -CommandType Application -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($terminal) {
                [pscustomobject]@{ Name = 'Windows Terminal + PowerShell 7'; Path = $terminal.Path; PowerShell = $pwsh; Terminal = $true; Legacy = $false }
            }
        }
        [pscustomobject]@{ Name = 'PowerShell 7'; Path = $pwsh; Terminal = $false; Legacy = $false }
    }

    $windowsPowerShell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf) {
        [pscustomobject]@{ Name = 'Windows PowerShell 5.1'; Path = $windowsPowerShell; Terminal = $false; Legacy = $true }
    }
}

function Write-PowerShellInstallLinks {
    Write-Host '  Windows Terminal（可选）：https://apps.microsoft.com/detail/9n0dx20hk701'
    Write-Host '  PowerShell 7（Microsoft Store）：https://www.microsoft.com/store/apps/9MZ1SNWT0N5D'
    Write-Host '  商店不可用或商店版无法提权时，从官方 GitHub Releases 获取 PowerShell 7：'
    Write-Host '  https://github.com/PowerShell/PowerShell/releases/latest'
    Write-Host '  微软安装指南：https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows'
}

function New-InstallerContext {
    param([System.Collections.IDictionary]$Options, [string]$SourceDirectory)

    $customPath = if ($Options['ClaudePath']) { $Options['ClaudePath'] } else { $env:CLAUDE_PATH }
    if ($customPath) {
        # 5.1 从含方括号的目录启动时可能把当前位置切到 $PSHOME；统一以项目目录解析相对路径。
        Push-Location -LiteralPath $SourceDirectory
        try {
            $provider = $null
            $drive = $null
            $customPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
                $customPath, [ref]$provider, [ref]$drive)
            if ($provider.Name -ne 'FileSystem') { throw '-ClaudePath 和 CLAUDE_PATH 必须指向文件系统目录。' }
        }
        finally {
            Pop-Location
        }
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        return [ordered]@{
            Interactive = [bool]$Options['Interactive'] -or
                ('Interactive' -notin $Options.Keys -and 'Action' -notin $Options.Keys -and 'Language' -notin $Options.Keys)
            Action = if ('Action' -in $Options.Keys) { $Options['Action'] } else { 'install' }
            Language = if ('Language' -in $Options.Keys) { $Options['Language'] } else { 'zh-CN' }
            AllowTakeOwnership = [bool]$Options['AllowTakeOwnership']
            ClaudePath = [string]$customPath
            OriginalUserSid = $identity.User.Value
            OriginalUserProfile = [string]$env:USERPROFILE
            OriginalAppData = [string]$env:APPDATA
            OriginalLocalAppData = [string]$env:LOCALAPPDATA
            OriginalScoop = [string]$env:SCOOP
            OwnershipConsent = [string]$env:CLAUDE_ZH_ALLOW_TAKE_OWNERSHIP
            SkipUpdateCheck = [string]$env:CLAUDE_ZH_SKIP_UPDATE_CHECK
        }
    }
    finally {
        $identity.Dispose()
    }
}

function Assert-InstallerPayload {
    param([string]$Directory)

    foreach ($relativePath in @('install-windows.ps1', 'scripts\install_windows.ps1', 'resources\manifest.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Directory $relativePath) -PathType Leaf)) {
            throw "安装文件不完整（缺少 $relativePath）。请重新解压完整项目，保留同级 scripts 和 resources 目录。"
        }
    }
}

function New-InstallerStage {
    param([string]$SourceDirectory, [System.Collections.IDictionary]$Context, [string]$TempDirectory = [IO.Path]::GetTempPath())

    Assert-InstallerPayload $SourceDirectory
    $tempDrive = [IO.Path]::GetPathRoot($TempDirectory)
    if ($tempDrive -notmatch '^[A-Za-z]:[\\/]$' -or [IO.DriveInfo]::new($tempDrive).DriveType -ne [IO.DriveType]::Fixed) {
        throw "临时目录不在本地固定磁盘上：$TempDirectory。请在本地 Windows 临时目录可用时重试。"
    }
    $stage = Join-Path (Join-Path $TempDirectory 'ClaudeDesktopZhCnInstaller') ([guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($stage) | Out-Null
    foreach ($name in @('install-windows.ps1', 'scripts', 'resources')) {
        Copy-Item -LiteralPath (Join-Path $SourceDirectory $name) -Destination $stage -Recurse -Force
    }
    Assert-InstallerPayload $stage
    [IO.File]::WriteAllText((Join-Path $stage 'launch-context.json'), ($Context | ConvertTo-Json -Compress))
    return $stage
}

function Write-InstallerLaunchLog {
    param([string]$StageDirectory, [string]$Message)

    Add-Content -LiteralPath (Join-Path $StageDirectory 'install-windows-launch.log') -Encoding UTF8 -Value $Message
}

function New-InstallerStartInfo {
    param($Candidate, [string]$StageDirectory, [bool]$Interactive, [bool]$Elevate)

    $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass'
    if (-not $Interactive) { $arguments += ' -NonInteractive' }
    $stagedLauncher = Join-Path $StageDirectory 'install-windows.ps1'
    $arguments += ' -File "{0}" -RunStaged' -f $stagedLauncher
    if ($Candidate.Terminal) {
        # 只把已解析的可执行文件和暂存目录作为 wt 参数，不传任何用户输入的命令。
        $arguments = '-w new new-tab -d "{0}" "{1}" {2}' -f $StageDirectory, $Candidate.PowerShell, $arguments
    }
    $start = [Diagnostics.ProcessStartInfo]::new($Candidate.Path, $arguments)
    $start.WorkingDirectory = $StageDirectory
    $start.UseShellExecute = $Elevate -or $Interactive
    if ($Elevate) { $start.Verb = 'runas' }
    return $start
}

function Start-InstallerHost {
    param($Candidate, [string]$StageDirectory, [bool]$Interactive, [bool]$Elevate)

    # Start-Process 会把 Win32 错误包装成仅含本地化文本的异常，无法可靠识别 UAC 取消。
    [Diagnostics.Process]::Start((New-InstallerStartInfo $Candidate $StageDirectory $Interactive $Elevate))
}

function Wait-InstallerReady {
    param([string]$StageDirectory, $Process, [bool]$Terminal)

    $readyPath = Join-Path $StageDirectory 'installer.ready'
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $readyPath -PathType Leaf)) {
        # wt 可以委托给另一个进程；wt 自身退出不代表子 PowerShell 没有启动。
        if ($timer.Elapsed.TotalSeconds -ge 12 -or (-not $Terminal -and $Process -and $Process.HasExited)) {
            return (Test-Path -LiteralPath $readyPath -PathType Leaf)
        }
        Start-Sleep -Milliseconds 150
    }
    return $true
}

function Invoke-InstallerLaunch {
    param([string]$StageDirectory, [bool]$Interactive, [bool]$NoTerminal)

    $hosts = @(Get-InstallerHosts ($Interactive -and -not $NoTerminal) $StageDirectory)
    $logPath = Join-Path $StageDirectory 'install-windows-launch.log'
    $elevate = -not (Test-InstallerAdministrator)
    if ($hosts.Count -eq 0) {
        Write-PowerShellInstallLinks
        throw '找不到可用的 PowerShell 7.6+ 或 Windows PowerShell 5.1。'
    }

    foreach ($candidate in $hosts) {
        if ($candidate.Legacy) {
            Write-Host '无法启动 PowerShell 7.6+，将使用 Windows PowerShell 5.1 兼容模式。' -ForegroundColor Yellow
            Write-PowerShellInstallLinks
        }
        Write-InstallerLaunchLog $StageDirectory "启动方式：$($candidate.Name)；请求 UAC：$elevate"
        try {
            $process = Start-InstallerHost $candidate $StageDirectory $Interactive $elevate
        }
        catch {
            $code = Get-LaunchWin32Error $_.Exception
            Write-InstallerLaunchLog $StageDirectory "启动失败（Win32 $code）：$($_.Exception.Message)"
            if ($code -eq 1223) { throw "已取消 UAC 管理员授权，未修改 Claude Desktop。启动日志：$logPath" }
            # 只有明确未能创建进程（文件/应用不可用）才回退，不重试权限或组织策略拒绝。
            if ($code -in 2, 3, 50, 1155, 1920) {
                Write-Host "$($candidate.Name) 无法启动（Win32 $code），尝试下一种启动方式。" -ForegroundColor Yellow
                continue
            }
            throw "无法启动安装器：$($_.Exception.Message)。如受组织策略限制，请联系管理员。启动日志：$logPath"
        }

        try {
            if (-not $Interactive) {
                if (-not $process) { throw "已发出启动请求但未取得安装进程，未重试。启动日志：$logPath" }
                $process.WaitForExit()
                Write-InstallerLaunchLog $StageDirectory "安装器退出码：$($process.ExitCode)"
                if ($process.ExitCode -ne 0) {
                    Write-Host "安装未完成。启动和安装日志目录：$StageDirectory" -ForegroundColor Red
                }
                return $process.ExitCode
            }

            if (-not (Wait-InstallerReady $StageDirectory $process $candidate.Terminal)) {
                Write-InstallerLaunchLog $StageDirectory '已发出启动请求，但尚未确认安装器接管。'
                throw "未能确认安装器启动，不会自动重试。请查看新窗口和启动日志：$logPath。若是组织策略拦截，请联系管理员；若是终端问题，请确认前次窗口已关闭后加 -NoTerminal 重试。"
            }
            Write-Host "安装器已在 $($candidate.Name) 中启动。日志目录：$StageDirectory"
            return 0
        }
        finally {
            if ($process) { $process.Dispose() }
        }
    }
    throw "所有可用的启动方式均未能启动安装器，未修改 Claude Desktop。启动日志：$logPath"
}

function Invoke-StagedInstaller {
    param([string]$StageDirectory)

    if (-not (Test-InstallerAdministrator)) { throw '暂存安装器没有获得管理员权限，未修改 Claude Desktop。' }
    $version = $PSVersionTable.PSVersion
    if (-not (($PSVersionTable.PSEdition -eq 'Desktop' -and $version.Major -eq 5 -and $version.Minor -eq 1) -or
        (Test-PowerShell7Version "PowerShell $version"))) {
        throw "安装器收到不支持的 PowerShell 版本 $version，未修改 Claude Desktop。"
    }
    Assert-InstallerPayload $StageDirectory
    $context = Get-Content -LiteralPath (Join-Path $StageDirectory 'launch-context.json') -Encoding UTF8 -Raw | ConvertFrom-Json
    $params = @{
        Interactive = [bool]$context.Interactive
        Action = [string]$context.Action
        Language = [string]$context.Language
        AllowTakeOwnership = [bool]$context.AllowTakeOwnership
        ClaudePath = [string]$context.ClaudePath
        OriginalUserSid = [string]$context.OriginalUserSid
        OriginalUserProfile = [string]$context.OriginalUserProfile
        OriginalAppData = [string]$context.OriginalAppData
        OriginalLocalAppData = [string]$context.OriginalLocalAppData
        OriginalScoop = [string]$context.OriginalScoop
    }
    # WT 或跨账户 UAC 可能不继承调用者的进程环境。
    $env:CLAUDE_ZH_SKIP_UPDATE_CHECK = [string]$context.SkipUpdateCheck
    $env:CLAUDE_ZH_ALLOW_TAKE_OWNERSHIP = [string]$context.OwnershipConsent
    Write-InstallerLaunchLog $StageDirectory "已验证暂存安装器；PowerShell $version"
    $ready = [IO.File]::Open((Join-Path $StageDirectory 'installer.ready'), [IO.FileMode]::CreateNew)
    $ready.Dispose()
    & (Join-Path $StageDirectory 'scripts\install_windows.ps1') @params
}

try {
    if ($env:OS -ne 'Windows_NT') { throw '此安装入口仅适用于 Windows。' }
    if ($RunStaged) {
        Invoke-StagedInstaller $PSScriptRoot
        exit $LASTEXITCODE
    }

    $context = New-InstallerContext $PSBoundParameters $PSScriptRoot
    $stage = New-InstallerStage $PSScriptRoot $context
    exit (Invoke-InstallerLaunch $stage $context.Interactive $NoTerminal)
}
catch {
    $message = $_.Exception.Message
    if ($RunStaged -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'launch-context.json') -PathType Leaf)) {
        try { Write-InstallerLaunchLog $PSScriptRoot "暂存安装器失败：$message" } catch { }
    }
    Write-Host "[错误] $message" -ForegroundColor Red
    exit 1
}
