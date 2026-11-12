# Testy parsera choco-reqs.txt. Uruchomienie (Pester 5):
#   Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser
#   Invoke-Pester .\tests

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $root 'lib\Common.ps1')
    . (Join-Path $root 'lib\Choco.ps1')
}

Describe 'ConvertFrom-WmRequirements' {
    It 'czyta nazwę bez wersji jako najnowszą' {
        $r = ConvertFrom-WmRequirements -Text 'googlechrome'
        $r.Count | Should -Be 1
        $r[0].Name | Should -Be 'googlechrome'
        $r[0].Version | Should -BeNullOrEmpty
        $r[0].Pinned | Should -BeFalse
        $r[0].NoUpdate | Should -BeFalse
    }

    It 'traktuje @latest jak brak wersji' {
        $r = ConvertFrom-WmRequirements -Text 'libreoffice-fresh@latest'
        $r[0].Version | Should -BeNullOrEmpty
        $r[0].Pinned | Should -BeFalse
    }

    It 'przypina wersję podaną po @' {
        $r = ConvertFrom-WmRequirements -Text '7zip@24.8.0'
        $r[0].Name | Should -Be '7zip'
        $r[0].Version | Should -Be '24.8.0'
        $r[0].Pinned | Should -BeTrue
    }

    It 'rozpoznaje !noupdate' {
        $r = ConvertFrom-WmRequirements -Text 'firefox !noupdate'
        $r[0].NoUpdate | Should -BeTrue
    }

    It 'pomija komentarze i puste linie' {
        $text = "# nagłówek`r`n`r`nvlc   # odtwarzacz`n  `n7zip"
        $r = ConvertFrom-WmRequirements -Text $text
        $r.Count | Should -Be 2
        $r[0].Name | Should -Be 'vlc'
        $r[1].Name | Should -Be '7zip'
    }

    It 'przekazuje parametry po znaku | bez zewnętrznych cudzysłowów' {
        $r = ConvertFrom-WmRequirements -Text 'vlc | --params "/NoDesktopShortcut /Language:pl"'
        $r[0].ExtraArgs | Should -Be @('--params', '/NoDesktopShortcut /Language:pl')
    }

    It 'zwraca pustą listę dla pustego pliku' {
        $r = ConvertFrom-WmRequirements -Text "# tylko komentarz`n"
        $r.Count | Should -Be 0
    }

    It 'odrzuca nieznaną opcję' {
        { ConvertFrom-WmRequirements -Text 'vlc !cos' } | Should -Throw
    }

    It 'odrzuca zduplikowaną paczkę' {
        { ConvertFrom-WmRequirements -Text "vlc`nVLC@3.0.21" } | Should -Throw
    }

    It 'odrzuca niepoprawną wersję' {
        { ConvertFrom-WmRequirements -Text 'vlc@abc' } | Should -Throw
    }

    It 'czyta dołączony choco-reqs.txt bez błędów' {
        $text = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'choco-reqs.txt') -Raw -Encoding UTF8
        $r = ConvertFrom-WmRequirements -Text $text
        $r.Count | Should -BeGreaterThan 0
        ($r | Where-Object Name -eq 'googlechrome').NoUpdate | Should -BeTrue
    }
}

Describe 'ConvertTo-WmJsonString' {
    It 'escapuje cudzysłowy, backslash i nowe linie' {
        ConvertTo-WmJsonString ('a"b\c' + "`n") | Should -Be '"a\"b\\c\n"'
    }
}
