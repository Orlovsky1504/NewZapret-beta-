@echo off
rem zapret-discord-youtube - menu launcher. Use zapret.ps1 directly for CLI commands.
rem Do not forward raw arguments through cmd.exe; zapret.ps1 handles UAC relaunch.
setlocal
set "ROOT=%~dp0"
set "PWSH=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
cd /d "%ROOT%"

if not exist "%PWSH%" (
    chcp 65001 >nul
    echo [zapret] Не найден Windows PowerShell. / Windows PowerShell was not found.
    exit /b 1
)
"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%ROOT%zapret.ps1"
set "RC=%errorlevel%"

if not "%RC%"=="0" (
    chcp 65001 >nul
    echo.
    echo [zapret] PowerShell завершился с кодом %RC%. / zapret.ps1 exited with code %RC%.
    pause
)
exit /b %RC%
