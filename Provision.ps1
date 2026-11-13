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
. (Join-Path $here 'lib\Debloat.ps1')
. (Join-Path $here 'lib\Privacy.ps1')
. (Join-Path $here 'lib\Choco.ps1')
. (Join-Path $here 'lib\Task.ps1')

# ---------------------------------------------------------------------------
# Helper steps
# ---------------------------------------------------------------------------

function Test-WmInteractive {
    if (-not [Environment]::UserInteractive) { return $false }
    if ([Environment]::GetCommandLineArgs() | Where-Object { $_ -match '^-NonI' }) { return $false }
    try { if ([Console]::IsInputRedirected) { return $false } } catch { return $false }
    return $true
}

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

function New-WmRestorePoint {
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        # Windows allows one restore point per 24 h; lift the limit for the duration of provisioning
        $sr = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
        $old = (Get-ItemProperty -LiteralPath $sr -Name 'SystemRestorePointCreationFrequency' -ErrorAction SilentlyContinue).SystemRestorePointCreationFrequency
        Set-WmRegValue $sr 'SystemRestorePointCreationFrequency' 0 | Out-Null
        Checkpoint-Computer -Description 'wmanager: before provisioning' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        if ($null -eq $old) { Remove-WmRegValue $sr 'SystemRestorePointCreationFrequency' } else { Set-WmRegValue $sr 'SystemRestorePointCreationFrequency' $old | Out-Null }
        Write-WmLog 'Utworzono punkt przywracania systemu.'
    } catch {
        Write-WmLog "Nie udało się utworzyć punktu przywracania: $($_.Exception.Message)" -Level warn
    }
}

function Install-WmFiles {
    param([string]$ConfigFile)
    $src = (Resolve-Path -LiteralPath $here).Path.TrimEnd('\')
    $dst = (Resolve-Path -LiteralPath $script:WmRoot).Path.TrimEnd('\')
    if ($src -ne $dst) {
        foreach ($f in @('Provision.ps1', 'Update-Packages.ps1', 'Notify-User.ps1', 'run.cmd', 'choco-reqs.txt')) {
            $p = Join-Path $src $f
            if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination $dst -Force }
        }
        Copy-Item -Path (Join-Path $src 'lib\*.ps1') -Destination (Join-Path $dst 'lib') -Force
        Copy-Item -LiteralPath $ConfigFile -Destination (Join-Path $dst 'provision.config.psd1') -Force
        Get-ChildItem -LiteralPath $dst -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
        Write-WmLog "Pliki skopiowane do $dst"
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
if ($newName -ne $env:COMPUTERNAME) { $script:WmHostName = $newName }
Write-WmLog "wmanager provisioning: $($os.Caption) build $($os.BuildNumber), komputer $env:COMPUTERNAME"
Send-WmHealthcheck -Config $config -Signal start
$failed = $false

try {
    if (-not $SkipRestorePoint) { New-WmRestorePoint }

    Install-WmFiles -ConfigFile $ConfigPath
    $config = Import-WmConfig (Join-Path $script:WmRoot 'provision.config.psd1')

    if ($newName -ne $env:COMPUTERNAME) {
        try {
            Rename-Computer -NewName $newName -Force -ErrorAction Stop
            Write-WmLog "Nazwa komputera zmieniona: $env:COMPUTERNAME -> $newName (działa po restarcie)."
        } catch {
            $script:WmHostName = $env:COMPUTERNAME
            Write-WmLog "Nie udało się zmienić nazwy na $newName : $($_.Exception.Message)" -Level error
        }
    } else {
        Write-WmLog "Nazwa komputera bez zmian: $env:COMPUTERNAME"
    }

    Invoke-WmDebloat -Config $config
    if (Get-WmSetting $config 'Privacy' $true) { Invoke-WmPrivacy }

    Install-WmChocolatey -Config $config
    $reqs = ConvertFrom-WmRequirements -Text (Get-WmRequirementsText -Config $config -BaseDir $here)
    $null = Sync-WmPackages -Requirements $reqs -ProcessMap (Get-WmSetting $config 'RunningProcessMap' @{})

    Set-WmDefaultBrowser -Config $config
    Write-WmPublicState -Config $config
    Register-WmTasks -Config $config
} catch {
    $failed = $true
    Write-WmLog "Provisioning przerwany: $($_.Exception.Message)" -Level error
} finally {
    if ($script:WmErrors -gt 0) { $failed = $true }
    Write-WmLog ("Koniec: ostrzeżenia {0}, błędy {1}. Log: {2}" -f $script:WmWarnings, $script:WmErrors, $script:WmLogFile)
    Remove-WmOldLogs -Days ([int](Get-WmSetting $config 'LogRetentionDays' 90))
    Send-WmLokiLog -Config $config
    $signal = 'success'
    if ($failed) { $signal = 'fail' }
    Send-WmHealthcheck -Config $config -Signal $signal -Body (Get-WmLogTail 60)
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
