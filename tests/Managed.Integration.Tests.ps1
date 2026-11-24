# Integration tests of the management source on real Windows: the osslsigncode signature and its timestamp (also of
# a certificate that expired), the checks of a new version, group scripts, jobs, the Loki batch and the hourly task. They CHANGE the computer (root store,
# C:\ProgramData\wmanager, C:\wm-ci, scheduled tasks), so they run only when WM_CI_SOURCES points to the
# sources built by tests/ci/build-sources.sh: on a throwaway CI runner (.github/workflows/tests.yml).
#   tests\ci\Invoke-Tests.ps1 -Kind Integration

Describe 'Management source on Windows' -Tag 'Integration' -Skip:(-not $env:WM_CI_SOURCES) {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        . (Join-Path $root 'lib\Common.ps1')
        . (Join-Path $root 'lib\Choco.ps1')
        . (Join-Path $root 'lib\Managed.ps1')
        . (Join-Path $root 'lib\Task.ps1')
        Initialize-WmLanguage -Lang 'en'

        $src = $env:WM_CI_SOURCES
        $id = (Get-Content -LiteralPath (Join-Path $src 'v1\source-id.txt') -Raw).Trim()
        $marker = 'C:\wm-ci\marker.txt'
        $secretFile = 'C:\wm-ci\secret.txt'
        $secretValue = 'ci-Secret-4711'
        $failMarker = 'C:\wm-ci\fail.txt'

        Initialize-WmRoot
        Initialize-WmLog 'ci'
        Copy-Item -LiteralPath (Join-Path $src 'wmanager-signing.cer') -Destination $script:WmRoot -Force

        function New-TestConfig {
            param([string]$Dir, [string]$SourceId = $id)
            @{
                Management = @{ Source = $Dir; SourceId = $SourceId; Certificate = 'wmanager-signing.cer'
                                ScriptTimeoutMinutes = 5; JobTimeoutMinutes = 5 }
                # Nothing listens there: the batch stays in logs\outbox, where the test reads it
                LokiUrl = 'https://127.0.0.1:9'; LokiUser = '1'; LokiToken = 'x'
                # groups/ci/scripts/30-secret.ps1 names it
                Secrets = @{ CiShare = $secretValue; Unused = 'not-for-this-script' }
            }
        }
        # A new run of wmanager: the content is resolved again
        function Reset-WmRun { $script:WmManaged = $null; $script:WmManagedError = $null }
        function Clear-WmBuffer { $script:WmLogBuffer.Clear() }
        function Get-WmBuffer { $script:WmLogBuffer.ToArray() }
        function Get-Serial { param([string]$Dir) [long](Import-PowerShellDataFile -LiteralPath (Join-Path $Dir 'manifest.psd1')).Serial }

        $thumb = (Get-WmSigningCertificate -Config (New-TestConfig (Join-Path $src 'v1')) -Dir $script:WmRoot).Thumbprint
        $nextThumb = (New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (Join-Path $src 'next-signing.cer')).Thumbprint

        # The wmanager certificates in the root store
        function Get-WmRootThumbprints {
            $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root', 'LocalMachine')
            $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
            try { return @($store.Certificates | Where-Object { $_.FriendlyName -eq $script:WmCertFriendlyName } | ForEach-Object Thumbprint) }
            finally { $store.Close() }
        }
        # Before a key change: the first certificate pinned, no next one, no copy of the source
        function Reset-WmKeys {
            Copy-Item -LiteralPath (Join-Path $src 'wmanager-signing.cer') -Destination $script:WmRoot -Force
            Remove-Item -LiteralPath $script:WmNextCertFile -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $script:WmManagedDir) { Remove-Item -LiteralPath $script:WmManagedDir -Recurse -Force }
            $null = Remove-WmSigningCertificates
            Install-WmSigningCertificate -Certificate (Get-WmSigningCertificate -Config (New-TestConfig (Join-Path $src 'v1')) -Dir $script:WmRoot)
        }
        function Get-PinnedThumbprint {
            (New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (Join-Path $script:WmRoot 'wmanager-signing.cer')).Thumbprint
        }
    }

    It 'accepts the osslsigncode signature once the certificate is in the root store' {
        Install-WmSigningCertificate -Certificate (Get-WmSigningCertificate -Config (New-TestConfig (Join-Path $src 'v1')) -Dir $script:WmRoot)
        $sig = Get-AuthenticodeSignature -LiteralPath (Join-Path $src 'v1\manifest.psd1')
        Write-Host "Signature: $($sig.Status) $($sig.StatusMessage)"
        $sig.Status | Should -Be 'Valid'
        $sig.SignerCertificate.Thumbprint | Should -Be $thumb
        # publish.sh timestamps it (DigiCert, or Sectigo), and Windows takes that timestamp
        Write-Host "Timestamp: $($sig.TimeStamperCertificate.Subject)"
        $sig.TimeStamperCertificate | Should -Not -BeNullOrEmpty
        # The second server's timestamp too
        $sig = Get-AuthenticodeSignature -LiteralPath (Join-Path $src 'sectigo\manifest.psd1')
        Write-Host "Sectigo: $($sig.Status) $($sig.TimeStamperCertificate.Subject)"
        $sig.Status | Should -Be 'Valid'
        $sig.TimeStamperCertificate.Subject | Should -Match 'Sectigo'
    }

    It 'accepts the first version, resolves the groups and merges the lists' {
        Reset-WmRun
        $c = Get-WmManagedContent -Config (New-TestConfig (Join-Path $src 'v1'))
        $c.Serial | Should -Be (Get-Serial (Join-Path $src 'v1'))
        $c.Groups | Should -Be @('all', 'ci')
        ($c.Requirements | Where-Object Name -eq '7zip').Pinned | Should -BeTrue      # the ci entry replaces the common one
        ($c.Requirements | Where-Object Name -eq 'vlc') | Should -Not -BeNullOrEmpty
        @($c.Scripts | ForEach-Object Path) | Should -Be @('groups/ci/scripts/10-marker.ps1', 'groups/ci/scripts/20-fail.ps1', 'groups/ci/scripts/30-secret.ps1', 'groups/ci/scripts/40-user.ps1')
        @($c.Jobs | ForEach-Object Name) | Should -Contain 'ci/ping'
        @($c.Jobs | ForEach-Object Name) | Should -Contain 'all/system-report'
    }

    It 'runs a script once per content, and a failing one every time' {
        $cfg = New-TestConfig (Join-Path $src 'v1')
        Reset-WmRun
        Invoke-WmGroupScripts -Config $cfg
        Reset-WmRun
        Invoke-WmGroupScripts -Config $cfg
        @(Get-Content -LiteralPath $marker).Count | Should -Be 1
        @(Get-Content -LiteralPath $failMarker).Count | Should -Be 2
    }

    It 'waits before trying a failed script again in the hourly run' {
        Reset-WmRun
        Invoke-WmGroupScripts -Config (New-TestConfig (Join-Path $src 'v1')) -RetryFailedAfterHours 20
        @(Get-Content -LiteralPath $failMarker).Count | Should -Be 2
    }

    It 'gives a script the secret it names, keeps the value out of the log and Loki, and without it runs nothing' {
        # 30-secret.ps1 ran with the other scripts above: it wrote the value it got, and printed it on both streams
        [IO.File]::ReadAllText($secretFile) | Should -BeExactly $secretValue
        $lines = @(Get-WmBuffer | ForEach-Object Line) -join "`n"
        $lines | Should -Match 'secret: \*\*\*'
        $lines | Should -Match 'on stderr too: \*\*\*'
        $lines | Should -Not -Match $secretValue
        [IO.File]::ReadAllText($script:WmLogFile) | Should -Not -Match $secretValue

        # A configuration without it: the script doesn't run and an error says why (the state put back afterwards)
        $saved = @{}
        foreach ($f in @($script:WmScriptsState, $script:WmScriptsFailed)) {
            $saved[$f] = if (Test-Path -LiteralPath $f) { [IO.File]::ReadAllBytes($f) } else { $null }
        }
        try {
            $done = Read-WmTabState $script:WmScriptsState
            $done.Remove('groups/ci/scripts/30-secret.ps1')
            Save-WmTabState -Path $script:WmScriptsState -Map $done
            Remove-Item -LiteralPath $secretFile
            $cfg = New-TestConfig (Join-Path $src 'v1')
            $cfg.Remove('Secrets')
            Reset-WmRun
            Clear-WmBuffer
            Invoke-WmGroupScripts -Config $cfg -RetryFailedAfterHours 20
            Test-Path -LiteralPath $secretFile | Should -BeFalse
            $errors = @(Get-WmBuffer | Where-Object { $_.Level -eq 'error' } | ForEach-Object Line) -join "`n"
            $errors | Should -Match "groups/ci/scripts/30-secret\.ps1: didn't run: the configuration of this computer has no secret CiShare"
            (Read-WmTabState $script:WmScriptsFailed)['groups/ci/scripts/30-secret.ps1'] | Should -Not -BeNullOrEmpty
        } finally {
            foreach ($f in @($saved.Keys)) {
                if ($null -ne $saved[$f]) { [IO.File]::WriteAllBytes($f, $saved[$f]) } else { Remove-Item -LiteralPath $f -ErrorAction SilentlyContinue }
            }
            Clear-WmBuffer
        }
    }

    It 'runs the due jobs and puts their lines into Loki unchanged, with a task label' {
        $cfg = New-TestConfig (Join-Path $src 'v1')
        Reset-WmRun
        Clear-WmBuffer
        $c = Get-WmManagedContent -Config $cfg -CachedOnly
        Invoke-WmGroupJobs -Config $cfg -Content $c

        $ping = @(Get-WmBuffer | Where-Object { $_.Task -eq 'ci/ping' -and $_.Line.StartsWith('{') })
        $ping.Count | Should -Be 1
        $p = $ping[0].Line | ConvertFrom-Json
        $p.group | Should -Be 'ci'
        $p.job | Should -Be 'ci/ping'

        # The example system report: every line is JSON with a kind
        $report = @(Get-WmBuffer | Where-Object { $_.Task -eq 'all/system-report' -and $_.Line.StartsWith('{') })
        foreach ($r in $report) { Write-Host $r.Line }
        $kinds = @($report | ForEach-Object { ($_.Line | ConvertFrom-Json).kind })
        $kinds | Should -Contain 'system'
        $kinds | Should -Contain 'disk'
        $kinds | Should -Contain 'security'

        Send-WmLokiLog -Config $cfg
        $batch = Get-ChildItem -LiteralPath (Join-Path $script:WmLogDir 'outbox') -Filter '*.json' -File | Sort-Object Name | Select-Object -Last 1
        $json = Get-Content -LiteralPath $batch.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $stream = @($json.streams | Where-Object { $_.stream.task -eq 'ci/ping' -and $_.stream.level -eq 'info' })
        $stream.Count | Should -Be 1
        $stream[0].stream.job | Should -Be 'ci'
        @($stream[0].values | Where-Object { $_[1].StartsWith('{') }).Count | Should -Be 1
    }

    It 'does not run a job again before its time' {
        $cfg = New-TestConfig (Join-Path $src 'v1')
        Reset-WmRun
        Clear-WmBuffer
        Invoke-WmGroupJobs -Config $cfg -Content (Get-WmManagedContent -Config $cfg -CachedOnly)
        @(Get-WmBuffer | Where-Object { $_.Task -eq 'ci/ping' }).Count | Should -Be 0
    }

    It 'accepts a newer version and runs the changed script again' {
        Reset-WmRun
        Invoke-WmGroupScripts -Config (New-TestConfig (Join-Path $src 'v2'))
        (Get-WmManagedManifest -Thumbprint $thumb -SourceId $id).Serial | Should -Be (Get-Serial (Join-Path $src 'v2'))
        @(Get-Content -LiteralPath $marker).Count | Should -Be 2
    }

    It 'rejects an older version' {
        $settings = (New-TestConfig (Join-Path $src 'v1')).Management
        { Update-WmManagedCopy -Settings $settings -Thumbprint $thumb } | Should -Throw '*older*'
    }

    It 'rejects a manifest of another source signed with the same key' {
        $settings = (New-TestConfig (Join-Path $src 'other')).Management
        { Update-WmManagedCopy -Settings $settings -Thumbprint $thumb } | Should -Throw '*another source*'
    }

    It 'rejects a changed file and a changed manifest' {
        # A computer without a copy yet, so every file is downloaded and checked
        Remove-Item -LiteralPath $script:WmManagedDir -Recurse -Force

        $changedFile = Join-Path $TestDrive 'changed-file'
        Copy-Item -LiteralPath (Join-Path $src 'v2') -Destination $changedFile -Recurse
        Add-Content -LiteralPath (Join-Path $changedFile 'groups\ci\scripts\10-marker.ps1') -Value '# changed'
        { Update-WmManagedCopy -Settings (New-TestConfig $changedFile).Management -Thumbprint $thumb } | Should -Throw '*SHA256*'

        $changedManifest = Join-Path $TestDrive 'changed-manifest'
        Copy-Item -LiteralPath (Join-Path $src 'v2') -Destination $changedManifest -Recurse
        $file = Join-Path $changedManifest 'manifest.psd1'
        $text = [IO.File]::ReadAllText($file)
        [IO.File]::WriteAllText($file, $text.Replace('Serial   = ', 'Serial   = 9'), (New-Object System.Text.UTF8Encoding($true)))
        { Update-WmManagedCopy -Settings (New-TestConfig $changedManifest).Management -Thumbprint $thumb } | Should -Throw '*signature*'

        Test-Path -LiteralPath $script:WmManagedDir | Should -BeFalse
    }

    It 'runs Invoke-Jobs.ps1 from start to end' {
        # Without a copy (removed above) the hourly run fetches the source; nothing is due and the failed script
        # waits for its retry, so the run ends without errors
        $configFile = Join-Path $root 'provision.config.psd1'
        @(
            '@{'
            "    Management = @{ Source = '$(Join-Path $src 'v2')'; SourceId = '$id'; Certificate = 'wmanager-signing.cer' }"
            "    Secrets = @{ CiShare = '$secretValue' }"
            '}'
        ) | Set-Content -LiteralPath $configFile -Encoding UTF8
        try {
            & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root 'Invoke-Jobs.ps1')
            $LASTEXITCODE | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $configFile -Force
        }
        (Get-WmManagedManifest -Thumbprint $thumb -SourceId $id).Serial | Should -Be (Get-Serial (Join-Path $src 'v2'))
        Test-Path -LiteralPath (Join-Path $script:WmLogDir ('jobs-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd'))) | Should -BeTrue
    }

    It 'runs a script that says run-as user in the session of the signed-in person, from SYSTEM (when the runner has one)' {
        # Run as an administrator here, it found nobody: it waits for the run of SYSTEM
        (Read-WmTabState $script:WmScriptsState).Keys | Where-Object { $_ -like 'groups/ci/scripts/40-user.ps1*' } | Should -BeNullOrEmpty
        $configFile = Join-Path $root 'provision.config.psd1'
        @(
            '@{'
            "    Management = @{ Source = '$(Join-Path $src 'v2')'; SourceId = '$id'; Certificate = 'wmanager-signing.cer' }"
            "    Secrets = @{ CiShare = '$secretValue' }"
            '}'
        ) | Set-Content -LiteralPath $configFile -Encoding UTF8
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $action = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$(Join-Path $root 'Invoke-Jobs.ps1')`""
        $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName 'wm-ci-jobs-system' -Action $action -Principal $principal -Force | Out-Null
        try {
            Start-ScheduledTask -TaskName 'wm-ci-jobs-system'
            $deadline = (Get-Date).AddMinutes(4)
            do { Start-Sleep -Seconds 3 } while ((Get-Date) -lt $deadline -and (Get-ScheduledTask -TaskName 'wm-ci-jobs-system').State -eq 'Running')
            Write-Host "Invoke-Jobs.ps1 as SYSTEM: $((Get-ScheduledTaskInfo -TaskName 'wm-ci-jobs-system').LastTaskResult)"
        } finally {
            Unregister-ScheduledTask -TaskName 'wm-ci-jobs-system' -Confirm:$false
            Remove-Item -LiteralPath $configFile -Force
        }
        $log = Get-Content -LiteralPath (Join-Path $script:WmLogDir ('jobs-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd'))) | Where-Object { $_ -like '*40-user*' -or $_ -like '*ran as*' }
        $log | ForEach-Object { Write-Host $_ }
        $sessions = @(Get-ChildItem -LiteralPath 'C:\wm-ci' -Filter 'user-*.txt' -ErrorAction SilentlyContinue)
        if ($sessions.Count -eq 0 -and -not ($log -match '40-user')) { Set-ItResult -Skipped -Because 'nobody is signed in on this runner'; return }
        $text = Get-Content -LiteralPath $sessions[0].FullName
        Write-Host $text
        $text | Should -Not -Match 'nt authority'
        $text | Should -Match '\|ci\|False$'
        ($log -join "`n") | Should -Match 'groups/ci/scripts/40-user\.ps1 \(.+\): done'
        @((Read-WmTabState $script:WmScriptsState).Keys | Where-Object { $_ -like 'groups/ci/scripts/40-user.ps1|S-1-5-*' }).Count | Should -Be 1
    }

    It 'registers the hourly jobs task' {
        Register-WmTasks -Config (New-TestConfig (Join-Path $src 'v2'))
        $task = Get-ScheduledTask -TaskPath $script:WmTaskPath -TaskName $script:WmTaskJobs
        $trigger = $task.Triggers | Select-Object -First 1
        Write-Host "Repetition: every $($trigger.Repetition.Interval), for '$($trigger.Repetition.Duration)'"
        $trigger.Repetition.Interval | Should -Be 'PT1H'
        $task.Actions[0].Arguments | Should -BeLike '*Invoke-Jobs.ps1*'
        (Get-ScheduledTaskInfo -TaskPath $script:WmTaskPath -TaskName $script:WmTaskJobs).NextRunTime | Should -Not -BeNullOrEmpty
    }

    It 'registers the sign-in task: SYSTEM, at every sign-in, half a minute later, queued' {
        $task = Get-ScheduledTask -TaskPath $script:WmTaskPath -TaskName $script:WmTaskLogon
        $trigger = $task.Triggers | Select-Object -First 1
        $trigger.CimClass.CimClassName | Should -Be 'MSFT_TaskLogonTrigger'
        $trigger.Delay | Should -Be 'PT30S'
        [string]$trigger.UserId | Should -BeNullOrEmpty
        $task.Principal.UserId | Should -Be 'SYSTEM'
        $task.Settings.MultipleInstances | Should -Be 'Queue'
        $task.Actions[0].Arguments | Should -BeLike '*Invoke-Logon.ps1*'
        # Without a management source it goes, with wmanager-Jobs
        Register-WmTasks -Config @{}
        Get-ScheduledTask -TaskPath $script:WmTaskPath -TaskName $script:WmTaskLogon -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        # A computer that updated itself from a version without it gets it at its scheduled update
        Update-WmTaskSchedule -Config (New-TestConfig (Join-Path $src 'v2'))
        Get-ScheduledTask -TaskPath $script:WmTaskPath -TaskName $script:WmTaskLogon | Should -Not -BeNullOrEmpty
        Register-WmTasks -Config (New-TestConfig (Join-Path $src 'v2'))
    }

    It 'registers the startup task: SYSTEM, at every start, a minute later, never twice at once' {
        $task = Get-ScheduledTask -TaskPath $script:WmTaskPath -TaskName $script:WmTaskStartup
        $trigger = $task.Triggers | Select-Object -First 1
        $trigger.CimClass.CimClassName | Should -Be 'MSFT_TaskBootTrigger'
        $trigger.Delay | Should -Be 'PT1M'
        $task.Principal.UserId | Should -Be 'SYSTEM'
        $task.Settings.MultipleInstances | Should -Be 'IgnoreNew'
        $task.Actions[0].Arguments | Should -BeLike '*Invoke-Startup.ps1*'
        # Without a management source it goes; a computer that updated itself from a version without it gets it at
        # its scheduled update
        Register-WmTasks -Config @{}
        Get-ScheduledTask -TaskPath $script:WmTaskPath -TaskName $script:WmTaskStartup -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        Update-WmTaskSchedule -Config (New-TestConfig (Join-Path $src 'v2'))
        Get-ScheduledTask -TaskPath $script:WmTaskPath -TaskName $script:WmTaskStartup | Should -Not -BeNullOrEmpty
        Register-WmTasks -Config (New-TestConfig (Join-Path $src 'v2'))
    }

    It 'runs Invoke-Startup.ps1 from start to end: the group''s startup script with its secret, hidden in the log' {
        $marker = 'C:\wm-ci\startup.txt'
        Remove-Item -LiteralPath $marker -ErrorAction SilentlyContinue
        $configFile = Join-Path $root 'provision.config.psd1'
        @(
            '@{'
            "    Management = @{ Source = '$(Join-Path $src 'v2')'; SourceId = '$id'; Certificate = 'wmanager-signing.cer' }"
            "    Secrets = @{ CiShare = '$secretValue' }"
            '}'
        ) | Set-Content -LiteralPath $configFile -Encoding UTF8
        try {
            & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root 'Invoke-Startup.ps1')
            $LASTEXITCODE | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $configFile -Force
        }
        [IO.File]::ReadAllText($marker) | Should -Be "ci|$($script:WmHostName)|$secretValue"
        $log = Get-ChildItem -LiteralPath $script:WmLogDir -Filter 'startup-*.log' | Sort-Object LastWriteTime | Select-Object -Last 1
        $text = [IO.File]::ReadAllText($log.FullName)
        $text | Should -Match 'startup secret: \*\*\*'
        $text | Should -Match 'ci/10-startup: done'
        $text | Should -Not -Match ([regex]::Escape($secretValue))
    }

    It 'compiles the session launcher in Windows PowerShell 5.1, and runs Invoke-Logon.ps1 from start to end' {
        . (Join-Path $root 'lib\UserSession.ps1')
        # Not SYSTEM here: no user token, so no sessions, and nothing to run
        { $null = Get-WmUserSessions } | Should -Not -Throw
        $configFile = Join-Path $root 'provision.config.psd1'
        @(
            '@{'
            "    Management = @{ Source = '$(Join-Path $src 'v2')'; SourceId = '$id'; Certificate = 'wmanager-signing.cer' }"
            '}'
        ) | Set-Content -LiteralPath $configFile -Encoding UTF8
        try {
            & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root 'Invoke-Logon.ps1')
            $LASTEXITCODE | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $configFile -Force
        }
    }

    It 'runs a program from SYSTEM in the session of the signed-in user, with variables, output and exit code' {
        $dir = 'C:\wm-ci\logon'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $result = Join-Path $dir 'result.txt'
        Remove-Item -LiteralPath $result -ErrorAction SilentlyContinue
        Set-Content -LiteralPath (Join-Path $dir 'user.ps1') -Value @(
            '"user: $(whoami)"'
            '"variable: $env:WMANAGER_SECRET_CI"'
            '"stdin: [$([Console]::In.ReadLine())]"'
            '[Console]::Error.WriteLine("on stderr")'
            'exit 7')
        Set-Content -LiteralPath (Join-Path $dir 'probe.ps1') -Value @(
            ". '$(Join-Path $root 'lib\UserSession.ps1')'"
            "`$out = '$result'"
            '$s = @(Get-WmUserSessions)'
            '"sessions: $($s.Count)" | Set-Content $out'
            'foreach ($x in $s) { "session $($x.SessionId) $($x.Domain)\$($x.User) $($x.LogonId)" | Add-Content $out }'
            'if ($s.Count -gt 0) {'
            "    `$r = Invoke-WmUserScript -SessionId `$s[0].SessionId -File '$(Join-Path $dir 'user.ps1')' -Environment @{ WMANAGER_SECRET_CI = 'ci-logon-4711' } -TimeoutMinutes 2"
            '    "exit: $($r.ExitCode)" | Add-Content $out'
            '    "output: $($r.Output.Trim() -replace ''\s*\r?\n\s*'', '' | '')" | Add-Content $out'
            '    "errors: $($r.Errors.Trim())" | Add-Content $out'
            '}'
            '"end" | Add-Content $out')
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $action = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$(Join-Path $dir 'probe.ps1')`""
        $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName 'wm-ci-logon-probe' -Action $action -Principal $principal -Force | Out-Null
        try {
            Start-ScheduledTask -TaskName 'wm-ci-logon-probe'
            $deadline = (Get-Date).AddMinutes(3)
            while ((Get-Date) -lt $deadline -and -not ((Test-Path -LiteralPath $result) -and (Get-Content -LiteralPath $result) -contains 'end')) { Start-Sleep -Seconds 2 }
        } finally {
            Unregister-ScheduledTask -TaskName 'wm-ci-logon-probe' -Confirm:$false
        }
        $text = (Get-Content -LiteralPath $result) -join "`n"
        Write-Host $text
        $text | Should -Match '(?m)^end$'
        if ($text -match 'sessions: 0') { Set-ItResult -Skipped -Because 'nobody is signed in on this runner (the VM test covers it)'; return }
        $text | Should -Match 'exit: 7'
        $text | Should -Match 'variable: ci-logon-4711'
        $text | Should -Match 'errors: on stderr'
        # Its input is empty: what reads it gets nothing at once instead of waiting
        $text | Should -Match 'stdin: \[\]'
        $text | Should -Not -Match 'user: nt authority'
    }

    It 'trusts the next certificate the source names, and forgets it when the source stops naming it' {
        Reset-WmKeys
        Reset-WmRun
        (Get-WmManagedContent -Config (New-TestConfig (Join-Path $src 'rot1'))).Serial | Should -Be (Get-Serial (Join-Path $src 'rot1'))
        Test-Path -LiteralPath $script:WmNextCertFile | Should -BeTrue
        $script:WmCertNext | Should -Be $nextThumb
        @(Get-WmRootThumbprints | Sort-Object) | Should -Be @(@($thumb, $nextThumb) | Sort-Object)
        Get-PinnedThumbprint | Should -Be $thumb

        Reset-WmRun
        (Get-WmManagedContent -Config (New-TestConfig (Join-Path $src 'rotcancel'))).Serial | Should -Be (Get-Serial (Join-Path $src 'rotcancel'))
        Test-Path -LiteralPath $script:WmNextCertFile | Should -BeFalse
        $script:WmCertNext | Should -Be ''
        @(Get-WmRootThumbprints) | Should -Be @($thumb)
    }

    It 'switches to the next certificate when the source comes signed with it' {
        Reset-WmKeys
        Reset-WmRun
        $null = Get-WmManagedContent -Config (New-TestConfig (Join-Path $src 'rot1'))
        Reset-WmRun
        Clear-WmBuffer
        (Get-WmManagedContent -Config (New-TestConfig (Join-Path $src 'rot2'))).Serial | Should -Be (Get-Serial (Join-Path $src 'rot2'))
        $log = @(Get-WmBuffer | ForEach-Object Line) -join "`n"
        $log | Should -Not -Match "couldn't be changed"
        Get-PinnedThumbprint | Should -Be $nextThumb -Because $log
        $script:WmCertCurrent | Should -Be $nextThumb
        @(Get-WmRootThumbprints) | Should -Be @($nextThumb)
        Test-Path -LiteralPath $script:WmNextCertFile | Should -BeFalse
        (@(Get-WmBuffer | ForEach-Object Line) -join "`n") | Should -Match 'signed with the next certificate'
        # The next run trusts only the new key
        Reset-WmRun
        (Get-WmManagedContent -Config (New-TestConfig (Join-Path $src 'rot2'))).Serial | Should -Be (Get-Serial (Join-Path $src 'rot2'))
    }

    It 'rejects the new key without the step that named it, and keeps the last copy' {
        Reset-WmKeys
        Reset-WmRun
        $null = Get-WmManagedContent -Config (New-TestConfig (Join-Path $src 'v2'))
        Reset-WmRun
        Clear-WmBuffer
        (Get-WmManagedContent -Config (New-TestConfig (Join-Path $src 'rot2'))).Serial | Should -Be (Get-Serial (Join-Path $src 'v2'))
        # Its certificate isn't in the root store either, so Windows itself calls the signature untrusted
        (@(Get-WmBuffer | ForEach-Object Line) -join "`n") | Should -Match 'Rejected the new version from the management source: invalid manifest signature|another certificate'
        Get-PinnedThumbprint | Should -Be $thumb
        Reset-WmKeys
    }

    It 'keeps a timestamped signature valid after its certificate expired, and rejects one without' {
        $expired = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (Join-Path $src 'expired-signing.cer')
        $tsa = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (Join-Path $src 'ci-tsa.cer')
        $expired.NotAfter | Should -BeLessThan (Get-Date)
        # The test timestamp server stands for DigiCert's, whose root Windows trusts
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root', 'LocalMachine')
        $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $store.Add($tsa)
        $store.Close()
        try {
            Install-WmSigningCertificate -Certificate $expired
            $sig = Get-AuthenticodeSignature -LiteralPath (Join-Path $src 'expired\manifest.psd1')
            Write-Host "Expired, timestamped: $($sig.Status) $($sig.StatusMessage)"
            $sig.Status | Should -Be 'Valid'
            $sig.TimeStamperCertificate.Thumbprint | Should -Be $tsa.Thumbprint
            { Test-WmManifestSignature -Path (Join-Path $src 'expired\manifest.psd1') -Thumbprint $expired.Thumbprint } | Should -Not -Throw
            $sig = Get-AuthenticodeSignature -LiteralPath (Join-Path $src 'expired-nots\manifest.psd1')
            Write-Host "Expired, no timestamp: $($sig.Status) $($sig.StatusMessage)"
            $sig.Status | Should -Not -Be 'Valid'
            { Test-WmManifestSignature -Path (Join-Path $src 'expired-nots\manifest.psd1') -Thumbprint $expired.Thumbprint } | Should -Throw
        } finally {
            $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
            $store.Remove($tsa)
            $store.Close()
            Reset-WmKeys
        }
    }

    It 'removes the signing certificate again, and forgets a next one (Restore-Backup)' {
        Copy-Item -LiteralPath (Join-Path $src 'next-signing.cer') -Destination $script:WmNextCertFile -Force
        Remove-WmSigningCertificates | Should -BeGreaterThan 0
        Test-Path -LiteralPath $script:WmNextCertFile | Should -BeFalse
        (Get-AuthenticodeSignature -LiteralPath (Join-Path $src 'v2\manifest.psd1')).Status | Should -Not -Be 'Valid'
    }
}
