@echo off
setlocal EnableExtensions
chcp 65001 >nul 2>&1

echo Staging installer to Windows local temp...
for /f "usebackq delims=" %%T in (`powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$local=[Environment]::GetFolderPath('LocalApplicationData'); if ($local) { Join-Path $local 'ClaudeDesktopZhCnInstaller' }"`) do set "CLAUDE_ZH_STAGE=%%T"
set "CLAUDE_ZH_SOURCE_CANDIDATE=%~dp0"
set "CLAUDE_ZH_SOURCE="
for /f "usebackq delims=" %%S in (`powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$p=$env:CLAUDE_ZH_SOURCE_CANDIDATE; if (Test-Path -LiteralPath $p) { (Get-Item -LiteralPath $p).FullName }"`) do set "CLAUDE_ZH_SOURCE=%%S"
if not defined CLAUDE_ZH_STAGE set "CLAUDE_ZH_STAGE=%TEMP%\ClaudeDesktopZhCnInstaller"
if not defined CLAUDE_ZH_SOURCE set "CLAUDE_ZH_SOURCE=%CD%\"
for /f "usebackq delims=" %%U in (`powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "[Environment]::GetFolderPath('UserProfile')"`) do set "CLAUDE_ZH_ORIGINAL_USER_PROFILE=%%U"
for /f "usebackq delims=" %%A in (`powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "[Environment]::GetFolderPath('ApplicationData')"`) do set "CLAUDE_ZH_ORIGINAL_APPDATA=%%A"
for /f "usebackq delims=" %%L in (`powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "[Environment]::GetFolderPath('LocalApplicationData')"`) do set "CLAUDE_ZH_ORIGINAL_LOCALAPPDATA=%%L"
if not defined CLAUDE_ZH_ORIGINAL_USER_PROFILE set "CLAUDE_ZH_ORIGINAL_USER_PROFILE=%USERPROFILE%"
if not defined CLAUDE_ZH_ORIGINAL_APPDATA set "CLAUDE_ZH_ORIGINAL_APPDATA=%APPDATA%"
if not defined CLAUDE_ZH_ORIGINAL_LOCALAPPDATA set "CLAUDE_ZH_ORIGINAL_LOCALAPPDATA=%LOCALAPPDATA%"
if defined SCOOP set "CLAUDE_ZH_ORIGINAL_SCOOP=%SCOOP%"
if defined CLAUDE_PATH set "CLAUDE_ZH_CUSTOM_PATH=%CLAUDE_PATH%"
for /f "usebackq delims=" %%S in (`powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "[System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value"`) do set "CLAUDE_ZH_ORIGINAL_USER_SID=%%S"

if not exist "%CLAUDE_ZH_SOURCE%\scripts\install_windows.ps1" (
    echo.
    echo The installer is incomplete: scripts\install_windows.ps1 was not found.
    echo Please extract the whole claude-desktop-zh-cn archive again, keeping the
    echo scripts and resources folders next to install-windows.bat.
    echo.
    echo 按任意键关闭此窗口。
    pause >nul
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { $src=$env:CLAUDE_ZH_SOURCE; $dst=$env:CLAUDE_ZH_STAGE; if (-not (Test-Path -LiteralPath $src -PathType Container)) { throw ('Source folder does not exist: ' + $src) }; if (-not (Test-Path -LiteralPath (Join-Path $src 'scripts\install_windows.ps1') -PathType Leaf)) { throw ('Installer script does not exist: ' + (Join-Path $src 'scripts\install_windows.ps1')) }; $srcFull=(Get-Item -LiteralPath $src -Force).FullName.TrimEnd('\'); $dstFull=if (Test-Path -LiteralPath $dst -PathType Container) { (Get-Item -LiteralPath $dst -Force).FullName.TrimEnd('\') } else { '' }; if ($srcFull -ieq $dstFull) { Write-Host 'Source and staging folders are the same; reusing the current installer folder.'; exit 0 }; if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }; New-Item -ItemType Directory -Path $dst -Force | Out-Null; Copy-Item -LiteralPath (Join-Path $src 'install-windows.bat') -Destination $dst -Force; Copy-Item -LiteralPath (Join-Path $src 'README.md') -Destination $dst -Force -ErrorAction SilentlyContinue; Copy-Item -LiteralPath (Join-Path $src 'scripts') -Destination $dst -Recurse -Force; Copy-Item -LiteralPath (Join-Path $src 'resources') -Destination $dst -Recurse -Force; exit 0 } catch { Write-Host $_.Exception.Message; exit 1 }"
if errorlevel 1 (
    echo.
    echo Failed to copy installer files to local temp.
    echo Source: %CLAUDE_ZH_SOURCE%
    echo Stage:  %CLAUDE_ZH_STAGE%
    echo Please copy the whole claude-desktop-zh-cn folder to a local Windows path, then run install-windows.bat again.
    echo 按任意键关闭此窗口。
    pause >nul
    exit /b 1
)

echo Requesting administrator privileges...
echo A UAC prompt should appear. If you cancel it, this window stays open with an error message.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { function q($v) { $quote=[string][char]34; return $quote + ([string]$v).Replace($quote, ('\' + $quote)) + $quote }; $script=Join-Path $env:CLAUDE_ZH_STAGE 'scripts\install_windows.ps1'; $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(q $script),'-Interactive'); if ($env:CLAUDE_ZH_ORIGINAL_USER_SID) { $args += @('-OriginalUserSid',(q $env:CLAUDE_ZH_ORIGINAL_USER_SID)) }; if ($env:CLAUDE_ZH_ORIGINAL_USER_PROFILE) { $args += @('-OriginalUserProfile',(q $env:CLAUDE_ZH_ORIGINAL_USER_PROFILE)) }; if ($env:CLAUDE_ZH_ORIGINAL_APPDATA) { $args += @('-OriginalAppData',(q $env:CLAUDE_ZH_ORIGINAL_APPDATA)) }; if ($env:CLAUDE_ZH_ORIGINAL_LOCALAPPDATA) { $args += @('-OriginalLocalAppData',(q $env:CLAUDE_ZH_ORIGINAL_LOCALAPPDATA)) }; if ($env:CLAUDE_ZH_CUSTOM_PATH) { $args += @('-ClaudePath',(q $env:CLAUDE_ZH_CUSTOM_PATH)) }; $log=Join-Path $env:CLAUDE_ZH_STAGE 'install-windows-launch.log'; @('script=' + $script, 'args=' + ($args -join ' '), 'started=' + (Get-Date).ToString('o')) | Set-Content -LiteralPath $log -Encoding UTF8; try { $proc=Start-Process -FilePath 'powershell.exe' -ArgumentList ($args -join ' ') -WorkingDirectory $env:CLAUDE_ZH_STAGE -Verb RunAs -PassThru -Wait -ErrorAction Stop } catch { Write-Host $_.Exception.Message; Add-Content -LiteralPath $log -Value ('elevationFailed=' + $_.Exception.Message) -Encoding UTF8; exit 1223 }; Add-Content -LiteralPath $log -Value ('exitCode=' + $proc.ExitCode) -Encoding UTF8; exit ([int]$proc.ExitCode) } catch { Write-Host $_.Exception.Message; exit 1223 }"
if errorlevel 1223 (
    echo.
    echo Failed to request administrator privileges.
    echo Common causes: UAC was cancelled, or the current user is not allowed to elevate.
    echo Run this script again and choose "Yes" in the UAC prompt.
    echo.
    echo No changes were made to Claude Desktop.
    echo 按任意键关闭此窗口。
    pause >nul
    exit /b 1
)
if errorlevel 1 (
    echo.
    echo 安装器报告失败，详情请查看管理员窗口提示或日志文件：
    echo %CLAUDE_ZH_STAGE%\install-windows.log
    echo 按任意键关闭此窗口。
    pause >nul
    exit /b 1
)

echo Administrator installer finished.
timeout /t 3 >nul 2>&1
exit /b 0
