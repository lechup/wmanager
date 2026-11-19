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

Describe 'Find-WmConfig' {
    BeforeEach {
        $script:dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:dir | Out-Null
        function New-Config {
            param([string]$Rel)
            $file = Join-Path $script:dir $Rel
            New-Item -ItemType File -Force -Path $file -Value '@{}' | Out-Null
            return $file
        }
        Mock Write-Host { }
    }

    It 'takes provision.config.psd1 next to the script first, without a question' {
        $own = New-Config 'provision.config.psd1'
        $null = New-Config 'configs\acme\provision.config.psd1'
        $null = New-Config 'configs\beta\provision.config.psd1'
        Mock Read-Host { throw 'asked' }
        Find-WmConfig -Folder $script:dir | Should -Be $own
    }

    It 'asks which company, by number or by name, until the answer is one of them' {
        $acme = New-Config 'configs\acme\provision.config.psd1'
        $beta = New-Config 'configs\beta\provision.config.psd1'
        New-Item -ItemType Directory -Path (Join-Path $script:dir 'configs\empty') | Out-Null   # no configuration: not offered
        Mock Test-WmInteractive { $true }
        $script:answers = [Collections.Queue]@('3', 'gamma', ' 2 ')
        Mock Read-Host { $script:answers.Dequeue() }
        Find-WmConfig -Folder $script:dir | Should -Be $beta
        Should -Invoke Read-Host -Times 3 -Exactly
        $script:answers = [Collections.Queue]@('acme')
        Find-WmConfig -Folder $script:dir | Should -Be $acme
    }

    It 'takes the only company without a question, and a folder of configurations without configs\ too' {
        $only = New-Config 'acme\provision.config.psd1'
        Mock Read-Host { throw 'asked' }
        Find-WmConfig -Folder $script:dir | Should -Be $only
        (@(Get-WmCompanyConfigs $script:dir).Name -join ',') | Should -Be 'acme'
    }

    It 'returns nothing for a folder without configurations' {
        New-Item -ItemType Directory -Path (Join-Path $script:dir 'configs\acme') | Out-Null
        Find-WmConfig -Folder $script:dir | Should -BeNullOrEmpty
    }

    It 'does not guess the company when nobody can answer' {
        $null = New-Config 'configs\acme\provision.config.psd1'
        $null = New-Config 'configs\beta\provision.config.psd1'
        Mock Test-WmInteractive { $false }
        { Find-WmConfig -Folder $script:dir } | Should -Throw '*several companies*-ConfigPath*'
        Mock Test-WmInteractive { $true }
        Mock Read-Host { $null }   # the end of redirected input
        { Find-WmConfig -Folder $script:dir } | Should -Throw '*several companies*'
    }
}
