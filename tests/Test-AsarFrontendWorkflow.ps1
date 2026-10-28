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
    'Test-AsarFrontendArchive',
    'Get-FrontendBundleMode',
    'Expand-AsarArchive',
    'Get-AsarFileIntegrity',
    'New-AsarArchive',
    'Get-BackupRoot',
    'New-BackupSet',
    'Get-RelativeResourcePath',
    'Backup-ModifiedFile',
    'Get-ClaudeAppPathFromResources',
    'Backup-AppFile',
    'Get-AsarHeaderHash',
    'Sync-ClaudeExeAsarIntegrity',
    'Remove-GeneratedFrontendWorkspace',
    'Initialize-FrontendPatchTarget',
    'Complete-FrontendPatchTarget',
    'Close-FrontendPatchTarget'
)

$temp = Join-Path ([IO.Path]::GetTempPath()) ('claude-asar-workflow-' + [guid]::NewGuid().ToString('N'))
$app = Join-Path $temp 'app'
$resources = Join-Path $app 'resources'
$source = Join-Path $temp 'source'
$utf8NoBom = [Text.UTF8Encoding]::new($false)
$AsarIntegrityBlockSize = 4MB

try {
    $assets = Join-Path $source 'assets\v1'
    $i18n = Join-Path $source 'i18n'
    New-Item -ItemType Directory -Path $assets -Force | Out-Null
    New-Item -ItemType Directory -Path $i18n -Force | Out-Null
    New-Item -ItemType Directory -Path $resources -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $assets 'index-fixture.js'), 'const x="original";', $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $i18n 'en-US.json'), '{"hello":"Hello"}', $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $source 'index.html'), '<html></html>', $utf8NoBom)

    $ionAsar = Join-Path $resources 'ion-dist.asar'
    $appAsar = Join-Path $resources 'app.asar'
    New-AsarArchive $source $ionAsar
    New-AsarArchive $source $appAsar

    $appMarker = 'resources\\app.asar","alg":"SHA256","value":"' + (Get-AsarHeaderHash $appAsar) + '"}PAD'
    $ionMarker = 'resources\\ion-dist.asar","alg":"SHA256","value":"' + (Get-AsarHeaderHash $ionAsar) + '"}PAD'
    [IO.File]::WriteAllText((Join-Path $app 'Claude.exe'), $appMarker + $ionMarker, [Text.Encoding]::ASCII)

    $staleWorkspace = Join-Path $resources 'ion-dist'
    New-Item -ItemType Directory -Path $staleWorkspace -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $staleWorkspace 'stale.txt'), 'stale', $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $resources '.zh-cn-asar-extracted'), $ionAsar, $utf8NoBom)
    if ((Get-FrontendBundleMode $resources) -ne 'Asar') {
        throw 'A generated workspace must not override the existing ion-dist.asar layout.'
    }

    $target = Initialize-FrontendPatchTarget $resources
    try {
        if ($target.Mode -ne 'Asar') {
            throw 'ASAR mode was not selected.'
        }
        if (Test-Path -LiteralPath (Join-Path $staleWorkspace 'stale.txt')) {
            throw 'A stale generated workspace was not cleaned before extraction.'
        }
        $work = Join-Path $resources 'ion-dist'
        if (-not (Test-Path -LiteralPath (Join-Path $work 'assets\v1\index-fixture.js'))) {
            throw 'Archive was not expanded into the patch workspace.'
        }
        $backup = Get-ChildItem -LiteralPath (Get-BackupRoot $resources) -File -Recurse |
            Where-Object { $_.Name -eq 'ion-dist.asar' } |
            Select-Object -First 1
        if (-not $backup) {
            throw 'Original ion-dist.asar was not backed up.'
        }

        [IO.File]::WriteAllText((Join-Path $work 'i18n\zh-CN.json'), '{"hello":"你好"}', $utf8NoBom)
        Complete-FrontendPatchTarget $target
    }
    finally {
        Close-FrontendPatchTarget $target
    }

    if (Test-Path -LiteralPath (Join-Path $resources 'ion-dist')) {
        throw 'The expanded patch workspace was not cleaned up.'
    }
    $verify = Join-Path $temp 'verify'
    Expand-AsarArchive $ionAsar $verify
    $translated = [IO.File]::ReadAllText((Join-Path $verify 'i18n\zh-CN.json'), [Text.Encoding]::UTF8)
    if ($translated -notmatch '你好') {
        throw 'The rebuilt ion-dist.asar does not contain the installed locale.'
    }

    Write-Host 'PASS: ASAR install workflow backs up, expands, rebuilds, verifies, and cleans up.' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $temp) {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
