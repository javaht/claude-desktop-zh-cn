# Install / uninstall / status / watch for Windows Frida Chinese (user Scheduled Task).
#
# Usage:
#   frida-zh-resident-ctl.ps1 -Action install -PythonExe <py> -Language zh-CN [-Port 19351] [-RepoRoot <root>]
#   frida-zh-resident-ctl.ps1 -Action uninstall [-RemoveRuntime]
#   frida-zh-resident-ctl.ps1 -Action status
#   frida-zh-resident-ctl.ps1 -Action watch   (task entrypoint)

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("install", "uninstall", "status", "watch")]
    [string]$Action,

    [string]$PythonExe = "",
    [ValidateSet("zh-CN", "zh-TW", "zh-HK", "")]
    [string]$Language = "zh-CN",
    [int]$Port = 19351,
    [string]$RepoRoot = "",
    [switch]$RemoveRuntime
)

$ErrorActionPreference = "Stop"
$TaskName = "ClaudeDesktopZhCn-FridaZh"
$TaskPath = "\"
$Label = "claude-desktop-zh-cn-frida-zh"
$RunValueName = "ClaudeDesktopZhCnFridaZh"

function Get-ClaudeZhRoot {
    $local = $env:CLAUDE_ZH_ORIGINAL_LOCALAPPDATA
    if (-not $local) { $local = [Environment]::GetFolderPath("LocalApplicationData") }
    if (-not $local) { $local = $env:LOCALAPPDATA }
    return (Join-Path $local "claude-zh")
}

function Get-RuntimeRoot {
    if ($env:CLAUDE_ZH_RUNTIME) { return $env:CLAUDE_ZH_RUNTIME }
    return (Join-Path (Get-ClaudeZhRoot) "runtime")
}

function Write-Info([string]$Message) { Write-Host "[frida-resident] $Message" }
function Write-Warn([string]$Message) { Write-Host "[frida-resident] $Message" -ForegroundColor Yellow }

function Stop-FridaRelated {
    # Only stop clearly-ours processes. Do NOT match parent shells (bash/cmd)
    # whose command lines merely mention this script path (e.g. installer host).
    $targets = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        if (-not $_.CommandLine) { return $false }
        $name = [string]$_.Name
        $cmd = [string]$_.CommandLine
        if ($name -like "frida-helper*") { return $true }
        # cmd running our wrapper
        if ($name -match '^(cmd)(\.exe)?$' -and $cmd -like "*claude-zh*watch.cmd*") {
            return $true
        }
        # Python running our launcher
        if ($name -match '^(python|pythonw)(\.exe)?$' -and $cmd -like "*frida_launch_zh_win.py*") {
            return $true
        }
        # PowerShell running our watch entrypoint only (not install/uninstall/status)
        if ($name -match '^(powershell|pwsh)(\.exe)?$' -and
            $cmd -like "*frida-zh-resident-ctl.ps1*" -and
            $cmd -match '(?i)(-Action\s+watch|/Action\s+watch)') {
            return $true
        }
        return $false
    })
    foreach ($proc in $targets) {
        try {
            Write-Info "停止 PID $($proc.ProcessId) ($($proc.Name))"
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
        }
        catch {}
    }
}

function Unregister-FridaTask {
    # Task may not exist yet (first install). Never treat "not found" as fatal:
    # $ErrorActionPreference=Stop would otherwise promote schtasks stderr to a
    # terminating NativeCommandError.
    try {
        $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($existing) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
    catch {}

    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        # Redirect both streams; ignore non-zero exit when task is absent.
        $null = & schtasks.exe /Delete /TN $TaskName /F 2>&1
    }
    catch {}
    finally {
        $ErrorActionPreference = $prevEap
    }
}

function Get-TaskUserName {
    # Prefer the interactive user that launched install-windows.bat (before UAC).
    if ($env:CLAUDE_ZH_ORIGINAL_USER_PROFILE) {
        $leaf = Split-Path -Leaf $env:CLAUDE_ZH_ORIGINAL_USER_PROFILE
        if ($leaf) {
            if ($env:USERDOMAIN) { return "$env:USERDOMAIN\$leaf" }
            return $leaf
        }
    }
    if ($env:CLAUDE_ZH_ORIGINAL_USER_SID) {
        try {
            $sid = New-Object System.Security.Principal.SecurityIdentifier($env:CLAUDE_ZH_ORIGINAL_USER_SID)
            $account = $sid.Translate([System.Security.Principal.NTAccount])
            if ($account -and $account.Value) {
                return $account.Value
            }
        }
        catch {}
    }
    if ($env:USERDOMAIN -and $env:USERNAME) {
        return "$env:USERDOMAIN\$env:USERNAME"
    }
    return $env:USERNAME
}

function Quote-CommandArg([string]$Value) {
    if ($Value -match '[\s"]') {
        return '"' + ($Value -replace '"', '\"') + '"'
    }
    return $Value
}

function Get-WatchPowerShellCommand {
    param(
        [string]$Root,
        [string]$Py,
        [string]$Lang,
        [int]$TaskPort
    )
    $ctl = Join-Path $Root "scripts\experimental\frida-zh-resident-ctl.ps1"
    $argv = @(
        (Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"),
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $ctl,
        "-Action", "watch",
        "-PythonExe", $Py,
        "-Language", $Lang,
        "-Port", "$TaskPort",
        "-RepoRoot", $Root
    )
    return (($argv | ForEach-Object { Quote-CommandArg ([string]$_) }) -join " ")
}

function Write-WatchLauncher {
    param(
        [string]$Root,
        [string]$Py,
        [string]$Lang,
        [int]$TaskPort
    )
    # Short entrypoint so schtasks /TR stays under the 261-char limit.
    $zhRoot = Get-ClaudeZhRoot
    New-Item -ItemType Directory -Path $zhRoot -Force | Out-Null
    $wrapper = Join-Path $zhRoot "watch.cmd"
    $watchCommand = Get-WatchPowerShellCommand -Root $Root -Py $Py -Lang $Lang -TaskPort $TaskPort
    $lines = @(
        "@echo off",
        "setlocal",
        "rem Auto-generated by claude-desktop-zh-cn Frida resident installer.",
        $watchCommand
    )
    $ascii = New-Object System.Text.ASCIIEncoding
    [System.IO.File]::WriteAllLines($wrapper, $lines, $ascii)
    return $wrapper
}

function Get-CmdArgumentsForWrapper([string]$WrapperPath) {
    return "/d /c `"`"$WrapperPath`"`""
}

function Write-HiddenLauncher {
    param(
        [string]$WrapperPath = "",
        [string]$CommandLine = "",
        [string]$LauncherPath = ""
    )

    if (-not $CommandLine) {
        if (-not $WrapperPath) { throw "Write-HiddenLauncher 需要 WrapperPath 或 CommandLine" }
        $CommandLine = "cmd.exe $(Get-CmdArgumentsForWrapper $WrapperPath)"
    }
    if (-not $LauncherPath) {
        $LauncherPath = Join-Path (Get-ClaudeZhRoot) "watch-hidden.vbs"
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $LauncherPath) -Force | Out-Null
    $escaped = $CommandLine.Replace('"', '""')
    $lines = @(
        'Set shell = CreateObject("WScript.Shell")',
        ('shell.Run "{0}", 0, False' -f $escaped)
    )
    $ascii = New-Object System.Text.ASCIIEncoding
    [System.IO.File]::WriteAllLines($LauncherPath, $lines, $ascii)
    return $LauncherPath
}

function Write-StartupLauncher {
    param(
        [string]$WrapperPath = "",
        [string]$CommandLine = ""
    )

    $startup = [Environment]::GetFolderPath("Startup")
    if (-not $startup) {
        $startup = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup"
    }
    $launcherPath = Join-Path $startup "ClaudeDesktopZhCn-FridaZh.vbs"
    return (Write-HiddenLauncher -WrapperPath $WrapperPath -CommandLine $CommandLine -LauncherPath $launcherPath)
}

function Write-RunKeyLauncher {
    param(
        [string]$WrapperPath = "",
        [string]$CommandLine = ""
    )

    $launcherPath = Write-HiddenLauncher -WrapperPath $WrapperPath -CommandLine $CommandLine
    $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    New-Item -Path $runKey -Force | Out-Null
    $wscript = Join-Path $env:WINDIR "System32\wscript.exe"
    $value = "`"$wscript`" `"$launcherPath`""
    Set-ItemProperty -Path $runKey -Name $RunValueName -Value $value -Force
    return $launcherPath
}

function Clear-UserAutostart {
    try {
        $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
        Remove-ItemProperty -Path $runKey -Name $RunValueName -Force -ErrorAction SilentlyContinue
    }
    catch {}
    try {
        $hiddenLauncher = Join-Path (Get-ClaudeZhRoot) "watch-hidden.vbs"
        if (Test-Path -LiteralPath $hiddenLauncher) {
            Remove-Item -LiteralPath $hiddenLauncher -Force -ErrorAction SilentlyContinue
        }
    }
    catch {}
    try {
        foreach ($startupLink in @((Get-StartupShortcutPath), (Get-LegacyStartupShortcutPath))) {
            if (Test-Path -LiteralPath $startupLink) {
                Remove-Item -LiteralPath $startupLink -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch {}
}

function Register-FridaTaskCom {
    param(
        [string]$LauncherPath,
        [string]$WorkingDirectory
    )
    # TASK_LOGON_INTERACTIVE_TOKEN = 3: no password, runs as logged-on user.
    # Works better than Register-ScheduledTask when the installer is elevated.
    $service = New-Object -ComObject Schedule.Service
    $service.Connect()
    $folder = $service.GetFolder("\")
    $task = $service.NewTask(0)
    $task.RegistrationInfo.Description = "Claude Desktop Frida Chinese resident watcher"
    $task.Settings.Enabled = $true
    $task.Settings.AllowDemandStart = $true
    $task.Settings.StartWhenAvailable = $true
    $task.Settings.DisallowStartIfOnBatteries = $false
    $task.Settings.StopIfGoingOnBatteries = $false
    $task.Settings.MultipleInstances = 0  # IgnoreNew
    $task.Settings.ExecutionTimeLimit = "PT0S"
    $task.Principal.RunLevel = 0  # Limited
    $task.Principal.LogonType = 3  # InteractiveToken

    $trigger = $task.Triggers.Create(9)  # TASK_TRIGGER_LOGON
    $trigger.Enabled = $true

    $action = $task.Actions.Create(0)  # TASK_ACTION_EXEC
    $action.Path = Join-Path $env:WINDIR "System32\wscript.exe"
    $action.Arguments = "`"$LauncherPath`""
    $action.WorkingDirectory = $WorkingDirectory

    # TASK_CREATE_OR_UPDATE = 6
    $null = $folder.RegisterTaskDefinition(
        $TaskName,
        $task,
        6,
        $null,
        $null,
        3,   # TASK_LOGON_INTERACTIVE_TOKEN
        $null
    )
}

function Install-FridaTask {
    param(
        [string]$Root,
        [string]$Py,
        [string]$Lang,
        [int]$TaskPort
    )

    $ctl = Join-Path $Root "scripts\experimental\frida-zh-resident-ctl.ps1"
    if (-not (Test-Path -LiteralPath $ctl)) {
        throw "常驻控制脚本不存在: $ctl"
    }
    if (-not (Test-Path -LiteralPath $Py)) {
        throw "Python 不存在: $Py"
    }

    $logDir = Join-Path (Get-ClaudeZhRoot) "logs"
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null

    Unregister-FridaTask
    Stop-FridaRelated
    Clear-UserAutostart

    $wrapper = Write-WatchLauncher -Root $Root -Py $Py -Lang $Lang -TaskPort $TaskPort
    $watchCommand = Get-WatchPowerShellCommand -Root $Root -Py $Py -Lang $Lang -TaskPort $TaskPort
    $hiddenLauncher = Write-HiddenLauncher -CommandLine $watchCommand
    try {
        [void](Write-RunKeyLauncher -CommandLine $watchCommand)
        Write-Info "已注册用户登录自启（隐藏后台 watcher）。"
    }
    catch {
        $lastError = $_.Exception.Message
        Write-Warn "HKCU Run 注册失败: $lastError"
    }
    $userForTask = Get-TaskUserName

    $registered = $false
    $lastError = $null
    $method = $null

    # 1) COM Schedule.Service + InteractiveToken (best under UAC elevation)
    try {
        Register-FridaTaskCom -LauncherPath $hiddenLauncher -WorkingDirectory (Get-ClaudeZhRoot)
        $registered = $true
        $method = "COM InteractiveToken"
        Write-Info "已注册计划任务 ($method): $TaskName"
    }
    catch {
        $lastError = $_.Exception.Message
        Write-Warn "COM 注册失败: $lastError"
    }

    # 2) Register-ScheduledTask cmdlets
    if (-not $registered) {
        try {
            $action = New-ScheduledTaskAction -Execute (Join-Path $env:WINDIR "System32\wscript.exe") -Argument "`"$hiddenLauncher`"" -WorkingDirectory (Get-ClaudeZhRoot)
            $trigger = New-ScheduledTaskTrigger -AtLogOn
            $settings = New-ScheduledTaskSettingsSet `
                -AllowStartIfOnBatteries `
                -DontStopIfGoingOnBatteries `
                -StartWhenAvailable `
                -ExecutionTimeLimit ([TimeSpan]::Zero) `
                -MultipleInstances IgnoreNew
            try {
                $principal = New-ScheduledTaskPrincipal -UserId $userForTask -LogonType Interactive -RunLevel Limited
                Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
            }
            catch {
                Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
            }
            $registered = $true
            $method = "Register-ScheduledTask"
            Write-Info "已注册计划任务 ($method): $TaskName"
        }
        catch {
            $lastError = $_.Exception.Message
            Write-Warn "Register-ScheduledTask 失败: $lastError"
        }
    }

    # 3) schtasks with SHORT /TR (wscript + hidden launcher only - under 261 chars)
    if (-not $registered) {
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $trCmd = "`"$(Join-Path $env:WINDIR "System32\wscript.exe")`" `"$hiddenLauncher`""
            $schOut = & schtasks.exe /Create /TN $TaskName /TR $trCmd /SC ONLOGON /RL LIMITED /F /IT 2>&1
            if ($LASTEXITCODE -eq 0) {
                $registered = $true
                $method = "schtasks"
                Write-Info "已注册计划任务 ($method): $TaskName"
            }
            else {
                $lastError = ($schOut | Out-String).Trim()
                Write-Warn "schtasks /Create 失败 (exit=$LASTEXITCODE): $lastError"
                $schOut2 = & schtasks.exe /Create /TN $TaskName /TR $trCmd /SC ONLOGON /RL LIMITED /F /IT /RU $userForTask 2>&1
                if ($LASTEXITCODE -eq 0) {
                    $registered = $true
                    $method = "schtasks /RU"
                    Write-Info "已注册计划任务 ($method): $TaskName"
                }
                else {
                    $lastError = ($schOut2 | Out-String).Trim()
                }
            }
        }
        finally {
            $ErrorActionPreference = $prevEap
        }
    }

    if (-not $registered) {
        # 4) HKCU Run fallback (no Scheduled Task permission needed).
        try {
            $registered = $true
            $method = "HKCU Run"
            Write-Info "计划任务权限不足，已使用用户登录自启: HKCU Run -> $hiddenLauncher"
            Write-Info "  （效果：用户登录后隐藏启动并自动监视；卸载常驻会删除该注册项）"
        }
        catch {
            $lastError = $_.Exception.Message
            Write-Warn "HKCU Run 回退失败: $lastError"
        }
    }

    if (-not $registered) {
        # 5) Startup-folder fallback (no Scheduled Task permission needed).
        # This survives logon via the user Startup folder and is easy to remove.
        try {
            $linkPath = Write-StartupLauncher -CommandLine $watchCommand
            $registered = $true
            $method = "Startup folder"
            Write-Info "计划任务权限不足，已改用开机启动项: $linkPath"
            Write-Info "  （效果：用户登录后隐藏启动并自动监视；卸载常驻会删除该启动项）"
        }
        catch {
            $lastError = $_.Exception.Message
            Write-Warn "Startup 回退失败: $lastError"
        }
    }

    if (-not $registered) {
        throw (
            "无法注册常驻（计划任务被拒绝，且 Startup 回退失败）: $lastError`n" +
            "  可改选「直接回车」做本次前台 Frida 启动，无需常驻。`n" +
            "  或在「非管理员」PowerShell 中执行:`n" +
            "  powershell -NoProfile -ExecutionPolicy Bypass -File `"$ctl`" -Action install -PythonExe `"$Py`" -Language $Lang -Port $TaskPort -RepoRoot `"$Root`""
        )
    }

    Write-Info "  Root:    $Root"
    Write-Info "  Wrapper: $wrapper"
    Write-Info "  Python:  $Py"
    Write-Info "  Lang:    $Lang"
    Write-Info "  Port:    $TaskPort"
    Write-Info "  User:    $userForTask"
    Write-Info "  Method:  $method"
    Write-Info "  Logs:    $logDir"

    # Persist resident meta for status/uninstall
    try {
        $meta = @{
            taskName = $TaskName
            method = $method
            wrapper = $wrapper
            pythonExe = $Py
            language = $Lang
            port = $TaskPort
            root = $Root
            installedAt = (Get-Date).ToString("o")
        }
        $metaPath = Join-Path (Get-ClaudeZhRoot) "resident-meta.json"
        $meta | ConvertTo-Json | Set-Content -LiteralPath $metaPath -Encoding UTF8
    }
    catch {}

    # Start scheduled-task registrations immediately (best-effort).
    $isScheduledTaskMethod = @("COM InteractiveToken", "Register-ScheduledTask", "schtasks", "schtasks /RU") -contains $method
    if ($isScheduledTaskMethod) {
        try {
            Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
            Write-Info "已启动常驻任务。"
            return
        }
        catch {}

        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $null = & schtasks.exe /Run /TN $TaskName 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Info "已启动常驻任务 (schtasks /Run)。"
                return
            }
        }
        finally {
            $ErrorActionPreference = $prevEap
        }
    }

    # Always try direct background start so user gets watcher without re-login
    try {
        Start-Process -FilePath (Join-Path $env:WINDIR "System32\wscript.exe") -ArgumentList "`"$hiddenLauncher`"" -WorkingDirectory (Get-ClaudeZhRoot) -WindowStyle Hidden | Out-Null
        Write-Info "已隐藏后台启动 watcher（当前会话立即生效）。"
    }
    catch {
        Write-Warn "常驻已注册，但立即启动失败。可注销重新登录，或手动运行: $wrapper"
    }
}

function Copy-FileBestEffort {
    param(
        [string]$Source,
        [string]$DestinationDir
    )
    if (-not (Test-Path -LiteralPath $Source)) {
        return $false
    }
    New-Item -ItemType Directory -Path $DestinationDir -Force | Out-Null
    $dest = Join-Path $DestinationDir (Split-Path -Leaf $Source)
    try {
        Copy-Item -LiteralPath $Source -Destination $dest -Force -ErrorAction Stop
        return $true
    }
    catch {
        # Same-path or locked file: ignore if destination already exists
        if ((Test-Path -LiteralPath $dest)) {
            Write-Warn "跳过复制（目标已存在或被占用）: $(Split-Path -Leaf $Source)"
            return $true
        }
        throw
    }
}

function Deploy-ToClaudeZh {
    param([string]$SourceRoot)

    $dest = Get-ClaudeZhRoot
    $SourceRoot = [System.IO.Path]::GetFullPath($SourceRoot)
    $destFull = [System.IO.Path]::GetFullPath($dest)

    Write-Info "部署运行文件到 $dest ..."
    $dirs = @(
        (Join-Path $dest "scripts\experimental"),
        (Join-Path $dest "resources"),
        (Join-Path $dest "scripts")
    )
    foreach ($d in $dirs) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }

    # If already deploying from the destination tree, skip copy.
    if ($SourceRoot.TrimEnd('\') -ieq $destFull.TrimEnd('\')) {
        Write-Info "源目录即部署目录，跳过复制。"
        return ,$dest
    }

    [void](Copy-FileBestEffort -Source (Join-Path $SourceRoot "scripts\patch_claude_zh_cn.py") -DestinationDir (Join-Path $dest "scripts"))
    $exp = Join-Path $SourceRoot "scripts\experimental"
    foreach ($name in @(
        "frida_launch_zh_win.py",
        "frida_cdp_gate_win.js",
        "cdp_launch_zh.py",
        "bootstrap_frida_runtime_win.ps1",
        "run_frida_zh_win.ps1",
        "frida-zh-resident-ctl.ps1",
        "requirements-frida.txt",
        "typing_shim_sitecustomize.py"
    )) {
        $src = Join-Path $exp $name
        [void](Copy-FileBestEffort -Source $src -DestinationDir (Join-Path $dest "scripts\experimental"))
    }
    try {
        Copy-Item -Path (Join-Path $SourceRoot "resources\*") -Destination (Join-Path $dest "resources\") -Force -Recurse -ErrorAction SilentlyContinue
    }
    catch {}
    Write-Info "部署完成: $dest"
    # Unary comma prevents PowerShell from unrolling / mixing prior pipeline noise.
    return ,$dest
}

function Get-StartupShortcutPath {
    $startup = [Environment]::GetFolderPath("Startup")
    if (-not $startup) {
        $startup = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup"
    }
    return (Join-Path $startup "ClaudeDesktopZhCn-FridaZh.vbs")
}

function Get-LegacyStartupShortcutPath {
    $startup = [Environment]::GetFolderPath("Startup")
    if (-not $startup) {
        $startup = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup"
    }
    return (Join-Path $startup "ClaudeDesktopZhCn-FridaZh.cmd")
}

function Do-Uninstall {
    Write-Info "卸载常驻: $TaskName"
    Unregister-FridaTask
    Stop-FridaRelated

    # Remove Startup-folder fallback if present
    try {
        Clear-UserAutostart
    }
    catch {}

    try {
        $wrapper = Join-Path (Get-ClaudeZhRoot) "watch.cmd"
        if (Test-Path -LiteralPath $wrapper) {
            Remove-Item -LiteralPath $wrapper -Force -ErrorAction SilentlyContinue
        }
        $meta = Join-Path (Get-ClaudeZhRoot) "resident-meta.json"
        if (Test-Path -LiteralPath $meta) {
            Remove-Item -LiteralPath $meta -Force -ErrorAction SilentlyContinue
        }
    }
    catch {}

    Write-Info "计划任务 / 启动项与相关进程已清理。"

    if ($RemoveRuntime) {
        $rt = Get-RuntimeRoot
        $root = Get-ClaudeZhRoot
        if (Test-Path -LiteralPath $rt) {
            Write-Info "删除便携运行时: $rt"
            Remove-Item -LiteralPath $rt -Recurse -Force -ErrorAction SilentlyContinue
        }
        # Remove deployed scripts but keep logs unless runtime root wipe
        if (Test-Path -LiteralPath $root) {
            Write-Info "删除部署目录: $root"
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    else {
        Write-Info "已保留便携运行时（如需删除请加 -RemoveRuntime 或卸载时选 y）。"
    }
}

function Do-Status {
    Write-Host "Task:   $TaskName"
    $taskState = "not registered"
    try {
        $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        $taskState = [string]$t.State
        Write-Host "State:  $taskState"
        $info = Get-ScheduledTaskInfo -TaskName $TaskName
        Write-Host "Last:   $($info.LastRunTime) result=$($info.LastTaskResult)"
    }
    catch {
        Write-Host "State:  not registered"
    }

    $startupLinks = @((Get-StartupShortcutPath), (Get-LegacyStartupShortcutPath)) | Where-Object {
        Test-Path -LiteralPath $_
    }
    $runValue = $null
    try {
        $runValue = (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name $RunValueName -ErrorAction Stop).$RunValueName
    }
    catch {}
    if ($runValue) {
        Write-Host "RunKey: installed ($runValue)"
    }
    else {
        Write-Host "RunKey: not installed"
    }
    if ($startupLinks.Count -gt 0) {
        Write-Host "Startup: installed ($($startupLinks -join ', '))"
    }
    else {
        Write-Host "Startup: not installed"
    }

    $metaPath = Join-Path (Get-ClaudeZhRoot) "resident-meta.json"
    if (Test-Path -LiteralPath $metaPath) {
        try {
            $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
            Write-Host "Method: $($meta.method)"
            Write-Host "Wrapper: $($meta.wrapper)"
        }
        catch {}
    }

    $procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -and $_.CommandLine -like "*frida_launch_zh_win.py*"
    })
    $watchers = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -and $_.CommandLine -like "*frida-zh-resident-ctl.ps1*" -and $_.CommandLine -match '(?i)(-Action\s+watch|/Action\s+watch)'
    })
    if ($watchers.Count -gt 0) {
        Write-Host "Watcher: running"
        $watchers | ForEach-Object { Write-Host "  PID $($_.ProcessId)" }
    }
    else {
        Write-Host "Watcher: not running"
    }
    if ($procs.Count -gt 0) {
        Write-Host "Process: frida_launch_zh_win.py running"
        $procs | ForEach-Object { Write-Host "  PID $($_.ProcessId)" }
    }
    else {
        Write-Host "Process: frida_launch_zh_win.py not running"
    }
    $rt = Get-RuntimeRoot
    Write-Host "Runtime: $rt  exists=$(Test-Path -LiteralPath $rt)"
}

function Do-Watch {
    if (-not $PythonExe) { throw "watch 需要 -PythonExe" }
    if (-not $RepoRoot) { $RepoRoot = Get-ClaudeZhRoot }
    $launcher = Join-Path $RepoRoot "scripts\experimental\frida_launch_zh_win.py"
    if (-not (Test-Path -LiteralPath $launcher)) {
        throw "缺少启动器: $launcher"
    }
    $logDir = Join-Path (Get-ClaudeZhRoot) "logs"
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $logFile = Join-Path $logDir ("watch-" + (Get-Date -Format "yyyyMMdd") + ".log")
    $launcherOutFile = Join-Path $logDir ("frida-launch-out-" + (Get-Date -Format "yyyyMMdd") + ".log")
    $launcherErrFile = Join-Path $logDir ("frida-launch-err-" + (Get-Date -Format "yyyyMMdd") + ".log")

    function Write-Log([string]$Message) {
        $line = "[{0}] {1}" -f (Get-Date -Format "o"), $Message
        Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
        Write-Host $line
    }

    $mutex = New-Object System.Threading.Mutex($false, "Local\ClaudeDesktopZhCnFridaZhWatch")
    if (-not $mutex.WaitOne(0, $false)) {
        Write-Log "watch already running; exit duplicate"
        return
    }

    Write-Log "watch start py=$PythonExe lang=$Language port=$Port root=$RepoRoot"

    # Simple resident: if Claude is running without our CDP port, replace via launcher.
    # For reliability we loop: ensure one frida_launch_zh_win foreground child when user wants Claude.
    # Strategy aligned with mac relaunch: when Claude.exe starts without our port, kill and respawn under Frida.
    $exeName = "Claude.exe"
    while ($true) {
        try {
            $claudeProcs = @(Get-Process -Name "Claude", "claude" -ErrorAction SilentlyContinue)
            $fridaLaunchers = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
                $_.CommandLine -and $_.CommandLine -like "*frida_launch_zh_win.py*"
            })

            $cdpUp = $false
            try {
                $req = [System.Net.WebRequest]::Create("http://127.0.0.1:$Port/json/version")
                $req.Timeout = 400
                $resp = $req.GetResponse()
                $resp.Close()
                $cdpUp = $true
            }
            catch { $cdpUp = $false }

            if ($fridaLaunchers.Count -gt 0) {
                Start-Sleep -Seconds 3
                continue
            }

            if ($claudeProcs.Count -gt 0 -and -not $cdpUp) {
                Write-Log "Detected official Claude without CDP; relaunch under Frida"
                foreach ($p in $claudeProcs) {
                    try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
                }
                Start-Sleep -Milliseconds 800
                $args = @(
                    $launcher,
                    "--lang", $Language,
                    "--port", "$Port",
                    "--mode", "both"
                )
                Write-Log "Starting $PythonExe $($args -join ' ')"
                Add-Content -LiteralPath $launcherOutFile -Encoding UTF8 -Value ("`n[{0}] launcher start" -f (Get-Date -Format "o"))
                $proc = Start-Process -FilePath $PythonExe `
                    -ArgumentList $args `
                    -WorkingDirectory $RepoRoot `
                    -PassThru `
                    -WindowStyle Hidden `
                    -RedirectStandardOutput $launcherOutFile `
                    -RedirectStandardError $launcherErrFile
                Write-Log "frida launcher pid=$($proc.Id)"
                # Wait until that launcher exits, then loop again
                Wait-Process -Id $proc.Id -ErrorAction SilentlyContinue
                Write-Log "frida launcher exited code=$($proc.ExitCode)"
            }
            else {
                Start-Sleep -Seconds 2
            }
        }
        catch {
            Write-Log "watch error: $($_.Exception.Message)"
            Start-Sleep -Seconds 5
        }
    }
}

switch ($Action) {
    "install" {
        if (-not $RepoRoot) {
            # Prefer caller-provided; else assume script lives in deployed or repo tree
            $here = $PSScriptRoot
            $RepoRoot = Split-Path -Parent (Split-Path -Parent $here)
        }
        if (-not $PythonExe) { throw "install 需要 -PythonExe" }
        if (-not $Language) { $Language = "zh-CN" }
        $deployed = Deploy-ToClaudeZh -SourceRoot $RepoRoot
        # Deploy may return Object[] if any nested command leaked to output; coerce path.
        if ($deployed -is [System.Array]) {
            $deployed = [string]($deployed | Select-Object -Last 1)
        }
        else {
            $deployed = [string]$deployed
        }
        if (-not $deployed -or -not (Test-Path -LiteralPath $deployed)) {
            $deployed = Get-ClaudeZhRoot
        }
        Install-FridaTask -Root $deployed -Py $PythonExe -Lang $Language -TaskPort $Port
    }
    "uninstall" { Do-Uninstall }
    "status" { Do-Status }
    "watch" { Do-Watch }
}
