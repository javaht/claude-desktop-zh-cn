param(
    [switch]$Interactive,
    [switch]$SkipAsarPatch,

    [Parameter(Position = 0)]
    [ValidateSet("install", "uninstall")]
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
$script:CurrentBackupSetPath = $null

function Read-InteractiveSelection {
    Write-Host "=== Claude Desktop Windows 中文补丁 ==="
    Write-Host ""
    Write-Host "[1] 安装中文补丁"
    Write-Host "[2] 安装中文补丁（安全模式，跳过 app.asar 补丁）"
    Write-Host "[3] 恢复原样 / 卸载补丁"
    Write-Host "[Q] 退出"
    Write-Host ""

    $skipAsarPatchForInstall = $false
    $actionSelected = $false
    while (-not $actionSelected) {
        $actionSelection = (Read-Host "请选择操作 [1/2/3/Q]").Trim()
        switch -Regex ($actionSelection) {
            '^[1]$' { $skipAsarPatchForInstall = $false; $actionSelected = $true }
            '^[2]$' { $skipAsarPatchForInstall = $true; $actionSelected = $true }
            '^[3]$' { return @{ Action = "uninstall"; Language = "zh-CN"; SkipAsarPatch = $false } }
            '^[Qq]$' { exit 0 }
            default { Write-Host "请输入 1、2、3 或 Q。" -ForegroundColor Yellow }
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
            '^[1]$' { return @{ Action = "install"; Language = "zh-CN"; SkipAsarPatch = $skipAsarPatchForInstall } }
            '^[2]$' { return @{ Action = "install"; Language = "zh-TW"; SkipAsarPatch = $skipAsarPatchForInstall } }
            '^[3]$' { return @{ Action = "install"; Language = "zh-HK"; SkipAsarPatch = $skipAsarPatchForInstall } }
            '^[Qq]$' { exit 0 }
            default { Write-Host "请输入 1、2、3 或 Q。" -ForegroundColor Yellow }
        }
    }
}

if ($Interactive) {
    $interactiveSelection = Read-InteractiveSelection
    $Action = $interactiveSelection.Action
    $Language = $interactiveSelection.Language
    if ($interactiveSelection.SkipAsarPatch) {
        $SkipAsarPatch = $true
    }
}

$LanguageCode = $Language

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

function Get-ClaudeResourcesPath {
    # 优先查找非打包安装（通常版本更新）
    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    if ($localAppData) {
        $unpackagedBase = Join-Path $localAppData "AnthropicClaude"
        if (Test-Path $unpackagedBase) {
            $latest = Get-ChildItem $unpackagedBase -Directory -Filter "app-*" -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1
            if ($latest) {
                $resourcesPath = Join-Path $latest.FullName "resources"
                if (Test-Path $resourcesPath) {
                    return @{
                        App = $latest.FullName
                        Resources = $resourcesPath
                    }
                }
            }
        }
    }

    # 回退到 AppX 查找
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
    }
}

function Get-ClaudeConfigPaths {
    if (-not $env:LOCALAPPDATA) {
        return @()
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

    $configPaths = @()
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

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $root = Get-BackupRoot $ResourcesPath
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
        Sort-Object Name -Descending |
        Select-Object -First 1
    if (-not $backup) {
        Write-Host "  no zh-CN backup found; skipping bundle restore" -ForegroundColor DarkYellow
        return
    }

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

    Require-File $AsarPath
    $data = [System.IO.File]::ReadAllBytes($AsarPath)
    $parsed = Read-AsarHeader $data $AsarPath
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
    $headerHash = Get-AsarHeaderHash $asarPath
    $marker = [System.Text.Encoding]::ASCII.GetBytes('resources\\app.asar","alg":"SHA256","value":"')
    $exeBytes = [System.IO.File]::ReadAllBytes($exePath)
    $matches = Find-BytePattern $exeBytes $marker
    if ($matches.Count -ne 1) {
        throw "Could not find Claude.exe app.asar integrity marker. Claude bundle format may have changed."
    }

    $hashOffset = $matches[0] + $marker.Length
    if (($hashOffset + 64) -gt $exeBytes.Length) {
        throw "Claude.exe app.asar integrity marker has invalid bounds."
    }

    $currentHash = [System.Text.Encoding]::ASCII.GetString($exeBytes, $hashOffset, 64)
    if ($currentHash -eq $headerHash) {
        Write-Host "  Claude.exe app.asar integrity already matches" -ForegroundColor Green
        return
    }
    if ($currentHash -notmatch '^[0-9a-fA-F]{64}$') {
        throw "Claude.exe app.asar integrity value is not a SHA256 hex string."
    }

    Backup-AppFile $ResourcesPath $exePath
    $newHashBytes = [System.Text.Encoding]::ASCII.GetBytes($headerHash)
    [System.Array]::Copy($newHashBytes, 0, $exeBytes, $hashOffset, $newHashBytes.Length)
    [System.IO.File]::WriteAllBytes($exePath, $exeBytes)
    Write-Host "  updated Claude.exe app.asar integrity: $currentHash -> $headerHash" -ForegroundColor Green
}

function Register-Language {
    param(
        [string]$ResourcesPath,
        [string]$Lang
    )

    $assetsDir = Join-Path $ResourcesPath "ion-dist\assets\v1"
    $jsFiles = @(Get-ChildItem (Join-Path $assetsDir "index-*.js") -ErrorAction SilentlyContinue)
    if ($jsFiles.Count -eq 0) {
        throw "未找到前端 index-*.js: $assetsDir"
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
    $jsFiles = @(Get-ChildItem (Join-Path $assetsDir "index-*.js") -ErrorAction SilentlyContinue)
    if ($jsFiles.Count -eq 0) {
        throw "未找到前端 index-*.js: $assetsDir"
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
    $jsFiles = @(Get-ChildItem (Join-Path $assetsDir "index-*.js") -ErrorAction SilentlyContinue)
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
    return $replacements
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
    foreach ($file in $jsFiles) {
        $text = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
        $patched = $text
        $count = 0
        foreach ($pair in $replacements) {
            $source = $pair[0]
            $target = $pair[1]
            $occurrences = 0
            $index = $patched.IndexOf($source, [System.StringComparison]::Ordinal)
            while ($index -ge 0) {
                $occurrences += 1
                $index = $patched.IndexOf($source, $index + $source.Length, [System.StringComparison]::Ordinal)
            }
            if ($occurrences -gt 0) {
                $patched = $patched.Replace($source, $target)
                $count += $occurrences
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

    $asarPath = Join-Path $ResourcesPath "app.asar"
    Require-File $asarPath

    $oldExpr = [System.Text.Encoding]::ASCII.GetBytes('process.env.NODE_ENV!=="production"')
    $newExprText = "false".PadRight($oldExpr.Length, " ")

    $data = [System.IO.File]::ReadAllBytes($asarPath)
    $parsed = Read-AsarHeader $data $asarPath
    $headerSize = $parsed["HeaderSize"]
    $header = $parsed["Header"]
    $entry = Get-AsarFileEntry $header $AsarPatchTarget

    $contentOffset = [int64](8 + $headerSize + [int64]$entry.offset)
    $contentSize = [int64]$entry.size
    $contentEnd = $contentOffset + $contentSize
    if (($contentOffset -lt 0) -or ($contentEnd -gt $data.Length)) {
        throw "Unsupported app.asar file bounds for $AsarPatchTarget."
    }

    $content = [byte[]]::new([int]$contentSize)
    [System.Array]::Copy($data, [int]$contentOffset, $content, 0, [int]$contentSize)
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

    Backup-ModifiedFile $ResourcesPath $asarPath
    [System.Array]::Copy($content, 0, $data, [int]$contentOffset, $content.Length)

    $entry.integrity = Get-AsarFileIntegrity $content
    $updatedHeaderString = $header | ConvertTo-Json -Compress -Depth 100
    $updatedHeader = Encode-AsarHeader $updatedHeaderString $headerSize
    [System.Array]::Copy($updatedHeader, 0, $data, 0, $updatedHeader.Length)

    [System.IO.File]::WriteAllBytes($asarPath, $data)
    Sync-ClaudeExeAsarIntegrity $ResourcesPath
    Write-Host "  patched custom 3P model-name validation in app.asar" -ForegroundColor Green
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
                @("Enable Main Process Debugger", "启用主进程调试器"),
                @("Record Performance Trace", "记录性能跟踪"),
                @("Write Main Process Heap Snapshot", "写入主进程堆快照"),
                @("Record Memory Trace (auto-stop)", "记录内存跟踪 (自动)")
            )
        }
        "zh-TW" {
            $replacements = @(
                @("Enable Main Process Debugger", "啟用主行程偵錯器"),
                @("Record Performance Trace", "記錄效能追蹤"),
                @("Write Main Process Heap Snapshot", "寫入主行程堆積快照"),
                @("Record Memory Trace (auto-stop)", "記錄記憶體追蹤 (自動)")
            )
        }
        "zh-HK" {
            $replacements = @(
                @("Enable Main Process Debugger", "啟用主行程偵錯器"),
                @("Record Performance Trace", "記錄效能追蹤"),
                @("Write Main Process Heap Snapshot", "寫入主行程堆積快照"),
                @("Record Memory Trace (auto-stop)", "記錄記憶體追蹤 (自動)")
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
    $entry = Get-AsarFileEntry $header $AsarPatchTarget

    $contentOffset = [int64](8 + $headerSize + [int64]$entry.offset)
    $contentSize = [int64]$entry.size
    $contentEnd = $contentOffset + $contentSize
    if (($contentOffset -lt 0) -or ($contentEnd -gt $data.Length)) {
        throw "Unsupported app.asar file bounds for $AsarPatchTarget."
    }

    $content = [byte[]]::new([int]$contentSize)
    [System.Array]::Copy($data, [int]$contentOffset, $content, 0, [int]$contentSize)
    $text = [System.Text.Encoding]::UTF8.GetString($content)
    $patched = $text
    $count = 0

    foreach ($pair in $replacements) {
        $source = $pair[0]
        $target = $pair[1]
        if (-not $patched.Contains($source) -or $patched.Contains($target)) {
            continue
        }

        $sourceLength = [System.Text.Encoding]::UTF8.GetByteCount($source)
        $targetLength = [System.Text.Encoding]::UTF8.GetByteCount($target)
        if ($targetLength -gt $sourceLength) {
            throw "Internal patch error: menu label replacement is longer than source: $source"
        }

        $paddedTarget = $target + (" " * ($sourceLength - $targetLength))
        $patched = $patched.Replace($source, $paddedTarget)
        $count += 1
    }

    if ($count -eq 0) {
        Write-Host "  hardcoded main-process menu labels already patched" -ForegroundColor Green
        return
    }

    $patchedContent = [System.Text.Encoding]::UTF8.GetBytes($patched)
    if ($patchedContent.Length -ne $content.Length) {
        throw "Internal patch error: menu label replacement changed bundle size."
    }

    Backup-ModifiedFile $ResourcesPath $asarPath
    [System.Array]::Copy($patchedContent, 0, $data, [int]$contentOffset, $patchedContent.Length)
    $entry.integrity = Get-AsarFileIntegrity $patchedContent
    $updatedHeaderString = $header | ConvertTo-Json -Compress -Depth 100
    $updatedHeader = Encode-AsarHeader $updatedHeaderString $headerSize
    [System.Array]::Copy($updatedHeader, 0, $data, 0, $updatedHeader.Length)

    [System.IO.File]::WriteAllBytes($asarPath, $data)
    Sync-ClaudeExeAsarIntegrity $ResourcesPath
    Write-Host "  patched hardcoded main-process menu labels: $count replacements" -ForegroundColor Green
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
        $config | ConvertTo-Json -Depth 20 | Set-Content $configPath -Encoding UTF8
        Write-Host "  locale=${Locale}: $configPath" -ForegroundColor Green
    }
}

function Test-ThirdPartyApiConfigExists {
    if (-not $env:LOCALAPPDATA) {
        return $false
    }

    $configLibrary = Join-Path $env:LOCALAPPDATA "Claude-3p\configLibrary"
    if (-not (Test-Path $configLibrary -PathType Container)) {
        return $false
    }

    $entries = @(Get-ChildItem $configLibrary -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
    return $entries.Count -gt 0
}

function Confirm-InstallWithoutThirdPartyApiConfig {
    if (Test-ThirdPartyApiConfigExists) {
        return $true
    }

    while ($true) {
        $selection = (Read-Host "未配置第三方API，程序运行后无效，请参照github上readme修改，是否继续配置？ [y/n]").Trim()
        switch -Regex ($selection) {
            '^[Yy]$' { return $true }
            '^[Nn]$' {
                Write-Host "已取消配置，未修改 Claude Desktop。" -ForegroundColor Yellow
                return $false
            }
            default { Write-Host "请输入 y 或 n。" -ForegroundColor Yellow }
        }
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
        if (Test-Path $target) {
            Write-Host "  removed: $target" -ForegroundColor Green
        }
    }
}

function Stop-ClaudeProcesses {
    Stop-Process -Name "Claude" -Force -ErrorAction SilentlyContinue
    Stop-Process -Name "claude" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Write-Host "  stopped Claude Desktop if it was running" -ForegroundColor Green
}

function Restart-Claude {
    param([string]$ClaudePath)

    Stop-ClaudeProcesses

    $exeCandidates = @(
        (Join-Path $ClaudePath "Claude.exe"),
        (Join-Path $ClaudePath "claude.exe"),
        (Join-Path $ClaudePath "app\Claude.exe"),
        (Join-Path $ClaudePath "app\claude.exe")
    )
    foreach ($exe in $exeCandidates) {
        if (Test-Path $exe) {
            Start-Process $exe
            Write-Host "  restarted Claude Desktop" -ForegroundColor Green
            return
        }
    }

    Write-Host "  [警告] 未找到 Claude.exe，请手动启动 Claude Desktop。" -ForegroundColor DarkYellow
}

function Install-WindowsLanguagePack {
    $label = Get-LanguageLabel $LanguageCode
    Write-Host "=== Claude Desktop Windows $label 补丁 ===" -ForegroundColor Cyan

    Write-Step "[1/9] 检查第三方 API 配置"
    if (-not (Confirm-InstallWithoutThirdPartyApiConfig)) {
        return
    }

    Write-Step "[2/9] 检查语言资源"
    $pack = Get-LanguageResources $LanguageCode

    Write-Step "[3/9] 查找 Claude Desktop"
    $paths = Get-ClaudeResourcesPath
    $claudePath = $paths["App"]
    $resourcesPath = $paths["Resources"]
    Write-Host "  app: $claudePath" -ForegroundColor Green
    Write-Host "  resources: $resourcesPath" -ForegroundColor Green

    Write-Step "关闭 Claude Desktop"
    Stop-ClaudeProcesses

    Write-Step "[4/9] 准备写入权限"
    Enable-WriteAccess $resourcesPath

    Write-Step "[5/9] 写入 $label 资源"
    Install-LanguageFiles $resourcesPath $pack $LanguageCode

    Write-Step "[6/9] 注册中文语言"
    Register-Language $resourcesPath $LanguageCode

    Write-Step "[7/9] 汉化硬编码界面文本"
    Patch-HardcodedFrontendStrings $resourcesPath $LanguageCode
    Patch-LanguageDisplayNames $resourcesPath
    if ($SkipAsarPatch) {
        Write-Host "  skipping main-process menu label patch (app.asar) due to -SkipAsarPatch" -ForegroundColor DarkYellow
    } else {
        Patch-HardcodedMainProcessMenuLabels $resourcesPath $LanguageCode
    }

    Write-Step "[8/9] 修复第三方模型名校验"
    if ($SkipAsarPatch) {
        Write-Host "  skipping 3P model validation patch (app.asar) due to -SkipAsarPatch" -ForegroundColor DarkYellow
    } else {
        Patch-Custom3PModelValidation $resourcesPath
    }

    if ($SkipAsarPatch) {
        Write-Host "  skipping Claude.exe asar integrity sync due to -SkipAsarPatch" -ForegroundColor DarkYellow
    }

    Write-Step "[9/9] 写入用户语言配置"
    Set-ClaudeLocale $LanguageCode

    Write-Step "重启 Claude Desktop"
    Restart-Claude $claudePath

    Write-Host ""
    Write-Host "安装完成。如果界面未立即切换，请在 Language 中选择 $label。" -ForegroundColor Green
}

function Uninstall-WindowsLanguagePack {
    Write-Host "=== Claude Desktop Windows 中文补丁卸载 ===" -ForegroundColor Cyan

    $paths = Get-ClaudeResourcesPath
    $claudePath = $paths["App"]
    $resourcesPath = $paths["Resources"]

    Write-Step "关闭 Claude Desktop"
    Stop-ClaudeProcesses

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

switch ($Action) {
    "install" { Install-WindowsLanguagePack }
    "uninstall" { Uninstall-WindowsLanguagePack }
}
