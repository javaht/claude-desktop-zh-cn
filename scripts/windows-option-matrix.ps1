param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$ExePath = "",
    [string]$ResourcesPath = "",
    [string[]]$Languages = @("zh-CN", "zh-TW", "zh-HK"),
    [string[]]$Modes = @("safe", "official"),
    [string[]]$LaunchAfterValues = @("false", "true"),
    [switch]$IncludeDryRun,
    [int]$InstallTimeoutSeconds = 240,
    [int]$LaunchCheckSeconds = 12,
    [int]$SecondLaunchCheckSeconds = 20
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message)
}

function Fail {
    param([string]$Message)
    throw $Message
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if (-not $Condition) {
        Fail $Message
    }
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if ([string]::IsNullOrWhiteSpace($ExePath)) {
    $ExePath = Join-Path $RepoRoot "target\release\claude-desktop-zh-cn-rs.exe"
}
if ([string]::IsNullOrWhiteSpace($ResourcesPath)) {
    $ResourcesPath = Join-Path $RepoRoot "resources"
}

Assert-True (Test-Path $ExePath) "未找到 release 可执行文件: $ExePath"
Assert-True (Test-Path $ResourcesPath) "未找到资源目录: $ResourcesPath"
$script:IsAdmin = Test-IsAdmin

$package = Get-AppxPackage | Where-Object { $_.Name -eq "Claude" -or $_.PackageFamilyName -like "Claude_*" } | Sort-Object Version -Descending | Select-Object -First 1
Assert-True ($null -ne $package) "未找到 Claude AppX 安装。"

$installLocation = $package.InstallLocation
$appDir = Join-Path $installLocation "app"
$resourcesDir = Join-Path $appDir "resources"
$claudeExe = Join-Path $appDir "Claude.exe"
$configPath = Join-Path $env:APPDATA "Claude\config.json"
$patchedVersionPath = Join-Path $env:LOCALAPPDATA "ClaudeDesktopZhCn\patched-version.json"

Assert-True (Test-Path $claudeExe) "未找到 Claude.exe: $claudeExe"
Assert-True (Test-Path $configPath) "未找到 Claude 配置: $configPath"

function Get-ClaudeProcesses {
    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in @("Claude.exe", "claude.exe") })
    if (-not $all) {
        return @()
    }
    $anchors = @($all | Where-Object {
        $_.ExecutablePath -and
        (
            $_.ExecutablePath -like "*\WindowsApps\Claude_*" -or
            $_.ExecutablePath -like "*\AnthropicClaude\app-*\*"
        )
    })
    if (-not $anchors) {
        return @()
    }
    $selected = @{}
    foreach ($proc in $anchors) {
        $selected[[int]$proc.ProcessId] = $true
    }
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($proc in $all) {
            $procId = [int]$proc.ProcessId
            $parentId = [int]$proc.ParentProcessId
            if ($selected.ContainsKey($procId) -or $selected.ContainsKey($parentId)) {
                if (-not $selected.ContainsKey($procId)) {
                    $selected[$procId] = $true
                    $changed = $true
                }
                if ($parentId -ne 0 -and -not $selected.ContainsKey($parentId)) {
                    $parent = $all | Where-Object { [int]$_.ProcessId -eq $parentId } | Select-Object -First 1
                    if ($parent) {
                        $selected[$parentId] = $true
                        $changed = $true
                    }
                }
            }
        }
    }
    @($all | Where-Object { $selected.ContainsKey([int]$_.ProcessId) })
}

function Stop-Claude {
    $procs = @(Get-ClaudeProcesses)
    if ($procs.Count -gt 0) {
        $procs | ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Seconds 2
    Assert-True (@(Get-ClaudeProcesses).Count -eq 0) "Claude 进程未能完全退出。"
}

function Get-ConfigLocale {
    (Get-Content $configPath -Raw | ConvertFrom-Json).locale
}

function Get-PatchedVersion {
    if (-not (Test-Path $patchedVersionPath)) {
        return $null
    }
    Get-Content $patchedVersionPath -Raw | ConvertFrom-Json
}

function New-RequestFile {
    param(
        [string]$Name,
        [hashtable]$Body
    )
    $jsonPath = Join-Path $env:TEMP "$Name.json"
    $logPath = Join-Path $env:TEMP "$Name.jsonl"
    $Body.logPath = $logPath
    $Body.resourcesPath = $ResourcesPath
    $json = $Body | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText(
        $jsonPath,
        $json,
        [System.Text.UTF8Encoding]::new($false)
    )
    [pscustomobject]@{
        Json = $jsonPath
        Log = $logPath
    }
}

function Invoke-InstallerRequest {
    param(
        [string]$Name,
        [hashtable]$Body
    )
    $request = New-RequestFile -Name $Name -Body $Body
    Write-Step "执行 $Name"
    $startArgs = @{
        FilePath = $ExePath
        ArgumentList = @("--cli-file", $request.Json)
        WindowStyle = "Hidden"
        PassThru = $true
    }
    if (-not $script:IsAdmin) {
        $startArgs.Verb = "RunAs"
    }
    $process = Start-Process @startArgs
    $deadline = (Get-Date).AddSeconds($InstallTimeoutSeconds)
    while (-not $process.HasExited) {
        if ((Get-Date) -ge $deadline) {
            $tail = if (Test-Path $request.Log) {
                (Get-Content $request.Log -Tail 40) -join "`n"
            } else {
                "NO_LOG"
            }
            try {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            } catch {}
            Fail "$Name 超时未退出（>${InstallTimeoutSeconds}s）。日志尾部:`n$tail"
        }
        Start-Sleep -Milliseconds 500
        $process.Refresh()
    }
    Assert-True ($process.ExitCode -eq 0) "$Name 失败，退出码 $($process.ExitCode)。日志: $($request.Log)"
    Assert-True (Test-Path $request.Log) "$Name 未生成日志: $($request.Log)"
    [pscustomobject]@{
        Json = $request.Json
        Log = $request.Log
        Lines = Get-Content $request.Log
    }
}

function Assert-LogContains {
    param(
        [string[]]$Lines,
        [string]$Needle,
        [string]$Context
    )
    Assert-True (($Lines -join "`n").Contains($Needle)) "$Context 缺少日志片段: $Needle"
}

function Assert-LogNotContains {
    param(
        [string[]]$Lines,
        [string]$Needle,
        [string]$Context
    )
    Assert-True (-not (($Lines -join "`n").Contains($Needle))) "$Context 不应出现日志片段: $Needle"
}

function Assert-RestoreState {
    Assert-True ((Get-ConfigLocale) -eq "en-US") "恢复后 locale 不是 en-US。"
    foreach ($lang in @("zh-CN", "zh-TW", "zh-HK")) {
        Assert-True (-not (Test-Path (Join-Path $resourcesDir "$lang.json"))) "恢复后仍残留 $lang.json"
        Assert-True (-not (Test-Path (Join-Path $resourcesDir "ion-dist\i18n\$lang.json"))) "恢复后仍残留 i18n $lang"
        Assert-True (-not (Test-Path (Join-Path $resourcesDir "ion-dist\i18n\statsig\$lang.json"))) "恢复后仍残留 statsig $lang"
    }
}

function Invoke-RestoreBaseline {
    Stop-Claude
    $result = Invoke-InstallerRequest -Name ("claude-zh-cn-restore-" + [guid]::NewGuid().ToString()) -Body @{
        action = "restore_patch"
    }
    Assert-LogContains -Lines $result.Lines -Needle "Windows 恢复完成。" -Context "restore"
    Assert-RestoreState
    return $result
}

function Assert-LanguageArtifacts {
    param([string]$Language)
    $underscore = $Language.Replace("-", "_")
    foreach ($path in @(
        (Join-Path $resourcesDir "$Language.json"),
        (Join-Path $resourcesDir "ion-dist\i18n\$Language.json"),
        (Join-Path $resourcesDir "ion-dist\i18n\statsig\$Language.json"),
        (Join-Path $resourcesDir "$Language.lproj\Localizable.strings"),
        (Join-Path $resourcesDir "$underscore.lproj\Localizable.strings")
    )) {
        Assert-True (Test-Path $path) "缺少语言产物: $path"
    }
}

function Assert-NoClaudeRunning {
    Assert-True (@(Get-ClaudeProcesses).Count -eq 0) "预期 Claude 未启动，但检测到仍有 Claude 进程。"
}

function Start-ClaudeAndAssertStable {
    param([int]$Seconds)
    Stop-Claude
    $process = Start-Process -FilePath $claudeExe -PassThru
    Start-Sleep -Seconds $Seconds
    $alive = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
    Assert-True ($null -ne $alive) "Claude 冷启动后 $Seconds 秒内退出，疑似闪退。"
}

function Assert-ModeSpecificLogs {
    param(
        [string]$Mode,
        [string[]]$Lines,
        [string]$Context
    )
    if ($Mode -eq "safe") {
        Assert-LogContains -Lines $Lines -Needle "Cowork 兼容模式：跳过在线页面和第三方模型名 app.asar 补丁。" -Context $Context
        Assert-LogNotContains -Lines $Lines -Needle "官方账号登录模式：跳过第三方模型名校验补丁。" -Context $Context
    } else {
        Assert-LogContains -Lines $Lines -Needle "官方账号登录模式：跳过第三方模型名校验补丁。" -Context $Context
        Assert-LogNotContains -Lines $Lines -Needle "Cowork 兼容模式：跳过在线页面和第三方模型名 app.asar 补丁。" -Context $Context
    }
}

function Convert-ToBool {
    param([string]$Value)
    switch ($Value.ToLowerInvariant()) {
        "true" { return $true }
        "false" { return $false }
        default { Fail "无法识别布尔值: $Value。请使用 true 或 false。" }
    }
}

function Invoke-InstallScenario {
    param(
        [string]$Language,
        [string]$Mode,
        [bool]$LaunchAfter,
        [bool]$DryRun
    )
    $name = "claude-zh-cn-install-$($Language)-$($Mode)-launch-$LaunchAfter-dry-$DryRun-" + [guid]::NewGuid().ToString()
    Stop-Claude
    $beforeLocale = Get-ConfigLocale
    $result = Invoke-InstallerRequest -Name $name -Body @{
        action = "install_patch"
        install = @{
            language = $Language
            mode = $Mode
            launchAfter = $LaunchAfter
            dryRun = $DryRun
        }
    }
    Assert-ModeSpecificLogs -Mode $Mode -Lines $result.Lines -Context $name
    if ($DryRun) {
        Assert-True ((Get-ConfigLocale) -eq $beforeLocale) "$name dry-run 不应修改 locale。"
        Assert-True (-not (Test-Path (Join-Path $resourcesDir "$Language.json"))) "$name dry-run 不应写入真实语言资源。"
        Assert-NoClaudeRunning
        return $result
    }
    Assert-True ((Get-ConfigLocale) -eq $Language) "$name 安装后 locale 不匹配。"
    $patched = Get-PatchedVersion
    Assert-True ($null -ne $patched) "$name 未写入 patched-version.json"
    Assert-True ($patched.language -eq $Language) "$name patched-version language 不匹配。"
    $patchedMode = $patched.patchMode
    if (-not $patchedMode) {
        $patchedMode = $patched.mode
    }
    Assert-True ($patchedMode -eq $Mode) "$name patched-version mode 不匹配。"
    Assert-LanguageArtifacts -Language $Language
    if ($LaunchAfter) {
        Start-Sleep -Seconds 8
        Assert-True (@(Get-ClaudeProcesses).Count -gt 0) "$name 预期自动启动 Claude，但未检测到进程。"
    } else {
        Assert-NoClaudeRunning
    }
    Start-ClaudeAndAssertStable -Seconds $LaunchCheckSeconds
    Start-ClaudeAndAssertStable -Seconds $SecondLaunchCheckSeconds
    return $result
}

$summary = New-Object System.Collections.Generic.List[string]

Write-Step "基线恢复"
$restore = Invoke-RestoreBaseline
$summary.Add("restore: ok")

if ($IncludeDryRun) {
    foreach ($mode in $Modes) {
        foreach ($language in $Languages) {
            Write-Step "dry-run: $language / $mode"
            $null = Invoke-InstallScenario -Language $language -Mode $mode -LaunchAfter $false -DryRun $true
            $summary.Add("dry-run $language ${mode}: ok")
        }
    }
}

foreach ($mode in $Modes) {
    foreach ($language in $Languages) {
        foreach ($launchAfter in $LaunchAfterValues) {
            $launchAfterBool = Convert-ToBool $launchAfter
            Write-Step "install: $language / $mode / launchAfter=$launchAfterBool"
            $null = Invoke-RestoreBaseline
            $null = Invoke-InstallScenario -Language $language -Mode $mode -LaunchAfter $launchAfterBool -DryRun $false
            $summary.Add("install $language ${mode} launchAfter=$launchAfterBool`: ok")
            $null = Invoke-RestoreBaseline
            $summary.Add("restore after $language ${mode} launchAfter=$launchAfterBool`: ok")
        }
    }
}

Write-Step "全部矩阵通过"
$summary | ForEach-Object { Write-Host $_ }
