# One-shot / resident entry for Windows Frida Chinese (no disk patch of Claude).
# Called from install_windows.ps1 menu option [3], or directly:
#   powershell -File run_frida_zh_win.ps1 -Language zh-CN
#
# Flow:
#   1) Detect portable/system Python+frida (bootstrap if missing)
#   2) Resident by default

[CmdletBinding()]
param(
    [ValidateSet("zh-CN", "zh-TW", "zh-HK")]
    [string]$Language = "zh-CN",

    [int]$Port = 19351,

    [ValidateSet("both", "mem-patch", "exit-hook")]
    [string]$Mode = "both",

    [string]$AppDir = "",

    [switch]$NoInject,
    [switch]$NoQuit,
    [switch]$SkipBootstrapPrompt,
    [switch]$ResidentInstall,
    [switch]$ResidentUninstall,
    [switch]$RemoveRuntimeOnUninstall
)

$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$Bootstrap = Join-Path $ScriptDir "bootstrap_frida_runtime_win.ps1"
$Launcher = Join-Path $ScriptDir "frida_launch_zh_win.py"
$ResidentCtl = Join-Path $ScriptDir "frida-zh-resident-ctl.ps1"

function Write-Info([string]$Message) { Write-Host $Message }
function Write-Warn([string]$Message) { Write-Host $Message -ForegroundColor Yellow }
function Write-Err([string]$Message) { Write-Host $Message -ForegroundColor Red }

function Get-RuntimeRoot {
    if ($env:CLAUDE_ZH_RUNTIME) { return $env:CLAUDE_ZH_RUNTIME }
    $local = $env:CLAUDE_ZH_ORIGINAL_LOCALAPPDATA
    if (-not $local) { $local = [Environment]::GetFolderPath("LocalApplicationData") }
    if (-not $local) { $local = $env:LOCALAPPDATA }
    return (Join-Path $local "claude-zh\runtime")
}

function Get-ClaudeZhRoot {
    $runtimeRoot = Get-RuntimeRoot
    return (Split-Path -Parent $runtimeRoot)
}

function Get-PortablePythonExe {
    $runtimeRoot = Get-RuntimeRoot
    foreach ($candidate in @(
        (Join-Path $runtimeRoot "python\python.exe"),
        (Join-Path $runtimeRoot "python.exe")
    )) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }
    return $null
}

function Test-FridaPython([string]$PythonExe) {
    if (-not $PythonExe -or -not (Test-Path -LiteralPath $PythonExe)) {
        return $false
    }
    try {
        & $PythonExe -c "import frida, websockets" *> $null
        return ($LASTEXITCODE -eq 0)
    }
    catch {
        return $false
    }
}

function Stop-FridaRelated {
    $targets = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        if (-not $_.CommandLine) { return $false }
        $name = [string]$_.Name
        $cmd = [string]$_.CommandLine
        if ($name -like "frida-helper*") { return $true }
        if ($name -match '^(cmd)(\.exe)?$' -and $cmd -like "*claude-zh*watch.cmd*") { return $true }
        if ($name -match '^(python|pythonw)(\.exe)?$' -and $cmd -like "*frida_launch_zh_win.py*") { return $true }
        if ($name -match '^(powershell|pwsh)(\.exe)?$' -and
            $cmd -like "*frida-zh-resident-ctl.ps1*" -and
            $cmd -match '(?i)(-Action\s+watch|/Action\s+watch)') {
            return $true
        }
        return $false
    })
    foreach ($proc in $targets) {
        try {
            Write-Info "停止旧 Frida 进程 PID $($proc.ProcessId) ($($proc.Name))"
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
        }
        catch {}
    }
}

function Copy-FileBestEffort {
    param(
        [string]$Source,
        [string]$DestinationDir
    )
    if (-not (Test-Path -LiteralPath $Source)) { return $false }
    New-Item -ItemType Directory -Path $DestinationDir -Force | Out-Null
    $dest = Join-Path $DestinationDir (Split-Path -Leaf $Source)
    try {
        Copy-Item -LiteralPath $Source -Destination $dest -Force -ErrorAction Stop
        return $true
    }
    catch {
        if (Test-Path -LiteralPath $dest) {
            Write-Warn "跳过复制（目标已存在或被占用）: $(Split-Path -Leaf $Source)"
            return $true
        }
        throw
    }
}

function Deploy-ToClaudeZh {
    param([string]$SourceRoot)

    $dest = Get-ClaudeZhRoot
    $SourceRoot = [System.IO.Path]::GetFullPath($SourceRoot)
    $destFull = [System.IO.Path]::GetFullPath($dest)

    Write-Info ""
    Write-Info "刷新 Frida 汉化运行文件 ..."
    Stop-FridaRelated

    New-Item -ItemType Directory -Path (Join-Path $dest "scripts\experimental") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $dest "resources") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $dest "scripts") -Force | Out-Null

    if ($SourceRoot.TrimEnd('\') -ine $destFull.TrimEnd('\')) {
        [void](Copy-FileBestEffort -Source (Join-Path $SourceRoot "scripts\patch_claude_zh_cn.py") -DestinationDir (Join-Path $dest "scripts"))
        $exp = Join-Path $SourceRoot "scripts\experimental"
        foreach ($name in @(
            "frida_launch_zh_win.py",
            "frida_cdp_gate_win.js",
            "cdp_launch_zh.py",
            "bootstrap_frida_runtime_win.ps1",
            "run_frida_zh_win.ps1",
            "frida-zh-resident-ctl.ps1",
            "requirements-frida.txt",
            "typing_shim_sitecustomize.py"
        )) {
            [void](Copy-FileBestEffort -Source (Join-Path $exp $name) -DestinationDir (Join-Path $dest "scripts\experimental"))
        }
        try {
            Copy-Item -Path (Join-Path $SourceRoot "resources\*") -Destination (Join-Path $dest "resources\") -Force -Recurse -ErrorAction SilentlyContinue
        }
        catch {}
    }

    Write-Info "  已部署到: $dest"
    return $dest
}

function Use-DeployedRoot {
    param([string]$DeployedRoot)

    $script:RepoRoot = $DeployedRoot
    $script:ScriptDir = Join-Path $DeployedRoot "scripts\experimental"
    $script:Bootstrap = Join-Path $script:ScriptDir "bootstrap_frida_runtime_win.ps1"
    $script:Launcher = Join-Path $script:ScriptDir "frida_launch_zh_win.py"
    $script:ResidentCtl = Join-Path $script:ScriptDir "frida-zh-resident-ctl.ps1"
}

function Start-ClaudeDesktop {
    Write-Info ""
    Write-Info "正在启动 Claude Desktop，让后台 watcher 自动接管汉化 ..."

    Start-Sleep -Seconds 2

    try {
        $app = Get-StartApps -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "*Claude*" -or $_.AppID -like "*Claude*" } |
            Select-Object -First 1
        if ($app -and $app.AppID) {
            Start-Process -FilePath "explorer.exe" -ArgumentList ("shell:AppsFolder\" + $app.AppID) | Out-Null
            Write-Info "  已通过开始菜单启动 Claude Desktop。"
            return
        }
    }
    catch {}

    $candidates = @()
    try {
        $candidates += Get-ChildItem "C:\Program Files\WindowsApps\Claude_*" -Directory -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            ForEach-Object {
                Join-Path $_.FullName "app\Claude.exe"
                Join-Path $_.FullName "Claude.exe"
            }
    }
    catch {}
    try {
        $local = [Environment]::GetFolderPath("LocalApplicationData")
        if ($local) {
            $candidates += Get-ChildItem (Join-Path $local "AnthropicClaude\app-*") -Directory -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending |
                ForEach-Object { Join-Path $_.FullName "Claude.exe" }
        }
    }
    catch {}

    foreach ($candidate in ($candidates | Where-Object { $_ } | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $candidate) {
            Start-Process -FilePath $candidate | Out-Null
            Write-Info "  已启动: $candidate"
            return
        }
    }

    Write-Warn "  未能自动找到 Claude Desktop，请手动打开；后台 watcher 已安装。"
}

function Get-PythonFromBootstrapJson([string]$JsonLine) {
    $obj = Get-BootstrapInfo $JsonLine
    if ($obj -and $obj.Ready -and $obj.PythonExe) { return [string]$obj.PythonExe }
    return $null
}

function Get-BootstrapInfo([string]$JsonLine) {
    if (-not $JsonLine) { return $null }
    # bootstrap prints progress lines then a final JSON object
    $lines = $JsonLine -split "`r?`n" | Where-Object { $_ -and $_.Trim().StartsWith("{") }
    if (-not $lines) { return $null }
    try { return ($lines[-1] | ConvertFrom-Json) } catch { return $null }
}

function Ensure-FridaPython {
    if (-not (Test-Path -LiteralPath $Bootstrap)) {
        throw "缺少 bootstrap 脚本: $Bootstrap"
    }

    Write-Info "检查便携 / 本机 Python+frida ..."
    $check = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Bootstrap -CheckOnly 2>&1
    $checkText = ($check | Out-String)
    $checkInfo = Get-BootstrapInfo $checkText
    $py = Get-PythonFromBootstrapJson $checkText
    if ($py) {
        Write-Info "  已就绪: $py"
        return $py
    }

    $runtimeRoot = Get-RuntimeRoot
    $existingPortable = Get-PortablePythonExe
    Write-Warn ""
    if ($existingPortable -or ($checkInfo -and $checkInfo.PythonExe)) {
        $existing = if ($existingPortable) { $existingPortable } else { [string]$checkInfo.PythonExe }
        Write-Warn "检测到已下载的便携 Python。"
        Write-Warn "将复用并修复:"
        Write-Warn "  $existing"
        Write-Warn "仅检查/安装 frida 依赖，不重新下载 Python。"
    }
    else {
        Write-Warn "未检测到可用的 Python+frida。"
        Write-Warn "将安装便携运行时到:"
        Write-Warn "  $runtimeRoot"
        Write-Warn "约 40–80 MB；仅本工具使用，不改系统 Python / PATH。"
    }
    Write-Warn ""

    if (-not $existingPortable -and -not $SkipBootstrapPrompt -and [Environment]::UserInteractive) {
        $ans = (Read-Host "是否继续下载并安装便携运行时？[Y/n]").Trim()
        if ($ans -match '^[Nn]') {
            throw "用户取消便携运行时安装。"
        }
    }

    $installLines = @()
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Bootstrap 2>&1 | ForEach-Object {
        $line = [string]$_
        $installLines += $line
        Write-Host $line
    }
    $installText = ($installLines -join "`n")
    $py = Get-PythonFromBootstrapJson $installText
    if (-not $py) {
        # fallback: conventional path
        $candidate = Join-Path (Get-RuntimeRoot) "python\python.exe"
        if ((Test-Path -LiteralPath $candidate) -and (Test-FridaPython $candidate)) {
            $py = $candidate
        }
    }
    if (-not $py) {
        throw "便携运行时安装/修复后仍未得到可用的 Python+frida。"
    }
    Write-Info "  使用: $py"
    return $py
}

# ---- resident shortcuts ----
if ($ResidentUninstall) {
    if (-not (Test-Path -LiteralPath $ResidentCtl)) {
        throw "缺少常驻控制脚本: $ResidentCtl"
    }
    $uargs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $ResidentCtl, "-Action", "uninstall")
    if ($RemoveRuntimeOnUninstall) {
        $uargs += "-RemoveRuntime"
    }
    & powershell.exe @uargs
    exit $LASTEXITCODE
}

$pythonExe = Ensure-FridaPython

if ($ResidentInstall) {
    $deployed = Deploy-ToClaudeZh -SourceRoot $RepoRoot
    Use-DeployedRoot -DeployedRoot $deployed
    if (-not (Test-Path -LiteralPath $ResidentCtl)) {
        throw "缺少常驻控制脚本: $ResidentCtl"
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ResidentCtl `
        -Action install `
        -PythonExe $pythonExe `
        -Language $Language `
        -Port $Port `
        -RepoRoot $RepoRoot
    $code = $LASTEXITCODE
    if ($code -eq 0) {
        Start-ClaudeDesktop
    }
    exit $code
}

# Interactive resident choice when run from menu
$residentChoice = $env:CLAUDE_FRIDA_RESIDENT
if (-not $residentChoice -and [Environment]::UserInteractive -and -not $ResidentInstall) {
    Write-Info "是否注册为用户登录后常驻（监视并自动用 Frida 启动汉化）？"
    Write-Info "  Y/回车 = 安装用户登录自启并隐藏后台运行（默认）"
    Write-Info "  N = 卸载常驻"
    Write-Info ""
    $residentChoice = (Read-Host "请选择 [Y/N/回车]").Trim()
}

switch -Regex ($residentChoice) {
    '^(|[Yy])$' {
        $deployed = Deploy-ToClaudeZh -SourceRoot $RepoRoot
        Use-DeployedRoot -DeployedRoot $deployed
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ResidentCtl `
            -Action install `
            -PythonExe $pythonExe `
            -Language $Language `
            -Port $Port `
            -RepoRoot $RepoRoot 2>&1 | ForEach-Object { Write-Host ([string]$_) }
        if ($LASTEXITCODE -eq 0) {
            Start-ClaudeDesktop
            exit 0
        }
        throw "常驻安装失败（exit=$LASTEXITCODE）。"
    }
    '^[Nn]' {
        $removeRuntime = $false
        if ([Environment]::UserInteractive) {
            $rr = (Read-Host "是否同时删除便携运行时 %LOCALAPPDATA%\claude-zh\runtime？[y/N]").Trim()
            if ($rr -match '^[Yy]') { $removeRuntime = $true }
        }
        $uargs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $ResidentCtl, "-Action", "uninstall")
        if ($removeRuntime) { $uargs += "-RemoveRuntime" }
        & powershell.exe @uargs
        exit $LASTEXITCODE
    }
    default {
        Write-Warn "未识别选择，默认安装隐藏后台常驻。"
        $deployed = Deploy-ToClaudeZh -SourceRoot $RepoRoot
        Use-DeployedRoot -DeployedRoot $deployed
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ResidentCtl `
            -Action install `
            -PythonExe $pythonExe `
            -Language $Language `
            -Port $Port `
            -RepoRoot $RepoRoot
        $code = $LASTEXITCODE
        if ($code -eq 0) {
            Start-ClaudeDesktop
        }
        exit $code
    }
}

exit 0
