$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Load-InstallerFunctions.ps1') -FunctionNames @(
    'Require-File',
    'Align-4',
    'Get-UInt32LE',
    'Get-Int32LE',
    'Read-AsarHeader',
    'Read-AsarHeaderFromFile',
    'Get-AsarEntryPaths',
    'Get-AsarFileIntegrity',
    'Get-AsarFileIntegrityFromBytes',
    'New-AsarArchive',
    'Get-ClaudeAppPathFromResources',
    'Get-ClaudeExeIntegrityMarker',
    'Assert-ClaudeExeIntegrityMarkers',
    'Test-ShellInternalI18nLayout',
    'Get-ShellCatalogBaseEntry',
    'Read-AsarEntryBytes',
    'Add-ShellLocaleCatalog'
)

# Stub backup and exe-write side effects while exercising the real installer logic.
function Backup-AppFile {
    param([string]$ResourcesPath, [string]$FilePath)
    $script:BackedUpFiles += $FilePath
}
function Sync-ClaudeExeAsarIntegrity {
    param([string]$ResourcesPath)
    $script:SyncedResources += $ResourcesPath
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('claude-shell-catalog-' + [guid]::NewGuid().ToString('N'))
$app = Join-Path $temp 'app'
$resources = Join-Path $app 'resources'
$source = Join-Path $temp 'source'
$utf8NoBom = [Text.UTF8Encoding]::new($false)
$AsarIntegrityBlockSize = 4MB
$script:BackedUpFiles = @()
$script:SyncedResources = @()

try {
    $i18n = Join-Path (Join-Path $source 'resources') 'i18n'
    New-Item -ItemType Directory -Path $i18n -Force | Out-Null
    New-Item -ItemType Directory -Path $resources -Force | Out-Null

    $zhHansJson = '{"hello":"世界","menu.close":"关闭会话"}'
    $enUSJson = '{"hello":"world","menu.close":"Close Session"}'
    [IO.File]::WriteAllText((Join-Path $i18n 'en-US.json'), $enUSJson, $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $i18n 'zh-Hans.json'), $zhHansJson, $utf8NoBom)

    $bigPayload = [byte[]]::new(10000)
    for ($i = 0; $i -lt $bigPayload.Length; $i++) {
        $bigPayload[$i] = [byte]($i % 251)
    }
    [IO.File]::WriteAllBytes((Join-Path $source 'payload.bin'), $bigPayload)

    $asarPath = Join-Path $resources 'app.asar'
    New-AsarArchive $source $asarPath

    $exePath = Join-Path $app 'Claude.exe'
    $bs = [string][char]92
    $validMarker = '{"file":"resources' + $bs + $bs + 'app.asar","alg":"SHA256","value":"' + ('a' * 64) + '"}'
    [IO.File]::WriteAllText($exePath, $validMarker, [Text.Encoding]::ASCII)

    # --- Test 1: layout detection ---
    if (-not (Test-ShellInternalI18nLayout $resources)) {
        throw 'FAIL: shell-internal i18n layout was not detected.'
    }
    Write-Host 'PASS: shell-internal i18n layout detected.' -ForegroundColor Green

    # --- Test 2: preflight Assert-ClaudeExeIntegrityMarkers rejects missing/invalid marker ---
    [IO.File]::WriteAllText($exePath, 'no-integrity-marker-here', [Text.Encoding]::ASCII)
    $threwOnMissing = $false
    try {
        Assert-ClaudeExeIntegrityMarkers $resources @('app.asar')
    }
    catch {
        $threwOnMissing = $true
    }
    if (-not $threwOnMissing) {
        throw 'FAIL: Assert-ClaudeExeIntegrityMarkers did not throw on missing marker.'
    }
    [IO.File]::WriteAllText($exePath, $validMarker, [Text.Encoding]::ASCII)
    Assert-ClaudeExeIntegrityMarkers $resources @('app.asar')
    Write-Host 'PASS: Assert-ClaudeExeIntegrityMarkers validates executable marker before patching.' -ForegroundColor Green

    # --- Test 3: real Add-ShellLocaleCatalog injects zh-CN.json and preserves payload ---
    Add-ShellLocaleCatalog $resources 'zh-CN'

    $parsed = Read-AsarHeaderFromFile $asarPath
    $paths = @(Get-AsarEntryPaths $parsed['Header'])
    foreach ($expected in @('resources/i18n/zh-CN.json', 'resources/i18n/en-US.json', 'resources/i18n/zh-Hans.json', 'payload.bin')) {
        if ($paths -notcontains $expected) {
            throw "FAIL: missing entry after injection: $expected"
        }
    }
    Write-Host 'PASS: all expected entries present after Add-ShellLocaleCatalog.' -ForegroundColor Green

    $zhCNBytes = Read-AsarEntryBytes $asarPath $parsed 'resources/i18n/zh-CN.json'
    $zhHansBytes = Read-AsarEntryBytes $asarPath $parsed 'resources/i18n/zh-Hans.json'
    if ([Text.Encoding]::UTF8.GetString($zhCNBytes) -cne $zhHansJson) {
        throw 'FAIL: injected zh-CN.json content does not match zh-Hans.json base.'
    }
    if ([Text.Encoding]::UTF8.GetString($zhHansBytes) -cne $zhHansJson) {
        throw 'FAIL: original zh-Hans.json content was altered.'
    }
    Write-Host 'PASS: zh-CN.json content matches zh-Hans.json base.' -ForegroundColor Green

    $enUSBytes = Read-AsarEntryBytes $asarPath $parsed 'resources/i18n/en-US.json'
    if ([Text.Encoding]::UTF8.GetString($enUSBytes) -cne $enUSJson) {
        throw 'FAIL: en-US.json content was altered.'
    }
    Write-Host 'PASS: en-US.json content preserved.' -ForegroundColor Green

    $payloadBytes = Read-AsarEntryBytes $asarPath $parsed 'payload.bin'
    if ($payloadBytes.Length -ne 10000 -or $payloadBytes[5000] -ne (5000 % 251) -or $payloadBytes[9999] -ne (9999 % 251)) {
        throw 'FAIL: payload.bin bytes were corrupted.'
    }
    Write-Host 'PASS: existing payload preserved byte-for-byte.' -ForegroundColor Green

    if ($script:BackedUpFiles.Count -ne 1 -or $script:SyncedResources.Count -ne 1) {
        throw "FAIL: expected 1 backup and 1 sync call, got backup=$($script:BackedUpFiles.Count) sync=$($script:SyncedResources.Count)."
    }

    # --- Test 4: idempotency ---
    $sizeBefore = (Get-Item -LiteralPath $asarPath).Length
    Add-ShellLocaleCatalog $resources 'zh-CN'
    $sizeAfter = (Get-Item -LiteralPath $asarPath).Length
    if ($sizeAfter -ne $sizeBefore) {
        throw "FAIL: Add-ShellLocaleCatalog is not idempotent (before=$sizeBefore, after=$sizeAfter)."
    }
    Write-Host 'PASS: Add-ShellLocaleCatalog is idempotent.' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $temp) {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}