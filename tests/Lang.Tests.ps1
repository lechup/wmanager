# Tests for the messages in the user's language (lib\Lang.ps1) and for the catalogs (lang\<code>\*.psd1).
# Platform-neutral: they run in Windows PowerShell 5.1 and in PowerShell 7 on Linux. To run (Pester 5):
#   Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser
#   Invoke-Pester .\tests

BeforeDiscovery {
    # the languages, for -ForEach (it needs them while Pester discovers the tests)
    . (Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib') 'Lang.ps1')
    $otherLanguages = @($WmLanguages | Where-Object { $_ -ne 'en' })
}

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path $root 'lib') 'Lang.ps1')
    # {0}, {1:N0}... of a text, as a sorted list of the indexes
    function Get-Placeholders { param([string]$Text) @([regex]::Matches($Text, '\{(\d+)(?:[,:][^}]*)?\}') | ForEach-Object { [int]$_.Groups[1].Value } | Sort-Object -Unique) }
}

Describe 'Resolve-WmLanguage' {
    BeforeEach { $script:saved = $env:WMANAGER_LANG; $env:WMANAGER_LANG = $null }
    AfterEach { $env:WMANAGER_LANG = $script:saved }

    It 'takes -Lang first, then WMANAGER_LANG, then the display language' {
        $env:WMANAGER_LANG = 'de'
        Resolve-WmLanguage 'pl' | Should -Be 'pl'
        Resolve-WmLanguage '' | Should -Be 'de'
        $env:WMANAGER_LANG = $null
        $ui = ConvertTo-WmLanguageCode ([Globalization.CultureInfo]::CurrentUICulture.Name)
        Resolve-WmLanguage '' | Should -Be $(if ($ui) { $ui } else { 'en' })
    }

    It 'understands region and encoding suffixes and skips a language it does not have' {
        Resolve-WmLanguage 'pl-PL' | Should -Be 'pl'
        Resolve-WmLanguage 'de_DE.UTF-8' | Should -Be 'de'
        $env:WMANAGER_LANG = 'cs'
        Resolve-WmLanguage 'xx' | Should -Be 'cs'
        ConvertTo-WmLanguageCode 'ja-JP' | Should -BeNullOrEmpty
    }
}

Describe 'Get-WmText' {
    BeforeAll {
        # catalogs made for these tests, so they don't depend on wmanager's own messages
        $fake = Join-Path $TestDrive 'fake'
        foreach ($code in 'en', 'pl') { New-Item -ItemType Directory -Force -Path (Join-Path (Join-Path $fake 'lang') $code) | Out-Null }
        $enText = "@{ 'common.yes_words' = 'y|yes'; 'common.no_words' = 'n|no'; 'test.hello' = 'Hello, {0}'; 'test.reason' = 'Stopped: {0}'; 'test.only_english' = 'Only in English' }"
        $plText = "@{ 'common.yes_words' = 't|tak'; 'common.no_words' = 'n|nie'; 'test.hello' = 'Cześć, {0}'; 'test.reason' = 'Przerwano: {0}' }"
        [IO.File]::WriteAllText((Join-Path $fake 'lang\en\Test.psd1'.Replace('\', [IO.Path]::DirectorySeparatorChar)), $enText, (New-Object System.Text.UTF8Encoding($true)))
        [IO.File]::WriteAllText((Join-Path $fake 'lang\pl\Test.psd1'.Replace('\', [IO.Path]::DirectorySeparatorChar)), $plText, (New-Object System.Text.UTF8Encoding($true)))
        Initialize-WmLanguage -Lang 'pl' -Root $fake
    }
    AfterAll { Initialize-WmLanguage -Lang 'en' -Root $root }

    It 'gives the chosen language, English with -English, and English for a key the language lacks' {
        Get-WmText 'common.yes_words' | Should -Be 't|tak'
        Get-WmText 'common.yes_words' -English | Should -Be 'y|yes'
        Get-WmText 'test.only_english' | Should -Be 'Only in English'
    }

    It 'fills the arguments and renders a nested text in the same language' {
        Get-WmText 'test.hello' @('Ala') | Should -Be 'Cześć, Ala'
        $inner = New-WmText 'test.hello' @('Ala')
        Get-WmText 'test.reason' @($inner) | Should -Be 'Przerwano: Cześć, Ala'
        Get-WmText 'test.reason' @($inner) -English | Should -Be 'Stopped: Hello, Ala'
    }

    It 'shows an unknown key instead of hiding it' {
        Get-WmText 'no.such.key' @('x') | Should -Be '[no.such.key] x'
    }

    It 'carries the text in an error: English message, either language on request' {
        $err = $null
        try { throw (New-WmError 'test.hello' @('Ala')) } catch { $err = $_ }
        $err.Exception.Message | Should -Be 'Hello, Ala'
        Get-WmText 'test.reason' @(Get-WmErrorText $err) | Should -Be 'Przerwano: Cześć, Ala'
        Format-WmErrorText $err | Should -Be 'Cześć, Ala'
        Format-WmErrorText $err -English | Should -Be 'Hello, Ala'
        $plain = $null
        try { throw 'plain' } catch { $plain = $_ }
        Get-WmErrorText $plain | Should -Be 'plain'
    }

    It 'reads yes and no in the chosen language and in English' {
        ConvertFrom-WmYesNo 'T' | Should -BeTrue
        ConvertFrom-WmYesNo 'yes' | Should -BeTrue
        ConvertFrom-WmYesNo 'nie' | Should -BeFalse
        ConvertFrom-WmYesNo 'maybe' | Should -BeNullOrEmpty
    }
}

Describe 'Catalogs' {
    BeforeAll {
        $script:en = Import-WmCatalog (Join-Path (Join-Path $root 'lang') 'en')
    }

    It 'has every key of English, and no other, in <_>, with the same placeholders' -ForEach $otherLanguages {
        $folder = Join-Path (Join-Path $root 'lang') $_
        $catalog = Import-WmCatalog $folder
        $missing = @($script:en.Keys | Where-Object { -not $catalog.ContainsKey($_) })
        $extra = @($catalog.Keys | Where-Object { -not $script:en.ContainsKey($_) })
        $missing | Should -BeNullOrEmpty -Because "missing in lang\$_"
        $extra | Should -BeNullOrEmpty -Because "extra in lang\$_"
        foreach ($key in $script:en.Keys) {
            (Get-Placeholders $catalog[$key]) -join ',' | Should -Be ((Get-Placeholders $script:en[$key]) -join ',') -Because "$_ $key"
        }
    }

    It 'formats every text of every language without an error' {
        foreach ($code in $script:WmLanguages) {
            $catalog = Import-WmCatalog (Join-Path (Join-Path $root 'lang') $code)
            foreach ($key in $catalog.Keys) {
                $values = [object[]]@(0..9 | ForEach-Object { "a$_" })
                { [string]::Format($catalog[$key], $values) } | Should -Not -Throw -Because "$code $key"
            }
        }
    }
}
