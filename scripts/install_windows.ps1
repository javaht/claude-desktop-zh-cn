param(
    [switch]$Interactive,
    [switch]$LibraryMode,
    [switch]$SkipAsarPatch,
    [ValidateSet("safe", "official")]
    [string]$PatchMode = "safe",

    [Parameter(Position = 0)]
    [ValidateSet("install", "maintain", "uninstall", "disable-updates", "enable-updates", "sync-skills", "unsync-skills")]
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
$AsarPatchTargetFallback = ".vite/build/index.js"
$AsarIntegrityBlockSize = 4 * 1024 * 1024
$OnlineLocaleMainMarker = "__claudeZhOnlineLocaleMain"
$MenuRuntimeMarker = "__claudeZhMenuRuntimePatch"
$OnlineTranslationMaxSourceLength = 1000
$WindowsMaintenanceSettleSeconds = 90
$WindowsMaintenanceFailureRetrySeconds = 6 * 60 * 60
$script:CurrentBackupSetPath = $null
$script:InstallTransactionActive = $false
$script:InstallTransactionResourcesPath = $null
$script:InstallTransactionCreatedFiles = [System.Collections.Generic.List[string]]::new()
$script:LastInstallRollbackSucceeded = $true
$script:IsMaintenanceRun = $false
$script:RemoveMaintenancePayloadAfterLog = $false
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
    if ($LibraryMode -or $Action -eq "maintain") {
        return
    }
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
    Write-Host "[3] 恢复原样 / 卸载补丁"
    Write-Host "[4] 自动更新设置（y=禁止自动更新，n=允许自动更新）"
    Write-Host "[5] 同步 CC Switch skills（y=开启同步，n=删除同步）"
    Write-Host "[Q] 退出"
    Write-Host ""

    $patchModeForInstall = "safe"
    $actionSelected = $false
    while (-not $actionSelected) {
        $actionSelection = (Read-Host "请选择操作 [1/2/3/4/5/Q]").Trim()
        switch -Regex ($actionSelection) {
            '^[1]$' { $patchModeForInstall = "safe"; $actionSelected = $true }
            '^[2]$' { $patchModeForInstall = "official"; $actionSelected = $true }
            '^[3]$' { return @{ Action = "uninstall"; Language = "zh-CN"; PatchMode = "safe" } }
            '^[4]$' {
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
    $directories = @()
    foreach ($localAppData in @(Get-OriginalLocalAppDataRoots)) {
        $unpackagedBase = Join-Path $localAppData "AnthropicClaude"
        if (-not (Test-Path -LiteralPath $unpackagedBase -PathType Container)) {
            continue
        }
        $directories += Get-ChildItem -LiteralPath $unpackagedBase -Directory -Filter "app-*" -ErrorAction SilentlyContinue |
            Where-Object { Test-UnpackagedClaudeAppDirectory $_ }
    }

    return @($directories |
        Sort-Object FullName -Unique |
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

function Get-OriginalLocalAppDataRoots {
    $roots = @()
    $hasOriginalContext = $false
    if ($env:CLAUDE_ZH_ORIGINAL_LOCALAPPDATA) {
        $roots += $env:CLAUDE_ZH_ORIGINAL_LOCALAPPDATA
        $hasOriginalContext = $true
    }
    if ($env:CLAUDE_ZH_ORIGINAL_USER_PROFILE) {
        $roots += Join-Path $env:CLAUDE_ZH_ORIGINAL_USER_PROFILE "AppData\Local"
        $hasOriginalContext = $true
    }
    if (-not $hasOriginalContext) {
        if ($env:LOCALAPPDATA) {
            $roots += $env:LOCALAPPDATA
        }
        $systemValue = [Environment]::GetFolderPath('LocalApplicationData')
        if ($systemValue) {
            $roots += $systemValue
        }
    }
    return @($roots | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)
}

function Get-OriginalAppDataRoots {
    $roots = @()
    $hasOriginalContext = $false
    if ($env:CLAUDE_ZH_ORIGINAL_APPDATA) {
        $roots += $env:CLAUDE_ZH_ORIGINAL_APPDATA
        $hasOriginalContext = $true
    }
    if ($env:CLAUDE_ZH_ORIGINAL_USER_PROFILE) {
        $roots += Join-Path $env:CLAUDE_ZH_ORIGINAL_USER_PROFILE "AppData\Roaming"
        $hasOriginalContext = $true
    }
    if (-not $hasOriginalContext) {
        if ($env:APPDATA) {
            $roots += $env:APPDATA
        }
        $systemValue = [Environment]::GetFolderPath('ApplicationData')
        if ($systemValue) {
            $roots += $systemValue
        }
    }
    return @($roots | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)
}

function Get-FrontendJavaScriptFiles {
    param([string]$ResourcesPath)

    $assetsRoot = Join-Path $ResourcesPath "ion-dist\assets"
    if (-not (Test-Path -LiteralPath $assetsRoot -PathType Container)) {
        throw "未找到前端 assets 目录: $assetsRoot"
    }

    $files = @(Get-ChildItem -LiteralPath $assetsRoot -Recurse -File -Filter "*.js" -ErrorAction SilentlyContinue |
        Sort-Object FullName)
    if ($files.Count -eq 0) {
        throw "未找到前端 JS bundle: $assetsRoot"
    }
    return $files
}

function Get-FrontendI18nDirectory {
    param([string]$ResourcesPath)

    $preferred = Join-Path $ResourcesPath "ion-dist\i18n"
    if (Test-Path -LiteralPath (Join-Path $preferred "en-US.json") -PathType Leaf) {
        return $preferred
    }

    $ionDist = Join-Path $ResourcesPath "ion-dist"
    if (-not (Test-Path -LiteralPath $ionDist -PathType Container)) {
        throw "未找到前端 ion-dist 目录: $ionDist"
    }
    $candidates = @()
    foreach ($englishFile in @(Get-ChildItem -LiteralPath $ionDist -Recurse -File -Filter "en-US.json" -ErrorAction SilentlyContinue)) {
        $lowerPath = $englishFile.FullName.ToLowerInvariant()
        if ($lowerPath.Contains("\statsig\") -or $lowerPath.Contains("\node_modules\")) {
            continue
        }
        $score = [int64]$englishFile.Length
        if ($englishFile.Directory.Name -in @("i18n", "locales")) {
            $score += 1000000000
        }
        $candidates += [pscustomobject]@{ Score = $score; Path = $englishFile.Directory.FullName }
    }
    $selected = $candidates |
        Sort-Object -Property `
            @{ Expression = { $_.Score }; Descending = $true },
            @{ Expression = { $_.Path }; Descending = $false } |
        Select-Object -First 1
    if (-not $selected) {
        throw "无法动态定位前端 en-US.json；Claude 资源布局可能已变化。"
    }
    return [string]$selected.Path
}

function Update-LanguageArraysInText {
    param(
        [string]$Text,
        [string]$Lang
    )

    # Match arrays made only of locale-like string literals. Requiring en-US and
    # several long-standing Claude locales avoids changing unrelated JS arrays,
    # while preserving every locale and ordering shipped by upstream.
    $arrayPattern = [System.Text.RegularExpressions.Regex]::new(
        '\[(?<items>\s*["''][A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})+["''](?:\s*,\s*["''][A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})+["'']){3,}\s*)\]',
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
    $localePattern = [System.Text.RegularExpressions.Regex]::new('(?<quote>["''])(?<locale>[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})+)\k<quote>')
    $knownLocales = @("de-DE", "fr-FR", "ko-KR", "ja-JP", "es-ES", "it-IT", "pt-BR")
    $candidateCount = 0
    $alreadyCount = 0
    $changedCount = 0
    $replacements = [System.Collections.Generic.List[object]]::new()

    foreach ($match in $arrayPattern.Matches($Text)) {
        $localeMatches = @($localePattern.Matches($match.Groups["items"].Value))
        $locales = @($localeMatches | ForEach-Object { $_.Groups["locale"].Value })
        if ($locales -notcontains "en-US") {
            continue
        }
        $knownCount = @($knownLocales | Where-Object { $locales -contains $_ }).Count
        if ($knownCount -lt 3) {
            continue
        }

        $candidateCount += 1
        if ($locales -contains $Lang) {
            $alreadyCount += 1
            continue
        }

        $items = $match.Groups["items"].Value
        $trailingWhitespace = [System.Text.RegularExpressions.Regex]::Match($items, '\s*$').Value
        $core = $items.Substring(0, $items.Length - $trailingWhitespace.Length)
        $quote = $localeMatches[0].Groups["quote"].Value
        $separatorMatches = [System.Text.RegularExpressions.Regex]::Matches(
            $items,
            '(?<separator>\s*,\s*)["''][A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})+["'']'
        )
        $separator = if ($separatorMatches.Count -gt 0) {
            $separatorMatches[$separatorMatches.Count - 1].Groups["separator"].Value
        } else {
            ","
        }
        $replacement = "[$core$separator$quote$Lang$quote$trailingWhitespace]"
        $replacements.Add([pscustomobject]@{
            Index = $match.Index
            Length = $match.Length
            Value = $replacement
        })
        $changedCount += 1
    }

    $updated = $Text
    foreach ($replacement in @($replacements | Sort-Object Index -Descending)) {
        $updated = $updated.Substring(0, $replacement.Index) +
            $replacement.Value +
            $updated.Substring($replacement.Index + $replacement.Length)
    }

    return @{
        Text = $updated
        CandidateCount = $candidateCount
        AlreadyCount = $alreadyCount
        ChangedCount = $changedCount
    }
}

function Find-ClaudePath {
    $packages = @()
    if ($env:CLAUDE_ZH_ORIGINAL_USER_SID) {
        $packages += @(Get-AppxPackage -User $env:CLAUDE_ZH_ORIGINAL_USER_SID -Name "Claude" -ErrorAction SilentlyContinue)
    }
    $packages += @(Get-AppxPackage -Name "Claude" -ErrorAction SilentlyContinue)
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
    $configPaths = @()
    foreach ($appData in @(Get-OriginalAppDataRoots)) {
        $configPaths += Join-Path $appData "Claude\config.json"
        $configPaths += Join-Path $appData "Claude-3p\config.json"
    }

    $packageNames = @()
    if ($env:CLAUDE_ZH_ORIGINAL_USER_SID) {
        $userPackages = @(Get-AppxPackage -User $env:CLAUDE_ZH_ORIGINAL_USER_SID -Name "Claude" -ErrorAction SilentlyContinue)
        foreach ($package in $userPackages) {
            if ($package.PackageFamilyName) {
                $packageNames += $package.PackageFamilyName
            }
        }
    }
    $packages = @(Get-AppxPackage -Name "Claude" -ErrorAction SilentlyContinue)
    foreach ($package in $packages) {
        if ($package.PackageFamilyName) {
            $packageNames += $package.PackageFamilyName
        }
    }

    foreach ($localAppData in @(Get-OriginalLocalAppDataRoots)) {
        $packageRoot = Join-Path $localAppData "Packages"
        $packageDirs = @(Get-ChildItem (Join-Path $packageRoot "Claude_*") -Directory -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending)
        foreach ($packageDir in $packageDirs) {
            $configPaths += Join-Path $packageDir.FullName "LocalCache\Roaming\Claude\config.json"
            $configPaths += Join-Path $packageDir.FullName "LocalCache\Roaming\Claude-3p\config.json"
        }
    }

    foreach ($localAppData in @(Get-OriginalLocalAppDataRoots)) {
        foreach ($packageName in @($packageNames | Select-Object -Unique)) {
            $packagePath = Join-Path (Join-Path $localAppData "Packages") $packageName
            if (Test-Path -LiteralPath $packagePath -PathType Container) {
                $configPaths += Join-Path $packagePath "LocalCache\Roaming\Claude\config.json"
                $configPaths += Join-Path $packagePath "LocalCache\Roaming\Claude-3p\config.json"
            }
        }
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

function Get-PatchMarkerPath {
    param([string]$ResourcesPath)
    return Join-Path $ResourcesPath ".claude-zh-cn.json"
}

function Get-WindowsPendingRestorePath {
    param([string]$ResourcesPath)
    return Join-Path $ResourcesPath ".claude-zh-cn.pending-restore.json"
}

function Get-PatchReleaseVersion {
    try {
        $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
        $releasePath = Join-Path (Split-Path -Parent $scriptDir) "resources\release.json"
        $release = Get-Content -LiteralPath $releasePath -Raw -Encoding UTF8 | ConvertFrom-Json
        return [string]$release.release
    }
    catch {
        return "unknown"
    }
}

function Get-ClaudeAppIdentity {
    param([hashtable]$Paths)

    $appPath = [System.IO.Path]::GetFullPath([string]$Paths["App"]).TrimEnd('\', '/')
    $exePath = Get-ClaudeExePath $appPath
    $fileVersion = ""
    $productVersion = ""
    $exeLength = [int64]0
    if ($exePath) {
        try {
            $exeItem = Get-Item -LiteralPath $exePath
            $versionInfo = $exeItem.VersionInfo
            $fileVersion = [string]$versionInfo.FileVersion
            $productVersion = [string]$versionInfo.ProductVersion
            $exeLength = [int64]$exeItem.Length
        }
        catch {
        }
    }
    $asarLength = [int64]0
    $asarPath = Join-Path ([string]$Paths["Resources"]) "app.asar"
    if (Test-Path -LiteralPath $asarPath -PathType Leaf) {
        $asarLength = [int64](Get-Item -LiteralPath $asarPath).Length
    }
    return [ordered]@{
        installKind = [string]$Paths["InstallKind"]
        appPath = $appPath
        directoryName = Split-Path -Leaf $appPath
        fileVersion = $fileVersion
        productVersion = $productVersion
        exeLength = $exeLength
        asarLength = $asarLength
    }
}

function Get-FileSha256HexFromPath {
    param([string]$Path)

    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($stream)
        return ([System.BitConverter]::ToString($hash) -replace "-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
        $stream.Dispose()
    }
}

function Get-FilePrefixSha256Hex {
    param(
        [string]$Path,
        [int]$MaximumBytes = 262144
    )

    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $count = [int][Math]::Min([int64]$MaximumBytes, $stream.Length)
        $bytes = [byte[]]::new($count)
        $offset = 0
        while ($offset -lt $count) {
            $read = $stream.Read($bytes, $offset, $count - $offset)
            if ($read -le 0) {
                break
            }
            $offset += $read
        }
        if ($offset -ne $count) {
            throw "无法读取文件指纹: $Path"
        }
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hash = $sha.ComputeHash($bytes)
            return ([System.BitConverter]::ToString($hash) -replace "-", "").ToLowerInvariant()
        }
        finally {
            $sha.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Read-PatchMarker {
    param([string]$ResourcesPath)

    $path = Get-PatchMarkerPath $ResourcesPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    try {
        $marker = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $marker -or -not $marker.appIdentity -or -not ([string]$marker.backupSet).Trim()) {
            throw "marker 缺少 appIdentity 或 backupSet"
        }
        return $marker
    }
    catch {
        Write-Host "  [警告] 汉化 marker 无效，不会恢复任何旧备份: $path" -ForegroundColor DarkYellow
        return $null
    }
}

function Test-PatchMarkerMatchesIdentity {
    param(
        [object]$Marker,
        [hashtable]$Paths
    )

    if (-not $Marker -or -not $Marker.appIdentity) {
        return $false
    }
    $current = Get-ClaudeAppIdentity $Paths
    $recordedPath = [string]$Marker.appIdentity.appPath
    if (-not $recordedPath -or -not $current.appPath.Equals($recordedPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    if ([string]$Marker.appIdentity.installKind -ne [string]$current.installKind) {
        return $false
    }
    foreach ($propertyName in @("fileVersion", "productVersion", "exeLength", "asarLength")) {
        $recorded = [string]$Marker.appIdentity.$propertyName
        $actual = [string]$current.$propertyName
        if ($recorded -and $actual -and $recorded -ne $actual) {
            return $false
        }
    }
    return $true
}

function Get-PatchedFrontendBundleRelativePaths {
    param(
        [string]$ResourcesPath,
        [string]$Lang
    )

    $relativePaths = @()
    foreach ($file in @(Get-FrontendJavaScriptFiles $ResourcesPath)) {
        $text = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
        if (-not $text.Contains("__claudeZhLabelPatch")) {
            continue
        }
        $languageArrays = Update-LanguageArraysInText $text $Lang
        if ([int]$languageArrays["AlreadyCount"] -gt 0) {
            $relativePaths += Get-RelativeResourcePath $ResourcesPath $file.FullName
        }
    }
    return @($relativePaths | Sort-Object -Unique)
}

function Get-RelativeFileFingerprints {
    param(
        [string]$ResourcesPath,
        [object[]]$RelativePaths
    )

    $resourceRoot = [System.IO.Path]::GetFullPath($ResourcesPath).TrimEnd('\', '/')
    $fingerprints = @()
    foreach ($relativeValue in @($RelativePaths)) {
        $relativePath = [string]$relativeValue
        $bundlePath = [System.IO.Path]::GetFullPath((Join-Path $ResourcesPath $relativePath))
        if (-not $bundlePath.StartsWith($resourceRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "marker 资源路径越界: $relativePath"
        }
        Require-File $bundlePath
        $item = Get-Item -LiteralPath $bundlePath
        $fingerprints += [ordered]@{
            path = $relativePath
            length = [int64]$item.Length
            sha256 = Get-FileSha256HexFromPath $bundlePath
        }
    }
    return $fingerprints
}

function Get-BackedUpResourceRelativePaths {
    param([string]$BackupSetPath)

    if (-not (Test-Path -LiteralPath $BackupSetPath -PathType Container)) {
        throw "marker 写入前备份集已丢失: $BackupSetPath"
    }
    $backupRoot = [System.IO.Path]::GetFullPath($BackupSetPath).TrimEnd('\', '/')
    $relativePaths = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $BackupSetPath -File -Recurse -ErrorAction Stop)) {
        $relativePath = $file.FullName.Substring($backupRoot.Length).TrimStart('\', '/')
        if ($relativePath.StartsWith("_app\", [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        $relativePaths += $relativePath
    }
    return @($relativePaths | Sort-Object -Unique)
}

function Write-PatchMarker {
    param(
        [string]$ResourcesPath,
        [hashtable]$Paths,
        [string]$Lang,
        [string]$Mode
    )

    if (-not $script:CurrentBackupSetPath) {
        throw "无法写入 marker：本次安装没有备份集。"
    }
    $frontendBundleFiles = @(Get-PatchedFrontendBundleRelativePaths $ResourcesPath $Lang)
    if ($frontendBundleFiles.Count -eq 0) {
        throw "无法写入 marker：没有找到已注册中文且带显示名补丁的前端 bundle。"
    }
    $i18nDir = Get-FrontendI18nDirectory $ResourcesPath
    $localeResourceFiles = @(
        (Get-RelativeResourcePath $ResourcesPath (Join-Path $i18nDir "$Lang.json")),
        (Get-RelativeResourcePath $ResourcesPath (Join-Path $i18nDir "statsig\$Lang.json")),
        (Get-RelativeResourcePath $ResourcesPath (Join-Path $ResourcesPath "$Lang.json"))
    )
    $localeResourceLookup = @{}
    foreach ($localeResourceFile in $localeResourceFiles) {
        $localeResourceLookup[[string]$localeResourceFile] = $true
    }
    $modifiedResourceFiles = @(Get-BackedUpResourceRelativePaths $script:CurrentBackupSetPath |
        Where-Object { -not $localeResourceLookup.ContainsKey([string]$_) })
    if ($modifiedResourceFiles.Count -eq 0) {
        throw "无法写入 marker：备份集中没有任何被修改的资源。"
    }
    $marker = [ordered]@{
        schemaVersion = 2
        patchVersion = Get-PatchReleaseVersion
        installedAt = [DateTimeOffset]::UtcNow.ToString("o")
        language = $Lang
        mode = $Mode
        backupSet = Split-Path -Leaf $script:CurrentBackupSetPath
        createdFiles = @($script:InstallTransactionCreatedFiles)
        frontendBundleFiles = $frontendBundleFiles
        frontendBundleFingerprints = @(Get-RelativeFileFingerprints $ResourcesPath $frontendBundleFiles)
        localeResourceFingerprints = @(Get-RelativeFileFingerprints $ResourcesPath $localeResourceFiles)
        modifiedResourceFingerprints = @(Get-RelativeFileFingerprints $ResourcesPath $modifiedResourceFiles)
        appIdentity = Get-ClaudeAppIdentity $Paths
        patchedFingerprint = Get-WindowsMaintenanceFingerprint $Paths
    }
    $path = Get-PatchMarkerPath $ResourcesPath
    $temporaryPath = "$path.tmp-$PID"
    try {
        Save-JsonNoBom $temporaryPath $marker 20
        Move-Item -LiteralPath $temporaryPath -Destination $path -Force
    }
    finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
    Write-Host "  wrote patch marker: $path" -ForegroundColor DarkGray
}

function New-BackupSet {
    param([string]$ResourcesPath)

    if ($script:CurrentBackupSetPath -and (Test-Path $script:CurrentBackupSetPath)) {
        return $script:CurrentBackupSetPath
    }

    $root = Get-BackupRoot $ResourcesPath
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

function Register-InstallCreatedFile {
    param(
        [string]$ResourcesPath,
        [string]$FilePath
    )

    $relative = Get-RelativeResourcePath $ResourcesPath $FilePath
    if (-not $script:InstallTransactionCreatedFiles.Contains($relative)) {
        $script:InstallTransactionCreatedFiles.Add($relative)
    }
}

function Prepare-ManagedResourceFile {
    param(
        [string]$ResourcesPath,
        [string]$FilePath
    )

    if (Test-Path -LiteralPath $FilePath) {
        Backup-ModifiedFile $ResourcesPath $FilePath
    }
    else {
        Register-InstallCreatedFile $ResourcesPath $FilePath
    }
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

function Resolve-MarkerBackupSetPath {
    param(
        [string]$ResourcesPath,
        [object]$Marker
    )

    $name = ([string]$Marker.backupSet).Trim()
    if (-not $name -or [System.IO.Path]::GetFileName($name) -ne $name) {
        throw "marker 中的备份集名称无效。"
    }
    return Join-Path (Get-BackupRoot $ResourcesPath) $name
}

function Restore-BackupSet {
    param(
        [string]$ResourcesPath,
        [string]$BackupSetPath
    )

    if (-not (Test-Path -LiteralPath $BackupSetPath -PathType Container)) {
        throw "marker 指向的备份集不存在: $BackupSetPath"
    }

    Write-Host "  restoring marker backup set: $BackupSetPath" -ForegroundColor DarkGray
    $backupRoot = [System.IO.Path]::GetFullPath($BackupSetPath).TrimEnd('\', '/')
    $files = @(Get-ChildItem -LiteralPath $BackupSetPath -File -Recurse -ErrorAction Stop)
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
    return $true
}

function Remove-CreatedResourceFiles {
    param(
        [string]$ResourcesPath,
        [object[]]$RelativePaths
    )

    $resourceRoot = [System.IO.Path]::GetFullPath($ResourcesPath).TrimEnd('\', '/')
    foreach ($relativeValue in @($RelativePaths)) {
        $relative = [string]$relativeValue
        if (-not $relative) {
            continue
        }
        $target = [System.IO.Path]::GetFullPath((Join-Path $ResourcesPath $relative))
        if (-not $target.StartsWith($resourceRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Host "  [警告] 跳过 marker 中越界的新增文件路径: $relative" -ForegroundColor DarkYellow
            continue
        }
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Force -ErrorAction Stop
            Write-Host "  removed patch-created file: $relative" -ForegroundColor Green
        }
    }
}

function Remove-BackupSetAfterRestore {
    param(
        [string]$ResourcesPath,
        [string]$BackupSetPath
    )

    if (Test-Path -LiteralPath $BackupSetPath) {
        Remove-Item -LiteralPath $BackupSetPath -Recurse -Force
    }
    $root = Get-BackupRoot $ResourcesPath
    if ((Test-Path -LiteralPath $root) -and -not (Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        Remove-Item -LiteralPath $root -Force -ErrorAction SilentlyContinue
    }
}

function Start-InstallTransaction {
    param([string]$ResourcesPath)

    $pendingPath = Get-WindowsPendingRestorePath $ResourcesPath
    if (Test-Path -LiteralPath $pendingPath -PathType Leaf) {
        throw "发现未完成的精确备份恢复状态，拒绝新建安装事务。请先完成卸载/维护续作: $pendingPath"
    }
    $markerPath = Get-PatchMarkerPath $ResourcesPath
    if (Test-Path -LiteralPath $markerPath) {
        throw "安装前仍存在 patch marker，拒绝创建可能跨版本的备份。"
    }
    $orphanedRoot = Get-BackupRoot $ResourcesPath
    if (Test-Path -LiteralPath $orphanedRoot) {
        $orphanedItem = Get-ChildItem -LiteralPath $orphanedRoot -Force -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($orphanedItem) {
            throw "发现没有 marker 的未决备份，可能来自一次未完整回滚；为避免删除唯一恢复源，已停止安装: $orphanedRoot"
        }
        Remove-Item -LiteralPath $orphanedRoot -Force -ErrorAction SilentlyContinue
    }

    $script:CurrentBackupSetPath = $null
    $script:InstallTransactionCreatedFiles = [System.Collections.Generic.List[string]]::new()
    $script:InstallTransactionResourcesPath = $ResourcesPath
    $script:InstallTransactionActive = $true
    $script:LastInstallRollbackSucceeded = $false
    [void](New-BackupSet $ResourcesPath)
}

function Complete-InstallTransaction {
    $script:InstallTransactionActive = $false
    $script:InstallTransactionResourcesPath = $null
    $script:LastInstallRollbackSucceeded = $true
}

function Rollback-InstallTransaction {
    param([string]$ResourcesPath)

    if (-not $script:InstallTransactionActive) {
        $script:LastInstallRollbackSucceeded = $true
        return $true
    }
    Write-Host "  正在自动回滚本次安装..." -ForegroundColor Yellow
    $rollbackSucceeded = $false
    try {
        if (-not $script:CurrentBackupSetPath -or -not (Test-Path -LiteralPath $script:CurrentBackupSetPath -PathType Container)) {
            throw "本次事务的备份集已丢失，无法确认回滚完成。"
        }
        [void](Restore-BackupSet $ResourcesPath $script:CurrentBackupSetPath)
        Remove-CreatedResourceFiles $ResourcesPath @($script:InstallTransactionCreatedFiles)
        Remove-Item -LiteralPath (Get-PatchMarkerPath $ResourcesPath) -Force -ErrorAction SilentlyContinue
        if ($script:CurrentBackupSetPath) {
            Remove-BackupSetAfterRestore $ResourcesPath $script:CurrentBackupSetPath
        }
        $rollbackSucceeded = $true
        Write-Host "  本次文件改动已回滚。" -ForegroundColor Green
    }
    catch {
        Write-Host "  [警告] 自动回滚未完全成功: $($_.Exception.Message)" -ForegroundColor Red
    }
    finally {
        $script:InstallTransactionActive = $false
        $script:InstallTransactionResourcesPath = $null
        if ($rollbackSucceeded) {
            $script:CurrentBackupSetPath = $null
        }
        $script:InstallTransactionCreatedFiles = [System.Collections.Generic.List[string]]::new()
        $script:LastInstallRollbackSucceeded = $rollbackSucceeded
    }
    return $rollbackSucceeded
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

    $i18nDir = Get-FrontendI18nDirectory $ResourcesPath
    $paths = @(
        (Get-ClaudeAppPathFromResources $ResourcesPath),
        $ResourcesPath,
        (Join-Path $ResourcesPath "ion-dist"),
        $i18nDir,
        (Join-Path $i18nDir "statsig"),
        (Join-Path $ResourcesPath "ion-dist\assets")
    )

    $assetsRoot = Join-Path $ResourcesPath "ion-dist\assets"
    if (Test-Path -LiteralPath $assetsRoot -PathType Container) {
        $paths += @(Get-ChildItem -LiteralPath $assetsRoot -Directory -Recurse -ErrorAction SilentlyContinue |
            ForEach-Object { $_.FullName })
    }

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

    $i18nDir = Get-FrontendI18nDirectory $ResourcesPath
    $statsigDir = Join-Path $i18nDir "statsig"
    New-Item -ItemType Directory -Path $i18nDir -Force | Out-Null
    New-Item -ItemType Directory -Path $statsigDir -Force | Out-Null

    $englishPath = Join-Path $i18nDir "en-US.json"
    Require-File $englishPath
    $english = Get-Content -LiteralPath $englishPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $translations = Get-Content -LiteralPath $Pack["Frontend"] -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $english -or -not $translations) {
        throw "Unsupported frontend i18n JSON shape."
    }

    $merged = [ordered]@{}
    $translatedCount = 0
    $fallbackCount = 0
    foreach ($property in $english.PSObject.Properties) {
        $translationProperty = $translations.PSObject.Properties[$property.Name]
        if ($null -ne $translationProperty) {
            $merged[$property.Name] = $translationProperty.Value
            $translatedCount += 1
        }
        else {
            $merged[$property.Name] = $property.Value
            $fallbackCount += 1
        }
    }

    $frontendTarget = Join-Path $i18nDir "$Lang.json"
    Prepare-ManagedResourceFile $ResourcesPath $frontendTarget
    Save-JsonNoBom $frontendTarget $merged 100
    Write-Host "  installed frontend locale $Lang.json ($translatedCount translated, $fallbackCount English fallback): $i18nDir" -ForegroundColor Green

    $desktopTarget = Join-Path $ResourcesPath "$Lang.json"
    Prepare-ManagedResourceFile $ResourcesPath $desktopTarget
    Copy-Item -LiteralPath $Pack["Desktop"] -Destination $desktopTarget -Force
    Write-Host "  installed resources/$Lang.json" -ForegroundColor Green

    $statsigTarget = Join-Path $statsigDir "$Lang.json"
    Prepare-ManagedResourceFile $ResourcesPath $statsigTarget
    Copy-Item -LiteralPath $Pack["Statsig"] -Destination $statsigTarget -Force
    Write-Host "  installed statsig locale $Lang.json" -ForegroundColor Green
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
        $orderedEntries = @(Get-AsarFileEntries $header)
        $targetIndex = -1
        for ($index = 0; $index -lt $orderedEntries.Count; $index++) {
            if ([object]::ReferenceEquals($orderedEntries[$index], $entry)) {
                $targetIndex = $index
                break
            }
        }
        if ($targetIndex -lt 0) {
            throw "Internal patch error: lost ASAR entry for $FilePath."
        }
        for ($index = $targetIndex + 1; $index -lt $orderedEntries.Count; $index++) {
            $other = $orderedEntries[$index]
            if ([int64]$other.offset -ge $targetOffset) {
                # Empty ASAR entries can share the following file's offset;
                # header order determines which later entries must move.
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

    $jsFiles = @(Get-FrontendJavaScriptFiles $ResourcesPath)
    $changed = 0
    $already = 0
    $candidates = 0
    foreach ($file in $jsFiles) {
        $text = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
        $result = Update-LanguageArraysInText $text $Lang
        $candidates += [int]$result["CandidateCount"]
        $already += [int]$result["AlreadyCount"]
        if ([int]$result["ChangedCount"] -gt 0) {
            Backup-ModifiedFile $ResourcesPath $file.FullName
            [System.IO.File]::WriteAllText($file.FullName, [string]$result["Text"], $Utf8NoBom)
            Write-Host "  patched language whitelist for ${Lang}: $($file.Name)" -ForegroundColor Green
            $changed += [int]$result["ChangedCount"]
        }
    }

    if ($candidates -eq 0) {
        throw "未能注册中文语言，Claude 前端 bundle 格式可能已经变化。"
    }
    if ($changed -eq 0 -and $already -gt 0) {
        Write-Host "  $Lang already registered in upstream language list" -ForegroundColor Green
    }
}

function Patch-LanguageDisplayNames {
    param([string]$ResourcesPath)

    $jsFiles = @(Get-FrontendJavaScriptFiles $ResourcesPath)

    $marker = "__claudeZhLabelPatch"
    $patch = ';(()=>{const e=Intl.DisplayNames&&Intl.DisplayNames.prototype;if(!e||e.__claudeZhLabelPatch)return;const n=e.of;e.of=function(e){const t=String(e);return t==="zh-CN"?"简体中文":t==="zh-HK"?"繁体中文（中国香港）":t==="zh-TW"?"繁体中文（中国台湾）":n.call(this,e)},Object.defineProperty(e,"__claudeZhLabelPatch",{value:!0})})();'
    $patchedFiles = 0
    foreach ($file in $jsFiles) {
        $text = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
        $languageArrays = Update-LanguageArraysInText $text $LanguageCode
        if ([int]$languageArrays["CandidateCount"] -eq 0) {
            continue
        }
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

    $jsFiles = @(Get-FrontendJavaScriptFiles $ResourcesPath)
    foreach ($file in $jsFiles) {
        $text = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
        $updated = $text
        $changed = $false
        foreach ($lang in @("zh-CN", "zh-TW", "zh-HK")) {
            $pattern = '(?<separator>\s*,\s*)["'']' + [System.Text.RegularExpressions.Regex]::Escape($lang) + '["'']'
            $next = [System.Text.RegularExpressions.Regex]::Replace($updated, $pattern, '')
            if ($next -ne $updated) {
                $updated = $next
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

    $enPath = Join-Path (Get-FrontendI18nDirectory $ResourcesPath) "en-US.json"
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
    } else {
        $selectedText = "已選擇 `$1 項"
        $deleteSelectedText = "刪除 `$1 個所選項目"
        $updatedMinuteText = "`$1 分鐘前更新"
        $updatedHourText = "`$1 小時前更新"
        $updatedDayText = "`$1 天前更新"
        $updatedWeekText = "`$1 週前更新"
        $updatedMonthText = "`$1 個月前更新"
        $updatedYearText = "`$1 年前更新"
    }
    $selectedTextJson = $selectedText | ConvertTo-Json -Compress
    $deleteSelectedTextJson = $deleteSelectedText | ConvertTo-Json -Compress
    $updatedMinuteTextJson = $updatedMinuteText | ConvertTo-Json -Compress
    $updatedHourTextJson = $updatedHourText | ConvertTo-Json -Compress
    $updatedDayTextJson = $updatedDayText | ConvertTo-Json -Compress
    $updatedWeekTextJson = $updatedWeekText | ConvertTo-Json -Compress
    $updatedMonthTextJson = $updatedMonthText | ConvertTo-Json -Compress
    $updatedYearTextJson = $updatedYearText | ConvertTo-Json -Compress
    $template = @'
(()=>{try{
const L=__LANGUAGE__,M=__MAPPING__,ST=__SELECTED_TEXT__,DST=__DELETE_SELECTED_TEXT__,UMI=__UPDATED_MINUTE_TEXT__,UH=__UPDATED_HOUR_TEXT__,UD=__UPDATED_DAY_TEXT__,UW=__UPDATED_WEEK_TEXT__,UMO=__UPDATED_MONTH_TEXT__,UY=__UPDATED_YEAR_TEXT__;
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
[/^Mon$/,"周一"],[/^Tue$/,"周二"],[/^Wed$/,"周三"],[/^Thu$/,"周四"],[/^Fri$/,"周五"],[/^Sat$/,"周六"],[/^Sun$/,"周日"]
];
const R=s=>{const n=N(s);if(M[n])return M[n];for(const [r,t] of G){const m=n.match(r);if(m)return t.replace("$1",m[1])}};
const X=new Set(["SCRIPT","STYLE","NOSCRIPT"]);
function T(){try{const b=document.body||document.documentElement;if(!b)return;const w=document.createTreeWalker(b,NodeFilter.SHOW_TEXT,{acceptNode(n){const p=n.parentElement;if(!p||X.has(p.tagName)||!R(n.nodeValue))return NodeFilter.FILTER_REJECT;return NodeFilter.FILTER_ACCEPT}});let n;while(n=w.nextNode()){const v=R(n.nodeValue);if(v)n.nodeValue=v}document.querySelectorAll("[role=dialog] p,[role=dialog] div,[role=dialog] span").forEach(e=>{try{if(e.closest("button,[contenteditable]"))return;const t=R(e.textContent);if(t&&N(e.textContent)!==N(t))e.textContent=t}catch{}});document.querySelectorAll("[aria-label],[title],[placeholder],input,textarea").forEach(e=>{["aria-label","title","placeholder","value"].forEach(a=>{try{if(a==="value"&&!(e.matches("input[type=button],input[type=submit]")))return;let v=e.getAttribute?e.getAttribute(a):void 0;if(v==null&&a in e)v=e[a];const t=R(v);if(t){if(e.setAttribute)e.setAttribute(a,t);try{if(a in e)e[a]=t}catch{}}}catch{}})});document.querySelectorAll("a").forEach(e=>{try{const r=e.getBoundingClientRect(),txt=N(e.textContent);if(txt==="Claude"&&r.left<100&&r.top<100)e.style.visibility="hidden"}catch{}})}catch{}}
T();
new MutationObserver(()=>{clearTimeout(window.__claudeZhDomTimer);window.__claudeZhDomTimer=setTimeout(T,30)}).observe(document.documentElement,{subtree:true,childList:true,characterData:true,attributes:true});
}catch(e){}})()
'@
    return $template.Replace("__LANGUAGE__", $languageJson).Replace("__MAPPING__", $mappingJson).Replace("__SELECTED_TEXT__", $selectedTextJson).Replace("__DELETE_SELECTED_TEXT__", $deleteSelectedTextJson).Replace("__UPDATED_MINUTE_TEXT__", $updatedMinuteTextJson).Replace("__UPDATED_HOUR_TEXT__", $updatedHourTextJson).Replace("__UPDATED_DAY_TEXT__", $updatedDayTextJson).Replace("__UPDATED_WEEK_TEXT__", $updatedWeekTextJson).Replace("__UPDATED_MONTH_TEXT__", $updatedMonthTextJson).Replace("__UPDATED_YEAR_TEXT__", $updatedYearTextJson)
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
    $handlerEnding = if ($markerIndex -ge 3) { $Text.Substring($markerIndex - 3, 3) } else { "" }
    if (($executeIndex -lt $bodyStart) -or (($handlerEnding -ne "});") -and ($handlerEnding -ne "}),"))) {
        Write-Host "  [警告] 找到旧补丁标记，但旧注入结构不符合预期；将保留原内容继续。" -ForegroundColor DarkYellow
        return @{ Text = $Text; Removed = $false }
    }

    $body = $Text.Substring($bodyStart, $executeIndex - $bodyStart)
    $terminator = $handlerEnding.Substring(2, 1)
    $replacement = $receiver + '.webContents.on("dom-ready",()=>{' + $body + '})' + $terminator
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
    $eventAnchor = '.webContents.on("dom-ready",()=>{'
    $handlerCloseNeedle = "})"

    if (-not $Quiet) {
        Write-Host "  [进度] 正在快速扫描 dom-ready handler..." -ForegroundColor DarkGray
    }
    $searchIndex = 0
    $checked = 0
    while ($true) {
        $anchorIndex = $Text.IndexOf($eventAnchor, $searchIndex, [System.StringComparison]::Ordinal)
        if ($anchorIndex -lt 0) {
            if (-not $Quiet) {
                Write-Host "  [进度] 已扫描 $checked 个 dom-ready handler，未找到 main_view_dom_ready handler，准备尝试 legacy 注入点..." -ForegroundColor DarkGray
            }
            return @{ Success = $false }
        }
        $checked += 1

        $bodyStart = $anchorIndex + $eventAnchor.Length
        $handlerClose = $Text.IndexOf($handlerCloseNeedle, $bodyStart, [System.StringComparison]::Ordinal)
        if ($handlerClose -lt $bodyStart) {
            if (-not $Quiet) {
                Write-Host "  [进度] 第 $checked 个 dom-ready handler 结束位置异常，继续查找下一个..." -ForegroundColor DarkGray
            }
            $searchIndex = $bodyStart
            continue
        }

        $body = $Text.Substring($bodyStart, $handlerClose - $bodyStart).TrimEnd(";")
        $terminatorIndex = $handlerClose + $handlerCloseNeedle.Length
        if (($body.Contains("{")) -or ($body.Contains("}")) -or ($terminatorIndex -ge $Text.Length)) {
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
        if (-not $body.Contains($readyNeedle)) {
            $searchIndex = $terminatorIndex + 1
            continue
        }

        if (-not $Quiet) {
            Write-Host "  [进度] 已找到包含 main_view_dom_ready 的 dom-ready handler，正在识别 webContents 变量..." -ForegroundColor DarkGray
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
        if (-not $Quiet) {
            Write-Host "  [进度] 在线 DOM 注入点定位完成：handler=$checked, receiver=$receiver。" -ForegroundColor DarkGray
        }
        return @{
            Success = $true
            Index = $receiverStart
            Length = $hookLength
            Receiver = $receiver
            Body = $body
            Terminator = $terminator
        }
    }
}

function Resolve-MainProcessAsarTarget {
    param(
        [byte[]]$Data,
        [int]$HeaderSize,
        [object]$Header
    )

    $markerMatches = [System.Collections.Generic.List[string]]::new()
    $hookMatches = [System.Collections.Generic.List[string]]::new()
    $legacyMatches = [System.Collections.Generic.List[string]]::new()
    $fallbackExists = $false

    foreach ($item in Get-AsarFilePathEntries $Header) {
        $filePath = [string]$item.Path
        if ($filePath -eq $AsarPatchTargetFallback) {
            $fallbackExists = $true
        }
        if ((-not $filePath.StartsWith(".vite/build/", [System.StringComparison]::Ordinal)) -or (-not $filePath.EndsWith(".js", [System.StringComparison]::Ordinal))) {
            continue
        }

        $content = Get-AsarEntryContent $Data $HeaderSize $item.Entry $filePath
        $text = [System.Text.Encoding]::UTF8.GetString($content)
        if ($text.Contains($OnlineLocaleMainMarker)) {
            $markerMatches.Add($filePath)
            continue
        }
        if ($text.Contains("main_view_dom_ready") -and $text.Contains('.webContents.on("dom-ready",()=>{')) {
            $hookMatch = Find-OnlineDomTranslationHook $text -Quiet
            if ($hookMatch["Success"]) {
                $hookMatches.Add($filePath)
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

    if ($hookMatches.Count -eq 1) {
        Write-Host "  selected main-process ASAR bundle: $($hookMatches[0])" -ForegroundColor DarkGray
        return $hookMatches[0]
    }
    if ($hookMatches.Count -gt 1) {
        throw "Could not select main-process app.asar bundle: multiple main_view_dom_ready handlers found: $($hookMatches -join ', ')"
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
        $injectedBody = $body + ";" + $receiver + ".webContents.executeJavaScript(" + $scriptLiteral + ").catch(()=>{})"
        $injection = $receiver + '.webContents.on("dom-ready",()=>{' + $injectedBody + '})' + $terminator + '/*' + $OnlineLocaleMainMarker + '*/'
        if ($text.Contains($injection)) {
            Write-Host "  online claude.ai DOM translation already patched" -ForegroundColor Green
            return
        }

        Write-Host "  injecting online DOM translation hook" -ForegroundColor DarkGray
        $hookIndex = [int]$hookMatch["Index"]
        $hookLength = [int]$hookMatch["Length"]
        $patched = $text.Substring(0, $hookIndex) + $injection + $text.Substring($hookIndex + $hookLength)
        $patchedContent = [System.Text.Encoding]::UTF8.GetBytes($patched)
        [void](Replace-AsarFileContent $ResourcesPath $asarTarget $patchedContent)
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
    [void](Replace-AsarFileContent $ResourcesPath $asarTarget $patchedContent)
    $action = if ($hadExisting) { "refreshed" } else { "patched" }
    Write-Host "  $action online claude.ai DOM translation: $($mapping.Count) strings" -ForegroundColor Green
}

function Patch-HardcodedFrontendStrings {
    param(
        [string]$ResourcesPath,
        [string]$Language
    )

    $jsFiles = @(Get-FrontendJavaScriptFiles $ResourcesPath)

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

function Get-WindowsMaintenanceRoot {
    $programData = [Environment]::GetFolderPath('CommonApplicationData')
    if (-not $programData) {
        throw "无法定位 ProgramData，不能安装自动维护任务。"
    }
    return Join-Path $programData "ClaudeDesktopZhCn"
}

function Get-WindowsMaintenanceTaskName {
    return "ClaudeDesktopZhCnMaintain"
}

function Test-PathIsReparsePoint {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }
    $item = Get-Item -LiteralPath $Path -Force
    return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Set-WindowsMaintenanceAcl {
    param([string]$Root)

    if (Test-PathIsReparsePoint $Root) {
        throw "拒绝使用 reparse point 作为维护目录: $Root"
    }
    $acl = [System.Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    foreach ($sidValue in @("S-1-5-18", "S-1-5-32-544")) {
        $sid = [System.Security.Principal.SecurityIdentifier]::new($sidValue)
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $sid,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            $propagation,
            $allow
        )
        [void]$acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Root -AclObject $acl
}

function Disable-WindowsMaintenanceTask {
    try {
        $taskName = Get-WindowsMaintenanceTaskName
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($task) {
            Disable-ScheduledTask -TaskName $taskName -ErrorAction Stop | Out-Null
        }
    }
    catch {
        Write-Host "  [警告] 无法禁用自动维护任务: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

function Test-WindowsMaintenanceTaskEnabled {
    try {
        $task = Get-ScheduledTask -TaskName (Get-WindowsMaintenanceTaskName) -ErrorAction SilentlyContinue
        return [bool]($task -and [string]$task.State -ne "Disabled")
    }
    catch {
        return $false
    }
}

function Enable-WindowsMaintenanceTask {
    try {
        $taskName = Get-WindowsMaintenanceTaskName
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($task) {
            Enable-ScheduledTask -TaskName $taskName -ErrorAction Stop | Out-Null
        }
    }
    catch {
        Write-Host "  [警告] 无法重新启用原自动维护任务: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

function Remove-WindowsMaintenanceTask {
    try {
        $taskName = Get-WindowsMaintenanceTaskName
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($task) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
            Write-Host "  removed maintenance task: $taskName" -ForegroundColor Green
        }
    }
    catch {
        Write-Host "  [警告] 无法删除自动维护任务: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

function Install-WindowsMaintenanceTask {
    param(
        [string]$Language,
        [string]$Mode
    )

    if ($script:IsMaintenanceRun) {
        return
    }

    $root = Get-WindowsMaintenanceRoot
    if ((Test-Path -LiteralPath $root) -and (Test-PathIsReparsePoint $root)) {
        throw "拒绝覆盖 reparse point 维护目录: $root"
    }
    Disable-WindowsMaintenanceTask
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    Set-WindowsMaintenanceAcl $root

    $payloadRoot = Join-Path $root "payload"
    $payloadScripts = Join-Path $payloadRoot "scripts"
    $payloadResources = Join-Path $payloadRoot "resources"
    New-Item -ItemType Directory -Path $payloadScripts -Force | Out-Null
    New-Item -ItemType Directory -Path $payloadResources -Force | Out-Null

    $sourceScript = Join-Path $PSScriptRoot "install_windows.ps1"
    $sourceProject = Split-Path -Parent (Split-Path -Parent $sourceScript)
    $sourceResources = Join-Path $sourceProject "resources"
    Require-File $sourceScript
    if (-not (Test-Path -LiteralPath $sourceResources -PathType Container)) {
        throw "缺少维护 payload resources: $sourceResources"
    }
    Copy-Item -LiteralPath $sourceScript -Destination (Join-Path $payloadScripts "install_windows.ps1") -Force
    Copy-Item -Path (Join-Path $sourceResources "*") -Destination $payloadResources -Recurse -Force

    $targetUserSid = if ($env:CLAUDE_ZH_ORIGINAL_USER_SID) {
        [string]$env:CLAUDE_ZH_ORIGINAL_USER_SID
    } else {
        [string]([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    }
    $targetUserProfile = if ($env:CLAUDE_ZH_ORIGINAL_USER_PROFILE) { [string]$env:CLAUDE_ZH_ORIGINAL_USER_PROFILE } else { [string]$env:USERPROFILE }
    $targetAppData = if ($env:CLAUDE_ZH_ORIGINAL_APPDATA) { [string]$env:CLAUDE_ZH_ORIGINAL_APPDATA } else { [string]$env:APPDATA }
    $targetLocalAppData = if ($env:CLAUDE_ZH_ORIGINAL_LOCALAPPDATA) { [string]$env:CLAUDE_ZH_ORIGINAL_LOCALAPPDATA } else { [string]$env:LOCALAPPDATA }
    $config = [ordered]@{
        schemaVersion = 1
        language = $Language
        patchMode = $Mode
        originalUserSid = $targetUserSid
        originalUserProfile = $targetUserProfile
        originalAppData = $targetAppData
        originalLocalAppData = $targetLocalAppData
        installedAt = [DateTimeOffset]::UtcNow.ToString("o")
    }
    Save-JsonNoBom (Join-Path $root "config.json") $config 10
    Set-WindowsMaintenanceAcl $root

    $powershellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    Require-File $powershellExe
    $payloadScript = Join-Path $payloadScripts "install_windows.ps1"
    $arguments = "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$payloadScript`" -Action maintain"
    $action = New-ScheduledTaskAction -Execute $powershellExe -Argument $arguments
    $startupTrigger = New-ScheduledTaskTrigger -AtStartup
    $repeatTrigger = New-ScheduledTaskTrigger `
        -Once `
        -At (Get-Date).AddMinutes(10) `
        -RepetitionInterval (New-TimeSpan -Minutes 15) `
        -RepetitionDuration (New-TimeSpan -Days 3650)
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet `
        -MultipleInstances IgnoreNew `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 15) `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries
    $task = New-ScheduledTask `
        -Action $action `
        -Trigger @($startupTrigger, $repeatTrigger) `
        -Principal $principal `
        -Settings $settings `
        -Description "Reapply Claude Desktop Chinese resources after an official app update."
    Register-ScheduledTask -TaskName (Get-WindowsMaintenanceTaskName) -InputObject $task -Force | Out-Null
    Write-Host "  installed automatic maintenance task (ProgramData payload, SYSTEM/admin-only)" -ForegroundColor Green
}

function Get-WindowsMaintenanceCriticalPaths {
    param([hashtable]$Paths)

    $exePath = Get-ClaudeExePath ([string]$Paths["App"])
    if (-not $exePath) {
        throw "Claude.exe 尚未准备完成。"
    }
    $asarPath = Join-Path ([string]$Paths["Resources"]) "app.asar"
    Require-File $exePath
    Require-File $asarPath

    $i18nDir = Get-FrontendI18nDirectory ([string]$Paths["Resources"])
    $englishPath = Join-Path $i18nDir "en-US.json"
    Require-File $englishPath
    $javascriptFiles = @(Get-FrontendJavaScriptFiles ([string]$Paths["Resources"]))
    if ($javascriptFiles.Count -eq 0) {
        throw "前端 JavaScript bundle 尚未准备完成。"
    }

    $criticalPaths = @($exePath, $asarPath, $englishPath)
    $criticalPaths += @($javascriptFiles | ForEach-Object { $_.FullName })
    return @($criticalPaths | Where-Object { $_ } | Sort-Object -Unique)
}

function Test-WindowsMaintenanceReady {
    param([hashtable]$Paths)

    if (@(Get-ClaudeDesktopProcesses).Count -gt 0 -or @(Get-ClaudeCoworkProcesses).Count -gt 0) {
        Write-Host "  Claude 正在运行，维护任务延后。" -ForegroundColor DarkYellow
        return $false
    }
    try {
        $criticalPaths = @(Get-WindowsMaintenanceCriticalPaths $Paths)
    }
    catch {
        Write-Host "  Claude 更新资源尚未准备完成，维护任务延后: $($_.Exception.Message)" -ForegroundColor DarkYellow
        return $false
    }

    $cutoff = (Get-Date).ToUniversalTime().AddSeconds(-$WindowsMaintenanceSettleSeconds)
    foreach ($criticalPath in $criticalPaths) {
        if (-not (Test-Path -LiteralPath $criticalPath -PathType Leaf)) {
            Write-Host "  Claude 更新文件尚未出现，维护任务延后: $criticalPath" -ForegroundColor DarkYellow
            return $false
        }
        $item = Get-Item -LiteralPath $criticalPath
        if ($item.LastWriteTimeUtc -gt $cutoff -or $item.CreationTimeUtc -gt $cutoff) {
            Write-Host "  Claude 更新文件仍可能写入中，维护任务延后: $criticalPath" -ForegroundColor DarkYellow
            return $false
        }
    }
    return $true
}

function Get-WindowsMaintenanceFingerprint {
    param([hashtable]$Paths)

    $discoveryError = ""
    try {
        $criticalPaths = @(Get-WindowsMaintenanceCriticalPaths $Paths)
    }
    catch {
        $discoveryError = $_.Exception.Message
        $criticalPaths = @(
            (Get-ClaudeExePath ([string]$Paths["App"])),
            (Join-Path ([string]$Paths["Resources"]) "app.asar")
        )
    }

    $files = @()
    $javascriptCount = 0
    $javascriptTotalLength = [int64]0
    $javascriptNewestWriteTicks = [int64]0
    $javascriptNewestCreationTicks = [int64]0
    foreach ($path in @($criticalPaths | Where-Object { $_ } | Sort-Object -Unique)) {
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            $item = Get-Item -LiteralPath $path
            if ($item.Extension -ieq ".js") {
                $javascriptCount += 1
                $javascriptTotalLength += [int64]$item.Length
                $javascriptNewestWriteTicks = [Math]::Max($javascriptNewestWriteTicks, [int64]$item.LastWriteTimeUtc.Ticks)
                $javascriptNewestCreationTicks = [Math]::Max($javascriptNewestCreationTicks, [int64]$item.CreationTimeUtc.Ticks)
                continue
            }
            $files += [ordered]@{
                path = [System.IO.Path]::GetFullPath($path)
                length = [int64]$item.Length
                lastWriteTimeUtcTicks = [int64]$item.LastWriteTimeUtc.Ticks
                creationTimeUtcTicks = [int64]$item.CreationTimeUtc.Ticks
                prefixSha256 = Get-FilePrefixSha256Hex $path
            }
        }
    }
    return [ordered]@{
        appIdentity = Get-ClaudeAppIdentity $Paths
        discoveryError = $discoveryError
        files = $files
        frontendJavaScript = [ordered]@{
            count = $javascriptCount
            totalLength = $javascriptTotalLength
            newestWriteTimeUtcTicks = $javascriptNewestWriteTicks
            newestCreationTimeUtcTicks = $javascriptNewestCreationTicks
        }
    }
}

function Test-PatchMarkerMatchesFingerprint {
    param(
        [object]$Marker,
        [hashtable]$Paths
    )

    if (-not $Marker -or -not $Marker.patchedFingerprint) {
        return $false
    }
    try {
        $recordedFingerprint = $Marker.patchedFingerprint | ConvertTo-Json -Compress -Depth 30
        $currentFingerprint = Get-WindowsMaintenanceFingerprint $Paths | ConvertTo-Json -Compress -Depth 30
        if ($recordedFingerprint -ne $currentFingerprint) {
            return $false
        }
        $bundleFiles = @($Marker.frontendBundleFiles)
        $recordedBundles = @($Marker.frontendBundleFingerprints)
        if ($bundleFiles.Count -eq 0 -or $recordedBundles.Count -eq 0) {
            return $false
        }
        $currentBundles = @(Get-RelativeFileFingerprints ([string]$Paths["Resources"]) $bundleFiles)
        $recordedBundleJson = $recordedBundles | ConvertTo-Json -Compress -Depth 10
        $currentBundleJson = $currentBundles | ConvertTo-Json -Compress -Depth 10
        if ($recordedBundleJson -ne $currentBundleJson) {
            return $false
        }
        $recordedModified = @($Marker.modifiedResourceFingerprints)
        if ($recordedModified.Count -eq 0) {
            return $false
        }
        $modifiedFiles = @($recordedModified | ForEach-Object { [string]$_.path })
        $currentModified = @(Get-RelativeFileFingerprints ([string]$Paths["Resources"]) $modifiedFiles)
        $recordedModifiedJson = $recordedModified | ConvertTo-Json -Compress -Depth 10
        $currentModifiedJson = $currentModified | ConvertTo-Json -Compress -Depth 10
        return $recordedModifiedJson -eq $currentModifiedJson
    }
    catch {
        return $false
    }
}

function Test-WindowsPatchCurrent {
    param(
        [object]$Marker,
        [hashtable]$Paths,
        [string]$Language,
        [string]$Mode
    )

    if (-not $Marker -or [int]$Marker.schemaVersion -ne 2) {
        return $false
    }
    if ([string]$Marker.patchVersion -ne (Get-PatchReleaseVersion) -or
        [string]$Marker.language -ne $Language -or
        [string]$Marker.mode -ne $Mode -or
        -not (Test-PatchMarkerMatchesIdentity $Marker $Paths) -or
        -not (Test-PatchMarkerMatchesFingerprint $Marker $Paths)) {
        return $false
    }

    try {
        $resourcesPath = [string]$Paths["Resources"]
        $backupSetPath = Resolve-MarkerBackupSetPath $resourcesPath $Marker
        if (-not (Test-Path -LiteralPath $backupSetPath -PathType Container)) {
            return $false
        }
        $frontendBundleFiles = @($Marker.frontendBundleFiles)
        if ($frontendBundleFiles.Count -eq 0) {
            return $false
        }
        $i18nDir = Get-FrontendI18nDirectory $resourcesPath
        $requiredLocales = @(
            (Join-Path $i18nDir "$Language.json"),
            (Join-Path $i18nDir "statsig\$Language.json"),
            (Join-Path $resourcesPath "$Language.json")
        )
        foreach ($localePath in $requiredLocales) {
            if (-not (Test-Path -LiteralPath $localePath -PathType Leaf)) {
                return $false
            }
            $locale = Get-Content -LiteralPath $localePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not $locale -or $locale.PSObject.Properties.Count -eq 0) {
                return $false
            }
        }
        $recordedLocaleFingerprints = @($Marker.localeResourceFingerprints)
        if ($recordedLocaleFingerprints.Count -ne $requiredLocales.Count) {
            return $false
        }
        $recordedLocaleFiles = @($recordedLocaleFingerprints | ForEach-Object { [string]$_.path })
        $currentLocaleFingerprints = @(Get-RelativeFileFingerprints $resourcesPath $recordedLocaleFiles)
        $recordedLocaleJson = $recordedLocaleFingerprints | ConvertTo-Json -Compress -Depth 10
        $currentLocaleJson = $currentLocaleFingerprints | ConvertTo-Json -Compress -Depth 10
        if ($recordedLocaleJson -ne $currentLocaleJson) {
            return $false
        }

        $registered = $false
        $displayNamePatched = $false
        $resourceRoot = [System.IO.Path]::GetFullPath($resourcesPath).TrimEnd('\', '/')
        foreach ($relativeValue in $frontendBundleFiles) {
            $relativePath = [string]$relativeValue
            $bundlePath = [System.IO.Path]::GetFullPath((Join-Path $resourcesPath $relativePath))
            if (-not $bundlePath.StartsWith($resourceRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -or
                -not (Test-Path -LiteralPath $bundlePath -PathType Leaf)) {
                return $false
            }
            $text = [System.IO.File]::ReadAllText($bundlePath, [System.Text.Encoding]::UTF8)
            $languageArrays = Update-LanguageArraysInText $text $Language
            if ([int]$languageArrays["AlreadyCount"] -gt 0) {
                $registered = $true
                if ($text.Contains("__claudeZhLabelPatch")) {
                    $displayNamePatched = $true
                }
            }
        }
        return ($registered -and $displayNamePatched)
    }
    catch {
        return $false
    }
}

function Read-WindowsPendingRestore {
    param([string]$ResourcesPath)

    $path = Get-WindowsPendingRestorePath $ResourcesPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    try {
        $pending = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $pending -or [int]$pending.schemaVersion -ne 1 -or -not $pending.marker) {
            throw "pending restore 缺少 schemaVersion/marker"
        }
        if (-not ([string]$pending.resourcesPath).Trim()) {
            throw "pending restore 缺少 resourcesPath"
        }
        if (-not ([string]$pending.marker.backupSet).Trim()) {
            throw "pending restore marker 缺少 backupSet"
        }
        return $pending
    }
    catch {
        Write-Host "  [警告] 待续作恢复状态无效，将忽略: $path ($($_.Exception.Message))" -ForegroundColor DarkYellow
        return $null
    }
}

function Write-WindowsPendingRestore {
    param(
        [string]$ResourcesPath,
        [object]$Marker,
        [hashtable]$Paths
    )

    if (-not $Marker -or -not ([string]$Marker.backupSet).Trim()) {
        throw "无法写入待续作恢复状态：marker 缺少 backupSet。"
    }
    $backupSetPath = Resolve-MarkerBackupSetPath $ResourcesPath $Marker
    if (-not (Test-Path -LiteralPath $backupSetPath -PathType Container)) {
        throw "无法写入待续作恢复状态：备份集不存在: $backupSetPath"
    }

    $pending = [ordered]@{
        schemaVersion = 1
        createdAt = [DateTimeOffset]::UtcNow.ToString("o")
        resourcesPath = [System.IO.Path]::GetFullPath($ResourcesPath)
        appPath = [System.IO.Path]::GetFullPath([string]$Paths["App"])
        marker = $Marker
    }
    $path = Get-WindowsPendingRestorePath $ResourcesPath
    $temporaryPath = "$path.tmp-$PID"
    try {
        Save-JsonNoBom $temporaryPath $pending 30
        Move-Item -LiteralPath $temporaryPath -Destination $path -Force
    }
    finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
    Write-Host "  wrote resumable restore state: $path" -ForegroundColor DarkGray
}

function Clear-WindowsPendingRestore {
    param([string]$ResourcesPath)

    $path = Get-WindowsPendingRestorePath $ResourcesPath
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        Write-Host "  cleared resumable restore state: $path" -ForegroundColor DarkGray
    }
}

function Test-WindowsPendingRestoreMatchesCurrentApp {
    param(
        [object]$Pending,
        [hashtable]$Paths
    )

    if (-not $Pending -or [int]$Pending.schemaVersion -ne 1 -or -not $Pending.marker) {
        return $false
    }
    $resourcesPath = [System.IO.Path]::GetFullPath([string]$Paths["Resources"]).TrimEnd('\', '/')
    $recordedResourcesPath = [System.IO.Path]::GetFullPath([string]$Pending.resourcesPath).TrimEnd('\', '/')
    if (-not $resourcesPath.Equals($recordedResourcesPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    $current = Get-ClaudeAppIdentity $Paths
    $recorded = $Pending.marker.appIdentity
    if (-not $recorded) {
        return $false
    }
    # Identity-only match: half-restored trees intentionally fail patched fingerprint checks.
    foreach ($propertyName in @("appPath", "installKind", "fileVersion", "productVersion")) {
        $expected = [string]$recorded.$propertyName
        $actual = [string]$current.$propertyName
        if ($propertyName -eq "appPath") {
            if (-not $expected -or -not $actual.Equals($expected, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $false
            }
        }
        elseif ($expected -and $actual -and $expected -ne $actual) {
            return $false
        }
    }
    try {
        $backupSetPath = Resolve-MarkerBackupSetPath $resourcesPath $Pending.marker
        return Test-Path -LiteralPath $backupSetPath -PathType Container
    }
    catch {
        return $false
    }
}

function Invoke-WindowsPendingRestore {
    param(
        [object]$Pending,
        [hashtable]$Paths
    )

    if (-not (Test-WindowsPendingRestoreMatchesCurrentApp $Pending $Paths)) {
        throw "待续作恢复状态与当前 Claude build 不匹配。"
    }
    $resourcesPath = [string]$Paths["Resources"]
    $marker = $Pending.marker
    $backupSetPath = Resolve-MarkerBackupSetPath $resourcesPath $marker
    Write-Step "[恢复 1/3] 续作当前 build 的精确原版备份"
    [void](Restore-BackupSet $resourcesPath $backupSetPath)

    Write-Step "[恢复 2/3] 删除仅由补丁创建的资源"
    Remove-CreatedResourceFiles $resourcesPath @($marker.createdFiles)

    Write-Step "[恢复 3/3] 恢复用户语言配置"
    try {
        Set-ClaudeLocale "en-US"
    }
    catch {
        Write-Host "  [警告] 原版文件已恢复，但无法自动写入 en-US 用户配置: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }

    Remove-Item -LiteralPath (Get-PatchMarkerPath $resourcesPath) -Force -ErrorAction SilentlyContinue
    Remove-BackupSetAfterRestore $resourcesPath $backupSetPath
    Clear-WindowsPendingRestore $resourcesPath
    $script:CurrentBackupSetPath = $null
    Write-Host "  当前 build 的官方基线已完整恢复。" -ForegroundColor Green
    return $true
}

function Invoke-WindowsMaintenanceLocked {
    $root = Get-WindowsMaintenanceRoot
    $configPath = Join-Path $root "config.json"
    Require-File $configPath
    $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $maintenanceLanguage = [string]$config.language
    $maintenanceMode = [string]$config.patchMode
    if ($maintenanceLanguage -notin @("zh-CN", "zh-TW", "zh-HK")) {
        throw "维护配置中的语言无效。"
    }
    if ($maintenanceMode -notin @("safe", "official")) {
        throw "维护配置中的补丁模式无效。"
    }

    $env:CLAUDE_ZH_ORIGINAL_USER_SID = [string]$config.originalUserSid
    $env:CLAUDE_ZH_ORIGINAL_USER_PROFILE = [string]$config.originalUserProfile
    $env:CLAUDE_ZH_ORIGINAL_APPDATA = [string]$config.originalAppData
    $env:CLAUDE_ZH_ORIGINAL_LOCALAPPDATA = [string]$config.originalLocalAppData
    $script:LanguageCode = $maintenanceLanguage
    $script:PatchMode = $maintenanceMode
    $script:IsMaintenanceRun = $true

    $paths = Get-ClaudeResourcesPath
    $resourcesPath = [string]$paths["Resources"]
    $markerPath = Get-PatchMarkerPath $resourcesPath
    $existingMarker = $null
    if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
        $existingMarker = Read-PatchMarker $resourcesPath
        if ($existingMarker -and (Test-WindowsPatchCurrent $existingMarker $paths $maintenanceLanguage $maintenanceMode)) {
            # Fully healthy install: drop any stale resume state left behind by a previous crash.
            Clear-WindowsPendingRestore $resourcesPath
            Write-Host "  当前 Claude 版本的汉化状态已完整验证，维护任务无需操作。" -ForegroundColor Green
            return
        }
    }
    if (-not (Test-WindowsMaintenanceReady $paths)) {
        return
    }

    # Resume an interrupted exact restore before any fingerprint-based decisions.
    # A half-restored tree intentionally fails patched fingerprint checks and must
    # not be treated as an official upstream update.
    $pendingRestore = Read-WindowsPendingRestore $resourcesPath
    if ($pendingRestore) {
        if (Test-WindowsPendingRestoreMatchesCurrentApp $pendingRestore $paths) {
            Write-Host "  检测到未完成的精确备份恢复；继续同一份备份，不会误判为官方新版。" -ForegroundColor DarkYellow
            [void](Invoke-WindowsPendingRestore $pendingRestore $paths)
            $existingMarker = $null
        }
        else {
            Write-Host "  待续作恢复状态与当前 Claude build 不匹配（可能官方已更新）；丢弃旧恢复状态与旧备份。" -ForegroundColor DarkYellow
            Clear-WindowsPendingRestore $resourcesPath
            Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath (Get-BackupRoot $resourcesPath) -Recurse -Force -ErrorAction SilentlyContinue
            $existingMarker = $null
        }
    }

    if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
        if (-not $existingMarker) {
            $existingMarker = Read-PatchMarker $resourcesPath
        }
        $exactPatchedBuild = $existingMarker -and
            (Test-PatchMarkerMatchesIdentity $existingMarker $paths) -and
            (Test-PatchMarkerMatchesFingerprint $existingMarker $paths)
        if ($exactPatchedBuild) {
            Write-Host "  当前 build 的部分汉化资源缺失；先从精确 marker 备份恢复官方基线，再完整重装。" -ForegroundColor DarkYellow
            $restored = Uninstall-WindowsLanguagePack -ForReinstall
            if (-not $restored) {
                throw "无法从当前 build 的精确 marker 备份恢复，已停止自动修复。"
            }
        }
        else {
            Write-Host "  marker 的 build 或补丁指纹已变化；不会恢复旧文件，将以当前官方资源为新基线。" -ForegroundColor DarkYellow
            Clear-WindowsPendingRestore $resourcesPath
            Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath (Get-BackupRoot $resourcesPath) -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $failurePath = Join-Path $root "failure.json"
    $fingerprint = Get-WindowsMaintenanceFingerprint $paths
    $fingerprintJson = $fingerprint | ConvertTo-Json -Compress -Depth 20
    if (Test-Path -LiteralPath $failurePath -PathType Leaf) {
        try {
            $previousFailure = Get-Content -LiteralPath $failurePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $previousFingerprintJson = $previousFailure.fingerprint | ConvertTo-Json -Compress -Depth 20
            $samePatchVersion = [string]$previousFailure.patchVersion -eq (Get-PatchReleaseVersion)
            if ($samePatchVersion -and $previousFingerprintJson -eq $fingerprintJson) {
                $failedAt = [DateTimeOffset]::Parse([string]$previousFailure.failedAt).ToUniversalTime()
                $retryAt = $failedAt.AddSeconds($WindowsMaintenanceFailureRetrySeconds)
                if ([DateTimeOffset]::UtcNow -lt $retryAt) {
                    Write-Host "  此 Claude build 最近已安全回滚；六小时退避期内不重复尝试。" -ForegroundColor DarkYellow
                    return
                }
            }
        }
        catch {
            Remove-Item -LiteralPath $failurePath -Force -ErrorAction SilentlyContinue
        }
    }

    try {
        $requestedMode = $script:PatchMode
        $maintenanceInstalled = Install-WindowsLanguagePackWithFallback
        if (-not $maintenanceInstalled) {
            return
        }
        if ($requestedMode -eq "official" -and $script:PatchMode -eq "safe") {
            $config.patchMode = "safe"
            Save-JsonNoBom $configPath $config 10
            Write-Host "  后续自动维护已切换为基础模式。" -ForegroundColor DarkYellow
        }
        Remove-Item -LiteralPath $failurePath -Force -ErrorAction SilentlyContinue
    }
    catch {
        $failedFingerprint = Get-WindowsMaintenanceFingerprint $paths
        $failure = [ordered]@{
            failedAt = [DateTimeOffset]::UtcNow.ToString("o")
            patchVersion = Get-PatchReleaseVersion
            message = $_.Exception.Message
            fingerprint = $failedFingerprint
        }
        Save-JsonNoBom $failurePath $failure 20
        throw
    }
}

function Invoke-WindowsMaintenance {
    $mutex = New-Object System.Threading.Mutex($false, "Global\ClaudeDesktopZhCn-Installer")
    $mutexAcquired = $false
    try {
        try {
            if (-not $mutex.WaitOne(0)) {
                Write-Host "  另一个安装或维护进程正在运行，本次维护延后。" -ForegroundColor DarkYellow
                return
            }
            $mutexAcquired = $true
        }
        catch [System.Threading.AbandonedMutexException] {
            $mutexAcquired = $true
        }
        Invoke-WindowsMaintenanceLocked
    }
    finally {
        if ($mutexAcquired) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}

function Remove-WindowsMaintenancePayload {
    try {
        $root = Get-WindowsMaintenanceRoot
        if (-not (Test-Path -LiteralPath $root)) {
            return
        }
        if (Test-PathIsReparsePoint $root) {
            Write-Host "  [警告] 维护目录是 reparse point，拒绝自动删除: $root" -ForegroundColor DarkYellow
            return
        }
        Remove-Item -LiteralPath $root -Recurse -Force
        Write-Host "  removed maintenance payload: $root" -ForegroundColor Green
    }
    catch {
        Write-Host "  [警告] 无法删除维护 payload: $($_.Exception.Message)" -ForegroundColor DarkYellow
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
    $script:LastInstallRollbackSucceeded = $true

    # 单实例互斥锁：防止多个安装进程并发写入 app.asar
    $mutex = New-Object System.Threading.Mutex($false, "Global\ClaudeDesktopZhCn-Installer")
    $mutexAcquired = $false
    $resourcesPath = $null
    try {
        if (-not $mutex.WaitOne(0)) {
            throw "另一个安装进程正在运行，请等待其完成后再试。"
        }
        $mutexAcquired = $true
    } catch [System.Threading.AbandonedMutexException] {
        # 上一个进程异常退出，锁已释放，继续执行
        $mutexAcquired = $true
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

        Write-Step "[3/8] 查找 Claude Desktop"
        $paths = Get-ClaudeResourcesPath
        $claudePath = $paths["App"]
        $resourcesPath = $paths["Resources"]
        $installKind = $paths["InstallKind"]
        Write-Host "  app: $claudePath" -ForegroundColor Green
        Write-Host "  resources: $resourcesPath" -ForegroundColor Green

        if ($script:IsMaintenanceRun) {
            $staleMarkerPath = Get-PatchMarkerPath $resourcesPath
            if (Test-Path -LiteralPath $staleMarkerPath -PathType Leaf) {
                throw "维护预检后仍存在 patch marker，拒绝覆盖其备份状态。"
            }
        }
        else {
            Write-Step "关闭 Claude Desktop"
            Stop-ClaudeProcesses
        }

        Write-Step "[4/8] 准备写入权限"
        Enable-WriteAccess $resourcesPath
        if (-not $script:IsMaintenanceRun) {
            Remove-LegacyAppxForkArtifacts
        }
        Start-InstallTransaction $resourcesPath

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

        Write-Step "[8/8] 验证并记录当前版本补丁状态"
        Write-PatchMarker $resourcesPath $paths $LanguageCode $PatchMode
        Complete-InstallTransaction

        try {
            Set-ClaudeLocale $LanguageCode
        }
        catch {
            Write-Host "  [警告] 汉化已安装，但无法自动写入用户语言配置: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }

        if (-not $script:IsMaintenanceRun) {
            try {
                Write-Step "重启 Claude Desktop"
                Restart-Claude $claudePath

                Write-Step "启动 CoworkVMService"
                Start-CoworkVMService
            }
            catch {
                Write-Host "  [警告] 汉化已提交，但 Claude/Cowork 自动重启失败，请手动启动: $($_.Exception.Message)" -ForegroundColor DarkYellow
            }
        }

        Write-Host ""
        Write-Host "安装完成。如果界面未立即切换，请在 Language 中选择 $label。" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host ""
        if ($resourcesPath -and $script:InstallTransactionActive) {
            [void](Rollback-InstallTransaction $resourcesPath)
        }
        Write-Host "安装过程中出现错误，本次已备份的文件已尝试自动回滚。" -ForegroundColor Red
        Write-Host "  详细日志: $script:InstallLogPath" -ForegroundColor DarkGray
        if ($script:DetectedMultipleClaudeInstalls) {
            Write-MultipleClaudeFailureHint
        }
        throw
    }
    finally {
        if ($mutexAcquired) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}

function Uninstall-WindowsLanguagePack {
    param([switch]$ForReinstall)

    Write-Host "=== Claude Desktop Windows 中文补丁卸载 ===" -ForegroundColor Cyan

    # Nested calls from maintenance already hold the same named mutex; skip re-acquire.
    $ownsMutex = -not $script:IsMaintenanceRun
    $mutex = $null
    $mutexAcquired = $false
    if ($ownsMutex) {
        $mutex = New-Object System.Threading.Mutex($false, "Global\ClaudeDesktopZhCn-Installer")
        try {
            if (-not $mutex.WaitOne(0)) {
                throw "另一个安装或维护进程正在运行，请等待其完成后再试。"
            }
            $mutexAcquired = $true
        }
        catch [System.Threading.AbandonedMutexException] {
            $mutexAcquired = $true
        }
    }

    try {
        $oldSkipAsarPatch = $SkipAsarPatch
        $SkipAsarPatch = $true
        try {
            $paths = Get-ClaudeResourcesPath
        }
        finally {
            $SkipAsarPatch = $oldSkipAsarPatch
        }
        $resourcesPath = $paths["Resources"]
        $markerPath = Get-PatchMarkerPath $resourcesPath

        # Resume an interrupted exact restore first (identity-only; fingerprint may already be half-restored).
        $pendingRestore = Read-WindowsPendingRestore $resourcesPath
        if ($pendingRestore) {
            if (Test-WindowsPendingRestoreMatchesCurrentApp $pendingRestore $paths) {
                Write-Host "  检测到未完成的精确备份恢复，继续同一份备份..." -ForegroundColor DarkYellow
                Write-Step "关闭 Claude Desktop"
                Stop-ClaudeProcesses
                if (-not $script:IsMaintenanceRun) {
                    Remove-LegacyAppxForkArtifacts
                }
                [void](Invoke-WindowsPendingRestore $pendingRestore $paths)
                Write-Host ""
                Write-Host "卸载完成。请重启 Claude Desktop 使更改生效。" -ForegroundColor Green
                return $true
            }
            Write-Host "  待续作恢复状态与当前 build 不匹配；丢弃过期状态。" -ForegroundColor DarkYellow
            Clear-WindowsPendingRestore $resourcesPath
        }

        if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
            Write-Host "  当前 Claude 版本没有 patch marker；不会恢复任何旧备份。" -ForegroundColor DarkYellow
            if (-not $ForReinstall) {
                Set-ClaudeLocale "en-US"
            }
            return $false
        }

        $marker = Read-PatchMarker $resourcesPath
        if (-not $marker) {
            Write-Host "  marker 无效；为避免跨版本恢复，仅清理无效元数据。" -ForegroundColor DarkYellow
            Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
            Clear-WindowsPendingRestore $resourcesPath
            $invalidBackupRoot = Get-BackupRoot $resourcesPath
            Remove-Item -LiteralPath $invalidBackupRoot -Recurse -Force -ErrorAction SilentlyContinue
            if (-not $ForReinstall) {
                Set-ClaudeLocale "en-US"
            }
            return $false
        }

        if (-not (Test-PatchMarkerMatchesIdentity $marker $paths) -or -not (Test-PatchMarkerMatchesFingerprint $marker $paths)) {
            Write-Host "  marker 对应的 build 或已打补丁文件指纹已变化；为避免降级，不会恢复其旧备份。" -ForegroundColor DarkYellow
            $staleBackup = Resolve-MarkerBackupSetPath $resourcesPath $marker
            Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
            Clear-WindowsPendingRestore $resourcesPath
            Remove-BackupSetAfterRestore $resourcesPath $staleBackup
            if (-not $ForReinstall) {
                Set-ClaudeLocale "en-US"
            }
            return $false
        }

        Write-Step "关闭 Claude Desktop"
        Stop-ClaudeProcesses
        if (-not $script:IsMaintenanceRun) {
            Remove-LegacyAppxForkArtifacts
        }

        # Persist resume state before the first file write so a crash mid-restore is recoverable.
        Write-WindowsPendingRestore $resourcesPath $marker $paths
        $backupSetPath = Resolve-MarkerBackupSetPath $resourcesPath $marker
        Write-Step "[1/3] 恢复本版本备份文件"
        [void](Restore-BackupSet $resourcesPath $backupSetPath)

        Write-Step "[2/3] 删除仅由本次补丁创建的资源"
        Remove-CreatedResourceFiles $resourcesPath @($marker.createdFiles)

        Write-Step "[3/3] 恢复用户语言配置"
        Set-ClaudeLocale "en-US"

        Remove-Item -LiteralPath $markerPath -Force -ErrorAction Stop
        Remove-BackupSetAfterRestore $resourcesPath $backupSetPath
        Clear-WindowsPendingRestore $resourcesPath
        $script:CurrentBackupSetPath = $null

        Write-Host ""
        Write-Host "卸载完成。请重启 Claude Desktop 使更改生效。" -ForegroundColor Green
        return $true
    }
    finally {
        if ($mutexAcquired -and $mutex) {
            $mutex.ReleaseMutex()
        }
        if ($mutex) {
            $mutex.Dispose()
        }
    }
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
    $markerPath = Get-PatchMarkerPath $resourcesPath
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        Write-Host "  当前版本没有 patch marker；不会恢复任何旧备份。" -ForegroundColor DarkYellow
        return
    }

    [void](Uninstall-WindowsLanguagePack -ForReinstall)
}

function Install-WindowsLanguagePackWithFallback {
    try {
        return Install-WindowsLanguagePack
    }
    catch {
        $fullModeError = $_.Exception.Message
        if ($script:PatchMode -ne "official") {
            throw
        }
        if (-not $script:LastInstallRollbackSucceeded) {
            throw "完整模式失败，且本次文件回滚未能完整确认。为保护唯一备份，已停止安装，不会继续基础模式。原错误: $fullModeError"
        }

        Write-Host ""
        Write-Host "  [兼容回退] 完整 app.asar 增强与此 Claude build 不兼容，改用基础汉化模式重试。" -ForegroundColor Yellow
        Write-Host "  [兼容详情] $fullModeError" -ForegroundColor DarkYellow
        $script:PatchMode = "safe"
        try {
            $result = Install-WindowsLanguagePack
            Write-Host "  [兼容回退] 基础汉化安装成功；app.asar 与 Claude.exe 未修改。" -ForegroundColor Green
            return $result
        }
        catch {
            throw "完整模式和基础模式均未通过兼容检查。完整模式: $fullModeError；基础模式: $($_.Exception.Message)"
        }
    }
}

if ($LibraryMode) {
    Stop-InstallLog
    return
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
            $oldMaintenanceEnabled = Test-WindowsMaintenanceTaskEnabled
            Disable-WindowsMaintenanceTask
            try {
                Invoke-PreInstallCleanup
                $installed = Install-WindowsLanguagePackWithFallback
            }
            catch {
                if ($oldMaintenanceEnabled) {
                    Enable-WindowsMaintenanceTask
                }
                throw
            }
            if ($installed) {
                try {
                    Install-WindowsMaintenanceTask $LanguageCode $PatchMode
                }
                catch {
                    Remove-WindowsMaintenanceTask
                    Remove-WindowsMaintenancePayload
                    Write-Host "  [警告] 汉化已安装，但自动维护任务安装失败: $($_.Exception.Message)" -ForegroundColor DarkYellow
                }
            }
        }
        "maintain" { Invoke-WindowsMaintenance }
        "uninstall" {
            Disable-WindowsMaintenanceTask
            try {
                [void](Uninstall-WindowsLanguagePack)
            }
            finally {
                Remove-WindowsMaintenanceTask
                $script:RemoveMaintenancePayloadAfterLog = $true
            }
        }
        "disable-updates" { Set-ClaudeAutoUpdates $false }
        "enable-updates" { Set-ClaudeAutoUpdates $true }
        "sync-skills" { Sync-CCSwitchSkills }
        "unsync-skills" { Unsync-CCSwitchSkills }
    }

    Stop-InstallLog
    if ($script:RemoveMaintenancePayloadAfterLog) {
        Remove-WindowsMaintenancePayload
    }
    exit 0
}
catch {
    Write-Host ""
    Write-Host "[错误] $($_.Exception.Message)" -ForegroundColor Red
    if ($script:InstallLogPath) {
        Write-Host "[错误] 详细日志已写入: $script:InstallLogPath" -ForegroundColor Red
    }
    Stop-InstallLog
    if ($script:RemoveMaintenancePayloadAfterLog) {
        Remove-WindowsMaintenancePayload
    }
    if ($Interactive) {
        [void](Read-Host "安装未完成，按 Enter 退出")
    }
    exit 1
}
