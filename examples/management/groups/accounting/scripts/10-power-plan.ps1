# Example group script. wmanager runs it as SYSTEM in Windows PowerShell 5.1: once, and again whenever
# this file changes. Exit code 0 = done, 3010 = done but needs a restart, anything else (or an
# exception) = failed, and it runs again at the next scheduled update. Its output goes to the wmanager log.
# Environment: WMANAGER_GROUP, WMANAGER_COMPUTER, WMANAGER_GROUP_DIR (this group's folder, for its files).
# Save scripts as UTF-8 with BOM, otherwise Windows PowerShell 5.1 garbles Polish letters.
$ErrorActionPreference = 'Stop'

# The accounting computers run long exports: never sleep on AC power.
# (With 'Stop', anything a program writes to stderr would stop the script, so check exit codes instead.)
powercfg.exe /change standby-timeout-ac 0
if ($LASTEXITCODE -ne 0) { throw "powercfg zwrócił kod $LASTEXITCODE" }
Write-Output "Uśpienie na zasilaczu wyłączone ($env:WMANAGER_COMPUTER, grupa $env:WMANAGER_GROUP)."
exit 0
