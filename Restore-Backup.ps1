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
    because otherwise the weekly run applies debloat again.

    Not undone: removed Store apps and OneDrive, installed Chocolatey packages, the computer name.
    A restart is needed afterwards.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File C:\ProgramData\wmanager\Restore-Backup.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
. (Join-Path $here 'lib\Common.ps1')
. (Join-Path $here 'lib\Backup.ps1')
. (Join-Path $here 'lib\Task.ps1')

if (-not (Test-Path -LiteralPath $script:WmBackupDir)) {
    Write-Host "Brak kopii w $($script:WmBackupDir): wmanager nie był tu uruchamiany." -ForegroundColor Red
    exit 2
}

$lock = Enter-WmLock
if (-not $lock) { Write-Host 'Inny przebieg wmanager już trwa. Spróbuj za chwilę.' -ForegroundColor Red; exit 3 }

Initialize-WmLog 'restore'
$config = @{}
$configFile = Join-Path $script:WmRoot 'provision.config.psd1'
if (Test-Path -LiteralPath $configFile) {
    try { $config = Import-WmConfig $configFile } catch { }
}
$failed = $false
$cancelled = $false

try {
    $journal = @(Read-WmJournal)
    $backups = @(Get-ChildItem -LiteralPath $script:WmBackupDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($journal.Count -eq 0 -and $backups.Count -eq 0) { throw "Brak kopii i dziennika zmian w $($script:WmBackupDir)." }

    $machine = @($journal | Where-Object { $_.Scope -eq 'machine' })
    $user    = @($journal | Where-Object { $_.Scope -eq 'user' })
    Write-WmLog "wmanager: przywracanie na $($script:WmHostName). Dziennik: $($machine.Count) wartości komputera, $($user.Count) wartości użytkowników."
    if (-not (Confirm-WmContinue 'Cofnąć zmiany wmanagera w rejestrze?')) {
        $cancelled = $true
        Write-WmLog 'Anulowano, nic nie zmieniono.'
        return
    }

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
    foreach ($p in $notFound) { Write-WmLog "Profil $p nie istnieje albo nie dało się go wczytać; jego ustawień nie przywrócono." -Level warn }
    Write-WmLog "Rejestr: przywrócono $($count.Ok) z $($journal.Count) wartości."

    # --- Default apps for new accounts, from the first backup ------------------
    $first = Get-WmFirstBackup
    if (-not $first) { $first = $backups | Select-Object -First 1 }
    if ($first) {
        Restore-WmDefaultAssociations -BackupDir $first.FullName

        # --- Store apps removed since the first backup -----------------------
        $csv = Join-Path $first.FullName 'appx-installed.csv'
        if (Test-Path -LiteralPath $csv) {
            $before = @(Import-Csv -LiteralPath $csv | ForEach-Object { $_.Name } | Sort-Object -Unique)
            $now = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object -Unique)
            $removed = @($before | Where-Object { $now -notcontains $_ })
            if ($removed.Count -gt 0) {
                Write-WmLog "Aplikacje ze Sklepu usunięte od kopii $($first.Name) ($($removed.Count)); w razie potrzeby zainstaluj je ze Sklepu:" -Level warn
                foreach ($r in $removed) { Write-WmLog "  $r" }
            }
        }
    }
    if ($machine | Where-Object { $_.Name -eq 'DisableFileSyncNGSC' }) {
        Write-WmLog 'OneDrive był odinstalowany; jeśli jest potrzebny, zainstaluj go ponownie ze strony Microsoftu.' -Level warn
    }

    # --- Scheduled tasks ----------------------------------------------------------
    $tasks = @(Get-ScheduledTask -TaskPath $script:WmTaskPath -ErrorAction SilentlyContinue)
    if ($tasks.Count -gt 0) {
        if (Confirm-WmContinue 'Wyłączyć zadania wmanager? Inaczej cotygodniowy przebieg znowu usunie aplikacje i zmieni ustawienia.' -DefaultYes) {
            $tasks | Disable-ScheduledTask -ErrorAction Stop | Out-Null
            Write-WmLog "Zadania wmanager wyłączone ($($tasks.Count))."
        } else {
            Write-WmLog 'Zadania wmanager zostają włączone; cotygodniowy przebieg znowu zastosuje ustawienia.' -Level warn
        }
    }
} catch {
    $failed = $true
    Write-WmLog "Przywracanie przerwane: $($_.Exception.Message)" -Level error
} finally {
    if ($script:WmErrors -gt 0) { $failed = $true }
    Write-WmLog ("Koniec: ostrzeżenia {0}, błędy {1}. Log: {2}" -f $script:WmWarnings, $script:WmErrors, $script:WmLogFile)
    Send-WmLokiLog -Config $config
    Exit-WmLock $lock
}

Write-Host ''
if ($cancelled) { exit 0 }
if ($failed) {
    Write-Host 'Przywracanie zakończone z błędami. Sprawdź log powyżej.' -ForegroundColor Yellow
    exit 1
}
Write-Host 'Przywracanie zakończone. Uruchom ponownie komputer, żeby ustawienia zadziałały.' -ForegroundColor Green
exit 0
