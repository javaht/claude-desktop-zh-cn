# 本汉化包只处理第三方 API 模式。Claude 官方已原生支持简体/繁体中文界面，
# 在线账号模式的中文化交给官方实现。Claude 4.29+ 将前端放进 ion-dist.asar，
# 4.29+ 的主进程壳层菜单只读取 app.asar 内的 resources/i18n 词库；安装器会重建
# ion-dist.asar、就地改写 app.asar，并同步 Claude.exe 内嵌的 ASAR 头哈希，因此
# 这类布局下 Claude.exe 的 Authenticode 签名会失效。
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
    [string]$OriginalLocalAppData = "",

    [string]$ClaudePath = "",

    # 非交互安装（脚本调用、自动化）默认不允许接管 WindowsApps 的所有权。
    # 需要显式授权，避免在没人确认的情况下静默改动系统保护目录的 ACL。
    [switch]$AllowTakeOwnership,

    [string]$OriginalScoop = ""
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
$script:SkipFrontendFileBackups = $false

$script:ExplicitClaudePath = ""
if ($ClaudePath) { $script:ExplicitClaudePath = $ClaudePath }
elseif ($env:CLAUDE_PATH) { $script:ExplicitClaudePath = $env:CLAUDE_PATH }
elseif ($env:CLAUDE_ZH_CUSTOM_PATH) { $script:ExplicitClaudePath = $env:CLAUDE_ZH_CUSTOM_PATH }

if ($OriginalUserSid) { $env:CLAUDE_ZH_ORIGINAL_USER_SID = $OriginalUserSid }
if ($OriginalUserProfile) { $env:CLAUDE_ZH_ORIGINAL_USER_PROFILE = $OriginalUserProfile }
if ($OriginalAppData) { $env:CLAUDE_ZH_ORIGINAL_APPDATA = $OriginalAppData }
if ($OriginalLocalAppData) { $env:CLAUDE_ZH_ORIGINAL_LOCALAPPDATA = $OriginalLocalAppData }
if ($OriginalScoop) { $env:CLAUDE_ZH_ORIGINAL_SCOOP = $OriginalScoop }

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
    Write-Host "[1] 安装中文补丁（第三方 API 模式，例如 DeepSeek；会重建 ion-dist.asar、就地改写 app.asar 并更新 Claude.exe 完整性哈希）"
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

function Get-CustomClaudePaths {
    $custom = @()
    if ($script:ExplicitClaudePath) { $custom += $script:ExplicitClaudePath }
    if ($env:CLAUDE_PATH) { $custom += $env:CLAUDE_PATH }
    if ($env:CLAUDE_ZH_CUSTOM_PATH) { $custom += $env:CLAUDE_ZH_CUSTOM_PATH }

    $valid = @()
    foreach ($path in ($custom | Where-Object { $_ } | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $res = Join-Path $path "resources"
        if (-not (Test-Path -LiteralPath $res)) {
            $res = Join-Path $path "app\resources"
        }
        if ((Test-Path -LiteralPath $res) -and (Get-ClaudeExePath $path)) {
            try {
                $valid += (Resolve-Path -LiteralPath $path).Path
            }
            catch {
                $valid += $path
            }
        }
    }
    return @($valid | Select-Object -Unique)
}

function Get-ScoopClaudePaths {
    $scoopRoots = @()
    if ($env:CLAUDE_ZH_ORIGINAL_SCOOP) { $scoopRoots += $env:CLAUDE_ZH_ORIGINAL_SCOOP }
    if ($env:CLAUDE_ZH_ORIGINAL_USER_PROFILE) {
        $scoopRoots += Join-Path $env:CLAUDE_ZH_ORIGINAL_USER_PROFILE "scoop"
    }
    if ($env:SCOOP) { $scoopRoots += $env:SCOOP }
    $userProfile = [Environment]::GetFolderPath('UserProfile')
    if ($userProfile) {
        $scoopRoots += Join-Path $userProfile "scoop"
    }
    if ($env:SCOOP_GLOBAL) { $scoopRoots += $env:SCOOP_GLOBAL }
    $programData = [Environment]::GetFolderPath('CommonApplicationData')
    if ($programData) {
        $scoopRoots += Join-Path $programData "scoop"
    }

    $candidates = @()
    foreach ($root in ($scoopRoots | Where-Object { $_ } | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($appName in @("claude", "claude-desktop", "AnthropicClaude")) {
            $appBase = Join-Path $root (Join-Path "apps" $appName)
            if (-not (Test-Path -LiteralPath $appBase)) { continue }

            # 1. current 目录（Scoop 标准活动目录软链接/Junction）
            $current = Join-Path $appBase "current"
            if (Test-Path -LiteralPath $current) {
                try {
                    $candidates += (Resolve-Path -LiteralPath $current).Path
                }
                catch {
                    $candidates += $current
                }
            }

            # 2. 版本子目录（如 5.11492.5）
            $versionDirs = @(Get-ChildItem -LiteralPath $appBase -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ne "current" } |
                Sort-Object `
                    @{ Expression = {
                        if ($_.Name -match '^\d+(?:\.\d+)+$') {
                            try { [System.Version]$_.Name } catch { [System.Version]::new(0, 0) }
                        } else {
                            [System.Version]::new(0, 0)
                        }
                    }; Descending = $true },
                    @{ Expression = { $_.LastWriteTime }; Descending = $true } |
                ForEach-Object { $_.FullName })
            $candidates += $versionDirs
        }
    }

    return @($candidates | Where-Object {
        $res = Join-Path $_ "resources"
        (Test-Path -LiteralPath $res) -and (Get-ClaudeExePath $_)
    } | Select-Object -Unique)
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
    $packages = @(Get-ClaudeAppxPackages |
        Where-Object { $_.InstallLocation -and (Test-Path $_.InstallLocation) } |
        Sort-Object `
            @{ Expression = {
                try { [System.Version]$_.Version } catch { [System.Version]::new(0, 0) }
            }; Descending = $true })
    if ($packages.Count -gt 0) {
        return $packages[0].InstallLocation
    }

    $fallback = Get-ChildItem "C:\Program Files\WindowsApps" -Directory -Filter "*Claude*" -ErrorAction SilentlyContinue |
        Sort-Object `
            @{ Expression = {
                if ($_.Name -match '_(\d+(?:\.\d+)+)_') {
                    try { [System.Version]$Matches[1] } catch { [System.Version]::new(0, 0) }
                } else {
                    [System.Version]::new(0, 0)
                }
            }; Descending = $true },
            @{ Expression = { $_.LastWriteTime }; Descending = $true } |
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

function Get-ClaudeExeProductVersion {
    param([string]$ClaudePath)

    $exePath = Get-ClaudeExePath $ClaudePath
    if ($exePath -and (Test-Path -LiteralPath $exePath)) {
        try {
            $ver = [string](Get-Item -LiteralPath $exePath).VersionInfo.ProductVersion
            if ($ver -and $ver.Trim()) {
                return $ver.Trim()
            }
        }
        catch {
            return "未知"
        }
    }
    return "未知"
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
    # 1. 显式指定的自定义安装路径（-ClaudePath / CLAUDE_PATH）
    $customCandidates = @(Get-CustomClaudePaths)
    foreach ($candidatePath in $customCandidates) {
        $candidateResources = Join-Path $candidatePath "resources"
        if (-not (Test-Path $candidateResources)) {
            $candidateResources = Join-Path $candidatePath "app\resources"
        }
        if ((Test-Path $candidateResources) -and (Test-FrontendBundleAvailable $candidateResources)) {
            Write-Host "  Claude 版本: $(Get-ClaudeExeProductVersion $candidatePath)" -ForegroundColor DarkGray
            return @{
                App = $candidatePath
                Resources = $candidateResources
                InstallKind = "Custom"
            }
        }
    }

    # 2. Scoop 安装目录（Scoop extras/claude）
    $scoopCandidates = @(Get-ScoopClaudePaths)
    foreach ($candidatePath in $scoopCandidates) {
        $candidateResources = Join-Path $candidatePath "resources"
        if (-not (Test-Path $candidateResources)) {
            $candidateResources = Join-Path $candidatePath "app\resources"
        }
        if ((Test-Path $candidateResources) -and (Test-FrontendBundleAvailable $candidateResources)) {
            Write-Host "  Claude 版本: $(Get-ClaudeExeProductVersion $candidatePath)" -ForegroundColor DarkGray
            return @{
                App = $candidatePath
                Resources = $candidateResources
                InstallKind = "Scoop"
            }
        }
    }

    # 3. 官方 Squirrel 历史解包路径（%LocalAppData%\AnthropicClaude\app-*）
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
        if (-not (Test-FrontendBundleAvailable $candidateResources)) {
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
        throw "未找到 Claude Desktop 安装。若使用非标准目录安装（如 Scoop 等），可通过设置环境变量 CLAUDE_PATH 指向安装目录后重试。"
    }

    $resourcesPath = Join-Path $claudePath "app\resources"
    if (-not (Test-Path $resourcesPath)) {
        $resourcesPath = Join-Path $claudePath "resources"
    }
    if (-not (Test-Path $resourcesPath)) {
        throw "未找到 Claude resources 目录: $(Join-Path $claudePath 'app\resources')"
    }
    if (-not (Test-FrontendBundleAvailable $resourcesPath)) {
        throw "未找到可用的前端资源: $resourcesPath\ion-dist 或 $resourcesPath\ion-dist.asar。Claude 前端目录结构可能已变化，请带上安装日志反馈。"
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

function Test-WriteAccess {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    try {
        if (Test-Path -LiteralPath $Path -PathType Container) {
            $probe = Join-Path $Path (".zh-cn-write-test-" + [guid]::NewGuid().ToString("N"))
            [IO.Directory]::CreateDirectory($probe) | Out-Null
            [IO.Directory]::Delete($probe)
        }
        else {
            $stream = [IO.File]::Open($Path, "Open", "ReadWrite", "Read")
            $stream.Dispose()
        }
        return $true
    }
    catch {
        return $false
    }
}

function Confirm-TakeOwnership {
    param([string]$Path)

    # 用户已经拒绝过，之后每个路径都不再重复问。
    if ($script:TakeOwnershipDeclined) {
        return $false
    }

    # 只在第一次真正要接管所有权时提示并确认，避免十几个路径刷屏。
    if ($script:TakeOwnershipAcknowledged) {
        return $true
    }

    Write-Host ""
    Write-Host "  [权限] 需要接管以下位置的系统所有权才能继续：" -ForegroundColor Yellow
    Write-Host "         $Path" -ForegroundColor DarkYellow
    Write-Host "         原因：该目录默认属于 TrustedInstaller，提权后的 Administrators" -ForegroundColor DarkGray
    Write-Host "         只有读和执行权限，无法改写 asar 与 Claude.exe。" -ForegroundColor DarkGray
    Write-Host "         副作用：" -ForegroundColor DarkGray
    Write-Host "           · 目录所有者会从 TrustedInstaller 改为 Administrators" -ForegroundColor DarkGray
    Write-Host "           · 会授予 Administrators 完全控制，卸载后不会自动恢复" -ForegroundColor DarkGray
    Write-Host "           · 仅在重装或升级 Claude 后由系统重置" -ForegroundColor DarkGray
    Write-Host "           · 部分安全软件或企业策略可能拦截并告警" -ForegroundColor DarkGray
    Write-Host ""

    if (-not $Interactive -or [Console]::IsInputRedirected) {
        # 非交互场景没有人可以确认，必须显式授权才继续，否则视为拒绝。
        $allowed = $AllowTakeOwnership -or ($env:CLAUDE_ZH_ALLOW_TAKE_OWNERSHIP -match '^(1|true|TRUE|yes|YES|y|Y)$')
        if ($allowed) {
            Write-Host "  [权限] 已通过 -AllowTakeOwnership / CLAUDE_ZH_ALLOW_TAKE_OWNERSHIP 授权，继续接管。" -ForegroundColor DarkYellow
            $script:TakeOwnershipAcknowledged = $true
            return $true
        }
        Write-Host "  [权限] 非交互模式未授权接管所有权，已跳过。" -ForegroundColor DarkYellow
        Write-Host "         如需继续，请加 -AllowTakeOwnership，或设置环境变量" -ForegroundColor DarkYellow
        Write-Host "         CLAUDE_ZH_ALLOW_TAKE_OWNERSHIP=1 后重试。" -ForegroundColor DarkYellow
        $script:TakeOwnershipDeclined = $true
        return $false
    }

    $answer = Read-Host "  继续接管所有权？输入 y 继续，其他任意键跳过（跳过会导致补丁安装失败） [y/N]"
    if ($answer -and $answer.Trim() -match '^(y|yes|Y|YES)$') {
        $script:TakeOwnershipAcknowledged = $true
        return $true
    }

    Write-Host "  [权限] 已跳过接管所有权。" -ForegroundColor DarkYellow
    $script:TakeOwnershipDeclined = $true
    return $false
}

function Take-OwnershipAndGrant {
    param([string]$Path)

    # 官网/商店 MSIX 包的默认 ACL：owner = NT AUTHORITY\SYSTEM，当前用户有显式
    # FullControl，但 BUILTIN\Administrators 只继承到 ReadAndExecute。UAC 提权后
    # 进程以 Administrators 身份运行，反而写不进去；Set-Acl 也会因不是 owner 失败。
    # 这里用 takeown + icacls 兜底，执行前先提示副作用并确认。
    if (-not (Confirm-TakeOwnership $Path)) {
        return $false
    }

    try {
        & takeown.exe /f $Path /a 2>&1 | Out-Null
        & icacls.exe $Path /grant "*S-1-5-32-544:F" /C 2>&1 | Out-Null
        return (Test-WriteAccess $Path)
    }
    catch {
        return $false
    }
}

function Grant-WriteAccess {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $true
    }

    if (Test-WriteAccess $Path) {
        return $true
    }

    $isContainer = Test-Path -LiteralPath $Path -PathType Container
    $identities = @(
        [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
        "BUILTIN\Administrators"
    )

    foreach ($identity in $identities) {
        try {
            $acl = Get-Acl -LiteralPath $Path
            $inheritance = if ($isContainer) { "ContainerInherit,ObjectInherit" } else { "None" }
            $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
                $identity,
                "FullControl",
                $inheritance,
                "None",
                "Allow"
            )
            $acl.SetAccessRule($rule)
            Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
        }
        catch {
        }
    }

    if (Test-WriteAccess $Path) {
        return $true
    }

    # Allow 已经加过却还是写不进去，说明存在显式 Deny —— 在 Windows 的 ACL 里
    # Deny 优先于 Allow，不清掉就永远覆盖不了。只针对本脚本要写的那两个主体。
    try {
        $acl = Get-Acl -LiteralPath $Path
        $removed = 0
        foreach ($rule in @($acl.GetAccessRules($true, $true, [System.Security.Principal.NTAccount]))) {
            if ($rule.AccessControlType -ne "Deny") { continue }
            if ($identities -notcontains $rule.IdentityReference.Value) { continue }
            if ($acl.RemoveAccessRule($rule)) { $removed++ }
        }
        if ($removed -gt 0) {
            Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
            Write-Host "  [权限] 已移除 $removed 条阻止写入的拒绝规则: $Path" -ForegroundColor DarkGray
        }
    }
    catch {
    }

    if (Test-WriteAccess $Path) {
        return $true
    }

    if (Take-OwnershipAndGrant $Path) {
        Write-Host "  [权限] 已接管所有权并授予写权限: $Path" -ForegroundColor DarkGray
        return $true
    }

    return $false
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
    if ($script:SkipFrontendFileBackups -and ($relative -eq "ion-dist" -or $relative.StartsWith("ion-dist\", [System.StringComparison]::OrdinalIgnoreCase))) {
        return
    }
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

    $appPath = Get-ClaudeAppPathFromResources $ResourcesPath
    $paths = @(
        $appPath,
        $ResourcesPath,
        (Join-Path $ResourcesPath "app.asar"),
        (Join-Path $ResourcesPath "ion-dist.asar"),
        (Join-Path $ResourcesPath "ion-dist"),
        (Join-Path $ResourcesPath "ion-dist\i18n"),
        (Join-Path $ResourcesPath "ion-dist\i18n\statsig"),
        (Join-Path $ResourcesPath "ion-dist\i18n\dynamic"),
        (Join-Path $ResourcesPath "ion-dist\assets"),
        (Join-Path $ResourcesPath "ion-dist\assets\v1")
    )
    if ($appPath) {
        $paths += (Join-Path $appPath "Claude.exe")
    }
    $coworkSvc = Join-Path $ResourcesPath "cowork-svc.exe"
    if (Test-Path -LiteralPath $coworkSvc) {
        $paths += $coworkSvc
    }

    $failed = @()
    foreach ($path in $paths) {
        if (-not (Grant-WriteAccess $path)) {
            $failed += $path
        }
    }

    if ($failed.Count -eq 0) {
        return $true
    }

    Write-Host "  [警告] 以下位置仍无法写入：" -ForegroundColor Yellow
    foreach ($path in $failed) {
        Write-Host "         $path" -ForegroundColor DarkYellow
    }
    if ($ResourcesPath -match '(?i)\\WindowsApps\\AnthropicPBC\.Claude_') {
        Write-Host "         当前是 Microsoft Store 版（MSIX/AppX）：系统会阻止修改程序文件，" -ForegroundColor DarkYellow
        Write-Host "         接管所有权与开发者模式都绕不过；请改用官网安装包后重试。" -ForegroundColor DarkYellow
    }
    else {
        Write-Host "         请确认安装脚本以管理员身份运行，并检查安全软件是否拦截了权限修改。" -ForegroundColor DarkYellow
    }
    return $false
}

function Assert-WriteAccess {
    param(
        [string]$ResourcesPath,
        [string]$Stage = "安装"
    )

    if (Enable-WriteAccess $ResourcesPath) {
        return
    }

    # 权限拿不到时直接中止：继续往下写 asar 只会在更靠后的位置抛一个
    # 更难懂的错误，还可能留下「asar 已改、exe 哈希没写回」的半坏状态。
    throw "无法获得 Claude 程序目录的写权限，已中止$Stage。请以管理员身份重试；若装的是 Microsoft Store 版，请改用官网安装包。"
}

function Install-LanguageFiles {
    param(
        [string]$ResourcesPath,
        [hashtable]$Pack,
        [string]$Lang,
        [switch]$DesktopOnly
    )

    if (-not $DesktopOnly) {
        $i18nDir = Join-Path $ResourcesPath "ion-dist\i18n"
        $statsigDir = Join-Path $i18nDir "statsig"
        New-Item -ItemType Directory -Path $i18nDir -Force | Out-Null
        New-Item -ItemType Directory -Path $statsigDir -Force | Out-Null

        Copy-Item $Pack["Frontend"] (Join-Path $i18nDir "$Lang.json") -Force
        Write-Host "  installed ion-dist/i18n/$Lang.json" -ForegroundColor Green
    }

    Copy-Item $Pack["Desktop"] (Join-Path $ResourcesPath "$Lang.json") -Force
    Write-Host "  installed resources/$Lang.json" -ForegroundColor Green

    # 独立窗口（如第三方推理配置）由前端 chunk 渲染，但文案取自壳层词表；
    # 这些条目沿用前端消息 id，壳层 en-US 词表里没有对应键，这里直接并入桌面词库。
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $desktopExtra = Join-Path (Split-Path -Parent $scriptDir) "resources\desktop-extra-$Lang.json"
    if (Test-Path -LiteralPath $desktopExtra -PathType Leaf) {
        $desktopTarget = Join-Path $ResourcesPath "$Lang.json"
        try {
            $extraMerged = Merge-LocaleJson ([IO.File]::ReadAllText($desktopTarget, [Text.Encoding]::UTF8)) ([IO.File]::ReadAllText($desktopExtra, [Text.Encoding]::UTF8))
            if ($extraMerged.Changed -gt 0) {
                [IO.File]::WriteAllText($desktopTarget, $extraMerged.Json, (New-Object System.Text.UTF8Encoding($false)))
                Write-Host "  merged desktop-extra-$Lang.json into resources/$Lang.json ($($extraMerged.Changed) entries)" -ForegroundColor Green
            }
        }
        catch {
            Write-Host "  [提示] 独立窗口词库不是有效 JSON，跳过合并: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }

    if ($DesktopOnly) {
        return
    }

    Copy-Item $Pack["Statsig"] (Join-Path $statsigDir "$Lang.json") -Force
    Write-Host "  installed ion-dist/i18n/statsig/$Lang.json" -ForegroundColor Green

    # Claude 2.9939.2 起前端强制加载 dynamic catalog，缺失会让整个语言包加载失败并
    # 回退英文。若项目自带对应的中文 dynamic 词表则优先使用，否则按官方 en-US 原文兜底。
    $dynamicDir = Join-Path $i18nDir "dynamic"
    $dynamicEn = Join-Path $dynamicDir "en-US.json"
    if (Test-Path $dynamicEn) {
        $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
        $localizedDynamic = Join-Path (Split-Path -Parent $scriptDir) "resources\dynamic-$Lang.json"
        $dynamicSource = if (Test-Path $localizedDynamic) { $localizedDynamic } else { $dynamicEn }
        New-Item -ItemType Directory -Path $dynamicDir -Force | Out-Null
        Copy-Item $dynamicSource (Join-Path $dynamicDir "$Lang.json") -Force
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











function Get-FrontendBundleMode {
    param([string]$ResourcesPath)

    if (Test-Path -LiteralPath (Join-Path $ResourcesPath "ion-dist.asar") -PathType Leaf) {
        return "Asar"
    }
    if (Test-Path -LiteralPath (Join-Path $ResourcesPath "ion-dist") -PathType Container) {
        return "Directory"
    }
    return "Missing"
}

function Get-AsarEntryPaths {
    param($Header)

    $paths = New-Object System.Collections.Generic.List[string]
    $walk = {
        param($Node, [string]$Prefix)

        if (-not $Node.PSObject.Properties["files"]) {
            return
        }
        foreach ($property in $Node.files.PSObject.Properties) {
            $relative = if ($Prefix) { "$Prefix/$($property.Name)" } else { $property.Name }
            $child = $property.Value
            if ($child.PSObject.Properties["files"]) {
                & $walk $child $relative
            }
            else {
                $paths.Add($relative)
            }
        }
    }
    & $walk $Header ""
    return @($paths)
}


function Test-AsarFrontendArchive {
    param([string]$AsarPath)

    if (-not (Test-Path -LiteralPath $AsarPath -PathType Leaf)) {
        return $false
    }

    if (-not ("ClaudeZhPatch.AsarHelper" -as [type]) -and $script:FrontendPatcherCSharp) {
        try { Add-Type -TypeDefinition $script:FrontendPatcherCSharp -ErrorAction Stop } catch {}
    }
    if ("ClaudeZhPatch.AsarHelper" -as [type]) {
        return [ClaudeZhPatch.AsarHelper]::TestFrontendArchive($AsarPath)
    }

    try {
        $parsed = Read-AsarHeaderFromFile $AsarPath
        $paths = @(Get-AsarEntryPaths $parsed["Header"])
        $hasI18n = $paths -contains "i18n/en-US.json"
        $hasBundle = @($paths | Where-Object { $_ -match '(^|/)assets/(?:[^/]+/)?index-[^/]+\.js$' }).Count -gt 0
        return ($hasI18n -and $hasBundle)
    }
    catch {
        return $false
    }
}

function Test-FrontendBundleAvailable {
    param([string]$ResourcesPath)

    $mode = Get-FrontendBundleMode $ResourcesPath
    if ($mode -eq "Asar") {
        return Test-AsarFrontendArchive (Join-Path $ResourcesPath "ion-dist.asar")
    }
    if ($mode -eq "Directory") {
        return $null -ne (Resolve-FrontendAssetsDir $ResourcesPath)
    }
    return $false
}

function Expand-AsarArchive {
    param(
        [string]$AsarPath,
        [string]$DestinationPath
    )

    Require-File $AsarPath
    if (Test-Path -LiteralPath $DestinationPath) {
        throw "ASAR 解包目标已存在: $DestinationPath"
    }

    if (-not ("ClaudeZhPatch.AsarHelper" -as [type]) -and $script:FrontendPatcherCSharp) {
        try { Add-Type -TypeDefinition $script:FrontendPatcherCSharp -ErrorAction Stop } catch {}
    }
    if ("ClaudeZhPatch.AsarHelper" -as [type]) {
        $workers = [Math]::Max(1, [Math]::Min([Environment]::ProcessorCount, 8))
        [ClaudeZhPatch.AsarHelper]::ExpandArchive($AsarPath, $DestinationPath, $workers)
        return
    }

    $parsed = Read-AsarHeaderFromFile $AsarPath
    $dataStart = 8 + [int]$parsed["HeaderSize"]
    New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    $destinationRoot = [IO.Path]::GetFullPath($DestinationPath).TrimEnd('\', '/')
    $buffer = [byte[]]::new(256 * 1024)
    $createdDirs = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    [void]$createdDirs.Add($destinationRoot)
    $asarStream = [IO.File]::Open($AsarPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $expand = {
            param($Node, [string]$Prefix)

            foreach ($property in $Node.files.PSObject.Properties) {
                $name = [string]$property.Name
                if (-not $name -or $name -in @(".", "..") -or $name.IndexOfAny([char[]]@('/', '\')) -ge 0) {
                    throw "ASAR 包含不安全路径: $name"
                }
                $relative = if ($Prefix) { Join-Path $Prefix $name } else { $name }
                $target = [IO.Path]::GetFullPath((Join-Path $destinationRoot $relative))
                if (-not $target.StartsWith($destinationRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "ASAR 路径越界: $relative"
                }

                $child = $property.Value
                if ($child.PSObject.Properties["files"]) {
                    if ($createdDirs.Add($target)) {
                        [void][IO.Directory]::CreateDirectory($target)
                    }
                    & $expand $child $relative
                    continue
                }
                if ($child.PSObject.Properties["link"]) {
                    throw "暂不支持包含软链接的 ASAR: $relative"
                }

                $parent = [IO.Path]::GetDirectoryName($target)
                if ($parent -and $createdDirs.Add($parent)) {
                    [void][IO.Directory]::CreateDirectory($parent)
                }
                if ($child.PSObject.Properties["unpacked"] -and [bool]$child.unpacked) {
                    $unpackedSource = Join-Path ($AsarPath + ".unpacked") ($relative -replace '/', '\')
                    Require-File $unpackedSource
                    Copy-Item -LiteralPath $unpackedSource -Destination $target -Force
                    continue
                }

                $offset = [int64]$child.offset
                $size = [int64]$child.size
                if ($offset -lt 0 -or $size -lt 0 -or ($dataStart + $offset + $size) -gt $asarStream.Length) {
                    throw "ASAR 文件边界无效: $relative (offset=$offset, size=$size, dataStart=$dataStart, archive=$($asarStream.Length))"
                }

                $output = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try {
                    $asarStream.Position = $dataStart + $offset
                    $remaining = $size
                    while ($remaining -gt 0) {
                        $wanted = [int][Math]::Min([int64]$buffer.Length, $remaining)
                        $read = $asarStream.Read($buffer, 0, $wanted)
                        if ($read -le 0) {
                            throw "ASAR 文件内容不完整: $relative"
                        }
                        $output.Write($buffer, 0, $read)
                        $remaining -= $read
                    }
                }
                finally {
                    $output.Dispose()
                }
            }
        }
        & $expand $parsed["Header"] ""
    }
    finally {
        $asarStream.Dispose()
    }
}

function Get-AsarFileIntegrity {
    param([string]$Path)

    # 流式分块读取。绝不能用 ReadAllBytes：Claude 4.29+ 的 ion-dist.asar 有 180MB+，
    # 逐个文件整块读入会把 PowerShell 的 LOH 撑爆。
    $blockSize = $AsarIntegrityBlockSize
    $blocks = New-Object System.Collections.Generic.List[string]
    $wholeSha = [Security.Cryptography.SHA256]::Create()
    $blockSha = [Security.Cryptography.SHA256]::Create()
    $buffer = [byte[]]::new($blockSize)
    $stream = [IO.File]::OpenRead($Path)
    try {
        while ($true) {
            $filled = 0
            while ($filled -lt $blockSize) {
                $read = $stream.Read($buffer, $filled, $blockSize - $filled)
                if ($read -le 0) {
                    break
                }
                $filled += $read
            }
            if ($filled -le 0) {
                break
            }
            [void]$wholeSha.TransformBlock($buffer, 0, $filled, $null, 0)
            $blockHash = $blockSha.ComputeHash($buffer, 0, $filled)
            $blocks.Add(([BitConverter]::ToString($blockHash) -replace "-", "").ToLowerInvariant())
            if ($filled -lt $blockSize) {
                break
            }
        }
        [void]$wholeSha.TransformFinalBlock(([byte[]]::new(0)), 0, 0)
        $hash = ([BitConverter]::ToString($wholeSha.Hash) -replace "-", "").ToLowerInvariant()
        if ($blocks.Count -eq 0) {
            $blocks.Add($hash)
        }
        return [ordered]@{
            algorithm = "SHA256"
            hash = $hash
            blockSize = $blockSize
            blocks = @($blocks)
        }
    }
    finally {
        $stream.Dispose()
        $wholeSha.Dispose()
        $blockSha.Dispose()
    }
}

function Get-AsarIntegrityFromBytes {
    param([byte[]]$Bytes)

    $blockSize = $AsarIntegrityBlockSize
    $blocks = New-Object System.Collections.Generic.List[string]
    $wholeSha = [Security.Cryptography.SHA256]::Create()
    $blockSha = [Security.Cryptography.SHA256]::Create()
    try {
        $offset = 0
        while ($offset -lt $Bytes.Length) {
            $length = [Math]::Min($blockSize, $Bytes.Length - $offset)
            [void]$wholeSha.TransformBlock($Bytes, $offset, $length, $null, 0)
            $blockHash = $blockSha.ComputeHash($Bytes, $offset, $length)
            $blocks.Add(([BitConverter]::ToString($blockHash) -replace "-", "").ToLowerInvariant())
            $offset += $length
        }
        [void]$wholeSha.TransformFinalBlock(([byte[]]::new(0)), 0, 0)
        $hash = ([BitConverter]::ToString($wholeSha.Hash) -replace "-", "").ToLowerInvariant()
        if ($blocks.Count -eq 0) {
            $blocks.Add($hash)
        }
        return [ordered]@{
            algorithm = "SHA256"
            hash = $hash
            blockSize = $blockSize
            blocks = @($blocks)
        }
    }
    finally {
        $wholeSha.Dispose()
        $blockSha.Dispose()
    }
}

function Get-AsarEntryNode {
    param($Header, [string]$EntryPath)

    $node = $Header
    foreach ($segment in ($EntryPath -split '/')) {
        $files = $node.PSObject.Properties["files"]
        if ($null -eq $files) {
            return $null
        }
        $child = $files.Value.PSObject.Properties[$segment]
        if ($null -eq $child) {
            return $null
        }
        $node = $child.Value
    }
    return $node
}

function Read-AsarEntryBytes {
    param(
        [string]$AsarPath,
        $Parsed,
        [string]$EntryPath
    )

    $node = Get-AsarEntryNode $Parsed["Header"] $EntryPath
    if ($null -eq $node) {
        throw "app.asar 缺少条目: $EntryPath"
    }
    if ($node.PSObject.Properties["files"]) {
        throw "app.asar 条目是目录: $EntryPath"
    }
    if ($node.PSObject.Properties["link"]) {
        throw "app.asar 条目是软链接: $EntryPath"
    }
    if ($node.PSObject.Properties["unpacked"] -and [bool]$node.unpacked) {
        throw "app.asar 条目是 unpacked: $EntryPath"
    }

    $size = [int64]$node.size
    if ($size -le 0) {
        return [byte[]]::new(0)
    }

    $dataStart = [int64]8 + [int64]$Parsed["HeaderSize"]
    $bytes = [byte[]]::new($size)
    $stream = [IO.File]::Open($AsarPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $stream.Seek(($dataStart + [int64]$node.offset), [IO.SeekOrigin]::Begin) | Out-Null
        $read = 0
        while ($read -lt $bytes.Length) {
            $chunk = $stream.Read($bytes, $read, $bytes.Length - $read)
            if ($chunk -le 0) {
                throw "app.asar 条目内容不完整: $EntryPath"
            }
            $read += $chunk
        }
    }
    finally {
        $stream.Dispose()
    }
    return $bytes
}

function Test-FileReplaceable {
    param(
        [string]$Path,
        [int]$TimeoutSeconds = 10
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $true
    }

    # MoveFileEx(MOVEFILE_REPLACE_EXISTING) 要求目标可以被独占打开；被 Claude
    # 之类的进程占用时，PowerShell 只会报 “Cannot create a file when that file already
    # exists”，完全看不出是文件被锁。这里提前探测并等待句柄释放。
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        try {
            $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $stream.Dispose()
            return $true
        }
        catch [System.IO.IOException] {
            Start-Sleep -Milliseconds 500
        }
        catch [System.UnauthorizedAccessException] {
            return $false
        }
    } while ([DateTime]::UtcNow -lt $deadline)

    return $false
}

function Assert-AsarReplaceable {
    param(
        [string]$Path,
        [int]$TimeoutSeconds = 10
    )

    if (Test-FileReplaceable $Path $TimeoutSeconds) {
        return
    }

    throw "无法替换 $Path：文件仍被占用或不可写。请彻底退出 Claude Desktop（任务管理器结束所有 Claude.exe / cowork-svc.exe）后重试；若应用在另一个 Windows 账户下运行，请先注销该账户。"
}

function Move-FileWithRetry {
    param(
        [string]$Source,
        [string]$Destination,
        [int]$Retries = 5,
        [int]$DelayMilliseconds = 500
    )

    $lastError = $null
    for ($attempt = 1; $attempt -le [Math]::Max(1, $Retries); $attempt++) {
        try {
            Move-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
            return
        }
        catch {
            $lastError = $_
            if ($attempt -lt $Retries) {
                Start-Sleep -Milliseconds $DelayMilliseconds
            }
        }
    }

    throw "无法替换 $Destination：文件可能仍被 Claude Desktop 占用。请彻底退出 Claude 后重试。原始错误：$($lastError.Exception.Message)"
}

function Write-AsarArchiveWithHeader {
    param(
        [string]$AsarPath,
        [string]$ResourcesPath,
        $Parsed,
        $Header,
        [byte[]]$Append
    )

    # 先确认目标没有被 Claude 占用，避免临时文件写完才发现无法替换。
    Assert-AsarReplaceable -Path $AsarPath

    # app.asar 是主进程包，真实安装里含 unpacked / executable / link 条目，解包重打包会丢
    # 这些元数据甚至让应用起不来。这里只替换头部，原有 payload 原样流式拷贝（头内 offset
    # 相对 payload 起点，头长度变化不影响其正确性），再把新内容追加到 payload 末尾。
    $oldDataStart = [int64]8 + [int64]$Parsed["HeaderSize"]
    $oldPayloadLength = [int64](Get-Item -LiteralPath $AsarPath).Length - $oldDataStart
    if ($oldPayloadLength -lt 0) {
        throw "app.asar 长度异常: $AsarPath"
    }

    $headerStringBytes = [Text.Encoding]::UTF8.GetBytes(($Header | ConvertTo-Json -Depth 100 -Compress))
    $headerPayloadSize = Align-4 (4 + $headerStringBytes.Length)
    $headerSize = 4 + $headerPayloadSize
    $headerPickle = [byte[]]::new($headerSize)
    [Array]::Copy([BitConverter]::GetBytes([uint32]$headerPayloadSize), 0, $headerPickle, 0, 4)
    [Array]::Copy([BitConverter]::GetBytes([int32]$headerStringBytes.Length), 0, $headerPickle, 4, 4)
    [Array]::Copy($headerStringBytes, 0, $headerPickle, 8, $headerStringBytes.Length)

    $prefix = [byte[]]::new(8)
    [Array]::Copy([BitConverter]::GetBytes([uint32]4), 0, $prefix, 0, 4)
    [Array]::Copy([BitConverter]::GetBytes([uint32]$headerSize), 0, $prefix, 4, 4)

    $temporary = "$AsarPath.zh-cn-new"
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    Backup-ModifiedFile $ResourcesPath $AsarPath
    $source = [IO.File]::Open($AsarPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $output = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $output.Write($prefix, 0, $prefix.Length)
        $output.Write($headerPickle, 0, $headerPickle.Length)
        $source.Seek($oldDataStart, [IO.SeekOrigin]::Begin) | Out-Null
        $buffer = [byte[]]::new(1024 * 1024)
        while ($true) {
            $read = $source.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) {
                break
            }
            $output.Write($buffer, 0, $read)
        }
        if ($null -ne $Append -and $Append.Length -gt 0) {
            $output.Write($Append, 0, $Append.Length)
        }
    }
    finally {
        $output.Dispose()
        $source.Dispose()
    }

    try {
        $verify = Read-AsarHeaderFromFile $temporary
        $expectedCount = @(Get-AsarEntryPaths $Header).Count
        $actualCount = @(Get-AsarEntryPaths $verify["Header"]).Count
        if ($actualCount -ne $expectedCount) {
            throw "app.asar 头部改写后条目数不一致: $expectedCount -> $actualCount"
        }
    }
    catch {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        throw
    }

    try {
        Move-FileWithRetry -Source $temporary -Destination $AsarPath
    }
    catch {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Set-AsarEntryContent {
    param(
        [string]$AsarPath,
        [string]$ResourcesPath,
        [string]$EntryPath,
        [byte[]]$Content
    )

    $parsed = Read-AsarHeaderFromFile $AsarPath
    $node = Get-AsarEntryNode $parsed["Header"] $EntryPath
    if ($null -eq $node) {
        throw "app.asar 缺少条目: $EntryPath"
    }
    if ($node.PSObject.Properties["link"]) {
        throw "app.asar 条目是软链接，拒绝改写: $EntryPath"
    }
    if ($node.PSObject.Properties["unpacked"] -and [bool]$node.unpacked) {
        throw "app.asar 条目是 unpacked，拒绝改写: $EntryPath"
    }

    $oldDataStart = [int64]8 + [int64]$parsed["HeaderSize"]
    $oldPayloadLength = [int64](Get-Item -LiteralPath $AsarPath).Length - $oldDataStart

    # 新内容追加到 payload 末尾，旧内容留在原地成为不再被引用的空洞，其它条目完全不受影响。
    $node.offset = "$oldPayloadLength"
    $node.size = [int64]$Content.Length
    if ($node.PSObject.Properties["integrity"]) {
        $integrity = Get-AsarIntegrityFromBytes $Content
        $node.integrity = [pscustomobject]@{
            algorithm = $integrity.algorithm
            hash = $integrity.hash
            blockSize = $integrity.blockSize
            blocks = @($integrity.blocks)
        }
    }

    Write-AsarArchiveWithHeader -AsarPath $AsarPath -ResourcesPath $ResourcesPath -Parsed $parsed -Header $parsed["Header"] -Append $Content
}

function Add-AsarEntryContent {
    param(
        [string]$AsarPath,
        [string]$ResourcesPath,
        [string]$EntryPath,
        [byte[]]$Content
    )

    $parsed = Read-AsarHeaderFromFile $AsarPath
    $segments = $EntryPath -split '/'
    if ($segments.Length -lt 2) {
        throw "app.asar 条目路径无效: $EntryPath"
    }
    $name = $segments[-1]
    $parentPath = $segments[0..($segments.Length - 2)] -join '/'
    $parentNode = Get-AsarEntryNode $parsed["Header"] $parentPath
    if ($null -eq $parentNode -or -not $parentNode.PSObject.Properties["files"]) {
        return $false
    }
    if ($null -ne $parentNode.files.PSObject.Properties[$name]) {
        return $false
    }

    $oldDataStart = [int64]8 + [int64]$parsed["HeaderSize"]
    $oldPayloadLength = [int64](Get-Item -LiteralPath $AsarPath).Length - $oldDataStart
    $integrity = Get-AsarIntegrityFromBytes $Content
    $node = [pscustomobject]@{
        size = [int64]$Content.Length
        offset = "$oldPayloadLength"
        integrity = [pscustomobject]@{
            algorithm = $integrity.algorithm
            hash = $integrity.hash
            blockSize = $integrity.blockSize
            blocks = @($integrity.blocks)
        }
    }
    Add-Member -InputObject $parentNode.files -NotePropertyName $name -NotePropertyValue $node

    Write-AsarArchiveWithHeader -AsarPath $AsarPath -ResourcesPath $ResourcesPath -Parsed $parsed -Header $parsed["Header"] -Append $Content
    return $true
}

function New-AsarArchive {
    param(
        [string]$SourceDirectory,
        [string]$DestinationPath
    )

    if (-not (Test-Path -LiteralPath $SourceDirectory -PathType Container)) {
        throw "ASAR 源目录不存在: $SourceDirectory"
    }
    if (-not $DestinationPath) {
        throw "缺少 ASAR 输出路径。"
    }

    if (-not ("ClaudeZhPatch.AsarHelper" -as [type]) -and $script:FrontendPatcherCSharp) {
        try { Add-Type -TypeDefinition $script:FrontendPatcherCSharp -ErrorAction Stop } catch {}
    }
    if ("ClaudeZhPatch.AsarHelper" -as [type]) {
        $destinationFull = [IO.Path]::GetFullPath($DestinationPath)
        $parent = Split-Path -Parent $destinationFull
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        $temporary = "$destinationFull.tmp-" + [guid]::NewGuid().ToString("N")
        $workers = [Math]::Max(1, [Math]::Min([Environment]::ProcessorCount, 12))
        try {
            [ClaudeZhPatch.AsarHelper]::CreateArchiveToPath($SourceDirectory, $temporary, [int]$AsarIntegrityBlockSize, $workers)
            Move-Item -LiteralPath $temporary -Destination $destinationFull -Force
        }
        finally {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
        return
    }

    $payloadEntries = New-Object System.Collections.Generic.List[object]
    $offsetState = [pscustomobject]@{ Offset = [int64]0 }
    # 手工拼装紧凑 JSON。ConvertTo-Json 在数千个嵌套节点上会构建完整 PSObject 图，
    # 183MB 的 ion-dist.asar 实测会被撑到十几 GB 内存，因此这里完全绕开它。
    $headerJson = New-Object System.Text.StringBuilder
    [void]$headerJson.Append('{"files":{')

    $appendNode = {
        param([string]$Directory)

        $first = $true
        foreach ($item in @(Get-ChildItem -LiteralPath $Directory -Force | Sort-Object Name)) {
            if (-not $first) {
                [void]$headerJson.Append(',')
            }
            $first = $false
            # 文件名来自文件系统，Windows 不允许反斜杠和双引号，这里只做保险性转义。
            $name = $item.Name.Replace('\', '\\').Replace('"', '\"')
            [void]$headerJson.Append('"').Append($name).Append('"')

            if ($item.PSIsContainer) {
                [void]$headerJson.Append(':{"files":{')
                & $appendNode $item.FullName
                [void]$headerJson.Append('}}')
                continue
            }
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq [IO.FileAttributes]::ReparsePoint) {
                throw "ASAR 源目录包含不支持的软链接: $($item.FullName)"
            }

            $offset = [int64]$offsetState.Offset
            $size = [int64]$item.Length
            $integrity = Get-AsarFileIntegrity $item.FullName

            [void]$headerJson.Append(':{"size":').Append($size).Append(',"offset":"').Append($offset).Append('","integrity":{"algorithm":"')
            [void]$headerJson.Append($integrity.algorithm).Append('","hash":"').Append($integrity.hash)
            [void]$headerJson.Append('","blockSize":').Append($integrity.blockSize).Append(',"blocks":[')
            $blockSeparator = ''
            foreach ($block in $integrity.blocks) {
                [void]$headerJson.Append($blockSeparator).Append('"').Append($block).Append('"')
                $blockSeparator = ','
            }
            [void]$headerJson.Append(']}}')

            $payloadEntries.Add([pscustomobject]@{ Path = $item.FullName; Size = $size })
            $offsetState.Offset += $size
        }
    }

    & $appendNode ([IO.Path]::GetFullPath($SourceDirectory))
    [void]$headerJson.Append('}}')

    $headerStringBytes = [Text.Encoding]::UTF8.GetBytes($headerJson.ToString())
    $headerPayloadSize = Align-4 (4 + $headerStringBytes.Length)
    $headerSize = 4 + $headerPayloadSize
    $headerPickle = [byte[]]::new($headerSize)
    [Array]::Copy([BitConverter]::GetBytes([uint32]$headerPayloadSize), 0, $headerPickle, 0, 4)
    [Array]::Copy([BitConverter]::GetBytes([int32]$headerStringBytes.Length), 0, $headerPickle, 4, 4)
    [Array]::Copy($headerStringBytes, 0, $headerPickle, 8, $headerStringBytes.Length)

    $prefix = [byte[]]::new(8)
    [Array]::Copy([BitConverter]::GetBytes([uint32]4), 0, $prefix, 0, 4)
    [Array]::Copy([BitConverter]::GetBytes([uint32]$headerSize), 0, $prefix, 4, 4)

    $destinationFull = [IO.Path]::GetFullPath($DestinationPath)
    $parent = Split-Path -Parent $destinationFull
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = "$destinationFull.tmp-" + [guid]::NewGuid().ToString("N")
    try {
        $output = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $output.Write($prefix, 0, $prefix.Length)
            $output.Write($headerPickle, 0, $headerPickle.Length)
            foreach ($entry in $payloadEntries) {
                $entryStream = [IO.File]::OpenRead($entry.Path)
                try {
                    $entryStream.CopyTo($output)
                }
                finally {
                    $entryStream.Dispose()
                }
            }
        }
        finally {
            $output.Dispose()
        }
        Move-Item -LiteralPath $temporary -Destination $destinationFull -Force
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Remove-GeneratedFrontendWorkspace {
    param(
        [string]$ResourcesPath,
        [string]$WorkspacePath
    )

    if (-not (Test-Path -LiteralPath $WorkspacePath)) {
        return
    }
    $root = [IO.Path]::GetFullPath($ResourcesPath).TrimEnd('\', '/')
    $target = [IO.Path]::GetFullPath($WorkspacePath).TrimEnd('\', '/')
    if (-not $target.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $target) -ne "ion-dist") {
        throw "拒绝清理非安装器工作目录: $WorkspacePath"
    }
    Remove-Item -LiteralPath $target -Recurse -Force
}

function Initialize-FrontendPatchTarget {
    param([string]$ResourcesPath)

    $mode = Get-FrontendBundleMode $ResourcesPath
    if ($mode -eq "Missing") {
        throw "未找到前端资源: $ResourcesPath\ion-dist 或 $ResourcesPath\ion-dist.asar"
    }
    if ($mode -eq "Directory") {
        return [pscustomobject]@{
            Mode = "Directory"
            ResourcesPath = $ResourcesPath
            Generated = $false
            WorkspacePath = Join-Path $ResourcesPath "ion-dist"
            AsarPath = $null
            MarkerPath = $null
        }
    }

    $asarPath = Join-Path $ResourcesPath "ion-dist.asar"
    $workspacePath = Join-Path $ResourcesPath "ion-dist"
    $markerPath = Join-Path $ResourcesPath ".zh-cn-asar-extracted"
    if (Test-Path -LiteralPath $workspacePath) {
        if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
            throw "发现未标记的 ion-dist 目录，为避免删除用户文件已停止: $workspacePath"
        }
        Remove-GeneratedFrontendWorkspace $ResourcesPath $workspacePath
    }
    Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue

    Backup-ModifiedFile $ResourcesPath $asarPath
    try {
        Expand-AsarArchive $asarPath $workspacePath
        [IO.File]::WriteAllText($markerPath, $asarPath, $Utf8NoBom)
    }
    catch {
        Remove-GeneratedFrontendWorkspace $ResourcesPath $workspacePath
        Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
        throw
    }

    $script:SkipFrontendFileBackups = $true
    Write-Host "  ion-dist.asar 已解包到临时工作目录" -ForegroundColor DarkGray
    return [pscustomobject]@{
        Mode = "Asar"
        ResourcesPath = $ResourcesPath
        Generated = $true
        WorkspacePath = $workspacePath
        AsarPath = $asarPath
        MarkerPath = $markerPath
    }
}

function Complete-FrontendPatchTarget {
    param($Target)

    if ($null -eq $Target -or $Target.Mode -ne "Asar") {
        return
    }
    if (-not (Test-Path -LiteralPath $Target.WorkspacePath -PathType Container)) {
        throw "ASAR 临时工作目录不存在: $($Target.WorkspacePath)"
    }

    $temporaryAsar = $Target.AsarPath + ".zh-cn-new"
    Remove-Item -LiteralPath $temporaryAsar -Force -ErrorAction SilentlyContinue
    # 重新打包前确认目标没有被 Claude 占用，避免耗时打包完成后才失败。
    Assert-AsarReplaceable -Path $Target.AsarPath
    Write-Host "  正在重新打包 ion-dist.asar..." -ForegroundColor DarkGray
    New-AsarArchive $Target.WorkspacePath $temporaryAsar
    try {
        if (-not (Test-AsarFrontendArchive $temporaryAsar)) {
            throw "重新打包后的 ion-dist.asar 未通过结构校验。"
        }
        Move-FileWithRetry -Source $temporaryAsar -Destination $Target.AsarPath
        Write-Host "  ion-dist.asar 已更新" -ForegroundColor Green
        Sync-ClaudeExeAsarIntegrity $Target.ResourcesPath
    }
    finally {
        Remove-Item -LiteralPath $temporaryAsar -Force -ErrorAction SilentlyContinue
    }
}

function Close-FrontendPatchTarget {
    param($Target)

    try {
        if ($null -ne $Target -and $Target.Generated) {
            Remove-GeneratedFrontendWorkspace $Target.ResourcesPath $Target.WorkspacePath
            Remove-Item -LiteralPath $Target.MarkerPath -Force -ErrorAction SilentlyContinue
        }
    }
    finally {
        $script:SkipFrontendFileBackups = $false
    }
}

function Patch-AsarFrontendDirect {
    param(
        [string]$ResourcesPath,
        [hashtable]$Pack,
        [string]$Language
    )

    $asarPath = Join-Path $ResourcesPath "ion-dist.asar"
    $workspacePath = Join-Path $ResourcesPath "ion-dist"
    $markerPath = Join-Path $ResourcesPath ".zh-cn-asar-extracted"
    if (Test-Path -LiteralPath $workspacePath) {
        if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
            throw "发现未标记的 ion-dist 目录，为避免删除用户文件已停止: $workspacePath"
        }
        Remove-GeneratedFrontendWorkspace $ResourcesPath $workspacePath
    }
    Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue

    $replacements = @(Get-FrontendHardcodedReplacements $Language)
    $prepared = New-Object 'System.Collections.Generic.List[object[]]'
    foreach ($pair in $replacements) {
        $source = [string]$pair[0]
        $target = [string]$pair[1]
        if (Test-StructuralJsReplacement $source) {
            continue
        }
        $isPlain = Test-PlainUiTextReplacement $source
        $prepared.Add([object[]]@([bool]$isPlain, $source, $target))
    }

    $slashConfig = Get-SlashCommandGlossConfig $Language
    $displayMarker = "__claudeZhLabelPatch"
    $displayPatch = ';(()=>{const e=Intl.DisplayNames&&Intl.DisplayNames.prototype;if(!e||e.__claudeZhLabelPatch)return;const n=e.of;e.of=function(e){const t=String(e);return t==="zh-CN"?"简体中文":t==="zh-HK"?"繁體中文（香港）":t==="zh-TW"?"繁體中文（台灣）":n.call(this,e)},Object.defineProperty(e,"__claudeZhLabelPatch",{value:!0})})();'
    $workers = [Math]::Max(1, [Math]::Min([Environment]::ProcessorCount, 12))

    Write-Host "  直接扫描 ion-dist.asar（免解包落盘，规则数: $($prepared.Count)）..." -ForegroundColor DarkGray
    $scan = [ClaudeZhPatch.AsarHelper]::ScanFrontendAsar(
        $asarPath,
        $Language,
        $BaseLanguageList,
        $LanguageListPattern,
        $prepared.ToArray(),
        [string]$slashConfig.Profile.module_pattern,
        $displayMarker,
        $workers
    )

    if (-not $scan.AssetsDir -or $scan.TotalJsFiles -eq 0) {
        throw "未找到前端 JS bundle（在 $asarPath 中未定位到前端主 bundle）。Claude 前端目录结构可能已变化，请带上安装日志反馈。"
    }

    if ($scan.WhitelistMatchedNames.Length -eq 0) {
        throw "未能注册中文语言：前端 bundle ($($scan.AssetsDir)) 中找不到语言白名单锚点，Claude 前端格式可能已经变化。"
    }
    Write-Host "  located $($scan.WhitelistMatchedNames.Length)/$($scan.TotalJsFiles) frontend JS files containing target text" -ForegroundColor DarkGray
    foreach ($name in $scan.WhitelistAlreadyNames) {
        Write-Host "  $Language already registered: $name" -ForegroundColor Green
    }
    foreach ($name in $scan.WhitelistChangedNames) {
        Write-Host "  patched language whitelist for ${Language}: $name" -ForegroundColor Green
    }
    if (($scan.WhitelistChangedNames.Length + $scan.WhitelistAlreadyNames.Length) -eq 0) {
        throw "未能注册中文语言，Claude 前端 bundle 格式可能已经变化。"
    }

    Write-Host "  patched hardcoded frontend strings: $($scan.HardcodedTotalReplacements) replacements in $($scan.HardcodedPatchedFiles) files" -ForegroundColor Green

    if ($scan.SlashCandidatePaths.Length -ne 1) {
        Write-Host '  [WARNING] Slash command gloss skipped: expected one menu component' -ForegroundColor DarkYellow
    }
    else {
        $candPath = $scan.SlashCandidatePaths[0]
        $candName = $candPath.Substring($candPath.LastIndexOf('/') + 1)
        try {
            $slashResult = Convert-SlashCommandMenuText $scan.SlashCandidateTexts[0] $slashConfig.Profile $slashConfig.Labels
            if ($slashResult.Status -eq 'already') {
                Write-Host "  slash command gloss already installed: $candName" -ForegroundColor DarkGray
            }
            else {
                $scan.ModifiedTexts[$candPath] = $slashResult.Text
                Write-Host "  patched bilingual slash command menu (${Language}): $candName" -ForegroundColor Green
            }
        }
        catch {
            Write-Host "  [WARNING] Slash command gloss skipped: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }

    if (($scan.DisplayNameTargetPaths.Length + $scan.DisplayNameAlreadyPaths.Length) -eq 0) {
        Write-Host "  no Intl.DisplayNames bundle found; skipping language display names" -ForegroundColor DarkYellow
    }
    else {
        foreach ($p in $scan.DisplayNameAlreadyPaths) {
            $name = $p.Substring($p.LastIndexOf('/') + 1)
            Write-Host "  language display names already patched: $name" -ForegroundColor Green
        }
        $patchedDn = 0
        foreach ($p in $scan.DisplayNameTargetPaths) {
            $cur = $scan.ModifiedTexts[$p]
            if (-not $cur.Contains($displayMarker)) {
                $scan.ModifiedTexts[$p] = $cur + $displayPatch
                $name = $p.Substring($p.LastIndexOf('/') + 1)
                Write-Host "  patched language display names: $name" -ForegroundColor Green
                $patchedDn += 1
            }
        }
        if ($patchedDn -eq 0) {
            Write-Host "  no language display name changes needed" -ForegroundColor Green
        }
    }

    $overlays = New-Object 'System.Collections.Generic.Dictionary[string, byte[]]' ([StringComparer]::Ordinal)
    foreach ($kv in $scan.ModifiedTexts.GetEnumerator()) {
        $overlays[$kv.Key] = $Utf8NoBom.GetBytes($kv.Value)
    }

    $overlays["i18n/$Language.json"] = [IO.File]::ReadAllBytes($Pack["Frontend"])
    Write-Host "  installed ion-dist/i18n/$Language.json" -ForegroundColor Green
    $overlays["i18n/statsig/$Language.json"] = [IO.File]::ReadAllBytes($Pack["Statsig"])
    Write-Host "  installed ion-dist/i18n/statsig/$Language.json" -ForegroundColor Green

    if ($scan.HasDynamicEnUs) {
        $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
        $localizedDynamic = Join-Path (Split-Path -Parent $scriptDir) "resources\dynamic-$Language.json"
        if (Test-Path -LiteralPath $localizedDynamic -PathType Leaf) {
            $overlays["i18n/dynamic/$Language.json"] = [IO.File]::ReadAllBytes($localizedDynamic)
        }
        else {
            $overlays["i18n/dynamic/$Language.json"] = $scan.DynamicEnUsBytes
        }
        Write-Host "  installed ion-dist/i18n/dynamic/$Language.json" -ForegroundColor Green
    }

    if ($scan.HasEnUsJson) {
        $mergedEnUs = Merge-LocaleJson $scan.EnUsJsonText ([IO.File]::ReadAllText($Pack["Frontend"], [Text.Encoding]::UTF8))
        if ($mergedEnUs.Changed -gt 0) {
            $overlays["i18n/en-US.json"] = $Utf8NoBom.GetBytes($mergedEnUs.Json)
            Write-Host "  ion-dist.asar 已把 $Language 词库覆盖进 i18n/en-US.json（$($mergedEnUs.Changed) 条）" -ForegroundColor Green
        }
    }

    if (-not [ClaudeZhPatch.AsarHelper]::HasOverlayChanges($asarPath, $overlays)) {
        Write-Host "  ion-dist.asar 已是最新汉化状态，无需重建" -ForegroundColor Green
        return
    }

    $temporaryAsar = $asarPath + ".zh-cn-new"
    Remove-Item -LiteralPath $temporaryAsar -Force -ErrorAction SilentlyContinue
    Assert-AsarReplaceable -Path $asarPath
    Backup-ModifiedFile $ResourcesPath $asarPath
    Write-Host "  正在流式重建 ion-dist.asar（仅重算 $($overlays.Count) 个变更条目哈希）..." -ForegroundColor DarkGray
    try {
        [ClaudeZhPatch.AsarHelper]::RebuildAsarWithOverlays(
            $asarPath,
            $temporaryAsar,
            $overlays,
            [int]$AsarIntegrityBlockSize,
            $workers
        )
        if (-not (Test-AsarFrontendArchive $temporaryAsar)) {
            throw "重新打包后的 ion-dist.asar 未通过结构校验。"
        }
        Move-FileWithRetry -Source $temporaryAsar -Destination $asarPath
        Write-Host "  ion-dist.asar 已更新" -ForegroundColor Green
    }
    finally {
        Remove-Item -LiteralPath $temporaryAsar -Force -ErrorAction SilentlyContinue
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

    if (-not ("ClaudeZhPatch.AsarHelper" -as [type]) -and $script:FrontendPatcherCSharp) {
        try { Add-Type -TypeDefinition $script:FrontendPatcherCSharp -ErrorAction Stop } catch {}
    }
    if ("ClaudeZhPatch.AsarHelper" -as [type]) {
        Require-File $AsarPath
        return [ClaudeZhPatch.AsarHelper]::GetHeaderHash($AsarPath)
    }

    Require-File $AsarPath
    $stream = [System.IO.File]::Open($AsarPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        if ($stream.Length -lt 16) {
            throw "Unsupported app.asar header in $AsarPath"
        }
        $prefix = [byte[]]::new(8)
        if ($stream.Read($prefix, 0, 8) -ne 8) {
            throw "Unsupported app.asar header in $AsarPath"
        }
        $sizePicklePayload = Get-UInt32LE $prefix 0
        $headerSize = Get-UInt32LE $prefix 4
        if (($sizePicklePayload -ne 4) -or ($headerSize -le 0) -or ($stream.Length -lt (8 + $headerSize))) {
            throw "Unsupported app.asar size pickle in $AsarPath"
        }
        $headerPickle = [byte[]]::new($headerSize)
        if ($stream.Read($headerPickle, 0, [int]$headerSize) -ne [int]$headerSize) {
            throw "Unsupported app.asar header in $AsarPath"
        }
        $headerPayloadSize = Get-UInt32LE $headerPickle 0
        $headerStringSize = Get-Int32LE $headerPickle 4
        $expectedPayloadSize = Align-4 (4 + $headerStringSize)
        if (($headerPayloadSize -ne $expectedPayloadSize) -or ($headerSize -ne (4 + $headerPayloadSize))) {
            throw "Unsupported app.asar header pickle in $AsarPath"
        }
        $headerBytes = [byte[]]::new($headerStringSize)
        [System.Array]::Copy($headerPickle, 8, $headerBytes, 0, $headerStringSize)
        return Get-Sha256Hex $headerBytes
    }
    finally {
        $stream.Dispose()
    }
}

function Get-ClaudeExePathFromResources {
    param([string]$ResourcesPath)

    $appPath = Get-ClaudeAppPathFromResources $ResourcesPath
    $exePath = Join-Path $appPath "Claude.exe"
    if (-not (Test-Path $exePath)) {
        $exePath = Join-Path $appPath "claude.exe"
    }
    Require-File $exePath
    return $exePath
}

function Get-ClaudeExeIntegrityMarker {
    param(
        [string]$ExeText,
        [string]$AsarName
    )

    # Claude Desktop 4.4212+ 把 Electron 的 ASAR integrity 记录改成了 JSON 转义形式：
    #   {"file":"resources\\ion-dist.asar","alg":"SHA256","value":"<hash>"}
    # 旧版本用的是裸相对路径（单反斜杠或双反斜杠两种写法都出现过）：
    #   resources\ion-dist.asar","alg":"SHA256","value":"<hash>"
    # 按优先级依次尝试，返回第一个在 ExeText 中唯一命中的标记。
    $bs = [string][char]92
    $fw = [string][char]47
    $tail = '","alg":"SHA256","value":"'
    $candidates = @(
        ('{"file":"resources' + $bs + $bs + $AsarName + $tail),
        ('resources' + $bs + $bs + $AsarName + $tail),
        ('{"file":"resources' + $fw + $AsarName + $tail),
        ('resources' + $fw + $AsarName + $tail),
        ('resources' + $bs + $AsarName + $tail)
    )

    foreach ($candidate in $candidates) {
        $index = $ExeText.IndexOf($candidate, [System.StringComparison]::Ordinal)
        if ($index -lt 0) {
            continue
        }
        if ($ExeText.IndexOf($candidate, $index + 1, [System.StringComparison]::Ordinal) -ge 0) {
            throw "Could not find a unique Claude.exe $AsarName integrity marker. Claude bundle format may have changed."
        }
        return $candidate
    }

    throw "Could not find Claude.exe $AsarName integrity marker. Claude bundle format may have changed."
}

function Assert-ClaudeExeIntegrityMarkers {
    param([string]$ResourcesPath)

    # 4.4212 曾出现「asar 已改完、Claude.exe 哈希却写不回去」的半坏状态。
    # 真正写入前先只读校验所有目标的标记，格式不兼容时零副作用地快速失败。
    $exePath = Get-ClaudeExePathFromResources $ResourcesPath
    $exeInfo = Get-Item -LiteralPath $exePath
    $targets = @(@("app.asar", "ion-dist.asar") | Where-Object {
        Test-Path -LiteralPath (Join-Path $ResourcesPath $_) -PathType Leaf
    })
    if ($targets.Count -eq 0) {
        return
    }

    Write-Host "  [进度] 正在校验 Claude.exe 完整性标记..." -ForegroundColor DarkGray
    if (-not ("ClaudeZhPatch.ExeIntegrityHelper" -as [type]) -and $script:FrontendPatcherCSharp) {
        try { Add-Type -TypeDefinition $script:FrontendPatcherCSharp -ErrorAction Stop } catch {}
    }
    if ("ClaudeZhPatch.ExeIntegrityHelper" -as [type]) {
        $null = [ClaudeZhPatch.ExeIntegrityHelper]::FindMarkerOffsets($exePath, [string[]]$targets)
        return
    }

    $exeText = [System.IO.File]::ReadAllText($exePath, [System.Text.Encoding]::ASCII)
    foreach ($asarName in $targets) {
        $marker = Get-ClaudeExeIntegrityMarker -ExeText $exeText -AsarName $asarName
        $hashOffset = $exeText.IndexOf($marker, [System.StringComparison]::Ordinal) + $marker.Length
        if (($hashOffset + 64) -gt $exeInfo.Length) {
            throw "Claude.exe $asarName integrity marker has invalid bounds."
        }
    }
}


function Merge-LocaleJson {
    param([string]$TargetJson, [string]$OverrideJson)

    if (-not ("ClaudeZhPatch.AsarHelper" -as [type]) -and $script:FrontendPatcherCSharp) {
        try { Add-Type -TypeDefinition $script:FrontendPatcherCSharp -ErrorAction Stop } catch {}
    }
    if ("ClaudeZhPatch.AsarHelper" -as [type]) {
        $changedCount = 0
        $mergedJson = [ClaudeZhPatch.AsarHelper]::MergeLocaleJson($TargetJson, $OverrideJson, [ref]$changedCount)
        return [pscustomobject]@{
            Changed = $changedCount
            Json = $mergedJson
        }
    }

    $target = $TargetJson | ConvertFrom-Json
    $override = $OverrideJson | ConvertFrom-Json

    $changed = 0
    foreach ($property in $override.PSObject.Properties) {
        if ($property.Value -isnot [string]) { continue }
        $existing = $target.PSObject.Properties[$property.Name]
        if ($null -ne $existing) {
            if ([string]$existing.Value -ne $property.Value) {
                $existing.Value = $property.Value
                $changed++
            }
            continue
        }
        Add-Member -InputObject $target -NotePropertyName $property.Name -NotePropertyValue $property.Value
        $changed++
    }

    return [pscustomobject]@{
        Changed = $changed
        Json = ($target | ConvertTo-Json -Depth 4 -Compress)
    }
}

function Merge-LocaleOverride {
    param(
        [Parameter(Mandatory = $true)][string]$I18nDirectory,
        [Parameter(Mandatory = $true)][string]$Lang
    )

    # Claude 4.29+ 的主进程菜单和前端 i18n 都固定按 en-US 加载词库（渲染进程约 1 秒后
    # 还会把 locale 写回 en-US），只放 zh-CN.json 不会被选中。这里把所选中文词库合并
    # 覆盖进 en-US.json，才能覆盖那些只存在于词库、JS 里没有字面量的条目。
    $targetPath = Join-Path $I18nDirectory "en-US.json"
    $overridePath = Join-Path $I18nDirectory "$Lang.json"
    if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $overridePath -PathType Leaf)) {
        return 0
    }

    try {
        $merged = Merge-LocaleJson ([IO.File]::ReadAllText($targetPath, [Text.Encoding]::UTF8)) ([IO.File]::ReadAllText($overridePath, [Text.Encoding]::UTF8))
    }
    catch {
        Write-Host "  [提示] 词库不是有效 JSON，跳过中英合并: $($_.Exception.Message)" -ForegroundColor DarkYellow
        return 0
    }

    if ($merged.Changed -gt 0) {
        [IO.File]::WriteAllText($targetPath, $merged.Json, (New-Object System.Text.UTF8Encoding($false)))
    }
    return $merged.Changed
}

function Patch-DesktopShellLocale {
    param(
        [string]$ResourcesPath,
        [string]$Lang,
        [switch]$SkipIntegritySync
    )

    # Claude 4.29+ 的主进程界面（原生菜单栏、任务栏右键菜单）只从 app.asar 内的
    # resources/i18n 词库取文案，但语言白名单不含中文、渲染进程还会把 locale 写回
    # en-US，所以仅补一份 <Lang>.json 不会生效。app.asar 是主进程包，真实安装里含
    # unpacked / executable 条目，解包重打包会破坏主进程，因此这里就地改写头部与 payload。
    $asarPath = Join-Path $ResourcesPath "app.asar"
    if (-not (Test-Path -LiteralPath $asarPath -PathType Leaf)) {
        Write-Host "  [提示] 未找到 app.asar，跳过主进程菜单汉化。" -ForegroundColor DarkYellow
        return
    }

    $desktopPack = Join-Path $ResourcesPath "$Lang.json"
    if (-not (Test-Path -LiteralPath $desktopPack -PathType Leaf)) {
        Write-Host "  [提示] 未找到桌面词库 $Lang.json，跳过主进程菜单汉化。" -ForegroundColor DarkYellow
        return
    }

    $parsed = Read-AsarHeaderFromFile $asarPath
    $entryPaths = @(Get-AsarEntryPaths $parsed["Header"])
    $basePath = "resources/i18n/en-US.json"
    if ($entryPaths -notcontains $basePath) {
        Write-Host "  [提示] app.asar 内未找到 $basePath，当前版本可能不读取壳层词库，跳过主进程菜单汉化。" -ForegroundColor DarkYellow
        return
    }

    try {
        $targetJson = [Text.Encoding]::UTF8.GetString((Read-AsarEntryBytes $asarPath $parsed $basePath))
        $merged = Merge-LocaleJson $targetJson ([IO.File]::ReadAllText($desktopPack, [Text.Encoding]::UTF8))
    }
    catch {
        Write-Host "  [提示] 词库不是有效 JSON，跳过主进程菜单汉化: $($_.Exception.Message)" -ForegroundColor DarkYellow
        return
    }

    $localePath = "resources/i18n/$Lang.json"
    $needSetEnUs = $merged.Changed -gt 0
    $needAddLocale = $entryPaths -notcontains $localePath

    if (-not ("ClaudeZhPatch.AsarHelper" -as [type]) -and $script:FrontendPatcherCSharp) {
        try { Add-Type -TypeDefinition $script:FrontendPatcherCSharp -ErrorAction Stop } catch {}
    }

    $changed = 0
    if (($needSetEnUs -or $needAddLocale) -and ("ClaudeZhPatch.AsarHelper" -as [type])) {
        if ($needSetEnUs) {
            $setPaths = [string[]]@($basePath)
            $setContents = New-Object 'byte[][]' 1
            $setContents[0] = [Text.Encoding]::UTF8.GetBytes($merged.Json)
        }
        else {
            $setPaths = [string[]]@()
            $setContents = New-Object 'byte[][]' 0
        }
        if ($needAddLocale) {
            $addPaths = [string[]]@($localePath)
            $addContents = New-Object 'byte[][]' 1
            $addContents[0] = [IO.File]::ReadAllBytes($desktopPack)
        }
        else {
            $addPaths = [string[]]@()
            $addContents = New-Object 'byte[][]' 0
        }

        Assert-AsarReplaceable -Path $asarPath
        $temporary = "$asarPath.zh-cn-new"
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        Backup-ModifiedFile $ResourcesPath $asarPath
        try {
            $applied = [ClaudeZhPatch.AsarHelper]::UpdateAsarEntries(
                $asarPath,
                $temporary,
                $setPaths,
                $setContents,
                $addPaths,
                $addContents,
                [int]$AsarIntegrityBlockSize
            )
            if ($applied -gt 0) {
                Move-FileWithRetry -Source $temporary -Destination $asarPath
            }
        }
        catch {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
            throw
        }

        if ($needSetEnUs) {
            $changed = $merged.Changed
            Write-Host "  app.asar 已把 $Lang 词库覆盖进 $basePath（$changed 条）" -ForegroundColor Green
        }
        else {
            Write-Host "  app.asar 的 $basePath 已是最新中文词库" -ForegroundColor Green
        }
        if ($needAddLocale) {
            Write-Host "  app.asar 已补入主进程词库 $localePath" -ForegroundColor Green
            $changed = $changed + 1
        }
    }
    else {
        if ($needSetEnUs) {
            Set-AsarEntryContent -AsarPath $asarPath -ResourcesPath $ResourcesPath -EntryPath $basePath -Content ([Text.Encoding]::UTF8.GetBytes($merged.Json))
            $changed = $merged.Changed
            Write-Host "  app.asar 已把 $Lang 词库覆盖进 $basePath（$changed 条）" -ForegroundColor Green
        }
        else {
            Write-Host "  app.asar 的 $basePath 已是最新中文词库" -ForegroundColor Green
        }

        if ($needAddLocale) {
            $localeBytes = [IO.File]::ReadAllBytes($desktopPack)
            if (Add-AsarEntryContent -AsarPath $asarPath -ResourcesPath $ResourcesPath -EntryPath $localePath -Content $localeBytes) {
                Write-Host "  app.asar 已补入主进程词库 $localePath" -ForegroundColor Green
                $changed = $changed + 1
            }
        }
    }

    if ($changed -gt 0 -and -not $SkipIntegritySync) {
        # app.asar 头部变了，Claude.exe 内嵌的 ASAR 头哈希必须同步，否则应用校验失败。
        Sync-ClaudeExeAsarIntegrity $ResourcesPath
    }
}


function Sync-ClaudeExeAsarIntegrity {
    param([string]$ResourcesPath)

    $exePath = Get-ClaudeExePathFromResources $ResourcesPath
    $targets = @(@("app.asar", "ion-dist.asar") | Where-Object {
        Test-Path -LiteralPath (Join-Path $ResourcesPath $_) -PathType Leaf
    })
    if ($targets.Count -eq 0) {
        return
    }
    $exeInfo = Get-Item -LiteralPath $exePath
    Write-Host "  [进度] 正在读取 Claude.exe ($(Format-ByteSize $exeInfo.Length)) 用于定位完整性标记..." -ForegroundColor DarkGray

    if (-not ("ClaudeZhPatch.ExeIntegrityHelper" -as [type]) -and $script:FrontendPatcherCSharp) {
        try { Add-Type -TypeDefinition $script:FrontendPatcherCSharp -ErrorAction Stop } catch {}
    }

    $hashOffsets = $null
    $exeText = $null
    if ("ClaudeZhPatch.ExeIntegrityHelper" -as [type]) {
        $hashOffsets = [ClaudeZhPatch.ExeIntegrityHelper]::FindMarkerOffsets($exePath, [string[]]$targets)
    }
    else {
        $exeText = [System.IO.File]::ReadAllText($exePath, [System.Text.Encoding]::ASCII)
    }

    for ($idx = 0; $idx -lt $targets.Count; $idx++) {
        $asarName = $targets[$idx]
        $asarPath = Join-Path $ResourcesPath $asarName
        Write-Host "  [进度] 正在计算 $asarName header hash..." -ForegroundColor DarkGray
        $headerHash = Get-AsarHeaderHash $asarPath

        if ($null -ne $hashOffsets) {
            $hashOffset = [int64]$hashOffsets[$idx]
        }
        else {
            $marker = Get-ClaudeExeIntegrityMarker -ExeText $exeText -AsarName $asarName
            $markerIndex = $exeText.IndexOf($marker, [System.StringComparison]::Ordinal)
            $hashOffset = [int64]($markerIndex + $marker.Length)
            if (($hashOffset + 64) -gt $exeInfo.Length) {
                throw "Claude.exe $asarName integrity marker has invalid bounds."
            }
        }

        $stream = [System.IO.File]::Open($exePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
        try {
            $hashBytes = [byte[]]::new(64)
            $stream.Seek($hashOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
            if ($stream.Read($hashBytes, 0, $hashBytes.Length) -ne $hashBytes.Length) {
                throw "Claude.exe $asarName integrity marker has invalid bounds."
            }
            $currentHash = [System.Text.Encoding]::ASCII.GetString($hashBytes)

            if ($currentHash -eq $headerHash) {
                Write-Host "  Claude.exe $asarName integrity already matches" -ForegroundColor Green
                continue
            }
            if ($currentHash -notmatch '^[0-9a-fA-F]{64}$') {
                throw "Claude.exe $asarName integrity value is not a SHA256 hex string."
            }

            Backup-AppFile $ResourcesPath $exePath
            Write-Host "  [进度] 正在定点写回 Claude.exe 中 $asarName 的完整性哈希（64 bytes）..." -ForegroundColor DarkGray
            $newHashBytes = [System.Text.Encoding]::ASCII.GetBytes($headerHash)
            $stream.Seek($hashOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
            $stream.Write($newHashBytes, 0, $newHashBytes.Length)
        }
        finally {
            $stream.Dispose()
        }
        Write-Host "  updated Claude.exe $asarName integrity: $currentHash -> $headerHash" -ForegroundColor Green
    }
}

function Find-GoPclntabOffset {
    param(
        [byte[]]$Bytes,
        [string]$Latin1Text,
        [bool]$IsArm64,
        [uint64]$ExpectedTextStart
    )

    $quantum = if ($IsArm64) { 4 } else { 1 }
    $magicBytes = [byte[]](0xF1, 0xFF, 0xFF, 0xFF, 0x00, 0x00, $quantum, 0x08)
    $magic = [System.Text.Encoding]::GetEncoding(28591).GetString($magicBytes)
    $searchFrom = 0
    while ($true) {
        $i = $Latin1Text.IndexOf($magic, $searchFrom, [System.StringComparison]::Ordinal)
        if ($i -lt 0) { return -1 }
        $nfunc = [BitConverter]::ToUInt64($Bytes, $i + 8)
        $textStart = [BitConverter]::ToUInt64($Bytes, $i + 24)
        $pclnOff = [BitConverter]::ToUInt64($Bytes, $i + 64)
        $functabEnd = [uint64]$i + $pclnOff + $nfunc * 8 + 8
        if ($nfunc -gt 0 -and $nfunc -lt 500000 -and
            $textStart -eq $ExpectedTextStart -and
            $pclnOff -gt 0 -and
            $functabEnd -lt [uint64]$Bytes.Length) {
            return $i
        }
        $searchFrom = $i + 1
    }
}

function Resolve-GoFuncEntry {
    param(
        [byte[]]$Bytes,
        [string]$Latin1Text,
        [int64]$FunctabStart,
        [int64]$FunctabEnd,
        [string]$NameTab,
        [string]$FuncName,
        [switch]$Suffix,
        [uint32]$TextVSize
    )

    # 收集候选 nameOff。funcnametab 允许复用后缀，因此后缀匹配时既把命中位置
    # 本身当作 nameOff，也把它所在完整名字的起点当作候选。
    $enc = [System.Text.Encoding]::GetEncoding(28591)
    $candidates = New-Object System.Collections.Generic.List[int]
    $from = 0
    while ($true) {
        $i = $NameTab.IndexOf($FuncName + [char]0, $from, [System.StringComparison]::Ordinal)
        if ($i -lt 0) { break }
        if ($Suffix) {
            $prev = if ($i -gt 0) { $NameTab.LastIndexOf([char]0, $i - 1) } else { -1 }
            $candidates.Add($prev + 1)
        }
        $candidates.Add($i)
        $from = $i + 1
    }

    # functab 条目形如 [entryoff][funcoff]，funcoff 指向 _func，其 nameOff 正是候选值。
    # 用「entryoff + funcoff」双字模式回查表位置，把 nameOff 唯一地映射到 entryoff。
    $entries = @{}
    foreach ($nameOff in $candidates) {
        $namePat = $enc.GetString([BitConverter]::GetBytes([int32]$nameOff))
        $searchFrom = $FunctabStart
        while ($true) {
            $x = $Latin1Text.IndexOf($namePat, [int]$searchFrom, [System.StringComparison]::Ordinal)
            if ($x -lt 0 -or $x -ge ($Latin1Text.Length - 4)) { break }
            if ($x -ge ($FunctabStart + 4)) {
                $fdStart = [int64]($x - 4)
                $entryoff = [BitConverter]::ToUInt32($Bytes, $fdStart)
                $funcoff = [int64]($fdStart - $FunctabStart)
                if ([uint64]$entryoff -lt [uint64]$TextVSize -and $funcoff -ge 0) {
                    $pairBytes = New-Object byte[] 8
                    [BitConverter]::GetBytes([uint32]$entryoff).CopyTo($pairBytes, 0)
                    [BitConverter]::GetBytes([uint32]$funcoff).CopyTo($pairBytes, 4)
                    $pairPat = $enc.GetString($pairBytes)
                    $pairIdx = $Latin1Text.IndexOf($pairPat, [int]$FunctabStart, [System.StringComparison]::Ordinal)
                    if ($pairIdx -ge $FunctabStart -and $pairIdx -lt $FunctabEnd -and
                        ((($pairIdx - $FunctabStart) % 8) -eq 0)) {
                        $entries[[uint32]$entryoff] = [int64](($pairIdx - $FunctabStart) / 8)
                    }
                }
            }
            $searchFrom = $x + 1
        }
    }

    if ($entries.Count -eq 0) { return $null }
    $entry = [uint32]($entries.Keys | Sort-Object | Select-Object -First 1)
    return @($entry, [int64]$entries[$entry])
}

function Patch-CoworkService {
    param(
        [string]$ResourcesPath,
        [string]$Version = "",
        [switch]$ScanOnly
    )

    $svcPath = Join-Path $ResourcesPath "cowork-svc.exe"
    if (-not (Test-Path -LiteralPath $svcPath)) {
        return @("未找到 cowork-svc.exe，跳过")
    }

    $bytes = [System.IO.File]::ReadAllBytes($svcPath)
    $latin1 = [System.Text.Encoding]::GetEncoding(28591)
    # 若备份集中已有原始副本则优先使用，保证重复安装时仍能唯一定位原始指令
    $backupRoot = Join-Path $ResourcesPath ".zh-cn-backups"
    $backupFile = Get-ChildItem -Path $backupRoot -Recurse -Filter "cowork-svc.exe" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($backupFile) {
        $originalBytes = [System.IO.File]::ReadAllBytes($backupFile.FullName)
    } else {
        $originalBytes = $bytes
    }
    $originalLatin1Text = $latin1.GetString($originalBytes)

    if ($bytes.Length -lt 0x40 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) {
        return @("[警告] cowork-svc.exe 不是有效的 PE 文件，跳过。")
    }

    $peOff = [BitConverter]::ToUInt32($bytes, 0x3C)
    if ($peOff -lt 0 -or ($peOff + 24) -gt $bytes.Length) {
        return @("[警告] PE 头部偏移无效，跳过。")
    }

    $machine = [BitConverter]::ToUInt16($bytes, $peOff + 4)
    $isArm64 = ($machine -eq 0xAA64)
    $isX64 = ($machine -eq 0x8664)
    if (-not ($isArm64 -or $isX64)) {
        return @("[警告] 无法识别架构 (machine=0x$($machine.ToString('X4')))，跳过。")
    }

    $numSections = [BitConverter]::ToUInt16($bytes, $peOff + 6)
    $optSize = [BitConverter]::ToUInt16($bytes, $peOff + 20)
    $optOff = $peOff + 24
    $optMagic = [BitConverter]::ToUInt16($bytes, $optOff)
    $imageBase = if ($optMagic -eq 0x20B) {
        [BitConverter]::ToUInt64($bytes, $optOff + 24)
    } else {
        [BitConverter]::ToUInt32($bytes, $optOff + 28)
    }

    $textVAddr = [uint32]0
    $textRAddr = [uint32]0
    $textVSize = [uint32]0
    for ($i = 0; $i -lt $numSections; $i++) {
        $s = $peOff + 24 + $optSize + $i * 40
        if (($s + 40) -gt $bytes.Length) { break }
        $name = [System.Text.Encoding]::ASCII.GetString($bytes, $s, 8).TrimEnd([char]0)
        if ($name -eq ".text") {
            $textVSize = [BitConverter]::ToUInt32($bytes, $s + 8)
            $textVAddr = [BitConverter]::ToUInt32($bytes, $s + 12)
            $textRAddr = [BitConverter]::ToUInt32($bytes, $s + 20)
            break
        }
    }
    if ($textRAddr -eq 0) {
        return @("[警告] 未找到 .text 节区，跳过。")
    }

    $expectedTextStart = [uint64]$imageBase + [uint64]$textVAddr
    $pt = Find-GoPclntabOffset -Bytes $originalBytes -Latin1Text $originalLatin1Text -IsArm64 $isArm64 -ExpectedTextStart $expectedTextStart
    if ($pt -lt 0) {
        return @("[警告] 未找到 Go pclntab 符号表，跳过。")
    }

    $nfunc = [BitConverter]::ToUInt64($originalBytes, $pt + 8)
    $funcnameOff = [BitConverter]::ToUInt64($originalBytes, $pt + 32)
    $pclnOff = [BitConverter]::ToUInt64($originalBytes, $pt + 64)

    $nameTabStart = [int64]($pt + $funcnameOff)
    $nameTabEnd = [int64]($pt + $pclnOff)
    if ($nameTabEnd -gt $bytes.Length) { $nameTabEnd = $bytes.Length }
    $nameTab = $originalLatin1Text.Substring($nameTabStart, [int]($nameTabEnd - $nameTabStart))

    $functabStart = [int64]($pt + $pclnOff)
    $functabEnd = [int64]($functabStart + $nfunc * 8)
    # Go 的 functab entryoff 是相对 textStart 的偏移，不是 RVA
    $textEndEntry = [uint32]$textVSize

    $resolved = @{}
    foreach ($funcName in @("main.runService", "main.isWindowsService")) {
        $r = Resolve-GoFuncEntry -Bytes $originalBytes -Latin1Text $originalLatin1Text `
            -FunctabStart $functabStart -FunctabEnd $functabEnd -NameTab $nameTab `
            -FuncName $funcName -TextVSize $textEndEntry
        if ($null -eq $r) {
            return @("[警告] 未能唯一定位 $funcName，跳过。")
        }
        $resolved[$funcName] = $r
    }

    $runEntry = [uint32]$resolved["main.runService"][0]
    $runIdx = [int64]$resolved["main.runService"][1]
    $wsEntry = [uint32]$resolved["main.isWindowsService"][0]
    if (($runIdx + 1) -lt $nfunc) {
        $runEnd = [BitConverter]::ToUInt32($originalBytes, $functabStart + ($runIdx + 1) * 8)
    } else {
        $runEnd = [uint32]$textEndEntry
    }

    $runStartFile = [int64]($runEntry + $textRAddr)
    $runEndFile = [int64]($runEnd + $textRAddr)

    $sites = @()
    if ($isArm64) {
        for ($f = $runStartFile; ($f + 4) -le $runEndFile; $f += 4) {
            $w = [BitConverter]::ToUInt32($originalBytes, $f)
            if ((($w -shr 26) -band 0x3F) -ne 0x25) { continue }  # BL: 100101b
            $imm = $w -band 0x03FFFFFF
            if ($imm -ge 0x02000000) { $imm -= 0x04000000 }
            $insnEntry = [int64]($f - $textRAddr)
            if (($insnEntry + $imm * 4) -eq [int64]$wsEntry) { $sites += $f }
        }
    } else {
        for ($f = $runStartFile; ($f + 5) -le $runEndFile; $f++) {
            if ($originalBytes[$f] -ne 0xE8) { continue }
            $rel = [BitConverter]::ToInt32($originalBytes, $f + 1)
            $insnEntry = [int64]($f - $textRAddr)
            if (($insnEntry + 5 + $rel) -eq [int64]$wsEntry) { $sites += $f }
        }
    }

    $archLabel = if ($isArm64) { "ARM64" } else { "x64" }
    if ($sites.Count -ne 1) {
        return @("[警告] 在 runService 中找到 $($sites.Count) 处 isWindowsService 调用 (预期 1 处)，跳过。")
    }

    # 语义校验：isWindowsService() 的返回值就是「是否启用客户端签名校验」的开关，
    # 它紧接着被作为第 2 个参数传给 (*Server).InitSignatureVerification。若该调用
    # 不存在，说明二进制布局已变化，此时不应凭符号名猜测补丁点。
    $initR = Resolve-GoFuncEntry -Bytes $originalBytes -Latin1Text $originalLatin1Text `
        -FunctabStart $functabStart -FunctabEnd $functabEnd -NameTab $nameTab `
        -FuncName "InitSignatureVerification" -Suffix -TextVSize $textEndEntry
    if ($null -eq $initR) {
        return @("[警告] 未找到 InitSignatureVerification，无法校验补丁点语义，跳过。")
    }
    $initEntry = [uint64]$initR[0]
    $site = $sites[0]
    $hasInitCall = $false
    $scanEnd = [Math]::Min($site + 64, $runEndFile)
    for ($f = $site + 4; $f -lt $scanEnd; $f++) {
        if ($isArm64) {
            if ((($f - $site) % 4) -ne 0) { continue }
            $w = [BitConverter]::ToUInt32($originalBytes, $f)
            if ((($w -shr 26) -band 0x3F) -ne 0x25) { continue }
            $imm = $w -band 0x03FFFFFF
            if ($imm -ge 0x02000000) { $imm -= 0x04000000 }
            if ([uint64]([int64]($f - $textRAddr) + $imm * 4) -eq $initEntry) { $hasInitCall = $true; break }
        } else {
            if ($originalBytes[$f] -ne 0xE8) { continue }
            $rel = [BitConverter]::ToInt32($originalBytes, $f + 1)
            if ([uint64]([int64]($f - $textRAddr) + 5 + $rel) -eq $initEntry) { $hasInitCall = $true; break }
        }
    }
    if (-not $hasInitCall) {
        return @("[警告] 补丁点后未跟随 InitSignatureVerification 调用，布局已变化，跳过。")
    }

    $patch = if ($isArm64) { [byte[]](0x00, 0x00, 0x80, 0x52) } else { [byte[]](0x31, 0xC0, 0x90, 0x90, 0x90) }

    # 检查当前状态是否已是补丁
    $alreadyPatched = $true
    for ($k = 0; $k -lt $patch.Length; $k++) {
        if ($bytes[$site + $k] -ne $patch[$k]) { $alreadyPatched = $false; break }
    }
    if ($alreadyPatched) {
        return @("cowork-svc.exe ($archLabel) 已处于补丁状态，无需重复处理")
    }

    if ($ScanOnly) {
        return @("[ScanOnly] 定位成功 ($archLabel): runService@0x$($runEntry.ToString('X8')) isWindowsService@0x$($wsEntry.ToString('X8')) callSite=0x$($site.ToString('X'))")
    }

    # 备份原始文件
    $backupDir = Join-Path $backupRoot "init-backup"
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    $backupFileTarget = Join-Path $backupDir "cowork-svc.exe"
    if (-not (Test-Path -LiteralPath $backupFileTarget)) {
        Copy-Item -LiteralPath $svcPath -Destination $backupFileTarget -Force
    }

    # 写入补丁
    $stream = [System.IO.File]::Open($svcPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite)
    try {
        $stream.Seek($site, [System.IO.SeekOrigin]::Begin) | Out-Null
        $stream.Write($patch, 0, $patch.Length)
    } finally {
        $stream.Dispose()
    }

    return @("✓ cowork-svc.exe ($archLabel) 签名校验分支已修补 (callSite=0x$($site.ToString('X')))")
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
    if (-not ("ClaudeZhPatch.FrontendPatcher" -as [type]) -and $script:FrontendPatcherCSharp) {
        try { Add-Type -TypeDefinition $script:FrontendPatcherCSharp -ErrorAction Stop } catch {}
    }
    if ("ClaudeZhPatch.FrontendPatcher" -as [type]) {
        $filePaths = [string[]]@($jsFiles | ForEach-Object { $_.FullName })
        $workers = [Math]::Max(1, [Math]::Min([Environment]::ProcessorCount, 12))
        $matchedPaths = [ClaudeZhPatch.FrontendPatcher]::FindFilesContaining($filePaths, [string[]]$patterns, $workers)
        $matched = New-Object System.Collections.Generic.List[System.IO.FileInfo]
        foreach ($p in $matchedPaths) {
            $matched.Add([System.IO.FileInfo]::new($p))
        }
        Write-Host "  located $($matched.Count)/$($jsFiles.Count) frontend JS files containing target text" -ForegroundColor DarkGray
        return @($matched)
    }

    $keep = 0
    foreach ($needle in $patterns) {
        $keep = [Math]::Max($keep, $needle.Length - 1)
    }
    $buffer = [char[]]::new(256 * 1024)
    $matched = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    foreach ($file in $jsFiles) {
        # StreamReader preserves UTF-8 characters split across reads. Keep enough
        # overlap for the longest needle, rather than imposing a fixed limit.
        $reader = [System.IO.StreamReader]::new($file.FullName, [System.Text.Encoding]::UTF8)
        try {
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
    $replacements = New-Object 'System.Collections.Generic.List[object[]]'
    foreach ($item in $items) {
        if ($item.Count -ne 2) {
            throw "无效的前端硬编码替换项: $path"
        }
        $replacements.Add([object[]]@([string]$item[0], [string]$item[1]))
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
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace ClaudeZhPatch
{
    internal sealed class JsonRawNumber
    {
        public readonly string Raw;
        public JsonRawNumber(string raw) { Raw = raw; }
        public long AsInt64()
        {
            return long.Parse(Raw, CultureInfo.InvariantCulture);
        }
    }

    internal sealed class JsonObject
    {
        public readonly List<KeyValuePair<string, object>> Entries = new List<KeyValuePair<string, object>>();
        private readonly Dictionary<string, int> _index = new Dictionary<string, int>(StringComparer.Ordinal);

        public bool TryGet(string key, out object value)
        {
            int idx;
            if (_index.TryGetValue(key, out idx))
            {
                value = Entries[idx].Value;
                return true;
            }
            value = null;
            return false;
        }

        public bool ContainsKey(string key)
        {
            return _index.ContainsKey(key);
        }

        public void Set(string key, object value)
        {
            int idx;
            if (_index.TryGetValue(key, out idx))
            {
                Entries[idx] = new KeyValuePair<string, object>(key, value);
            }
            else
            {
                _index[key] = Entries.Count;
                Entries.Add(new KeyValuePair<string, object>(key, value));
            }
        }
    }

    internal static class MiniJson
    {
        private struct Parser
        {
            private readonly string _s;
            private int _pos;

            public Parser(string s)
            {
                _s = s;
                _pos = 0;
            }

            public object ParseRoot()
            {
                SkipWs();
                object val = ParseValue();
                SkipWs();
                if (_pos != _s.Length)
                {
                    throw new FormatException("Unexpected trailing JSON content at position " + _pos);
                }
                return val;
            }

            private void SkipWs()
            {
                while (_pos < _s.Length)
                {
                    char c = _s[_pos];
                    if (c == ' ' || c == '\t' || c == '\r' || c == '\n') _pos++;
                    else break;
                }
            }

            private object ParseValue()
            {
                SkipWs();
                if (_pos >= _s.Length) throw new FormatException("Unexpected end of JSON");
                char c = _s[_pos];
                if (c == '{') return ParseObject();
                if (c == '[') return ParseArray();
                if (c == '"') return ParseString();
                if (c == 't') { Expect("true"); return true; }
                if (c == 'f') { Expect("false"); return false; }
                if (c == 'n') { Expect("null"); return null; }
                if (c == '-' || (c >= '0' && c <= '9')) return ParseNumber();
                throw new FormatException("Unexpected JSON character '" + c + "' at position " + _pos);
            }

            private void Expect(string lit)
            {
                if (_pos + lit.Length > _s.Length || string.CompareOrdinal(_s, _pos, lit, 0, lit.Length) != 0)
                {
                    throw new FormatException("Expected '" + lit + "' at position " + _pos);
                }
                _pos += lit.Length;
            }

            private JsonObject ParseObject()
            {
                _pos++; // '{'
                JsonObject obj = new JsonObject();
                SkipWs();
                if (_pos < _s.Length && _s[_pos] == '}')
                {
                    _pos++;
                    return obj;
                }
                while (true)
                {
                    SkipWs();
                    if (_pos >= _s.Length || _s[_pos] != '"')
                    {
                        throw new FormatException("Expected string key at position " + _pos);
                    }
                    string key = ParseString();
                    SkipWs();
                    if (_pos >= _s.Length || _s[_pos] != ':')
                    {
                        throw new FormatException("Expected ':' at position " + _pos);
                    }
                    _pos++;
                    object val = ParseValue();
                    obj.Set(key, val);
                    SkipWs();
                    if (_pos >= _s.Length) throw new FormatException("Unterminated JSON object");
                    char sep = _s[_pos++];
                    if (sep == '}') return obj;
                    if (sep != ',') throw new FormatException("Expected ',' or '}' at position " + (_pos - 1));
                }
            }

            private List<object> ParseArray()
            {
                _pos++; // '['
                List<object> list = new List<object>();
                SkipWs();
                if (_pos < _s.Length && _s[_pos] == ']')
                {
                    _pos++;
                    return list;
                }
                while (true)
                {
                    list.Add(ParseValue());
                    SkipWs();
                    if (_pos >= _s.Length) throw new FormatException("Unterminated JSON array");
                    char sep = _s[_pos++];
                    if (sep == ']') return list;
                    if (sep != ',') throw new FormatException("Expected ',' or ']' at position " + (_pos - 1));
                }
            }

            private string ParseString()
            {
                _pos++; // '"'
                int start = _pos;
                StringBuilder sb = null;
                while (_pos < _s.Length)
                {
                    char c = _s[_pos++];
                    if (c == '"')
                    {
                        if (sb == null) return _s.Substring(start, _pos - 1 - start);
                        sb.Append(_s, start, _pos - 1 - start);
                        return sb.ToString();
                    }
                    if (c == '\\')
                    {
                        if (sb == null) sb = new StringBuilder();
                        if (_pos - 1 > start) sb.Append(_s, start, _pos - 1 - start);
                        if (_pos >= _s.Length) throw new FormatException("Unterminated string escape");
                        char esc = _s[_pos++];
                        switch (esc)
                        {
                            case '"': sb.Append('"'); break;
                            case '\\': sb.Append('\\'); break;
                            case '/': sb.Append('/'); break;
                            case 'b': sb.Append('\b'); break;
                            case 'f': sb.Append('\f'); break;
                            case 'n': sb.Append('\n'); break;
                            case 'r': sb.Append('\r'); break;
                            case 't': sb.Append('\t'); break;
                            case 'u':
                                if (_pos + 4 > _s.Length) throw new FormatException("Invalid unicode escape");
                                int code = ParseHex4(_s, _pos);
                                _pos += 4;
                                sb.Append((char)code);
                                break;
                            default:
                                throw new FormatException("Invalid escape character '\\" + esc + "'");
                        }
                        start = _pos;
                    }
                }
                throw new FormatException("Unterminated JSON string");
            }

            private static int ParseHex4(string s, int offset)
            {
                int v = 0;
                for (int i = 0; i < 4; i++)
                {
                    char c = s[offset + i];
                    int d;
                    if (c >= '0' && c <= '9') d = c - '0';
                    else if (c >= 'a' && c <= 'f') d = 10 + (c - 'a');
                    else if (c >= 'A' && c <= 'F') d = 10 + (c - 'A');
                    else throw new FormatException("Invalid hex digit '" + c + "'");
                    v = (v << 4) | d;
                }
                return v;
            }

            private JsonRawNumber ParseNumber()
            {
                int start = _pos;
                if (_s[_pos] == '-') _pos++;
                if (_pos >= _s.Length || _s[_pos] < '0' || _s[_pos] > '9')
                {
                    throw new FormatException("Invalid number at position " + start);
                }
                while (_pos < _s.Length && _s[_pos] >= '0' && _s[_pos] <= '9') _pos++;
                if (_pos < _s.Length && _s[_pos] == '.')
                {
                    _pos++;
                    if (_pos >= _s.Length || _s[_pos] < '0' || _s[_pos] > '9')
                    {
                        throw new FormatException("Invalid fraction at position " + _pos);
                    }
                    while (_pos < _s.Length && _s[_pos] >= '0' && _s[_pos] <= '9') _pos++;
                }
                if (_pos < _s.Length && (_s[_pos] == 'e' || _s[_pos] == 'E'))
                {
                    _pos++;
                    if (_pos < _s.Length && (_s[_pos] == '+' || _s[_pos] == '-')) _pos++;
                    if (_pos >= _s.Length || _s[_pos] < '0' || _s[_pos] > '9')
                    {
                        throw new FormatException("Invalid exponent at position " + _pos);
                    }
                    while (_pos < _s.Length && _s[_pos] >= '0' && _s[_pos] <= '9') _pos++;
                }
                return new JsonRawNumber(_s.Substring(start, _pos - start));
            }
        }

        public static object Parse(string json)
        {
            if (json == null) throw new FormatException("JSON input is null");
            Parser p = new Parser(json);
            return p.ParseRoot();
        }

        public static string Serialize(object value)
        {
            StringBuilder sb = new StringBuilder(1024);
            WriteValue(value, sb);
            return sb.ToString();
        }

        public static void WriteString(string s, StringBuilder sb)
        {
            sb.Append('"');
            int start = 0;
            int len = s.Length;
            for (int i = 0; i < len; i++)
            {
                char c = s[i];
                if (c == '"' || c == '\\' || c < 0x20 || c == '\u2028' || c == '\u2029')
                {
                    if (i > start) sb.Append(s, start, i - start);
                    switch (c)
                    {
                        case '"': sb.Append("\\\""); break;
                        case '\\': sb.Append("\\\\"); break;
                        case '\b': sb.Append("\\b"); break;
                        case '\f': sb.Append("\\f"); break;
                        case '\n': sb.Append("\\n"); break;
                        case '\r': sb.Append("\\r"); break;
                        case '\t': sb.Append("\\t"); break;
                        case '\u2028': sb.Append("\\u2028"); break;
                        case '\u2029': sb.Append("\\u2029"); break;
                        default:
                            sb.Append("\\u");
                            sb.Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                            break;
                    }
                    start = i + 1;
                }
            }
            if (len > start) sb.Append(s, start, len - start);
            sb.Append('"');
        }

        public static void WriteValue(object value, StringBuilder sb)
        {
            if (value == null)
            {
                sb.Append("null");
                return;
            }
            string str = value as string;
            if (str != null)
            {
                WriteString(str, sb);
                return;
            }
            if (value is bool)
            {
                sb.Append((bool)value ? "true" : "false");
                return;
            }
            JsonRawNumber num = value as JsonRawNumber;
            if (num != null)
            {
                sb.Append(num.Raw);
                return;
            }
            if (value is long)
            {
                sb.Append(((long)value).ToString(CultureInfo.InvariantCulture));
                return;
            }
            if (value is int)
            {
                sb.Append(((int)value).ToString(CultureInfo.InvariantCulture));
                return;
            }
            JsonObject obj = value as JsonObject;
            if (obj != null)
            {
                sb.Append('{');
                for (int i = 0; i < obj.Entries.Count; i++)
                {
                    if (i > 0) sb.Append(',');
                    WriteString(obj.Entries[i].Key, sb);
                    sb.Append(':');
                    WriteValue(obj.Entries[i].Value, sb);
                }
                sb.Append('}');
                return;
            }
            string[] strArr = value as string[];
            if (strArr != null)
            {
                sb.Append('[');
                for (int i = 0; i < strArr.Length; i++)
                {
                    if (i > 0) sb.Append(',');
                    WriteString(strArr[i], sb);
                }
                sb.Append(']');
                return;
            }
            IList<object> list = value as IList<object>;
            if (list != null)
            {
                sb.Append('[');
                for (int i = 0; i < list.Count; i++)
                {
                    if (i > 0) sb.Append(',');
                    WriteValue(list[i], sb);
                }
                sb.Append(']');
                return;
            }
            throw new InvalidOperationException("Unsupported JSON value type: " + value.GetType().FullName);
        }

        public static string MergeLocaleJson(string targetJson, string overrideJson, out int changed)
        {
            JsonObject target = Parse(targetJson) as JsonObject;
            JsonObject over = Parse(overrideJson) as JsonObject;
            if (target == null || over == null)
            {
                throw new FormatException("Locale catalog must be a JSON object");
            }
            changed = 0;
            for (int i = 0; i < over.Entries.Count; i++)
            {
                string key = over.Entries[i].Key;
                string newVal = over.Entries[i].Value as string;
                if (newVal == null) continue;
                object existing;
                if (target.TryGet(key, out existing))
                {
                    string existingStr = existing as string;
                    if (existingStr == null && existing != null)
                    {
                        JsonRawNumber rn = existing as JsonRawNumber;
                        existingStr = rn != null ? rn.Raw : existing.ToString();
                    }
                    if (!string.Equals(existingStr, newVal, StringComparison.Ordinal))
                    {
                        target.Set(key, newVal);
                        changed++;
                    }
                }
                else
                {
                    target.Set(key, newVal);
                    changed++;
                }
            }
            StringBuilder sb = new StringBuilder(targetJson.Length + overrideJson.Length / 2);
            WriteValue(target, sb);
            return sb.ToString();
        }
    }

    public sealed class CompiledFrontendRules
    {
        public readonly string[] Sources;
        public readonly string[] Targets;
        public readonly bool[] IsPlain;
        public readonly int RuleCount;
        public readonly int MaxSourceLength;

        private readonly int[] _rootAscii;
        private readonly Dictionary<char, int> _rootNonAscii;
        private readonly int[] _edgeStart;
        private readonly int[] _edgeCount;
        private readonly char[] _edgeChar;
        private readonly int[] _edgeNext;
        private readonly int[] _fail;
        private readonly int[] _dictLink;
        private readonly int[] _outHead;
        private readonly int[] _outRule;
        private readonly int[] _outNext;

        public CompiledFrontendRules(object[][] rules)
        {
            int n = rules == null ? 0 : rules.Length;
            Sources = new string[n];
            Targets = new string[n];
            IsPlain = new bool[n];
            RuleCount = n;

            List<Dictionary<char, int>> trie = new List<Dictionary<char, int>>();
            List<int> outHead = new List<int>();
            List<int> outRule = new List<int>();
            List<int> outNext = new List<int>();
            trie.Add(new Dictionary<char, int>());
            outHead.Add(-1);

            int maxLen = 0;
            for (int r = 0; r < n; r++)
            {
                object[] row = rules[r];
                object marker = row[0];
                bool plain = false;
                if (marker is bool) plain = (bool)marker;
                else if (marker != null) plain = true;

                string src = (string)row[1];
                string dst = (string)row[2];
                Sources[r] = src;
                Targets[r] = dst;
                IsPlain[r] = plain;
                if (string.IsNullOrEmpty(src)) continue;
                if (src.Length > maxLen) maxLen = src.Length;

                int state = 0;
                for (int i = 0; i < src.Length; i++)
                {
                    char c = src[i];
                    int next;
                    if (!trie[state].TryGetValue(c, out next))
                    {
                        next = trie.Count;
                        trie[state][c] = next;
                        trie.Add(new Dictionary<char, int>());
                        outHead.Add(-1);
                    }
                    state = next;
                }
                outRule.Add(r);
                outNext.Add(outHead[state]);
                outHead[state] = outRule.Count - 1;
            }
            MaxSourceLength = maxLen;

            int stateCount = trie.Count;
            _fail = new int[stateCount];
            _dictLink = new int[stateCount];
            for (int i = 0; i < stateCount; i++) _dictLink[i] = -1;
            _outHead = outHead.ToArray();
            _outRule = outRule.ToArray();
            _outNext = outNext.ToArray();

            Queue<int> queue = new Queue<int>();
            _rootAscii = new int[128];
            _rootNonAscii = new Dictionary<char, int>();
            foreach (KeyValuePair<char, int> kv in trie[0])
            {
                if (kv.Key < 128) _rootAscii[kv.Key] = kv.Value;
                else _rootNonAscii[kv.Key] = kv.Value;
                _fail[kv.Value] = 0;
                _dictLink[kv.Value] = -1;
                queue.Enqueue(kv.Value);
            }

            while (queue.Count > 0)
            {
                int u = queue.Dequeue();
                foreach (KeyValuePair<char, int> kv in trie[u])
                {
                    char c = kv.Key;
                    int v = kv.Value;
                    int f = _fail[u];
                    int next = 0;
                    while (f != 0 && !trie[f].TryGetValue(c, out next))
                    {
                        f = _fail[f];
                    }
                    if (f == 0)
                    {
                        if (!trie[0].TryGetValue(c, out next)) next = 0;
                    }
                    _fail[v] = next;
                    _dictLink[v] = _outHead[next] >= 0 ? next : _dictLink[next];
                    queue.Enqueue(v);
                }
            }

            int totalEdges = 0;
            for (int s = 1; s < stateCount; s++) totalEdges += trie[s].Count;
            _edgeStart = new int[stateCount];
            _edgeCount = new int[stateCount];
            _edgeChar = new char[totalEdges];
            _edgeNext = new int[totalEdges];
            int cursor = 0;
            for (int s = 1; s < stateCount; s++)
            {
                int cnt = trie[s].Count;
                _edgeStart[s] = cursor;
                _edgeCount[s] = cnt;
                if (cnt == 0) continue;
                int start = cursor;
                foreach (KeyValuePair<char, int> kv in trie[s])
                {
                    _edgeChar[cursor] = kv.Key;
                    _edgeNext[cursor] = kv.Value;
                    cursor++;
                }
                if (cnt > 1)
                {
                    Array.Sort(_edgeChar, _edgeNext, start, cnt);
                }
            }
        }

        private int Step(int state, char c)
        {
            while (state != 0)
            {
                int cnt = _edgeCount[state];
                if (cnt == 1)
                {
                    int start = _edgeStart[state];
                    if (_edgeChar[start] == c) return _edgeNext[start];
                }
                else if (cnt > 1)
                {
                    int start = _edgeStart[state];
                    if (cnt <= 8)
                    {
                        int end = start + cnt;
                        for (int i = start; i < end; i++)
                        {
                            if (_edgeChar[i] == c) return _edgeNext[i];
                        }
                    }
                    else
                    {
                        int lo = start;
                        int hi = start + cnt - 1;
                        while (lo <= hi)
                        {
                            int mid = (lo + hi) >> 1;
                            char mc = _edgeChar[mid];
                            if (mc == c) return _edgeNext[mid];
                            if (mc < c) lo = mid + 1;
                            else hi = mid - 1;
                        }
                    }
                }
                state = _fail[state];
            }
            if (c < 128) return _rootAscii[c];
            int rootNext;
            return _rootNonAscii.TryGetValue(c, out rootNext) ? rootNext : 0;
        }

        public void ScanInto(string text, int startIdx, int endIdx, int minRuleExclusive, SortedSet<int> hits)
        {
            if (RuleCount == 0 || startIdx >= endIdx) return;
            int state = 0;
            for (int i = startIdx; i < endIdx; i++)
            {
                state = Step(state, text[i]);
                int o = _outHead[state] >= 0 ? state : _dictLink[state];
                while (o >= 0)
                {
                    for (int idx = _outHead[o]; idx >= 0; idx = _outNext[idx])
                    {
                        int r = _outRule[idx];
                        if (r > minRuleExclusive) hits.Add(r);
                    }
                    o = _dictLink[o];
                }
            }
        }
    }

    public static class FrontendPatcher
    {
        static readonly Regex StructuralContextRe = new Regex(
            "(?<![A-Za-z0-9_$-])(?:as|component|displayName|glyph|[\\w$-]*[Ii]con(?:Name)?|name|role|type)\\s*[:=]\\s*(?:(?:(?:(?:[^?:\\\"'`,;{}]|\\\"[^\\\"]{0,60}\\\"|'[^']{0,60}'|`[^`]{0,60}`){1,120}?)\\?\\??\\s*(?:\\\"[^\\\"]{0,80}\\\"|'[^']{0,80}'|`[^`]{0,80}`)\\s*:\\s*)*)(?:(?:(?:[^?:\\\"'`,;{}]|\\\"[^\\\"]{0,60}\\\"|'[^']{0,60}'|`[^`]{0,60}`){1,120}?)(?:\\?\\??)?\\s*)?(?:=\\s*)?$",
            RegexOptions.Compiled);

        static readonly Regex StructuralAliasContextRe = new Regex(
            "(?<![A-Za-z0-9_$-])[\\w$-]*[Ii]con(?:Name)?\\s*:\\s*(?<alias>[A-Za-z0-9_$]+)\\b.*?(?:=\\s*\\k<alias>\\s*===\\s*void 0\\s*\\?\\s*|=\\s*\\k<alias>\\s*!==\\s*void 0\\s*\\?\\s*\\k<alias>\\s*:\\s*|(?<![A-Za-z0-9_$-])\\k<alias>\\s*\\?\\?\\s*)$",
            RegexOptions.Compiled);

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

        static string ApplyRule(string current, string source, string target, bool isPlain, out int localCount, List<int> changedStarts, List<int> changedEnds)
        {
            int srcLen = source.Length;
            int len = current.Length;
            localCount = 0;
            if (srcLen == 0) return current;

            if (isPlain)
            {
                int searchPos = 1;
                int lastCopy = 0;
                StringBuilder sb = null;
                while (searchPos <= len - srcLen - 1)
                {
                    int idx = current.IndexOf(source, searchPos, StringComparison.Ordinal);
                    if (idx < 0 || idx + srcLen >= len) break;
                    char q = current[idx - 1];
                    if ((q == '"' || q == '\'' || q == '`') && current[idx + srcLen] == q)
                    {
                        int litStart = idx - 1;
                        if (!IsStructuralJsLiteralContext(current, litStart))
                        {
                            if (sb == null) sb = new StringBuilder(len + 64);
                            sb.Append(current, lastCopy, litStart - lastCopy);
                            int repStart = sb.Length;
                            sb.Append(q);
                            sb.Append(target);
                            sb.Append(q);
                            changedStarts.Add(repStart);
                            changedEnds.Add(sb.Length);
                            lastCopy = idx + srcLen + 1;
                            localCount++;
                        }
                        // Regex consumed [idx-1 .. idx+srcLen]; next opening quote cannot be before idx+srcLen+1.
                        searchPos = idx + srcLen + 2;
                    }
                    else
                    {
                        searchPos = idx + 1;
                    }
                }
                if (sb == null) return current;
                sb.Append(current, lastCopy, len - lastCopy);
                return sb.ToString();
            }
            else
            {
                int searchPos = 0;
                int lastCopy = 0;
                StringBuilder sb = null;
                while (searchPos <= len - srcLen)
                {
                    int idx = current.IndexOf(source, searchPos, StringComparison.Ordinal);
                    if (idx < 0) break;
                    if (sb == null) sb = new StringBuilder(len + 64);
                    sb.Append(current, lastCopy, idx - lastCopy);
                    int repStart = sb.Length;
                    sb.Append(target);
                    changedStarts.Add(repStart);
                    changedEnds.Add(sb.Length);
                    lastCopy = idx + srcLen;
                    searchPos = lastCopy;
                    localCount++;
                }
                if (sb == null) return current;
                sb.Append(current, lastCopy, len - lastCopy);
                return sb.ToString();
            }
        }

        public static string PatchText(string text, CompiledFrontendRules compiled, out int count)
        {
            count = 0;
            if (string.IsNullOrEmpty(text) || compiled == null || compiled.RuleCount == 0)
            {
                return text;
            }
            SortedSet<int> worklist = new SortedSet<int>();
            compiled.ScanInto(text, 0, text.Length, -1, worklist);
            if (worklist.Count == 0)
            {
                return text;
            }

            string patched = text;
            List<int> starts = new List<int>(8);
            List<int> ends = new List<int>(8);
            int pad = Math.Max(0, compiled.MaxSourceLength - 1);
            while (worklist.Count > 0)
            {
                int r = worklist.Min;
                worklist.Remove(r);
                starts.Clear();
                ends.Clear();
                int localCount;
                string next = ApplyRule(patched, compiled.Sources[r], compiled.Targets[r], compiled.IsPlain[r], out localCount, starts, ends);
                if (localCount > 0)
                {
                    count += localCount;
                    patched = next;
                    if (pad > 0 && starts.Count > 0 && r + 1 < compiled.RuleCount)
                    {
                        int pLen = patched.Length;
                        int winStart = Math.Max(0, starts[0] - pad);
                        int winEnd = Math.Min(pLen, ends[0] + pad);
                        for (int k = 1; k < starts.Count; k++)
                        {
                            int s = Math.Max(0, starts[k] - pad);
                            int e = Math.Min(pLen, ends[k] + pad);
                            if (s <= winEnd)
                            {
                                if (e > winEnd) winEnd = e;
                            }
                            else
                            {
                                compiled.ScanInto(patched, winStart, winEnd, r, worklist);
                                winStart = s;
                                winEnd = e;
                            }
                        }
                        compiled.ScanInto(patched, winStart, winEnd, r, worklist);
                    }
                }
            }
            return patched;
        }

        // rules 行结构: [Regex 或 bool(plain 规则, 直接替换规则为 null/false), source, target]，顺序与词表一致。
        // 纯计算：不读盘之外不做任何副作用，变更后的内容写入 outputContents[i]，由调用方备份并写盘。
        // 返回每个文件的替换计数（未变更为 0）。
        public static int[] PatchFiles(string[] filePaths, object[][] rules, int maxWorkers, string[] outputContents)
        {
            int total = filePaths.Length;
            int scanned = 0;
            int[] counts = new int[total];
            CompiledFrontendRules compiled = new CompiledFrontendRules(rules);
            Parallel.For(0, total, new ParallelOptions { MaxDegreeOfParallelism = Math.Max(1, maxWorkers) }, delegate(int i)
            {
                string filePath = filePaths[i];
                string text = File.ReadAllText(filePath, Encoding.UTF8);
                int count;
                string patched = PatchText(text, compiled, out count);
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

        public static string[] FindFilesContaining(string[] filePaths, string[] needles, int maxWorkers)
        {
            if (filePaths == null || filePaths.Length == 0 || needles == null || needles.Length == 0)
            {
                return new string[0];
            }
            bool[] matched = new bool[filePaths.Length];
            Parallel.For(0, filePaths.Length, new ParallelOptions { MaxDegreeOfParallelism = Math.Max(1, maxWorkers) }, delegate(int i)
            {
                string text = File.ReadAllText(filePaths[i], Encoding.UTF8);
                for (int n = 0; n < needles.Length; n++)
                {
                    string needle = needles[n];
                    if (!string.IsNullOrEmpty(needle) && text.IndexOf(needle, StringComparison.Ordinal) >= 0)
                    {
                        matched[i] = true;
                        break;
                    }
                }
            });
            List<string> results = new List<string>();
            for (int i = 0; i < filePaths.Length; i++)
            {
                if (matched[i]) results.Add(filePaths[i]);
            }
            return results.ToArray();
        }

        public static string[] FindFilesMatchingRegex(string[] filePaths, string pattern, int maxWorkers)
        {
            if (filePaths == null || filePaths.Length == 0 || string.IsNullOrEmpty(pattern))
            {
                return new string[0];
            }
            Regex re = new Regex(pattern, RegexOptions.Compiled);
            bool[] matched = new bool[filePaths.Length];
            Parallel.For(0, filePaths.Length, new ParallelOptions { MaxDegreeOfParallelism = Math.Max(1, maxWorkers) }, delegate(int i)
            {
                string text = File.ReadAllText(filePaths[i], Encoding.UTF8);
                if (re.IsMatch(text))
                {
                    matched[i] = true;
                }
            });
            List<string> results = new List<string>();
            for (int i = 0; i < filePaths.Length; i++)
            {
                if (matched[i]) results.Add(filePaths[i]);
            }
            return results.ToArray();
        }
    }

    public sealed class FrontendAsarScanResult
    {
        public string AssetsDir;
        public int TotalJsFiles;
        public string[] WhitelistMatchedNames;
        public string[] WhitelistChangedNames;
        public string[] WhitelistAlreadyNames;
        public int HardcodedPatchedFiles;
        public int HardcodedTotalReplacements;
        public string[] HardcodedLogEntries;
        public string[] SlashCandidatePaths;
        public string[] SlashCandidateTexts;
        public string[] DisplayNameTargetPaths;
        public string[] DisplayNameAlreadyPaths;
        public Dictionary<string, string> ModifiedTexts;
        public bool HasEnUsJson;
        public string EnUsJsonText;
        public bool HasDynamicEnUs;
        public byte[] DynamicEnUsBytes;
    }

    public static class AsarHelper
    {
        private static readonly UTF8Encoding Utf8NoBom = new UTF8Encoding(false);
        private static readonly Regex FrontendIndexRe = new Regex("(^|/)assets/(?:[^/]+/)?index-[^/]+\\.js$", RegexOptions.Compiled);

        private static int Align4(int value)
        {
            return value + ((4 - (value % 4)) % 4);
        }

        private static string BytesToLowerHex(byte[] hash)
        {
            char[] c = new char[hash.Length * 2];
            const string hex = "0123456789abcdef";
            for (int i = 0; i < hash.Length; i++)
            {
                int b = hash[i];
                c[i * 2] = hex[b >> 4];
                c[i * 2 + 1] = hex[b & 0xF];
            }
            return new string(c);
        }

        private static byte[] ReadHeaderJsonBytes(string asarPath, out int headerSize, out long dataStart)
        {
            using (FileStream fs = File.Open(asarPath, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                if (fs.Length < 16) throw new InvalidDataException("Unsupported app.asar header in " + asarPath);
                byte[] prefix = new byte[8];
                if (fs.Read(prefix, 0, 8) != 8) throw new InvalidDataException("Unsupported app.asar header in " + asarPath);
                uint sizePicklePayload = BitConverter.ToUInt32(prefix, 0);
                uint rawHeaderSize = BitConverter.ToUInt32(prefix, 4);
                if (sizePicklePayload != 4 || rawHeaderSize == 0 || fs.Length < 8L + rawHeaderSize)
                {
                    throw new InvalidDataException("Unsupported app.asar size pickle in " + asarPath);
                }
                headerSize = (int)rawHeaderSize;
                dataStart = 8L + headerSize;
                byte[] pickle = new byte[headerSize];
                int read = 0;
                while (read < headerSize)
                {
                    int n = fs.Read(pickle, read, headerSize - read);
                    if (n <= 0) throw new InvalidDataException("Unsupported app.asar header in " + asarPath);
                    read += n;
                }
                uint headerPayloadSize = BitConverter.ToUInt32(pickle, 0);
                int headerStringSize = BitConverter.ToInt32(pickle, 4);
                int expectedPayloadSize = Align4(4 + headerStringSize);
                if (headerStringSize < 0 || headerPayloadSize != (uint)expectedPayloadSize || headerSize != 4 + (int)headerPayloadSize)
                {
                    throw new InvalidDataException("Unsupported app.asar header pickle in " + asarPath);
                }
                byte[] jsonBytes = new byte[headerStringSize];
                Buffer.BlockCopy(pickle, 8, jsonBytes, 0, headerStringSize);
                return jsonBytes;
            }
        }

        public static string GetHeaderHash(string asarPath)
        {
            int headerSize;
            long dataStart;
            byte[] jsonBytes = ReadHeaderJsonBytes(asarPath, out headerSize, out dataStart);
            using (SHA256 sha = SHA256.Create())
            {
                return BytesToLowerHex(sha.ComputeHash(jsonBytes));
            }
        }

        public static string MergeLocaleJson(string targetJson, string overrideJson, out int changed)
        {
            return MiniJson.MergeLocaleJson(targetJson, overrideJson, out changed);
        }

        private static bool GetBoolProp(JsonObject obj, string key)
        {
            object val;
            return obj.TryGet(key, out val) && val is bool && (bool)val;
        }

        private static long GetInt64Prop(JsonObject obj, string key)
        {
            object val;
            if (!obj.TryGet(key, out val) || val == null) return 0;
            JsonRawNumber rn = val as JsonRawNumber;
            if (rn != null) return rn.AsInt64();
            string s = val as string;
            if (s != null) return long.Parse(s, CultureInfo.InvariantCulture);
            if (val is long) return (long)val;
            if (val is int) return (int)val;
            return Convert.ToInt64(val, CultureInfo.InvariantCulture);
        }

        private static void CollectEntryPaths(JsonObject node, string prefix, List<string> paths)
        {
            object filesVal;
            if (!node.TryGet("files", out filesVal)) return;
            JsonObject files = filesVal as JsonObject;
            if (files == null) return;
            for (int i = 0; i < files.Entries.Count; i++)
            {
                string name = files.Entries[i].Key;
                string rel = prefix.Length == 0 ? name : prefix + "/" + name;
                JsonObject child = files.Entries[i].Value as JsonObject;
                if (child != null && child.ContainsKey("files"))
                {
                    CollectEntryPaths(child, rel, paths);
                }
                else
                {
                    paths.Add(rel);
                }
            }
        }

        public static bool TestFrontendArchive(string asarPath)
        {
            if (!File.Exists(asarPath)) return false;
            try
            {
                int headerSize;
                long dataStart;
                byte[] jsonBytes = ReadHeaderJsonBytes(asarPath, out headerSize, out dataStart);
                JsonObject header = MiniJson.Parse(Encoding.UTF8.GetString(jsonBytes)) as JsonObject;
                if (header == null) return false;
                List<string> paths = new List<string>(256);
                CollectEntryPaths(header, "", paths);
                bool hasI18n = false;
                bool hasBundle = false;
                for (int i = 0; i < paths.Count; i++)
                {
                    string p = paths[i];
                    if (!hasI18n && string.Equals(p, "i18n/en-US.json", StringComparison.OrdinalIgnoreCase))
                    {
                        hasI18n = true;
                    }
                    if (!hasBundle && FrontendIndexRe.IsMatch(p))
                    {
                        hasBundle = true;
                    }
                    if (hasI18n && hasBundle) return true;
                }
                return false;
            }
            catch
            {
                return false;
            }
        }

        private sealed class ExpandItem
        {
            public string TargetPath;
            public string RelativePath;
            public bool Unpacked;
            public long Offset;
            public long Size;
        }

        private static void CollectExpandItems(JsonObject node, string prefix, string destRoot, string destRootWithSep, List<string> dirs, List<ExpandItem> items, long dataStart, long archiveLength)
        {
            object filesVal;
            if (!node.TryGet("files", out filesVal)) return;
            JsonObject files = filesVal as JsonObject;
            if (files == null) return;
            for (int i = 0; i < files.Entries.Count; i++)
            {
                string name = files.Entries[i].Key;
                if (string.IsNullOrEmpty(name) || name == "." || name == ".." || name.IndexOf('/') >= 0 || name.IndexOf('\\') >= 0)
                {
                    throw new InvalidDataException("ASAR 包含不安全路径: " + name);
                }
                string rel = prefix.Length == 0 ? name : prefix + Path.DirectorySeparatorChar + name;
                string target = Path.GetFullPath(Path.Combine(destRoot, rel));
                if (!target.StartsWith(destRootWithSep, StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidDataException("ASAR 路径越界: " + rel);
                }
                JsonObject child = files.Entries[i].Value as JsonObject;
                if (child == null) continue;
                if (child.ContainsKey("files"))
                {
                    dirs.Add(target);
                    CollectExpandItems(child, rel, destRoot, destRootWithSep, dirs, items, dataStart, archiveLength);
                    continue;
                }
                if (child.ContainsKey("link"))
                {
                    throw new InvalidDataException("暂不支持包含软链接的 ASAR: " + rel);
                }
                if (GetBoolProp(child, "unpacked"))
                {
                    ExpandItem ui = new ExpandItem();
                    ui.TargetPath = target;
                    ui.RelativePath = rel;
                    ui.Unpacked = true;
                    items.Add(ui);
                    continue;
                }
                long offset = GetInt64Prop(child, "offset");
                long size = GetInt64Prop(child, "size");
                if (offset < 0 || size < 0 || dataStart + offset + size > archiveLength)
                {
                    throw new InvalidDataException("ASAR 文件边界无效: " + rel + " (offset=" + offset + ", size=" + size + ", dataStart=" + dataStart + ", archive=" + archiveLength + ")");
                }
                ExpandItem item = new ExpandItem();
                item.TargetPath = target;
                item.RelativePath = rel;
                item.Unpacked = false;
                item.Offset = offset;
                item.Size = size;
                items.Add(item);
            }
        }

        public static void ExpandArchive(string asarPath, string destinationPath, int maxWorkers)
        {
            if (!File.Exists(asarPath)) throw new FileNotFoundException("缺少必要文件: " + asarPath);
            if (Directory.Exists(destinationPath) || File.Exists(destinationPath))
            {
                throw new IOException("ASAR 解包目标已存在: " + destinationPath);
            }

            int headerSize;
            long dataStart;
            byte[] jsonBytes = ReadHeaderJsonBytes(asarPath, out headerSize, out dataStart);
            JsonObject header = MiniJson.Parse(Encoding.UTF8.GetString(jsonBytes)) as JsonObject;
            long archiveLength = new FileInfo(asarPath).Length;

            Directory.CreateDirectory(destinationPath);
            string destRoot = Path.GetFullPath(destinationPath).TrimEnd('\\', '/');
            string destRootWithSep = destRoot + Path.DirectorySeparatorChar;
            List<string> dirs = new List<string>(64);
            List<ExpandItem> items = new List<ExpandItem>(256);
            CollectExpandItems(header, "", destRoot, destRootWithSep, dirs, items, dataStart, archiveLength);

            for (int i = 0; i < dirs.Count; i++)
            {
                Directory.CreateDirectory(dirs[i]);
            }

            string unpackedBase = asarPath + ".unpacked";
            int workers = items.Count < 32 ? 1 : Math.Max(1, Math.Min(maxWorkers, 8));
            if (workers == 1)
            {
                byte[] buffer = new byte[256 * 1024];
                using (FileStream asarStream = File.Open(asarPath, FileMode.Open, FileAccess.Read, FileShare.Read))
                {
                    for (int i = 0; i < items.Count; i++)
                    {
                        WriteExpandedItem(items[i], asarStream, dataStart, unpackedBase, buffer);
                    }
                }
            }
            else
            {
                int nextIdx = -1;
                Exception firstErr = null;
                Parallel.For(0, workers, new ParallelOptions { MaxDegreeOfParallelism = workers }, delegate(int w)
                {
                    byte[] buffer = new byte[256 * 1024];
                    using (FileStream asarStream = File.Open(asarPath, FileMode.Open, FileAccess.Read, FileShare.Read))
                    {
                        while (true)
                        {
                            if (Volatile.Read(ref firstErr) != null) return;
                            int idx = Interlocked.Increment(ref nextIdx);
                            if (idx >= items.Count) return;
                            try
                            {
                                WriteExpandedItem(items[idx], asarStream, dataStart, unpackedBase, buffer);
                            }
                            catch (Exception ex)
                            {
                                Interlocked.CompareExchange(ref firstErr, ex, null);
                                return;
                            }
                        }
                    }
                });
                if (firstErr != null) throw new IOException(firstErr.Message, firstErr);
            }
        }

        private static void WriteExpandedItem(ExpandItem item, FileStream asarStream, long dataStart, string unpackedBase, byte[] buffer)
        {
            if (item.Unpacked)
            {
                string src = Path.Combine(unpackedBase, item.RelativePath);
                if (!File.Exists(src)) throw new FileNotFoundException("缺少必要文件: " + src);
                File.Copy(src, item.TargetPath, true);
                return;
            }
            using (FileStream output = File.Open(item.TargetPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                if (item.Size == 0) return;
                asarStream.Position = dataStart + item.Offset;
                long remaining = item.Size;
                while (remaining > 0)
                {
                    int wanted = (int)Math.Min(buffer.Length, remaining);
                    int read = asarStream.Read(buffer, 0, wanted);
                    if (read <= 0) throw new IOException("ASAR 文件内容不完整: " + item.RelativePath);
                    output.Write(buffer, 0, read);
                    remaining -= read;
                }
            }
        }

        private sealed class IntegrityResult
        {
            public string Hash;
            public int BlockSize;
            public string[] Blocks;
        }

        private static IntegrityResult ComputeFileIntegrity(string path, int blockSize, byte[] buffer, SHA256 wholeSha, SHA256 blockSha)
        {
            wholeSha.Initialize();
            List<string> blocks = new List<string>(2);
            using (FileStream fs = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                while (true)
                {
                    int filled = 0;
                    while (filled < blockSize)
                    {
                        int n = fs.Read(buffer, filled, blockSize - filled);
                        if (n <= 0) break;
                        filled += n;
                    }
                    if (filled <= 0) break;
                    wholeSha.TransformBlock(buffer, 0, filled, null, 0);
                    blockSha.Initialize();
                    byte[] bh = blockSha.ComputeHash(buffer, 0, filled);
                    blocks.Add(BytesToLowerHex(bh));
                    if (filled < blockSize) break;
                }
            }
            wholeSha.TransformFinalBlock(new byte[0], 0, 0);
            string hash = BytesToLowerHex(wholeSha.Hash);
            if (blocks.Count == 0) blocks.Add(hash);
            IntegrityResult res = new IntegrityResult();
            res.Hash = hash;
            res.BlockSize = blockSize;
            res.Blocks = blocks.ToArray();
            return res;
        }

        private static IntegrityResult ComputeBytesIntegrity(byte[] data, int blockSize, SHA256 wholeSha, SHA256 blockSha)
        {
            wholeSha.Initialize();
            List<string> blocks = new List<string>(2);
            int offset = 0;
            while (offset < data.Length)
            {
                int len = Math.Min(blockSize, data.Length - offset);
                wholeSha.TransformBlock(data, offset, len, null, 0);
                blockSha.Initialize();
                byte[] bh = blockSha.ComputeHash(data, offset, len);
                blocks.Add(BytesToLowerHex(bh));
                offset += len;
            }
            wholeSha.TransformFinalBlock(new byte[0], 0, 0);
            string hash = BytesToLowerHex(wholeSha.Hash);
            if (blocks.Count == 0) blocks.Add(hash);
            IntegrityResult res = new IntegrityResult();
            res.Hash = hash;
            res.BlockSize = blockSize;
            res.Blocks = blocks.ToArray();
            return res;
        }

        private static JsonObject IntegrityToJson(IntegrityResult r)
        {
            JsonObject obj = new JsonObject();
            obj.Set("algorithm", "SHA256");
            obj.Set("hash", r.Hash);
            obj.Set("blockSize", (long)r.BlockSize);
            obj.Set("blocks", r.Blocks);
            return obj;
        }

        private sealed class PackNode
        {
            public string Name;
            public bool IsDir;
            public string FullPath;
            public long Size;
            public long Offset;
            public int FileIndex;
            public List<PackNode> Children;
        }

        private static PackNode ScanDirectoryTree(string directory, List<PackNode> flatFiles, ref long offset)
        {
            PackNode dirNode = new PackNode();
            dirNode.IsDir = true;
            dirNode.Children = new List<PackNode>();
            DirectoryInfo di = new DirectoryInfo(directory);
            FileSystemInfo[] entries = di.GetFileSystemInfos();
            Array.Sort(entries, delegate(FileSystemInfo a, FileSystemInfo b)
            {
                return string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase);
            });
            for (int i = 0; i < entries.Length; i++)
            {
                FileSystemInfo fsi = entries[i];
                if ((fsi.Attributes & FileAttributes.Directory) == FileAttributes.Directory)
                {
                    PackNode sub = ScanDirectoryTree(fsi.FullName, flatFiles, ref offset);
                    sub.Name = fsi.Name;
                    dirNode.Children.Add(sub);
                }
                else
                {
                    if ((fsi.Attributes & FileAttributes.ReparsePoint) == FileAttributes.ReparsePoint)
                    {
                        throw new IOException("ASAR 源目录包含不支持的软链接: " + fsi.FullName);
                    }
                    FileInfo fi = (FileInfo)fsi;
                    PackNode fileNode = new PackNode();
                    fileNode.Name = fi.Name;
                    fileNode.IsDir = false;
                    fileNode.FullPath = fi.FullName;
                    fileNode.Size = fi.Length;
                    fileNode.Offset = offset;
                    fileNode.FileIndex = flatFiles.Count;
                    offset += fileNode.Size;
                    flatFiles.Add(fileNode);
                    dirNode.Children.Add(fileNode);
                }
            }
            return dirNode;
        }

        private static void AppendPackNodeJson(PackNode dir, IntegrityResult[] hashes, StringBuilder sb)
        {
            sb.Append("{\"files\":{");
            for (int i = 0; i < dir.Children.Count; i++)
            {
                if (i > 0) sb.Append(',');
                PackNode child = dir.Children[i];
                MiniJson.WriteString(child.Name, sb);
                sb.Append(':');
                if (child.IsDir)
                {
                    AppendPackNodeJson(child, hashes, sb);
                }
                else
                {
                    IntegrityResult h = hashes[child.FileIndex];
                    sb.Append("{\"size\":");
                    sb.Append(child.Size.ToString(CultureInfo.InvariantCulture));
                    sb.Append(",\"offset\":\"");
                    sb.Append(child.Offset.ToString(CultureInfo.InvariantCulture));
                    sb.Append("\",\"integrity\":{\"algorithm\":\"SHA256\",\"hash\":\"");
                    sb.Append(h.Hash);
                    sb.Append("\",\"blockSize\":");
                    sb.Append(h.BlockSize.ToString(CultureInfo.InvariantCulture));
                    sb.Append(",\"blocks\":[");
                    for (int b = 0; b < h.Blocks.Length; b++)
                    {
                        if (b > 0) sb.Append(',');
                        sb.Append('"');
                        sb.Append(h.Blocks[b]);
                        sb.Append('"');
                    }
                    sb.Append("]}}");
                }
            }
            sb.Append("}}");
        }

        private static void WriteAsarPrefixAndHeader(FileStream output, byte[] headerStringBytes)
        {
            int headerPayloadSize = Align4(4 + headerStringBytes.Length);
            int headerSize = 4 + headerPayloadSize;
            byte[] headerPickle = new byte[headerSize];
            Buffer.BlockCopy(BitConverter.GetBytes((uint)headerPayloadSize), 0, headerPickle, 0, 4);
            Buffer.BlockCopy(BitConverter.GetBytes(headerStringBytes.Length), 0, headerPickle, 4, 4);
            Buffer.BlockCopy(headerStringBytes, 0, headerPickle, 8, headerStringBytes.Length);

            byte[] prefix = new byte[8];
            Buffer.BlockCopy(BitConverter.GetBytes((uint)4), 0, prefix, 0, 4);
            Buffer.BlockCopy(BitConverter.GetBytes((uint)headerSize), 0, prefix, 4, 4);

            output.Write(prefix, 0, 8);
            output.Write(headerPickle, 0, headerPickle.Length);
        }

        public static void CreateArchiveToPath(string sourceDirectory, string destinationPath, int blockSize, int maxWorkers)
        {
            if (!Directory.Exists(sourceDirectory)) throw new DirectoryNotFoundException("ASAR 源目录不存在: " + sourceDirectory);
            List<PackNode> flatFiles = new List<PackNode>(256);
            long offset = 0;
            PackNode root = ScanDirectoryTree(Path.GetFullPath(sourceDirectory), flatFiles, ref offset);

            IntegrityResult[] hashes = new IntegrityResult[flatFiles.Count];
            int workers = flatFiles.Count < 16 ? 1 : Math.Max(1, Math.Min(maxWorkers, 12));
            if (workers == 1)
            {
                byte[] buffer = new byte[blockSize];
                using (SHA256 wholeSha = SHA256.Create())
                using (SHA256 blockSha = SHA256.Create())
                {
                    for (int i = 0; i < flatFiles.Count; i++)
                    {
                        hashes[i] = ComputeFileIntegrity(flatFiles[i].FullPath, blockSize, buffer, wholeSha, blockSha);
                    }
                }
            }
            else
            {
                int nextIdx = -1;
                Exception firstErr = null;
                Parallel.For(0, workers, new ParallelOptions { MaxDegreeOfParallelism = workers }, delegate(int w)
                {
                    byte[] buffer = new byte[blockSize];
                    using (SHA256 wholeSha = SHA256.Create())
                    using (SHA256 blockSha = SHA256.Create())
                    {
                        while (true)
                        {
                            if (Volatile.Read(ref firstErr) != null) return;
                            int idx = Interlocked.Increment(ref nextIdx);
                            if (idx >= flatFiles.Count) return;
                            try
                            {
                                hashes[idx] = ComputeFileIntegrity(flatFiles[idx].FullPath, blockSize, buffer, wholeSha, blockSha);
                            }
                            catch (Exception ex)
                            {
                                Interlocked.CompareExchange(ref firstErr, ex, null);
                                return;
                            }
                        }
                    }
                });
                if (firstErr != null) throw new IOException(firstErr.Message, firstErr);
            }

            StringBuilder headerJson = new StringBuilder(flatFiles.Count * 220 + 64);
            AppendPackNodeJson(root, hashes, headerJson);
            byte[] headerStringBytes = Utf8NoBom.GetBytes(headerJson.ToString());

            string destFull = Path.GetFullPath(destinationPath);
            string parent = Path.GetDirectoryName(destFull);
            if (!string.IsNullOrEmpty(parent)) Directory.CreateDirectory(parent);

            byte[] copyBuf = new byte[1024 * 1024];
            using (FileStream output = File.Open(destFull, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                WriteAsarPrefixAndHeader(output, headerStringBytes);
                for (int i = 0; i < flatFiles.Count; i++)
                {
                    using (FileStream input = File.Open(flatFiles[i].FullPath, FileMode.Open, FileAccess.Read, FileShare.Read))
                    {
                        int n;
                        while ((n = input.Read(copyBuf, 0, copyBuf.Length)) > 0)
                        {
                            output.Write(copyBuf, 0, n);
                        }
                    }
                }
            }
        }

        private static JsonObject FindNode(JsonObject root, string entryPath)
        {
            JsonObject cur = root;
            string[] segments = entryPath.Split('/');
            for (int i = 0; i < segments.Length; i++)
            {
                object filesVal;
                if (!cur.TryGet("files", out filesVal)) return null;
                JsonObject files = filesVal as JsonObject;
                if (files == null) return null;
                object childVal;
                if (!files.TryGet(segments[i], out childVal)) return null;
                cur = childVal as JsonObject;
                if (cur == null) return null;
            }
            return cur;
        }

        public static int UpdateAsarEntries(string asarPath, string tempPath, string[] setPaths, byte[][] setContents, string[] addPaths, byte[][] addContents, int blockSize)
        {
            int headerSize;
            long oldDataStart;
            byte[] headerBytes = ReadHeaderJsonBytes(asarPath, out headerSize, out oldDataStart);
            JsonObject header = MiniJson.Parse(Encoding.UTF8.GetString(headerBytes)) as JsonObject;
            long archiveLength = new FileInfo(asarPath).Length;
            long oldPayloadLength = archiveLength - oldDataStart;
            if (oldPayloadLength < 0) throw new InvalidDataException("app.asar 长度异常: " + asarPath);

            long nextOffset = oldPayloadLength;
            List<byte[]> appends = new List<byte[]>();
            int applied = 0;

            using (SHA256 wholeSha = SHA256.Create())
            using (SHA256 blockSha = SHA256.Create())
            {
                if (setPaths != null)
                {
                    for (int i = 0; i < setPaths.Length; i++)
                    {
                        string entryPath = setPaths[i];
                        byte[] content = setContents[i];
                        JsonObject node = FindNode(header, entryPath);
                        if (node == null) throw new InvalidDataException("app.asar 缺少条目: " + entryPath);
                        if (node.ContainsKey("link")) throw new InvalidDataException("app.asar 条目是软链接，拒绝改写: " + entryPath);
                        if (GetBoolProp(node, "unpacked")) throw new InvalidDataException("app.asar 条目是 unpacked，拒绝改写: " + entryPath);

                        node.Set("offset", nextOffset.ToString(CultureInfo.InvariantCulture));
                        node.Set("size", (long)content.Length);
                        if (node.ContainsKey("integrity"))
                        {
                            node.Set("integrity", IntegrityToJson(ComputeBytesIntegrity(content, blockSize, wholeSha, blockSha)));
                        }
                        appends.Add(content);
                        nextOffset += content.Length;
                        applied++;
                    }
                }

                if (addPaths != null)
                {
                    for (int i = 0; i < addPaths.Length; i++)
                    {
                        string entryPath = addPaths[i];
                        byte[] content = addContents[i];
                        int lastSlash = entryPath.LastIndexOf('/');
                        if (lastSlash <= 0) throw new InvalidDataException("app.asar 条目路径无效: " + entryPath);
                        string parentPath = entryPath.Substring(0, lastSlash);
                        string name = entryPath.Substring(lastSlash + 1);
                        JsonObject parentNode = FindNode(header, parentPath);
                        object filesVal;
                        if (parentNode == null || !parentNode.TryGet("files", out filesVal)) continue;
                        JsonObject files = filesVal as JsonObject;
                        if (files == null || files.ContainsKey(name)) continue;

                        JsonObject newNode = new JsonObject();
                        newNode.Set("size", (long)content.Length);
                        newNode.Set("offset", nextOffset.ToString(CultureInfo.InvariantCulture));
                        newNode.Set("integrity", IntegrityToJson(ComputeBytesIntegrity(content, blockSize, wholeSha, blockSha)));
                        files.Set(name, newNode);
                        appends.Add(content);
                        nextOffset += content.Length;
                        applied++;
                    }
                }
            }

            if (applied == 0) return 0;

            StringBuilder sb = new StringBuilder(headerBytes.Length + 1024);
            MiniJson.WriteValue(header, sb);
            byte[] newHeaderBytes = Utf8NoBom.GetBytes(sb.ToString());

            using (FileStream src = File.Open(asarPath, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (FileStream dst = File.Open(tempPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                WriteAsarPrefixAndHeader(dst, newHeaderBytes);
                src.Position = oldDataStart;
                byte[] copyBuf = new byte[1024 * 1024];
                int n;
                while ((n = src.Read(copyBuf, 0, copyBuf.Length)) > 0)
                {
                    dst.Write(copyBuf, 0, n);
                }
                for (int i = 0; i < appends.Count; i++)
                {
                    if (appends[i].Length > 0) dst.Write(appends[i], 0, appends[i].Length);
                }
            }

            List<string> expectedPaths = new List<string>(256);
            CollectEntryPaths(header, "", expectedPaths);
            int verifyHeaderSize;
            long verifyDataStart;
            byte[] verifyBytes = ReadHeaderJsonBytes(tempPath, out verifyHeaderSize, out verifyDataStart);
            JsonObject verifyHeader = MiniJson.Parse(Encoding.UTF8.GetString(verifyBytes)) as JsonObject;
            List<string> actualPaths = new List<string>(256);
            CollectEntryPaths(verifyHeader, "", actualPaths);
            if (actualPaths.Count != expectedPaths.Count)
            {
                throw new InvalidDataException("app.asar 头部改写后条目数不一致: " + expectedPaths.Count + " -> " + actualPaths.Count);
            }
            return applied;
        }

        private static string DecodeUtf8StripBom(byte[] bytes)
        {
            if (bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF)
            {
                return Encoding.UTF8.GetString(bytes, 3, bytes.Length - 3);
            }
            return Encoding.UTF8.GetString(bytes);
        }

        private static byte[] ReadEntryExact(FileStream fs, long dataStart, long offset, long size)
        {
            if (size <= 0) return new byte[0];
            byte[] buf = new byte[size];
            fs.Position = dataStart + offset;
            int read = 0;
            while (read < buf.Length)
            {
                int n = fs.Read(buf, read, buf.Length - read);
                if (n <= 0) throw new IOException("ASAR 条目读取不完整");
                read += n;
            }
            return buf;
        }

        private sealed class JsEntryInfo
        {
            public string EntryPath;
            public string FileName;
            public long Offset;
            public long Size;
        }

        private static void CollectDirsWithJs(JsonObject node, string prefix, int depth, List<string> dirs, Dictionary<string, bool> hasIndex)
        {
            if (depth > 3) return;
            object filesVal;
            if (!node.TryGet("files", out filesVal)) return;
            JsonObject files = filesVal as JsonObject;
            if (files == null) return;
            bool anyJs = false;
            bool idxJs = false;
            for (int i = 0; i < files.Entries.Count; i++)
            {
                string name = files.Entries[i].Key;
                JsonObject child = files.Entries[i].Value as JsonObject;
                if (child == null) continue;
                if (child.ContainsKey("files"))
                {
                    string sub = prefix.Length == 0 ? name : prefix + "/" + name;
                    CollectDirsWithJs(child, sub, depth + 1, dirs, hasIndex);
                }
                else if (name.EndsWith(".js", StringComparison.OrdinalIgnoreCase))
                {
                    anyJs = true;
                    if (name.StartsWith("index-", StringComparison.OrdinalIgnoreCase)) idxJs = true;
                }
            }
            if (anyJs && prefix.Length > 0)
            {
                dirs.Add(prefix);
                hasIndex[prefix] = idxJs;
            }
        }

        private static List<JsEntryInfo> GetJsEntriesInDir(JsonObject header, string dirPath)
        {
            List<JsEntryInfo> list = new List<JsEntryInfo>();
            JsonObject dirNode = FindNode(header, dirPath);
            if (dirNode == null) return list;
            object filesVal;
            if (!dirNode.TryGet("files", out filesVal)) return list;
            JsonObject files = filesVal as JsonObject;
            if (files == null) return list;
            for (int i = 0; i < files.Entries.Count; i++)
            {
                string name = files.Entries[i].Key;
                JsonObject child = files.Entries[i].Value as JsonObject;
                if (child == null || child.ContainsKey("files")) continue;
                if (!name.EndsWith(".js", StringComparison.OrdinalIgnoreCase)) continue;
                JsEntryInfo info = new JsEntryInfo();
                info.EntryPath = dirPath + "/" + name;
                info.FileName = name;
                info.Offset = GetInt64Prop(child, "offset");
                info.Size = GetInt64Prop(child, "size");
                list.Add(info);
            }
            list.Sort(delegate(JsEntryInfo a, JsEntryInfo b)
            {
                return string.Compare(a.FileName, b.FileName, StringComparison.OrdinalIgnoreCase);
            });
            return list;
        }

        public static FrontendAsarScanResult ScanFrontendAsar(
            string asarPath,
            string language,
            string baseLanguageList,
            string languageListPattern,
            object[][] hardcodedRules,
            string slashModulePattern,
            string displayNamesMarker,
            int maxWorkers)
        {
            int headerSize;
            long dataStart;
            byte[] headerBytes = ReadHeaderJsonBytes(asarPath, out headerSize, out dataStart);
            JsonObject header = MiniJson.Parse(Encoding.UTF8.GetString(headerBytes)) as JsonObject;
            if (header == null) throw new InvalidDataException("无效的 ion-dist.asar 头部");

            const string whitelistAnchor = "\"en-US\",\"de-DE\",\"fr-FR\",\"ko-KR\",\"ja-JP\"";
            string assetsDir = null;
            List<JsEntryInfo> jsEntries = GetJsEntriesInDir(header, "assets/v1");
            if (jsEntries.Count > 0)
            {
                assetsDir = "assets/v1";
            }
            else
            {
                List<string> candidateDirs = new List<string>();
                Dictionary<string, bool> hasIndex = new Dictionary<string, bool>(StringComparer.Ordinal);
                CollectDirsWithJs(header, "", 0, candidateDirs, hasIndex);
                candidateDirs.Sort(delegate(string a, string b)
                {
                    bool ai = hasIndex[a];
                    bool bi = hasIndex[b];
                    if (ai != bi) return bi ? 1 : -1;
                    return string.Compare(a, b, StringComparison.OrdinalIgnoreCase);
                });
                using (FileStream probeFs = File.Open(asarPath, FileMode.Open, FileAccess.Read, FileShare.Read))
                {
                    for (int d = 0; d < candidateDirs.Count; d++)
                    {
                        List<JsEntryInfo> entries = GetJsEntriesInDir(header, candidateDirs[d]);
                        bool found = false;
                        for (int e = 0; e < entries.Count; e++)
                        {
                            string t = DecodeUtf8StripBom(ReadEntryExact(probeFs, dataStart, entries[e].Offset, entries[e].Size));
                            if (t.IndexOf(whitelistAnchor, StringComparison.Ordinal) >= 0)
                            {
                                found = true;
                                break;
                            }
                        }
                        if (found)
                        {
                            assetsDir = candidateDirs[d];
                            jsEntries = entries;
                            break;
                        }
                    }
                }
                if (assetsDir == null)
                {
                    for (int d = 0; d < candidateDirs.Count; d++)
                    {
                        if (hasIndex[candidateDirs[d]])
                        {
                            assetsDir = candidateDirs[d];
                            jsEntries = GetJsEntriesInDir(header, assetsDir);
                            break;
                        }
                    }
                }
            }

            FrontendAsarScanResult res = new FrontendAsarScanResult();
            res.AssetsDir = assetsDir;
            res.TotalJsFiles = jsEntries.Count;
            res.ModifiedTexts = new Dictionary<string, string>(StringComparer.Ordinal);

            using (FileStream i18nFs = File.Open(asarPath, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                JsonObject enUsNode = FindNode(header, "i18n/en-US.json");
                if (enUsNode != null && !enUsNode.ContainsKey("files"))
                {
                    res.HasEnUsJson = true;
                    res.EnUsJsonText = DecodeUtf8StripBom(ReadEntryExact(i18nFs, dataStart, GetInt64Prop(enUsNode, "offset"), GetInt64Prop(enUsNode, "size")));
                }
                JsonObject dynNode = FindNode(header, "i18n/dynamic/en-US.json");
                if (dynNode != null && !dynNode.ContainsKey("files"))
                {
                    res.HasDynamicEnUs = true;
                    res.DynamicEnUsBytes = ReadEntryExact(i18nFs, dataStart, GetInt64Prop(dynNode, "offset"), GetInt64Prop(dynNode, "size"));
                }
            }

            if (assetsDir == null || jsEntries.Count == 0)
            {
                res.WhitelistMatchedNames = new string[0];
                res.WhitelistChangedNames = new string[0];
                res.WhitelistAlreadyNames = new string[0];
                res.HardcodedLogEntries = new string[0];
                res.SlashCandidatePaths = new string[0];
                res.SlashCandidateTexts = new string[0];
                res.DisplayNameTargetPaths = new string[0];
                res.DisplayNameAlreadyPaths = new string[0];
                return res;
            }

            CompiledFrontendRules compiled = new CompiledFrontendRules(hardcodedRules);
            Regex langListRe = new Regex(languageListPattern, RegexOptions.Compiled);
            string langReplacement = baseLanguageList + ",\"" + language + "\"]";
            Regex slashRe = string.IsNullOrEmpty(slashModulePattern) ? null : new Regex(slashModulePattern, RegexOptions.Compiled);

            int total = jsEntries.Count;
            bool[] wlMatched = new bool[total];
            bool[] wlChanged = new bool[total];
            bool[] wlAlready = new bool[total];
            int[] hcCounts = new int[total];
            bool[] slashMatched = new bool[total];
            bool[] dnTarget = new bool[total];
            bool[] dnAlready = new bool[total];
            string[] modifiedOut = new string[total];
            string[] slashTextOut = new string[total];

            int workers = total < 16 ? 1 : Math.Max(1, Math.Min(maxWorkers, 12));
            int nextIdx = -1;
            int scanned = 0;
            Exception firstErr = null;
            Parallel.For(0, workers, new ParallelOptions { MaxDegreeOfParallelism = workers }, delegate(int w)
            {
                using (FileStream fs = File.Open(asarPath, FileMode.Open, FileAccess.Read, FileShare.Read))
                {
                    while (true)
                    {
                        if (Volatile.Read(ref firstErr) != null) return;
                        int i = Interlocked.Increment(ref nextIdx);
                        if (i >= total) return;
                        try
                        {
                            JsEntryInfo entry = jsEntries[i];
                            byte[] raw = ReadEntryExact(fs, dataStart, entry.Offset, entry.Size);
                            string text = DecodeUtf8StripBom(raw);
                            string cur = text;
                            bool dirty = false;

                            // 1. Register-Language
                            if (cur.IndexOf(whitelistAnchor, StringComparison.Ordinal) >= 0)
                            {
                                wlMatched[i] = true;
                                if (langListRe.IsMatch(cur))
                                {
                                    string updated = langListRe.Replace(cur, langReplacement);
                                    if (string.Equals(updated, cur, StringComparison.Ordinal))
                                    {
                                        wlAlready[i] = true;
                                    }
                                    else
                                    {
                                        cur = updated;
                                        dirty = true;
                                        wlChanged[i] = true;
                                    }
                                }
                            }

                            // 2. Patch-HardcodedFrontendStrings
                            int hcCount;
                            string afterHc = FrontendPatcher.PatchText(cur, compiled, out hcCount);
                            if (hcCount > 0 && !string.Equals(afterHc, cur, StringComparison.OrdinalIgnoreCase))
                            {
                                cur = afterHc;
                                dirty = true;
                                hcCounts[i] = hcCount;
                            }

                            // 3. Patch-SlashCommandMenu candidate detection
                            if (slashRe != null && slashRe.IsMatch(cur))
                            {
                                slashMatched[i] = true;
                                slashTextOut[i] = cur;
                            }

                            // 4. Patch-LanguageDisplayNames detection
                            bool hasMarker = !string.IsNullOrEmpty(displayNamesMarker) && cur.IndexOf(displayNamesMarker, StringComparison.Ordinal) >= 0;
                            if (hasMarker)
                            {
                                dnAlready[i] = true;
                            }
                            else if (cur.IndexOf("Intl.DisplayNames", StringComparison.Ordinal) >= 0)
                            {
                                dnTarget[i] = true;
                                dirty = true;
                            }

                            if (dirty)
                            {
                                modifiedOut[i] = cur;
                            }

                            int done = Interlocked.Increment(ref scanned);
                            if (done % 500 == 0 || done == total)
                            {
                                Console.WriteLine("  scanned " + done + "/" + total + " JS files");
                            }
                        }
                        catch (Exception ex)
                        {
                            Interlocked.CompareExchange(ref firstErr, ex, null);
                            return;
                        }
                    }
                }
            });
            if (firstErr != null) throw new IOException(firstErr.Message, firstErr);

            List<string> wlMatchedList = new List<string>();
            List<string> wlChangedList = new List<string>();
            List<string> wlAlreadyList = new List<string>();
            List<string> hcLogs = new List<string>();
            List<string> slashPaths = new List<string>();
            List<string> slashTexts = new List<string>();
            List<string> dnTargets = new List<string>();
            List<string> dnAlreadys = new List<string>();
            int hcPatchedFiles = 0;
            int hcTotalRepl = 0;

            for (int i = 0; i < total; i++)
            {
                string path = jsEntries[i].EntryPath;
                string name = jsEntries[i].FileName;
                if (wlMatched[i]) wlMatchedList.Add(name);
                if (wlChanged[i]) wlChangedList.Add(name);
                if (wlAlready[i]) wlAlreadyList.Add(name);
                if (hcCounts[i] > 0)
                {
                    hcPatchedFiles++;
                    hcTotalRepl += hcCounts[i];
                    hcLogs.Add(name + " (" + hcCounts[i] + " replacements)");
                }
                if (slashMatched[i])
                {
                    slashPaths.Add(path);
                    slashTexts.Add(slashTextOut[i]);
                }
                if (dnTarget[i]) dnTargets.Add(path);
                if (dnAlready[i]) dnAlreadys.Add(path);
                if (modifiedOut[i] != null)
                {
                    res.ModifiedTexts[path] = modifiedOut[i];
                }
            }

            res.WhitelistMatchedNames = wlMatchedList.ToArray();
            res.WhitelistChangedNames = wlChangedList.ToArray();
            res.WhitelistAlreadyNames = wlAlreadyList.ToArray();
            res.HardcodedPatchedFiles = hcPatchedFiles;
            res.HardcodedTotalReplacements = hcTotalRepl;
            res.HardcodedLogEntries = hcLogs.ToArray();
            res.SlashCandidatePaths = slashPaths.ToArray();
            res.SlashCandidateTexts = slashTexts.ToArray();
            res.DisplayNameTargetPaths = dnTargets.ToArray();
            res.DisplayNameAlreadyPaths = dnAlreadys.ToArray();
            return res;
        }

        private sealed class CopyChunk
        {
            public bool FromSource;
            public long SourceOffset;
            public long Length;
            public byte[] Data;
        }

        private static void InsertOverlayEntry(JsonObject root, string entryPath, JsonObject fileNode)
        {
            string[] segments = entryPath.Split('/');
            JsonObject cur = root;
            for (int i = 0; i < segments.Length - 1; i++)
            {
                object filesVal;
                JsonObject files;
                if (!cur.TryGet("files", out filesVal) || (files = filesVal as JsonObject) == null)
                {
                    files = new JsonObject();
                    cur.Set("files", files);
                }
                object nextVal;
                JsonObject next;
                if (!files.TryGet(segments[i], out nextVal) || (next = nextVal as JsonObject) == null || !next.ContainsKey("files"))
                {
                    next = new JsonObject();
                    next.Set("files", new JsonObject());
                    files.Set(segments[i], next);
                }
                cur = next;
            }
            object leafFilesVal;
            JsonObject leafFiles;
            if (!cur.TryGet("files", out leafFilesVal) || (leafFiles = leafFilesVal as JsonObject) == null)
            {
                leafFiles = new JsonObject();
                cur.Set("files", leafFiles);
            }
            leafFiles.Set(segments[segments.Length - 1], fileNode);
        }

        private static void RebuildTreePlan(
            JsonObject node,
            string prefix,
            Dictionary<string, byte[]> overlays,
            Dictionary<string, IntegrityResult> overlayIntegrities,
            List<CopyChunk> plan,
            ref long outOffset,
            StringBuilder sb)
        {
            sb.Append("{\"files\":{");
            object filesVal;
            JsonObject files = (node.TryGet("files", out filesVal) ? filesVal as JsonObject : null);
            if (files != null)
            {
                List<KeyValuePair<string, object>> sorted = new List<KeyValuePair<string, object>>(files.Entries);
                sorted.Sort(delegate(KeyValuePair<string, object> a, KeyValuePair<string, object> b)
                {
                    return string.Compare(a.Key, b.Key, StringComparison.OrdinalIgnoreCase);
                });
                for (int i = 0; i < sorted.Count; i++)
                {
                    if (i > 0) sb.Append(',');
                    string name = sorted[i].Key;
                    string rel = prefix.Length == 0 ? name : prefix + "/" + name;
                    MiniJson.WriteString(name, sb);
                    sb.Append(':');
                    JsonObject child = sorted[i].Value as JsonObject;
                    if (child != null && child.ContainsKey("files"))
                    {
                        RebuildTreePlan(child, rel, overlays, overlayIntegrities, plan, ref outOffset, sb);
                        continue;
                    }
                    if (child != null && child.ContainsKey("link"))
                    {
                        throw new InvalidDataException("暂不支持包含软链接的 ASAR: " + rel);
                    }
                    byte[] overlayData;
                    if (overlays.TryGetValue(rel, out overlayData))
                    {
                        IntegrityResult h = overlayIntegrities[rel];
                        sb.Append("{\"size\":");
                        sb.Append(overlayData.Length.ToString(CultureInfo.InvariantCulture));
                        sb.Append(",\"offset\":\"");
                        sb.Append(outOffset.ToString(CultureInfo.InvariantCulture));
                        sb.Append("\",\"integrity\":{\"algorithm\":\"SHA256\",\"hash\":\"");
                        sb.Append(h.Hash);
                        sb.Append("\",\"blockSize\":");
                        sb.Append(h.BlockSize.ToString(CultureInfo.InvariantCulture));
                        sb.Append(",\"blocks\":[");
                        for (int b = 0; b < h.Blocks.Length; b++)
                        {
                            if (b > 0) sb.Append(',');
                            sb.Append('"');
                            sb.Append(h.Blocks[b]);
                            sb.Append('"');
                        }
                        sb.Append("]}}");
                        CopyChunk c = new CopyChunk();
                        c.FromSource = false;
                        c.Data = overlayData;
                        c.Length = overlayData.Length;
                        plan.Add(c);
                        outOffset += overlayData.Length;
                    }
                    else if (child != null && GetBoolProp(child, "unpacked"))
                    {
                        MiniJson.WriteValue(child, sb);
                    }
                    else if (child != null)
                    {
                        long oldOff = GetInt64Prop(child, "offset");
                        long size = GetInt64Prop(child, "size");
                        JsonObject updated = new JsonObject();
                        for (int e = 0; e < child.Entries.Count; e++)
                        {
                            string k = child.Entries[e].Key;
                            if (k == "offset") updated.Set("offset", outOffset.ToString(CultureInfo.InvariantCulture));
                            else if (k == "size") updated.Set("size", size);
                            else updated.Set(k, child.Entries[e].Value);
                        }
                        if (!updated.ContainsKey("offset")) updated.Set("offset", outOffset.ToString(CultureInfo.InvariantCulture));
                        if (!updated.ContainsKey("size")) updated.Set("size", size);
                        MiniJson.WriteValue(updated, sb);

                        if (size > 0)
                        {
                            if (plan.Count > 0 && plan[plan.Count - 1].FromSource &&
                                plan[plan.Count - 1].SourceOffset + plan[plan.Count - 1].Length == oldOff)
                            {
                                plan[plan.Count - 1].Length += size;
                            }
                            else
                            {
                                CopyChunk c = new CopyChunk();
                                c.FromSource = true;
                                c.SourceOffset = oldOff;
                                c.Length = size;
                                plan.Add(c);
                            }
                            outOffset += size;
                        }
                    }
                }
            }
            sb.Append("}}");
        }

        public static bool HasOverlayChanges(string sourceAsarPath, Dictionary<string, byte[]> overlays)
        {
            if (overlays == null || overlays.Count == 0) return false;
            int headerSize;
            long dataStart;
            byte[] headerBytes = ReadHeaderJsonBytes(sourceAsarPath, out headerSize, out dataStart);
            JsonObject header = MiniJson.Parse(Encoding.UTF8.GetString(headerBytes)) as JsonObject;
            if (header == null) return true;

            using (FileStream fs = File.Open(sourceAsarPath, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                foreach (KeyValuePair<string, byte[]> kv in overlays)
                {
                    JsonObject node = FindNode(header, kv.Key);
                    if (node == null || node.ContainsKey("files") || node.ContainsKey("link") || GetBoolProp(node, "unpacked"))
                    {
                        return true;
                    }
                    long sz = GetInt64Prop(node, "size");
                    if (sz != kv.Value.Length) return true;
                    long off = GetInt64Prop(node, "offset");
                    byte[] existing = ReadEntryExact(fs, dataStart, off, sz);
                    for (int i = 0; i < existing.Length; i++)
                    {
                        if (existing[i] != kv.Value[i]) return true;
                    }
                }
            }
            return false;
        }

        public static void RebuildAsarWithOverlays(string sourceAsarPath, string tempAsarPath, Dictionary<string, byte[]> overlays, int blockSize, int maxWorkers)
        {
            int headerSize;
            long oldDataStart;
            byte[] headerBytes = ReadHeaderJsonBytes(sourceAsarPath, out headerSize, out oldDataStart);
            JsonObject header = MiniJson.Parse(Encoding.UTF8.GetString(headerBytes)) as JsonObject;
            if (header == null) throw new InvalidDataException("无效的 ASAR 头部: " + sourceAsarPath);

            string[] overlayKeys = new string[overlays.Count];
            byte[][] overlayVals = new byte[overlays.Count][];
            int idx = 0;
            foreach (KeyValuePair<string, byte[]> kv in overlays)
            {
                overlayKeys[idx] = kv.Key;
                overlayVals[idx] = kv.Value;
                idx++;
            }

            IntegrityResult[] overlayHashes = new IntegrityResult[overlayKeys.Length];
            int workers = overlayKeys.Length < 8 ? 1 : Math.Max(1, Math.Min(maxWorkers, 12));
            if (workers == 1)
            {
                using (SHA256 wholeSha = SHA256.Create())
                using (SHA256 blockSha = SHA256.Create())
                {
                    for (int i = 0; i < overlayKeys.Length; i++)
                    {
                        overlayHashes[i] = ComputeBytesIntegrity(overlayVals[i], blockSize, wholeSha, blockSha);
                    }
                }
            }
            else
            {
                int nextIdx = -1;
                Parallel.For(0, workers, new ParallelOptions { MaxDegreeOfParallelism = workers }, delegate(int w)
                {
                    using (SHA256 wholeSha = SHA256.Create())
                    using (SHA256 blockSha = SHA256.Create())
                    {
                        while (true)
                        {
                            int k = Interlocked.Increment(ref nextIdx);
                            if (k >= overlayKeys.Length) return;
                            overlayHashes[k] = ComputeBytesIntegrity(overlayVals[k], blockSize, wholeSha, blockSha);
                        }
                    }
                });
            }

            Dictionary<string, IntegrityResult> integrityMap = new Dictionary<string, IntegrityResult>(overlayKeys.Length, StringComparer.Ordinal);
            for (int i = 0; i < overlayKeys.Length; i++)
            {
                integrityMap[overlayKeys[i]] = overlayHashes[i];
                if (FindNode(header, overlayKeys[i]) == null)
                {
                    InsertOverlayEntry(header, overlayKeys[i], new JsonObject());
                }
            }

            List<CopyChunk> plan = new List<CopyChunk>(1024);
            long outOffset = 0;
            StringBuilder headerSb = new StringBuilder(headerBytes.Length + overlayKeys.Length * 220);
            RebuildTreePlan(header, "", overlays, integrityMap, plan, ref outOffset, headerSb);
            byte[] newHeaderBytes = Utf8NoBom.GetBytes(headerSb.ToString());

            byte[] copyBuf = new byte[1024 * 1024];
            using (FileStream src = File.Open(sourceAsarPath, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (FileStream dst = File.Open(tempAsarPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                WriteAsarPrefixAndHeader(dst, newHeaderBytes);
                for (int i = 0; i < plan.Count; i++)
                {
                    CopyChunk chunk = plan[i];
                    if (chunk.FromSource)
                    {
                        src.Position = oldDataStart + chunk.SourceOffset;
                        long remaining = chunk.Length;
                        while (remaining > 0)
                        {
                            int wanted = (int)Math.Min(copyBuf.Length, remaining);
                            int n = src.Read(copyBuf, 0, wanted);
                            if (n <= 0) throw new IOException("复制原始 ASAR 数据时提前结束");
                            dst.Write(copyBuf, 0, n);
                            remaining -= n;
                        }
                    }
                    else if (chunk.Data.Length > 0)
                    {
                        dst.Write(chunk.Data, 0, chunk.Data.Length);
                    }
                }
            }
        }
    }

    public static class ExeIntegrityHelper
    {
        private static readonly byte[] ResourcesAnchor = Encoding.ASCII.GetBytes("resources");

        private static bool MatchAt(byte[] buf, int pos, int validLen, byte[] pat)
        {
            if (pos < 0 || pos + pat.Length > validLen) return false;
            for (int i = 0; i < pat.Length; i++)
            {
                if (buf[pos + i] != pat[i]) return false;
            }
            return true;
        }

        public static long[] FindMarkerOffsets(string exePath, string[] asarNames)
        {
            int targetCount = asarNames.Length;
            byte[][][] patterns = new byte[targetCount][][];
            int[][] anchorOffsets = new int[targetCount][];
            int[,] counts = new int[targetCount, 5];
            long[,] firstHashOffsets = new long[targetCount, 5];
            long[,] lastMatchStarts = new long[targetCount, 5];

            const string tail = "\",\"alg\":\"SHA256\",\"value\":\"";
            for (int t = 0; t < targetCount; t++)
            {
                string name = asarNames[t];
                string[] cands = new string[5];
                cands[0] = "{\"file\":\"resources\\\\" + name + tail;
                cands[1] = "resources\\\\" + name + tail;
                cands[2] = "{\"file\":\"resources/" + name + tail;
                cands[3] = "resources/" + name + tail;
                cands[4] = "resources\\" + name + tail;
                patterns[t] = new byte[5][];
                anchorOffsets[t] = new int[5];
                for (int c = 0; c < 5; c++)
                {
                    patterns[t][c] = Encoding.ASCII.GetBytes(cands[c]);
                    anchorOffsets[t][c] = cands[c].IndexOf("resources", StringComparison.Ordinal);
                    lastMatchStarts[t, c] = -1L;
                }
            }

            long fileLength;
            const int chunkSize = 4 * 1024 * 1024;
            const int overlap = 256;
            byte[] buf = new byte[chunkSize + overlap];

            using (FileStream fs = File.Open(exePath, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                fileLength = fs.Length;
                int carry = 0;
                long chunkFileStart = 0;
                while (true)
                {
                    int read = fs.Read(buf, carry, chunkSize);
                    if (read <= 0) break;
                    int valid = carry + read;

                    int pos = 0;
                    int limit = valid - ResourcesAnchor.Length;
                    while (pos <= limit)
                    {
                        int hit = Array.IndexOf(buf, (byte)'r', pos, limit - pos + 1);
                        if (hit < 0) break;
                        if (buf[hit + 1] == (byte)'e' && buf[hit + 2] == (byte)'s' && buf[hit + 3] == (byte)'o' &&
                            buf[hit + 4] == (byte)'u' && buf[hit + 5] == (byte)'r' && buf[hit + 6] == (byte)'c' &&
                            buf[hit + 7] == (byte)'e' && buf[hit + 8] == (byte)'s')
                        {
                            for (int t = 0; t < targetCount; t++)
                            {
                                for (int c = 0; c < 5; c++)
                                {
                                    int start = hit - anchorOffsets[t][c];
                                    if (MatchAt(buf, start, valid, patterns[t][c]))
                                    {
                                        long absStart = chunkFileStart + start;
                                        if (absStart > lastMatchStarts[t, c])
                                        {
                                            lastMatchStarts[t, c] = absStart;
                                            counts[t, c]++;
                                            if (counts[t, c] == 1)
                                            {
                                                firstHashOffsets[t, c] = absStart + patterns[t][c].Length;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        pos = hit + 1;
                    }

                    if (valid > overlap)
                    {
                        int keep = overlap;
                        Buffer.BlockCopy(buf, valid - keep, buf, 0, keep);
                        chunkFileStart += (valid - keep);
                        carry = keep;
                    }
                    else
                    {
                        carry = valid;
                    }
                }
            }

            long[] result = new long[targetCount];
            for (int t = 0; t < targetCount; t++)
            {
                bool found = false;
                for (int c = 0; c < 5; c++)
                {
                    if (counts[t, c] == 0) continue;
                    if (counts[t, c] > 1)
                    {
                        throw new InvalidDataException("Could not find a unique Claude.exe " + asarNames[t] + " integrity marker. Claude bundle format may have changed.");
                    }
                    long hashOffset = firstHashOffsets[t, c];
                    if (hashOffset + 64 > fileLength)
                    {
                        throw new InvalidDataException("Claude.exe " + asarNames[t] + " integrity marker has invalid bounds.");
                    }
                    result[t] = hashOffset;
                    found = true;
                    break;
                }
                if (!found)
                {
                    throw new InvalidDataException("Could not find Claude.exe " + asarNames[t] + " integrity marker. Claude bundle format may have changed.");
                }
            }
            return result;
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

    # 预处理：过滤结构性跳过规则，记录每条规则是否为 plain UI 文本。
    # C# 引擎直接基于 Aho-Corasick + 引号边界扫描，无需在 PowerShell 里逐条预编译数千个 Regex。
    $prepared = New-Object 'System.Collections.Generic.List[object[]]'
    foreach ($pair in $replacements) {
        $source = [string]$pair[0]
        $target = [string]$pair[1]
        if (Test-StructuralJsReplacement $source) {
            continue
        }
        $isPlain = Test-PlainUiTextReplacement $source
        $prepared.Add([object[]]@([bool]$isPlain, $source, $target))
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
    $jsFiles = @(Get-ChildItem (Join-Path $assetsDir '*.js') -File -ErrorAction SilentlyContinue)
    if (-not ("ClaudeZhPatch.FrontendPatcher" -as [type]) -and $script:FrontendPatcherCSharp) {
        try { Add-Type -TypeDefinition $script:FrontendPatcherCSharp -ErrorAction Stop } catch {}
    }
    if ("ClaudeZhPatch.FrontendPatcher" -as [type]) {
        $filePaths = [string[]]@($jsFiles | ForEach-Object { $_.FullName })
        $workers = [Math]::Max(1, [Math]::Min([Environment]::ProcessorCount, 12))
        $matchedPaths = [ClaudeZhPatch.FrontendPatcher]::FindFilesMatchingRegex($filePaths, [string]$config.Profile.module_pattern, $workers)
        $candidates = @(
            foreach ($p in $matchedPaths) {
                @{ File = [IO.FileInfo]::new($p); Text = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) }
            }
        )
    }
    else {
        $candidates = @(
            foreach ($file in $jsFiles) {
                $text = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8)
                if ([regex]::IsMatch($text, $config.Profile.module_pattern)) { @{ File = $file; Text = $text } }
            }
        )
    }
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

function Test-ServiceControlAvailable {
    # Get-Service / Stop-Service / Start-Service 只在 Windows 上存在；非 Windows 上的
    # PowerShell 7 没有这些 cmdlet，且 CommandNotFoundException 不受
    # -ErrorAction SilentlyContinue 抑制，因此必须先探测可用性。
    return [bool](Get-Command -Name Get-Service -ErrorAction SilentlyContinue)
}

function Stop-CoworkVMService {
    if (-not (Test-ServiceControlAvailable)) {
        return
    }

    $serviceNames = @("CoworkVMService", "CoworkVMServiceStore")
    foreach ($serviceName in $serviceNames) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($service -and $service.Status -ne "Stopped") {
            try {
                Write-Host "  正在停止 $serviceName 服务..." -ForegroundColor DarkGray
                Stop-Service -Name $serviceName -Force -ErrorAction Stop
                Start-Sleep -Seconds 1
            }
            catch {
                Write-Host "  [提示] 停止 $serviceName 服务: $($_.Exception.Message)" -ForegroundColor DarkGray
            }
        }
    }
}

function Start-CoworkVMService {
    if (-not (Test-ServiceControlAvailable)) {
        return
    }

    $serviceNames = @("CoworkVMService", "CoworkVMServiceStore")
    $foundAny = $false
    foreach ($serviceName in $serviceNames) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($service) {
            $foundAny = $true
            if ($service.Status -eq "Running") {
                Write-Host "  $serviceName 已在运行" -ForegroundColor Green
                continue
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
    }

    if (-not $foundAny) {
        Write-Host "  [提示] 未找到 CoworkVMService 服务，跳过。" -ForegroundColor DarkGray
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

    $failed = @()
    foreach ($target in $targets) {
        Remove-Item $target -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path $target)) {
            Write-Host "  removed: $target" -ForegroundColor Green
        } else {
            $failed += $target
            Write-Host "  [警告] 未能删除: $target" -ForegroundColor DarkYellow
        }
    }

    if ($failed.Count -gt 0) {
        Write-Host "  [警告] 有 $($failed.Count) 个中文资源未能删除，卸载可能不完整；" -ForegroundColor Yellow
        Write-Host "         请确认脚本以管理员身份运行后重试卸载。" -ForegroundColor DarkYellow
    }
    return $failed.Count
}

function Test-ClaudeDesktopProcessPath {
    param([string]$Path)

    if (-not $Path) {
        return $false
    }
    return ($Path -match "(?i)WindowsApps\\.*Claude" -or
            $Path -match "(?i)AnthropicClaude\\app-" -or
            $Path -match "(?i)scoop\\apps\\(?:claude|claude-desktop)" -or
            ($script:ExplicitClaudePath -and $Path.StartsWith($script:ExplicitClaudePath, [System.StringComparison]::OrdinalIgnoreCase)) -or
            ($env:CLAUDE_PATH -and $Path.StartsWith($env:CLAUDE_PATH, [System.StringComparison]::OrdinalIgnoreCase)))
}

function Get-ClaudeDesktopProcesses {
    # Win32_Process 可跨用户会话枚举；旧实现用 Get-Process + MainModule 取路径，
    # 读取另一账户会话里的 MSIX 进程会被拒绝并静默跳过，安装器就会误以为应用已退出，
    # 随后替换 app.asar 时被锁文件挡住（issue #244）。
    $procs = @()
    $seen = @{}
    $cimAvailable = $null -ne (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)
    if ($cimAvailable) {
        $items = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -ieq "claude.exe" -and (Test-ClaudeDesktopProcessPath $_.ExecutablePath)
            })

        foreach ($item in $items) {
            if ($seen.ContainsKey([int]$item.ProcessId)) { continue }
            $seen[[int]$item.ProcessId] = $true
            $proc = Get-Process -Id $item.ProcessId -ErrorAction SilentlyContinue
            if ($proc) {
                $procs += $proc
            }
            else {
                # 进程存在但当前身份读不到；保留 PID/名称，交给 taskkill 兜底。
                $procs += [pscustomobject]@{
                    Id = [int]$item.ProcessId
                    ProcessName = [IO.Path]::GetFileNameWithoutExtension([string]$item.Name)
                    MainWindowHandle = 0
                    HasExited = $false
                }
            }
        }
    }

    if (-not $cimAvailable) {
        foreach ($proc in Get-Process -Name "claude" -ErrorAction SilentlyContinue) {
            try {
                $path = $proc.MainModule.FileName
                if (Test-ClaudeDesktopProcessPath $path) {
                    $procs += $proc
                }
            } catch {
                # MainModule 不可读；CIM 不可用时只能跳过，避免误杀。
            }
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
        # Stop-Process 对跨会话/受保护的 MSIX 进程可能静默失败，再用 taskkill /PID 兜底。
        foreach ($proc in @(Get-ClaudeDesktopProcesses)) {
            $null = & taskkill.exe /PID $proc.Id 2>&1
        }
        Start-Sleep -Seconds 1
    }

    # cowork-svc.exe 不叫 claude.exe，旧逻辑不会停它；恢复/覆盖 app.asar 时它可能继续占用资源。
    Stop-CoworkVMService
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
            # Stop-Process 可能被跨会话/服务保护挡住，用 taskkill 再试一次。
            $null = & taskkill.exe /PID $proc.Id 2>&1
        }
        Start-Sleep -Milliseconds 500
        foreach ($proc in @(Get-ClaudeCoworkProcesses)) {
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
    param([switch]$RequireStopped)

    $null = Stop-ClaudeProcessesGracefully -TimeoutSeconds 10
    $remaining = @(@(Get-ClaudeDesktopProcesses) + @(Get-ClaudeCoworkProcesses) | Sort-Object Id -Unique)
    if ($remaining.Count -gt 0) {
        $list = ($remaining | ForEach-Object { "$($_.ProcessName) (PID=$($_.Id))" }) -join ", "
        if ($RequireStopped) {
            throw "无法停止 Claude Desktop（$list）。请先手动结束这些进程再重试；如果应用在另一个 Windows 账户下运行，请先注销该账户，或改用官网安装包。"
        }
        Write-Host "  [警告] 仍有 Claude 进程未退出: $list" -ForegroundColor DarkYellow
        return $false
    }

    Write-Host "  Claude Desktop 已停止" -ForegroundColor Green
    return $true
}

function Restart-Claude {
    param([string]$ClaudePath)

    Stop-ClaudeProcesses

    # 仅对 AppX(MSIX) 安装优先用包激活启动: 进程带包身份, 更新检查走 msix 路径
    # (直接启动 exe 会被更新器误判为 Squirrel 解包安装而报 "Can not find Squirrel",
    #  Cowork 客户端校验也只能靠签名回退)
    if ($ClaudePath -match "WindowsApps") {
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
    }

    $exe = Get-ClaudeExePath $ClaudePath
    if ($exe) {
        Start-Process -FilePath "explorer.exe" -ArgumentList "`"$exe`""
        Write-Host "  restarted Claude Desktop" -ForegroundColor Green
        if ($ClaudePath -match "WindowsApps") {
            Write-Host "  [提示] MSIX 安装建议从开始菜单启动 Claude，以获得完整功能(自动更新/Cowork)。" -ForegroundColor DarkYellow
        }
        return
    }

    Write-Host "  [警告] 未找到 Claude.exe，请手动启动 Claude Desktop。" -ForegroundColor DarkYellow
}

function Install-WindowsLanguagePack {
    $label = Get-LanguageLabel $LanguageCode

    # 单实例互斥锁：防止多个安装进程并发写入 Claude 资源
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

    $patchTarget = $null
    try {
        Write-Step "[1/7] 检查语言资源"
        $pack = Get-LanguageResources $LanguageCode

        Write-Step "关闭 Claude Desktop"
        Stop-ClaudeProcesses -RequireStopped

        Write-Step "[2/7] 查找 Claude Desktop"
        $paths = Get-ClaudeResourcesPath
        $claudePath = $paths["App"]
        $resourcesPath = $paths["Resources"]
        $installKind = $paths["InstallKind"]
        Write-Host "  app: $claudePath" -ForegroundColor Green
        Write-Host "  resources: $resourcesPath" -ForegroundColor Green
        if ($installKind -eq "AppX") {
            if ($resourcesPath -match '(?i)\\WindowsApps\\AnthropicPBC\.Claude_') {
                Write-Host "  安装类型: Microsoft Store 商店版 (MSIX/AppX)" -ForegroundColor DarkGray
            }
            else {
                Write-Host "  安装类型: 官网安装包 (MSIX/AppX)" -ForegroundColor DarkGray
            }
        }
        elseif ($installKind -eq "Scoop") {
            Write-Host "  安装类型: Scoop 安装包 (extras/claude)" -ForegroundColor DarkGray
        }
        elseif ($installKind -eq "Custom") {
            Write-Host "  安装类型: 自定义路径" -ForegroundColor DarkGray
        }
        # 先只读校验完整性标记，再动任何 asar：4.4212 曾出现「asar 已改、exe 哈希写不回」
        # 的半坏状态，这里在结构不兼容时零副作用地快速失败。
        Assert-ClaudeExeIntegrityMarkers $resourcesPath

        Write-Step "修复桌面 Claude 快捷方式"
        Repair-ClaudeDesktopShortcut $claudePath

        Write-Step "[3/7] 准备写入权限"
        Assert-WriteAccess $resourcesPath "安装"
        # 先确认应用确实退出、asar 可替换，再动任何文件；否则可能写到一半才失败。
        $null = Stop-ClaudeProcesses -RequireStopped
        foreach ($asarPath in @((Join-Path $resourcesPath "app.asar"), (Join-Path $resourcesPath "ion-dist.asar"))) {
            Assert-AsarReplaceable -Path $asarPath
        }
        Remove-LegacyAppxForkArtifacts

        $bundleMode = Get-FrontendBundleMode $resourcesPath
        if ($bundleMode -eq "Asar") {
            if (-not ("ClaudeZhPatch.AsarHelper" -as [type]) -and $script:FrontendPatcherCSharp) {
                try { Add-Type -TypeDefinition $script:FrontendPatcherCSharp -ErrorAction Stop } catch {}
            }
        }
        $useDirectAsar = ($bundleMode -eq "Asar") -and [bool]("ClaudeZhPatch.AsarHelper" -as [type])

        if ($useDirectAsar) {
            Write-Step "[4/7] 写入 $label 桌面资源"
            Install-LanguageFiles $resourcesPath $pack $LanguageCode -DesktopOnly

            Write-Step "[5/7] 扫描并汉化前端资源 (ion-dist.asar)"
            Patch-AsarFrontendDirect $resourcesPath $pack $LanguageCode

            Write-Step "[6/7] 汉化主进程菜单并同步完整性哈希"
            $null = Stop-ClaudeProcesses -RequireStopped
            Patch-DesktopShellLocale $resourcesPath $LanguageCode -SkipIntegritySync
            Sync-ClaudeExeAsarIntegrity $resourcesPath
            $usedAsarFrontend = $true
        }
        else {
            $patchTarget = Initialize-FrontendPatchTarget $resourcesPath

            Write-Step "[4/7] 写入 $label 资源"
            Install-LanguageFiles $resourcesPath $pack $LanguageCode

            Write-Step "[5/7] 注册中文语言"
            Register-Language $resourcesPath $LanguageCode

            Write-Step "[6/7] 汉化硬编码界面文本"
            Patch-HardcodedFrontendStrings $resourcesPath $LanguageCode
            Patch-SlashCommandMenu $resourcesPath $LanguageCode
            Patch-LanguageDisplayNames $resourcesPath
            # 前端同样固定加载 en-US 词库，把中文词库合并进去才能覆盖仅存在于词库的文案。
            $mergedFrontend = Merge-LocaleOverride (Join-Path $resourcesPath "ion-dist\i18n") $LanguageCode
            if ($mergedFrontend -gt 0) {
                Write-Host "  ion-dist.asar 已把 $LanguageCode 词库覆盖进 i18n/en-US.json（$mergedFrontend 条）" -ForegroundColor Green
            }
            # 前端补丁阶段可能耗时数分钟，MSIX 版可能在期间被重新激活；写 app.asar 前再确认一次。
            $null = Stop-ClaudeProcesses -RequireStopped
            $usedAsarFrontend = $patchTarget.Mode -eq "Asar"
            if ($usedAsarFrontend) {
                Patch-DesktopShellLocale $resourcesPath $LanguageCode -SkipIntegritySync
            }
            else {
                Patch-DesktopShellLocale $resourcesPath $LanguageCode
            }
            Complete-FrontendPatchTarget $patchTarget
            Close-FrontendPatchTarget $patchTarget
            $patchTarget = $null
        }

        $appVersion = Get-ClaudeExeProductVersion $claudePath
        Patch-CoworkService $resourcesPath $appVersion

        Write-Step "[7/7] 写入用户语言配置"
        Set-ClaudeLocale $LanguageCode

        Write-Step "重启 Claude Desktop"
        Restart-Claude $claudePath

        Write-Step "启动 CoworkVMService"
        Start-CoworkVMService

        Write-Host ""
        Write-Host "安装完成。如果界面未立即切换，请在 Language 中选择 $label。" -ForegroundColor Green
        if ($usedAsarFrontend) {
            Write-Host "提示：Claude 4.29+ 将前端打包为 ion-dist.asar，主进程菜单词库在 app.asar 内；安装器已重建 ion-dist.asar、就地改写 app.asar 并更新 Claude.exe 完整性哈希；同时已自动修补 cowork-svc.exe 签名校验，解决 Cowork 报 RPC pipe closed 的问题。" -ForegroundColor DarkYellow
        }
        else {
            Write-Host "提示：本补丁仅写入中文资源，不改动 app.asar / Claude.exe；官方账号登录界面请直接使用 Claude 自带的语言设置。" -ForegroundColor DarkGray
        }
    }
    catch {
        Write-Host ""
        Write-Host "安装过程中出现错误，Claude Desktop 可能处于不完整状态。" -ForegroundColor Red
        Write-Host "  建议从项目目录重新运行 install-windows.ps1，选择「恢复原样 / 卸载补丁」。" -ForegroundColor DarkYellow
        Write-Host "  详细日志: $script:InstallLogPath" -ForegroundColor DarkGray
        if ($script:DetectedMultipleClaudeInstalls) {
            Write-MultipleClaudeFailureHint
        }
        throw
    }
    finally {
        if ($null -ne $patchTarget) {
            Close-FrontendPatchTarget $patchTarget
        }
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
    Stop-ClaudeProcesses -RequireStopped
    Remove-LegacyAppxForkArtifacts

    # 卸载路径同样要写回备份、重同步 exe 哈希，所以也得先把权限拿到。
    # 之前只有安装流程调过，ACL 一旦被系统修复 / 安全软件 / 手动 icacls 重置，
    # 预清理会在 Restore-LatestBackup 或 Sync-ClaudeExeAsarIntegrity 处抛错，
    # 外层 catch 直接退出，连后面 [3/7] 的兜底都轮不到。
    #
    # 但如果这台机器上根本没有补丁可卸（例如装的是商店版、从来没打上过），
    # 就不该为了「清理」去接管系统目录的所有权 —— 那只会让用户看到一个
    # 与卸载无关的权限错误。这种情况跳过授权，后面的步骤都是幂等的空操作。
    $hasBackup = Test-Path -LiteralPath (Get-BackupRoot $resourcesPath)
    $langCandidates = @(
        (Join-Path $resourcesPath "zh-CN.json"),
        (Join-Path $resourcesPath "zh-TW.json"),
        (Join-Path $resourcesPath "zh-HK.json"),
        (Join-Path $resourcesPath "ion-dist\i18n\zh-CN.json"),
        (Join-Path $resourcesPath "ion-dist\i18n\zh-TW.json"),
        (Join-Path $resourcesPath "ion-dist\i18n\zh-HK.json")
    )
    $hasLang = @($langCandidates | Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0

    if ($hasBackup -or $hasLang) {
        Write-Step "确认写入权限"
        Assert-WriteAccess $resourcesPath "卸载"
    }
    else {
        Write-Host "  未检测到中文补丁（无备份、无中文资源），跳过权限检查。" -ForegroundColor DarkGray
    }

    Write-Step "[1/4] 恢复前端 bundle 和 app.asar"
    $workspacePath = Join-Path $resourcesPath "ion-dist"
    $markerPath = Join-Path $resourcesPath ".zh-cn-asar-extracted"
    if ((Test-Path -LiteralPath $markerPath -PathType Leaf) -and (Test-Path -LiteralPath $workspacePath)) {
        Remove-GeneratedFrontendWorkspace $resourcesPath $workspacePath
        Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
    }
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
