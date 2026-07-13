param(
    [Parameter(Mandatory = $true)]
    [string]$StatePath
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Write-WatcherLog {
    param([string]$Message)

    try {
        $root = Split-Path -Parent $StatePath
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $logPath = Join-Path $root "update-watcher.log"
        if ((Test-Path -LiteralPath $logPath) -and (Get-Item -LiteralPath $logPath).Length -gt 1MB) {
            $tail = @(Get-Content -LiteralPath $logPath -Tail 200 -ErrorAction SilentlyContinue)
            [System.IO.File]::WriteAllLines($logPath, $tail, $Utf8NoBom)
        }
        $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
        [System.IO.File]::AppendAllText($logPath, "$line`r`n", $Utf8NoBom)
    }
    catch {
    }
}

function Save-State {
    param([pscustomobject]$State)

    $json = $State | ConvertTo-Json -Depth 10
    $tempPath = "$StatePath.tmp"
    [System.IO.File]::WriteAllText($tempPath, $json, $Utf8NoBom)
    Move-Item -LiteralPath $tempPath -Destination $StatePath -Force
}

function Set-StateProperty {
    param(
        [pscustomobject]$State,
        [string]$Name,
        [object]$Value
    )
    $State | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Get-ClaudeExePath {
    param([string]$ClaudePath)

    foreach ($candidate in @(
        (Join-Path $ClaudePath "Claude.exe"),
        (Join-Path $ClaudePath "claude.exe"),
        (Join-Path $ClaudePath "app\Claude.exe"),
        (Join-Path $ClaudePath "app\claude.exe")
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    return $null
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

function Get-ClaudeInstallInfo {
    param([pscustomobject]$State)

    $localAppData = [string]$State.originalLocalAppData
    if ($localAppData) {
        $unpackagedBase = Join-Path $localAppData "AnthropicClaude"
        $latest = Get-ChildItem -LiteralPath $unpackagedBase -Directory -Filter "app-*" -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "resources") -PathType Container } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($latest) {
            return [pscustomobject]@{
                appPath = $latest.FullName
                identity = Get-ClaudeInstallIdentity $latest.FullName
            }
        }
    }

    $package = Get-AppxPackage -AllUsers -Name "Claude" -ErrorAction SilentlyContinue |
        Where-Object { $_.InstallLocation -and (Test-Path -LiteralPath $_.InstallLocation) } |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if ($package) {
        $resourcesPath = Join-Path $package.InstallLocation "app\resources"
        if (Test-Path -LiteralPath $resourcesPath -PathType Container) {
            return [pscustomobject]@{
                appPath = $package.InstallLocation
                identity = Get-ClaudeInstallIdentity $package.InstallLocation
            }
        }
    }

    $fallback = Get-ChildItem "C:\Program Files\WindowsApps\Claude_*" -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "app\resources") -PathType Container } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($fallback) {
        return [pscustomobject]@{
            appPath = $fallback.FullName
            identity = Get-ClaudeInstallIdentity $fallback.FullName
        }
    }
    return $null
}

function Test-ClaudeIsRunning {
    param([string]$ClaudePath)

    $appRoot = [System.IO.Path]::GetFullPath($ClaudePath).TrimEnd('\', '/')
    foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
        if ($process.Name -notin @("claude.exe", "cowork-svc.exe")) {
            continue
        }
        $executablePath = [string]$process.ExecutablePath
        if (-not $executablePath) {
            continue
        }
        try {
            $fullPath = [System.IO.Path]::GetFullPath($executablePath)
            if ($fullPath.StartsWith($appRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
        catch {
        }
    }
    return $false
}

try {
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        exit 0
    }
    $state = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($state.schemaVersion -ne 1 -or $state.language -notin @("zh-CN", "zh-TW", "zh-HK") -or $state.patchMode -notin @("safe", "official")) {
        Write-WatcherLog "状态文件无效，停止检查。"
        exit 1
    }

    $install = Get-ClaudeInstallInfo $state
    if (-not $install) {
        Write-WatcherLog "未找到完整的 Claude Desktop 安装，等待下次检查。"
        exit 0
    }
    if ($install.identity -eq [string]$state.lastPatchedIdentity) {
        exit 0
    }
    if ($install.identity -eq [string]$state.failedIdentity) {
        exit 0
    }

    if ($install.identity -ne [string]$state.pendingIdentity) {
        Set-StateProperty $state "pendingIdentity" $install.identity
        Set-StateProperty $state "pendingSince" (Get-Date).ToUniversalTime().ToString("o")
        Set-StateProperty $state "failedIdentity" ""
        Save-State $state
        Write-WatcherLog "检测到 Claude Desktop 新版本，等待下一轮确认更新已稳定: $($install.identity)"
        exit 0
    }

    if (Test-ClaudeIsRunning $install.appPath) {
        Write-WatcherLog "Claude Desktop/Cowork 正在运行，本轮延后自动汉化。"
        exit 0
    }

    $payloadRoot = Join-Path (Split-Path -Parent $StatePath) "payload"
    $installer = Join-Path $payloadRoot "scripts\install_windows.ps1"
    if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
        throw "持久化安装脚本不存在: $installer"
    }

    $arguments = @(
        "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
        "-File", $installer,
        "-Action", "install",
        "-Language", [string]$state.language,
        "-PatchMode", [string]$state.patchMode,
        "-AutoReapply"
    )
    foreach ($item in @(
        @("-OriginalUserSid", [string]$state.originalUserSid),
        @("-OriginalUserProfile", [string]$state.originalUserProfile),
        @("-OriginalAppData", [string]$state.originalAppData),
        @("-OriginalLocalAppData", [string]$state.originalLocalAppData)
    )) {
        if ($item[1]) {
            $arguments += $item
        }
    }
    & powershell.exe @arguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        Set-StateProperty $state "failedIdentity" $install.identity
        Set-StateProperty $state "pendingIdentity" ""
        Save-State $state
        Write-WatcherLog "自动汉化失败（退出码 $exitCode）。为保护当前版本，本版本不再自动重试；请查看 payload\install-windows.log。"
        exit $exitCode
    }

    Set-StateProperty $state "lastPatchedIdentity" $install.identity
    Set-StateProperty $state "pendingIdentity" ""
    Set-StateProperty $state "pendingSince" ""
    Set-StateProperty $state "failedIdentity" ""
    Set-StateProperty $state "lastPatchedAt" (Get-Date).ToUniversalTime().ToString("o")
    Save-State $state
    Write-WatcherLog "Claude Desktop 新版本已自动汉化: $($install.identity)"
    exit 0
}
catch {
    Write-WatcherLog "自动检查失败: $($_.Exception.Message)"
    exit 1
}
