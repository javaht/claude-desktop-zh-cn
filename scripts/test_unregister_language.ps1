param([string]$InstallerPath = (Join-Path $PSScriptRoot 'install_windows.ps1'))
$ErrorActionPreference = 'Stop'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($InstallerPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Installer PowerShell syntax is invalid.' }
foreach ($name in @('Resolve-FrontendAssetsDir', 'Get-FrontendJsFilesContaining', 'Unregister-Language')) {
    $definition = $ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq $name }
    if (-not $definition) { throw "Missing function: $name" }
    Invoke-Expression $definition.Extent.Text
}
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$BaseLanguageList = '["en-US","de-DE","fr-FR","ko-KR","ja-JP","es-419","es-ES","it-IT","hi-IN","pt-BR","id-ID"'
$LanguageListPattern = [regex]::Escape($BaseLanguageList) + '(?:(?:,"zh-CN")|(?:,"zh-TW")|(?:,"zh-HK"))*\]'
$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('claude-zh-unregister-test-' + [guid]::NewGuid())
$assets = Join-Path $fixtureRoot 'ion-dist\assets\v1'
$file = Join-Path $assets 'fixture.js'
$nativeFile = Join-Path $assets 'native-only.js'
New-Item -ItemType Directory -Path $assets -Force | Out-Null
try {
    $unrelated = ';const localeMap={"uk-UA":1,"zh-CN":2,"zh-TW":3,"zh-HK":4};const nativeList=["ru","zh-CN","zh-TW","zh-HK","id"];'
    [System.IO.File]::WriteAllText($nativeFile, $unrelated, $Utf8NoBom)
    foreach ($suffix in @(',"zh-CN"', ',"zh-TW","zh-HK"', ',"zh-CN","zh-TW","zh-CN"', '')) {
        $inputText = 'const whitelist=' + $BaseLanguageList + $suffix + '];const secondWhitelist=' + $BaseLanguageList + $suffix + ']' + $unrelated
        $expected = 'const whitelist=' + $BaseLanguageList + '];const secondWhitelist=' + $BaseLanguageList + ']' + $unrelated
        [System.IO.File]::WriteAllText($file, $inputText, $Utf8NoBom)
        Unregister-Language $fixtureRoot
        if ([System.IO.File]::ReadAllText($file) -cne $expected) { throw 'Unregister must only change the supported-language whitelist, preserving object keys and unrelated native locale lists.' }
        Unregister-Language $fixtureRoot
        if ([System.IO.File]::ReadAllText($file) -cne $expected) { throw 'Unregister must be idempotent.' }
        if ([System.IO.File]::ReadAllText($nativeFile) -cne $unrelated) { throw 'A bundle without the language whitelist must stay unchanged.' }
    }
    Write-Host 'PASS: whitelist cleanup, native locale preservation, and repeated cleanup.'
}
finally {
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $nativeFile -Force -ErrorAction SilentlyContinue
    foreach ($directory in @($assets, (Split-Path $assets -Parent), (Join-Path $fixtureRoot 'ion-dist'), $fixtureRoot)) {
        Remove-Item -LiteralPath $directory -Force -ErrorAction SilentlyContinue
    }
}
