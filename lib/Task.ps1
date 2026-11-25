# Task Scheduler tasks: scheduled update (every day by default), retry at sign-in, notification, group jobs, the
# groups' sign-in scripts and startup scripts.

$script:WmTaskPath   = '\wmanager\'
$script:WmTaskUpdate = 'wmanager-Update'
$script:WmTaskRetry  = 'wmanager-Retry'
$script:WmTaskNotify = 'wmanager-Notify'
$script:WmTaskJobs   = 'wmanager-Jobs'
$script:WmTaskLogon  = 'wmanager-Logon'
$script:WmTaskStartup = 'wmanager-Startup'
$script:WmAllDays    = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')

# The sign-in scripts of the groups (Invoke-Logon.ps1): SYSTEM at every sign-in of any user, half a minute later
# (the desktop and the network come up first); it runs them in the user's session itself. Sign-ins close together
# queue up.
function Register-WmLogonTask {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $logon = Join-Path $script:WmRoot 'Invoke-Logon.ps1'
    $a = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$logon`""
    $t = New-ScheduledTaskTrigger -AtLogOn
    $t.Delay = 'PT30S'
    $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances Queue
    $system = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskPath $script:WmTaskPath -TaskName $script:WmTaskLogon -Action $a -Trigger $t `
        -Settings $s -Principal $system -Description 'wmanager: sign-in scripts of the groups, run as the user who signs in' -Force -ErrorAction Stop | Out-Null
}

# The startup scripts of the groups (Invoke-Startup.ps1): SYSTEM at every start of the computer, a minute later (the
# network comes up first), usually before anyone signs in. Two triggers: the boot, and the boot event Windows logs at
# every start (System log, Kernel-Boot 27), also after a Fast Startup "Shut down", where the boot trigger doesn't fire;
# a start both catch runs them once (lib\Managed.ps1). Each script has its own time limit, so the task's is only a
# backstop.
$script:WmBootEventQuery = '<QueryList><Query Id="0" Path="System"><Select Path="System">' +
    '*[System[Provider[@Name=''Microsoft-Windows-Kernel-Boot''] and EventID=27]]</Select></Query></QueryList>'

function Register-WmStartupTask {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $startup = Join-Path $script:WmRoot 'Invoke-Startup.ps1'
    $a = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$startup`""
    $boot = New-ScheduledTaskTrigger -AtStartup
    $boot.Delay = 'PT1M'
    $bootEvent = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace 'Root/Microsoft/Windows/TaskScheduler' |
        New-CimInstance -ClientOnly
    $bootEvent.Enabled = $true
    $bootEvent.Subscription = $script:WmBootEventQuery
    $bootEvent.Delay = 'PT1M'
    $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit (New-TimeSpan -Hours 12) -MultipleInstances IgnoreNew
    $system = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskPath $script:WmTaskPath -TaskName $script:WmTaskStartup -Action $a -Trigger @($boot, $bootEvent) `
        -Settings $s -Principal $system -Description 'wmanager: startup scripts of the groups, as SYSTEM' -Force -ErrorAction Stop | Out-Null
}

function Get-WmUsersGroupName {
    # The Users group name depends on the system language (e.g. "Użytkownicy"), so resolve it from the SID
    return (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')).Translate([System.Security.Principal.NTAccount]).Value
}

function New-WmUpdateTrigger {
    param([Parameter(Mandatory = $true)][hashtable]$Config)
    return New-WmWeeklyTrigger -Time (Get-WmSetting $Config 'UpdateTime' '12:00') -Days (Get-WmUpdateDays $Config)
}

# A weekly trigger at a time of day (HH:mm) in local time. New-ScheduledTaskTrigger writes the time with the UTC offset
# of the moment ("Synchronize across time zones"), so after the clocks change for summer or winter the task would
# start an hour off; without the offset it keeps its time of day.
function New-WmWeeklyTrigger {
    param([Parameter(Mandatory = $true)][string]$Time, [Parameter(Mandatory = $true)][string[]]$Days)
    $at = [datetime]::ParseExact($Time, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    $trigger = New-ScheduledTaskTrigger -Weekly -WeeksInterval 1 -DaysOfWeek $Days -At $at
    $trigger.StartBoundary = $at.ToString('s', [Globalization.CultureInfo]::InvariantCulture)
    return $trigger
}

# The time of day (HH:mm) of a trigger in local time; '' without one, or for one with a UTC offset (written by an
# older version), so that it is written again
function Get-WmTriggerTime {
    param($Trigger)
    if ([string]$Trigger.StartBoundary -match '^\d{4}-\d{2}-\d{2}T(\d{2}:\d{2}):\d{2}(\.\d+)?$') { return $Matches[1] }
    return ''
}

# Days of the scheduled update: every day unless UpdateDays says otherwise (a weekly trigger with all seven days)
function Get-WmUpdateDays {
    param([Parameter(Mandatory = $true)][hashtable]$Config)
    return @(Get-WmSetting $Config 'UpdateDays' $script:WmAllDays)
}

# The times of the jobs that declare one (Get-WmJobTimes) as extra triggers of wmanager-Jobs, after its hourly one,
# so such a job starts at its time rather than at the next hour, in local time (New-WmWeeklyTrigger). Changed only when
# the set of times differs, or a trigger still has a UTC offset (the task runs this itself: changing its triggers
# doesn't stop the run). Without the task (no management source) nothing.
function Sync-WmJobsTaskTimes {
    param([AllowEmptyCollection()][object[]]$Times = @())
    $task = Get-ScheduledTask -TaskPath $script:WmTaskPath -TaskName $script:WmTaskJobs -ErrorAction SilentlyContinue
    if (-not $task) { return }
    $want = @{}
    foreach ($t in $Times) { $want['{0} {1}' -f $t.Time, (Get-WmDaysMask $t.Days)] = $t }
    $have = @{}
    foreach ($tr in @($task.Triggers | Select-Object -Skip 1)) {
        $have['{0} {1}' -f (Get-WmTriggerTime $tr), [int]$tr.DaysOfWeek] = $true
    }
    $same = $want.Count -eq $have.Count
    foreach ($k in $want.Keys) { if (-not $have.ContainsKey($k)) { $same = $false } }
    if ($same) { return }
    $keys = @($want.Keys | Sort-Object)
    $triggers = @($task.Triggers | Select-Object -First 1) + @(foreach ($k in $keys) {
        New-WmWeeklyTrigger -Time $want[$k].Time -Days $want[$k].Days
    })
    Set-ScheduledTask -TaskPath $script:WmTaskPath -TaskName $script:WmTaskJobs -Trigger $triggers -ErrorAction Stop | Out-Null
    $list = if ($keys.Count) { @($keys | ForEach-Object { $want[$_].Text }) -join '; ' } else { '-' }
    Write-WmLog -Key 'task.jobs_times' -Arguments @($list)
}

function Get-WmDaysMask {
    param([string[]]$Days)
    $bits = @{ Sunday = 1; Monday = 2; Tuesday = 4; Wednesday = 8; Thursday = 16; Friday = 32; Saturday = 64 }
    $mask = 0
    foreach ($d in $Days) { $mask = $mask -bor $bits[$d] }
    return $mask
}

# For the log, always a text to render: "every day" for all seven days, otherwise the configured days as they are
# in the configuration (English day names)
function Format-WmUpdateDays {
    param([string[]]$Days)
    if ((Get-WmDaysMask $Days) -eq 127) { return New-WmText 'task.every_day' }
    return New-WmText 'task.days_list' @($Days -join ', ')
}

function Register-WmTasks {
    param([Parameter(Mandatory = $true)][hashtable]$Config)
    Write-WmLog -Key 'task.section'
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
        # 5. The groups' sign-in scripts, at every sign-in; 6. their startup scripts, at every start
        Register-WmLogonTask
        Register-WmStartupTask
    } else {
        foreach ($name in @($script:WmTaskJobs, $script:WmTaskLogon, $script:WmTaskStartup)) {
            if (Get-ScheduledTask -TaskPath $script:WmTaskPath -TaskName $name -ErrorAction SilentlyContinue) {
                Unregister-ScheduledTask -TaskPath $script:WmTaskPath -TaskName $name -Confirm:$false -ErrorAction Stop
                if ($name -eq $script:WmTaskJobs) { Write-WmLog -Key 'task.jobs_removed' }
            }
        }
    }

    $days = Format-WmUpdateDays (Get-WmUpdateDays $Config)
    Write-WmLog -Key 'task.registered' -Arguments @($days, (Get-WmSetting $Config 'UpdateTime' '12:00'))
}

# Called from the task: updates the schedule if it changed in the configuration.
# Changes only the trigger, so it doesn't interrupt the current run.
function Update-WmTaskSchedule {
    param([Parameter(Mandatory = $true)][hashtable]$Config)
    $task = Get-ScheduledTask -TaskPath $script:WmTaskPath -TaskName $script:WmTaskUpdate -ErrorAction SilentlyContinue
    if (-not $task) { return }
    # A computer that updated itself from a version without sign-in scripts gets their task here
    if ((Get-WmManagementSettings $Config) -and
            -not (Get-ScheduledTask -TaskPath $script:WmTaskPath -TaskName $script:WmTaskLogon -ErrorAction SilentlyContinue)) {
        Register-WmLogonTask
        Write-WmLog -Key 'task.logon_registered'
    }
    # ... and the one of the startup scripts
    if ((Get-WmManagementSettings $Config) -and
            -not (Get-ScheduledTask -TaskPath $script:WmTaskPath -TaskName $script:WmTaskStartup -ErrorAction SilentlyContinue)) {
        Register-WmStartupTask
        Write-WmLog -Key 'task.startup_registered'
    }
    # A trigger with a UTC offset (an older version) has no time here, so it is written again in local time
    $want = New-WmUpdateTrigger $Config
    $have = $task.Triggers | Select-Object -First 1
    $wantTime = Get-WmTriggerTime $want
    $haveTime = Get-WmTriggerTime $have
    $wantMask = Get-WmDaysMask (Get-WmUpdateDays $Config)
    $haveMask = [int]$have.DaysOfWeek
    if ($wantTime -ne $haveTime -or $wantMask -ne $haveMask) {
        Set-ScheduledTask -TaskPath $script:WmTaskPath -TaskName $script:WmTaskUpdate -Trigger $want -ErrorAction Stop | Out-Null
        Write-WmLog -Key 'task.schedule_changed' -Arguments @((Format-WmUpdateDays (Get-WmUpdateDays $Config)), $wantTime)
    }
}

# After a sign-in: the scripts and jobs that run as the user, for the person who signed in, now rather than at the
# next hour (an instance already running takes them as it is). After the scheduled update: what came due while it
# held the lock.
function Start-WmJobsTask {
    try {
        Start-ScheduledTask -TaskPath $script:WmTaskPath -TaskName $script:WmTaskJobs -ErrorAction Stop
    } catch {
        Write-WmLog -Key 'task.jobs_start_failed' -Arguments @(Get-WmErrorText $_) -Level warn
    }
}

function Start-WmNotifyTask {
    try {
        Start-ScheduledTask -TaskPath $script:WmTaskPath -TaskName $script:WmTaskNotify -ErrorAction Stop
    } catch {
        Write-WmLog -Key 'task.notify_failed' -Arguments @(Get-WmErrorText $_) -Level warn
    }
}
