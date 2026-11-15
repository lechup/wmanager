# Tests for the undo journal (Add-WmJournalEntry in lib\Common.ps1, Restore-WmJournalEntry in lib\Backup.ps1),
# against a real registry key in the current user's hive (HKEY_USERS\<SID>, which Open-WmRegKey supports).
# To run (Pester 5):
#   Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser
#   Invoke-Pester .\tests

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $root 'lib\Common.ps1')
    . (Join-Path $root 'lib\Backup.ps1')
    $script:me = [Security.Principal.WindowsIdentity]::GetCurrent().User

    # A value the way the journal records it, read through the same code
    function Get-TestEntry {
        param([string]$Path, [string]$Name)
        $k = Open-WmRegKey -Path $Path
        try { $state = Get-WmJournalValueState -Key $k -Name $Name } finally { if ($k) { $k.Close() } }
        return [pscustomobject]@{ Key = $Path; Name = $Name; KeyExisted = $true; Ancestor = ''
                                  Existed = [bool]$state; Kind = $(if ($state) { $state.Kind } else { '' })
                                  Value = $(if ($state) { $state.Value } else { $null }) }
    }

    # Like a key Windows protects: the current user may read but not write
    # (through .NET: Get-Acl -LiteralPath doesn't find Registry:: paths in Windows PowerShell 5.1)
    function Set-TestKeyReadOnly {
        param([string]$Path, [bool]$ReadOnly)
        $sub = $Path -replace '^HKEY_USERS\\', ''
        $k = [Microsoft.Win32.Registry]::Users.OpenSubKey($sub, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [System.Security.AccessControl.RegistryRights]'ReadPermissions, ChangePermissions')
        if (-not $k) { return }
        try {
            $acl = $k.GetAccessControl()
            $rule = New-Object System.Security.AccessControl.RegistryAccessRule($script:me, 'SetValue, CreateSubKey, Delete', 'Deny')
            if ($ReadOnly) { $acl.AddAccessRule($rule) } else { [void]$acl.RemoveAccessRule($rule) }
            $k.SetAccessControl($acl)
        } finally { $k.Close() }
    }
}

Describe 'Restore-WmJournalEntry' {
    BeforeEach {
        $script:key = "HKEY_USERS\$($script:me.Value)\Software\wmanager-tests\$([guid]::NewGuid().ToString('N'))"
        New-Item -Path "Registry::$script:key" -Force | Out-Null
        $script:warnings = [System.Collections.ArrayList]@()
        Mock Write-WmLog { if ($Level -eq 'warn') { [void]$script:warnings.Add($Message) } }
    }
    AfterEach {
        Set-TestKeyReadOnly -Path $script:key -ReadOnly $false
        Remove-Item -LiteralPath "Registry::$script:key" -Recurse -Force -ErrorAction SilentlyContinue
    }
    AfterAll {
        Remove-Item -LiteralPath "Registry::HKEY_USERS\$($script:me.Value)\Software\wmanager-tests" -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'leaves a value that never changed alone, even in a key it may not write to' {
        New-ItemProperty -LiteralPath "Registry::$script:key" -Name 'Kept' -Value 0 -PropertyType DWord | Out-Null
        $existed = Get-TestEntry -Path $script:key -Name 'Kept'
        $missing = Get-TestEntry -Path $script:key -Name 'NeverSet'
        Set-TestKeyReadOnly -Path $script:key -ReadOnly $true
        Restore-WmJournalEntry -Entry $existed | Should -BeTrue
        Restore-WmJournalEntry -Entry $missing | Should -BeTrue
        $script:warnings | Should -BeNullOrEmpty
    }

    It 'puts changed values back with their kind' {
        $p = "Registry::$script:key"
        New-ItemProperty -LiteralPath $p -Name 'D' -Value 1 -PropertyType DWord | Out-Null
        New-ItemProperty -LiteralPath $p -Name 'E' -Value '%SystemRoot%\x' -PropertyType ExpandString | Out-Null
        New-ItemProperty -LiteralPath $p -Name 'M' -Value @('a', 'b') -PropertyType MultiString | Out-Null
        New-ItemProperty -LiteralPath $p -Name 'B' -Value ([byte[]](1, 2, 3)) -PropertyType Binary | Out-Null
        $entries = @('D', 'E', 'M', 'B') | ForEach-Object { Get-TestEntry -Path $script:key -Name $_ }
        Set-ItemProperty -LiteralPath $p -Name 'D' -Value 0
        Set-ItemProperty -LiteralPath $p -Name 'E' -Value 'changed'
        Set-ItemProperty -LiteralPath $p -Name 'M' -Value @('a')
        Remove-ItemProperty -LiteralPath $p -Name 'B'
        foreach ($e in $entries) { Restore-WmJournalEntry -Entry $e | Should -BeTrue }
        $k = Open-WmRegKey -Path $script:key
        try {
            $k.GetValue('D') | Should -Be 1
            $k.GetValueKind('E') | Should -Be 'ExpandString'
            $k.GetValue('E', $null, 'DoNotExpandEnvironmentNames') | Should -Be '%SystemRoot%\x'
            $k.GetValue('M') | Should -Be @('a', 'b')
            $k.GetValue('B') | Should -Be @(1, 2, 3)
        } finally { $k.Close() }
    }

    It 'removes a value that did not exist before' {
        $entry = Get-TestEntry -Path $script:key -Name 'Added'
        New-ItemProperty -LiteralPath "Registry::$script:key" -Name 'Added' -Value 1 -PropertyType DWord | Out-Null
        Restore-WmJournalEntry -Entry $entry | Should -BeTrue
        (Get-Item -LiteralPath "Registry::$script:key").GetValueNames() | Should -Not -Contain 'Added'
    }

    It 'still reports a value it really cannot put back' {
        New-ItemProperty -LiteralPath "Registry::$script:key" -Name 'Locked' -Value 1 -PropertyType DWord | Out-Null
        $entry = Get-TestEntry -Path $script:key -Name 'Locked'
        Set-ItemProperty -LiteralPath "Registry::$script:key" -Name 'Locked' -Value 0
        Set-TestKeyReadOnly -Path $script:key -ReadOnly $true
        Restore-WmJournalEntry -Entry $entry | Should -BeFalse
        $script:warnings.Count | Should -Be 1
    }
}
