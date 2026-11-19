# Tests for tools/wm.ps1, the helper for several companies: the companies and what they lack, the commands it passes
# on to tools/groups.ps1, the menu, and the configuration of every company onto a USB drive. PowerShell 7 (Linux in
# CI). A new company's steps (key, first signature) run only where osslsigncode can sign PowerShell files (2.13 can,
# older ones can't), as in the README setup.
# To run (Pester 5):
#   Invoke-Pester ./tests/Wm.Tests.ps1

BeforeDiscovery {
    $script:notPwsh7 = $PSVersionTable.PSVersion.Major -lt 7
    $script:noOpenssl = $script:notPwsh7 -or (Get-Command bash, openssl -ErrorAction SilentlyContinue).Count -ne 2
    # openssl asks for a passphrase on the terminal itself; where there is one, a test would wait for the person
    $script:hasTty = $false
    if (-not $script:notPwsh7) { try { [IO.File]::OpenRead('/dev/tty').Dispose(); $script:hasTty = $true } catch { } }
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
    $script:savedEditor = $env:EDITOR

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

    # The files of a key, for what only looks at them (no signing)
    function Add-FakeKey {
        param([string]$Dir, [string]$Cer = 'certificate')
        $keys = Join-Path $Dir 'keys'
        New-Item -ItemType Directory -Force -Path $keys | Out-Null
        Set-Content -LiteralPath (Join-Path $keys 'key.pem') -Value 'key'
        Set-Content -LiteralPath (Join-Path $keys 'cert.pem') -Value 'cert'
        Set-Content -LiteralPath (Join-Path $keys 'wmanager-signing.cer') -Value $Cer
    }

    # An "editor" for the menu: adds a line to the file it opens ($EDITOR, inherited by the tool's own pwsh)
    $script:editor = Join-Path $TestDrive 'editor.sh'
    Set-Content -LiteralPath $script:editor -Value 'printf ''Write-Output "edited"\r\n'' >> "$1"'

    # manifest.psd1 with the hashes of the source's files, as tools/publish.sh writes it (the signature isn't read
    # here); -Exclude: what git ignores
    function Write-Manifest {
        param([string]$Source, [string]$Exclude = '^$')
        $lines = foreach ($f in Get-ChildItem -LiteralPath $Source -Recurse -File) {
            $rel = [IO.Path]::GetRelativePath($Source, $f.FullName).Replace('\', '/')
            if ($rel -ne 'manifest.psd1' -and $rel -notmatch $Exclude) { "        '$rel' = '$((Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash)'" }
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
    $env:EDITOR = $script:savedEditor
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

    It 'makes a new script and a new job for a group, opens them in the editor and checks the source' {
        $source = Join-Path (Add-Company 'acme' -Source -Config '@{}') 'source'
        $env:EDITOR = "sh $script:editor"
        $r = Invoke-Typed @('acme', '5', '1', 'install-printer', 'n', '6', 'front-desk', 'weekly', 'check-backup', 'n', 'b', 'q')
        $r.Code | Should -Be 0
        $script = @(Get-ChildItem -LiteralPath (Join-Path $source 'groups/accounting/scripts') -Filter '*install-printer.ps1')
        $script.Count | Should -Be 1
        $script[0].Name | Should -Match '^[0-9]+-install-printer\.ps1$'
        [IO.File]::ReadAllText($script[0].FullName) | Should -Match 'Write-Output "edited"'
        $job = Join-Path $source 'groups/front-desk/jobs/weekly/check-backup.ps1'
        [IO.File]::ReadAllText($job) | Should -Match 'Write-Output "edited"'
        $r.Text | Should -Match 'Opening it in sh '
        ([regex]::Matches($r.Text, 'Sign and publish now\?')).Count | Should -Be 2
    }

    It 'opens a new script again while the source has a mistake in it' {
        $source = Join-Path (Add-Company 'acme' -Source -Config '@{}') 'source'
        $broken = Join-Path $TestDrive 'broken-editor.sh'
        Set-Content -LiteralPath $broken -Value 'printf ''if ($x) {\r\n'' >> "$1"'
        $env:EDITOR = "sh $broken"
        $r = Invoke-Typed @('acme', '5', '1', 'broken', 'n', 'n', 'b', 'q')
        $r.Code | Should -Be 0
        $r.Text | Should -Match 'Open it again to fix it\?'
        ([regex]::Matches($r.Text, 'Opening it in')).Count | Should -Be 1
    }

    It 'asks again for a group number that is not on the list' {
        $source = Join-Path (Add-Company 'acme' -Source -Config '@{}') 'source'
        $r = Invoke-Typed @('acme', '2', 'OFFICE-09', '7', '1', 'n', 'b', 'q')
        $r.Code | Should -Be 0
        $r.Text | Should -Match 'Not on the list: 7'
        [IO.File]::ReadAllText((Join-Path $source 'groups.psd1')) | Should -Match "'OFFICE-09' = @\('accounting'\)"
        [IO.File]::ReadAllText((Join-Path $source 'groups.psd1')) | Should -Not -Match "'7'"
    }

    It 'counts only what git would push as signed, like tools/publish.sh' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $source = Join-Path (Add-Company 'acme' -Source -Config '@{}') 'source'
        Add-FakeKey (Join-Path $env:WMANAGER_COMPANIES 'acme')
        & git -C $source init -q
        Set-Content -LiteralPath (Join-Path $source '.gitignore') -Value '*.bak'
        Set-Content -LiteralPath (Join-Path $source 'groups.psd1.bak') -Value 'old'
        Write-Manifest $source -Exclude '\.bak$'
        (Invoke-Tool list).Text | Should -Match '(?m)^acme\s+2 computers\s*$'
        Set-Content -LiteralPath (Join-Path $source 'new.txt') -Value 'not ignored'
        (Invoke-Tool list).Text | Should -Match 'changes not signed yet'
    }

    It 'keeps company names apart from list numbers, menu letters and each other''s letter case' {
        foreach ($bad in @('12', 'n', 'q')) {
            $r = Invoke-Tool new $bad
            $r.Code | Should -Be 1
            $r.Text | Should -Match 'invalid company name'
        }
        $null = Add-Company 'acme' -Config '@{}'
        $r = Invoke-Tool new ACME
        $r.Code | Should -Be 1
        $r.Text | Should -Match 'there is a company acme already'
        $null = Add-Company 'Acme' -Config '@{}'   # made by hand
        $r = Invoke-Tool usb (Join-Path $TestDrive 'usb-case')
        $r.Code | Should -Be 1
        $r.Text | Should -Match 'differ only in letter case'
    }

    It 'takes the companies folder from WMANAGER_COMPANIES with ~ as the home folder' {
        $savedHome = $env:HOME
        try {
            $env:HOME = Join-Path $TestDrive 'home'
            $null = New-Item -ItemType Directory -Force -Path (Join-Path $env:HOME 'co/acme')
            $env:WMANAGER_COMPANIES = '~/co'
            $r = Invoke-Typed @() @('list')
            $r.Text | Should -Match '(?m)^acme\s'
        } finally {
            $env:HOME = $savedHome
        }
    }

    It 'gives the wizard the certificate of the key and the identifier of the source' -Skip:$noOpenssl {
        $config = [IO.File]::ReadAllText((Join-Path $script:root 'provision.config.example.psd1'))
        $config = $config -replace "(?m)^(\s*Source\s*=\s*)''", "`$1'\\srv\acme'" -replace "(?m)^(\s*SourceId\s*=\s*)''", "`$1'old-source-0001'"
        $dir = Add-Company 'acme' -Source -Config $config
        Add-TestKey $dir
        Add-TestKey (Join-Path $TestDrive 'other')   # the certificate of an older key
        Copy-Item -LiteralPath (Join-Path $TestDrive 'other/keys/wmanager-signing.cer') -Destination (Join-Path $dir 'config/wmanager-signing.cer')
        Set-Content -LiteralPath (Join-Path $dir 'source/source-id.txt') -Value 'new-source-0002'
        # keep the file, Enter at every question (update time, days, Loki, Healthchecks, source, certificate, identifier)
        $r = Invoke-Typed @('y', '', '', '', '', '', '', '') @('acme', 'config')
        $r.Code | Should -Be 0
        $r.Text | Should -Match 'config/wmanager-signing\.cer was another certificate'
        (Get-FileHash -LiteralPath (Join-Path $dir 'config/wmanager-signing.cer')).Hash |
            Should -Be (Get-FileHash -LiteralPath (Join-Path $dir 'keys/wmanager-signing.cer')).Hash
        $r.Text | Should -Match 'old-source-0001'   # the wizard says the saved identifier is another one
        (Import-PowerShellDataFile -LiteralPath (Join-Path $dir 'config/provision.config.psd1')).Management.SourceId | Should -Be 'new-source-0002'
    }

    It 'leaves alone a key.pem without its certificates' {
        $dir = Add-Company 'acme'
        New-Item -ItemType Directory -Force -Path (Join-Path $dir 'keys') | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'keys/key.pem') -Value 'a key without its certificates'
        $r = Invoke-Typed @() @('new', 'acme')
        $r.Code | Should -Be 1
        $r.Text | Should -Match 'has a key\.pem but no certificates'
        [IO.File]::ReadAllText((Join-Path $dir 'keys/key.pem')).Trim() | Should -Be 'a key without its certificates'
    }

    It 'starts the key again after a creation that stopped at the passphrase' -Skip:($noOpenssl -or $hasTty) {
        # An empty key.pem is what such a creation left before. Without a terminal openssl can't ask either, so this
        # run stops too, and leaves nothing behind
        $dir = Add-Company 'acme'
        New-Item -ItemType Directory -Force -Path (Join-Path $dir 'keys') | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir 'keys/key.pem'), '')
        $r = Invoke-Typed @() @('new', 'acme')
        $r.Code | Should -Be 1
        $r.Text | Should -Match 'no key was created'
        @(Get-ChildItem -LiteralPath (Join-Path $dir 'keys')).Count | Should -Be 0
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

        It 'says when the drive keeps the configuration of a company that has none now, and refuses a certificate path' {
            $null = Add-Company 'acme' -Config '@{}'
            $null = Add-Company 'gamma'
            New-Item -ItemType File -Force -Path (Join-Path $script:usb 'configs/gamma/provision.config.psd1') -Value '@{}' | Out-Null
            $r = Invoke-Tool usb $script:usb
            $r.Code | Should -Be 0
            $r.Text | Should -Match 'still has configs/gamma from before'
            $r.Text | Should -Not -Match "gamma has no configuration yet, so it isn't on the drive"
            $null = Add-Company 'beta' -Config "@{ Management = @{ Source = '\\srv\beta'; SourceId = 'test-source-0001'; Certificate = '../../run.cmd' } }"
            $r = Invoke-Tool usb $script:usb
            $r.Code | Should -Be 1
            $r.Text | Should -Match 'not a plain file name'
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
