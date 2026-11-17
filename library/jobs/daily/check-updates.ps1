# wmanager library: check-updates, revision 1
# Check: Windows keeps installing updates and gets its restarts; the job fails when it falls behind.
#
# Job: wmanager runs it as SYSTEM on its schedule (the jobs/<schedule> folder) and sends each line to Loki, labelled
# task="<group>/check-updates". One JSON line:
#   {"kind":"check","check":"windows_update","ok":false,"problems":"no update installed for 52 days",...}
# A problem makes the job end with exit code 1, which wmanager logs as an error (see check-disk-space).
# How long a restart has been pending isn't recorded by Windows, so this uses the uptime: a restart is pending and
# the computer hasn't restarted for that many days. With Fast Startup on, "Shut down" doesn't reset the uptime
# (the power script of the library turns Fast Startup off).
$ErrorActionPreference = 'Stop'

# --- Settings -----------------------------------------------------------------------------------------------
$MaxDaysWithoutUpdate  = 40   # the monthly updates come every ~30 days
$MaxDaysRestartPending = 7
# ------------------------------------------------------------------------------------------------------------

$now = Get-Date
$problems = @()

# The last successful installation, without the daily Defender definition and platform updates
$searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
$count = $searcher.GetTotalHistoryCount()
$history = @()
if ($count -gt 0) { $history = @($searcher.QueryHistory(0, [Math]::Min($count, 300))) }
$installs = @($history | Where-Object { $_.Operation -eq 1 -and $_.Title -notmatch 'KB2267602|KB4052623|KB915597' })
$ok = @($installs | Where-Object { $_.ResultCode -eq 2 -or $_.ResultCode -eq 3 } | Sort-Object Date -Descending)
$failed = @($installs | Where-Object { ($_.ResultCode -eq 4 -or $_.ResultCode -eq 5) -and $_.Date -gt $now.AddDays(-30) })
$os = Get-CimInstance Win32_OperatingSystem
$last = $null
if ($ok.Count -gt 0) { $last = $ok[0].Date.ToLocalTime() }
# A computer installed recently has no history yet: count from the installation of Windows
$since = $last
if (-not $since) { $since = $os.InstallDate }
$days = [math]::Floor(($now - $since).TotalDays)
if ($days -gt $MaxDaysWithoutUpdate) { $problems += "no update installed for $days days" }

$pending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
           (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
$uptime = [math]::Round(($now - $os.LastBootUpTime).TotalDays, 1)
if ($pending -and $uptime -gt $MaxDaysRestartPending) { $problems += "a restart is pending and the computer has been up for $uptime days" }

$lastText = $null
if ($last) { $lastText = $last.ToString('s') }
[pscustomobject][ordered]@{
    kind = 'check'; check = 'windows_update'; ok = ($problems.Count -eq 0); problems = ($problems -join '; ')
    last_install = $lastText; days_without_update = $days; failed_30d = $failed.Count
    restart_pending = [bool]$pending; uptime_days = $uptime
} | ConvertTo-Json -Compress
if ($problems.Count -gt 0) {
    [Console]::Error.WriteLine('Windows Update: ' + ($problems -join '; '))
    exit 1
}
exit 0
