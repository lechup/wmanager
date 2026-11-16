# Tests for the management source checks (lib\Managed.ps1). To run (Pester 5):
#   Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser
#   Invoke-Pester .\tests

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $root 'lib\Common.ps1')
    . (Join-Path $root 'lib\Choco.ps1')
    . (Join-Path $root 'lib\Managed.ps1')
    Initialize-WmLanguage -Lang 'en'
    $hashA = 'A' * 64
    $sid = 'test-source-0001'
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
    It 'returns the source, the serial and upper-case hashes' {
        $m = ConvertFrom-WmManifestData @{ SourceId = $sid; Serial = 20261114120000; Files = @{ 'groups.psd1' = ('a' * 64) } } -SourceId $sid
        $m.SourceId | Should -Be $sid
        $m.Serial | Should -Be 20261114120000
        $m.Files['groups.psd1'] | Should -Be $hashA
    }

    It 'rejects a manifest of another source or without one' {
        { ConvertFrom-WmManifestData @{ SourceId = 'other-source-01'; Serial = 1; Files = @{} } -SourceId $sid } |
            Should -Throw "manifest belongs to another source (other-source-01), not to $sid from the configuration"
        { ConvertFrom-WmManifestData @{ Serial = 1; Files = @{} } } | Should -Throw
        { ConvertFrom-WmManifestData @{ SourceId = 'short'; Serial = 1; Files = @{} } } | Should -Throw
    }

    It 'rejects a missing or invalid serial' {
        { ConvertFrom-WmManifestData @{ SourceId = $sid; Files = @{} } } | Should -Throw
        { ConvertFrom-WmManifestData @{ SourceId = $sid; Serial = 'abc'; Files = @{} } } | Should -Throw
        { ConvertFrom-WmManifestData @{ SourceId = $sid; Serial = 0; Files = @{} } } | Should -Throw
    }

    It 'rejects bad paths, bad hashes and the manifest itself' {
        { ConvertFrom-WmManifestData @{ SourceId = $sid; Serial = 1; Files = @{ '../x' = $hashA } } } | Should -Throw
        { ConvertFrom-WmManifestData @{ SourceId = $sid; Serial = 1; Files = @{ 'x.txt' = 'abc' } } } | Should -Throw
        { ConvertFrom-WmManifestData @{ SourceId = $sid; Serial = 1; Files = @{ 'manifest.psd1' = $hashA } } } | Should -Throw
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
        { Assert-WmGroupMap @{ Computers = @('OFFICE-01') } } | Should -Throw "groups.psd1: Computers must be a table @{ 'NAME' = @('group') }"
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
        # the logged messages, in English
        Mock Write-WmLog { [void]$script:log.Add($(if ($Key) { Get-WmText -Key $Key -Arguments $Arguments -English } else { $Message })) }
        $common = ConvertFrom-WmRequirements -Text "vlc`n7zip@24.8.0"
        $acc    = ConvertFrom-WmRequirements -Text "7zip`nadobereader !noupdate"
        $other  = ConvertFrom-WmRequirements -Text "adobereader"
    }
    BeforeEach { $script:log = New-Object 'System.Collections.Generic.List[string]' }

    It 'lets a group entry replace the common one and adds new packages' {
        $r = Merge-WmRequirements -Lists @(
            @{ Label = 'common'; IsGroup = $false; Items = $common },
            @{ Label = 'accounting'; IsGroup = $true; Items = $acc })
        $r.Count | Should -Be 3
        ($r | Where-Object Name -eq '7zip').Pinned | Should -BeFalse
        ($r | Where-Object Name -eq 'adobereader').NoUpdate | Should -BeTrue
        $script:log | Should -Contain 'Package 7zip: the entry of group accounting replaces the entry of the common list.'
    }

    It 'warns when a later group differs from a group that repeated the common entry' {
        $same  = ConvertFrom-WmRequirements -Text '7zip@24.8.0'
        $other = ConvertFrom-WmRequirements -Text '7zip'
        $r = Merge-WmRequirements -Lists @(
            @{ Label = 'common'; IsGroup = $false; Items = $common },
            @{ Label = 'a'; IsGroup = $true; Items = $same },
            @{ Label = 'b'; IsGroup = $true; Items = $other })
        ($r | Where-Object Name -eq '7zip').Pinned | Should -BeTrue
        Should -Invoke Write-WmLog -ParameterFilter { $Level -eq 'warn' }
        $script:log | Should -Contain "Package 7zip is described differently in 'a' and 'b'; using the entry from 'a'."
    }

    It 'keeps the first group when two groups disagree' {
        $r = Merge-WmRequirements -Lists @(
            @{ Label = 'common'; IsGroup = $false; Items = @() },
            @{ Label = 'accounting'; IsGroup = $true; Items = $acc },
            @{ Label = 'other'; IsGroup = $true; Items = $other })
        ($r | Where-Object Name -eq 'adobereader').NoUpdate | Should -BeTrue
        Should -Invoke Write-WmLog -ParameterFilter { $Level -eq 'warn' }
        $script:log | Should -Contain "Package adobereader is described differently in 'accounting' and 'other'; using the entry from 'accounting'."
    }
}

Describe 'Get-WmRequirements without a management source' {
    It 'returns a flat list, not a list nested in an array' {
        Mock Get-WmRequirementsText { "vlc`n7zip" }
        $r = Get-WmRequirements -Config @{} -BaseDir 'C:\x'
        $r.Count | Should -Be 2
        $r[0].Name | Should -Be 'vlc'
        $r[0].Pinned | Should -BeFalse
    }
}

Describe 'Read-WmManagedSnapshot' {
    It 'reads the map and the lists as flat lists' {
        $dir = Join-Path $TestDrive 'managed'
        New-Item -ItemType Directory -Path (Join-Path $dir 'groups\acc') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'groups.psd1') -Value "@{ Default = @('acc') }" -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $dir 'choco-reqs.txt') -Value "vlc`r`n7zip" -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $dir 'groups\acc\choco-reqs.txt') -Value 'adobereader' -Encoding UTF8
        $manifest = [pscustomobject]@{ Files = @{ 'groups.psd1' = $hashA; 'choco-reqs.txt' = $hashA; 'groups/acc/choco-reqs.txt' = $hashA } }
        $snap = Read-WmManagedSnapshot -Dir $dir -Manifest $manifest
        $snap.Map.Default | Should -Be @('acc')
        $snap.Lists[''].Count | Should -Be 2
        $snap.Lists[''][1].Name | Should -Be '7zip'
        $snap.Lists['acc'][0].Name | Should -Be 'adobereader'
    }

    It 'rejects an invalid list' {
        $dir = Join-Path $TestDrive 'bad'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'choco-reqs.txt') -Value 'vlc !cos' -Encoding UTF8
        { Read-WmManagedSnapshot -Dir $dir -Manifest ([pscustomobject]@{ Files = @{ 'choco-reqs.txt' = $hashA } }) } | Should -Throw
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

Describe 'Get-WmGroupJobs' {
    It 'finds jobs by frequency folder and names them group/file' {
        $files = @{
            'groups/all/jobs/daily/system-report.ps1' = $hashA
            'groups/all/jobs/hourly/ping.ps1' = $hashA
            'groups/all/jobs/monthly/ignored.ps1' = $hashA
            'groups/all/scripts/10-x.ps1' = $hashA
        }
        $j = Get-WmGroupJobs -Files $files -Groups @('all')
        $j.Count | Should -Be 2
        ($j | Where-Object Every -eq 'daily').Name | Should -Be 'all/system-report'
        ($j | Where-Object Every -eq 'hourly').Path | Should -Be 'groups/all/jobs/hourly/ping.ps1'
    }
}

Describe 'Test-WmJobDue' {
    BeforeAll { $now = [datetime]'2026-11-14T12:00:00' }

    It 'runs a job that never ran' {
        Test-WmJobDue -Every 'daily' -LastRun $null -Now $now | Should -BeTrue
    }

    It 'keeps the period with a few minutes of slack' {
        Test-WmJobDue -Every 'daily' -LastRun $now.AddHours(-24).AddMinutes(2) -Now $now | Should -BeTrue
        Test-WmJobDue -Every 'daily' -LastRun $now.AddHours(-23) -Now $now | Should -BeFalse
        Test-WmJobDue -Every 'hourly' -LastRun $now.AddMinutes(-57) -Now $now | Should -BeTrue
        Test-WmJobDue -Every 'weekly' -LastRun $now.AddDays(-6) -Now $now | Should -BeFalse
    }

    It 'runs a job whose last run is in the future (clock went back)' {
        Test-WmJobDue -Every 'weekly' -LastRun $now.AddDays(2) -Now $now | Should -BeTrue
    }
}
