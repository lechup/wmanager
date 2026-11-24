#Requires -RunAsAdministrator
<#
.SYNOPSIS
    wmanager: undo the registry changes made by provisioning.

.DESCRIPTION
    Uses the undo journal (C:\ProgramData\wmanager\state\backup\journal.jsonl): every registry value
    wmanager changed during provisioning gets its previous value back, or is removed if it did not
    exist. Later changes users made in the same keys are left alone.

    Also restores the default apps for new accounts from the first backup, lists Store apps removed
    since then (they have to be reinstalled from the Store) and offers to disable the wmanager tasks,
    because otherwise the scheduled update applies debloat again. With the tasks disabled, the wmanager
    signing certificate is also removed from the computer's trusted root store.

    The people provisioning made standard users (AdminAccount) become administrators again; the administrator
    account it created stays.

    Not undone: removed Store apps and OneDrive, installed Chocolatey packages, the effects of group
    scripts, the computer name. A restart is needed afterwards.

.PARAMETER Lang
    Language of the screen: en, de, fr, es, it, pl, nl, pt, ro, cs. Without it: WMANAGER_LANG, then the Windows
    display language, then English. The log file and Loki are always in English.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File C:\ProgramData\wmanager\Restore-Backup.ps1
#>
[CmdletBinding()]
param([string]$Lang)

$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
. (Join-Path $here 'lib\Common.ps1')
. (Join-Path $here 'lib\Backup.ps1')
. (Join-Path $here 'lib\Managed.ps1')
. (Join-Path $here 'lib\Task.ps1')
. (Join-Path $here 'lib\Accounts.ps1')
Initialize-WmLanguage -Lang $Lang

if (-not (Test-Path -LiteralPath $script:WmBackupDir)) {
    Write-Host (Get-WmText 'restore.no_backup' @($script:WmBackupDir)) -ForegroundColor Red
    exit 2
}

$lock = Enter-WmLock
if (-not $lock) {
    Write-Host (Get-WmText 'restore.lock_wait') -ForegroundColor Yellow
    $lock = Enter-WmLock -WaitSeconds 600
}
if (-not $lock) { Write-Host (Get-WmText 'restore.lock_busy') -ForegroundColor Red; exit 3 }

Initialize-WmLog 'restore'
$config = @{}
$configFile = Join-Path $script:WmRoot 'provision.config.psd1'
if (Test-Path -LiteralPath $configFile) {
    try { $config = Import-WmConfig $configFile } catch { }
}
# Read and confirm before anything changes
try {
    $journal = @(Read-WmJournal)
} catch {
    Write-WmLog -Key 'restore.journal_read_failed' -Arguments @(Get-WmErrorText $_) -Level error
    Exit-WmLock $lock
    exit 1
}
$backups = @(Get-ChildItem -LiteralPath $script:WmBackupDir -Directory -ErrorAction SilentlyContinue)
$machine = @($journal | Where-Object { $_.Scope -eq 'machine' })
$user    = @($journal | Where-Object { $_.Scope -eq 'user' })
Write-WmLog -Key 'restore.start' -Arguments @((Get-WmName), $script:WmHostName, $machine.Count, $user.Count, $backups.Count)
if (-not (Confirm-WmContinue 'restore.confirm')) {
    Write-WmLog -Key 'restore.cancelled'
    Exit-WmLock $lock
    exit 0
}

$failed = $false
try {
    # Counters live in a hashtable: the hive scriptblock below runs in a child scope
    $count = @{ Ok = 0 }

    # --- Registry: values of the computer -----------------------------------
    foreach ($e in $machine) { if (Restore-WmJournalEntry -Entry $e) { $count.Ok++ } }

    # --- Registry: values of each user profile (matched by SID; the default profile by name) ---
    $seenProfiles = @{}
    Invoke-WmForEachUserHive {
        param($root, $name, $sid)
        $hive = ConvertTo-WmRegNativePath $root
        foreach ($e in $user) {
            $match = if ($e.Sid) { $e.Sid -eq $sid } else { (-not $sid) -and $e.Profile -eq $name }
            if (-not $match) { continue }
            $seenProfiles[[string]$e.Sid + '|' + $e.Profile] = $true
            if (Restore-WmJournalEntry -Entry $e -HiveRoot $hive) { $count.Ok++ }
        }
    }
    $notFound = @($user | Where-Object { -not $seenProfiles.ContainsKey([string]$_.Sid + '|' + $_.Profile) } |
                  ForEach-Object { $_.Profile } | Sort-Object -Unique)
    foreach ($p in $notFound) { Write-WmLog -Key 'restore.profile_not_found' -Arguments @($p) -Level warn }
    Write-WmLog -Key 'restore.registry_summary' -Arguments @($count.Ok, $journal.Count)

    # --- Default apps for new accounts, from the first backup ------------------
    $first = Get-WmFirstBackup
    if (-not $first) { $first = $backups | Sort-Object Name | Select-Object -First 1 }
    if ($first) {
        Restore-WmDefaultAssociations -BackupDir $first.FullName

        # --- Store apps removed since the first backup -----------------------
        $csv = Join-Path $first.FullName 'appx-installed.csv'
        if (Test-Path -LiteralPath $csv) {
            $before = @(Import-Csv -LiteralPath $csv | ForEach-Object { $_.Name } | Sort-Object -Unique)
            $now = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object -Unique)
            $removed = @($before | Where-Object { $now -notcontains $_ })
            if ($removed.Count -gt 0) {
                Write-WmLog -Key 'restore.store_apps_removed' -Arguments @($first.Name, $removed.Count) -Level warn
                foreach ($r in $removed) { Write-WmLog "  $r" }
            }
        }
    }
    if ($machine | Where-Object { $_.Name -eq 'DisableFileSyncNGSC' }) {
        Write-WmLog -Key 'restore.onedrive_removed' -Level warn
    }

    # --- People provisioning made standard users (AdminAccount) ---------------------------
    if ((Test-Path -LiteralPath $script:WmDemotedFile) -and (Confirm-WmContinue 'restore.confirm_admin_again' -DefaultYes)) {
        Restore-WmDemotedAdmins
    }
    $admin = [string](Get-WmSetting $config 'AdminAccount' '')
    if ($admin -and (Get-LocalUser -Name $admin -ErrorAction SilentlyContinue)) {
        Write-WmLog -Key 'restore.admin_account_stays' -Arguments @($admin)
    }

    # --- Scheduled tasks and the signing certificate (the scheduled update needs it) ------
    $tasksOff = $true
    $tasks = @(Get-ScheduledTask -TaskPath $script:WmTaskPath -ErrorAction SilentlyContinue)
    if ($tasks.Count -gt 0) {
        if (Confirm-WmContinue 'restore.confirm_disable_tasks' -DefaultYes) {
            $tasks | Disable-ScheduledTask -ErrorAction Stop | Out-Null
            Write-WmLog -Key 'restore.tasks_disabled' -Arguments @($tasks.Count)
        } else {
            $tasksOff = $false
            Write-WmLog -Key 'restore.tasks_kept' -Level warn
        }
    }
    if ($tasksOff) {
        try {
            $n = Remove-WmSigningCertificates
            if ($n -gt 0) { Write-WmLog -Key 'restore.certificate_removed' -Arguments @($n) }
        } catch {
            Write-WmLog -Key 'restore.certificate_remove_failed' -Arguments @(Get-WmErrorText $_) -Level warn
        }
    }
} catch {
    $failed = $true
    Write-WmLog -Key 'restore.stopped' -Arguments @(Get-WmErrorText $_) -Level error
} finally {
    if ($script:WmErrors -gt 0) { $failed = $true }
    Write-WmLog -Key 'restore.summary' -Arguments @($script:WmWarnings, $script:WmErrors, $script:WmLogFile)
    Send-WmLokiLog -Config $config
    Exit-WmLock $lock
}

Write-Host ''
if ($failed) {
    Write-Host (Get-WmText 'restore.finished_with_errors') -ForegroundColor Yellow
    exit 1
}
Write-Host (Get-WmText 'restore.finished') -ForegroundColor Green
exit 0
