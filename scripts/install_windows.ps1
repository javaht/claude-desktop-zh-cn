param(
    [switch]$Interactive,

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
    Write-Host "[1] 安装简体中文"
    Write-Host "[2] 安装繁体中文（中国台湾）"
    Write-Host "[3] 安装繁体中文（中国香港）"
    Write-Host "[4] 恢复原样 / 卸载补丁"
    Write-Host "[Q] 退出"
    Write-Host ""

    while ($true) {
        $selection = (Read-Host "请选择操作 [1/2/3/4/Q]").Trim()
        switch -Regex ($selection) {
            '^[1]$' { return @{ Action = "install"; Language = "zh-CN" } }
            '^[2]$' { return @{ Action = "install"; Language = "zh-TW" } }
            '^[3]$' { return @{ Action = "install"; Language = "zh-HK" } }
            '^[4]$' { return @{ Action = "uninstall"; Language = "zh-CN" } }
            '^[Qq]$' { exit 0 }
            default { Write-Host "请输入 1、2、3、4 或 Q。" -ForegroundColor Yellow }
        }
    }
}

if ($Interactive) {
    $interactiveSelection = Read-InteractiveSelection
    $Action = $interactiveSelection.Action
    $Language = $interactiveSelection.Language
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

    $replacements = @(
        @('"New task"', '"新建任务"'),
        @('"New session"', '"新会话"'),
        @('"New chat"', '"新建聊天"'),
        @('"Starting up..."', '"正在启动..."'),
        @('"Starting up…"', '"正在启动..."'),
        @('"Write a message..."', '"输入消息..."'),
        @('"Write a message…"', '"输入消息..."'),
        @('"Pinned"', '"已固定"'),
        @('"Recents"', '"最近使用"'),
        @('"View all"', '"查看全部"'),
        @('"Search"', '"搜索"'),
        @('label:"Status"', 'label:"状态"'),
        @('children:"Project"', 'children:"项目"'),
        @('label:"Environment"', 'label:"环境"'),
        @('label:"Last activity"', 'label:"最近活动"'),
        @('label:"Group by"', 'label:"分组方式"'),
        @('label:"Sort by"', 'label:"排序依据"'),
        @('["active","Active"]', '["active","活跃"]'),
        @('["archived","Archived"]', '["archived","已归档"]'),
        @('["all","All"]', '["all","全部"]'),
        @('["alpha","Alphabetically"]', '["alpha","按名称"]'),
        @('["created","Created time"]', '["created","创建时间"]'),
        @('["recency","Recency"]', '["recency","最近活动"]'),
        @('["1","1d"]', '["1","1天"]'),
        @('["3","3d"]', '["3","3天"]'),
        @('["7","7d"]', '["7","7天"]'),
        @('["30","30d"]', '["30","30天"]'),
        @('["0","All"]', '["0","全部"]'),
        @('["date","Date"]', '["date","日期"]'),
        @('["project","Project"]', '["project","项目"]'),
        @('["state","State"]', '["state","状态"]'),
        @('["environment","Environment"]', '["environment","环境"]'),
        @('["none","None"]', '["none","无"]'),
        @('fa="Local"', 'fa="本地"'),
        @('pa="Cloud"', 'pa="云端"'),
        @('ha="Remote Control"', 'ha="远程控制"'),
        @('ga="All"', 'ga="全部"'),
        @('children:"All projects"', 'children:"全部项目"'),
        @('children:"Clear filters"', 'children:"清除筛选"'),
        @('0===e.length?"All"', '0===e.length?"全部"'),
        @('value:a?s.keyLabel(a):"All"', 'value:a?s.keyLabel(a):"全部"'),
        @('children:"All"', 'children:"全部"'),
        @('"代码"', '"Code"'),
        @('"Legacy Model"', '"旧版模型"'),
        @('"Drag to pin"', '"拖到此处固定"'),
        @('"Drop here"', '"拖到此处"'),
        @('"Let go"', '"松开"'),
        @('label:"Projects"', 'label:"项目"'),
        @('label:"Scheduled"', 'label:"计划任务"'),
        @('label:"Customize"', 'label:"自定义"'),
        @('name:"Customize"', 'name:"自定义"'),
        @('defaultMessage:"Customize",id:"TXpOBiuxud"', 'defaultMessage:"自定义",id:"TXpOBiuxud"'),
        @('defaultMessage:"Collapse sidebar",id:"eOJ4QUCTXl"', 'defaultMessage:"折叠侧边栏",id:"eOJ4QUCTXl"'),
        @('defaultMessage:"Search",id:"xmcVZ0BU63"', 'defaultMessage:"搜索",id:"xmcVZ0BU63"'),
        @('defaultMessage:"Cancel",id:"47FYwba+bI"', 'defaultMessage:"取消",id:"47FYwba+bI"'),
        @('defaultMessage:"Open Setup",id:"ne5uHhIPyk"', 'defaultMessage:"打开设置",id:"ne5uHhIPyk"'),
        @('defaultMessage:"Can''t reach {host}",id:"Uj5zPEHmrp"', 'defaultMessage:"无法连接到 {host}",id:"Uj5zPEHmrp"'),
        @('defaultMessage:"The provider didn''t respond. Check your network or VPN, then try again.",id:"4zOvK89/in"', 'defaultMessage:"提供商未响应。请检查网络或 VPN，然后重试。",id:"4zOvK89/in"'),
        @('title:"Scheduled tasks"', 'title:"计划任务"'),
        @('subheader:a.jsx("p",{className:"text-sm text-text-500",children:"Run tasks on a schedule or whenever you need them. Type /schedule in any existing task to set one up."})', 'subheader:a.jsx("p",{className:"text-sm text-text-500",children:"按计划运行任务，或在需要时随时运行。在任意现有任务中输入 /schedule 即可设置。"})'),
        @('message:"Scheduled tasks only run while your computer is awake."', 'message:"计划任务仅在电脑保持唤醒时运行。"'),
        @('defaultMessage:"Scheduled tasks only run while your computer is awake.",id:"qgksMV96yc"', 'defaultMessage:"计划任务仅在电脑保持唤醒时运行。",id:"qgksMV96yc"'),
        @('"No scheduled tasks yet."', '"尚无计划任务。"'),
        @('children:"No scheduled tasks match your search."', 'children:"没有匹配的计划任务。"'),
        @('placeholder:"Filter scheduled tasks"', 'placeholder:"筛选计划任务"'),
        @('xYt={nextRun:"Next run",name:"Name"}', 'xYt={nextRun:"下次执行",name:"任务名称"}'),
        @('xYt={nextRun:"下次运行",name:"名称"}', 'xYt={nextRun:"下次执行",name:"任务名称"}'),
        @('name:{defaultMessage:"Name",id:"HAlOn1ZsuY"},namePlaceholder:{defaultMessage:"daily-code-review"', 'name:{defaultMessage:"任务名称",id:"scheduledTaskName"},namePlaceholder:{defaultMessage:"daily-code-review"'),
        @('name:{defaultMessage:"Name",id:"HAlOn1ZsuY"},namePlaceholder:{defaultMessage:"e.g., Daily code review"', 'name:{defaultMessage:"任务名称",id:"scheduledTaskName"},namePlaceholder:{defaultMessage:"e.g., Daily code review"'),
        @('label:x.formatMessage({defaultMessage:"Name",id:"HAlOn1ZsuY"}),value:V,onChange', 'label:"任务名称",value:V,onChange'),
        @('"aria-label":"Sort by"', '"aria-label":"排序依据"'),
        @('tooltip:"Collapse sidebar"', 'tooltip:"折叠侧边栏"'),
        @('tooltip:"Expand sidebar"', 'tooltip:"展开侧边栏"'),
        @('tooltip:"Search"', 'tooltip:"搜索"'),
        @('n?"Expand sidebar":"Collapse sidebar"', 'n?"展开侧边栏":"折叠侧边栏"'),
        @('b?"Expand sidebar":"Collapse sidebar"', 'b?"展开侧边栏":"折叠侧边栏"'),
        @('"aria-label":"Collapse sidebar"', '"aria-label":"折叠侧边栏"'),
        @('"aria-label":"Expand sidebar"', '"aria-label":"展开侧边栏"'),
        @('"aria-label":"Search"', '"aria-label":"搜索"'),
        @('title:"Connection"', 'title:"连接"'),
        @('description:"Choose where Claude Desktop sends inference requests."', 'description:"选择 Claude Desktop 发送推理请求的位置。"'),
        @('title:"Sandbox & workspace"', 'title:"沙盒与工作区"'),
        @('title:"Connectors & extensions"', 'title:"连接器与扩展"'),
        @('title:"Telemetry & updates"', 'title:"诊断与更新"'),
        @('title:"遥测与更新"', 'title:"诊断与更新"'),
        @('telemetry:{title:"Telemetry & updates"', 'telemetry:{title:"诊断与更新"'),
        @('title:"Usage limits"', 'title:"使用限制"'),
        @('title:"Plugins & skills"', 'title:"插件与技能"'),
        @('title:"Egress Requirements"', 'title:"出站要求"'),
        @('label:"macOS configuration profile"', 'label:"macOS 配置描述文件"'),
        @('label:"Windows registry file"', 'label:"Windows 注册表文件"'),
        @('label:"Plain JSON"', 'label:"纯 JSON"'),
        @('label:"Firewall allowlist (.txt)"', 'label:"防火墙允许列表（.txt）"'),
        @('label:"Copy to clipboard (redacted)"', 'label:"复制到剪贴板（已脱敏）"'),
        @('title:"Source"', 'title:"来源"'),
        @('group:"Identity & models"', 'group:"身份与模型"'),
        @('label:"Model ID"', 'label:"模型 ID"'),
        @('label:"Offer 1M-context variant"', 'label:"提供 1M 上下文变体"'),
        @('title:"Skip login-mode chooser"', 'title:"启动时跳过登录方式选择"'),
        @('title:"Hide Anthropic sign-in"', 'title:"隐藏 Anthropic 登录"'),
        @('title:"Gateway base URL"', 'title:"网关基础 URL"'),
        @('description:"Full URL of the inference gateway endpoint."', 'description:"推理网关端点的完整 URL。"'),
        @('title:"Gateway API key"', 'title:"网关 API 密钥"'),
        @('title:"Gateway auth scheme"', 'title:"网关认证方案"'),
        @('title:"Gateway extra headers"', 'title:"网关额外请求头"'),
        @('description:"Extra HTTP headers sent on every inference request. JSON array of ''Name: Value'' strings."', 'description:"每次推理请求都会附带的额外 HTTP 请求头。格式为“名称: 值”字符串组成的 JSON 数组。"'),
        @('title:"Inference provider"', 'title:"推理提供商"'),
        @('description:"Selects the inference backend. Setting this key activates third-party mode."', 'description:"选择推理后端。设置此项会启用第三方模式。"'),
        @('title:"GCP project ID"', 'title:"GCP 项目 ID"'),
        @('title:"GCP region"', 'title:"GCP 区域"'),
        @('title:"GCP credentials file path"', 'title:"GCP 凭据文件路径"'),
        @('title:"Vertex OAuth client ID"', 'title:"Vertex OAuth 客户端 ID"'),
        @('title:"Vertex OAuth client secret"', 'title:"Vertex OAuth 客户端密钥"'),
        @('title:"Vertex OAuth scopes"', 'title:"Vertex OAuth 范围"'),
        @('title:"Vertex AI base URL"', 'title:"Vertex AI 基础 URL"'),
        @('title:"AWS region"', 'title:"AWS 区域"'),
        @('title:"AWS bearer token"', 'title:"AWS Bearer 令牌"'),
        @('title:"Bedrock base URL"', 'title:"Bedrock 基础 URL"'),
        @('title:"AWS profile name"', 'title:"AWS 配置文件名称"'),
        @('title:"AWS config directory"', 'title:"AWS 配置目录"'),
        @('title:"Bedrock service tier"', 'title:"Bedrock 服务层级"'),
        @('title:"Azure AI Foundry resource name"', 'title:"Azure AI Foundry 资源名称"'),
        @('title:"Azure AI Foundry API key"', 'title:"Azure AI Foundry API 密钥"'),
        @('title:"Model list"', 'title:"模型列表"'),
        @('title:"Managed MCP servers"', 'title:"托管的 MCP 服务器"'),
        @('title:"Organization UUID"', 'title:"组织 UUID"'),
        @('title:"Credential helper script"', 'title:"凭据辅助脚本"'),
        @('description:"Absolute path to an executable that prints the inference credential to stdout. When set, the static inferenceGatewayApiKey / inferenceFoundryApiKey is optional."', 'description:"可执行文件的绝对路径，该文件会将推理凭据输出到标准输出。设置后，可不填写静态 inferenceGatewayApiKey / inferenceFoundryApiKey。"'),
        @('hint:"Absolute path to an executable that prints the credential."', 'hint:"输出凭据的可执行文件绝对路径。"'),
        @('title:"Credential helper TTL"', 'title:"凭据辅助脚本 TTL"'),
        @('description:"Helper output is cached for this many seconds. Default 3600. Re-runs at the next session start after expiry."', 'description:"辅助脚本输出缓存的秒数。默认 3600。过期后会在下一次会话开始时重新运行。"'),
        @('title:"Allow desktop extensions"', 'title:"允许桌面扩展"'),
        @('description:"Permit users to install local desktop extensions (.dxt/.mcpb)."', 'description:"允许用户安装本地桌面扩展（.dxt/.mcpb）。"'),
        @('group:"Extensions"', 'group:"扩展"'),
        @('group:"MCP servers"', 'group:"MCP 服务器"'),
        @('group:"Anthropic telemetry"', 'group:"Anthropic 诊断"'),
        @('group:"Anthropic 遥测"', 'group:"Anthropic 诊断"'),
        @('label:"Name"', 'label:"名称"'),
        @('label:"Transport"', 'label:"传输方式"'),
        @('label:"Headers"', 'label:"请求头"'),
        @('label:"Headers helper script"', 'label:"请求头辅助脚本"'),
        @('label:"Helper cache TTL (sec)"', 'label:"辅助缓存 TTL（秒）"'),
        @('placeholder:"Absolute path"', 'placeholder:"绝对路径"'),
        @('banner:"Plugins and skills aren''t set in this configuration. Mount plugin bundles to the folder below using your device-management tool and Cowork will load them at launch."', 'banner:"插件和技能未在此配置中设置。请使用你的设备管理工具将插件包挂载到下方文件夹，Cowork 会在启动时加载它们。"'),
        @('caption:"Drop plugin folders here. Read-only to the app."', 'caption:"将插件文件夹拖放到这里。应用对此目录为只读。"'),
        @('description:"Hosts your network firewall must allow, derived from your current settings. This list is read-only and updates as you make changes. Traffic is HTTPS on port 443 unless a custom port is specified (OTLP, gateway, or MCP server URLs)."', 'description:"根据当前设置推导出的、主机网络防火墙必须放行的主机。此列表为只读，并会随着你的更改自动更新。除非指定了自定义端口（OTLP、网关或 MCP 服务器 URL），否则流量均为 443 端口上的 HTTPS。"'),
        @('hint:"First entry is the picker default. Aliases like sonnet, opus accepted. Optional for gateway — when set, the picker shows exactly this list instead of /v1/models discovery. Turn on 1M context only for models your provider actually serves with the extended window."', 'hint:"第一项是选择器默认值。支持 sonnet、opus 等别名。网关可选；设置后，选择器会显示此列表，而不是通过 /v1/models 发现。仅当提供商实际支持扩展窗口时才开启 1M 上下文。"'),
        @('hint:"Tags telemetry events with your org so support can find them. Not used for auth."', 'hint:"为诊断事件标记你的组织，便于支持团队定位。不会用于认证。"'),
        @('hint:"Go straight to this provider at launch — users won\''t see the option to sign in to Anthropic instead."', 'hint:"启动后直接进入这个提供商，用户将不会看到改为登录 Anthropic 的选项。"'),
        @('hint:"Users see only this provider at the login screen — the option to sign in to Anthropic is hidden."', 'hint:"用户在登录界面只会看到此提供商，Anthropic 登录选项将被隐藏。"'),
        @('description:"How to send the gateway credential. ''bearer'' (default) sends Authorization: Bearer. Set ''x-api-key'' only if your gateway requires the x-api-key header instead (e.g. api.anthropic.com). Set ''sso'' to obtain the credential via the gateway''s own browser-based sign-in (RFC 8414 discovery at `<inferenceGatewayBaseUrl>/.well-known/oauth-authorization-server` + RFC 8628 device-code grant); inferenceGatewayApiKey and inferenceCredentialHelper are not required."', 'description:"如何发送网关凭据。bearer（默认）发送 Authorization: Bearer。仅当网关要求 x-api-key 请求头时才设置为 x-api-key（例如 api.anthropic.com）。设置为 sso 时，将通过网关自己的浏览器登录获取凭据（RFC 8414 发现 + RFC 8628 设备码授权）；无需 inferenceGatewayApiKey 和 inferenceCredentialHelper。"'),
        @('hint:"Bearer (default) sends Authorization: Bearer. x-api-key is for the Anthropic API directly — auto-selected when the URL is *.anthropic.com."', 'hint:"Bearer（默认）发送 Authorization: Bearer。x-api-key 用于直连 Anthropic API；当 URL 为 *.anthropic.com 时会自动选择。"'),
        @('hint:"Extra headers sent to the gateway, one ''Name: Value'' per entry. For tenant routing, org IDs, etc."', 'hint:"发送到网关的额外请求头，每项格式为“名称: 值”。可用于租户路由、组织 ID 等。"'),
        @('hint:"Extra headers sent to the gateway. One value per header name. For tenant routing, org IDs, etc."', 'hint:"发送到网关的额外请求头。每个请求头名称对应一个值。用于租户路由、组织 ID 等。"'),
        @('body:"Sent on every inference and `/v1/models` discovery request (joined into the CLI''s `ANTHROPIC_CUSTOM_HEADERS`).\n\nUse this for fleet-wide constants. For per-user or per-session values, have the **credential helper script** emit JSON with a `headers` field — those are merged over these static entries (helper wins on conflict)."', 'body:"每次推理和 `/v1/models` 发现请求都会发送这些请求头（会合并到 CLI 的 `ANTHROPIC_CUSTOM_HEADERS`）。\n\n适合填写全局固定值。针对单个用户或会话的值，请让**凭据辅助脚本**输出包含 `headers` 字段的 JSON；这些值会覆盖此处的静态项（冲突时辅助脚本优先）。"'),
        @('description:''JSON array of MCP server configs. Each entry: `name` (string, required, unique within array), `url` (https URL, required), `transport` ("http" or "sse", default "http"), `headers` (string→string map, optional, mutually exclusive with `oauth`), `headersHelper` (absolute path to local executable that prints a JSON object of HTTP headers on stdout — for rotating bearers; optional, mutually exclusive with `oauth`; merged over `headers`, helper wins on conflict. The helper runs with the app''s launch environment, not your shell rc — read credentials from keychain/file or source them explicitly in the script), `headersHelperTtlSec` (positive integer, default 300 — re-runs the helper at most once per TTL across connection attempts), `oauth` (boolean or object, optional — `true` triggers dynamic-registration PKCE; `{"clientId":"<id>"}` skips registration and uses a pre-registered public client (register redirect URI `http://127.0.0.1:53280/callback` on it — Entra/Google accept the portless `http://127.0.0.1/callback`, but providers that match the port exactly need 53280). Optional `tenantId` (Entra Directory ID) pins the authorization server for single-tenant apps; `scope` is required when `tenantId` is set), `toolPolicy` (toolName→"allow"/"ask"/"blocked", optional — locks the per-tool approval state; unset = user controls). Connections are made from a host-side utility process and do not pass through the in-VM allowlist.''', 'description:''MCP 服务器配置的 JSON 数组。每项包含：`name`（字符串，必填，数组内唯一）、`url`（https URL，必填）、`transport`（"http" 或 "sse"，默认 "http"）、`headers`（字符串到字符串映射，可选，与 `oauth` 互斥）、`headersHelper`（本地可执行文件绝对路径，会向 stdout 输出 HTTP 请求头 JSON 对象，用于轮换 bearer；可选，与 `oauth` 互斥；会覆盖合并到 `headers`，冲突时辅助脚本优先）、`headersHelperTtlSec`（正整数，默认 300，在 TTL 内连接时最多重新运行一次）、`oauth`（布尔值或对象，可选）、`toolPolicy`（工具名到 "allow"/"ask"/"blocked"，可选，用于锁定每个工具的批准状态；未设置则由用户控制）。连接由主机侧工具进程发起，不经过虚拟机内允许列表。'''),
        @('body:''Claude runs the executable with no arguments and reads **stdout** (trimmed). Exit code must be `0`; any output on **stderr** is logged but ignored. **Stdout must be the credential only** — no banners, prompts, or log lines.\n\n**Output format** — either:\n- a single bare token (the API key / bearer token), or\n- a JSON object `{"token": "...", "headers": {"Name": "Value", ...}}` when per-request headers are needed (gateway provider only; merged over **Gateway extra headers**, helper wins on conflict)\n\nResult is cached for the TTL below. On TTL expiry the helper is re-invoked transparently — no user prompt, no relaunch.\n\n**Typical use:** a shell script that pulls from Keychain, 1Password CLI, or an internal secret broker. Example:\n\n`security find-generic-password -s anthropic-api -w`\n\nIf this field is set, static credential fields (API key, bearer token) are ignored. The helper always wins.''', 'body:''Claude 会在不带参数的情况下运行该可执行文件，并读取修剪后的 **标准输出**。退出码必须为 `0`；**标准错误** 的任何输出会被记录但忽略。**标准输出必须只包含凭据**，不能有横幅、提示或日志行。\n\n**输出格式**二选一：\n- 单个纯令牌（API key / bearer token），或\n- 需要按请求附加请求头时，输出 JSON 对象 `{"token": "...", "headers": {"Name": "Value", ...}}`（仅适用于网关提供商；会与**网关额外请求头**合并，冲突时以辅助脚本为准）。\n\n结果会按下方 TTL 缓存。TTL 过期后会自动重新调用辅助脚本，无需用户确认，也无需重启。\n\n**常见用法：**通过 shell 脚本从钥匙串、1Password CLI 或内部密钥代理中读取凭据。例如：\n\n`security find-generic-password -s anthropic-api -w`\n\n设置此字段后，静态凭据字段（API key、bearer token）会被忽略，始终以辅助脚本输出为准。'''),
        @('egressRequirementsLabel:"Desktop extensions (Python runtime)"', 'egressRequirementsLabel:"桌面扩展（Python 运行时）"'),
        @('title:"Show extension directory"', 'title:"显示扩展目录"'),
        @('description:"Show the Anthropic extension directory in the connectors UI."', 'description:"在连接器界面显示 Anthropic 扩展目录。"'),
        @('title:"Require signed extensions"', 'title:"要求扩展已签名"'),
        @('description:"Reject desktop extensions that are not signed by a trusted publisher."', 'description:"拒绝未由受信任发布者签名的桌面扩展。"'),
        @('hint:"Reject desktop extensions that are not signed by a trusted publisher."', 'hint:"拒绝未由受信任发布者签名的桌面扩展。"'),
        @('title:"Allow user-added MCP servers"', 'title:"允许用户添加 MCP 服务器"'),
        @('description:"Permit users to add their own local (stdio) MCP servers via Developer settings. HTTP/SSE servers are managed separately. When false, only servers from the Managed MCP servers list and org-provisioned plugins are available."', 'description:"允许用户通过开发者设置添加自己的本地（stdio）MCP 服务器。HTTP/SSE 服务器会单独管理。关闭后，仅可使用托管 MCP 服务器列表和组织预配插件中的服务器。"'),
        @('egressRequirementsLabel:"User-added MCP (Python runtime)"', 'egressRequirementsLabel:"用户添加的 MCP（Python 运行时）"'),
        @('title:"Allow Claude Code tab"', 'title:"允许 Claude Code 标签页"'),
        @('description:"Show the Code tab (terminal-based coding sessions). Sessions run on the host, not inside the VM."', 'description:"显示 Code 标签页（基于终端的编码会话）。会话在主机上运行，而不是在虚拟机内运行。"'),
        @('hint:"Show the Code tab (terminal-based coding sessions). Sessions run on the host, not inside the VM."', 'hint:"显示 Code 标签页（基于终端的编码会话）。会话在主机上运行，而不是在虚拟机内运行。"'),
        @('title:"Secure VM features"', 'title:"安全虚拟机功能"'),
        @('title:"Require full VM sandbox"', 'title:"要求完整虚拟机沙盒"'),
        @('description:"Forces the agent loop, file/web tools, and plugin-bundled MCPs to run inside the VM, disabling host-loop mode."', 'description:"强制代理循环、文件/网页工具以及插件内置 MCP 在虚拟机内运行，并禁用主机循环模式。"'),
        @('title:"Allowed egress hosts"', 'title:"允许的出站主机"'),
        @('description:`Additional hostnames the Cowork sandbox may reach (web fetch, shell commands, package installs). JSON array; supports *.example.com wildcards. The inference provider host is always allowed. Set to ["*"] to disable VM-level egress filtering entirely. Common hosts to add for dependency installs (pip/npm/apt/cargo/git): ${I.join(", ")}.`', 'description:`Cowork 沙盒可访问的额外主机名（网页抓取、Shell 命令、包安装）。JSON 数组；支持 *.example.com 通配符。推理提供商主机始终允许。设置为 ["*"] 可完全禁用虚拟机级出站过滤。依赖安装（pip/npm/apt/cargo/git）常需添加的主机：${I.join(", ")}。`'),
        @('egressRequirementsLabel:"Tool egress (VM sandbox)"', 'egressRequirementsLabel:"工具出站（虚拟机沙盒）"'),
        @('banner:"Prompts, completions, and your data are never sent to Anthropic — telemetry covers crash and usage signals only."', 'banner:"提示词、补全和你的数据绝不会发送给 Anthropic；诊断只包含崩溃和使用信号。"'),
        @('banner:"提示词、补全和你的数据绝不会发送给 Anthropic；遥测只包含崩溃和使用信号。"', 'banner:"提示词、补全和你的数据绝不会发送给 Anthropic；诊断只包含崩溃和使用信号。"'),
        @('group:"OpenTelemetry"', 'group:"OpenTelemetry"'),
        @('group:"Updates"', 'group:"更新"'),
        @('title:"OpenTelemetry collector endpoint"', 'title:"OpenTelemetry 收集器端点"'),
        @('title:"OpenTelemetry resource attributes"', 'title:"OpenTelemetry 资源属性"'),
        @('description:"Base URL of an OpenTelemetry collector. When set, Cowork sessions export logs and metrics (prompts, tool calls, token counts) to this endpoint."', 'description:"OpenTelemetry 收集器的基础 URL。设置后，Cowork 会话会将日志和指标（提示词、工具调用、令牌计数）导出到此端点。"'),
        @('description:"Extra OTEL resource attributes as comma-separated key=value pairs (the standard OTEL_RESOURCE_ATTRIBUTES format). Appended to the app''s built-in attributes; keys that collide with built-ins (e.g. service.name) are dropped. Scoped for bootstrap so per-user values can be returned at sign-in."', 'description:"额外的 OTEL 资源属性，以逗号分隔的 key=value 对填写（标准 OTEL_RESOURCE_ATTRIBUTES 格式）。会追加到应用内置属性；与内置属性冲突的键（如 service.name）会被丢弃。用于 bootstrap 时可在登录时返回按用户设置的值。"'),
        @('title:"Block essential telemetry"', 'title:"阻止基础诊断"'),
        @('title:"阻止基础遥测"', 'title:"阻止基础诊断"'),
        @('description:"Blocks crash and error reports (stack traces, app state at failure, device/OS info) and performance timing data sent to Anthropic. Used to investigate bugs and monitor responsiveness."', 'description:"阻止发送给 Anthropic 的崩溃和错误报告（堆栈跟踪、故障时应用状态、设备/系统信息）以及性能计时数据。这些数据用于调查错误并监控响应性。"'),
        @('title:"Block nonessential telemetry"', 'title:"阻止非必要诊断"'),
        @('title:"阻止非必要遥测"', 'title:"阻止非必要诊断"'),
        @('description:"Blocks product-usage analytics sent to Anthropic — feature usage, navigation patterns, UI actions."', 'description:"阻止发送给 Anthropic 的产品使用分析，包括功能使用、导航模式和界面操作。"'),
        @('title:"Block nonessential services"', 'title:"阻止非必要服务"'),
        @('description:"Blocks connector favicons (fetched from a third-party favicon service — leaks MCP hostnames) and the artifact-preview sandbox iframe. Connectors fall back to letter icons; artifacts do not render."', 'description:"阻止连接器网站图标（从第三方图标服务获取，可能泄露 MCP 主机名）和 artifact 预览沙盒 iframe。连接器会回退为字母图标，artifact 将无法渲染。"'),
        @('title:"Auto-update enforcement window"', 'title:"自动更新强制窗口"'),
        @('description:"When set, forces a pending update to install after this many hours regardless of user activity. When unset, the app uses a 72-hour window but defers installation while the user is active."', 'description:"设置后，无论用户是否正在使用，待处理更新都会在指定小时后强制安装。未设置时，应用使用 72 小时窗口，但会在用户活跃时延后安装。"'),
        @('title:"Block auto-updates"', 'title:"阻止自动更新"'),
        @('description:"Blocks the app from checking for and downloading updates from Anthropic. The app will stay on its installed version until updated by other means."', 'description:"阻止应用检查并下载来自 Anthropic 的更新。应用会保持当前已安装版本，直到通过其他方式更新。"'),
        @('suffix:"hours"', 'suffix:"小时"'),
        @('title:"Disable essential telemetry"', 'title:"禁用基础诊断"'),
        @('title:"禁用基础遥测"', 'title:"禁用基础诊断"'),
        @('description:"Disable essential crash and performance telemetry."', 'description:"禁用基础崩溃和性能诊断。"'),
        @('title:"Disable auto updates"', 'title:"禁用自动更新"'),
        @('description:"Prevent Claude Desktop from checking for updates automatically."', 'description:"阻止 Claude Desktop 自动检查更新。"'),
        @('title:"Daily message limit"', 'title:"每日消息限制"'),
        @('description:"Maximum number of messages a user can send per day."', 'description:"用户每天可发送的最大消息数。"'),
        @('title:"Max tokens per window"', 'title:"每窗口最大令牌数"'),
        @('description:"Total input+output tokens permitted per window before further messages are refused. Unset = no cap."', 'description:"每个窗口允许的输入和输出令牌总数；超过后将拒绝继续发送消息。未设置表示不限制。"'),
        @('title:"Token cap window"', 'title:"令牌限制窗口"'),
        @('description:"Tumbling window length for the token cap. Max 720 hours (30 days). The counter resets at the end of each window."', 'description:"令牌限制的滚动窗口长度。最大 720 小时（30 天）。每个窗口结束时计数器会重置。"'),
        @('hint:"Crash and performance reports to Anthropic."', 'hint:"将崩溃和性能报告发送给 Anthropic。"'),
        @('hint:"Product-usage analytics and diagnostic-report uploads. No message content."', 'hint:"产品使用分析和诊断报告上传。不包含消息内容。"'),
        @('hint:"Favicon fetch and the artifact-preview iframe origin. Artifacts will not render."', 'hint:"网站图标获取和 artifact 预览 iframe 的来源。Artifacts 将无法渲染。"'),
        @('hint:"Stop Cowork from fetching updates. You''ll need to push new versions yourself."', 'hint:"阻止 Cowork 获取更新。后续新版本需要由你自行推送。"'),
        @('hint:"Hours before a downloaded update force-installs. Blank = 72-hour default."', 'hint:"已下载更新会在多少小时后强制安装。留空则使用默认的 72 小时。"'),
        @('hint:"Where Cowork sends OpenTelemetry logs and metrics. Leave blank to disable."', 'hint:"Cowork 会将 OpenTelemetry 日志和指标发送到哪里。留空表示禁用。"'),
        @('hint:"grpc or http/protobuf."', 'hint:"支持 grpc 或 http/protobuf。"'),
        @('hint:"Optional auth headers for the collector."', 'hint:"发送给收集器的可选认证请求头。"'),
        @('hint:"Extra resource attributes to attach to every span/metric, e.g. enduser.id=alice@example.com."', 'hint:"附加到每个 span/metric 的额外资源属性，例如 enduser.id=alice@example.com。"'),
        @('hint:"Per-user soft cap, counted client-side over the duration below. Not a server-enforced quota."', 'hint:"按用户设置的软限制，在下方时长范围内由客户端统计。不是服务器强制执行的配额。"'),
        @('reason:"Security and compatibility fixes will not install automatically. Make sure IT has another distribution path."', 'reason:"安全和兼容性修复不会自动安装。请确保 IT 有其他分发路径。"'),
        @('reason:"Usage analytics help us prioritize improvements for third-party inference. Diagnostic-report uploads will also be blocked. No message content is included in either."', 'reason:"使用分析可帮助我们优先改进第三方推理。诊断报告上传也会被阻止。两者都不包含消息内容。"'),
        @('reason:"This disables artifact previews and connector icons. Artifacts will not render in conversations."', 'reason:"这会禁用 artifact 预览和连接器图标。Artifact 将不会在对话中渲染。"'),
        @('body:"\"Essential\" means the signals Anthropic needs to keep your deployment working: **crash stacks**, **startup failure reasons**, and **version/OS metadata**. No prompts, completions, file contents, or identifiers beyond a random install ID.\n\n**What you lose when this is on:** when a Cowork build hits a bug that only reproduces on your OS version or locale, Anthropic can''t see it unless a user manually reports. Fixes ship slower.\n\n**Why this is discouraged, not blocked:** some air-gapped environments require zero outbound telemetry as a matter of policy. The switch exists for them — if you don''t have that constraint, leave it off."', 'body:"\"基础\"是指 Anthropic 为保持你的部署正常运行所需的信号：**崩溃堆栈**、**启动失败原因**以及**版本/系统元数据**。不包含提示词、补全、文件内容，也不包含随机安装 ID 之外的标识符。\n\n**开启后会失去什么：**当 Cowork 构建遇到只在你的系统版本或区域设置上复现的问题时，除非用户手动报告，否则 Anthropic 无法看到，修复发布会更慢。\n\n**为什么这是不推荐而不是禁止：**某些隔离网络环境因策略要求零出站诊断数据。此开关就是为这些环境准备的；如果你没有这类约束，请保持关闭。"'),
        @('body:''"Nonessential" covers two things: **product-usage analytics** (which features get used, navigation patterns — no prompts or completions) and the **Send** action in Help → Generate Diagnostic Report. Turning this on stops both.\n\nDestination for both: `claude.ai`. Already listed under Egress Requirements → Nonessential telemetry.''', 'body:''"非必要"包括两类内容：**产品使用分析**（使用了哪些功能、导航模式；不包含提示词或补全）以及「帮助 → 生成诊断报告」中的**发送**操作。开启后会同时停止两者。\n\n两者的目标地址都是 `claude.ai`，已列在「出站要求 → 非必要诊断」下。'''),
        @('title:"Disabled built-in tools"', 'title:"禁用内置工具"'),
        @('description:''JSON array of tool names to remove from the agent tool list (e.g. ["WebSearch"]).''', 'description:''要从代理工具列表中移除的工具名称 JSON 数组（例如 ["WebSearch"]）。'''),
        @('title:"Allowed workspace folders"', 'title:"允许的工作区文件夹"'),
        @('description:"JSON array of absolute paths the user may attach as workspace folders. A leading ~ expands to the per-user home directory. Unset means unrestricted."', 'description:"用户可附加为工作区文件夹的绝对路径 JSON 数组。开头的 ~ 会展开为对应用户的主目录。未设置表示不限制。"'),
        @('hint:"Domains Cowork''s tools may reach during a turn. Also surfaced under Egress Requirements."', 'hint:"Cowork 工具在一次回合中可访问的域名。也会显示在出站要求中。"'),
        @('body:"Only affects **tool calls** — inference and MCP traffic are covered by their own allowlists elsewhere.\n\nAccepts exact hostnames (`api.github.com`), wildcards (`*.corp.com` matches one subdomain level), and `*` to allow all.\n\nWildcards don''t cross schemes. `*.corp.com` matches `docs.corp.com` but not `corp.com` itself — add both if you need the apex.\n\nIP literals and localhost always resolve regardless of this list; this is a public-egress filter, not a sandbox.\n\nHosts you add here also need to be open on your network firewall — see **Egress Requirements** for the full allowlist."', 'body:"仅影响**工具调用**；推理和 MCP 流量由其他位置各自的允许列表控制。\n\n支持精确主机名（`api.github.com`）、通配符（`*.corp.com` 匹配一级子域）以及用于允许全部的 `*`。\n\n通配符不会跨层级匹配。`*.corp.com` 会匹配 `docs.corp.com`，但不匹配 `corp.com` 本身；如需顶级域，请同时添加两者。\n\n无论此列表如何设置，IP 字面量和 localhost 始终可解析；这是公共出站过滤器，不是沙盒。\n\n你在此处添加的主机也需要在网络防火墙中放行；完整允许列表请参见**出站要求**。"'),
        @('hint:"Folders users may attach as a workspace. Leave unset for unrestricted access."', 'hint:"用户可附加为工作区的文件夹。留空表示不限制访问。"'),
        @('hint:"Built-in tools removed from Cowork."', 'hint:"从 Cowork 中移除的内置工具。"'),
        @('hint:".dxt and .mcpb installs."', 'hint:".dxt 和 .mcpb 安装。"'),
        @('hint:"The in-app catalogue of installable extensions. Hide to allow sideload only."', 'hint:"应用内可安装扩展目录。隐藏后仅允许侧载。"'),
        @('hint:"Local stdio servers added via the Developer settings. Remote servers come from the managed list above, or plugins mounted to a user''s computer by an organization admin."', 'hint:"通过开发者设置添加的本地 stdio 服务器。远程服务器来自上方托管列表，或来自组织管理员挂载到用户电脑的插件。"'),
        @('hint:"Org-pushed remote MCP servers. May embed bearer tokens."', 'hint:"组织推送的远程 MCP 服务器。可能嵌入 Bearer 令牌。"'),
        @('"Scheduled"', '"定时任务"'),
        @("`"What’s up next?`"", '"接下来做什么？"'),
        @('"Let''s knock something off your list"', '"先把清单上的一件事做完"')
    )
    $replacements += Get-FrontendHardcodedReplacements $Language

    $patchedFiles = 0
    $patchedStrings = 0
    foreach ($file in $jsFiles) {
        $text = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
        $patched = $text
        $count = 0
        foreach ($pair in $replacements) {
            $source = $pair[0]
            $target = $pair[1]
            if ($patched.Contains($source)) {
                $patched = $patched.Replace($source, $target)
                $count += 1
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
    param([string]$ResourcesPath)

    $asarPath = Join-Path $ResourcesPath "app.asar"
    Require-File $asarPath

    $replacements = @(
        @("Enable Main Process Debugger", "启用主进程调试器"),
        @("Record Performance Trace", "记录性能跟踪"),
        @("Write Main Process Heap Snapshot", "写入主进程堆快照"),
        @("Record Memory Trace (auto-stop)", "记录内存跟踪 (自动)")
    )

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
        $sourceLength = [System.Text.Encoding]::UTF8.GetByteCount($source)
        $targetLength = [System.Text.Encoding]::UTF8.GetByteCount($target)
        if ($targetLength -gt $sourceLength) {
            throw "Internal patch error: menu label replacement is longer than source: $source"
        }

        if ($patched.Contains($target)) {
            continue
        }
        if ($patched.Contains($source)) {
            $paddedTarget = $target + (" " * ($sourceLength - $targetLength))
            $patched = $patched.Replace($source, $paddedTarget)
            $count += 1
        }
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
    Patch-HardcodedMainProcessMenuLabels $resourcesPath

    Write-Step "[8/9] 修复第三方模型名校验"
    Patch-Custom3PModelValidation $resourcesPath

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
