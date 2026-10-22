#requires -Version 7.0
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Run the Windows launcher regression checks on Windows.' }
$repository = Split-Path $PSScriptRoot -Parent
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repository 'install-windows.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Launcher syntax is invalid.' }
if ($ast.ScriptRequirements.RequiredPSVersion.Major -lt 7) { throw 'The primary entry must require PowerShell 7.' }
foreach ($definition in $ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] }) {
    Invoke-Expression $definition.Extent.Text
}
function Assert-Launcher {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Invoke-TestChild {
    param([Diagnostics.ProcessStartInfo]$Info)
    $Info.UseShellExecute = $false
    $Info.CreateNoWindow = $true
    $Info.RedirectStandardInput = $true
    $Info.RedirectStandardOutput = $true
    $Info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    try {
        $process.StartInfo = $Info
        [void]$process.Start()
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            $process.Kill()
            throw 'Test child process timed out.'
        }
        return @{ ExitCode = $process.ExitCode; Output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult() }
    }
    finally { $process.Dispose() }
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('claude-windows-launcher-test-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
try {
    $source = Join-Path $fixtureRoot "中文 源目录 & O'Brien"
    $temp = Join-Path $fixtureRoot '中文 暂存目录'
    New-Item -ItemType Directory -Path (Join-Path $source 'scripts'), (Join-Path $source 'resources') -Force | Out-Null
    $fakeInstaller = @'
param([switch]$Interactive, [string]$OriginalUserSid, [string]$OriginalUserProfile, [string]$OriginalAppData, [string]$OriginalLocalAppData)
@{
    Interactive = [bool]$Interactive
    OriginalUserSid = $OriginalUserSid
    OriginalUserProfile = $OriginalUserProfile
    OriginalAppData = $OriginalAppData
    OriginalLocalAppData = $OriginalLocalAppData
} | ConvertTo-Json | Set-Content -LiteralPath $env:CLAUDE_ZH_TEST_OUTPUT -Encoding utf8
'@
    Set-Content -LiteralPath (Join-Path $source 'scripts\install_windows.ps1') -Value $fakeInstaller -Encoding utf8
    Set-Content -LiteralPath (Join-Path $source 'resources\fixture.txt') -Value '资源内容' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $source 'install-windows.ps1') -Value 'throw "Fixture entry must not run."' -Encoding utf8
    Copy-Item -LiteralPath (Join-Path $repository 'install-windows.bat') -Destination $source
    $stage = New-InstallerStage $source $temp
    $secondStage = New-InstallerStage $source $temp
    Assert-Launcher ($stage -ne $secondStage) 'Concurrent launches must have separate staging directories.'
    Assert-Launcher ((Get-Content -LiteralPath (Join-Path $stage 'resources\fixture.txt') -Raw).Trim() -eq '资源内容') 'Staging lost resource content.'
    Assert-Launcher (Test-Path -LiteralPath (Join-Path $stage 'install-windows.ps1')) 'Staging lost the primary entry.'
    Assert-Launcher (Test-Path -LiteralPath (Join-Path $stage 'install-windows.bat')) 'Staging lost the compatibility wrapper.'
    $rejected = $false
    try { New-InstallerStage (Join-Path $fixtureRoot 'missing-source') $temp | Out-Null }
    catch { $rejected = $true }
    Assert-Launcher $rejected 'Incomplete archives must be rejected before launch.'

    $originalUser = @{
        OriginalUserSid = 'S-1-5-21-12345'
        OriginalUserProfile = "C:\Users\测试 O'Brien & Team\"
        OriginalAppData = "C:\Users\测试 O'Brien & Team\AppData\Roaming\"
        OriginalLocalAppData = "C:\Users\测试 O'Brien & Team\AppData\Local\"
    }
    $encoded = New-InstallerEncodedCommand (Join-Path $stage 'scripts\install_windows.ps1') $originalUser
    $pwsh = Join-Path $PSHOME 'pwsh.exe'
    $info = [Diagnostics.ProcessStartInfo]::new($pwsh)
    foreach ($argument in @('-NoProfile', '-EncodedCommand', $encoded)) { $info.ArgumentList.Add($argument) }
    $outputFile = Join-Path $fixtureRoot 'received.json'
    $info.Environment['CLAUDE_ZH_TEST_OUTPUT'] = $outputFile
    $result = Invoke-TestChild $info
    Assert-Launcher ($result.ExitCode -eq 0) ("Encoded installer invocation failed: " + $result.Output)
    $received = Get-Content -LiteralPath $outputFile -Raw | ConvertFrom-Json -AsHashtable
    Assert-Launcher $received.Interactive 'Interactive mode was lost.'
    foreach ($key in $originalUser.Keys) {
        Assert-Launcher ($received[$key] -ceq $originalUser[$key]) "Original user value changed: $key"
    }

    # Mock only the UAC/process boundary; never launch the real installer or a terminal.
    $script:launches = [Collections.Generic.List[object]]::new()
    $script:launchFailure = ''
    function Start-Process {
        [CmdletBinding()]
        param([string]$FilePath, [string[]]$ArgumentList, [string]$WorkingDirectory, [string]$Verb)
        $script:launches.Add(@{ FilePath = $FilePath; Arguments = $ArgumentList; Directory = $WorkingDirectory; Verb = $Verb })
        if ($script:launchFailure -eq 'cancel') { throw [ComponentModel.Win32Exception]::new(1223) }
        if ($script:launchFailure -eq 'terminal' -and $FilePath -like '*wt.exe') { throw 'Terminal launch failed.' }
    }
    $terminal = 'C:\Program Files\Windows Terminal\wt.exe'
    Start-InstallerWindow $pwsh $stage $originalUser $terminal
    Assert-Launcher ($launches.Count -eq 1 -and $launches[0].FilePath -eq $terminal) 'Windows Terminal must be preferred.'
    Assert-Launcher ($launches[0].Verb -eq 'RunAs' -and $launches[0].Arguments[1] -eq 'new') 'Terminal must request a new elevated window.'
    Assert-Launcher ($launches[0].Arguments[4] -ceq ('"{0}"' -f $stage)) 'Terminal staging path must remain quoted.'
    Assert-Launcher ($launches[0].Arguments[5] -ceq ('"{0}"' -f $pwsh)) 'Terminal PowerShell path must remain quoted.'
    $launches.Clear()
    Start-InstallerWindow $pwsh $stage $originalUser ''
    Assert-Launcher ($launches.Count -eq 1 -and $launches[0].FilePath -eq $pwsh) 'Missing Terminal must use PowerShell 7 directly.'
    $launches.Clear()
    $script:launchFailure = 'terminal'
    Start-InstallerWindow $pwsh $stage $originalUser $terminal
    Assert-Launcher ($launches.Count -eq 2 -and $launches[1].FilePath -eq $pwsh) 'A failed Terminal launch must fall back to PowerShell 7.'
    foreach ($terminalChoice in @($terminal, '')) {
        $launches.Clear()
        $script:launchFailure = 'cancel'
        $cancelled = $false
        try { Start-InstallerWindow $pwsh $stage $originalUser $terminalChoice }
        catch { $cancelled = Test-UacCancellation $_.Exception }
        Assert-Launcher ($cancelled -and $launches.Count -eq 1) 'UAC cancellation must stop without a second elevation request.'
    }

    $cmd = [Diagnostics.ProcessStartInfo]::new($env:ComSpec)
    $cmd.WorkingDirectory = $source
    foreach ($argument in @('/d', '/c', 'install-windows.bat')) { $cmd.ArgumentList.Add($argument) }
    $cmd.Environment['PATH'] = [Environment]::SystemDirectory
    $result = Invoke-TestChild $cmd
    Assert-Launcher ($result.ExitCode -eq 1 -and $result.Output.Contains('PowerShell 7 or later is required')) 'Missing PowerShell 7 must show an installation hint and fail safely.'
    Write-Host 'PASS: Unicode/spaced staging paths, original-user arguments, Terminal selection/fallback, missing PowerShell 7, and simulated UAC cancellation.'
}
finally {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolved = [IO.Path]::GetFullPath($fixtureRoot)
    if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -notlike 'claude-windows-launcher-test-*') {
        throw 'Refusing to clean an unexpected fixture path.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
