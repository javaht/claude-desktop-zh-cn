$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Load-InstallerFunctions.ps1') -FunctionNames @(
    'Get-ClaudeAppxPackages',
    'Get-AppxEntryForPath',
    'Select-ClaudeInstallTarget',
    'Test-ClaudeDesktopProcessPath'
)

$temp = Join-Path ([IO.Path]::GetTempPath()) ('claude-desktop-restart-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    $pkgStore = Join-Path $temp 'AnthropicPBC.Claude_5.11492.5.0_x64__store'
    $pkgOfficial = Join-Path $temp 'Claude_5.11492.5.0_x64__official'
    New-Item -ItemType Directory -Path $pkgStore -Force | Out-Null
    New-Item -ItemType Directory -Path $pkgOfficial -Force | Out-Null

    $manifestXml = @'
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10">
  <Applications>
    <Application Id="Claude" Executable="app\Claude.exe" />
  </Applications>
</Package>
'@
    Set-Content -LiteralPath (Join-Path $pkgStore 'AppxManifest.xml') -Value $manifestXml -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $pkgOfficial 'AppxManifest.xml') -Value $manifestXml -Encoding UTF8

    # Mock: two packages coexist; store build is returned FIRST to simulate the
    # unordered Get-AppxPackage / Get-StartApps behaviour that caused the original bug.
    function script:Get-ClaudeAppxPackages {
        return @(
            [pscustomobject]@{
                Name = 'AnthropicPBC.Claude'
                Version = '5.11492.5.0'
                InstallLocation = $pkgStore
                PackageFamilyName = 'AnthropicPBC.Claude_store'
            },
            [pscustomobject]@{
                Name = 'Claude'
                Version = '5.11492.5.0'
                InstallLocation = $pkgOfficial
                PackageFamilyName = 'Claude_official'
            }
        )
    }

    # --- Test 1: path-based resolution must NOT just return the first package ---
    $entryOfficial = Get-AppxEntryForPath $pkgOfficial
    if (-not $entryOfficial -or $entryOfficial.AppID -ne 'Claude_official!Claude') {
        throw "Get-AppxEntryForPath failed to resolve official build by path. Got: $($entryOfficial.AppID)"
    }
    $entryStore = Get-AppxEntryForPath $pkgStore
    if (-not $entryStore -or $entryStore.AppID -ne 'AnthropicPBC.Claude_store!Claude') {
        throw "Get-AppxEntryForPath failed to resolve store build by path. Got: $($entryStore.AppID)"
    }

    # --- Test 2: Select-ClaudeInstallTarget honours an explicit preference without prompting ---
    $prefResources = Join-Path $pkgOfficial 'app\resources'
    New-Item -ItemType Directory -Path $prefResources -Force | Out-Null
    $script:PreferredResourcesPath = $prefResources
    $selected = Select-ClaudeInstallTarget
    if ($selected -ne $prefResources) {
        throw "Select-ClaudeInstallTarget did not honour PreferredResourcesPath. Got: $selected"
    }

    Write-Host 'PASS: Get-AppxEntryForPath resolves the correct package by install path (store vs official).'
    Write-Host 'PASS: Select-ClaudeInstallTarget honours the explicitly chosen target.'
}
finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}
