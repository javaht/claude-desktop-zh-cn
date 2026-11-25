$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Load-InstallerFunctions.ps1') -FunctionNames @(
    'Format-ByteSize',
    'Require-File',
    'Align-4',
    'Get-UInt32LE',
    'Get-Int32LE',
    'Get-Sha256Hex',
    'Read-AsarHeader',
    'Read-AsarHeaderFromFile',
    'Get-AsarEntryPaths',
    'Get-AsarEntryNode',
    'Read-AsarEntryBytes',
    'Get-AsarFileIntegrity',
    'Get-AsarIntegrityFromBytes',
    'Test-AsarFrontendArchive',
    'Get-FrontendBundleMode',
    'Expand-AsarArchive',
    'New-AsarArchive',
    'Get-BackupRoot',
    'New-BackupSet',
    'Get-RelativeResourcePath',
    'Backup-ModifiedFile',
    'Backup-AppFile',
    'Get-ClaudeAppPathFromResources',
    'Get-ClaudeExePathFromResources',
    'Get-AsarHeaderHash',
    'Get-ClaudeExeIntegrityMarker',
    'Assert-ClaudeExeIntegrityMarkers',
    'Sync-ClaudeExeAsarIntegrity',
    'Merge-LocaleJson',
    'Test-FileReplaceable',
    'Assert-AsarReplaceable',
    'Move-FileWithRetry',
    'Remove-GeneratedFrontendWorkspace',
    'Test-StructuralJsReplacement',
    'Test-PlainUiTextReplacement',
    'Get-FrontendHardcodedReplacements',
    'Get-SlashCommandGlossConfig',
    'Convert-SlashCommandMenuText',
    'Patch-AsarFrontendDirect'
)

# Load constants and C# fast-path definition from install_windows.ps1
$installerPath = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts') 'install_windows.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($installerPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw "Parse errors in install_windows.ps1: $($parseErrors[0].Message)"
}
foreach ($stmt in $ast.EndBlock.Statements) {
    if ($stmt -is [System.Management.Automation.Language.AssignmentStatementAst]) {
        $lhs = $stmt.Left.Extent.Text
        if ($lhs -match 'Utf8NoBom|BaseLanguageList|LanguageListPattern|AsarIntegrityBlockSize|FrontendPatcherCSharp') {
            . ([scriptblock]::Create($stmt.Extent.Text))
        }
    }
}
if (-not ('ClaudeZhPatch.AsarHelper' -as [type])) {
    Add-Type -TypeDefinition $script:FrontendPatcherCSharp -ErrorAction Stop
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('claude-direct-asar-fastpath-' + [guid]::NewGuid().ToString('N'))
$app = Join-Path $temp 'app'
$resources = Join-Path $app 'resources'
$source = Join-Path $temp 'source'
$utf8NoBom = [Text.UTF8Encoding]::new($false)

try {
    # 1. Build a synthetic ion-dist.asar covering whitelist, hardcoded plain+raw rules,
    #    structural skip protection, Intl.DisplayNames, i18n/en-US.json, dynamic/en-US.json,
    #    and an untouched binary payload.
    $assets = Join-Path (Join-Path $source 'assets') 'v1'
    $i18n = Join-Path $source 'i18n'
    $dynamic = Join-Path $i18n 'dynamic'
    New-Item -ItemType Directory -Path $assets -Force | Out-Null
    New-Item -ItemType Directory -Path $dynamic -Force | Out-Null
    New-Item -ItemType Directory -Path $resources -Force | Out-Null

    $jsWhitelist = "const langs=[$BaseLanguageList];"
    $jsHardcoded = 'const a="Settings",b="Copy",c="not-a-match",d={case:"Settings"};'
    $jsDisplay = 'const dn=new Intl.DisplayNames(["en"],{type:"language"});'
    [IO.File]::WriteAllText((Join-Path $assets 'index-main.js'), $jsWhitelist + "`n" + $jsHardcoded, $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $assets 'chunk-intl.js'), $jsDisplay, $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $i18n 'en-US.json'), '{"EfdnINFnIz":"File","artifactKey":"artifact","KeepMe":"Keep English"}', $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $dynamic 'en-US.json'), '{"dyn":"value"}', $utf8NoBom)
    $binaryBytes = [byte[]](0, 1, 2, 3, 255, 254, 128, 64, 42, 0, 99)
    [IO.File]::WriteAllBytes((Join-Path $source 'logo.bin'), $binaryBytes)

    $ionAsar = Join-Path $resources 'ion-dist.asar'
    New-AsarArchive $source $ionAsar

    $packDir = Join-Path $temp 'pack'
    New-Item -ItemType Directory -Path $packDir -Force | Out-Null
    $zhFile = ([char]0x6587) + ([char]0x4EF6)
    $frontendPack = Join-Path $packDir 'frontend-zh-CN.json'
    $statsigPack = Join-Path $packDir 'statsig-zh-CN.json'
    [IO.File]::WriteAllText($frontendPack, ('{"EfdnINFnIz":"' + $zhFile + '","artifactKey":"Artifact","AddedKey":"Added"}'), $utf8NoBom)
    [IO.File]::WriteAllText($statsigPack, '{"flag":"ok"}', $utf8NoBom)
    $pack = @{
        Frontend = $frontendPack
        Statsig = $statsigPack
    }

    # First run: patches in-place without leaving ion-dist directory on disk
    Patch-AsarFrontendDirect $resources $pack 'zh-CN'

    if (Test-Path -LiteralPath (Join-Path $resources 'ion-dist')) {
        throw 'Patch-AsarFrontendDirect must not leave an extracted ion-dist directory on disk.'
    }
    $backup = Get-ChildItem -LiteralPath (Get-BackupRoot $resources) -File -Recurse |
        Where-Object { $_.Name -eq 'ion-dist.asar' } |
        Select-Object -First 1
    if (-not $backup) {
        throw 'Patch-AsarFrontendDirect did not back up original ion-dist.asar.'
    }

    $verifyDir = Join-Path $temp 'verify'
    Expand-AsarArchive $ionAsar $verifyDir

    $patchedMain = [IO.File]::ReadAllText((Join-Path (Join-Path (Join-Path $verifyDir 'assets') 'v1') 'index-main.js'), [Text.Encoding]::UTF8)
    if ($patchedMain -notmatch '"zh-CN"') {
        throw 'Whitelist was not patched by Patch-AsarFrontendDirect.'
    }
    $patchedIntl = [IO.File]::ReadAllText((Join-Path (Join-Path (Join-Path $verifyDir 'assets') 'v1') 'chunk-intl.js'), [Text.Encoding]::UTF8)
    if (-not $patchedIntl.Contains('__claudeZhLabelPatch')) {
        throw 'Intl.DisplayNames patch was not applied by Patch-AsarFrontendDirect.'
    }
    $verifyI18n = Join-Path $verifyDir 'i18n'
    $mergedEnUs = [IO.File]::ReadAllText((Join-Path $verifyI18n 'en-US.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($mergedEnUs.EfdnINFnIz -ne $zhFile -or $mergedEnUs.artifactKey -ne 'Artifact' -or $mergedEnUs.KeepMe -ne 'Keep English' -or $mergedEnUs.AddedKey -ne 'Added') {
        throw 'i18n/en-US.json merge in direct ASAR path did not match expected entries.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $verifyI18n 'zh-CN.json') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path (Join-Path $verifyI18n 'statsig') 'zh-CN.json') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path (Join-Path $verifyI18n 'dynamic') 'zh-CN.json') -PathType Leaf)) {
        throw 'Expected locale JSON files were not added to ion-dist.asar.'
    }
    $verifyBinary = [IO.File]::ReadAllBytes((Join-Path $verifyDir 'logo.bin'))
    if ($verifyBinary.Length -ne $binaryBytes.Length) {
        throw 'Untouched binary asset length changed.'
    }
    for ($i = 0; $i -lt $binaryBytes.Length; $i++) {
        if ($verifyBinary[$i] -ne $binaryBytes[$i]) {
            throw 'Untouched binary asset bytes were corrupted.'
        }
    }

    # Verify every integrity hash in rebuilt ion-dist.asar matches payload bytes
    $parsed = Read-AsarHeaderFromFile $ionAsar
    foreach ($entryPath in @(Get-AsarEntryPaths $parsed['Header'])) {
        $node = Get-AsarEntryNode $parsed['Header'] $entryPath
        $bytes = Read-AsarEntryBytes $ionAsar $parsed $entryPath
        $actualHash = Get-Sha256Hex $bytes
        if ([string]$node.integrity.hash -ne $actualHash) {
            throw "Integrity hash mismatch for ${entryPath}: expected $($node.integrity.hash), actual $actualHash"
        }
    }

    # Second run: must be idempotent and skip rewriting ion-dist.asar
    $hashBeforeSecond = Get-AsarHeaderHash $ionAsar
    $mtimeBeforeSecond = (Get-Item -LiteralPath $ionAsar).LastWriteTimeUtc
    Start-Sleep -Milliseconds 50
    Patch-AsarFrontendDirect $resources $pack 'zh-CN'
    $hashAfterSecond = Get-AsarHeaderHash $ionAsar
    $mtimeAfterSecond = (Get-Item -LiteralPath $ionAsar).LastWriteTimeUtc
    if ($hashAfterSecond -ne $hashBeforeSecond -or $mtimeAfterSecond -ne $mtimeBeforeSecond) {
        throw 'Second idempotent run of Patch-AsarFrontendDirect needlessly rewrote ion-dist.asar.'
    }

    # 2. ExeIntegrityHelper chunk-boundary test: marker straddles the 4 MB read boundary
    $boundaryExe = Join-Path $app 'Claude.exe'
    $boundaryMarker = '{"file":"resources\\ion-dist.asar","alg":"SHA256","value":"'
    $dummyHash = '0' * 64
    $chunkBoundary = 4 * 1024 * 1024
    $markerStart = $chunkBoundary - 12
    $exeBuf = [byte[]]::new($chunkBoundary + 1024)
    $markerBytes = [Text.Encoding]::ASCII.GetBytes($boundaryMarker + $dummyHash + '"}')
    [Array]::Copy($markerBytes, 0, $exeBuf, $markerStart, $markerBytes.Length)
    [IO.File]::WriteAllBytes($boundaryExe, $exeBuf)

    $offsets = [ClaudeZhPatch.ExeIntegrityHelper]::FindMarkerOffsets($boundaryExe, [string[]]@('ion-dist.asar'))
    $expectedHashOffset = [int64]($markerStart + $boundaryMarker.Length)
    if ($offsets.Length -ne 1 -or $offsets[0] -ne $expectedHashOffset) {
        throw "Chunk-boundary ExeIntegrityHelper offset mismatch: got $($offsets[0]), expected $expectedHashOffset"
    }

    # Sync-ClaudeExeAsarIntegrity on single-target exe (regression test for PS 1-element array unwrapping)
    Sync-ClaudeExeAsarIntegrity $resources
    $patchedExeBytes = [IO.File]::ReadAllBytes($boundaryExe)
    $writtenHash = [Text.Encoding]::ASCII.GetString($patchedExeBytes, [int]$expectedHashOffset, 64)
    if ($writtenHash -ne (Get-AsarHeaderHash $ionAsar)) {
        throw "Chunk-boundary Sync-ClaudeExeAsarIntegrity did not write expected header hash."
    }

    # 3. Aho-Corasick FrontendPatcher edge cases: overlapping prefix/suffix rules + quote matching
    $acDir = Join-Path $temp 'ac'
    New-Item -ItemType Directory -Path $acDir -Force | Out-Null
    $acFile = Join-Path $acDir 'sample.js'
    [IO.File]::WriteAllText($acFile, 'const t=["Save","Save As","Save As...","Unsaved",''Save'',`Save`];', $utf8NoBom)
    $rules = @(
        [object[]]@($true, 'Save As...', 'SAVE_AS_DOTS'),
        [object[]]@($true, 'Save As', 'SAVE_AS'),
        [object[]]@($true, 'Save', 'SAVE_ONLY')
    )
    $outArr = [string[]]::new(1)
    $counts = [ClaudeZhPatch.FrontendPatcher]::PatchFiles([string[]]@($acFile), [object[]]$rules, 1, $outArr)
    if ($counts[0] -ne 5 -or $outArr[0] -ne 'const t=["SAVE_ONLY","SAVE_AS","SAVE_AS_DOTS","Unsaved",''SAVE_ONLY'',`SAVE_ONLY`];') {
        throw "Aho-Corasick overlapping rule result unexpected: count=$($counts[0]) text=$($outArr[0])"
    }

    Write-Host 'PASS: Direct ASAR fast path, idempotent no-op skip, chunk-boundary EXE integrity, and Aho-Corasick overlap rules verified.' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $temp) {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
