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
        $r.Text | Should -Match "WARNING: not a company in .* is left out"
        $lines = @($r.Text -split '\r?\n' | Where-Object { $_ -and $_ -notmatch '^WARNING' })
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

    It 'shows what changed since the last signature: added, changed and removed files' {
        $source = Join-Path (Add-Company 'acme' -Source -Config '@{}') 'source'
        $r = Invoke-Tool acme changes
        $r.Code | Should -Be 0
        $files = @(Get-ChildItem -LiteralPath $source -Recurse -File).Count + 1   # with the source-id.txt it creates
        $r.Text | Should -Match "Never signed: the first signature publishes $files files"
        (Invoke-Tool nope changes).Text | Should -Match "no company 'nope'"
        $null = Add-Company 'beta' -Config '@{}'
        (Invoke-Tool beta changes).Text | Should -Match 'beta has no source yet'
        Write-Manifest $source
        (Invoke-Tool acme changes).Text | Should -Match 'Nothing changed since the last signature \(manifest 1\)'
        Add-Content -LiteralPath (Join-Path $source 'choco-reqs.txt') -Value 'vlc'
        Set-Content -LiteralPath (Join-Path $source 'groups/all/new.txt') -Value 'new'
        $gone = @(Get-ChildItem -LiteralPath (Join-Path $source 'groups/accounting') -Recurse -File)[0]
        $goneRel = [IO.Path]::GetRelativePath($source, $gone.FullName).Replace('\', '/')
        Remove-Item -LiteralPath $gone.FullName
        $r = Invoke-Tool acme changes
        $r.Text | Should -Match '(?m)^\s+\+ groups/all/new\.txt\s*$'
        $r.Text | Should -Match '(?m)^\s+~ choco-reqs\.txt\s*$'
        $r.Text | Should -Match ("(?m)^\s+- " + [regex]::Escape($goneRel) + '\s*$')
        @([regex]::Matches($r.Text, '(?m)^\s+[+~-] ')).Count | Should -Be 3

        # A new name that differs only in letter case is a new file for a web server
        Write-Manifest $source
        Rename-Item -LiteralPath (Join-Path $source 'groups.psd1') -NewName 'Groups.psd1'
        $r = Invoke-Tool acme changes
        $r.Text | Should -Match '(?m)^\s+\+ Groups\.psd1\s*$'
        $r.Text | Should -Match '(?m)^\s+- groups\.psd1\s*$'
        Rename-Item -LiteralPath (Join-Path $source 'Groups.psd1') -NewName 'groups.psd1'

        # A manifest that can't be read is not "never signed"
        Set-Content -LiteralPath (Join-Path $source 'manifest.psd1') -Value '@{ <<<<<<< HEAD'
        (Invoke-Tool acme changes).Text | Should -Match "manifest\.psd1 can't be read"
        (Invoke-Tool list).Text | Should -Match '(?m)^acme\s+.*changes not signed yet'
    }

    It 'shows the changes before signing and signs only when you say so' {
        $dir = Add-Company 'acme' -Source -Config '@{}'
        Add-FakeKey $dir   # the signature is never reached here
        Write-Manifest (Join-Path $dir 'source')
        $manifest = [IO.File]::ReadAllText((Join-Path $dir 'source/manifest.psd1'))
        $r = Invoke-Typed @('') @('acme', 'publish')
        $r.Code | Should -Be 0
        $r.Text | Should -Match 'Nothing changed since the last signature'
        $r.Text | Should -Match 'Sign it again anyway\? \[y/N\]'
        $r.Text | Should -Match 'Not signed\.'
        Add-Content -LiteralPath (Join-Path $dir 'source/choco-reqs.txt') -Value 'vlc'
        $r = Invoke-Typed @('n') @('acme', 'publish')
        $r.Code | Should -Be 0
        $r.Text | Should -Match '~ choco-reqs\.txt'
        $r.Text | Should -Match 'Sign and publish this\? \[Y/n\]'
        $r.Text | Should -Match 'Not signed\.'
        [IO.File]::ReadAllText((Join-Path $dir 'source/manifest.psd1')) | Should -Be $manifest
        # -Yes: no question (a script signs this way); the fake key can't sign, so it stops at publish.sh
        $r = Invoke-Typed @() @('acme', 'publish', '-Yes')
        $r.Text | Should -Not -Match 'Sign and publish this\?'
        $r.Text | Should -Match 'not signed \(the reason is above\)'
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
        $r = Invoke-Typed @('acme', '3', 'OFFICE-09', '1 front-desk', 'n', '5', '2', 'vlc', 'n', 'x', 'b', 'q')
        $r.Code | Should -Be 0
        $text = [IO.File]::ReadAllText((Join-Path $source 'groups.psd1'))
        $text | Should -Match "'OFFICE-09' = @\('accounting', 'front-desk'\)"
        Get-Content -LiteralPath (Join-Path $source 'groups/accounting/choco-reqs.txt') | Should -Contain 'vlc'
        ([regex]::Matches($r.Text, 'Sign and publish now\?')).Count | Should -Be 2
        $r.Text | Should -Match 'Never signed: the first signature publishes'
        $r.Text | Should -Match 'Choose a number from the list, or b'
        $r.Text | Should -Match '(?m)^Choose: q'
    }

    It 'makes a new script and a new job for a group, opens them in the editor and checks the source' {
        $source = Join-Path (Add-Company 'acme' -Source -Config '@{}') 'source'
        $env:EDITOR = "sh $script:editor"
        $r = Invoke-Typed @('acme', '7', '1', 'install-printer', 'n', '8', 'front-desk', 'weekly', 'check-backup', 'n', 'b', 'q')
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
        $r = Invoke-Typed @('acme', '7', '1', 'broken', 'n', 'n', 'b', 'q')
        $r.Code | Should -Be 0
        $r.Text | Should -Match 'Open it again to fix it\?'
        ([regex]::Matches($r.Text, 'Opening it in')).Count | Should -Be 1
    }

    It 'removes a package from a list, chosen by number or name in any letter case' {
        $source = Join-Path (Add-Company 'acme' -Source -Config '@{}') 'source'
        $r = Invoke-Typed @('acme', '6', '1', '99', 'VLC', 'n', '6', '1', '1', 'n', 'b', 'q')
        $r.Code | Should -Be 0
        $r.Text | Should -Match 'Not on the list: 99\. A number from 1 to \d+ or a name'
        $r.Text | Should -Match 'never uninstalled'
        $list = Get-Content -LiteralPath (Join-Path $source 'choco-reqs.txt')
        $list | Should -Not -Contain 'vlc'
        $list | Should -Not -Contain 'googlechrome !noupdate'   # the first one, by its number
        $list | Should -Contain 'libreoffice-fresh'
        $null = Add-Company 'beta' -Config '@{}'
        (Invoke-Typed @('beta', '6', 'b', 'q')).Text | Should -Match 'beta has no source yet'
    }

    It 'switches the wmanager version of the computers only when you confirm it' {
        $source = Join-Path (Add-Company 'acme' -Source -Config '@{}') 'source'
        $r = Invoke-Typed @('acme', '11', 'v0.3.0', '', '', 'b', 'q')
        $r.Code | Should -Be 0
        $r.Text | Should -Match 'every computer switches to wmanager v0\.3\.0 at its next update\. Set it\? \[y/N\]'
        Test-Path -LiteralPath (Join-Path $source 'version.psd1') | Should -BeFalse
        $r.Text | Should -Not -Match 'Sign and publish now\?'
    }

    It 'edits a script of a group in the editor, and removes a job after asking' {
        $source = Join-Path (Add-Company 'acme' -Source -Config '@{}') 'source'
        $env:EDITOR = "sh $script:editor"
        $r = Invoke-Typed @('acme', '9', '1', 'x', 'e', 'n', '9', 'groups/all/jobs/daily/system-report.ps1', 'r', 'n', '9', '2', 'r', 'y', 'n', 'b', 'q')
        $r.Code | Should -Be 0
        $r.Text | Should -Match '(?m)^\s+1\) groups/accounting/scripts/10-power-plan\.ps1\s*$'
        $r.Text | Should -Match '(?m)^\s+2\) groups/all/jobs/daily/system-report\.ps1\s*$'
        [IO.File]::ReadAllText((Join-Path $source 'groups/accounting/scripts/10-power-plan.ps1')) | Should -Match 'Write-Output "edited"'
        $r.Text | Should -Match 'e, r or Enter\.'
        $r.Text | Should -Match 'A changed script runs again on every computer of its group'
        $r.Text | Should -Match 'stop running it'
        $r.Text | Should -Match 'Removed groups/all/jobs/daily/system-report\.ps1\.(\r?\n.*)*Checked \d+ files'
        $r.Text | Should -Match 'Removed groups/all/jobs/daily/system-report\.ps1'
        Test-Path -LiteralPath (Join-Path $source 'groups/all/jobs/daily/system-report.ps1') | Should -BeFalse
        ([regex]::Matches($r.Text, 'Sign and publish now\?')).Count | Should -Be 2   # after the edit and the removal
    }

    It 'asks again for a group number that is not on the list' {
        $source = Join-Path (Add-Company 'acme' -Source -Config '@{}') 'source'
        $r = Invoke-Typed @('acme', '3', 'OFFICE-09', '7', '1', 'n', 'b', 'q')
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

    Context 'status' {
        BeforeAll {
            # A stand-in for the Healthchecks API and Loki on this computer, with what real computers send: Loki lines
            # with Write-WmLog's prefix, run records (Add-WmRunRecord), and pages as Loki gives them (newest first,
            # up to "limit", up to and including "end"). Every request goes to requests.txt.
            $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
            $probe.Start(); $script:port = $probe.LocalEndpoint.Port; $probe.Stop()
            $script:requests = Join-Path $TestDrive 'requests.txt'
            $script:server = Start-ThreadJob -ArgumentList $script:port, $script:requests -ScriptBlock {
                param($port, $log)
                $l = New-Object System.Net.HttpListener
                $l.Prefixes.Add("http://127.0.0.1:$port/")
                $l.Start()
                $now = [datetimeoffset]::UtcNow
                $line = { param($t, $level, $text) @{ ns = [decimal]($t.ToUnixTimeMilliseconds() * 1000000); text = ('{0} [{1}] {2}' -f $t.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss'), $level, $text) } }
                $record = { param($t, $version, $w, $e) @{ ns = [decimal]($t.ToUnixTimeMilliseconds() * 1000000 + 1); text = ('{{"wmanager_run":"{0}","job":"update","warnings":{1},"errors":{2}}}' -f $version, $w, $e) } }
                $entries = @{
                    # A computer that sends run records
                    'office-01' = @((& $line $now.AddMinutes(-65) 'INFO' 'wmanager v0.3.0 update on OFFICE-01'),
                                    (& $line $now.AddHours(-1) 'INFO' 'End: warnings 0, errors 0.'),
                                    (& $record $now.AddHours(-1) 'v0.3.0' 0 0))
                    # One on v0.2.0, from before run records
                    'office-02' = @((& $line $now.AddDays(-3).AddMinutes(-5) 'INFO' 'wmanager v0.2.0 update on OFFICE-02'),
                                    (& $line $now.AddDays(-3) 'INFO' 'End: warnings 1, errors 2.'))
                    # One whose switch to v0.4.0 failed: the new version logged its start, the old one finished the run
                    'office-05' = @((& $line $now.AddMinutes(-20) 'INFO' 'wmanager v0.3.0 update on OFFICE-05'),
                                    (& $line $now.AddMinutes(-19) 'INFO' 'wmanager v0.4.0 update on OFFICE-05'),
                                    (& $line $now.AddMinutes(-2) 'INFO' 'End: warnings 0, errors 1.'),
                                    (& $record $now.AddMinutes(-2) 'v0.3.0' 0 1))
                }
                $checks = @{ checks = @(
                    @{ slug = 'wm-office-01'; status = 'up'; last_ping = $now.AddHours(-2).ToString('o') },
                    @{ slug = 'wm-office-02'; status = 'down'; last_ping = $now.AddDays(-3).ToString('o') },
                    @{ slug = 'wm-reception'; status = 'up'; last_ping = $now.AddMinutes(-30).ToString('o') },
                    @{ slug = 'office-01'; status = 'up'; last_ping = $now.AddHours(-2).ToString('o') },
                    @{ slug = 'backup-server'; status = 'down'; last_ping = $null }
                ) } | ConvertTo-Json -Depth 5
                $errors = @{ status = 'success'; data = @{ resultType = 'vector'; result = @(
                    @{ metric = @{ host = 'office-02' }; value = @(1, '4') }) } } | ConvertTo-Json -Depth 8
                $basic = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes('123:loki-read'))
                while ($l.IsListening) {
                    $c = $l.GetContext()
                    $path = $c.Request.Url.AbsolutePath
                    $query = $c.Request.QueryString
                    Add-Content -LiteralPath $log -Value ($path + ' ' + [uri]::UnescapeDataString($c.Request.Url.Query))
                    $code = 200; $body = '{}'
                    if ($path -eq '/stop') { $l.Stop(); break }
                    elseif ($path -eq '/api/v3/checks/') {
                        if ($c.Request.Headers['X-Api-Key'] -eq 'hc-read') { $body = $checks } else { $code = 401; $body = '{"error":"wrong api key"}' }
                    } elseif ($path -like '/loki/api/v1/*') {
                        if ($c.Request.Headers['Authorization'] -ne $basic) { $code = 401; $body = 'no' }
                        elseif ($path -eq '/loki/api/v1/query_range') {
                            $end = [decimal]$query['end']; $limit = [int]$query['limit']
                            $page = @(foreach ($h in $entries.Keys) { foreach ($e in $entries[$h]) { if ($e.ns -le $end) { @{ host = $h; ns = $e.ns; text = $e.text } } } }) |
                                Sort-Object { $_.ns } -Descending | Select-Object -First $limit
                            $streams = @($page | Group-Object { $_.host } | ForEach-Object {
                                @{ stream = @{ host = $_.Name; service_name = 'wmanager' }; values = @($_.Group | ForEach-Object { , @([string]$_.ns, $_.text) }) } })
                            $body = @{ status = 'success'; data = @{ resultType = 'streams'; result = $streams } } | ConvertTo-Json -Depth 8
                        } else { $body = $errors }
                    } elseif ($path -ne '/ready') { $code = 404 }
                    $bytes = [Text.Encoding]::UTF8.GetBytes($body)
                    $c.Response.StatusCode = $code
                    $c.Response.ContentType = 'application/json'
                    $c.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                    $c.Response.Close()
                }
            }
            $script:base = "http://127.0.0.1:$($script:port)"
            for ($i = 0; $i -lt 100; $i++) {
                try { Invoke-WebRequest -Uri "$($script:base)/ready" -TimeoutSec 2 | Out-Null; break } catch { Start-Sleep -Milliseconds 100 }
            }
            function New-Reporting {
                param([string]$Prefix = 'wm-')
                $config = [IO.File]::ReadAllText((Join-Path $script:root 'provision.config.example.psd1'))
                foreach ($s in @(@('LokiUrl', "$($script:base)/loki/api/v1/push/"), @('LokiUser', '123'), @('LokiToken', 'loki-write'),
                                 @('HealthchecksBaseUrl', "$($script:base)/ping"), @('HealthchecksPingKey', 'ping-key'),
                                 @('HealthchecksSlugPrefix', $Prefix))) {
                    $config = $config -replace "(?m)^(\s*$($s[0])\s*=\s*)'[^']*'", "`${1}'$($s[1])'"
                }
                return $config
            }
            # acme: the computers of the stand-in, OFFICE-05 in a group that runs v0.4.0, OFFICE-07 never reported
            function Add-StatusCompany {
                param([string]$Prefix = 'wm-')
                $dir = Add-Company 'acme' -Source -Config (New-Reporting $Prefix)
                $null = Invoke-Tool acme add-computer OFFICE-05 pilot
                $null = Invoke-Tool acme add-computer OFFICE-07 accounting
                $null = Invoke-Tool acme set-version v0.3.0 -Url 'https://example.test/wmanager-v0.3.0.zip' -Zip (New-Release 'v0.3.0')
                $null = Invoke-Tool acme set-version v0.4.0 pilot -Url 'https://example.test/wmanager-v0.4.0.zip' -Zip (New-Release 'v0.4.0')
                return $dir
            }
        }

        AfterAll {
            try { Invoke-WebRequest -Uri "$($script:base)/stop" -TimeoutSec 5 | Out-Null } catch { }
            $script:server | Remove-Job -Force
            Remove-Item Env:\WMANAGER_LOKI_PAGE -ErrorAction SilentlyContinue
        }

        It 'shows each computer: its check, its last update, its errors and the version it runs against the source''s' {
            $dir = Add-StatusCompany
            $r = Invoke-Tool acme status
            $r.Code | Should -Be 1
            $r.Text | Should -Match 'no read-only keys for acme yet: pwsh tools/wm.ps1 acme monitoring'

            $r = Invoke-Typed @('hc-read', 'loki-read') @('acme', 'monitoring')
            $r.Code | Should -Be 0
            $keys = Import-PowerShellDataFile -LiteralPath (Join-Path $dir 'monitoring.psd1')
            $keys.HealthchecksApiKey | Should -Be 'hc-read'
            $keys.LokiReadToken | Should -Be 'loki-read'
            (& stat -c '%a' (Join-Path $dir 'monitoring.psd1')) | Should -Be '600'

            # Three lines a page: the oldest computer's lines come only on later pages
            $env:WMANAGER_LOKI_PAGE = '3'
            $r = Invoke-Tool acme status
            Remove-Item Env:\WMANAGER_LOKI_PAGE
            $r.Code | Should -Be 0
            $lines = @($r.Text -split '\r?\n')
            ($lines | Where-Object { $_ -match '^OFFICE-01\s' }) | Should -Match '^OFFICE-01\s+up \(2h\)\s+\S+ \S+ \(1h\)\s+ok\s+v0\.3\.0\s*$'
            ($lines | Where-Object { $_ -match '^OFFICE-02\s' }) | Should -Match '^OFFICE-02\s+down \(3d\)\s+\S+ \S+ \(3d\)\s+2 errors, 4 errors/24h\s+v0\.2\.0 -> v0\.3\.0\s*$'
            ($lines | Where-Object { $_ -match '^OFFICE-05\s' }) | Should -Match '^OFFICE-05\s+-\s+\S+ \S+ \(2m\)\s+1 error\s+v0\.3\.0 -> v0\.4\.0\s*$'
            ($lines | Where-Object { $_ -match '^OFFICE-07\s' }) | Should -Match '^OFFICE-07\s+-\s+-\s+-\s+-\s*$'
            ($lines | Where-Object { $_ -match '^RECEPTION\s' }) | Should -Match '^RECEPTION\s+up \(30m\)\s+-\s+-\s+-\s*$'
            $r.Text | Should -Not -Match 'BACKUP-SERVER'
            $r.Text | Should -Match '5 computers, 1 down, 2 with errors, 2 not on their version yet, 1 silent for 14 days'
            $sent = @(Get-Content -LiteralPath $script:requests | Where-Object { $_ -like '/loki/api/v1/query_range *' })
            $sent.Count | Should -BeGreaterThan 2
            $sent[0] | Should -Match 'service_name="wmanager"'
        }

        It 'counts a check of the project as a computer only when it is one, without a slug prefix' {
            $dir = Add-StatusCompany -Prefix ''
            Set-Content -LiteralPath (Join-Path $dir 'monitoring.psd1') -Value "@{ HealthchecksApiKey = 'hc-read'; HealthchecksApiUrl = ''; LokiReadToken = 'loki-read' }"
            $r = Invoke-Tool acme status
            $r.Code | Should -Be 0
            @($r.Text -split '\r?\n' | Where-Object { $_ -match '^OFFICE-01\s' }) | Should -Match 'up \(2h\)'
            $r.Text | Should -Not -Match 'BACKUP-SERVER|RECEPTION|WM-'
            $r.Text | Should -Match '4 other checks of the Healthchecks project left out'
        }

        It 'marks what a service that refused the key would know, instead of calling the computers silent' {
            $dir = Add-StatusCompany
            Set-Content -LiteralPath (Join-Path $dir 'monitoring.psd1') -Value "@{ HealthchecksApiKey = 'wrong'; HealthchecksApiUrl = ''; LokiReadToken = 'loki-read' }"
            $null = Add-Company 'beta' -Config '@{}'
            $r = Invoke-Tool acme status
            $r.Text | Should -Match 'WARNING: Healthchecks: '
            ($r.Text -split '\r?\n' | Where-Object { $_ -match '^OFFICE-07\s' }) | Should -Match '^OFFICE-07\s+\?\s+-\s+-\s+-\s*$'
            $r.Text | Should -Not -Match 'silent'
            $r = Invoke-Tool status
            $r.Code | Should -Be 0
            $r.Text | Should -Match '(?m)^acme\s+4 computers, 2 with errors, 2 not on their version yet \(Healthchecks: '
            $r.Text | Should -Match '(?m)^beta\s+no read-only keys for beta yet'
        }

        It 'repairs a monitoring.psd1 it can''t read, and refuses plain http:// to other computers' {
            $dir = Add-StatusCompany
            Set-Content -LiteralPath (Join-Path $dir 'monitoring.psd1') -Value "@{ broken"
            $r = Invoke-Typed @('hc-read', 'loki-read') @('acme', 'monitoring')
            $r.Code | Should -Be 0
            $r.Text | Should -Match "can't be read"
            (Import-PowerShellDataFile -LiteralPath (Join-Path $dir 'monitoring.psd1')).LokiReadToken | Should -Be 'loki-read'
            $config = (New-Reporting) -replace [regex]::Escape($script:base), 'http://logs.example.test'
            Set-Content -LiteralPath (Join-Path $dir 'config/provision.config.psd1') -Value $config
            $r = Invoke-Tool acme status
            $r.Text | Should -Match 'LokiUrl must be an https:// address'
        }
    }

    Context 'publish target and sync' {
        BeforeAll {
            $script:gitEnv = @{}
            foreach ($k in @('GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL', 'GIT_TERMINAL_PROMPT', 'GH_CONFIG_DIR', 'GH_TOKEN', 'GITHUB_TOKEN', 'WMANAGER_TEST_LOCAL_HTTP', 'WMANAGER_TEST_WAIT')) {
                $script:gitEnv[$k] = [Environment]::GetEnvironmentVariable($k)
            }
            $env:GIT_AUTHOR_NAME = 'wm test'; $env:GIT_COMMITTER_NAME = 'wm test'
            $env:GIT_AUTHOR_EMAIL = 'wm@example.test'; $env:GIT_COMMITTER_EMAIL = 'wm@example.test'
            $env:GIT_TERMINAL_PROMPT = '0'
            # The stand-in server is http://127.0.0.1, and a check waits 2 s for a host's cache, not 5 minutes
            $env:WMANAGER_TEST_LOCAL_HTTP = '1'
            $env:WMANAGER_TEST_WAIT = '2'
            # gh is never signed in here, so the remote is asked for: a stand-in gh that says what gh says then
            # ("not logged into", which a case-blind "logged in" would take for yes)
            $env:GH_CONFIG_DIR = Join-Path $TestDrive 'gh'
            Remove-Item Env:\GH_TOKEN, Env:\GITHUB_TOKEN -ErrorAction SilentlyContinue
            $script:savedPath = $env:PATH
            $fakeBin = Join-Path $TestDrive 'fake-bin'
            New-Item -ItemType Directory -Force -Path $fakeBin | Out-Null
            Set-Content -LiteralPath (Join-Path $fakeBin 'gh') -Value @(
                '#!/bin/sh'
                'echo "You are not logged into any GitHub hosts. To log in, run: gh auth login" >&2'
                'exit 1')
            & chmod +x (Join-Path $fakeBin 'gh')
            $env:PATH = $fakeBin + [IO.Path]::PathSeparator + $env:PATH

            # The computers' side: a web server giving the files of $web (the folder sync copies to)
            $script:web = Join-Path $TestDrive 'web'
            New-Item -ItemType Directory -Force -Path $script:web | Out-Null
            $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
            $probe.Start(); $port = $probe.LocalEndpoint.Port; $probe.Stop()
            $script:webBase = "http://127.0.0.1:$port"
            $script:webServer = Start-ThreadJob -ArgumentList $port, $script:web -ScriptBlock {
                param($port, $root)
                $l = New-Object System.Net.HttpListener
                $l.Prefixes.Add("http://127.0.0.1:$port/")
                $l.Start()
                while ($l.IsListening) {
                    $c = $l.GetContext()
                    $path = $c.Request.Url.AbsolutePath
                    if ($path -eq '/stop') { $c.Response.Close(); $l.Stop(); break }
                    $file = Join-Path $root $path.TrimStart('/')
                    if ($path -ne '/ready' -and -not [IO.File]::Exists($file)) { $c.Response.StatusCode = 404 }
                    elseif ($path -ne '/ready') { $b = [IO.File]::ReadAllBytes($file); $c.Response.OutputStream.Write($b, 0, $b.Length) }
                    $c.Response.Close()
                }
            }
            for ($i = 0; $i -lt 100; $i++) {
                try { Invoke-WebRequest -Uri "$($script:webBase)/ready" -TimeoutSec 2 | Out-Null; break } catch { Start-Sleep -Milliseconds 100 }
            }
        }

        AfterAll {
            try { Invoke-WebRequest -Uri "$($script:webBase)/stop" -TimeoutSec 5 | Out-Null } catch { }
            $script:webServer | Remove-Job -Force
            foreach ($k in $script:gitEnv.Keys) { [Environment]::SetEnvironmentVariable($k, $script:gitEnv[$k]) }
            $env:PATH = $script:savedPath
        }

        It 'copies the signed source to a folder, manifest last, and checks that the computers'' address gives it' {
            $dir = Add-Company 'acme' -Source -Config "@{ Management = @{ Source = '$($script:webBase)/acme'; SourceId = 'test-source-0001' } }"
            Write-Manifest (Join-Path $dir 'source')
            $folder = Join-Path $script:web 'acme'
            $r = Invoke-Typed @('f', $folder, 'y', 'y') @('acme', 'target')
            $r.Code | Should -Be 0 -Because $r.Text
            $r.Text | Should -Match "doesn't exist\. Create it"
            (Import-PowerShellDataFile -LiteralPath (Join-Path $dir 'publish.psd1')).Target | Should -Be $folder
            (& stat -c '%a' (Join-Path $dir 'publish.psd1')) | Should -Be '600'
            $r.Text | Should -Match 'Copied \d+ changed files and manifest\.psd1 \(last\)'
            $r.Text | Should -Match 'The computers can read manifest 1 now'
            Test-Path -LiteralPath (Join-Path $folder 'groups/accounting/scripts/10-power-plan.ps1') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $folder '.gitattributes') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $folder 'manifest.psd1.new') | Should -BeFalse

            # Again: only what changed (nothing) and the manifest
            $r = Invoke-Tool acme sync
            $r.Code | Should -Be 0
            $r.Text | Should -Match 'Copied 0 changed files and manifest\.psd1'

            # The computers read https:// (and Windows paths) only: an http:// address is a mistake
            Remove-Item Env:\WMANAGER_TEST_LOCAL_HTTP
            try { $r = Invoke-Tool acme sync } finally { $env:WMANAGER_TEST_LOCAL_HTTP = '1' }
            $r.Code | Should -Be 1
            $r.Text | Should -Match 'the computers read only https:// addresses'

            # Changes that aren't signed stay here
            Add-Content -LiteralPath (Join-Path $dir 'source/choco-reqs.txt') -Value 'not-signed-yet'
            $r = Invoke-Tool acme sync
            $r.Code | Should -Be 1
            $r.Text | Should -Match "changes that aren't signed"
            Get-Content -LiteralPath (Join-Path $folder 'choco-reqs.txt') | Should -Not -Contain 'not-signed-yet'
        }

        It 'refuses a folder that is missing, holds another source or a newer manifest' {
            $dir = Add-Company 'acme' -Source -Config '@{}'
            Write-Manifest (Join-Path $dir 'source')
            $folder = Join-Path $TestDrive 'share-acme'
            Set-Content -LiteralPath (Join-Path $dir 'publish.psd1') -Value "@{ Target = '$folder' }"
            (Invoke-Tool acme sync).Text | Should -Match "doesn't exist: is the share mounted\?"
            New-Item -ItemType Directory -Force -Path $folder | Out-Null
            Set-Content -LiteralPath (Join-Path $folder 'manifest.psd1') -Value "@{ SourceId = 'another-source'; Serial = 1; Files = @{} }"
            $r = Invoke-Tool acme sync
            $r.Code | Should -Be 1
            $r.Text | Should -Match 'holds another source \(SourceId another-source'
            Set-Content -LiteralPath (Join-Path $folder 'manifest.psd1') -Value "@{ SourceId = 'test-source-0001'; Serial = 5; Files = @{} }"
            $r = Invoke-Tool acme sync
            $r.Text | Should -Match 'has a newer manifest \(5\) than this source \(1\)'
            Test-Path -LiteralPath (Join-Path $folder 'groups.psd1') | Should -BeFalse
            Set-Content -LiteralPath (Join-Path $dir 'publish.psd1') -Value "@{ Target = "
            (Invoke-Tool acme sync).Text | Should -Match "publish\.psd1 can't be read"
        }

        It 'offers to send what was signed before when nothing changed, and fails when the address gives another manifest' {
            $dir = Add-Company 'acme' -Source -Config "@{ Management = @{ Source = '$($script:webBase)/other'; SourceId = 'test-source-0001' } }"
            Add-FakeKey $dir
            Write-Manifest (Join-Path $dir 'source')
            $folder = Join-Path $script:web 'acme2'
            New-Item -ItemType Directory -Force -Path $folder | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'publish.psd1') -Value "@{ Target = '$folder' }"
            New-Item -ItemType Directory -Force -Path (Join-Path $script:web 'other') | Out-Null
            Set-Content -LiteralPath (Join-Path $script:web 'other/manifest.psd1') -Value "@{ SourceId = 'x'; Serial = 0; Files = @{} }"
            $r = Invoke-Typed @('', 'y', 'n') @('acme', 'publish')
            $r.Code | Should -Be 1
            $r.Text | Should -Match 'Sign it again anyway\? \[y/N\]'
            $r.Text | Should -Match 'Send it where the computers read it \(.*acme2\)\? \[y/N\]'
            Test-Path -LiteralPath (Join-Path $folder 'manifest.psd1') | Should -BeTrue
            $r.Text | Should -Match 'still gives manifest 0'
        }

        It 'makes the source a Git repository, sends it only once signed, then commits and pushes each signature' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
            $dir = Add-Company 'acme' -Source -Config '@{}'
            $remote = Join-Path $TestDrive 'acme-remote.git'
            & git init -q --bare $remote
            # Not signed yet: set up, nothing sent
            $r = Invoke-Typed @('g', 'y', $remote) @('acme', 'target')
            $r.Code | Should -Be 0 -Because $r.Text
            $r.Text | Should -Match 'Made it a Git repository'
            $r.Text | Should -Match 'It goes there once signed'
            (Import-PowerShellDataFile -LiteralPath (Join-Path $dir 'publish.psd1')).Target | Should -Be 'git'
            @(& git -C $remote log main --format=%s 2>$null).Count | Should -Be 0

            Write-Manifest (Join-Path $dir 'source')
            $r = Invoke-Tool acme sync
            $r.Code | Should -Be 0 -Because $r.Text
            $r.Text | Should -Match 'Committed: Manifest 1: \d+ files'
            $r.Text | Should -Match 'no Management\.Source yet'
            Add-Content -LiteralPath (Join-Path $dir 'source/choco-reqs.txt') -Value 'signed-now'
            Write-Manifest (Join-Path $dir 'source')
            $r = Invoke-Tool acme sync
            $r.Text | Should -Match 'Committed: Manifest 1: 2 files'
            (& git -C $remote log main --format=%s) | Should -Contain 'Manifest 1: 2 files'
            (& git -C $remote show main:choco-reqs.txt) | Should -Contain 'signed-now'

            # Git must keep the bytes as signed
            Remove-Item -LiteralPath (Join-Path $dir 'source/.gitattributes') -Force   # hidden: needs -Force
            $r = Invoke-Tool acme sync
            $r.Code | Should -Be 1
            $r.Text | Should -Match "git would change the line endings of: .*add the line '\* -text'"

            # A GitHub remote: the address the computers read it from
            $null = Add-Company 'beta' -Source -Config '@{}'
            $r = Invoke-Typed @('g', 'y', 'https://github.com/acme-it/wmanager-beta.git') @('beta', 'target')
            $r.Text | Should -Match 'The computers read it from https://raw\.githubusercontent\.com/acme-it/wmanager-beta/main'
            $r.Text | Should -Match 'pwsh tools/wm\.ps1 beta config'
        }

        It 'gives the source a repository of its own when the companies folder is a Git work tree' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
            $dir = Add-Company 'acme' -Source -Config "@{ LokiToken = 'a secret' }"
            & git init -q $env:WMANAGER_COMPANIES
            Write-Manifest (Join-Path $dir 'source')
            $remote = Join-Path $TestDrive 'acme-own.git'
            & git init -q --bare $remote
            $r = Invoke-Typed @('g', 'y', $remote, 'y') @('acme', 'target')
            $r.Code | Should -Be 0 -Because $r.Text
            $r.Text | Should -Match 'is inside the Git repository'
            (& git -C (Join-Path $dir 'source') rev-parse --show-prefix) | Should -BeNullOrEmpty
            $tree = @(& git -C $remote ls-tree -r --name-only main)
            $tree | Should -Contain 'groups.psd1'
            $tree | Should -Not -Contain 'config/provision.config.psd1'
            @($tree | Where-Object { $_ -like 'acme/*' -or $_ -like 'config/*' -or $_ -like 'keys/*' }).Count | Should -Be 0
        }
    }

    Context 'backup' -Skip:(-not (Get-Command tar -ErrorAction SilentlyContinue)) {
        It 'puts a company into an archive only you can read, and back, never over one that is there' {
            $dir = Add-Company 'acme' -Source -Config "@{ LokiToken = 'a secret' }"
            Add-FakeKey $dir
            $backups = Join-Path $TestDrive ('backups-' + [guid]::NewGuid().ToString('N'))
            $r = Invoke-Tool acme backup $backups
            $r.Code | Should -Be 0 -Because $r.Text
            $archive = @(Get-ChildItem -LiteralPath $backups -Filter 'acme-*.tar.gz')
            $archive.Count | Should -Be 1
            (& stat -c '%a' $archive[0].FullName) | Should -Be '600'
            (& stat -c '%a' $backups) | Should -Be '700'
            $entries = @(& tar -tzf $archive[0].FullName)
            $entries | Should -Contain 'acme/keys/key.pem'
            $entries | Should -Contain 'acme/config/provision.config.psd1'
            $entries | Should -Contain 'acme/source/groups.psd1'
            $entries | Should -Contain 'acme/source/.gitattributes'

            # Elsewhere (another computer): back, as it was
            $env:WMANAGER_COMPANIES = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $r = Invoke-Tool restore $archive[0].FullName
            $r.Code | Should -Be 0 -Because $r.Text
            $r.Text | Should -Match 'Restored acme into'
            [IO.File]::ReadAllText((Join-Path $env:WMANAGER_COMPANIES 'acme/config/provision.config.psd1')) |
                Should -Be ([IO.File]::ReadAllText((Join-Path $dir 'config/provision.config.psd1')))
            $r = Invoke-Tool restore $archive[0].FullName
            $r.Code | Should -Be 1
            $r.Text | Should -Match 'restore never overwrites one'
        }

        It 'puts linked folders in with what they hold, and never overwrites an earlier backup' {
            $dir = Add-Company 'acme' -Source -Config '@{}'
            $keysElsewhere = Join-Path $TestDrive ('keys-' + [guid]::NewGuid().ToString('N'))
            Add-FakeKey $keysElsewhere
            $link = Join-Path $dir 'keys'
            New-Item -ItemType SymbolicLink -Path $link -Target (Join-Path $keysElsewhere 'keys') | Out-Null
            $backups = Join-Path $TestDrive ('linked-' + [guid]::NewGuid().ToString('N'))
            try {
                $r = Invoke-Tool acme backup $backups
                $r.Code | Should -Be 0 -Because $r.Text
                $r = Invoke-Tool acme backup $backups
                $r.Code | Should -Be 0 -Because $r.Text
            } finally {
                [IO.Directory]::Delete($link)   # the link only: cleaning TestDrive must not walk through it
            }
            $archives = @(Get-ChildItem -LiteralPath $backups -Filter 'acme-*Z*.tar.gz')
            $archives.Count | Should -Be 2
            $listing = @(& tar -tvzf $archives[0].FullName)
            ($listing | Where-Object { $_ -match ' acme/keys/key\.pem$' }) | Should -Match '^-'
            @($listing | Where-Object { $_ -match '^l' }).Count | Should -Be 0
            $r = Invoke-Tool backup acme
            $r.Code | Should -Be 1
            $r.Text | Should -Match 'acme is a company: pwsh tools/wm\.ps1 acme backup'
        }

        It 'backs up the other companies when one fails, and says which' {
            $acme = Add-Company 'acme' -Source -Config '@{}'
            $null = Add-Company 'beta' -Config '@{}'
            $secret = Join-Path $acme 'config/unreadable.txt'
            Set-Content -LiteralPath $secret -Value 'x'
            & chmod 000 $secret
            try {
                $backups = Join-Path $TestDrive ('partial-' + [guid]::NewGuid().ToString('N'))
                $r = Invoke-Tool backup $backups
            } finally {
                & chmod 600 $secret
            }
            $r.Code | Should -Be 1
            $r.Text | Should -Match 'acme: ERROR: the backup of acme failed'
            $r.Text | Should -Match 'no backup of acme'
            @(Get-ChildItem -LiteralPath $backups -Filter 'beta-*.tar.gz').Count | Should -Be 1
            @(Get-ChildItem -LiteralPath $backups -Filter 'acme-*').Count | Should -Be 0
        }

        It 'backs up every company, but not into the companies folder' {
            $null = Add-Company 'acme' -Source -Config '@{}'
            $null = Add-Company 'beta' -Config '@{}'
            $backups = Join-Path $TestDrive ('all-' + [guid]::NewGuid().ToString('N'))
            $r = Invoke-Tool backup $backups
            $r.Code | Should -Be 0 -Because $r.Text
            @(Get-ChildItem -LiteralPath $backups -Filter '*.tar.gz' | ForEach-Object { ($_.Name -split '-')[0] } | Sort-Object) -join ',' |
                Should -Be 'acme,beta'
            $r.Text | Should -Match 'keep them somewhere safe, not on the USB drive'
            $r = Invoke-Tool backup (Join-Path $env:WMANAGER_COMPANIES 'backups')
            $r.Code | Should -Be 1
            $r.Text | Should -Match "a backup can't go into"
        }

        It 'restores only an archive of one company''s folder, and leaves nothing behind when it fails' {
            $work = Join-Path $TestDrive ('archives-' + [guid]::NewGuid().ToString('N'))
            foreach ($d in @('acme', 'beta')) { New-Item -ItemType Directory -Force -Path (Join-Path $work "$d/config") | Out-Null }
            & tar -czf (Join-Path $work 'two.tar.gz') -C $work acme beta
            $r = Invoke-Tool restore (Join-Path $work 'two.tar.gz')
            $r.Code | Should -Be 1
            $r.Text | Should -Match 'holds acme, beta, not one company''s folder'
            Set-Content -LiteralPath (Join-Path $TestDrive 'outside.txt') -Value 'x'
            Push-Location $work
            try { & tar -czPf (Join-Path $work 'evil.tar.gz') acme ../outside.txt 2>$null } finally { Pop-Location }
            $r = Invoke-Tool restore (Join-Path $work 'evil.tar.gz')
            $r.Code | Should -Be 1
            $r.Text | Should -Match 'paths outside a company''s folder'
            # A link (a backup has none): a keys folder that points elsewhere
            New-Item -ItemType Directory -Force -Path (Join-Path $work 'linked/acme/config'), (Join-Path $work 'elsewhere') | Out-Null
            $link = Join-Path $work 'linked/acme/keys'
            New-Item -ItemType SymbolicLink -Path $link -Target (Join-Path $work 'elsewhere') | Out-Null
            try { & tar -czf (Join-Path $work 'link.tar.gz') -C (Join-Path $work 'linked') acme }
            finally { [IO.Directory]::Delete($link) }
            $r = Invoke-Tool restore (Join-Path $work 'link.tar.gz')
            $r.Code | Should -Be 1
            $r.Text | Should -Match 'holds links'
            # Not a company's folder: a file, or a folder without source, keys or config
            New-Item -ItemType Directory -Force -Path (Join-Path $work 'project/acme/src') | Out-Null
            & tar -czf (Join-Path $work 'project.tar.gz') -C (Join-Path $work 'project') acme
            $r = Invoke-Tool restore (Join-Path $work 'project.tar.gz')
            $r.Code | Should -Be 1
            $r.Text | Should -Match 'holds no company''s folder'
            # Cut short: tar fails partway
            & tar -czf (Join-Path $work 'acme.tar.gz') -C $work acme
            $bytes = [IO.File]::ReadAllBytes((Join-Path $work 'acme.tar.gz'))
            [IO.File]::WriteAllBytes((Join-Path $work 'short.tar.gz'), $bytes[0..([int]($bytes.Length / 2))])
            $r = Invoke-Tool restore (Join-Path $work 'short.tar.gz')
            $r.Code | Should -Be 1
            @(Get-ChildItem -LiteralPath $env:WMANAGER_COMPANIES -Force -ErrorAction SilentlyContinue).Count | Should -Be 0
            # A company of that name is here already (letter case aside)
            $null = Add-Company 'Acme' -Config '@{}'
            $r = Invoke-Tool restore (Join-Path $work 'acme.tar.gz')
            $r.Code | Should -Be 1
            $r.Text | Should -Match 'there is a company Acme already'
            Test-Path -LiteralPath (Join-Path $env:WMANAGER_COMPANIES 'acme') | Should -BeFalse
        }
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
        # where it goes: later; the wizard: update time, days, Loki, Healthchecks, source, certificate, identifier
        $r = Invoke-Typed @('n', 'y', '', '', '', '', '\\srv\acme', '', '') @('new', 'acme')
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

        # Another key in keys/ (the old one replaced): the source is still signed with the old one
        Remove-Item -LiteralPath (Join-Path $dir 'keys') -Recurse
        Add-TestKey $dir
        (Invoke-Tool acme changes).Text | Should -Match 'Signed with another key'
        (Invoke-Tool list).Text | Should -Match '(?m)^acme\s+.*signed with another key'
    }
}
