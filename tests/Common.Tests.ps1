# Tests for the shared helpers in lib\Common.ps1. To run (Pester 5):
#   Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser
#   Invoke-Pester .\tests

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $root 'lib\Common.ps1')
    Initialize-WmLanguage -Lang 'en'
}

Describe 'Invoke-WmTimeLimited' {
    It 'returns the output of the script block, with its arguments' {
        Invoke-WmTimeLimited -TimeoutSeconds 60 -ArgumentList @(2, 3) -ScriptBlock { param($a, $b) $a * $b } | Should -Be 6
    }

    It 'throws the error of the script block' {
        { Invoke-WmTimeLimited -TimeoutSeconds 60 -ScriptBlock { throw 'VSS said no' } } | Should -Throw '*VSS said no*'
    }

    It 'stops waiting after the time limit, with a text to translate, and leaves no job behind' {
        $before = @(Get-Job).Count
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $caught = $null
        try { Invoke-WmTimeLimited -TimeoutSeconds 2 -ScriptBlock { Start-Sleep -Seconds 60 } } catch { $caught = $_ }
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 30
        $caught | Should -Not -BeNullOrEmpty
        (Get-WmErrorText $caught).Key | Should -Be 'common.timed_out'
        Format-WmErrorText $caught -English | Should -Be 'no result after 1 min; stopped waiting'
        @(Get-Job).Count | Should -Be $before
    }
}
