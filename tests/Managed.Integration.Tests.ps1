# Integration tests of the management source on real Windows: the osslsigncode signature, the checks of a new
# version, group scripts, jobs, the Loki batch and the hourly task. They CHANGE the computer (root store,
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
            }
        }
        # A new run of wmanager: the content is resolved again
        function Reset-WmRun { $script:WmManaged = $null; $script:WmManagedError = $null }
        function Clear-WmBuffer { $script:WmLogBuffer.Clear() }
        function Get-WmBuffer { $script:WmLogBuffer.ToArray() }
        function Get-Serial { param([string]$Dir) [long](Import-PowerShellDataFile -LiteralPath (Join-Path $Dir 'manifest.psd1')).Serial }

        $thumb = (Get-WmSigningCertificate -Config (New-TestConfig (Join-Path $src 'v1')) -Dir $script:WmRoot).Thumbprint
    }

    It 'accepts the osslsigncode signature once the certificate is in the root store' {
        Install-WmSigningCertificate -Certificate (Get-WmSigningCertificate -Config (New-TestConfig (Join-Path $src 'v1')) -Dir $script:WmRoot)
        $sig = Get-AuthenticodeSignature -LiteralPath (Join-Path $src 'v1\manifest.psd1')
        Write-Host "Signature: $($sig.Status) $($sig.StatusMessage)"
        $sig.Status | Should -Be 'Valid'
        $sig.SignerCertificate.Thumbprint | Should -Be $thumb
    }

    It 'accepts the first version, resolves the groups and merges the lists' {
        Reset-WmRun
        $c = Get-WmManagedContent -Config (New-TestConfig (Join-Path $src 'v1'))
        $c.Serial | Should -Be (Get-Serial (Join-Path $src 'v1'))
        $c.Groups | Should -Be @('all', 'ci')
        ($c.Requirements | Where-Object Name -eq '7zip').Pinned | Should -BeTrue      # the ci entry replaces the common one
        ($c.Requirements | Where-Object Name -eq 'vlc') | Should -Not -BeNullOrEmpty
        @($c.Scripts | ForEach-Object Path) | Should -Be @('groups/ci/scripts/10-marker.ps1', 'groups/ci/scripts/20-fail.ps1')
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

    It 'registers the hourly jobs task' {
        Register-WmTasks -Config (New-TestConfig (Join-Path $src 'v2'))
        $task = Get-ScheduledTask -TaskPath $script:WmTaskPath -TaskName $script:WmTaskJobs
        $trigger = $task.Triggers | Select-Object -First 1
        Write-Host "Repetition: every $($trigger.Repetition.Interval), for '$($trigger.Repetition.Duration)'"
        $trigger.Repetition.Interval | Should -Be 'PT1H'
        $task.Actions[0].Arguments | Should -BeLike '*Invoke-Jobs.ps1*'
        (Get-ScheduledTaskInfo -TaskPath $script:WmTaskPath -TaskName $script:WmTaskJobs).NextRunTime | Should -Not -BeNullOrEmpty
    }

    It 'removes the signing certificate again (Restore-Backup)' {
        Remove-WmSigningCertificates | Should -BeGreaterThan 0
        (Get-AuthenticodeSignature -LiteralPath (Join-Path $src 'v2\manifest.psd1')).Status | Should -Not -Be 'Valid'
    }
}
