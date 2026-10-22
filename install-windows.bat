@echo off
setlocal EnableExtensions
chcp 65001 >nul 2>&1

where pwsh.exe >nul 2>&1
if errorlevel 1 goto missing_powershell
pwsh.exe -NoProfile -Command "if ($PSVersionTable.PSVersion.Major -lt 7) { exit 1 }"
if errorlevel 1 goto missing_powershell

if not exist "%~dp0install-windows.ps1" (
    echo The installer is incomplete: install-windows.ps1 was not found.
    echo Please extract the whole claude-desktop-zh-cn archive again.
    pause
    exit /b 1
)

pwsh.exe -NoProfile -File "%~dp0install-windows.ps1"
set "CLAUDE_ZH_EXIT_CODE=%ERRORLEVEL%"
if not "%CLAUDE_ZH_EXIT_CODE%"=="0" pause
exit /b %CLAUDE_ZH_EXIT_CODE%

:missing_powershell
echo PowerShell 7 or later is required. Install it, then open a new terminal.
echo https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows
echo Nothing was installed and no system settings were changed.
pause
exit /b 1
