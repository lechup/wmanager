<#
.SYNOPSIS
    wmanager: installs the latest release from GitHub and runs provisioning. No USB drive needed.

.DESCRIPTION
    In PowerShell started as administrator:

        irm https://github.com/lechup/wmanager/releases/latest/download/install.ps1 | iex

    or, with parameters:

        & ([scriptblock]::Create((irm https://github.com/lechup/wmanager/releases/latest/download/install.ps1))) -ComputerName OFFICE-03

    Downloads SHA256SUMS and the ZIP of the release (the download links, not the GitHub API, which allows only 60
    requests an hour from one address), checks the ZIP, unpacks it to a temporary folder and runs lib\Install.ps1
    from it in Windows PowerShell 5.1: that asks where provision.config.psd1 is and runs Provision.ps1. The temporary
    folder (with the tokens of the configuration) is removed at the end.

    This file stays plain ASCII without a BOM (tests/ci/Test-Syntax.ps1 checks it): "irm | iex" in Windows
    PowerShell 5.1 reads a release asset (application/octet-stream) as ISO-8859-1, so a BOM or Polish letters would
    break it. Its few messages are therefore without Polish letters; the rest is in lib\Install.ps1.

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
.PARAMETER ReleasesUrl
    https:// address of the releases with GitHub's layout (latest/download/..., download/<tag>/...), for a mirror;
    defaults to https://github.com/<Repository>/releases.
#>
param(
    [string]$ComputerName,
    [string]$Config,
    [string]$AuthHeader,
    [string]$Tag,
    [string]$Repository = 'lechup/wmanager',
    [string]$ReleasesUrl
)

# --- Steps (the tests set $WmInstallNoRun and dot-source this file) ------------------------------------------------

# The name of the release ZIP in SHA256SUMS (wmanager-<tag>.zip).
function Get-WmZipName {
    param([Parameter(Mandatory = $true)][string]$SumsFile)
    $names = @(Get-Content -LiteralPath $SumsFile | ForEach-Object {
        if ($_ -match '^[0-9a-fA-F]{64} [ *](wmanager-[0-9A-Za-z.-]+\.zip)$') { $Matches[1] }
    })
    if ($names.Count -ne 1) { throw 'SHA256SUMS nie wskazuje jednego pliku wmanager-*.zip.' }
    return $names[0]
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
    if ($have -ne $want[0]) { throw "Suma SHA-256 pliku $name sie nie zgadza: plik jest uszkodzony albo niepelny. Nic nie uruchomilem." }
}

function Install-Wmanager {
    param([string]$ComputerName, [string]$Config, [string]$AuthHeader, [string]$Tag, [string]$Repository, [string]$ReleasesUrl)
    $ErrorActionPreference = 'Stop'   # only in this function (and what it calls), not in the user's session
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { Write-Host 'wmanager instaluje sie tylko w Windows.' -ForegroundColor Red; return }
    $principal = New-Object Security.Principal.WindowsPrincipal -ArgumentList ([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host 'Uruchom PowerShell jako administrator (prawy przycisk: Uruchom jako administrator) i wklej polecenie jeszcze raz.' -ForegroundColor Red
        return
    }
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    $ProgressPreference = 'SilentlyContinue'   # the progress bar slows downloads down a lot in 5.1

    $work = Join-Path ([IO.Path]::GetTempPath()) ('wmanager-install-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        # SHA256SUMS of the latest (or the given) release names its ZIP; the ZIP comes from that same release,
        # so a release published in between doesn't mix two versions
        if (-not $ReleasesUrl) { $ReleasesUrl = "https://github.com/$Repository/releases" }
        if ($ReleasesUrl -notmatch '^https://') { throw 'ReleasesUrl: tylko adres https://.' }
        $ReleasesUrl = $ReleasesUrl.TrimEnd('/')
        $base = if ($Tag) { "$ReleasesUrl/download/$Tag" } else { "$ReleasesUrl/latest/download" }
        $sums = Join-Path $work 'SHA256SUMS'
        try { Invoke-WebRequest -Uri "$base/SHA256SUMS" -OutFile $sums -UseBasicParsing -TimeoutSec 60 }
        catch { throw "Nie ma wydania $(if ($Tag) { $Tag } else { '(najnowszego)' }) w $ReleasesUrl albo brak polaczenia: $($_.Exception.Message)" }
        $zipName = Get-WmZipName -SumsFile $sums
        $release = $zipName -replace '^wmanager-(.+)\.zip$', '$1'
        Write-Host "wmanager $release`: pobieram z $ReleasesUrl..."
        $zip = Join-Path $work $zipName
        Invoke-WebRequest -Uri "$ReleasesUrl/download/$release/$zipName" -OutFile $zip -UseBasicParsing -TimeoutSec 300
        Assert-WmSha256 -File $zip -SumsFile $sums
        Expand-Archive -LiteralPath $zip -DestinationPath $work -Force
        $folder = Join-Path $work 'wmanager'
        $next = Join-Path $folder 'lib\Install.ps1'
        if (-not (Test-Path -LiteralPath $next)) { throw 'W pliku ZIP nie ma wmanager\lib\Install.ps1.' }

        # The rest runs as a file in Windows PowerShell 5.1, in this console (it asks questions). The header and
        # the configuration's address (which may hold a token) go through the environment, not the command line
        # that the process list shows; lib\Install.ps1 removes them at once. WaitForExit, not -Wait, which also
        # waits for every program provisioning started (an updater left running would hold the installer up)
        if ($AuthHeader) { $env:WM_INSTALL_AUTH = $AuthHeader }
        if ($Config) { $env:WM_INSTALL_CONFIG = $Config }
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Folder "{1}"' -f $next, $folder
        if ($ComputerName) { $arguments += ' -ComputerName "{0}"' -f ($ComputerName -replace '"', '') }
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $p = Start-Process -FilePath $ps -ArgumentList $arguments -NoNewWindow -PassThru
        $null = $p.Handle   # keeps the exit code readable after the process ends (Windows PowerShell 5.1)
        $p.WaitForExit()
        Write-Host ''
        if ($p.ExitCode -eq 0) {
            Write-Host 'Gotowe. Uruchom ponownie komputer, zeby wszystkie zmiany zadzialaly.' -ForegroundColor Green
        } elseif ($p.ExitCode -eq 5) {
            # lib\Install.ps1 stopped before provisioning and said why
            Write-Host 'Instalacja przerwana przed provisioningiem; nic nie zostalo zmienione.' -ForegroundColor Red
        } else {
            Write-Host "Provisioning zakonczyl sie bledem (kod $($p.ExitCode)); szczegoly powyzej i w C:\ProgramData\wmanager\logs, jesli log powstal." -ForegroundColor Red
        }
    } finally {
        Remove-Item Env:\WM_INSTALL_AUTH, Env:\WM_INSTALL_CONFIG -ErrorAction SilentlyContinue
        # The unpacked configuration holds the tokens; provisioning keeps its own copy
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Never "exit": with "irm | iex" it would close the administrator's PowerShell window. Get-Variable: the
# variable is only set by the tests, and a profile with Set-StrictMode would refuse an undefined one
if (-not (Get-Variable -Name WmInstallNoRun -ValueOnly -ErrorAction SilentlyContinue)) {
    try {
        Install-Wmanager -ComputerName $ComputerName -Config $Config -AuthHeader $AuthHeader -Tag $Tag -Repository $Repository -ReleasesUrl $ReleasesUrl
    } catch {
        Write-Host "Instalacja przerwana: $($_.Exception.Message)" -ForegroundColor Red
    }
}
