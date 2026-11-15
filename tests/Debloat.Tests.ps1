# Tests for lib\Debloat.ps1. To run (Pester 5):
#   Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser
#   Invoke-Pester .\tests

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $root 'lib\Common.ps1')
    . (Join-Path $root 'lib\Debloat.ps1')
}

Describe 'Remove-WmAppxPackages' {
    BeforeEach {
        # Two apps, installed and in the image. Removing BingNews for all users also takes it out of the image
        # (current Windows 11 builds); Todos stays in the image (older builds).
        $script:apps = [System.Collections.ArrayList]@('Microsoft.BingNews', 'Microsoft.Todos')
        $script:image = [System.Collections.ArrayList]@('Microsoft.BingNews', 'Microsoft.Todos')
        $script:warnings = [System.Collections.ArrayList]@()
        Mock Write-WmLog { if ($Level -eq 'warn') { [void]$script:warnings.Add($Message) } }
        Mock Get-AppxPackage {
            $script:apps | Where-Object { $_ -like $Name } |
                ForEach-Object { [pscustomobject]@{ Name = $_; PackageFullName = "${_}_1.0.0.0_x64__8wekyb3d8bbwe" } }
        }
        Mock Remove-AppxPackage {
            $n = ([string]$Package).Split('_')[0]
            $script:apps.Remove($n)
            if ($n -eq 'Microsoft.BingNews') { $script:image.Remove($n) }
        }
        Mock Get-AppxProvisionedPackage {
            $script:image |
                ForEach-Object { [pscustomobject]@{ DisplayName = $_; PackageName = "${_}_1.0.0.0_neutral_~_8wekyb3d8bbwe" } }
        }
        Mock Remove-AppxProvisionedPackage {
            $n = ([string]$PackageName).Split('_')[0]
            if ($n -notin $script:image) { throw 'System nie może odnaleźć określonej ścieżki.' }
            $script:image.Remove($n)
        }
    }

    It 'removes the apps and what is still in the image, without false warnings' {
        Remove-WmAppxPackages -Patterns @('Microsoft.BingNews', 'Microsoft.Todos', '', 'Microsoft.NotThere')
        $script:apps.Count | Should -Be 0
        $script:image.Count | Should -Be 0
        $script:warnings | Should -BeNullOrEmpty
        # the image is read once, after the apps are gone; only Todos is still there to remove
        Should -Invoke Get-AppxProvisionedPackage -Times 1 -Exactly
        Should -Invoke Remove-AppxProvisionedPackage -Times 1 -Exactly
    }

    It 'warns when removing from the image really fails' {
        Mock Remove-AppxProvisionedPackage { throw 'Odmowa dostępu.' }
        Remove-WmAppxPackages -Patterns @('Microsoft.Todos')
        $script:warnings.Count | Should -Be 1
        $script:warnings[0] | Should -BeLike '*z obrazu Microsoft.Todos*Odmowa*'
    }
}
