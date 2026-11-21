@echo off
rem Safe in-place updater. Run this from the extracted release folder before copying files.
setlocal
set "ROOT=%~dp0"
set "PWSH=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PWSH%" (
    echo [zapret] Windows PowerShell 5.1 was not found.
    pause
    exit /b 1
)
chcp 65001 >nul
cd /d "%ROOT%"
"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%ROOT%Update-Zapret.ps1"
set "RC=%errorlevel%"
exit /b %RC%
