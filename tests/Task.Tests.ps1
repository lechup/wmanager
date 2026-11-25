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

    It 'keeps its time in local time, without a UTC offset (which would move it an hour when the clocks change)' {
        $t = New-WmUpdateTrigger @{ UpdateTime = '07:30' }
        $t.StartBoundary | Should -Match '^\d{4}-\d{2}-\d{2}T07:30:00$'
        Get-WmTriggerTime $t | Should -Be '07:30'
    }
}

Describe 'Get-WmTriggerTime' {
    It 'reads the local time of a trigger, and none from one with a UTC offset, so that it is written again' {
        Get-WmTriggerTime ([pscustomobject]@{ StartBoundary = '2026-11-25T18:00:00' }) | Should -Be '18:00'
        Get-WmTriggerTime ([pscustomobject]@{ StartBoundary = '2026-11-25T18:00:00.123' }) | Should -Be '18:00'
        Get-WmTriggerTime ([pscustomobject]@{ StartBoundary = '2026-11-25T18:00:00+01:00' }) | Should -Be ''
        Get-WmTriggerTime ([pscustomobject]@{ StartBoundary = '2026-11-25T17:00:00Z' }) | Should -Be ''
        Get-WmTriggerTime ([pscustomobject]@{ StartBoundary = $null }) | Should -Be ''
        # As New-ScheduledTaskTrigger writes it
        $at = [datetime]::ParseExact('18:00', 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)
        Get-WmTriggerTime (New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At $at) | Should -Be ''
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
