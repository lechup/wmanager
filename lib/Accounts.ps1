# Local accounts (Provision.ps1, AdminAccount in the configuration): a separate administrator account, hidden from the
# sign-in screen, and the person signed in a standard user. Both passwords are typed at the computer when provisioning
# starts (twice, not shown, checked against the password rules of the computer) and kept nowhere. The person's
# password is changed with the current one, as Ctrl+Alt+Del does: set without it (a reset), Windows would lose what it
# keeps under the old one (passwords saved in the browser and in Credential Manager, EFS files). The administrator
# account is created and checked first; the person is made a standard user only then, so a failure never leaves the
# computer without a way to administrator rights. Restore-Backup.ps1 makes those people administrators again
# (state\accounts-demoted.txt); the hidden flag and the UAC prompt asking for a name are registry values of the undo
# journal. Automatic sign-in as an account whose password changed is turned off (Disable-WmAutoLogon).

$script:WmAdminsSid = 'S-1-5-32-544'
$script:WmDemotedFile = Join-Path $script:WmStateDir 'accounts-demoted.txt'
$script:WmHiddenAccountsKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
$script:WmCredUiKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\CredUI'
# Automatic sign-in: the account in the Winlogon key, its password in the LSA secret DefaultPassword (Windows Setup,
# netplwiz, Sysinternals Autologon) or in the value of that name there (plain text, set by hand or by a script)
$script:WmWinlogonKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$script:WmAutoLogonSecret = 'DefaultPassword'
# Accounts Windows makes itself, by the end of their SID: Administrator, Guest, DefaultAccount, WDAGUtilityAccount
$script:WmBuiltinRids = @(500, 501, 503, 504)

# LogonUser checks a password without signing in (a network logon: no profile, no session); NetUserChangePassword
# changes one with the current one; NetValidatePasswordPolicy checks a new one against the password rules of this
# computer (length, complexity) before anything is set; LsaStorePrivateData without data removes an LSA secret.
function Initialize-WmAccountNative {
    if ('WmAccountNative' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WmAccountNative {
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool LogonUser(string user, string domain, string password, int logonType, int provider, out IntPtr token);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr handle);
    [DllImport("netapi32.dll", CharSet = CharSet.Unicode)]
    static extern int NetUserChangePassword(string domain, string user, string oldPassword, string newPassword);

    [StructLayout(LayoutKind.Sequential)]
    struct FileTime { public uint Low; public uint High; }
    [StructLayout(LayoutKind.Sequential)]
    struct PersistedFields {
        public uint PresentFields; public FileTime PasswordLastSet; public FileTime BadPasswordTime; public FileTime LockoutTime;
        public uint BadPasswordCount; public uint PasswordHistoryLength; public IntPtr PasswordHistory;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct ResetInput {
        public PersistedFields InputPersistedFields; public string ClearPassword; public string UserAccountName;
        public uint HashLength; public IntPtr Hash; public byte PasswordMustChangeAtNextLogon; public byte ClearLockout;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct Output { public PersistedFields ChangedPersistedFields; public uint ValidationStatus; }
    [DllImport("netapi32.dll", CharSet = CharSet.Unicode)]
    static extern int NetValidatePasswordPolicy(string server, IntPtr qualifier, int type, ref ResetInput input, out IntPtr output);
    [DllImport("netapi32.dll")]
    static extern int NetValidatePasswordPolicyFree(ref IntPtr output);

    [StructLayout(LayoutKind.Sequential)]
    struct LsaObjectAttributes {
        public int Length; public IntPtr RootDirectory; public IntPtr ObjectName; public uint Attributes;
        public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct LsaString { public ushort Length; public ushort MaximumLength; [MarshalAs(UnmanagedType.LPWStr)] public string Buffer; }
    [DllImport("advapi32.dll")]
    static extern uint LsaOpenPolicy(IntPtr system, ref LsaObjectAttributes attributes, uint access, out IntPtr policy);
    [DllImport("advapi32.dll")]
    static extern uint LsaStorePrivateData(IntPtr policy, ref LsaString key, IntPtr data);
    [DllImport("advapi32.dll")]
    static extern uint LsaClose(IntPtr policy);
    [DllImport("advapi32.dll")]
    static extern int LsaNtStatusToWinError(uint status);

    // 0 when the password of the local account is right, else the Windows error of the logon
    public static int CheckPassword(string user, string password) {
        IntPtr token;
        if (LogonUser(user, ".", password, 3, 0, out token)) { CloseHandle(token); return 0; }   // LOGON32_LOGON_NETWORK
        return Marshal.GetLastWin32Error();
    }
    public static int ChangePassword(string user, string oldPassword, string newPassword) {
        return NetUserChangePassword(Environment.MachineName, user, oldPassword, newPassword);
    }
    // 0 when the password meets the password rules of this computer, else why not (e.g. 2245 too short, 2247 not
    // complex enough); -1 when the rules can't be read
    public static int CheckPolicy(string user, string password) {
        ResetInput input = new ResetInput();
        input.ClearPassword = password;
        input.UserAccountName = user;
        IntPtr output;
        if (NetValidatePasswordPolicy(null, IntPtr.Zero, 3, ref input, out output) != 0) return -1;   // NetValidatePasswordReset
        try { return (int)((Output)Marshal.PtrToStructure(output, typeof(Output))).ValidationStatus; }
        finally { NetValidatePasswordPolicyFree(ref output); }
    }
    // 0 when the LSA secret $name is removed, 2 when there was none, else the Windows error
    public static int RemoveSecret(string name) {
        LsaObjectAttributes attributes = new LsaObjectAttributes();
        attributes.Length = Marshal.SizeOf(typeof(LsaObjectAttributes));
        IntPtr policy;
        uint status = LsaOpenPolicy(IntPtr.Zero, ref attributes, 0x20, out policy);   // POLICY_CREATE_SECRET
        if (status != 0) return LsaNtStatusToWinError(status);
        try {
            LsaString key = new LsaString();
            key.Buffer = name;
            key.Length = (ushort)(name.Length * 2);
            key.MaximumLength = (ushort)(name.Length * 2 + 2);
            return LsaNtStatusToWinError(LsaStorePrivateData(policy, ref key, IntPtr.Zero));
        } finally { LsaClose(policy); }
    }
}
'@
}

# Whether $Password is the current password of the local account $Name: $true, $false (wrong), or $null when Windows
# can't say. A right password may still not be allowed to sign in this way: no password at all (allowed at the screen
# only, 1327), the kind of logon not granted (1385), expired (1330, 1907).
function Test-WmAccountPassword {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][securestring]$Password)
    Initialize-WmAccountNative
    $plain = [System.Net.NetworkCredential]::new('', $Password).Password
    try { $code = [WmAccountNative]::CheckPassword($Name, $plain) } finally { $plain = $null }
    if (@(0, 1327, 1385, 1330, 1907) -contains $code) { return $true }
    if ($code -eq 1326) { return $false }
    return $null
}

# Whether $Password meets the password rules of this computer (length, complexity) for the account $Name; $true when
# the rules can't be read (Windows then decides when the password is set)
function Test-WmPasswordPolicy {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][securestring]$Password)
    Initialize-WmAccountNative
    $plain = [System.Net.NetworkCredential]::new('', $Password).Password
    try { $code = [WmAccountNative]::CheckPolicy($Name, $plain) } finally { $plain = $null }
    return ($code -le 0)
}

# Changes the password of the local account $Name with its current one (an empty SecureString: none)
function Set-WmAccountPassword {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][securestring]$Old,
          [Parameter(Mandatory = $true)][securestring]$New)
    Initialize-WmAccountNative
    $o = [System.Net.NetworkCredential]::new('', $Old).Password
    $n = [System.Net.NetworkCredential]::new('', $New).Password
    try { $code = [WmAccountNative]::ChangePassword($Name, $o, $n) } finally { $o = $null; $n = $null }
    if ($code -eq 0) { return }
    # 2245 is a NetAPI error the system messages don't have
    $why = if ($code -eq 2245) { Get-WmText 'provision.password_policy' -English } else { (New-Object ComponentModel.Win32Exception $code).Message }
    throw "$why (error $code)"
}

# Removes the LSA secret $Name; nothing when there is none
function Remove-WmLsaSecret {
    param([Parameter(Mandatory = $true)][string]$Name)
    Initialize-WmAccountNative
    $code = [WmAccountNative]::RemoveSecret($Name)
    if ($code -eq 0 -or $code -eq 2) { return }
    throw ('LSA secret {0}: {1} (error {2})' -f $Name, (New-Object ComponentModel.Win32Exception $code).Message, $code)
}

# Turns off automatic sign-in when it is set for the local account $Name, after wmanager changed its password: at the
# next start Windows would sign in with the old one and fail, and keeping the new one would leave it stored on the
# computer (and the value DefaultPassword in the Winlogon key is plain text that any user can read). AutoAdminLogon 0, and
# the old password removed from both places Windows keeps it; AutoLogonCount too, which would turn off an automatic
# sign-in set up again later. Not journaled: Restore-Backup.ps1 would only bring back a password that no longer works.
# $true when it was on for that account.
function Disable-WmAutoLogon {
    param([Parameter(Mandatory = $true)][string]$Name)
    $values = Get-ItemProperty -LiteralPath $script:WmWinlogonKey -ErrorAction SilentlyContinue
    if (-not $values -or [string]$values.AutoAdminLogon -ne '1') { return $false }
    $user = [string]$values.DefaultUserName
    $domain = [string]$values.DefaultDomainName
    if ($user -match '^(?<domain>[^\\]*)\\(?<user>.+)$') { $domain = $Matches['domain']; $user = $Matches['user'] }
    # A local account: the computer's name, or none; another domain has an account of the same name
    if ($user -ine $Name -or ($domain -and $domain -ne '.' -and $domain -ine $env:COMPUTERNAME)) { return $false }
    Set-ItemProperty -LiteralPath $script:WmWinlogonKey -Name 'AutoAdminLogon' -Value '0' -ErrorAction Stop
    # Each removal is tried even when one before it fails, so a failure leaves as little of the password as it can
    $failed = @()
    foreach ($v in @('DefaultPassword', 'AutoLogonCount')) {
        if ($null -eq $values.$v) { continue }
        try { Remove-ItemProperty -LiteralPath $script:WmWinlogonKey -Name $v -ErrorAction Stop }
        catch { $failed += '{0}: {1}' -f $v, (Get-WmErrorText $_) }
    }
    try { Remove-WmLsaSecret -Name $script:WmAutoLogonSecret } catch { $failed += Get-WmErrorText $_ }
    if ($failed.Count -gt 0) { throw ($failed -join '; ') }
    return $true
}

# After a password change of $Name: automatic sign-in as that account off, said in the log; a failure is a warning
# (the accounts are ready by then, so the step goes on)
function Update-WmAutoLogon {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$Display)
    try {
        if (Disable-WmAutoLogon -Name $Name) { Write-WmLog -Key 'provision.autologon_off' -Arguments @($Display) }
    } catch {
        Write-WmLog -Key 'provision.autologon_failed' -Arguments @($Display, (Get-WmErrorText $_)) -Level warn
    }
}

# The members of the local Administrators group (by its SID, so in every language): Sid, and Group ($true for a group,
# whose members are administrators too). Read through ADSI: Get-LocalGroupMember fails on a group that holds a member
# it can't resolve (a removed or cloud account).
function Get-WmAdminMembers {
    $name = (New-Object System.Security.Principal.SecurityIdentifier $script:WmAdminsSid).Translate([System.Security.Principal.NTAccount]).Value.Split('\')[-1]
    $group = [ADSI]"WinNT://./$name,group"
    return @(foreach ($m in @($group.Invoke('Members'))) {
        $t = $m.GetType()
        $bytes = $t.InvokeMember('objectSid', 'GetProperty', $null, $m, $null)
        $class = try { [string]$t.InvokeMember('Class', 'GetProperty', $null, $m, $null) } catch { '' }
        [pscustomobject]@{ Sid = (New-Object System.Security.Principal.SecurityIdentifier($bytes, 0)).Value; Group = ($class -eq 'Group') }
    })
}

function Get-WmAdminSids { return @(Get-WmAdminMembers | ForEach-Object { $_.Sid }) }

# Adds an account to the local Administrators group, or removes it (by SID)
function Add-WmAdminMember { param([Parameter(Mandatory = $true)][string]$Sid) Add-LocalGroupMember -SID $script:WmAdminsSid -Member $Sid -ErrorAction Stop }
function Remove-WmAdminMember { param([Parameter(Mandatory = $true)][string]$Sid) Remove-LocalGroupMember -SID $script:WmAdminsSid -Member $Sid -ErrorAction Stop }

# The name of an account or group for the log, else its SID
function Get-WmSidName {
    param([string]$Sid)
    try { return (New-Object System.Security.Principal.SecurityIdentifier $Sid).Translate([System.Security.Principal.NTAccount]).Value } catch { return $Sid }
}

# The person signed in at the computer's screen: the user of the console session, not this process (which after UAC
# may run as the administrator account). Name (as DOMAIN\name), Sid, ShortName, Local (the local account, $null for a
# domain or cloud one), Microsoft (signs in with a Microsoft account); $null when nobody is signed in. Throws when the
# account can't be resolved (e.g. a cloud account offline).
function Get-WmConsoleUser {
    $name = [string](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
    if (-not $name) { return $null }
    $sid = (New-Object System.Security.Principal.NTAccount $name).Translate([System.Security.Principal.SecurityIdentifier]).Value
    $local = Get-LocalUser -SID $sid -ErrorAction SilentlyContinue
    return [pscustomobject]@{
        Name = $name; Sid = $sid; ShortName = $name.Split('\')[-1]; Local = $local
        Microsoft = [bool]($local -and [string]$local.PrincipalSource -eq 'MicrosoftAccount')
    }
}

# A new password typed twice, not shown, that meets the password rules of this computer for the account $Account;
# $null for Enter (allowed unless -Required)
function Read-WmNewPassword {
    param([Parameter(Mandatory = $true)][string]$Key, [object[]]$Arguments = @(), [Parameter(Mandatory = $true)][string]$Account,
          [switch]$Required)
    while ($true) {
        $first = Read-Host (Get-WmText $Key $Arguments) -AsSecureString
        if ($first.Length -eq 0) {
            if (-not $Required) { return $null }
            Write-Host (Get-WmText 'provision.password_required') -ForegroundColor Yellow
            continue
        }
        $second = Read-Host (Get-WmText 'provision.password_again') -AsSecureString
        $a = [System.Net.NetworkCredential]::new('', $first).Password
        $b = [System.Net.NetworkCredential]::new('', $second).Password
        $same = [string]::Equals($a, $b, [StringComparison]::Ordinal)
        $a = $null; $b = $null
        if (-not $same) { Write-Host (Get-WmText 'provision.password_mismatch') -ForegroundColor Yellow; continue }
        # Checked now: Windows would refuse it in the middle of the run, when nobody may be at the computer any more
        if (-not (Test-WmPasswordPolicy -Name $Account -Password $first)) { Write-Host (Get-WmText 'provision.password_rules') -ForegroundColor Yellow; continue }
        return $first
    }
}

# Asked when provisioning starts, before anything changes: the administrator account's password, whether the person
# signed in becomes a standard user, and that person's new password with the current one (checked now, three tries).
# $null without AdminAccount. Without a console nothing is asked and Skip says so (Set-WmAccounts then changes nothing).
function Read-WmAccountPlan {
    param([Parameter(Mandatory = $true)][hashtable]$Config)
    $admin = [string](Get-WmSetting $Config 'AdminAccount' '')
    if (-not $admin) { return $null }
    if (-not (Test-WmAccountName $admin)) { throw (New-WmError 'provision.admin_account_invalid' @($admin)) }
    $existing = Get-LocalUser -Name $admin -ErrorAction SilentlyContinue
    # Administrator or Guest would be enabled and hidden as they are (often without a password): never these
    if ($existing -and $script:WmBuiltinRids -contains [long]($existing.SID.Value.Split('-')[-1])) {
        throw (New-WmError 'provision.admin_account_builtin' @($admin))
    }
    $plan = [pscustomobject]@{ Admin = $admin; AdminPassword = $null; User = $null; UserPassword = $null
                               UserOldPassword = $null; UserError = ''; Skip = '' }
    if (-not (Test-WmInteractive)) { $plan.Skip = 'no_console'; return $plan }

    if (-not $existing) {
        $plan.AdminPassword = Read-WmNewPassword 'provision.admin_password_new' @($admin) -Account $admin -Required
    } elseif (-not $existing.Enabled -or (Test-WmAccountPassword -Name $admin -Password (New-Object System.Security.SecureString)) -eq $true) {
        # Enabled as it is, a disabled account or one without a password would be an administrator anyone can use
        $plan.AdminPassword = Read-WmNewPassword 'provision.admin_password_needed' @($admin) -Account $admin -Required
    } else {
        $plan.AdminPassword = Read-WmNewPassword 'provision.admin_password_existing' @($admin) -Account $admin
    }
    try { $user = Get-WmConsoleUser }
    catch { $plan.Skip = 'user_unknown'; $plan.UserError = Get-WmErrorText $_; return $plan }
    if (-not $user) { $plan.Skip = 'no_user'; return $plan }
    if ($user.ShortName -ieq $admin) { $plan.Skip = 'signed_in_as_admin'; return $plan }
    $plan.User = $user
    # The person at the computer might be someone else's administrator account (signed in by mistake): asked, also
    # when the group can't be read
    $isAdmin = $true
    try { $isAdmin = (Get-WmAdminSids) -contains $user.Sid } catch { }
    if ($isAdmin -and -not (Read-WmYesNo (Get-WmText 'provision.demote_confirm' @($user.Name, $admin)) $true)) { $plan.Skip = 'kept'; return $plan }
    if ($user.Microsoft) { Write-Host ('  ' + (Get-WmText 'provision.user_microsoft_account' @($user.Name))); return $plan }
    if (-not $user.Local) { Write-Host ('  ' + (Get-WmText 'provision.user_not_local' @($user.Name))); return $plan }
    $new = Read-WmNewPassword 'provision.user_password' @($user.Name) -Account $user.ShortName
    if (-not $new) { return $plan }
    for ($try = 1; $try -le 3; $try++) {
        $old = Read-Host (Get-WmText 'provision.user_old_password' @($user.Name)) -AsSecureString
        $right = Test-WmAccountPassword -Name $user.ShortName -Password $old
        if ($right -ne $false) { $plan.UserPassword = $new; $plan.UserOldPassword = $old; return $plan }
        Write-Host (Get-WmText 'provision.user_old_password_wrong' @($user.Name)) -ForegroundColor Yellow
    }
    Write-Host ('  ' + (Get-WmText 'provision.user_password_kept' @($user.Name))) -ForegroundColor Yellow
    return $plan
}

# Puts the plan in place: the administrator account (created, or its password changed when one was typed; enabled, an
# administrator, hidden from the sign-in screen, given by name in the UAC prompt), checked; then the person's password
# and their removal from the Administrators group. Throws when the administrator account isn't ready, before anyone
# loses administrator rights.
function Set-WmAccounts {
    param($Plan)
    if (-not $Plan) { return }
    if ($Plan.Skip -eq 'no_console') { Write-WmLog -Key 'provision.accounts_no_console' -Arguments @($Plan.Admin) -Level warn; return }

    $account = Get-LocalUser -Name $Plan.Admin -ErrorAction SilentlyContinue
    if (-not $account) {
        $account = New-LocalUser -Name $Plan.Admin -Password $Plan.AdminPassword -PasswordNeverExpires -AccountNeverExpires `
                                 -Description 'wmanager: administrator account' -ErrorAction Stop
        Write-WmLog -Key 'provision.admin_created' -Arguments @($Plan.Admin)
    } else {
        # Its own account, so set without the old password (nothing of a person's is kept under it)
        if ($Plan.AdminPassword) {
            Set-LocalUser -SID $account.SID.Value -Password $Plan.AdminPassword -ErrorAction Stop
            Write-WmLog -Key 'provision.password_changed' -Arguments @($Plan.Admin)
            Update-WmAutoLogon -Name $Plan.Admin -Display $Plan.Admin
        }
        if (-not $account.Enabled) { Enable-LocalUser -SID $account.SID.Value -ErrorAction Stop }
    }
    $adminSid = $account.SID.Value
    if ((Get-WmAdminSids) -notcontains $adminSid) { Add-WmAdminMember -Sid $adminSid }
    $hidden = Set-WmRegValue $script:WmHiddenAccountsKey $Plan.Admin 0
    # The UAC prompt lists only the administrator accounts the sign-in screen shows: without another one it has no way
    # to give the hidden one (just "No"). It asks for a name and password instead ("Enumerate administrator accounts
    # on elevation" disabled, as CIS also recommends). Hidden without it, nobody may lose administrator rights.
    $byName = Set-WmRegValue $script:WmCredUiKey 'EnumerateAdministrators' 0
    if ($hidden -and -not $byName) { throw (New-WmError 'provision.admin_prompt_failed' @($Plan.Admin)) }
    $account = Get-LocalUser -SID $adminSid -ErrorAction Stop
    $members = @(Get-WmAdminMembers)
    $sids = @($members | ForEach-Object { $_.Sid })
    if (-not $account.Enabled -or $sids -notcontains $adminSid) { throw (New-WmError 'provision.admin_not_usable' @($Plan.Admin)) }
    Write-WmLog -Key 'provision.admin_ready' -Arguments @($Plan.Admin)

    switch ($Plan.Skip) {
        'user_unknown' { Write-WmLog -Key 'provision.accounts_user_unknown' -Arguments @($Plan.UserError) -Level warn; return }
        'no_user' { Write-WmLog -Key 'provision.accounts_no_user' -Level warn; return }
        'signed_in_as_admin' { Write-WmLog -Key 'provision.accounts_signed_in_as_admin' -Arguments @($Plan.Admin); return }
        'kept' { Write-WmLog -Key 'provision.accounts_kept_admin' -Arguments @($Plan.User.Name) -Level warn; return }
    }
    $user = $Plan.User
    if ($Plan.UserPassword) {
        # Not changed (e.g. the password history of the computer): the old one stays, which the person knows
        try {
            Set-WmAccountPassword -Name $user.ShortName -Old $Plan.UserOldPassword -New $Plan.UserPassword
            Write-WmLog -Key 'provision.password_changed' -Arguments @($user.Name)
            Update-WmAutoLogon -Name $user.ShortName -Display $user.Name
        } catch {
            Write-WmLog -Key 'provision.password_not_changed' -Arguments @($user.Name, (Get-WmErrorText $_)) -Level warn
        }
    }
    if ($sids -contains $user.Sid) {
        # Written down first, so Restore-Backup.ps1 knows even when the removal fails half way
        Add-Content -LiteralPath $script:WmDemotedFile -Value $user.Sid -Encoding ASCII -ErrorAction Stop
        Remove-WmAdminMember -Sid $user.Sid
        Write-WmLog -Key 'provision.user_demoted' -Arguments @($user.Name, $Plan.Admin)
    } else {
        Write-WmLog -Key 'provision.user_already_standard' -Arguments @($user.Name)
    }
    # Only the person's own membership is removed: the members of a group in Administrators stay administrators
    $groups = @($members | Where-Object { $_.Group } | ForEach-Object { Get-WmSidName $_.Sid })
    if ($groups.Count -gt 0) { Write-WmLog -Key 'provision.admins_groups' -Arguments @($groups -join ', ') -Level warn }
}

# Restore-Backup.ps1: the people provisioning made standard users become administrators again. The administrator
# account stays (removing an account could lose its files); it shows on the sign-in screen again with the journal.
function Restore-WmDemotedAdmins {
    if (-not (Test-Path -LiteralPath $script:WmDemotedFile)) { return }
    $sids = @(Get-Content -LiteralPath $script:WmDemotedFile | Where-Object { $_ -match '^S-1-' } | Select-Object -Unique)
    $admins = @(Get-WmAdminSids)
    $failed = $false
    foreach ($sid in $sids) {
        $name = Get-WmSidName $sid
        try {
            if ($admins -notcontains $sid) { Add-WmAdminMember -Sid $sid }
            Write-WmLog -Key 'restore.admin_again' -Arguments @($name)
        } catch {
            $failed = $true
            Write-WmLog -Key 'restore.admin_again_failed' -Arguments @($name, (Get-WmErrorText $_)) -Level error
        }
    }
    if (-not $failed) { Remove-Item -LiteralPath $script:WmDemotedFile -Force -ErrorAction SilentlyContinue }
}
