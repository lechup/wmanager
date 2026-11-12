# Zadania w Harmonogramie zadań: cotygodniowa aktualizacja, ponowienie przy logowaniu, powiadomienie.

$script:WmTaskPath   = '\wmanager\'
$script:WmTaskUpdate = 'wmanager-Update'
$script:WmTaskRetry  = 'wmanager-Retry'
$script:WmTaskNotify = 'wmanager-Notify'

function Get-WmUsersGroupName {
    # Nazwa grupy Users zależy od języka systemu ("Użytkownicy"), więc tłumaczymy z SID
    return (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')).Translate([System.Security.Principal.NTAccount]).Value
}

function New-WmUpdateTrigger {
    param([Parameter(Mandatory = $true)][hashtable]$Config)
    $days = @(Get-WmSetting $Config 'UpdateDays' @('Monday'))
    $time = Get-WmSetting $Config 'UpdateTime' '12:00'
    $at = [datetime]::ParseExact($time, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    return New-ScheduledTaskTrigger -Weekly -WeeksInterval 1 -DaysOfWeek $days -At $at
}

function Get-WmDaysMask {
    param([string[]]$Days)
    $bits = @{ Sunday = 1; Monday = 2; Tuesday = 4; Wednesday = 8; Thursday = 16; Friday = 32; Saturday = 64 }
    $mask = 0
    foreach ($d in $Days) { $mask = $mask -bor $bits[$d] }
    return $mask
}

function Register-WmTasks {
    param([Parameter(Mandatory = $true)][hashtable]$Config)
    Write-WmLog '--- Harmonogram zadań ---'
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $update = Join-Path $script:WmRoot 'Update-Packages.ps1'
    $notify = Join-Path $script:WmRoot 'Notify-User.ps1'

    $system = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest

    # 1. Cotygodniowa aktualizacja (SYSTEM); po pominiętym terminie rusza po starcie
    $a1 = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$update`""
    $s1 = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit (New-TimeSpan -Hours 2) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskPath $script:WmTaskPath -TaskName $script:WmTaskUpdate -Action $a1 -Trigger (New-WmUpdateTrigger $Config) `
        -Settings $s1 -Principal $system -Description 'wmanager: cotygodniowa aktualizacja paczek z choco-reqs.txt' -Force | Out-Null

    # 2. Ponowienie odłożonych aktualizacji przy logowaniu (działa tylko, gdy coś odłożono)
    $a2 = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$update`" -OnlyIfPending"
    $t2 = New-ScheduledTaskTrigger -AtLogOn
    $t2.Delay = 'PT2M'
    $s2 = New-ScheduledTaskSettingsSet -RunOnlyIfNetworkAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskPath $script:WmTaskPath -TaskName $script:WmTaskRetry -Action $a2 -Trigger $t2 `
        -Settings $s2 -Principal $system -Description 'wmanager: ponowienie odłożonych aktualizacji' -Force | Out-Null

    # 3. Powiadomienie w sesji zalogowanego użytkownika (grupa Users)
    $a3 = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$notify`""
    $t3 = New-ScheduledTaskTrigger -AtLogOn
    $t3.Delay = 'PT1M'
    $users = New-ScheduledTaskPrincipal -GroupId (Get-WmUsersGroupName) -RunLevel Limited
    $s3 = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskPath $script:WmTaskPath -TaskName $script:WmTaskNotify -Action $a3 -Trigger $t3 `
        -Settings $s3 -Principal $users -Description 'wmanager: prośba o restart i ustawienie domyślnej przeglądarki' -Force | Out-Null

    $days = (@(Get-WmSetting $Config 'UpdateDays' @('Monday')) -join ', ')
    Write-WmLog "Zadania zarejestrowane; aktualizacja: $days o $(Get-WmSetting $Config 'UpdateTime' '12:00')."
}

# Wywoływane z zadania: poprawia termin, jeśli w konfiguracji się zmienił.
# Zmienia tylko wyzwalacz, więc nie przerywa bieżącego przebiegu.
function Update-WmTaskSchedule {
    param([Parameter(Mandatory = $true)][hashtable]$Config)
    $task = Get-ScheduledTask -TaskPath $script:WmTaskPath -TaskName $script:WmTaskUpdate -ErrorAction SilentlyContinue
    if (-not $task) { return }
    $want = New-WmUpdateTrigger $Config
    $have = $task.Triggers | Select-Object -First 1
    $wantTime = ([datetime]$want.StartBoundary).ToString('HH:mm')
    $haveTime = if ($have.StartBoundary) { ([datetime]$have.StartBoundary).ToString('HH:mm') } else { '' }
    $wantMask = Get-WmDaysMask @(Get-WmSetting $Config 'UpdateDays' @('Monday'))
    $haveMask = [int]$have.DaysOfWeek
    if ($wantTime -ne $haveTime -or $wantMask -ne $haveMask) {
        Set-ScheduledTask -TaskPath $script:WmTaskPath -TaskName $script:WmTaskUpdate -Trigger $want | Out-Null
        Write-WmLog "Zmieniono termin aktualizacji na: $((@(Get-WmSetting $Config 'UpdateDays' @('Monday'))) -join ', ') $wantTime."
    }
}

function Start-WmNotifyTask {
    try {
        Start-ScheduledTask -TaskPath $script:WmTaskPath -TaskName $script:WmTaskNotify -ErrorAction Stop
    } catch {
        Write-WmLog "Nie udało się uruchomić powiadomienia: $($_.Exception.Message)" -Level warn
    }
}
