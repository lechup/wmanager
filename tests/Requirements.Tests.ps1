# Tests for the choco-reqs.txt parser. To run (Pester 5):
#   Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser
#   Invoke-Pester .\tests

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $root 'lib\Common.ps1')
    . (Join-Path $root 'lib\Choco.ps1')
    Initialize-WmLanguage -Lang 'en'   # the errors are checked in English
}

Describe 'ConvertFrom-WmRequirements' {
    It 'reads a name without a version as latest' {
        $r = ConvertFrom-WmRequirements -Text 'googlechrome'
        $r.Count | Should -Be 1
        $r[0].Name | Should -Be 'googlechrome'
        $r[0].Version | Should -BeNullOrEmpty
        $r[0].Pinned | Should -BeFalse
        $r[0].NoUpdate | Should -BeFalse
    }

    It 'treats @latest as no version' {
        $r = ConvertFrom-WmRequirements -Text 'libreoffice-fresh@latest'
        $r[0].Version | Should -BeNullOrEmpty
        $r[0].Pinned | Should -BeFalse
    }

    It 'pins the version given after @' {
        $r = ConvertFrom-WmRequirements -Text '7zip@24.8.0'
        $r[0].Name | Should -Be '7zip'
        $r[0].Version | Should -Be '24.8.0'
        $r[0].Pinned | Should -BeTrue
    }

    It 'recognizes !noupdate' {
        $r = ConvertFrom-WmRequirements -Text 'firefox !noupdate'
        $r[0].NoUpdate | Should -BeTrue
    }

    It 'skips comments and empty lines' {
        $text = "# header`r`n`r`nvlc   # player`n  `n7zip"
        $r = ConvertFrom-WmRequirements -Text $text
        $r.Count | Should -Be 2
        $r[0].Name | Should -Be 'vlc'
        $r[1].Name | Should -Be '7zip'
    }

    It 'passes parameters after | without the outer quotes' {
        $r = ConvertFrom-WmRequirements -Text 'vlc | --params "/NoDesktopShortcut /Language:pl"'
        $r[0].ExtraArgs | Should -Be @('--params', '/NoDesktopShortcut /Language:pl')
    }

    It 'returns an empty list for an empty file' {
        $r = ConvertFrom-WmRequirements -Text "# only a comment`n"
        $r.Count | Should -Be 0
    }

    It 'rejects an unknown option' {
        { ConvertFrom-WmRequirements -Text 'vlc !cos' } | Should -Throw -ExpectedMessage "Line 1: unknown option '!cos'*"
    }

    It 'rejects a duplicate package' {
        { ConvertFrom-WmRequirements -Text "vlc`nVLC@3.0.21" } | Should -Throw -ExpectedMessage "Line 2: package 'VLC' appears a second time (first in line 1)"
    }

    It 'rejects an invalid version' {
        { ConvertFrom-WmRequirements -Text 'vlc@abc' } | Should -Throw -ExpectedMessage "Line 1: invalid version 'abc' for 'vlc'"
    }

    It 'reads the publisher of !signer, in quotes or without' {
        $r = ConvertFrom-WmRequirements -Text "firefox !signer=`"Mozilla Corporation`" !noupdate | --params `"/X`"`nzoom !signer=Zoom   # comment`nvlc"
        $r[0].Signer | Should -Be 'Mozilla Corporation'
        $r[0].NoUpdate | Should -BeTrue
        $r[0].ExtraArgs | Should -Be @('--params', '/X')
        $r[1].Signer | Should -Be 'Zoom'
        $r[2].Signer | Should -BeNullOrEmpty
    }

    It 'rejects !signer without a name, twice, or with a quote not closed: <_>' -ForEach @(
        'vlc !signer=', 'vlc !signer=""', 'vlc !signer=a !signer=b', 'vlc !signer="Video LAN', 'vlc !signerx'
    ) {
        { ConvertFrom-WmRequirements -Text $_ } | Should -Throw -ExpectedMessage 'Line 1: !signer needs the publisher*'
    }

    It 'tells the same package apart by its publisher when lists are joined' {
        $a = ConvertFrom-WmRequirements -Text 'firefox !signer=A'
        $b = ConvertFrom-WmRequirements -Text 'firefox !signer=B'
        Get-WmRequirementSpec $a[0] | Should -Not -Be (Get-WmRequirementSpec $b[0])
    }

    It 'reads the bundled choco-reqs.txt without errors' {
        $text = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'choco-reqs.txt') -Raw -Encoding UTF8
        $r = ConvertFrom-WmRequirements -Text $text
        $r.Count | Should -BeGreaterThan 0
        ($r | Where-Object Name -eq 'googlechrome').NoUpdate | Should -BeTrue
    }
}

Describe 'Format-WmChocoArgs' {
    It 'masks the value after -p and --password' {
        Format-WmChocoArgs @('source', 'add', '-n', 'company', '-u', 'bob', '-p', 'S3cret') | Should -Be 'source add -n company -u bob -p ***'
        Format-WmChocoArgs @('source', 'add', '--password', 'S3cret') | Should -Be 'source add --password ***'
    }

    It 'masks the value in the --flag=value form' {
        Format-WmChocoArgs @('apikey', '--api-key=abc123') | Should -Be 'apikey --api-key=***'
    }

    It 'leaves other arguments unchanged' {
        Format-WmChocoArgs @('upgrade', 'vlc', '--version', '3.0.21', '-y') | Should -Be 'upgrade vlc --version 3.0.21 -y'
    }
}

Describe 'Get-WmChecksumMismatch' {
    It 'finds the download choco refused, and the https address it came from' {
        # As choco 2.x wrote it on a Windows 11 test machine
        $out = @(
            'Downloading googlechrome 64 bit'
            "  from 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi'"
            'Download of googlechromestandaloneenterprise64.msi (-1 B) completed.'
            "Error - hashes do not match. Actual value was 'AA958C31C82A744EBA52E1354BF2D97AE3B413D5ECD14125BDF7DB1B1F44C99B'."
            "ERROR: Checksum for 'C:\Users\tester\AppData\Local\Temp\chocolatey\GoogleChrome\159.0.8154.13\googlechromestandaloneenterprise64.msi' did not meet '3a6e02f372f35dd9f97b4109440c5622e02db4c42406a7fd99d08145a5276ba0' for checksum type 'sha256'. Consider passing the actual checksums through with --checksum --checksum64 once you validate the checksums are appropriate. A less secure option is to pass --ignore-checksums if necessary."
            'The install of GoogleChrome was NOT successful.'
        )
        $m = Get-WmChecksumMismatch -Output $out
        $m.File | Should -Be 'C:\Users\tester\AppData\Local\Temp\chocolatey\GoogleChrome\159.0.8154.13\googlechromestandaloneenterprise64.msi'
        $m.Url | Should -Be 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi'
    }

    It 'keeps no address that is not https, and no file without a full path' {
        $m = Get-WmChecksumMismatch -Output @("  from 'http://example.com/x.msi'", "Checksum for 'C:\t\x.msi' did not meet 'ab' for checksum type 'sha256'.")
        $m.File | Should -Be 'C:\t\x.msi'
        $m.Url | Should -BeNullOrEmpty
        Get-WmChecksumMismatch -Output @("Checksum for 'x.msi' did not meet 'ab' for checksum type 'sha256'.") | Should -BeNullOrEmpty
    }

    It 'finds nothing when choco failed for another reason' {
        Get-WmChecksumMismatch -Output @('The package was not found with the source(s) listed.') | Should -BeNullOrEmpty
        Get-WmChecksumMismatch -Output @() | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-WmChocoPackage' {
    BeforeEach {
        $script:log = New-Object System.Collections.Generic.List[string]
        Mock Write-WmLog { if ($Key) { [void]$script:log.Add((Get-WmText -Key $Key -Arguments $Arguments -English)) } }
        # The download choco refused, where it keeps it
        $script:download = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '\chrome64.msi')
        New-Item -ItemType Directory -Force -Path (Split-Path $script:download) | Out-Null
        Set-Content -LiteralPath $script:download -Value 'the new version' -Encoding ASCII
        $script:hash = (Get-FileHash -LiteralPath $script:download -Algorithm SHA256).Hash.ToLowerInvariant()
        $script:refused = @("  from 'https://dl.example.com/chrome64.msi'", "ERROR: Checksum for '$($script:download)' did not meet 'abc' for checksum type 'sha256'.")
        # choco: refuses the download at first, installs it when given its checksum
        $script:runs = New-Object System.Collections.Generic.List[string]
        $script:firstCode = 1
        Mock Invoke-WmChoco {
            [void]$script:runs.Add($Arguments -join ' ')
            if ($Arguments -match '^--checksum=') { $script:WmChocoOutput = @('installed'); return 0 }
            $script:WmChocoOutput = $script:refused
            return $script:firstCode
        }
        Mock Get-WmFileSigner { [pscustomobject]@{ Valid = $true; Name = 'Google LLC'; Why = 'Valid' } }
        Mock Save-WmWebFile { }
        $script:chrome = [pscustomobject]@{ Name = 'googlechrome'; Signer = $null }
        $script:install = @('install', 'googlechrome', '-y', '--no-progress')
    }

    It 'installs a Chrome download whose checksum is behind once Google''s signature vouches for it' {
        Invoke-WmChocoPackage $script:chrome $script:install | Should -Be 0
        $script:runs.Count | Should -Be 2
        $script:runs[1] | Should -Be "install googlechrome -y --no-progress --checksum=$($script:hash) --checksum64=$($script:hash) --checksumtype=sha256 --checksumtype64=sha256"
        Should -Invoke Get-WmFileSigner -Times 1 -ParameterFilter { $Path -eq $script:download }
        Should -Invoke Save-WmWebFile -Times 0   # choco's own copy
        $script:log -join "`n" | Should -Match 'chrome64.msi is signed by Google LLC: installing it with its own checksum'
    }

    It 'doesn''t install a download signed by someone else, or not validly' {
        Mock Get-WmFileSigner { [pscustomobject]@{ Valid = $true; Name = 'Someone Else'; Why = 'Valid' } }
        Invoke-WmChocoPackage $script:chrome $script:install | Should -Be 1
        Mock Get-WmFileSigner { [pscustomobject]@{ Valid = $false; Name = $null; Why = 'NotSigned' } }
        Invoke-WmChocoPackage $script:chrome $script:install | Should -Be 1
        $script:runs.Count | Should -Be 2   # once each, no second run
        $script:log -join "`n" | Should -Match 'chrome64.msi is not validly signed by Google LLC \(Valid, Someone Else\): not installed'
        $script:log -join "`n" | Should -Match 'chrome64.msi is not validly signed by Google LLC \(NotSigned\): not installed'
    }

    It 'checks the publisher given with !signer' {
        Mock Get-WmFileSigner { [pscustomobject]@{ Valid = $true; Name = 'Mozilla Corporation'; Why = 'Valid' } }
        Invoke-WmChocoPackage ([pscustomobject]@{ Name = 'firefox'; Signer = 'Mozilla Corporation' }) @('install', 'firefox') | Should -Be 0
        $script:runs.Count | Should -Be 2
    }

    It 'says what to do for a package without a publisher, and doesn''t run choco again' {
        Invoke-WmChocoPackage ([pscustomobject]@{ Name = 'vlc'; Signer = $null }) @('install', 'vlc') | Should -Be 1
        $script:runs.Count | Should -Be 1
        Should -Invoke Get-WmFileSigner -Times 0
        $script:log -join "`n" | Should -Match 'vlc: the download doesn''t match .*With !signer="publisher"'
    }

    It 'leaves alone a success and a failure for another reason' {
        $script:firstCode = 0
        Invoke-WmChocoPackage $script:chrome $script:install | Should -Be 0
        $script:firstCode = 1; $script:refused = @('The package was not found with the source(s) listed.')
        Invoke-WmChocoPackage $script:chrome $script:install | Should -Be 1
        Should -Invoke Get-WmFileSigner -Times 0
        $script:log.Count | Should -Be 0
    }

    It 'downloads the file again from its https address when choco''s copy is gone, and checks that one' {
        Remove-Item -LiteralPath $script:download
        Mock Save-WmWebFile { Set-Content -LiteralPath $Path -Value 'the new version' -Encoding ASCII }
        Invoke-WmChocoPackage $script:chrome $script:install | Should -Be 0
        Should -Invoke Save-WmWebFile -Times 1 -ParameterFilter { $Url -eq 'https://dl.example.com/chrome64.msi' -and $Path -eq $script:download }
        $script:runs[1] | Should -Match "--checksum=$($script:hash) "
    }

    It 'gives up when the copy is gone and there is no https address, or the download fails' {
        Remove-Item -LiteralPath $script:download
        $script:refused = @("ERROR: Checksum for '$($script:download)' did not meet 'abc' for checksum type 'sha256'.")
        Invoke-WmChocoPackage $script:chrome $script:install | Should -Be 1
        $script:refused = @("  from 'https://dl.example.com/chrome64.msi'") + $script:refused
        Mock Save-WmWebFile { throw 'The remote name could not be resolved' }
        Invoke-WmChocoPackage $script:chrome $script:install | Should -Be 1
        Should -Invoke Get-WmFileSigner -Times 0
        $script:log -join "`n" | Should -Match 'the download to check is gone'
        $script:log -join "`n" | Should -Match 'couldn''t be fetched from https://dl.example.com/chrome64.msi: The remote name'
    }
}

# Real choco, with a package of its own whose download has a checksum that doesn't match: a file signed by the CI's
# throwaway key (tests/ci/build-sources.sh, "wmanager CI"), trusted in the root store for the test
Describe 'A download whose checksum does not match, with real choco' -Tag 'Integration' -Skip:(-not $env:WM_CI_SOURCES) {
    BeforeAll {
        Mock Write-WmLog { if ($Key) { [void]$script:log.Add((Get-WmText -Key $Key -Arguments $Arguments -English)) } }
        $script:log = New-Object System.Collections.Generic.List[string]
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (Join-Path $env:WM_CI_SOURCES 'wmanager-signing.cer')
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root', 'LocalMachine')
        $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $script:addedCert = -not ($store.Certificates | Where-Object Thumbprint -eq $cert.Thumbprint)
        if ($script:addedCert) { $store.Add($cert) }
        $store.Close()
        $script:cert = $cert

        $work = 'C:\wm-ci\choco-signed'
        if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
        New-Item -ItemType Directory -Force -Path "$work\pkg\tools", "$work\repo" | Out-Null
        Copy-Item -LiteralPath (Join-Path $env:WM_CI_SOURCES 'v1\manifest.psd1') -Destination "$work\signed.psd1"
        $script:installed = "$work\installed.psd1"
        # The package's checksum is of another file, as when the publisher replaced the download with a new version
        @"
`$ErrorActionPreference = 'Stop'
`$file = Join-Path `$env:TEMP 'chocolatey\wmci-signed\1.0.0\signed.psd1'
Get-ChocolateyWebFile -PackageName 'wmci-signed' -FileFullPath `$file -Url 'file:///$($work -replace '\\', '/')/signed.psd1' -Checksum '$('0' * 64)' -ChecksumType 'sha256'
Copy-Item -LiteralPath `$file -Destination '$($script:installed)' -Force
"@ | Set-Content -LiteralPath "$work\pkg\tools\chocolateyInstall.ps1" -Encoding UTF8
        @'
<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://schemas.microsoft.com/packaging/2015/06/nuspec.xsd">
  <metadata><id>wmci-signed</id><version>1.0.0</version><authors>wmanager CI</authors>
    <description>wmanager CI: a download whose checksum does not match the package</description></metadata>
  <files><file src="tools\**" target="tools" /></files>
</package>
'@ | Set-Content -LiteralPath "$work\pkg\wmci-signed.nuspec" -Encoding UTF8
        & $script:WmChocoExe pack "$work\pkg\wmci-signed.nuspec" --out "$work\repo" | Out-Null
        $script:installArgs = @('install', 'wmci-signed', '-y', '--no-progress', "--source=$work\repo")
    }
    AfterAll {
        & $script:WmChocoExe uninstall wmci-signed -y --skip-autouninstaller | Out-Null
        if ($script:addedCert) {
            $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root', 'LocalMachine')
            $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
            $store.Remove($script:cert)
            $store.Close()
        }
    }

    It 'doesn''t install it when it is signed by someone else than the publisher given' {
        $code = Invoke-WmChocoPackage ([pscustomobject]@{ Name = 'wmci-signed'; Signer = 'Someone Else' }) $script:installArgs
        $code | Should -Not -Be 0
        Test-Path -LiteralPath $script:installed | Should -BeFalse
        $script:log -join "`n" | Should -Match 'signed.psd1 is not validly signed by Someone Else \(Valid, wmanager CI\)'
    }

    It 'installs it once the signature of the publisher given vouches for it' {
        $script:log.Clear()
        $code = Invoke-WmChocoPackage ([pscustomobject]@{ Name = 'wmci-signed'; Signer = 'wmanager CI' }) $script:installArgs
        $script:WmChocoOutput | ForEach-Object { Write-Host "  choco: $_" }
        $code | Should -Be 0
        $script:log -join "`n" | Should -Match 'signed.psd1 is signed by wmanager CI: installing it with its own checksum'
        (Get-FileHash -LiteralPath $script:installed).Hash | Should -Be (Get-FileHash -LiteralPath 'C:\wm-ci\choco-signed\signed.psd1').Hash
    }
}

Describe 'ConvertTo-WmJsonString' {
    It 'escapes quotes, backslashes and newlines' {
        ConvertTo-WmJsonString ('a"b\c' + "`n") | Should -Be '"a\"b\\c\n"'
    }
}
