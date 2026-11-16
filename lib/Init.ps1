# Configuration wizard (init.ps1): functions. Runs in Windows PowerShell 5.1 and in PowerShell 7 (Windows, Linux),
# so it doesn't use the other lib\*.ps1 files (they assume Windows and C:\ProgramData).

$script:WmIsWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
if ($PSVersionTable.PSVersion.Major -lt 6) {
    # Windows PowerShell 5.1 doesn't always offer TLS 1.2, which Grafana Cloud and GitHub require
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

$script:WmWorkDays = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday')
$script:WmEveryDay = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')

# --- Configuration text --------------------------------------------------------------------------------------
# The configuration is changed as text, value by value, so its comments and layout stay as they are.

# A PowerShell single-quoted string literal.
function ConvertTo-WmPsdString {
    param([AllowEmptyString()][string]$Value)
    return "'" + ($Value -replace "'", "''") + "'"
}

function ConvertTo-WmPsdArray {
    param([string[]]$Values)
    return '@(' + ((@($Values) | ForEach-Object { ConvertTo-WmPsdString $_ }) -join ', ') + ')'
}

# Replaces the value of "Name = <value>" (a quoted string, $true/$false, a number or @(...) on one line).
# Throws when the setting isn't in the text or appears more than once.
function Set-WmConfigText {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Literal
    )
    $pattern = '(?m)^(\s*' + [regex]::Escape($Name) + '\s*=\s*)(''(?:[^'']|'''')*''|\$true|\$false|-?\d+|@\([^)\r\n]*\))'
    $found = [regex]::Matches($Text, $pattern)
    if ($found.Count -ne 1) { throw "W pliku konfiguracji nie ma jednego ustawienia $Name (jest: $($found.Count)); dopisz je ręcznie." }
    $m = $found[0]
    return $Text.Substring(0, $m.Groups[2].Index) + $Literal + $Text.Substring($m.Groups[2].Index + $m.Groups[2].Length)
}

# UTF-8 with BOM and CRLF, like the other .psd1 files (Windows PowerShell 5.1 reads them correctly).
function Write-WmConfigFile {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Text)
    $crlf = ($Text -replace "`r`n", "`n") -replace "`n", "`r`n"
    [IO.File]::WriteAllText($Path, $crlf, (New-Object System.Text.UTF8Encoding($true)))
}

# --- Checking the answers ---------------------------------------------------------------------------------------

function Test-WmUpdateTime {
    param([string]$Value)
    $t = [datetime]::MinValue
    return ($Value -match '^\d{2}:\d{2}$') -and
        [datetime]::TryParseExact($Value, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$t)
}

# c = every day, r = working days, p = Monday; nothing for anything else. Wrap the result in @().
function Get-WmUpdateDaysChoice {
    param([string]$Choice)
    switch -Regex ($Choice.Trim().ToLowerInvariant()) {
        '^(c|codziennie)$'   { return $script:WmEveryDay }
        '^(r|robocze)$'      { return $script:WmWorkDays }
        '^(p|poniedzia.ek)$' { return 'Monday' }
    }
}

function Get-WmUpdateDaysLabel {
    param([string[]]$Days)
    $d = @($Days)
    if (-not (Compare-Object $d $script:WmEveryDay)) { return 'c' }
    if (-not (Compare-Object $d $script:WmWorkDays)) { return 'r' }
    if ($d.Count -eq 1 -and $d[0] -eq 'Monday') { return 'p' }
    return ''
}

# Healthchecks.io ping key: 22 characters, letters, digits, - and _.
function Test-WmPingKey {
    param([string]$Value)
    return $Value -match '^[A-Za-z0-9_-]{22}$'
}

function Test-WmSourceId {
    param([string]$Value)
    return $Value -match '^[A-Za-z0-9._-]{8,64}$'
}

# A management source: an https:// address or a full Windows folder path (C:\... or \\server\share\...), as the
# office computers read it (Get-WmManagementSettings in Common.ps1), also when the wizard runs on Linux.
function Test-WmManagementSource {
    param([string]$Value)
    if ($Value -match '^[A-Za-z][A-Za-z0-9+.-]*://') { return $Value -match '^https://' }
    return ($Value -match '^[A-Za-z]:\\') -or ($Value -match '^\\\\[^\\]+\\[^\\]+')
}

# --- Network checks ---------------------------------------------------------------------------------------------

function Get-WmHttpStatus {
    param($ErrorRecord)
    try { return [int]$ErrorRecord.Exception.Response.StatusCode } catch { return 0 }
}

# The JSON Loki gets from the test: one line, labels like wmanager's own (job "init").
function Get-WmLokiTestBody {
    param([Parameter(Mandatory = $true)][string]$HostName, [Parameter(Mandatory = $true)][DateTimeOffset]$Time)
    $ns = [string]($Time.ToUnixTimeMilliseconds() * 1000000)
    $stream = [ordered]@{ service_name = 'wmanager'; host = $HostName.ToLowerInvariant(); job = 'init'; level = 'info' }
    $body = @{ streams = @(@{ stream = $stream; values = @(, @($ns, 'wmanager init: test połączenia')) }) }
    return ConvertTo-Json -InputObject $body -Depth 6 -Compress
}

# Sends the test line. Returns $null when Loki took it, otherwise a description of the problem.
function Test-WmLoki {
    param([string]$Url, [string]$User, [string]$Token)
    if ($Url -notmatch '/loki/api/v1/push$') { $Url = $Url.TrimEnd('/') + '/loki/api/v1/push' }
    $auth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${User}:$Token"))
    $json = Get-WmLokiTestBody -HostName ([Environment]::MachineName) -Time ([DateTimeOffset]::UtcNow)
    try {
        Invoke-RestMethod -Uri $Url -Method Post -Headers @{ Authorization = $auth } -ContentType 'application/json' `
            -Body ([Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 20 -UseBasicParsing | Out-Null
        return $null
    } catch {
        switch (Get-WmHttpStatus $_) {
            401 { return 'Loki odrzuca dane logowania (401): sprawdź użytkownika i token.' }
            403 { return 'Token nie ma uprawnień do zapisu (403): potrzebny zakres logs:write.' }
            404 { return 'Pod tym adresem nie ma Loki (404): sprawdź adres.' }
        }
        return "Nie udało się połączyć z Loki: $($_.Exception.Message)"
    }
}

# Pings the check "<prefix>init" (Healthchecks creates it). $null on success, otherwise the problem.
function Test-WmHealthchecks {
    param([string]$BaseUrl, [string]$PingKey, [string]$SlugPrefix)
    $slug = ($SlugPrefix + 'init').ToLowerInvariant() -replace '[^a-z0-9_-]', '-'
    $url = '{0}/{1}/{2}?create=1' -f $BaseUrl.TrimEnd('/'), $PingKey, $slug
    try {
        Invoke-RestMethod -Uri $url -Method Post -Body 'wmanager init: test' -TimeoutSec 15 -UseBasicParsing | Out-Null
        return $null
    } catch {
        if ((Get-WmHttpStatus $_) -eq 404) { return 'Healthchecks nie zna tego klucza (404): sprawdź Ping key projektu.' }
        return "Nie udało się połączyć z Healthchecks: $($_.Exception.Message)"
    }
}

# Fetches manifest.psd1 of a management source to a temporary file. Returns the path; throws on failure.
function Get-WmSourceManifest {
    param([Parameter(Mandatory = $true)][string]$Source, [string]$AuthHeader)
    $file = Join-Path ([IO.Path]::GetTempPath()) ('wmanager-init-' + [guid]::NewGuid().ToString('N') + '.psd1')
    if ($Source -match '^https://') {
        $headers = @{}
        if ($AuthHeader) { $headers['Authorization'] = $AuthHeader }
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri ($Source.TrimEnd('/') + '/manifest.psd1') -OutFile $file -Headers $headers -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
    } else {
        Copy-Item -LiteralPath (Join-Path $Source 'manifest.psd1') -Destination $file -Force -ErrorAction Stop
    }
    return $file
}

# Whether the manifest is signed with the given certificate: 'ok', 'skipped' (no Authenticode outside Windows)
# or a description of the problem. The root certificate is usually not trusted on the computer the wizard runs
# on, so "untrusted root" counts as ok as long as the signer is this certificate and the content is intact.
function Test-WmManifestSigner {
    param([Parameter(Mandatory = $true)][string]$ManifestPath, [Parameter(Mandatory = $true)][string]$CertificatePath)
    if (-not $script:WmIsWindows -or -not (Get-Command Get-AuthenticodeSignature -ErrorAction SilentlyContinue)) { return 'skipped' }
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $CertificatePath
    $sig = Get-AuthenticodeSignature -FilePath $ManifestPath
    if (-not $sig.SignerCertificate) { return "manifest nie jest podpisany ($($sig.Status))" }
    if ($sig.SignerCertificate.Thumbprint -ne $cert.Thumbprint) {
        return "manifest podpisał inny certyfikat ($($sig.SignerCertificate.Thumbprint), oczekiwany $($cert.Thumbprint))"
    }
    if ([string]$sig.Status -notin @('Valid', 'UnknownError')) { return "podpis jest nieważny ($($sig.Status)): plik zmieniono po podpisaniu" }
    return 'ok'
}
