# Tests for the installer from the internet (install.ps1): the steps that don't need GitHub or provisioning.
# To run (Pester 5):
#   Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser
#   Invoke-Pester .\tests

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $WmInstallNoRun = $true   # load the functions without installing anything
    . (Join-Path $root 'install.ps1')
}

Describe 'Get-WmReleaseAssets' {
    It 'picks the ZIP and SHA256SUMS of a release' {
        $release = [pscustomobject]@{ tag_name = 'v0.1.0'; assets = @(
            [pscustomobject]@{ name = 'install.ps1'; browser_download_url = 'https://x/install.ps1' }
            [pscustomobject]@{ name = 'wmanager-v0.1.0.zip'; browser_download_url = 'https://x/wmanager-v0.1.0.zip' }
            [pscustomobject]@{ name = 'SHA256SUMS'; browser_download_url = 'https://x/SHA256SUMS' }) }
        $a = Get-WmReleaseAssets -Release $release
        $a.Tag | Should -Be 'v0.1.0'
        $a.Zip.browser_download_url | Should -Be 'https://x/wmanager-v0.1.0.zip'
        $a.Sums.name | Should -Be 'SHA256SUMS'
    }

    It 'refuses a release without them' {
        { Get-WmReleaseAssets -Release ([pscustomobject]@{ tag_name = 'v9'; assets = @() }) } | Should -Throw '*v9*'
    }
}

Describe 'Assert-WmSha256' {
    BeforeEach {
        $script:file = Join-Path $TestDrive 'wmanager-v0.1.0.zip'
        [IO.File]::WriteAllBytes($script:file, [byte[]](1, 2, 3))
        $script:hash = (Get-FileHash -LiteralPath $script:file -Algorithm SHA256).Hash.ToLowerInvariant()
        $script:sums = Join-Path $TestDrive 'SHA256SUMS'
    }

    It 'accepts the sum sha256sum writes (text or binary mode)' {
        Set-Content -LiteralPath $script:sums -Value "$($script:hash)  wmanager-v0.1.0.zip", ('0' * 64 + '  install.ps1')
        { Assert-WmSha256 -File $script:file -SumsFile $script:sums } | Should -Not -Throw
        Set-Content -LiteralPath $script:sums -Value "$($script:hash) *wmanager-v0.1.0.zip"
        { Assert-WmSha256 -File $script:file -SumsFile $script:sums } | Should -Not -Throw
    }

    It 'refuses a changed file and a list without the file' {
        Set-Content -LiteralPath $script:sums -Value "$('a' * 64)  wmanager-v0.1.0.zip"
        { Assert-WmSha256 -File $script:file -SumsFile $script:sums } | Should -Throw '*nie zgadza*'
        Set-Content -LiteralPath $script:sums -Value "$($script:hash)  other.zip"
        { Assert-WmSha256 -File $script:file -SumsFile $script:sums } | Should -Throw '*nie zawiera*'
    }
}

Describe 'Get-WmSiblingLocation' {
    It 'finds the certificate next to the configuration' {
        Get-WmSiblingLocation -Location 'https://raw.githubusercontent.com/o/r/main/cfg/provision.config.psd1' -Name 'wmanager-signing.cer' |
            Should -Be 'https://raw.githubusercontent.com/o/r/main/cfg/wmanager-signing.cer'
        # a drive letter that isn't there and a share: only the text of the path matters
        Get-WmSiblingLocation -Location 'Q:\cfg\provision.config.psd1' -Name 'org.cer' | Should -Be 'Q:\cfg\org.cer'
        Get-WmSiblingLocation -Location '\\server\share\wm\provision.config.psd1' -Name 'org.cer' | Should -Be '\\server\share\wm\org.cer'
    }
}

Describe 'Copy-WmConfiguration' {
    BeforeEach {
        $script:src = Join-Path $TestDrive ('src' + [guid]::NewGuid().ToString('N'))
        $script:dst = Join-Path $TestDrive ('dst' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:src, $script:dst | Out-Null
    }

    It 'copies the configuration and, with a management source, its certificate' {
        Set-Content -LiteralPath (Join-Path $script:src 'provision.config.psd1') -Value "@{ Management = @{ Source = 'C:\wm-source'; SourceId = 'abcdefgh'; Certificate = 'org.cer' } }"
        Set-Content -LiteralPath (Join-Path $script:src 'org.cer') -Value 'cert'
        Copy-WmConfiguration -Location (Join-Path $script:src 'provision.config.psd1') -Folder $script:dst
        Test-Path -LiteralPath (Join-Path $script:dst 'provision.config.psd1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:dst 'org.cer') | Should -BeTrue
    }

    It 'needs no certificate without a management source' {
        Set-Content -LiteralPath (Join-Path $script:src 'provision.config.psd1') -Value "@{ UpdateTime = '12:00' }"
        Copy-WmConfiguration -Location (Join-Path $script:src 'provision.config.psd1') -Folder $script:dst
        @(Get-ChildItem -LiteralPath $script:dst).Count | Should -Be 1
    }

    It 'stops on a missing certificate, a file that is not a configuration and a plain http address' {
        Set-Content -LiteralPath (Join-Path $script:src 'provision.config.psd1') -Value "@{ Management = @{ Source = 'C:\wm-source'; SourceId = 'abcdefgh' } }"
        { Copy-WmConfiguration -Location (Join-Path $script:src 'provision.config.psd1') -Folder $script:dst } | Should -Throw '*wmanager-signing.cer*'
        Set-Content -LiteralPath (Join-Path $script:src 'bad.psd1') -Value 'to nie jest konfiguracja ('
        { Copy-WmConfiguration -Location (Join-Path $script:src 'bad.psd1') -Folder $script:dst } | Should -Throw '*poprawną konfiguracją*'
        { Copy-WmConfiguration -Location 'http://example/provision.config.psd1' -Folder $script:dst } | Should -Throw '*https*'
    }
}
