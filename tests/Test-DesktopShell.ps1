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
    'Get-AsarUnsupportedEntryPaths',
    'Get-AsarFileIntegrity',
    'Expand-AsarArchive',
    'New-AsarArchive',
    'Get-BackupRoot',
    'New-BackupSet',
    'Get-RelativeResourcePath',
    'Backup-ModifiedFile',
    'Merge-LocaleOverride',
    'Patch-DesktopShellLocale'
)

$temp = Join-Path ([IO.Path]::GetTempPath()) ('claude-desktop-shell-' + [guid]::NewGuid().ToString('N'))
$app = Join-Path $temp 'app'
$resources = Join-Path $app 'resources'
$fixture = Join-Path $temp 'fixture'
$utf8NoBom = [Text.UTF8Encoding]::new($false)
$AsarIntegrityBlockSize = 4MB

try {
    $i18n = Join-Path (Join-Path $fixture 'resources') 'i18n'
    New-Item -ItemType Directory -Path $i18n -Force | Out-Null
    New-Item -ItemType Directory -Path $resources -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $i18n 'en-US.json'), '{"EfdnINFnIz":"File","qHPWFPPScPZ":"Settings"}', $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $fixture 'main.js'), 'const locale="en-US";', $utf8NoBom)

    $appAsar = Join-Path $resources 'app.asar'
    New-AsarArchive $fixture $appAsar

    # Install-LanguageFiles 会把桌面词库写到 resources\<lang>.json。
    $desktopPack = Join-Path $resources 'zh-CN.json'
    [IO.File]::WriteAllText($desktopPack, '{"EfdnINFnIz":"文件","tyiWynSRix":"新建任务"}', $utf8NoBom)

    Patch-DesktopShellLocale $resources 'zh-CN'

    $backup = Get-ChildItem -LiteralPath (Get-BackupRoot $resources) -File -Recurse |
        Where-Object { $_.Name -eq 'app.asar' } |
        Select-Object -First 1
    if (-not $backup) {
        throw 'Original app.asar was not backed up before rebuilding.'
    }

    $verify = Join-Path $temp 'verify'
    Expand-AsarArchive $appAsar $verify
    $installedPack = Join-Path (Join-Path (Join-Path $verify 'resources') 'i18n') 'zh-CN.json'
    if (-not (Test-Path -LiteralPath $installedPack -PathType Leaf)) {
        throw 'The desktop shell locale was not added to app.asar.'
    }
    $text = [IO.File]::ReadAllText($installedPack, [Text.Encoding]::UTF8)
    if ($text -notmatch '文件') {
        throw 'The desktop shell locale content was not preserved.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $verify 'main.js') -PathType Leaf)) {
        throw 'Rebuilding app.asar dropped an original entry.'
    }

    # 主进程只加载 en-US，所以译文必须同时覆盖进 en-US.json 才能生效。
    $enUs = Get-Content -LiteralPath (Join-Path (Join-Path (Join-Path $verify 'resources') 'i18n') 'en-US.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$enUs.EfdnINFnIz -ne '文件') {
        throw 'Existing en-US shell text was not overridden by the Chinese pack.'
    }
    if ([string]$enUs.tyiWynSRix -ne '新建任务') {
        throw 'A shell key missing from en-US.json was not added.'
    }
    if ([string]$enUs.qHPWFPPScPZ -ne 'Settings') {
        throw 'Shell keys without a Chinese translation must keep their English text.'
    }

    # 幂等：第二次调用不应再次重建。
    $hashAfterFirst = (Get-Item -LiteralPath $appAsar).Length
    Patch-DesktopShellLocale $resources 'zh-CN'
    if ((Get-Item -LiteralPath $appAsar).Length -ne $hashAfterFirst) {
        throw 'Patch-DesktopShellLocale is not idempotent.'
    }

    # 前端 i18n 目录同样复用 Merge-LocaleOverride：override 优先、缺失键补齐、非字符串忽略。
    $frontendI18n = Join-Path $temp 'frontend\i18n'
    New-Item -ItemType Directory -Path $frontendI18n -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $frontendI18n 'en-US.json'), '{"a":"Alpha","b":"Beta"}', $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $frontendI18n 'zh-CN.json'), '{"a":"甲","c":"丙","d":123}', $utf8NoBom)
    $mergedCount = Merge-LocaleOverride $frontendI18n 'zh-CN'
    if ($mergedCount -ne 2) {
        throw "Expected 2 merged entries, got $mergedCount."
    }
    $frontendMerged = Get-Content -LiteralPath (Join-Path $frontendI18n 'en-US.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$frontendMerged.a -ne '甲' -or [string]$frontendMerged.b -ne 'Beta' -or [string]$frontendMerged.c -ne '丙') {
        throw 'Merge-LocaleOverride produced unexpected frontend values.'
    }
    if ($frontendMerged.PSObject.Properties.Name -contains 'd') {
        throw 'Non-string override values must be skipped.'
    }
    $secondMerge = Merge-LocaleOverride $frontendI18n 'zh-CN'
    if ($secondMerge -ne 0) {
        throw 'Merge-LocaleOverride is not idempotent.'
    }

    Write-Host 'PASS: desktop shell locale is added to app.asar and merged into en-US.' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $temp) {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
