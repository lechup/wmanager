# wmanager library: windows-update, revision 1
# Windows Update: no automatic restart during working hours, new Windows versions later, drivers optional.
#
# Group script: wmanager runs it as SYSTEM once, and again whenever this file changes (a setting below, or a
# newer revision). It sets the Windows Update for Business policies in
# HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate, as Group Policy would; Settings then shows
# "Some settings are managed by your organization". Windows 11 Home ignores the deferrals (active hours work
# everywhere). Removing the script or leaving the group doesn't undo the settings.
$ErrorActionPreference = 'Stop'

# --- Settings -----------------------------------------------------------------------------------------------
$ActiveHoursStart    = 7       # 0-23: Windows doesn't restart for updates from this hour...
$ActiveHoursEnd      = 19      # ...to this one (0-23, at most 18 hours later)
$FeatureDeferralDays = 90      # 0-365: a new Windows version (e.g. 25H2) waits this many days after its release
$QualityDeferralDays = 0       # 0-30: the monthly updates wait this many days (0 = as soon as they are out)
$ExcludeDrivers      = $false  # $true: no drivers from Windows Update (when the vendor's tool updates them)
# ------------------------------------------------------------------------------------------------------------

if ($ActiveHoursStart -notin 0..23 -or $ActiveHoursEnd -notin 0..23) { throw 'ActiveHoursStart and ActiveHoursEnd must be 0-23' }
$span = ($ActiveHoursEnd - $ActiveHoursStart + 24) % 24
if ($span -lt 1 -or $span -gt 18) { throw 'Active hours must last 1 to 18 hours' }
if ($FeatureDeferralDays -notin 0..365) { throw 'FeatureDeferralDays must be 0-365' }
if ($QualityDeferralDays -notin 0..30) { throw 'QualityDeferralDays must be 0-30' }

# New-Item -Force on an existing key would empty it, so only for a missing one
function Set-Dword {
    param([string]$Key, [string]$Name, [int]$Value)
    if (-not (Test-Path -LiteralPath $Key)) { New-Item -Path $Key -Force | Out-Null }
    New-ItemProperty -LiteralPath $Key -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
}

$key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
Set-Dword $key 'SetActiveHours' 1
Set-Dword $key 'ActiveHoursStart' $ActiveHoursStart
Set-Dword $key 'ActiveHoursEnd' $ActiveHoursEnd
Set-Dword $key 'DeferFeatureUpdates' ([int]($FeatureDeferralDays -gt 0))
Set-Dword $key 'DeferFeatureUpdatesPeriodInDays' $FeatureDeferralDays
Set-Dword $key 'DeferQualityUpdates' ([int]($QualityDeferralDays -gt 0))
Set-Dword $key 'DeferQualityUpdatesPeriodInDays' $QualityDeferralDays
Set-Dword $key 'ExcludeWUDriversInQualityUpdate' ([int]$ExcludeDrivers)

$drivers = 'included'
if ($ExcludeDrivers) { $drivers = 'excluded' }
Write-Output ('Windows Update: active hours {0}:00-{1}:00, new Windows versions after {2} days, monthly updates after {3} days, drivers {4}.' -f
              $ActiveHoursStart, $ActiveHoursEnd, $FeatureDeferralDays, $QualityDeferralDays, $drivers)
exit 0
