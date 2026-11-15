# Task Scheduler tasks: scheduled update (every day by default), retry at sign-in, notification, group jobs.

$script:WmTaskPath   = '\wmanager\'
$script:WmTaskUpdate = 'wmanager-Update'
$script:WmTaskRetry  = 'wmanager-Retry'
$script:WmTaskNotify = 'wmanager-Notify'
$script:WmTaskJobs   = 'wmanager-Jobs'
$script:WmAllDays    = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')

function Get-WmUsersGroupName {
    # The Users group name depends on the system language (e.g. "Użytkownicy"), so resolve it from the SID
    return (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')).Translate([System.Security.Principal.NTAccount]).Value
}

function New-WmUpdateTrigger {
    param([Parameter(Mandatory = $true)][hashtable]$Config)
    $days = Get-WmUpdateDays $Config
    $time = Get-WmSetting $Config 'UpdateTime' '12:00'
    $at = [datetime]::ParseExact($time, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    return New-ScheduledTaskTrigger -Weekly -WeeksInterval 1 -DaysOfWeek $days -At $at
}

# Days of the scheduled update: every day unless UpdateDays says otherwise (a weekly trigger with all seven days)
function Get-WmUpdateDays {
    param([Parameter(Mandatory = $true)][hashtable]$Config)
    return @(Get-WmSetting $Config 'UpdateDays' $script:WmAllDays)
}

function Get-WmDaysMask {
    param([string[]]$Days)
    $bits = @{ Sunday = 1; Monday = 2; Tuesday = 4; Wednesday = 8; Thursday = 16; Friday = 32; Saturday = 64 }
    $mask = 0
    foreach ($d in $Days) { $mask = $mask -bor $bits[$d] }
    return $mask
}

# For the log: 'codziennie' for all seven days, otherwise the list
function Format-WmUpdateDays {
    param([string[]]$Days)
    if ((Get-WmDaysMask $Days) -eq 127) { return 'codziennie' }
    return ($Days -join ', ')
}

function Register-WmTasks {
    param([Parameter(Mandatory = $true)][hashtable]$Config)
    Write-WmLog '--- Harmonogram zadań ---'
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $update = Join-Path $script:WmRoot 'Update-Packages.ps1'
    $notify = Join-Path $script:WmRoot 'Notify-User.ps1'

    $system = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest

    # 1. Scheduled update (SYSTEM), every day by default; after a missed run it starts after boot
    $a1 = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$update`""
    $s1 = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit (New-TimeSpan -Hours 2) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskPath $script:WmTaskPath -TaskName $script:WmTaskUpdate -Action $a1 -Trigger (New-WmUpdateTrigger $Config) `
        -Settings $s1 -Principal $system -Description 'wmanager: scheduled update of packages, debloat and group scripts' -Force -ErrorAction Stop | Out-Null

    # 2. Retry deferred updates at sign-in (runs only when something was deferred)
    $a2 = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$update`" -OnlyIfPending"
    $t2 = New-ScheduledTaskTrigger -AtLogOn
    $t2.Delay = 'PT2M'
    $s2 = New-ScheduledTaskSettingsSet -RunOnlyIfNetworkAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskPath $script:WmTaskPath -TaskName $script:WmTaskRetry -Action $a2 -Trigger $t2 `
        -Settings $s2 -Principal $system -Description 'wmanager: retry of deferred updates' -Force -ErrorAction Stop | Out-Null

    # 3. Notification in the signed-in user's session (Users group)
    $a3 = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$notify`""
    $t3 = New-ScheduledTaskTrigger -AtLogOn
    $t3.Delay = 'PT1M'
    $users = New-ScheduledTaskPrincipal -GroupId (Get-WmUsersGroupName) -RunLevel Limited
    $s3 = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskPath $script:WmTaskPath -TaskName $script:WmTaskNotify -Action $a3 -Trigger $t3 `
        -Settings $s3 -Principal $users -Description 'wmanager: restart prompt and default browser setup' -Force -ErrorAction Stop | Out-Null

    # 4. Group scripts and jobs every hour (SYSTEM), only with a management source. The first run is a few
    #    minutes after provisioning (or right after a restart: StartWhenAvailable). Without -RepetitionDuration
    #    the repetition never ends (Windows 10 and later).
    if (Get-WmManagementSettings $Config) {
        $jobs = Join-Path $script:WmRoot 'Invoke-Jobs.ps1'
        $a4 = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$jobs`""
        $t4 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Hours 1)
        $s4 = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskPath $script:WmTaskPath -TaskName $script:WmTaskJobs -Action $a4 -Trigger $t4 `
            -Settings $s4 -Principal $system -Description 'wmanager: group scripts and jobs from the management source (hourly)' -Force -ErrorAction Stop | Out-Null
    } elseif (Get-ScheduledTask -TaskPath $script:WmTaskPath -TaskName $script:WmTaskJobs -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskPath $script:WmTaskPath -TaskName $script:WmTaskJobs -Confirm:$false -ErrorAction Stop
        Write-WmLog 'Brak źródła zarządzania: zadanie jobów usunięte.'
    }

    $days = Format-WmUpdateDays (Get-WmUpdateDays $Config)
    Write-WmLog "Zadania zarejestrowane; aktualizacja: $days o $(Get-WmSetting $Config 'UpdateTime' '12:00')."
}

# Called from the task: updates the schedule if it changed in the configuration.
# Changes only the trigger, so it doesn't interrupt the current run.
function Update-WmTaskSchedule {
    param([Parameter(Mandatory = $true)][hashtable]$Config)
    $task = Get-ScheduledTask -TaskPath $script:WmTaskPath -TaskName $script:WmTaskUpdate -ErrorAction SilentlyContinue
    if (-not $task) { return }
    $want = New-WmUpdateTrigger $Config
    $have = $task.Triggers | Select-Object -First 1
    $wantTime = ([datetime]$want.StartBoundary).ToString('HH:mm')
    $haveTime = if ($have.StartBoundary) { ([datetime]$have.StartBoundary).ToString('HH:mm') } else { '' }
    $wantMask = Get-WmDaysMask (Get-WmUpdateDays $Config)
    $haveMask = [int]$have.DaysOfWeek
    if ($wantTime -ne $haveTime -or $wantMask -ne $haveMask) {
        Set-ScheduledTask -TaskPath $script:WmTaskPath -TaskName $script:WmTaskUpdate -Trigger $want -ErrorAction Stop | Out-Null
        Write-WmLog "Zmieniono termin aktualizacji na: $(Format-WmUpdateDays (Get-WmUpdateDays $Config)) $wantTime."
    }
}

function Start-WmNotifyTask {
    try {
        Start-ScheduledTask -TaskPath $script:WmTaskPath -TaskName $script:WmTaskNotify -ErrorAction Stop
    } catch {
        Write-WmLog "Nie udało się uruchomić powiadomienia: $($_.Exception.Message)" -Level warn
    }
}
