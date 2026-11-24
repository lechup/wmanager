# wmanager library: network-drive, revision 1
# Network drives at every sign-in: with each person's own login (asked once, then remembered) or a shared one.
#
# Sign-in script: wmanager runs it at every sign-in, as the person who signs in, hidden, at most 5 minutes. A drive
# that is there and reachable is left as it is; any other is mapped (and remembered, as with "Map network drive" in
# Explorer).
# - Each person's own login (the default; no secret anywhere): it maps a drive with the login Windows remembers for
#   its server; when there is none (or it no longer works), Windows' own login window asks for it, with "Remember"
#   (ticked: the login is kept in the person's Credential Manager, and the drive is mapped without asking from then
#   on). Cancelled: the next sign-in asks again; not answered within the 5 minutes: the window closes, the log has an
#   error, and the next sign-in asks again (sign-in scripts after this one wait for it meanwhile).
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

# WNetAddConnection2 maps a drive with a login it is given (without one it would log on anonymously, not with the
# remembered one: net use does that). CredUIPromptForCredentials is Windows' own login window; CredWrite keeps the
# login as cmdkey /add does (what the window's own "Remember" keeps isn't always taken when the drive reconnects).
if (-not ('WmNetworkDrive' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class WmNetworkDrive {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public class Resource {
        public int Scope; public int Type = 1; public int DisplayType; public int Usage;
        public string LocalName; public string RemoteName; public string Comment; public string Provider;
    }
    [DllImport("mpr.dll", CharSet = CharSet.Unicode)]
    public static extern int WNetAddConnection2(Resource resource, string password, string user, int flags);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct CREDUI_INFO { public int cbSize; public IntPtr hwndParent; public string pszMessageText; public string pszCaptionText; public IntPtr hbmBanner; }
    [DllImport("credui.dll", CharSet = CharSet.Unicode)]
    static extern int CredUIPromptForCredentials(ref CREDUI_INFO info, string target, IntPtr reserved, int authError,
        StringBuilder user, int userMax, StringBuilder password, int passwordMax, ref bool save, int flags);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct CREDENTIAL {
        public int Flags; public int Type; public string TargetName; public string Comment; public long LastWritten;
        public int CredentialBlobSize; public IntPtr CredentialBlob; public int Persist; public int AttributeCount;
        public IntPtr Attributes; public string TargetAlias; public string UserName;
    }
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredWrite(ref CREDENTIAL credential, int flags);

    public class Login { public string User; public string Password; public bool Save; }

    // Windows' login window for the server, with "Remember" (kept by Remember below, not by the window); null when
    // cancelled. error: why the last login failed (0 for none), which the window shows.
    public static Login Ask(string server, string message, int error) {
        CREDUI_INFO info = new CREDUI_INFO();
        info.cbSize = Marshal.SizeOf(typeof(CREDUI_INFO));
        info.pszMessageText = message;
        info.pszCaptionText = "Network drive";
        StringBuilder user = new StringBuilder(513);
        StringBuilder password = new StringBuilder(256);
        bool save = true;
        // CREDUI_FLAGS_DO_NOT_PERSIST 0x2, EXCLUDE_CERTIFICATES 0x8, SHOW_SAVE_CHECK_BOX 0x40, INCORRECT_PASSWORD 0x1
        int flags = 0x2 | 0x8 | 0x40 | (error != 0 ? 0x1 : 0);
        int code = CredUIPromptForCredentials(ref info, server, IntPtr.Zero, error, user, user.Capacity, password, password.Capacity, ref save, flags);
        if (code == 1223) return null;
        if (code != 0) throw new System.ComponentModel.Win32Exception(code, "CredUIPromptForCredentials");
        Login login = new Login();
        login.User = user.ToString(); login.Password = password.ToString(); login.Save = save;
        return login;
    }

    // Keeps the login for the server in the person's Credential Manager, as cmdkey /add:<server> does
    public static void Remember(string server, string user, string password) {
        CREDENTIAL c = new CREDENTIAL();
        c.Type = 2;                                   // CRED_TYPE_DOMAIN_PASSWORD
        c.TargetName = server;
        c.UserName = user;
        c.Persist = 2;                                // CRED_PERSIST_LOCAL_MACHINE: this computer
        c.CredentialBlobSize = password.Length * 2;
        c.CredentialBlob = Marshal.StringToCoTaskMemUni(password);
        try {
            if (!CredWrite(ref c, 0)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "CredWrite");
        } finally {
            Marshal.ZeroFreeCoTaskMemUnicode(c.CredentialBlob);
        }
    }
}
'@
}
# net use with the login Windows remembers; its exit code (Windows PowerShell 5.1 would turn its message on stderr
# into an exception under 'Stop')
function Invoke-NetUse {
    param([string]$Drive, [string]$Share)
    $ErrorActionPreference = 'Continue'
    $null = & net.exe use $Drive $Share /persistent:yes 2>&1
    return $LASTEXITCODE
}

$remember = 0x1          # CONNECT_UPDATE_PROFILE: remembered, like a drive mapped in Explorer
$sharedUser = $env:WMANAGER_SECRET_SHAREUSER
$failed = 0

foreach ($d in $Drives) {
    $drive = $d.Drive.ToUpperInvariant()
    $share = $d.Share
    $server = $share.Substring(2).Split('\')[0]
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
    if ($sharedUser) {
        $code = [WmNetworkDrive]::WNetAddConnection2($resource, $env:WMANAGER_SECRET_SHAREPASSWORD, $sharedUser, $remember)
    } else {
        # The login Windows remembers for the server: net use takes it (its input is empty here, so where it would
        # ask for one it fails at once)
        if ((Invoke-NetUse $drive $share) -eq 0) { Write-Output "$drive mapped to $share with the remembered login."; continue }
        # None, or it no longer works: Windows' login window, three tries
        $code = 1223
        $why = 0
        for ($try = 1; $try -le 3; $try++) {
            $login = [WmNetworkDrive]::Ask($server, "Your login to $share, for drive $drive", $why)
            if (-not $login) { $code = 1223; break }
            $code = [WmNetworkDrive]::WNetAddConnection2($resource, $login.Password, $login.User, $remember)
            if ($code -eq 0) {
                if ($login.Save) { [WmNetworkDrive]::Remember($server, $login.User, $login.Password) }
                break
            }
            if (@(86, 1326, 5) -notcontains $code) { break }   # a wrong login: asked again, with the reason
            $why = $code
        }
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
