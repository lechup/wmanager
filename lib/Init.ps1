# Configuration wizard (init.ps1): functions. Runs in Windows PowerShell 5.1 and in PowerShell 7 (Windows, Linux),
# so of the other lib\*.ps1 files it uses only Lang.ps1, which init.ps1 loads first (the rest assume Windows and
# C:\ProgramData).

$script:WmIsWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
if ($PSVersionTable.PSVersion.Major -lt 6) {
    # Windows PowerShell 5.1 doesn't always offer TLS 1.2, which Grafana Cloud and GitHub require
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

$script:WmWorkDays = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday')
$script:WmEveryDay = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')

# --- Configuration text --------------------------------------------------------------------------------------
# The configuration is changed as text, value by value, so its comments and layout stay as they are.

# A PowerShell single-quoted string literal. PowerShell also ends such a string at the typographic quotes
# U+2018, U+2019, U+201A and U+201B, so they are doubled like the apostrophe.
function ConvertTo-WmPsdString {
    param([AllowEmptyString()][string]$Value)
    return "'" + ($Value -replace "(['\u2018\u2019\u201A\u201B])", '$1$1') + "'"
}

function ConvertTo-WmPsdArray {
    param([string[]]$Values)
    return '@(' + ((@($Values) | ForEach-Object { ConvertTo-WmPsdString $_ }) -join ', ') + ')'
}

# The settings (of the given ones) that Set-WmConfigText can't change in this text: missing, repeated, or with a
# value it doesn't handle (e.g. an array over several lines).
function Get-WmConfigTextProblems {
    param([Parameter(Mandatory = $true)][string]$Text, [Parameter(Mandatory = $true)][string[]]$Names)
    foreach ($name in $Names) {
        try { $null = Set-WmConfigText $Text $name "''" } catch { $name }
    }
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
    if ($found.Count -ne 1) { throw (New-WmError 'init.setting_not_once' @($Name, $found.Count)) }
    $m = $found[0]
    return $Text.Substring(0, $m.Groups[2].Index) + $Literal + $Text.Substring($m.Groups[2].Index + $m.Groups[2].Length)
}

# UTF-8 with BOM and CRLF, like the other .psd1 files (Windows PowerShell 5.1 reads them correctly).
function Write-WmConfigFile {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Text)
    $crlf = ($Text -replace "`r`n", "`n") -replace "`n", "`r`n"
    [IO.File]::WriteAllText($Path, $crlf, (New-Object System.Text.UTF8Encoding($true)))
}

# The configuration text read as Import-PowerShellDataFile reads a file (data only), without writing it anywhere
function ConvertFrom-WmConfigText {
    param([Parameter(Mandatory = $true)][string]$Text)
    $tokens = $null
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errs)
    if (@($errs).Count -gt 0) { throw $errs[0].Message }
    $table = $ast.Find({ $args[0] -is [System.Management.Automation.Language.HashtableAst] }, $false)
    if (-not $table) { throw 'no @{ ... } in the configuration' }
    return $table.SafeGetValue()
}

# --- Secrets = @{ ... } (tools/wm.ps1 <company> secret) ----------------------------------------------------------
# Changed as text too, one entry per line ("Name = 'value'"); a table written otherwise is left to be changed by hand.

# Where the table is in $Lines: Start (its "Secrets = @{" line), End (its "}" line; the same line for "@{}"), or $null
# when there is none
function Find-WmConfigSecrets {
    param([AllowEmptyCollection()][string[]]$Lines)
    $starts = @(for ($i = 0; $i -lt $Lines.Count; $i++) { if ($Lines[$i] -match '^\s*Secrets\s*=') { $i } })
    if ($starts.Count -eq 0) { return $null }
    if ($starts.Count -gt 1) { throw (New-WmError 'init.setting_not_once' @('Secrets', $starts.Count)) }
    $s = $starts[0]
    if ($Lines[$s] -match '^\s*Secrets\s*=\s*@\{\s*\}\s*(#.*)?$') { return [pscustomobject]@{ Start = $s; End = $s } }
    if ($Lines[$s] -notmatch '^\s*Secrets\s*=\s*@\{\s*(#.*)?$') { throw (New-WmError 'init.secrets_layout') }
    for ($e = $s + 1; $e -lt $Lines.Count; $e++) {
        if ($Lines[$e] -match '^\s*\}\s*(#.*)?$') { return [pscustomobject]@{ Start = $s; End = $e } }
        if ($Lines[$e] -notmatch '^\s*(#.*)?$' -and $Lines[$e] -notmatch "^\s*[A-Za-z][A-Za-z0-9_]*\s*=\s*'(?:[^']|'')*'\s*(#.*)?$") {
            throw (New-WmError 'init.secrets_layout')
        }
    }
    throw (New-WmError 'init.secrets_layout')
}

# The configuration text with Secrets.<Name> = <Value>: the entry replaced (whatever the letter case of its name), or
# added to the table, or a table added before the configuration's closing brace. The name and value are the caller's
# to check (Test-WmSecretName in lib\Groups.ps1; text on one line).
function Set-WmConfigSecretText {
    param([Parameter(Mandatory = $true)][string]$Text, [Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$Value)
    $nl = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.AddRange([string[]]($Text -split "\r?\n"))
    $entry = $Name + ' = ' + (ConvertTo-WmPsdString $Value)
    $b = Find-WmConfigSecrets $lines.ToArray()
    if (-not $b) {
        $last = -1
        for ($i = $lines.Count - 1; $i -ge 0; $i--) { if ($lines[$i] -match '^\}\s*$') { $last = $i; break } }
        if ($last -lt 0) { throw (New-WmError 'init.secrets_layout') }
        $lines.InsertRange($last, [string[]]@(
            '',
            '    # Secrets for the scripts and jobs of the groups (docs/groups.md): pwsh tools/wm.ps1 <company> secret <name>',
            '    Secrets = @{',
            "        $entry",
            '    }'))
        return ($lines -join $nl)
    }
    $indent = [regex]::Match($lines[$b.Start], '^\s*').Value
    if ($b.End -eq $b.Start) {
        $lines[$b.Start] = "${indent}Secrets = @{"
        $lines.InsertRange($b.Start + 1, [string[]]@("$indent    $entry", "$indent}"))
        return ($lines -join $nl)
    }
    for ($i = $b.Start + 1; $i -lt $b.End; $i++) {
        if ($lines[$i] -match '^(\s*)([A-Za-z][A-Za-z0-9_]*)\s*=' -and $Matches[2] -ieq $Name) {
            $lines[$i] = $Matches[1] + $entry
            return ($lines -join $nl)
        }
    }
    $lines.Insert($b.End, "$indent    $entry")
    return ($lines -join $nl)
}

# The configuration text without Secrets.<Name> (any letter case), or $null when it has no such secret
function Remove-WmConfigSecretText {
    param([Parameter(Mandatory = $true)][string]$Text, [Parameter(Mandatory = $true)][string]$Name)
    $nl = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.AddRange([string[]]($Text -split "\r?\n"))
    $b = Find-WmConfigSecrets $lines.ToArray()
    if (-not $b) { return $null }
    for ($i = $b.Start + 1; $i -lt $b.End; $i++) {
        if ($lines[$i] -match '^\s*([A-Za-z][A-Za-z0-9_]*)\s*=' -and $Matches[1] -ieq $Name) {
            $lines.RemoveAt($i)
            return ($lines -join $nl)
        }
    }
    return $null
}

# --- Checking the answers ---------------------------------------------------------------------------------------

function Test-WmUpdateTime {
    param([string]$Value)
    $t = [datetime]::MinValue
    return ($Value -match '^\d{2}:\d{2}$') -and
        [datetime]::TryParseExact($Value, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$t)
}

# d = every day (daily), w = working days, m = Monday, the same in every language; the earlier Polish letters
# c, r, p still work. Nothing for anything else. Wrap the result in @().
function Get-WmUpdateDaysChoice {
    param([string]$Choice)
    switch -Regex ($Choice.Trim().ToLowerInvariant()) {
        '^(d|daily|c|codziennie)$'      { return $script:WmEveryDay }
        '^(w|workdays|r|robocze)$'      { return $script:WmWorkDays }
        '^(m|monday|p|poniedzia.ek)$'   { return 'Monday' }
    }
}

function Get-WmUpdateDaysLabel {
    param([string[]]$Days)
    $d = @($Days)
    if ($d.Count -eq 0) { return '' }   # Compare-Object refuses an empty list
    if (-not (Compare-Object $d $script:WmEveryDay)) { return 'd' }
    if (-not (Compare-Object $d $script:WmWorkDays)) { return 'w' }
    if ($d.Count -eq 1 -and $d[0] -eq 'Monday') { return 'm' }
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

# The JSON Loki gets from the test: one line, labels like wmanager's own (job "init"). English, like every line
# wmanager sends to Loki.
function Get-WmLokiTestBody {
    param([Parameter(Mandatory = $true)][string]$HostName, [Parameter(Mandatory = $true)][DateTimeOffset]$Time)
    $ns = [string]($Time.ToUnixTimeMilliseconds() * 1000000)
    $stream = [ordered]@{ service_name = 'wmanager'; host = $HostName.ToLowerInvariant(); job = 'init'; level = 'info' }
    $body = @{ streams = @(@{ stream = $stream; values = @(, @($ns, 'wmanager init: connection test')) }) }
    return ConvertTo-Json -InputObject $body -Depth 6 -Compress
}

# Sends the test line. Returns $null when Loki took it, otherwise a description of the problem (in the user's
# language).
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
            401 { return (Get-WmText 'init.loki_401') }
            403 { return (Get-WmText 'init.loki_403') }
            404 { return (Get-WmText 'init.loki_404') }
        }
        return (Get-WmText 'init.loki_failed' @(Get-WmErrorText $_))
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
        if ((Get-WmHttpStatus $_) -eq 404) { return (Get-WmText 'init.healthchecks_404') }
        return (Get-WmText 'init.healthchecks_failed' @(Get-WmErrorText $_))
    }
}

# Fetches manifest.psd1 of a management source to a temporary file. Returns the path; throws on failure
# (and leaves no partial file behind).
function Get-WmSourceManifest {
    param([Parameter(Mandatory = $true)][string]$Source, [string]$AuthHeader)
    $file = Join-Path ([IO.Path]::GetTempPath()) ('wmanager-init-' + [guid]::NewGuid().ToString('N') + '.psd1')
    try {
        if ($Source -match '^https://') {
            $headers = @{}
            if ($AuthHeader) { $headers['Authorization'] = $AuthHeader }
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri ($Source.TrimEnd('/') + '/manifest.psd1') -OutFile $file -Headers $headers -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
        } else {
            Copy-Item -LiteralPath (Join-Path $Source 'manifest.psd1') -Destination $file -Force -ErrorAction Stop
        }
    } catch {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        throw
    }
    return $file
}

# A certificate file, or $null when the file isn't one.
function Import-WmCertificateFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    try { return New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $Path }
    catch { return $null }
}

# What makes a certificate unfit for wmanager, or $null: the same checks provisioning makes
# (Get-WmSigningCertificate in Managed.ps1), so a wrong file is caught before it reaches a USB drive.
function Get-WmSigningCertificateProblem {
    param([Parameter(Mandatory = $true)]$Certificate)
    if ($Certificate.HasPrivateKey) { return (Get-WmText 'init.cert_private_key') }
    foreach ($ext in $Certificate.Extensions) {
        if ($ext -is [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension] -and $ext.CertificateAuthority) {
            return (Get-WmText 'init.cert_authority')
        }
    }
    $usages = @($Certificate.Extensions | Where-Object { $_ -is [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] } |
        ForEach-Object { $_.EnhancedKeyUsages } | ForEach-Object { $_.Value })
    if ($usages -notcontains '1.3.6.1.5.5.7.3.3') { return (Get-WmText 'init.cert_not_code_signing') }
    return $null
}

# Whether the manifest is signed with the given certificate: 'ok', 'skipped' (no Authenticode outside Windows)
# or a description of the problem. The root certificate is usually not trusted on the computer the wizard runs
# on, so "untrusted root" counts as ok as long as the signer is this certificate and the content is intact.
function Test-WmManifestSigner {
    param([Parameter(Mandatory = $true)][string]$ManifestPath, [Parameter(Mandatory = $true)][string]$CertificatePath)
    if (-not $script:WmIsWindows -or -not (Get-Command Get-AuthenticodeSignature -ErrorAction SilentlyContinue)) { return 'skipped' }
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $CertificatePath
    $sig = Get-AuthenticodeSignature -FilePath $ManifestPath
    if (-not $sig.SignerCertificate) { return (Get-WmText 'init.manifest_unsigned' @([string]$sig.Status)) }
    if ($sig.SignerCertificate.Thumbprint -ne $cert.Thumbprint) {
        return (Get-WmText 'init.manifest_other_signer' @($sig.SignerCertificate.Thumbprint, $cert.Thumbprint))
    }
    if ([string]$sig.Status -notin @('Valid', 'UnknownError')) { return (Get-WmText 'init.signature_invalid' @([string]$sig.Status)) }
    return 'ok'
}
