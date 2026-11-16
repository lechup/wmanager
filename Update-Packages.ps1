# Scheduled package update, debloat and group scripts (wmanager-Update task, SYSTEM account, every day by default).
# With -OnlyIfPending (wmanager-Retry task at sign-in): runs only when something was deferred.
[CmdletBinding()]
param([switch]$OnlyIfPending, [string]$Lang)

$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
. (Join-Path $here 'lib\Common.ps1')
. (Join-Path $here 'lib\Debloat.ps1')
. (Join-Path $here 'lib\Privacy.ps1')
. (Join-Path $here 'lib\Choco.ps1')
. (Join-Path $here 'lib\Managed.ps1')
. (Join-Path $here 'lib\Task.ps1')
Initialize-WmLanguage -Lang $Lang   # as SYSTEM (the task): the system's display language

# A scheduled run that couldn't run (no internet, another run busy for too long) leaves 'full' in the retry
# flag, so the retry at the next sign-in does the full run. ('offline' is the older name of the mark.)
function Set-WmFullRunPending {
    try {
        New-Item -ItemType Directory -Force -Path $script:WmStateDir -ErrorAction Stop | Out-Null
        if (@(Get-Content -LiteralPath $script:WmRetryFlag -ErrorAction SilentlyContinue) -notcontains 'full') {
            Add-Content -LiteralPath $script:WmRetryFlag -Value 'full' -Encoding ASCII -ErrorAction Stop
        }
    } catch {
        Write-Host (Get-WmText 'update.retry_flag_failed' @(Get-WmErrorText $_))
    }
}

$fullRun = -not $OnlyIfPending
if ($OnlyIfPending) {
    if (-not (Test-Path -LiteralPath $script:WmRetryFlag)) { exit 0 }
    $marks = @(Get-Content -LiteralPath $script:WmRetryFlag -ErrorAction SilentlyContinue)
    if ($marks -contains 'full' -or $marks -contains 'offline') { $fullRun = $true }
}

$config = Import-WmConfig (Join-Path $here 'provision.config.psd1')
$job = 'update'
if (-not $fullRun) { $job = 'retry' }

# The hourly jobs may hold the lock for a few minutes (e.g. after boot, when both tasks start); wait for them
$wait = 1200
if ($fullRun) { $wait = 3000 }
$lock = Enter-WmLock -WaitSeconds $wait
if (-not $lock) {
    Write-Host (Get-WmText 'update.busy')
    if ($fullRun) { Set-WmFullRunPending }
    exit 0
}

Initialize-WmLog $job
Write-WmLog -Key 'update.start' -Arguments @((Get-WmName), $job, $script:WmHostName)

# Without internet: change nothing, report nothing, try again at the next sign-in (wmanager-Retry)
$unreachable = @(Get-WmUnreachableHosts -Config $config)
if ($unreachable.Count -gt 0) {
    Write-WmLog -Key 'update.offline' -Arguments @($unreachable -join ', ')
    if ($fullRun) { Set-WmFullRunPending }
    Exit-WmLock $lock
    exit 0
}

$failed = $false
if ($fullRun) { Send-WmHealthcheck -Config $config -Signal start }

try {
    # Stages run independently (see Invoke-WmStep). Install-WmChocolatey also repairs a machine
    # where provisioning could not install Chocolatey, and applies changed package sources.
    $script:WmDeferred = $null
    if (Invoke-WmStep 'step.chocolatey' { Install-WmChocolatey -Config $config }) {
        $null = Invoke-WmStep 'step.packages' {
            $reqs = Get-WmRequirements -Config $config -BaseDir $here
            $script:WmDeferred = Sync-WmPackages -Requirements $reqs -Upgrade `
                                    -SkipRunning:([bool](Get-WmSetting $config 'SkipRunningPackages' $true)) `
                                    -ProcessMap (Get-WmSetting $config 'RunningProcessMap' @{})
        }
    }

    # Without a package result the retry flag stays as it was
    if ($null -ne $script:WmDeferred) {
        if ($script:WmDeferred.Count -gt 0) {
            New-Item -ItemType Directory -Force -Path $script:WmStateDir -ErrorAction Stop | Out-Null
            Set-Content -LiteralPath $script:WmRetryFlag -Value ($script:WmDeferred -join "`r`n") -Encoding ASCII -ErrorAction Stop
            Write-WmLog -Key 'update.deferred' -Arguments @($script:WmDeferred -join ', ') -Level warn
        } else {
            Remove-Item -LiteralPath $script:WmRetryFlag -Force -ErrorAction SilentlyContinue
        }
    }

    if ($fullRun) {
        if (Test-WmRerunDebloat -Config $config) {
            $null = Invoke-WmStep 'step.debloat' { Invoke-WmDebloat -Config $config }
            if (Get-WmSetting $config 'Privacy' $true) { $null = Invoke-WmStep 'step.privacy' { Invoke-WmPrivacy } }
        }
        # Failed scripts run again after 20 hours, as in the hourly task (with a daily update, retrying at every
        # run would mean twice a day), and not at sign-in
        $null = Invoke-WmStep 'step.group_scripts' { Invoke-WmGroupScripts -Config $config -RetryFailedAfterHours 20 }
        $null = Invoke-WmStep 'step.schedule' { Update-WmTaskSchedule -Config $config }
    }

    if ($script:WmChocoNeedsReboot -or $script:WmScriptsNeedReboot -or (Test-WmPendingReboot)) {
        Set-WmRebootFlag
        Write-WmLog -Key 'update.reboot_pending'
        Start-WmNotifyTask
    }
} catch {
    $failed = $true
    Write-WmLog -Key 'update.run_failed' -Arguments @(Get-WmErrorText $_) -Level error
} finally {
    if ($script:WmErrors -gt 0) { $failed = $true }
    Write-WmLog -Key 'update.summary' -Arguments @($script:WmWarnings, $script:WmErrors)
    Remove-WmOldLogs -Days ([int](Get-WmSetting $config 'LogRetentionDays' 90))
    Send-WmLokiLog -Config $config
    if ($fullRun) {
        $signal = 'success'
        if ($failed) { $signal = 'fail' }
        Send-WmHealthcheck -Config $config -Signal $signal -Body (Get-WmLogTail 60)
    }
    Exit-WmLock $lock
}

if ($failed) { exit 1 }
exit 0
