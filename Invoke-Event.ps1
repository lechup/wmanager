# Event scripts (the wmanager-Event-<group>-<name>-<n> tasks, SYSTEM account, at the event a script names), from the
# management source: the script groups/<group>/events/<name>.ps1 of this computer's groups, as SYSTEM, with the
# secrets it names (# wmanager-secrets:) in its environment only, and the event that started it. Uses the verified
# copy of the source as it is (it never fetches). Output goes to the daily log logs\events-YYYY-MM-DD.log and to Loki.
# -Script: group/name; -Index: which of the script's events (from 1); -Record and -Log: the event's record number and
# log, which Task Scheduler fills in for an event of a log.
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Script, [int]$Index = 1, [string]$Record = '', [string]$Log = '', [string]$Lang)

$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
. (Join-Path $here 'lib\Common.ps1')
. (Join-Path $here 'lib\Choco.ps1')
. (Join-Path $here 'lib\Managed.ps1')
# A computer moved back to a wmanager release without event scripts keeps this file and the tasks, but not the code:
# the tasks go, quietly, instead of an error at every event
if (-not (Get-Command Invoke-WmEventScript -ErrorAction SilentlyContinue)) {
    Get-ScheduledTask -TaskPath '\wmanager\' -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'wmanager-Event-*' } |
        Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
    exit 0
}
Initialize-WmLanguage -Lang $Lang

$config = Import-WmConfig (Join-Path $here 'provision.config.psd1')
try {
    if (-not (Get-WmManagementSettings $config)) { exit 0 }
} catch {
    Write-Host (Get-WmText 'jobs.management_settings_error' @(Get-WmErrorText $_))
    exit 1
}

# No lock: the scheduled update may hold it for long, and these only read the verified copy
Initialize-WmLog 'events' -Daily
$script:WmManagedQuiet = $true
$failed = $false
try {
    Invoke-WmEventScript -Config $config -Name $Script -Index $Index -Record $Record -Log $Log
} catch {
    $failed = $true
    Write-WmLog -Key 'events.run_failed' -Arguments @($Script, (Get-WmErrorText $_)) -Level error
} finally {
    if ($script:WmErrors -gt 0) { $failed = $true }
    Send-WmLokiLog -Config $config
}

if ($failed) { exit 1 }
exit 0
