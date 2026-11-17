# wmanager library: power, revision 1
# Power: when the screen turns off and the computer sleeps, plugged in and on battery; Fast Startup off.
#
# Group script: wmanager runs it as SYSTEM once, and again whenever this file changes. It changes the active power
# plan (powercfg), which every user of the computer shares. Fast Startup off makes "Shut down" a real shutdown:
# updates waiting for a restart get it, and the uptime in the reports means what it says. Removing the script
# doesn't undo the settings.
$ErrorActionPreference = 'Stop'

# --- Settings (minutes; 0 = never) --------------------------------------------------------------------------
$ScreenOffPluggedIn = 15
$SleepPluggedIn     = 0        # desktops and docked laptops: never sleep, so remote access and exports keep working
$ScreenOffOnBattery = 5
$SleepOnBattery     = 20
$DisableFastStartup = $true
# ------------------------------------------------------------------------------------------------------------

function Invoke-Powercfg {
    param([string[]]$Arguments)
    # Windows PowerShell 5.1 would turn a line on stderr into an exception under 'Stop'; the exit code decides
    $ErrorActionPreference = 'Continue'
    $out = & powercfg.exe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "powercfg $($Arguments -join ' ') failed ($LASTEXITCODE): $out" }
}

foreach ($v in @($ScreenOffPluggedIn, $SleepPluggedIn, $ScreenOffOnBattery, $SleepOnBattery)) {
    if ($v -isnot [int] -or $v -lt 0) { throw 'The times must be whole minutes, 0 or more' }
}
Invoke-Powercfg @('/change', 'monitor-timeout-ac', "$ScreenOffPluggedIn")
Invoke-Powercfg @('/change', 'standby-timeout-ac', "$SleepPluggedIn")
Invoke-Powercfg @('/change', 'monitor-timeout-dc', "$ScreenOffOnBattery")
Invoke-Powercfg @('/change', 'standby-timeout-dc', "$SleepOnBattery")

$key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
New-ItemProperty -LiteralPath $key -Name 'HiberbootEnabled' -Value ([int](-not $DisableFastStartup)) -PropertyType DWord -Force | Out-Null

function Format-Minutes { param([int]$M) if ($M -eq 0) { 'never' } else { "$M min" } }
$fast = 'on'
if ($DisableFastStartup) { $fast = 'off' }
Write-Output ('Power: plugged in screen off {0}, sleep {1}; on battery screen off {2}, sleep {3}; Fast Startup {4}.' -f
              (Format-Minutes $ScreenOffPluggedIn), (Format-Minutes $SleepPluggedIn),
              (Format-Minutes $ScreenOffOnBattery), (Format-Minutes $SleepOnBattery), $fast)
exit 0
