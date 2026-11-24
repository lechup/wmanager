# Local accounts (Provision.ps1, AdminAccount in the configuration): a separate administrator account, hidden from the
# sign-in screen, and the person signed in a standard user. Both passwords are typed at the computer when provisioning
# starts (twice, not shown) and kept nowhere. The person's password is changed with the current one, as Ctrl+Alt+Del
# does: set without it (a reset), Windows would lose what it keeps under the old one (passwords saved in the browser
# and in Credential Manager, EFS files). The administrator account is created and checked first; the person is
# made a standard user only then, so a failure never leaves the computer without an administrator. Restore-Backup.ps1
# makes those people administrators again (state\accounts-demoted.txt); the hidden flag is a registry value of the
# undo journal.

$script:WmAdminsSid = 'S-1-5-32-544'
$script:WmDemotedFile = Join-Path $script:WmStateDir 'accounts-demoted.txt'
$script:WmHiddenAccountsKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'

# LogonUser checks a password without signing in (a network logon: no profile, no session); NetUserChangePassword
# changes one with the current one.
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

    // 0 when the password of the local account is right, else the Windows error of the logon
    public static int CheckPassword(string user, string password) {
        IntPtr token;
        if (LogonUser(user, ".", password, 3, 0, out token)) { CloseHandle(token); return 0; }   // LOGON32_LOGON_NETWORK
        return Marshal.GetLastWin32Error();
    }
    public static int ChangePassword(string user, string oldPassword, string newPassword) {
        return NetUserChangePassword(Environment.MachineName, user, oldPassword, newPassword);
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

# The SIDs of the members of the local Administrators group (by its SID, so in every language). Read through ADSI:
# Get-LocalGroupMember fails on a group that holds a member it can't resolve (a removed or cloud account).
function Get-WmAdminSids {
    $name = (New-Object System.Security.Principal.SecurityIdentifier $script:WmAdminsSid).Translate([System.Security.Principal.NTAccount]).Value.Split('\')[-1]
    $group = [ADSI]"WinNT://./$name,group"
    return @(foreach ($m in @($group.Invoke('Members'))) {
        $bytes = $m.GetType().InvokeMember('objectSid', 'GetProperty', $null, $m, $null)
        (New-Object System.Security.Principal.SecurityIdentifier($bytes, 0)).Value
    })
}

# Adds an account to the local Administrators group, or removes it (by SID)
function Add-WmAdminMember { param([Parameter(Mandatory = $true)][string]$Sid) Add-LocalGroupMember -SID $script:WmAdminsSid -Member $Sid -ErrorAction Stop }
function Remove-WmAdminMember { param([Parameter(Mandatory = $true)][string]$Sid) Remove-LocalGroupMember -SID $script:WmAdminsSid -Member $Sid -ErrorAction Stop }

# The person signed in at the computer's screen: the user of the console session, not this process (which after UAC
# may run as the administrator account). Name (as DOMAIN\name), Sid, ShortName, Local (the local account, $null for a
# domain or cloud one), Microsoft (signs in with a Microsoft account); $null when nobody is signed in.
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

# A new password typed twice, not shown; $null for Enter (allowed unless -Required)
function Read-WmNewPassword {
    param([Parameter(Mandatory = $true)][string]$Key, [object[]]$Arguments = @(), [switch]$Required)
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
        if ($same) { return $first }
        Write-Host (Get-WmText 'provision.password_mismatch') -ForegroundColor Yellow
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
    $plan = [pscustomobject]@{ Admin = $admin; AdminPassword = $null; User = $null; UserPassword = $null
                               UserOldPassword = $null; Skip = '' }
    if (-not (Test-WmInteractive)) { $plan.Skip = 'no_console'; return $plan }

    if (Get-LocalUser -Name $admin -ErrorAction SilentlyContinue) {
        $plan.AdminPassword = Read-WmNewPassword 'provision.admin_password_existing' @($admin)
    } else {
        $plan.AdminPassword = Read-WmNewPassword 'provision.admin_password_new' @($admin) -Required
    }
    $user = Get-WmConsoleUser
    if (-not $user) { $plan.Skip = 'no_user'; return $plan }
    if ($user.ShortName -ieq $admin) { $plan.Skip = 'signed_in_as_admin'; return $plan }
    $plan.User = $user
    # The person at the computer might be someone else's administrator account (signed in by mistake): asked
    if ((Get-WmAdminSids) -contains $user.Sid -and
        -not (Read-WmYesNo (Get-WmText 'provision.demote_confirm' @($user.Name, $admin)) $true)) { $plan.Skip = 'kept'; return $plan }
    if ($user.Microsoft) { Write-Host ('  ' + (Get-WmText 'provision.user_microsoft_account' @($user.Name))); return $plan }
    if (-not $user.Local) { Write-Host ('  ' + (Get-WmText 'provision.user_not_local' @($user.Name))); return $plan }
    $new = Read-WmNewPassword 'provision.user_password' @($user.Name)
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
# administrator, hidden from the sign-in screen), checked; then the person's password and their removal from the
# Administrators group. Throws when the administrator account isn't ready, before anyone loses administrator rights.
function Set-WmAccounts {
    param($Plan)
    if (-not $Plan) { return }
    switch ($Plan.Skip) {
        'no_console' { Write-WmLog -Key 'provision.accounts_no_console' -Arguments @($Plan.Admin) -Level warn; return }
    }

    $account = Get-LocalUser -Name $Plan.Admin -ErrorAction SilentlyContinue
    if (-not $account) {
        $account = New-LocalUser -Name $Plan.Admin -Password $Plan.AdminPassword -PasswordNeverExpires -AccountNeverExpires `
                                 -Description 'wmanager: administrator account' -ErrorAction Stop
        Write-WmLog -Key 'provision.admin_created' -Arguments @($Plan.Admin)
    } else {
        # Its own account, so set without the old password (nothing of a person's is kept under it)
        if (-not $account.Enabled) { Enable-LocalUser -SID $account.SID.Value -ErrorAction Stop }
        if ($Plan.AdminPassword) {
            Set-LocalUser -SID $account.SID.Value -Password $Plan.AdminPassword -ErrorAction Stop
            Write-WmLog -Key 'provision.password_changed' -Arguments @($Plan.Admin)
        }
    }
    $adminSid = $account.SID.Value
    if ((Get-WmAdminSids) -notcontains $adminSid) { Add-WmAdminMember -Sid $adminSid }
    Set-WmRegValue $script:WmHiddenAccountsKey $Plan.Admin 0
    $account = Get-LocalUser -SID $adminSid -ErrorAction Stop
    if (-not $account.Enabled -or (Get-WmAdminSids) -notcontains $adminSid) { throw (New-WmError 'provision.admin_not_usable' @($Plan.Admin)) }
    Write-WmLog -Key 'provision.admin_ready' -Arguments @($Plan.Admin)

    switch ($Plan.Skip) {
        'no_user' { Write-WmLog -Key 'provision.accounts_no_user' -Level warn; return }
        'signed_in_as_admin' { Write-WmLog -Key 'provision.accounts_signed_in_as_admin' -Arguments @($Plan.Admin); return }
        'kept' { Write-WmLog -Key 'provision.accounts_kept_admin' -Arguments @($Plan.User.Name) -Level warn; return }
    }
    $user = $Plan.User
    if ($Plan.UserPassword) {
        # Not changed (e.g. the password rules of the computer): the old one stays, which the person knows
        try {
            Set-WmAccountPassword -Name $user.ShortName -Old $Plan.UserOldPassword -New $Plan.UserPassword
            Write-WmLog -Key 'provision.password_changed' -Arguments @($user.Name)
        } catch {
            Write-WmLog -Key 'provision.password_not_changed' -Arguments @($user.Name, (Get-WmErrorText $_)) -Level warn
        }
    }
    if ((Get-WmAdminSids) -contains $user.Sid) {
        Remove-WmAdminMember -Sid $user.Sid
        Add-Content -LiteralPath $script:WmDemotedFile -Value $user.Sid -Encoding ASCII
        Write-WmLog -Key 'provision.user_demoted' -Arguments @($user.Name, $Plan.Admin)
    } else {
        Write-WmLog -Key 'provision.user_already_standard' -Arguments @($user.Name)
    }
}

# Restore-Backup.ps1: the people provisioning made standard users become administrators again. The administrator
# account stays (removing an account could lose its files); it shows on the sign-in screen again with the journal.
function Restore-WmDemotedAdmins {
    if (-not (Test-Path -LiteralPath $script:WmDemotedFile)) { return }
    $sids = @(Get-Content -LiteralPath $script:WmDemotedFile | Where-Object { $_ -match '^S-1-' } | Select-Object -Unique)
    $failed = $false
    foreach ($sid in $sids) {
        $name = $sid
        try { $name = (New-Object System.Security.Principal.SecurityIdentifier $sid).Translate([System.Security.Principal.NTAccount]).Value } catch { }
        try {
            if ((Get-WmAdminSids) -notcontains $sid) { Add-WmAdminMember -Sid $sid }
            Write-WmLog -Key 'restore.admin_again' -Arguments @($name)
        } catch {
            $failed = $true
            Write-WmLog -Key 'restore.admin_again_failed' -Arguments @($name, (Get-WmErrorText $_)) -Level error
        }
    }
    if (-not $failed) { Remove-Item -LiteralPath $script:WmDemotedFile -Force -ErrorAction SilentlyContinue }
}
