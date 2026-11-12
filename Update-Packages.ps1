# Weekly package update (wmanager-Update task, SYSTEM account).
# With -OnlyIfPending (wmanager-Retry task at sign-in): runs only when something was deferred.
[CmdletBinding()]
param([switch]$OnlyIfPending)

$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
. (Join-Path $here 'lib\Common.ps1')
. (Join-Path $here 'lib\Debloat.ps1')
. (Join-Path $here 'lib\Privacy.ps1')
. (Join-Path $here 'lib\Choco.ps1')
. (Join-Path $here 'lib\Task.ps1')

if ($OnlyIfPending -and -not (Test-Path -LiteralPath $script:WmRetryFlag)) { exit 0 }

$config = Import-WmConfig (Join-Path $here 'provision.config.psd1')
$job = 'update'
if ($OnlyIfPending) { $job = 'retry' }

$lock = Enter-WmLock
if (-not $lock) { Write-Host 'Inny przebieg wmanager już trwa, kończę.'; exit 0 }

Initialize-WmLog $job
Write-WmLog "wmanager $job na $($script:WmHostName)"
$failed = $false
if (-not $OnlyIfPending) { Send-WmHealthcheck -Config $config -Signal start }

try {
    Clear-WmStaleRebootFlag

    $reqs = ConvertFrom-WmRequirements -Text (Get-WmRequirementsText -Config $config -BaseDir $here)
    $deferred = Sync-WmPackages -Requirements $reqs -Upgrade `
                    -SkipRunning:([bool](Get-WmSetting $config 'SkipRunningPackages' $true)) `
                    -ProcessMap (Get-WmSetting $config 'RunningProcessMap' @{})

    if ($deferred.Count -gt 0) {
        New-Item -ItemType Directory -Force -Path $script:WmStateDir | Out-Null
        Set-Content -LiteralPath $script:WmRetryFlag -Value ($deferred -join "`r`n") -Encoding ASCII
        Write-WmLog "Odłożone do następnego logowania: $($deferred -join ', ')" -Level warn
    } else {
        Remove-Item -LiteralPath $script:WmRetryFlag -Force -ErrorAction SilentlyContinue
    }

    if (-not $OnlyIfPending) {
        if (Get-WmSetting $config 'RerunDebloatWeekly' $true) {
            Invoke-WmDebloat -Config $config
            if (Get-WmSetting $config 'Privacy' $true) { Invoke-WmPrivacy }
        }
        Update-WmTaskSchedule -Config $config
    }

    if ($script:WmChocoNeedsReboot -or (Test-WmPendingReboot)) {
        Set-WmRebootFlag
        Write-WmLog 'System czeka na restart; użytkownik dostanie powiadomienie.'
        Start-WmNotifyTask
    }
} catch {
    $failed = $true
    Write-WmLog "Przebieg przerwany: $($_.Exception.Message)" -Level error
} finally {
    if ($script:WmErrors -gt 0) { $failed = $true }
    Write-WmLog ("Koniec: ostrzeżenia {0}, błędy {1}." -f $script:WmWarnings, $script:WmErrors)
    Remove-WmOldLogs -Days ([int](Get-WmSetting $config 'LogRetentionDays' 90))
    Send-WmLokiLog -Config $config
    if (-not $OnlyIfPending) {
        $signal = 'success'
        if ($failed) { $signal = 'fail' }
        Send-WmHealthcheck -Config $config -Signal $signal -Body (Get-WmLogTail 60)
    }
    Exit-WmLock $lock
}

if ($failed) { exit 1 }
exit 0
