# Startup scripts (wmanager-Startup task, SYSTEM account, a minute after every start of the computer), from the
# management source: the scripts in groups/<group>/startup/ of this computer's groups, as SYSTEM, usually before anyone
# signs in, with the secrets they name (# wmanager-secrets:) in their environment only. Uses the verified copy of the
# source as it is (it never fetches). Output goes to the daily log logs\startup-YYYY-MM-DD.log and to Loki.
[CmdletBinding()]
param([string]$Lang)

$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
. (Join-Path $here 'lib\Common.ps1')
. (Join-Path $here 'lib\Choco.ps1')
. (Join-Path $here 'lib\Managed.ps1')
Initialize-WmLanguage -Lang $Lang

$config = Import-WmConfig (Join-Path $here 'provision.config.psd1')
try {
    if (-not (Get-WmManagementSettings $config)) { exit 0 }
} catch {
    Write-Host (Get-WmText 'jobs.management_settings_error' @(Get-WmErrorText $_))
    exit 1
}

# No lock: a scheduled update that catches up at startup may hold it for long, and these only read the verified copy
Initialize-WmLog 'startup' -Daily
$script:WmManagedQuiet = $true
$failed = $false
try {
    Invoke-WmStartupScripts -Config $config
} catch {
    $failed = $true
    Write-WmLog -Key 'startup.run_failed' -Arguments @(Get-WmErrorText $_) -Level error
} finally {
    if ($script:WmErrors -gt 0) { $failed = $true }
    # Without the network yet, the batch waits in logs\outbox for the next sending
    Send-WmLokiLog -Config $config
}

if ($failed) { exit 1 }
exit 0
