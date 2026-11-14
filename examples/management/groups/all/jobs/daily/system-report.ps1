# Example job: daily system report. wmanager runs it as SYSTEM once a day (folder jobs/daily) and sends
# every line it prints to Loki unchanged, labelled task="all/system-report". Each line is one JSON object
# with a "kind" field, so Grafana can turn the report into tables, e.g. free space on every computer:
#   {service_name="wmanager", task="all/system-report"} | json | kind="disk"
# A section that fails prints {"kind": ..., "error": ...} instead of stopping the report.
# Exit code 0 = done; anything else is an error in the log. Save as UTF-8 with BOM.
$ErrorActionPreference = 'Stop'

function Out-Report {
    param([string]$Kind, [System.Collections.IDictionary]$Data)
    $o = [ordered]@{ kind = $Kind }
    foreach ($k in $Data.Keys) { $o[$k] = $Data[$k] }
    [pscustomobject]$o | ConvertTo-Json -Compress
}

function Invoke-Section {
    param([string]$Kind, [scriptblock]$Body)
    try { & $Body } catch { Out-Report $Kind ([ordered]@{ error = $_.Exception.Message }) }
}

function Get-Gb { param($Bytes) [math]::Round([double]$Bytes / 1GB, 1) }

# One value of a section: $null when it can't be read, so the rest of the section still gets reported
function Get-Value {
    param([scriptblock]$Body)
    try { & $Body } catch { $null }
}

# --- Resources ------------------------------------------------------------------------
Invoke-Section 'system' {
    $os   = Get-CimInstance Win32_OperatingSystem
    $cs   = Get-CimInstance Win32_ComputerSystem
    $bios = Get-CimInstance Win32_BIOS
    $cpu  = Get-CimInstance Win32_Processor | Select-Object -First 1
    $ubr  = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').UBR
    Out-Report 'system' ([ordered]@{
        manufacturer = $cs.Manufacturer
        model        = $cs.Model
        serial       = $bios.SerialNumber
        os           = $os.Caption
        build        = "$($os.BuildNumber).$ubr"
        cpu          = "$($cpu.Name)".Trim()
        ram_gb       = Get-Gb $cs.TotalPhysicalMemory
        ram_free_gb  = Get-Gb ($os.FreePhysicalMemory * 1KB)    # FreePhysicalMemory is in KB
        last_boot    = $os.LastBootUpTime.ToString('s')
        uptime_days  = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1)
    })
}

Invoke-Section 'disk' {
    foreach ($d in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3')) {
        $pct = $null
        if ($d.Size) { $pct = [math]::Round(100 * $d.FreeSpace / $d.Size) }
        Out-Report 'disk' ([ordered]@{ drive = $d.DeviceID; size_gb = Get-Gb $d.Size; free_gb = Get-Gb $d.FreeSpace; free_pct = $pct })
    }
}

# --- Updates and Defender ---------------------------------------------------------------
Invoke-Section 'updates' {
    $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
    $count = $searcher.GetTotalHistoryCount()
    $history = @()
    if ($count -gt 0) { $history = @($searcher.QueryHistory(0, [Math]::Min($count, 300))) }
    # Installations only (Operation 1), without the daily Defender definition and platform updates
    $installs = @($history | Where-Object { $_.Operation -eq 1 -and $_.Title -notmatch 'KB2267602|KB4052623|KB915597' } |
                  Sort-Object Date -Descending)
    $ok = $installs | Where-Object { $_.ResultCode -eq 2 -or $_.ResultCode -eq 3 } | Select-Object -First 1   # succeeded
    $failed = @($installs | Where-Object { ($_.ResultCode -eq 4 -or $_.ResultCode -eq 5) -and $_.Date -gt (Get-Date).AddDays(-30) })
    $pending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
               (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    $lastInstall = $null; $lastTitle = $null
    if ($ok) { $lastInstall = $ok.Date.ToLocalTime().ToString('s'); $lastTitle = $ok.Title }
    Out-Report 'updates' ([ordered]@{
        last_install       = $lastInstall
        last_install_title = $lastTitle
        failed_30d         = $failed.Count
        reboot_pending     = [bool]$pending
    })
}

Invoke-Section 'defender' {
    $s = Get-MpComputerStatus
    $since = (Get-Date).AddDays(-30)
    $detections = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object { $_.InitialDetectionTime -gt $since })
    $lastName = $null
    if ($detections.Count -gt 0) {
        $last = $detections | Sort-Object InitialDetectionTime -Descending | Select-Object -First 1
        $lastName = (Get-MpThreat -ErrorAction SilentlyContinue | Where-Object { $_.ThreatID -eq $last.ThreatID } | Select-Object -First 1).ThreatName
    }
    # Defender reports 4294967295 (UInt32 max) for "never"
    $never = [uint32]::MaxValue
    $sigAge = $s.AntivirusSignatureAge; if ($sigAge -eq $never) { $sigAge = $null }
    $scanAge = $s.QuickScanAge; if ($scanAge -eq $never) { $scanAge = $null }
    $av = @(Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction SilentlyContinue |
            ForEach-Object { $_.displayName }) -join ', '
    Out-Report 'defender' ([ordered]@{
        antivirus_products = $av
        mode               = [string]$s.AMRunningMode
        realtime           = [bool]$s.RealTimeProtectionEnabled
        tamper_protection  = [bool]$s.IsTamperProtected
        signature_age_days = $sigAge
        quick_scan_age_days = $scanAge
        detections_30d     = $detections.Count
        last_detection     = $lastName
    })
}

# --- Security -----------------------------------------------------------------------------
Invoke-Section 'bitlocker' {
    $ns = 'root\cimv2\Security\MicrosoftVolumeEncryption'
    $protection = @{ 0 = 'off'; 1 = 'on'; 2 = 'unknown' }
    $conversion = @{ 0 = 'decrypted'; 1 = 'encrypted'; 2 = 'encrypting'; 3 = 'decrypting'; 4 = 'encryption paused'; 5 = 'decryption paused' }
    foreach ($v in @(Get-CimInstance -Namespace $ns -ClassName Win32_EncryptableVolume | Where-Object { $_.DriveLetter })) {
        Out-Report 'bitlocker' ([ordered]@{
            drive      = $v.DriveLetter
            protection = $protection[[int]$v.ProtectionStatus]
            status     = $conversion[[int]$v.ConversionStatus]
        })
    }
}

Invoke-Section 'security' {
    $tpm = Get-Value { Get-Tpm }
    $tpmVersion = Get-Value { ((Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName Win32_Tpm).SpecVersion -split ',')[0].Trim() }
    $secureBoot = Get-Value { if (Confirm-SecureBootUEFI) { 'on' } else { 'off' } }
    if (-not $secureBoot) { $secureBoot = 'unsupported' }   # legacy BIOS
    # ActiveStore: what is in force, including group policy and MDM, not only the local settings
    $firewall = Get-Value {
        @(Get-NetFirewallProfile -PolicyStore ActiveStore | ForEach-Object { '{0}={1}' -f $_.Name, $(if ([string]$_.Enabled -eq 'True') { 'on' } else { 'off' }) }) -join ', '
    }
    $uac = Get-Value { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System').EnableLUA -eq 1 }

    # Members of Administrators (S-1-5-32-544). Get-LocalGroupMember fails on some computers with
    # Entra ID members, so the old ADSI interface is used instead.
    $admins = Get-Value {
        $group = (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')).Translate([System.Security.Principal.NTAccount]).Value.Split('\')[-1]
        @(([ADSI]"WinNT://./$group,group").psbase.Invoke('Members') | ForEach-Object {
            $path = $_.GetType().InvokeMember('ADsPath', 'GetProperty', $null, $_, $null)
            $path -replace '^WinNT://', '' -replace '/', '\'
        }) -join ', '
    }

    $tpmPresent = $null; $tpmReady = $null
    if ($tpm) { $tpmPresent = [bool]$tpm.TpmPresent; $tpmReady = [bool]$tpm.TpmReady }
    Out-Report 'security' ([ordered]@{
        tpm_present  = $tpmPresent
        tpm_ready    = $tpmReady
        tpm_version  = $tpmVersion
        secure_boot  = $secureBoot
        firewall     = $firewall
        uac          = $uac
        local_admins = $admins
    })
}

# --- Hardware -------------------------------------------------------------------------------
Invoke-Section 'physical_disk' {
    foreach ($d in @(Get-PhysicalDisk)) {
        $r = $null
        try { $r = $d | Get-StorageReliabilityCounter } catch { }
        Out-Report 'physical_disk' ([ordered]@{
            name            = $d.FriendlyName
            media           = [string]$d.MediaType
            size_gb         = Get-Gb $d.Size
            health          = [string]$d.HealthStatus
            status          = (@($d.OperationalStatus) -join ', ')
            temperature_c   = $r.Temperature
            wear_pct        = $r.Wear
            power_on_hours  = $r.PowerOnHours
            read_errors     = $r.ReadErrorsUncorrected
        })
    }
}

Invoke-Section 'battery' {
    if (-not (Get-CimInstance Win32_Battery)) { return }   # desktop: no line
    # Not every laptop provides these classes ("Not supported"); each value on its own
    $design = Get-Value { @(Get-CimInstance -Namespace 'root\wmi' -ClassName BatteryStaticData)[0].DesignedCapacity }
    $full   = Get-Value { @(Get-CimInstance -Namespace 'root\wmi' -ClassName BatteryFullChargedCapacity)[0].FullChargedCapacity }
    $cycles = Get-Value { @(Get-CimInstance -Namespace 'root\wmi' -ClassName BatteryCycleCount)[0].CycleCount }
    $health = $null
    if ($design -and $full) { $health = [math]::Round(100 * $full / $design) }
    Out-Report 'battery' ([ordered]@{ design_mwh = $design; full_charge_mwh = $full; health_pct = $health; cycles = $cycles })
}

exit 0
