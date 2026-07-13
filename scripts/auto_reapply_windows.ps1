$script:AutoReapplyTaskName = "ClaudeDesktopZhCn-AutoReapply"

function Get-AutoReapplyRoot {
    $programData = [Environment]::GetFolderPath("CommonApplicationData")
    if (-not $programData) {
        throw "无法定位 ProgramData，不能配置更新后自动汉化。"
    }
    return Join-Path $programData "ClaudeDesktopZhCn"
}

function Remove-TreeWithoutFollowingLinks {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        if ($item.PSIsContainer) {
            [System.IO.Directory]::Delete($Path, $false)
        }
        else {
            [System.IO.File]::Delete($Path)
        }
        return
    }
    if ($item.PSIsContainer) {
        foreach ($child in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
            Remove-TreeWithoutFollowingLinks $child.FullName
        }
    }
    Remove-Item -LiteralPath $Path -Force
}

function Remove-AutoReapplyRoot {
    Remove-TreeWithoutFollowingLinks (Get-AutoReapplyRoot)
}

function Initialize-AutoReapplyRoot {
    Remove-AutoReapplyRoot
    $root = Get-AutoReapplyRoot
    New-Item -ItemType Directory -Path $root -Force | Out-Null

    $acl = [System.Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $inheritance = [System.Security.AccessControl.InheritanceFlags]"ContainerInherit, ObjectInherit"
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    foreach ($sid in @("S-1-5-18", "S-1-5-32-544")) {
        $identity = [System.Security.Principal.SecurityIdentifier]::new($sid)
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $identity,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            $propagation,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        [void]$acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $root -AclObject $acl
    return $root
}

function Get-ClaudeInstallIdentity {
    param([string]$ClaudePath)

    $fullPath = [System.IO.Path]::GetFullPath($ClaudePath).TrimEnd('\', '/').ToLowerInvariant()
    $version = ""
    $exe = Get-ClaudeExePath $ClaudePath
    if ($exe) {
        try {
            $version = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($exe).ProductVersion
        }
        catch {
            $version = ""
        }
    }
    return "$fullPath|$version"
}

function Reset-AutoReapplyBackups {
    $paths = Get-ClaudeResourcesPath
    $resourcesPath = [string]$paths["Resources"]
    $backupRoot = Get-BackupRoot $resourcesPath
    if (Test-Path -LiteralPath $backupRoot) {
        Write-Host "  检测到 Claude 新版本，丢弃旧版本补丁备份并建立新基线。" -ForegroundColor DarkGray
        Remove-Item -LiteralPath $backupRoot -Recurse -Force
    }
    $script:CurrentBackupSetPath = $null
}

function Enable-AutoReapply {
    $sourceRoot = Split-Path -Parent $PSScriptRoot
    $sourceScripts = Join-Path $sourceRoot "scripts"
    $sourceResources = Join-Path $sourceRoot "resources"
    Require-File (Join-Path $sourceScripts "watch_claude_update.ps1")
    Require-File (Join-Path $sourceScripts "install_windows.ps1")
    Require-File (Join-Path $sourceResources "release.json")

    Stop-ScheduledTask -TaskName $script:AutoReapplyTaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $script:AutoReapplyTaskName -Confirm:$false -ErrorAction SilentlyContinue
    $root = Initialize-AutoReapplyRoot
    $payloadRoot = Join-Path $root "payload"
    $payloadScripts = Join-Path $payloadRoot "scripts"
    $statePath = Join-Path $root "state.json"
    New-Item -ItemType Directory -Path $payloadScripts -Force | Out-Null
    foreach ($scriptName in @("install_windows.ps1", "auto_reapply_windows.ps1", "watch_claude_update.ps1")) {
        Copy-Item -LiteralPath (Join-Path $sourceScripts $scriptName) -Destination $payloadScripts -Force
    }
    Copy-Item -LiteralPath $sourceResources -Destination $payloadRoot -Recurse -Force

    $paths = Get-ClaudeResourcesPath
    $identity = Get-ClaudeInstallIdentity ([string]$paths["App"])
    $sid = [string]$env:CLAUDE_ZH_ORIGINAL_USER_SID
    if (-not $sid) {
        try { $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { $sid = "" }
    }
    $originalUserProfile = [string]$env:CLAUDE_ZH_ORIGINAL_USER_PROFILE
    if (-not $originalUserProfile) { $originalUserProfile = [Environment]::GetFolderPath("UserProfile") }
    $originalAppData = [string]$env:CLAUDE_ZH_ORIGINAL_APPDATA
    if (-not $originalAppData) { $originalAppData = [string]$env:APPDATA }
    $originalLocalAppData = [string]$env:CLAUDE_ZH_ORIGINAL_LOCALAPPDATA
    if (-not $originalLocalAppData) { $originalLocalAppData = [Environment]::GetFolderPath("LocalApplicationData") }
    $state = [pscustomobject]@{
        schemaVersion = 1
        language = $LanguageCode
        patchMode = $PatchMode
        lastPatchedIdentity = $identity
        pendingIdentity = ""
        failedIdentity = ""
        originalUserSid = $sid
        originalUserProfile = $originalUserProfile
        originalAppData = $originalAppData
        originalLocalAppData = $originalLocalAppData
        configuredAt = (Get-Date).ToUniversalTime().ToString("o")
    }
    Save-JsonNoBom $statePath $state

    $watcherPath = Join-Path $payloadRoot "scripts\watch_claude_update.ps1"
    $taskArgument = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$watcherPath`" -StatePath `"$statePath`""
    $taskAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $taskArgument
    $taskTrigger = New-ScheduledTaskTrigger `
        -Once `
        -At (Get-Date).AddMinutes(1) `
        -RepetitionInterval (New-TimeSpan -Minutes 15) `
        -RepetitionDuration (New-TimeSpan -Days 3650)
    $taskTrigger.Repetition.StopAtDurationEnd = $false
    $taskSettings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 20)
    $taskPrincipal = New-ScheduledTaskPrincipal `
        -UserId "SYSTEM" `
        -LogonType ServiceAccount `
        -RunLevel Highest

    Register-ScheduledTask `
        -TaskName $script:AutoReapplyTaskName `
        -Action $taskAction `
        -Trigger $taskTrigger `
        -Settings $taskSettings `
        -Principal $taskPrincipal `
        -Description "Claude Desktop 更新后自动重新应用中文补丁" `
        -Force | Out-Null

    Write-Host "  已启用更新后自动汉化（每 15 分钟检查一次，Claude 运行时自动延后）。" -ForegroundColor Green
    Write-Host "  持久化文件: $root" -ForegroundColor DarkGray
}

function Disable-AutoReapply {
    Stop-ScheduledTask -TaskName $script:AutoReapplyTaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $script:AutoReapplyTaskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-AutoReapplyRoot
    Write-Host "  已关闭更新后自动汉化。当前已安装的中文补丁保持不变。" -ForegroundColor Green
}
