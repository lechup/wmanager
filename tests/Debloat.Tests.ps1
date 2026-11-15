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
        # BingNews and Todos are installed and in the image, Maps only in the image. Removing BingNews for all
        # users also takes it out of the image (current Windows 11 builds); Todos stays there (older builds).
        $script:apps = [System.Collections.ArrayList]@('Microsoft.BingNews', 'Microsoft.Todos')
        $script:image = [System.Collections.ArrayList]@('Microsoft.BingNews', 'Microsoft.Todos', 'Microsoft.WindowsMaps')
        $script:ops = [System.Collections.ArrayList]@()
        $script:warnings = [System.Collections.ArrayList]@()
        Mock Write-WmLog { if ($Level -eq 'warn') { [void]$script:warnings.Add($Message) } }
        Mock Get-AppxPackage {
            $script:apps | Where-Object { $_ -like $Name } |
                ForEach-Object { [pscustomobject]@{ Name = $_; PackageFullName = "${_}_1.0.0.0_x64__8wekyb3d8bbwe" } }
        }
        Mock Remove-AppxPackage {
            $n = ([string]$Package).Split('_')[0]
            [void]$script:ops.Add("app:$n")
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
            [void]$script:ops.Add("image:$n")
            $script:image.Remove($n)
        }
    }

    It 'removes the apps from the image first, then the installed copies, without warnings' {
        Remove-WmAppxPackages -Patterns @('Microsoft.BingNews', 'Microsoft.Todos', '', '   ', 'Microsoft.NotThere')
        $script:apps.Count | Should -Be 0
        $script:image | Should -Be @('Microsoft.WindowsMaps')
        $script:warnings | Should -BeNullOrEmpty
        $script:ops | Should -Be @('image:Microsoft.BingNews', 'image:Microsoft.Todos', 'app:Microsoft.BingNews', 'app:Microsoft.Todos')
        Should -Invoke Get-AppxProvisionedPackage -Times 1 -Exactly
    }

    It 'removes an image package once when several patterns match it' {
        Remove-WmAppxPackages -Patterns @('Microsoft.Todos', 'Microsoft.To*', ' Microsoft.Todos ')
        $script:warnings | Should -BeNullOrEmpty
        Should -Invoke Remove-AppxProvisionedPackage -Times 1 -Exactly
        Should -Invoke Remove-AppxPackage -Times 1 -Exactly
    }

    It 'removes an app that is only in the image' {
        Remove-WmAppxPackages -Patterns @('Microsoft.WindowsMaps')
        $script:image | Should -Not -Contain 'Microsoft.WindowsMaps'
        $script:warnings | Should -BeNullOrEmpty
    }

    It 'warns when removing from the image really fails' {
        Mock Remove-AppxProvisionedPackage { throw 'Odmowa dostępu.' }
        Remove-WmAppxPackages -Patterns @('Microsoft.Todos')
        $script:warnings.Count | Should -Be 1
        $script:warnings[0] | Should -BeLike '*z obrazu Microsoft.Todos*Odmowa*'
    }

    It 'warns when the image cannot be read and still removes the installed apps' {
        Mock Get-AppxProvisionedPackage { throw 'DISM jest zajęty.' }
        Remove-WmAppxPackages -Patterns @('Microsoft.BingNews', 'Microsoft.Todos')
        $script:apps.Count | Should -Be 0
        $script:warnings.Count | Should -Be 1
        $script:warnings[0] | Should -BeLike '*odczytać*DISM*'
    }
}
