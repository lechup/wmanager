# Install from the internet, second step (README, "Quick start"). install.ps1 runs it from the unpacked release in
# Windows PowerShell 5.1, as administrator: it asks where provision.config.psd1 is (a path or an https:// address;
# Enter = the example), puts it and the certificate of a management source into the release folder and runs
# Provision.ps1 in this process, so the exit code is provisioning's. Without -Folder (the tests dot-source this file)
# it only defines its functions.
param(
    [string]$Folder,
    [string]$ComputerName,
    [string]$Config
)

# A path pasted from Explorer ("Copy as path") comes in quotes.
function ConvertFrom-WmPastedPath {
    param([AllowEmptyString()][string]$Value)
    return $Value.Trim().Trim('"').Trim("'").Trim()
}

# Where the certificate of a configuration is: in the same folder, or at the same address with the same query
# (a token in the query must reach the certificate too).
function Get-WmSiblingLocation {
    param([Parameter(Mandatory = $true)][string]$Location, [Parameter(Mandatory = $true)][string]$Name)
    if ($Location -match '^https://') {
        $b = New-Object UriBuilder -ArgumentList $Location
        $b.Path = $b.Path.Substring(0, $b.Path.LastIndexOf('/') + 1) + $Name
        return $b.Uri.AbsoluteUri
    }
    # [IO.Path], not Split-Path/Join-Path: those look the drive up (a USB drive letter or a share may not be mapped)
    return [IO.Path]::Combine([IO.Path]::GetDirectoryName($Location), $Name)
}

function Get-WmFile {
    param([string]$Location, [string]$Destination, [string]$AuthHeader)
    if ($Location -match '^https://') {
        $headers = @{}
        if ($AuthHeader) { $headers['Authorization'] = $AuthHeader }
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $Location -OutFile $Destination -Headers $headers -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
    } else {
        Copy-Item -LiteralPath $Location -Destination $Destination -Force -ErrorAction Stop
    }
}

# Puts provision.config.psd1 (and, with a management source, its certificate) into the folder. The management
# settings are checked by the same functions provisioning uses (lib\Common.ps1).
function Copy-WmConfiguration {
    param([Parameter(Mandatory = $true)][string]$Location, [string]$AuthHeader, [Parameter(Mandatory = $true)][string]$Folder)
    if ($Location -match '^[A-Za-z][A-Za-z0-9+.-]*://' -and $Location -notmatch '^https://') { throw "Konfiguracja: tylko adres https:// ('$Location')." }
    $file = Join-Path $Folder 'provision.config.psd1'
    Get-WmFile -Location $Location -Destination $file -AuthHeader $AuthHeader
    # -ErrorAction Stop: with the default preference a broken file is only an error message
    $why = ''
    try { $cfg = Import-PowerShellDataFile -LiteralPath $file -ErrorAction Stop } catch { $cfg = $null; $why = $_.Exception.Message }
    if (-not ($cfg -is [hashtable])) { throw "Pobrany plik nie jest poprawną konfiguracją wmanagera: $why" }
    $cert = Get-WmCertificateFileName $cfg   # $null without a management source; throws on a bad one
    if ($cert) {
        $from = Get-WmSiblingLocation -Location $Location -Name $cert
        try { Get-WmFile -Location $from -Destination (Join-Path $Folder $cert) -AuthHeader $AuthHeader }
        catch { throw "Konfiguracja ma źródło grup, ale obok niej nie ma certyfikatu $cert ($from): $($_.Exception.Message)" }
    }
}

if (-not $Folder) { return }

$ErrorActionPreference = 'Stop'
. (Join-Path $Folder 'lib\Common.ps1')
try {
    if (-not $Config) {
        Write-Host ''
        Write-Host 'Plik konfiguracji (provision.config.psd1 z init.cmd): ścieżka, np. E:\provision.config.psd1 albo'
        Write-Host '\\serwer\udział\wmanager\provision.config.psd1, albo adres https://. Enter = konfiguracja przykładowa'
        Write-Host '(bez Loki, Healthchecks i grup).'
        $Config = [string](Read-Host 'Konfiguracja')
    }
    $Config = ConvertFrom-WmPastedPath $Config
    if ($Config -and $Config -ne '-') {
        $auth = [string]$env:WM_INSTALL_AUTH
        if ($Config -match '^https://' -and -not $auth) {
            $ss = Read-Host 'Nagłówek Authorization, np. token github_pat_... (Enter = bez)' -AsSecureString
            $auth = ([Net.NetworkCredential]::new('', $ss).Password).Trim()
        }
        Copy-WmConfiguration -Location $Config -AuthHeader $auth -Folder $Folder
        Write-Host '  Konfiguracja pobrana.'
    } else {
        Write-Host '  Bez pliku konfiguracji: provisioning użyje przykładowej.'
    }
} catch {
    Write-Host "Instalacja przerwana: $($_.Exception.Message)" -ForegroundColor Red
    exit 5
}

$params = @{}
if ($ComputerName) { $params['ComputerName'] = $ComputerName }
& (Join-Path $Folder 'Provision.ps1') @params   # its "exit" ends this process with provisioning's code
exit $LASTEXITCODE
