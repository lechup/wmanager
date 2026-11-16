@echo off
rem Configuration wizard: writes provision.config.psd1 next to run.cmd (no administrator rights needed).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0init.ps1" %*
echo.
pause
