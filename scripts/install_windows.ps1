param(
    [switch]$Interactive,
    [switch]$SkipAsarPatch,
    [ValidateSet("safe", "official")]
    [string]$PatchMode = "safe",

    [Parameter(Position = 0)]
    [ValidateSet("install", "uninstall", "disable-updates", "enable-updates", "sync-skills", "unsync-skills", "frida-launch")]
    [string]$Action = "install",

    [Parameter(Position = 1)]
    [ValidateSet("zh-CN", "zh-TW", "zh-HK")]
    [string]$Language = "zh-CN",

    [string]$OriginalUserSid = "",
    [string]$OriginalUserProfile = "",
    [string]$OriginalAppData = "",
    [string]$OriginalLocalAppData = ""
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$BaseLanguageList = '["en-US","de-DE","fr-FR","ko-KR","ja-JP","es-419","es-ES","it-IT","hi-IN","pt-BR","id-ID"'
$LanguageListPattern = [System.Text.RegularExpressions.Regex]::Escape($BaseLanguageList) + '(?:(?:,"zh-CN")|(?:,"zh-TW")|(?:,"zh-HK"))*\]'
$AsarPatchTargetFallback = ".vite/build/index.js"
$AsarIntegrityBlockSize = 4 * 1024 * 1024
$OnlineLocaleMainMarker = "__claudeZhOnlineLocaleMain"
$OnlineLocaleLockMarker = "__claudeZhLocaleLock"
$MenuRuntimeMarker = "__claudeZhMenuRuntimePatch"
$OnlineTranslationMaxSourceLength = 1000
$script:CurrentBackupSetPath = $null
$script:DetectedUnpackagedClaudePaths = @()
$script:DetectedMultipleClaudeInstalls = $false
$script:InstallLogPath = $null
$script:InstallTranscriptStarted = $false
$script:PreInstallCleanupDone = $false

if ($OriginalUserSid) { $env:CLAUDE_ZH_ORIGINAL_USER_SID = $OriginalUserSid }
if ($OriginalUserProfile) { $env:CLAUDE_ZH_ORIGINAL_USER_PROFILE = $OriginalUserProfile }
if ($OriginalAppData) { $env:CLAUDE_ZH_ORIGINAL_APPDATA = $OriginalAppData }
if ($OriginalLocalAppData) { $env:CLAUDE_ZH_ORIGINAL_LOCALAPPDATA = $OriginalLocalAppData }

function Start-InstallLog {
    try {
        $root = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }
        $script:InstallLogPath = Join-Path $root "install-windows.log"
        Start-Transcript -Path $script:InstallLogPath -Force | Out-Null
        $script:InstallTranscriptStarted = $true
    }
    catch {
        $script:InstallTranscriptStarted = $false
    }
}

function Stop-InstallLog {
    if (-not $script:InstallTranscriptStarted) {
        return
    }
    try {
        Stop-Transcript | Out-Null
    }
    catch {
    }
    $script:InstallTranscriptStarted = $false
}

Start-InstallLog

function Compare-ReleaseVersion {
    param(
        [string]$Left,
        [string]$Right
    )

    $leftParts = @([regex]::Matches($Left, '\d+') | ForEach-Object { [int]$_.Value })
    $rightParts = @([regex]::Matches($Right, '\d+') | ForEach-Object { [int]$_.Value })
    $count = [Math]::Max($leftParts.Count, $rightParts.Count)
    for ($i = 0; $i -lt $count; $i++) {
        $leftPart = if ($i -lt $leftParts.Count) { $leftParts[$i] } else { 0 }
        $rightPart = if ($i -lt $rightParts.Count) { $rightParts[$i] } else { 0 }
        if ($leftPart -gt $rightPart) { return 1 }
        if ($leftPart -lt $rightPart) { return -1 }
    }
    return 0
}

function Test-SkipReleaseUpdateCheck {
    $value = $env:CLAUDE_ZH_SKIP_UPDATE_CHECK
    return $value -match '^(1|true|TRUE|yes|YES|y|Y)$'
}

function Test-GitHubReleaseUpdate {
    if (Test-SkipReleaseUpdateCheck) {
        return
    }

    try {
        $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
        $projectDir = Split-Path -Parent $scriptDir
        $metadataPath = Join-Path $projectDir "resources\release.json"
        $metadata = Get-Content $metadataPath -Raw -ErrorAction Stop | ConvertFrom-Json
        $repo = [string]$metadata.repo
        $current = [string]$metadata.release
        if (-not $repo -or -not $current) {
            return
        }

        $latestRelease = Invoke-RestMethod `
            -Uri "https://api.github.com/repos/$repo/releases/latest" `
            -Headers @{ Accept = "application/vnd.github+json"; "User-Agent" = "claude-desktop-zh-cn-update-check" } `
            -TimeoutSec 3 `
            -ErrorAction Stop
        $latest = [string]$latestRelease.tag_name
        if ($latest -and ((Compare-ReleaseVersion $latest $current) -gt 0)) {
            Write-Host "检测到 GitHub Releases 已发布新版 $latest，当前脚本包为 $current。建议及时更新。本次操作会继续执行。" -ForegroundColor Yellow
            Write-Host ""
        }
    }
    catch {
        return
    }
}

Test-GitHubReleaseUpdate

function Read-InteractiveSelection {
    Write-Host "=== Claude Desktop Windows 中文补丁 ==="
    Write-Host ""
    Write-Host "[1] 安装中文补丁(第三方API登陆模式(例DeepSeek)：（Cowork 沙箱/工作区不可用(看群公告))"
    Write-Host "[2] 安装中文补丁(官方账号登录模式：Cowork 沙箱/工作区不可用(看群公告))"
    Write-Host "[3] Frida 运行时汉化（实验中，有问题请反馈，不保证成功）"
    Write-Host "[4] 恢复原样 / 卸载补丁"
    Write-Host "[5] 自动更新设置（y=禁止自动更新，n=允许自动更新）"
    Write-Host "[6] 同步 CC Switch skills（y=开启同步，n=删除同步）"
    Write-Host "[Q] 退出"
    Write-Host ""

    $patchModeForInstall = "safe"
    $actionSelected = $false
    $selectedAction = "install"
    while (-not $actionSelected) {
        $actionSelection = (Read-Host "请选择操作 [1/2/3/4/5/6/Q]").Trim()
        switch -Regex ($actionSelection) {
            '^[1]$' { $patchModeForInstall = "safe"; $selectedAction = "install"; $actionSelected = $true }
            '^[2]$' { $patchModeForInstall = "official"; $selectedAction = "install"; $actionSelected = $true }
            '^[3]$' { $selectedAction = "frida-launch"; $actionSelected = $true }
            '^[4]$' { return @{ Action = "uninstall"; Language = "zh-CN"; PatchMode = "safe" } }
            '^[5]$' {
                $updateChoice = (Read-Host "是否禁止自动更新？[y=禁止 / n=允许]").Trim()
                switch -Regex ($updateChoice) {
                    '^[Yy]$' { return @{ Action = "disable-updates"; Language = "zh-CN"; PatchMode = "safe" } }
                    '^[Nn]$' { return @{ Action = "enable-updates"; Language = "zh-CN"; PatchMode = "safe" } }
                    default {
                        Write-Host "无效输入，请输入 y 禁止自动更新，或输入 n 允许自动更新。" -ForegroundColor Yellow
                        continue
                    }
                }
            }
            '^[6]$' {
                $skillsChoice = (Read-Host "是否同步 CC Switch skills？[y=开启同步 / n=删除同步]").Trim()
                switch -Regex ($skillsChoice) {
                    '^[Yy]$' { return @{ Action = "sync-skills"; Language = "zh-CN"; PatchMode = "safe" } }
                    '^[Nn]$' { return @{ Action = "unsync-skills"; Language = "zh-CN"; PatchMode = "safe" } }
                    default {
                        Write-Host "无效输入，请输入 y 开启同步，或输入 n 删除同步。" -ForegroundColor Yellow
                        continue
                    }
                }
            }
            '^[Qq]$' { exit 0 }
            default { Write-Host "请输入 1、2、3、4、5、6 或 Q。" -ForegroundColor Yellow }
        }
    }

    Write-Host ""
    if ($selectedAction -eq "install") {
        Invoke-PreInstallCleanup
        Write-Host ""
    }

    if ($selectedAction -eq "frida-launch") {
        Write-Host "请选择要注入的语言："
    }
    else {
        Write-Host "请选择要安装的语言："
    }
    Write-Host "[1] 简体中文"
    Write-Host "[2] 繁体中文（中国台湾）"
    Write-Host "[3] 繁体中文（中国香港）"
    Write-Host "[Q] 退出"
    Write-Host ""

    while ($true) {
        $languageSelection = (Read-Host "请选择语言 [1/2/3/Q]").Trim()
        switch -Regex ($languageSelection) {
            '^[1]$' { return @{ Action = $selectedAction; Language = "zh-CN"; PatchMode = $patchModeForInstall } }
            '^[2]$' { return @{ Action = $selectedAction; Language = "zh-TW"; PatchMode = $patchModeForInstall } }
            '^[3]$' { return @{ Action = $selectedAction; Language = "zh-HK"; PatchMode = $patchModeForInstall } }
            '^[Qq]$' { exit 0 }
            default { Write-Host "请输入 1、2、3 或 Q。" -ForegroundColor Yellow }
        }
    }
}

function Invoke-FridaRuntimeLaunch {
    param([string]$Lang)

    $runner = Join-Path $PSScriptRoot "experimental\run_frida_zh_win.ps1"
    if (-not (Test-Path -LiteralPath $runner)) {
        throw "缺少 Frida 启动入口: $runner"
    }

    Write-Host "=== Frida 运行时汉化（实验，不修改官方磁盘文件）===" -ForegroundColor Cyan
    Write-Host "  将检测 %LOCALAPPDATA%\claude-zh\runtime 或本机 Python+frida。" -ForegroundColor DarkGray
    Write-Host "  若缺失，会提示下载便携 Python（仅本工具使用）。" -ForegroundColor DarkGray
    Write-Host ""

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Language $Lang
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        throw "Frida 运行时汉化退出码: $code"
    }
}

function Disable-FridaResidentForDiskInstall {
    $fridaCtl = Join-Path $PSScriptRoot "experimental\frida-zh-resident-ctl.ps1"
    if (-not (Test-Path -LiteralPath $fridaCtl)) {
        return
    }

    Write-Host "  正在停用 Frida 常驻，避免它接管磁盘补丁启动的 Claude..." -ForegroundColor DarkGray
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fridaCtl -Action uninstall 2>&1 |
        ForEach-Object { Write-Host ("  " + [string]$_) }
    if ($LASTEXITCODE -ne 0) {
        throw "无法停用 Frida 常驻（exit=$LASTEXITCODE）。请先卸载 Frida 常驻后重试。"
    }
    Write-Host "  Frida 常驻已停用；便携运行时已保留。" -ForegroundColor Green
}

function Test-OnlineAccountPatchEnabled {
    return $PatchMode -eq "official"
}

function Test-AsarPatchEnabled {
    return Test-OnlineAccountPatchEnabled
}

function Get-LanguageLabel {
    param([string]$Code)
    switch ($Code) {
        "zh-CN" { return "简体中文" }
        "zh-TW" { return "繁体中文（中国台湾）" }
        "zh-HK" { return "繁体中文（中国香港）" }
        default { return $Code }
    }
}

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host $Message -ForegroundColor Yellow
}

function Format-ByteSize {
    param([int64]$Bytes)

    if ($Bytes -ge 1GB) {
        return "$([Math]::Round($Bytes / 1GB, 2)) GB"
    }
    if ($Bytes -ge 1MB) {
        return "$([Math]::Round($Bytes / 1MB, 1)) MB"
    }
    if ($Bytes -ge 1KB) {
        return "$([Math]::Round($Bytes / 1KB, 1)) KB"
    }
    return "$Bytes bytes"
}

function Get-UnpackagedClaudeVersion {
    param([System.IO.DirectoryInfo]$Directory)

    if ($Directory.Name -notmatch '^app-(\d+(?:\.\d+){1,3})$') {
        return $null
    }

    try {
        return [version]$matches[1]
    }
    catch {
        return $null
    }
}

function Test-UnpackagedClaudeAppDirectory {
    param([System.IO.DirectoryInfo]$Directory)

    $version = Get-UnpackagedClaudeVersion $Directory
    return ($null -ne $version) -and
        (Test-Path -LiteralPath (Join-Path $Directory.FullName "Claude.exe")) -and
        (Test-Path -LiteralPath (Join-Path $Directory.FullName "resources"))
}

function Get-UnpackagedClaudePaths {
    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    if (-not $localAppData) {
        return @()
    }

    $unpackagedBase = Join-Path $localAppData "AnthropicClaude"
    if (-not (Test-Path $unpackagedBase)) {
        return @()
    }

    return @(Get-ChildItem $unpackagedBase -Directory -Filter "app-*" -ErrorAction SilentlyContinue |
        Where-Object { Test-UnpackagedClaudeAppDirectory $_ } |
        Sort-Object `
            @{ Expression = { Get-UnpackagedClaudeVersion $_ }; Descending = $true },
            @{ Expression = { $_.LastWriteTime }; Descending = $true } |
        ForEach-Object { $_.FullName })
}

function Write-MultipleClaudeFailureHint {
    Write-Host ""
    Write-Host "[提示] 检测到多个 %LocalAppData%\AnthropicClaude\app-* 版本，本脚本已选择最新版本。" -ForegroundColor Yellow
    Write-Host "[提示] 如果失败，请卸载旧版本或手动清理旧 app-* 目录后重试。" -ForegroundColor Yellow
}

function Write-AsarCoworkSignatureWarning {
    Write-Host ""
    Write-Host "[重要] 当前选择会修改 app.asar，并同步改写 Claude.exe 内嵌的 asar 完整性哈希。" -ForegroundColor Yellow
    Write-Host "[重要] 这会让 Claude.exe 的 Authenticode 签名变为 HashMismatch；Cowork VM 服务会拒绝未通过签名验证的客户端。" -ForegroundColor Yellow
    Write-Host "[重要] 如果需要 Cowork/截图工作区，请改用模式 1，并在第三方网关或 ccswitch 中把 claude/anthropic 风格模型名映射到实际模型。" -ForegroundColor Yellow
    Write-Host ""
}

function Find-ClaudePath {
    $packages = @(Get-AppxPackage -Name "Claude" -ErrorAction SilentlyContinue)
    foreach ($package in $packages) {
        if ($package.InstallLocation -and (Test-Path $package.InstallLocation)) {
            return $package.InstallLocation
        }
    }

    $fallback = Get-ChildItem "C:\Program Files\WindowsApps\Claude_*" -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($fallback) {
        return $fallback.FullName
    }

    return $null
}

function Get-ClaudeExePath {
    param([string]$ClaudePath)

    $exeCandidates = @(
        (Join-Path $ClaudePath "Claude.exe"),
        (Join-Path $ClaudePath "claude.exe"),
        (Join-Path $ClaudePath "app\Claude.exe"),
        (Join-Path $ClaudePath "app\claude.exe")
    )
    foreach ($exe in $exeCandidates) {
        if (Test-Path $exe) {
            return $exe
        }
    }
    return $null
}

function Remove-LegacyAppxForkArtifacts {
    $shortcutTargets = @()
    foreach ($folderName in @("Desktop", "CommonDesktopDirectory", "Programs", "CommonPrograms")) {
        $folder = [Environment]::GetFolderPath($folderName)
        if ($folder) {
            $shortcutTargets += Join-Path $folder "Claude Desktop 中文补丁.lnk"
        }
    }

    foreach ($shortcutPath in @($shortcutTargets | Select-Object -Unique)) {
        Remove-Item $shortcutPath -Force -ErrorAction SilentlyContinue
    }

    if ($env:LOCALAPPDATA) {
        $forkBase = Join-Path $env:LOCALAPPDATA "ClaudeDesktopZhCn\appx-fork"
        Remove-Item $forkBase -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-ClaudeResourcesPath {
    $script:DetectedUnpackagedClaudePaths = @(Get-UnpackagedClaudePaths)
    $script:DetectedMultipleClaudeInstalls = $false

    if ($script:DetectedUnpackagedClaudePaths.Count -gt 0) {
        $claudePath = $script:DetectedUnpackagedClaudePaths[0]
        $resourcesPath = Join-Path $claudePath "resources"
        if (-not (Test-Path $resourcesPath)) {
            throw "未找到 Claude resources 目录: $resourcesPath"
        }
        if ($script:DetectedUnpackagedClaudePaths.Count -gt 1) {
            $script:DetectedMultipleClaudeInstalls = $true
            Write-Host "  [警告] 检测到多个 %LocalAppData%\AnthropicClaude\app-*，将使用最新版本: $claudePath" -ForegroundColor Yellow
        }
        return @{
            App = $claudePath
            Resources = $resourcesPath
            InstallKind = "Unpackaged"
        }
    }

    $claudePath = Find-ClaudePath
    if (-not $claudePath) {
        throw "未找到 Claude Desktop 安装。"
    }

    $resourcesPath = Join-Path $claudePath "app\resources"
    if (-not (Test-Path $resourcesPath)) {
        throw "未找到 Claude resources 目录: $resourcesPath"
    }

    return @{
        App = $claudePath
        Resources = $resourcesPath
        InstallKind = "AppX"
    }
}

function Get-ClaudeConfigPaths {
    if (-not $env:LOCALAPPDATA) {
        return @()
    }

    $configPaths = @()
    if ($env:APPDATA) {
        $configPaths += Join-Path $env:APPDATA "Claude\config.json"
        $configPaths += Join-Path $env:APPDATA "Claude-3p\config.json"
    }

    $packageNames = @()
    $packages = @(Get-AppxPackage -Name "Claude" -ErrorAction SilentlyContinue)
    foreach ($package in $packages) {
        if ($package.PackageFamilyName) {
            $packageNames += $package.PackageFamilyName
        }
    }

    if ($packageNames.Count -eq 0) {
        $packageRoot = Join-Path $env:LOCALAPPDATA "Packages"
        $packageDirs = @(Get-ChildItem (Join-Path $packageRoot "Claude_*") -Directory -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending)
        foreach ($packageDir in $packageDirs) {
            $packageNames += $packageDir.Name
        }
    }

    foreach ($packageName in @($packageNames | Select-Object -Unique)) {
        $packagePath = Join-Path (Join-Path $env:LOCALAPPDATA "Packages") $packageName
        $configPaths += Join-Path $packagePath "LocalCache\Roaming\Claude\config.json"
        $configPaths += Join-Path $packagePath "LocalCache\Roaming\Claude-3p\config.json"
    }

    return @($configPaths | Select-Object -Unique)
}

function Grant-WriteAccess {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return
    }

    try {
        $acl = Get-Acl $Path
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $identity,
            "FullControl",
            "ContainerInherit,ObjectInherit",
            "None",
            "Allow"
        )
        $acl.SetAccessRule($rule)
        Set-Acl $Path $acl -ErrorAction SilentlyContinue
    }
    catch {
        Write-Host "  [警告] 无法更新权限: $Path" -ForegroundColor DarkYellow
    }
}

function Require-File {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        throw "缺少必要文件: $Path"
    }
}

function Get-BackupRoot {
    param([string]$ResourcesPath)
    return Join-Path $ResourcesPath ".zh-cn-backups"
}

function Get-ClaudeAppPathFromResources {
    param([string]$ResourcesPath)
    return Split-Path -Parent $ResourcesPath
}

function New-BackupSet {
    param([string]$ResourcesPath)

    if ($script:CurrentBackupSetPath -and (Test-Path $script:CurrentBackupSetPath)) {
        return $script:CurrentBackupSetPath
    }

    $root = Get-BackupRoot $ResourcesPath
    $existing = Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name |
        Select-Object -First 1
    if ($existing) {
        $script:CurrentBackupSetPath = $existing.FullName
        Write-Host "  backup set already exists, reusing oldest: $($existing.FullName)" -ForegroundColor DarkGray
        return $script:CurrentBackupSetPath
    }

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $path = Join-Path $root $stamp
    $suffix = 0
    while (Test-Path $path) {
        $suffix += 1
        $path = Join-Path $root "$stamp-$suffix"
    }

    New-Item -ItemType Directory -Path $path -Force | Out-Null
    $script:CurrentBackupSetPath = $path
    Write-Host "  backup set: $path" -ForegroundColor DarkGray
    return $path
}

function Get-RelativeResourcePath {
    param(
        [string]$ResourcesPath,
        [string]$FilePath
    )

    $root = [System.IO.Path]::GetFullPath($ResourcesPath).TrimEnd('\', '/')
    $full = [System.IO.Path]::GetFullPath($FilePath)
    if (-not $full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "备份目标不在 Claude resources 目录内: $FilePath"
    }

    return $full.Substring($root.Length).TrimStart('\', '/')
}

function Backup-ModifiedFile {
    param(
        [string]$ResourcesPath,
        [string]$FilePath
    )

    if (-not (Test-Path $FilePath)) {
        return
    }

    $backupSet = New-BackupSet $ResourcesPath
    $relative = Get-RelativeResourcePath $ResourcesPath $FilePath
    $target = Join-Path $backupSet $relative
    if (Test-Path $target) {
        return
    }

    $parent = Split-Path -Parent $target
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    Copy-Item $FilePath $target -Force
    Write-Host "  backed up: $relative" -ForegroundColor DarkGray
}

function Backup-AppFile {
    param(
        [string]$ResourcesPath,
        [string]$FilePath
    )

    if (-not (Test-Path $FilePath)) {
        return
    }

    $appPath = Get-ClaudeAppPathFromResources $ResourcesPath
    $appRoot = [System.IO.Path]::GetFullPath($appPath).TrimEnd('\', '/')
    $full = [System.IO.Path]::GetFullPath($FilePath)
    if (-not $full.StartsWith($appRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "备份目标不在 Claude app 目录内: $FilePath"
    }

    $backupSet = New-BackupSet $ResourcesPath
    $relative = $full.Substring($appRoot.Length).TrimStart('\', '/')
    $target = Join-Path $backupSet (Join-Path "_app" $relative)
    if (Test-Path $target) {
        return
    }

    $parent = Split-Path -Parent $target
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    Copy-Item $FilePath $target -Force
    Write-Host "  backed up: app\$relative" -ForegroundColor DarkGray
}

function Restore-LatestBackup {
    param([string]$ResourcesPath)

    $root = Get-BackupRoot $ResourcesPath
    if (-not (Test-Path $root)) {
        Write-Host "  no zh-CN backup found; skipping bundle restore" -ForegroundColor DarkYellow
        return
    }

    $backup = Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name |
        Select-Object -First 1
    if (-not $backup) {
        Write-Host "  no zh-CN backup found; skipping bundle restore" -ForegroundColor DarkYellow
        return
    }

    Write-Host "  restoring oldest backup set: $($backup.FullName)" -ForegroundColor DarkGray
    $backupRoot = $backup.FullName.TrimEnd('\', '/')
    $files = @(Get-ChildItem $backup.FullName -File -Recurse -ErrorAction SilentlyContinue)
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($backupRoot.Length).TrimStart('\', '/')
        if ($relative.StartsWith("_app\", [System.StringComparison]::OrdinalIgnoreCase)) {
            $appPath = Get-ClaudeAppPathFromResources $ResourcesPath
            $target = Join-Path $appPath $relative.Substring(5)
        }
        else {
            $target = Join-Path $ResourcesPath $relative
        }
        $parent = Split-Path -Parent $target
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        Copy-Item $file.FullName $target -Force
        Write-Host "  restored: $relative" -ForegroundColor Green
    }
}

function Get-LanguageResources {
    param([string]$Lang)

    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $projectDir = Split-Path -Parent $scriptDir
    $resourcesDir = Join-Path $projectDir "resources"
    $resources = @{
        Frontend = Join-Path $resourcesDir "frontend-$Lang.json"
        FrontendHardcoded = Join-Path $resourcesDir "frontend-hardcoded-$Lang.json"
        Desktop = Join-Path $resourcesDir "desktop-$Lang.json"
        Statsig = Join-Path $resourcesDir "statsig-$Lang.json"
    }

    foreach ($path in $resources.Values) {
        Require-File $path
    }

    return $resources
}

function Enable-WriteAccess {
    param([string]$ResourcesPath)

    $paths = @(
        (Get-ClaudeAppPathFromResources $ResourcesPath),
        $ResourcesPath,
        (Join-Path $ResourcesPath "ion-dist"),
        (Join-Path $ResourcesPath "ion-dist\i18n"),
        (Join-Path $ResourcesPath "ion-dist\i18n\statsig"),
        (Join-Path $ResourcesPath "ion-dist\assets"),
        (Join-Path $ResourcesPath "ion-dist\assets\v1")
    )

    foreach ($path in $paths) {
        Grant-WriteAccess $path
    }
}

function Install-LanguageFiles {
    param(
        [string]$ResourcesPath,
        [hashtable]$Pack,
        [string]$Lang
    )

    $i18nDir = Join-Path $ResourcesPath "ion-dist\i18n"
    $statsigDir = Join-Path $i18nDir "statsig"
    New-Item -ItemType Directory -Path $i18nDir -Force | Out-Null
    New-Item -ItemType Directory -Path $statsigDir -Force | Out-Null

    Copy-Item $Pack["Frontend"] (Join-Path $i18nDir "$Lang.json") -Force
    Write-Host "  installed ion-dist/i18n/$Lang.json" -ForegroundColor Green

    Copy-Item $Pack["Desktop"] (Join-Path $ResourcesPath "$Lang.json") -Force
    Write-Host "  installed resources/$Lang.json" -ForegroundColor Green

    Copy-Item $Pack["Statsig"] (Join-Path $statsigDir "$Lang.json") -Force
    Write-Host "  installed ion-dist/i18n/statsig/$Lang.json" -ForegroundColor Green
}

function Align-4 {
    param([int]$Value)
    return $Value + ((4 - ($Value % 4)) % 4)
}

function Get-UInt32LE {
    param(
        [byte[]]$Bytes,
        [int]$Offset
    )
    return [System.BitConverter]::ToUInt32($Bytes, $Offset)
}

function Get-Int32LE {
    param(
        [byte[]]$Bytes,
        [int]$Offset
    )
    return [System.BitConverter]::ToInt32($Bytes, $Offset)
}

function Read-AsarHeader {
    param(
        [byte[]]$Data,
        [string]$Path
    )

    if ($Data.Length -lt 16) {
        throw "Unsupported app.asar header in $Path"
    }

    $sizePicklePayload = Get-UInt32LE $Data 0
    $headerSize = Get-UInt32LE $Data 4
    if (($sizePicklePayload -ne 4) -or ($headerSize -le 0) -or ($Data.Length -lt (8 + $headerSize))) {
        throw "Unsupported app.asar size pickle in $Path"
    }

    $headerPickle = [byte[]]::new($headerSize)
    [System.Array]::Copy($Data, 8, $headerPickle, 0, $headerSize)
    $headerPayloadSize = Get-UInt32LE $headerPickle 0
    $headerStringSize = Get-Int32LE $headerPickle 4
    $expectedPayloadSize = Align-4 (4 + $headerStringSize)
    if (($headerPayloadSize -ne $expectedPayloadSize) -or ($headerSize -ne (4 + $headerPayloadSize))) {
        throw "Unsupported app.asar header pickle in $Path"
    }

    $headerBytes = [byte[]]::new($headerStringSize)
    [System.Array]::Copy($headerPickle, 8, $headerBytes, 0, $headerStringSize)
    $headerString = [System.Text.Encoding]::UTF8.GetString($headerBytes)
    $header = $headerString | ConvertFrom-Json
    return @{
        HeaderSize = [int]$headerSize
        HeaderString = $headerString
        Header = $header
    }
}

function Read-AsarHeaderFromFile {
    param([string]$Path)

    Require-File $Path
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        if ($stream.Length -lt 16) {
            throw "Unsupported app.asar header in $Path"
        }

        $prefix = [byte[]]::new(8)
        if ($stream.Read($prefix, 0, $prefix.Length) -ne $prefix.Length) {
            throw "Unsupported app.asar header in $Path"
        }
        $sizePicklePayload = Get-UInt32LE $prefix 0
        $headerSize = Get-UInt32LE $prefix 4
        if (($sizePicklePayload -ne 4) -or ($headerSize -le 0) -or ($stream.Length -lt (8 + $headerSize))) {
            throw "Unsupported app.asar size pickle in $Path"
        }

        $data = [byte[]]::new(8 + $headerSize)
        [System.Array]::Copy($prefix, 0, $data, 0, $prefix.Length)
        if ($stream.Read($data, 8, [int]$headerSize) -ne [int]$headerSize) {
            throw "Unsupported app.asar header pickle in $Path"
        }
        return Read-AsarHeader $data $Path
    }
    finally {
        $stream.Dispose()
    }
}

function Encode-AsarHeader {
    param(
        [string]$HeaderString,
        [int]$ExpectedHeaderSize
    )

    $headerBytes = [System.Text.Encoding]::UTF8.GetBytes($HeaderString)
    $headerPayloadSize = Align-4 (4 + $headerBytes.Length)
    if ((4 + $headerPayloadSize) -ne $ExpectedHeaderSize) {
        throw "app.asar header length changed; refusing to write an unsafe patch."
    }

    $headerPickle = [byte[]]::new($ExpectedHeaderSize)
    [System.Array]::Copy([System.BitConverter]::GetBytes([uint32]$headerPayloadSize), 0, $headerPickle, 0, 4)
    [System.Array]::Copy([System.BitConverter]::GetBytes([int32]$headerBytes.Length), 0, $headerPickle, 4, 4)
    [System.Array]::Copy($headerBytes, 0, $headerPickle, 8, $headerBytes.Length)

    $encoded = [byte[]]::new(8 + $ExpectedHeaderSize)
    [System.Array]::Copy([System.BitConverter]::GetBytes([uint32]4), 0, $encoded, 0, 4)
    [System.Array]::Copy([System.BitConverter]::GetBytes([uint32]$ExpectedHeaderSize), 0, $encoded, 4, 4)
    [System.Array]::Copy($headerPickle, 0, $encoded, 8, $ExpectedHeaderSize)
    return $encoded
}

function Encode-AsarHeaderDynamic {
    param([string]$HeaderString)

    $headerBytes = [System.Text.Encoding]::UTF8.GetBytes($HeaderString)
    $headerPayloadSize = Align-4 (4 + $headerBytes.Length)
    $headerPickleSize = 4 + $headerPayloadSize
    $headerPickle = [byte[]]::new($headerPickleSize)
    [System.Array]::Copy([System.BitConverter]::GetBytes([uint32]$headerPayloadSize), 0, $headerPickle, 0, 4)
    [System.Array]::Copy([System.BitConverter]::GetBytes([int32]$headerBytes.Length), 0, $headerPickle, 4, 4)
    [System.Array]::Copy($headerBytes, 0, $headerPickle, 8, $headerBytes.Length)

    $encoded = [byte[]]::new(8 + $headerPickleSize)
    [System.Array]::Copy([System.BitConverter]::GetBytes([uint32]4), 0, $encoded, 0, 4)
    [System.Array]::Copy([System.BitConverter]::GetBytes([uint32]$headerPickleSize), 0, $encoded, 4, 4)
    [System.Array]::Copy($headerPickle, 0, $encoded, 8, $headerPickleSize)
    return $encoded
}

function Get-AsarFileEntry {
    param(
        [object]$Header,
        [string]$FilePath
    )

    $node = $Header
    foreach ($part in $FilePath.Split('/')) {
        $filesProperty = $node.PSObject.Properties["files"]
        if (-not $filesProperty) {
            throw "Could not find $FilePath in app.asar header."
        }

        $childProperty = $filesProperty.Value.PSObject.Properties[$part]
        if (-not $childProperty) {
            throw "Could not find $FilePath in app.asar header."
        }

        $node = $childProperty.Value
    }

    foreach ($key in @("size", "offset", "integrity")) {
        if (-not $node.PSObject.Properties[$key]) {
            throw "Missing $key for $FilePath in app.asar header."
        }
    }

    return $node
}

function Add-AsarFileEntries {
    param(
        [object]$Node,
        [System.Collections.Generic.List[object]]$Entries
    )

    $filesProperty = $Node.PSObject.Properties["files"]
    if (-not $filesProperty) {
        return
    }

    foreach ($childProperty in $filesProperty.Value.PSObject.Properties) {
        $child = $childProperty.Value
        if ($child.PSObject.Properties["files"]) {
            Add-AsarFileEntries $child $Entries
        } elseif ($child.PSObject.Properties["offset"] -and $child.PSObject.Properties["size"]) {
            $Entries.Add($child)
        }
    }
}

function Get-AsarFileEntries {
    param([object]$Header)

    $entries = [System.Collections.Generic.List[object]]::new()
    Add-AsarFileEntries $Header $entries
    return $entries
}

function Add-AsarFilePathEntries {
    param(
        [object]$Node,
        [string]$Prefix,
        [System.Collections.Generic.List[object]]$Entries
    )

    $filesProperty = $Node.PSObject.Properties["files"]
    if (-not $filesProperty) {
        return
    }

    foreach ($childProperty in $filesProperty.Value.PSObject.Properties) {
        $childPath = if ($Prefix) { "$Prefix/$($childProperty.Name)" } else { $childProperty.Name }
        $child = $childProperty.Value
        if ($child.PSObject.Properties["files"]) {
            Add-AsarFilePathEntries $child $childPath $Entries
        } elseif ($child.PSObject.Properties["offset"] -and $child.PSObject.Properties["size"]) {
            $Entries.Add([pscustomobject]@{
                Path = $childPath
                Entry = $child
            })
        }
    }
}

function Get-AsarFilePathEntries {
    param([object]$Header)

    $entries = [System.Collections.Generic.List[object]]::new()
    Add-AsarFilePathEntries $Header "" $entries
    return $entries
}

function Get-AsarEntryContent {
    param(
        [byte[]]$Data,
        [int]$HeaderSize,
        [object]$Entry,
        [string]$FilePath
    )

    $contentOffset = [int64](8 + $HeaderSize + [int64]$Entry.offset)
    $contentSize = [int64]$Entry.size
    $contentEnd = $contentOffset + $contentSize
    if (($contentOffset -lt 0) -or ($contentEnd -gt $Data.Length) -or ($contentSize -gt [int]::MaxValue)) {
        throw "Unsupported app.asar file bounds for $FilePath."
    }

    $content = [byte[]]::new([int]$contentSize)
    [System.Array]::Copy($Data, [int]$contentOffset, $content, 0, [int]$contentSize)
    return $content
}

function Set-AsarEntryOffset {
    param(
        [object]$Entry,
        [int64]$Offset
    )

    if ($Entry.offset -is [string]) {
        $Entry.offset = [string]$Offset
    } else {
        $Entry.offset = $Offset
    }
}

function Replace-AsarFileContent {
    param(
        [string]$ResourcesPath,
        [string]$FilePath,
        [byte[]]$PatchedContent
    )

    $asarPath = Join-Path $ResourcesPath "app.asar"
    Require-File $asarPath

    $asarInfo = Get-Item -LiteralPath $asarPath
    Write-Host "  reading app.asar ($(Format-ByteSize $asarInfo.Length)): $FilePath" -ForegroundColor DarkGray
    Write-Host "  [进度] 正在读取 app.asar，大文件或共享盘可能需要一些时间..." -ForegroundColor DarkGray
    $data = [System.IO.File]::ReadAllBytes($asarPath)
    Write-Host "  [进度] app.asar 读取完成，正在解析 asar 头..." -ForegroundColor DarkGray
    $parsed = Read-AsarHeader $data $asarPath
    Write-Host "  [进度] asar 头解析完成，正在定位目标文件..." -ForegroundColor DarkGray
    $headerSize = $parsed["HeaderSize"]
    $header = $parsed["Header"]
    $entry = Get-AsarFileEntry $header $FilePath

    $contentOffset = [int64](8 + $headerSize + [int64]$entry.offset)
    $contentSize = [int64]$entry.size
    $contentEnd = $contentOffset + $contentSize
    if (($contentOffset -lt 0) -or ($contentEnd -gt $data.Length)) {
        throw "Unsupported app.asar file bounds for $FilePath."
    }

    $oldContent = [byte[]]::new([int]$contentSize)
    [System.Array]::Copy($data, [int]$contentOffset, $oldContent, 0, [int]$contentSize)
    Write-Host "  checking app.asar target content: $(Format-ByteSize $contentSize)" -ForegroundColor DarkGray
    Write-Host "  [进度] 正在比较旧内容和新补丁内容..." -ForegroundColor DarkGray
    $contentMatches = $oldContent.Length -eq $PatchedContent.Length
    if ($contentMatches) {
        for ($i = 0; $i -lt $oldContent.Length; $i++) {
            if ($oldContent[$i] -ne $PatchedContent[$i]) {
                $contentMatches = $false
                break
            }
        }
    }
    if ($contentMatches) {
        return $false
    }

    $targetOffset = [int64]$entry.offset
    $delta = [int64]$PatchedContent.Length - $contentSize
    Write-Host "  rebuilding app.asar content: delta=$delta bytes" -ForegroundColor DarkGray
    Write-Host "  [进度] 正在更新目标文件完整性信息..." -ForegroundColor DarkGray
    $entry.size = $PatchedContent.Length
    $entry.integrity = Get-AsarFileIntegrity $PatchedContent
    if ($delta -ne 0) {
        foreach ($other in Get-AsarFileEntries $header) {
            if ((-not [object]::ReferenceEquals($other, $entry)) -and ([int64]$other.offset -gt $targetOffset)) {
                Set-AsarEntryOffset $other ([int64]$other.offset + $delta)
            }
        }
    }

    Write-Host "  [进度] 正在拼接新的 app.asar 内容..." -ForegroundColor DarkGray
    $bodyStart = 8 + $headerSize
    $body = [System.IO.MemoryStream]::new()
    $body.Write($data, $bodyStart, [int]($contentOffset - $bodyStart))
    $body.Write($PatchedContent, 0, $PatchedContent.Length)
    $tailOffset = [int]$contentEnd
    $body.Write($data, $tailOffset, $data.Length - $tailOffset)

    Write-Host "  serializing app.asar header" -ForegroundColor DarkGray
    $updatedHeaderString = $header | ConvertTo-Json -Compress -Depth 100
    $updatedHeader = Encode-AsarHeaderDynamic $updatedHeaderString
    Write-Host "  [进度] 正在合并 header 和 body..." -ForegroundColor DarkGray
    $updatedBody = $body.ToArray()
    $updated = [byte[]]::new($updatedHeader.Length + $updatedBody.Length)
    [System.Array]::Copy($updatedHeader, 0, $updated, 0, $updatedHeader.Length)
    [System.Array]::Copy($updatedBody, 0, $updated, $updatedHeader.Length, $updatedBody.Length)

    Write-Host "  [进度] 正在创建/复用备份..." -ForegroundColor DarkGray
    Backup-ModifiedFile $ResourcesPath $asarPath
    Write-Host "  writing app.asar: $(Format-ByteSize $updated.Length)" -ForegroundColor DarkGray
    Write-Host "  [进度] 正在写回 app.asar，请勿关闭窗口..." -ForegroundColor DarkGray
    [System.IO.File]::WriteAllBytes($asarPath, $updated)
    Write-Host "  syncing Claude.exe app.asar integrity" -ForegroundColor DarkGray
    Sync-ClaudeExeAsarIntegrity $ResourcesPath
    return $true
}

function Find-BytePattern {
    param(
        [byte[]]$Data,
        [byte[]]$Pattern
    )

    $matches = New-Object System.Collections.Generic.List[int]
    if (($Pattern.Length -eq 0) -or ($Data.Length -lt $Pattern.Length)) {
        return $matches
    }

    for ($i = 0; $i -le ($Data.Length - $Pattern.Length); $i++) {
        $found = $true
        for ($j = 0; $j -lt $Pattern.Length; $j++) {
            if ($Data[$i + $j] -ne $Pattern[$j]) {
                $found = $false
                break
            }
        }
        if ($found) {
            $matches.Add($i)
        }
    }

    return $matches
}


function Get-Sha256Hex {
    param([byte[]]$Bytes)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($Bytes)
        return ([System.BitConverter]::ToString($hash) -replace "-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-Sha256HexRange {
    param(
        [byte[]]$Bytes,
        [int]$Offset,
        [int]$Count
    )

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($Bytes, $Offset, $Count)
        return ([System.BitConverter]::ToString($hash) -replace "-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-AsarFileIntegrity {
    param([byte[]]$Data)

    $blocks = New-Object System.Collections.Generic.List[string]
    if ($Data.Length -eq 0) {
        $blocks.Add((Get-Sha256Hex $Data))
    }
    else {
        for ($offset = 0; $offset -lt $Data.Length; $offset += $AsarIntegrityBlockSize) {
            $count = [Math]::Min($AsarIntegrityBlockSize, $Data.Length - $offset)
            $blocks.Add((Get-Sha256HexRange $Data $offset $count))
        }
    }

    return [pscustomobject][ordered]@{
        algorithm = "SHA256"
        hash = Get-Sha256Hex $Data
        blockSize = $AsarIntegrityBlockSize
        blocks = $blocks.ToArray()
    }
}

function Get-AsarHeaderHash {
    param([string]$AsarPath)

    $parsed = Read-AsarHeaderFromFile $AsarPath
    return Get-Sha256Hex ([System.Text.Encoding]::UTF8.GetBytes($parsed["HeaderString"]))
}

function Sync-ClaudeExeAsarIntegrity {
    param([string]$ResourcesPath)

    $appPath = Get-ClaudeAppPathFromResources $ResourcesPath
    $exePath = Join-Path $appPath "Claude.exe"
    if (-not (Test-Path $exePath)) {
        $exePath = Join-Path $appPath "claude.exe"
    }
    Require-File $exePath

    $asarPath = Join-Path $ResourcesPath "app.asar"
    Write-Host "  [进度] 正在计算 app.asar header hash..." -ForegroundColor DarkGray
    $headerHash = Get-AsarHeaderHash $asarPath
    $marker = 'resources\\app.asar","alg":"SHA256","value":"'
    $exeInfo = Get-Item -LiteralPath $exePath
    Write-Host "  [进度] 正在读取 Claude.exe ($(Format-ByteSize $exeInfo.Length)) 用于快速定位完整性标记..." -ForegroundColor DarkGray
    $exeText = [System.IO.File]::ReadAllText($exePath, [System.Text.Encoding]::ASCII)
    Write-Host "  [进度] 正在用 .NET IndexOf 扫描 Claude.exe 内嵌 app.asar 完整性标记..." -ForegroundColor DarkGray
    $markerIndex = $exeText.IndexOf($marker, [System.StringComparison]::Ordinal)
    if ($markerIndex -lt 0) {
        throw "Could not find Claude.exe app.asar integrity marker. Claude bundle format may have changed."
    }
    if ($exeText.IndexOf($marker, $markerIndex + 1, [System.StringComparison]::Ordinal) -ge 0) {
        throw "Could not find a unique Claude.exe app.asar integrity marker. Claude bundle format may have changed."
    }

    $hashOffset = $markerIndex + $marker.Length
    if (($hashOffset + 64) -gt $exeInfo.Length) {
        throw "Claude.exe app.asar integrity marker has invalid bounds."
    }

    $stream = [System.IO.File]::Open($exePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
    try {
        $hashBytes = [byte[]]::new(64)
        $stream.Seek([int64]$hashOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
        if ($stream.Read($hashBytes, 0, $hashBytes.Length) -ne $hashBytes.Length) {
            throw "Claude.exe app.asar integrity marker has invalid bounds."
        }
        $currentHash = [System.Text.Encoding]::ASCII.GetString($hashBytes)
    }
    finally {
        $stream.Dispose()
    }

    if ($currentHash -eq $headerHash) {
        Write-Host "  Claude.exe app.asar integrity already matches" -ForegroundColor Green
        return
    }
    if ($currentHash -notmatch '^[0-9a-fA-F]{64}$') {
        throw "Claude.exe app.asar integrity value is not a SHA256 hex string."
    }

    Backup-AppFile $ResourcesPath $exePath
    Write-Host "  [进度] 正在定点写回 Claude.exe 完整性哈希（64 bytes）..." -ForegroundColor DarkGray
    $newHashBytes = [System.Text.Encoding]::ASCII.GetBytes($headerHash)
    $stream = [System.IO.File]::Open($exePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
    try {
        $stream.Seek([int64]$hashOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
        $stream.Write($newHashBytes, 0, $newHashBytes.Length)
    }
    finally {
        $stream.Dispose()
    }
    Write-Host "  updated Claude.exe app.asar integrity: $currentHash -> $headerHash" -ForegroundColor Green
}

function Register-Language {
    param(
        [string]$ResourcesPath,
        [string]$Lang
    )

    $assetsDir = Join-Path $ResourcesPath "ion-dist\assets\v1"
    $jsFiles = @(Get-ChildItem (Join-Path $assetsDir "*.js") -ErrorAction SilentlyContinue)
    if ($jsFiles.Count -eq 0) {
        throw "未找到前端 JS bundle: $assetsDir"
    }

    $regex = [System.Text.RegularExpressions.Regex]::new($LanguageListPattern)
    $replacement = "$BaseLanguageList,`"$Lang`"]"
    $changed = 0
    $already = 0
    foreach ($file in $jsFiles) {
        $text = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
        if ($text.Contains($replacement)) {
            Write-Host "  $Lang already registered: $($file.Name)" -ForegroundColor Green
            $already += 1
            continue
        }

        if ($regex.IsMatch($text)) {
            $updated = $regex.Replace($text, $replacement, 1)
            Backup-ModifiedFile $ResourcesPath $file.FullName
            [System.IO.File]::WriteAllText($file.FullName, $updated, $Utf8NoBom)
            Write-Host "  patched language whitelist for ${Lang}: $($file.Name)" -ForegroundColor Green
            $changed += 1
        }
    }

    if (($changed + $already) -eq 0) {
        throw "未能注册中文语言，Claude 前端 bundle 格式可能已经变化。"
    }
}

function Patch-LanguageDisplayNames {
    param([string]$ResourcesPath)

    $assetsDir = Join-Path $ResourcesPath "ion-dist\assets\v1"
    $jsFiles = @(Get-ChildItem (Join-Path $assetsDir "*.js") -ErrorAction SilentlyContinue)
    if ($jsFiles.Count -eq 0) {
        throw "未找到前端 JS bundle: $assetsDir"
    }

    $marker = "__claudeZhLabelPatch"
    $patch = ';(()=>{const e=Intl.DisplayNames&&Intl.DisplayNames.prototype;if(!e||e.__claudeZhLabelPatch)return;const n=e.of;e.of=function(e){const t=String(e);return t==="zh-CN"?"简体中文":t==="zh-HK"?"繁体中文（中国香港）":t==="zh-TW"?"繁体中文（中国台湾）":n.call(this,e)},Object.defineProperty(e,"__claudeZhLabelPatch",{value:!0})})();'
    $patchedFiles = 0
    foreach ($file in $jsFiles) {
        $text = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
        if ($text.Contains($marker)) {
            Write-Host "  language display names already patched: $($file.Name)" -ForegroundColor Green
            continue
        }

        Backup-ModifiedFile $ResourcesPath $file.FullName
        [System.IO.File]::WriteAllText($file.FullName, ($text + $patch), $Utf8NoBom)
        Write-Host "  patched language display names: $($file.Name)" -ForegroundColor Green
        $patchedFiles += 1
    }

    if ($patchedFiles -eq 0) {
        Write-Host "  no language display name changes needed" -ForegroundColor Green
    }
}

function Unregister-Language {
    param([string]$ResourcesPath)

    $assetsDir = Join-Path $ResourcesPath "ion-dist\assets\v1"
    $jsFiles = @(Get-ChildItem (Join-Path $assetsDir "*.js") -ErrorAction SilentlyContinue)
    foreach ($file in $jsFiles) {
        $text = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
        $updated = $text
        $changed = $false
        foreach ($lang in @(',"zh-CN"', ',"zh-TW"', ',"zh-HK"')) {
            if ($updated.Contains($lang)) {
                $updated = $updated.Replace($lang, '')
                $changed = $true
            }
        }
        if ($changed) {
            [System.IO.File]::WriteAllText($file.FullName, $updated, $Utf8NoBom)
            Write-Host "  removed language whitelist entries: $($file.Name)" -ForegroundColor Green
        }
    }
}

function Get-FrontendHardcodedReplacements {
    param([string]$Language)

    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $projectDir = Split-Path -Parent $scriptDir
    $path = Join-Path $projectDir "resources\frontend-hardcoded-$Language.json"
    Require-File $path

    $items = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $replacements = @()
    foreach ($item in $items) {
        if ($item.Count -ne 2) {
            throw "无效的前端硬编码替换项: $path"
        }
        $replacements += ,@([string]$item[0], [string]$item[1])
    }
    return @($replacements | Sort-Object -Property @{ Expression = { $_[0].Length }; Descending = $true })
}

function Test-PlainUiTextReplacement {
    param([string]$Source)

    if ($Source.Contains("`n")) {
        return $false
    }
    foreach ($marker in @('"', '\', '=', ';', '=>')) {
        if ($Source.Contains($marker)) {
            return $false
        }
    }
    return $true
}

function Test-StructuralJsReplacement {
    param([string]$Source)

    $structuralStrings = @(
        "hour", "hours",
        "minute", "minutes",
        "second", "seconds",
        "day", "days",
        "week", "weeks",
        "month", "months",
        "year", "years"
    )
    $structuralLiterals = @('"Search"')
    return ($structuralStrings -contains $Source) -or ($structuralLiterals -contains $Source)
}

function Test-StructuralJsLiteralContext {
    param(
        [string]$Text,
        [int]$LiteralStart
    )

    $prefixStart = [Math]::Max(0, $LiteralStart - 96)
    $prefix = $Text.Substring($prefixStart, $LiteralStart - $prefixStart)
    return [System.Text.RegularExpressions.Regex]::IsMatch(
        $prefix,
        '(?<![A-Za-z0-9_$-])(?:as|component|displayName|glyph|icon|iconName|leadingIcon|name|role|trailingIcon|type)\s*[:=]\s*$'
    )
}

function Replace-FrontendHardcodedText {
    param(
        [string]$Text,
        [string]$Source,
        [string]$Target
    )

    if (Test-StructuralJsReplacement $Source) {
        return @{ Text = $Text; Count = 0 }
    }

    if (-not (Test-PlainUiTextReplacement $Source)) {
        $occurrences = 0
        $index = $Text.IndexOf($Source, [System.StringComparison]::Ordinal)
        while ($index -ge 0) {
            $occurrences += 1
            $index = $Text.IndexOf($Source, $index + $Source.Length, [System.StringComparison]::Ordinal)
        }
        if ($occurrences -gt 0) {
            $Text = $Text.Replace($Source, $Target)
        }
        return @{ Text = $Text; Count = $occurrences }
    }

    if (-not $Text.Contains($Source)) {
        return @{ Text = $Text; Count = 0 }
    }

    $pattern = '(?<quote>["''`])' + [System.Text.RegularExpressions.Regex]::Escape($Source) + '\k<quote>'
    $script:__frontendReplacementCount = 0
    $patched = [System.Text.RegularExpressions.Regex]::Replace(
        $Text,
        $pattern,
        {
            param($match)
            if (Test-StructuralJsLiteralContext $Text $match.Index) {
                return $match.Value
            }
            $script:__frontendReplacementCount += 1
            $quote = $match.Groups["quote"].Value
            return "$quote$Target$quote"
        }
    )
    $count = $script:__frontendReplacementCount
    $script:__frontendReplacementCount = 0
    return @{ Text = $patched; Count = $count }
}

function Test-OnlineDomTranslationEntry {
    param(
        [string]$Source,
        [string]$Target
    )

    if ([string]::IsNullOrEmpty($Source) -or [string]::IsNullOrEmpty($Target) -or ($Source -eq $Target)) {
        return $false
    }
    if ($Source.Length -gt $OnlineTranslationMaxSourceLength) {
        return $false
    }
    foreach ($fragment in @("{", "`n")) {
        if ($Source.Contains($fragment) -or $Target.Contains($fragment)) {
            return $false
        }
    }
    return $true
}

function Get-OnlineTranslationMap {
    param(
        [string]$ResourcesPath,
        [object]$Pack,
        [string]$Language
    )

    $enPath = Join-Path $ResourcesPath "ion-dist\i18n\en-US.json"
    Require-File $enPath
    Require-File $Pack["Frontend"]

    Write-Host "  loading online DOM translation sources" -ForegroundColor DarkGray
    $en = Get-Content $enPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $zh = Get-Content $Pack["Frontend"] -Raw -Encoding UTF8 | ConvertFrom-Json
    $mapping = [ordered]@{}

    Write-Host "  collecting frontend i18n DOM strings" -ForegroundColor DarkGray
    foreach ($property in $en.PSObject.Properties) {
        $source = [string]$property.Value
        $targetProperty = $zh.PSObject.Properties[$property.Name]
        if ($targetProperty) {
            $target = [string]$targetProperty.Value
            if (Test-OnlineDomTranslationEntry $source $target) {
                $mapping[$source] = $target
            }
        }
    }

    Write-Host "  merging hardcoded DOM strings" -ForegroundColor DarkGray
    foreach ($pair in @(Get-FrontendHardcodedReplacements $Language)) {
        $source = $pair[0]
        $target = $pair[1]
        if (Test-OnlineDomTranslationEntry $source $target) {
            $mapping[$source] = $target
        }
    }

    Write-Host "  prepared online DOM translation map: $($mapping.Count) strings" -ForegroundColor DarkGray
    return $mapping
}

function Get-OnlineDomTranslationScript {
    param(
        [string]$Language,
        [object]$Mapping
    )

    Write-Host "  serializing online DOM translation script" -ForegroundColor DarkGray
    $mappingJson = $Mapping | ConvertTo-Json -Compress -Depth 100
    $languageJson = $Language | ConvertTo-Json -Compress
    if ($Language -eq "zh-CN") {
        $selectedText = "已选择 `$1 项"
        $deleteSelectedText = "删除 `$1 个所选项目"
        $updatedMinuteText = "`$1 分钟前更新"
        $updatedHourText = "`$1 小时前更新"
        $updatedDayText = "`$1 天前更新"
        $updatedWeekText = "`$1 周前更新"
        $updatedMonthText = "`$1 个月前更新"
        $updatedYearText = "`$1 年前更新"
        $agoSecondText = "`$1 秒前"
        $agoMinuteText = "`$1 分钟前"
        $agoHourText = "`$1 小时前"
        $agoDayText = "`$1 天前"
        $agoWeekText = "`$1 周前"
        $addedMinuteText = "`$1 分钟前添加"
        $addedHourText = "`$1 小时前添加"
        $addedDayText = "`$1 天前添加"
        $addedWeekText = "`$1 周前添加"
        $addedMonthText = "`$1 个月前添加"
        $addedYearText = "`$1 年前添加"
        $addedOnSuffix = "添加"
    } else {
        $selectedText = "已選擇 `$1 項"
        $deleteSelectedText = "刪除 `$1 個所選項目"
        $updatedMinuteText = "`$1 分鐘前更新"
        $updatedHourText = "`$1 小時前更新"
        $updatedDayText = "`$1 天前更新"
        $updatedWeekText = "`$1 週前更新"
        $updatedMonthText = "`$1 個月前更新"
        $updatedYearText = "`$1 年前更新"
        $agoSecondText = "`$1 秒前"
        $agoMinuteText = "`$1 分鐘前"
        $agoHourText = "`$1 小時前"
        $agoDayText = "`$1 天前"
        $agoWeekText = "`$1 週前"
        $addedMinuteText = "`$1 分鐘前新增"
        $addedHourText = "`$1 小時前新增"
        $addedDayText = "`$1 天前新增"
        $addedWeekText = "`$1 週前新增"
        $addedMonthText = "`$1 個月前新增"
        $addedYearText = "`$1 年前新增"
        $addedOnSuffix = "新增"
    }
    $selectedTextJson = $selectedText | ConvertTo-Json -Compress
    $deleteSelectedTextJson = $deleteSelectedText | ConvertTo-Json -Compress
    $updatedMinuteTextJson = $updatedMinuteText | ConvertTo-Json -Compress
    $updatedHourTextJson = $updatedHourText | ConvertTo-Json -Compress
    $updatedDayTextJson = $updatedDayText | ConvertTo-Json -Compress
    $updatedWeekTextJson = $updatedWeekText | ConvertTo-Json -Compress
    $updatedMonthTextJson = $updatedMonthText | ConvertTo-Json -Compress
    $updatedYearTextJson = $updatedYearText | ConvertTo-Json -Compress
    $agoSecondTextJson = $agoSecondText | ConvertTo-Json -Compress
    $agoMinuteTextJson = $agoMinuteText | ConvertTo-Json -Compress
    $agoHourTextJson = $agoHourText | ConvertTo-Json -Compress
    $agoDayTextJson = $agoDayText | ConvertTo-Json -Compress
    $agoWeekTextJson = $agoWeekText | ConvertTo-Json -Compress
    $addedMinuteTextJson = $addedMinuteText | ConvertTo-Json -Compress
    $addedHourTextJson = $addedHourText | ConvertTo-Json -Compress
    $addedDayTextJson = $addedDayText | ConvertTo-Json -Compress
    $addedWeekTextJson = $addedWeekText | ConvertTo-Json -Compress
    $addedMonthTextJson = $addedMonthText | ConvertTo-Json -Compress
    $addedYearTextJson = $addedYearText | ConvertTo-Json -Compress
    $addedMonthNames = @("Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec")
    $addedMonthRuleParts = for ($i = 0; $i -lt 12; $i++) {
        $addedOnLabel = ('' + ($i + 1) + '月$1日') + $addedOnSuffix
        '[/^added ' + $addedMonthNames[$i] + ' (\d\d?)(?:, \d\d\d\d)?$/,' + ($addedOnLabel | ConvertTo-Json -Compress) + ']'
    }
    # __ADDED_MONTH_RULES__ sits inside the G=[...] array literal, so inject the
    # flat comma-joined rule elements -- wrapping them in [ ] would nest them as
    # a single G entry and never match.
    $addedMonthRulesJson = $addedMonthRuleParts -join ','
    $template = @'
(()=>{try{
const L=__LANGUAGE__,M=__MAPPING__,ST=__SELECTED_TEXT__,DST=__DELETE_SELECTED_TEXT__,UMI=__UPDATED_MINUTE_TEXT__,UH=__UPDATED_HOUR_TEXT__,UD=__UPDATED_DAY_TEXT__,UW=__UPDATED_WEEK_TEXT__,UMO=__UPDATED_MONTH_TEXT__,UY=__UPDATED_YEAR_TEXT__,AS=__AGO_SECOND__,AMN=__AGO_MINUTE__,AH=__AGO_HOUR__,ADY=__AGO_DAY__,AWK=__AGO_WEEK__,ADDMI=__ADDED_MINUTE__,ADDH=__ADDED_HOUR__,ADDD=__ADDED_DAY__,ADDW=__ADDED_WEEK__,ADDMO=__ADDED_MONTH__,ADDY=__ADDED_YEAR__;
localStorage.setItem("spa:locale",L);
document.documentElement&&document.documentElement.setAttribute("lang",L);
const N=s=>(s||"").replace(/\s+/g," ").trim();
const G=[
[/^Morning, (.+)$/,"早上好，$1"],[/^Good morning, (.+)$/,"早上好，$1"],
[/^Afternoon, (.+)$/,"下午好，$1"],[/^Good afternoon, (.+)$/,"下午好，$1"],
[/^Evening, (.+)$/,"晚上好，$1"],[/^Good evening, (.+)$/,"晚上好，$1"],
[/^It's late-night (.+)$/,"夜深了，$1"],[/^Good night, (.+)$/,"晚安，$1"],
[/^Delete (\d+) chat$/,"删除 $1 个聊天"],[/^Delete (\d+) chats$/,"删除 $1 个聊天"],
[/^Move (\d+) chat to a project$/,"将 $1 个聊天移至项目"],[/^Move (\d+) chats to a project$/,"将 $1 个聊天移至项目"],
[/^Connection needs (\d+) field$/,"连接还需要填写 $1 个字段"],[/^Connection needs (\d+) fields$/,"连接还需要填写 $1 个字段"],
[/^needs (\d+) field$/,"还需要填写 $1 个字段"],[/^needs (\d+) fields$/,"还需要填写 $1 个字段"],
[/^Are you sure you want to delete (\d+) chat\? This cannot be undone\.$/,"你确定要删除 $1 个聊天吗？此操作无法撤消。"],
[/^Are you sure you want to delete (\d+) chats\? This cannot be undone\.$/,"你确定要删除 $1 个聊天吗？此操作无法撤消。"],
[/^Are you sure you want to permanently delete this chat\? This cannot be undone\.$/,"你确定要永久删除此聊天吗？此操作无法撤消。"],
[/^Are you sure you want to permanently delete these chats\? This cannot be undone\.$/,"你确定要永久删除这些聊天吗？此操作无法撤消。"],
[/^Archive (\d+) task\? You can find it in the Archived tab\.$/,"要归档 $1 个任务吗？你可以在“已归档”标签页中找到它。"],
[/^Archive (\d+) tasks\? You can find them in the Archived tab\.$/,"要归档 $1 个任务吗？你可以在“已归档”标签页中找到它们。"],
[/^(\d+) selected$/,ST],
[/^Delete (\d+) selected item$/,DST],
[/^Delete (\d+) selected items$/,DST],
[/^Updated (\d+) minutes? ago$/,UMI],
[/^Updated (\d+) hours? ago$/,UH],
[/^Updated (\d+) days? ago$/,UD],
[/^Updated (\d+) weeks? ago$/,UW],
[/^Updated (\d+) months? ago$/,UMO],
[/^Updated (\d+) years? ago$/,UY],
[/^(\d+)s ago$/,AS],
[/^(\d+)m ago$/,AMN],
[/^(\d+)h ago$/,AH],
[/^(\d+)d ago$/,ADY],
[/^(\d+)w ago$/,AWK],
[/^added (\d+) minutes? ago$/,ADDMI],
[/^added (\d+) hours? ago$/,ADDH],
[/^added (\d+) days? ago$/,ADDD],
[/^added (\d+) weeks? ago$/,ADDW],
[/^added (\d+) months? ago$/,ADDMO],
[/^added (\d+) years? ago$/,ADDY],
__ADDED_MONTH_RULES__,
[/^Mon$/,"周一"],[/^Tue$/,"周二"],[/^Wed$/,"周三"],[/^Thu$/,"周四"],[/^Fri$/,"周五"],[/^Sat$/,"周六"],[/^Sun$/,"周日"]
];
const R=s=>{const n=N(s);if(M[n])return M[n];for(const [r,t] of G){const m=n.match(r);if(m)return t.replace("$1",m[1])}};
const X=new Set(["SCRIPT","STYLE","NOSCRIPT"]),C="pre,code,kbd,samp,var,[data-language],[data-testid*=code],.cm-editor,.monaco-editor,.hljs",P='[data-testid="user-message"],.standard-markdown,.progressive-markdown,[data-testid="chat-input"],[data-testid="conway-composer-input"],[data-testid="conway-user-message"] .user-bubble,[data-testid="conway-output-cell"]';
const SL=/^\/?[a-z][a-z0-9_]*(?:-[a-z0-9_]+)+(?:\s*(?:Custom command|Slash command))?$/i;
function K(n){let e=n.nodeType===1?n:n.parentElement;for(let i=0;e&&i<5;e=e.parentElement,i++){const t=N(e.textContent);if(SL.test(t))return true;if(/\s/.test(t))break}return false}
function Q(n){const e=n.nodeType===1?n:n.parentElement;return !!(e&&e.closest(P))}
function H(n){return Q(n)||!!(n&&n.nodeType===1&&n.querySelector(P))}
function T(){try{const b=document.body||document.documentElement;if(!b)return;const w=document.createTreeWalker(b,NodeFilter.SHOW_TEXT,{acceptNode(n){const p=n.parentElement;if(!p||X.has(p.tagName)||p.closest('[contenteditable],'+C)||Q(n)||K(n)||!R(n.nodeValue))return NodeFilter.FILTER_REJECT;return NodeFilter.FILTER_ACCEPT}});let n;while(n=w.nextNode()){const v=R(n.nodeValue);if(v)n.nodeValue=v}document.querySelectorAll("[role=dialog] p,[role=dialog] div,[role=dialog] span").forEach(e=>{try{if(e.closest("button,[contenteditable],"+C)||H(e)||K(e))return;const t=R(e.textContent);if(t&&N(e.textContent)!==N(t))e.textContent=t}catch{}});document.querySelectorAll("[aria-label],[title],[placeholder],input,textarea").forEach(e=>{["aria-label","title","placeholder","value"].forEach(a=>{try{if(e.closest(C)||Q(e)||K(e))return;if(a==="value"&&!(e.matches("input[type=button],input[type=submit]")))return;let v=e.getAttribute?e.getAttribute(a):void 0;if(v==null&&a in e)v=e[a];const t=R(v);if(t){if(e.setAttribute)e.setAttribute(a,t);try{if(a in e)e[a]=t}catch{}}}catch{}})});document.querySelectorAll("a").forEach(e=>{try{if(H(e))return;const r=e.getBoundingClientRect(),txt=N(e.textContent);if(txt==="Claude"&&r.left<100&&r.top<100)e.style.visibility="hidden"}catch{}})}catch{}}
T();
new MutationObserver(()=>{clearTimeout(window.__claudeZhDomTimer);window.__claudeZhDomTimer=setTimeout(T,30)}).observe(document.documentElement,{subtree:true,childList:true,characterData:true,attributes:true});
}catch(e){}})()
'@
    return $template.Replace("__LANGUAGE__", $languageJson).Replace("__MAPPING__", $mappingJson).Replace("__SELECTED_TEXT__", $selectedTextJson).Replace("__DELETE_SELECTED_TEXT__", $deleteSelectedTextJson).Replace("__UPDATED_MINUTE_TEXT__", $updatedMinuteTextJson).Replace("__UPDATED_HOUR_TEXT__", $updatedHourTextJson).Replace("__UPDATED_DAY_TEXT__", $updatedDayTextJson).Replace("__UPDATED_WEEK_TEXT__", $updatedWeekTextJson).Replace("__UPDATED_MONTH_TEXT__", $updatedMonthTextJson).Replace("__UPDATED_YEAR_TEXT__", $updatedYearTextJson).Replace("__AGO_SECOND__", $agoSecondTextJson).Replace("__AGO_MINUTE__", $agoMinuteTextJson).Replace("__AGO_HOUR__", $agoHourTextJson).Replace("__AGO_DAY__", $agoDayTextJson).Replace("__AGO_WEEK__", $agoWeekTextJson).Replace("__ADDED_MINUTE__", $addedMinuteTextJson).Replace("__ADDED_HOUR__", $addedHourTextJson).Replace("__ADDED_DAY__", $addedDayTextJson).Replace("__ADDED_WEEK__", $addedWeekTextJson).Replace("__ADDED_MONTH__", $addedMonthTextJson).Replace("__ADDED_YEAR__", $addedYearTextJson).Replace("__ADDED_MONTH_RULES__", $addedMonthRulesJson)
}

function Remove-ExistingOnlineDomTranslationPatch {
    param([string]$Text)

    $markerComment = "/*$OnlineLocaleMainMarker*/"
    $markerIndex = $Text.IndexOf($markerComment, [System.StringComparison]::Ordinal)
    if ($markerIndex -lt 0) {
        return @{ Text = $Text; Removed = $false }
    }

    Write-Host "  [进度] 检测到旧版在线 DOM 补丁标记，正在快速定位旧注入..." -ForegroundColor DarkGray
    $eventPattern = [System.Text.RegularExpressions.Regex]::new('\.webContents\.on\((?<quote>["''`])dom-ready\k<quote>,\(\)=>\{')
    $eventMatches = $eventPattern.Matches($Text.Substring(0, $markerIndex))
    if ($eventMatches.Count -eq 0) {
        Write-Host "  [警告] 找到旧补丁标记，但无法定位 dom-ready 注入起点；将保留原内容继续。" -ForegroundColor DarkYellow
        return @{ Text = $Text; Removed = $false }
    }
    $eventMatch = $eventMatches[$eventMatches.Count - 1]
    $anchorIndex = $eventMatch.Index
    $eventQuote = $eventMatch.Groups["quote"].Value

    $receiverStart = $anchorIndex - 1
    while ($receiverStart -ge 0) {
        $ch = $Text[$receiverStart]
        $isIdentifierChar = (($ch -ge 'a') -and ($ch -le 'z')) -or (($ch -ge 'A') -and ($ch -le 'Z')) -or (($ch -ge '0') -and ($ch -le '9')) -or ($ch -eq '_') -or ($ch -eq '$')
        if (-not $isIdentifierChar) {
            break
        }
        $receiverStart -= 1
    }
    $receiverStart += 1
    if ($receiverStart -ge $anchorIndex) {
        Write-Host "  [警告] 找到旧补丁标记，但无法识别 webContents 变量名；将保留原内容继续。" -ForegroundColor DarkYellow
        return @{ Text = $Text; Removed = $false }
    }

    $receiver = $Text.Substring($receiverStart, $anchorIndex - $receiverStart)
    $bodyStart = $anchorIndex + $eventMatch.Length
    $executeNeedle = ";" + $receiver + ".webContents.executeJavaScript("
    $executeIndex = $Text.LastIndexOf($executeNeedle, $markerIndex, [System.StringComparison]::Ordinal)
    $handlerEnding = if ($markerIndex -ge 3) { $Text.Substring($markerIndex - 3, 3) } else { "" }
    if (($executeIndex -lt $bodyStart) -or (($handlerEnding -ne "});") -and ($handlerEnding -ne "}),"))) {
        Write-Host "  [警告] 找到旧补丁标记，但旧注入结构不符合预期；将保留原内容继续。" -ForegroundColor DarkYellow
        return @{ Text = $Text; Removed = $false }
    }

    $body = $Text.Substring($bodyStart, $executeIndex - $bodyStart)
    $terminator = $handlerEnding.Substring(2, 1)
    $replacement = $receiver + ".webContents.on(" + $eventQuote + "dom-ready" + $eventQuote + ",()=>{" + $body + '})' + $terminator
    $patchedEnd = $markerIndex + $markerComment.Length
    $patchedText = $Text.Substring(0, $receiverStart) + $replacement + $Text.Substring($patchedEnd)
    return @{ Text = $patchedText; Removed = $true }
}

function Find-OnlineDomTranslationHook {
    param(
        [string]$Text,
        [switch]$Quiet
    )

    $readyNeedle = "main_view_dom_ready"
    # Claude 1.1xxxx moved the main-view handler into a nested callback. A
    # regex that stops at the first `})` can select no handler (or truncate it),
    # so we locate the callback and balance braces while honoring JS strings.
    $eventPattern = [System.Text.RegularExpressions.Regex]::new('\.webContents\.on\((?<quote>["''`])dom-ready\k<quote>,(?<outer>\()?\(\)=>\{')
        $handlerCloseNeedle = "})"

    if (-not $Quiet) {
        Write-Host "  [进度] 正在快速扫描 dom-ready handler..." -ForegroundColor DarkGray
    }
    $searchIndex = 0
    $checked = 0
    $fallbackMatch = $null
    $mainViewMatch = $null
    while ($true) {
        $eventMatch = $eventPattern.Match($Text, $searchIndex)
        if (-not $eventMatch.Success) {
            break
        }
        $anchorIndex = $eventMatch.Index
        $checked += 1

        $bodyStart = $anchorIndex + $eventMatch.Length
        $bodyStart = $bodyStart
        $depth = 1
        $quote = $null
        $escaped = $false
        $handlerClose = -1
        for ($i = $bodyStart; $i -lt $Text.Length; $i++) {
            $ch = $Text[$i]
            if ($quote) {
                if ($escaped) { $escaped = $false; continue }
                if ($ch -eq '\\') { $escaped = $true; continue }
                if ($ch -eq $quote) { $quote = $null }
                continue
            }
            if (($ch -eq '"') -or ($ch -eq "'") -or ($ch -eq '`')) { $quote = $ch; continue }
            if ($ch -eq '{') { $depth++; continue }
            if ($ch -eq '}') {
                $depth--
                if ($depth -eq 0 -and ($i + 1 -lt $Text.Length) -and $Text[$i + 1] -eq ')') {
                    $handlerClose = $i
                    break
                }
            }
        }
        if ($handlerClose -lt $bodyStart) {
            if (-not $Quiet) {
                Write-Host "  [进度] 第 $checked 个 dom-ready handler 结束位置异常，继续查找下一个..." -ForegroundColor DarkGray
            }
            $searchIndex = $bodyStart
            continue
        }

        $body = $Text.Substring($bodyStart, $handlerClose - $bodyStart).TrimEnd(";")
        $closeLength = if ($eventMatch.Groups["outer"].Success) { 3 } else { 2 }
        $terminatorIndex = $handlerClose + $closeLength
        if ($terminatorIndex -ge $Text.Length) {
            if (-not $Quiet) {
                Write-Host "  [进度] 第 $checked 个 dom-ready handler 含嵌套代码或缺少结束分隔符，继续查找下一个..." -ForegroundColor DarkGray
            }
            $searchIndex = $bodyStart
            continue
        }
        $terminator = [string]$Text[$terminatorIndex]
        if (($terminator -ne ";") -and ($terminator -ne ",")) {
            if (-not $Quiet) {
                Write-Host "  [进度] 第 $checked 个 dom-ready handler 使用未知结束分隔符，继续查找下一个..." -ForegroundColor DarkGray
            }
            $searchIndex = $bodyStart
            continue
        }
        $receiverStart = $anchorIndex - 1
        while ($receiverStart -ge 0) {
            $ch = $Text[$receiverStart]
            $isIdentifierChar = (($ch -ge 'a') -and ($ch -le 'z')) -or (($ch -ge 'A') -and ($ch -le 'Z')) -or (($ch -ge '0') -and ($ch -le '9')) -or ($ch -eq '_') -or ($ch -eq '$')
            if (-not $isIdentifierChar) {
                break
            }
            $receiverStart -= 1
        }
        $receiverStart += 1
        if ($receiverStart -ge $anchorIndex) {
            if (-not $Quiet) {
                Write-Host "  [进度] 无法识别 webContents 变量名，继续查找下一个 handler..." -ForegroundColor DarkGray
            }
            $searchIndex = $terminatorIndex + 1
            continue
        }

        $receiver = $Text.Substring($receiverStart, $anchorIndex - $receiverStart)
        $hookLength = ($terminatorIndex + 1) - $receiverStart
        $result = @{
            Success = $true
            Index = $receiverStart
            Length = $hookLength
            Receiver = $receiver
            Body = $body
            Terminator = $terminator
            EventQuote = $eventMatch.Groups["quote"].Value
            CallbackWrapped = $eventMatch.Groups["outer"].Success
        }
        if ($body.Contains($readyNeedle)) {
            if (-not $Quiet) {
                Write-Host "  [进度] 已找到包含 main_view_dom_ready 的 dom-ready handler：handler=$checked, receiver=$receiver。" -ForegroundColor DarkGray
            }
            return $result
        }

        $contextStart = [Math]::Max(0, $receiverStart - 2500)
        $context = $Text.Substring($contextStart, $receiverStart - $contextStart)
        if (($null -eq $mainViewMatch) -and $context.Contains(".vite/build/mainView.js")) {
            $mainViewMatch = $result
        }
        if ($null -eq $fallbackMatch) {
            $fallbackMatch = $result
        }
        $searchIndex = $terminatorIndex + 1
    }

    $selected = if ($null -ne $mainViewMatch) { $mainViewMatch } else { $fallbackMatch }
    if ($null -ne $selected) {
        if (-not $Quiet) {
            Write-Host "  [进度] 在线 DOM 注入点定位完成：扫描 $checked 个 handler，receiver=$($selected['Receiver'])。" -ForegroundColor DarkGray
        }
        return $selected
    }
    if (-not $Quiet) {
        Write-Host "  [进度] 已扫描 $checked 个 dom-ready handler，未找到可用注入点，准备尝试 legacy 注入点..." -ForegroundColor DarkGray
    }
    return @{ Success = $false }
}

function Resolve-MainProcessAsarTarget {
    param(
        [byte[]]$Data,
        [int]$HeaderSize,
        [object]$Header
    )

    $markerMatches = [System.Collections.Generic.List[string]]::new()
    $hookMatches = [System.Collections.Generic.List[object]]::new()
    $legacyMatches = [System.Collections.Generic.List[string]]::new()
    $fallbackExists = $false

    foreach ($item in Get-AsarFilePathEntries $Header) {
        $filePath = [string]$item.Path
        if ($filePath -eq $AsarPatchTargetFallback) {
            $fallbackExists = $true
        }
        # Recent Windows builds no longer keep the main process under
        # `.vite/build/`; it may be emitted beside the frame-shell bundles.
        # Inspect every JavaScript entry and use the semantic hook/path filters
        # below to avoid selecting the tiny bootstrap index.js.
        if (-not $filePath.EndsWith(".js", [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $content = Get-AsarEntryContent $Data $HeaderSize $item.Entry $filePath
        $text = [System.Text.Encoding]::UTF8.GetString($content)
        if ($text.Contains($OnlineLocaleMainMarker)) {
            $markerMatches.Add($filePath)
            continue
        }
        if ($text.Contains("main_view_dom_ready") -or $text.Contains('.webContents.on("dom-ready"')) {
            $hookMatch = Find-OnlineDomTranslationHook $text -Quiet
            if ($hookMatch["Success"]) {
                # Prefer bundles whose path identifies the desktop main view;
                # keep other valid candidates as a fallback for renamed builds.
                $score = if ($filePath -match '(?i)(main|window|frame|shell|index)') { 0 } else { 1 }
                $hookMatches.Add([pscustomobject]@{ Path = $filePath; Score = $score })
                continue
            }
        }
        if ($text.Contains('s.webContents.on("dom-ready",()=>{DIA()});')) {
            $legacyMatches.Add($filePath)
        }
    }

    if ($markerMatches.Count -eq 1) {
        Write-Host "  selected main-process ASAR bundle: $($markerMatches[0]) (existing online patch)" -ForegroundColor DarkGray
        return $markerMatches[0]
    }
    if ($markerMatches.Count -gt 1) {
        throw "Could not select main-process app.asar bundle: multiple existing online patch markers found: $($markerMatches -join ', ')"
    }

    if ($hookMatches.Count -ge 1) {
        $best = @($hookMatches | Sort-Object Score, Path)
        if (($best | Where-Object Score -eq $best[0].Score).Count -gt 1) {
            throw "Could not select main-process app.asar bundle: multiple dom-ready candidates found: $((($best | Where-Object Score -eq $best[0].Score).Path) -join ', ')"
        }
        Write-Host "  selected main-process ASAR bundle: $($best[0].Path)" -ForegroundColor DarkGray
        return $best[0].Path
    }

    if ($legacyMatches.Count -eq 1) {
        Write-Host "  selected legacy main-process ASAR bundle: $($legacyMatches[0])" -ForegroundColor DarkGray
        return $legacyMatches[0]
    }
    if ($legacyMatches.Count -gt 1) {
        throw "Could not select main-process app.asar bundle: multiple legacy dom-ready handlers found: $($legacyMatches -join ', ')"
    }

    if ($fallbackExists) {
        Write-Host "  [警告] 未动态定位到 main-process bundle，回退到旧版目标：$AsarPatchTargetFallback" -ForegroundColor DarkYellow
        return $AsarPatchTargetFallback
    }

    throw "Could not locate Claude's main-process app.asar bundle."
}

function Remove-ExistingOnlineLocaleLockPatch {
    param([string]$Text)

    $pattern = [System.Text.RegularExpressions.Regex]::new(
        'requestLocaleChange\((?<arg>[A-Za-z_$][A-Za-z0-9_$]*)\)\{(?<setter>[A-Za-z_$][A-Za-z0-9_$]*)\("(?<lang>[^"]+)"\)\}/\*' +
        [System.Text.RegularExpressions.Regex]::Escape($OnlineLocaleLockMarker) +
        '\*/'
    )
    $match = $pattern.Match($Text)
    if (-not $match.Success) {
        return @{ Text = $Text; Removed = $false }
    }
    if ($pattern.Match($Text, $match.Index + $match.Length).Success) {
        throw "Could not refresh DesktopIntl locale persistence: multiple existing lock markers found."
    }

    $arg = $match.Groups["arg"].Value
    $setter = $match.Groups["setter"].Value
    $replacement = "requestLocaleChange(" + $arg + "){" + $setter + "(" + $arg + ")}"
    $patched = $Text.Substring(0, $match.Index) + $replacement + $Text.Substring($match.Index + $match.Length)
    return @{ Text = $patched; Removed = $true }
}

function Find-OnlineLocaleLockHandler {
    param([string]$Text)

    $pattern = [System.Text.RegularExpressions.Regex]::new(
        'requestLocaleChange\((?<arg>[A-Za-z_$][A-Za-z0-9_$]*)\)\{(?<setter>[A-Za-z_$][A-Za-z0-9_$]*)\(\k<arg>\)\}'
    )
    $candidates = @()
    foreach ($match in $pattern.Matches($Text)) {
        $beforeStart = [Math]::Max(0, $match.Index - 512)
        $before = $Text.Substring($beforeStart, $match.Index - $beforeStart)
        $afterLength = [Math]::Min(512, $Text.Length - ($match.Index + $match.Length))
        $after = $Text.Substring($match.Index + $match.Length, $afterLength)
        if ($before.Contains(".setImplementation({") -and $before.Contains("getInitialLocale") -and $after.Contains("dispatchLocaleChanged")) {
            $candidates += $match
        }
    }

    if ($candidates.Count -gt 1) {
        throw "Could not patch DesktopIntl locale persistence: multiple requestLocaleChange handlers found."
    }
    if ($candidates.Count -eq 0) {
        return @{ Success = $false }
    }

    $match = $candidates[0]
    return @{
        Success = $true
        Index = $match.Index
        Length = $match.Length
        Arg = $match.Groups["arg"].Value
        Setter = $match.Groups["setter"].Value
    }
}

function Resolve-OnlineLocaleLockAsarTarget {
    param(
        [byte[]]$Data,
        [int]$HeaderSize,
        [object]$Header
    )

    $markerMatches = [System.Collections.Generic.List[string]]::new()
    $handlerMatches = [System.Collections.Generic.List[string]]::new()
    foreach ($item in Get-AsarFilePathEntries $Header) {
        $filePath = [string]$item.Path
        if ((-not $filePath.StartsWith(".vite/build/", [System.StringComparison]::Ordinal)) -or (-not $filePath.EndsWith(".js", [System.StringComparison]::Ordinal))) {
            continue
        }

        $content = Get-AsarEntryContent $Data $HeaderSize $item.Entry $filePath
        $text = [System.Text.Encoding]::UTF8.GetString($content)
        if ($text.Contains($OnlineLocaleLockMarker)) {
            $markerMatches.Add($filePath)
            continue
        }
        if ((-not $text.Contains("requestLocaleChange")) -or (-not $text.Contains("dispatchLocaleChanged"))) {
            continue
        }
        $handler = Find-OnlineLocaleLockHandler $text
        if ($handler["Success"]) {
            $handlerMatches.Add($filePath)
        }
    }

    if ($markerMatches.Count -eq 1) {
        return $markerMatches[0]
    }
    if ($markerMatches.Count -gt 1) {
        throw "Could not select DesktopIntl locale bundle: multiple candidates found: $($markerMatches -join ', ')"
    }
    if ($handlerMatches.Count -eq 1) {
        return $handlerMatches[0]
    }
    if ($handlerMatches.Count -gt 1) {
        throw "Could not select DesktopIntl locale bundle: multiple candidates found: $($handlerMatches -join ', ')"
    }
    throw "Could not patch DesktopIntl locale persistence. Claude's bundle format may have changed."
}

function Patch-OnlineLocaleLock {
    param(
        [string]$ResourcesPath,
        [string]$Language
    )

    $asarPath = Join-Path $ResourcesPath "app.asar"
    $data = [System.IO.File]::ReadAllBytes($asarPath)
    $parsed = Read-AsarHeader $data $asarPath
    $headerSize = $parsed["HeaderSize"]
    $header = $parsed["Header"]
    $asarTarget = Resolve-OnlineLocaleLockAsarTarget $data $headerSize $header
    $entry = Get-AsarFileEntry $header $asarTarget
    $content = Get-AsarEntryContent $data $headerSize $entry $asarTarget
    $text = [System.Text.Encoding]::UTF8.GetString($content)

    $existing = Remove-ExistingOnlineLocaleLockPatch $text
    $text = $existing["Text"]
    $handler = Find-OnlineLocaleLockHandler $text
    if (-not $handler["Success"]) {
        throw "Could not patch DesktopIntl locale persistence in $asarTarget."
    }

    $languageJson = $Language | ConvertTo-Json -Compress
    $replacement = "requestLocaleChange(" + $handler["Arg"] + "){" + $handler["Setter"] + "(" + $languageJson + ")}/*" + $OnlineLocaleLockMarker + "*/"
    $index = [int]$handler["Index"]
    $length = [int]$handler["Length"]
    $patched = $text.Substring(0, $index) + $replacement + $text.Substring($index + $length)
    [void](Replace-AsarFileContent $ResourcesPath $asarTarget ([System.Text.Encoding]::UTF8.GetBytes($patched)))
    $action = if ([bool]$existing["Removed"]) { "refreshed" } else { "patched" }
    Write-Host "  $action DesktopIntl locale lock in ${asarTarget}: $Language" -ForegroundColor Green
}

function Patch-OnlineDomTranslation {
    param(
        [string]$ResourcesPath,
        [object]$Pack,
        [string]$Language
    )

    $asarPath = Join-Path $ResourcesPath "app.asar"
    Require-File $asarPath

    Write-Host "  preparing online claude.ai DOM translation patch" -ForegroundColor DarkGray
    $asarInfo = Get-Item -LiteralPath $asarPath
    Write-Host "  [进度] 正在读取 app.asar ($(Format-ByteSize $asarInfo.Length))..." -ForegroundColor DarkGray
    $data = [System.IO.File]::ReadAllBytes($asarPath)
    Write-Host "  [进度] app.asar 读取完成，正在解析 asar 头..." -ForegroundColor DarkGray
    $parsed = Read-AsarHeader $data $asarPath
    Write-Host "  [进度] asar 头解析完成，正在定位 main-process bundle..." -ForegroundColor DarkGray
    $headerSize = $parsed["HeaderSize"]
    $header = $parsed["Header"]
    $asarTarget = Resolve-MainProcessAsarTarget $data $headerSize $header
    $entry = Get-AsarFileEntry $header $asarTarget

    $contentOffset = [int64](8 + $headerSize + [int64]$entry.offset)
    $contentSize = [int64]$entry.size
    $contentEnd = $contentOffset + $contentSize
    if (($contentOffset -lt 0) -or ($contentEnd -gt $data.Length)) {
        throw "Unsupported app.asar file bounds for $asarTarget."
    }

    $content = [byte[]]::new([int]$contentSize)
    [System.Array]::Copy($data, [int]$contentOffset, $content, 0, [int]$contentSize)
    Write-Host "  loaded main-process bundle: $(Format-ByteSize $contentSize)" -ForegroundColor DarkGray
    Write-Host "  [进度] 正在解码 main-process bundle 文本..." -ForegroundColor DarkGray
    $text = [System.Text.Encoding]::UTF8.GetString($content)
    Write-Host "  [进度] 正在快速检查是否已有旧版在线 DOM 补丁标记..." -ForegroundColor DarkGray
    if ($text.Contains($OnlineLocaleMainMarker)) {
        $existingPatch = Remove-ExistingOnlineDomTranslationPatch $text
        $text = $existingPatch["Text"]
        $hadExisting = [bool]$existingPatch["Removed"]
        if ($hadExisting) {
            Write-Host "  [进度] 已移除旧版在线 DOM 补丁，继续生成新补丁..." -ForegroundColor DarkGray
        }
    } else {
        Write-Host "  [进度] 未发现旧版在线 DOM 补丁，继续生成新补丁..." -ForegroundColor DarkGray
        $hadExisting = $false
    }

    $mapping = Get-OnlineTranslationMap $ResourcesPath $Pack $Language
    $script = Get-OnlineDomTranslationScript $Language $mapping
    $scriptLiteral = $script | ConvertTo-Json -Compress

    Write-Host "  locating online DOM translation injection point" -ForegroundColor DarkGray
    $hookMatch = Find-OnlineDomTranslationHook $text
    if ($hookMatch["Success"]) {
        $receiver = $hookMatch["Receiver"]
        $body = $hookMatch["Body"]
        $terminator = $hookMatch["Terminator"]
        $eventQuote = $hookMatch["EventQuote"]
        $injectedBody = $body + ";" + $receiver + ".webContents.executeJavaScript(" + $scriptLiteral + ").catch(()=>{})"
        $callbackOpen = if ([bool]$hookMatch["CallbackWrapped"]) { "(()=>{" } else { "()=>{" }
        $callbackClose = if ([bool]$hookMatch["CallbackWrapped"]) { "}))" } else { "})" }
        $injection = $receiver + ".webContents.on(" + $eventQuote + "dom-ready" + $eventQuote + "," + $callbackOpen + $injectedBody + $callbackClose + $terminator + '/*' + $OnlineLocaleMainMarker + '*/'
        if ($text.Contains($injection)) {
            Write-Host "  online claude.ai DOM translation already patched" -ForegroundColor Green
        } else {
            Write-Host "  injecting online DOM translation hook" -ForegroundColor DarkGray
            $hookIndex = [int]$hookMatch["Index"]
            $hookLength = [int]$hookMatch["Length"]
            $patched = $text.Substring(0, $hookIndex) + $injection + $text.Substring($hookIndex + $hookLength)
            $patchedContent = [System.Text.Encoding]::UTF8.GetBytes($patched)
            [void](Replace-AsarFileContent $ResourcesPath $asarTarget $patchedContent)
            $action = if ($hadExisting) { "refreshed" } else { "patched" }
            Write-Host "  $action online claude.ai DOM translation: $($mapping.Count) strings" -ForegroundColor Green
        }
        Patch-OnlineLocaleLock $ResourcesPath $Language
        return
    }

    $legacyAnchor = 's.webContents.on("dom-ready",()=>{DIA()});'
    if (-not $text.Contains($legacyAnchor)) {
        throw "Could not find online claude.ai DOM translation injection point. Claude's bundle format may have changed."
    }

    $injection = 's.webContents.on("dom-ready",()=>{DIA();s.webContents.executeJavaScript(' + $scriptLiteral + ').catch(()=>{})});/*' + $OnlineLocaleMainMarker + '*/'
    if ($text.Contains($injection)) {
        Write-Host "  online claude.ai DOM translation already patched" -ForegroundColor Green
    } else {
        $anchorIndex = $text.IndexOf($legacyAnchor, [System.StringComparison]::Ordinal)
        Write-Host "  injecting legacy online DOM translation hook" -ForegroundColor DarkGray
        $patched = $text.Substring(0, $anchorIndex) + $injection + $text.Substring($anchorIndex + $legacyAnchor.Length)
        $patchedContent = [System.Text.Encoding]::UTF8.GetBytes($patched)
        [void](Replace-AsarFileContent $ResourcesPath $asarTarget $patchedContent)
        $action = if ($hadExisting) { "refreshed" } else { "patched" }
        Write-Host "  $action online claude.ai DOM translation: $($mapping.Count) strings" -ForegroundColor Green
    }
    Patch-OnlineLocaleLock $ResourcesPath $Language
}

function Patch-HardcodedFrontendStrings {
    param(
        [string]$ResourcesPath,
        [string]$Language
    )

    $assetsDir = Join-Path $ResourcesPath "ion-dist\assets\v1"
    $jsFiles = @(Get-ChildItem (Join-Path $assetsDir "*.js") -ErrorAction SilentlyContinue)
    if ($jsFiles.Count -eq 0) {
        throw "未找到前端 JS bundle: $assetsDir"
    }

    $replacements = @(Get-FrontendHardcodedReplacements $Language)
    $patchedFiles = 0
    $patchedStrings = 0
    $fileIndex = 0
    foreach ($file in $jsFiles) {
        $fileIndex += 1
        $text = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
        $patched = $text
        $count = 0
        foreach ($pair in $replacements) {
            $source = $pair[0]
            $target = $pair[1]
            if (-not $patched.Contains($source)) {
                continue
            }
            $result = Replace-FrontendHardcodedText $patched $source $target
            if ($result["Count"] -gt 0) {
                $patched = $result["Text"]
                $count += $result["Count"]
            }
        }

        if ($patched -ne $text) {
            Backup-ModifiedFile $ResourcesPath $file.FullName
            [System.IO.File]::WriteAllText($file.FullName, $patched, $Utf8NoBom)
            $patchedFiles += 1
            $patchedStrings += $count
            Write-Host "  patched file $fileIndex/$($jsFiles.Count): $($file.Name) ($count replacements)" -ForegroundColor DarkGray
        } else {
            Write-Host "  skipping file $fileIndex/$($jsFiles.Count): $($file.Name) (no matches)" -ForegroundColor DarkGray
        }
    }

    Write-Host "  patched hardcoded frontend strings: $patchedStrings replacements in $patchedFiles files" -ForegroundColor Green
}

function Get-MainProcessMenuRoleReplacementPairs {
    param([string]$Language)

    switch ($Language) {
        "zh-CN" {
            return @(
                @("about", "关于..."),
                @("close", "关闭窗口"),
                @("copy", "复制"),
                @("cut", "剪切"),
                @("find", "查找"),
                @("findNext", "查找下一个"),
                @("findPrevious", "查找上一个"),
                @("forceReload", "强制重新加载"),
                @("paste", "粘贴"),
                @("preferences", "设置..."),
                @("quit", "退出"),
                @("redo", "重做"),
                @("reload", "重新加载"),
                @("resetZoom", "实际大小"),
                @("selectAll", "全选"),
                @("settings", "设置..."),
                @("undo", "撤销"),
                @("zoomIn", "放大"),
                @("zoomOut", "缩小")
            )
        }
        "zh-TW" {
            return @(
                @("about", "關於..."),
                @("close", "關閉視窗"),
                @("copy", "複製"),
                @("cut", "剪下"),
                @("find", "尋找"),
                @("findNext", "尋找下一個"),
                @("findPrevious", "尋找上一個"),
                @("forceReload", "強制重新載入"),
                @("paste", "貼上"),
                @("preferences", "設定..."),
                @("quit", "結束"),
                @("redo", "重做"),
                @("reload", "重新載入"),
                @("resetZoom", "實際大小"),
                @("selectAll", "全選"),
                @("settings", "設定..."),
                @("undo", "復原"),
                @("zoomIn", "放大"),
                @("zoomOut", "縮小")
            )
        }
        "zh-HK" {
            return @(
                @("about", "關於..."),
                @("close", "關閉視窗"),
                @("copy", "複製"),
                @("cut", "剪下"),
                @("find", "尋找"),
                @("findNext", "尋找下一個"),
                @("findPrevious", "尋找上一個"),
                @("forceReload", "強制重新載入"),
                @("paste", "貼上"),
                @("preferences", "設定..."),
                @("quit", "結束"),
                @("redo", "重做"),
                @("reload", "重新載入"),
                @("resetZoom", "實際大小"),
                @("selectAll", "全選"),
                @("settings", "設定..."),
                @("undo", "還原"),
                @("zoomIn", "放大"),
                @("zoomOut", "縮小")
            )
        }
        default {
            throw "Unsupported language for main-process menu roles: $Language"
        }
    }
}

function Convert-PairsToHashtable {
    param([object[]]$Pairs)

    $map = [ordered]@{}
    foreach ($pair in $Pairs) {
        $map[$pair[0]] = $pair[1]
    }
    return $map
}

function Get-MenuRuntimePatch {
    param(
        [object[]]$LabelPairs,
        [object[]]$RolePairs
    )

    $labelJson = Convert-PairsToHashtable $LabelPairs | ConvertTo-Json -Compress -Depth 20
    $roleJson = Convert-PairsToHashtable $RolePairs | ConvertTo-Json -Compress -Depth 20
    return ';(()=>{try{const e=require("electron"),M=' + $labelJson + ',R=' + $roleJson + ';if(!e||!e.Menu||e.Menu.__claudeZhMenuRuntimePatch)return;const n=s=>String(s||"").replace(/\u2026/g,"...").trim(),t=s=>M[s]||M[n(s)]||M[String(s||"").replace(/\.\.\.$/,"…")];function w(a){if(!Array.isArray(a))return;for(const i of a){if(!i||typeof i!=="object")continue;if(i.label){const l=t(i.label);if(l)i.label=l}const r=i.role==null?"":String(i.role),k=R[r]||R[r.charAt(0).toLowerCase()+r.slice(1)]||R[r.toLowerCase()];if(!i.label&&k)i.label=k;if(Array.isArray(i.submenu))w(i.submenu)}}const b=e.Menu.buildFromTemplate;e.Menu.buildFromTemplate=function(a){try{w(a)}catch{}return b.call(this,a)};if(e.MenuItem&&!e.MenuItem.__claudeZhMenuRuntimePatch){const I=e.MenuItem;e.MenuItem=function(o){try{w([o])}catch{}return new I(o)};e.MenuItem.prototype=I.prototype;Object.setPrototypeOf(e.MenuItem,I);Object.defineProperty(e.MenuItem,"__claudeZhMenuRuntimePatch",{value:!0})}Object.defineProperty(e.Menu,"__claudeZhMenuRuntimePatch",{value:!0})}catch{}})();/*' + $MenuRuntimeMarker + '*/'
}

function Patch-HardcodedMainProcessMenuLabels {
    param(
        [string]$ResourcesPath,
        [string]$Language
    )

    $asarPath = Join-Path $ResourcesPath "app.asar"
    Require-File $asarPath
    switch ($Language) {
        "zh-CN" {
            $replacements = @(
                @("File", "文件"),
                @("Edit", "编辑"),
                @("View", "查看"),
                @("Developer", "开发者"),
                @("Help", "帮助"),
                @("New Conversation", "新对话"),
                @("Settings…", "设置…"),
                @("Settings...", "设置..."),
                @("Close Window", "关闭窗口"),
                @("Exit", "退出"),
                @("Undo", "撤销"),
                @("Redo", "重做"),
                @("Cut", "剪切"),
                @("Copy", "复制"),
                @("Paste", "粘贴"),
                @("Select All", "全选"),
                @("Find", "查找"),
                @("Find Next", "查找下一个"),
                @("Find Previous", "查找上一个"),
                @("Reload", "重新加载"),
                @("Actual Size", "实际大小"),
                @("Zoom In", "放大"),
                @("Zoom Out", "缩小"),
                @("Copy URL", "复制 URL"),
                @("Extensions", "扩展"),
                @("Install Extension…", "安装扩展…"),
                @("Install Extension...", "安装扩展..."),
                @("Install Unpacked Extension…", "安装未打包的扩展…"),
                @("Install Unpacked Extension...", "安装未打包的扩展..."),
                @("Open Extensions Folder…", "打开扩展文件夹…"),
                @("Open Extensions Folder...", "打开扩展文件夹..."),
                @("Open Extension Settings Folder…", "打开扩展设置文件夹…"),
                @("Open Extension Settings Folder...", "打开扩展设置文件夹..."),
                @("Open Developer Config File…", "打开开发者配置文件…"),
                @("Open Developer Config File...", "打开开发者配置文件..."),
                @("Configure Third-Party Inference…", "配置第三方推理…"),
                @("Configure Third-Party Inference...", "配置第三方推理..."),
                @("Open App Config File…", "打开应用配置文件…"),
                @("Open App Config File...", "打开应用配置文件..."),
                @("Reload MCP Configuration", "重新加载 MCP 配置"),
                @("Open MCP Log File", "打开 MCP 日志文件"),
                @("Open MCP Log File…", "打开 MCP 日志文件…"),
                @("Open MCP Log File...", "打开 MCP 日志文件..."),
                @("Open Hardware Buddy…", "打开硬件伙伴…"),
                @("Open Hardware Buddy...", "打开硬件伙伴..."),
                @("Show All Dev Tools", "显示所有开发者工具"),
                @("Show Dev Tools", "显示开发者工具"),
                @("Enable Main Process Debugger", "启用主进程调试器"),
                @("Record Performance Trace", "记录性能跟踪"),
                @("Write Main Process Heap Snapshot", "写入主进程堆快照"),
                @("Record Memory Trace (auto-stop)", "记录内存跟踪 (自动)"),
                @("Open Documentation", "打开文档"),
                @("Check for Updates…", "检查更新…"),
                @("Check for Updates...", "检查更新..."),
                @("Troubleshooting", "故障排除"),
                @("Get Support", "获取支持"),
                @("About…", "关于…"),
                @("About...", "关于...")
            )
            $intlReplacements = @(
                @("0tZLEYF8mJ", "开发者"),
                @("/PgA81GVOD", "编辑"),
                @("LCWUQ/4Fu6", "查看"),
                @("uc3dnSo+eo", "文件"),
                @("EfdnINFnIz", "文件"),
                @("pWXxZASpOB", "帮助"),
                @("JOf7G+dCf1", "打开应用配置文件..."),
                @("K5GtyaPaw/", "打开开发者配置文件..."),
                @("RTg057HE1D", "显示开发者工具"),
                @("STqYpFr7p4", "显示所有开发者工具"),
                @("rNAd+HxSK4", "打开 MCP 日志文件"),
                @("PW5U8NgTto", "打开 MCP 日志文件..."),
                @("uKCcuVd1Yt", "重新加载 MCP 配置"),
                @("9GRz7bC+rr", "配置第三方推理…"),
                @("baGq3gy8z1", "新对话"),
                @("ODySlGptaj", "设置…"),
                @("IHsCTXnnSv", "关闭窗口"),
                @("7fdcqxofEs", "退出"),
                @("dKX0bpR+a2", "退出"),
                @("Xda79B7DPP", "撤销"),
                @("fFJxOwJRj2", "撤销"),
                @("R0/CZEcsoI", "重做"),
                @("3ML3xT+gEV", "重做"),
                @("TH+W2Ad73P", "剪切"),
                @("4MLbtbVfJv", "剪切"),
                @("+7sd9hoyZA", "复制"),
                @("3unrKzH4zB", "复制"),
                @("JVwNvMZjVT", "粘贴"),
                @("KAo3lt5Hv+", "粘贴"),
                @("8YQEOfuaGO", "全选"),
                @("grarAzxOkG", "全选"),
                @("O3rtEd7aMd", "查找"),
                @("Ko/2Ml7mZG", "重新加载此页面"),
                @("+/cwsayrqk", "实际大小"),
                @("Z9g5m/V9Nq", "放大"),
                @("XZ36+EBE5/", "缩小"),
                @("WvMIEFradI", "复制链接"),
                @("l6/rglN9Fm", "复制 URL"),
                @("YgfdkMAdfQ", "打开硬件伙伴…"),
                @("Q0f46SlJw", "扩展"),
                @("j66cdL4EK5", "打开文档"),
                @("mRXjxhS6p4", "检查更新…"),
                @("4XmExNuKUb", "故障排除"),
                @("XfMPtFNO8C", "获取支持"),
                @("5DUIVR3fVi", "关于...")
            )
        }
        "zh-TW" {
            $replacements = @(
                @("File", "檔案"),
                @("Edit", "編輯"),
                @("View", "檢視"),
                @("Developer", "開發者"),
                @("Help", "說明"),
                @("New Conversation", "新對話"),
                @("Settings…", "設定…"),
                @("Settings...", "設定..."),
                @("Close Window", "關閉視窗"),
                @("Exit", "結束"),
                @("Undo", "復原"),
                @("Redo", "重做"),
                @("Cut", "剪下"),
                @("Copy", "複製"),
                @("Paste", "貼上"),
                @("Select All", "全選"),
                @("Find", "尋找"),
                @("Find Next", "尋找下一個"),
                @("Find Previous", "尋找上一個"),
                @("Reload", "重新載入"),
                @("Actual Size", "實際大小"),
                @("Zoom In", "放大"),
                @("Zoom Out", "縮小"),
                @("Copy URL", "複製 URL"),
                @("Extensions", "擴充功能"),
                @("Install Extension…", "安裝擴充功能…"),
                @("Install Extension...", "安裝擴充功能..."),
                @("Install Unpacked Extension…", "安裝未封裝的擴充功能…"),
                @("Install Unpacked Extension...", "安裝未封裝的擴充功能..."),
                @("Open Extensions Folder…", "開啟擴充功能資料夾…"),
                @("Open Extensions Folder...", "開啟擴充功能資料夾..."),
                @("Open Extension Settings Folder…", "開啟擴充功能設定資料夾…"),
                @("Open Extension Settings Folder...", "開啟擴充功能設定資料夾..."),
                @("Open Developer Config File…", "開啟開發者設定檔…"),
                @("Open Developer Config File...", "開啟開發者設定檔..."),
                @("Configure Third-Party Inference…", "設定第三方推理…"),
                @("Configure Third-Party Inference...", "設定第三方推理..."),
                @("Open App Config File…", "開啟應用程式設定檔…"),
                @("Open App Config File...", "開啟應用程式設定檔..."),
                @("Reload MCP Configuration", "重新載入 MCP 設定"),
                @("Open MCP Log File", "開啟 MCP 記錄檔"),
                @("Open MCP Log File…", "開啟 MCP 記錄檔…"),
                @("Open MCP Log File...", "開啟 MCP 記錄檔..."),
                @("Open Hardware Buddy…", "開啟硬體夥伴…"),
                @("Open Hardware Buddy...", "開啟硬體夥伴..."),
                @("Show All Dev Tools", "顯示所有開發者工具"),
                @("Show Dev Tools", "顯示開發者工具"),
                @("Enable Main Process Debugger", "啟用主行程偵錯器"),
                @("Record Performance Trace", "記錄效能追蹤"),
                @("Write Main Process Heap Snapshot", "寫入主行程堆積快照"),
                @("Record Memory Trace (auto-stop)", "記錄記憶體追蹤 (自動)"),
                @("Open Documentation", "開啟文件"),
                @("Check for Updates…", "檢查更新…"),
                @("Check for Updates...", "檢查更新..."),
                @("Troubleshooting", "疑難排解"),
                @("Get Support", "取得支援"),
                @("About…", "關於…"),
                @("About...", "關於...")
            )
            $intlReplacements = @(
                @("0tZLEYF8mJ", "開發者"),
                @("/PgA81GVOD", "編輯"),
                @("LCWUQ/4Fu6", "檢視"),
                @("uc3dnSo+eo", "檔案"),
                @("EfdnINFnIz", "檔案"),
                @("pWXxZASpOB", "說明"),
                @("JOf7G+dCf1", "開啟應用程式設定檔..."),
                @("K5GtyaPaw/", "開啟開發者設定檔..."),
                @("RTg057HE1D", "顯示開發者工具"),
                @("STqYpFr7p4", "顯示所有開發者工具"),
                @("rNAd+HxSK4", "開啟 MCP 記錄檔"),
                @("PW5U8NgTto", "開啟 MCP 記錄檔..."),
                @("uKCcuVd1Yt", "重新載入 MCP 設定"),
                @("9GRz7bC+rr", "設定第三方推理…"),
                @("baGq3gy8z1", "新對話"),
                @("ODySlGptaj", "設定…"),
                @("IHsCTXnnSv", "關閉視窗"),
                @("7fdcqxofEs", "結束"),
                @("dKX0bpR+a2", "結束"),
                @("Xda79B7DPP", "復原"),
                @("fFJxOwJRj2", "復原"),
                @("R0/CZEcsoI", "重做"),
                @("3ML3xT+gEV", "重做"),
                @("TH+W2Ad73P", "剪下"),
                @("4MLbtbVfJv", "剪下"),
                @("+7sd9hoyZA", "複製"),
                @("3unrKzH4zB", "複製"),
                @("JVwNvMZjVT", "貼上"),
                @("KAo3lt5Hv+", "貼上"),
                @("8YQEOfuaGO", "全選"),
                @("grarAzxOkG", "全選"),
                @("O3rtEd7aMd", "尋找"),
                @("Ko/2Ml7mZG", "重新載入此頁面"),
                @("+/cwsayrqk", "實際大小"),
                @("Z9g5m/V9Nq", "放大"),
                @("XZ36+EBE5/", "縮小"),
                @("WvMIEFradI", "複製連結"),
                @("l6/rglN9Fm", "複製 URL"),
                @("YgfdkMAdfQ", "開啟硬體夥伴…"),
                @("Q0f46SlJw", "擴充功能"),
                @("j66cdL4EK5", "開啟文件"),
                @("mRXjxhS6p4", "檢查更新…"),
                @("4XmExNuKUb", "疑難排解"),
                @("XfMPtFNO8C", "取得支援"),
                @("5DUIVR3fVi", "關於...")
            )
        }
        "zh-HK" {
            $replacements = @(
                @("File", "檔案"),
                @("Edit", "編輯"),
                @("View", "檢視"),
                @("Developer", "開發者"),
                @("Help", "說明"),
                @("New Conversation", "新對話"),
                @("Settings…", "設定…"),
                @("Settings...", "設定..."),
                @("Close Window", "關閉視窗"),
                @("Exit", "結束"),
                @("Undo", "還原"),
                @("Redo", "重做"),
                @("Cut", "剪下"),
                @("Copy", "複製"),
                @("Paste", "貼上"),
                @("Select All", "全選"),
                @("Find", "尋找"),
                @("Find Next", "尋找下一個"),
                @("Find Previous", "尋找上一個"),
                @("Reload", "重新載入"),
                @("Actual Size", "實際大小"),
                @("Zoom In", "放大"),
                @("Zoom Out", "縮小"),
                @("Copy URL", "複製 URL"),
                @("Extensions", "擴充功能"),
                @("Install Extension…", "安裝擴充功能…"),
                @("Install Extension...", "安裝擴充功能..."),
                @("Install Unpacked Extension…", "安裝未封裝的擴充功能…"),
                @("Install Unpacked Extension...", "安裝未封裝的擴充功能..."),
                @("Open Extensions Folder…", "開啟擴充功能資料夾…"),
                @("Open Extensions Folder...", "開啟擴充功能資料夾..."),
                @("Open Extension Settings Folder…", "開啟擴充功能設定資料夾…"),
                @("Open Extension Settings Folder...", "開啟擴充功能設定資料夾..."),
                @("Open Developer Config File…", "開啟開發者設定檔…"),
                @("Open Developer Config File...", "開啟開發者設定檔..."),
                @("Configure Third-Party Inference…", "設定第三方推理…"),
                @("Configure Third-Party Inference...", "設定第三方推理..."),
                @("Open App Config File…", "開啟應用程式設定檔…"),
                @("Open App Config File...", "開啟應用程式設定檔..."),
                @("Reload MCP Configuration", "重新載入 MCP 設定"),
                @("Open MCP Log File", "開啟 MCP 記錄檔"),
                @("Open MCP Log File…", "開啟 MCP 記錄檔…"),
                @("Open MCP Log File...", "開啟 MCP 記錄檔..."),
                @("Open Hardware Buddy…", "開啟硬件夥伴…"),
                @("Open Hardware Buddy...", "開啟硬件夥伴..."),
                @("Show All Dev Tools", "顯示所有開發者工具"),
                @("Show Dev Tools", "顯示開發者工具"),
                @("Enable Main Process Debugger", "啟用主行程偵錯器"),
                @("Record Performance Trace", "記錄效能追蹤"),
                @("Write Main Process Heap Snapshot", "寫入主行程堆積快照"),
                @("Record Memory Trace (auto-stop)", "記錄記憶體追蹤 (自動)"),
                @("Open Documentation", "開啟文件"),
                @("Check for Updates…", "檢查更新…"),
                @("Check for Updates...", "檢查更新..."),
                @("Troubleshooting", "疑難排解"),
                @("Get Support", "取得支援"),
                @("About…", "關於…"),
                @("About...", "關於...")
            )
            $intlReplacements = @(
                @("0tZLEYF8mJ", "開發者"),
                @("/PgA81GVOD", "編輯"),
                @("LCWUQ/4Fu6", "檢視"),
                @("uc3dnSo+eo", "檔案"),
                @("EfdnINFnIz", "檔案"),
                @("pWXxZASpOB", "說明"),
                @("JOf7G+dCf1", "開啟應用程式設定檔..."),
                @("K5GtyaPaw/", "開啟開發者設定檔..."),
                @("RTg057HE1D", "顯示開發者工具"),
                @("STqYpFr7p4", "顯示所有開發者工具"),
                @("rNAd+HxSK4", "開啟 MCP 記錄檔"),
                @("PW5U8NgTto", "開啟 MCP 記錄檔..."),
                @("uKCcuVd1Yt", "重新載入 MCP 設定"),
                @("9GRz7bC+rr", "設定第三方推理…"),
                @("baGq3gy8z1", "新對話"),
                @("ODySlGptaj", "設定…"),
                @("IHsCTXnnSv", "關閉視窗"),
                @("7fdcqxofEs", "結束"),
                @("dKX0bpR+a2", "結束"),
                @("Xda79B7DPP", "還原"),
                @("fFJxOwJRj2", "還原"),
                @("R0/CZEcsoI", "重做"),
                @("3ML3xT+gEV", "重做"),
                @("TH+W2Ad73P", "剪下"),
                @("4MLbtbVfJv", "剪下"),
                @("+7sd9hoyZA", "複製"),
                @("3unrKzH4zB", "複製"),
                @("JVwNvMZjVT", "貼上"),
                @("KAo3lt5Hv+", "貼上"),
                @("8YQEOfuaGO", "全選"),
                @("grarAzxOkG", "全選"),
                @("O3rtEd7aMd", "尋找"),
                @("Ko/2Ml7mZG", "重新載入此頁面"),
                @("+/cwsayrqk", "實際大小"),
                @("Z9g5m/V9Nq", "放大"),
                @("XZ36+EBE5/", "縮小"),
                @("WvMIEFradI", "複製連結"),
                @("l6/rglN9Fm", "複製 URL"),
                @("YgfdkMAdfQ", "開啟硬件夥伴…"),
                @("Q0f46SlJw", "擴充功能"),
                @("j66cdL4EK5", "開啟文件"),
                @("mRXjxhS6p4", "檢查更新…"),
                @("4XmExNuKUb", "疑難排解"),
                @("XfMPtFNO8C", "取得支援"),
                @("5DUIVR3fVi", "關於...")
            )
        }
        default {
            throw "Unsupported language for main-process menu labels: $Language"
        }
    }

    $data = [System.IO.File]::ReadAllBytes($asarPath)
    $parsed = Read-AsarHeader $data $asarPath
    $headerSize = $parsed["HeaderSize"]
    $header = $parsed["Header"]
    $asarTarget = Resolve-MainProcessAsarTarget $data $headerSize $header
    $entry = Get-AsarFileEntry $header $asarTarget
    $content = Get-AsarEntryContent $data $headerSize $entry $asarTarget
    $text = [System.Text.Encoding]::UTF8.GetString($content)
    $patched = $text
    $count = 0
    $intlCount = 0
    $runtimeCount = 0
    $repairCount = 0

    $runtimePattern = ';\(\(\)=>\{try\{const e=require\("electron"\),M=.*?/\*' + [regex]::Escape($MenuRuntimeMarker) + '\*/'
    $script:__menuRuntimeRemovedCount = 0
    $patched = [regex]::Replace(
        $patched,
        $runtimePattern,
        {
            param($match)
            $script:__menuRuntimeRemovedCount += 1
            return ""
        },
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )

    $unsafeRepairs = @(
        @("文件", "File"),
        @("檔案", "File"),
        @("编辑", "Edit"),
        @("編輯", "Edit"),
        @("查看", "View"),
        @("檢視", "View"),
        @("帮助", "Help"),
        @("說明", "Help"),
        @("开发者", "Developer"),
        @("開發者", "Developer"),
        @("扩展", "Extensions"),
        @("擴充功能", "Extensions")
    )
    foreach ($pair in $unsafeRepairs) {
        $source = $pair[0]
        $target = $pair[1]
        $pattern = '(?<quote>["' + "'" + '`])' + [regex]::Escape($source) + '\k<quote>'
        $script:__menuRepairCount = 0
        $patched = [regex]::Replace(
            $patched,
            $pattern,
            {
                param($match)
                $script:__menuRepairCount += 1
                return $match.Groups["quote"].Value + $target + $match.Groups["quote"].Value
            }
        )
        $repairCount += $script:__menuRepairCount
        $script:__menuRepairCount = 0
    }

    foreach ($pair in $intlReplacements) {
        $id = $pair[0]
        $target = $pair[1]
        $literal = ConvertTo-Json $target -Compress
        $needle = 'id:"' + $id + '"'
        $searchStart = 0
        while ($true) {
            $idIndex = $patched.IndexOf($needle, $searchStart, [System.StringComparison]::Ordinal)
            if ($idIndex -lt 0) {
                break
            }

            $callStart = $patched.LastIndexOf(".formatMessage({", $idIndex, [System.StringComparison]::Ordinal)
            if ($callStart -lt 0) {
                $searchStart = $idIndex + $needle.Length
                continue
            }

            $receiverStart = $callStart - 1
            while ($receiverStart -ge 0) {
                $ch = $patched[$receiverStart]
                $isCallChar = (($ch -ge 'a') -and ($ch -le 'z')) -or (($ch -ge 'A') -and ($ch -le 'Z')) -or (($ch -ge '0') -and ($ch -le '9')) -or ($ch -eq '_') -or ($ch -eq '$') -or ($ch -eq '.') -or ($ch -eq '(') -or ($ch -eq ')')
                if (-not $isCallChar) {
                    break
                }
                $receiverStart -= 1
            }
            $receiverStart += 1

            $callEnd = $patched.IndexOf("})", $idIndex, [System.StringComparison]::Ordinal)
            if ($callEnd -lt 0) {
                $searchStart = $idIndex + $needle.Length
                continue
            }
            $absoluteStart = $receiverStart
            $absoluteEnd = $callEnd + 2
            $callText = $patched.Substring($absoluteStart, $absoluteEnd - $absoluteStart)
            if ((-not $callText.Contains("formatMessage({")) -or (-not $callText.Contains($needle))) {
                $searchStart = $idIndex + $needle.Length
                continue
            }

            $patched = $patched.Substring(0, $absoluteStart) + $literal + $patched.Substring($absoluteEnd)
            $intlCount += 1
            $searchStart = $absoluteStart + $literal.Length
        }
    }

    foreach ($pair in $replacements) {
        $source = $pair[0]
        $target = $pair[1]
        if (-not $patched.Contains($source)) {
            continue
        }

        $pattern = '(?<prefix>(?<![A-Za-z0-9_$])(?:label|defaultMessage)\s*:\s*)(?<quote>["' + "'" + '`])' + [regex]::Escape($source) + '\k<quote>'
        $script:__menuReplacementCount = 0
        $patched = [regex]::Replace(
            $patched,
            $pattern,
            {
                param($match)
                $script:__menuReplacementCount += 1
                return $match.Groups["prefix"].Value + $match.Groups["quote"].Value + $target + $match.Groups["quote"].Value
            }
        )
        $occurrences = $script:__menuReplacementCount
        $script:__menuReplacementCount = 0
        $count += $occurrences
    }

    if (-not $patched.Contains($MenuRuntimeMarker)) {
        $patched = (Get-MenuRuntimePatch $replacements (Get-MainProcessMenuRoleReplacementPairs $Language)) + $patched
        $runtimeCount = 1
    }
    elseif ($script:__menuRuntimeRemovedCount -gt 0) {
        $runtimeCount = 1
    }
    $script:__menuRuntimeRemovedCount = 0

    if (($count -eq 0) -and ($intlCount -eq 0) -and ($runtimeCount -eq 0) -and ($repairCount -eq 0)) {
        Write-Host "  hardcoded main-process menu labels already patched" -ForegroundColor Green
        return
    }
    if (($count -eq 0) -and ($intlCount -eq 0) -and ($runtimeCount -eq 0)) {
        throw "Could not patch main-process menu labels; Claude's menu bundle format may have changed."
    }

    $patchedContent = [System.Text.Encoding]::UTF8.GetBytes($patched)
    Replace-AsarFileContent $ResourcesPath $asarTarget $patchedContent | Out-Null
    if ($repairCount -gt 0) {
        Write-Host "  repaired unsafe short main-process menu replacements: $repairCount occurrences" -ForegroundColor Yellow
    }
    Write-Host "  patched hardcoded main-process menu labels: $($count + $intlCount) replacements, runtime patch: $runtimeCount" -ForegroundColor Green
}

function Get-ModelPickerReplacementPairs {
    param([string]$Language)

    switch ($Language) {
        "zh-CN" {
            return @(
                @("Higher effort means more thorough responses, but takes longer and uses your limits faster.", "更高的思考深度会带来更全面的回答，但耗时更久，也会更快消耗你的额度。"),
                @("May use excessive tokens resulting in long response times and may hit token limits. Use sparingly for the hardest tasks.", "可能会消耗大量 token，导致响应时间很长，也可能触及 token 限制。请仅在最困难的任务中谨慎使用。"),
                @("Most capable for ambitious work", "适合高难度工作的最强模型"),
                @("1M context window", "100 万上下文窗口"),
                @("name:`"Low`"", "name:`"低`""),
                @("name:`"Medium`"", "name:`"中`""),
                @("name:`"High`"", "name:`"高`""),
                @("name:`"Extra`"", "name:`"极高`""),
                @("name:`"Max`"", "name:`"最高`""),
                @("message:`"Default`"", "message:`"默认`"")
            )
        }
        "zh-TW" {
            return @(
                @("Higher effort means more thorough responses, but takes longer and uses your limits faster.", "更高的思考深度會帶來更全面的回應，但耗時更久，也會更快消耗你的額度。"),
                @("May use excessive tokens resulting in long response times and may hit token limits. Use sparingly for the hardest tasks.", "可能會消耗大量 token，導致回應時間很長，也可能觸及 token 限制。請僅在最困難的任務中謹慎使用。"),
                @("Most capable for ambitious work", "適合高難度工作的最強模型"),
                @("1M context window", "100 萬上下文視窗"),
                @("name:`"Low`"", "name:`"低`""),
                @("name:`"Medium`"", "name:`"中`""),
                @("name:`"High`"", "name:`"高`""),
                @("name:`"Extra`"", "name:`"極高`""),
                @("name:`"Max`"", "name:`"最高`""),
                @("message:`"Default`"", "message:`"預設`"")
            )
        }
        "zh-HK" {
            return @(
                @("Higher effort means more thorough responses, but takes longer and uses your limits faster.", "更高的思考深度會帶來更全面的回應，但耗時更久，也會更快消耗你的額度。"),
                @("May use excessive tokens resulting in long response times and may hit token limits. Use sparingly for the hardest tasks.", "可能會消耗大量 token，導致回應時間很長，也可能觸及 token 限制。請僅在最困難的任務中謹慎使用。"),
                @("Most capable for ambitious work", "適合高難度工作的最強模型"),
                @("1M context window", "100 萬上下文視窗"),
                @("name:`"Low`"", "name:`"低`""),
                @("name:`"Medium`"", "name:`"中`""),
                @("name:`"High`"", "name:`"高`""),
                @("name:`"Extra`"", "name:`"極高`""),
                @("name:`"Max`"", "name:`"最高`""),
                @("message:`"Default`"", "message:`"預設`"")
            )
        }
        default { throw "Unsupported language for model picker replacements: $Language" }
    }
}

function Patch-ModelPickerStrings {
    param(
        [string]$ResourcesPath,
        [string]$Language
    )

    $asarPath = Join-Path $ResourcesPath "app.asar"
    Require-File $asarPath

    $data = [System.IO.File]::ReadAllBytes($asarPath)
    $parsed = Read-AsarHeader $data $asarPath
    $headerSize = $parsed["HeaderSize"]
    $header = $parsed["Header"]
    $asarTarget = Resolve-MainProcessAsarTarget $data $headerSize $header
    $entry = Get-AsarFileEntry $header $asarTarget
    $contentBytes = Get-AsarEntryContent $data $headerSize $entry $asarTarget
    $text = [System.Text.Encoding]::UTF8.GetString($contentBytes)
    $patched = $text
    $count = 0
    $pairs = @(Get-ModelPickerReplacementPairs $Language | Sort-Object -Property @{ Expression = { $_[0].Length }; Descending = $true })
    foreach ($pair in $pairs) {
        $source = $pair[0]
        $target = $pair[1]
        $occurrences = [System.Text.RegularExpressions.Regex]::Matches($patched, [System.Text.RegularExpressions.Regex]::Escape($source)).Count
        if ($occurrences -gt 0) {
            $patched = $patched.Replace($source, $target)
            $count += $occurrences
        }
    }

    if ($count -eq 0) {
        Write-Host "  hardcoded model picker strings already patched or not present" -ForegroundColor Green
        return
    }

    [void](Replace-AsarFileContent $ResourcesPath $asarTarget ([System.Text.Encoding]::UTF8.GetBytes($patched)))
    Write-Host "  patched hardcoded model picker strings in app.asar: $count replacements" -ForegroundColor Green
}

function Set-ClaudeLocale {
    param([string]$Locale)

    if (-not $env:LOCALAPPDATA) {
        Write-Host "  [警告] LOCALAPPDATA 未设置，跳过用户配置。" -ForegroundColor DarkYellow
        return
    }

    $configPaths = Get-ClaudeConfigPaths
    if ($configPaths.Count -eq 0) {
        Write-Host "  [警告] 未找到 Claude 用户配置目录，跳过用户配置。" -ForegroundColor DarkYellow
        return
    }

    foreach ($configPath in $configPaths) {
        $parent = Split-Path -Parent $configPath
        New-Item -ItemType Directory -Path $parent -Force | Out-Null

        $config = [pscustomobject]@{}
        if (Test-Path $configPath) {
            try {
                $loaded = Get-Content $configPath -Raw | ConvertFrom-Json
                if ($loaded) {
                    $config = $loaded
                }
            }
            catch {
                $backup = "$configPath.bak-invalid"
                Copy-Item $configPath $backup -Force
                Write-Host "  invalid JSON backed up: $backup" -ForegroundColor DarkYellow
            }
        }

        $config | Add-Member -NotePropertyName "locale" -NotePropertyValue $Locale -Force
        Save-JsonNoBom $configPath $config
        Write-Host "  locale=${Locale}: $configPath" -ForegroundColor Green
    }
}

function Get-ThirdPartyConfigLibraryPaths {
    $paths = @()
    $appDataRoots = @()
    $localAppDataRoots = @()
    if ($env:APPDATA) {
        $appDataRoots += $env:APPDATA
    }
    if ($env:CLAUDE_ZH_ORIGINAL_APPDATA) {
        $appDataRoots += $env:CLAUDE_ZH_ORIGINAL_APPDATA
    }
    if ($env:LOCALAPPDATA) {
        $localAppDataRoots += $env:LOCALAPPDATA
    }
    if ($env:CLAUDE_ZH_ORIGINAL_LOCALAPPDATA) {
        $localAppDataRoots += $env:CLAUDE_ZH_ORIGINAL_LOCALAPPDATA
    }
    if ($env:CLAUDE_ZH_ORIGINAL_USER_PROFILE) {
        $appDataRoots += Join-Path $env:CLAUDE_ZH_ORIGINAL_USER_PROFILE "AppData\Roaming"
        $localAppDataRoots += Join-Path $env:CLAUDE_ZH_ORIGINAL_USER_PROFILE "AppData\Local"
    }

    foreach ($localAppData in @($localAppDataRoots | Select-Object -Unique)) {
        $paths += Join-Path $localAppData "Claude-3p\configLibrary"
    }

    foreach ($localAppData in @($localAppDataRoots | Select-Object -Unique)) {
        $packageRoot = Join-Path $localAppData "Packages"
        $packageDirs = @(Get-ChildItem (Join-Path $packageRoot "Claude_*") -Directory -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending)
        foreach ($packageDir in $packageDirs) {
            $paths += Join-Path $packageDir.FullName "LocalCache\Roaming\Claude-3p\configLibrary"
        }
    }

    foreach ($appData in @($appDataRoots | Select-Object -Unique)) {
        $paths += Join-Path $appData "Claude-3p\configLibrary"
    }

    return @($paths | Select-Object -Unique)
}

function Get-JsonObjectOrBackup {
    param([string]$Path)

    if (-not (Test-Path $Path -PathType Leaf)) {
        return [pscustomobject]@{}
    }

    try {
        $loaded = Get-Content $Path -Raw | ConvertFrom-Json
        if ($loaded -is [pscustomobject]) {
            return $loaded
        }
        throw "JSON root is not an object."
    }
    catch {
        $backup = "$Path.bak-invalid"
        Copy-Item $Path $backup -Force
        return [pscustomobject]@{}
    }
}

function Save-JsonNoBom {
    param(
        [string]$Path,
        [object]$Value,
        [int]$Depth = 20
    )

    $json = $Value | ConvertTo-Json -Depth $Depth
    [System.IO.File]::WriteAllText($Path, $json, $Utf8NoBom)
}

function Test-ThirdPartyApiConfig {
    param([object]$Config)

    if ($null -eq $Config) {
        return $false
    }

    foreach ($name in @(
        "inferenceGatewayApiKey",
        "inferenceGatewayBaseUrl",
        "inferenceGatewayAuthScheme",
        "inferenceProvider"
    )) {
        if (($Config.PSObject.Properties.Name -contains $name) -and ([string]$Config.$name).Trim()) {
            return $true
        }
    }

    return $false
}

function Add-OrSetJsonProperty {
    param(
        [pscustomobject]$Object,
        [string]$Name,
        [object]$Value
    )

    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Ensure-ConfigLibraryEntry {
    param(
        [pscustomobject]$Meta,
        [string]$ConfigId
    )

    Add-OrSetJsonProperty $Meta "appliedId" $ConfigId

    $entries = @()
    if ($Meta.PSObject.Properties.Name -contains "entries" -and $Meta.entries) {
        $entries = @($Meta.entries)
    }

    foreach ($entry in $entries) {
        if ($entry -is [pscustomobject] -and [string]$entry.id -eq $ConfigId) {
            Add-OrSetJsonProperty $Meta "entries" $entries
            return
        }
    }

    $entries += [pscustomobject]@{ id = $ConfigId; name = "Default" }
    Add-OrSetJsonProperty $Meta "entries" $entries
}

function Get-ExistingThirdPartyConfigLibraryPaths {
    $paths = @()
    foreach ($configLibrary in @(Get-ThirdPartyConfigLibraryPaths)) {
        $metaPath = Join-Path $configLibrary "_meta.json"
        if (-not (Test-Path $metaPath -PathType Leaf)) {
            continue
        }

        $meta = Get-JsonObjectOrBackup $metaPath
        $configId = ""
        if ($meta.PSObject.Properties.Name -contains "appliedId") {
            $configId = ([string]$meta.appliedId).Trim()
        }
        if (-not $configId) {
            continue
        }

        $configPath = Join-Path $configLibrary "$configId.json"
        if (Test-Path $configPath -PathType Leaf) {
            $config = Get-JsonObjectOrBackup $configPath
            if (Test-ThirdPartyApiConfig $config) {
                $paths += $configLibrary
            }
        }
    }

    return @($paths | Select-Object -Unique)
}

function Set-ThirdPartyConfigAutoUpdates {
    param([bool]$Enabled)

    $libraryPaths = @(Get-ExistingThirdPartyConfigLibraryPaths)
    if ($libraryPaths.Count -eq 0) {
        return $false
    }

    $updatedCount = 0
    foreach ($configLibrary in $libraryPaths) {
        $metaPath = Join-Path $configLibrary "_meta.json"

        $meta = Get-JsonObjectOrBackup $metaPath
        $configId = ""
        if ($meta.PSObject.Properties.Name -contains "appliedId") {
            $configId = ([string]$meta.appliedId).Trim()
        }

        $configPath = Join-Path $configLibrary "$configId.json"
        $config = Get-JsonObjectOrBackup $configPath
        Add-OrSetJsonProperty $config "disableAutoUpdates" (-not $Enabled)
        Ensure-ConfigLibraryEntry $meta $configId

        New-Item -ItemType Directory -Path $configLibrary -Force | Out-Null
        Save-JsonNoBom $configPath $config
        Save-JsonNoBom $metaPath $meta

        $updatedCount++
    }

    Write-Host "  已更新 Claude-3p 配置库自动更新设置: $updatedCount 个配置" -ForegroundColor DarkGray
    return $true
}

function Get-ClaudePolicyRegistryPath {
    $sid = [string]$env:CLAUDE_ZH_ORIGINAL_USER_SID
    if ($sid -and (Test-Path "Registry::HKEY_USERS\$sid")) {
        return "Registry::HKEY_USERS\$sid\SOFTWARE\Policies\Claude"
    }

    return "HKCU:\SOFTWARE\Policies\Claude"
}

function Set-ClaudeManagedAutoUpdates {
    param([bool]$Enabled)

    $policyPath = Get-ClaudePolicyRegistryPath
    if ($Enabled) {
        if (Test-Path $policyPath) {
            Remove-ItemProperty -Path $policyPath -Name "disableAutoUpdates" -ErrorAction SilentlyContinue
        }
        Write-Host "  已移除 Claude Desktop 自动更新禁用策略: $policyPath" -ForegroundColor DarkGray
    } else {
        New-Item -Path $policyPath -Force | Out-Null
        New-ItemProperty -Path $policyPath -Name "disableAutoUpdates" -Value 1 -PropertyType DWord -Force | Out-Null
        Write-Host "  已写入 Claude Desktop 自动更新禁用策略: $policyPath" -ForegroundColor DarkGray
    }
}

function Set-ClaudeAutoUpdates {
    param([bool]$Enabled)

    if (-not (Set-ThirdPartyConfigAutoUpdates $Enabled)) {
        Set-ClaudeManagedAutoUpdates $Enabled
    }

    if ($Enabled) {
        Write-Host "允许更新成功" -ForegroundColor Green
    } else {
        Write-Host "禁止更新成功" -ForegroundColor Green
    }
}

function Get-ClaudeAppUserModelId {
    param([string]$ShortcutPath)

    # 优先从原快捷方式字节中提取 AUMID，如 Claude_pzs8sxrjxfjjc!Claude
    if (Test-Path -LiteralPath $ShortcutPath) {
        try {
            $data = [System.IO.File]::ReadAllBytes($ShortcutPath)
            $text = [System.Text.Encoding]::Unicode.GetString($data)
            $match = [regex]::Match($text, 'Claude_[A-Za-z0-9]+![A-Za-z0-9]+')
            if ($match.Success) {
                return $match.Value
            }
        } catch {
        }
    }

    # 回退：从 AppX 包推导 PackageFamilyName + AppId
    try {
        $package = Get-AppxPackage -Name "Claude" -ErrorAction SilentlyContinue
        if ($package) {
            $manifest = Join-Path $package.InstallLocation "AppxManifest.xml"
            $appId = "Claude"
            if (Test-Path -LiteralPath $manifest) {
                try {
                    $xml = New-Object System.Xml.XmlDocument
                    $xml.Load($manifest)
                    $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
                    $ns.AddNamespace("d", "http://schemas.microsoft.com/appx/manifest/foundation/windows10")
                    $appNode = $xml.SelectSingleNode("//d:Application", $ns)
                    if ($appNode -and $appNode.Id) {
                        $appId = [string]$appNode.Id
                    }
                } catch {
                }
            }
            return "$($package.PackageFamilyName)!$appId"
        }
    } catch {
    }

    return ""
}

function Rebuild-ClaudeDesktopShortcut {
    param(
        [string]$ShortcutPath,
        [string]$ClaudePath
    )

    $aumid = Get-ClaudeAppUserModelId $ShortcutPath
    if (-not $aumid) {
        Write-Host "  [警告] 无法确定 AppUserModelID，跳过快捷方式重建: $ShortcutPath" -ForegroundColor Yellow
        return $false
    }

    $backup = "$ShortcutPath.broken.bak"
    if (-not (Test-Path -LiteralPath $backup)) {
        Copy-Item -LiteralPath $ShortcutPath $backup -Force
        Write-Host "  已备份原快捷方式: $backup" -ForegroundColor DarkGray
    }

    try {
        $iconCandidates = @(
            (Join-Path $ClaudePath "Assets\Square44x44Logo.png"),
            (Join-Path $ClaudePath "Assets\Square150x150Logo.png"),
            (Join-Path $ClaudePath "Assets\icon.png"),
            (Join-Path $ClaudePath "app\claude.exe")
        )
        $iconLocation = ""
        foreach ($candidate in $iconCandidates) {
            if (Test-Path -LiteralPath $candidate) {
                $iconLocation = $candidate
                break
            }
        }

        $ws = New-Object -ComObject WScript.Shell
        $shellShortcut = $ws.CreateShortcut($ShortcutPath)
        $shellShortcut.TargetPath = (Join-Path $env:WINDIR "explorer.exe")
        $shellShortcut.Arguments = "shell:AppsFolder\$aumid"
        $shellShortcut.WorkingDirectory = $env:WINDIR
        $shellShortcut.Description = "Claude Desktop"
        if ($iconLocation) {
            $shellShortcut.IconLocation = $iconLocation
        }
        $shellShortcut.Save()

        Write-Host "  [重建] 快捷方式已按当前版本重建，AUMID: $aumid" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "  [警告] 快捷方式重建失败: $ShortcutPath - $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
}

function Repair-ClaudeDesktopShortcut {
    param([string]$ClaudePath)

    if (-not $ClaudePath) {
        return
    }

    # 从安装路径提取当前 AppX 版本号，如 Claude_1.40609.0.0_x64__pzs8sxrjxfjjc
    $currentVersion = ""
    if ($ClaudePath -match 'Claude_(\d+\.\d+\.\d+\.\d+)_') {
        $currentVersion = $Matches[1]
    }
    if (-not $currentVersion) {
        Write-Host "  [跳过] 无法从安装路径识别版本号: $ClaudePath" -ForegroundColor DarkYellow
        return
    }

    # 查找桌面（用户桌面 + 公共桌面）上的 Claude 快捷方式
    $shortcutPaths = @()
    foreach ($folderName in @("Desktop", "CommonDesktopDirectory")) {
        $folder = [Environment]::GetFolderPath($folderName)
        if ($folder -and (Test-Path -LiteralPath $folder)) {
            $shortcutPaths += @(Get-ChildItem -LiteralPath $folder -Filter "Claude*.lnk" -Force -ErrorAction SilentlyContinue |
                ForEach-Object { $_.FullName })
        }
    }
    $shortcutPaths = @($shortcutPaths | Where-Object { $_ } | Select-Object -Unique)
    if ($shortcutPaths.Count -eq 0) {
        Write-Host "  未找到桌面 Claude 快捷方式，跳过修复。" -ForegroundColor DarkGray
        return
    }

    $needleUtf16 = [System.Text.Encoding]::Unicode.GetBytes("Claude_")
    $needleAscii = [System.Text.Encoding]::ASCII.GetBytes("Claude_")
    $newVersionUtf16 = [System.Text.Encoding]::Unicode.GetBytes($currentVersion)
    $newVersionAscii = [System.Text.Encoding]::ASCII.GetBytes($currentVersion)

    foreach ($shortcutPath in $shortcutPaths) {
        try {
            $data = [System.IO.File]::ReadAllBytes($shortcutPath)
        } catch {
            Write-Host "  [警告] 无法读取快捷方式: $shortcutPath" -ForegroundColor DarkYellow
            continue
        }

        # 第一遍：找出所有版本号，判断是否有不等长（需要整文件重建）
        $needsRebuild = $false
        $versionRefs = [System.Collections.Generic.List[object]]::new()
        foreach ($mode in @('utf16', 'ascii')) {
            $needle = if ($mode -eq 'utf16') { $needleUtf16 } else { $needleAscii }
            foreach ($index in Find-BytePattern $data $needle) {
                $verStart = $index + $needle.Length
                $chars = New-Object System.Collections.Generic.List[char]
                $pos = $verStart
                if ($mode -eq 'utf16') {
                    while (($pos + 1) -lt $data.Length -and $data[$pos + 1] -eq 0 -and
                        ((($data[$pos] -ge 0x30) -and ($data[$pos] -le 0x39)) -or ($data[$pos] -eq 0x2E))) {
                        $chars.Add([char]$data[$pos])
                        $pos += 2
                    }
                } else {
                    while ($pos -lt $data.Length -and
                        ((($data[$pos] -ge 0x30) -and ($data[$pos] -le 0x39)) -or ($data[$pos] -eq 0x2E))) {
                        $chars.Add([char]$data[$pos])
                        $pos += 1
                    }
                }
                $oldVersion = -join $chars
                if (($oldVersion -notmatch '^\d+\.\d+\.\d+\.\d+$') -or ($oldVersion -eq $currentVersion)) {
                    continue
                }
                $versionRefs.Add([pscustomobject]@{
                    Mode = $mode
                    Offset = $verStart
                    OldVersion = $oldVersion
                })
                if ($oldVersion.Length -ne $currentVersion.Length) {
                    $needsRebuild = $true
                }
            }
        }

        if ($versionRefs.Count -eq 0) {
            Write-Host "  快捷方式版本已是最新: $shortcutPath" -ForegroundColor DarkGray
            continue
        }

        # 等长：原地字节替换，保留 .lnk 原始结构
        if (-not $needsRebuild) {
            $repaired = $false
            foreach ($ref in $versionRefs) {
                if ($ref.Mode -eq 'utf16') {
                    [System.Array]::Copy($newVersionUtf16, 0, $data, [int]$ref.Offset, $newVersionUtf16.Length)
                } else {
                    [System.Array]::Copy($newVersionAscii, 0, $data, [int]$ref.Offset, $newVersionAscii.Length)
                }
                Write-Host "  快捷方式版本号: $($ref.OldVersion) -> $currentVersion" -ForegroundColor Green
                $repaired = $true
            }
            if ($repaired) {
                $backup = "$shortcutPath.broken.bak"
                if (-not (Test-Path -LiteralPath $backup)) {
                    Copy-Item -LiteralPath $shortcutPath $backup -Force
                    Write-Host "  已备份原快捷方式: $backup" -ForegroundColor DarkGray
                }
                [System.IO.File]::WriteAllBytes($shortcutPath, $data)
                Write-Host "  已更新快捷方式: $shortcutPath" -ForegroundColor Green
            }
            continue
        }

        # 版本号长度不一致：.lnk 是二进制结构，直接增删字节会破坏文件，改为整文件重建
        Write-Host "  [重建] $shortcutPath 内版本号长度不一致（$($(($versionRefs | ForEach-Object { $_.OldVersion }) -join ', '))），改为按当前版本重建快捷方式..." -ForegroundColor Yellow
        [void](Rebuild-ClaudeDesktopShortcut $shortcutPath $ClaudePath)
    }
}

function Start-CoworkVMService {
    $serviceName = "CoworkVMService"
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Host "  [提示] 未找到 $serviceName 服务，跳过。" -ForegroundColor DarkGray
        return
    }

    if ($service.Status -eq "Running") {
        Write-Host "  $serviceName 已在运行" -ForegroundColor Green
        return
    }

    try {
        Start-Service -Name $serviceName -ErrorAction Stop
        Start-Sleep -Seconds 2
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        Write-Host "  $serviceName 已启动，当前状态: $($service.Status)" -ForegroundColor Green
    }
    catch {
        Write-Host "  [警告] 启动 $serviceName 失败: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Get-CCSwitchSkillsDirectory {
    $userProfile = $env:USERPROFILE
    if (-not $userProfile) {
        $userProfile = [Environment]::GetFolderPath("UserProfile")
    }
    if (-not $userProfile) {
        throw "无法确定当前用户目录，无法定位 CC Switch skills。"
    }

    return Join-Path $userProfile ".cc-switch\skills"
}

function Get-ClaudeSkillsPluginBasePaths {
    $paths = @()
    if ($env:LOCALAPPDATA) {
        $paths += Join-Path $env:LOCALAPPDATA "Claude-3p\local-agent-mode-sessions\skills-plugin"
    }
    if ($env:APPDATA) {
        $paths += Join-Path $env:APPDATA "Claude-3p\local-agent-mode-sessions\skills-plugin"
    }

    return @($paths | Where-Object { $_ } | Select-Object -Unique)
}

function Find-ClaudeDesktopSkillsPluginRoot {
    $candidates = @()
    foreach ($base in Get-ClaudeSkillsPluginBasePaths) {
        if (-not (Test-Path -LiteralPath $base -PathType Container)) {
            continue
        }

        foreach ($orgDir in Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue) {
            foreach ($pluginDir in Get-ChildItem -LiteralPath $orgDir.FullName -Directory -ErrorAction SilentlyContinue) {
                $manifestPath = Join-Path $pluginDir.FullName "manifest.json"
                $skillsDir = Join-Path $pluginDir.FullName "skills"
                if ((Test-Path -LiteralPath $manifestPath -PathType Leaf) -and (Test-Path -LiteralPath $skillsDir -PathType Container)) {
                    $manifest = Get-Item -LiteralPath $manifestPath
                    $candidates += [pscustomobject]@{
                        Path = $pluginDir.FullName
                        ManifestLastWriteTime = $manifest.LastWriteTimeUtc
                    }
                }
            }
        }
    }

    if ($candidates.Count -eq 0) {
        $searched = (Get-ClaudeSkillsPluginBasePaths) -join "; "
        throw "未找到 Claude Desktop skills plugin 目录。已搜索: $searched"
    }

    return ($candidates | Sort-Object ManifestLastWriteTime -Descending | Select-Object -First 1).Path
}

function Read-SkillFrontmatter {
    param([string]$SkillMdPath)

    $text = Get-Content $SkillMdPath -Raw -Encoding UTF8
    $lines = $text -split "`r?`n"
    if ($lines.Count -eq 0 -or $lines[0].Trim() -ne "---") {
        return @{}
    }

    $end = -1
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq "---") {
            $end = $i
            break
        }
    }
    if ($end -lt 0) {
        return @{}
    }

    $data = @{}
    $key = ""
    $valueLines = @()
    $flushFrontmatterValue = {
        if ($key) {
            $data[$key] = (($valueLines | ForEach-Object { $_.Trim() }) -join "`n").Trim()
        }
        $key = ""
        $valueLines = @()
    }

    for ($i = 1; $i -lt $end; $i++) {
        $line = $lines[$i]
        if (-not $line.Trim()) {
            if ($key -and $valueLines.Count -gt 0) {
                $valueLines += ""
            }
            continue
        }

        if ($line -match '^\s') {
            if ($key) {
                $valueLines += $line.Trim()
            }
            continue
        }

        $match = [regex]::Match($line, '^([A-Za-z0-9_-]+):(?:\s*(.*))?$')
        if (-not $match.Success) {
            continue
        }

        . $flushFrontmatterValue
        $key = $match.Groups[1].Value
        $value = $match.Groups[2].Value.Trim()
        if ($value) {
            $valueLines = @($value)
        } else {
            $valueLines = @()
        }
    }
    . $flushFrontmatterValue

    return $data
}

function Get-CCSwitchSkills {
    param([string]$SkillsDirectory)

    if (-not (Test-Path -LiteralPath $SkillsDirectory -PathType Container)) {
        throw "CC Switch skills 目录不存在: $SkillsDirectory"
    }

    $skills = @()
    foreach ($dir in Get-ChildItem -LiteralPath $SkillsDirectory -Directory -ErrorAction SilentlyContinue | Sort-Object Name) {
        $skillMd = Join-Path $dir.FullName "SKILL.md"
        if (-not (Test-Path -LiteralPath $skillMd -PathType Leaf)) {
            continue
        }

        $frontmatter = Read-SkillFrontmatter $skillMd
        $name = ""
        if ($frontmatter.ContainsKey("name")) {
            $name = ([string]$frontmatter["name"]).Trim()
        }
        if (-not $name) {
            $name = $dir.Name
        }
        if (-not $name -or $name -eq "." -or $name -eq ".." -or $name.Contains("/") -or $name.Contains("\")) {
            Write-Host "  [跳过] skill 名称无效: $name" -ForegroundColor DarkYellow
            continue
        }

        $description = ""
        if ($frontmatter.ContainsKey("description")) {
            $description = ([string]$frontmatter["description"]).Trim()
        }

        $skills += [pscustomobject]@{
            Name = $name
            Description = $description
            Path = $dir.FullName
        }
    }

    return $skills
}

function Ensure-SkillsManifestList {
    param([pscustomobject]$Manifest)

    if (-not ($Manifest.PSObject.Properties.Name -contains "skills") -or $null -eq $Manifest.skills -or ($Manifest.skills -is [string])) {
        Add-OrSetJsonProperty $Manifest "skills" @()
    }
}

function Get-ReparsePointTarget {
    param([string]$Path)

    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (-not (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint)) {
            return ""
        }

        if ($item.PSObject.Properties.Name -contains "Target" -and $item.Target) {
            if ($item.Target -is [array]) {
                return [string]$item.Target[0]
            }
            return [string]$item.Target
        }
        if ($item.PSObject.Properties.Name -contains "LinkTarget" -and $item.LinkTarget) {
            return [string]$item.LinkTarget
        }
    }
    catch {
        return ""
    }

    return ""
}

function Resolve-ExistingPath {
    param([string]$Path)

    try {
        return [System.IO.Path]::GetFullPath($Path)
    }
    catch {
        return ""
    }
}

function Test-PathWithinDirectory {
    param(
        [string]$Path,
        [string]$Parent
    )

    $fullPath = Resolve-ExistingPath $Path
    $fullParent = Resolve-ExistingPath $Parent
    if (-not $fullPath -or -not $fullParent) {
        return $false
    }

    $fullParent = $fullParent.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    return $fullPath.Equals($fullParent, [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($fullParent + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($fullParent + [System.IO.Path]::AltDirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
}

function Remove-ReparsePoint {
    param([string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [System.IO.FileAttributes]::Directory) -eq [System.IO.FileAttributes]::Directory) {
        [System.IO.Directory]::Delete($Path, $false)
    } else {
        [System.IO.File]::Delete($Path)
    }
}

function Sync-CCSwitchSkills {
    $skillsDirectory = Get-CCSwitchSkillsDirectory
    $pluginRoot = Find-ClaudeDesktopSkillsPluginRoot
    $desktopSkillsDirectory = Join-Path $pluginRoot "skills"
    $manifestPath = Join-Path $pluginRoot "manifest.json"
    $manifest = Get-JsonObjectOrBackup $manifestPath
    Ensure-SkillsManifestList $manifest

    $manifestSkills = @($manifest.skills)
    $existingNames = @{}
    foreach ($item in $manifestSkills) {
        if ($item -is [pscustomobject] -and $item.PSObject.Properties.Name -contains "name" -and [string]$item.name) {
            $existingNames[[string]$item.name] = $true
        }
    }

    $ccSkills = @(Get-CCSwitchSkills $skillsDirectory)
    $now = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    $linked = 0
    $manifestAdded = 0
    $skipped = 0

    Write-Host "Claude Desktop skills plugin: $pluginRoot"
    Write-Host "CC Switch skills source: $skillsDirectory"

    foreach ($skill in $ccSkills) {
        $target = Join-Path $desktopSkillsDirectory $skill.Name
        if ((Test-Path -LiteralPath $target) -or $existingNames.ContainsKey($skill.Name)) {
            Write-Host "  同名 skill 已存在，跳过: $($skill.Name)" -ForegroundColor DarkYellow
            $skipped++
            continue
        }

        New-Item -ItemType SymbolicLink -Path $target -Target $skill.Path | Out-Null
        $linked++
        Write-Host "  同步软链接: $($skill.Name) -> $($skill.Path)" -ForegroundColor Green

        $manifestItem = [pscustomobject][ordered]@{
            skillId = $skill.Name
            name = $skill.Name
            description = $skill.Description
            creatorType = "user"
            syncManaged = $false
            updatedAt = $now
            enabled = $true
        }
        $manifestSkills += $manifestItem
        $existingNames[$skill.Name] = $true
        $manifestAdded++
        Write-Host "  写入 manifest: $($skill.Name)" -ForegroundColor Green
    }

    if ($manifestAdded -gt 0) {
        Add-OrSetJsonProperty $manifest "skills" $manifestSkills
        Add-OrSetJsonProperty $manifest "lastUpdated" ([Int64]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()))
        $backup = Join-Path $pluginRoot "manifest.json.bak-before-cc-switch-sync"
        Copy-Item $manifestPath $backup -Force
        Save-JsonNoBom $manifestPath $manifest
    }

    Write-Host "同步完成：新增软链接 $linked 个，新增 manifest $manifestAdded 条，跳过 $skipped 个。" -ForegroundColor Green
}

function Unsync-CCSwitchSkills {
    $skillsDirectory = Get-CCSwitchSkillsDirectory
    $pluginRoot = Find-ClaudeDesktopSkillsPluginRoot
    $desktopSkillsDirectory = Join-Path $pluginRoot "skills"
    $manifestPath = Join-Path $pluginRoot "manifest.json"
    $manifest = Get-JsonObjectOrBackup $manifestPath
    Ensure-SkillsManifestList $manifest
    $removedNames = @{}
    $skipped = 0

    Write-Host "Claude Desktop skills plugin: $pluginRoot"
    Write-Host "CC Switch skills source: $skillsDirectory"

    foreach ($targetItem in Get-ChildItem -LiteralPath $desktopSkillsDirectory -Force -ErrorAction SilentlyContinue) {
        $target = $targetItem.FullName
        $targetItem = Get-Item -LiteralPath $target -Force
        if (-not (($targetItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint)) {
            Write-Host "  不是 CC Switch 同步软链接，跳过: $($targetItem.Name)" -ForegroundColor DarkYellow
            $skipped++
            continue
        }

        $linkTarget = Get-ReparsePointTarget $target
        if (-not $linkTarget) {
            Write-Host "  无法解析软链接目标，跳过: $target" -ForegroundColor DarkYellow
            $skipped++
            continue
        }
        if (-not [System.IO.Path]::IsPathRooted($linkTarget)) {
            $linkTarget = Join-Path $desktopSkillsDirectory $linkTarget
        }
        $resolvedTarget = Resolve-ExistingPath $linkTarget
        if (-not (Test-PathWithinDirectory $resolvedTarget $skillsDirectory)) {
            Write-Host "  软链接目标不在 CC Switch skills 目录内，跳过: $($targetItem.Name)" -ForegroundColor DarkYellow
            $skipped++
            continue
        }

        Remove-ReparsePoint $target
        $removedNames[$targetItem.Name] = $true
        Write-Host "  删除同步: $($targetItem.Name) -> $resolvedTarget" -ForegroundColor Green
    }

    if ($removedNames.Count -gt 0) {
        $oldManifestSkills = @($manifest.skills)
        $keptSkills = @()
        foreach ($item in $oldManifestSkills) {
            if ($item -is [pscustomobject] -and $item.PSObject.Properties.Name -contains "name" -and $removedNames.ContainsKey([string]$item.name)) {
                continue
            }
            $keptSkills += $item
        }
        $removedManifestCount = $oldManifestSkills.Count - $keptSkills.Count
        Add-OrSetJsonProperty $manifest "skills" $keptSkills
        Add-OrSetJsonProperty $manifest "lastUpdated" ([Int64]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()))
        $backup = Join-Path $pluginRoot "manifest.json.bak-before-cc-switch-sync"
        Copy-Item $manifestPath $backup -Force
        Save-JsonNoBom $manifestPath $manifest
        Write-Host "取消同步完成：删除 $($removedNames.Count) 个软链接，删除 $removedManifestCount 条 manifest 记录，跳过 $skipped 个。" -ForegroundColor Green
    } else {
        Write-Host "取消同步完成：删除 0 个，跳过 $skipped 个。" -ForegroundColor Green
    }
}

function Remove-LanguageFiles {
    param([string]$ResourcesPath)

    $targets = @(
        (Join-Path $ResourcesPath "ion-dist\i18n\zh-CN.json"),
        (Join-Path $ResourcesPath "zh-CN.json"),
        (Join-Path $ResourcesPath "ion-dist\i18n\statsig\zh-CN.json"),
        (Join-Path $ResourcesPath "ion-dist\i18n\zh-TW.json"),
        (Join-Path $ResourcesPath "zh-TW.json"),
        (Join-Path $ResourcesPath "ion-dist\i18n\statsig\zh-TW.json"),
        (Join-Path $ResourcesPath "ion-dist\i18n\zh-HK.json"),
        (Join-Path $ResourcesPath "zh-HK.json"),
        (Join-Path $ResourcesPath "ion-dist\i18n\statsig\zh-HK.json")
    )

    foreach ($target in $targets) {
        Remove-Item $target -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path $target)) {
            Write-Host "  removed: $target" -ForegroundColor Green
        } else {
            Write-Host "  [警告] 未能删除: $target" -ForegroundColor DarkYellow
        }
    }
}

function Test-ClaudeDesktopProcessPath {
    param([string]$Path)

    if (-not $Path) {
        return $false
    }
    return ($Path -match "WindowsApps\\Claude_" -or $Path -match "AnthropicClaude\\app-")
}

function Get-ClaudeDesktopProcesses {
    $procs = @()
    foreach ($proc in Get-Process -Name "claude" -ErrorAction SilentlyContinue) {
        try {
            $path = $proc.MainModule.FileName
            if (Test-ClaudeDesktopProcessPath $path) {
                $procs += $proc
            }
        } catch {
            # MainModule inaccessible (permission or 32/64 mismatch) — skip rather than risk killing Claude Code.
        }
    }
    return @($procs | Sort-Object Id -Unique)
}

function Get-ClaudeCoworkProcesses {
    $items = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -ieq "cowork-svc.exe" -and (Test-ClaudeDesktopProcessPath $_.ExecutablePath)
        })

    $procs = @()
    foreach ($item in $items) {
        $proc = Get-Process -Id $item.ProcessId -ErrorAction SilentlyContinue
        if ($proc) {
            $procs += $proc
        }
    }
    return @($procs | Sort-Object Id -Unique)
}

function Wait-ProcessesExit {
    param(
        [object[]]$Processes,
        [int]$TimeoutSeconds = 10
    )

    $remaining = @($Processes)
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        if ($remaining.Count -eq 0) {
            return @()
        }
        Start-Sleep -Seconds 1
        $elapsed++
        $remaining = @($remaining | Where-Object {
            try { -not $_.HasExited } catch { $false }
        })
    }
    return @($remaining)
}

function Stop-ClaudeProcessesGracefully {
    param(
        [int]$TimeoutSeconds = 10
    )

    $desktopProcs = @(Get-ClaudeDesktopProcesses)
    $coworkProcs = @(Get-ClaudeCoworkProcesses)
    if (($desktopProcs.Count + $coworkProcs.Count) -eq 0) {
        return $true
    }

    foreach ($proc in $desktopProcs) {
        Write-Host "  正在请求 Claude Desktop 优雅退出 (PID $($proc.Id))..." -ForegroundColor DarkGray
        try {
            if ($proc.MainWindowHandle -ne 0) {
                [void]$proc.CloseMainWindow()
            } else {
                $null = & taskkill /PID $proc.Id 2>&1
            }
        } catch {
            # 继续等待，必要时只终止 Claude Desktop 自身，不终止进程树。
        }
    }

    $remainingDesktop = @(Wait-ProcessesExit $desktopProcs $TimeoutSeconds)
    if ($remainingDesktop.Count -gt 0) {
        Write-Host "  Claude Desktop 优雅退出超时（${TimeoutSeconds}秒），仅强制终止 Desktop 主进程..." -ForegroundColor DarkYellow
        foreach ($proc in $remainingDesktop) {
            try {
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            } catch {
                # 已退出或无法终止
            }
        }
        Start-Sleep -Seconds 1
    }

    # cowork-svc.exe 不叫 claude.exe，旧逻辑不会停它；恢复/覆盖 app.asar 时它可能继续占用资源。
    $coworkProcs = @(Get-ClaudeCoworkProcesses)
    if ($coworkProcs.Count -gt 0) {
        foreach ($proc in $coworkProcs) {
            Write-Host "  正在停止 Claude Cowork 服务进程 (PID $($proc.Id))..." -ForegroundColor DarkGray
            try {
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            } catch {
                # 已退出或权限不足
            }
        }
        $remainingCowork = @(Wait-ProcessesExit $coworkProcs 5)
        foreach ($proc in $remainingCowork) {
            Write-Host "  [警告] 未能停止 Cowork 进程 PID $($proc.Id)，可能需要管理员权限或手动结束。" -ForegroundColor DarkYellow
        }
    }

    $stillDesktop = @(Get-ClaudeDesktopProcesses)
    $stillCowork = @(Get-ClaudeCoworkProcesses)
    if (($stillDesktop.Count + $stillCowork.Count) -eq 0) {
        Write-Host "  Claude Desktop/Cowork 已停止" -ForegroundColor Green
        return $true
    }
    return $false
}

function Stop-ClaudeProcesses {
    $killed = Stop-ClaudeProcessesGracefully -TimeoutSeconds 10
    if ($killed) {
        Write-Host "  Claude Desktop 已停止" -ForegroundColor Green
    } else {
        Write-Host "  已强制停止 Claude Desktop" -ForegroundColor Green
    }
}

function Restart-Claude {
    param([string]$ClaudePath)

    Stop-ClaudeProcesses

    $exe = Get-ClaudeExePath $ClaudePath
    if ($exe) {
        Start-Process -FilePath "explorer.exe" -ArgumentList "`"$exe`""
        Write-Host "  restarted Claude Desktop" -ForegroundColor Green
        return
    }

    Write-Host "  [警告] 未找到 Claude.exe，请手动启动 Claude Desktop。" -ForegroundColor DarkYellow
}

function Install-WindowsLanguagePack {
    $label = Get-LanguageLabel $LanguageCode

    # 单实例互斥锁：防止多个安装进程并发写入 app.asar
    $mutex = New-Object System.Threading.Mutex($false, "Global\ClaudeDesktopZhCn-Installer")
    try {
        if (-not $mutex.WaitOne(0)) {
            Write-Host "  [错误] 另一个安装进程正在运行，请等待其完成后再试。" -ForegroundColor Red
            return
        }
    } catch [System.Threading.AbandonedMutexException] {
        # 上一个进程异常退出，锁已释放，继续执行
    }

    Write-Host "=== Claude Desktop Windows $label 补丁 ===" -ForegroundColor Cyan

    try {
        Write-Step "[1/8] 检查安装模式"
        if ($PatchMode -eq "safe") {
            Write-Host "  Cowork 兼容模式。" -ForegroundColor Green
        } else {
            Write-Host "  官方账号登录模式。" -ForegroundColor Green
        }

        Write-Step "[2/8] 检查语言资源"
        $pack = Get-LanguageResources $LanguageCode

        Write-Step "停用 Frida 常驻模式"
        Disable-FridaResidentForDiskInstall

        Write-Step "关闭 Claude Desktop"
        Stop-ClaudeProcesses

        Write-Step "[3/8] 查找 Claude Desktop"
        $paths = Get-ClaudeResourcesPath
        $claudePath = $paths["App"]
        $resourcesPath = $paths["Resources"]
        $installKind = $paths["InstallKind"]
        Write-Host "  app: $claudePath" -ForegroundColor Green
        Write-Host "  resources: $resourcesPath" -ForegroundColor Green

        Write-Step "修复桌面 Claude 快捷方式"
        if ($PatchMode -eq "safe") {
            Repair-ClaudeDesktopShortcut $claudePath
        } else {
            Write-Host "  skipping desktop shortcut repair (official mode)" -ForegroundColor DarkGray
        }

        Write-Step "[4/8] 准备写入权限"
        Enable-WriteAccess $resourcesPath
        Remove-LegacyAppxForkArtifacts

        Write-Step "[5/8] 写入 $label 资源"
        Install-LanguageFiles $resourcesPath $pack $LanguageCode

        Write-Step "[6/8] 注册中文语言"
        Register-Language $resourcesPath $LanguageCode

        Write-Step "[7/8] 汉化硬编码界面文本"
        Patch-HardcodedFrontendStrings $resourcesPath $LanguageCode
        Patch-LanguageDisplayNames $resourcesPath
        if (Test-OnlineAccountPatchEnabled) {
            Write-AsarCoworkSignatureWarning
            Patch-OnlineDomTranslation $resourcesPath $pack $LanguageCode
            Patch-HardcodedMainProcessMenuLabels $resourcesPath $LanguageCode
            Patch-ModelPickerStrings $resourcesPath $LanguageCode
        } else {
            Write-Host "  skipping online claude.ai DOM translation patch (app.asar) due to patch mode: $PatchMode" -ForegroundColor DarkYellow
            Write-Host "  skipping main-process menu label patch (app.asar) due to patch mode: $PatchMode" -ForegroundColor DarkYellow
        }

        if (-not (Test-AsarPatchEnabled)) {
            Write-Host "  skipping Claude.exe asar integrity sync due to patch mode: $PatchMode" -ForegroundColor DarkYellow
        }

        Write-Step "[8/8] 写入用户语言配置"
        Set-ClaudeLocale $LanguageCode

        Write-Step "重启 Claude Desktop"
        Restart-Claude $claudePath

        Write-Step "启动 CoworkVMService"
        Start-CoworkVMService

        Write-Host ""
        Write-Host "安装完成。如果界面未立即切换，请在 Language 中选择 $label。" -ForegroundColor Green
    }
    catch {
        Write-Host ""
        Write-Host "安装过程中出现错误，Claude Desktop 可能处于不完整状态。" -ForegroundColor Red
        Write-Host "  建议运行卸载命令恢复原始状态：install-windows.bat → 选择卸载。" -ForegroundColor DarkYellow
        Write-Host "  详细日志: $script:InstallLogPath" -ForegroundColor DarkGray
        if ($script:DetectedMultipleClaudeInstalls) {
            Write-MultipleClaudeFailureHint
        }
        throw
    }
    finally {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

function Uninstall-WindowsLanguagePack {
    Write-Host "=== Claude Desktop Windows 中文补丁卸载 ===" -ForegroundColor Cyan

    $oldSkipAsarPatch = $SkipAsarPatch
    $SkipAsarPatch = $true
    try {
        $paths = Get-ClaudeResourcesPath
    }
    finally {
        $SkipAsarPatch = $oldSkipAsarPatch
    }
    $claudePath = $paths["App"]
    $resourcesPath = $paths["Resources"]

    # Best-effort: stop Frida resident/watch/launcher and remove deployed runtime files.
    $fridaCtl = Join-Path $PSScriptRoot "experimental\frida-zh-resident-ctl.ps1"
    if (Test-Path -LiteralPath $fridaCtl) {
        try {
            Write-Step "清理 Frida 常驻 / 进程 / claude-zh 目录（如有）"
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fridaCtl -Action uninstall -RemoveRuntime 2>$null
        }
        catch {
            Write-Host "  [警告] 清理 Frida 常驻失败（可忽略）: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }

    Write-Step "关闭 Claude Desktop"
    Stop-ClaudeProcesses
    Remove-LegacyAppxForkArtifacts

    Write-Step "[1/4] 恢复前端 bundle 和 app.asar"
    Restore-LatestBackup $resourcesPath
    Sync-ClaudeExeAsarIntegrity $resourcesPath

    Write-Step "[2/4] 删除中文资源"
    Remove-LanguageFiles $resourcesPath

    Write-Step "[3/4] 移除 zh-CN 语言注册"
    Unregister-Language $resourcesPath

    Write-Step "[4/4] 恢复用户语言配置"
    Set-ClaudeLocale "en-US"

    Write-Host ""
    Write-Host "卸载完成。请重启 Claude Desktop 使更改生效。" -ForegroundColor Green
}

function Invoke-PreInstallCleanup {
    if ($script:PreInstallCleanupDone) {
        return
    }
    $script:PreInstallCleanupDone = $true

    Write-Host "=== 安装前清理旧中文补丁 ===" -ForegroundColor Cyan

    $oldSkipAsarPatch = $SkipAsarPatch
    $SkipAsarPatch = $true
    try {
        $paths = Get-ClaudeResourcesPath
    }
    finally {
        $SkipAsarPatch = $oldSkipAsarPatch
    }

    $resourcesPath = $paths["Resources"]
    $backupRoot = Get-BackupRoot $resourcesPath
    $backup = $null
    if (Test-Path $backupRoot) {
        $backup = Get-ChildItem $backupRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name |
            Select-Object -First 1
    }
    if (-not $backup) {
        Write-Host "  未找到旧中文补丁备份，跳过预卸载。" -ForegroundColor DarkYellow
        return
    }

    Uninstall-WindowsLanguagePack
}

if ($Interactive) {
    $interactiveSelection = Read-InteractiveSelection
    $Action = $interactiveSelection.Action
    $Language = $interactiveSelection.Language
    $PatchMode = $interactiveSelection.PatchMode
}

if ($SkipAsarPatch) {
    $PatchMode = "safe"
}

$LanguageCode = $Language

try {
    switch ($Action) {
        "install" {
            Invoke-PreInstallCleanup
            Install-WindowsLanguagePack
        }
        "uninstall" { Uninstall-WindowsLanguagePack }
        "disable-updates" { Set-ClaudeAutoUpdates $false }
        "enable-updates" { Set-ClaudeAutoUpdates $true }
        "sync-skills" { Sync-CCSwitchSkills }
        "unsync-skills" { Unsync-CCSwitchSkills }
        "frida-launch" { Invoke-FridaRuntimeLaunch -Lang $LanguageCode }
    }

    Stop-InstallLog
    exit 0
}
catch {
    Write-Host ""
    Write-Host "[错误] $($_.Exception.Message)" -ForegroundColor Red
    if ($script:InstallLogPath) {
        Write-Host "[错误] 详细日志已写入: $script:InstallLogPath" -ForegroundColor Red
    }
    Stop-InstallLog
    if ($Interactive) {
        [void](Read-Host "安装未完成，按 Enter 退出")
    }
    exit 1
}
