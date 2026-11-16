$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Load-InstallerFunctions.ps1') -FunctionNames @(
    'Get-ClaudeDesktopProcesses',
    'Get-ClaudeCoworkProcesses',
    'Wait-ProcessesExit',
    'Stop-ClaudeProcessesGracefully',
    'Stop-ClaudeProcesses'
)

# Keep this file pure ASCII: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.
# The installer used to print a success message even when the app was still running, so the
# asar swap failed later with a misleading "Cannot create a file..." error (#244).

$script:Remaining = @()

function Get-ClaudeDesktopProcesses { return @($script:Remaining) }
function Get-ClaudeCoworkProcesses { return @() }
function Stop-ClaudeProcessesGracefully {
    param([int]$TimeoutSeconds = 10)
    return $false
}

# --- survivors must abort when the caller requires a stopped app ---
$script:Remaining = @([pscustomobject]@{ Id = 4242; ProcessName = 'claude'; MainWindowHandle = 0 })
$threw = $false
try {
    Stop-ClaudeProcesses -RequireStopped | Out-Null
}
catch {
    $threw = $true
    if ($_.Exception.Message -notmatch '4242') {
        throw "Unexpected error message: $($_.Exception.Message)"
    }
}
if (-not $threw) {
    throw 'Stop-ClaudeProcesses -RequireStopped should throw when a process remains.'
}

# --- without the switch a restart should warn but not abort the install ---
$script:Remaining = @([pscustomobject]@{ Id = 4242; ProcessName = 'claude'; MainWindowHandle = 0 })
if (Stop-ClaudeProcesses) {
    throw 'Stop-ClaudeProcesses should return false when a process remains.'
}

# --- no survivors means success ---
$script:Remaining = @()
if (-not (Stop-ClaudeProcesses -RequireStopped)) {
    throw 'Stop-ClaudeProcesses should return true when no process remains.'
}

Write-Host 'PASS: stop failures are detected and reported instead of being treated as success.' -ForegroundColor Green
Write-Host 'PASS: restart warnings do not abort the install.' -ForegroundColor Green