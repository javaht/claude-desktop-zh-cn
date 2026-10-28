$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Load-InstallerFunctions.ps1') -FunctionNames @(
    'Require-File',
    'Align-4',
    'Get-UInt32LE',
    'Get-Int32LE',
    'Read-AsarHeader',
    'Read-AsarHeaderFromFile',
    'Get-AsarEntryPaths',
    'Test-AsarFrontendArchive',
    'Test-FrontendBundleAvailable',
    'Get-FrontendBundleMode',
    'Expand-AsarArchive',
    'Get-AsarFileIntegrity',
    'New-AsarArchive'
)

$temp = Join-Path ([IO.Path]::GetTempPath()) ('claude-asar-tests-' + [guid]::NewGuid().ToString('N'))
$source = Join-Path $temp 'source'
$extracted = Join-Path $temp 'extracted'
$updatedExtracted = Join-Path $temp 'updated-extracted'
$resources = Join-Path $temp 'resources'
$archive = Join-Path $resources 'ion-dist.asar'
$updatedArchive = Join-Path $temp 'ion-dist-updated.asar'
$utf8NoBom = [Text.UTF8Encoding]::new($false)
$AsarIntegrityBlockSize = 4MB

try {
    $assets = Join-Path $source 'assets\v1'
    $i18n = Join-Path $source 'i18n'
    $dynamic = Join-Path $i18n 'dynamic'
    New-Item -ItemType Directory -Path $assets -Force | Out-Null
    New-Item -ItemType Directory -Path $dynamic -Force | Out-Null
    New-Item -ItemType Directory -Path $resources -Force | Out-Null

    [IO.File]::WriteAllText(
        (Join-Path $assets 'index-fixture.js'),
        'const supported=["en-US","de-DE","fr-FR","ko-KR","ja-JP"];',
        $utf8NoBom
    )
    [IO.File]::WriteAllText((Join-Path $i18n 'en-US.json'), '{"hello":"Hello"}', $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $dynamic 'en-US.json'), '{"dynamic":"Dynamic"}', $utf8NoBom)
    $binary = [byte[]](0..255)
    [IO.File]::WriteAllBytes((Join-Path $source 'fixture.bin'), $binary)

    New-AsarArchive $source $archive
    if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
        throw 'New-AsarArchive did not create the archive.'
    }
    if ((Get-FrontendBundleMode $resources) -ne 'Asar') {
        throw 'ion-dist.asar was not detected as the ASAR frontend layout.'
    }
    if (-not (Test-FrontendBundleAvailable $resources)) {
        throw 'A valid ion-dist.asar was rejected.'
    }

    Expand-AsarArchive $archive $extracted
    $roundTripBinary = [IO.File]::ReadAllBytes((Join-Path $extracted 'fixture.bin'))
    if ([Convert]::ToBase64String($roundTripBinary) -cne [Convert]::ToBase64String($binary)) {
        throw 'Binary archive entry was not preserved.'
    }

    [IO.File]::WriteAllText((Join-Path $extracted 'i18n\zh-CN.json'), '{"hello":"你好"}', $utf8NoBom)
    New-AsarArchive $extracted $updatedArchive
    Expand-AsarArchive $updatedArchive $updatedExtracted
    if (-not (Test-Path -LiteralPath (Join-Path $updatedExtracted 'i18n\zh-CN.json'))) {
        throw 'New nested ASAR entry was not installed.'
    }
    $updatedText = [IO.File]::ReadAllText((Join-Path $updatedExtracted 'i18n\zh-CN.json'), [Text.Encoding]::UTF8)
    if ($updatedText -notmatch '你好') {
        throw 'Updated ASAR entry content did not round-trip.'
    }

    Write-Host 'PASS: ion-dist.asar detection and binary-safe archive round-trip.' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $temp) {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
