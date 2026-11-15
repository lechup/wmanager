# Group scripts and jobs (wmanager-Jobs task, SYSTEM account, every hour), from the management source:
# - scripts (groups/<group>/scripts/*.ps1) whose content changed since their last successful run;
#   a failed one is tried again after 20 hours, or at once when its content changes;
# - jobs (groups/<group>/jobs/hourly|daily|weekly/*.ps1) whose time has come.
# Uses the verified copy of the source and fetches a new version at most once every 20 hours (the scheduled
# update fetches too). Output goes to the daily log logs\jobs-YYYY-MM-DD.log and to Loki.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
. (Join-Path $here 'lib\Common.ps1')
. (Join-Path $here 'lib\Choco.ps1')
. (Join-Path $here 'lib\Managed.ps1')
. (Join-Path $here 'lib\Task.ps1')

$config = Import-WmConfig (Join-Path $here 'provision.config.psd1')
try {
    if (-not (Get-WmManagementSettings $config)) { exit 0 }
} catch {
    Write-Host "Błąd w ustawieniach Management: $($_.Exception.Message)"
    exit 1
}

# Provisioning or the scheduled update is busy (and may be replacing state\managed): the next hour tries again
$lock = Enter-WmLock
if (-not $lock) { exit 0 }

Initialize-WmLog 'jobs' -Daily
$script:WmManagedQuiet = $true
$failed = $false
try {
    $content = Get-WmManagedContent -Config $config -CachedOnly:(-not (Test-WmManagedRefreshDue -Hours 20))
    $null = Invoke-WmStep 'Skrypty grup' { Invoke-WmGroupScripts -Config $config -RetryFailedAfterHours 20 }
    $null = Invoke-WmStep 'Joby grup' { Invoke-WmGroupJobs -Config $config -Content $content }
    if ($script:WmScriptsNeedReboot) {
        Set-WmRebootFlag
        Write-WmLog 'Skrypt grupy wymaga restartu; użytkownik dostanie powiadomienie.'
        Start-WmNotifyTask
    }
} catch {
    $failed = $true
    Write-WmLog "Przebieg skryptów i jobów przerwany: $($_.Exception.Message)" -Level error
} finally {
    if ($script:WmErrors -gt 0) { $failed = $true }
    Send-WmLokiLog -Config $config
    Exit-WmLock $lock
}

if ($failed) { exit 1 }
exit 0
