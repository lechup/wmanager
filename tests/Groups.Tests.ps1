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
        $r.Text | Should -Match 'give the number yourself'
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
