# wmanager library: defender-hardening, revision 1
# Microsoft Defender: blocks unwanted apps and malicious sites; attack surface reduction rules, logging first.
#
# Group script: wmanager runs it as SYSTEM once, and again whenever this file changes. The attack surface reduction
# (ASR) rules stop typical attack paths: Office macros starting programs, scripts from e-mail, password theft from
# LSASS, ransomware. In AuditMode they only record what they would have blocked (Event Viewer: Applications and
# Services Logs > Microsoft > Windows > Windows Defender > Operational, event 1122); after a few weeks without
# surprises set $AsrAction = 'Enabled'. (Defender's "warn" mode isn't offered: some of these rules don't support it.)
# When another antivirus is active, or Defender is off, its settings don't apply and the script changes nothing.
# Removing the script doesn't undo the settings.
$ErrorActionPreference = 'Stop'

# --- Settings -----------------------------------------------------------------------------------------------
$PuaProtection     = 'Enabled'     # Enabled, AuditMode or Disabled: potentially unwanted apps (adware, bundles)
$NetworkProtection = 'Enabled'     # Enabled, AuditMode or Disabled: connections to known malicious sites, any app
$AsrAction         = 'AuditMode'   # AuditMode (only record) or Enabled (block)
# Left out on purpose: "Block process creations from PSExec and WMI commands" (breaks management tools) and
# "Block executable files unless they meet a prevalence, age or trusted list criterion" (blocks rare in-house tools).
$AsrRules = [ordered]@{
    'BE9BA2D9-53EA-4CDC-84E5-9B1EEEE46550' = 'executable content from e-mail and webmail'
    'D4F940AB-401B-4EFC-AADC-AD5F3C50688A' = 'Office apps creating child processes'
    '3B576869-A4EC-4529-8536-B80A7769E899' = 'Office apps creating executable content'
    '75668C1F-73B5-4CF0-BB93-3ECF5CB7CC84' = 'Office apps injecting code into other processes'
    '26190899-1602-49E8-8B27-EB1D0A1CE869' = 'Office communication app creating child processes'
    '92E97FA1-2EDF-4476-BDD6-9DD0B4DDDC7B' = 'Win32 API calls from Office macros'
    '7674BA52-37EB-4A4F-A9A1-F0F9A1619A2C' = 'Adobe Reader creating child processes'
    'D3E037E1-3EB8-44C8-A917-57927947596D' = 'JavaScript or VBScript launching downloaded executables'
    '5BEB7EFE-FD9A-4556-801D-275E5FFC04CC' = 'potentially obfuscated scripts'
    'B2B3F03D-6A65-4F7B-A9C7-1C7EF74A9BA4' = 'untrusted and unsigned processes from USB'
    '9E6C4E1F-7D60-472F-BA1A-A39EF669E4B2' = 'credential stealing from LSASS'
    'E6DB77E5-3DF2-4CF1-B95A-636979351E5B' = 'persistence through WMI event subscription'
    '56A863A9-875E-4185-98A7-B882C64B5CE5' = 'abuse of exploited vulnerable signed drivers'
    'C1DB55AB-C21A-4637-BB3F-A12568109D35' = 'advanced protection against ransomware'
}
# ------------------------------------------------------------------------------------------------------------

foreach ($v in @($PuaProtection, $NetworkProtection)) {
    if (@('Enabled', 'AuditMode', 'Disabled') -notcontains $v) { throw "PuaProtection and NetworkProtection: Enabled, AuditMode or Disabled, not '$v'" }
}
$asrCode = @{ Enabled = 1; AuditMode = 2 }
if (-not $asrCode.ContainsKey($AsrAction)) { throw "AsrAction: AuditMode or Enabled, not '$AsrAction'" }

# Some antivirus products turn the Defender service off altogether; then this fails instead of reporting a mode
$mode = 'not running'
try { $mode = [string](Get-MpComputerStatus).AMRunningMode } catch { }
if ($mode -ne 'Normal') {
    Write-Output "Microsoft Defender is not the active antivirus (mode: $mode); nothing changed."
    exit 0
}

Set-MpPreference -PUAProtection $PuaProtection -EnableNetworkProtection $NetworkProtection
$ids = @($AsrRules.Keys)
Add-MpPreference -AttackSurfaceReductionRules_Ids $ids -AttackSurfaceReductionRules_Actions (@($AsrAction) * $ids.Count)

# Read back what Defender keeps (Tamper Protection or a policy can overrule a setting)
$p = Get-MpPreference
$have = @{}
$pIds = @($p.AttackSurfaceReductionRules_Ids)
$pActions = @($p.AttackSurfaceReductionRules_Actions)
for ($i = 0; $i -lt $pIds.Count; $i++) { $have[([string]$pIds[$i]).ToUpperInvariant()] = [int]$pActions[$i] }
$missing = @($ids | Where-Object { $have[$_] -ne $asrCode[$AsrAction] })
$names = @{ 0 = 'Disabled'; 1 = 'Enabled'; 2 = 'AuditMode' }
Write-Output ('Defender: unwanted apps {0}, network protection {1}, {2} of {3} attack surface reduction rules in {4}.' -f
              $names[[int]$p.PUAProtection], $names[[int]$p.EnableNetworkProtection], ($ids.Count - $missing.Count), $ids.Count, $AsrAction)
if ($missing.Count -gt 0) {
    Write-Output ('Not in force: ' + (@($missing | ForEach-Object { $AsrRules[$_] }) -join '; '))
    exit 1
}
exit 0
