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

    It 'passes the warnings of the script block on' {
        $w = @()
        $null = Invoke-WmTimeLimited -TimeoutSeconds 60 -ScriptBlock { Write-Warning 'only one per day' } -WarningVariable w -WarningAction SilentlyContinue
        @($w).Count | Should -Be 1
        "$($w[0])" | Should -Be 'only one per day'
    }

    It 'stops waiting after the time limit even in a call PowerShell cannot interrupt, and leaves nothing behind' {
        $temp = @(Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter 'wmanager-run-*').Count
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $caught = $null
        # a blocking .NET call, like the WMI call to a stuck service: Stop-Job would wait for it
        try { Invoke-WmTimeLimited -TimeoutSeconds 3 -ScriptBlock { [System.Threading.Thread]::Sleep(120000) } } catch { $caught = $_ }
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 30
        $caught | Should -Not -BeNullOrEmpty
        (Get-WmErrorText $caught).Key | Should -Be 'common.timed_out'
        Format-WmErrorText $caught -English | Should -Be 'no result after 3 s; stopped waiting'
        @(Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter 'wmanager-run-*').Count | Should -Be $temp
        @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object { $_.CommandLine -like '*wmanager-run-*' }).Count | Should -Be 0
    }

    It 'refuses a time limit that would not limit anything' {
        { Invoke-WmTimeLimited -TimeoutSeconds 0 -ScriptBlock { 1 } } | Should -Throw
        { Invoke-WmTimeLimited -TimeoutSeconds -1 -ScriptBlock { 1 } } | Should -Throw
    }
}
