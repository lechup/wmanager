# wmanager library: network-hardening, revision 1
# Network: SMBv1 off, no LLMNR or NetBIOS name guessing on the local network, firewall on in every profile.
#
# Group script: wmanager runs it as SYSTEM once, and again whenever this file changes. LLMNR and NetBIOS let any
# device on the network answer a name that DNS couldn't find, a common way to capture passwords in an office
# network; with DNS working nothing needs them. Turning NetBIOS off can stop very old devices (an old NAS or
# printer) from being found by name: use their address or DNS name, or set $DisableNetbios = $false. NetBIOS is set
# per network adapter, so an adapter added later (a new dock) keeps the default until this file changes.
# Exit code 3010 when removing SMBv1 needs a restart. Removing the script doesn't undo the settings.
$ErrorActionPreference = 'Stop'

# --- Settings -----------------------------------------------------------------------------------------------
$DisableSmb1    = $true
$DisableLlmnr   = $true
$DisableNetbios = $true
$FirewallOn     = $true   # the Windows firewall in the domain, private and public profiles
# ------------------------------------------------------------------------------------------------------------

# New-Item -Force on an existing key would empty it, so only for a missing one
function Set-Dword {
    param([string]$Key, [string]$Name, [int]$Value)
    if (-not (Test-Path -LiteralPath $Key)) { New-Item -Path $Key -Force | Out-Null }
    New-ItemProperty -LiteralPath $Key -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
}

$restart = $false
$done = @()
if ($DisableSmb1) {
    $f = Get-WindowsOptionalFeature -Online -FeatureName SMB1Protocol
    if ($f -and ([string]$f.State -eq 'Enabled' -or [string]$f.State -eq 'EnablePending')) {
        $r = Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart
        if ($r.RestartNeeded) { $restart = $true }
        $done += 'SMBv1 removed'
    } else {
        $done += 'SMBv1 not installed'
    }
    Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force -Confirm:$false
}
if ($DisableLlmnr) {
    Set-Dword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' 'EnableMulticast' 0
    $done += 'LLMNR off'
}
if ($DisableNetbios) {
    $n = 0
    foreach ($k in @(Get-ChildItem -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces')) {
        New-ItemProperty -LiteralPath $k.PSPath -Name 'NetbiosOptions' -Value 2 -PropertyType DWord -Force | Out-Null
        $n++
    }
    $done += "NetBIOS off on $n adapters"
}
if ($FirewallOn) {
    Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled True
    $done += 'firewall on in every profile'
}

Write-Output ('Network: ' + ($done -join ', ') + '.')
if ($restart) { Write-Output 'Removing SMBv1 takes effect after a restart.'; exit 3010 }
exit 0
