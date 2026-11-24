# wmanager library: network-drive, revision 1
# Network drives at every sign-in: with each person's own login (Windows asks once and remembers it) or a shared one.
#
# Sign-in script: wmanager runs it at every sign-in, as the person who signs in, hidden, at most 5 minutes. A drive
# that is there and reachable is left as it is; any other is mapped (and remembered, as with "Map network drive" in
# Explorer).
# - Each person's own login (the default; no secret anywhere): it maps a drive with the login Windows remembers for
#   its server; when there is none, Windows shows its "Enter network credentials" window with "Remember my
#   credentials". Cancelled: the next sign-in asks again; not answered within the 5 minutes: the window closes, the
#   log has an error, and the next sign-in asks again (sign-in scripts after this one wait for it meanwhile).
# - One shared login from the company's secrets: delete "off: " in the line below, then add them on your computer:
#   pwsh tools/wm.ps1 <company> secret ShareUser (and SharePassword). Every user of these computers can read them,
#   so give that login access to these shares only.
# off: wmanager-secrets: ShareUser, SharePassword
$ErrorActionPreference = 'Stop'

# --- Settings: the drives (letter and \\server\share) ----------------------------------------------------------
$Drives = @(
    @{ Drive = 'Z:'; Share = '\\nas\documents' }
    # @{ Drive = 'Y:'; Share = '\\nas\scans' }
)
# ------------------------------------------------------------------------------------------------------------

foreach ($d in $Drives) {
    if ($d.Drive -notmatch '^[A-Za-z]:$') { throw "A drive is a letter with a colon, e.g. 'Z:', not '$($d.Drive)'" }
    if ($d.Share -notmatch '^\\\\[^\\]+\\[^\\]+') { throw "A share is \\server\share, not '$($d.Share)'" }
}

# WNetAddConnection2 is what Explorer's "Map network drive" uses: it can show Windows' own login window
if (-not ('WmNetworkDrive' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WmNetworkDrive {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public class Resource {
        public int Scope; public int Type = 1; public int DisplayType; public int Usage;
        public string LocalName; public string RemoteName; public string Comment; public string Provider;
    }
    [DllImport("mpr.dll", CharSet = CharSet.Unicode)]
    public static extern int WNetAddConnection2(Resource resource, string password, string user, int flags);
}
'@
}
$remember = 0x1          # CONNECT_UPDATE_PROFILE: remembered, like a drive mapped in Explorer
$ask = 0x8 -bor 0x10     # CONNECT_INTERACTIVE, CONNECT_PROMPT: Windows asks for the login
$user = $env:WMANAGER_SECRET_SHAREUSER
$failed = 0

foreach ($d in $Drives) {
    $drive = $d.Drive.ToUpperInvariant()
    $share = $d.Share
    # There already, to this share, and reachable: nothing to do
    $mapping = Get-SmbMapping -LocalPath $drive -ErrorAction SilentlyContinue
    if ($mapping -and $mapping.RemotePath -eq $share -and (Test-Path -LiteralPath "$drive\")) {
        Write-Output "$drive is $share."
        continue
    }
    # Another share, or remembered but not reachable (e.g. its login no longer works): mapped again
    if ($mapping) { Remove-SmbMapping -LocalPath $drive -Force -UpdateProfile -ErrorAction SilentlyContinue }

    $resource = New-Object WmNetworkDrive+Resource
    $resource.LocalName = $drive
    $resource.RemoteName = $share
    if ($user) {
        $code = [WmNetworkDrive]::WNetAddConnection2($resource, $env:WMANAGER_SECRET_SHAREPASSWORD, $user, $remember)
    } else {
        # The login Windows remembers for the server first; Windows asks only when there is none (or it fails)
        $code = [WmNetworkDrive]::WNetAddConnection2($resource, $null, $null, $remember)
        if ($code -ne 0) { $code = [WmNetworkDrive]::WNetAddConnection2($resource, $null, $null, $remember -bor $ask) }
    }
    switch ($code) {
        0 { Write-Output "$drive mapped to $share." }
        1223 { Write-Output "$drive not mapped: the login window was cancelled; the next sign-in asks again." }
        85 { Write-Output "$drive is taken by another drive on this computer: set another letter."; $failed++ }
        1219 { Write-Output "$drive not mapped: this computer is connected to the server of $share with another login already (Windows takes one login per server)."; $failed++ }
        default { Write-Output "$drive not mapped to ${share}: $((New-Object ComponentModel.Win32Exception $code).Message) (error $code)"; $failed++ }
    }
}
if ($failed -gt 0) { exit 1 }
exit 0
