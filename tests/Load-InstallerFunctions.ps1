param([Parameter(Mandatory = $true)][string[]]$FunctionNames)

# Extract only named functions and the C# string. Never execute the installer entry point.
$script:InstallerScriptRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts'
$installerPath = Join-Path $script:InstallerScriptRoot 'install_windows.ps1'
$source = [IO.File]::ReadAllText($installerPath, [Text.Encoding]::UTF8)
$tokens = $null
$parseErrors = $null
$installerAst = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$definitions = $installerAst.FindAll({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst]
}, $true)
foreach ($name in $FunctionNames) {
    $definition = @($definitions | Where-Object { $_.Name -eq $name })
    if ($definition.Count -ne 1) { throw "Expected one function: $name" }
    # Dynamically extracted blocks lack a filename; preserve the installer's resource lookup.
    $text = $definition[0].Extent.Text.Replace('$PSScriptRoot', '$script:InstallerScriptRoot')
    . ([scriptblock]::Create($text))
}
$assignment = $installerAst.Find({ param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left.Extent.Text -eq '$script:FrontendPatcherCSharp'
}, $true)
if ($null -eq $assignment) { throw 'C# helper assignment not found' }
$constant = $assignment.Right.Find({ param($node)
    $node -is [Management.Automation.Language.StringConstantExpressionAst]
}, $true)
if ($constant -isnot [Management.Automation.Language.StringConstantExpressionAst]) {
    throw 'Expected a literal C# here-string'
}
$script:FrontendPatcherCSharp = $constant.Value
