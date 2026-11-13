@echo off
rem Runs Provision.ps1 as administrator and passes parameters through,
rem e.g.:  run.cmd -ComputerName OFFICE-01
setlocal

rem fltmc works only elevated; unlike 'net session' it does not depend on the Server service
fltmc >nul 2>&1
if %errorlevel% neq 0 (
    echo Potrzebne uprawnienia administratora, pojawi sie okno UAC...
    if "%~1"=="" (
        powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    ) else (
        powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    )
    exit /b
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Provision.ps1" %*
echo.
pause
