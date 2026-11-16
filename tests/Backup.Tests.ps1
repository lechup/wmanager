# Tests for registry writes and the undo journal (Set-WmRegValue and Add-WmJournalEntry in lib\Common.ps1,
# Restore-WmJournalEntry in lib\Backup.ps1),
# against a real registry key in the current user's hive (HKEY_USERS\<SID>, which Open-WmRegKey supports).
# To run (Pester 5):
#   Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser
#   Invoke-Pester .\tests

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $root 'lib\Common.ps1')
    . (Join-Path $root 'lib\Backup.ps1')
    Initialize-WmLanguage -Lang 'en'
    $script:me = [Security.Principal.WindowsIdentity]::GetCurrent().User

    # A value the way the journal records it, read through the same code and through the same JSON line
    # (Add-WmJournalEntry writes it, Read-WmJournal reads it back)
    function Get-TestEntry {
        param([string]$Path, [string]$Name)
        $k = Open-WmRegKey -Path $Path
        try { $state = Get-WmJournalValueState -Key $k -Name $Name } finally { if ($k) { $k.Close() } }
        $entry = [ordered]@{ Key = $Path; Name = $Name; KeyExisted = $true; Ancestor = ''
                             Existed = [bool]$state; Kind = $(if ($state) { $state.Kind } else { '' })
                             Value = $(if ($state) { $state.Value } else { $null }) }
        return ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject ([pscustomobject]$entry) -Compress -Depth 4)
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
            # the key's only explicit rule for this user is the deny one (the rest is inherited)
            if ($ReadOnly) { $acl.AddAccessRule($rule) } else { $acl.PurgeAccessRules($script:me) }
            $k.SetAccessControl($acl)
        } finally { $k.Close() }
    }
}

Describe 'Restore-WmJournalEntry' {
    BeforeEach {
        $script:key = "HKEY_USERS\$($script:me.Value)\Software\wmanager-tests\$([guid]::NewGuid().ToString('N'))"
        New-Item -Path "Registry::$script:key" -Force | Out-Null
        $script:warnings = [System.Collections.ArrayList]@()
        Mock Write-WmLog { if ($Level -eq 'warn') { [void]$script:warnings.Add($(if ($Key) { Get-WmText -Key $Key -Arguments $Arguments -English } else { $Message })) } }
    }
    AfterEach {
        Set-TestKeyReadOnly -Path $script:key -ReadOnly $false
        Remove-Item -LiteralPath "Registry::$script:key" -Recurse -Force -ErrorAction SilentlyContinue
    }
    AfterAll {
        Remove-Item -LiteralPath "Registry::HKEY_USERS\$($script:me.Value)\Software\wmanager-tests" -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'leaves a value that never changed alone, even in a key it may not write to' {
        $p = "Registry::$script:key"
        New-ItemProperty -LiteralPath $p -Name 'Kept' -Value 0 -PropertyType DWord | Out-Null
        New-ItemProperty -LiteralPath $p -Name 'One' -Value @('only') -PropertyType MultiString | Out-Null
        New-ItemProperty -LiteralPath $p -Name 'Path' -Value '%SystemRoot%\x' -PropertyType ExpandString | Out-Null
        $entries = @('Kept', 'One', 'Path', 'NeverSet') | ForEach-Object { Get-TestEntry -Path $script:key -Name $_ }
        Set-TestKeyReadOnly -Path $script:key -ReadOnly $true
        foreach ($e in $entries) { Restore-WmJournalEntry -Entry $e | Should -BeTrue -Because $e.Name }
        $script:warnings | Should -BeNullOrEmpty
    }

    It 'tells an empty multi-string from one holding an empty string' {
        Test-WmSameJournalValue @() @('') | Should -BeFalse
        Test-WmSameJournalValue @('a', 'b') @('a', 'b') | Should -BeTrue
        Test-WmSameJournalValue @('a', 'b') @('a', 'B') | Should -BeFalse
        Test-WmSameJournalValue '1' 1 | Should -BeTrue
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
        $script:warnings[0] | Should -BeLike "Could not restore $script:key\Locked : *"
    }
}

Describe 'Set-WmRegValue' {
    BeforeEach {
        $script:key = "HKEY_USERS\$($script:me.Value)\Software\wmanager-tests\$([guid]::NewGuid().ToString('N'))"
        $script:path = "Registry::$script:key"
        New-Item -Path $script:path -Force | Out-Null
        $script:WmJournalOn = $false
        $script:warnings = [System.Collections.ArrayList]@()
        $script:infos = [System.Collections.ArrayList]@()
        Mock Write-WmLog {
            $text = if ($Key) { Get-WmText -Key $Key -Arguments $Arguments -English } else { $Message }
            if ($Level -eq 'warn') { [void]$script:warnings.Add($text) } else { [void]$script:infos.Add($text) }
        }
    }
    AfterEach {
        Set-TestKeyReadOnly -Path $script:key -ReadOnly $false
        Remove-Item -LiteralPath $script:path -Recurse -Force -ErrorAction SilentlyContinue
    }
    AfterAll {
        Remove-Item -LiteralPath "Registry::HKEY_USERS\$($script:me.Value)\Software\wmanager-tests" -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'writes a new value and changes a different one' {
        Set-WmRegValue $script:path 'V' 1 | Should -BeTrue
        (Get-ItemProperty -LiteralPath $script:path).V | Should -Be 1
        Set-WmRegValue $script:path 'V' 2 | Should -BeTrue
        (Get-ItemProperty -LiteralPath $script:path).V | Should -Be 2
        Set-WmRegValue $script:path 'S' 'tekst' -Type String | Should -BeTrue
        (Get-ItemProperty -LiteralPath $script:path).S | Should -Be 'tekst'
    }

    It 'leaves a value that is already set alone, even in a key it may not write to' {
        New-ItemProperty -LiteralPath $script:path -Name 'Policy' -Value 0 -PropertyType DWord | Out-Null
        New-ItemProperty -LiteralPath $script:path -Name 'Text' -Value '%SystemRoot%\x' -PropertyType ExpandString | Out-Null
        Set-TestKeyReadOnly -Path $script:key -ReadOnly $true
        Set-WmRegValue $script:path 'Policy' 0 | Should -BeTrue
        Set-WmRegValue $script:path 'Text' '%SystemRoot%\x' -Type ExpandString | Should -BeTrue
        $script:warnings | Should -BeNullOrEmpty
    }

    It 'journals a value before the first change, also one that is already set' {
        $script:WmJournalFile = Join-Path $TestDrive 'journal.jsonl'
        $script:WmJournalSeen = @{}
        $script:WmJournalKeys = @{}
        $script:WmJournalOn = $true
        New-ItemProperty -LiteralPath $script:path -Name 'Same' -Value 0 -PropertyType DWord | Out-Null
        New-ItemProperty -LiteralPath $script:path -Name 'Changed' -Value 5 -PropertyType DWord | Out-Null
        Set-WmRegValue $script:path 'Same' 0 | Should -BeTrue
        Set-WmRegValue $script:path 'Changed' 1 | Should -BeTrue
        Set-WmRegValue $script:path 'New' 1 | Should -BeTrue
        $entries = @(Get-Content -LiteralPath $script:WmJournalFile | ForEach-Object { ConvertFrom-Json -InputObject $_ })
        $entries.Count | Should -Be 3
        ($entries | Where-Object Name -eq 'Same').Value | Should -Be '0'
        ($entries | Where-Object Name -eq 'Changed').Value | Should -Be '5'
        ($entries | Where-Object Name -eq 'New').Existed | Should -BeFalse
    }

    It 'writes again when only the kind differs' {
        New-ItemProperty -LiteralPath $script:path -Name 'V' -Value '1' -PropertyType String | Out-Null
        Set-WmRegValue $script:path 'V' 1 | Should -BeTrue
        (Get-Item -LiteralPath $script:path).GetValueKind('V') | Should -Be 'DWord'
    }

    It 'warns when a different value cannot be written, or logs it as info with -OnError info' {
        New-ItemProperty -LiteralPath $script:path -Name 'Policy' -Value 1 -PropertyType DWord | Out-Null
        Set-TestKeyReadOnly -Path $script:key -ReadOnly $true
        Set-WmRegValue $script:path 'Policy' 0 | Should -BeFalse
        $script:warnings.Count | Should -Be 1
        Set-WmRegValue $script:path 'Policy' 0 -OnError info | Should -BeFalse
        $script:warnings.Count | Should -Be 1
        $script:infos.Count | Should -Be 1
    }
}
