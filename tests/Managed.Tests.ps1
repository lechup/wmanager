# Tests for the management source checks (lib\Managed.ps1). To run (Pester 5):
#   Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser
#   Invoke-Pester .\tests

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $root 'lib\Common.ps1')
    . (Join-Path $root 'lib\Choco.ps1')
    . (Join-Path $root 'lib\Managed.ps1')
    $hashA = 'A' * 64
}

Describe 'Test-WmManagedPath' {
    It 'accepts relative paths with safe characters' {
        Test-WmManagedPath 'groups.psd1' | Should -BeTrue
        Test-WmManagedPath 'groups/accounting/scripts/10-power_plan.ps1' | Should -BeTrue
    }

    It 'rejects paths that could leave the folder or confuse Windows' {
        foreach ($p in @('', '../x', 'a/../b', './a', '/abs', 'C:/x', 'a\b', 'a//b', 'a b', 'dir./x', 'x.', 'nul', 'groups/CON.txt', 'com1.ps1')) {
            Test-WmManagedPath $p | Should -BeFalse -Because $p
        }
    }
}

Describe 'ConvertFrom-WmManifestData' {
    It 'returns the serial and upper-case hashes' {
        $m = ConvertFrom-WmManifestData @{ Serial = 20261114120000; Files = @{ 'groups.psd1' = ('a' * 64) } }
        $m.Serial | Should -Be 20261114120000
        $m.Files['groups.psd1'] | Should -Be $hashA
    }

    It 'rejects a missing or invalid serial' {
        { ConvertFrom-WmManifestData @{ Files = @{} } } | Should -Throw
        { ConvertFrom-WmManifestData @{ Serial = 'abc'; Files = @{} } } | Should -Throw
        { ConvertFrom-WmManifestData @{ Serial = 0; Files = @{} } } | Should -Throw
    }

    It 'rejects bad paths, bad hashes and the manifest itself' {
        { ConvertFrom-WmManifestData @{ Serial = 1; Files = @{ '../x' = $hashA } } } | Should -Throw
        { ConvertFrom-WmManifestData @{ Serial = 1; Files = @{ 'x.txt' = 'abc' } } } | Should -Throw
        { ConvertFrom-WmManifestData @{ Serial = 1; Files = @{ 'manifest.psd1' = $hashA } } } | Should -Throw
    }
}

Describe 'Assert-WmGroupMap' {
    It 'accepts a valid map' {
        { Assert-WmGroupMap @{ Default = @('all'); Computers = @{ 'OFFICE-01' = @('accounting', 'floor-1') } } } | Should -Not -Throw
        { Assert-WmGroupMap @{} } | Should -Not -Throw
    }

    It 'rejects unknown keys and bad group names' {
        { Assert-WmGroupMap @{ Computer = @{} } } | Should -Throw
        { Assert-WmGroupMap @{ Computers = @{ 'OFFICE-01' = @('../x') } } } | Should -Throw
        { Assert-WmGroupMap @{ Default = @('a b') } } | Should -Throw
        { Assert-WmGroupMap @{ Computers = @('OFFICE-01') } } | Should -Throw
    }
}

Describe 'Get-WmComputerGroups' {
    BeforeAll {
        $map = @{ Default = @('all'); Computers = @{ 'OFFICE-01' = @('accounting', 'ALL') } }
    }

    It 'puts the default groups first and matches the name without regard to case' {
        $g = Get-WmComputerGroups -Map $map -ComputerName 'office-01'
        $g | Should -Be @('all', 'accounting')
    }

    It 'gives an unknown computer only the default groups' {
        Get-WmComputerGroups -Map $map -ComputerName 'OFFICE-99' | Should -Be @('all')
    }

    It 'returns an empty list without groups' {
        (Get-WmComputerGroups -Map @{} -ComputerName 'X').Count | Should -Be 0
    }
}

Describe 'Merge-WmRequirements' {
    BeforeAll {
        Mock Write-WmLog { }
        $common = ConvertFrom-WmRequirements -Text "vlc`n7zip@24.8.0"
        $acc    = ConvertFrom-WmRequirements -Text "7zip`nadobereader !noupdate"
        $other  = ConvertFrom-WmRequirements -Text "adobereader"
    }

    It 'lets a group entry replace the common one and adds new packages' {
        $r = Merge-WmRequirements -Lists @(
            @{ Label = 'common'; IsGroup = $false; Items = $common },
            @{ Label = 'accounting'; IsGroup = $true; Items = $acc })
        $r.Count | Should -Be 3
        ($r | Where-Object Name -eq '7zip').Pinned | Should -BeFalse
        ($r | Where-Object Name -eq 'adobereader').NoUpdate | Should -BeTrue
    }

    It 'keeps the first group when two groups disagree' {
        $r = Merge-WmRequirements -Lists @(
            @{ Label = 'common'; IsGroup = $false; Items = @() },
            @{ Label = 'accounting'; IsGroup = $true; Items = $acc },
            @{ Label = 'other'; IsGroup = $true; Items = $other })
        ($r | Where-Object Name -eq 'adobereader').NoUpdate | Should -BeTrue
        Should -Invoke Write-WmLog -ParameterFilter { $Level -eq 'warn' }
    }
}

Describe 'Get-WmGroupScripts' {
    It 'lists scripts of the given groups in group order, then by name' {
        $files = @{
            'groups/b/scripts/20-x.ps1' = $hashA
            'groups/b/scripts/10-y.ps1' = $hashA
            'groups/a/scripts/10-z.ps1' = $hashA
            'groups/a/scripts/sub/30-no.ps1' = $hashA
            'groups/a/scripts/readme.txt' = $hashA
            'groups/c/scripts/10-other.ps1' = $hashA
        }
        $s = Get-WmGroupScripts -Files $files -Groups @('b', 'a')
        @($s | ForEach-Object Path) | Should -Be @('groups/b/scripts/10-y.ps1', 'groups/b/scripts/20-x.ps1', 'groups/a/scripts/10-z.ps1')
        $s[0].Group | Should -Be 'b'
    }

    It 'returns nothing without groups' {
        (Get-WmGroupScripts -Files @{ 'groups/a/scripts/1.ps1' = $hashA } -Groups @()).Count | Should -Be 0
    }
}
