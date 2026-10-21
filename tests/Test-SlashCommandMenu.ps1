$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Load-InstallerFunctions.ps1') -FunctionNames @(
    'Get-SlashCommandGlossConfig', 'Get-SlashGlossReplacement',
    'Convert-SlashCommandMenuText', 'Patch-SlashCommandMenu'
)
$fixture = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures/slash-command-menu.js'), [Text.Encoding]::UTF8)
$Utf8NoBom = New-Object Text.UTF8Encoding($false)
$temp = Join-Path ([IO.Path]::GetTempPath()) ('claude-slash-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
function Assert-Rejected {
    param([string]$Text, $Config)
    $rejected = $false
    try { Convert-SlashCommandMenuText $Text $Config.Profile $Config.Labels | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Unsafe menu input was accepted' }
}
function Resolve-FrontendAssetsDir { param($ResourcesPath) return $ResourcesPath }
function Backup-ModifiedFile {
    param($ResourcesPath, $FilePath)
    $script:Backups += [IO.File]::ReadAllText($FilePath, [Text.Encoding]::UTF8)
}
try {
    foreach ($lang in @('zh-CN', 'zh-TW', 'zh-HK')) {
        $config = Get-SlashCommandGlossConfig $lang
        $result = Convert-SlashCommandMenuText $fixture $config.Profile $config.Labels
        if ($result.Status -ne 'updated') { throw "Missing patch: $lang" }
        $path = Join-Path $temp ($lang + '.js')
        [IO.File]::WriteAllText($path, $result.Text, $Utf8NoBom)
        & node --check $path
        if ($LASTEXITCODE) { throw "Invalid JavaScript: $lang" }
        & node (Join-Path $PSScriptRoot 'test_slash_menu_runtime.cjs') $path $lang
        if ($LASTEXITCODE) { throw "Runtime failure: $lang" }
        $again = Convert-SlashCommandMenuText $result.Text $config.Profile $config.Labels
        if ($again.Status -ne 'already' -or $again.Text -cne $result.Text) { throw 'Not idempotent' }
    }
    $cn = Get-SlashCommandGlossConfig 'zh-CN'
    $tw = Get-SlashCommandGlossConfig 'zh-TW'
    $first = Convert-SlashCommandMenuText $fixture $cn.Profile $cn.Labels
    $second = Convert-SlashCommandMenuText $first.Text $tw.Profile $tw.Labels
    if ($second.Status -ne 'updated') { throw 'Language switch failed' }
    if ((Convert-SlashCommandMenuText $second.Text $tw.Profile $tw.Labels).Status -ne 'already') { throw 'Repeated language switch is not idempotent' }
    $anchor = 'children: jsx(HighlightedText, {text:item.label,query:query,highlightClassName:"font-semibold"})'
    foreach ($bad in @(
        $fixture.Replace($anchor, 'children:null'),
        ($fixture + "`nconst duplicate={" + $anchor + '};'),
        $fixture.Replace('SlashCommandMenuPopupBody', 'MenuItems'),
        ($fixture + "`nfunction __claudeZhSlashGloss(){}"),
        ($fixture + "`n" + $cn.Profile.marker),
        ($first.Text + $cn.Profile.marker),
        $first.Text.Replace('anthropicDefined===!0', 'anthropicDefined===!1'),
        $first.Text.Replace(';const __claudeZhSlashLabels=', ';const bad=')
    )) { Assert-Rejected $bad $cn }
    $renamed = $fixture.Replace('jsx', 'render$node').Replace('HighlightedText', 'H').Replace('item', 'entry').Replace('query', 'q').Replace('q:q', 'query:q')
    $renamedResult = Convert-SlashCommandMenuText $renamed $cn.Profile $cn.Labels
    if (-not $renamedResult.Text.Contains('entry.anthropicDefined')) { throw 'Changed minified aliases not supported' }

    $special = [regex]::Replace($fixture, '\bjsx\b', '__ITEM__')
    $special = [regex]::Replace($special, '\bitem\b', '__JSX__')
    $specialResult = Convert-SlashCommandMenuText $special $cn.Profile $cn.Labels
    if (-not $specialResult.Text.Contains('__ITEM__(HighlightedText, {text:__JSX__.label')) { throw 'Captured alias was rewritten by template expansion' }
    if ((Convert-SlashCommandMenuText $specialResult.Text $cn.Profile $cn.Labels).Status -ne 'already') { throw 'Special alias patch is not idempotent' }
    $casing = $first.Text.Replace('"model":', '"Model":')
    $corrected = Convert-SlashCommandMenuText $casing $cn.Profile $cn.Labels
    if ($corrected.Status -ne 'updated' -or $corrected.Text -cne $first.Text) { throw 'Catalog key casing must remain ordinal' }

    # Integration test: backup must precede the first write; unrelated add-menu bytes stay intact.
    $assets = Join-Path $temp 'assets'
    New-Item -ItemType Directory -Path $assets | Out-Null
    $menu = Join-Path $assets 'menu.js'
    $decoy = Join-Path $assets 'add-menu.js'
    $decoyText = $fixture.Replace('SlashCommandMenuPopupBody', 'MenuItems')
    [IO.File]::WriteAllText($menu, $fixture, $Utf8NoBom)
    [IO.File]::WriteAllText($decoy, $decoyText, $Utf8NoBom)
    $script:Backups = @()
    Patch-SlashCommandMenu $assets 'zh-CN' 6>&1 | Out-Null
    if ($script:Backups.Count -ne 1 -or $script:Backups[0] -cne $fixture) { throw 'Original menu was not backed up before writing' }
    $hash = (Get-FileHash -LiteralPath $menu).Hash
    Patch-SlashCommandMenu $assets 'zh-CN' 6>&1 | Out-Null
    if ($script:Backups.Count -ne 1 -or (Get-FileHash -LiteralPath $menu).Hash -ne $hash) { throw 'Repeat installation changed bytes or backups' }
    if ([IO.File]::ReadAllText($decoy, [Text.Encoding]::UTF8) -cne $decoyText) { throw 'Unrelated add menu was modified' }
    $secondMenu = Join-Path $assets 'second-menu.js'
    [IO.File]::WriteAllText($secondMenu, $fixture, $Utf8NoBom)
    $log = Patch-SlashCommandMenu $assets 'zh-CN' 6>&1 | Out-String
    if ($log -notmatch 'WARNING' -or (Get-FileHash -LiteralPath $menu).Hash -ne $hash -or $script:Backups.Count -ne 1) { throw 'Ambiguous module must skip without writes' }
    Remove-Item -LiteralPath $secondMenu
    [IO.File]::WriteAllText($menu, $fixture.Replace($anchor, 'children:null'), $Utf8NoBom)
    $before = (Get-FileHash -LiteralPath $menu).Hash
    $log = Patch-SlashCommandMenu $assets 'zh-CN' 6>&1 | Out-String
    if ($log -notmatch 'WARNING' -or (Get-FileHash -LiteralPath $menu).Hash -ne $before -or $script:Backups.Count -ne 1) { throw 'Unknown row shape must skip without writes' }
    Remove-Item -LiteralPath $menu
    $log = Patch-SlashCommandMenu $assets 'zh-CN' 6>&1 | Out-String
    if ($log -notmatch 'WARNING' -or $script:Backups.Count -ne 1) { throw 'Missing module must skip without writes' }
    Write-Output 'PASS: bilingual menus, language changes, original backups, idempotence, alias changes and safe skip'
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force
}
