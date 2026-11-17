# wmanager library: check-defender, revision 1
# Check: the antivirus is on and up to date, scans run, and nothing was found lately; the job fails otherwise.
#
# Job: wmanager runs it as SYSTEM on its schedule (the jobs/<schedule> folder) and sends each line to Loki, labelled
# task="<group>/check-defender". One JSON line:
#   {"kind":"check","check":"defender","ok":false,"problems":"signatures 6 days old",...}
# A problem makes the job end with exit code 1, which wmanager logs as an error (see check-disk-space). With another
# antivirus active (Defender passive or off), the check passes and names that antivirus.
$ErrorActionPreference = 'Stop'

# --- Settings -----------------------------------------------------------------------------------------------
$MaxSignatureAgeDays = 3
$MaxScanAgeDays      = 14   # days since the last quick or full scan (0 = don't check); a computer whose Windows
                            # is newer than that has time for its first scan
$DetectionDays       = 1    # a threat found within this many days fails the check (0 = don't check)
# ------------------------------------------------------------------------------------------------------------

$problems = @()
$others = @(Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction SilentlyContinue |
            Where-Object { $_.displayName -notmatch 'Defender' } | ForEach-Object { $_.displayName })
$s = $null
try { $s = Get-MpComputerStatus } catch { }
$mode = 'not running'
if ($s) { $mode = [string]$s.AMRunningMode }

$never = [uint32]::MaxValue   # Defender's "never"
$sigAge = $null; $scanAge = $null; $found = 0
if ($mode -eq 'Normal') {
    if (-not $s.RealTimeProtectionEnabled) { $problems += 'real-time protection is off' }
    $sigAge = [int64]$s.AntivirusSignatureAge
    if ($sigAge -eq $never) { $sigAge = $null; $problems += 'no signatures' }
    elseif ($sigAge -gt $MaxSignatureAgeDays) { $problems += "signatures $sigAge days old" }
    $ages = @(@($s.QuickScanAge, $s.FullScanAge) | Where-Object { $_ -ne $never } | ForEach-Object { [int64]$_ })
    if ($ages.Count -gt 0) { $scanAge = ($ages | Measure-Object -Minimum).Minimum }
    if ($MaxScanAgeDays -gt 0) {
        if ($null -ne $scanAge -and $scanAge -gt $MaxScanAgeDays) { $problems += "last scan $scanAge days ago" }
        if ($null -eq $scanAge) {
            $installed = [math]::Floor(((Get-Date) - (Get-CimInstance Win32_OperatingSystem).InstallDate).TotalDays)
            if ($installed -gt $MaxScanAgeDays) { $problems += "no scan in the $installed days since Windows was installed" }
        }
    }
    if ($DetectionDays -gt 0) {
        $from = (Get-Date).AddDays(-$DetectionDays)
        $found = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object { $_.InitialDetectionTime -gt $from }).Count
        if ($found -gt 0) { $problems += "$found threats found in the last $DetectionDays days" }
    }
} elseif ($others.Count -eq 0) {
    $problems += "Microsoft Defender is $mode and no other antivirus is registered"
}

[pscustomobject][ordered]@{
    kind = 'check'; check = 'defender'; ok = ($problems.Count -eq 0); problems = ($problems -join '; ')
    mode = $mode; other_antivirus = ($others -join ', '); signature_age_days = $sigAge
    scan_age_days = $scanAge; detections = $found
} | ConvertTo-Json -Compress
if ($problems.Count -gt 0) {
    [Console]::Error.WriteLine('Defender: ' + ($problems -join '; '))
    exit 1
}
exit 0
