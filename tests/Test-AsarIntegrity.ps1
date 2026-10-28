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
    'Get-AsarHeaderHash',
    'Get-AsarFileIntegrity',
    'New-AsarArchive',
    'Get-ClaudeAppPathFromResources',
    'New-BackupSet',
    'Get-BackupRoot',
    'Backup-AppFile',
    'Sync-ClaudeExeAsarIntegrity'
)

$temp = Join-Path ([IO.Path]::GetTempPath()) ('claude-asar-integrity-' + [guid]::NewGuid().ToString('N'))
$app = Join-Path $temp 'app'
$resources = Join-Path $app 'resources'
$exe = Join-Path $app 'Claude.exe'
$utf8NoBom = [Text.UTF8Encoding]::new($false)
$AsarIntegrityBlockSize = 4MB

try {
    New-Item -ItemType Directory -Path $resources -Force | Out-Null
    $fixture = Join-Path $temp 'fixture'
    New-Item -ItemType Directory -Path $fixture -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $fixture 'index.js'), 'console.log("fixture")', $utf8NoBom)

    $appAsar = Join-Path $resources 'app.asar'
    $ionAsar = Join-Path $resources 'ion-dist.asar'
    New-AsarArchive $fixture $appAsar
    New-AsarArchive $fixture $ionAsar

    $appMarker = 'resources\\app.asar","alg":"SHA256","value":"'
    $ionMarker = 'resources\\ion-dist.asar","alg":"SHA256","value":"'
    $exeText = $appMarker + (Get-AsarHeaderHash $appAsar) + '"}PAD' +
        $ionMarker + ('0' * 64) + '"}PAD'
    [IO.File]::WriteAllText($exe, $exeText, [Text.Encoding]::ASCII)
    $script:CurrentBackupSetPath = Join-Path $resources '.zh-cn-backups\fixture'
    New-Item -ItemType Directory -Path $script:CurrentBackupSetPath -Force | Out-Null

    Sync-ClaudeExeAsarIntegrity $resources

    $actual = [IO.File]::ReadAllText($exe, [Text.Encoding]::ASCII)
    $appIndex = $actual.IndexOf($appMarker, [StringComparison]::Ordinal) + $appMarker.Length
    $ionIndex = $actual.IndexOf($ionMarker, [StringComparison]::Ordinal) + $ionMarker.Length
    if ($appIndex -lt $appMarker.Length -or $ionIndex -lt $ionMarker.Length) {
        throw 'Integrity markers are missing from the fixture.'
    }
    if ($actual.Substring($appIndex, 64) -ne (Get-AsarHeaderHash $appAsar)) {
        throw 'app.asar integrity hash was not synchronized.'
    }
    if ($actual.Substring($ionIndex, 64) -ne (Get-AsarHeaderHash $ionAsar)) {
        throw 'ion-dist.asar integrity hash was not synchronized.'
    }

    Write-Host 'PASS: Claude.exe integrity hashes cover app.asar and ion-dist.asar.' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $temp) {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
