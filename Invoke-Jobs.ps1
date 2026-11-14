# Group jobs (wmanager-Jobs task, SYSTEM account, every hour): runs the jobs of this computer's groups
# whose time has come (groups/<group>/jobs/hourly|daily|weekly/*.ps1 in the management source).
# Uses the verified copy of the source and fetches a new version at most once every 20 hours (the weekly
# run fetches too). Job output goes to the daily log logs\jobs-YYYY-MM-DD.log and to Loki.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
. (Join-Path $here 'lib\Common.ps1')
. (Join-Path $here 'lib\Choco.ps1')
. (Join-Path $here 'lib\Managed.ps1')

$config = Import-WmConfig (Join-Path $here 'provision.config.psd1')
try {
    if (-not (Get-WmManagementSettings $config)) { exit 0 }
} catch {
    Write-Host "Błąd w ustawieniach Management: $($_.Exception.Message)"
    exit 1
}

# Provisioning or the weekly run is busy (and may be replacing state\managed): the next hour tries again
$lock = Enter-WmLock
if (-not $lock) { exit 0 }

Initialize-WmLog 'jobs' -Daily
$script:WmManagedQuiet = $true
$failed = $false
try {
    $content = Get-WmManagedContent -Config $config -CachedOnly:(-not (Test-WmManagedRefreshDue -Hours 20))
    Invoke-WmGroupJobs -Config $config -Content $content
} catch {
    $failed = $true
    Write-WmLog "Joby przerwane: $($_.Exception.Message)" -Level error
} finally {
    if ($script:WmErrors -gt 0) { $failed = $true }
    Send-WmLokiLog -Config $config
    Exit-WmLock $lock
}

if ($failed) { exit 1 }
exit 0
