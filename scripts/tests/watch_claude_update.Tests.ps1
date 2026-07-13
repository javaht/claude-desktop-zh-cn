$ErrorActionPreference = "Stop"
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$Watcher = (Resolve-Path (Join-Path $PSScriptRoot "..\watch_claude_update.ps1")).Path
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("claude-zh-watcher-test-" + [guid]::NewGuid().ToString("N"))

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) {
        throw "$Message (expected=$Expected, actual=$Actual)"
    }
}

function Invoke-Watcher {
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Watcher -StatePath $script:StatePath
    return $LASTEXITCODE
}

function New-FakeClaudeVersion {
    param([string]$Name)
    $app = Join-Path $script:LocalAppData "AnthropicClaude\$Name"
    New-Item -ItemType Directory -Path (Join-Path $app "resources") -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $app "Claude.exe"), $Name, $Utf8NoBom)
    (Get-Item -LiteralPath $app).LastWriteTime = Get-Date
    return $app
}

try {
    $LocalAppData = Join-Path $TempRoot "LocalAppData"
    $PayloadScripts = Join-Path $TempRoot "payload\scripts"
    $StatePath = Join-Path $TempRoot "state.json"
    New-Item -ItemType Directory -Path $PayloadScripts -Force | Out-Null
    [void](New-FakeClaudeVersion "app-1.0.0")

    $fakeInstaller = @'
param(
    [string]$Action,
    [string]$Language,
    [string]$PatchMode,
    [switch]$AutoReapply,
    [string]$OriginalUserSid,
    [string]$OriginalUserProfile,
    [string]$OriginalAppData,
    [string]$OriginalLocalAppData
)
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Add-Content -LiteralPath (Join-Path $root "fake-installer-runs.log") -Value $Language
if (Test-Path -LiteralPath (Join-Path $root "fail.flag")) { exit 7 }
exit 0
'@
    [System.IO.File]::WriteAllText((Join-Path $PayloadScripts "install_windows.ps1"), $fakeInstaller, $Utf8NoBom)

    $state = [pscustomobject]@{
        schemaVersion = 1
        language = "zh-CN"
        patchMode = "safe"
        lastPatchedIdentity = "old-version"
        pendingIdentity = ""
        failedIdentity = ""
        originalUserSid = "S-1-5-21-test"
        originalUserProfile = Join-Path $TempRoot "User"
        originalAppData = Join-Path $TempRoot "AppData"
        originalLocalAppData = $LocalAppData
    }
    [System.IO.File]::WriteAllText($StatePath, ($state | ConvertTo-Json), $Utf8NoBom)

    Assert-Equal (Invoke-Watcher) 0 "首次发现版本变化应只记录 pending"
    $pendingState = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    if (-not $pendingState.pendingIdentity) { throw "首次检查没有记录 pendingIdentity" }
    if (Test-Path -LiteralPath (Join-Path $TempRoot "fake-installer-runs.log")) { throw "首次检查不应立即执行补丁" }
    $expectedIdentity = $pendingState.pendingIdentity

    Assert-Equal (Invoke-Watcher) 0 "第二次确认稳定版本后应执行补丁"
    $patchedState = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    Assert-Equal $patchedState.lastPatchedIdentity $expectedIdentity "成功后应记录已补丁版本"
    Assert-Equal $patchedState.pendingIdentity "" "成功后应清空 pendingIdentity"
    Assert-Equal (Get-Content -LiteralPath (Join-Path $TempRoot "fake-installer-runs.log")).Count 1 "成功路径应执行一次安装器"
    Assert-Equal (Invoke-Watcher) 0 "已汉化版本应直接跳过"
    Assert-Equal (Get-Content -LiteralPath (Join-Path $TempRoot "fake-installer-runs.log")).Count 1 "已汉化版本不应重复执行安装器"

    Start-Sleep -Milliseconds 20
    [void](New-FakeClaudeVersion "app-2.0.0")
    [System.IO.File]::WriteAllText((Join-Path $TempRoot "fail.flag"), "fail", $Utf8NoBom)
    Assert-Equal (Invoke-Watcher) 0 "新版本首次检查仍应等待稳定"
    Assert-Equal (Invoke-Watcher) 7 "安装器失败码应向外传递"
    $failedState = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    if (-not $failedState.failedIdentity) { throw "失败后没有记录 failedIdentity" }
    $runCountAfterFailure = @(Get-Content -LiteralPath (Join-Path $TempRoot "fake-installer-runs.log")).Count

    Assert-Equal (Invoke-Watcher) 0 "同一失败版本后续检查应安全跳过"
    Assert-Equal @(Get-Content -LiteralPath (Join-Path $TempRoot "fake-installer-runs.log")).Count $runCountAfterFailure "同一失败版本不应无限重试"

    Write-Host "watch_claude_update.Tests.ps1: PASS" -ForegroundColor Green
}
finally {
    if ((Test-Path -LiteralPath $TempRoot) -and $TempRoot.StartsWith([System.IO.Path]::GetTempPath(), [System.StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
