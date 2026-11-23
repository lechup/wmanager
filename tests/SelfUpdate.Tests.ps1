# Tests for the self-update (lib\SelfUpdate.ps1): copying a version into the installed folder, preparing the release
# the management source names, and handing over to it. Windows PowerShell 5.1 (Expand-Archive, powershell.exe).
# The whole switch, with the scheduled task, is tested on a Windows 11 virtual machine (docs/testing.md).
# To run (Pester 5):
#   Invoke-Pester .\tests\SelfUpdate.Tests.ps1

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $root 'lib\Common.ps1')
    . (Join-Path $root 'lib\Choco.ps1')
    . (Join-Path $root 'lib\Managed.ps1')
    . (Join-Path $root 'lib\SelfUpdate.ps1')
    Initialize-WmLanguage -Lang 'en'
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

    # A release ZIP laid out like tools/build-release.sh makes it (wmanager/<file>, '/' in the names); returns its SHA256
    function New-TestRelease {
        param([string]$Path, [hashtable]$Files)
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Create)
        try {
            $zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
            foreach ($name in $Files.Keys) {
                $w = New-Object IO.StreamWriter($zip.CreateEntry("wmanager/$name").Open())
                $w.Write($Files[$name])
                $w.Dispose()
            }
            $zip.Dispose()
        } finally {
            $fs.Dispose()
        }
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }

    # What the management source names for this computer (the cache Get-WmManagedContent returns)
    function Set-Wanted {
        param([string]$Version, [string]$Url, [string]$Sha256, [string]$Group = '')
        $want = $null
        if ($Version) { $want = [pscustomobject]@{ Version = $Version; Url = $Url; Sha256 = $Sha256; Group = $Group } }
        $script:WmManaged = [pscustomobject]@{ Wmanager = $want }
        $script:WmManagedError = $null
    }

    function Get-Logged {
        param([string]$Level)
        return @($script:WmLogBuffer | Where-Object { -not $Level -or $_.Level -eq $Level } | ForEach-Object { $_.Line })
    }

    function New-TestFile {
        param([string]$Path, [string]$Text)
        New-Item -ItemType File -Force -Path $Path -Value $Text | Out-Null
    }

    $config = @{ Management = @{ Source = 'C:\wm-nowhere'; SourceId = 'test-source-0001' } }
}

Describe 'Copy-WmProgramFiles' {
    It 'copies the catalogs, lib, the scripts and VERSION, drops catalogs the new version lacks and keeps the rest' {
        $from = Join-Path $TestDrive 'new'
        $to = Join-Path $TestDrive 'installed'
        foreach ($f in @('lang\en\Common.psd1', 'lib\Common.ps1', 'Update-Packages.ps1', 'VERSION')) { New-TestFile (Join-Path $from $f) "new $f" }
        foreach ($f in @('lang\en\Common.psd1', 'lang\en\Gone.psd1', 'lib\Common.ps1', 'VERSION', 'provision.config.psd1', 'state\x.txt')) {
            New-TestFile (Join-Path $to $f) "old $f"
        }
        Copy-WmProgramFiles -From $from -To $to
        Get-Content -LiteralPath (Join-Path $to 'VERSION') -Raw | Should -Be 'new VERSION'
        Get-Content -LiteralPath (Join-Path $to 'lib\Common.ps1') -Raw | Should -Be 'new lib\Common.ps1'
        Get-Content -LiteralPath (Join-Path $to 'Update-Packages.ps1') -Raw | Should -Be 'new Update-Packages.ps1'
        Get-Content -LiteralPath (Join-Path $to 'lang\en\Common.psd1') -Raw | Should -Be 'new lang\en\Common.psd1'
        Test-Path -LiteralPath (Join-Path $to 'lang\en\Gone.psd1') | Should -BeFalse
        Get-Content -LiteralPath (Join-Path $to 'provision.config.psd1') -Raw | Should -Be 'old provision.config.psd1'
        Get-Content -LiteralPath (Join-Path $to 'state\x.txt') -Raw | Should -Be 'old state\x.txt'
    }

    It 'removes VERSION when the copy has none (a git checkout)' {
        $from = Join-Path $TestDrive 'checkout'
        $to = Join-Path $TestDrive 'installed2'
        foreach ($f in @('lang\en\Common.psd1', 'lib\Common.ps1')) { New-TestFile (Join-Path $from $f) 'x' }
        New-TestFile (Join-Path $to 'VERSION') 'v0.1.0'
        Copy-WmProgramFiles -From $from -To $to
        Test-Path -LiteralPath (Join-Path $to 'VERSION') | Should -BeFalse
    }
}

Describe 'Install-WmProgramFiles' {
    BeforeEach {
        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $new = Join-Path $base 'new'
        $installed = Join-Path $base 'installed'
        $backup = Join-Path $base 'previous'
        foreach ($f in @('lang\en\Common.psd1', 'lib\Common.ps1', 'Update-Packages.ps1', 'VERSION')) {
            New-TestFile (Join-Path $new $f) "new $f"
            New-TestFile (Join-Path $installed $f) "old $f"
        }
    }

    It 'installs the new version and keeps the old one aside' {
        Install-WmProgramFiles -From $new -To $installed -Backup $backup
        Get-Content -LiteralPath (Join-Path $installed 'lib\Common.ps1') -Raw | Should -Be 'new lib\Common.ps1'
        Get-Content -LiteralPath (Join-Path $backup 'lib\Common.ps1') -Raw | Should -Be 'old lib\Common.ps1'
    }

    It 'puts the old version back when the copy stops partway' {
        # The new catalogs are in place, then the copy fails
        Mock Copy-WmProgramFiles -ParameterFilter { $From -eq $new } {
            Copy-Item -LiteralPath (Join-Path $From 'lang\en\Common.psd1') -Destination (Join-Path $To 'lang\en\Common.psd1') -Force
            throw 'disk full'
        }
        { Install-WmProgramFiles -From $new -To $installed -Backup $backup } | Should -Throw '*disk full; the previous version was put back*'
        Get-Content -LiteralPath (Join-Path $installed 'lang\en\Common.psd1') -Raw | Should -Be 'old lang\en\Common.psd1'
        Get-Content -LiteralPath (Join-Path $installed 'VERSION') -Raw | Should -Be 'old VERSION'
    }

    It 'says so when the old version can''t be put back either' {
        Mock Copy-WmProgramFiles -ParameterFilter { $From -eq $new } { throw 'disk full' }
        Mock Copy-WmProgramFiles -ParameterFilter { $From -eq $backup } { throw 'still full' }
        { Install-WmProgramFiles -From $new -To $installed -Backup $backup } | Should -Throw '*disk full; putting the previous version back failed too (still full)*'
    }
}

Describe 'Get-WmSelfUpdateRelease' {
    BeforeEach {
        $script:WmSelfUpdateDir = Join-Path $TestDrive ('self-update-' + [guid]::NewGuid().ToString('N'))
        $script:WmVersion = 'v0.2.0'
        $script:WmLogBuffer.Clear()
    }

    It 'does nothing without a management source, without a version or with the one running' {
        Get-WmSelfUpdateRelease -Config @{} | Should -BeNullOrEmpty
        Set-Wanted
        Get-WmSelfUpdateRelease -Config $config | Should -BeNullOrEmpty
        Set-Wanted -Version 'v0.2.0' -Url 'C:\wm-nowhere\x.zip' -Sha256 ('A' * 64)
        Get-WmSelfUpdateRelease -Config $config | Should -BeNullOrEmpty
        Get-Logged | Should -BeNullOrEmpty
    }

    It 'fetches the release, checks its SHA256 and unpacks it' {
        $zip = Join-Path $TestDrive 'wmanager-v0.3.0.zip'
        $hash = New-TestRelease $zip @{ 'VERSION' = 'v0.3.0'; 'Update-Packages.ps1' = 'param([switch]$SelfInstall)' }
        Set-Wanted -Version 'v0.3.0' -Url $zip -Sha256 $hash -Group 'test'
        $r = Get-WmSelfUpdateRelease -Config $config
        $r.Version | Should -Be 'v0.3.0'
        $r.Folder | Should -Be (Join-Path $script:WmSelfUpdateDir 'unpacked\wmanager')
        Test-Path -LiteralPath (Join-Path $r.Folder 'Update-Packages.ps1') | Should -BeTrue
        (Get-Logged -Level 'info') -join "`n" | Should -Match 'wmanager v0\.2\.0 -> wmanager v0\.3\.0 \(group test\)'
    }

    It 'goes back to an older version too' {
        $zip = Join-Path $TestDrive 'wmanager-v0.1.5.zip'
        $hash = New-TestRelease $zip @{ 'VERSION' = 'v0.1.5'; 'Update-Packages.ps1' = 'param([switch]$SelfInstall)' }
        Set-Wanted -Version 'v0.1.5' -Url $zip -Sha256 $hash
        (Get-WmSelfUpdateRelease -Config $config).Version | Should -Be 'v0.1.5'
    }

    It 'refuses a file whose SHA256 differs from the one in the source' {
        $zip = Join-Path $TestDrive 'wmanager-v0.3.0-b.zip'
        $null = New-TestRelease $zip @{ 'VERSION' = 'v0.3.0'; 'Update-Packages.ps1' = 'param([switch]$SelfInstall)' }
        Set-Wanted -Version 'v0.3.0' -Url $zip -Sha256 ('B' * 64)
        Get-WmSelfUpdateRelease -Config $config | Should -BeNullOrEmpty
        (Get-Logged -Level 'error') -join "`n" | Should -Match 'the management source names B{64}; not installed'
        Test-Path -LiteralPath $script:WmSelfUpdateDir | Should -BeFalse   # nothing stays behind
    }

    It 'refuses a ZIP that is not the named version' {
        $zip = Join-Path $TestDrive 'wmanager-v0.3.0-c.zip'
        $hash = New-TestRelease $zip @{ 'VERSION' = 'v0.4.0'; 'Update-Packages.ps1' = 'param([switch]$SelfInstall)' }
        Set-Wanted -Version 'v0.3.0' -Url $zip -Sha256 $hash
        Get-WmSelfUpdateRelease -Config $config | Should -BeNullOrEmpty
        (Get-Logged -Level 'error') -join "`n" | Should -Match 'not the wmanager v0\.3\.0 release'
        Test-Path -LiteralPath $script:WmSelfUpdateDir | Should -BeFalse
    }

    It 'only warns when the release cannot be fetched, so the next update tries again' {
        Set-Wanted -Version 'v0.3.0' -Url (Join-Path $TestDrive 'missing.zip') -Sha256 ('A' * 64)
        Get-WmSelfUpdateRelease -Config $config | Should -BeNullOrEmpty
        Get-Logged -Level 'error' | Should -BeNullOrEmpty
        (Get-Logged -Level 'warn') -join "`n" | Should -Match 'Cannot download wmanager v0\.3\.0: .*Staying on wmanager v0\.2\.0'
    }
}

Describe 'Invoke-WmSelfInstall' {
    It 'runs the new Update-Packages.ps1 with -SelfInstall and returns its exit code' {
        $folder = Join-Path $TestDrive 'handover'
        $out = Join-Path $TestDrive 'handover.txt'
        New-TestFile (Join-Path $folder 'Update-Packages.ps1') @"
param([switch]`$SelfInstall, [string]`$Lang)
Set-Content -LiteralPath '$out' -Value "`$SelfInstall `$Lang"
exit 7
"@
        Invoke-WmSelfInstall -Folder $folder -Lang 'pl' | Should -Be 7
        (Get-Content -LiteralPath $out -Raw).Trim() | Should -Be 'True pl'
    }
}
