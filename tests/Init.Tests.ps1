# Tests for the configuration wizard (lib\Init.ps1). They run in Windows PowerShell 5.1 and PowerShell 7, with the
# English messages, whatever the language of the computer.
# To run (Pester 5):
#   Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser
#   Invoke-Pester .\tests

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path $root 'lib') 'Lang.ps1')
    . (Join-Path (Join-Path $root 'lib') 'Init.ps1')
    Initialize-WmLanguage -Lang 'en' -Root $root
    $script:example = [IO.File]::ReadAllText((Join-Path $root 'provision.config.example.psd1'))

    function Import-TestConfig {
        param([string]$Text)
        $file = Join-Path $TestDrive ('c' + [guid]::NewGuid().ToString('N') + '.psd1')
        Write-WmConfigFile -Path $file -Text $Text
        return Import-PowerShellDataFile -LiteralPath $file
    }
}

Describe 'Set-WmConfigText' {
    It 'changes the values the wizard asks for and leaves the rest of the example as it was' {
        $t = $script:example
        $t = Set-WmConfigText $t 'UpdateTime' (ConvertTo-WmPsdString '07:30')
        $t = Set-WmConfigText $t 'UpdateDays' (ConvertTo-WmPsdArray @('Monday', 'Friday'))
        $t = Set-WmConfigText $t 'LokiUrl' (ConvertTo-WmPsdString 'https://logs.example')
        $t = Set-WmConfigText $t 'LokiToken' (ConvertTo-WmPsdString "glc_it's")
        $t = Set-WmConfigText $t 'Source' (ConvertTo-WmPsdString 'https://example/src')
        $t = Set-WmConfigText $t 'SourceId' (ConvertTo-WmPsdString 'abcdefgh-1234')
        $t = Set-WmConfigText $t 'Certificate' (ConvertTo-WmPsdString 'org.cer')
        $c = Import-TestConfig $t
        $c.UpdateTime | Should -Be '07:30'
        $c.UpdateDays | Should -Be @('Monday', 'Friday')
        $c.LokiUrl | Should -Be 'https://logs.example'
        $c.LokiToken | Should -Be "glc_it's"
        $c.Management.Source | Should -Be 'https://example/src'
        $c.Management.SourceId | Should -Be 'abcdefgh-1234'
        $c.Management.Certificate | Should -Be 'org.cer'
        # untouched: the package list sources and the Chocolatey sources, whose names also end in "Sources"
        $e = Import-TestConfig $script:example
        $c.ReqsSources | Should -Be $e.ReqsSources
        $c.ChocolateySources.Count | Should -Be $e.ChocolateySources.Count
        $c.RemoveAppx | Should -Be $e.RemoveAppx
        $t | Should -Match '# --- Logs and monitoring'
    }

    It 'replaces a value set before, also one with doubled quotes' {
        $t = Set-WmConfigText $script:example 'LokiToken' (ConvertTo-WmPsdString "a'b")
        $t = Set-WmConfigText $t 'LokiToken' (ConvertTo-WmPsdString 'new')
        (Import-TestConfig $t).LokiToken | Should -Be 'new'
    }

    It 'refuses a setting that is not in the file' {
        { Set-WmConfigText $script:example 'NoSuchSetting' "'x'" } | Should -Throw '*NoSuchSetting*'
    }

    It 'writes typographic quotes, which also end a PowerShell string, so the file stays valid' {
        $value = "O" + [char]0x2019 + "Brien " + [char]0x2018 + "x" + [char]0x201B + "'"
        (Import-TestConfig (Set-WmConfigText $script:example 'LokiToken' (ConvertTo-WmPsdString $value))).LokiToken | Should -Be $value
    }
}

Describe 'Get-WmConfigTextProblems' {
    It 'finds nothing in the example and names what an older or hand-edited file lacks' {
        $names = @('UpdateTime', 'UpdateDays', 'Source', 'SourceId', 'Certificate')
        @(Get-WmConfigTextProblems -Text $script:example -Names $names).Count | Should -Be 0
        $old = "@{`n    UpdateTime = '12:00'`n    UpdateDays = @(`n        'Monday'`n    )`n}"
        Get-WmConfigTextProblems -Text $old -Names $names | Should -Be @('UpdateDays', 'Source', 'SourceId', 'Certificate')
    }
}

Describe 'Get-WmSigningCertificateProblem' {
    BeforeAll {
        # Certificates made here, public part only (as a .cer file has it)
        function New-TestCertificate {
            param([switch]$CodeSigning, [switch]$Authority, [switch]$KeepPrivateKey)
            $req = New-Object System.Security.Cryptography.X509Certificates.CertificateRequest -ArgumentList 'CN=wmanager test',
                ([System.Security.Cryptography.RSA]::Create(2048)), ([System.Security.Cryptography.HashAlgorithmName]::SHA256),
                ([System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
            $req.CertificateExtensions.Add((New-Object System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension -ArgumentList ([bool]$Authority), $false, 0, $true))
            if ($CodeSigning) {
                $oids = New-Object System.Security.Cryptography.OidCollection
                [void]$oids.Add((New-Object System.Security.Cryptography.Oid -ArgumentList '1.3.6.1.5.5.7.3.3'))
                $req.CertificateExtensions.Add((New-Object System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension -ArgumentList $oids, $false))
            }
            $cert = $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(30))
            if ($KeepPrivateKey) { return $cert }
            return New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (, $cert.Export('Cert'))
        }
    }

    It 'accepts a public code signing certificate' {
        Get-WmSigningCertificateProblem (New-TestCertificate -CodeSigning) | Should -BeNullOrEmpty
    }

    It 'refuses a private key, an authority and a certificate without Code Signing' {
        Get-WmSigningCertificateProblem (New-TestCertificate -CodeSigning -KeepPrivateKey) | Should -BeLike '*private key*'
        Get-WmSigningCertificateProblem (New-TestCertificate -CodeSigning -Authority) | Should -BeLike '*(CA)*'
        Get-WmSigningCertificateProblem (New-TestCertificate) | Should -BeLike '*Code Signing*'
    }

    It 'reads a .cer file and gives nothing for a file that is not a certificate' {
        $cer = Join-Path $TestDrive 'sign.cer'
        [IO.File]::WriteAllBytes($cer, (New-TestCertificate -CodeSigning).RawData)
        (Import-WmCertificateFile $cer).Subject | Should -Be 'CN=wmanager test'
        $txt = Join-Path $TestDrive 'not.cer'
        Set-Content -LiteralPath $txt -Value 'not a certificate'
        Import-WmCertificateFile $txt | Should -BeNullOrEmpty
    }
}

Describe 'Write-WmConfigFile' {
    It 'writes UTF-8 with a BOM and CRLF line ends' {
        $file = Join-Path $TestDrive 'out.psd1'
        Write-WmConfigFile -Path $file -Text "@{`n    A = 'ż'`n}`n"
        $bytes = [IO.File]::ReadAllBytes($file)
        $bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
        [Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3) | Should -Be "@{`r`n    A = 'ż'`r`n}`r`n"
    }
}

Describe 'Answer checks' {
    It 'accepts only HH:mm times' {
        Test-WmUpdateTime '12:00' | Should -BeTrue
        Test-WmUpdateTime '07:05' | Should -BeTrue
        foreach ($t in @('7:00', '24:00', '12:60', '12.00', '')) { Test-WmUpdateTime $t | Should -BeFalse -Because $t }
    }

    It 'turns the days choice into day names and back' {
        @(Get-WmUpdateDaysChoice 'd').Count | Should -Be 7
        @(Get-WmUpdateDaysChoice ' W ') | Should -Be @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday')
        @(Get-WmUpdateDaysChoice 'm') | Should -Be @('Monday')
        @(Get-WmUpdateDaysChoice 'x').Count | Should -Be 0
        Get-WmUpdateDaysLabel @(Get-WmUpdateDaysChoice 'd') | Should -Be 'd'
        Get-WmUpdateDaysLabel @(Get-WmUpdateDaysChoice 'w') | Should -Be 'w'
        Get-WmUpdateDaysLabel @('Monday') | Should -Be 'm'
        Get-WmUpdateDaysLabel @('Monday', 'Friday') | Should -Be ''
        Get-WmUpdateDaysLabel @() | Should -Be ''
    }

    It 'still takes the earlier letters c, r and p' {
        @(Get-WmUpdateDaysChoice 'c').Count | Should -Be 7
        @(Get-WmUpdateDaysChoice ' R ') | Should -Be @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday')
        @(Get-WmUpdateDaysChoice 'p') | Should -Be @('Monday')
    }

    It 'checks the ping key, the source identifier and the source' {
        Test-WmPingKey 'abcdefghijklmnopqrstu_' | Should -BeTrue
        Test-WmPingKey 'short' | Should -BeFalse
        Test-WmSourceId 'a5c9f541-8f81-47ef-a575-99a1b6679e38' | Should -BeTrue
        Test-WmSourceId 'bad id' | Should -BeFalse
        Test-WmManagementSource 'https://example/src' | Should -BeTrue
        Test-WmManagementSource 'http://example/src' | Should -BeFalse
        Test-WmManagementSource 'C:\wm-source' | Should -BeTrue
        Test-WmManagementSource '\\server\share\wmanager' | Should -BeTrue
        # a path that means nothing on an office computer, even when the wizard runs on Linux
        foreach ($p in @('/src/v1', 'relative\folder', '\\server')) { Test-WmManagementSource $p | Should -BeFalse -Because $p }
    }
}

Describe 'Get-WmSourceManifest' {
    It 'copies manifest.psd1 of a folder source to a temporary file' {
        $src = Join-Path $TestDrive 'src'
        New-Item -ItemType Directory -Path $src | Out-Null
        Set-Content -LiteralPath (Join-Path $src 'manifest.psd1') -Value "@{ SourceId = 'abcdefgh' }"
        $file = Get-WmSourceManifest -Source $src
        try { (Import-PowerShellDataFile -LiteralPath $file).SourceId | Should -Be 'abcdefgh' }
        finally { Remove-Item -LiteralPath $file -Force }
    }

    It 'throws for a source without a manifest and leaves no temporary file' {
        $pattern = 'wmanager-init-*.psd1'
        $before = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter $pattern).Count
        { Get-WmSourceManifest -Source (Join-Path $TestDrive 'none') } | Should -Throw
        @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter $pattern).Count | Should -Be $before
    }
}

Describe 'Get-WmLokiTestBody' {
    It 'builds one stream with wmanager labels and one line' {
        $j = Get-WmLokiTestBody -HostName 'OFFICE-01' -Time ([DateTimeOffset]::FromUnixTimeMilliseconds(1700000000000)) | ConvertFrom-Json
        @($j.streams).Count | Should -Be 1
        $j.streams[0].stream.service_name | Should -Be 'wmanager'
        $j.streams[0].stream.host | Should -Be 'office-01'
        $j.streams[0].stream.job | Should -Be 'init'
        $j.streams[0].values[0][0] | Should -Be '1700000000000000000'
        $j.streams[0].values[0][1] | Should -BeLike 'wmanager init*'
    }
}

Describe 'Test-WmManifestSigner' -Tag 'Integration' -Skip:(-not $env:WM_CI_SOURCES) {
    It 'accepts the manifest signed with the source certificate and names another certificate' {
        $src = $env:WM_CI_SOURCES
        Test-WmManifestSigner -ManifestPath (Join-Path $src 'v1\manifest.psd1') -CertificatePath (Join-Path $src 'wmanager-signing.cer') |
            Should -Be 'ok'
        $other = New-SelfSignedCertificate -Subject 'CN=wmanager init test' -CertStoreLocation 'Cert:\CurrentUser\My' -Type CodeSigningCert
        try {
            $file = Join-Path $TestDrive 'other.cer'
            [IO.File]::WriteAllBytes($file, $other.RawData)
            Test-WmManifestSigner -ManifestPath (Join-Path $src 'v1\manifest.psd1') -CertificatePath $file | Should -BeLike '*another certificate*'
        } finally {
            Remove-Item -LiteralPath "Cert:\CurrentUser\My\$($other.Thumbprint)" -Force
        }
    }
}
