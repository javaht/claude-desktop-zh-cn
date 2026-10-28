param(
    [Parameter(Mandatory = $true)]
    [string]$ArchivePath
)

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$tempName = '.tmp-asar-roundtrip-' + [guid]::NewGuid().ToString('N')
$temp = [IO.Path]::GetFullPath((Join-Path $workspace $tempName)).TrimEnd('\', '/')
if (-not $temp.StartsWith($workspace.TrimEnd('\', '/') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe temporary path: $temp"
}

. (Join-Path $PSScriptRoot 'Load-InstallerFunctions.ps1') -FunctionNames @(
    'Require-File',
    'Align-4',
    'Get-UInt32LE',
    'Get-Int32LE',
    'Read-AsarHeader',
    'Read-AsarHeaderFromFile',
    'Get-AsarEntryPaths',
    'Test-AsarFrontendArchive',
    'Expand-AsarArchive',
    'Get-AsarFileIntegrity',
    'New-AsarArchive'
)
$AsarIntegrityBlockSize = 4MB

New-Item -ItemType Directory -Path $temp -Force | Out-Null
try {
    $extracted = Join-Path $temp 'extracted'
    $rebuilt = Join-Path $temp 'ion-dist.rebuilt.asar'
    $roundTrip = Join-Path $temp 'roundtrip'

    $original = Read-AsarHeaderFromFile $ArchivePath
    $originalMap = @{}
    $collect = {
        param($Node, [string]$Prefix)
        foreach ($property in $Node.files.PSObject.Properties) {
            $path = if ($Prefix) { "$Prefix/$($property.Name)" } else { $property.Name }
            $child = $property.Value
            if ($child.PSObject.Properties['files']) {
                & $collect $child $path
            }
            else {
                $originalMap[$path] = [pscustomobject]@{
                    Size = [int64]$child.size
                    Hash = [string]$child.integrity.hash
                }
            }
        }
    }
    & $collect $original.Header ''

    Expand-AsarArchive $ArchivePath $extracted
    New-AsarArchive $extracted $rebuilt
    if (-not (Test-AsarFrontendArchive $rebuilt)) {
        throw 'Rebuilt archive failed frontend structure validation.'
    }

    $newParsed = Read-AsarHeaderFromFile $rebuilt
    $newMap = @{}
    $collectNew = {
        param($Node, [string]$Prefix)
        foreach ($property in $Node.files.PSObject.Properties) {
            $path = if ($Prefix) { "$Prefix/$($property.Name)" } else { $property.Name }
            $child = $property.Value
            if ($child.PSObject.Properties['files']) {
                & $collectNew $child $path
            }
            else {
                $newMap[$path] = [pscustomobject]@{
                    Size = [int64]$child.size
                    Hash = [string]$child.integrity.hash
                }
            }
        }
    }
    & $collectNew $newParsed.Header ''
    if ($newMap.Count -ne $originalMap.Count) {
        throw "Entry count changed: $($originalMap.Count) -> $($newMap.Count)"
    }
    foreach ($path in $originalMap.Keys) {
        if (-not $newMap.ContainsKey($path)) {
            throw "Missing rebuilt entry: $path"
        }
        if ($newMap[$path].Size -ne $originalMap[$path].Size -or $newMap[$path].Hash -cne $originalMap[$path].Hash) {
            throw "Header integrity changed: $path"
        }
    }

    Expand-AsarArchive $rebuilt $roundTrip
    $verified = 0
    foreach ($path in $originalMap.Keys) {
        $file = Join-Path $roundTrip ($path -replace '/', '\')
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            throw "Missing round-trip file: $path"
        }
        $integrity = Get-AsarFileIntegrity $file
        if ($integrity.hash -cne $originalMap[$path].Hash) {
            throw "Round-trip content changed: $path"
        }
        $verified++
    }

    Write-Host "PASS: real ASAR round-trip verified for $verified entries." -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $temp) {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
