# Bootstrap a portable Python + frida/websockets runtime for Windows Frida Chinese.
# Does NOT install system Python or modify PATH permanently.
#
# Usage:
#   .\bootstrap_frida_runtime_win.ps1 [-RuntimeRoot <path>] [-Force]
#   .\bootstrap_frida_runtime_win.ps1 -CheckOnly
#
# Default RuntimeRoot: %LOCALAPPDATA%\claude-zh\runtime
# Also accepts CLAUDE_ZH_RUNTIME env override.

[CmdletBinding()]
param(
    [string]$RuntimeRoot = "",
    [switch]$Force,
    [switch]$CheckOnly,
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"
$PythonVersion = "3.12.10"
$ScriptDir = $PSScriptRoot
$RequirementsFile = Join-Path $ScriptDir "requirements-frida.txt"

function Write-Info([string]$Message) {
    if (-not $Quiet) {
        Write-Host $Message
    }
}

function Write-Warn([string]$Message) {
    Write-Host $Message -ForegroundColor Yellow
}

function Write-Err([string]$Message) {
    Write-Host $Message -ForegroundColor Red
}

function Invoke-ProcessWithProgress {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [string]$WorkingDirectory = "",
        [string]$Label = "执行中"
    )
    Write-Info "    $Label ..."
    $oldLocation = $null
    try {
        if ($WorkingDirectory) {
            $oldLocation = (Get-Location).Path
            Set-Location -LiteralPath $WorkingDirectory
        }
        & $FilePath @ArgumentList 2>&1 | ForEach-Object {
            Write-Info ("      " + $_)
        }
        $exitCode = $LASTEXITCODE
        if ($null -eq $exitCode) {
            $exitCode = 0
        }
        return [int]$exitCode
    }
    finally {
        if ($oldLocation) {
            Set-Location -LiteralPath $oldLocation
        }
    }
}

function Get-NativeMachineTag {
    # Prefer real CPU arch (ARM64 Windows often runs x64 PowerShell under emulation).
    try {
        $code = @"
using System;
using System.Runtime.InteropServices;
public static class ClaudeZhNativeArch {
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool IsWow64Process2(IntPtr hProcess, out ushort processMachine, out ushort nativeMachine);
}
"@
        if (-not ("ClaudeZhNativeArch" -as [type])) {
            Add-Type -TypeDefinition $code -ErrorAction Stop
        }
        $processMachine = [UInt16]0
        $nativeMachine = [UInt16]0
        $ok = [ClaudeZhNativeArch]::IsWow64Process2(
            [System.Diagnostics.Process]::GetCurrentProcess().Handle,
            [ref]$processMachine,
            [ref]$nativeMachine
        )
        if ($ok) {
            switch ($nativeMachine) {
                0xAA64 { return "arm64" }
                0x8664 { return "amd64" }
                0x014C { return "win32" }
            }
        }
    }
    catch {}

    $reg = $null
    try {
        $reg = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" -Name PROCESSOR_ARCHITECTURE -ErrorAction Stop).PROCESSOR_ARCHITECTURE
    }
    catch {}
    switch -Regex ($reg) {
        'ARM64' { return "arm64" }
        'AMD64' { return "amd64" }
        'x86' { return "win32" }
    }

    $envArch = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) {
        $envArch = $env:PROCESSOR_ARCHITEW6432
    }
    switch -Regex ($envArch) {
        'ARM64' { return "arm64" }
        'AMD64' { return "amd64" }
        default { return "amd64" }
    }
}

function Get-DefaultRuntimeRoot {
    if ($env:CLAUDE_ZH_RUNTIME) {
        return $env:CLAUDE_ZH_RUNTIME
    }
    if ($env:CLAUDE_ZH_ORIGINAL_LOCALAPPDATA) {
        return (Join-Path $env:CLAUDE_ZH_ORIGINAL_LOCALAPPDATA "claude-zh\runtime")
    }
    $local = [Environment]::GetFolderPath("LocalApplicationData")
    if (-not $local) {
        $local = $env:LOCALAPPDATA
    }
    if (-not $local) {
        throw "Cannot resolve LocalAppData for runtime root."
    }
    return (Join-Path $local "claude-zh\runtime")
}

function Get-PythonExe([string]$Root) {
    $candidates = @(
        (Join-Path $Root "python\python.exe"),
        (Join-Path $Root "python.exe")
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) {
            return $c
        }
    }
    return $null
}

function Test-FridaPython {
    param(
        [string]$PythonExe,
        [string[]]$PrefixArgs = @()
    )
    if (-not $PythonExe -or -not (Test-Path -LiteralPath $PythonExe)) {
        return $false
    }
    try {
        $allArgs = @()
        if ($PrefixArgs) { $allArgs += $PrefixArgs }
        $allArgs += @("-c", "import frida, websockets; print(frida.__version__)")
        $argLine = ($allArgs | ForEach-Object {
            $s = [string]$_
            if ($s -match '[\s"]') { '"' + ($s -replace '"', '\"') + '"' } else { $s }
        }) -join ' '
        $p = Start-Process -FilePath $PythonExe -ArgumentList $argLine -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput (Join-Path $env:TEMP "claude-zh-frida-out.txt") `
            -RedirectStandardError (Join-Path $env:TEMP "claude-zh-frida-err.txt")
        return ($null -ne $p -and $p.ExitCode -eq 0)
    }
    catch {
        return $false
    }
}

function Get-EmbedZipName([string]$ArchTag) {
    switch ($ArchTag) {
        "arm64" { return "python-$PythonVersion-embed-arm64.zip" }
        "amd64" { return "python-$PythonVersion-embed-amd64.zip" }
        "win32" { return "python-$PythonVersion-embed-win32.zip" }
        default { return "python-$PythonVersion-embed-amd64.zip" }
    }
}

function Enable-EmbedSite([string]$PythonDir) {
    $pth = Get-ChildItem -LiteralPath $PythonDir -Filter "python*._pth" | Select-Object -First 1
    if (-not $pth) {
        Write-Warn "  [警告] 未找到 python*._pth，embed 包可能不完整。"
        return
    }
    $lines = Get-Content -LiteralPath $pth.FullName -ErrorAction Stop
    $out = @()
    $sawImportSite = $false
    foreach ($line in $lines) {
        $t = $line.Trim()
        if ($t -eq "#import site") {
            $out += "import site"
            $sawImportSite = $true
            continue
        }
        if ($t -eq "import site") {
            $out += "import site"
            $sawImportSite = $true
            continue
        }
        $out += $line
    }
    if (-not $sawImportSite) {
        $out += "import site"
    }
    # Ensure Lib\site-packages is importable even before pip creates it.
    if (-not ($out | Where-Object { $_ -match 'site-packages' })) {
        $out = @("Lib\site-packages") + $out
    }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllLines($pth.FullName, $out, $utf8)
}

function Install-GetPip([string]$PythonExe, [string]$PythonDir) {
    $getPip = Join-Path $PythonDir "get-pip.py"
    if (-not (Test-Path -LiteralPath $getPip)) {
        Write-Info "  下载 get-pip.py ..."
        Invoke-WebRequest -Uri "https://bootstrap.pypa.io/get-pip.py" -OutFile $getPip -UseBasicParsing -TimeoutSec 120
    }
    Write-Info "  安装 pip 到便携 Python ..."
    $code = Invoke-ProcessWithProgress -FilePath $PythonExe -ArgumentList @("$getPip", "--no-warn-script-location") -WorkingDirectory $PythonDir -Label "get-pip"
    if ($code -ne 0) {
        throw "get-pip.py 失败，退出码 $code"
    }
}

function Test-PipAvailable([string]$PythonExe) {
    try {
        $p = Start-Process -FilePath $PythonExe -ArgumentList @("-m", "pip", "--version") -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput (Join-Path $env:TEMP "claude-zh-pip-out.txt") `
            -RedirectStandardError (Join-Path $env:TEMP "claude-zh-pip-err.txt")
        return ($null -ne $p -and $p.ExitCode -eq 0)
    }
    catch {
        return $false
    }
}

function Install-FridaRequirements([string]$PythonExe) {
    if (-not (Test-Path -LiteralPath $RequirementsFile)) {
        throw "缺少依赖清单: $RequirementsFile"
    }
    Write-Info "  安装构建辅助 (setuptools/wheel) ..."
    $prepCode = Invoke-ProcessWithProgress -FilePath $PythonExe -ArgumentList @(
        "-m", "pip", "install", "--upgrade", "--no-cache-dir", "--no-warn-script-location",
        "setuptools", "wheel"
    ) -Label "pip install setuptools/wheel"
    if ($prepCode -ne 0) {
        throw "pip install setuptools/wheel 失败，退出码 $prepCode"
    }

    # Core runtime deps. Prefer wheels; frida publishes win_arm64/win_amd64 wheels.
    Write-Info "  安装 frida / websockets ..."
    $coreCode = Invoke-ProcessWithProgress -FilePath $PythonExe -ArgumentList @(
        "-m", "pip", "install", "--upgrade", "--no-cache-dir", "--no-warn-script-location",
        "frida>=16.0.0", "websockets>=12.0"
    ) -Label "pip install frida/websockets"
    if ($coreCode -ne 0) {
        throw "pip install frida/websockets 失败，退出码 $coreCode。可配置镜像后重试，例如: `$env:PIP_INDEX_URL='https://pypi.tuna.tsinghua.edu.cn/simple'"
    }

    # frida-tools is optional on Windows (no ObjC bridge). Best-effort install.
    Write-Info "  尝试安装 frida-tools（可选，失败可忽略）..."
    $toolsCode = Invoke-ProcessWithProgress -FilePath $PythonExe -ArgumentList @(
        "-m", "pip", "install", "--upgrade", "--no-cache-dir", "--no-warn-script-location",
        "frida-tools>=12.0.0"
    ) -Label "pip install frida-tools"
    if ($toolsCode -ne 0) {
        Write-Warn "  frida-tools 安装失败（Windows DOM 路径不依赖它，继续）。"
    }
}

function Repair-ExistingPortableRuntime([string]$Root, [string]$PythonExe, [string]$ArchTag) {
    $pythonDir = Split-Path -Parent $PythonExe
    if (-not (Test-Path -LiteralPath $pythonDir)) {
        throw "便携 Python 目录不存在: $pythonDir"
    }

    Write-Info "  检测到已下载的便携 Python: $PythonExe"
    Write-Info "  复用现有 Python，仅检查/修复 pip 与 frida 依赖。"

    Enable-EmbedSite $pythonDir
    New-Item -ItemType Directory -Path (Join-Path $pythonDir "Lib\site-packages") -Force | Out-Null
    if (-not (Test-PipAvailable $PythonExe)) {
        Install-GetPip $PythonExe $pythonDir
    }
    Install-FridaRequirements $PythonExe

    if (-not (Test-FridaPython -PythonExe $PythonExe)) {
        throw "复用便携 Python 后仍无法 import frida/websockets。"
    }

    $meta = @{
        pythonVersion = $PythonVersion
        arch = $ArchTag
        repairedAt = (Get-Date).ToString("o")
        pythonExe = $PythonExe
        requirements = $RequirementsFile
    }
    $metaPath = Join-Path $Root "runtime-meta.json"
    $meta | ConvertTo-Json | Set-Content -LiteralPath $metaPath -Encoding UTF8
    Write-Info "  便携运行时已复用并修复: $PythonExe"
    return $PythonExe
}

function Install-PortableRuntime([string]$Root, [string]$ArchTag) {
    $pythonDir = Join-Path $Root "python"
    $zipName = Get-EmbedZipName $ArchTag
    $zipPath = Join-Path $Root $zipName
    $url = "https://www.python.org/ftp/python/$PythonVersion/$zipName"

    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    if ($Force -and (Test-Path -LiteralPath $pythonDir)) {
        Write-Info "  清理旧便携 Python: $pythonDir"
        Remove-Item -LiteralPath $pythonDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $pythonDir -Force | Out-Null

    if (-not (Test-Path -LiteralPath $zipPath) -or $Force) {
        Write-Info "  下载 $zipName ..."
        Write-Info "  $url"
        Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing -TimeoutSec 300
    }
    else {
        Write-Info "  复用已下载: $zipPath"
    }

    Write-Info "  解压 embeddable Python ..."
    # Clear dir contents but keep folder
    Get-ChildItem -LiteralPath $pythonDir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -LiteralPath $zipPath -DestinationPath $pythonDir -Force

    $pythonExe = Join-Path $pythonDir "python.exe"
    if (-not (Test-Path -LiteralPath $pythonExe)) {
        throw "解压后未找到 python.exe: $pythonExe"
    }

    Enable-EmbedSite $pythonDir
    New-Item -ItemType Directory -Path (Join-Path $pythonDir "Lib\site-packages") -Force | Out-Null
    Install-GetPip $pythonExe $pythonDir
    Install-FridaRequirements $pythonExe

    if (-not (Test-FridaPython -PythonExe $pythonExe)) {
        throw "便携运行时安装完成，但 import frida/websockets 失败。"
    }

    $meta = @{
        pythonVersion = $PythonVersion
        arch = $ArchTag
        installedAt = (Get-Date).ToString("o")
        pythonExe = $pythonExe
        requirements = $RequirementsFile
    }
    $metaPath = Join-Path $Root "runtime-meta.json"
    $meta | ConvertTo-Json | Set-Content -LiteralPath $metaPath -Encoding UTF8
    Write-Info "  便携运行时就绪: $pythonExe"
    return $pythonExe
}

function Find-SystemPythonWithFrida {
    # Returns a single executable path (never "py -3" compound), or $null.
    $candidates = @()
    foreach ($cmd in @("py", "python", "python3")) {
        try {
            $c = Get-Command $cmd -ErrorAction SilentlyContinue
            if ($c -and $c.Source) { $candidates += $c.Source }
        }
        catch {}
    }
    foreach ($cmdPath in ($candidates | Select-Object -Unique)) {
        if (Test-FridaPython -PythonExe $cmdPath) {
            return $cmdPath
        }
        # py launcher: resolve the actual python.exe via -3 -c
        if ([IO.Path]::GetFileNameWithoutExtension($cmdPath) -eq "py") {
            try {
                $outFile = Join-Path $env:TEMP ("claude-zh-py-which-" + [guid]::NewGuid().ToString("n") + ".txt")
                $p = Start-Process -FilePath $cmdPath -ArgumentList @("-3", "-c", "import sys; print(sys.executable)") `
                    -NoNewWindow -Wait -PassThru -RedirectStandardOutput $outFile -WindowStyle Hidden
                if ($p.ExitCode -eq 0 -and (Test-Path -LiteralPath $outFile)) {
                    $resolved = (Get-Content -LiteralPath $outFile -TotalCount 1).Trim()
                    Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
                    if ($resolved -and (Test-FridaPython -PythonExe $resolved)) {
                        return $resolved
                    }
                }
                Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
            }
            catch {}
        }
    }
    return $null
}

# ---- main ----
if (-not $RuntimeRoot) {
    $RuntimeRoot = Get-DefaultRuntimeRoot
}
$ArchTag = Get-NativeMachineTag
$PythonExe = Get-PythonExe $RuntimeRoot
$Ready = Test-FridaPython -PythonExe $PythonExe

$result = [ordered]@{
    RuntimeRoot = $RuntimeRoot
    Arch = $ArchTag
    PythonExe = $PythonExe
    Ready = [bool]$Ready
    Action = "none"
}

if ($CheckOnly) {
    if (-not $Ready) {
        $sys = Find-SystemPythonWithFrida
        if ($sys) {
            $result.PythonExe = $sys
            $result.Ready = $true
            $result.Action = "system"
        }
    }
    $result | ConvertTo-Json -Compress
    if ($result.Ready) { exit 0 } else { exit 2 }
}

Write-Info "=== Claude Desktop Frida 便携运行时 ==="
Write-Info "  架构: $ArchTag"
Write-Info "  目录: $RuntimeRoot"

if ($Ready -and -not $Force) {
    Write-Info "  已存在可用运行时: $PythonExe"
    $result.Action = "reuse"
    $result | ConvertTo-Json -Compress | Write-Output
    exit 0
}

if ($PythonExe -and (Test-Path -LiteralPath $PythonExe) -and -not $Force) {
    try {
        $exe = Repair-ExistingPortableRuntime -Root $RuntimeRoot -PythonExe $PythonExe -ArchTag $ArchTag
        $result.PythonExe = $exe
        $result.Ready = $true
        $result.Action = "repaired"
        $result | ConvertTo-Json -Compress | Write-Output
        exit 0
    }
    catch {
        Write-Warn "  已下载 Python 复用失败: $($_.Exception.Message)"
        Write-Warn "  将继续尝试本机 Python；如仍不可用才重新下载便携运行时。"
    }
}

# Prefer already-working system Python only if user did not force portable.
if (-not $Force) {
    $sys = Find-SystemPythonWithFrida
    if ($sys) {
        Write-Info "  使用本机已有 Python+frida: $sys"
        $result.PythonExe = $sys
        $result.Ready = $true
        $result.Action = "system"
        $result | ConvertTo-Json -Compress | Write-Output
        exit 0
    }
}

Write-Warn "  未检测到可用的 Python+frida。"
Write-Warn "  将安装便携运行时（Python $PythonVersion embed + frida），约 40–80 MB。"
Write-Warn "  若已存在下载的 zip 会复用；若已存在 python.exe 会优先修复依赖。"
Write-Warn "  仅本工具使用，不改系统 Python / PATH。"
Write-Info ""

try {
    $exe = Install-PortableRuntime -Root $RuntimeRoot -ArchTag $ArchTag
    $result.PythonExe = $exe
    $result.Ready = $true
    $result.Action = "installed"
    $result | ConvertTo-Json -Compress | Write-Output
    exit 0
}
catch {
    Write-Err "  便携运行时安装失败: $($_.Exception.Message)"
    $result.Ready = $false
    $result.Action = "failed"
    $result.Error = $_.Exception.Message
    $result | ConvertTo-Json -Compress | Write-Output
    exit 1
}
