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
    'Get-AsarFileIntegrity',
    'Get-AsarIntegrityFromBytes',
    'Get-AsarEntryNode',
    'Read-AsarEntryBytes',
    'Write-AsarArchiveWithHeader',
    'Set-AsarEntryContent',
    'Add-AsarEntryContent',
    'Get-AsarHeaderHash',
    'Expand-AsarArchive',
    'New-AsarArchive',
    'Get-BackupRoot',
    'New-BackupSet',
    'Get-RelativeResourcePath',
    'Backup-ModifiedFile',
    'Backup-AppFile',
    'Get-ClaudeAppPathFromResources',
    'Get-ClaudeExePathFromResources',
    'Get-ClaudeExeIntegrityMarker',
    'Sync-ClaudeExeAsarIntegrity',
    'Merge-LocaleJson',
    'Merge-LocaleOverride',
    'Patch-DesktopShellLocale'
)

$temp = Join-Path ([IO.Path]::GetTempPath()) ('claude-desktop-shell-' + [guid]::NewGuid().ToString('N'))
$app = Join-Path $temp 'app'
$resources = Join-Path $app 'resources'
$fixture = Join-Path $temp 'fixture'
$utf8NoBom = [Text.UTF8Encoding]::new($false)
$AsarIntegrityBlockSize = 4MB

function Get-EntryBytes {
    param([string]$AsarPath, [string]$EntryPath)

    $parsed = Read-AsarHeaderFromFile $AsarPath
    return ,(Read-AsarEntryBytes $AsarPath $parsed $EntryPath)
}

try {
    New-Item -ItemType Directory -Path $resources -Force | Out-Null
    $i18n = Join-Path (Join-Path $fixture 'resources') 'i18n'
    New-Item -ItemType Directory -Path $i18n -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fixture 'node_modules') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fixture 'bin') -Force | Out-Null

    # 真实 app.asar 的壳层词库位于 resources/i18n/。这里同时准备一个未翻译键，
    # 合并后必须原样保留英文。
    [IO.File]::WriteAllText((Join-Path $i18n 'en-US.json'), '{"EfdnINFnIz":"File","qHPWFPPScPZ":"Settings","OnlyEnglish":"Only English"}', $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $fixture 'main.js'), 'const locale="en-US";', $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path (Join-Path $fixture 'node_modules') 'native.node'), 'native-binary-payload', $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path (Join-Path $fixture 'bin') 'helper.sh'), '#!/bin/sh', $utf8NoBom)

    $appAsar = Join-Path $resources 'app.asar'
    New-AsarArchive $fixture $appAsar

    # 复刻真实包的元数据：unpacked 原生模块、executable 文件、link 条目。
    # 旧实现遇到 unpacked 会直接跳过汉化，这三种标记也必须原样保留。
    $parsed = Read-AsarHeaderFromFile $appAsar
    $header = $parsed["Header"]
    $nativeNode = Get-AsarEntryNode $header 'node_modules/native.node'
    $nativeNode | Add-Member -NotePropertyName unpacked -NotePropertyValue $true
    $helperNode = Get-AsarEntryNode $header 'bin/helper.sh'
    $helperNode | Add-Member -NotePropertyName executable -NotePropertyValue $true
    $i18nNode = Get-AsarEntryNode $header 'resources/i18n'
    $i18nNode.files | Add-Member -NotePropertyName 'en-GB.json' -NotePropertyValue ([pscustomobject]@{ link = 'en-US.json' })
    Write-AsarArchiveWithHeader -AsarPath $appAsar -ResourcesPath $resources -Parsed $parsed -Header $header -Append ([byte[]]::new(0))

    $marked = Read-AsarHeaderFromFile $appAsar
    $nativeOffset = [int64](Get-AsarEntryNode $marked["Header"] 'node_modules/native.node').offset
    $nativeSize = [int64](Get-AsarEntryNode $marked["Header"] 'node_modules/native.node').size

    # Claude.exe 内嵌 app.asar 头哈希（JSON 转义写法，4.4212+ 的实际格式）。
    $exe = Join-Path $app 'Claude.exe'
    $marker = 'resources\\app.asar","alg":"SHA256","value":"'
    [IO.File]::WriteAllText($exe, ($marker + (Get-AsarHeaderHash $appAsar) + '"}PAD'), [Text.Encoding]::ASCII)

    # Install-LanguageFiles 会把桌面词库写到 resources\<lang>.json。
    $desktopPack = Join-Path $resources 'zh-CN.json'
    [IO.File]::WriteAllText($desktopPack, '{"EfdnINFnIz":"文件","tyiWynSRix":"新建任务"}', $utf8NoBom)
    $mainJsBefore = [Text.Encoding]::UTF8.GetString((Get-EntryBytes $appAsar 'main.js'))

    Patch-DesktopShellLocale $resources 'zh-CN'

    $backupRoot = Get-BackupRoot $resources
    $backup = Get-ChildItem -LiteralPath $backupRoot -File -Recurse |
        Where-Object { $_.Name -eq 'app.asar' } |
        Select-Object -First 1
    if (-not $backup) {
        throw 'Original app.asar was not backed up before patching.'
    }

    $patched = Read-AsarHeaderFromFile $appAsar
    $patchedPaths = @(Get-AsarEntryPaths $patched["Header"])
    foreach ($path in @('node_modules/native.node', 'bin/helper.sh', 'resources/i18n/en-GB.json', 'main.js')) {
        if ($patchedPaths -notcontains $path) {
            throw "Metadata entry went missing after patching: $path"
        }
    }

    # unpacked / executable / link 元数据必须原样保留（真实包缺了这些应用直接起不来）。
    $patchedNative = Get-AsarEntryNode $patched["Header"] 'node_modules/native.node'
    if (-not ($patchedNative.PSObject.Properties['unpacked']) -or -not [bool]$patchedNative.unpacked) {
        throw 'unpacked flag was dropped when rewriting app.asar.'
    }
    if ([int64]$patchedNative.offset -ne $nativeOffset -or [int64]$patchedNative.size -ne $nativeSize) {
        throw 'unpacked entry offset/size changed when rewriting app.asar.'
    }
    $patchedHelper = Get-AsarEntryNode $patched["Header"] 'bin/helper.sh'
    if (-not ($patchedHelper.PSObject.Properties['executable']) -or -not [bool]$patchedHelper.executable) {
        throw 'executable flag was dropped when rewriting app.asar.'
    }
    $patchedLink = Get-AsarEntryNode $patched["Header"] 'resources/i18n/en-GB.json'
    if (-not $patchedLink.PSObject.Properties['link']) {
        throw 'link entry was dropped when rewriting app.asar.'
    }

    $mainJsAfter = [Text.Encoding]::UTF8.GetString((Get-EntryBytes $appAsar 'main.js'))
    if ($mainJsAfter -ne $mainJsBefore) {
        throw 'Untouched payload entry was corrupted by the rewrite.'
    }

    $mergedText = [Text.Encoding]::UTF8.GetString((Get-EntryBytes $appAsar 'resources/i18n/en-US.json'))
    if ($mergedText -notmatch '文件') {
        throw 'Chinese translations were not merged into resources/i18n/en-US.json.'
    }
    if ($mergedText -notmatch 'Only English') {
        throw 'Untranslated keys must stay in English.'
    }
    $catalog = [Text.Encoding]::UTF8.GetString((Get-EntryBytes $appAsar 'resources/i18n/zh-CN.json'))
    if ($catalog -ne [IO.File]::ReadAllText($desktopPack, [Text.Encoding]::UTF8)) {
        throw 'Desktop shell catalog was not added to app.asar.'
    }

    # 头哈希变了，Claude.exe 里的值必须同步，否则 Electron 会拒绝加载 app.asar。
    $exeText = [IO.File]::ReadAllText($exe, [Text.Encoding]::ASCII)
    $hashIndex = $exeText.IndexOf($marker, [StringComparison]::Ordinal) + $marker.Length
    if ($hashIndex -lt $marker.Length) {
        throw 'Integrity marker went missing from the patched Claude.exe.'
    }
    if ($exeText.Substring($hashIndex, 64) -ne (Get-AsarHeaderHash $appAsar)) {
        throw 'Claude.exe app.asar integrity hash was not synchronized after patching.'
    }

    # 幂等：词库没有新条目时不应再次改写，也不应再次备份。
    $headerBefore = (Read-AsarHeaderFromFile $appAsar)["HeaderString"]
    Patch-DesktopShellLocale $resources 'zh-CN'
    if ((Read-AsarHeaderFromFile $appAsar)["HeaderString"] -ne $headerBefore) {
        throw 'Patch-DesktopShellLocale is not idempotent.'
    }

    # --- Merge-LocaleOverride：文件级合并（覆盖 + 补键 + 非字符串跳过 + 幂等） ---
    $mergeDir = Join-Path $temp 'merge'
    New-Item -ItemType Directory -Path $mergeDir -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $mergeDir 'en-US.json'), '{"a":"Alpha","b":"Beta","n":1}', $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $mergeDir 'zh-CN.json'), '{"a":"甲","c":"丙","n":2}', $utf8NoBom)
    $changed = Merge-LocaleOverride $mergeDir 'zh-CN'
    if ($changed -ne 2) {
        throw "Expected 2 merged entries, got $changed."
    }
    $mergedFile = [IO.File]::ReadAllText((Join-Path $mergeDir 'en-US.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($mergedFile.a -ne '甲' -or $mergedFile.b -ne 'Beta' -or $mergedFile.c -ne '丙') {
        throw 'Merge-LocaleOverride overwrote or dropped unexpected keys.'
    }
    if ((Merge-LocaleOverride $mergeDir 'zh-CN') -ne 0) {
        throw 'Merge-LocaleOverride should be idempotent.'
    }

    Write-Host 'PASS: desktop shell locale is applied in place without losing app.asar metadata.' -ForegroundColor Green
    Write-Host 'PASS: Claude.exe integrity hash is synchronized after patching app.asar.' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $temp) {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
