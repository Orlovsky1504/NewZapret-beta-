@echo off
setlocal
rem Native launcher (Zapret-Control.exe) is the preferred entry point; this
rem batch file stays as a compatibility fallback for locked-down systems.
if exist "%~dp0Zapret-Control.exe" (
    start "" "%~dp0Zapret-Control.exe"
    exit /b 0
)
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" (
    echo Windows PowerShell 5.1 was not found.
    pause
    exit /b 1
)
if not exist "%~dp0Zapret-Control.ps1" (
    echo Zapret-Control.ps1 was not found next to this launcher.
    pause
    exit /b 1
)
start "" "%PS%" -NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0Zapret-Control.ps1"
endlocal
