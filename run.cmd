@echo off
rem Uruchamia Provision.ps1 jako administrator. Parametry przekazuje dalej,
rem np.:  run.cmd -ComputerName BIURO-01
setlocal

net session >nul 2>&1
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
