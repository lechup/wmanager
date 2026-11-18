# wmanager library: check-disk-space, revision 1
# Check: enough free space on every local disk; the job fails (an error in the log and Loki) when one runs low.
#
# Job: wmanager runs it as SYSTEM on its schedule (the jobs/<schedule> folder) and sends each line to Loki, labelled
# task="<group>/check-disk-space". One JSON line per disk:
#   {"kind":"check","check":"disk_space","ok":false,"drive":"C:","free_gb":9.6,"free_pct":4,...}
# A low disk makes the job end with exit code 1, which wmanager logs as an error, so one alert covers every check:
#   count_over_time({service_name="wmanager", job="jobs", level="error"} [1d])
$ErrorActionPreference = 'Stop'

# --- Settings -----------------------------------------------------------------------------------------------
$MinFreeGb      = 15   # a disk is low when it has less than this many GB free...
$MinFreePercent = 10   # ...and less than this share of its size (so a small disk isn't low just for its size)
# ------------------------------------------------------------------------------------------------------------

$low = @()
foreach ($d in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3')) {
    if (-not $d.Size) { continue }
    $freeGb = [double]$d.FreeSpace / 1GB
    $freePct = 100 * [double]$d.FreeSpace / [double]$d.Size
    $ok = -not ($freeGb -lt $MinFreeGb -and $freePct -lt $MinFreePercent)   # the exact values, rounded only for the output
    $gb = [math]::Round($freeGb, 1)
    $pct = [math]::Round($freePct)
    if (-not $ok) { $low += $d.DeviceID }
    [pscustomobject][ordered]@{
        kind = 'check'; check = 'disk_space'; ok = $ok; drive = $d.DeviceID
        free_gb = $gb; free_pct = $pct; size_gb = [math]::Round([double]$d.Size / 1GB, 1)
        min_free_gb = $MinFreeGb; min_free_pct = $MinFreePercent
    } | ConvertTo-Json -Compress
}
if ($low.Count -gt 0) {
    [Console]::Error.WriteLine("Low on free space: $($low -join ', ')")
    exit 1
}
exit 0
