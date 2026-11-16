<#
.SYNOPSIS
    wmanager: installs the latest release from GitHub and runs provisioning. No USB drive needed.

.DESCRIPTION
    In PowerShell started as administrator:

        irm https://github.com/lechup/wmanager/releases/latest/download/install.ps1 | iex

    or, with parameters:

        & ([scriptblock]::Create((irm https://github.com/lechup/wmanager/releases/latest/download/install.ps1))) -ComputerName OFFICE-03

    Downloads the ZIP of the release, checks it against SHA256SUMS of the same release, unpacks it to a temporary
    folder, asks where provision.config.psd1 is (a path or any https:// address; Enter = the example configuration)
    and runs Provision.ps1 in Windows PowerShell 5.1, the way run.cmd does. The temporary folder (with the tokens of
    the configuration) is removed at the end; provisioning keeps its own copy in C:\ProgramData\wmanager.

.PARAMETER ComputerName
    Passed to Provision.ps1 (without it provisioning asks).
.PARAMETER Config
    Where the configuration is, instead of the question: a path or an https:// address. '-' = the example.
.PARAMETER AuthHeader
    Authorization header for an https:// configuration (e.g. 'token github_pat_...'), instead of the question.
.PARAMETER Tag
    A given release (e.g. v0.1.0) instead of the latest.
.PARAMETER Repository
    owner/name of the GitHub repository.
#>
param(
    [string]$ComputerName,
    [string]$Config,
    [string]$AuthHeader,
    [string]$Tag,
    [string]$Repository = 'lechup/wmanager'
)

# --- Steps (also used by the tests: they set $WmInstallNoRun and dot-source this file) ---------------------------

# The ZIP and SHA256SUMS of a release (the object the GitHub API returns).
function Get-WmReleaseAssets {
    param([Parameter(Mandatory = $true)]$Release)
    $zip = @($Release.assets | Where-Object { $_.name -like 'wmanager-*.zip' })
    $sums = @($Release.assets | Where-Object { $_.name -eq 'SHA256SUMS' })
    if ($zip.Count -ne 1 -or $sums.Count -ne 1) { throw "Wydanie $($Release.tag_name) nie ma pliku wmanager-*.zip i SHA256SUMS." }
    return [pscustomobject]@{ Tag = [string]$Release.tag_name; Zip = $zip[0]; Sums = $sums[0] }
}

# Throws unless the file's SHA-256 is the one SHA256SUMS lists for its name.
function Assert-WmSha256 {
    param([Parameter(Mandatory = $true)][string]$File, [Parameter(Mandatory = $true)][string]$SumsFile)
    $name = Split-Path $File -Leaf
    $want = @(Get-Content -LiteralPath $SumsFile | ForEach-Object {
        if ($_ -match '^([0-9a-fA-F]{64}) [ *](.+)$' -and $Matches[2] -eq $name) { $Matches[1] }
    })
    if ($want.Count -ne 1) { throw "SHA256SUMS nie zawiera sumy pliku $name." }
    $have = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash
    if ($have -ne $want[0]) { throw "Suma SHA-256 pliku $name się nie zgadza: pobrany plik jest uszkodzony albo podmieniony. Nic nie uruchomiłem." }
}

# Where the certificate of a configuration is: next to it, at the same address or in the same folder.
function Get-WmSiblingLocation {
    param([Parameter(Mandatory = $true)][string]$Location, [Parameter(Mandatory = $true)][string]$Name)
    if ($Location -match '^https://') { return (New-Object Uri -ArgumentList ([Uri]$Location), $Name).AbsoluteUri }
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

# Puts provision.config.psd1 (and, with a management source, its certificate) into the unpacked folder.
function Copy-WmConfiguration {
    param([Parameter(Mandatory = $true)][string]$Location, [string]$AuthHeader, [Parameter(Mandatory = $true)][string]$Folder)
    if ($Location -match '^[A-Za-z][A-Za-z0-9+.-]*://' -and $Location -notmatch '^https://') { throw "Konfiguracja: tylko adres https:// ('$Location')." }
    $file = Join-Path $Folder 'provision.config.psd1'
    Get-WmFile -Location $Location -Destination $file -AuthHeader $AuthHeader
    # -ErrorAction Stop: in a session with the default preference a broken file is only an error message
    try { $cfg = Import-PowerShellDataFile -LiteralPath $file -ErrorAction Stop } catch { $cfg = $null; $why = $_.Exception.Message }
    if (-not ($cfg -is [hashtable])) { throw "Pobrany plik nie jest poprawną konfiguracją wmanagera: $why" }
    $m = $cfg['Management']
    if ($m -is [hashtable] -and $m['Source']) {
        $cert = if ($m['Certificate']) { [string]$m['Certificate'] } else { 'wmanager-signing.cer' }
        $from = Get-WmSiblingLocation -Location $Location -Name $cert
        try { Get-WmFile -Location $from -Destination (Join-Path $Folder $cert) -AuthHeader $AuthHeader }
        catch { throw "Konfiguracja ma źródło grup, ale nie ma obok niej certyfikatu $cert ($from): $($_.Exception.Message)" }
    }
}

# The second half: from the downloaded ZIP and SHA256SUMS to a finished provisioning run.
function Install-WmFromZip {
    param(
        [Parameter(Mandatory = $true)][string]$Zip,
        [Parameter(Mandatory = $true)][string]$Sums,
        [Parameter(Mandatory = $true)][string]$Work,
        [string]$ComputerName,
        [string]$Config,
        [string]$AuthHeader
    )
    Assert-WmSha256 -File $Zip -SumsFile $Sums
    Write-Host '  Suma SHA-256 się zgadza.'
    Expand-Archive -LiteralPath $Zip -DestinationPath $Work -Force
    $folder = Join-Path $Work 'wmanager'
    if (-not (Test-Path -LiteralPath (Join-Path $folder 'Provision.ps1'))) { throw 'W pliku ZIP nie ma wmanager\Provision.ps1.' }

    if (-not $Config) {
        Write-Host ''
        Write-Host 'Plik konfiguracji (provision.config.psd1 z init.cmd): ścieżka, np. E:\provision.config.psd1 albo'
        Write-Host '\\serwer\udział\wmanager\provision.config.psd1, albo adres https://. Enter = konfiguracja przykładowa'
        Write-Host '(bez Loki, Healthchecks i grup).'
        $Config = ([string](Read-Host 'Konfiguracja')).Trim()
    }
    if ($Config -and $Config -ne '-') {
        if ($Config -match '^https://' -and -not $AuthHeader) {
            $ss = Read-Host 'Nagłówek Authorization, np. token github_pat_... (Enter = bez)' -AsSecureString
            $AuthHeader = ([Net.NetworkCredential]::new('', $ss).Password).Trim()
        }
        Copy-WmConfiguration -Location $Config -AuthHeader $AuthHeader -Folder $folder
        Write-Host '  Konfiguracja pobrana.'
    } else {
        Write-Host '  Bez pliku konfiguracji: provisioning użyje przykładowej.'
    }

    # Like run.cmd: Windows PowerShell 5.1 in this console. Start-Process, not &: the child must keep the console
    # (provisioning asks questions), and nothing of its output may end up in this function's result.
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $folder 'Provision.ps1')
    if ($ComputerName) { $arguments += ' -ComputerName "{0}"' -f ($ComputerName -replace '"', '') }
    $p = Start-Process -FilePath $ps -ArgumentList $arguments -NoNewWindow -Wait -PassThru
    return $p.ExitCode
}

function Install-Wmanager {
    param([string]$ComputerName, [string]$Config, [string]$AuthHeader, [string]$Tag, [string]$Repository)
    $ErrorActionPreference = 'Stop'   # only in this function (and what it calls), not in the user's session
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { Write-Host 'wmanager instaluje się tylko w Windows.' -ForegroundColor Red; return }
    $principal = New-Object Security.Principal.WindowsPrincipal -ArgumentList ([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host 'Uruchom PowerShell jako administrator (prawy przycisk: "Uruchom jako administrator") i wklej polecenie jeszcze raz.' -ForegroundColor Red
        return
    }
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }

    $which = if ($Tag) { "tags/$Tag" } else { 'latest' }
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/$which" -UseBasicParsing `
            -Headers @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'wmanager-install' } -TimeoutSec 30
    } catch {
        $status = 0
        try { $status = [int]$_.Exception.Response.StatusCode } catch { }
        if ($status -eq 404) { throw "Nie ma wydania $(if ($Tag) { $Tag } else { '(najnowszego)' }) w github.com/$Repository." }
        throw "Nie udało się sprawdzić wydań na GitHubie: $($_.Exception.Message)"
    }
    $assets = Get-WmReleaseAssets -Release $release
    Write-Host "wmanager $($assets.Tag): pobieram z github.com/$Repository..."

    $work = Join-Path ([IO.Path]::GetTempPath()) ('wmanager-install-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        $zip = Join-Path $work $assets.Zip.name
        $sums = Join-Path $work 'SHA256SUMS'
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $assets.Zip.browser_download_url -OutFile $zip -UseBasicParsing -TimeoutSec 300
        Invoke-WebRequest -Uri $assets.Sums.browser_download_url -OutFile $sums -UseBasicParsing -TimeoutSec 60
        $code = Install-WmFromZip -Zip $zip -Sums $sums -Work $work -ComputerName $ComputerName -Config $Config -AuthHeader $AuthHeader
        Write-Host ''
        Write-Host "Provisioning zakończony (kod $code)."
    } finally {
        # The unpacked configuration holds the tokens; provisioning keeps its own copy
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Not "exit" anywhere: with "irm | iex" it would close the administrator's PowerShell window
if (-not $WmInstallNoRun) {
    try {
        Install-Wmanager -ComputerName $ComputerName -Config $Config -AuthHeader $AuthHeader -Tag $Tag -Repository $Repository
    } catch {
        Write-Host "Instalacja przerwana: $($_.Exception.Message)" -ForegroundColor Red
    }
}
