# Tests for the administrator account and the person made a standard user (lib\Accounts.ps1). Windows only.
# - the questions and the order of the changes, with the accounts mocked (nothing on the computer changes)
# - Integration: real local accounts (created, changed and removed again), only on a throwaway CI runner
#   (WM_CI_SOURCES set, see tests\ci\Invoke-Tests.ps1)

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $root 'lib\Common.ps1')
    . (Join-Path $root 'lib\Groups.ps1')
    . (Join-Path $root 'lib\Accounts.ps1')
    Initialize-WmLanguage -Lang 'en'

    function New-TestSecret { param([string]$Text) if (-not $Text) { return (New-Object System.Security.SecureString) }; ConvertTo-SecureString $Text -AsPlainText -Force }
    function Get-TestPlain { param($Secret) if ($null -eq $Secret) { return $null }; [System.Net.NetworkCredential]::new('', $Secret).Password }
}

Describe 'Read-WmAccountPlan' {
    BeforeEach {
        # What is typed, in order (Read-Host: the passwords and the yes/no answer)
        $script:typed = New-Object System.Collections.Generic.Queue[string]
        $script:prompts = New-Object System.Collections.Generic.List[string]
        Mock Read-Host {
            [void]$script:prompts.Add([string]$Prompt)
            $a = if ($script:typed.Count) { $script:typed.Dequeue() } else { '' }
            if ($AsSecureString) { return (New-TestSecret $a) }
            return $a
        }
        Mock Test-WmInteractive { $true }
        Mock Get-LocalUser { $null }
        Mock Get-WmAdminSids { @('S-1-5-21-1-2-3-500', 'S-1-5-21-1-2-3-1001') }
        Mock Test-WmAccountPassword { (Get-TestPlain $Password) -eq 'old-right' }
        Mock Test-WmPasswordPolicy { $true }
        $script:existing = [pscustomobject]@{ Name = 'it-admin'; Enabled = $true; SID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-1002' } }
        $script:person = [pscustomobject]@{ Name = 'PC1\anna'; Sid = 'S-1-5-21-1-2-3-1001'; ShortName = 'anna'
                                            Local = [pscustomobject]@{ Name = 'anna' }; Microsoft = $false }
        Mock Get-WmConsoleUser { $script:person }
        function Use-Typed { param([string[]]$Answers) foreach ($a in $Answers) { $script:typed.Enqueue($a) } }
    }

    It 'is off without AdminAccount' {
        Read-WmAccountPlan -Config @{ AdminAccount = '' } | Should -BeNullOrEmpty
        Should -Invoke Read-Host -Times 0
    }

    It 'stops on a name that is not an account name' {
        { Read-WmAccountPlan -Config @{ AdminAccount = 'bad name' } } | Should -Throw '*not an account name*'
    }

    It 'asks nothing without a console, and says so' {
        Mock Test-WmInteractive { $false }
        $plan = Read-WmAccountPlan -Config @{ AdminAccount = 'it-admin' }
        $plan.Skip | Should -Be 'no_console'
        Should -Invoke Read-Host -Times 0
    }

    It 'asks the new administrator password twice, then the person''s new and current one' {
        # admin, admin again, yes, new, new again, the current one
        Use-Typed 'Adm-1', 'Adm-1', '', 'New-2', 'New-2', 'old-right'
        $plan = Read-WmAccountPlan -Config @{ AdminAccount = 'it-admin' }
        $plan.Skip | Should -Be ''
        Get-TestPlain $plan.AdminPassword | Should -Be 'Adm-1'
        $plan.User.ShortName | Should -Be 'anna'
        Get-TestPlain $plan.UserPassword | Should -Be 'New-2'
        Get-TestPlain $plan.UserOldPassword | Should -Be 'old-right'
        $script:prompts[2] | Should -BeLike 'PC1\anna becomes a standard user*it-admin*'
        $script:prompts[5] | Should -BeLike 'The current password of PC1\anna*'
    }

    It 'asks the new administrator password again when empty or not the same twice' {
        Use-Typed '', 'Adm-1', 'Adm-X', 'Adm-1', 'Adm-1', 'n'
        $plan = Read-WmAccountPlan -Config @{ AdminAccount = 'it-admin' }
        Get-TestPlain $plan.AdminPassword | Should -Be 'Adm-1'
        $plan.Skip | Should -Be 'kept'
    }

    It 'keeps the password of an administrator account that exists on Enter, and the person''s on Enter' {
        Mock Get-LocalUser { $script:existing } -ParameterFilter { $Name -eq 'it-admin' }
        Use-Typed '', 'y', ''
        $plan = Read-WmAccountPlan -Config @{ AdminAccount = 'it-admin' }
        $plan.AdminPassword | Should -BeNullOrEmpty
        $plan.UserPassword | Should -BeNullOrEmpty
        $plan.Skip | Should -Be ''
        # only whether the account has no password
        Should -Invoke Test-WmAccountPassword -Times 1 -ParameterFilter { $Name -eq 'it-admin' -and $Password.Length -eq 0 }
    }

    It 'needs a new password for an administrator account that exists but is disabled' {
        $script:existing.Enabled = $false
        Mock Get-LocalUser { $script:existing } -ParameterFilter { $Name -eq 'it-admin' }
        Use-Typed '', 'Adm-1', 'Adm-1', 'n'
        $plan = Read-WmAccountPlan -Config @{ AdminAccount = 'it-admin' }
        Get-TestPlain $plan.AdminPassword | Should -Be 'Adm-1'
        $script:prompts[0] | Should -BeLike '*it-admin is disabled or has no password*'
    }

    It 'needs a new password for an administrator account that exists without one' {
        Mock Get-LocalUser { $script:existing } -ParameterFilter { $Name -eq 'it-admin' }
        Mock Test-WmAccountPassword { (Get-TestPlain $Password) -eq '' }
        Use-Typed '', 'Adm-1', 'Adm-1', 'n'
        Get-TestPlain (Read-WmAccountPlan -Config @{ AdminAccount = 'it-admin' }).AdminPassword | Should -Be 'Adm-1'
    }

    It 'refuses an account Windows makes itself, whatever its name' {
        Mock Get-LocalUser { [pscustomobject]@{ Name = 'Admin'; Enabled = $false; SID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-500' } } } -ParameterFilter { $Name -eq 'Admin' }
        { Read-WmAccountPlan -Config @{ AdminAccount = 'Admin' } } | Should -Throw '*an account Windows makes itself*'
        Should -Invoke Read-Host -Times 0
    }

    It 'asks again for a password the rules of the computer refuse' {
        Mock Test-WmPasswordPolicy { (Get-TestPlain $Password).Length -ge 5 }
        Use-Typed 'abc', 'abc', 'Adm-1', 'Adm-1', 'n'
        Get-TestPlain (Read-WmAccountPlan -Config @{ AdminAccount = 'it-admin' }).AdminPassword | Should -Be 'Adm-1'
        Should -Invoke Test-WmPasswordPolicy -Times 2 -ParameterFilter { $Name -eq 'it-admin' }
    }

    It 'goes on, making nobody a standard user, when the person signed in can''t be determined' {
        Mock Get-WmConsoleUser { throw 'Some or all identity references could not be translated.' }
        Use-Typed 'Adm-1', 'Adm-1'
        $plan = Read-WmAccountPlan -Config @{ AdminAccount = 'it-admin' }
        $plan.Skip | Should -Be 'user_unknown'
        $plan.UserError | Should -BeLike '*could not be translated*'
    }

    It 'keeps the person''s password after three wrong current ones' {
        Use-Typed 'Adm-1', 'Adm-1', 'y', 'New-2', 'New-2', 'no1', 'no2', 'no3'
        $plan = Read-WmAccountPlan -Config @{ AdminAccount = 'it-admin' }
        $plan.UserPassword | Should -BeNullOrEmpty
        $plan.Skip | Should -Be ''
        Should -Invoke Test-WmAccountPassword -Times 3
    }

    It 'asks no password of a Microsoft account, and no yes/no of a standard user' {
        $script:person.Microsoft = $true
        Mock Get-WmAdminSids { @('S-1-5-21-1-2-3-500') }
        Use-Typed 'Adm-1', 'Adm-1'
        $plan = Read-WmAccountPlan -Config @{ AdminAccount = 'it-admin' }
        $plan.Skip | Should -Be ''
        $plan.UserPassword | Should -BeNullOrEmpty
        Should -Invoke Read-Host -Times 2
    }

    It 'makes nobody a standard user when the administrator account itself is signed in' {
        $script:person.ShortName = 'IT-Admin'
        Use-Typed 'Adm-1', 'Adm-1'
        (Read-WmAccountPlan -Config @{ AdminAccount = 'it-admin' }).Skip | Should -Be 'signed_in_as_admin'
    }

    It 'makes nobody a standard user when nobody is signed in' {
        Mock Get-WmConsoleUser { $null }
        Use-Typed 'Adm-1', 'Adm-1'
        (Read-WmAccountPlan -Config @{ AdminAccount = 'it-admin' }).Skip | Should -Be 'no_user'
    }
}

Describe 'Set-WmAccounts' {
    BeforeEach {
        # TestDrive is shared by the whole Describe: a file of its own for each test
        $script:WmDemotedFile = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.txt')
        $script:log = New-Object System.Collections.Generic.List[string]
        Mock Write-WmLog { [void]$script:log.Add($(if ($Key) { Get-WmText -Key $Key -Arguments $Arguments -English } else { $Message })) }
        $script:admins = New-Object System.Collections.Generic.List[string]
        $script:admins.Add('S-1-5-21-1-2-3-1001')
        Mock Get-WmAdminMembers { @($script:admins | ForEach-Object { [pscustomobject]@{ Sid = $_; Group = $false } }) }
        $script:adminUser = [pscustomobject]@{ Name = 'it-admin'; Enabled = $true; SID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-1002' } }
        Mock Get-LocalUser { $null } -ParameterFilter { $Name }
        Mock Get-LocalUser { $script:adminUser } -ParameterFilter { $SID }
        Mock New-LocalUser { $script:adminUser }
        Mock Enable-LocalUser { }
        Mock Set-LocalUser { }
        Mock Add-WmAdminMember { $script:admins.Add($Sid) }
        Mock Remove-WmAdminMember { [void]$script:admins.Remove($Sid) }
        Mock Set-WmRegValue { $true }
        Mock Set-WmAccountPassword { }
        Mock Disable-WmAutoLogon { $false }
        $script:plan = [pscustomobject]@{
            Admin = 'it-admin'; AdminPassword = (New-TestSecret 'Adm-1'); Skip = ''
            User = [pscustomobject]@{ Name = 'PC1\anna'; Sid = 'S-1-5-21-1-2-3-1001'; ShortName = 'anna'; Microsoft = $false }
            UserPassword = (New-TestSecret 'New-2'); UserOldPassword = (New-TestSecret 'old-right')
        }
    }

    It 'creates the administrator account, hides it, then makes the person a standard user' {
        Set-WmAccounts -Plan $script:plan
        Should -Invoke New-LocalUser -Times 1 -ParameterFilter { $Name -eq 'it-admin' -and $PasswordNeverExpires }
        Should -Invoke Set-WmRegValue -Times 1 -ParameterFilter { $Path -like '*\SpecialAccounts\UserList' -and $Name -eq 'it-admin' -and $Value -eq 0 }
        # hidden, it is typed in the UAC prompt
        Should -Invoke Set-WmRegValue -Times 1 -ParameterFilter { $Path -like '*\Policies\CredUI' -and $Name -eq 'EnumerateAdministrators' -and $Value -eq 0 }
        Should -Invoke Set-WmAccountPassword -Times 1 -ParameterFilter { $Name -eq 'anna' -and (Get-TestPlain $Old) -eq 'old-right' -and (Get-TestPlain $New) -eq 'New-2' }
        Should -Invoke Remove-WmAdminMember -Times 1 -ParameterFilter { $Sid -eq 'S-1-5-21-1-2-3-1001' }
        $script:admins | Should -Be @('S-1-5-21-1-2-3-1002')
        Get-Content -LiteralPath $script:WmDemotedFile | Should -Be 'S-1-5-21-1-2-3-1001'
        $script:log -join "`n" | Should -Match 'PC1\\anna is a standard user now'
    }

    It 'leaves the person an administrator when the administrator account is not one' {
        Mock Add-WmAdminMember { }   # e.g. refused: the account is not in the group afterwards
        { Set-WmAccounts -Plan $script:plan } | Should -Throw '*not enabled or not an administrator*'
        Should -Invoke Remove-WmAdminMember -Times 0
        Should -Invoke Set-WmAccountPassword -Times 0
        Test-Path -LiteralPath $script:WmDemotedFile | Should -BeFalse
    }

    It 'still makes the person a standard user when their password is not changed' {
        Mock Set-WmAccountPassword { throw 'the new password does not meet the password rules (error 2245)' }
        Set-WmAccounts -Plan $script:plan
        $script:log -join "`n" | Should -Match "The password of PC1\\anna wasn't changed .*2245"
        Should -Invoke Remove-WmAdminMember -Times 1
    }

    It 'enables an administrator account that exists and changes its password only when one was typed' {
        $script:adminUser.Enabled = $false
        Mock Get-LocalUser { $script:adminUser } -ParameterFilter { $Name }
        Mock Enable-LocalUser { $script:adminUser.Enabled = $true }
        $script:plan.AdminPassword = $null
        Set-WmAccounts -Plan $script:plan
        Should -Invoke New-LocalUser -Times 0
        Should -Invoke Enable-LocalUser -Times 1
        Should -Invoke Set-LocalUser -Times 0
        Should -Invoke Add-WmAdminMember -Times 1
    }

    It 'changes nothing without a console' {
        $script:plan.Skip = 'no_console'
        Set-WmAccounts -Plan $script:plan
        Should -Invoke New-LocalUser -Times 0
        Should -Invoke Remove-WmAdminMember -Times 0
        $script:log -join "`n" | Should -Match 'Nobody at the console'
    }

    It 'leaves the person as they are when answered so, after the administrator account' {
        $script:plan.Skip = 'kept'
        Set-WmAccounts -Plan $script:plan
        Should -Invoke New-LocalUser -Times 1
        Should -Invoke Remove-WmAdminMember -Times 0
        Should -Invoke Set-WmAccountPassword -Times 0
    }

    It 'says so when the person is a standard user already' {
        $script:admins.Clear()
        Set-WmAccounts -Plan $script:plan
        Should -Invoke Remove-WmAdminMember -Times 0
        $script:log -join "`n" | Should -Match 'PC1\\anna is not in the Administrators group'
    }

    It 'turns off automatic sign-in as the person after changing their password, and says so' {
        Mock Disable-WmAutoLogon { $Name -eq 'anna' }
        Set-WmAccounts -Plan $script:plan
        Should -Invoke Disable-WmAutoLogon -Times 1 -ParameterFilter { $Name -eq 'anna' }
        # a new administrator account can't be the one signing in automatically
        Should -Invoke Disable-WmAutoLogon -Times 0 -ParameterFilter { $Name -eq 'it-admin' }
        $script:log -join "`n" | Should -Match 'Automatic sign-in as PC1\\anna turned off'
    }

    It 'leaves automatic sign-in alone when the person''s password stays' {
        Mock Set-WmAccountPassword { throw 'the new password does not meet the password rules (error 2245)' }
        Set-WmAccounts -Plan $script:plan
        $script:plan.UserPassword = $null
        Set-WmAccounts -Plan $script:plan
        Should -Invoke Disable-WmAutoLogon -Times 0
    }

    It 'turns it off for an administrator account that exists when its password was typed' {
        Mock Get-LocalUser { $script:adminUser } -ParameterFilter { $Name }
        Set-WmAccounts -Plan $script:plan
        Should -Invoke Disable-WmAutoLogon -Times 1 -ParameterFilter { $Name -eq 'it-admin' }
        $script:log -join "`n" | Should -Not -Match 'Automatic sign-in'   # it wasn't on
    }

    It 'warns and goes on when automatic sign-in can''t be turned off' {
        Mock Disable-WmAutoLogon { throw 'LSA secret DefaultPassword: Access is denied (error 5)' }
        Set-WmAccounts -Plan $script:plan
        $script:log -join "`n" | Should -Match 'Turning off automatic sign-in as PC1\\anna failed: .*\(error 5\)'
        $script:log -join "`n" | Should -Not -Match "wasn't changed"
        Should -Invoke Remove-WmAdminMember -Times 1
    }
}

Describe 'Disable-WmAutoLogon' {
    BeforeEach {
        $script:WmWinlogonKey = 'TestRegistry:\winlogon-' + [guid]::NewGuid().ToString('N')
        New-Item -Path $script:WmWinlogonKey -Force | Out-Null
        Mock Remove-WmLsaSecret { }
        function Set-TestAutoLogon {
            param([hashtable]$Values)
            foreach ($k in $Values.Keys) {
                $type = if ($Values[$k] -is [int]) { 'DWord' } else { 'String' }
                New-ItemProperty -LiteralPath $script:WmWinlogonKey -Name $k -Value $Values[$k] -PropertyType $type -Force | Out-Null
            }
        }
        function Get-TestNames { @((Get-ItemProperty -LiteralPath $script:WmWinlogonKey).PSObject.Properties.Name) }
    }

    It 'turns it off for the account, and removes the old password from both places Windows keeps it' {
        Set-TestAutoLogon @{ AutoAdminLogon = '1'; DefaultUserName = 'anna'; DefaultDomainName = $env:COMPUTERNAME
                             DefaultPassword = 'old-right'; AutoLogonCount = 9999 }
        Disable-WmAutoLogon -Name 'Anna' | Should -BeTrue
        (Get-ItemProperty -LiteralPath $script:WmWinlogonKey).AutoAdminLogon | Should -Be '0'
        Get-TestNames | Should -Not -Contain 'DefaultPassword'
        Get-TestNames | Should -Not -Contain 'AutoLogonCount'
        (Get-ItemProperty -LiteralPath $script:WmWinlogonKey).DefaultUserName | Should -Be 'anna'
        Should -Invoke Remove-WmLsaSecret -Times 1 -ParameterFilter { $Name -eq 'DefaultPassword' }
    }

    It 'knows the local account written as <User> with the domain "<Domain>"' -ForEach @(
        @{ User = 'anna'; Domain = '' }, @{ User = 'anna'; Domain = '.' }, @{ User = '.\anna'; Domain = '' }
        @{ User = "$env:COMPUTERNAME\anna"; Domain = 'OFFICE' }
    ) {
        Set-TestAutoLogon @{ AutoAdminLogon = '1'; DefaultUserName = $User; DefaultDomainName = $Domain }
        Disable-WmAutoLogon -Name 'anna' | Should -BeTrue
        (Get-ItemProperty -LiteralPath $script:WmWinlogonKey).AutoAdminLogon | Should -Be '0'
    }

    It 'leaves automatic sign-in as <User> with the domain "<Domain>" alone' -ForEach @(
        @{ User = 'piotr'; Domain = $env:COMPUTERNAME }, @{ User = 'anna'; Domain = 'OFFICE' }
        @{ User = 'OFFICE\anna'; Domain = $env:COMPUTERNAME }
    ) {
        Set-TestAutoLogon @{ AutoAdminLogon = '1'; DefaultUserName = $User; DefaultDomainName = $Domain; DefaultPassword = 'x' }
        Disable-WmAutoLogon -Name 'anna' | Should -BeFalse
        (Get-ItemProperty -LiteralPath $script:WmWinlogonKey).AutoAdminLogon | Should -Be '1'
        Get-TestNames | Should -Contain 'DefaultPassword'
        Should -Invoke Remove-WmLsaSecret -Times 0
    }

    It 'still removes what it can of the password when one place refuses, then says what failed' {
        Set-TestAutoLogon @{ AutoAdminLogon = '1'; DefaultUserName = 'anna'; DefaultPassword = 'old-right'; AutoLogonCount = 3 }
        Mock Remove-ItemProperty { throw 'Access is denied' } -ParameterFilter { $Name -eq 'DefaultPassword' }
        { Disable-WmAutoLogon -Name 'anna' } | Should -Throw '*DefaultPassword: Access is denied*'
        (Get-ItemProperty -LiteralPath $script:WmWinlogonKey).AutoAdminLogon | Should -Be '0'
        Get-TestNames | Should -Not -Contain 'AutoLogonCount'
        Should -Invoke Remove-WmLsaSecret -Times 1
    }

    It 'does nothing when automatic sign-in is off' {
        Set-TestAutoLogon @{ AutoAdminLogon = '0'; DefaultUserName = 'anna'; DefaultPassword = 'x' }
        Disable-WmAutoLogon -Name 'anna' | Should -BeFalse
        Get-TestNames | Should -Contain 'DefaultPassword'
        Remove-Item -LiteralPath $script:WmWinlogonKey
        Disable-WmAutoLogon -Name 'anna' | Should -BeFalse
        Should -Invoke Remove-WmLsaSecret -Times 0
    }
}

Describe 'Set-WmAccounts, when something fails' {
    BeforeEach {
        $script:WmDemotedFile = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.txt')
        $script:log = New-Object System.Collections.Generic.List[string]
        Mock Write-WmLog { [void]$script:log.Add($(if ($Key) { Get-WmText -Key $Key -Arguments $Arguments -English } else { $Message })) }
        $script:admins = New-Object System.Collections.Generic.List[string]
        $script:admins.Add('S-1-5-21-1-2-3-1001')
        $script:adminGroups = @()
        Mock Get-WmAdminMembers { @($script:admins | ForEach-Object { [pscustomobject]@{ Sid = $_; Group = $false } }) + @($script:adminGroups) }
        $script:adminUser = [pscustomobject]@{ Name = 'it-admin'; Enabled = $true; SID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-1002' } }
        Mock Get-LocalUser { $null } -ParameterFilter { $Name }
        Mock Get-LocalUser { $script:adminUser } -ParameterFilter { $SID }
        Mock New-LocalUser { $script:adminUser }
        Mock Add-WmAdminMember { $script:admins.Add($Sid) }
        Mock Remove-WmAdminMember { [void]$script:admins.Remove($Sid) }
        Mock Set-WmRegValue { $true }
        Mock Set-WmAccountPassword { }
        Mock Disable-WmAutoLogon { $false }
        $script:plan = [pscustomobject]@{
            Admin = 'it-admin'; AdminPassword = (New-TestSecret 'Adm-1'); Skip = ''; UserError = ''
            User = [pscustomobject]@{ Name = 'PC1\anna'; Sid = 'S-1-5-21-1-2-3-1001'; ShortName = 'anna'; Microsoft = $false }
            UserPassword = $null; UserOldPassword = $null
        }
    }

    It 'leaves the person an administrator when the UAC prompt can''t be set to ask for the hidden account' {
        Mock Set-WmRegValue { $Name -ne 'EnumerateAdministrators' }
        { Set-WmAccounts -Plan $script:plan } | Should -Throw '*UAC prompt*'
        Should -Invoke Remove-WmAdminMember -Times 0
    }

    It 'writes the person down for the restore before removing them' {
        Mock Remove-WmAdminMember { throw 'Access is denied' }
        { Set-WmAccounts -Plan $script:plan } | Should -Throw '*denied*'
        Get-Content -LiteralPath $script:WmDemotedFile | Should -Be 'S-1-5-21-1-2-3-1001'
    }

    It 'warns about groups in the Administrators group, whose members stay administrators' {
        $script:adminGroups = @([pscustomobject]@{ Sid = 'S-1-5-21-1-2-3-2000'; Group = $true })
        Mock Get-WmSidName { 'PC1\helpdesk' }
        Set-WmAccounts -Plan $script:plan
        $script:log -join "`n" | Should -Match 'groups as members, whose members stay administrators: PC1\\helpdesk'
    }

    It 'says why nobody becomes a standard user when the person signed in can''t be determined' {
        $script:plan.Skip = 'user_unknown'; $script:plan.UserError = 'not translated'
        Set-WmAccounts -Plan $script:plan
        Should -Invoke New-LocalUser -Times 1
        Should -Invoke Remove-WmAdminMember -Times 0
        $script:log -join "`n" | Should -Match "couldn't be determined \(not translated\)"
    }
}

Describe 'Local accounts on Windows' -Tag 'Integration' -Skip:(-not $env:WM_CI_SOURCES) {
    BeforeAll {
        # First: until then these name the computer's own automatic sign-in, which AfterAll would remove after a
        # failure below
        $script:ciWinlogonKey = 'HKLM:\SOFTWARE\wmanager-ci-winlogon'
        $script:ciAutoLogonSecret = 'wmanager-ci-autologon'
        $script:WmWinlogonKey = $script:ciWinlogonKey
        $script:WmAutoLogonSecret = $script:ciAutoLogonSecret
        $script:WmDemotedFile = Join-Path $TestDrive 'accounts-demoted.txt'
        Mock Write-WmLog { }
        $script:names = @('wmci-admin', 'wmci-person', 'wmci-blank')
        foreach ($n in $script:names) { Remove-LocalUser -Name $n -ErrorAction SilentlyContinue }
        # Passwords that also meet the complexity rules of Windows Server
        $script:personOld = 'Old-pass-2026!'
        $person = New-LocalUser -Name 'wmci-person' -Password (New-TestSecret $script:personOld) -PasswordNeverExpires
        Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $person.SID.Value
        $script:person = [pscustomobject]@{ Name = "$env:COMPUTERNAME\wmci-person"; Sid = $person.SID.Value
                                            ShortName = 'wmci-person'; Local = $person; Microsoft = $false }

        # Automatic sign-in as the person, in a key and an LSA secret of the test's own (the runner's own automatic
        # sign-in stays as it is)
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WmTestLsa {
    [StructLayout(LayoutKind.Sequential)]
    struct Attributes { public int Length; public IntPtr Root; public IntPtr Name; public uint Flags; public IntPtr Sd; public IntPtr Qos; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct LsaString { public ushort Length; public ushort MaximumLength; [MarshalAs(UnmanagedType.LPWStr)] public string Buffer; }
    [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr system, ref Attributes attributes, uint access, out IntPtr policy);
    [DllImport("advapi32.dll")] static extern uint LsaStorePrivateData(IntPtr policy, ref LsaString key, ref LsaString data);
    [DllImport("advapi32.dll")] static extern uint LsaRetrievePrivateData(IntPtr policy, ref LsaString key, out IntPtr data);
    [DllImport("advapi32.dll")] static extern uint LsaFreeMemory(IntPtr buffer);
    [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr policy);
    static LsaString Text(string s) { LsaString l = new LsaString(); l.Buffer = s; l.Length = (ushort)(s.Length * 2); l.MaximumLength = (ushort)(s.Length * 2 + 2); return l; }
    static IntPtr Open() {
        Attributes a = new Attributes(); a.Length = Marshal.SizeOf(typeof(Attributes)); IntPtr p;
        uint status = LsaOpenPolicy(IntPtr.Zero, ref a, 0x24, out p);   // POLICY_CREATE_SECRET | POLICY_GET_PRIVATE_INFORMATION
        if (status != 0) throw new Exception("LsaOpenPolicy 0x" + status.ToString("X8"));
        return p;
    }
    public static void Store(string name, string value) {
        IntPtr p = Open();
        try { LsaString k = Text(name); LsaString v = Text(value); uint s = LsaStorePrivateData(p, ref k, ref v); if (s != 0) throw new Exception("LsaStorePrivateData 0x" + s.ToString("X8")); }
        finally { LsaClose(p); }
    }
    public static bool Exists(string name) {
        IntPtr p = Open();
        try {
            LsaString k = Text(name); IntPtr data;
            uint s = LsaRetrievePrivateData(p, ref k, out data);
            if (s == 0) { LsaFreeMemory(data); return true; }
            if (s == 0xC0000034) return false;   // STATUS_OBJECT_NAME_NOT_FOUND
            throw new Exception("LsaRetrievePrivateData 0x" + s.ToString("X8"));
        } finally { LsaClose(p); }
    }
}
'@
        New-Item -Path $script:WmWinlogonKey -Force | Out-Null
        foreach ($v in @(@('AutoAdminLogon', '1'), @('DefaultUserName', 'wmci-person'), @('DefaultDomainName', $env:COMPUTERNAME),
                         @('DefaultPassword', $script:personOld))) {
            New-ItemProperty -LiteralPath $script:WmWinlogonKey -Name $v[0] -Value $v[1] -PropertyType String -Force | Out-Null
        }
        [WmTestLsa]::Store($script:WmAutoLogonSecret, $script:personOld)
    }
    AfterAll {
        foreach ($n in $script:names) { Remove-LocalUser -Name $n -ErrorAction SilentlyContinue }
        Remove-ItemProperty -Path $script:WmHiddenAccountsKey -Name 'wmci-admin' -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $script:WmCredUiKey -Name 'EnumerateAdministrators' -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:ciWinlogonKey -Recurse -ErrorAction SilentlyContinue
        try { Remove-WmLsaSecret -Name $script:ciAutoLogonSecret } catch { }
    }

    It 'tells the current password from a wrong one' {
        Test-WmAccountPassword -Name 'wmci-person' -Password (New-TestSecret $script:personOld) | Should -BeTrue
        Test-WmAccountPassword -Name 'wmci-person' -Password (New-TestSecret 'Wrong-pass-1!') | Should -BeFalse
    }

    It 'creates the hidden administrator account and makes the person a standard user with a new password' {
        $plan = [pscustomobject]@{
            Admin = 'wmci-admin'; AdminPassword = (New-TestSecret 'Admin-pass-2026!'); Skip = ''; User = $script:person
            UserPassword = (New-TestSecret 'New-pass-2026!'); UserOldPassword = (New-TestSecret $script:personOld)
        }
        Set-WmAccounts -Plan $plan
        $admin = Get-LocalUser -Name 'wmci-admin'
        $admin.Enabled | Should -BeTrue
        Get-WmAdminSids | Should -Contain $admin.SID.Value
        Get-WmAdminSids | Should -Not -Contain $script:person.Sid
        (Get-ItemProperty -Path $script:WmHiddenAccountsKey -Name 'wmci-admin').'wmci-admin' | Should -Be 0
        (Get-ItemProperty -Path $script:WmCredUiKey -Name 'EnumerateAdministrators').EnumerateAdministrators | Should -Be 0
        Test-WmAccountPassword -Name 'wmci-admin' -Password (New-TestSecret 'Admin-pass-2026!') | Should -BeTrue
        Test-WmAccountPassword -Name 'wmci-person' -Password (New-TestSecret 'New-pass-2026!') | Should -BeTrue
        Test-WmAccountPassword -Name 'wmci-person' -Password (New-TestSecret $script:personOld) | Should -BeFalse
        Get-Content -LiteralPath $script:WmDemotedFile | Should -Be $script:person.Sid
        # automatic sign-in with the old password: off, and that password gone from the registry and from LSA
        $winlogon = Get-ItemProperty -LiteralPath $script:WmWinlogonKey
        $winlogon.AutoAdminLogon | Should -Be '0'
        $winlogon.PSObject.Properties.Name | Should -Not -Contain 'DefaultPassword'
        [WmTestLsa]::Exists($script:WmAutoLogonSecret) | Should -BeFalse
    }

    It 'removes an LSA secret, and says nothing when there is none' {
        [WmTestLsa]::Store($script:WmAutoLogonSecret, 'x')
        [WmTestLsa]::Exists($script:WmAutoLogonSecret) | Should -BeTrue
        Remove-WmLsaSecret -Name $script:WmAutoLogonSecret
        [WmTestLsa]::Exists($script:WmAutoLogonSecret) | Should -BeFalse
        { Remove-WmLsaSecret -Name $script:WmAutoLogonSecret } | Should -Not -Throw
    }

    It 'makes the person an administrator again (Restore-Backup.ps1)' {
        Restore-WmDemotedAdmins
        Get-WmAdminSids | Should -Contain $script:person.Sid
        Test-Path -LiteralPath $script:WmDemotedFile | Should -BeFalse
    }

    It 'gives an account without a password one' {
        $blank = New-LocalUser -Name 'wmci-blank' -NoPassword
        Test-WmAccountPassword -Name 'wmci-blank' -Password (New-TestSecret '') | Should -BeTrue
        Set-WmAccountPassword -Name 'wmci-blank' -Old (New-TestSecret '') -New (New-TestSecret 'Blank-pass-2026!')
        Test-WmAccountPassword -Name 'wmci-blank' -Password (New-TestSecret 'Blank-pass-2026!') | Should -BeTrue
        $blank | Should -Not -BeNullOrEmpty
    }

    It 'checks a new password against the password rules of the computer' {
        $line = @(& net.exe accounts) -match 'Minimum password length'
        $before = if ($line -and "$line" -match '(\d+)\s*$') { $Matches[1] } else { '0' }
        & net.exe accounts /minpwlen:14 | Out-Null
        try {
            Test-WmPasswordPolicy -Name 'wmci-person' -Password (New-TestSecret 'Sh0rt-pass!') | Should -BeFalse
            Test-WmPasswordPolicy -Name 'wmci-person' -Password (New-TestSecret 'Long-enough-pass-2026!') | Should -BeTrue
        } finally {
            & net.exe accounts "/minpwlen:$before" | Out-Null
        }
    }

    It 'refuses the built-in Administrator account' {
        $builtin = Get-LocalUser | Where-Object { $_.SID.Value -like '*-500' }
        { Read-WmAccountPlan -Config @{ AdminAccount = $builtin.Name } } | Should -Throw '*an account Windows makes itself*'
    }

    It 'says why a password is not changed' {
        { Set-WmAccountPassword -Name 'wmci-person' -Old (New-TestSecret 'Wrong-pass-1!') -New (New-TestSecret 'Other-pass-2026!') } |
            Should -Throw '*(error 86)*'
    }
}
