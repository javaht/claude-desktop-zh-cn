$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Load-InstallerFunctions.ps1') -FunctionNames @(
    'Get-ClaudeAppxPackages',
    'Test-IsMicrosoftStorePackage',
    'Find-ClaudePath',
    'Get-AppxEntryForPath'
)

$temp = Join-Path ([IO.Path]::GetTempPath()) ('claude-desktop-restart-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    $pkgStore = Join-Path $temp 'AnthropicPBC.Claude_6.28899.2.0_x64__fnn82j28hfe8t'
    $pkgOfficialOld = Join-Path $temp 'Claude_5.1231.2.0_x64__pzs8sxrjxfjjc'
    $pkgOfficialNew = Join-Path $temp 'Claude_5.11492.5.0_x64__pzs8sxrjxfjjc'
    New-Item -ItemType Directory -Path $pkgStore, $pkgOfficialOld, $pkgOfficialNew -Force | Out-Null

    $officialManifest = @'
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10">
  <Applications>
    <Application Id="Claude" Executable="app\Claude.exe" />
  </Applications>
</Package>
'@
    $storeManifest = @'
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10">
  <Applications>
    <Application Id="Helper" Executable="app\helper.exe" />
    <Application Id="ClaudeStore" Executable="app\Claude.exe" />
  </Applications>
</Package>
'@
    Set-Content -LiteralPath (Join-Path $pkgOfficialOld 'AppxManifest.xml') -Value $officialManifest -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $pkgOfficialNew 'AppxManifest.xml') -Value $officialManifest -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $pkgStore 'AppxManifest.xml') -Value $storeManifest -Encoding UTF8

    # Mock: store package appears first and has a higher version than official packages.
    $script:MockPackages = @(
        [pscustomobject]@{
            Name              = 'AnthropicPBC.Claude'
            Version           = '6.28899.2.0'
            InstallLocation   = $pkgStore
            PackageFamilyName = 'AnthropicPBC.Claude_fnn82j28hfe8t'
        },
        [pscustomobject]@{
            Name              = 'Claude'
            Version           = '5.1231.2.0'
            InstallLocation   = $pkgOfficialOld
            PackageFamilyName = 'Claude_pzs8sxrjxfjjc'
        },
        [pscustomobject]@{
            Name              = 'Claude'
            Version           = '5.11492.5.0'
            InstallLocation   = $pkgOfficialNew
            PackageFamilyName = 'Claude_pzs8sxrjxfjjc'
        }
    )
    function script:Get-ClaudeAppxPackages {
        return $script:MockPackages
    }

    # --- Test 1: Find-ClaudePath prefers newest official package over Store package ---
    $selected = Find-ClaudePath
    if ($selected -ne $pkgOfficialNew) {
        throw "Find-ClaudePath must prefer newest official MSIX over Store package. Expected: $pkgOfficialNew, Got: $selected"
    }

    # --- Test 2: Get-AppxEntryForPath resolves exact package by install path ---
    $entryOfficial = Get-AppxEntryForPath $pkgOfficialNew
    if (-not $entryOfficial -or $entryOfficial.AppID -ne 'Claude_pzs8sxrjxfjjc!Claude') {
        throw "Get-AppxEntryForPath failed to resolve official build by path. Got: $($entryOfficial.AppID)"
    }
    $entryStore = Get-AppxEntryForPath ($pkgStore + '\')
    if (-not $entryStore -or $entryStore.AppID -ne 'AnthropicPBC.Claude_fnn82j28hfe8t!ClaudeStore') {
        throw "Get-AppxEntryForPath failed to resolve Store build by path and executable match. Got: $($entryStore.AppID)"
    }

    # --- Test 3: When only Store package exists, Find-ClaudePath still returns it ---
    $script:MockPackages = @($script:MockPackages[0])
    $selectedStoreOnly = Find-ClaudePath
    if ($selectedStoreOnly -ne $pkgStore) {
        throw "Find-ClaudePath should return Store package when no official package exists. Expected: $pkgStore, Got: $selectedStoreOnly"
    }

    Write-Host 'PASS: Find-ClaudePath prefers newest official MSIX when coexisting with Microsoft Store build.'
    Write-Host 'PASS: Get-AppxEntryForPath resolves exact AppID by install path and manifest executable.'
    Write-Host 'PASS: Find-ClaudePath falls back to Store package when it is the only AppX install.'
}
finally {
    if (Test-Path -LiteralPath $temp) {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
