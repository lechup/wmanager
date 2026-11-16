# Tests for the update schedule (lib\Task.ps1) and the debloat rerun option (lib\Debloat.ps1). To run (Pester 5):
#   Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser
#   Invoke-Pester .\tests

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $root 'lib\Common.ps1')
    . (Join-Path $root 'lib\Debloat.ps1')
    . (Join-Path $root 'lib\Task.ps1')
}

Describe 'New-WmUpdateTrigger' {
    It 'runs every day at 12:00 without UpdateDays and UpdateTime' {
        $t = New-WmUpdateTrigger @{}
        [int]$t.DaysOfWeek | Should -Be 127
        ([datetime]$t.StartBoundary).ToString('HH:mm') | Should -Be '12:00'
    }

    It 'follows UpdateDays and UpdateTime from the configuration' {
        $t = New-WmUpdateTrigger @{ UpdateDays = @('Monday', 'Thursday'); UpdateTime = '07:30' }
        [int]$t.DaysOfWeek | Should -Be (Get-WmDaysMask @('Monday', 'Thursday'))
        ([datetime]$t.StartBoundary).ToString('HH:mm') | Should -Be '07:30'
    }

    It 'gets every day from the example configuration' {
        $example = Import-PowerShellDataFile (Join-Path $root 'provision.config.example.psd1')
        [int](New-WmUpdateTrigger $example).DaysOfWeek | Should -Be 127
    }
}

Describe 'Format-WmUpdateDays' {
    It 'says every day for all seven days, in any order, in the language of the screen' {
        $text = Format-WmUpdateDays @('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')
        Get-WmText -Key 'test.days' -Arguments @($text) -English | Should -Be '[test.days] every day'
        Initialize-WmLanguage -Lang 'pl'
        try { Get-WmText -Key $text.Key | Should -Be 'codziennie' } finally { Initialize-WmLanguage -Lang 'en' }
    }

    It 'lists the days otherwise' {
        $text = Format-WmUpdateDays @('Monday', 'Friday')
        Get-WmText -Key $text.Key -Arguments $text.Arguments | Should -Be 'Monday, Friday'
    }
}

Describe 'Test-WmRerunDebloat' {
    It 'is on by default' {
        Test-WmRerunDebloat @{} | Should -BeTrue
    }

    It 'reads RerunDebloat and the older RerunDebloatWeekly, the new name first' {
        Test-WmRerunDebloat @{ RerunDebloat = $false } | Should -BeFalse
        Test-WmRerunDebloat @{ RerunDebloatWeekly = $false } | Should -BeFalse
        Test-WmRerunDebloat @{ RerunDebloat = $true; RerunDebloatWeekly = $false } | Should -BeTrue
    }
}
