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

Describe 'ConvertFrom-WmVersionData and Get-WmWantedVersion' {
    BeforeAll {
        $e = @{ Version = 'v0.2.0'; Url = 'https://example.com/wmanager-v0.2.0.zip'; Sha256 = ('a' * 64) }
    }

    It 'reads the version for every computer and for groups' {
        $v = ConvertFrom-WmVersionData @{ Version = 'v0.2.0'; Url = $e.Url; Sha256 = $e.Sha256
                                          Groups = @{ test = @{ Version = 'v0.3.0-rc1'; Url = '\\srv\share\wmanager-v0.3.0-rc1.zip'; Sha256 = ('b' * 64) } } }
        $v.Default.Version | Should -Be 'v0.2.0'
        $v.Default.Sha256 | Should -Be ('A' * 64)
        $v.Groups['TEST'].Url | Should -Be '\\srv\share\wmanager-v0.3.0-rc1.zip'
        (ConvertFrom-WmVersionData @{ Groups = @{ test = $e } }).Default | Should -BeNullOrEmpty
        (ConvertFrom-WmVersionData @{ Version = 'v1.0.0'; Url = 'C:\rel\wmanager-v1.0.0.zip'; Sha256 = $e.Sha256 }).Default.Url | Should -Be 'C:\rel\wmanager-v1.0.0.zip'
    }

    It 'rejects what a computer could not use' {
        { ConvertFrom-WmVersionData @{ Version = 'v0.2.0' } } | Should -Throw 'version.psd1: Url is missing*'
        { ConvertFrom-WmVersionData @{ Version = '0.2.0'; Url = $e.Url; Sha256 = $e.Sha256 } } | Should -Throw '*Version is not a wmanager release*'
        { ConvertFrom-WmVersionData @{ Version = 'v0.2.0'; Url = 'http://example.com/x.zip'; Sha256 = $e.Sha256 } } | Should -Throw '*Url must be an https:// address*'
        { ConvertFrom-WmVersionData @{ Version = 'v0.2.0'; Url = 'wmanager.zip'; Sha256 = $e.Sha256 } } | Should -Throw '*Url must be*'
        { ConvertFrom-WmVersionData @{ Version = 'v0.2.0'; Url = $e.Url; Sha256 = 'abc' } } | Should -Throw '*Sha256 is not a SHA256*'
        { ConvertFrom-WmVersionData @{ Versoin = 'v0.2.0' } } | Should -Throw "*unknown key 'Versoin'*"
        { ConvertFrom-WmVersionData @{ Groups = @{ test = @{ Version = 'v0.2.0'; Url = $e.Url } } } } | Should -Throw '*Groups.test.Sha256 is missing*'
        { ConvertFrom-WmVersionData @{ Groups = @{ '../x' = $e } } } | Should -Throw '*invalid group name*'
        { ConvertFrom-WmVersionData @{ Groups = @('test') } } | Should -Throw '*Groups must*'
    }

    It 'gives a computer the version of its first group that has one, otherwise the default' {
        $v = ConvertFrom-WmVersionData @{ Version = 'v0.2.0'; Url = $e.Url; Sha256 = $e.Sha256
                                          Groups = @{ test  = @{ Version = 'v0.3.0'; Url = $e.Url; Sha256 = $e.Sha256 }
                                                      pilot = @{ Version = 'v0.4.0'; Url = $e.Url; Sha256 = $e.Sha256 } } }
        $w = Get-WmWantedVersion -Versions $v -Groups @('all', 'accounting')
        $w.Version | Should -Be 'v0.2.0'
        $w.Group | Should -Be ''
        $w = Get-WmWantedVersion -Versions $v -Groups @('all', 'PILOT', 'test')
        $w.Version | Should -Be 'v0.4.0'
        $w.Group | Should -Be 'PILOT'
        Get-WmWantedVersion -Versions $null -Groups @('all') | Should -BeNullOrEmpty
        Get-WmWantedVersion -Versions (ConvertFrom-WmVersionData @{ Groups = @{ test = $e } }) -Groups @('all') | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-WmComputerContent' {
    It 'names the wmanager version, and a group that exists only for its version is no warning' {
        $script:WmLogBuffer.Clear()
        $v = ConvertFrom-WmVersionData @{ Groups = @{ pilot = @{ Version = 'v0.3.0'; Url = 'C:\rel\w.zip'; Sha256 = ('d' * 64) } } }
        $c = Resolve-WmComputerContent -Map @{ Computers = @{ 'PC-1' = @('pilot', 'ghost') } } -Lists @{ '' = @() } `
                                       -Files @{ 'choco-reqs.txt' = $hashA } -ComputerName 'pc-1' -Versions $v
        $c.Wmanager.Version | Should -Be 'v0.3.0'
        $c.Wmanager.Group | Should -Be 'pilot'
        $warn = @($script:WmLogBuffer | Where-Object { $_.Level -eq 'warn' } | ForEach-Object { $_.Line }) -join "`n"
        $warn | Should -Match 'Group ghost has no files'
        $warn | Should -Not -Match 'Group pilot'
    }

    It 'lets a computer''s own group win over a default group for the version' {
        $v = ConvertFrom-WmVersionData @{ Groups = @{ all   = @{ Version = 'v0.2.0'; Url = 'C:\rel\a.zip'; Sha256 = ('d' * 64) }
                                                      pilot = @{ Version = 'v0.3.0'; Url = 'C:\rel\b.zip'; Sha256 = ('e' * 64) } } }
        $map = @{ Default = @('all'); Computers = @{ 'PC-1' = @('pilot'); 'PC-2' = @('accounting') } }
        $files = @{ 'groups/all/x.txt' = $hashA; 'groups/pilot/x.txt' = $hashA; 'groups/accounting/x.txt' = $hashA }
        (Resolve-WmComputerContent -Map $map -Lists @{ '' = @() } -Files $files -ComputerName 'PC-1' -Versions $v).Wmanager.Version | Should -Be 'v0.3.0'
        (Resolve-WmComputerContent -Map $map -Lists @{ '' = @() } -Files $files -ComputerName 'PC-2' -Versions $v).Wmanager.Version | Should -Be 'v0.2.0'
        $order = Get-WmVersionGroupOrder -Map $map -Groups @('all', 'pilot', 'floor-1')   # one array, not its items
        $order | Should -Be @('pilot', 'floor-1', 'all')
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

Describe 'Test-WmManagementConfig and Write-WmCertificateExpiry' {
    BeforeAll {
        $cfg = @{ Management = @{ Source = 'https://example.test/acme'; SourceId = $sid; Certificate = 'wmanager-signing.cer' } }
        function New-FakeCert { param([int]$Days) [pscustomobject]@{ Subject = 'CN=t'; Thumbprint = 'AB12'; NotAfter = (Get-Date).AddDays($Days) } }
    }
    It 'names the source before provisioning starts, but leaves the expiry to the run (the log file is not open yet)' {
        Mock Get-WmSigningCertificate { New-FakeCert 10 }
        Mock Write-WmLog { }
        Test-WmManagementConfig -Config $cfg -ConfigDir 'C:\cfg'
        Should -Invoke Write-WmLog -Times 1 -Exactly -ParameterFilter { $Key -eq 'managed.source_info' }
        Should -Invoke Write-WmLog -Times 0 -Exactly -ParameterFilter { $Key -like 'managed.cert_exp*' }
    }
    It 'warns of a certificate that expires within 60 days, and of one that expired' {
        Mock Write-WmLog { }
        Write-WmCertificateExpiry (New-FakeCert 10)
        Should -Invoke Write-WmLog -Times 1 -Exactly -ParameterFilter { $Key -eq 'managed.cert_expiring' -and $Level -eq 'warn' }
        Write-WmCertificateExpiry (New-FakeCert -1)
        Should -Invoke Write-WmLog -Times 1 -Exactly -ParameterFilter { $Key -eq 'managed.cert_expired' -and $Level -eq 'warn' }
        Write-WmCertificateExpiry (New-FakeCert 400)
        Should -Invoke Write-WmLog -Times 2 -Exactly
    }
}

Describe 'Add-WmScriptSecrets' {
    BeforeAll {
        $file = Join-Path $TestDrive 'share.ps1'
        $secrets = @{ ShareUser = 'office'; SharePassword = 'p4ss'; Other = 'x' }
    }
    It 'gives a script only the secrets it names, as WMANAGER_SECRET_ and the name in capitals' {
        [IO.File]::WriteAllText($file, "# wmanager-secrets: shareuser, SharePassword`r`nWrite-Output 1`r`n")
        $vars = @{ WMANAGER_GROUP = 'all' }
        Add-WmScriptSecrets -Environment $vars -Secrets $secrets -File $file
        $vars['WMANAGER_SECRET_SHAREUSER'] | Should -BeExactly 'office'
        $vars['WMANAGER_SECRET_SHAREPASSWORD'] | Should -BeExactly 'p4ss'
        $vars.Count | Should -Be 3
    }
    It 'adds nothing for a script that names none' {
        [IO.File]::WriteAllText($file, "Write-Output 1`r`n")
        $vars = @{}
        Add-WmScriptSecrets -Environment $vars -Secrets $secrets -File $file
        $vars.Count | Should -Be 0
    }
    It 'refuses a script whose secret the configuration lacks, or with a name that is not one' {
        [IO.File]::WriteAllText($file, "# wmanager-secrets: ShareUser, Missing`r`n")
        { Add-WmScriptSecrets -Environment @{} -Secrets $secrets -File $file } | Should -Throw '*has no secret Missing*'
        [IO.File]::WriteAllText($file, "# wmanager-secrets: 1st`r`n")
        { Add-WmScriptSecrets -Environment @{} -Secrets $secrets -File $file } | Should -Throw "*'1st' is not a secret's name*"
    }
}

Describe 'Test-WmManagementConfig and the secrets' {
    It 'stops provisioning on Secrets the computers could not use' {
        Mock Get-WmSigningCertificate { [pscustomobject]@{ Subject = 'CN=t'; Thumbprint = 'AB12'; NotAfter = (Get-Date).AddDays(400) } }
        Mock Write-WmLog { }
        $cfg = @{ Management = @{ Source = 'https://example.test/acme'; SourceId = $sid }; Secrets = @{ A = '' } }
        { Test-WmManagementConfig -Config $cfg -ConfigDir 'C:\cfg' } | Should -Throw '*value of A*'
        $cfg.Secrets = @{ A = 'x' }
        { Test-WmManagementConfig -Config $cfg -ConfigDir 'C:\cfg' } | Should -Not -Throw
    }
}

Describe 'Invoke-WmLogonScripts' {
    BeforeAll {
        # lib\UserSession.ps1 (Windows API, SYSTEM) is replaced by mocks; these stand in so they can be mocked
        function Get-WmUserSessions { }
        function Invoke-WmUserScript { param([int]$SessionId, [string]$File, [hashtable]$Environment, [int]$TimeoutMinutes) }
        function Start-WmJobsTask { }
        $script:WmManagedDir = Join-Path $TestDrive 'managed'
        $script:WmLogonDir = Join-Path $TestDrive 'logon'
        $script:WmLogonServed = Join-Path $TestDrive 'logon-served.txt'
        $cfg = @{ Management = @{ Source = 'https://example.test/acme'; SourceId = $sid }; Secrets = @{ ShareUser = 'office'; SharePassword = 'p4ss-W0rd' } }

        # A sign-in script in the verified copy, as the manifest lists it
        function Add-LogonScript {
            param([string]$Rel, [string]$Text)
            $file = Join-Path $script:WmManagedDir ($Rel -replace '/', '\')
            New-Item -ItemType Directory -Force -Path (Split-Path $file -Parent) | Out-Null
            [IO.File]::WriteAllText($file, $Text)
            $parts = $Rel.Split('/')
            return [pscustomobject]@{ Group = $parts[1]; Path = $Rel; Hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
                                      Name = $parts[1] + '/' + [IO.Path]::GetFileNameWithoutExtension($parts[3]) }
        }
        function New-Session { param([int]$Id, [string]$LogonId) [pscustomobject]@{ SessionId = $Id; User = "user$Id"; Domain = 'PC'; LogonId = $LogonId } }
    }
    BeforeEach {
        Remove-Item -LiteralPath $script:WmLogonServed, $script:WmLogonDir, $script:WmManagedDir -Recurse -Force -ErrorAction SilentlyContinue
        Mock Write-WmLog { }
    }

    It 'runs them once per sign-in, in the user''s session, with only the secrets each names, and hides those in the log' {
        $drive = Add-LogonScript 'groups/all/logon/10-drive.ps1' "# wmanager-secrets: ShareUser, SharePassword`r`nexit 0`r`n"
        $hello = Add-LogonScript 'groups/all/logon/20-hello.ps1' "exit 0`r`n"
        Mock Get-WmLogonContent { [pscustomobject]@{ Scripts = @($drive, $hello); UserRuns = $false } }
        Mock Get-WmUserSessions { @(New-Session 1 '00000000000A1B2C') }
        Mock Invoke-WmUserScript { [pscustomobject]@{ ExitCode = 0; Output = 'mapped as office with p4ss-W0rd'; Errors = '' } }
        Invoke-WmLogonScripts -Config $cfg
        Should -Invoke Invoke-WmUserScript -Times 2 -Exactly
        Should -Invoke Invoke-WmUserScript -Times 1 -Exactly -ParameterFilter {
            $SessionId -eq 1 -and $File -like '*all-logon-10-drive.ps1' -and $Environment['WMANAGER_SECRET_SHAREPASSWORD'] -eq 'p4ss-W0rd' -and
            $Environment['WMANAGER_SECRET_SHAREUSER'] -eq 'office' -and $Environment['WMANAGER_GROUP'] -eq 'all' -and $TimeoutMinutes -eq 5 }
        Should -Invoke Invoke-WmUserScript -Times 1 -Exactly -ParameterFilter { $File -like '*all-logon-20-hello.ps1' -and $Environment.Count -eq 2 }
        Should -Invoke Write-WmLog -Times 2 -Exactly -ParameterFilter { $Message -match 'mapped as \*\*\* with \*\*\*' }
        Should -Invoke Write-WmLog -Times 0 -ParameterFilter { "$Message" -match 'p4ss|office' }
        Should -Invoke Write-WmLog -Times 2 -Exactly -ParameterFilter { $Key -eq 'logon.script_done' }
        # What the users' processes read: the verified file, in the folder only administrators change
        [IO.File]::ReadAllText((Join-Path $script:WmLogonDir 'all-logon-20-hello.ps1')) | Should -Be "exit 0`r`n"

        # The same sign-in again: nothing more
        Invoke-WmLogonScripts -Config $cfg
        Should -Invoke Invoke-WmUserScript -Times 2 -Exactly
    }

    It 'serves a new sign-in alongside one already served, and forgets the ones that ended' {
        $hello = Add-LogonScript 'groups/all/logon/20-hello.ps1' "exit 0`r`n"
        Mock Get-WmLogonContent { [pscustomobject]@{ Scripts = @($hello); UserRuns = $false } }
        Mock Invoke-WmUserScript { [pscustomobject]@{ ExitCode = 0; Output = ''; Errors = '' } }
        Mock Get-WmUserSessions { @(New-Session 1 'AAAA') }
        Invoke-WmLogonScripts -Config $cfg
        Mock Get-WmUserSessions { @((New-Session 1 'AAAA'), (New-Session 2 'BBBB')) }
        Invoke-WmLogonScripts -Config $cfg
        Should -Invoke Invoke-WmUserScript -Times 1 -Exactly -ParameterFilter { $SessionId -eq 2 }
        Should -Invoke Invoke-WmUserScript -Times 2 -Exactly
        Mock Get-WmUserSessions { @(New-Session 2 'BBBB') }
        Invoke-WmLogonScripts -Config $cfg
        @((Read-WmTabState $script:WmLogonServed).Keys) | Should -Be @('BBBB')
        # Signed in again in session 1: a new sign-in, so they run again
        Mock Get-WmUserSessions { @((New-Session 1 'CCCC'), (New-Session 2 'BBBB')) }
        Invoke-WmLogonScripts -Config $cfg
        Should -Invoke Invoke-WmUserScript -Times 3 -Exactly
    }

    It 'skips a script whose secret is missing or whose file is not the verified one, and logs exit codes and time limits' {
        $missing = Add-LogonScript 'groups/all/logon/30-missing.ps1' "# wmanager-secrets: Nope`r`nexit 0`r`n"
        $changed = Add-LogonScript 'groups/all/logon/40-changed.ps1' "exit 0`r`n"
        [IO.File]::WriteAllText((Join-Path $script:WmManagedDir 'groups\all\logon\40-changed.ps1'), "exit 5`r`n")
        $fails = Add-LogonScript 'groups/all/logon/50-fails.ps1' "exit 3`r`n"
        $hangs = Add-LogonScript 'groups/all/logon/60-hangs.ps1' "Start-Sleep 600`r`n"
        Mock Get-WmLogonContent { [pscustomobject]@{ Scripts = @($missing, $changed, $fails, $hangs); UserRuns = $false } }
        Mock Get-WmUserSessions { @(New-Session 1 'AAAA') }
        Mock Invoke-WmUserScript {
            if ($File -like '*50-fails.ps1') { [pscustomobject]@{ ExitCode = 3; Output = ''; Errors = 'boom' } }
            else { [pscustomobject]@{ ExitCode = $null; Output = ''; Errors = '' } }
        }
        Invoke-WmLogonScripts -Config $cfg
        Should -Invoke Invoke-WmUserScript -Times 2 -Exactly
        Should -Invoke Write-WmLog -Times 1 -Exactly -ParameterFilter { $Key -eq 'logon.script_not_run' -and $Arguments[0] -eq 'all/30-missing' }
        Should -Invoke Write-WmLog -Times 1 -Exactly -ParameterFilter { $Key -eq 'logon.script_not_run' -and $Arguments[0] -eq 'all/40-changed' }
        Should -Invoke Write-WmLog -Times 1 -Exactly -ParameterFilter { $Key -eq 'logon.script_exit_code' -and $Arguments[1] -eq 3 -and $Level -eq 'error' }
        Should -Invoke Write-WmLog -Times 1 -Exactly -ParameterFilter { $Key -eq 'logon.script_timeout' -and $Arguments[0] -eq 'all/60-hangs' }
        Test-Path -LiteralPath (Join-Path $script:WmLogonDir 'all-logon-40-changed.ps1') | Should -BeFalse
    }

    It 'starts wmanager-Jobs after a sign-in when scripts or jobs run as the user, also without sign-in scripts' {
        Mock Get-WmLogonContent { [pscustomobject]@{ Scripts = @(); UserRuns = $true } }
        Mock Get-WmUserSessions { @(New-Session 1 'AAAA') }
        Mock Start-WmJobsTask { }
        Invoke-WmLogonScripts -Config $cfg
        Should -Invoke Start-WmJobsTask -Times 1 -Exactly
        Invoke-WmLogonScripts -Config $cfg   # the same sign-in: no
        Should -Invoke Start-WmJobsTask -Times 1 -Exactly
    }

    It 'reads the sign-in scripts of the computer''s groups from the verified copy, and whether anything runs as the user' {
        $a = Add-LogonScript 'groups/all/logon/10-a.ps1' "exit 0`r`n"
        $b = Add-LogonScript 'groups/all/logon/20-b.ps1' "exit 0`r`n"
        $other = Add-LogonScript 'groups/other/logon/10-c.ps1' "exit 0`r`n"
        $plain = Add-LogonScript 'groups/all/scripts/10-plain.ps1' "exit 0`r`n"
        $files = @{ 'groups.psd1' = 'X'; 'groups/all/logon/10-a.ps1' = $a.Hash; 'groups/all/logon/20-b.ps1' = $b.Hash
                    'groups/other/logon/10-c.ps1' = $other.Hash; 'groups/all/scripts/10-plain.ps1' = $plain.Hash }
        Mock Get-WmSigningCertificate { [pscustomobject]@{ Thumbprint = 'AB' } }
        Mock Get-WmNextCertificate { $null }
        Mock Get-WmManagedManifest { [pscustomobject]@{ Files = $files } }
        Mock Read-WmManagedSnapshot { [pscustomobject]@{ Map = @{ Default = @('all') } } }
        $savedHost = $script:WmHostName
        $script:WmHostName = 'OFFICE-01'
        try {
        $c = Get-WmLogonContent $cfg
        @($c.Scripts | ForEach-Object Path) | Should -Be @('groups/all/logon/10-a.ps1', 'groups/all/logon/20-b.ps1')
        $c.UserRuns | Should -BeFalse
        [IO.File]::WriteAllText((Join-Path $script:WmManagedDir 'groups\all\scripts\10-plain.ps1'), "# wmanager-run-as: user`r`nexit 0`r`n")
        (Get-WmLogonContent $cfg).UserRuns | Should -BeTrue
        } finally { $script:WmHostName = $savedHost }
    }

    It 'does nothing without a new sign-in or without sign-in scripts' {
        Mock Get-WmLogonContent { [pscustomobject]@{ Scripts = @(); UserRuns = $false } }
        Mock Get-WmUserSessions { @(New-Session 1 'AAAA') }
        Mock Invoke-WmUserScript { }
        Invoke-WmLogonScripts -Config $cfg
        Mock Get-WmUserSessions { @() }
        Invoke-WmLogonScripts -Config $cfg
        Should -Invoke Invoke-WmUserScript -Times 0
        Should -Invoke Write-WmLog -Times 0
    }
}

Describe 'Invoke-WmStartupScripts' {
    BeforeAll {
        $script:WmManagedDir = Join-Path $TestDrive 'managed-startup'
        $script:WmStartupDir = Join-Path $TestDrive 'startup'
        $script:WmStartupServed = Join-Path $TestDrive 'startup-served.txt'
        $script:WmHostName = 'PC-1'
        $cfg = @{ Management = @{ Source = 'https://example.test/acme'; SourceId = $sid; ScriptTimeoutMinutes = 7 }
                  Secrets = @{ ShareUser = 'office'; SharePassword = 'p4ss-W0rd' } }

        # Startup scripts in the verified copy, as its manifest lists them (path -> SHA256)
        function Set-StartupFiles {
            param([hashtable]$Scripts)
            $script:startupFiles = @{}
            foreach ($rel in $Scripts.Keys) {
                $file = Join-Path $script:WmManagedDir ($rel -replace '/', '\')
                New-Item -ItemType Directory -Force -Path (Split-Path $file -Parent) | Out-Null
                [IO.File]::WriteAllText($file, $Scripts[$rel])
                $script:startupFiles[$rel] = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
            }
        }
    }
    BeforeEach {
        Remove-Item -LiteralPath $script:WmStartupDir, $script:WmManagedDir, $script:WmStartupServed -Recurse -Force -ErrorAction SilentlyContinue
        Mock Write-WmLog { }
        Mock Get-WmBootMark { '' }
        Mock Get-WmVerifiedGroups { [pscustomobject]@{ Files = $script:startupFiles; Groups = @('all', 'office'); Settings = $cfg.Management } }
        Mock Invoke-WmScriptProcess { [pscustomobject]@{ ExitCode = 0; Output = 'mapped as office with p4ss-W0rd'; Errors = '' } }
    }

    It 'runs them group by group and by name, with only the secrets each names, hidden in the log' {
        Set-StartupFiles @{
            'groups/office/startup/10-share.ps1' = "# wmanager-secrets: ShareUser, SharePassword`r`nexit 0`r`n"
            'groups/all/startup/20-clean.ps1'    = "exit 0`r`n"
            'groups/all/startup/10-first.ps1'    = "exit 0`r`n"
            'groups/all/startup/sub/10-deep.ps1' = "exit 0`r`n"
            'groups/other/startup/10-not.ps1'    = "exit 0`r`n"
        }
        $script:order = New-Object System.Collections.Generic.List[string]
        Mock Invoke-WmScriptProcess { [void]$script:order.Add((Split-Path $File -Leaf)); [pscustomobject]@{ ExitCode = 0; Output = 'mapped as office with p4ss-W0rd'; Errors = '' } }
        Invoke-WmStartupScripts -Config $cfg
        $script:order | Should -Be @('all-startup-10-first.ps1', 'all-startup-20-clean.ps1', 'office-startup-10-share.ps1')
        Should -Invoke Invoke-WmScriptProcess -Times 1 -Exactly -ParameterFilter {
            $File -like '*office-startup-10-share.ps1' -and $Environment['WMANAGER_SECRET_SHAREPASSWORD'] -eq 'p4ss-W0rd' -and
            $Environment['WMANAGER_GROUP'] -eq 'office' -and $Environment['WMANAGER_COMPUTER'] -eq 'PC-1' -and $TimeoutMinutes -eq 7 }
        Should -Invoke Invoke-WmScriptProcess -Times 1 -Exactly -ParameterFilter { $File -like '*all-startup-20-clean.ps1' -and $Environment.Count -eq 2 }
        Should -Invoke Write-WmLog -Times 0 -ParameterFilter { "$Message" -match 'p4ss|office with' }
        Should -Invoke Write-WmLog -Times 3 -Exactly -ParameterFilter { $Key -eq 'startup.script_done' }
        Should -Invoke Write-WmLog -Times 1 -Exactly -ParameterFilter { $Key -eq 'startup.scripts' -and $Arguments[0] -eq 3 }
    }

    It 'skips a script whose secret is missing or whose file is not the verified one, and logs exit codes and time limits' {
        Set-StartupFiles @{
            'groups/all/startup/10-missing.ps1' = "# wmanager-secrets: Nope`r`nexit 0`r`n"
            'groups/all/startup/20-changed.ps1' = "exit 0`r`n"
            'groups/all/startup/30-fails.ps1'   = "exit 3`r`n"
            'groups/all/startup/40-hangs.ps1'   = "Start-Sleep 600`r`n"
        }
        [IO.File]::WriteAllText((Join-Path $script:WmManagedDir 'groups\all\startup\20-changed.ps1'), "exit 5`r`n")
        Mock Invoke-WmScriptProcess {
            if ($File -like '*30-fails.ps1') { [pscustomobject]@{ ExitCode = 3; Output = ''; Errors = 'boom' } }
            else { [pscustomobject]@{ ExitCode = $null; Output = ''; Errors = '' } }
        }
        Invoke-WmStartupScripts -Config $cfg
        Should -Invoke Invoke-WmScriptProcess -Times 2 -Exactly
        Should -Invoke Write-WmLog -Times 1 -Exactly -ParameterFilter { $Key -eq 'startup.script_not_run' -and $Arguments[0] -eq 'all/10-missing' }
        Should -Invoke Write-WmLog -Times 1 -Exactly -ParameterFilter { $Key -eq 'startup.script_not_run' -and $Arguments[0] -eq 'all/20-changed' }
        Should -Invoke Write-WmLog -Times 1 -Exactly -ParameterFilter { $Key -eq 'startup.script_exit_code' -and $Arguments[1] -eq 3 }
        Should -Invoke Write-WmLog -Times 1 -Exactly -ParameterFilter { $Key -eq 'startup.script_timeout' -and $Arguments[1] -eq 7 }
    }

    It 'says so without a verified copy, after waiting for one, and drops the copies of scripts gone from the source' {
        Mock Get-WmVerifiedGroups { $null }
        Invoke-WmStartupScripts -Config $cfg -CopyWaitSeconds 0
        Should -Invoke Invoke-WmScriptProcess -Times 0
        Should -Invoke Write-WmLog -Times 1 -Exactly -ParameterFilter { $Key -eq 'startup.no_copy' -and $Level -eq 'warn' }

        Set-StartupFiles @{ 'groups/all/startup/10-first.ps1' = "exit 0`r`n" }
        Mock Get-WmVerifiedGroups { [pscustomobject]@{ Files = $script:startupFiles; Groups = @('all'); Settings = $cfg.Management } }
        Invoke-WmStartupScripts -Config $cfg
        Test-Path -LiteralPath (Join-Path $script:WmStartupDir 'all-startup-10-first.ps1') | Should -BeTrue
        $script:startupFiles = @{}
        Invoke-WmStartupScripts -Config $cfg
        @(Get-ChildItem -LiteralPath $script:WmStartupDir -File).Count | Should -Be 0
        Should -Invoke Write-WmLog -Times 1 -Exactly -ParameterFilter { $Key -eq 'startup.scripts' }
    }

    It 'serves a start once, whichever of its two triggers comes second' {
        Set-StartupFiles @{ 'groups/all/startup/10-first.ps1' = "exit 0`r`n" }
        Mock Get-WmBootMark { '4711' }
        Invoke-WmStartupScripts -Config $cfg
        Invoke-WmStartupScripts -Config $cfg
        Should -Invoke Invoke-WmScriptProcess -Times 1 -Exactly
        Mock Get-WmBootMark { '4800' }
        Invoke-WmStartupScripts -Config $cfg
        Should -Invoke Invoke-WmScriptProcess -Times 2 -Exactly
    }

    It 'takes 3010 as done, and goes on after a script that can''t start' {
        Set-StartupFiles @{
            'groups/all/startup/10-restart.ps1' = "exit 3010`r`n"
            'groups/all/startup/20-blocked.ps1' = "exit 0`r`n"
            'groups/all/startup/30-after.ps1'   = "exit 0`r`n"
        }
        Mock Invoke-WmScriptProcess {
            if ($File -like '*10-restart.ps1') { return [pscustomobject]@{ ExitCode = 3010; Output = ''; Errors = '' } }
            if ($File -like '*20-blocked.ps1') { throw 'Access is denied' }
            [pscustomobject]@{ ExitCode = 0; Output = ''; Errors = '' }
        }
        Invoke-WmStartupScripts -Config $cfg
        Should -Invoke Write-WmLog -Times 1 -Exactly -ParameterFilter { $Key -eq 'startup.script_restart' -and $Arguments[0] -eq 'all/10-restart' }
        Should -Invoke Write-WmLog -Times 1 -Exactly -ParameterFilter { $Key -eq 'startup.script_not_run' -and $Arguments[0] -eq 'all/20-blocked' -and $Level -eq 'error' }
        Should -Invoke Write-WmLog -Times 1 -Exactly -ParameterFilter { $Key -eq 'startup.script_done' -and $Arguments[0] -eq 'all/30-after' }
        Should -Invoke Write-WmLog -Times 0 -ParameterFilter { $Key -eq 'startup.script_exit_code' }
    }
}

Describe 'scripts and jobs that run as the user' {
    BeforeAll {
        function Get-WmUserSessions { }
        function Invoke-WmUserScript { param([int]$SessionId, [string]$File, [hashtable]$Environment, [int]$TimeoutMinutes) }
        $script:WmManagedDir = Join-Path $TestDrive 'managed'
        $script:WmUserRunDir = Join-Path $TestDrive 'user-run'
        $script:WmScriptsState = Join-Path $TestDrive 'scripts-done.txt'
        $script:WmScriptsFailed = Join-Path $TestDrive 'scripts-failed.txt'
        $script:WmJobsState = Join-Path $TestDrive 'jobs-state.txt'
        $cfg = @{ Management = @{ Source = 'https://example.test/acme'; SourceId = $sid }; Secrets = @{ Pw = 's3cret-Value' } }

        # A script or job in the verified copy, as the content lists it
        function Add-Item {
            param([string]$Rel, [string]$Text, [string]$Every)
            $file = Join-Path $script:WmManagedDir ($Rel -replace '/', '\')
            New-Item -ItemType Directory -Force -Path (Split-Path $file -Parent) | Out-Null
            [IO.File]::WriteAllText($file, $Text)
            $parts = $Rel.Split('/')
            $item = [pscustomobject]@{ Group = $parts[1]; Path = $Rel; Hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash }
            if ($Every) {
                $item | Add-Member Every $Every
                $item | Add-Member Name ($parts[1] + '/' + [IO.Path]::GetFileNameWithoutExtension($parts[-1]))
            }
            return $item
        }
        function New-Session { param([int]$Id, [string]$Sid) [pscustomobject]@{ SessionId = $Id; User = "user$Id"; Domain = 'PC'; LogonId = "L$Id"; Sid = $Sid } }
        $ok = [pscustomobject]@{ ExitCode = 0; Output = 'set for s3cret-Value'; Errors = '' }
    }
    BeforeEach {
        Remove-Item -LiteralPath $script:WmManagedDir, $script:WmUserRunDir, $script:WmScriptsState, $script:WmScriptsFailed, $script:WmJobsState `
            -Recurse -Force -ErrorAction SilentlyContinue
        $script:WmRunSessions = $null
        $script:WmManaged = $null
        Mock Write-WmLog { }
        Mock Invoke-WmScriptProcess { [pscustomobject]@{ ExitCode = 0; Output = ''; Errors = '' } }
    }

    It 'reads who a script runs as from its wmanager-run-as line' {
        Get-WmScriptRunAs "exit 0" | Should -Be 'system'
        Get-WmScriptRunAs "# x`r`n  # wmanager-run-as: User`r`nexit 0" | Should -Be 'user'
        Get-WmScriptRunAs "# wmanager-run-as: system" | Should -Be 'system'
        { Get-WmScriptRunAs "# wmanager-run-as: admin" } | Should -Throw "*'admin' is neither user nor system*"
        { Get-WmScriptRunAs "# wmanager-run-as: user`r`n# wmanager-run-as: user" } | Should -Throw '*more than once*'
    }

    It 'runs a user script once per signed-in person and content, as that person, and a SYSTEM script once' {
        $user = Add-Item 'groups/all/scripts/10-profile.ps1' "# wmanager-run-as: user`r`n# wmanager-secrets: Pw`r`nexit 0`r`n"
        $system = Add-Item 'groups/all/scripts/20-machine.ps1' "exit 0`r`n"
        Mock Get-WmManagedContent { [pscustomobject]@{ Scripts = @($user, $system) } }
        Mock Get-WmUserSessions { @((New-Session 1 'S-1-5-21-1'), (New-Session 2 'S-1-5-21-2')) }
        Mock Invoke-WmUserScript { $ok }
        Invoke-WmGroupScripts -Config $cfg
        Should -Invoke Invoke-WmUserScript -Times 2 -Exactly
        Should -Invoke Invoke-WmUserScript -Times 1 -Exactly -ParameterFilter {
            $SessionId -eq 2 -and $File -like '*user-run*all-scripts-10-profile.ps1' -and $Environment['WMANAGER_SECRET_PW'] -eq 's3cret-Value' -and
            -not $Environment.ContainsKey('WMANAGER_GROUP_DIR') -and $Environment['WMANAGER_GROUP'] -eq 'all' }
        Should -Invoke Invoke-WmScriptProcess -Times 1 -Exactly -ParameterFilter { $File -like '*20-machine.ps1' }
        Should -Invoke Write-WmLog -Times 1 -Exactly -ParameterFilter { $Key -eq 'managed.script_done' -and $Arguments[0] -eq 'groups/all/scripts/10-profile.ps1 (user2)' }
        Should -Invoke Write-WmLog -Times 0 -ParameterFilter { "$Message" -match 's3cret' }
        $done = Read-WmTabState $script:WmScriptsState
        $done['groups/all/scripts/10-profile.ps1|S-1-5-21-1'] | Should -Be $user.Hash
        $done['groups/all/scripts/20-machine.ps1'] | Should -Be $system.Hash

        # Again: nothing; a third person signs in: only for them
        $script:WmRunSessions = $null
        Invoke-WmGroupScripts -Config $cfg
        Should -Invoke Invoke-WmUserScript -Times 2 -Exactly
        $script:WmRunSessions = $null
        Mock Get-WmUserSessions { @((New-Session 1 'S-1-5-21-1'), (New-Session 3 'S-1-5-21-3')) }
        Invoke-WmGroupScripts -Config $cfg
        Should -Invoke Invoke-WmUserScript -Times 3 -Exactly
        Should -Invoke Invoke-WmUserScript -Times 1 -Exactly -ParameterFilter { $SessionId -eq 3 }
        Should -Invoke Invoke-WmScriptProcess -Times 1 -Exactly
    }

    It 'waits for a person when nobody is signed in, and records a failure per person' {
        $user = Add-Item 'groups/all/scripts/10-profile.ps1' "# wmanager-run-as: user`r`nexit 0`r`n"
        Mock Get-WmManagedContent { [pscustomobject]@{ Scripts = @($user) } }
        Mock Get-WmUserSessions { @() }
        Mock Invoke-WmUserScript { $ok }
        Invoke-WmGroupScripts -Config $cfg
        Should -Invoke Invoke-WmUserScript -Times 0
        (Read-WmTabState $script:WmScriptsState).Count | Should -Be 0

        $script:WmRunSessions = $null
        Mock Get-WmUserSessions { @((New-Session 1 'S-1'), (New-Session 2 'S-2')) }
        Mock Invoke-WmUserScript { if ($SessionId -eq 1) { [pscustomobject]@{ ExitCode = 2; Output = ''; Errors = '' } } else { $ok } }
        Invoke-WmGroupScripts -Config $cfg -RetryFailedAfterHours 20
        Should -Invoke Write-WmLog -Times 1 -Exactly -ParameterFilter { $Key -eq 'managed.script_exit_code' -and $Arguments[0] -eq 'groups/all/scripts/10-profile.ps1 (user1)' }
        (Read-WmTabState $script:WmScriptsFailed).ContainsKey('groups/all/scripts/10-profile.ps1|S-1') | Should -BeTrue
        (Read-WmTabState $script:WmScriptsState).ContainsKey('groups/all/scripts/10-profile.ps1|S-2') | Should -BeTrue
        # Within the 20 hours: not again for the person it failed for
        $script:WmRunSessions = $null
        Invoke-WmGroupScripts -Config $cfg -RetryFailedAfterHours 20
        Should -Invoke Invoke-WmUserScript -Times 2 -Exactly
    }

    It 'does not run a script whose run-as line it cannot read, or whose copy is not the verified file' {
        $bad = Add-Item 'groups/all/scripts/10-bad.ps1' "# wmanager-run-as: everyone`r`nexit 0`r`n"
        $changed = Add-Item 'groups/all/scripts/20-changed.ps1' "# wmanager-run-as: user`r`nexit 0`r`n"
        [IO.File]::WriteAllText((Join-Path $script:WmManagedDir 'groups\all\scripts\20-changed.ps1'), "# wmanager-run-as: user`r`nexit 5`r`n")
        Mock Get-WmManagedContent { [pscustomobject]@{ Scripts = @($bad, $changed) } }
        Mock Get-WmUserSessions { @(New-Session 1 'S-1') }
        Mock Invoke-WmUserScript { $ok }
        Invoke-WmGroupScripts -Config $cfg
        Should -Invoke Invoke-WmScriptProcess -Times 0
        Should -Invoke Invoke-WmUserScript -Times 0
        Should -Invoke Write-WmLog -Times 1 -Exactly -ParameterFilter { $Key -eq 'managed.script_not_run' -and $Arguments[0] -eq 'groups/all/scripts/10-bad.ps1' }
        Should -Invoke Write-WmLog -Times 1 -Exactly -ParameterFilter { $Key -eq 'managed.script_not_run' -and $Arguments[0] -eq 'groups/all/scripts/20-changed.ps1 (user1)' }
    }

    It 'runs a job with a time at that time, once, and not when it first appears' {
        # Its time within the next minute: the 2 minutes of slack make it due at the second run
        $at = (Get-Date).AddMinutes(1).ToString('HH:mm')
        $job = Add-Item 'groups/all/jobs/daily/backup.ps1' "# wmanager-at: $at`r`nexit 0`r`n" 'daily'
        $content = [pscustomobject]@{ Jobs = @($job) }
        Mock Invoke-WmScriptProcess { [pscustomobject]@{ ExitCode = 0; Output = ''; Errors = '' } }
        Invoke-WmGroupJobs -Config $cfg -Content $content
        Should -Invoke Invoke-WmScriptProcess -Times 0
        Should -Invoke Write-WmLog -Times 1 -Exactly -ParameterFilter { $Key -eq 'managed.job_first_time' -and $Arguments[1] -eq $at }
        Invoke-WmGroupJobs -Config $cfg -Content $content
        Should -Invoke Invoke-WmScriptProcess -Times 1 -Exactly
        Should -Invoke Write-WmLog -Times 1 -Exactly -ParameterFilter { $Key -eq 'managed.job_starting' -and $Arguments[1] -eq "daily $at" }
        # Started a moment before its time, it counts as run at it: the trigger of that time doesn't run it again
        Invoke-WmGroupJobs -Config $cfg -Content $content
        Should -Invoke Invoke-WmScriptProcess -Times 1 -Exactly
    }

    It 'does not run a job whose time it can''t read' {
        $job = Add-Item 'groups/all/jobs/hourly/ping.ps1' "# wmanager-at: 18:00`r`nexit 0`r`n" 'hourly'
        Mock Invoke-WmScriptProcess { [pscustomobject]@{ ExitCode = 0; Output = ''; Errors = '' } }
        Invoke-WmGroupJobs -Config $cfg -Content ([pscustomobject]@{ Jobs = @($job) })
        Should -Invoke Invoke-WmScriptProcess -Times 0
        Should -Invoke Write-WmLog -Times 1 -Exactly -ParameterFilter { $Key -eq 'managed.job_not_run' -and $Arguments[0] -eq 'all/ping' }
    }

    It 'runs a user job on its schedule for each signed-in person' {
        $job = Add-Item 'groups/all/jobs/daily/inbox.ps1' "# wmanager-run-as: user`r`nexit 0`r`n" 'daily'
        $content = [pscustomobject]@{ Jobs = @($job) }
        Mock Get-WmUserSessions { @((New-Session 1 'S-1'), (New-Session 2 'S-2')) }
        Mock Invoke-WmUserScript { [pscustomobject]@{ ExitCode = 0; Output = '{"kind":"inbox"}'; Errors = '' } }
        Invoke-WmGroupJobs -Config $cfg -Content $content
        Should -Invoke Invoke-WmUserScript -Times 2 -Exactly
        Should -Invoke Invoke-WmUserScript -Times 2 -Exactly -ParameterFilter { $Environment['WMANAGER_JOB'] -eq 'all/inbox' -and $File -like '*all-jobs-daily-inbox.ps1' }
        Should -Invoke Write-WmLog -Times 2 -Exactly -ParameterFilter { $Message -eq '{"kind":"inbox"}' -and $Task -eq 'all/inbox' }
        # Not due again today; a person who signs in later gets it
        $script:WmRunSessions = $null
        Invoke-WmGroupJobs -Config $cfg -Content $content
        Should -Invoke Invoke-WmUserScript -Times 2 -Exactly
        $script:WmRunSessions = $null
        Mock Get-WmUserSessions { @((New-Session 1 'S-1'), (New-Session 3 'S-3')) }
        Invoke-WmGroupJobs -Config $cfg -Content $content
        Should -Invoke Invoke-WmUserScript -Times 3 -Exactly
        (Read-WmTabState $script:WmJobsState).Keys | Sort-Object | Should -Be @('groups/all/jobs/daily/inbox.ps1|S-1', 'groups/all/jobs/daily/inbox.ps1|S-2', 'groups/all/jobs/daily/inbox.ps1|S-3')
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

Describe 'Read-WmManagedSnapshot with version.psd1' {
    It 'reads the version and rejects an invalid one' {
        $dir = Join-Path $TestDrive 'ver'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $file = Join-Path $dir 'version.psd1'
        $manifest = [pscustomobject]@{ Files = @{ 'version.psd1' = $hashA } }
        Set-Content -LiteralPath $file -Value "@{ Version = 'v0.2.0'; Url = 'C:\rel\wmanager-v0.2.0.zip'; Sha256 = '$('c' * 64)' }" -Encoding UTF8
        (Read-WmManagedSnapshot -Dir $dir -Manifest $manifest).Versions.Default.Version | Should -Be 'v0.2.0'
        Set-Content -LiteralPath $file -Value "@{ Version = 'v0.2.0' }" -Encoding UTF8
        { Read-WmManagedSnapshot -Dir $dir -Manifest $manifest } | Should -Throw 'version.psd1: Url is missing*'
        Set-Content -LiteralPath $file -Value "@{ Version = (Get-Date) }" -Encoding UTF8
        { Read-WmManagedSnapshot -Dir $dir -Manifest $manifest } | Should -Throw 'version.psd1: *'
    }

    It 'has no version without the file' {
        $dir = Join-Path $TestDrive 'nover'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        (Read-WmManagedSnapshot -Dir $dir -Manifest ([pscustomobject]@{ Files = @{} })).Versions | Should -BeNullOrEmpty
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

Describe 'Get-WmJobAt' {
    It 'reads a time, days, lists and ranges' {
        $at = Get-WmJobAt "exit 0`r`n# wmanager-at: 18:00`r`n" 'daily'
        $at.Time | Should -Be '18:00'
        $at.Days | Should -Be @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')
        (Get-WmJobAt '# wmanager-at: Mon-Fri 7:30' 'daily').Days | Should -Be @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday')
        (Get-WmJobAt '# wmanager-at: Mon-Fri 7:30' 'daily').Time | Should -Be '07:30'
        (Get-WmJobAt '#wmanager-at: sat,MONDAY 06:00' 'daily').Days | Should -Be @('Monday', 'Saturday')
        (Get-WmJobAt '# wmanager-at: Fri-Mon 22:00' 'daily').Days | Should -Be @('Monday', 'Friday', 'Saturday', 'Sunday')
        (Get-WmJobAt '# wmanager-at: Mon, Wed, Fri 07:30' 'daily').Days | Should -Be @('Monday', 'Wednesday', 'Friday')
        (Get-WmJobAt '# wmanager-at: Mon - Fri 18:00' 'daily').Days | Should -Be @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday')
        (Get-WmJobAt '# wmanager-at: Fri 17:00' 'weekly').Days | Should -Be @('Friday')
        (Get-WmJobAt '# wmanager-at: Fri 17:00' 'weekly').Text | Should -Be 'Fri 17:00'
        Get-WmJobAt "exit 0`r`n" 'daily' | Should -BeNullOrEmpty
    }

    It 'refuses what it can''t read, a second line, an hourly job, and a weekly job without exactly one day' {
        foreach ($bad in @('18', '25:00', '18:60', 'Mo 18:00', 'Mon-Tue-Wed 18:00', 'Mon- 18:00', 'Funday 18:00', 'Mon Fri 18:00', '')) {
            { Get-WmJobAt "# wmanager-at: $bad" 'daily' } | Should -Throw '*is not a time like*' -Because $bad
        }
        { Get-WmJobAt "# wmanager-at: 18:00`r`n# wmanager-at: 19:00" 'daily' } | Should -Throw '*more than one*'
        { Get-WmJobAt '# wmanager-at: 18:00' 'hourly' } | Should -Throw '*every hour*'
        { Get-WmJobAt '# wmanager-at: 17:00' 'weekly' } | Should -Throw '*names one day*'
        { Get-WmJobAt '# wmanager-at: Mon,Fri 17:00' 'weekly' } | Should -Throw '*names one day*'
    }
}

Describe 'Test-WmJobDue with a time' {
    BeforeAll {
        # Local times, as the user writes them; the job state keeps UTC
        function L { param([string]$Text) ([datetime]::ParseExact($Text, 'yyyy-MM-dd HH:mm', $null)).ToUniversalTime() }
        $workdays = Get-WmJobAt '# wmanager-at: Mon-Fri 18:00' 'daily'
    }

    It 'is due once its time has passed since the last run, a moment early included' {
        # 2026-11-24 is a Tuesday
        Test-WmJobDue -Every 'daily' -LastRun (L '2026-11-23 18:00') -Now (L '2026-11-24 17:00') -At $workdays | Should -BeFalse
        Test-WmJobDue -Every 'daily' -LastRun (L '2026-11-23 18:00') -Now (L '2026-11-24 17:59') -At $workdays | Should -BeTrue
        Test-WmJobDue -Every 'daily' -LastRun (L '2026-11-24 18:00') -Now (L '2026-11-24 23:00') -At $workdays | Should -BeFalse
    }

    It 'catches up at the next hour after a time the computer was off, and skips the days it doesn''t run' {
        # Off from Friday 17:00 to Monday 09:00: Friday's 18:00 is caught up, once
        Test-WmJobDue -Every 'daily' -LastRun (L '2026-11-26 18:00') -Now (L '2026-11-30 09:00') -At $workdays | Should -BeTrue
        Test-WmJobDue -Every 'daily' -LastRun (L '2026-11-27 18:00') -Now (L '2026-11-30 09:00') -At $workdays | Should -BeFalse
        $friday = Get-WmJobAt '# wmanager-at: Fri 17:00' 'weekly'
        Test-WmJobDue -Every 'weekly' -LastRun (L '2026-11-20 17:00') -Now (L '2026-11-26 12:00') -At $friday | Should -BeFalse
        Test-WmJobDue -Every 'weekly' -LastRun (L '2026-11-20 17:00') -Now (L '2026-11-27 17:00') -At $friday | Should -BeTrue
    }

    It 'leaves the catching up to its next time when that comes within the hour, so it runs once, not twice' {
        # Off on Monday at 18:00, on again on Tuesday: before 17:00 it catches up, after that the 18:00 run stands for both
        Test-WmJobDue -Every 'daily' -LastRun (L '2026-11-20 18:00') -Now (L '2026-11-24 16:58') -At $workdays | Should -BeTrue
        Test-WmJobDue -Every 'daily' -LastRun (L '2026-11-20 18:00') -Now (L '2026-11-24 17:30') -At $workdays | Should -BeFalse
        Test-WmJobDue -Every 'daily' -LastRun (L '2026-11-20 18:00') -Now (L '2026-11-24 18:00') -At $workdays | Should -BeTrue
        # After Friday's run the next one is Monday's, over the weekend
        Get-WmJobNextSlot -At $workdays -Now (L '2026-11-27 18:30') | Should -Be ([datetime]'2026-11-30 18:00')
    }
}

Describe 'Get-WmEventSpecs' {
    It 'reads the ready names, raw events with or without a source, a quoted log, and the gap' {
        $specs = Get-WmEventSpecs "exit 0`r`n# wmanager-event: Network`r`n#wmanager-event: unlock`r`n"
        @($specs.Events | ForEach-Object { $_.Name }) | Should -Be @('network', 'unlock')
        $specs.Events[0].Text | Should -Be 'Network'
        $specs.Gap | Should -Be 5
        $raw = (Get-WmEventSpecs "# wmanager-event: System 7036 Service Control Manager`r`n# wmanager-event-gap: 0").Events[0]
        $raw.Log | Should -Be 'System'
        $raw.Id | Should -Be 7036
        $raw.Provider | Should -Be 'Service Control Manager'
        $raw.Name | Should -Be ''
        (Get-WmEventSpecs "# wmanager-event: System 7036 Service Control Manager`r`n# wmanager-event-gap: 0").Gap | Should -Be 0
        $q = (Get-WmEventSpecs '# wmanager-event: "Windows PowerShell" 400').Events[0]
        $q.Log | Should -Be 'Windows PowerShell'
        $q.Provider | Should -Be ''
        (Get-WmEventSpecs "# wmanager-event: Microsoft-Windows-NetworkProfile/Operational 10000`r`n# wmanager-event-gap: 1440").Gap | Should -Be 1440
    }

    It 'refuses a script without an event, a line it can''t read, an event twice and a bad or second gap' {
        { Get-WmEventSpecs "exit 0`r`n" } | Should -Throw '*names its event*'
        foreach ($bad in @('thunder', 'System', 'System x', 'System 70000', '"System 7036', "System 7036 it's", 'System 7036 <x>', '')) {
            { Get-WmEventSpecs "# wmanager-event: $bad" } | Should -Throw '*is neither network*' -Because $bad
        }
        { Get-WmEventSpecs "# wmanager-event: lock`r`n# wmanager-event: LOCK" } | Should -Throw '*twice*'
        { Get-WmEventSpecs "# wmanager-event: System 7036`r`n# wmanager-event: system 7036" } | Should -Throw '*twice*'
        foreach ($gap in @('1441', '-1', '5 min', '')) {
            { Get-WmEventSpecs "# wmanager-event: wake`r`n# wmanager-event-gap: $gap" } | Should -Throw '*number of minutes*' -Because $gap
        }
        { Get-WmEventSpecs "# wmanager-event: wake`r`n# wmanager-event-gap: 1`r`n# wmanager-event-gap: 2" } | Should -Throw '*more than one*'
    }
}

Describe 'Event scripts' {
    BeforeAll {
        $script:WmManagedDir = Join-Path $TestDrive 'managed-events'
        $script:WmEventsDir = Join-Path $TestDrive 'events'
        $script:WmEventsState = Join-Path $TestDrive 'events-state.txt'
        $script:WmEventsMutex = 'wmanager-test-events-' + [guid]::NewGuid().ToString('N')
        $script:WmHostName = 'PC-1'
        $cfg = @{ Management = @{ Source = 'https://example.test/acme'; SourceId = $sid; ScriptTimeoutMinutes = 7 }
                  Secrets = @{ ShareUser = 'office'; SharePassword = 'p4ss-W0rd' } }

        # Event scripts in the verified copy, as its manifest lists them (path -> SHA256)
        function Set-EventFiles {
            param([hashtable]$Scripts)
            $script:eventFiles = @{}
            foreach ($rel in $Scripts.Keys) {
                $file = Join-Path $script:WmManagedDir ($rel -replace '/', '\')
                New-Item -ItemType Directory -Force -Path (Split-Path $file -Parent) | Out-Null
                [IO.File]::WriteAllText($file, $Scripts[$rel])
                $script:eventFiles[$rel] = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
            }
        }
        function Set-LastRun {
            param([string]$Path, [datetime]$When)
            Save-WmTabState -Path $script:WmEventsState -Map @{ $Path = $When.ToUniversalTime().ToString('o') }
        }
    }
    BeforeEach {
        Remove-Item -LiteralPath $script:WmEventsDir, $script:WmManagedDir, $script:WmEventsState -Recurse -Force -ErrorAction SilentlyContinue
        Mock Write-WmLog { }
        Mock Get-WmVerifiedGroups { [pscustomobject]@{ Files = $script:eventFiles; Groups = @('all', 'office'); Settings = $cfg.Management } }
        Mock Invoke-WmScriptProcess { [pscustomobject]@{ ExitCode = 0; Output = 'mapped as office with p4ss-W0rd'; Errors = '' } }
        Mock Get-WmConsoleSession { [pscustomobject]@{ SessionId = 2; User = 'anna'; Domain = 'PC-1' } }
    }

    It 'lists a task for each event of each script, and none for a script whose events can''t be read' {
        Set-EventFiles @{
            'groups/office/events/drives.ps1' = "# wmanager-event: network`r`n# wmanager-event: wake`r`nexit 0`r`n"
            'groups/all/events/broken.ps1'    = "exit 0`r`n"
        }
        $content = [pscustomobject]@{ EventScripts = @(
            [pscustomobject]@{ Group = 'office'; Path = 'groups/office/events/drives.ps1'; Name = 'office/drives' },
            [pscustomobject]@{ Group = 'all'; Path = 'groups/all/events/broken.ps1'; Name = 'all/broken' }) }
        $list = @(Get-WmEventTaskList -Content $content)
        $list.Count | Should -Be 2
        @($list | ForEach-Object { "$($_.Script) $($_.Index) $($_.Spec.Name)" }) | Should -Be @('office/drives 1 network', 'office/drives 2 wake')
        $list[1].Description | Should -Be 'wmanager: event script office/drives, at "wake" (v1)'
        Should -Invoke Write-WmLog -Times 1 -Exactly -ParameterFilter { $Key -eq 'events.script_not_run' -and $Arguments[0] -eq 'all/broken' }
    }

    It 'runs the script for its event, with the event, its log and record, and only the secrets it names, hidden in the log' {
        Set-EventFiles @{
            'groups/office/events/drives.ps1' = "# wmanager-event: network`r`n# wmanager-event: System 7036 Service Control Manager`r`n# wmanager-secrets: ShareUser`r`nexit 0`r`n"
        }
        Invoke-WmEventScript -Config $cfg -Name 'office/drives' -Index 2 -Record '123' -Log 'System'
        Should -Invoke Invoke-WmScriptProcess -Times 1 -Exactly -ParameterFilter {
            $File -like '*office-events-drives.ps1' -and $Environment['WMANAGER_EVENT'] -eq 'System 7036 Service Control Manager' -and
            $Environment['WMANAGER_EVENT_RECORD'] -eq '123' -and $Environment['WMANAGER_EVENT_LOG'] -eq 'System' -and
            $Environment['WMANAGER_SECRET_SHAREUSER'] -eq 'office' -and -not $Environment.ContainsKey('WMANAGER_SECRET_SHAREPASSWORD') -and
            $Environment['WMANAGER_GROUP'] -eq 'office' -and $Environment['WMANAGER_COMPUTER'] -eq 'PC-1' -and $TimeoutMinutes -eq 7 }
        Should -Invoke Write-WmLog -Times 1 -Exactly -ParameterFilter { $Key -eq 'events.starting' -and $Arguments[1] -eq 'System 7036 Service Control Manager' }
        Should -Invoke Write-WmLog -Times 1 -Exactly -ParameterFilter { $Key -eq 'events.script_done' -and $Arguments[0] -eq 'office/drives' }
        Should -Invoke Write-WmLog -Times 0 -ParameterFilter { "$Message" -match 'office with' }
        Should -Invoke Write-WmLog -Times 1 -Exactly -ParameterFilter { "$Message" -match 'mapped as \*\*\* with' }
    }

    It 'gives lock and unlock the session at the screen, and leaves out the values Task Scheduler didn''t fill in' {
        Set-EventFiles @{ 'groups/all/events/screen.ps1' = "# wmanager-event: unlock`r`n# wmanager-event: Application 999`r`n# wmanager-event-gap: 0`r`nexit 0`r`n" }
        Invoke-WmEventScript -Config $cfg -Name 'all/screen' -Index 1
        Should -Invoke Invoke-WmScriptProcess -Times 1 -Exactly -ParameterFilter {
            $Environment['WMANAGER_EVENT'] -eq 'unlock' -and $Environment['WMANAGER_EVENT_SESSION'] -eq '2' -and
            $Environment['WMANAGER_EVENT_USER'] -eq 'PC-1\anna' -and -not $Environment.ContainsKey('WMANAGER_EVENT_RECORD') }
        Invoke-WmEventScript -Config $cfg -Name 'all/screen' -Index 2 -Record '$(Record)' -Log '$(Log)'
        Should -Invoke Invoke-WmScriptProcess -Times 1 -Exactly -ParameterFilter {
            $Environment['WMANAGER_EVENT'] -eq 'Application 999' -and -not $Environment.ContainsKey('WMANAGER_EVENT_RECORD') -and
            -not $Environment.ContainsKey('WMANAGER_EVENT_LOG') -and -not $Environment.ContainsKey('WMANAGER_EVENT_SESSION') }
    }

    It 'doesn''t run again within its gap, whichever of its events comes, and runs after it' {
        Set-EventFiles @{ 'groups/all/events/net.ps1' = "# wmanager-event: network`r`n# wmanager-event: wake`r`nexit 0`r`n" }
        Invoke-WmEventScript -Config $cfg -Name 'all/net' -Index 1
        Invoke-WmEventScript -Config $cfg -Name 'all/net' -Index 2
        Should -Invoke Invoke-WmScriptProcess -Times 1 -Exactly
        Set-LastRun 'groups/all/events/net.ps1' (Get-Date).AddMinutes(-6)
        Invoke-WmEventScript -Config $cfg -Name 'all/net' -Index 2
        Should -Invoke Invoke-WmScriptProcess -Times 2 -Exactly
        # A last run in the future (the clock went back) doesn't hold it
        Set-LastRun 'groups/all/events/net.ps1' (Get-Date).AddHours(2)
        Invoke-WmEventScript -Config $cfg -Name 'all/net' -Index 1
        Should -Invoke Invoke-WmScriptProcess -Times 3 -Exactly
    }

    It 'skips a script gone from the source, an event its lines no longer have, and a copy that isn''t the verified one' {
        Set-EventFiles @{ 'groups/all/events/net.ps1' = "# wmanager-event: network`r`nexit 0`r`n" }
        Invoke-WmEventScript -Config $cfg -Name 'all/gone' -Index 1
        Should -Invoke Write-WmLog -Times 1 -Exactly -ParameterFilter { $Key -eq 'events.not_here' -and $Arguments[0] -eq 'all/gone' }
        Invoke-WmEventScript -Config $cfg -Name 'all/net' -Index 2
        Should -Invoke Write-WmLog -Times 1 -Exactly -ParameterFilter { $Key -eq 'events.changed' -and $Arguments[0] -eq 'all/net' }
        [IO.File]::WriteAllText((Join-Path $script:WmManagedDir 'groups\all\events\net.ps1'), "# wmanager-event: network`r`nexit 5`r`n")
        Invoke-WmEventScript -Config $cfg -Name 'all/net' -Index 1
        Should -Invoke Write-WmLog -Times 1 -Exactly -ParameterFilter { $Key -eq 'events.script_not_run' -and $Arguments[0] -eq 'all/net' }
        Should -Invoke Invoke-WmScriptProcess -Times 0
    }

    It 'says so without a verified copy, and when another event script is still running' {
        Mock Get-WmVerifiedGroups { $null }
        Invoke-WmEventScript -Config $cfg -Name 'all/net' -CopyWaitSeconds 0
        Should -Invoke Write-WmLog -Times 1 -Exactly -ParameterFilter { $Key -eq 'events.no_copy' -and $Level -eq 'warn' }
        # Another one holds the lock of the event scripts (in its own thread)
        $other = [powershell]::Create().AddScript("`$m = New-Object System.Threading.Mutex(`$false, '$($script:WmEventsMutex)'); `$null = `$m.WaitOne(); Start-Sleep -Seconds 4; `$m.ReleaseMutex()")
        $busy = $other.BeginInvoke()
        try {
            Start-Sleep -Milliseconds 1500
            Invoke-WmEventScript -Config $cfg -Name 'all/net' -WaitMinutes 0
            Should -Invoke Write-WmLog -Times 1 -Exactly -ParameterFilter { $Key -eq 'events.busy' -and $Arguments[0] -eq 'all/net' }
            Should -Invoke Get-WmVerifiedGroups -Times 1 -Exactly
        } finally {
            $null = $other.EndInvoke($busy)
            $other.Dispose()
        }
    }
}
