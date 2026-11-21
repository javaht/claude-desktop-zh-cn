$ErrorActionPreference = 'Stop'

# 只加载入口函数，不执行仓库中真实安装器的入口。端到端测试使用独立的合成安装包。
$launcherPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'install-windows.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($launcherPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$definitions = @{}
foreach ($definition in $ast.EndBlock.Statements) {
    if ($definition -is [Management.Automation.Language.FunctionDefinitionAst]) {
        $definitions[$definition.Name] = $definition.Extent.Text
        . ([scriptblock]::Create($definition.Extent.Text))
    }
}

function Assert-LauncherTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-LauncherError {
    param([scriptblock]$Operation, [string]$ExpectedText)
    try { & $Operation | Out-Null }
    catch {
        Assert-LauncherTest ($_.Exception.Message.Contains($ExpectedText)) "错误提示不匹配：$($_.Exception.Message)"
        return
    }
    throw "预期报错：$ExpectedText"
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('claude-windows-launcher-' + [guid]::NewGuid().ToString('N'))
try {
    [IO.Directory]::CreateDirectory($temp) | Out-Null
    $launcherBytes = [IO.File]::ReadAllBytes($launcherPath)
    Assert-LauncherTest ([BitConverter]::ToString($launcherBytes, 0, 3) -eq 'EF-BB-BF') '5.1 兼容入口必须保留 UTF-8 BOM。'
    Assert-LauncherTest (Test-PowerShell7Version "PowerShell 7.6.0`r`n") '应接受最低版本 PowerShell 7.6。'
    Assert-LauncherTest (-not (Test-PowerShell7Version 'PowerShell 7.5.11')) '不能使用低于最低版本的 PowerShell 7。'
    Assert-LauncherTest (-not (Test-PowerShell7Version 'PowerShell 7.7.0-preview.1')) '默认不选择预览版。'
    Assert-LauncherTest (-not (Test-PowerShell7Version '')) '空输出不能当作可用的运行时。'
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $detectedVersion = Get-InstallerPowerShellVersion (Join-Path $PSHOME 'pwsh.exe')
        Assert-LauncherTest ($detectedVersion.Trim() -eq "PowerShell $($PSVersionTable.PSVersion)") '未能正确探测当前 pwsh.exe 版本。'
    }

    $missingExe = Join-Path $temp 'not-installed.exe'
    $nativeError = 0
    try { Start-InstallerHost ([pscustomobject]@{ Path = $missingExe; Terminal = $false }) $temp $false $false }
    catch { $nativeError = Get-LaunchWin32Error $_.Exception }
    Assert-LauncherTest ($nativeError -eq 2) '启动错误必须保留 Win32 错误码，不能依赖系统语言。'

    $defaultContext = New-InstallerContext @{} $temp
    Assert-LauncherTest ($defaultContext.Interactive -and $defaultContext.OriginalUserSid -match '^S-1-') '默认应打开菜单并记录原用户 SID。'
    foreach ($action in 'install', 'uninstall', 'disable-updates', 'enable-updates', 'sync-skills', 'unsync-skills') {
        $context = New-InstallerContext @{ Action = $action; Language = 'zh-TW' } $temp
        Assert-LauncherTest (-not $context.Interactive -and $context.Action -eq $action -and $context.Language -eq 'zh-TW') "非交互操作未保留：$action"
    }
    Assert-LauncherError { New-InstallerStage (Join-Path $temp '缺少安装包') $defaultContext $temp } '安装文件不完整'
    Assert-LauncherTest (-not (Test-Path -LiteralPath (Join-Path $temp 'ClaudeDesktopZhCnInstaller'))) '缺少载荷时不应先创建暂存目录。'
    Assert-LauncherTest (-not (Wait-InstallerReady $temp ([pscustomobject]@{ HasExited = $true }) $false)) '直接启动失败不能报告就绪。'

    # 控制运行时和 Terminal 的发现结果，不启动真实窗口或请求 UAC。
    $script:testPwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
    $script:testTerminal = 'C:\Terminal\wt.exe'
    function Find-InstallerPowerShell7 { $script:testPwsh }
    function Get-Command {
        param($Name, $CommandType, $ErrorAction)
        if ($Name -ne 'wt.exe' -or $CommandType -ne 'Application') { throw "意外的命令发现：$Name" }
        if ($script:testTerminal) { [pscustomobject]@{ Path = $script:testTerminal } }
    }
    $expectedOrder = 'Windows Terminal + PowerShell 7,PowerShell 7,Windows PowerShell 5.1'
    $stagePath = Join-Path $temp '中文 暂存 [样例]'
    $candidates = @(Get-InstallerHosts $true $stagePath)
    Assert-LauncherTest (($candidates.Name -join ',') -eq $expectedOrder) 'Terminal + 7、直接 7、5.1 顺序不正确。'
    $terminalStart = New-InstallerStartInfo $candidates[0] $stagePath $true $true
    $stagedEntry = Join-Path $stagePath 'install-windows.ps1'
    Assert-LauncherTest ($terminalStart.UseShellExecute -and $terminalStart.Verb -eq 'runas' -and $terminalStart.FileName -eq $script:testTerminal) 'Terminal 应通过系统 UAC 启动。'
    Assert-LauncherTest ($terminalStart.Arguments.StartsWith(('-w new new-tab -d "{0}" "{1}" ' -f $stagePath, $script:testPwsh))) 'Terminal 应在新窗口中启动指定的 pwsh.exe。'
    Assert-LauncherTest ($terminalStart.Arguments.EndsWith(('-File "{0}" -RunStaged' -f $stagedEntry))) '启动参数必须使用已引用的绝对暂存路径。'
    $directStart = New-InstallerStartInfo $candidates[1] $stagePath $false $false
    Assert-LauncherTest (-not $directStart.UseShellExecute -and $directStart.Arguments.Contains(' -NonInteractive ')) '已有管理员权限的非交互调用不应再次提权或打开 Terminal。'
    $directOrder = 'PowerShell 7,Windows PowerShell 5.1'
    Assert-LauncherTest (((Get-InstallerHosts $false $temp).Name -join ',') -eq $directOrder) '禁用 Terminal 或非交互时必须直接启动。'
    Assert-LauncherTest (((Get-InstallerHosts $true "$temp;分隔符").Name -join ',') -eq $directOrder) '不能把含分号的暂存路径交给 wt 解析。'
    $terminalPath = $script:testTerminal
    $script:testTerminal = $null
    Assert-LauncherTest (((Get-InstallerHosts $true $temp).Name -join ',') -eq $directOrder) '无 Terminal 时仍应优先直接启动 PowerShell 7。'
    $script:testTerminal = $terminalPath
    $pwshPath = $script:testPwsh
    $script:testPwsh = $null
    Assert-LauncherTest (((Get-InstallerHosts $true $temp).Name -join ',') -eq 'Windows PowerShell 5.1') '无可用 PowerShell 7 时必须回退到系统 5.1。'
    $script:testPwsh = $pwshPath

    $script:startedHosts = @()
    $script:launchErrors = @{}
    $script:confirmReady = $true
    $script:waitedForChild = $false
    function Test-InstallerAdministrator { return $false }
    function Wait-InstallerReady { return $script:confirmReady }
    function Start-InstallerHost {
        param($Candidate, $StageDirectory, $Interactive, $Elevate)
        Assert-LauncherTest $Elevate '非管理员启动必须明确请求 UAC。'
        $script:startedHosts += $Candidate.Name
        if ($script:launchErrors[$Candidate.Name]) {
            throw [ComponentModel.Win32Exception]::new([int]$script:launchErrors[$Candidate.Name])
        }
        $process = [pscustomobject]@{ ExitCode = 37 }
        $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { $script:waitedForChild = $true }
        $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
        return $process
    }
    $terminalName = 'Windows Terminal + PowerShell 7'
    $script:launchErrors[$terminalName] = 1223
    Assert-LauncherError { Invoke-InstallerLaunch $temp $true $false } '已取消 UAC'
    Assert-LauncherTest (($script:startedHosts -join ',') -eq $terminalName) '取消 UAC 后不能尝试其他启动方式。'
    $script:startedHosts = @()
    $script:launchErrors[$terminalName] = 1260
    Assert-LauncherError { Invoke-InstallerLaunch $temp $true $false } '组织策略'
    Assert-LauncherTest (($script:startedHosts -join ',') -eq $terminalName) '策略拒绝后不能回退。'
    $script:startedHosts = @()
    $script:launchErrors[$terminalName] = 1920
    Assert-LauncherTest ((Invoke-InstallerLaunch $temp $true $false) -eq 0) 'Terminal 明确不可用时应成功直接启动 PowerShell 7。'
    Assert-LauncherTest (($script:startedHosts -join ',') -eq "$terminalName,PowerShell 7") '终端不可用后的回退顺序不正确。'
    $script:startedHosts = @()
    $script:launchErrors['PowerShell 7'] = 2
    Assert-LauncherTest ((Invoke-InstallerLaunch $temp $true $false) -eq 0) 'PowerShell 7 无法创建进程时应使用可用的 5.1。'
    Assert-LauncherTest (($script:startedHosts -join ',') -eq $expectedOrder) '启动失败应按优先级逐级回退。'
    $script:startedHosts = @()
    $script:launchErrors = @{}
    $script:confirmReady = $false
    Assert-LauncherError { Invoke-InstallerLaunch $temp $true $false } '未能确认安装器启动'
    Assert-LauncherTest (($script:startedHosts -join ',') -eq $terminalName) '终端已接受请求但状态不明时不能重复启动安装器。'
    $script:startedHosts = @()
    Assert-LauncherTest ((Invoke-InstallerLaunch $temp $false $false) -eq 37 -and $script:waitedForChild) '非交互需要等待并传回真实退出码。'
    Assert-LauncherTest (($script:startedHosts -join ',') -eq 'PowerShell 7') '非交互失败不能通过 Terminal 或 5.1 再运行一次。'
    Assert-LauncherError { Invoke-StagedInstaller $temp } '没有获得管理员权限'
    Assert-LauncherTest (-not (Test-Path -LiteralPath (Join-Path $temp 'installer.ready'))) '未获得管理员权限时不能执行安装载荷。'

    # 保留真实入口和参数绑定，只在合成副本中替换管理员检测；载荷只写回收到的参数。
    # 5.1 环境中模拟未装 7，以便真实验证兼容回退和 BOM 解码。
    $source = Join-Path $temp '中文 安装包 [测试];样例'
    [IO.Directory]::CreateDirectory((Join-Path $source 'scripts')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $source 'resources')) | Out-Null
    $syntheticLauncher = [IO.File]::ReadAllText($launcherPath).Replace(
        $definitions['Test-InstallerAdministrator'], 'function Test-InstallerAdministrator { return $true }')
    $legacy = $PSVersionTable.PSEdition -eq 'Desktop'
    if ($legacy) {
        $syntheticLauncher = $syntheticLauncher.Replace($definitions['Find-InstallerPowerShell7'], 'function Find-InstallerPowerShell7 { }')
    }
    [IO.File]::WriteAllText((Join-Path $source 'install-windows.ps1'), $syntheticLauncher, [Text.UTF8Encoding]::new($true))
    [IO.File]::WriteAllText((Join-Path $source 'resources\manifest.json'), '{}')
    [IO.File]::WriteAllText((Join-Path $source 'scripts\install_windows.ps1'), @'
param([switch]$Interactive, [string]$Action, [string]$Language, [switch]$AllowTakeOwnership,
    [string]$ClaudePath, [string]$OriginalUserSid, [string]$OriginalUserProfile,
    [string]$OriginalAppData, [string]$OriginalLocalAppData, [string]$OriginalScoop)
$result = @{} + $PSBoundParameters
$result.Interactive = [bool]$Interactive
$result.AllowTakeOwnership = [bool]$AllowTakeOwnership
$result.OwnershipConsent = $env:CLAUDE_ZH_ALLOW_TAKE_OWNERSHIP
$result.SkipUpdateCheck = $env:CLAUDE_ZH_SKIP_UPDATE_CHECK
$result.Runtime = $PSVersionTable.PSEdition
$result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot '..\received.json') -Encoding UTF8
exit 37
'@)

    $claude = Join-Path $source "Claude [自定义];O'Brien"
    $executable = Join-Path $PSHOME $(if ($legacy) { 'powershell.exe' } else { 'pwsh.exe' })
    $commandLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File .\install-windows.ps1 uninstall zh-HK -AllowTakeOwnership -NoTerminal -ClaudePath ".\{0}"' -f (Split-Path -Leaf $claude)
    $start = [Diagnostics.ProcessStartInfo]::new($executable, $commandLine)
    $start.UseShellExecute = $false
    $start.WorkingDirectory = $source
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.EnvironmentVariables['TEMP'] = $source
    $start.EnvironmentVariables['TMP'] = $source
    # 不伪造系统用户目录，PowerShell 7 初始化本身需要它们和 Windows Known Folders 一致。
    $start.EnvironmentVariables['SCOOP'] = (Join-Path $source '自定义 Scoop') + '\'
    $start.EnvironmentVariables['CLAUDE_PATH'] = Join-Path $source '环境变量路径不应优先'
    $start.EnvironmentVariables['CLAUDE_ZH_SKIP_UPDATE_CHECK'] = '1'
    $start.EnvironmentVariables['CLAUDE_ZH_ALLOW_TAKE_OWNERSHIP'] = 'yes'
    $process = [Diagnostics.Process]::Start($start)
    try {
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) { throw '合成安装器未在限定时间退出。' }
        Assert-LauncherTest ($process.ExitCode -eq 37) "未收到合成安装器退出码 37（实际 $($process.ExitCode)）：$($output.Result) $($errors.Result)"
    }
    finally {
        if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        $process.Dispose()
    }

    $staged = @(Get-ChildItem -LiteralPath (Join-Path $source 'ClaudeDesktopZhCnInstaller') -Directory)
    Assert-LauncherTest ($staged.Count -eq 1) '每次调用只能成功暂存一份安装包。'
    $received = Get-Content -LiteralPath (Join-Path $staged[0].FullName 'received.json') -Encoding UTF8 -Raw | ConvertFrom-Json
    Assert-LauncherTest ($received.Action -eq 'uninstall' -and $received.Language -eq 'zh-HK' -and -not $received.Interactive) '跨进程调用未保留非交互操作参数。'
    Assert-LauncherTest ($received.Runtime -eq $PSVersionTable.PSEdition) '合成安装器使用了错误的运行时。'
    Assert-LauncherTest ($received.OriginalUserSid -eq $defaultContext.OriginalUserSid) '没有正确传递原用户 SID。'
    Assert-LauncherTest ($received.ClaudePath -ceq $claude) "没有正确传递显式自定义路径：期望 $claude，实际 $($received.ClaudePath)。"
    foreach ($pair in @(@('OriginalUserProfile', 'USERPROFILE'), @('OriginalAppData', 'APPDATA'), @('OriginalLocalAppData', 'LOCALAPPDATA'), @('OriginalScoop', 'SCOOP'))) {
        Assert-LauncherTest ($received.($pair[0]) -ceq $start.EnvironmentVariables[$pair[1]]) "没有原样传递 $($pair[0])。"
    }
    Assert-LauncherTest ($received.AllowTakeOwnership -and $received.OwnershipConsent -eq 'yes' -and $received.SkipUpdateCheck -eq '1') '授权选项和更新检查环境未从调用者传递。'
    foreach ($file in 'install-windows-launch.log', 'installer.ready') {
        Assert-LauncherTest (Test-Path -LiteralPath (Join-Path $staged[0].FullName $file) -PathType Leaf) "缺少启动记录 $file。"
    }
    Write-Host "PASS：Windows 启动优先级、运行时回退、UAC 失败保护、中文路径、原用户参数和退出码（$($PSVersionTable.PSVersion)）。" -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $temp -PathType Container) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
