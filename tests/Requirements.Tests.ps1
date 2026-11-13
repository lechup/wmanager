# Tests for the choco-reqs.txt parser. To run (Pester 5):
#   Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser
#   Invoke-Pester .\tests

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $root 'lib\Common.ps1')
    . (Join-Path $root 'lib\Choco.ps1')
}

Describe 'ConvertFrom-WmRequirements' {
    It 'reads a name without a version as latest' {
        $r = ConvertFrom-WmRequirements -Text 'googlechrome'
        $r.Count | Should -Be 1
        $r[0].Name | Should -Be 'googlechrome'
        $r[0].Version | Should -BeNullOrEmpty
        $r[0].Pinned | Should -BeFalse
        $r[0].NoUpdate | Should -BeFalse
    }

    It 'treats @latest as no version' {
        $r = ConvertFrom-WmRequirements -Text 'libreoffice-fresh@latest'
        $r[0].Version | Should -BeNullOrEmpty
        $r[0].Pinned | Should -BeFalse
    }

    It 'pins the version given after @' {
        $r = ConvertFrom-WmRequirements -Text '7zip@24.8.0'
        $r[0].Name | Should -Be '7zip'
        $r[0].Version | Should -Be '24.8.0'
        $r[0].Pinned | Should -BeTrue
    }

    It 'recognizes !noupdate' {
        $r = ConvertFrom-WmRequirements -Text 'firefox !noupdate'
        $r[0].NoUpdate | Should -BeTrue
    }

    It 'skips comments and empty lines' {
        $text = "# header`r`n`r`nvlc   # player`n  `n7zip"
        $r = ConvertFrom-WmRequirements -Text $text
        $r.Count | Should -Be 2
        $r[0].Name | Should -Be 'vlc'
        $r[1].Name | Should -Be '7zip'
    }

    It 'passes parameters after | without the outer quotes' {
        $r = ConvertFrom-WmRequirements -Text 'vlc | --params "/NoDesktopShortcut /Language:pl"'
        $r[0].ExtraArgs | Should -Be @('--params', '/NoDesktopShortcut /Language:pl')
    }

    It 'returns an empty list for an empty file' {
        $r = ConvertFrom-WmRequirements -Text "# tylko komentarz`n"
        $r.Count | Should -Be 0
    }

    It 'rejects an unknown option' {
        { ConvertFrom-WmRequirements -Text 'vlc !cos' } | Should -Throw
    }

    It 'rejects a duplicate package' {
        { ConvertFrom-WmRequirements -Text "vlc`nVLC@3.0.21" } | Should -Throw
    }

    It 'rejects an invalid version' {
        { ConvertFrom-WmRequirements -Text 'vlc@abc' } | Should -Throw
    }

    It 'reads the bundled choco-reqs.txt without errors' {
        $text = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'choco-reqs.txt') -Raw -Encoding UTF8
        $r = ConvertFrom-WmRequirements -Text $text
        $r.Count | Should -BeGreaterThan 0
        ($r | Where-Object Name -eq 'googlechrome').NoUpdate | Should -BeTrue
    }
}

Describe 'Format-WmChocoArgs' {
    It 'masks the value after -p and --password' {
        Format-WmChocoArgs @('source', 'add', '-n', 'company', '-u', 'bob', '-p', 'S3cret') | Should -Be 'source add -n company -u bob -p ***'
        Format-WmChocoArgs @('source', 'add', '--password', 'S3cret') | Should -Be 'source add --password ***'
    }

    It 'masks the value in the --flag=value form' {
        Format-WmChocoArgs @('apikey', '--api-key=abc123') | Should -Be 'apikey --api-key=***'
    }

    It 'leaves other arguments unchanged' {
        Format-WmChocoArgs @('upgrade', 'vlc', '--version', '3.0.21', '-y') | Should -Be 'upgrade vlc --version 3.0.21 -y'
    }
}

Describe 'ConvertTo-WmJsonString' {
    It 'escapes quotes, backslashes and newlines' {
        ConvertTo-WmJsonString ('a"b\c' + "`n") | Should -Be '"a\"b\\c\n"'
    }
}
