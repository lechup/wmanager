# Tests for the installer from the internet: install.ps1 (download and check) and lib\Install.ps1 (configuration),
# the steps that need neither GitHub nor provisioning. To run (Pester 5):
#   Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser
#   Invoke-Pester .\tests

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $WmInstallNoRun = $true   # load the functions without installing anything
    . (Join-Path $root 'install.ps1')
    . (Join-Path $root 'lib\Common.ps1')
    . (Join-Path $root 'lib\Install.ps1')   # without -Folder it only defines its functions
}

Describe 'install.ps1' {
    It 'is plain ASCII without a BOM, so "irm | iex" works in Windows PowerShell 5.1' {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $root 'install.ps1'))
        @($bytes | Where-Object { $_ -ge 0x80 }).Count | Should -Be 0
    }
}

Describe 'Get-WmZipName' {
    It 'finds the release ZIP in SHA256SUMS' {
        $sums = Join-Path $TestDrive 'SHA256SUMS'
        Set-Content -LiteralPath $sums -Value ('a' * 64 + '  wmanager-v0.1.0.zip'), ('b' * 64 + '  install.ps1')
        Get-WmZipName -SumsFile $sums | Should -Be 'wmanager-v0.1.0.zip'
        Set-Content -LiteralPath $sums -Value ('b' * 64 + '  install.ps1')
        { Get-WmZipName -SumsFile $sums } | Should -Throw '*wmanager-*.zip*'
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

Describe 'ConvertFrom-WmPastedPath' {
    It 'drops the quotes of a path copied from Explorer' {
        ConvertFrom-WmPastedPath ' "E:\wm\provision.config.psd1" ' | Should -Be 'E:\wm\provision.config.psd1'
        ConvertFrom-WmPastedPath "'\\server\share\p.psd1'" | Should -Be '\\server\share\p.psd1'
        ConvertFrom-WmPastedPath '' | Should -Be ''
    }
}

Describe 'Get-WmSiblingLocation' {
    It 'finds the certificate next to the configuration, keeping a token in the query' {
        Get-WmSiblingLocation -Location 'https://raw.githubusercontent.com/o/r/main/cfg/provision.config.psd1' -Name 'wmanager-signing.cer' |
            Should -Be 'https://raw.githubusercontent.com/o/r/main/cfg/wmanager-signing.cer'
        Get-WmSiblingLocation -Location 'https://files.example/cfg/provision.config.psd1?token=abc' -Name 'org.cer' |
            Should -Be 'https://files.example/cfg/org.cer?token=abc'
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
        $script:cfg = Join-Path $script:src 'provision.config.psd1'
    }

    It 'copies the configuration and, with a management source, its certificate' {
        Set-Content -LiteralPath $script:cfg -Value "@{ Management = @{ Source = 'C:\wm-source'; SourceId = 'abcdefgh'; Certificate = 'org.cer' } }"
        Set-Content -LiteralPath (Join-Path $script:src 'org.cer') -Value 'cert'
        Copy-WmConfiguration -Location $script:cfg -Folder $script:dst
        Test-Path -LiteralPath (Join-Path $script:dst 'provision.config.psd1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:dst 'org.cer') | Should -BeTrue
    }

    It 'needs no certificate without a management source' {
        Set-Content -LiteralPath $script:cfg -Value "@{ UpdateTime = '12:00' }"
        Copy-WmConfiguration -Location $script:cfg -Folder $script:dst
        @(Get-ChildItem -LiteralPath $script:dst).Count | Should -Be 1
    }

    It 'refuses what provisioning would refuse: a certificate path, a bad source identifier' {
        Set-Content -LiteralPath $script:cfg -Value "@{ Management = @{ Source = 'C:\wm-source'; SourceId = 'abcdefgh'; Certificate = '..\x.cer' } }"
        { Copy-WmConfiguration -Location $script:cfg -Folder $script:dst } | Should -Throw '*Certificate*'
        Set-Content -LiteralPath $script:cfg -Value "@{ Management = @{ Source = 'C:\wm-source'; SourceId = 'zle id' } }"
        { Copy-WmConfiguration -Location $script:cfg -Folder $script:dst } | Should -Throw '*SourceId*'
    }

    It 'stops on a missing certificate, a file that is not a configuration and a plain http address' {
        Set-Content -LiteralPath $script:cfg -Value "@{ Management = @{ Source = 'C:\wm-source'; SourceId = 'abcdefgh' } }"
        { Copy-WmConfiguration -Location $script:cfg -Folder $script:dst } | Should -Throw '*wmanager-signing.cer*'
        Set-Content -LiteralPath (Join-Path $script:src 'bad.psd1') -Value 'to nie jest konfiguracja ('
        { Copy-WmConfiguration -Location (Join-Path $script:src 'bad.psd1') -Folder $script:dst } | Should -Throw '*poprawną konfiguracją*'
        { Copy-WmConfiguration -Location 'http://example/provision.config.psd1' -Folder $script:dst } | Should -Throw '*https*'
    }
}
