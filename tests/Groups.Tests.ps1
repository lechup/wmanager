# Tests for tools/groups.ps1, the terminal helper for a management source: what a computer gets, the checks, and the
# edits, which must keep the rest of each file as it is (comments, BOM, CRLF). Platform-neutral: runs on Linux in CI.
# To run (Pester 5):
#   Invoke-Pester ./tests/Groups.Tests.ps1

BeforeAll {
    $script:root = Split-Path $PSScriptRoot -Parent
    $script:tool = Join-Path (Join-Path $script:root 'tools') 'groups.ps1'

    # Runs the tool in this process; its messages go through Write-Host (stream 6)
    function Invoke-Tool {
        $out = & $script:tool @args 6>&1 | Out-String
        return [pscustomobject]@{ Code = $LASTEXITCODE; Text = $out }
    }

    # A fresh copy of examples/management
    function New-Source {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Copy-Item -Recurse -LiteralPath (Join-Path (Join-Path $script:root 'examples') 'management') -Destination $dir
        return $dir
    }

    function Get-Path {
        param([string]$Dir, [string]$Rel)
        return [IO.Path]::Combine($Dir, $Rel.Replace('/', [IO.Path]::DirectorySeparatorChar))
    }

    function Read-Text {
        param([string]$Path)
        return [IO.File]::ReadAllText($Path)
    }

    function Set-Text {
        param([string]$Path, [string]$Text, [switch]$Bom)
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
        [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding([bool]$Bom)))
    }

    function Test-Bom {
        param([string]$Path)
        $b = [IO.File]::ReadAllBytes($Path)
        return ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
    }

    function Test-OnlyCrLf {
        param([string]$Text)
        return (($Text -replace "`r`n", '') -notmatch "[`r`n]")
    }

    # A release ZIP laid out like tools/build-release.sh makes it (wmanager/<file>); returns its path
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    function New-Release {
        param([string]$Version, [switch]$NoSelfInstall, [string]$Inside = $Version)
        $path = Join-Path $TestDrive ("wmanager-$Version-" + [guid]::NewGuid().ToString('N') + '.zip')
        $update = 'param([switch]$OnlyIfPending, [switch]$SelfInstall, [string]$Lang)'
        if ($NoSelfInstall) { $update = 'param([switch]$OnlyIfPending, [string]$Lang)' }
        $fs = [IO.File]::Open($path, [IO.FileMode]::Create)
        try {
            $zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
            foreach ($e in @(@('wmanager/VERSION', $Inside), @('wmanager/Update-Packages.ps1', $update))) {
                $w = New-Object IO.StreamWriter($zip.CreateEntry($e[0]).Open())
                $w.Write($e[1])
                $w.Dispose()
            }
            $zip.Dispose()
        } finally {
            $fs.Dispose()
        }
        return $path
    }

    function Get-Sha256 {
        param([string]$Path)
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
}

Describe 'Test-WmAccountName' {
    BeforeAll { . (Join-Path (Join-Path $script:root 'lib') 'Groups.ps1') }
    It 'takes plain local account names' {
        foreach ($n in @('it-admin', 'Admin2', 'office.admin', 'a', 'x_y', '12345678901234567890')) { Test-WmAccountName $n | Should -BeTrue -Because $n }
    }
    It 'refuses names other tools or languages would trip on' {
        foreach ($n in @('', 'bad name', '-admin', '.admin', 'admin.', 'a\b', 'a@b', 'ąbc', '123456789012345678901')) { Test-WmAccountName $n | Should -BeFalse -Because $n }
    }
}

Describe 'show' {
    It 'lists what a computer gets: its groups, the merged packages with their list, scripts and jobs' {
        $src = New-Source
        $r = Invoke-Tool $src show office-01
        $r.Code | Should -Be 0
        $r.Text | Should -Match 'OFFICE-01: groups all, accounting'
        $r.Text | Should -Match 'adobereader !noupdate\s+from accounting'
        $r.Text | Should -Match 'vlc\s+from common'
        $r.Text | Should -Match 'groups/accounting/scripts/10-power-plan\.ps1'
        $r.Text | Should -Match 'daily\s+all/system-report'
    }

    It 'gives a computer that is not in the map only the default groups' {
        $src = New-Source
        $r = Invoke-Tool $src show OFFICE-99
        $r.Text | Should -Match 'OFFICE-99 is not in groups\.psd1, so only the default groups: all'
        $r.Text | Should -Not -Match 'adobereader'
        $r.Text | Should -Not -Match '10-power-plan'
    }

    It 'gives an overview of groups and computers' {
        $src = New-Source
        $r = Invoke-Tool $src show
        $r.Code | Should -Be 0
        $r.Text | Should -Match 'Default groups \(every computer\): all'
        $r.Text | Should -Match 'accounting\s+2 computers\s+packages: 1\s+scripts: 1\s+jobs: 0'
        $r.Text | Should -Match 'all\s+every computer\s+packages: 0\s+scripts: 0\s+jobs: 1'
    }

    It 'shows the entry the computer uses when a group replaces a common entry or two groups differ' {
        $src = New-Source
        (Invoke-Tool $src add-package accounting '7zip !noupdate').Code | Should -Be 0
        (Invoke-Tool $src add-package floor-1 '7zip@24.8.0').Code | Should -Be 0
        (Invoke-Tool $src add-computer OFFICE-01 floor-1).Code | Should -Be 0
        $r = Invoke-Tool $src show OFFICE-01
        $r.Text | Should -Match '7zip !noupdate\s+from accounting'
        $r.Text | Should -Match 'Note: Package 7zip: the entry of group accounting replaces the entry of the common list'
        $r.Text | Should -Match "WARNING: Package 7zip is described differently in 'accounting' and 'floor-1'"
    }
}

Describe 'check' {
    It 'passes the example source' {
        $r = Invoke-Tool (New-Source) check
        $r.Code | Should -Be 0
        $r.Text | Should -Match '0 errors, 0 warnings'
    }

    It 'fails on a groups.psd1 the computers would reject' {
        $src = New-Source
        Set-Text (Get-Path $src 'groups.psd1') "@{`r`n    Default = @('all'`r`n}`r`n" -Bom
        $r = Invoke-Tool $src check
        $r.Code | Should -Be 1
        $r.Text | Should -Match 'ERROR: groups\.psd1, line'

        Set-Text (Get-Path $src 'groups.psd1') "@{ Default = @('all'); Printers = @{} }`r`n" -Bom
        $r = Invoke-Tool $src check
        $r.Code | Should -Be 1
        $r.Text | Should -Match 'Printers'
    }

    It 'fails on an invalid package line and on a script that does not parse' {
        $src = New-Source
        Set-Text (Get-Path $src 'groups/accounting/choco-reqs.txt') "adobereader !sometimes`r`n"
        Set-Text (Get-Path $src 'groups/accounting/scripts/20-broken.ps1') "if (`$true) {`r`n" -Bom
        $r = Invoke-Tool $src check
        $r.Code | Should -Be 1
        $r.Text | Should -Match "ERROR: groups/accounting/choco-reqs\.txt: Line 1: unknown option '!sometimes'"
        $r.Text | Should -Match 'ERROR: groups/accounting/scripts/20-broken\.ps1, line'
    }

    It 'warns about what the computers would ignore, without failing' {
        $src = New-Source
        Set-Text (Get-Path $src 'groups/accounting/jobs/monthly/report.ps1') "exit 0`r`n" -Bom
        Set-Text (Get-Path $src 'groups/accounting/scripts/old/10-x.ps1') "exit 0`r`n" -Bom
        Set-Text (Get-Path $src 'groups/unused/choco-reqs.txt') "vlc`r`n"
        Set-Text (Get-Path $src 'groups/accounting/scripts/30-no-bom.ps1') "Write-Output 'zażółć'`r`n"
        (Invoke-Tool $src add-computer OFFICE-05 reception).Code | Should -Be 0
        $r = Invoke-Tool $src check
        $r.Code | Should -Be 0
        $r.Text | Should -Match 'jobs/monthly/report\.ps1 is not run'
        $r.Text | Should -Match 'scripts/old/10-x\.ps1 is not run'
        $r.Text | Should -Match 'groups/unused/ is not used'
        $r.Text | Should -Match 'group reception \(groups\.psd1\) has no folder'
        $r.Text | Should -Match '30-no-bom\.ps1 has non-ASCII characters but no BOM'
    }

    It 'fails on syntax that Windows PowerShell 5.1 on the computers does not have' {
        $src = New-Source
        Set-Text (Get-Path $src 'groups/accounting/scripts/20-ps7.ps1') "`$x = `$env:X ?? 'default'`r`n" -Bom
        $r = Invoke-Tool $src check
        $r.Code | Should -Be 1
        $r.Text | Should -Match 'ERROR: groups/accounting/scripts/20-ps7\.ps1, line 1'
    }

    It 'warns when script numbers have different widths, and about a group named common' {
        $src = New-Source
        Set-Text (Get-Path $src 'groups/accounting/scripts/5-early.ps1') "exit 0`r`n" -Bom
        Set-Text (Get-Path $src 'groups/common/choco-reqs.txt') "vlc`r`n"
        $r = Invoke-Tool $src check
        $r.Text | Should -Match 'groups/accounting/scripts: number the scripts with the same number of digits'
        $r.Text | Should -Match "a group is named 'common'"
        (Invoke-Tool $src add-package common 'vlc').Code | Should -Be 1
    }

    It 'in a git repository checks what git would push, not ignored files' -Skip:(-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
        $src = New-Source
        & git -C $src init -q 2>$null
        Set-Text (Get-Path $src '.gitignore') "99-draft.ps1`n"
        Set-Text (Get-Path $src 'groups/accounting/scripts/99-draft.ps1') "if (`$true) {`r`n" -Bom
        $r = Invoke-Tool $src check
        $r.Code | Should -Be 0
        $r.Text | Should -Not -Match '99-draft'
    }

    It 'checks only the listed files with -FileList' {
        $src = New-Source
        Set-Text (Get-Path $src 'groups/accounting/scripts/99-ignored.ps1') "if (`$true) {`r`n" -Bom
        $list = Join-Path $TestDrive 'files.txt'
        Set-Text $list "groups.psd1`nchoco-reqs.txt`ngroups/accounting/choco-reqs.txt`ngroups/accounting/scripts/10-power-plan.ps1`ngroups/all/jobs/daily/system-report.ps1`n"
        $r = Invoke-Tool $src check -FileList $list
        $r.Code | Should -Be 0
    }
}

Describe 'secrets for scripts' {
    BeforeAll {
        . (Join-Path (Join-Path $script:root 'lib') 'Lang.ps1')
        . (Join-Path (Join-Path $script:root 'lib') 'Groups.ps1')
        Initialize-WmLanguage -Lang 'en' -Root $script:root
    }

    It 'reads the names a script gives in its wmanager-secrets lines, each once' {
        $text = "# A script`r`n# wmanager-secrets: ShareUser, SharePassword`r`n`$x = 1`r`n    #wmanager-secrets:sharepassword WifiKey`r`n"
        $names = Get-WmScriptSecretNames $text
        $names | Should -Be @('ShareUser', 'SharePassword', 'WifiKey')
        Get-WmScriptSecretNames "Write-Output '# wmanager-secrets: Nope'" | Should -BeNullOrEmpty
        (Get-WmScriptSecretNames '').Count | Should -Be 0
        { Get-WmScriptSecretNames '# wmanager-secrets: 9lives' } | Should -Throw "*'9lives' is not a secret's name*"
        { Get-WmScriptSecretNames '# wmanager-secrets: Share-User' } | Should -Throw '*Share-User*'
    }

    It 'checks the Secrets of a configuration' {
        (Get-WmSecrets @{}).Count | Should -Be 0
        (Get-WmSecrets @{ Secrets = @{ A = 'x'; B_2 = "it's" } }).B_2 | Should -Be "it's"
        { Get-WmSecrets @{ Secrets = 'x' } } | Should -Throw '*must be a table*'
        { Get-WmSecrets @{ Secrets = @{ '1a' = 'x' } } } | Should -Throw "*'1a' is not a secret's name*"
        { Get-WmSecrets @{ Secrets = @{ A = '' } } } | Should -Throw '*value of A*'
        { Get-WmSecrets @{ Secrets = @{ A = "two`nlines" } } } | Should -Throw '*value of A*'
        { Get-WmSecrets @{ Secrets = @{ A = 5 } } } | Should -Throw '*value of A*'
    }

    It 'hides the values in what a script prints, the longest first' {
        Hide-WmSecrets 'user office, password office-2026!' @('office', 'office-2026!') | Should -Be 'user ***, password ***'
        Hide-WmSecrets 'nothing secret' @() | Should -Be 'nothing secret'
        Hide-WmSecrets '' @('x') | Should -Be ''
    }

    It 'check refuses a script or job with a name that is not one' {
        $src = New-Source
        Set-Text (Get-Path $src 'groups/all/scripts/30-share.ps1') "# wmanager-secrets: ShareUser, 2nd`r`nWrite-Output 1`r`n" -Bom
        $r = Invoke-Tool $src check
        $r.Code | Should -Be 1
        $r.Text | Should -Match "ERROR: groups/all/scripts/30-share\.ps1: wmanager-secrets: '2nd' is not a secret's name"
        Set-Text (Get-Path $src 'groups/all/scripts/30-share.ps1') "# wmanager-secrets: ShareUser, Second`r`nWrite-Output 1`r`n" -Bom
        (Invoke-Tool $src check).Code | Should -Be 0
    }
}

Describe 'add-computer and remove-computer' {
    It 'adds a computer after the last entry, aligned, and keeps comments, BOM and line endings' {
        $src = New-Source
        $path = Get-Path $src 'groups.psd1'
        $r = Invoke-Tool $src add-computer office-03 accounting
        $r.Code | Should -Be 0
        $text = Read-Text $path
        $text | Should -Match ([regex]::Escape("'OFFICE-02' = @('accounting')`r`n        'OFFICE-03' = @('accounting')`r`n        # 'RECEPTION'"))
        $text | Should -Match '# Groups of every computer'
        Test-Bom $path | Should -BeTrue
        Test-OnlyCrLf $text | Should -BeTrue
    }

    It 'adds a group to a computer with an entry, and takes it out again' {
        $src = New-Source
        $path = Get-Path $src 'groups.psd1'
        $r = Invoke-Tool $src add-computer OFFICE-01 floor-1
        $r.Text | Should -Match 'group floor-1 has no folder groups/floor-1/ yet'
        Read-Text $path | Should -Match ([regex]::Escape("'OFFICE-01' = @('accounting', 'floor-1')"))
        (Invoke-Tool $src remove-computer OFFICE-01 floor-1).Code | Should -Be 0
        Read-Text $path | Should -Match ([regex]::Escape("'OFFICE-01' = @('accounting')`r`n"))
        (Invoke-Tool $src add-computer OFFICE-01 accounting).Text | Should -Match 'No change'
    }

    It 'removes the whole entry with its line' {
        $src = New-Source
        $path = Get-Path $src 'groups.psd1'
        $before = (Read-Text $path) -split "`r`n"
        (Invoke-Tool $src remove-computer office-02).Code | Should -Be 0
        $after = Read-Text $path
        $after | Should -Not -Match 'OFFICE-02'
        $after | Should -Match ([regex]::Escape("'OFFICE-01' = @('accounting')`r`n        # 'RECEPTION'"))
        ($after -split "`r`n").Count | Should -Be ($before.Count - 1)
    }

    It 'fills an empty Computers, and adds Computers to a map without it' {
        $src = New-Source
        $path = Get-Path $src 'groups.psd1'
        Set-Text $path "@{`r`n    Default = @('all')`r`n    Computers = @{}`r`n}`r`n" -Bom
        (Invoke-Tool $src add-computer pc-1 accounting).Code | Should -Be 0
        Read-Text $path | Should -Be "@{`r`n    Default = @('all')`r`n    Computers = @{`r`n        'PC-1' = @('accounting')`r`n    }`r`n}`r`n"

        Set-Text $path "@{`r`n    Default = @('all')`r`n}`r`n" -Bom
        (Invoke-Tool $src add-computer pc-1 accounting).Code | Should -Be 0
        Read-Text $path | Should -Be "@{`r`n    Default = @('all')`r`n`r`n    Computers = @{`r`n        'PC-1' = @('accounting')`r`n    }`r`n}`r`n"
    }

    It 'refuses invalid names and changes nothing' {
        $src = New-Source
        $path = Get-Path $src 'groups.psd1'
        $before = [IO.File]::ReadAllBytes($path)
        (Invoke-Tool $src add-computer 'NOT-A-VALID-NAME-1' accounting).Code | Should -Be 1
        (Invoke-Tool $src add-computer PC-1 'bad/group').Code | Should -Be 1
        [IO.File]::ReadAllBytes($path) | Should -Be $before
    }
}

Describe 'add-package and remove-package' {
    It 'adds a package to a group, creating its list' {
        $src = New-Source
        $r = Invoke-Tool $src add-package floor-1 '7zip@24.8.0'
        $r.Code | Should -Be 0
        Read-Text (Get-Path $src 'groups/floor-1/choco-reqs.txt') | Should -Be "7zip@24.8.0`r`n"
    }

    It 'replaces the line of the same package and keeps its comment; the words of the line may come separately' {
        $src = New-Source
        $path = Get-Path $src 'groups/accounting/choco-reqs.txt'
        Set-Text $path "# accounting`r`nvlc   # player`r`n"
        (Invoke-Tool $src add-package accounting 'vlc@3.0.21').Code | Should -Be 0
        Read-Text $path | Should -Be "# accounting`r`nvlc@3.0.21   # player`r`n"
        (Invoke-Tool $src add-package common 7zip '!noupdate').Code | Should -Be 0
        Read-Text (Get-Path $src 'choco-reqs.txt') | Should -Match "(?m)^7zip !noupdate\r$"
    }

    It 'removes a package from a list' {
        $src = New-Source
        $r = Invoke-Tool $src remove-package common VLC
        $r.Code | Should -Be 0
        $r.Text | Should -Match 'packages are never uninstalled'
        Read-Text (Get-Path $src 'choco-reqs.txt') | Should -Not -Match '(?m)^vlc'
        (Invoke-Tool $src remove-package common vlc).Code | Should -Be 1
    }

    It 'refuses an invalid line and leaves the list as it was' {
        $src = New-Source
        $path = Get-Path $src 'choco-reqs.txt'
        $before = [IO.File]::ReadAllBytes($path)
        (Invoke-Tool $src add-package common 'vlc !bogus').Code | Should -Be 1
        (Invoke-Tool $src add-package 'bad/group' 'vlc').Code | Should -Be 1
        [IO.File]::ReadAllBytes($path) | Should -Be $before
    }
}

Describe 'new-script and new-job' {
    It 'creates a numbered script that parses, saved as UTF-8 with BOM and CRLF' {
        $src = New-Source
        (Invoke-Tool $src new-script accounting printers).Code | Should -Be 0
        $path = Get-Path $src 'groups/accounting/scripts/20-printers.ps1'
        Test-Bom $path | Should -BeTrue
        $text = Read-Text $path
        Test-OnlyCrLf $text | Should -BeTrue
        $text | Should -Match 'Script of group accounting'
        $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errs)
        @($errs).Count | Should -Be 0
        (Invoke-Tool $src new-script floor-1 05-first).Code | Should -Be 0
        Test-Path -LiteralPath (Get-Path $src 'groups/floor-1/scripts/05-first.ps1') | Should -BeTrue
        (Invoke-Tool $src new-script accounting 20-printers).Code | Should -Be 1
    }

    It 'stops numbering at 90 instead of sorting a 100- script first' {
        $src = New-Source
        Set-Text (Get-Path $src 'groups/accounting/scripts/90-last.ps1') "exit 0`r`n" -Bom
        $r = Invoke-Tool $src new-script accounting more
        $r.Code | Should -Be 1
        $r.Text | Should -Match 'renumber them to make room'
    }

    It 'creates a job in the folder of its schedule, with the Loki label the computer gives it' {
        $src = New-Source
        (Invoke-Tool $src new-job all daily 10-inventory).Code | Should -Be 0
        Read-Text (Get-Path $src 'groups/all/jobs/daily/10-inventory.ps1') | Should -Match ([regex]::Escape('task="all/10-inventory"'))
    }

    It 'creates a job in the folder of its schedule' {
        $src = New-Source
        (Invoke-Tool $src new-job all weekly cleanup).Code | Should -Be 0
        $text = Read-Text (Get-Path $src 'groups/all/jobs/weekly/cleanup.ps1')
        $text | Should -Match 'once a week'
        $text | Should -Match ([regex]::Escape('task="all/cleanup"'))
        (Invoke-Tool $src new-job all monthly cleanup).Code | Should -Be 1
        (Invoke-Tool $src check).Code | Should -Be 0
    }
}

Describe 'sign-in scripts' {
    It 'new-logon makes a numbered sign-in script that parses and names no secret' {
        $src = New-Source
        (Invoke-Tool $src new-logon accounting network-drive).Code | Should -Be 0
        $path = Get-Path $src 'groups/accounting/logon/10-network-drive.ps1'
        Test-Bom $path | Should -BeTrue
        $text = Read-Text $path
        Test-OnlyCrLf $text | Should -BeTrue
        $text | Should -Match 'Sign-in script of group accounting'
        $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errs)
        @($errs).Count | Should -Be 0
        . (Join-Path (Join-Path $script:root 'lib') 'Lang.ps1')
        . (Join-Path (Join-Path $script:root 'lib') 'Groups.ps1')
        (Get-WmScriptSecretNames $text).Count | Should -Be 0
        (Invoke-Tool $src new-logon accounting printers).Code | Should -Be 0
        Test-Path -LiteralPath (Get-Path $src 'groups/accounting/logon/20-printers.ps1') | Should -BeTrue
        (Invoke-Tool $src check).Code | Should -Be 0
    }

    It 'show lists them for a computer and counts them per group' {
        $src = New-Source
        Set-Text (Get-Path $src 'groups/accounting/logon/10-drive.ps1') "exit 0`r`n" -Bom
        Set-Text (Get-Path $src 'groups/all/logon/20-printer.ps1') "exit 0`r`n" -Bom
        $r = Invoke-Tool $src show office-01
        $r.Text | Should -Match 'Sign-in scripts, in this order'
        $r.Text | Should -Match '(?s)groups/all/logon/20-printer\.ps1.*groups/accounting/logon/10-drive\.ps1'
        (Invoke-Tool $src show office-99).Text | Should -Not -Match '10-drive'
        (Invoke-Tool $src show).Text | Should -Match 'accounting\s+2 computers\s+packages: 1\s+scripts: 1\s+jobs: 0\s+sign-in: 1'
        Set-Text (Get-Path $src 'groups/accounting/logon/20-more.ps1') "exit 0`r`n" -Bom
        Remove-Item -LiteralPath (Get-Path $src 'groups/all/logon') -Recurse
        $r = Invoke-Tool $src show
        $r.Text | Should -Match 'accounting\s+2 computers\s+packages: 1\s+scripts: 1\s+jobs: 0\s+sign-in: 2'
        $r.Text | Should -Match 'all\s+every computer\s+packages: 0\s+scripts: 0\s+jobs: 1\s+sign-in: 0'
    }

    It 'check reads them like scripts: syntax, secrets, and a subfolder that is not run' {
        $src = New-Source
        Set-Text (Get-Path $src 'groups/all/logon/10-bad.ps1') "if (`$x {`r`n" -Bom
        $r = Invoke-Tool $src check
        $r.Code | Should -Be 1
        $r.Text | Should -Match 'ERROR: groups/all/logon/10-bad\.ps1, line'
        Set-Text (Get-Path $src 'groups/all/logon/10-bad.ps1') "# wmanager-secrets: 1x`r`nexit 0`r`n" -Bom
        (Invoke-Tool $src check).Text | Should -Match "groups/all/logon/10-bad\.ps1: wmanager-secrets: '1x'"
        Remove-Item -LiteralPath (Get-Path $src 'groups/all/logon/10-bad.ps1')
        Set-Text (Get-Path $src 'groups/all/logon/sub/10-deep.ps1') "exit 0`r`n" -Bom
        $r = Invoke-Tool $src check
        $r.Code | Should -Be 0
        $r.Text | Should -Match 'groups/all/logon/sub/10-deep\.ps1 is not run: sign-in scripts go directly in groups/<group>/logon/'
    }
}

Describe 'startup scripts' {
    It 'new-startup makes a numbered startup script that parses, names no secret and passes check' {
        $src = New-Source
        (Invoke-Tool $src new-startup accounting clean-temp).Code | Should -Be 0
        $path = Get-Path $src 'groups/accounting/startup/10-clean-temp.ps1'
        Test-Bom $path | Should -BeTrue
        $text = Read-Text $path
        Test-OnlyCrLf $text | Should -BeTrue
        $text | Should -Match 'Startup script of group accounting'
        $text | Should -Match 'function Wait-Network'
        $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errs)
        @($errs).Count | Should -Be 0
        . (Join-Path (Join-Path $script:root 'lib') 'Lang.ps1')
        . (Join-Path (Join-Path $script:root 'lib') 'Groups.ps1')
        (Get-WmScriptSecretNames $text).Count | Should -Be 0
        (Invoke-Tool $src new-startup accounting services).Code | Should -Be 0
        Test-Path -LiteralPath (Get-Path $src 'groups/accounting/startup/20-services.ps1') | Should -BeTrue
        (Invoke-Tool $src check).Code | Should -Be 0
    }

    It 'show lists them for a computer and counts them per group' {
        $src = New-Source
        # None yet: (none), not an empty line (the lists stay one object, also when empty)
        $r = Invoke-Tool $src show office-01
        $r.Text | Should -Match 'Sign-in scripts, in this order[^\r\n]*\r?\n  \(none\)'
        $r.Text | Should -Match 'Startup scripts, in this order[^\r\n]*\r?\n  \(none\)'
        Set-Text (Get-Path $src 'groups/accounting/startup/10-clean.ps1') "exit 0`r`n" -Bom
        Set-Text (Get-Path $src 'groups/all/startup/20-check.ps1') "exit 0`r`n" -Bom
        $r = Invoke-Tool $src show office-01
        $r.Text | Should -Match 'Startup scripts, in this order \(at every start of the computer, as SYSTEM\)'
        $r.Text | Should -Match '(?s)groups/all/startup/20-check\.ps1.*groups/accounting/startup/10-clean\.ps1'
        (Invoke-Tool $src show office-99).Text | Should -Not -Match '10-clean'
        $r = Invoke-Tool $src show
        $r.Text | Should -Match 'accounting\s+2 computers\s+packages: 1\s+scripts: 1\s+jobs: 0\s+sign-in: 0\s+startup: 1'
        $r.Text | Should -Match 'all\s+every computer\s+packages: 0\s+scripts: 0\s+jobs: 1\s+sign-in: 0\s+startup: 1'
    }

    It 'check reads them like scripts, refuses run-as in them, and warns about a subfolder that is not run' {
        $src = New-Source
        Set-Text (Get-Path $src 'groups/all/startup/10-bad.ps1') "if (`$x {`r`n" -Bom
        $r = Invoke-Tool $src check
        $r.Code | Should -Be 1
        $r.Text | Should -Match 'ERROR: groups/all/startup/10-bad\.ps1, line'
        Set-Text (Get-Path $src 'groups/all/startup/10-bad.ps1') "# wmanager-run-as: user`r`nexit 0`r`n" -Bom
        $r = Invoke-Tool $src check
        $r.Code | Should -Be 1
        $r.Text | Should -Match 'groups/all/startup/10-bad\.ps1: a startup script always runs as SYSTEM'
        Remove-Item -LiteralPath (Get-Path $src 'groups/all/startup/10-bad.ps1')
        Set-Text (Get-Path $src 'groups/all/startup/sub/10-deep.ps1') "exit 0`r`n" -Bom
        $r = Invoke-Tool $src check
        $r.Code | Should -Be 0
        $r.Text | Should -Match 'groups/all/startup/sub/10-deep\.ps1 is not run: startup scripts go directly in groups/<group>/startup/'
    }
}

Describe 'run-as' {
    It 'check takes user or system, never in a sign-in script, and show marks what runs as each person' {
        $src = New-Source
        Set-Text (Get-Path $src 'groups/all/scripts/30-profile.ps1') "# wmanager-run-as: user`r`nexit 0`r`n" -Bom
        Set-Text (Get-Path $src 'groups/all/jobs/daily/inbox.ps1') "# wmanager-run-as: user`r`nexit 0`r`n" -Bom
        (Invoke-Tool $src check).Code | Should -Be 0
        $r = Invoke-Tool $src show office-01
        $r.Text | Should -Match 'groups/all/scripts/30-profile\.ps1   \(as each signed-in person\)'
        $r.Text | Should -Match 'all/inbox\s+\(groups/all/jobs/daily/inbox\.ps1\)   \(as each signed-in person\)'
        $r.Text | Should -Not -Match '10-power-plan\.ps1   \(as'

        Set-Text (Get-Path $src 'groups/all/scripts/30-profile.ps1') "# wmanager-run-as: admin`r`nexit 0`r`n" -Bom
        $r = Invoke-Tool $src check
        $r.Code | Should -Be 1
        $r.Text | Should -Match "groups/all/scripts/30-profile\.ps1: wmanager-run-as: 'admin' is neither user nor system"
        Set-Text (Get-Path $src 'groups/all/scripts/30-profile.ps1') "# wmanager-run-as: user`r`n" -Bom
        Set-Text (Get-Path $src 'groups/all/logon/10-drive.ps1') "# wmanager-run-as: system`r`nexit 0`r`n" -Bom
        $r = Invoke-Tool $src check
        $r.Code | Should -Be 1
        $r.Text | Should -Match 'groups/all/logon/10-drive\.ps1: a sign-in script always runs as the user who signs in'
    }

    It 'the templates name the option without taking it' {
        $src = New-Source
        (Invoke-Tool $src new-script all profile).Code | Should -Be 0
        (Invoke-Tool $src new-job all daily inbox).Code | Should -Be 0
        Read-Text (Get-Path $src 'groups/all/scripts/10-profile.ps1') | Should -Match 'wmanager-run-as: user'
        (Invoke-Tool $src show office-01).Text | Should -Not -Match 'as each signed-in person'
    }
}

# The tests give -Url as a path and -Zip as the file, so they don't go to GitHub
Describe 'set-version and unset-version' {
    It 'writes version.psd1 for every computer and for a group, and show and check read it' {
        $src = New-Source
        $zip2 = New-Release 'v0.2.0'
        $r = Invoke-Tool $src set-version v0.2.0 -Url 'C:\rel\wmanager-v0.2.0.zip' -Zip $zip2
        $r.Code | Should -Be 0
        $r.Text | Should -Match 'not checked against a SHA256SUMS'   # nothing to compare with: it says so
        $path = Get-Path $src 'version.psd1'
        Test-Bom $path | Should -BeTrue
        $text = Read-Text $path
        Test-OnlyCrLf $text | Should -BeTrue
        $text | Should -Match ([regex]::Escape("Version = 'v0.2.0'"))
        $text | Should -Match ([regex]::Escape("Url     = 'C:\rel\wmanager-v0.2.0.zip'"))
        $text | Should -Match ([regex]::Escape("Sha256  = '$(Get-Sha256 $zip2)'"))

        $zip3 = New-Release 'v0.3.0-rc1'
        $r = Invoke-Tool $src set-version v0.3.0-rc1 pilot -Url 'https://files.example.com/wmanager-v0.3.0-rc1.zip' -Zip $zip3
        $r.Code | Should -Be 0
        $r.Text | Should -Match 'no computer is in group pilot yet'
        (Invoke-Tool $src add-computer OFFICE-07 pilot).Code | Should -Be 0

        $r = Invoke-Tool $src show
        $r.Text | Should -Match 'wmanager version: v0\.2\.0 on every computer; v0\.3\.0-rc1 in group pilot'
        $r.Text | Should -Match 'pilot\s+1 computer.*\(only a wmanager version\)'
        (Invoke-Tool $src show OFFICE-07).Text | Should -Match 'wmanager: v0\.3\.0-rc1 \(group pilot\)'
        (Invoke-Tool $src show OFFICE-01).Text | Should -Match 'wmanager: v0\.2\.0'
        $r = Invoke-Tool $src check
        $r.Code | Should -Be 0
        $r.Text | Should -Not -Match 'pilot'   # a group only for its version needs no folder

        # A new version for the same group replaces its entry
        $zip4 = New-Release 'v0.4.0'
        (Invoke-Tool $src set-version v0.4.0 PILOT -Url 'C:\rel\wmanager-v0.4.0.zip' -Zip $zip4).Code | Should -Be 0
        $text = Read-Text $path
        $text | Should -Not -Match 'v0\.3\.0-rc1'
        ([regex]::Matches($text, 'Version = ')).Count | Should -Be 2
    }

    It 'refuses a release that cannot install itself, another version in the ZIP, a bad name or address, and changes nothing' {
        $src = New-Source
        (Invoke-Tool $src set-version v0.2.0 -Url 'C:\rel\a.zip' -Zip (New-Release 'v0.2.0')).Code | Should -Be 0
        $before = Read-Text (Get-Path $src 'version.psd1')

        $r = Invoke-Tool $src set-version v0.1.0 -Url 'C:\rel\b.zip' -Zip (New-Release 'v0.1.0' -NoSelfInstall)
        $r.Code | Should -Be 1
        $r.Text | Should -Match "can't install itself"
        $r = Invoke-Tool $src set-version v0.3.0 -Url 'C:\rel\c.zip' -Zip (New-Release 'v0.3.0' -Inside 'v0.2.9')
        $r.Code | Should -Be 1
        $r.Text | Should -Match 'the ZIP holds wmanager v0\.2\.9, not v0\.3\.0'
        (Invoke-Tool $src set-version 0.3 -Url 'C:\rel\d.zip' -Zip (New-Release 'v0.3.0')).Code | Should -Be 1
        $r = Invoke-Tool $src set-version v0.3.0 -Url 'http://files.example.com/w.zip' -Zip (New-Release 'v0.3.0')
        $r.Code | Should -Be 1
        $r.Text | Should -Match 'https:// address or a path'
        (Invoke-Tool $src set-version v0.3.0 'bad group' -Url 'C:\rel\e.zip' -Zip (New-Release 'v0.3.0')).Code | Should -Be 1
        (Invoke-Tool $src set-version v0.3.0 -Url 'C:\rel\f.zip' -Zip (Join-Path $TestDrive 'missing.zip')).Code | Should -Be 1

        Read-Text (Get-Path $src 'version.psd1') | Should -Be $before
    }

    It 'drops a group''s version, then the version for every computer, and deletes the empty file' {
        $src = New-Source
        (Invoke-Tool $src set-version v0.2.0 -Url 'C:\rel\a.zip' -Zip (New-Release 'v0.2.0')).Code | Should -Be 0
        (Invoke-Tool $src set-version v0.3.0 pilot -Url 'C:\rel\b.zip' -Zip (New-Release 'v0.3.0')).Code | Should -Be 0
        (Invoke-Tool $src unset-version Pilot).Code | Should -Be 0
        Read-Text (Get-Path $src 'version.psd1') | Should -Not -Match 'pilot'
        (Invoke-Tool $src unset-version pilot).Code | Should -Be 1
        $r = Invoke-Tool $src unset-version
        $r.Code | Should -Be 0
        $r.Text | Should -Match 'Deleted version\.psd1'
        Test-Path -LiteralPath (Get-Path $src 'version.psd1') | Should -BeFalse
        (Invoke-Tool $src unset-version).Code | Should -Be 1
        (Invoke-Tool $src show).Text | Should -Match 'wmanager version: not set'
    }

    It 'fails the check on a version.psd1 the computers would reject, and warns about a group no computer is in' {
        $src = New-Source
        Set-Text (Get-Path $src 'version.psd1') "@{ Version = 'v0.2.0'; Url = 'C:\rel\a.zip'; Sha256 = 'abc' }`r`n"
        $r = Invoke-Tool $src check
        $r.Code | Should -Be 1
        $r.Text | Should -Match 'version\.psd1: Sha256 is not a SHA256'
        (Invoke-Tool $src set-version v0.2.0 -Url 'C:\rel\a.zip' -Zip (New-Release 'v0.2.0')).Text | Should -Match 'fix or delete version\.psd1 first'

        Set-Text (Get-Path $src 'version.psd1') "@{ Groups = @{ nobody = @{ Version = 'v0.2.0'; Url = 'C:\rel\a.zip'; Sha256 = '$('a' * 64)' } } }`r`n"
        $r = Invoke-Tool $src check
        $r.Code | Should -Be 0
        $r.Text | Should -Match 'version\.psd1: no computer is in group nobody'
    }
}

Describe 'library and enable' {
    It 'lists the library and the groups that have its items' {
        $src = New-Source
        $r = Invoke-Tool $src library
        $r.Code | Should -Be 0
        foreach ($name in @('windows-update', 'power', 'defender-hardening', 'network-hardening', 'check-disk-space', 'check-updates', 'check-defender', 'system-report')) {
            $r.Text | Should -Match "(?m)^  $name\s"
        }
        $r.Text | Should -Match 'in groups/all/jobs/daily/system-report\.ps1 \(r1\)'   # the example's copy
    }

    It 'copies a script with the next number and a job into its schedule, as UTF-8 with BOM and CRLF' {
        $src = New-Source
        (Invoke-Tool $src enable windows-update accounting).Code | Should -Be 0
        $path = Get-Path $src 'groups/accounting/scripts/20-windows-update.ps1'
        Test-Bom $path | Should -BeTrue
        $text = Read-Text $path
        Test-OnlyCrLf $text | Should -BeTrue
        $text.TrimStart([char]0xFEFF) | Should -Match '^# wmanager library: windows-update, revision 1'
        (Invoke-Tool $src enable check-disk-space all).Code | Should -Be 0
        Test-Path -LiteralPath (Get-Path $src 'groups/all/jobs/daily/check-disk-space.ps1') | Should -BeTrue
        (Invoke-Tool $src enable check-updates all weekly).Code | Should -Be 0
        Test-Path -LiteralPath (Get-Path $src 'groups/all/jobs/weekly/check-updates.ps1') | Should -BeTrue
        $r = Invoke-Tool $src enable power pilot
        $r.Code | Should -Be 0
        $r.Text | Should -Match 'no computer is in group pilot yet'
    }

    It 'refuses a second copy in the same group, an unknown name, a schedule for a script and a bad schedule' {
        $src = New-Source
        $r = Invoke-Tool $src enable system-report all
        $r.Code | Should -Be 1
        $r.Text | Should -Match 'group all already has system-report'
        (Invoke-Tool $src enable no-such-thing all).Code | Should -Be 1
        (Invoke-Tool $src enable power all daily).Code | Should -Be 1
        (Invoke-Tool $src enable check-defender all monthly).Code | Should -Be 1
        (Invoke-Tool $src enable power 'bad group').Code | Should -Be 1
    }

    It 'passes check with every item enabled, and warns about a copy older than the library' {
        $src = New-Source
        foreach ($name in @('windows-update', 'power', 'defender-hardening', 'network-hardening', 'check-disk-space', 'check-updates', 'check-defender', 'network-drive')) {
            (Invoke-Tool $src enable $name all).Code | Should -Be 0
        }
        $r = Invoke-Tool $src check
        $r.Code | Should -Be 0
        $r.Text | Should -Match 'Checked \d+ files: 0 errors, 0 warnings'
        $path = Get-Path $src 'groups/all/scripts/20-power.ps1'
        Set-Text $path ((Read-Text $path).Replace('# wmanager library: power, revision 1', '# wmanager library: power, revision 0')) -Bom
        $r = Invoke-Tool $src check
        $r.Code | Should -Be 0
        $r.Text | Should -Match 'groups/all/scripts/20-power\.ps1 is power revision 0; the library has revision 1'
    }

    It 'warns when a computer gets the same item from two of its groups' {
        $src = New-Source
        (Invoke-Tool $src enable power all).Code | Should -Be 0
        (Invoke-Tool $src enable power accounting).Code | Should -Be 0
        $r = Invoke-Tool $src check
        $r.Code | Should -Be 0
        $r.Text | Should -Match 'a computer in groups all, accounting runs power twice'
        ([regex]::Matches($r.Text, 'runs power twice')).Count | Should -Be 1   # once, not per computer
    }

    It 'names every library file after its header, once' {
        $names = @{}
        foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $script:root 'library') -Recurse -Filter '*.ps1')) {
            $first = ([IO.File]::ReadAllLines($f.FullName)[0]).TrimStart([char]0xFEFF)
            $first | Should -Match '^# wmanager library: ([A-Za-z0-9._-]+), revision [0-9]+$'
            $null = $first -match '^# wmanager library: ([A-Za-z0-9._-]+),'
            $Matches[1] | Should -Be $f.BaseName
            $names.ContainsKey($f.BaseName) | Should -BeFalse
            $names[$f.BaseName] = $true
        }
        $names.Count | Should -Be 9
    }

    It 'puts the network-drive sign-in script in the group''s logon folder; its shared login is off until one line changes' {
        $src = New-Source
        $r = Invoke-Tool $src library
        $r.Text | Should -Match '(?s)Sign-in scripts \(at every sign-in.*network-drive\s+r1'
        (Invoke-Tool $src enable network-drive accounting).Code | Should -Be 0
        $path = Get-Path $src 'groups/accounting/logon/10-network-drive.ps1'
        Test-Bom $path | Should -BeTrue
        Test-OnlyCrLf (Read-Text $path) | Should -BeTrue
        (Invoke-Tool $src library).Text | Should -Match 'in groups/accounting/logon/10-network-drive\.ps1 \(r1\)'
        (Invoke-Tool $src enable network-drive accounting).Code | Should -Be 1
        (Invoke-Tool $src enable network-drive all daily).Code | Should -Be 1
        (Invoke-Tool $src show office-01).Text | Should -Match 'groups/accounting/logon/10-network-drive\.ps1'
        . (Join-Path (Join-Path $script:root 'lib') 'Lang.ps1')
        . (Join-Path (Join-Path $script:root 'lib') 'Groups.ps1')
        (Get-WmScriptSecretNames (Read-Text $path)).Count | Should -Be 0
        $shared = (Read-Text $path).Replace('# off: wmanager-secrets:', '# wmanager-secrets:')
        $names = Get-WmScriptSecretNames $shared
        $names | Should -Be @('ShareUser', 'SharePassword')
        Set-Text $path $shared -Bom
        (Invoke-Tool $src check).Code | Should -Be 0
    }

    It 'keeps the example system report the same as the library''s' {
        $lib = Join-Path (Join-Path (Join-Path (Join-Path $script:root 'library') 'jobs') 'daily') 'system-report.ps1'
        $example = Get-Path (Join-Path (Join-Path $script:root 'examples') 'management') 'groups/all/jobs/daily/system-report.ps1'
        (Read-Text $example) | Should -Be (Read-Text $lib)
    }
}
