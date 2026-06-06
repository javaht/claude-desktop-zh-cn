param(
    [switch]$Interactive,
    [switch]$SkipAsarPatch,
    [ValidateSet("safe", "official", "full")]
    [string]$PatchMode = "full",

    [Parameter(Position = 0)]
    [ValidateSet("install", "uninstall", "sync-skills", "unsync-skills")]
    [string]$Action = "install",

    [Parameter(Position = 1)]
    [ValidateSet("zh-CN", "zh-TW", "zh-HK")]
    [string]$Language = "zh-CN"
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$BaseLanguageList = '["en-US","de-DE","fr-FR","ko-KR","ja-JP","es-419","es-ES","it-IT","hi-IN","pt-BR","id-ID"'
$LanguageListPattern = [System.Text.RegularExpressions.Regex]::Escape($BaseLanguageList) + '(?:(?:,"zh-CN")|(?:,"zh-TW")|(?:,"zh-HK"))*\]'
$AsarPatchTarget = ".vite/build/index.js"
$AsarIntegrityBlockSize = 4 * 1024 * 1024
$OnlineLocaleMainMarker = "__claudeZhOnlineLocaleMain"
$OnlineTranslationMaxSourceLength = 240
$script:CurrentBackupSetPath = $null
$script:DetectedUnpackagedClaudePaths = @()
$script:DetectedMultipleClaudeInstalls = $false
$script:InstallLogPath = $null
$script:InstallTranscriptStarted = $false

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

function Get-ScriptProjectDirectory {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    return Split-Path -Parent $scriptDir
}

function Test-GitHubReleaseUpdate {
    if (Test-SkipReleaseUpdateCheck) {
        return
    }

    try {
        $projectDir = Get-ScriptProjectDirectory
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
    Write-Host "[1] 安装中文补丁(第三方 API 登录方式：Cowork 安全模式，第三方模型请用 ccswitch/别名映射)"
    Write-Host "[2] 安装中文补丁(官方账号登录方式：Cowork 沙箱/工作区不可用)"
    Write-Host "[3] 安装中文补丁(第三方 API 登录方式：同时去除模型限制；Cowork 沙箱/工作区不可用)"
    Write-Host "[4] 恢复原样 / 卸载补丁"
    Write-Host "[5] 同步 CC Switch skills（y=开启同步，n=删除同步）"
    Write-Host "[Q] 退出"
    Write-Host ""

    $patchModeForInstall = "full"
    $actionSelected = $false
    while (-not $actionSelected) {
        $actionSelection = (Read-Host "请选择操作 [1/2/3/4/5/Q]").Trim()
        switch -Regex ($actionSelection) {
            '^[1]$' { $patchModeForInstall = "safe"; $actionSelected = $true }
            '^[2]$' { $patchModeForInstall = "official"; $actionSelected = $true }
            '^[3]$' { $patchModeForInstall = "full"; $actionSelected = $true }
            '^[4]$' { return @{ Action = "uninstall"; Language = "zh-CN"; PatchMode = "safe" } }
            '^[5]$' {
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
            default { Write-Host "请输入 1、2、3、4、5 或 Q。" -ForegroundColor Yellow }
        }
    }

    Write-Host ""
    Write-Host "请选择要安装的语言："
    Write-Host "[1] 简体中文"
    Write-Host "[2] 繁体中文（中国台湾）"
    Write-Host "[3] 繁体中文（中国香港）"
    Write-Host "[Q] 退出"
    Write-Host ""

    while ($true) {
        $languageSelection = (Read-Host "请选择语言 [1/2/3/Q]").Trim()
        switch -Regex ($languageSelection) {
            '^[1]$' { return @{ Action = "install"; Language = "zh-CN"; PatchMode = $patchModeForInstall } }
            '^[2]$' { return @{ Action = "install"; Language = "zh-TW"; PatchMode = $patchModeForInstall } }
            '^[3]$' { return @{ Action = "install"; Language = "zh-HK"; PatchMode = $patchModeForInstall } }
            '^[Qq]$' { exit 0 }
            default { Write-Host "请输入 1、2、3 或 Q。" -ForegroundColor Yellow }
        }
    }
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

function Test-OnlineAccountPatchEnabled {
    return $PatchMode -eq "official" -or $PatchMode -eq "full"
}

function Test-Custom3PPatchEnabled {
    return $PatchMode -eq "full"
}

function Test-AsarPatchEnabled {
    return (Test-OnlineAccountPatchEnabled) -or (Test-Custom3PPatchEnabled)
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
        Sort-Object LastWriteTime -Descending |
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

    $projectDir = Get-ScriptProjectDirectory
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

function Encode-AsarHeader {
    param(
        [string]$HeaderString,
        [int]$ExpectedHeaderSize
    )
    $encoded = Encode-AsarHeaderDynamic $HeaderString
    $actualSize = [System.BitConverter]::ToUInt32($encoded, 4)
    if ($actualSize -ne $ExpectedHeaderSize) {
        throw "app.asar header length changed; refusing to write an unsafe patch."
    }
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

function Read-AsarFileContent {
    param(
        [string]$ResourcesPath,
        [string]$FilePath
    )
    $asarPath = Join-Path $ResourcesPath "app.asar"
    Require-File $asarPath
    $data = [System.IO.File]::ReadAllBytes($asarPath)
    $parsed = Read-AsarHeader $data $asarPath
    $headerSize = $parsed["HeaderSize"]
    $header = $parsed["Header"]
    $entry = Get-AsarFileEntry $header $FilePath
    $contentOffset = [int64](8 + $headerSize + [int64]$entry.offset)
    $contentSize = [int64]$entry.size
    $contentEnd = $contentOffset + $contentSize
    if (($contentOffset -lt 0) -or ($contentEnd -gt $data.Length)) {
        throw "Unsupported app.asar file bounds for $FilePath."
    }
    $content = [byte[]]::new([int]$contentSize)
    [System.Array]::Copy($data, [int]$contentOffset, $content, 0, [int]$contentSize)
    return @{
        Data = $data
        HeaderSize = $headerSize
        Header = $header
        Entry = $entry
        Content = $content
        ContentOffset = $contentOffset
        AsarPath = $asarPath
    }
}

function Write-AsarContentInPlace {
    param(
        [string]$ResourcesPath,
        [byte[]]$Data,
        [string]$HeaderString,
        [int]$HeaderSize,
        [object]$Entry,
        [byte[]]$Content
    )
    $asarPath = Join-Path $ResourcesPath "app.asar"
    Backup-ModifiedFile $ResourcesPath $asarPath
    $Entry.integrity = Get-AsarFileIntegrity $Content
    $updatedHeader = Encode-AsarHeader $HeaderString $HeaderSize
    [System.Array]::Copy($Content, 0, $Data, [int](8 + $HeaderSize + [int64]$Entry.offset), $Content.Length)
    [System.Array]::Copy($updatedHeader, 0, $Data, 0, $updatedHeader.Length)
    [System.IO.File]::WriteAllBytes($asarPath, $Data)
    Sync-ClaudeExeAsarIntegrity $ResourcesPath
}

function Replace-AsarFileContent {
    param(
        [string]$ResourcesPath,
        [string]$FilePath,
        [byte[]]$PatchedContent
    )

    $asarInfo = Get-Item -LiteralPath (Join-Path $ResourcesPath "app.asar")
    Write-Host "  reading app.asar ($(Format-ByteSize $asarInfo.Length)): $FilePath" -ForegroundColor DarkGray
    Write-Host "  [进度] 正在读取 app.asar，大文件或共享盘可能需要一些时间..." -ForegroundColor DarkGray
    $asar = Read-AsarFileContent $ResourcesPath $FilePath
    Write-Host "  [进度] app.asar 读取完成，正在解析 asar 头..." -ForegroundColor DarkGray
    Write-Host "  [进度] asar 头解析完成，正在定位目标文件..." -ForegroundColor DarkGray
    $asarPath = $asar.AsarPath
    $data = $asar.Data
    $headerSize = $asar.HeaderSize
    $header = $asar.Header
    $entry = $asar.Entry
    $contentOffset = $asar.ContentOffset
    $contentSize = [int64]$entry.size
    $contentEnd = $contentOffset + $contentSize

    $oldContent = $asar.Content
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

function Find-Custom3PValidationToggle {
    param(
        [byte[]]$Content,
        [string]$ExprText
    )

    $contentText = [System.Text.Encoding]::ASCII.GetString($Content)
    $pattern = 'const ([A-Za-z_$][A-Za-z0-9_$]*)=' + [regex]::Escape($ExprText) + '\|\|!1,([A-Za-z_$][A-Za-z0-9_$]*)='
    $validMatches = New-Object System.Collections.Generic.List[object]

    foreach ($match in [regex]::Matches($contentText, $pattern)) {
        $flagName = $match.Groups[1].Value
        $windowLength = [Math]::Min(2500, $contentText.Length - $match.Index)
        $validationWindow = $contentText.Substring($match.Index, $windowLength)
        if (
            $validationWindow.Contains(('if(!' + $flagName + ')return{ok:!0}')) -and
            $validationWindow.Contains('expected a gateway model route referencing an Anthropic model') -and
            $validationWindow.Contains('Bedrock model')
        ) {
            $validMatches.Add($match)
        }
    }

    if ($validMatches.Count -gt 1) {
        throw "Could not patch custom 3P model validation: multiple matching toggles found."
    }
    if ($validMatches.Count -eq 1) {
        return $validMatches[0]
    }
    return $null
}

function Test-Custom3PValidationRemoved {
    param([byte[]]$Content)

    $contentText = [System.Text.Encoding]::ASCII.GetString($Content)
    if (
        (-not $contentText.Contains('expected a gateway model route referencing an Anthropic model')) -and
        (-not $contentText.Contains('Bedrock model'))
    ) {
        return $true
    }
    return $false
}

function Find-Custom3PNameValidator {
    param(
        [byte[]]$Content,
        [bool]$Patched
    )

    $contentText = [System.Text.Encoding]::ASCII.GetString($Content)
    $pattern = 'function ([A-Za-z_$][A-Za-z0-9_$]*)\(([A-Za-z_$][A-Za-z0-9_$]*)\)\{const ([A-Za-z_$][A-Za-z0-9_$]*)=\2\.toLowerCase\(\);return ([^{};]+)\}'
    $validMatches = New-Object System.Collections.Generic.List[object]

    foreach ($match in [regex]::Matches($contentText, $pattern)) {
        $windowStart = [Math]::Max(0, $match.Index - 1500)
        $windowLength = [Math]::Min(3000 + ($match.Index - $windowStart), $contentText.Length - $windowStart)
        $validationWindow = $contentText.Substring($windowStart, $windowLength)
        if (
            $validationWindow.Contains('deepseek') -and
            $validationWindow.Contains('expected a gateway model route referencing an Anthropic model')
        ) {
            $expr = $match.Groups[4].Value.Trim()
            if ($Patched -and ($expr -eq '!0')) {
                $validMatches.Add($match)
            }
            elseif (
                (-not $Patched) -and
                $match.Groups[4].Value.Contains('.test(') -and
                $match.Groups[4].Value.Contains('.some(') -and
                $match.Groups[4].Value.Contains('.includes(')
            ) {
                $validMatches.Add($match)
            }
        }
    }

    if ($validMatches.Count -gt 1) {
        throw "Could not patch custom 3P model validation: multiple matching validators found."
    }
    if ($validMatches.Count -eq 1) {
        return $validMatches[0]
    }
    return $null
}

function Patch-Custom3PNameValidator {
    param([byte[]]$Content)

    $match = Find-Custom3PNameValidator $Content $false
    if ($null -eq $match) {
        return $false
    }

    $expr = $match.Groups[4].Value
    $replacementText = '!0' + (' ' * ($expr.Length - 2))
    $replacement = [System.Text.Encoding]::ASCII.GetBytes($replacementText)
    if ($replacement.Length -ne $expr.Length) {
        throw "Internal patch error: custom 3P validator replacement changed length."
    }
    [System.Array]::Copy($replacement, 0, $Content, $match.Groups[4].Index, $replacement.Length)
    return $true
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

function Get-FrontendJsBundleFiles {
    param([string]$ResourcesPath)
    $assetsDir = Join-Path $ResourcesPath "ion-dist\assets\v1"
    $jsFiles = @(Get-ChildItem (Join-Path $assetsDir "*.js") -ErrorAction SilentlyContinue)
    if ($jsFiles.Count -eq 0) {
        throw "未找到前端 JS bundle: $assetsDir"
    }
    return $jsFiles
}

function Register-Language {
    param(
        [string]$ResourcesPath,
        [string]$Lang
    )

    $jsFiles = Get-FrontendJsBundleFiles $ResourcesPath

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

    $jsFiles = Get-FrontendJsBundleFiles $ResourcesPath

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

    $projectDir = Get-ScriptProjectDirectory
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
    foreach ($fragment in @("<", "{", "`n", "http://", "https://")) {
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
    } else {
        $selectedText = "已選擇 `$1 項"
        $deleteSelectedText = "刪除 `$1 個所選項目"
    }
    $selectedTextJson = $selectedText | ConvertTo-Json -Compress
    $deleteSelectedTextJson = $deleteSelectedText | ConvertTo-Json -Compress
    $template = @'
(()=>{try{
const L=__LANGUAGE__,M=__MAPPING__,ST=__SELECTED_TEXT__,DST=__DELETE_SELECTED_TEXT__;
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
[/^Mon$/,"周一"],[/^Tue$/,"周二"],[/^Wed$/,"周三"],[/^Thu$/,"周四"],[/^Fri$/,"周五"],[/^Sat$/,"周六"],[/^Sun$/,"周日"]
];
const R=s=>{const n=N(s);if(M[n])return M[n];for(const [r,t] of G){const m=n.match(r);if(m)return t.replace("$1",m[1])}};
const X=new Set(["SCRIPT","STYLE","NOSCRIPT"]);
function T(){try{const b=document.body||document.documentElement;if(!b)return;const w=document.createTreeWalker(b,NodeFilter.SHOW_TEXT,{acceptNode(n){const p=n.parentElement;if(!p||X.has(p.tagName)||!R(n.nodeValue))return NodeFilter.FILTER_REJECT;return NodeFilter.FILTER_ACCEPT}});let n;while(n=w.nextNode()){const v=R(n.nodeValue);if(v)n.nodeValue=v}document.querySelectorAll("[role=dialog] p,[role=dialog] div,[role=dialog] span").forEach(e=>{try{if(e.closest("button,[contenteditable]"))return;const t=R(e.textContent);if(t&&N(e.textContent)!==N(t))e.textContent=t}catch{}});document.querySelectorAll("[aria-label],[title],[placeholder],input,textarea").forEach(e=>{["aria-label","title","placeholder","value"].forEach(a=>{try{if(a==="value"&&!(e.matches("input[type=button],input[type=submit]")))return;let v=e.getAttribute?e.getAttribute(a):void 0;if(v==null&&a in e)v=e[a];const t=R(v);if(t){if(e.setAttribute)e.setAttribute(a,t);try{if(a in e)e[a]=t}catch{}}}catch{}})});document.querySelectorAll("a").forEach(e=>{try{const r=e.getBoundingClientRect(),txt=N(e.textContent);if(txt==="Claude"&&r.left<100&&r.top<100)e.style.visibility="hidden"}catch{}})}catch{}}
T();
new MutationObserver(()=>{clearTimeout(window.__claudeZhDomTimer);window.__claudeZhDomTimer=setTimeout(T,30)}).observe(document.documentElement,{subtree:true,childList:true,characterData:true,attributes:true});
}catch(e){}})()
'@
    return $template.Replace("__LANGUAGE__", $languageJson).Replace("__MAPPING__", $mappingJson).Replace("__SELECTED_TEXT__", $selectedTextJson).Replace("__DELETE_SELECTED_TEXT__", $deleteSelectedTextJson)
}

function Remove-ExistingOnlineDomTranslationPatch {
    param([string]$Text)

    $markerComment = "/*$OnlineLocaleMainMarker*/"
    $markerIndex = $Text.IndexOf($markerComment, [System.StringComparison]::Ordinal)
    if ($markerIndex -lt 0) {
        return @{ Text = $Text; Removed = $false }
    }

    Write-Host "  [进度] 检测到旧版在线 DOM 补丁标记，正在快速定位旧注入..." -ForegroundColor DarkGray
    $eventAnchor = '.webContents.on("dom-ready",()=>{'
    $anchorIndex = $Text.LastIndexOf($eventAnchor, $markerIndex, [System.StringComparison]::Ordinal)
    if ($anchorIndex -lt 1) {
        Write-Host "  [警告] 找到旧补丁标记，但无法定位 dom-ready 注入起点；将保留原内容继续。" -ForegroundColor DarkYellow
        return @{ Text = $Text; Removed = $false }
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
        Write-Host "  [警告] 找到旧补丁标记，但无法识别 webContents 变量名；将保留原内容继续。" -ForegroundColor DarkYellow
        return @{ Text = $Text; Removed = $false }
    }

    $receiver = $Text.Substring($receiverStart, $anchorIndex - $receiverStart)
    $bodyStart = $anchorIndex + $eventAnchor.Length
    $executeNeedle = ";" + $receiver + ".webContents.executeJavaScript("
    $executeIndex = $Text.LastIndexOf($executeNeedle, $markerIndex, [System.StringComparison]::Ordinal)
    if (($executeIndex -lt $bodyStart) -or (-not $Text.Substring($markerIndex - 3, 3).Equals("});", [System.StringComparison]::Ordinal))) {
        Write-Host "  [警告] 找到旧补丁标记，但旧注入结构不符合预期；将保留原内容继续。" -ForegroundColor DarkYellow
        return @{ Text = $Text; Removed = $false }
    }

    $body = $Text.Substring($bodyStart, $executeIndex - $bodyStart)
    $replacement = $receiver + '.webContents.on("dom-ready",()=>{' + $body + '});'
    $patchedEnd = $markerIndex + $markerComment.Length
    $patchedText = $Text.Substring(0, $receiverStart) + $replacement + $Text.Substring($patchedEnd)
    return @{ Text = $patchedText; Removed = $true }
}

function Find-OnlineDomTranslationHook {
    param([string]$Text)

    $readyNeedle = "main_view_dom_ready"
    $eventAnchor = '.webContents.on("dom-ready",()=>{'
    $handlerEndNeedle = "});"

    Write-Host "  [进度] 正在快速扫描 dom-ready handler..." -ForegroundColor DarkGray
    $searchIndex = 0
    $checked = 0
    while ($true) {
        $anchorIndex = $Text.IndexOf($eventAnchor, $searchIndex, [System.StringComparison]::Ordinal)
        if ($anchorIndex -lt 0) {
            Write-Host "  [进度] 已扫描 $checked 个 dom-ready handler，未找到 main_view_dom_ready handler，准备尝试 legacy 注入点..." -ForegroundColor DarkGray
            return @{ Success = $false }
        }
        $checked += 1

        $bodyStart = $anchorIndex + $eventAnchor.Length
        $handlerEnd = $Text.IndexOf($handlerEndNeedle, $bodyStart, [System.StringComparison]::Ordinal)
        if ($handlerEnd -lt $bodyStart) {
            Write-Host "  [进度] 第 $checked 个 dom-ready handler 结束位置异常，继续查找下一个..." -ForegroundColor DarkGray
            $searchIndex = $bodyStart
            continue
        }

        $body = $Text.Substring($bodyStart, $handlerEnd - $bodyStart).TrimEnd(";")
        if (-not $body.Contains($readyNeedle)) {
            $searchIndex = $handlerEnd + $handlerEndNeedle.Length
            continue
        }

        Write-Host "  [进度] 已找到包含 main_view_dom_ready 的 dom-ready handler，正在识别 webContents 变量..." -ForegroundColor DarkGray
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
            Write-Host "  [进度] 无法识别 webContents 变量名，继续查找下一个 handler..." -ForegroundColor DarkGray
            $searchIndex = $handlerEnd + $handlerEndNeedle.Length
            continue
        }

        $receiver = $Text.Substring($receiverStart, $anchorIndex - $receiverStart)
        $hookLength = ($handlerEnd + $handlerEndNeedle.Length) - $receiverStart
        Write-Host "  [进度] 在线 DOM 注入点定位完成：handler=$checked, receiver=$receiver。" -ForegroundColor DarkGray
        return @{
            Success = $true
            Index = $receiverStart
            Length = $hookLength
            Receiver = $receiver
            Body = $body
        }
    }
}

function Patch-OnlineDomTranslation {
    param(
        [string]$ResourcesPath,
        [object]$Pack,
        [string]$Language
    )

    Write-Host "  preparing online claude.ai DOM translation patch" -ForegroundColor DarkGray
    $asarInfo = Get-Item -LiteralPath (Join-Path $ResourcesPath "app.asar")
    Write-Host "  [进度] 正在读取 app.asar ($(Format-ByteSize $asarInfo.Length))..." -ForegroundColor DarkGray
    $asar = Read-AsarFileContent $ResourcesPath $AsarPatchTarget
    Write-Host "  [进度] app.asar 读取完成，正在解析 asar 头..." -ForegroundColor DarkGray
    Write-Host "  [进度] asar 头解析完成，正在提取 main-process bundle..." -ForegroundColor DarkGray
    $content = $asar.Content
    $contentSize = [int64]$asar.Entry.size
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
        $injectedBody = $body + ";" + $receiver + ".webContents.executeJavaScript(" + $scriptLiteral + ").catch(()=>{})"
        $injection = $receiver + '.webContents.on("dom-ready",()=>{' + $injectedBody + '});/*' + $OnlineLocaleMainMarker + '*/'
        if ($text.Contains($injection)) {
            Write-Host "  online claude.ai DOM translation already patched" -ForegroundColor Green
            return
        }

        Write-Host "  injecting online DOM translation hook" -ForegroundColor DarkGray
        $hookIndex = [int]$hookMatch["Index"]
        $hookLength = [int]$hookMatch["Length"]
        $patched = $text.Substring(0, $hookIndex) + $injection + $text.Substring($hookIndex + $hookLength)
        $patchedContent = [System.Text.Encoding]::UTF8.GetBytes($patched)
        [void](Replace-AsarFileContent $ResourcesPath $AsarPatchTarget $patchedContent)
        $action = if ($hadExisting) { "refreshed" } else { "patched" }
        Write-Host "  $action online claude.ai DOM translation: $($mapping.Count) strings" -ForegroundColor Green
        return
    }

    $legacyAnchor = 's.webContents.on("dom-ready",()=>{DIA()});'
    if (-not $text.Contains($legacyAnchor)) {
        Write-Host "  [警告] 未找到在线 claude.ai DOM 翻译注入点，跳过 app.asar 在线页面补丁；本地中文资源和语言配置会继续安装。" -ForegroundColor DarkYellow
        return
    }

    $injection = 's.webContents.on("dom-ready",()=>{DIA();s.webContents.executeJavaScript(' + $scriptLiteral + ').catch(()=>{})});/*' + $OnlineLocaleMainMarker + '*/'
    if ($text.Contains($injection)) {
        Write-Host "  online claude.ai DOM translation already patched" -ForegroundColor Green
        return
    }

    $anchorIndex = $text.IndexOf($legacyAnchor, [System.StringComparison]::Ordinal)
    Write-Host "  injecting legacy online DOM translation hook" -ForegroundColor DarkGray
    $patched = $text.Substring(0, $anchorIndex) + $injection + $text.Substring($anchorIndex + $legacyAnchor.Length)
    $patchedContent = [System.Text.Encoding]::UTF8.GetBytes($patched)
    [void](Replace-AsarFileContent $ResourcesPath $AsarPatchTarget $patchedContent)
    $action = if ($hadExisting) { "refreshed" } else { "patched" }
    Write-Host "  $action online claude.ai DOM translation: $($mapping.Count) strings" -ForegroundColor Green
}

function Patch-HardcodedFrontendStrings {
    param(
        [string]$ResourcesPath,
        [string]$Language
    )

    $jsFiles = Get-FrontendJsBundleFiles $ResourcesPath

    $replacements = @(Get-FrontendHardcodedReplacements $Language)
    $patchedFiles = 0
    $patchedStrings = 0
    foreach ($file in $jsFiles) {
        $text = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
        $patched = $text
        $count = 0
        foreach ($pair in $replacements) {
            $source = $pair[0]
            $target = $pair[1]
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
        }
    }

    Write-Host "  patched hardcoded frontend strings: $patchedStrings replacements in $patchedFiles files" -ForegroundColor Green
}

function Patch-Custom3PModelValidation {
    param([string]$ResourcesPath)

    $oldExpr = [System.Text.Encoding]::ASCII.GetBytes('process.env.NODE_ENV!=="production"')
    $newExprText = "false".PadRight($oldExpr.Length, " ")

    $asar = Read-AsarFileContent $ResourcesPath $AsarPatchTarget
    $content = $asar.Content
    $data = $asar.Data
    $header = $asar.Header
    $entry = $asar.Entry
    $contentOffset = $asar.ContentOffset
    $asarPath = $asar.AsarPath
    $match = Find-Custom3PValidationToggle $content 'process.env.NODE_ENV!=="production"'
    if ($null -eq $match) {
        $patchedMatch = Find-Custom3PValidationToggle $content $newExprText
        if ($null -ne $patchedMatch) {
            Write-Host "  custom 3P model-name validation already patched" -ForegroundColor Green
            Sync-ClaudeExeAsarIntegrity $ResourcesPath
            return
        }
        $patchedNameValidator = Find-Custom3PNameValidator $content $true
        if ($null -ne $patchedNameValidator) {
            Write-Host "  custom 3P model-name validation already patched" -ForegroundColor Green
            Sync-ClaudeExeAsarIntegrity $ResourcesPath
            return
        }
        if (-not (Patch-Custom3PNameValidator $content)) {
            if (Test-Custom3PValidationRemoved $content) {
                Write-Host "  custom 3P model-name validation not present (removed in this Claude version)" -ForegroundColor Green
                return
            }
            throw "Could not patch custom 3P model validation. Claude bundle format may have changed."
        }
    }
    else {
        $anchorText = $match.Value
        $patchedAnchorText = 'const ' + $match.Groups[1].Value + '=' + $newExprText + '||!1,' + $match.Groups[2].Value + '='
        $anchor = [System.Text.Encoding]::ASCII.GetBytes($anchorText)
        $patchedAnchor = [System.Text.Encoding]::ASCII.GetBytes($patchedAnchorText)
        if ($anchor.Length -ne $patchedAnchor.Length) {
            throw "Internal patch error: custom 3P validation replacement changed length."
        }

        $matchOffset = $match.Index
        [System.Array]::Copy($patchedAnchor, 0, $content, $matchOffset, $patchedAnchor.Length)
    }

    Write-AsarContentInPlace $ResourcesPath $data ($header | ConvertTo-Json -Compress -Depth 100) $headerSize $entry $content
    Write-Host "  patched custom 3P model-name validation in app.asar" -ForegroundColor Green
}

function Patch-CoworkModernInstallerCheck {
    param([string]$ResourcesPath)

    $asar = Read-AsarFileContent $ResourcesPath $AsarPatchTarget
    $content = $asar.Content
    $data = $asar.Data
    $header = $asar.Header
    $entry = $asar.Entry
    $contentOffset = $asar.ContentOffset
    $headerSize = $asar.HeaderSize
    $asarPath = $asar.AsarPath
    $contentText = [System.Text.Encoding]::ASCII.GetString($content)

    if (
        $contentText.Contains('function _I(){return mo?(XX="patched",sP=!0,!0):!1}') -or
        $contentText.Contains('function LI(){return io?(nAA="patched",A2=!0,!0):!1}')
    ) {
        Write-Host "  Cowork modern installer check already patched" -ForegroundColor Green
        Sync-ClaudeExeAsarIntegrity $ResourcesPath
        return
    }

    $patches = @(
        @{
            Source = 'function _I(){return mo?sP!==void 0?sP:process.windowsStore?(XX="windowsStore",sP=!0,!0):uVe()?(XX="appPath",sP=!0,!0):(XX=null,sP=!1,!1):!1}'
            Target = 'function _I(){return mo?(XX="patched",sP=!0,!0):!1}'
        },
        @{
            Source = 'function LI(){return io?A2!==void 0?A2:process.windowsStore?(nAA="windowsStore",A2=!0,!0):pje()?(nAA="appPath",A2=!0,!0):(nAA=null,A2=!1,!1):!1}'
            Target = 'function LI(){return io?(nAA="patched",A2=!0,!0):!1}'
        }
    )

    $selectedPatch = $null
    $sourceIndex = -1
    foreach ($candidate in $patches) {
        $source = [string]$candidate["Source"]
        $candidateIndex = $contentText.IndexOf($source, [System.StringComparison]::Ordinal)
        if ($candidateIndex -lt 0) {
            continue
        }
        if ($contentText.IndexOf($source, $candidateIndex + $source.Length, [System.StringComparison]::Ordinal) -ge 0) {
            Write-Host "  [警告] Cowork modern installer check 匹配到多个候选，跳过该补丁；中文补丁和第三方模型名补丁已继续保留。" -ForegroundColor DarkYellow
            return
        }
        $selectedPatch = $candidate
        $sourceIndex = $candidateIndex
        break
    }

    if ($null -eq $selectedPatch) {
        Write-Host "  [警告] 未找到 Cowork modern installer check 补丁点，跳过该补丁；中文补丁和第三方模型名补丁已继续保留。" -ForegroundColor DarkYellow
        return
    }

    $source = [string]$selectedPatch["Source"]
    $target = [string]$selectedPatch["Target"]
    if ($target.Length -gt $source.Length) {
        throw "Internal patch error: Cowork installer check replacement is longer than source."
    }
    $target = $target.PadRight($source.Length, " ")

    $replacement = [System.Text.Encoding]::ASCII.GetBytes($target)
    [System.Array]::Copy($replacement, 0, $content, $sourceIndex, $replacement.Length)

    Write-AsarContentInPlace $ResourcesPath $data ($header | ConvertTo-Json -Compress -Depth 100) $headerSize $entry $content
    Write-Host "  patched Cowork modern installer check in app.asar" -ForegroundColor Green
}

function Patch-HardcodedMainProcessMenuLabels {
    param(
        [string]$ResourcesPath,
        [string]$Language
    )

    switch ($Language) {
        "zh-CN" {
            $replacements = @(
                @("File", "文件"),
                @("Edit", "编辑"),
                @("View", "查看"),
                @("Developer", "开发者"),
                @("Help", "帮助"),
                @("Extensions", "扩展"),
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
                @("Record Memory Trace (auto-stop)", "记录内存跟踪 (自动)")
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
                @("9GRz7bC+rr", "配置第三方推理…")
            )
        }
        "zh-TW" {
            $replacements = @(
                @("File", "檔案"),
                @("Edit", "編輯"),
                @("View", "檢視"),
                @("Developer", "開發者"),
                @("Help", "說明"),
                @("Extensions", "擴充功能"),
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
                @("Record Memory Trace (auto-stop)", "記錄記憶體追蹤 (自動)")
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
                @("9GRz7bC+rr", "設定第三方推理…")
            )
        }
        "zh-HK" {
            $replacements = @(
                @("File", "檔案"),
                @("Edit", "編輯"),
                @("View", "檢視"),
                @("Developer", "開發者"),
                @("Help", "說明"),
                @("Extensions", "擴充功能"),
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
                @("Record Memory Trace (auto-stop)", "記錄記憶體追蹤 (自動)")
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
                @("9GRz7bC+rr", "設定第三方推理…")
            )
        }
        default {
            throw "Unsupported language for main-process menu labels: $Language"
        }
    }

    $asar = Read-AsarFileContent $ResourcesPath $AsarPatchTarget
    $content = $asar.Content
    $text = [System.Text.Encoding]::UTF8.GetString($content)
    $patched = $text
    $count = 0
    $intlCount = 0
    $repairCount = 0

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
        $pattern = '[A-Za-z_$][A-Za-z0-9_$]*\(\)\.formatMessage\(\{defaultMessage:"(?:\\.|[^"\\])*",id:"' + [regex]::Escape($id) + '"(?:,description:"(?:\\.|[^"\\])*")?\}\)'
        $searchStart = 0
        while ($true) {
            $idIndex = $patched.IndexOf($needle, $searchStart, [System.StringComparison]::Ordinal)
            if ($idIndex -lt 0) {
                break
            }

            $windowStart = [Math]::Max(0, $idIndex - 600)
            $windowEnd = [Math]::Min($patched.Length, $idIndex + 600)
            $window = $patched.Substring($windowStart, $windowEnd - $windowStart)
            $match = [regex]::Match($window, $pattern)
            if (-not $match.Success) {
                $searchStart = $idIndex + $needle.Length
                continue
            }

            $absoluteStart = $windowStart + $match.Index
            $patched = $patched.Substring(0, $absoluteStart) + $literal + $patched.Substring($absoluteStart + $match.Length)
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

    if (($count -eq 0) -and ($intlCount -eq 0) -and ($repairCount -eq 0)) {
        Write-Host "  hardcoded main-process menu labels already patched" -ForegroundColor Green
        return
    }

    $patchedContent = [System.Text.Encoding]::UTF8.GetBytes($patched)
    Replace-AsarFileContent $ResourcesPath $AsarPatchTarget $patchedContent | Out-Null
    if ($repairCount -gt 0) {
        Write-Host "  repaired unsafe short main-process menu replacements: $repairCount occurrences" -ForegroundColor Yellow
    }
    Write-Host "  patched hardcoded main-process menu labels: $($count + $intlCount) replacements" -ForegroundColor Green
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

        $config = Get-JsonObjectOrBackup $configPath

        $config | Add-Member -NotePropertyName "locale" -NotePropertyValue $Locale -Force
        $config | ConvertTo-Json -Depth 20 | Set-Content $configPath -Encoding UTF8
        Write-Host "  locale=${Locale}: $configPath" -ForegroundColor Green
    }
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

function Add-OrSetJsonProperty {
    param(
        [pscustomobject]$Object,
        [string]$Name,
        [object]$Value
    )

    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
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

function Initialize-CCSwitchSkillsSync {
    $skillsDirectory = Get-CCSwitchSkillsDirectory
    $pluginRoot = Find-ClaudeDesktopSkillsPluginRoot
    $desktopSkillsDirectory = Join-Path $pluginRoot "skills"
    $manifestPath = Join-Path $pluginRoot "manifest.json"
    $manifest = Get-JsonObjectOrBackup $manifestPath
    Ensure-SkillsManifestList $manifest
    return @{
        SkillsDirectory = $skillsDirectory
        PluginRoot = $pluginRoot
        DesktopSkillsDirectory = $desktopSkillsDirectory
        ManifestPath = $manifestPath
        Manifest = $manifest
    }
}

function Sync-CCSwitchSkills {
    $ctx = Initialize-CCSwitchSkillsSync
    $skillsDirectory = $ctx.SkillsDirectory
    $pluginRoot = $ctx.PluginRoot
    $desktopSkillsDirectory = $ctx.DesktopSkillsDirectory
    $manifestPath = $ctx.ManifestPath
    $manifest = $ctx.Manifest

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
    $ctx = Initialize-CCSwitchSkillsSync
    $skillsDirectory = $ctx.SkillsDirectory
    $pluginRoot = $ctx.PluginRoot
    $desktopSkillsDirectory = $ctx.DesktopSkillsDirectory
    $manifestPath = $ctx.ManifestPath
    $manifest = $ctx.Manifest
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

function Stop-ClaudeProcessesGracefully {
    param(
        [int]$TimeoutSeconds = 10
    )

    $procs = @()
    foreach ($proc in Get-Process -Name "claude" -ErrorAction SilentlyContinue) {
        try {
            $path = $proc.MainModule.FileName
            if ($path -and ($path -match "WindowsApps\\Claude_" -or $path -match "AnthropicClaude\\app-")) {
                $procs += $proc
            }
        } catch {
            # MainModule inaccessible (permission or 32/64 mismatch) — skip
        }
    }

    if ($procs.Count -eq 0) {
        return $true
    }

    # 第一层：发送 WM_CLOSE 消息（/T 通知子进程，不带 /F），允许 Electron 执行 app.quit() 和数据库 flush
    foreach ($proc in $procs) {
        Write-Host "  正在请求 Claude Desktop 优雅退出 (PID $($proc.Id))..." -ForegroundColor DarkGray
        try {
            $null = & taskkill /PID $proc.Id /T 2>&1
        } catch {
            # taskkill 失败，继续等待超时后强制终止
        }
    }

    # 等待进程退出，每秒检查一次，提前跳出
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        Start-Sleep -Seconds 1
        $elapsed++
        $stillRunning = @()
        foreach ($proc in $procs) {
            if (-not $proc.HasExited) {
                $stillRunning += $proc
            }
        }
        if ($stillRunning.Count -eq 0) {
            Write-Host "  Claude Desktop 已优雅退出" -ForegroundColor Green
            return $true
        }
        $procs = $stillRunning
    }

    # 第二层：超时后才回退到 taskkill /T /F 强制终止进程树
    Write-Host "  优雅退出超时（${TimeoutSeconds}秒），强制终止剩余进程..." -ForegroundColor DarkYellow
    foreach ($proc in $procs) {
        if (-not $proc.HasExited) {
            try {
                $null = & taskkill /PID $proc.Id /T /F 2>&1
            } catch {
                # 已退出或无法终止
            }
        }
    }

    Start-Sleep -Seconds 1
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
        Start-Process $exe
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
        Write-Step "[1/9] 检查安装模式"
        if ($PatchMode -eq "safe") {
            Write-Host "  Cowork 兼容模式：无需第三方 API 配置检查。" -ForegroundColor Green
        } elseif ($PatchMode -eq "official") {
            Write-Host "  官方账号登录模式：无需第三方 API 配置检查。" -ForegroundColor Green
        } else {
            Write-Host "  第三方 API 登录模式：无需第三方 API 配置检查。" -ForegroundColor Green
        }

        Write-Step "[2/9] 检查语言资源"
        $pack = Get-LanguageResources $LanguageCode

        Write-Step "关闭 Claude Desktop"
        Stop-ClaudeProcesses

        Write-Step "[3/9] 查找 Claude Desktop"
        $paths = Get-ClaudeResourcesPath
        $claudePath = $paths["App"]
        $resourcesPath = $paths["Resources"]
        Write-Host "  app: $claudePath" -ForegroundColor Green
        Write-Host "  resources: $resourcesPath" -ForegroundColor Green

        Write-Step "[4/9] 准备写入权限"
        Enable-WriteAccess $resourcesPath
        Remove-LegacyAppxForkArtifacts

        Write-Step "[5/9] 写入 $label 资源"
        Install-LanguageFiles $resourcesPath $pack $LanguageCode

        Write-Step "[6/9] 注册中文语言"
        Register-Language $resourcesPath $LanguageCode

        Write-Step "[7/9] 汉化硬编码界面文本"
        Patch-HardcodedFrontendStrings $resourcesPath $LanguageCode
        Patch-LanguageDisplayNames $resourcesPath
        if (Test-OnlineAccountPatchEnabled) {
            Write-AsarCoworkSignatureWarning
            Patch-OnlineDomTranslation $resourcesPath $pack $LanguageCode
            Patch-HardcodedMainProcessMenuLabels $resourcesPath $LanguageCode
        } else {
            Write-Host "  skipping online claude.ai DOM translation patch (app.asar) due to patch mode: $PatchMode" -ForegroundColor DarkYellow
            Write-Host "  skipping main-process menu label patch (app.asar) due to patch mode: $PatchMode" -ForegroundColor DarkYellow
        }

        Write-Step "[8/9] 修复第三方模型名校验"
        if (Test-Custom3PPatchEnabled) {
            Patch-Custom3PModelValidation $resourcesPath
            Patch-CoworkModernInstallerCheck $resourcesPath
        } else {
            Write-Host "  skipping 3P model validation patch (app.asar) due to patch mode: $PatchMode" -ForegroundColor DarkYellow
        }

        if (-not (Test-AsarPatchEnabled)) {
            Write-Host "  skipping Claude.exe asar integrity sync due to patch mode: $PatchMode" -ForegroundColor DarkYellow
        }

        Write-Step "[9/9] 写入用户语言配置"
        Set-ClaudeLocale $LanguageCode

        Write-Step "重启 Claude Desktop"
        Restart-Claude $claudePath

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

try {
    switch ($Action) {
        "install" { Install-WindowsLanguagePack }
        "uninstall" { Uninstall-WindowsLanguagePack }
        "sync-skills" { Sync-CCSwitchSkills }
        "unsync-skills" { Unsync-CCSwitchSkills }
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
