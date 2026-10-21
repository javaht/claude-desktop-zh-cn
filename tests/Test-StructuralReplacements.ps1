$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'Load-InstallerFunctions.ps1') -FunctionNames @(
    'Require-File', 'Get-FrontendHardcodedReplacements', 'Test-PlainUiTextReplacement',
    'Test-StructuralJsReplacement', 'Test-StructuralJsLiteralContext',
    'Replace-FrontendHardcodedText', 'Patch-HardcodedFrontendStrings'
)
$protected = @('Search', 'Add', 'Copy', 'Check', 'Tasks', 'Settings', 'Command', 'Cancel',
    'Sort', 'Voice', 'Default', 'Arguments', 'Normal', 'All', 'Application', 'Medium',
    'Motion', 'Thinking', 'Verbose')
foreach ($word in $protected) {
    foreach ($source in @($word, ('"' + $word + '"'))) {
        if (-not (Test-StructuralJsReplacement $source)) { throw "Unsafe rule: $source" }
    }
}
foreach ($lang in @('zh-CN', 'zh-TW', 'zh-HK')) {
    $rules = Get-FrontendHardcodedReplacements $lang
    foreach ($rule in $rules) {
        if ($protected -contains $rule[0].Trim('"')) { throw "Unsafe catalog entry: $lang $($rule[0])" }
    }
}

$cases = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures/structural-replacements.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
$translation = [string][char]0x6D4B + [char]0x8BD5 + [char]0x8BD1 + [char]0x6587
foreach ($case in $cases) {
    $result = Replace-FrontendHardcodedText $case.text $case.source $translation
    if ($result.Text -cne $case.expected) { throw "Fallback mismatch: $($case.name)" }
}

# Test the actual fast-path rule preparation and writer on temporary files.
# This also proves structural rules never reach the C# literal replacer.
function Resolve-FrontendAssetsDir { param($ResourcesPath) return $ResourcesPath }
function Get-FrontendHardcodedReplacements { param($Language) return ,$script:FixturePair }
function Backup-ModifiedFile { param($ResourcesPath, $FilePath) $script:BackupCount++ }
$Utf8NoBom = New-Object Text.UTF8Encoding($false)
$temp = Join-Path ([IO.Path]::GetTempPath()) ('claude-structural-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    Add-Type -TypeDefinition $script:FrontendPatcherCSharp
    $fixture = Join-Path $temp 'fixture.js'
    foreach ($case in $cases) {
        $script:FixturePair = @([string]$case.source, $translation)
        $script:BackupCount = 0
        [IO.File]::WriteAllText($fixture, $case.text, $Utf8NoBom)
        Patch-HardcodedFrontendStrings $temp 'zh-CN' 6>&1 | Out-Null
        $actual = [IO.File]::ReadAllText($fixture, [Text.Encoding]::UTF8)
        if ($actual -cne $case.expected) { throw "Fast-path mismatch: $($case.name)" }
        $expectedBackups = if ($case.text -cne $case.expected) { 1 } else { 0 }
        if ($script:BackupCount -ne $expectedBackups) { throw "Backup count mismatch: $($case.name)" }
    }
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force
}
Write-Output ('PASS: PowerShell fallback + actual C# fast path (' + (2 * $cases.Count) + ' fixture checks), protected rules and three catalogs')
