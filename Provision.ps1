#Requires -RunAsAdministrator
<#
.SYNOPSIS
    wmanager: Windows 11 provisioning for office work.

.DESCRIPTION
    Removes Microsoft bloatware and services, turns off telemetry and ads, installs Chocolatey
    and the packages from choco-reqs.txt (or from the signed management source, with the packages,
    scripts and jobs of the computer's groups), and registers a daily update. Safe to run
    repeatedly: every run brings the computer to the state defined in the configuration.

.PARAMETER ComputerName
    New computer name. Without it the script asks (Enter = keep current);
    without a console the question is skipped and the name stays.

.PARAMETER ConfigPath
    Path to the configuration file. Defaults to provision.config.psd1 next to the script.

.PARAMETER SkipRestorePoint
    Don't create a system restore point. Without it, a failed restore point stops provisioning
    unless the person at the console confirms going on without one.

.PARAMETER Lang
    Language of the screen: en, de, fr, es, it, pl, nl, pt, ro, cs. Without it: WMANAGER_LANG, then the Windows
    display language, then English. The log file and Loki are always in English.

.EXAMPLE
    .\Provision.ps1
.EXAMPLE
    .\Provision.ps1 -ComputerName OFFICE-03
#>
[CmdletBinding()]
param(
    [string]$ComputerName,
    [string]$ConfigPath,
    [switch]$SkipRestorePoint,
    [string]$Lang
)

$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
. (Join-Path $here 'lib\Common.ps1')
. (Join-Path $here 'lib\Backup.ps1')
. (Join-Path $here 'lib\Debloat.ps1')
. (Join-Path $here 'lib\Privacy.ps1')
. (Join-Path $here 'lib\Choco.ps1')
. (Join-Path $here 'lib\Managed.ps1')
. (Join-Path $here 'lib\Task.ps1')
Initialize-WmLanguage -Lang $Lang

# ---------------------------------------------------------------------------
# Helper steps
# ---------------------------------------------------------------------------

function Test-WmComputerName {
    param([string]$Name)
    # NetBIOS: 1-15 characters, letters/digits/hyphen, not all digits, no hyphen at the start or end
    return ($Name -match '^(?![0-9]+$)[A-Za-z0-9](?:[A-Za-z0-9-]{0,13}[A-Za-z0-9])?$')
}

function Resolve-WmComputerName {
    param([string]$Requested, [bool]$Prompt)
    $current = $env:COMPUTERNAME
    if ($Requested) {
        if (-not (Test-WmComputerName $Requested)) {
            throw (New-WmError 'provision.computer_name_invalid' @($Requested))
        }
        return $Requested.ToUpper()
    }
    if (-not $Prompt -or -not (Test-WmInteractive)) { return $current }
    while ($true) {
        $answer = (Read-Host (Get-WmText 'provision.computer_name_prompt' @($current))).Trim()
        if (-not $answer) { return $current }
        if (Test-WmComputerName $answer) { return $answer.ToUpper() }
        Write-Host (Get-WmText 'provision.computer_name_retry') -ForegroundColor Yellow
    }
}

# Returns $true when the restore point was created.
function New-WmRestorePoint {
    $sr = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $old = (Get-ItemProperty -LiteralPath $sr -Name 'SystemRestorePointCreationFrequency' -ErrorAction SilentlyContinue).SystemRestorePointCreationFrequency
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        # Windows allows one restore point per 24 h; lift the limit for the duration of provisioning
        Set-WmRegValue $sr 'SystemRestorePointCreationFrequency' 0 | Out-Null
        Checkpoint-Computer -Description 'wmanager: before provisioning' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-WmLog -Key 'provision.restore_point_created'
        return $true
    } catch {
        Write-WmLog -Key 'provision.restore_point_failed' -Arguments @(Get-WmErrorText $_) -Level warn
        return $false
    } finally {
        if ($null -eq $old) { Remove-WmRegValue $sr 'SystemRestorePointCreationFrequency' } else { Set-WmRegValue $sr 'SystemRestorePointCreationFrequency' $old | Out-Null }
    }
}

function Install-WmFiles {
    param([string]$ConfigFile, [hashtable]$Config)
    $src = (Resolve-Path -LiteralPath $here).Path.TrimEnd('\')
    $dst = (Resolve-Path -LiteralPath $script:WmRoot).Path.TrimEnd('\')
    if ($src -ne $dst) {
        # The catalogs of the messages first: the scheduled tasks and the notification run from this copy, and new
        # code must not meet old catalogs. Files a newer version no longer has are removed (all *.psd1 are loaded)
        $srcLang = Join-Path $src 'lang'
        $dstLang = Join-Path $dst 'lang'
        New-Item -ItemType Directory -Force -Path $dstLang -ErrorAction Stop | Out-Null
        Copy-Item -Path (Join-Path $srcLang '*') -Destination $dstLang -Recurse -Force -ErrorAction Stop
        foreach ($old in @(Get-ChildItem -LiteralPath $dstLang -Recurse -File)) {
            if (-not (Test-Path -LiteralPath (Join-Path $srcLang $old.FullName.Substring($dstLang.Length + 1)))) {
                Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
            }
        }
        foreach ($f in @('Provision.ps1', 'Update-Packages.ps1', 'Invoke-Jobs.ps1', 'Notify-User.ps1', 'Restore-Backup.ps1', 'run.cmd', 'choco-reqs.txt', 'VERSION')) {
            $p = Join-Path $src $f
            if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination $dst -Force -ErrorAction Stop }
        }
        # A copy without VERSION (a git checkout) must not leave an older release's version in the logs
        if (-not (Test-Path -LiteralPath (Join-Path $src 'VERSION'))) {
            Remove-Item -LiteralPath (Join-Path $dst 'VERSION') -Force -ErrorAction SilentlyContinue
        }
        Copy-Item -Path (Join-Path $src 'lib\*.ps1') -Destination (Join-Path $dst 'lib') -Force -ErrorAction Stop
        Get-ChildItem -LiteralPath $dst -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
        Write-WmLog -Key 'provision.files_copied' -Arguments @($dst)
    }
    # The config is copied whenever it comes from elsewhere, also when running from $dst itself with -ConfigPath
    $dstConfig = Join-Path $dst 'provision.config.psd1'
    $srcConfig = (Resolve-Path -LiteralPath $ConfigFile).Path
    if ($srcConfig -ne $dstConfig) {
        Copy-Item -LiteralPath $srcConfig -Destination $dstConfig -Force -ErrorAction Stop
        Write-WmLog -Key 'provision.config_copied' -Arguments @($srcConfig)
    }
    # The signing certificate travels with the config; the scheduled update and the hourly run check the source with it
    $cert = Get-WmCertificateFileName $Config
    if ($cert) {
        $srcCert = Join-Path (Split-Path $srcConfig -Parent) $cert
        $dstCert = Join-Path $dst $cert
        if ($srcCert -ne $dstCert) {
            Copy-Item -LiteralPath $srcCert -Destination $dstCert -Force -ErrorAction Stop
            Write-WmLog -Key 'provision.certificate_copied' -Arguments @($srcCert)
        }
    }
    Set-WmFolderAcl -Path $dst -ConfigFile (Join-Path $dst 'provision.config.psd1')
}

function Write-WmPublicState {
    param([hashtable]$Config)
    # Settings without secrets, readable by Notify-User.ps1 (the user account can't read the configuration)
    $b = Get-WmSetting $Config 'DefaultBrowser' @{}
    $json = '{"DefaultBrowserProgId":' + (ConvertTo-WmJsonString ([string]$b.ProgId)) +
            ',"DefaultBrowserName":' + (ConvertTo-WmJsonString ([string]$b.Name)) + '}'
    [IO.File]::WriteAllText($script:WmPublicState, $json, (New-Object System.Text.UTF8Encoding($false)))
}

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------

$os = Get-CimInstance -ClassName Win32_OperatingSystem
if ([int]$os.BuildNumber -lt 22000) {
    Write-Host (Get-WmText 'provision.not_windows11' @($os.Caption, $os.BuildNumber)) -ForegroundColor Red
    exit 2
}

if (-not $ConfigPath) { $ConfigPath = Join-Path $here 'provision.config.psd1' }
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    $example = Join-Path $here 'provision.config.example.psd1'
    Write-Host (Get-WmText 'provision.config_example' @($ConfigPath)) -ForegroundColor Yellow
    Copy-Item -LiteralPath $example -Destination $ConfigPath
}
$config = Import-WmConfig $ConfigPath
# A mistake in the management settings stops provisioning before anything changes
try {
    Test-WmManagementConfig -Config $config -ConfigDir (Split-Path (Resolve-Path -LiteralPath $ConfigPath).Path -Parent)
} catch {
    Write-Host (Get-WmText 'provision.management_config_error' @(Get-WmErrorText $_)) -ForegroundColor Red
    exit 2
}

try {
    $newName = Resolve-WmComputerName -Requested $ComputerName -Prompt ([bool](Get-WmSetting $config 'PromptComputerName' $true))
} catch {
    Write-Host (Get-WmText 'provision.stopped' @(Get-WmErrorText $_)) -ForegroundColor Red
    exit 1
}

$lock = Enter-WmLock
if (-not $lock) {
    Write-Host (Get-WmText 'provision.lock_wait') -ForegroundColor Yellow
    $lock = Enter-WmLock -WaitSeconds 600
}
if (-not $lock) { Write-Host (Get-WmText 'provision.lock_busy') -ForegroundColor Red; exit 3 }

try {
    Initialize-WmRoot
} catch {
    Write-Host (Get-WmText 'provision.root_failed' @($script:WmRoot, (Get-WmErrorText $_))) -ForegroundColor Red
    Exit-WmLock $lock
    exit 4
}
Initialize-WmLog 'provision'
Write-WmLog -Key 'provision.start' -Arguments @((Get-WmName), $os.Caption, $os.BuildNumber, $env:COMPUTERNAME)
$failed = $false
$hcStarted = $false

try {
    # Internet for Chocolatey and the package list, checked before anything changes.
    # Without it the person at the console decides; the scheduled update installs the programs later.
    $offline = $false
    $unreachable = @(Get-WmUnreachableHosts -Config $config)
    if ($unreachable.Count -gt 0) {
        Write-WmLog -Key 'provision.no_connection' -Arguments @($unreachable -join ', ') -Level warn
        if (-not (Confirm-WmContinue 'provision.confirm_offline')) {
            throw (New-WmError 'provision.stopped_offline')
        }
        $offline = $true
        Write-WmLog -Key 'provision.continue_offline' -Level warn
    }

    # Nothing is changed before this point. Without a restore point the person at the console decides.
    if ($SkipRestorePoint) {
        Write-WmLog -Key 'provision.restore_point_skipped'
    } elseif (-not (New-WmRestorePoint)) {
        if (-not (Confirm-WmContinue 'provision.confirm_no_restore_point')) {
            throw (New-WmError 'provision.stopped_no_restore_point')
        }
        Write-WmLog -Key 'provision.continue_no_restore_point' -Level warn
    }

    # Backup (Store apps, registry branches) and the undo journal for Restore-Backup.ps1; see lib\Backup.ps1
    $backupOk = $true
    try {
        $backupDir = Backup-WmState
        Write-WmLog -Key 'provision.backup_saved' -Arguments @($backupDir)
    } catch {
        $backupOk = $false
        Write-WmLog -Key 'provision.backup_failed' -Arguments @(Get-WmErrorText $_) -Level warn
    }
    try {
        Start-WmJournal
    } catch {
        $backupOk = $false
        Write-WmLog -Key 'provision.journal_failed' -Arguments @(Get-WmErrorText $_) -Level warn
    }
    if (-not $backupOk) {
        if (-not (Confirm-WmContinue 'provision.confirm_incomplete_backup')) {
            throw (New-WmError 'provision.stopped_no_backup')
        }
        Write-WmLog -Key 'provision.continue_incomplete_backup' -Level warn
    }

    # The scheduled tasks run the copied files, so if copying fails the run stops here
    Install-WmFiles -ConfigFile $ConfigPath -Config $config
    $config = Import-WmConfig (Join-Path $script:WmRoot 'provision.config.psd1')

    if ($newName -ne $env:COMPUTERNAME) {
        try {
            Rename-Computer -NewName $newName -Force -ErrorAction Stop
            $script:WmHostName = $newName
            Write-WmLog -Key 'provision.renamed' -Arguments @($env:COMPUTERNAME, $newName)
        } catch {
            Write-WmLog -Key 'provision.rename_failed' -Arguments @($newName, (Get-WmErrorText $_)) -Level error
        }
    } else {
        Write-WmLog -Key 'provision.name_unchanged' -Arguments @($env:COMPUTERNAME)
    }
    # Pinged only once the final name is known, so start and end go to the same check
    Send-WmHealthcheck -Config $config -Signal start
    $hcStarted = $true

    # Each stage on its own: a failure (e.g. no network for Chocolatey) is logged as an error,
    # but the scheduled tasks still get registered, so the scheduled update can finish the job.
    $null = Invoke-WmStep 'step.debloat' { Invoke-WmDebloat -Config $config }
    if (Get-WmSetting $config 'Privacy' $true) { $null = Invoke-WmStep 'step.privacy' { Invoke-WmPrivacy } }

    if ($offline) {
        Write-WmLog -Key 'provision.skip_programs_offline' -Level warn
    } elseif (Invoke-WmStep 'step.chocolatey' { Install-WmChocolatey -Config $config }) {
        $null = Invoke-WmStep 'step.packages' {
            $reqs = Get-WmRequirements -Config $config -BaseDir $here
            $null = Sync-WmPackages -Requirements $reqs -ProcessMap (Get-WmSetting $config 'RunningProcessMap' @{})
        }
    }

    $null = Invoke-WmStep 'step.default_browser' { Set-WmDefaultBrowser -Config $config }
    $null = Invoke-WmStep 'step.notify_settings' { Write-WmPublicState -Config $config }
    $null = Invoke-WmStep 'step.schedule' { Register-WmTasks -Config $config }
    # Group scripts must run as SYSTEM, and provisioning runs as the person at the console
    if (Get-WmManagementSettings $config) {
        Write-WmLog -Key 'provision.group_jobs_later'
    }
} catch {
    $failed = $true
    Write-WmLog -Key 'provision.stopped' -Arguments @(Get-WmErrorText $_) -Level error
} finally {
    Stop-WmJournal
    if ($script:WmErrors -gt 0) { $failed = $true }
    Write-WmLog -Key 'provision.summary' -Arguments @($script:WmWarnings, $script:WmErrors, $script:WmLogFile)
    Remove-WmOldLogs -Days ([int](Get-WmSetting $config 'LogRetentionDays' 90))
    Send-WmLokiLog -Config $config
    # Stopped before the name was settled: no ping. The person at the console sees the result, and a
    # ping under the old name would create (?create=1) a check that never hears from this computer again.
    if ($hcStarted) {
        $signal = 'success'
        if ($failed) { $signal = 'fail' }
        Send-WmHealthcheck -Config $config -Signal $signal -Body (Get-WmLogTail 60)
    }
    Exit-WmLock $lock
}

Write-Host ''
if ($failed) {
    Write-Host (Get-WmText 'provision.finished_with_errors') -ForegroundColor Yellow
} else {
    Write-Host (Get-WmText 'provision.finished') -ForegroundColor Green
}
if ($failed) { exit 1 }
exit 0
