# Tests for tools/wm.ps1, the helper for several companies: the companies and what they lack, the commands it passes
# on to tools/groups.ps1, the menu, and the configuration of every company onto a USB drive. PowerShell 7 (Linux in
# CI). A new company's steps (key, first signature) run only where osslsigncode can sign PowerShell files (2.13 can,
# older ones can't), as in the README setup.
# To run (Pester 5):
#   Invoke-Pester ./tests/Wm.Tests.ps1

BeforeDiscovery {
    $script:notPwsh7 = $PSVersionTable.PSVersion.Major -lt 7
    # Can this computer sign a .psd1 the way tools/publish.sh does?
    $script:cantSign = $true
    if (-not $script:notPwsh7 -and (Get-Command bash, openssl, osslsigncode -ErrorAction SilentlyContinue).Count -eq 3) {
        $probe = Join-Path ([IO.Path]::GetTempPath()) ('wm-sign-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $probe | Out-Null
        try {
            & openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj '/CN=probe' -keyout "$probe/key.pem" -out "$probe/cert.pem" 2>&1 | Out-Null
            Set-Content -LiteralPath "$probe/x.psd1" -Value '@{}'
            & osslsigncode sign -certs "$probe/cert.pem" -key "$probe/key.pem" -in "$probe/x.psd1" -out "$probe/y.psd1" 2>&1 | Out-Null
            $script:cantSign = $LASTEXITCODE -ne 0
        } finally {
            Remove-Item -LiteralPath $probe -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

BeforeAll {
    $script:root = Split-Path $PSScriptRoot -Parent
    $script:tool = Join-Path (Join-Path $script:root 'tools') 'wm.ps1'
    $script:savedCompanies = $env:WMANAGER_COMPANIES

    # Runs the tool in this process; its messages go through Write-Host (stream 6)
    function Invoke-Tool {
        $out = & $script:tool @args 6>&1 | Out-String
        return [pscustomobject]@{ Code = $LASTEXITCODE; Text = $out }
    }

    # Runs the tool in its own pwsh with these lines typed at its questions; after the last one the input ends
    function Invoke-Typed {
        param([string[]]$Answers, [string[]]$Arguments = @())
        $pwsh = (Get-Process -Id $PID).Path
        $out = $Answers | & $pwsh -NoProfile -File $script:tool @Arguments 2>&1 | Out-String
        return [pscustomobject]@{ Code = $LASTEXITCODE; Text = $out }
    }

    function Add-Company {
        param([string]$Name, [switch]$Source, [string]$Config)
        $dir = Join-Path $env:WMANAGER_COMPANIES $Name
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        if ($Source) {
            Copy-Item -Recurse -LiteralPath (Join-Path (Join-Path $script:root 'examples') 'management') -Destination (Join-Path $dir 'source')
        }
        if ($Config) { New-Item -ItemType File -Force -Path (Join-Path (Join-Path $dir 'config') 'provision.config.psd1') -Value $Config | Out-Null }
        return $dir
    }

    # A test key without a passphrase, where tools/new-signing-cert.sh would put the company's key
    function Add-TestKey {
        param([string]$Dir)
        $keys = Join-Path $Dir 'keys'
        New-Item -ItemType Directory -Force -Path $keys | Out-Null
        & openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 365 -subj '/CN=wmanager test' `
            -addext 'basicConstraints=critical,CA:FALSE' -addext 'keyUsage=critical,digitalSignature' -addext 'extendedKeyUsage=codeSigning' `
            -keyout (Join-Path $keys 'key.pem') -out (Join-Path $keys 'cert.pem') 2>&1 | Out-Null
        & openssl x509 -in (Join-Path $keys 'cert.pem') -outform DER -out (Join-Path $keys 'wmanager-signing.cer')
    }

    # manifest.psd1 with the hashes of the source's files, as tools/publish.sh writes it (the signature isn't read here)
    function Write-Manifest {
        param([string]$Source)
        $lines = foreach ($f in Get-ChildItem -LiteralPath $Source -Recurse -File) {
            $rel = [IO.Path]::GetRelativePath($Source, $f.FullName).Replace('\', '/')
            if ($rel -ne 'manifest.psd1') { "        '$rel' = '$((Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash)'" }
        }
        Set-Content -LiteralPath (Join-Path $Source 'manifest.psd1') -Value (@("@{ SourceId = 'test-source-0001'; Serial = 1; Files = @{") + $lines + @('} }'))
    }

    # A release ZIP laid out like tools/build-release.sh makes it
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    function New-Release {
        param([string]$Version)
        $path = Join-Path $TestDrive "wmanager-$Version.zip"
        $fs = [IO.File]::Open($path, [IO.FileMode]::Create)
        try {
            $zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
            foreach ($e in @(@('wmanager/VERSION', $Version), @('wmanager/Update-Packages.ps1', 'param([switch]$OnlyIfPending, [switch]$SelfInstall, [string]$Lang)'))) {
                $w = New-Object IO.StreamWriter($zip.CreateEntry($e[0]).Open())
                $w.Write($e[1])
                $w.Dispose()
            }
            $zip.Dispose()
        } finally {
            $fs.Dispose()
        }
        return $path
    }

    $script:managed = "@{ Management = @{ Source = '\\srv\acme'; SourceId = 'test-source-0001'; Certificate = 'wmanager-signing.cer' } }"
}

AfterAll {
    $env:WMANAGER_COMPANIES = $script:savedCompanies
}

Describe 'tools/wm.ps1' -Skip:$notPwsh7 {
    BeforeEach {
        $env:WMANAGER_COMPANIES = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    }

    It 'lists the companies with what each still lacks' {
        (Invoke-Tool list).Text | Should -Match 'No companies in .* yet'
        $null = Add-Company 'acme' -Source -Config '@{}'
        $null = Add-Company 'beta' -Config '@{}'
        $null = Add-Company 'gamma'
        $null = Add-Company 'not a company'   # not a company name: left out
        $r = Invoke-Tool list
        $r.Code | Should -Be 0
        $lines = @($r.Text -split '\r?\n' | Where-Object { $_ })
        $lines.Count | Should -Be 3
        $lines[0] | Should -Match '^acme\s+2 computers, not signed yet, no signing key$'
        $lines[1] | Should -Match '^beta\s+no management source$'
        $lines[2] | Should -Match '^gamma\s+no management source, no configuration yet$'
    }

    It 'notices changes made after the last signature' {
        $source = Join-Path (Add-Company 'acme' -Source -Config '@{}') 'source'
        Write-Manifest $source
        (Invoke-Tool list).Text | Should -Not -Match 'signed'
        Add-Content -LiteralPath (Join-Path $source 'choco-reqs.txt') -Value 'vlc'
        (Invoke-Tool list).Text | Should -Match 'changes not signed yet'
        Write-Manifest $source
        New-Item -ItemType File -Path (Join-Path $source 'groups/all/new.txt') -Force | Out-Null
        (Invoke-Tool list).Text | Should -Match 'changes not signed yet'
        Write-Manifest $source
        Remove-Item -LiteralPath (Join-Path $source 'groups/all/new.txt')
        (Invoke-Tool list).Text | Should -Match 'changes not signed yet'
    }

    It 'passes a command on to tools/groups.ps1 for the source of the company, with -Url and -Zip' {
        $source = Join-Path (Add-Company 'acme' -Source) 'source'
        $r = Invoke-Tool acme add-computer OFFICE-07 accounting
        $r.Code | Should -Be 0
        [IO.File]::ReadAllText((Join-Path $source 'groups.psd1')) | Should -Match "'OFFICE-07' = @\('accounting'\)"
        (Invoke-Tool acme show OFFICE-07).Text | Should -Match 'accounting'
        (Invoke-Tool acme add-computer OFFICE-08).Code | Should -Be 1
        $zip = New-Release 'v0.3.0'
        $r = Invoke-Tool acme set-version v0.3.0 -Url 'https://example.test/wmanager-v0.3.0.zip' -Zip $zip
        $r.Code | Should -Be 0
        [IO.File]::ReadAllText((Join-Path $source 'version.psd1')) | Should -Match 'https://example\.test/wmanager-v0\.3\.0\.zip'
    }

    It 'refuses a company it doesn''t have and a name that can''t be one' {
        $r = Invoke-Tool nope show
        $r.Code | Should -Be 1
        $r.Text | Should -Match "no company 'nope'"
        foreach ($bad in @('bad name', 'list', 'con', '-x', 'a.')) {
            $r = Invoke-Tool new $bad
            $r.Code | Should -Be 1
            $r.Text | Should -Match 'invalid company name'
        }
        Test-Path -LiteralPath $env:WMANAGER_COMPANIES | Should -BeFalse
    }

    It 'leads through the menu: a company, a computer into groups, then the offer to sign' {
        $source = Join-Path (Add-Company 'acme' -Source -Config '@{}') 'source'
        $null = Add-Company 'beta' -Config '@{}'
        $r = Invoke-Typed @('acme', '2', 'OFFICE-09', '1 front-desk', 'n', '4', '2', 'vlc', 'n', 'x', 'b', 'q')
        $r.Code | Should -Be 0
        $text = [IO.File]::ReadAllText((Join-Path $source 'groups.psd1'))
        $text | Should -Match "'OFFICE-09' = @\('accounting', 'front-desk'\)"
        Get-Content -LiteralPath (Join-Path $source 'groups/accounting/choco-reqs.txt') | Should -Contain 'vlc'
        ([regex]::Matches($r.Text, 'Sign and publish now\?')).Count | Should -Be 2
        $r.Text | Should -Match 'Choose a number from the list, or b'
        $r.Text | Should -Match '(?m)^Choose: q'
    }

    It 'ends at the end of the input' {
        $null = Add-Company 'acme' -Source
        (Invoke-Typed @('1')).Code | Should -Be 0
    }

    Context 'usb' {
        BeforeEach {
            $script:usb = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            # The wmanager there: one that asks for the company
            New-Item -ItemType File -Force -Path (Join-Path $script:usb 'Provision.ps1') | Out-Null
            New-Item -ItemType File -Force -Path (Join-Path $script:usb 'lib/Common.ps1') -Value 'function Find-WmConfig { }' | Out-Null
            Set-Content -LiteralPath (Join-Path $script:usb 'VERSION') -Value 'v0.3.0'
        }

        It 'puts every company''s configuration and certificate onto the drive and says who is missing' {
            $acme = Add-Company 'acme' -Config $script:managed
            Set-Content -LiteralPath (Join-Path $acme 'config/wmanager-signing.cer') -Value 'cert'
            Set-Content -LiteralPath (Join-Path $acme 'config/provision.config.psd1.bak-20260101000000') -Value 'old'
            $null = Add-Company 'beta' -Config '@{}'
            $null = Add-Company 'gamma'
            New-Item -ItemType Directory -Force -Path (Join-Path $script:usb 'configs/gone') | Out-Null
            $r = Invoke-Tool usb $script:usb
            $r.Code | Should -Be 0
            $r.Text | Should -Match 'wmanager v0\.3\.0 is already in'
            $r.Text | Should -Match 'asks which company'
            $r.Text | Should -Match 'gamma has no configuration yet'
            $r.Text | Should -Match 'configs/gone on the drive is not one of the companies here'
            @(Get-ChildItem -LiteralPath (Join-Path $script:usb 'configs/acme') -Name | Sort-Object) -join ',' |
                Should -Be 'provision.config.psd1,wmanager-signing.cer'
            @(Get-ChildItem -LiteralPath (Join-Path $script:usb 'configs/beta') -Name) -join ',' | Should -Be 'provision.config.psd1'
            Test-Path -LiteralPath (Join-Path $script:usb 'configs/gamma') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $script:usb 'configs/gone') | Should -BeTrue
        }

        It 'warns when run.cmd there would not ask for the company' {
            $acme = Add-Company 'acme' -Config $script:managed   # no certificate next to it
            Set-Content -LiteralPath (Join-Path $script:usb 'lib/Common.ps1') -Value '# an older wmanager'
            Set-Content -LiteralPath (Join-Path $script:usb 'provision.config.psd1') -Value '@{}'
            $r = Invoke-Tool usb $script:usb
            $r.Code | Should -Be 0
            $r.Text | Should -Match "doesn't ask for the company yet"
            $r.Text | Should -Match 'has its own provision\.config\.psd1'
            $r.Text | Should -Match 'acme: no wmanager-signing\.cer next to its configuration'
            $r.Text | Should -Match 'run\.cmd -ConfigPath'
        }

        It 'stops when no company has a configuration' {
            $null = Add-Company 'acme'
            $r = Invoke-Tool usb $script:usb
            $r.Code | Should -Be 1
            $r.Text | Should -Match 'no company has a configuration yet'
            Test-Path -LiteralPath (Join-Path $script:usb 'configs') | Should -BeFalse
        }
    }

    It 'goes through the steps of a new company, and carries on after one that stopped' -Skip:$cantSign {
        $dir = Join-Path $env:WMANAGER_COMPANIES 'acme'
        Add-TestKey $dir   # no passphrase to ask for
        # The source is broken: the first signature stops after the copy
        New-Item -ItemType Directory -Force -Path (Join-Path $dir 'source') | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'source/groups.psd1') -Value '@{ broken'
        $r = Invoke-Typed @() @('new', 'acme')
        $r.Code | Should -Be 1
        $r.Text | Should -Match 'to carry on: pwsh tools/wm.ps1 new acme'
        Test-Path -LiteralPath (Join-Path $dir 'source/manifest.psd1') | Should -BeFalse

        # Mended, it carries on: signed, then the wizard with the source's identifier offered
        Remove-Item -LiteralPath (Join-Path $dir 'source') -Recurse
        # wizard: update time, days, Loki, Healthchecks, source, certificate, source identifier (all Enter but the source)
        $r = Invoke-Typed @('y', '', '', '', '', '\\srv\acme', '', '') @('new', 'acme')
        $r.Code | Should -Be 0
        $r.Text | Should -Match '1/4 Signing key: .*\r?\n\s+Already there'
        $r.Text | Should -Match 'Copied from examples/management'
        $id = [IO.File]::ReadAllText((Join-Path $dir 'source/source-id.txt')).Trim()
        Test-Path -LiteralPath (Join-Path $dir 'source/manifest.psd1') | Should -BeTrue
        $config = Import-PowerShellDataFile -LiteralPath (Join-Path $dir 'config/provision.config.psd1')
        $config.Management.Source | Should -Be '\\srv\acme'
        $config.Management.SourceId | Should -Be $id
        Test-Path -LiteralPath (Join-Path $dir 'config/wmanager-signing.cer') | Should -BeTrue
        (Invoke-Tool list).Text | Should -Match '(?m)^acme\s+2 computers\s*$'

        # Once more: nothing left to do
        $r = Invoke-Typed @() @('new', 'acme')
        $r.Code | Should -Be 0
        ([regex]::Matches($r.Text, 'Already')).Count | Should -Be 4
    }
}
