#Requires -RunAsAdministrator
<#
.SYNOPSIS
    wmanager: Windows 11 provisioning for office work.

.DESCRIPTION
    Removes Microsoft bloatware and services, turns off telemetry and ads, installs Chocolatey
    and the packages from choco-reqs.txt, and registers a weekly update. Safe to run
    repeatedly: every run brings the computer to the state defined in the configuration.

.PARAMETER ComputerName
    New computer name. Without it the script asks (Enter = keep current);
    without a console the question is skipped and the name stays.

.PARAMETER ConfigPath
    Path to the configuration file. Defaults to provision.config.psd1 next to the script.

.PARAMETER SkipRestorePoint
    Don't create a system restore point. Without it, a failed restore point stops provisioning
    unless the person at the console confirms going on without one.

.EXAMPLE
    .\Provision.ps1
.EXAMPLE
    .\Provision.ps1 -ComputerName OFFICE-03
#>
[CmdletBinding()]
param(
    [string]$ComputerName,
    [string]$ConfigPath,
    [switch]$SkipRestorePoint
)

$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
. (Join-Path $here 'lib\Common.ps1')
. (Join-Path $here 'lib\Backup.ps1')
. (Join-Path $here 'lib\Debloat.ps1')
. (Join-Path $here 'lib\Privacy.ps1')
. (Join-Path $here 'lib\Choco.ps1')
. (Join-Path $here 'lib\Task.ps1')

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
            throw "Niepoprawna nazwa komputera '$Requested' (1-15 znaków: litery, cyfry, myślnik; nie same cyfry)."
        }
        return $Requested.ToUpper()
    }
    if (-not $Prompt -or -not (Test-WmInteractive)) { return $current }
    while ($true) {
        $answer = (Read-Host "Nazwa komputera [$current] (Enter = bez zmian)").Trim()
        if (-not $answer) { return $current }
        if (Test-WmComputerName $answer) { return $answer.ToUpper() }
        Write-Host 'Niepoprawna nazwa: 1-15 znaków, litery, cyfry i myślnik, nie same cyfry.' -ForegroundColor Yellow
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
        Write-WmLog 'Utworzono punkt przywracania systemu.'
        return $true
    } catch {
        Write-WmLog "Nie udało się utworzyć punktu przywracania: $($_.Exception.Message)" -Level warn
        return $false
    } finally {
        if ($null -eq $old) { Remove-WmRegValue $sr 'SystemRestorePointCreationFrequency' } else { Set-WmRegValue $sr 'SystemRestorePointCreationFrequency' $old | Out-Null }
    }
}

function Install-WmFiles {
    param([string]$ConfigFile)
    $src = (Resolve-Path -LiteralPath $here).Path.TrimEnd('\')
    $dst = (Resolve-Path -LiteralPath $script:WmRoot).Path.TrimEnd('\')
    if ($src -ne $dst) {
        foreach ($f in @('Provision.ps1', 'Update-Packages.ps1', 'Notify-User.ps1', 'Restore-Backup.ps1', 'run.cmd', 'choco-reqs.txt')) {
            $p = Join-Path $src $f
            if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination $dst -Force -ErrorAction Stop }
        }
        Copy-Item -Path (Join-Path $src 'lib\*.ps1') -Destination (Join-Path $dst 'lib') -Force -ErrorAction Stop
        Get-ChildItem -LiteralPath $dst -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
        Write-WmLog "Pliki skopiowane do $dst"
    }
    # The config is copied whenever it comes from elsewhere, also when running from $dst itself with -ConfigPath
    $dstConfig = Join-Path $dst 'provision.config.psd1'
    $srcConfig = (Resolve-Path -LiteralPath $ConfigFile).Path
    if ($srcConfig -ne $dstConfig) {
        Copy-Item -LiteralPath $srcConfig -Destination $dstConfig -Force -ErrorAction Stop
        Write-WmLog "Konfiguracja skopiowana z $srcConfig"
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
    Write-Host "To nie jest Windows 11 ($($os.Caption), build $($os.BuildNumber)). Przerywam." -ForegroundColor Red
    exit 2
}

if (-not $ConfigPath) { $ConfigPath = Join-Path $here 'provision.config.psd1' }
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    $example = Join-Path $here 'provision.config.example.psd1'
    Write-Host "Brak $ConfigPath, używam provision.config.example.psd1 (bez Loki i Healthchecks)." -ForegroundColor Yellow
    Copy-Item -LiteralPath $example -Destination $ConfigPath
}
$config = Import-WmConfig $ConfigPath

$newName = Resolve-WmComputerName -Requested $ComputerName -Prompt ([bool](Get-WmSetting $config 'PromptComputerName' $true))

$lock = Enter-WmLock
if (-not $lock) { Write-Host 'Inny przebieg wmanager już trwa. Spróbuj za chwilę.' -ForegroundColor Red; exit 3 }

try {
    Initialize-WmRoot
} catch {
    Write-Host "Nie mogę przygotować $($script:WmRoot): $($_.Exception.Message)" -ForegroundColor Red
    Exit-WmLock $lock
    exit 4
}
Initialize-WmLog 'provision'
Write-WmLog "wmanager provisioning: $($os.Caption) build $($os.BuildNumber), komputer $env:COMPUTERNAME"
$failed = $false
$hcStarted = $false

try {
    # Internet for Chocolatey and the package list, checked before anything changes.
    # Without it the person at the console decides; the weekly task installs the programs later.
    $offline = $false
    $unreachable = @(Get-WmUnreachableHosts -Config $config)
    if ($unreachable.Count -gt 0) {
        Write-WmLog "Brak połączenia z: $($unreachable -join ', ')" -Level warn
        if (-not (Confirm-WmContinue 'Brak internetu. Kontynuować bez instalacji programów (doinstaluje je cotygodniowe zadanie)?')) {
            throw 'Brak internetu; provisioning przerwany przed zmianami.'
        }
        $offline = $true
        Write-WmLog 'Kontynuuję bez internetu: Chocolatey i programy zostaną pominięte.' -Level warn
    }

    # Nothing is changed before this point. Without a restore point the person at the console decides.
    if ($SkipRestorePoint) {
        Write-WmLog 'Punkt przywracania pominięty (-SkipRestorePoint).'
    } elseif (-not (New-WmRestorePoint)) {
        if (-not (Confirm-WmContinue 'Nie udało się utworzyć punktu przywracania. Kontynuować bez niego?')) {
            throw 'Brak punktu przywracania; provisioning przerwany przed zmianami.'
        }
        Write-WmLog 'Kontynuuję bez punktu przywracania (potwierdzone w konsoli).' -Level warn
    }

    # Backup (Store apps, registry branches) and the undo journal for Restore-Backup.ps1; see lib\Backup.ps1
    $backupOk = $true
    try {
        $backupDir = Backup-WmState
        Write-WmLog "Kopia ustawień zapisana w $backupDir"
    } catch {
        $backupOk = $false
        Write-WmLog "Nie udało się zrobić kopii ustawień: $($_.Exception.Message)" -Level warn
    }
    try {
        Start-WmJournal
    } catch {
        $backupOk = $false
        Write-WmLog "Nie udało się uruchomić dziennika zmian: $($_.Exception.Message)" -Level warn
    }
    if (-not $backupOk) {
        if (-not (Confirm-WmContinue 'Kopia ustawień jest niepełna. Kontynuować mimo to?')) {
            throw 'Brak kopii ustawień; provisioning przerwany przed zmianami.'
        }
        Write-WmLog 'Kontynuuję z niepełną kopią ustawień (potwierdzone w konsoli).' -Level warn
    }

    # The scheduled tasks run the copied files, so if copying fails the run stops here
    Install-WmFiles -ConfigFile $ConfigPath
    $config = Import-WmConfig (Join-Path $script:WmRoot 'provision.config.psd1')

    if ($newName -ne $env:COMPUTERNAME) {
        try {
            Rename-Computer -NewName $newName -Force -ErrorAction Stop
            $script:WmHostName = $newName
            Write-WmLog "Nazwa komputera zmieniona: $env:COMPUTERNAME -> $newName (działa po restarcie)."
        } catch {
            Write-WmLog "Nie udało się zmienić nazwy na $newName : $($_.Exception.Message)" -Level error
        }
    } else {
        Write-WmLog "Nazwa komputera bez zmian: $env:COMPUTERNAME"
    }
    # Pinged only once the final name is known, so start and end go to the same check
    Send-WmHealthcheck -Config $config -Signal start
    $hcStarted = $true

    # Each stage on its own: a failure (e.g. no network for Chocolatey) is logged as an error,
    # but the scheduled tasks still get registered, so the weekly run can finish the job.
    $null = Invoke-WmStep 'Debloat' { Invoke-WmDebloat -Config $config }
    if (Get-WmSetting $config 'Privacy' $true) { $null = Invoke-WmStep 'Prywatność' { Invoke-WmPrivacy } }

    if ($offline) {
        Write-WmLog 'Pomijam Chocolatey i programy (brak internetu); zainstaluje je cotygodniowe zadanie.' -Level warn
    } elseif (Invoke-WmStep 'Chocolatey' { Install-WmChocolatey -Config $config }) {
        $null = Invoke-WmStep 'Paczki' {
            $reqs = ConvertFrom-WmRequirements -Text (Get-WmRequirementsText -Config $config -BaseDir $here)
            $null = Sync-WmPackages -Requirements $reqs -ProcessMap (Get-WmSetting $config 'RunningProcessMap' @{})
        }
    }

    $null = Invoke-WmStep 'Domyślna przeglądarka' { Set-WmDefaultBrowser -Config $config }
    $null = Invoke-WmStep 'Ustawienia dla powiadomień' { Write-WmPublicState -Config $config }
    $null = Invoke-WmStep 'Harmonogram zadań' { Register-WmTasks -Config $config }
} catch {
    $failed = $true
    Write-WmLog "Provisioning przerwany: $($_.Exception.Message)" -Level error
} finally {
    Stop-WmJournal
    if ($script:WmErrors -gt 0) { $failed = $true }
    Write-WmLog ("Koniec: ostrzeżenia {0}, błędy {1}. Log: {2}" -f $script:WmWarnings, $script:WmErrors, $script:WmLogFile)
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
    Write-Host 'Provisioning zakończony z błędami. Sprawdź log powyżej i uruchom skrypt ponownie.' -ForegroundColor Yellow
} else {
    Write-Host 'Provisioning zakończony. Uruchom ponownie komputer, żeby wszystkie zmiany zadziałały.' -ForegroundColor Green
}
if ($failed) { exit 1 }
exit 0
