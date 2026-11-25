# Computer groups: a signed management source with the central group map, package lists, group scripts and jobs.
#
# The source is an https:// prefix (a web server or a private Git repository) or a folder (see examples\management):
#   manifest.psd1                          generated and signed by tools/publish.sh (Authenticode)
#   source-id.txt                          identifier of this source (created by tools/publish.sh)
#   groups.psd1                            computer name -> groups
#   version.psd1                           the wmanager version the computers run (optional; lib\SelfUpdate.ps1)
#   choco-reqs.txt                         the common package list
#   groups/<group>/choco-reqs.txt          extra packages for the group (optional)
#   groups/<group>/scripts/*.ps1           run as SYSTEM (hourly task and scheduled update), again whenever their content changes
#   groups/<group>/jobs/<when>/*.ps1       run as SYSTEM on a schedule: hourly, daily or weekly (Invoke-Jobs.ps1)
#   groups/<group>/logon/*.ps1             run at every sign-in as the user who signs in (Invoke-Logon.ps1)
#   groups/<group>/startup/*.ps1           run as SYSTEM at every start of the computer (Invoke-Startup.ps1)
#   groups/<group>/events/*.ps1            run as SYSTEM when the events they name happen (Invoke-Event.ps1)
#   groups/<group>/...                     any other files the scripts use
#
# The manifest lists every file with its SHA256. A computer accepts a manifest only when its Authenticode
# signature is valid and made with the certificate named in the config (during a key change also with the next
# certificate the source named, see "Key change" below), its SourceId is the one from the config
# (a manifest signed for another source doesn't fit), and its Serial is not lower than the one accepted before
# (an old signed manifest can't be replayed). Every downloaded file must match its hash and every list must parse
# before the new version replaces the previous one in state\managed. When the source can't be reached, or its new
# version is rejected, the last verified copy is used.

. (Join-Path $PSScriptRoot 'Groups.ps1')   # content checks without system dependencies
. (Join-Path $PSScriptRoot 'UserSession.ps1')   # scripts and jobs run in a person's session

$script:WmScriptsState      = Join-Path $script:WmStateDir 'scripts-done.txt'
$script:WmScriptsFailed     = Join-Path $script:WmStateDir 'scripts-failed.txt'   # path -> hash|time of the last failure
$script:WmJobsState         = Join-Path $script:WmStateDir 'jobs-state.txt'
$script:WmManagedChecked    = Join-Path $script:WmStateDir 'managed-checked.txt'   # touched at every fetch attempt
$script:WmCertFriendlyName  = 'wmanager-signing'   # marks the certificate wmanager added to the root store
$script:WmCodeSigningOid    = '1.3.6.1.5.5.7.3.3'
$script:WmManaged           = $null                # content resolved in this run (Get-WmManagedContent)
$script:WmManagedError      = $null
$script:WmManagedQuiet      = $false               # the hourly job run logs only warnings and errors
$script:WmScriptsNeedReboot = $false

# Routine information; left out in the hourly job run so the log and Loki don't fill up with it.
# -Key/-Arguments: a message of lang\<code>\Managed.psd1, as for Write-WmLog.
function Write-WmManagedNote {
    param([Parameter(Mandatory = $true)][string]$Key, [object[]]$Arguments = @())
    if (-not $script:WmManagedQuiet) { Write-WmLog -Key $Key -Arguments $Arguments }
}

# Warnings about the content of the source (e.g. a group without files): reported by the scheduled update,
# not again every hour.
function Write-WmManagedWarning {
    param([Parameter(Mandatory = $true)][string]$Key, [object[]]$Arguments = @())
    if (-not $script:WmManagedQuiet) { Write-WmLog -Key $Key -Arguments $Arguments -Level warn }
}

# ---------------------------------------------------------------------------
# Checks on the content (no system dependencies, tested in tests\Managed.Tests.ps1)
# ---------------------------------------------------------------------------


# Checks the data of manifest.psd1. Returns SourceId, Serial and Files (path -> upper-case SHA256).
# With -SourceId, a manifest of another source is rejected.
function ConvertFrom-WmManifestData {
    param([Parameter(Mandatory = $true)][hashtable]$Data, [string]$SourceId)
    $id = [string]$Data.SourceId
    if ($id -notmatch '^[A-Za-z0-9._-]{8,64}$') { throw (New-WmError 'managed.manifest_no_source_id') }
    if ($SourceId -and $id -ne $SourceId) { throw (New-WmError 'managed.manifest_other_source' @($id, $SourceId)) }
    $serial = 0L
    if (-not [long]::TryParse([string]$Data.Serial, [ref]$serial) -or $serial -le 0) {
        throw (New-WmError 'managed.manifest_no_serial')
    }
    if (-not ($Data.Files -is [hashtable])) { throw (New-WmError 'managed.manifest_no_files') }
    $files = @{}   # case-insensitive, like paths on Windows
    foreach ($p in $Data.Files.Keys) {
        $path = [string]$p
        $hash = [string]$Data.Files[$p]
        if (-not (Test-WmManagedPath $path)) { throw (New-WmError 'managed.manifest_bad_path' @($path)) }
        if ($path -ieq 'manifest.psd1') { throw (New-WmError 'managed.manifest_lists_itself') }
        if ($hash -notmatch '^[0-9A-Fa-f]{64}$') { throw (New-WmError 'managed.manifest_bad_hash' @($path)) }
        if ($files.ContainsKey($path)) { throw (New-WmError 'managed.manifest_duplicate_path' @($path)) }
        $files[$path] = $hash.ToUpperInvariant()
    }
    return [pscustomobject]@{ SourceId = $id; Serial = $serial; Files = $files }
}

function Test-WmSameFiles {
    param([hashtable]$A, [hashtable]$B)
    if ($A.Count -ne $B.Count) { return $false }
    foreach ($k in $A.Keys) { if (-not $B.ContainsKey($k) -or $B[$k] -ne $A[$k]) { return $false } }
    return $true
}









# The latest time a job with a time ($At, from Get-WmJobAt) was due, at or before $Now: its time on today or an
# earlier one of its days, in local time (as the user wrote it). 2 minutes of slack: the task that time starts may
# start a moment early.
function Get-WmJobLastSlot {
    param([Parameter(Mandatory = $true)]$At, [Parameter(Mandatory = $true)][datetime]$Now)
    $probe = $Now.ToLocalTime().AddMinutes(2)
    $time = [TimeSpan]::ParseExact($At.Time, 'hh\:mm', [Globalization.CultureInfo]::InvariantCulture)
    for ($d = 0; $d -le 7; $d++) {
        $day = $probe.Date.AddDays(-$d)
        if (@($At.Days) -notcontains $day.DayOfWeek.ToString()) { continue }
        $slot = $day.Add($time)
        if ($slot -le $probe) { return $slot }
    }
    return $null
}

# The next time a job with a time is due, after $Now (with the same slack as Get-WmJobLastSlot)
function Get-WmJobNextSlot {
    param([Parameter(Mandatory = $true)]$At, [Parameter(Mandatory = $true)][datetime]$Now)
    $probe = $Now.ToLocalTime().AddMinutes(2)
    $time = [TimeSpan]::ParseExact($At.Time, 'hh\:mm', [Globalization.CultureInfo]::InvariantCulture)
    for ($d = 0; $d -le 7; $d++) {
        $day = $probe.Date.AddDays($d)
        if (@($At.Days) -notcontains $day.DayOfWeek.ToString()) { continue }
        $slot = $day.Add($time)
        if ($slot -gt $probe) { return $slot }
    }
    return $null
}

# Is a job due? The hourly task starts a little early or late, so 5 minutes of slack keep a daily job at
# the same hour instead of drifting. A last run in the future (the clock went back) counts as due. A job with a time
# ($At) is due when its latest time has passed since its last run (a computer that was off then catches up), unless
# its next time comes within the hour: that run then stands for both, rather than two runs close together. A job has
# one time a day, so that never holds back the run of the time that has just come.
function Test-WmJobDue {
    param([Parameter(Mandatory = $true)][string]$Every, $LastRun, [Parameter(Mandatory = $true)][datetime]$Now, $At = $null)
    if ($null -eq $LastRun) { return $true }
    $last = [datetime]$LastRun
    if ($last -gt $Now.AddMinutes(5)) { return $true }
    if ($At) {
        $slot = Get-WmJobLastSlot -At $At -Now $Now
        if ($null -eq $slot -or $last -ge $slot.ToUniversalTime()) { return $false }
        $next = Get-WmJobNextSlot -At $At -Now $Now
        return ($null -eq $next -or ($next.ToUniversalTime() - $Now.ToUniversalTime()) -gt [TimeSpan]::FromHours(1))
    }
    switch ($Every) {
        'hourly' { $period = [TimeSpan]::FromHours(1) }
        'daily'  { $period = [TimeSpan]::FromDays(1) }
        'weekly' { $period = [TimeSpan]::FromDays(7) }
        default  { throw (New-WmError 'managed.unknown_period' @($Every)) }
    }
    return (($Now - $last) -ge ($period - [TimeSpan]::FromMinutes(5)))
}

# ---------------------------------------------------------------------------
# Signing certificate
# ---------------------------------------------------------------------------

# The public certificate from the config, checked: code signing only, not a CA, no private key.
# It lies next to the configuration file ($Dir). An expired certificate is not rejected here: a signature
# with a timestamp stays valid, and Get-AuthenticodeSignature decides.
function Get-WmSigningCertificate {
    param([Parameter(Mandatory = $true)][hashtable]$Config, [Parameter(Mandatory = $true)][string]$Dir)
    $path = Join-Path $Dir (Get-WmCertificateFileName $Config)
    if (-not (Test-Path -LiteralPath $path)) { throw (New-WmError 'managed.cert_missing' @($path)) }
    return (Read-WmSigningCertificateFile $path)
}

# A signing certificate file with the checks of Get-WmSigningCertificate
function Read-WmSigningCertificateFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($path)
    if ($cert.HasPrivateKey) { throw (New-WmError 'managed.cert_private_key' @($path)) }
    foreach ($ext in $cert.Extensions) {
        if ($ext -is [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension] -and $ext.CertificateAuthority) {
            throw (New-WmError 'managed.cert_is_ca' @($path))
        }
    }
    $eku = @($cert.Extensions | Where-Object { $_ -is [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] })
    $codeSigning = $eku | ForEach-Object { $_.EnhancedKeyUsages } | Where-Object { $_.Value -eq $script:WmCodeSigningOid }
    if (-not $codeSigning) { throw (New-WmError 'managed.cert_not_code_signing' @($path)) }
    return $cert
}

function Write-WmCertificateExpiry {
    param([Parameter(Mandatory = $true)]$Certificate)
    $left = ($Certificate.NotAfter - (Get-Date)).TotalDays
    if ($left -lt 0) {
        Write-WmLog -Key 'managed.cert_expired' -Arguments @($Certificate.NotAfter.ToString('yyyy-MM-dd')) -Level warn
    } elseif ($left -lt 60) {
        Write-WmLog -Key 'managed.cert_expiring' -Arguments @($Certificate.NotAfter.ToString('yyyy-MM-dd')) -Level warn
    }
}

# Windows accepts the signature of a self-signed certificate only if the certificate is in the computer's
# trusted root store. It is added with a FriendlyName, so a previous wmanager certificate is removed when the
# config gets a new one, and Restore-Backup.ps1 can find it. A certificate that was already there stays as it was.
# -Next: during a key change, the next certificate (Update-WmSigningKeys) is trusted too.
function Install-WmSigningCertificate {
    param([Parameter(Mandatory = $true)]$Certificate, $Next)
    $wanted = @(@($Certificate, $Next) | Where-Object { $_ })
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root', 'LocalMachine')
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    try {
        foreach ($c in @($store.Certificates)) {
            if ($c.FriendlyName -eq $script:WmCertFriendlyName -and @($wanted | Where-Object { $_.Thumbprint -eq $c.Thumbprint }).Count -eq 0) {
                $store.Remove($c)
                Write-WmLog -Key 'managed.cert_previous_removed' -Arguments @($c.Thumbprint)
            }
        }
        foreach ($w in $wanted) {
            if (-not (@($store.Certificates) | Where-Object { $_.Thumbprint -eq $w.Thumbprint })) {
                $copy = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($w.RawData)
                $copy.FriendlyName = $script:WmCertFriendlyName
                $store.Add($copy)
                Write-WmLog -Key 'managed.cert_added' -Arguments @($w.Thumbprint)
            }
        }
    } finally {
        $store.Close()
    }
}

# --- Key change ---------------------------------------------------------------------------------------------------
# The source names its next signing certificate in next-certificate.cer while it is still signed with the current
# key; a computer that reads it (in a copy signed with a key it trusts) keeps it in state\signing-next.cer and trusts
# both. When the source comes signed with the next certificate, that one becomes the computer's own: it replaces the
# certificate file next to the installed configuration, and the old one leaves the root store. A source that no
# longer names it (a key change called off) makes the computer forget it. tools/wm.ps1 rotate-key does the other side.

$script:WmNextCertName = 'next-certificate.cer'
$script:WmNextCertFile = Join-Path $script:WmStateDir 'signing-next.cer'
$script:WmCertCurrent = ''
$script:WmCertNext = ''

# A certificate file written whole or not at all (a temporary file next to it, then a replace): the computer's own
# certificate is what it trusts the source by, and half a file would leave it with none
function Write-WmCertificateFile {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][byte[]]$Bytes)
    $tmp = "$Path.new"
    [IO.File]::WriteAllBytes($tmp, $Bytes)
    # [NullString]::Value: PowerShell would pass $null to a string parameter as "" (no backup file is meant)
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) }
    else { [IO.File]::Move($tmp, $Path) }
}

# The next certificate this computer trusts during a key change, or $null
function Get-WmNextCertificate {
    if (-not (Test-Path -LiteralPath $script:WmNextCertFile)) { return $null }
    try { return (Read-WmSigningCertificateFile $script:WmNextCertFile) }
    catch {
        Write-WmLog -Key 'managed.cert_next_invalid' -Arguments @((Get-WmErrorText $_)) -Level warn
        Remove-Item -LiteralPath $script:WmNextCertFile -Force -ErrorAction SilentlyContinue
        return $null
    }
}

# After the copy in state\managed is settled: switches to the next certificate when the copy is signed with it, and
# takes (or forgets) the next certificate the copy names. Returns the computer's certificate after that.
function Update-WmSigningKeys {
    param([Parameter(Mandatory = $true)][hashtable]$Config, [Parameter(Mandatory = $true)]$Manifest,
          [Parameter(Mandatory = $true)]$Current, $Next)
    $signer = (Get-AuthenticodeSignature -LiteralPath (Join-Path $script:WmManagedDir 'manifest.psd1')).SignerCertificate
    if ($Next -and $signer -and $signer.Thumbprint -eq $Next.Thumbprint) {
        Write-WmCertificateFile -Path (Join-Path $script:WmRoot (Get-WmCertificateFileName $Config)) -Bytes $Next.RawData
        Remove-Item -LiteralPath $script:WmNextCertFile -Force -ErrorAction SilentlyContinue
        Write-WmLog -Key 'managed.cert_switched' -Arguments @($Next.Thumbprint, $Current.Thumbprint)
        $Current = $Next
        $Next = $null
        Install-WmSigningCertificate -Certificate $Current
    }
    $named = $null
    if ($Manifest.Files.ContainsKey($script:WmNextCertName)) {
        try { $named = Read-WmSigningCertificateFile (Join-Path $script:WmManagedDir $script:WmNextCertName) }
        catch { Write-WmLog -Key 'managed.cert_next_invalid' -Arguments @((Get-WmErrorText $_)) -Level warn }
    }
    if ($named -and $named.Thumbprint -ne $Current.Thumbprint) {
        if (-not $Next -or $Next.Thumbprint -ne $named.Thumbprint) {
            Write-WmCertificateFile -Path $script:WmNextCertFile -Bytes $named.RawData
            Write-WmLog -Key 'managed.cert_next_added' -Arguments @($named.Thumbprint)
            $Next = $named
            Install-WmSigningCertificate -Certificate $Current -Next $Next
        }
    } elseif ($Next) {
        Remove-Item -LiteralPath $script:WmNextCertFile -Force -ErrorAction SilentlyContinue
        Write-WmLog -Key 'managed.cert_next_removed' -Arguments @($Next.Thumbprint)
        $Next = $null
        Install-WmSigningCertificate -Certificate $Current
    }
    $script:WmCertCurrent = $Current.Thumbprint
    $script:WmCertNext = if ($Next) { $Next.Thumbprint } else { '' }
    return $Current
}

# Removes the certificates wmanager added to the root store, and forgets a next certificate. Returns how many.
function Remove-WmSigningCertificates {
    Remove-Item -LiteralPath $script:WmNextCertFile -Force -ErrorAction SilentlyContinue
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root', 'LocalMachine')
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    $n = 0
    try {
        foreach ($c in @($store.Certificates)) {
            if ($c.FriendlyName -eq $script:WmCertFriendlyName) { $store.Remove($c); $n++ }
        }
    } finally {
        $store.Close()
    }
    return $n
}

# $Thumbprint: the certificates this computer trusts (its own, and during a key change the next one)
function Test-WmManifestSignature {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string[]]$Thumbprint)
    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    if ($sig.Status -ne 'Valid') { throw (New-WmError 'managed.signature_invalid' @($sig.Status, $sig.StatusMessage)) }
    if (-not $sig.SignerCertificate -or $Thumbprint -notcontains $sig.SignerCertificate.Thumbprint) {
        throw (New-WmError 'managed.signature_other_cert' @($sig.SignerCertificate.Thumbprint, ($Thumbprint -join ', ')))
    }
}

# ---------------------------------------------------------------------------
# Fetching
# ---------------------------------------------------------------------------

function Get-WmManagedFile {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Settings,
        [Parameter(Mandatory = $true)][string]$RelPath,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    $src = [string]$Settings.Source
    $location = if ($src -match '^https://') { $src.TrimEnd('/') + '/' + $RelPath } else { Join-Path $src ($RelPath -replace '/', '\') }
    Get-WmRemoteFile -Location $location -Destination $Destination -AuthHeader ([string]$Settings.AuthHeader)
}

# The manifest of the copy in state\managed, if it is still valid for the configured certificate and source.
function Get-WmManagedManifest {
    param([Parameter(Mandatory = $true)][string[]]$Thumbprint, [Parameter(Mandatory = $true)][string]$SourceId)
    $file = Join-Path $script:WmManagedDir 'manifest.psd1'
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    try {
        Test-WmManifestSignature -Path $file -Thumbprint $Thumbprint
        return (ConvertFrom-WmManifestData -Data (Import-PowerShellDataFile -LiteralPath $file) -SourceId $SourceId)
    } catch {
        Write-WmLog -Key 'managed.saved_copy_invalid' -Arguments @(Get-WmErrorText $_) -Level warn
        return $null
    }
}

# Reads groups.psd1 and every package list of a downloaded copy. Throws when any of them is invalid,
# so a broken version never replaces a working one.
function Read-WmManagedSnapshot {
    param([Parameter(Mandatory = $true)][string]$Dir, [Parameter(Mandatory = $true)]$Manifest)
    $map = @{}
    if ($Manifest.Files.ContainsKey('groups.psd1')) {
        try { $map = Import-PowerShellDataFile -LiteralPath (Join-Path $Dir 'groups.psd1') }
        catch { throw (New-WmError 'managed.file_error' @('groups.psd1', (Get-WmErrorText $_))) }
        Assert-WmGroupMap $map
    }
    $versions = $null
    if ($Manifest.Files.ContainsKey('version.psd1')) {
        try { $data = Import-PowerShellDataFile -LiteralPath (Join-Path $Dir 'version.psd1') }
        catch { throw (New-WmError 'managed.file_error' @('version.psd1', (Get-WmErrorText $_))) }
        $versions = ConvertFrom-WmVersionData $data   # its messages name the file
    }
    $lists = @{}   # '' = the common list, otherwise the group name
    foreach ($path in @($Manifest.Files.Keys)) {
        $group = Get-WmListOwner $path
        if ($null -eq $group) { continue }
        $text = [IO.File]::ReadAllText((Join-Path $Dir ($path -replace '/', '\')), [Text.Encoding]::UTF8)
        # Plain assignment: ConvertFrom-WmRequirements returns the list as one object (,$items)
        try { $lists[$group] = ConvertFrom-WmRequirements -Text $text }
        catch { throw (New-WmError 'managed.file_error' @($path, (Get-WmErrorText $_))) }
    }
    return [pscustomobject]@{ Map = $map; Lists = $lists; Versions = $versions }
}

# Copies replaced by a newer version. They are deleted at once, but a file kept open (e.g. by a program a
# script started) can leave one behind; a later run tries again.
function Remove-WmOldManagedCopies {
    Get-ChildItem -LiteralPath $script:WmStateDir -Directory -Filter 'managed.old-*' -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

# A swap interrupted between the two renames leaves state\managed missing; put the newest old copy back.
function Repair-WmManagedSwap {
    if (Test-Path -LiteralPath $script:WmManagedDir) { return }
    $old = Get-ChildItem -LiteralPath $script:WmStateDir -Directory -Filter 'managed.old-*' -ErrorAction SilentlyContinue |
           Sort-Object Name -Descending | Select-Object -First 1
    if ($old) {
        Move-Item -LiteralPath $old.FullName -Destination $script:WmManagedDir -ErrorAction Stop
        # Provisioning may have reset the old copy's ACL (Set-WmFolderAcl); keep it administrators-only
        Set-WmExplicitAcl -Path $script:WmManagedDir
    }
}

# Downloads and checks the current version of the source; when it is valid, it replaces state\managed.
# Returns the accepted manifest, or $null when the manifest could not be downloaded (warning logged).
# Throws when the new version is invalid (signature, source, serial, hashes, content) or can't be put in place.
function Update-WmManagedCopy {
    param([Parameter(Mandatory = $true)][hashtable]$Settings, [Parameter(Mandatory = $true)][string[]]$Thumbprint)
    $sourceId = [string]$Settings.SourceId
    $new = "$($script:WmManagedDir).new"
    if (Test-Path -LiteralPath $new) { Remove-Item -LiteralPath $new -Recurse -Force -ErrorAction Stop }
    # Scripts may hold things meant for administrators only, like the private repository they come from
    [IO.Directory]::CreateDirectory($new, (New-WmExplicitAcl -Directory)) | Out-Null
    try {
        $manifestFile = Join-Path $new 'manifest.psd1'
        try {
            Get-WmManagedFile -Settings $Settings -RelPath 'manifest.psd1' -Destination $manifestFile
        } catch {
            Write-WmLog -Key 'managed.source_unreachable' -Arguments @($Settings.Source, (Get-WmErrorText $_)) -Level warn
            return $null
        }
        Test-WmManifestSignature -Path $manifestFile -Thumbprint $Thumbprint
        $manifest = ConvertFrom-WmManifestData -Data (Import-PowerShellDataFile -LiteralPath $manifestFile) -SourceId $sourceId

        $current = Get-WmManagedManifest -Thumbprint $Thumbprint -SourceId $sourceId
        if ($current) {
            if ($manifest.Serial -lt $current.Serial) {
                throw (New-WmError 'managed.manifest_older' @($manifest.Serial, $current.Serial))
            }
            if ($manifest.Serial -eq $current.Serial) {
                if (-not (Test-WmSameFiles $manifest.Files $current.Files)) {
                    throw (New-WmError 'managed.manifest_same_serial' @($manifest.Serial))
                }
                Write-WmManagedNote -Key 'managed.source_unchanged' -Arguments @($manifest.Serial)
                return $current
            }
        }

        foreach ($path in @($manifest.Files.Keys | Sort-Object)) {
            $dst = Join-Path $new ($path -replace '/', '\')
            try { Get-WmManagedFile -Settings $Settings -RelPath $path -Destination $dst }
            catch { throw (New-WmError 'managed.download_failed' @($path, (Get-WmErrorText $_))) }
            if ((Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash -ne $manifest.Files[$path]) {
                throw (New-WmError 'managed.hash_mismatch' @($path))
            }
        }
        $null = Read-WmManagedSnapshot -Dir $new -Manifest $manifest

        # Swap. If the second rename fails, the previous copy goes back, so the run still has one.
        $old = '{0}.old-{1}' -f $script:WmManagedDir, (Get-Date -Format 'yyyyMMddHHmmssfff')
        if (Test-Path -LiteralPath $script:WmManagedDir) {
            try { Move-Item -LiteralPath $script:WmManagedDir -Destination $old -ErrorAction Stop }
            catch { throw (New-WmError 'managed.swap_failed' @($script:WmManagedDir, (Get-WmErrorText $_))) }
        }
        try {
            Move-Item -LiteralPath $new -Destination $script:WmManagedDir -ErrorAction Stop
        } catch {
            if (Test-Path -LiteralPath $old) { Move-Item -LiteralPath $old -Destination $script:WmManagedDir -ErrorAction SilentlyContinue }
            throw
        }
        Remove-WmOldManagedCopies
        Write-WmLog -Key 'managed.manifest_accepted' -Arguments @($manifest.Serial, $manifest.Files.Count)
        return $manifest
    } finally {
        if (Test-Path -LiteralPath $new) { Remove-Item -LiteralPath $new -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# Is it time for the hourly job run to fetch the source again? Also when there is no copy yet.
function Test-WmManagedRefreshDue {
    param([int]$Hours = 20)
    if (-not (Test-Path -LiteralPath (Join-Path $script:WmManagedDir 'manifest.psd1'))) { return $true }
    $f = Get-Item -LiteralPath $script:WmManagedChecked -ErrorAction SilentlyContinue
    if (-not $f) { return $true }
    $age = [DateTime]::UtcNow - $f.LastWriteTimeUtc
    return ($age.TotalHours -ge $Hours -or $age.TotalHours -lt 0)
}

# -CachedOnly: use the verified copy without contacting the source (the hourly job run, between fetches).
function Resolve-WmManagedContent {
    param([Parameter(Mandatory = $true)][hashtable]$Config, [switch]$CachedOnly)
    $settings = Get-WmManagementSettings $Config
    if (-not $settings) { throw (New-WmError 'managed.no_source') }
    $sourceId = [string]$settings.SourceId
    # The installed copy of the certificate (Install-WmFiles puts it next to the installed config)
    $cert = Get-WmSigningCertificate -Config $Config -Dir $script:WmRoot
    $next = Get-WmNextCertificate
    if ($next -and $next.Thumbprint -eq $cert.Thumbprint) { Remove-Item -LiteralPath $script:WmNextCertFile -Force -ErrorAction SilentlyContinue; $next = $null }
    Install-WmSigningCertificate -Certificate $cert -Next $next
    $trusted = @(@($cert, $next) | Where-Object { $_ } | ForEach-Object { $_.Thumbprint })
    Repair-WmManagedSwap

    $manifest = $null
    if (-not $CachedOnly) {
        Write-WmCertificateExpiry $cert
        try {
            $manifest = Update-WmManagedCopy -Settings $settings -Thumbprint $trusted
        } catch {
            Write-WmLog -Key 'managed.new_version_rejected' -Arguments @(Get-WmErrorText $_) -Level error
        }
        try { [IO.File]::WriteAllText($script:WmManagedChecked, [DateTime]::UtcNow.ToString('o')) } catch { }
    }
    if (-not $manifest) {
        $manifest = Get-WmManagedManifest -Thumbprint $trusted -SourceId $sourceId
        if (-not $manifest) { throw (New-WmError 'managed.no_verified_copy') }
        if (-not $CachedOnly) { Write-WmLog -Key 'managed.using_last_copy' -Arguments @($manifest.Serial) -Level warn }
    }
    # The key change: a failure here (a locked file, the root store) doesn't stop the run, which keeps what it trusts;
    # the next run tries again
    $script:WmCertCurrent = $cert.Thumbprint
    $script:WmCertNext = if ($next) { $next.Thumbprint } else { '' }
    try { $null = Update-WmSigningKeys -Config $Config -Manifest $manifest -Current $cert -Next $next }
    catch { Write-WmLog -Key 'managed.cert_change_failed' -Arguments @(Get-WmErrorText $_) -Level error }

    $snap = Read-WmManagedSnapshot -Dir $script:WmManagedDir -Manifest $manifest
    $groups = Get-WmComputerGroups -Map $snap.Map -ComputerName $script:WmHostName
    if ($groups.Count -gt 0) { Write-WmManagedNote -Key 'managed.computer_groups' -Arguments @($script:WmHostName, ($groups -join ', ')) }
    else { Write-WmManagedNote -Key 'managed.computer_no_groups' -Arguments @($script:WmHostName) }

    # The same resolution as tools/groups.ps1 show/check (lib\Groups.ps1)
    $content = Resolve-WmComputerContent -Map $snap.Map -Lists $snap.Lists -Files $manifest.Files -ComputerName $script:WmHostName `
                                         -Versions $snap.Versions
    return [pscustomobject]@{
        Serial       = $manifest.Serial
        Groups       = $content.Groups
        Requirements = $content.Requirements
        Scripts      = $content.Scripts
        Jobs         = $content.Jobs
        LogonScripts = $content.LogonScripts
        EventScripts = $content.EventScripts
        Wmanager     = $content.Wmanager
    }
}

# The management content for this run, resolved once and reused by the package, script and job stages.
function Get-WmManagedContent {
    param([Parameter(Mandatory = $true)][hashtable]$Config, [switch]$CachedOnly)
    if ($script:WmManaged) { return $script:WmManaged }
    if ($script:WmManagedError) { throw $script:WmManagedError }
    try {
        $script:WmManaged = Resolve-WmManagedContent -Config $Config -CachedOnly:$CachedOnly
        return $script:WmManaged
    } catch {
        $script:WmManagedError = $_.Exception
        throw
    }
}

# The package list for this run: from the management source when one is configured, otherwise from
# ReqsSources ($BaseDir resolves their relative paths).
function Get-WmRequirements {
    param([Parameter(Mandatory = $true)][hashtable]$Config, [Parameter(Mandatory = $true)][string]$BaseDir)
    if (Get-WmManagementSettings $Config) {
        return ,@((Get-WmManagedContent -Config $Config).Requirements)
    }
    # Not @(...): the parser already returns the list as one object, and @() would nest it in another array
    $items = ConvertFrom-WmRequirements -Text (Get-WmRequirementsText -Config $Config -BaseDir $BaseDir)
    return ,$items
}

# Checked before provisioning changes anything: settings, the secrets for scripts and the certificate next to the
# config ($ConfigDir). The log file isn't open yet, so it doesn't warn of the certificate's expiry: reading the
# source does, in the log.
function Test-WmManagementConfig {
    param([Parameter(Mandatory = $true)][hashtable]$Config, [Parameter(Mandatory = $true)][string]$ConfigDir)
    $settings = Get-WmManagementSettings $Config
    if (-not $settings) { return }
    $null = Get-WmSecrets $Config
    $cert = Get-WmSigningCertificate -Config $Config -Dir $ConfigDir
    Write-WmLog -Key 'managed.source_info' -Arguments @($settings.Source, $settings.SourceId, $cert.Subject, $cert.Thumbprint)
}

# ---------------------------------------------------------------------------
# Running group scripts and jobs
# ---------------------------------------------------------------------------

# Small state files: one "key<TAB>value" per line.
function Read-WmTabState {
    param([Parameter(Mandatory = $true)][string]$Path)
    $map = @{}
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in [IO.File]::ReadAllLines($Path)) {
            $p = $line.Split("`t")
            if ($p.Count -ge 2 -and $p[0]) { $map[$p[0]] = $p[1] }
        }
    }
    return $map
}

function Save-WmTabState {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][hashtable]$Map)
    $lines = @($Map.Keys | Sort-Object | ForEach-Object { "$_`t$($Map[$_])" })
    [IO.File]::WriteAllLines($Path, [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
}

# Runs one script in its own Windows PowerShell process (so it can't change wmanager's state).
# The working folder is the system TEMP, not the group folder: state\managed is replaced with every new
# version, and a program left running from it would block that. Returns ExitCode ($null after the timeout,
# when the process tree is killed), Output and Errors.
function Invoke-WmScriptProcess {
    param(
        [Parameter(Mandatory = $true)][string]$File,
        [hashtable]$Environment = @{},
        [int]$TimeoutMinutes = 15
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$File`""
    $psi.WorkingDirectory = [IO.Path]::GetTempPath()
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    # A console process without a window writes in the OEM code page (852 on Polish Windows)
    $oem = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
    $psi.StandardOutputEncoding = $oem
    $psi.StandardErrorEncoding = $oem
    foreach ($k in $Environment.Keys) { $psi.EnvironmentVariables[$k] = [string]$Environment[$k] }

    $p = [System.Diagnostics.Process]::Start($psi)
    try {
        # Read both streams at the same time, otherwise a full buffer would block the script
        $out = $p.StandardOutput.ReadToEndAsync()
        $err = $p.StandardError.ReadToEndAsync()
        $code = $null
        if ($p.WaitForExit($TimeoutMinutes * 60000)) {
            $p.WaitForExit()
            $code = $p.ExitCode
        } else {
            & taskkill.exe /PID $p.Id /T /F 2>&1 | Out-Null
            $null = $p.WaitForExit(30000)
        }
        $stdout = ''; $stderr = ''
        try { if ($out.Wait(10000)) { $stdout = $out.Result } } catch { }
        try { if ($err.Wait(10000)) { $stderr = $err.Result } } catch { }
        return [pscustomobject]@{ ExitCode = $code; Output = $stdout; Errors = $stderr }
    } finally {
        $p.Dispose()
    }
}

# Writes the lines of a script's output to the log. -Raw (jobs): each line goes to Loki as it is, so a job
# printing JSON can be read with '| json' in Grafana.
function Write-WmScriptOutput {
    param([AllowEmptyString()][string]$Text, [string]$Prefix = '  ', [string]$Task = '', [switch]$Raw, [int]$MaxLength = 2000)
    foreach ($l in ($Text -split "\r?\n")) {
        $s = $l.TrimEnd()
        if (-not $s) { continue }
        if ($s.Length -gt $MaxLength) { $s = $s.Substring(0, $MaxLength) + '...' }
        if ($Raw) { Write-WmLog $s -Task $Task -Raw } else { Write-WmLog "$Prefix$s" -Task $Task }
    }
}

function Get-WmScriptEnvironment {
    param([Parameter(Mandatory = $true)][string]$Group, [Parameter(Mandatory = $true)][string]$Path)
    $parts = $Path.Split('/')   # groups/<folder>/...
    return @{
        WMANAGER_GROUP     = $Group
        WMANAGER_COMPUTER  = $script:WmHostName
        WMANAGER_GROUP_DIR = Join-Path $script:WmManagedDir ('groups\' + $parts[1])
    }
}

# Adds the secrets the script or job $File names (# wmanager-secrets:) to its $Environment, as
# WMANAGER_SECRET_<NAME>; only those, so a program it starts doesn't get the others. Throws when the configuration
# doesn't have one (the script doesn't run then).
function Add-WmScriptSecrets {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Environment,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][hashtable]$Secrets,
        [Parameter(Mandatory = $true)][string]$File
    )
    foreach ($n in (Get-WmScriptSecretNames ([IO.File]::ReadAllText($File)))) {
        $key = @($Secrets.Keys | Where-Object { $_ -ieq $n }) | Select-Object -First 1
        if (-not $key) { throw (New-WmError 'managed.secret_missing' @($n)) }
        $Environment['WMANAGER_SECRET_' + $n.ToUpperInvariant()] = [string]$Secrets[$key]
    }
}

# ---------------------------------------------------------------------------
# Who runs a script or job: SYSTEM, or each signed-in person ("# wmanager-run-as: user")
# ---------------------------------------------------------------------------
# A script or job that runs as the user runs in the session of every person signed in when the run comes (from SYSTEM,
# lib\UserSession.ps1): a script once per person and content, a job on its schedule per person. Its state is kept
# per person (key "<path>|<SID>"). Nobody signed in: it waits; the wmanager-Logon task starts wmanager-Jobs after a
# sign-in, so a new person gets it within a minute. It runs from a copy in state\user-run (the copy of the source is
# private) checked against the manifest's hash, without WMANAGER_GROUP_DIR, which the person can't read.

$script:WmUserRunDir = Join-Path $script:WmStateDir 'user-run'
$script:WmRunSessions = $null

# The signed-in people, read once per run; none when they can't be read (not SYSTEM: e.g. provisioning run by hand,
# whose hourly run after it reads them)
function Get-WmRunSessions {
    if ($null -eq $script:WmRunSessions) {
        try { $script:WmRunSessions = @(Get-WmUserSessions) }
        catch {
            Write-WmLog -Key 'managed.sessions_failed' -Arguments @(Get-WmErrorText $_) -Level warn
            $script:WmRunSessions = @()
        }
    }
    return $script:WmRunSessions
}

# The runs of a script or job: one as SYSTEM (Key = its path), or one per signed-in person (Key = "<path>|<SID>",
# Label with the person's name). A run-as line that can't be read: one run that doesn't run (NotRun).
function Get-WmGroupRuns {
    param([Parameter(Mandatory = $true)]$Item, [Parameter(Mandatory = $true)][string]$File, [string]$Label)
    if (-not $Label) { $Label = $Item.Path }
    try { $runAs = Get-WmScriptRunAs ([IO.File]::ReadAllText($File)) }
    catch { return @([pscustomobject]@{ Key = $Item.Path; Label = $Label; Session = $null; NotRun = (Get-WmErrorText $_) }) }
    if ($runAs -ne 'user') { return @([pscustomobject]@{ Key = $Item.Path; Label = $Label; Session = $null; NotRun = $null }) }
    return @(Get-WmRunSessions | ForEach-Object {
        [pscustomobject]@{ Key = "$($Item.Path)|$($_.Sid)"; Label = "$Label ($($_.User))"; Session = $_; NotRun = $null }
    })
}

# Runs one run of a script or job with $Vars (and the secrets it names): as SYSTEM in its own process, or in the
# person's session from a checked copy ($Copies: path -> copy, filled as needed). Returns NotRun (why it didn't run),
# or ExitCode ($null after the time limit), Output and Errors.
function Invoke-WmGroupRun {
    param($Item, [string]$File, $Run, [hashtable]$Vars, [hashtable]$Secrets, [int]$TimeoutMinutes, [hashtable]$Copies)
    $notRun = { param($why) [pscustomobject]@{ NotRun = $why; ExitCode = $null; Output = ''; Errors = '' } }
    if ($Run.NotRun) { return (& $notRun $Run.NotRun) }
    $path = $File
    if ($Run.Session) {
        if (-not $Copies.ContainsKey($Item.Path)) {
            $c = Copy-WmCheckedScripts -Scripts @($Item) -Dir $script:WmUserRunDir -Keep
            if ($c.Errors.ContainsKey($Item.Path)) { return (& $notRun $c.Errors[$Item.Path]) }
            $Copies[$Item.Path] = $c.Copies[$Item.Path]
        }
        $path = $Copies[$Item.Path]
        $Vars.Remove('WMANAGER_GROUP_DIR')
    }
    try { Add-WmScriptSecrets -Environment $Vars -Secrets $Secrets -File $path } catch { return (& $notRun (Get-WmErrorText $_)) }
    if (-not $Run.Session) { $r = Invoke-WmScriptProcess -File $path -Environment $Vars -TimeoutMinutes $TimeoutMinutes }
    else {
        try { $r = Invoke-WmUserScript -SessionId $Run.Session.SessionId -File $path -Environment $Vars -TimeoutMinutes $TimeoutMinutes }
        catch { return (& $notRun (Get-WmErrorText $_)) }   # e.g. the person signed out in the meantime
    }
    return [pscustomobject]@{ NotRun = $null; ExitCode = $r.ExitCode; Output = $r.Output; Errors = $r.Errors }
}

# A state key without the person: the path of the script or job
function Get-WmRunPath {
    param([string]$Key)
    return $Key.Split('|')[0]
}

# Runs the scripts of this computer's groups whose content changed since their last successful run
# (the hourly wmanager-Jobs task and the scheduled update, both as SYSTEM). Exit code 0 = done, 3010 = done and a
# restart is needed; anything else (or the timeout) is an error and the script runs again later: with
# -RetryFailedAfterHours (the hourly run) not before that many hours, unless its content changed.
# A failed script doesn't stop the ones after it. A script that runs as the user does all that per person.
function Invoke-WmGroupScripts {
    param([Parameter(Mandatory = $true)][hashtable]$Config, [int]$RetryFailedAfterHours = 0)
    $settings = Get-WmManagementSettings $Config
    if (-not $settings) { return }
    Write-WmManagedNote -Key 'managed.scripts_section'
    $content = Get-WmManagedContent -Config $Config
    $scripts = @($content.Scripts)

    # Forget scripts this computer no longer has (for every person too): if it joins the group again, they run again
    $done = Read-WmTabState $script:WmScriptsState
    $failed = Read-WmTabState $script:WmScriptsFailed
    foreach ($map in @($done, $failed)) {
        foreach ($k in @($map.Keys)) { if (-not ($scripts | Where-Object { $_.Path -eq (Get-WmRunPath $k) })) { $map.Remove($k) } }
    }
    try { Save-WmTabState -Path $script:WmScriptsState -Map $done; Save-WmTabState -Path $script:WmScriptsFailed -Map $failed } catch { }
    if ($scripts.Count -eq 0) { Write-WmManagedNote -Key 'managed.no_scripts'; return }

    $timeout = [int]$settings.ScriptTimeoutMinutes
    if ($timeout -le 0) { $timeout = 15 }
    $secrets = Get-WmSecrets $Config
    $mask = [string[]]@($secrets.Values)
    $copies = @{}
    $now = [DateTime]::UtcNow
    foreach ($s in $scripts) {
        $file = Join-Path $script:WmManagedDir ($s.Path -replace '/', '\')
        foreach ($run in (Get-WmGroupRuns -Item $s -File $file)) {
            if ($done[$run.Key] -eq $s.Hash) {
                if (-not $script:WmManagedQuiet) { Write-WmLog -Key 'managed.script_unchanged' -Arguments @($run.Label) -LocalOnly }
                continue
            }
            if ($RetryFailedAfterHours -gt 0 -and $failed[$run.Key]) {
                $f = $failed[$run.Key].Split('|')
                $at = [datetime]::MinValue
                if ($f.Count -eq 2 -and $f[0] -eq $s.Hash -and [datetime]::TryParse($f[1], [Globalization.CultureInfo]::InvariantCulture,
                        [Globalization.DateTimeStyles]::RoundtripKind, [ref]$at)) {
                    $age = $now - $at.ToUniversalTime()
                    if ($age.TotalHours -ge 0 -and $age.TotalHours -lt $RetryFailedAfterHours) { continue }
                }
            }
            Write-WmLog -Key 'managed.script_starting' -Arguments @($run.Label)
            $r = Invoke-WmGroupRun -Item $s -File $file -Run $run -Vars (Get-WmScriptEnvironment $s.Group $s.Path) -Secrets $secrets `
                                   -TimeoutMinutes $timeout -Copies $copies
            if (-not $r.NotRun) {
                Write-WmScriptOutput (Hide-WmSecrets $r.Output $mask)
                if ($r.Errors -and $r.Errors.Trim()) { Write-WmScriptOutput (Hide-WmSecrets $r.Errors $mask) -Prefix '  ! ' }
            }

            if ($r.NotRun -or $null -eq $r.ExitCode -or ($r.ExitCode -ne 0 -and $r.ExitCode -ne 3010)) {
                $failed[$run.Key] = '{0}|{1}' -f $s.Hash, [DateTime]::UtcNow.ToString('o')
                $retry = New-WmText 'managed.retry_next_update'
                if ($RetryFailedAfterHours -gt 0) { $retry = New-WmText 'managed.retry_after_hours' @($RetryFailedAfterHours) }
                if ($r.NotRun) { Write-WmLog -Key 'managed.script_not_run' -Arguments @($run.Label, $r.NotRun, $retry) -Level error }
                elseif ($null -eq $r.ExitCode) { Write-WmLog -Key 'managed.script_timeout' -Arguments @($run.Label, $timeout, $retry) -Level error }
                else { Write-WmLog -Key 'managed.script_exit_code' -Arguments @($run.Label, $r.ExitCode, $retry) -Level error }
            } else {
                $done[$run.Key] = $s.Hash
                $failed.Remove($run.Key)
                if ($r.ExitCode -eq 3010) {
                    $script:WmScriptsNeedReboot = $true
                    Write-WmLog -Key 'managed.script_done_reboot' -Arguments @($run.Label)
                } else {
                    Write-WmLog -Key 'managed.script_done' -Arguments @($run.Label)
                }
            }
            try {
                Save-WmTabState -Path $script:WmScriptsState -Map $done
                Save-WmTabState -Path $script:WmScriptsFailed -Map $failed
            } catch {
                Write-WmLog -Key 'managed.scripts_state_failed' -Arguments @(Get-WmErrorText $_) -Level warn
            }
        }
    }
}

# The times of this computer's jobs that declare one (Get-WmJobAt), for the triggers of wmanager-Jobs
# (Sync-WmJobsTaskTimes). A job whose line can't be read is left out here (it doesn't run; the log says why).
function Get-WmJobTimes {
    param([Parameter(Mandatory = $true)]$Content)
    return @(foreach ($j in @($Content.Jobs)) {
        try { $at = Get-WmJobAt ([IO.File]::ReadAllText((Join-Path $script:WmManagedDir ($j.Path -replace '/', '\')))) $j.Every }
        catch { continue }
        if ($at) { $at }
    })
}

# Runs the due jobs of this computer's groups (Invoke-Jobs.ps1, every hour). The start time is recorded
# before the run, so a failed or killed job waits for its next turn instead of repeating every hour.
# Output lines go to Loki unchanged, labelled task="<group>/<name>". A job that runs as the user is due per person:
# each signed-in person gets it on its schedule.
function Invoke-WmGroupJobs {
    param([Parameter(Mandatory = $true)][hashtable]$Config, [Parameter(Mandatory = $true)]$Content)
    $settings = Get-WmManagementSettings $Config
    $jobs = @($Content.Jobs)
    $state = Read-WmTabState $script:WmJobsState
    foreach ($k in @($state.Keys)) { if (-not ($jobs | Where-Object { $_.Path -eq (Get-WmRunPath $k) })) { $state.Remove($k) } }

    $timeout = [int]$settings.JobTimeoutMinutes
    if ($timeout -le 0) { $timeout = 10 }
    $secrets = Get-WmSecrets $Config
    $mask = [string[]]@($secrets.Values)
    $copies = @{}
    # One time for the whole run: a long job doesn't shift the ones after it
    $now = [DateTime]::UtcNow
    foreach ($j in $jobs) {
        $file = Join-Path $script:WmManagedDir ($j.Path -replace '/', '\')
        try { $at = Get-WmJobAt ([IO.File]::ReadAllText($file)) $j.Every }
        catch {
            Write-WmLog -Key 'managed.job_not_run' -Arguments @($j.Name, (Get-WmErrorText $_)) -Level error -Task $j.Name
            continue
        }
        $when = if ($at) { "$($j.Every) $($at.Text)" } else { $j.Every }
        foreach ($run in (Get-WmGroupRuns -Item $j -File $file -Label $j.Name)) {
            $last = $null
            $parsed = [datetime]::MinValue
            if ($state[$run.Key] -and [datetime]::TryParse($state[$run.Key], [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) { $last = $parsed.ToUniversalTime() }
            # A new job with a time waits for its first time, rather than running when it appears
            if ($at -and $null -eq $last -and -not $run.NotRun) {
                $state[$run.Key] = $now.ToString('o')
                Write-WmLog -Key 'managed.job_first_time' -Arguments @($run.Label, $at.Text) -Task $j.Name -LocalOnly
                continue
            }
            if (-not (Test-WmJobDue -Every $j.Every -LastRun $last -Now $now -At $at)) { continue }

            # A job with a time that starts a moment before it (the slack) counts as run at its time, so the trigger
            # of that time doesn't run it again
            $stamp = $now
            if ($at) {
                $slot = (Get-WmJobLastSlot -At $at -Now $now).ToUniversalTime()
                if ($slot -gt $stamp) { $stamp = $slot }
            }
            $state[$run.Key] = $stamp.ToString('o')
            try { Save-WmTabState -Path $script:WmJobsState -Map $state } catch { Write-WmLog -Key 'managed.jobs_state_failed' -Arguments @(Get-WmErrorText $_) -Level warn }
            Write-WmLog -Key 'managed.job_starting' -Arguments @($run.Label, $when) -Task $j.Name
            $vars = Get-WmScriptEnvironment $j.Group $j.Path
            $vars['WMANAGER_JOB'] = $j.Name
            $r = Invoke-WmGroupRun -Item $j -File $file -Run $run -Vars $vars -Secrets $secrets -TimeoutMinutes $timeout -Copies $copies
            if ($r.NotRun) {
                Write-WmLog -Key 'managed.job_not_run' -Arguments @($run.Label, $r.NotRun) -Level error -Task $j.Name
                continue
            }
            Write-WmScriptOutput (Hide-WmSecrets $r.Output $mask) -Task $j.Name -Raw -MaxLength 60000
            if ($r.Errors -and $r.Errors.Trim()) { Write-WmScriptOutput (Hide-WmSecrets $r.Errors $mask) -Prefix '! ' -Task $j.Name }

            if ($null -eq $r.ExitCode) {
                Write-WmLog -Key 'managed.job_timeout' -Arguments @($run.Label, $timeout) -Level error -Task $j.Name
            } elseif ($r.ExitCode -ne 0) {
                Write-WmLog -Key 'managed.job_exit_code' -Arguments @($run.Label, $r.ExitCode) -Level error -Task $j.Name
            } else {
                Write-WmLog -Key 'managed.job_done' -Arguments @($run.Label) -Task $j.Name -LocalOnly
            }
        }
    }
    try { Save-WmTabState -Path $script:WmJobsState -Map $state } catch { }
}

# ---------------------------------------------------------------------------
# Sign-in scripts (groups/<group>/logon/*.ps1): at every sign-in, as the user who signed in
# ---------------------------------------------------------------------------
# The wmanager-Logon task (SYSTEM, at every sign-in, Invoke-Logon.ps1) runs them in the user's session
# (lib\UserSession.ps1), hidden, with the secrets they name in that process's environment only, and logs their output
# (secrets as ***). They read the verified copy without the lock, which the scheduled update may hold for long: the
# manifest's signature as always, then the hash of each file. The copy itself is private, so each script runs from
# state\logon, a copy the users can read but only administrators change. A sign-in is served once (its LogonId).
# Then, when the computer's scripts or jobs include some that run as the user, it starts wmanager-Jobs, so the
# person gets them now rather than at the next hour.

$script:WmLogonDir = Join-Path $script:WmStateDir 'logon'
$script:WmLogonServed = Join-Path $script:WmStateDir 'logon-served.txt'
$script:WmLogonTimeoutMinutes = 5

# From the verified copy, read only and without the lock: the files of its manifest (Files), this computer's groups
# (Groups) and the management settings (Settings); $null without a management source or a verified copy. Read through
# Read-WmManagedSnapshot, which also checks the files against the manifest.
function Get-WmVerifiedGroups {
    param([Parameter(Mandatory = $true)][hashtable]$Config)
    $settings = Get-WmManagementSettings $Config
    if (-not $settings) { return $null }
    $cert = Get-WmSigningCertificate -Config $Config -Dir $script:WmRoot
    $trusted = @($cert.Thumbprint)
    $next = Get-WmNextCertificate
    if ($next) { $trusted += $next.Thumbprint }
    $manifest = Get-WmManagedManifest -Thumbprint $trusted -SourceId ([string]$settings.SourceId)
    if (-not $manifest) { return $null }
    $snap = Read-WmManagedSnapshot -Dir $script:WmManagedDir -Manifest $manifest
    $groups = Get-WmComputerGroups -Map $snap.Map -ComputerName $script:WmHostName
    return [pscustomobject]@{ Files = $manifest.Files; Groups = @($groups); Settings = $settings }
}

# Logs what a sign-in or startup script did ($Prefix: logon or startup): its output (secrets as ***), then done, its
# exit code or the time limit. -RestartIsDone: 3010 (done, a restart needed) is done too, without a restart.
function Write-WmScriptResult {
    param([Parameter(Mandatory = $true)][string]$Prefix, [Parameter(Mandatory = $true)][string]$Name,
          [Parameter(Mandatory = $true)]$Result, [int]$TimeoutMinutes, [string[]]$Mask = @(), [switch]$RestartIsDone)
    Write-WmScriptOutput (Hide-WmSecrets $Result.Output $Mask) -Task $Name
    if ($Result.Errors -and $Result.Errors.Trim()) { Write-WmScriptOutput (Hide-WmSecrets $Result.Errors $Mask) -Prefix '  ! ' -Task $Name }
    if ($null -eq $Result.ExitCode) {
        Write-WmLog -Key "$Prefix.script_timeout" -Arguments @($Name, $TimeoutMinutes) -Level error -Task $Name
    } elseif ($Result.ExitCode -eq 3010 -and $RestartIsDone) {
        Write-WmLog -Key "$Prefix.script_restart" -Arguments @($Name) -Task $Name
    } elseif ($Result.ExitCode -ne 0) {
        Write-WmLog -Key "$Prefix.script_exit_code" -Arguments @($Name, $Result.ExitCode) -Level error -Task $Name
    } else {
        Write-WmLog -Key "$Prefix.script_done" -Arguments @($Name) -Task $Name
    }
}

# From the verified copy, read only: this computer's sign-in scripts (Scripts), and whether any of its scripts or jobs
# runs as the user (UserRuns). Nothing without a verified copy.
function Get-WmLogonContent {
    param([Parameter(Mandatory = $true)][hashtable]$Config)
    $none = [pscustomobject]@{ Scripts = @(); UserRuns = $false }
    $verified = Get-WmVerifiedGroups $Config
    if (-not $verified) { return $none }
    $groups = [string[]]$verified.Groups
    # (lib\Groups.ps1 returns each list as one object: taken into a variable, @() doesn't wrap it once more)
    $logon = Get-WmGroupLogonScripts -Files $verified.Files -Groups $groups
    $scripts = Get-WmGroupScripts -Files $verified.Files -Groups $groups
    $jobs = Get-WmGroupJobs -Files $verified.Files -Groups $groups
    $userRuns = $false
    foreach ($item in @(@($scripts) + @($jobs))) {
        try {
            if ((Get-WmScriptRunAs ([IO.File]::ReadAllText((Join-Path $script:WmManagedDir ($item.Path -replace '/', '\'))))) -eq 'user') { $userRuns = $true; break }
        } catch { }
    }
    return [pscustomobject]@{ Scripts = @($logon); UserRuns = $userRuns }
}

# Copies of the scripts in $Dir, each checked against the hash the manifest gives it (from the bytes written, so
# nothing changes between the check and the copy): Copies (path in the source -> copy) and Errors (path -> why not).
# Without -Keep, copies of other scripts there are removed.
function Copy-WmCheckedScripts {
    param([AllowEmptyCollection()][object[]]$Scripts, [Parameter(Mandatory = $true)][string]$Dir, [switch]$Keep)
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    $copies = @{}
    $errors = @{}
    $names = @{}
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        foreach ($s in $Scripts) {
            $name = ($s.Path -replace '^groups/', '') -replace '/', '-'
            try {
                $bytes = [IO.File]::ReadAllBytes((Join-Path $script:WmManagedDir ($s.Path -replace '/', '\')))
                $hash = ([BitConverter]::ToString($sha.ComputeHash($bytes))) -replace '-', ''
                if ($hash -ne ([string]$s.Hash).ToUpperInvariant()) { throw (New-WmError 'logon.file_changed') }
                $dst = Join-Path $Dir $name
                [IO.File]::WriteAllBytes($dst, $bytes)
                $copies[$s.Path] = $dst
                $names[$name] = $true
            } catch {
                $errors[$s.Path] = Get-WmErrorText $_
            }
        }
    } finally {
        $sha.Dispose()
    }
    if (-not $Keep) {
        foreach ($f in @(Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue)) {
            if (-not $names.ContainsKey($f.Name)) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
        }
    }
    return [pscustomobject]@{ Copies = $copies; Errors = $errors }
}

# Runs the sign-in scripts for every user session not served yet. Exit code 0 = done, anything else (or the time
# limit, 5 minutes) is an error in the log; the next sign-in runs them again anyway.
function Invoke-WmLogonScripts {
    param([Parameter(Mandatory = $true)][hashtable]$Config)
    $sessions = @(Get-WmUserSessions)
    $served = Read-WmTabState $script:WmLogonServed
    foreach ($k in @($served.Keys)) { if (-not ($sessions | Where-Object { $_.LogonId -eq $k })) { $served.Remove($k) } }
    $new = @($sessions | Where-Object { -not $served.ContainsKey($_.LogonId) })
    foreach ($u in $new) { $served[$u.LogonId] = [DateTime]::UtcNow.ToString('o') }
    # Served before they run: a run that stops halfway doesn't repeat them for the same sign-in
    Save-WmTabState -Path $script:WmLogonServed -Map $served
    if ($new.Count -eq 0) { return }
    $content = Get-WmLogonContent $Config
    $scripts = @($content.Scripts)

    if ($scripts.Count -gt 0) {
        $secrets = Get-WmSecrets $Config
        $mask = [string[]]@($secrets.Values)
        $checked = Copy-WmCheckedScripts -Scripts $scripts -Dir $script:WmLogonDir
        foreach ($s in $scripts) {
            if ($checked.Errors.ContainsKey($s.Path)) {
                Write-WmLog -Key 'logon.script_not_run' -Arguments @($s.Name, $checked.Errors[$s.Path]) -Level error -Task $s.Name
            }
        }
        foreach ($u in $new) {
            Write-WmLog -Key 'logon.user' -Arguments @($u.User, $u.SessionId, $scripts.Count)
            foreach ($s in $scripts) {
                if (-not $checked.Copies.ContainsKey($s.Path)) { continue }
                $copy = $checked.Copies[$s.Path]
                $vars = @{ WMANAGER_GROUP = $s.Group; WMANAGER_COMPUTER = $script:WmHostName }
                try { Add-WmScriptSecrets -Environment $vars -Secrets $secrets -File $copy }
                catch {
                    Write-WmLog -Key 'logon.script_not_run' -Arguments @($s.Name, (Get-WmErrorText $_)) -Level error -Task $s.Name
                    continue
                }
                try {
                    $r = Invoke-WmUserScript -SessionId $u.SessionId -File $copy -Environment $vars -TimeoutMinutes $script:WmLogonTimeoutMinutes
                } catch {
                    Write-WmLog -Key 'logon.start_failed' -Arguments @($s.Name, $u.User, (Get-WmErrorText $_)) -Level error -Task $s.Name
                    continue
                }
                Write-WmScriptResult -Prefix 'logon' -Name $s.Name -Result $r -TimeoutMinutes $script:WmLogonTimeoutMinutes -Mask $mask
            }
        }
    }
    # The scripts and jobs that run as the user, for the person who just signed in (wmanager-Jobs takes the lock)
    if ($content.UserRuns) { Start-WmJobsTask }
}

# ---------------------------------------------------------------------------
# Startup scripts (groups/<group>/startup/*.ps1): at every start of the computer, as SYSTEM
# ---------------------------------------------------------------------------
# The wmanager-Startup task (SYSTEM, a minute after the computer starts, Invoke-Startup.ps1) runs them group by group
# and by name, each in its own process with the secrets it names. It has two triggers: the boot, and the boot event of
# the System log (Kernel-Boot 27), which Windows logs at every start, also one from Fast Startup (the default "Shut
# down", after which the boot trigger doesn't fire). A start is served once: by the record of that event. Like the
# sign-in scripts they read the verified copy without the lock (a scheduled update that catches up at startup may hold
# it for long, and may be swapping the copy: waited for, up to 2 minutes) and run from copies checked against the
# manifest, in state\startup. Exit code 0 = done, 3010 = done (no restart is made at startup), anything else (or
# ScriptTimeoutMinutes) is an error in the log; the next start runs them again anyway.

$script:WmStartupDir = Join-Path $script:WmStateDir 'startup'
$script:WmStartupServed = Join-Path $script:WmStateDir 'startup-served.txt'

# This start: the record number of the newest boot event ('' when the log has none, e.g. cleared)
function Get-WmBootMark {
    $e = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Boot'; Id = 27 } `
            -MaxEvents 1 -ErrorAction SilentlyContinue
    if ($e) { return [string]$e.RecordId }
    return ''
}

# The verified copy (Get-WmVerifiedGroups), waited for up to $Seconds: the scheduled update may be swapping it
function Wait-WmVerifiedGroups {
    param([Parameter(Mandatory = $true)][hashtable]$Config, [int]$Seconds = 120)
    $verified = Get-WmVerifiedGroups $Config
    $waited = 0
    while (-not $verified -and $waited -lt $Seconds) {
        Start-Sleep -Seconds 10; $waited += 10
        $verified = Get-WmVerifiedGroups $Config
    }
    return $verified
}

# The time limit of one script: ScriptTimeoutMinutes of the management settings, 15 without it
function Get-WmScriptTimeout {
    param($Settings)
    $timeout = [int]$Settings.ScriptTimeoutMinutes
    if ($timeout -le 0) { $timeout = 15 }
    return $timeout
}

function Invoke-WmStartupScripts {
    param([Parameter(Mandatory = $true)][hashtable]$Config, [int]$CopyWaitSeconds = 120)
    # Served before they run: the other trigger of the same start finds it so
    $mark = Get-WmBootMark
    if ($mark) {
        if ((Test-Path -LiteralPath $script:WmStartupServed) -and
                ([IO.File]::ReadAllText($script:WmStartupServed).Trim() -eq $mark)) { return }
        [IO.File]::WriteAllText($script:WmStartupServed, $mark)
    }
    $verified = Wait-WmVerifiedGroups -Config $Config -Seconds $CopyWaitSeconds
    if (-not $verified) { Write-WmLog -Key 'startup.no_copy' -Level warn; return }
    $list = Get-WmGroupStartupScripts -Files $verified.Files -Groups ([string[]]$verified.Groups)
    $scripts = @($list)
    # Also with none: copies of scripts removed from the source go
    $checked = Copy-WmCheckedScripts -Scripts $scripts -Dir $script:WmStartupDir
    if ($scripts.Count -eq 0) { return }
    $timeout = Get-WmScriptTimeout $verified.Settings
    $secrets = Get-WmSecrets $Config
    $mask = [string[]]@($secrets.Values)
    Write-WmLog -Key 'startup.scripts' -Arguments @($scripts.Count)
    foreach ($s in $scripts) {
        if ($checked.Errors.ContainsKey($s.Path)) {
            Write-WmLog -Key 'startup.script_not_run' -Arguments @($s.Name, $checked.Errors[$s.Path]) -Level error -Task $s.Name
            continue
        }
        $copy = $checked.Copies[$s.Path]
        $vars = @{ WMANAGER_GROUP = $s.Group; WMANAGER_COMPUTER = $script:WmHostName }
        # One that can't start doesn't keep the ones after it from running
        try {
            Add-WmScriptSecrets -Environment $vars -Secrets $secrets -File $copy
            $r = Invoke-WmScriptProcess -File $copy -Environment $vars -TimeoutMinutes $timeout
        } catch {
            Write-WmLog -Key 'startup.script_not_run' -Arguments @($s.Name, (Get-WmErrorText $_)) -Level error -Task $s.Name
            continue
        }
        Write-WmScriptResult -Prefix 'startup' -Name $s.Name -Result $r -TimeoutMinutes $timeout -Mask $mask -RestartIsDone
    }
}

# ---------------------------------------------------------------------------
# Event scripts (groups/<group>/events/*.ps1): as SYSTEM when the events they name happen
# ---------------------------------------------------------------------------
# Each event a script names (Get-WmEventSpecs) has its own task (lib\Task.ps1), which the hourly run keeps as the
# source says (Get-WmEventTaskList, Sync-WmEventTasks). The task runs Invoke-Event.ps1 with the script and which of its
# events it is. Like startup scripts they read the verified copy without the lock and run from checked copies (in
# state\events). One event script runs at a time, on the whole computer (a second one waits, up to 30 minutes), and a
# script doesn't run again within its gap (5 minutes by default) after its last run, whichever of its events comes:
# a burst of events (a network that comes and goes) runs it once, and a run within the gap of the copy it ran from
# last time ends before it verifies or waits for anything. Exit code 0 = done, 3010 = done (no restart is made for an
# event), anything else (or ScriptTimeoutMinutes) is an error in the log.

$script:WmEventsDir = Join-Path $script:WmStateDir 'events'
$script:WmEventsState = Join-Path $script:WmStateDir 'events-state.txt'   # script path -> its last run (UTC)

$script:WmEventsMutex = 'Global\wmanager-events'

# A short key of an event's text (8 hex digits of its SHA256). The task passes it rather than the event's place in
# the script, so a run finds its event also when the lines were reordered since the task was made.
function Get-WmEventKey {
    param([Parameter(Mandatory = $true)][string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) } finally { $sha.Dispose() }
    return ([BitConverter]::ToString($hash, 0, 4) -replace '-', '').ToLowerInvariant()
}

# The tasks the event scripts of $Content (Get-WmManagedContent) need: Script (group/name), Index (of the event in the
# script, from 1, for the task's name), Key, Spec and Description. A script whose events can't be read gets none (an
# error in the log says why; its tasks go).
function Get-WmEventTaskList {
    param([Parameter(Mandatory = $true)]$Content)
    $list = @()
    foreach ($s in @($Content.EventScripts | Where-Object { $_ })) {
        try { $specs = Get-WmEventSpecs ([IO.File]::ReadAllText((Join-Path $script:WmManagedDir ($s.Path -replace '/', '\')))) }
        catch {
            Write-WmLog -Key 'events.script_not_run' -Arguments @($s.Name, (Get-WmErrorText $_)) -Level error -Task $s.Name
            continue
        }
        $i = 0
        foreach ($e in @($specs.Events)) {
            $i++
            $list += [pscustomobject]@{
                Script      = $s.Name
                Index       = $i
                Key         = Get-WmEventKey $e.Text
                Spec        = $e
                # What the task is for: a change of the event (or of this layout, v1) registers it again
                Description = 'wmanager: event script {0}, at "{1}" (v1)' -f $s.Name, $e.Text
            }
        }
    }
    return $list
}

# The last run of the event script $Path (UTC) in $State; $null without one
function Get-WmEventLastRun {
    param([hashtable]$State, [string]$Path)
    $parsed = [datetime]::MinValue
    if ($State[$Path] -and [datetime]::TryParse($State[$Path], [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) { return $parsed.ToUniversalTime() }
    return $null
}

# Within the gap of $Gap minutes after the last run? A last run in the future (the clock went back) doesn't hold it.
function Test-WmEventInGap {
    param($LastRun, [int]$Gap, [Parameter(Mandatory = $true)][datetime]$Now)
    if ($Gap -le 0 -or $null -eq $LastRun) { return $false }
    return ($LastRun -le $Now -and ($Now - $LastRun) -lt [TimeSpan]::FromMinutes($Gap))
}

# Runs the event script $Name (group/name) for its event $Key (Get-WmEventKey); $Record and $Log: the event's record
# number and log, as the task passes them; -Session: a lock or unlock, whose session at the screen is read first.
function Invoke-WmEventScript {
    param([Parameter(Mandatory = $true)][hashtable]$Config, [Parameter(Mandatory = $true)][string]$Name, [string]$Key = '',
          [string]$Record = '', [string]$Log = '', [switch]$Session, [int]$CopyWaitSeconds = 120, [int]$WaitMinutes = 30)
    # The person at the screen before any waiting: later it may be someone else
    $console = $null
    if ($Session) { try { $console = Get-WmConsoleSession } catch { } }
    # Within the gap of the copy it ran from last time: nothing to verify or wait for
    $parts = $Name.Split('/', 2)
    if ($parts.Count -eq 2) {
        try {
            $last = Get-WmEventLastRun (Read-WmTabState $script:WmEventsState) "groups/$($parts[0])/events/$($parts[1]).ps1"
            $old = Join-Path $script:WmEventsDir ('{0}-events-{1}.ps1' -f $parts[0], $parts[1])
            if ($last -and [IO.File]::Exists($old) -and
                    (Test-WmEventInGap $last (Get-WmEventSpecs ([IO.File]::ReadAllText($old))).Gap ([DateTime]::UtcNow))) { return }
        } catch { }   # a state or a copy it can't read: the full run decides
    }

    $mutex = New-Object System.Threading.Mutex($false, $script:WmEventsMutex)
    $held = $false
    try {
        try { $held = $mutex.WaitOne([TimeSpan]::FromMinutes($WaitMinutes)) }
        catch [System.Threading.AbandonedMutexException] { $held = $true }   # a run that was killed: free now
        if (-not $held) { Write-WmLog -Key 'events.busy' -Arguments @($Name, $WaitMinutes) -Level warn -Task $Name; return }

        $verified = Wait-WmVerifiedGroups -Config $Config -Seconds $CopyWaitSeconds
        if (-not $verified) { Write-WmLog -Key 'events.no_copy' -Arguments @($Name) -Level warn -Task $Name; return }
        $list = Get-WmGroupEventScripts -Files $verified.Files -Groups ([string[]]$verified.Groups)
        $scripts = @($list)
        $s = $scripts | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
        # Gone from the source, or the computer left its group: the hourly run removes its tasks
        if (-not $s) { Write-WmLog -Key 'events.not_here' -Arguments @($Name) -Task $Name; return }
        # All of them: copies of scripts removed from the source go
        $checked = Copy-WmCheckedScripts -Scripts $scripts -Dir $script:WmEventsDir
        if ($checked.Errors.ContainsKey($s.Path)) {
            Write-WmLog -Key 'events.script_not_run' -Arguments @($s.Name, $checked.Errors[$s.Path]) -Level error -Task $s.Name
            return
        }
        $copy = $checked.Copies[$s.Path]
        try { $specs = Get-WmEventSpecs ([IO.File]::ReadAllText($copy)) }
        catch {
            Write-WmLog -Key 'events.script_not_run' -Arguments @($s.Name, (Get-WmErrorText $_)) -Level error -Task $s.Name
            return
        }
        $spec = @($specs.Events | Where-Object { (Get-WmEventKey $_.Text) -eq $Key }) | Select-Object -First 1
        # Its event is gone from its lines since the task was made: the hourly run makes the tasks again
        if (-not $spec) { Write-WmLog -Key 'events.changed' -Arguments @($s.Name) -Task $s.Name; return }

        $state = Read-WmTabState $script:WmEventsState
        foreach ($k in @($state.Keys)) { if (-not ($scripts | Where-Object { $_.Path -eq $k })) { $state.Remove($k) } }
        $now = [DateTime]::UtcNow
        if (Test-WmEventInGap (Get-WmEventLastRun $state $s.Path) $specs.Gap $now) { return }
        # Recorded before it runs: a run that is killed still counts
        $state[$s.Path] = $now.ToString('o')
        Save-WmTabState -Path $script:WmEventsState -Map $state

        $vars = @{ WMANAGER_GROUP = $s.Group; WMANAGER_COMPUTER = $script:WmHostName; WMANAGER_EVENT = $spec.Text }
        if ('lock', 'unlock' -contains $spec.Name) {
            # The person at the screen: who locked or unlocked the computer (a task without -Session: read now)
            if (-not $Session) { try { $console = Get-WmConsoleSession } catch { } }
            if ($console) {
                $vars['WMANAGER_EVENT_SESSION'] = [string]$console.SessionId
                if ($console.User) { $vars['WMANAGER_EVENT_USER'] = $(if ($console.Domain) { "$($console.Domain)\$($console.User)" } else { $console.User }) }
            }
        } else {
            # Values Task Scheduler didn't fill in stay as "$(Record)": left out
            if ($Record -match '^[0-9]+$') { $vars['WMANAGER_EVENT_RECORD'] = $Record }
            if ($Log -and $Log -notmatch '^\$\(') { $vars['WMANAGER_EVENT_LOG'] = $Log }
        }
        $timeout = Get-WmScriptTimeout $verified.Settings
        $secrets = Get-WmSecrets $Config
        $mask = [string[]]@($secrets.Values)
        Write-WmLog -Key 'events.starting' -Arguments @($s.Name, $spec.Text) -Task $s.Name
        try {
            Add-WmScriptSecrets -Environment $vars -Secrets $secrets -File $copy
            $r = Invoke-WmScriptProcess -File $copy -Environment $vars -TimeoutMinutes $timeout
        } catch {
            Write-WmLog -Key 'events.script_not_run' -Arguments @($s.Name, (Get-WmErrorText $_)) -Level error -Task $s.Name
            return
        }
        Write-WmScriptResult -Prefix 'events' -Name $s.Name -Result $r -TimeoutMinutes $timeout -Mask $mask -RestartIsDone
    } finally {
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
