# Sign-in scripts (wmanager-Logon task, SYSTEM account, at every sign-in), from the management source: the scripts in
# groups/<group>/logon/ of this computer's groups run as the user who signed in, in that user's session, hidden, with
# the secrets they name (# wmanager-secrets:) in their environment only. Each sign-in is served once; a user who
# signs in again gets them again. Uses the verified copy of the source as it is (it never fetches). Output goes to the
# daily log logs\logon-YYYY-MM-DD.log and to Loki.
[CmdletBinding()]
param([string]$Lang)

$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
. (Join-Path $here 'lib\Common.ps1')
. (Join-Path $here 'lib\Choco.ps1')
. (Join-Path $here 'lib\Managed.ps1')
. (Join-Path $here 'lib\UserSession.ps1')
Initialize-WmLanguage -Lang $Lang

$config = Import-WmConfig (Join-Path $here 'provision.config.psd1')
try {
    if (-not (Get-WmManagementSettings $config)) { exit 0 }
} catch {
    Write-Host (Get-WmText 'jobs.management_settings_error' @(Get-WmErrorText $_))
    exit 1
}

# No lock: the scheduled update may hold it for long, and these only read the verified copy (lib\Managed.ps1)
Initialize-WmLog 'logon' -Daily
$script:WmManagedQuiet = $true
$failed = $false
try {
    Invoke-WmLogonScripts -Config $config
} catch {
    $failed = $true
    Write-WmLog -Key 'logon.run_failed' -Arguments @(Get-WmErrorText $_) -Level error
} finally {
    if ($script:WmErrors -gt 0) { $failed = $true }
    Send-WmLokiLog -Config $config
}

if ($failed) { exit 1 }
exit 0
