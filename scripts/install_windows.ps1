# 本汉化包只处理第三方 API 模式。Claude 官方已原生支持简体/繁体中文界面，
# 在线账号模式的中文化交给官方实现，这里不再改写 app.asar，也不再改动
# Claude.exe 的完整性哈希（否则会破坏 Authenticode 签名并牵连 Cowork）。
param(
    [switch]$Interactive,

    [Parameter(Position = 0)]
    [ValidateSet("install", "uninstall", "disable-updates", "enable-updates", "sync-skills", "unsync-skills")]
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
$AsarIntegrityBlockSize = 4 * 1024 * 1024
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
    Write-Host "[1] 安装中文补丁（第三方 API 模式，例如 DeepSeek；不会改动 app.asar / Claude.exe 签名）"
    Write-Host "    官方账号登录界面已由 Claude 原生提供中文，无需本补丁。"
    Write-Host "[2] 恢复原样 / 卸载补丁"
    Write-Host "[3] 自动更新设置（y=禁止自动更新，n=允许自动更新）"
    Write-Host "[4] 同步 CC Switch skills（y=开启同步，n=删除同步）"
    Write-Host "[Q] 退出"
    Write-Host ""

    $actionSelected = $false
    $selectedAction = "install"
    while (-not $actionSelected) {
        $actionSelection = (Read-Host "请选择操作 [1/2/3/4/Q]").Trim()
        switch -Regex ($actionSelection) {
            '^[1]$' { $selectedAction = "install"; $actionSelected = $true }
            '^[2]$' { return @{ Action = "uninstall"; Language = "zh-CN" } }
            '^[3]$' {
                $updateChoice = (Read-Host "是否禁止自动更新？[y=禁止 / n=允许]").Trim()
                switch -Regex ($updateChoice) {
                    '^[Yy]$' { return @{ Action = "disable-updates"; Language = "zh-CN" } }
                    '^[Nn]$' { return @{ Action = "enable-updates"; Language = "zh-CN" } }
                    default {
                        Write-Host "无效输入，请输入 y 禁止自动更新，或输入 n 允许自动更新。" -ForegroundColor Yellow
                        continue
                    }
                }
            }
            '^[4]$' {
                $skillsChoice = (Read-Host "是否同步 CC Switch skills？[y=开启同步 / n=删除同步]").Trim()
                switch -Regex ($skillsChoice) {
                    '^[Yy]$' { return @{ Action = "sync-skills"; Language = "zh-CN" } }
                    '^[Nn]$' { return @{ Action = "unsync-skills"; Language = "zh-CN" } }
                    default {
                        Write-Host "无效输入，请输入 y 开启同步，或输入 n 删除同步。" -ForegroundColor Yellow
                        continue
                    }
                }
            }
            '^[Qq]$' { exit 0 }
            default { Write-Host "请输入 1、2、3、4 或 Q。" -ForegroundColor Yellow }
        }
    }

    Write-Host ""
    if ($selectedAction -eq "install") {
        # 预清理只用于“先恢复旧补丁再安装”。它需要定位已安装的 Claude，
        # 定位失败时不能让整个安装器退出（issue #199：闪退），只提示后继续，
        # 由后面的安装步骤给出更准确的错误。
        try {
            Invoke-PreInstallCleanup
        }
        catch {
            Write-Host ""
            Write-Host "[警告] 安装前清理旧补丁未完成：$($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "        将继续安装流程。" -ForegroundColor Yellow
        }
        Write-Host ""
    }

    Write-Host "请选择要安装的语言："
    Write-Host "[1] 简体中文"
    Write-Host "[2] 繁體中文（台灣）"
    Write-Host "[3] 繁體中文（香港）"
    Write-Host "[Q] 退出"
    Write-Host ""

    while ($true) {
        $languageSelection = (Read-Host "请选择语言 [1/2/3/Q]").Trim()
        switch -Regex ($languageSelection) {
            '^[1]$' { return @{ Action = $selectedAction; Language = "zh-CN" } }
            '^[2]$' { return @{ Action = $selectedAction; Language = "zh-TW" } }
            '^[3]$' { return @{ Action = $selectedAction; Language = "zh-HK" } }
            '^[Qq]$' { exit 0 }
            default { Write-Host "请输入 1、2、3 或 Q。" -ForegroundColor Yellow }
        }
    }
}





function Get-LanguageLabel {
    param([string]$Code)
    switch ($Code) {
        "zh-CN" { return "简体中文" }
        "zh-TW" { return "繁體中文（台灣）" }
        "zh-HK" { return "繁體中文（香港）" }
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


function Get-ClaudeAppxPackages {
    # 商店版包名可能调整（issue #194：2.19675.0 起由 Claude 改名为 AnthropicPBC.Claude），
    # 按名称/发布者模糊匹配，误报由调用方对 resources 目录的校验兜底。
    return @(Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object {
            ($_.Name -like "*Claude*") -or ($_.Publisher -like "*Anthropic*")
        })
}

function Find-ClaudePath {
    $packages = @(Get-ClaudeAppxPackages)
    foreach ($package in $packages) {
        if ($package.InstallLocation -and (Test-Path $package.InstallLocation)) {
            return $package.InstallLocation
        }
    }

    $fallback = Get-ChildItem "C:\Program Files\WindowsApps" -Directory -Filter "*Claude*" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($fallback) {
        return $fallback.FullName
    }

    return $null
}

function Get-ClaudeExeProductVersion {
    param([string]$ClaudePath)

    foreach ($name in @("Claude.exe", "claude.exe")) {
        $exePath = Join-Path $ClaudePath $name
        if (Test-Path -LiteralPath $exePath) {
            try {
                return [string](Get-Item -LiteralPath $exePath).VersionInfo.ProductVersion
            }
            catch {
                return "未知"
            }
        }
    }
    return "未知"
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

    # 化石目录防线（issue #196）：升级/换渠道安装后，%LocalAppData%\AnthropicClaude
    # 可能残留旧渠道的 app-* 目录（例如 fast-ring 时代的 app-1.0.x）。它们能通过
    # Claude.exe + resources 的基础检测，但里面没有前端 bundle；旧逻辑选中这类目录
    # 后，前几步往空目录里"成功"写入资源，最后在注册语言时才报
    # "未找到前端 JS bundle"。这里要求候选目录真的能定位到前端 JS，否则跳过并
    # 尝试下一个候选；全部无效时回退商店版（AppX）检测。
    $rejectedHints = @()
    foreach ($candidatePath in $script:DetectedUnpackagedClaudePaths) {
        $candidateResources = Join-Path $candidatePath "resources"
        if (-not (Test-Path $candidateResources)) {
            $rejectedHints += "  跳过 ${candidatePath}（缺少 resources 目录）"
            continue
        }
        if (-not (Resolve-FrontendAssetsDir $candidateResources)) {
            $rejectedHints += "  跳过 ${candidatePath}（前端 JS bundle 缺失，版本 $(Get-ClaudeExeProductVersion $candidatePath)，疑似残留旧版本目录）"
            continue
        }

        $claudePath = $candidatePath
        $resourcesPath = $candidateResources
        if ($script:DetectedUnpackagedClaudePaths.Count -gt 1) {
            $script:DetectedMultipleClaudeInstalls = $true
            Write-Host "  [提示] 检测到多个 %LocalAppData%\AnthropicClaude\app-*，已选用可补丁的最新版本: $claudePath" -ForegroundColor Yellow
        }
        Write-Host "  Claude 版本: $(Get-ClaudeExeProductVersion $claudePath)" -ForegroundColor DarkGray
        return @{
            App = $claudePath
            Resources = $resourcesPath
            InstallKind = "Unpackaged"
        }
    }

    if ($script:DetectedUnpackagedClaudePaths.Count -gt 0) {
        Write-Host "  [警告] 以下本地 app-* 目录无法作为补丁目标：" -ForegroundColor Yellow
        foreach ($hint in $rejectedHints) {
            Write-Host $hint -ForegroundColor Yellow
        }
        Write-Host "  [提示] 继续尝试商店版（AppX）安装检测。" -ForegroundColor Yellow
    }

    $claudePath = Find-ClaudePath
    if (-not $claudePath) {
        if ($script:DetectedUnpackagedClaudePaths.Count -gt 0) {
            throw "未找到可补丁的 Claude Desktop 安装：本地 app-* 目录均缺前端 bundle，商店版也未检测到。请确认 Claude Desktop 已完整安装（安装后至少启动过一次），或清理旧 app-* 目录后重试。"
        }
        throw "未找到 Claude Desktop 安装。"
    }

    $resourcesPath = Join-Path $claudePath "app\resources"
    if (-not (Test-Path $resourcesPath)) {
        $resourcesPath = Join-Path $claudePath "resources"
    }
    if (-not (Test-Path $resourcesPath)) {
        throw "未找到 Claude resources 目录: $(Join-Path $claudePath 'app\resources')"
    }
    if (-not (Resolve-FrontendAssetsDir $resourcesPath)) {
        throw "未找到前端 JS bundle: $resourcesPath\ion-dist。Claude 前端目录结构可能已变化，请带上安装日志反馈。"
    }

    Write-Host "  Claude 版本: $(Get-ClaudeExeProductVersion $claudePath)" -ForegroundColor DarkGray
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
    $packages = @(Get-ClaudeAppxPackages)
    foreach ($package in $packages) {
        if ($package.PackageFamilyName) {
            $packageNames += $package.PackageFamilyName
        }
    }

    if ($packageNames.Count -eq 0) {
        $packageRoot = Join-Path $env:LOCALAPPDATA "Packages"
        $packageDirs = @(Get-ChildItem (Join-Path $packageRoot "*Claude_*") -Directory -ErrorAction SilentlyContinue |
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

function Assert-WindowsIconBytes {
    param([byte[]]$Bytes, [string]$Path)

    if ($bytes.Length -lt 6 -or [BitConverter]::ToUInt16($bytes, 0) -ne 0 -or
        [BitConverter]::ToUInt16($bytes, 2) -ne 1) {
        throw "无效的 Windows 托盘 ICO: $path"
    }
    $count = [BitConverter]::ToUInt16($bytes, 4)
    $headerSize = 6 + 16 * $count
    if ($count -eq 0 -or $bytes.Length -lt $headerSize) { throw "不完整的 Windows 托盘 ICO: $path" }
    for ($i = 0; $i -lt $count; $i++) {
        $length = [BitConverter]::ToUInt32($bytes, 6 + 16 * $i + 8)
        $offset = [BitConverter]::ToUInt32($bytes, 6 + 16 * $i + 12)
        if ($length -eq 0 -or $offset -lt $headerSize -or ([long]$offset + $length) -gt $bytes.Length) {
            throw "Windows 托盘 ICO 图像越界: $path"
        }
    }
}

function Get-WindowsTrayIconBytes {
    $path = Join-Path (Split-Path -Parent $PSScriptRoot) 'resources\claude-tray-windows.ico'
    $bytes = [IO.File]::ReadAllBytes($path)
    Assert-WindowsIconBytes $bytes $path
    return ,$bytes
}

function Install-WindowsTrayIcons {
    param([string]$ResourcesPath, [byte[]]$IconBytes)

    Assert-WindowsIconBytes $IconBytes 'claude-tray-windows.ico'
    $targets = @('Tray-Win32.ico', 'Tray-Win32-Dark.ico' | ForEach-Object { Join-Path $ResourcesPath $_ })
    foreach ($target in $targets) {
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            Write-Host "  [警告] 未找到已知 Windows 托盘资源，跳过图标替换: $target" -ForegroundColor Yellow
            return $false
        }
    }
    $originals = @{}
    $changed = @()
    $replacement = [Convert]::ToBase64String($IconBytes)
    foreach ($target in $targets) {
        $originals[$target] = [IO.File]::ReadAllBytes($target)
        if ([Convert]::ToBase64String($originals[$target]) -cne $replacement) { $changed += $target }
    }
    if ($changed.Count -eq 0) { return $false }

    # 两份原图均完成备份后才写入，卸载时由通用资源恢复流程还原。
    foreach ($target in $targets) {
        Backup-ModifiedFile $ResourcesPath $target
        $backup = Join-Path (New-BackupSet $ResourcesPath) (Split-Path -Leaf $target)
        if (-not (Test-Path -LiteralPath $backup -PathType Leaf)) { throw "托盘图标备份失败: $target" }
        Assert-WindowsIconBytes ([IO.File]::ReadAllBytes($backup)) $backup
    }
    $attempted = @()
    try {
        foreach ($target in $changed) {
            $attempted += $target
            [IO.File]::WriteAllBytes($target, $IconBytes)
        }
    } catch {
        foreach ($target in $attempted) {
            if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($target)) -cne [Convert]::ToBase64String($originals[$target])) {
                [IO.File]::WriteAllBytes($target, $originals[$target])
            }
        }
        throw
    }
    Write-Host "  已替换 Windows 明暗主题托盘图标：橙底白色星标" -ForegroundColor Green
    return $true
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
        (Join-Path $ResourcesPath "ion-dist\i18n\dynamic"),
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

    # Claude 2.9939.2 起前端强制加载 dynamic catalog，缺失会让整个语言包加载失败并
    # 回退英文。其 key 为内容哈希、随包词表暂无对应翻译，按官方 en-US 原文兜底。
    $dynamicDir = Join-Path $i18nDir "dynamic"
    $dynamicEn = Join-Path $dynamicDir "en-US.json"
    if (Test-Path $dynamicEn) {
        New-Item -ItemType Directory -Path $dynamicDir -Force | Out-Null
        Copy-Item $dynamicEn (Join-Path $dynamicDir "$Lang.json") -Force
        Write-Host "  installed ion-dist/i18n/dynamic/$Lang.json" -ForegroundColor Green
    }
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

function Get-FrontendJsFilesContaining {
    param(
        [string]$AssetsDir,
        [string[]]$Needles
    )

    $jsFiles = @(Get-ChildItem (Join-Path $AssetsDir "*.js") -File -ErrorAction SilentlyContinue)
    if ($jsFiles.Count -eq 0) {
        Write-Host "  [提示] 目录中没有前端 JS 文件: $AssetsDir" -ForegroundColor DarkYellow
        return @()
    }

    $patterns = @($Needles | Where-Object { $_ })
    $keep = 0
    foreach ($needle in $patterns) {
        $keep = [Math]::Max($keep, $needle.Length - 1)
    }
    $matched = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    foreach ($file in $jsFiles) {
        # StreamReader preserves UTF-8 characters split across reads. Keep enough
        # overlap for the longest needle, rather than imposing a fixed limit.
        $reader = [System.IO.StreamReader]::new($file.FullName, [System.Text.Encoding]::UTF8)
        try {
            $buffer = [char[]]::new(1024 * 1024)
            $carry = ""
            while (($read = $reader.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $chunk = $carry + [string]::new($buffer, 0, $read)
                foreach ($needle in $patterns) {
                    if ($chunk.Contains($needle)) {
                        $matched.Add($file)
                        $read = -1
                        break
                    }
                }
                if ($read -lt 0) {
                    break
                }
                $carry = if ($chunk.Length -gt $keep) { $chunk.Substring($chunk.Length - $keep) } else { $chunk }
            }
        }
        finally {
            $reader.Dispose()
        }
    }

    Write-Host "  located $($matched.Count)/$($jsFiles.Count) frontend JS files containing target text" -ForegroundColor DarkGray
    return @($matched)
}

function Resolve-FrontendAssetsDir {
    param([string]$ResourcesPath)

    # 已知布局（Claude 2.x 至 2.31226.1）：ion-dist\assets\v1
    $known = Join-Path $ResourcesPath "ion-dist\assets\v1"
    if (Test-Path (Join-Path $known "*.js")) {
        return $known
    }

    # 兼容未来版本的目录改名/层级变化：在 ion-dist 下递归（限深 3 层）找含 JS
    # bundle 的目录，优先带 index-*.js 的目录，并用语言白名单锚点确认是前端主
    # bundle，避免误选 worker 等辅助 JS 目录。
    $ionDist = Join-Path $ResourcesPath "ion-dist"
    if (-not (Test-Path $ionDist)) {
        return $null
    }

    $probeNeedle = '"en-US","de-DE","fr-FR","ko-KR","ja-JP"'
    $candidateDirs = @(Get-ChildItem $ionDist -Directory -Recurse -Depth 3 -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName "*.js") } |
        Sort-Object @{ Expression = { Test-Path (Join-Path $_.FullName "index-*.js") }; Descending = $true })
    foreach ($dir in $candidateDirs) {
        $matched = @(Get-FrontendJsFilesContaining $dir.FullName @($probeNeedle))
        if ($matched.Count -gt 0) {
            return $dir.FullName
        }
    }

    # 锚点扫不到时退而求其次：主 bundle 目录几乎必含 index-*.js
    foreach ($dir in $candidateDirs) {
        if (Test-Path (Join-Path $dir.FullName "index-*.js")) {
            return $dir.FullName
        }
    }

    return $null
}

function Register-Language {
    param(
        [string]$ResourcesPath,
        [string]$Lang
    )

    $assetsDir = Resolve-FrontendAssetsDir $ResourcesPath
    if (-not $assetsDir) {
        throw "未找到前端 JS bundle（在 $ResourcesPath\ion-dist 下未定位到前端主 bundle）。Claude 前端目录结构可能已变化，请带上安装日志反馈。"
    }
    $jsFiles = @(Get-FrontendJsFilesContaining $assetsDir @('"en-US","de-DE","fr-FR","ko-KR","ja-JP"'))
    if ($jsFiles.Count -eq 0) {
        throw "未能注册中文语言：前端 bundle ($assetsDir) 中找不到语言白名单锚点，Claude 前端格式可能已经变化。"
    }

    $regex = [System.Text.RegularExpressions.Regex]::new($LanguageListPattern)
    $replacement = "$BaseLanguageList,`"$Lang`"]"
    $changed = 0
    $already = 0
    foreach ($file in $jsFiles) {
        $text = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
        if (-not $regex.IsMatch($text)) {
            continue
        }

        # Claude 2.9939.2 起同一 bundle 内有多份语言白名单（导航语言解析与语言可用性
        # 校验各一份），必须全部补上；正则会吞掉已存在的 zh 项，整体替换是幂等的。
        $updated = $regex.Replace($text, $replacement)
        if ($updated -eq $text) {
            Write-Host "  $Lang already registered: $($file.Name)" -ForegroundColor Green
            $already += 1
            continue
        }

        Backup-ModifiedFile $ResourcesPath $file.FullName
        [System.IO.File]::WriteAllText($file.FullName, $updated, $Utf8NoBom)
        Write-Host "  patched language whitelist for ${Lang}: $($file.Name)" -ForegroundColor Green
        $changed += 1
    }

    if (($changed + $already) -eq 0) {
        throw "未能注册中文语言，Claude 前端 bundle 格式可能已经变化。"
    }
}

function Patch-LanguageDisplayNames {
    param([string]$ResourcesPath)

    $assetsDir = Resolve-FrontendAssetsDir $ResourcesPath
    $marker = "__claudeZhLabelPatch"
    if (-not $assetsDir) {
        Write-Host "  [提示] 未定位到前端 JS bundle，跳过语言显示名补丁。" -ForegroundColor DarkYellow
        return
    }
    $jsFiles = @(Get-FrontendJsFilesContaining $assetsDir @("Intl.DisplayNames", $marker))
    if ($jsFiles.Count -eq 0) {
        Write-Host "  no Intl.DisplayNames bundle found; skipping language display names" -ForegroundColor DarkYellow
        return
    }

    $patch = ';(()=>{const e=Intl.DisplayNames&&Intl.DisplayNames.prototype;if(!e||e.__claudeZhLabelPatch)return;const n=e.of;e.of=function(e){const t=String(e);return t==="zh-CN"?"简体中文":t==="zh-HK"?"繁體中文（香港）":t==="zh-TW"?"繁體中文（台灣）":n.call(this,e)},Object.defineProperty(e,"__claudeZhLabelPatch",{value:!0})})();'
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

    $assetsDir = Resolve-FrontendAssetsDir $ResourcesPath
    if (-not $assetsDir) {
        # Claude 已被卸载或前端目录无法定位时安静跳过, 不阻断卸载流程
        Write-Host "  [提示] 未定位到前端 JS bundle($ResourcesPath\ion-dist)，跳过语言注销。" -ForegroundColor DarkYellow
        return
    }
    # 只移除补丁追加到白名单的中文项，保留原生语言对象键和其他语言列表。
    $jsFiles = @(Get-FrontendJsFilesContaining $assetsDir @('"en-US","de-DE","fr-FR","ko-KR","ja-JP"'))
    $regex = [System.Text.RegularExpressions.Regex]::new($LanguageListPattern)
    foreach ($file in $jsFiles) {
        $text = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
        $updated = $regex.Replace($text, "$BaseLanguageList]")
        if ($updated -cne $text) {
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

    # Lowercase single words (hours, tokens, matches...) are object keys or enum
    # values in the bundled JS, not visible text; they are translated by the DOM layer only.
    # Structural literal skip list: high-risk words used as icon names, key modifiers,
    # event suffixes, or core identifiers (#193, #204, #205, #206).
    $structuralLiterals = @(
        '"Search"', 'Search',
        '"Add"', 'Add',
        '"Copy"', 'Copy',
        '"Check"', 'Check',
        '"Tasks"', 'Tasks',
        '"Settings"', 'Settings',
        '"Command"', 'Command',
        '"Cancel"', 'Cancel',
        '"Sort"', 'Sort',
        '"Voice"', 'Voice',
        '"Default"', 'Default',
        '"Arguments"', 'Arguments',
        '"Normal"', 'Normal',
        '"All"', 'All',
        '"Application"', 'Application',
        '"Medium"', 'Medium',
        '"Motion"', 'Motion',
        '"Thinking"', 'Thinking',
        '"Verbose"', 'Verbose'
    )
    return ($Source -cmatch '^[a-z][A-Za-z0-9_]*$') -or ($structuralLiterals -contains $Source)
}

function Test-StructuralJsLiteralContext {
    param(
        [string]$Text,
        [int]$LiteralStart
    )

    # Protects not only the direct KEY:"X" form but also the minified shapes that
    # pass icon/enum names as values: destructure defaults (icon:i="Add"), ternary
    # branches (icon:d?"Check":"Copy", icon:f?"Add":void 0, icon:e.length===0?"A":"B",
    # nested chains), nullish coalescing (icon:f??"Add") and destructure alias defaults
    # (icon:c}=e;h=c===void 0?"Add":c, #204). Translating those strings breaks the
    # icon-name lookup and renders empty button glyphs (#193).
    $prefixStart = [Math]::Max(0, $LiteralStart - 160)
    $prefix = $Text.Substring($prefixStart, $LiteralStart - $prefixStart)
    $aliasPattern = '(?<![A-Za-z0-9_$-])[\w$-]*[Ii]con(?:Name)?\s*:\s*(?<alias>[A-Za-z0-9_$]+)\b.*?(?:=\s*\k<alias>\s*===\s*void 0\s*\?\s*|=\s*\k<alias>\s*!==\s*void 0\s*\?\s*\k<alias>\s*:\s*|(?<![A-Za-z0-9_$-])\k<alias>\s*\?\?\s*)$'
    if ([System.Text.RegularExpressions.Regex]::IsMatch($prefix, $aliasPattern)) {
        return $true
    }
    $shortPrefix = if ($prefix.Length -gt 96) { $prefix.Substring($prefix.Length - 96) } else { $prefix }
    return [System.Text.RegularExpressions.Regex]::IsMatch(
        $shortPrefix,
        '(?<![A-Za-z0-9_$-])(?:as|component|displayName|glyph|[\w$-]*[Ii]con(?:Name)?|name|role|type)\s*[:=]\s*(?:(?:(?:(?:[^?:"''`,;{}]|"[^"]{0,60}"|''[^'']{0,60}''|`[^`]{0,60}`){1,120}?)\?\??\s*(?:"[^"]{0,80}"|''[^'']{0,80}''|`[^`]{0,80}`)\s*:\s*)*)(?:(?:(?:[^?:"''`,;{}]|"[^"]{0,60}"|''[^'']{0,60}''|`[^`]{0,60}`){1,120}?)(?:\?\??)?\s*)?(?:=\s*)?$'
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












$script:FrontendPatcherCSharp = @'
using System;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace ClaudeZhPatch
{
    public static class FrontendPatcher
    {
        static readonly Regex StructuralContextRe = new Regex(
            "(?<![A-Za-z0-9_$-])(?:as|component|displayName|glyph|[\\w$-]*[Ii]con(?:Name)?|name|role|type)\\s*[:=]\\s*(?:(?:(?:(?:[^?:\\\"'`,;{}]|\\\"[^\\\"]{0,60}\\\"|'[^']{0,60}'|`[^`]{0,60}`){1,120}?)\\?\\??\\s*(?:\\\"[^\\\"]{0,80}\\\"|'[^']{0,80}'|`[^`]{0,80}`)\\s*:\\s*)*)(?:(?:(?:[^?:\\\"'`,;{}]|\\\"[^\\\"]{0,60}\\\"|'[^']{0,60}'|`[^`]{0,60}`){1,120}?)(?:\\?\\??)?\\s*)?(?:=\\s*)?$");

        static readonly Regex StructuralAliasContextRe = new Regex(
            "(?<![A-Za-z0-9_$-])[\\w$-]*[Ii]con(?:Name)?\\s*:\\s*(?<alias>[A-Za-z0-9_$]+)\\b.*?(?:=\\s*\\k<alias>\\s*===\\s*void 0\\s*\\?\\s*|=\\s*\\k<alias>\\s*!==\\s*void 0\\s*\\?\\s*\\k<alias>\\s*:\\s*|(?<![A-Za-z0-9_$-])\\k<alias>\\s*\\?\\?\\s*)$");

        static bool IsStructuralJsLiteralContext(string text, int literalStart)
        {
            int prefixStart = Math.Max(0, literalStart - 160);
            string prefix = text.Substring(prefixStart, literalStart - prefixStart);
            if (StructuralAliasContextRe.IsMatch(prefix))
            {
                return true;
            }
            string shortPrefix = prefix.Length > 96 ? prefix.Substring(prefix.Length - 96) : prefix;
            return StructuralContextRe.IsMatch(shortPrefix);
        }

        static int CountOrdinal(string text, string source)
        {
            int occurrences = 0;
            int index = text.IndexOf(source, StringComparison.Ordinal);
            while (index >= 0)
            {
                occurrences++;
                index = text.IndexOf(source, index + source.Length, StringComparison.Ordinal);
            }
            return occurrences;
        }

        // rules 行结构: [Regex(plain 规则, 直接替换规则为 null), source, target]，顺序与词表一致。
        // 纯计算：不读盘之外不做任何副作用，变更后的内容写入 outputContents[i]，由调用方备份并写盘。
        // 返回每个文件的替换计数（未变更为 0）。
        public static int[] PatchFiles(string[] filePaths, object[][] rules, int maxWorkers, string[] outputContents)
        {
            int total = filePaths.Length;
            int scanned = 0;
            int[] counts = new int[total];
            Parallel.For(0, total, new ParallelOptions { MaxDegreeOfParallelism = Math.Max(1, maxWorkers) }, delegate(int i)
            {
                string filePath = filePaths[i];
                string text = File.ReadAllText(filePath, Encoding.UTF8);
                string patched = text;
                int count = 0;
                for (int r = 0; r < rules.Length; r++)
                {
                    object[] rule = rules[r];
                    string source = (string)rule[1];
                    if (!patched.Contains(source))
                    {
                        continue;
                    }
                    Regex regex = (Regex)rule[0];
                    string target = (string)rule[2];
                    if (regex != null)
                    {
                        string current = patched;
                        int localCount = 0;
                        patched = regex.Replace(current, delegate(Match m)
                        {
                            if (IsStructuralJsLiteralContext(current, m.Index))
                            {
                                return m.Value;
                            }
                            localCount++;
                            return m.Groups["quote"].Value + target + m.Groups["quote"].Value;
                        });
                        count += localCount;
                    }
                    else
                    {
                        int occurrences = CountOrdinal(patched, source);
                        if (occurrences > 0)
                        {
                            patched = patched.Replace(source, target);
                            count += occurrences;
                        }
                    }
                }
                if (count > 0 && !string.Equals(patched, text, StringComparison.OrdinalIgnoreCase))
                {
                    outputContents[i] = patched;
                    counts[i] = count;
                }
                int done = Interlocked.Increment(ref scanned);
                if (done % 250 == 0 || done == total)
                {
                    Console.WriteLine("  scanned " + done + "/" + total + " JS files");
                }
            });
            return counts;
        }
    }
}
'@

function Patch-HardcodedFrontendStrings {
    param(
        [string]$ResourcesPath,
        [string]$Language
    )

    $assetsDir = Resolve-FrontendAssetsDir $ResourcesPath
    if (-not $assetsDir) {
        throw "未找到前端 JS bundle: $(Join-Path $ResourcesPath 'ion-dist')"
    }
    $jsFiles = @(Get-ChildItem (Join-Path $assetsDir "*.js") -File -ErrorAction SilentlyContinue)

    $replacements = @(Get-FrontendHardcodedReplacements $Language)

    # 预处理：过滤结构性跳过规则，plain 规则一次性编译 Regex，
    # 避免 (文件 × 规则) 循环里反复拼 pattern、调函数、分配哈希表。
    $prepared = New-Object 'System.Collections.Generic.List[object[]]'
    foreach ($pair in $replacements) {
        $source = [string]$pair[0]
        $target = [string]$pair[1]
        if (Test-StructuralJsReplacement $source) {
            continue
        }
        if (Test-PlainUiTextReplacement $source) {
            $pattern = '(?<quote>["''`])' + [System.Text.RegularExpressions.Regex]::Escape($source) + '\k<quote>'
            $prepared.Add([object[]]@(
                [System.Text.RegularExpressions.Regex]::new($pattern),
                $source,
                $target
            ))
        } else {
            $prepared.Add([object[]]@($null, $source, $target))
        }
    }

    Write-Host "  scanning frontend JS for hardcoded strings: $($jsFiles.Count) files, $($prepared.Count) replacement rules" -ForegroundColor DarkGray
    $patchedFiles = 0
    $patchedStrings = 0

    $patcherReady = $false
    try {
        if (-not ("ClaudeZhPatch.FrontendPatcher" -as [type])) {
            Add-Type -TypeDefinition $script:FrontendPatcherCSharp -ErrorAction Stop
        }
        $patcherReady = $true
    } catch {
        Write-Host "  native scan helper unavailable ($($_.Exception.Message)); using single-threaded fallback" -ForegroundColor DarkYellow
    }

    if ($patcherReady) {
        $filePaths = [string[]]@($jsFiles | ForEach-Object { $_.FullName })
        $outputContents = [string[]]::new($filePaths.Count)
        $workers = [Math]::Max(1, [Math]::Min([Environment]::ProcessorCount, 12))
        $counts = [ClaudeZhPatch.FrontendPatcher]::PatchFiles($filePaths, $prepared.ToArray(), $workers, $outputContents)
        for ($i = 0; $i -lt $filePaths.Count; $i++) {
            if ($null -ne $outputContents[$i]) {
                Backup-ModifiedFile $ResourcesPath $filePaths[$i]
                [System.IO.File]::WriteAllText($filePaths[$i], $outputContents[$i], $Utf8NoBom)
                $patchedFiles += 1
                $patchedStrings += $counts[$i]
                Write-Host "  patched: $([System.IO.Path]::GetFileName($filePaths[$i])) ($($counts[$i]) replacements)" -ForegroundColor DarkGray
            }
        }
    } else {
        foreach ($file in $jsFiles) {
            $text = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
            $patched = $text
            $count = 0
            foreach ($rule in $prepared) {
                $source = [string]$rule[1]
                $target = [string]$rule[2]
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
                Write-Host "  patched file: $($file.Name) ($count replacements)" -ForegroundColor DarkGray
            }
        }
    }

    Write-Host "  patched hardcoded frontend strings: $patchedStrings replacements in $patchedFiles files" -ForegroundColor Green
}







function Get-SlashCommandGlossConfig {
    param([string]$Language)

    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $resources = Join-Path (Split-Path -Parent $scriptDir) 'resources'
    $profile = Get-Content -LiteralPath (Join-Path $resources 'slash-command-menu-patch.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $catalogs = Get-Content -LiteralPath (Join-Path $resources 'slash-command-glosses.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $languageProperty = $catalogs.PSObject.Properties[$Language]
    if ($null -eq $languageProperty) { throw "Unsupported slash command gloss language: $Language" }
    $labels = $languageProperty.Value
    if (@($labels.PSObject.Properties).Count -eq 0) { throw 'Empty slash command gloss catalog' }
    foreach ($property in $labels.PSObject.Properties) {
        if ($property.Name -cnotmatch '^[a-z][a-z0-9-]*$' -or $property.Value -isnot [string] -or -not $property.Value.Trim()) {
            throw 'Invalid slash command gloss catalog'
        }
    }
    return @{ Profile = $profile; Labels = $labels }
}

function Get-SlashGlossReplacement {
    param($Match, $Profile, [switch]$Patched)

    $original = $Match.Value.Substring($Match.Value.IndexOf(':') + 1).TrimStart()
    if ($Patched) { $original = $original.Substring(1) }
    $values = @{ '__ORIGINAL__' = $original; '__ITEM__' = $Match.Groups[3].Value; '__JSX__' = $Match.Groups[1].Value }
    return [regex]::Replace($Profile.replacement, '__ORIGINAL__|__ITEM__|__JSX__', { param($token) $values[$token.Value] })
}

function Convert-SlashCommandMenuText {
    param([string]$Text, $Profile, $Labels)

    if (-not [regex]::IsMatch($Text, $Profile.module_pattern)) {
        throw 'SlashCommandMenuPopupBody export not found'
    }
    $keys = [string[]]@($Labels.PSObject.Properties.Name)
    [array]::Sort($keys, [StringComparer]::Ordinal)
    $orderedLabels = [ordered]@{}
    foreach ($key in $keys) { $orderedLabels[$key] = $Labels.PSObject.Properties[$key].Value }
    $encoded = ConvertTo-Json -InputObject $orderedLabels -Compress -Depth 3
    $encoded = $encoded.Replace([string][char]0x2028, ([string][char]92 + 'u2028')).Replace([string][char]0x2029, ([string][char]92 + 'u2029'))
    $marker = [string]$Profile.marker
    $suffix = "`n" + $marker + $Profile.suffix.Replace('__LABELS__', $encoded)
    if ($Text.Contains($marker)) {
        $separator = "`n" + $marker
        if (([regex]::Matches($Text, [regex]::Escape($marker))).Count -ne 1 -or -not $Text.Contains($separator)) {
            throw 'Ambiguous slash command gloss marker'
        }
        $index = $Text.IndexOf($separator, [StringComparison]::Ordinal)
        $body = $Text.Substring(0, $index)
        $tail = $Text.Substring($index + $separator.Length)
        $parts = $Profile.suffix -split '__LABELS__', 2
        $left = $parts[0]
        $right = $parts[1]
        if (-not $tail.StartsWith($left, [StringComparison]::Ordinal) -or -not $tail.EndsWith($right, [StringComparison]::Ordinal)) {
            throw 'Unrecognized existing slash command helper'
        }
        $previous = $tail.Substring($left.Length, $tail.Length - $left.Length - $right.Length) | ConvertFrom-Json
        $pattern = $Profile.anchor_pattern.Replace('children:', 'children:\[')
        $anchors = [regex]::Matches($body, $pattern)
        if ($anchors.Count -ne 1) { throw 'Existing slash menu row is missing or ambiguous' }
        $replacement = Get-SlashGlossReplacement $anchors[0] $Profile -Patched
        $start = $anchors[0].Index
        if ($body.Length -lt $start + $replacement.Length -or $body.Substring($start, $replacement.Length) -cne $replacement) {
            throw 'Existing slash menu row does not match the patch'
        }
        $same = @($previous.PSObject.Properties).Count -eq $keys.Count
        foreach ($key in $keys) {
            $property = $previous.PSObject.Properties[$key]
            if ($null -eq $property -or $property.Name -cne $key -or $property.Value -cne $orderedLabels[$key]) { $same = $false }
        }
        if ($same) { return @{ Text = $Text; Status = 'already' } }
        return @{ Text = $body + $suffix; Status = 'updated' }
    }
    if ($Text.Contains('__claudeZhSlashGloss') -or $Text.Contains('__claudeZhSlashLabels')) {
        throw 'Slash command helper name already exists'
    }
    $anchors = [regex]::Matches($Text, $Profile.anchor_pattern)
    if ($anchors.Count -ne 1) { throw 'Expected exactly one slash menu label anchor' }
    $anchor = $anchors[0]
    if (-not [regex]::IsMatch($Text, [regex]::Escape($anchor.Groups[3].Value) + '\.type\s*===\s*"skill"')) {
        throw 'Slash menu skill row not found'
    }
    $replacement = Get-SlashGlossReplacement $anchor $Profile
    $updated = $Text.Substring(0, $anchor.Index) + $replacement + $Text.Substring($anchor.Index + $anchor.Length)
    return @{ Text = $updated + $suffix; Status = 'updated' }
}

function Patch-SlashCommandMenu {
    param([string]$ResourcesPath, [string]$Language)

    $assetsDir = Resolve-FrontendAssetsDir $ResourcesPath
    if (-not $assetsDir) {
        Write-Host '  [WARNING] Slash command gloss skipped: frontend assets not found' -ForegroundColor DarkYellow
        return
    }
    $config = Get-SlashCommandGlossConfig $Language
    $candidates = @(
        foreach ($file in (Get-ChildItem (Join-Path $assetsDir '*.js') -File)) {
            $text = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8)
            if ([regex]::IsMatch($text, $config.Profile.module_pattern)) { @{ File = $file; Text = $text } }
        }
    )
    if ($candidates.Count -ne 1) {
        Write-Host '  [WARNING] Slash command gloss skipped: expected one menu component' -ForegroundColor DarkYellow
        return
    }
    $candidate = $candidates[0]
    try { $result = Convert-SlashCommandMenuText $candidate.Text $config.Profile $config.Labels }
    catch {
        Write-Host "  [WARNING] Slash command gloss skipped: $($_.Exception.Message)" -ForegroundColor DarkYellow
        return
    }
    if ($result.Status -eq 'already') {
        Write-Host "  slash command gloss already installed: $($candidate.File.Name)" -ForegroundColor DarkGray
        return
    }
    Backup-ModifiedFile $ResourcesPath $candidate.File.FullName
    [IO.File]::WriteAllText($candidate.File.FullName, $result.Text, $Utf8NoBom)
    Write-Host "  patched bilingual slash command menu (${Language}): $($candidate.File.Name)" -ForegroundColor Green
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
        $packageDirs = @(Get-ChildItem (Join-Path $packageRoot "*Claude_*") -Directory -ErrorAction SilentlyContinue |
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
            $match = [regex]::Match($text, '(?:[A-Za-z0-9]+\.)*Claude_[A-Za-z0-9]+![A-Za-z0-9]+')
            if ($match.Success) {
                return $match.Value
            }
        } catch {
        }
    }

    # 回退：从 AppX 包推导 PackageFamilyName + AppId
    try {
        $package = Get-ClaudeAppxPackages | Select-Object -First 1
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
        (Join-Path $ResourcesPath "ion-dist\i18n\dynamic\zh-CN.json"),
        (Join-Path $ResourcesPath "ion-dist\i18n\zh-TW.json"),
        (Join-Path $ResourcesPath "zh-TW.json"),
        (Join-Path $ResourcesPath "ion-dist\i18n\statsig\zh-TW.json"),
        (Join-Path $ResourcesPath "ion-dist\i18n\dynamic\zh-TW.json"),
        (Join-Path $ResourcesPath "ion-dist\i18n\zh-HK.json"),
        (Join-Path $ResourcesPath "zh-HK.json"),
        (Join-Path $ResourcesPath "ion-dist\i18n\statsig\zh-HK.json"),
        (Join-Path $ResourcesPath "ion-dist\i18n\dynamic\zh-HK.json")
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

    # AppX(MSIX) 安装优先用包激活启动: 进程带包身份, 更新检查走 msix 路径
    # (直接启动 exe 会被更新器误判为 Squirrel 解包安装而报 "Can not find Squirrel",
    #  Cowork 客户端校验也只能靠签名回退)
    try {
        $app = Get-StartApps -ErrorAction Stop | Where-Object { $_.AppID -like "*Claude_*!*" } | Select-Object -First 1
        if ($app -and $app.AppID) {
            Start-Process -FilePath "explorer.exe" -ArgumentList "shell:AppsFolder\$($app.AppID)"
            Write-Host "  已通过 AppX 激活重启 Claude Desktop ($($app.AppID))" -ForegroundColor Green
            return
        }
    } catch {
        Write-Host "  [提示] AppX 激活不可用($($_.Exception.Message))，改用直接启动。" -ForegroundColor DarkYellow
    }

    $exe = Get-ClaudeExePath $ClaudePath
    if ($exe) {
        Start-Process -FilePath "explorer.exe" -ArgumentList "`"$exe`""
        Write-Host "  restarted Claude Desktop" -ForegroundColor Green
        Write-Host "  [提示] MSIX 安装建议从开始菜单启动 Claude，以获得完整功能(自动更新/Cowork)。" -ForegroundColor DarkYellow
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
        Write-Step "[1/7] 检查语言资源"
        $pack = Get-LanguageResources $LanguageCode
        $trayIconBytes = Get-WindowsTrayIconBytes

        Write-Step "关闭 Claude Desktop"
        Stop-ClaudeProcesses

        Write-Step "[2/7] 查找 Claude Desktop"
        $paths = Get-ClaudeResourcesPath
        $claudePath = $paths["App"]
        $resourcesPath = $paths["Resources"]
        $installKind = $paths["InstallKind"]
        Write-Host "  app: $claudePath" -ForegroundColor Green
        Write-Host "  resources: $resourcesPath" -ForegroundColor Green
        if ($installKind -eq "AppX") {
            Write-Host "  安装类型: 商店版 (MSIX/AppX)" -ForegroundColor DarkGray
        }

        Write-Step "修复桌面 Claude 快捷方式"
        Repair-ClaudeDesktopShortcut $claudePath

        Write-Step "[3/7] 准备写入权限"
        Enable-WriteAccess $resourcesPath
        Remove-LegacyAppxForkArtifacts

        Write-Step "[4/7] 写入 $label 资源"
        Install-LanguageFiles $resourcesPath $pack $LanguageCode
        [void](Install-WindowsTrayIcons $resourcesPath $trayIconBytes)

        Write-Step "[5/7] 注册中文语言"
        Register-Language $resourcesPath $LanguageCode

        Write-Step "[6/7] 汉化硬编码界面文本"
        Patch-HardcodedFrontendStrings $resourcesPath $LanguageCode
        Patch-SlashCommandMenu $resourcesPath $LanguageCode
        Patch-LanguageDisplayNames $resourcesPath

        Write-Step "[7/7] 写入用户语言配置"
        Set-ClaudeLocale $LanguageCode

        Write-Step "重启 Claude Desktop"
        Restart-Claude $claudePath

        Write-Step "启动 CoworkVMService"
        Start-CoworkVMService

        Write-Host ""
        Write-Host "安装完成。如果界面未立即切换，请在 Language 中选择 $label。" -ForegroundColor Green
        Write-Host "提示：本补丁不改动 app.asar / Claude.exe 签名，官方账号登录界面请直接使用 Claude 自带的语言设置。" -ForegroundColor DarkGray
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

    $paths = Get-ClaudeResourcesPath
    $claudePath = $paths["App"]
    $resourcesPath = $paths["Resources"]

    # 旧版本提供过 Frida 常驻模式，相关脚本已移除。这里只做一次性兜底清理，
    # 让从旧版升级的用户不会残留计划任务和便携运行时。
    Remove-LegacyFridaResident

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

function Remove-LegacyFridaResident {
    # Frida 常驻模式已从本项目中移除。仅清理旧版本可能留下的计划任务、
    # 进程和便携运行时，避免升级后残留后台任务。
    $taskNames = @("ClaudeDesktopZhCn-FridaZh", "ClaudeDesktopZhCn-FridaResident")
    foreach ($taskName in $taskNames) {
        try {
            $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            if ($existing) {
                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
                Write-Host "  已移除旧的 Frida 常驻计划任务: $taskName" -ForegroundColor Green
            }
        }
        catch {
        }
    }

    foreach ($pattern in @("frida_launch_zh_win.py", "run_frida_zh_win.ps1")) {
        try {
            Get-CimInstance Win32_Process -Filter "Name = 'python.exe' OR Name = 'pythonw.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -and $_.CommandLine.Contains($pattern) } |
                ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        }
        catch {
        }
    }

    $runtimeDir = Join-Path $env:LOCALAPPDATA "claude-zh"
    if (Test-Path -LiteralPath $runtimeDir) {
        try {
            Remove-Item -LiteralPath $runtimeDir -Recurse -Force -ErrorAction Stop
            Write-Host "  已清理旧的 Frida 便携运行时: $runtimeDir" -ForegroundColor Green
        }
        catch {
            Write-Host "  [提示] 无法清理 $runtimeDir（可忽略）: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }
}

function Invoke-PreInstallCleanup {
    if ($script:PreInstallCleanupDone) {
        return
    }
    $script:PreInstallCleanupDone = $true

    Write-Host "=== 安装前清理旧中文补丁 ===" -ForegroundColor Cyan

    $paths = Get-ClaudeResourcesPath
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

$LanguageCode = $Language

try {
    # 交互选择也必须放在 try 里（issue #199）：选择阶段抛异常（例如检测不到
    # Claude 安装、预清理失败、配置文件损坏）时，如果没人接住，PowerShell
    # 进程会直接退出，用户看到的就是"窗口一闪而过"。
    if ($Interactive) {
        $interactiveSelection = Read-InteractiveSelection
        $Action = $interactiveSelection.Action
        $Language = $interactiveSelection.Language
        $LanguageCode = $Language
    }

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
    }

    Stop-InstallLog
    if ($Interactive) {
        # 成功后也留一个停顿，否则管理员窗口会瞬间关闭，用户看不到结果（issue #199）
        Write-Host ""
        [void](Read-Host "操作完成，按 Enter 关闭此窗口")
    }
    exit 0
}
catch {
    Write-Host ""
    Write-Host "[错误] $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ScriptStackTrace) {
        Write-Host "[错误] 出错位置: $($_.ScriptStackTrace)" -ForegroundColor DarkGray
    }
    if ($script:InstallLogPath -and (Test-Path -LiteralPath $script:InstallLogPath)) {
        Write-Host "[错误] 详细日志已写入: $($script:InstallLogPath)" -ForegroundColor Red
    }
    Stop-InstallLog
    if ($Interactive) {
        [void](Read-Host "安装未完成，按 Enter 退出")
    }
    exit 1
}
