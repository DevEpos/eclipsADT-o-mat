@echo off
setlocal

cd /d "%~dp0"

where pwsh >nul 2>&1
if errorlevel 1 (
    echo PowerShell 7 ^(pwsh.exe^) was not found.
    echo Install it from https://aka.ms/powershell
    pause
    exit /b 1
)

pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-AdtEclipse.ps1" %*
set "exitCode=%ERRORLEVEL%"

if not "%exitCode%"=="0" (
    echo.
    echo The ADT Bundler exited with code %exitCode%.
)
pause
exit /b %exitCode%
