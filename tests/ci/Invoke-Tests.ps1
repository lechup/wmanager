# CI: runs the Pester tests in Windows PowerShell 5.1.
#   -Kind Unit          everything except the integration tests (default)
#   -Kind Integration   tests\Managed.Integration.Tests.ps1: they change the computer (root store, ProgramData,
#                       scheduled tasks), so only on a throwaway CI runner, with WM_CI_SOURCES set
param([ValidateSet('Unit', 'Integration')][string]$Kind = 'Unit')

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if (-not (Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge [version]'5.5.0' })) {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
    Install-Module Pester -MinimumVersion 5.5.0 -Force -SkipPublisherCheck -Scope CurrentUser
}
Import-Module Pester -MinimumVersion 5.5.0

$config = New-PesterConfiguration
$config.Run.Path = Split-Path $PSScriptRoot -Parent
$config.Run.Exit = $true
$config.Output.Verbosity = 'Detailed'
if ($Kind -eq 'Integration') { $config.Filter.Tag = 'Integration' } else { $config.Filter.ExcludeTag = 'Integration' }
Invoke-Pester -Configuration $config
