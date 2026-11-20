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









# Is a job due? The hourly task starts a little early or late, so 5 minutes of slack keep a daily job at
# the same hour instead of drifting. A last run in the future (the clock went back) counts as due.
function Test-WmJobDue {
    param([Parameter(Mandatory = $true)][string]$Every, $LastRun, [Parameter(Mandatory = $true)][datetime]$Now)
    if ($null -eq $LastRun) { return $true }
    $last = [datetime]$LastRun
    if ($last -gt $Now.AddMinutes(5)) { return $true }
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
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($tmp, $Path, $null) }
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

# Checked before provisioning changes anything: settings and the certificate next to the config ($ConfigDir).
function Test-WmManagementConfig {
    param([Parameter(Mandatory = $true)][hashtable]$Config, [Parameter(Mandatory = $true)][string]$ConfigDir)
    $settings = Get-WmManagementSettings $Config
    if (-not $settings) { return }
    $cert = Get-WmSigningCertificate -Config $Config -Dir $ConfigDir
    Write-WmLog -Key 'managed.source_info' -Arguments @($settings.Source, $settings.SourceId, $cert.Subject, $cert.Thumbprint)
    Write-WmCertificateExpiry $cert
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

# Runs the scripts of this computer's groups whose content changed since their last successful run
# (the hourly wmanager-Jobs task and the scheduled update, both as SYSTEM). Exit code 0 = done, 3010 = done and a
# restart is needed; anything else (or the timeout) is an error and the script runs again later: with
# -RetryFailedAfterHours (the hourly run) not before that many hours, unless its content changed.
# A failed script doesn't stop the ones after it.
function Invoke-WmGroupScripts {
    param([Parameter(Mandatory = $true)][hashtable]$Config, [int]$RetryFailedAfterHours = 0)
    $settings = Get-WmManagementSettings $Config
    if (-not $settings) { return }
    Write-WmManagedNote -Key 'managed.scripts_section'
    $content = Get-WmManagedContent -Config $Config
    $scripts = @($content.Scripts)

    # Forget scripts this computer no longer has: if it joins the group again, they run again
    $done = Read-WmTabState $script:WmScriptsState
    $failed = Read-WmTabState $script:WmScriptsFailed
    foreach ($map in @($done, $failed)) {
        foreach ($k in @($map.Keys)) { if (-not ($scripts | Where-Object { $_.Path -eq $k })) { $map.Remove($k) } }
    }
    try { Save-WmTabState -Path $script:WmScriptsState -Map $done; Save-WmTabState -Path $script:WmScriptsFailed -Map $failed } catch { }
    if ($scripts.Count -eq 0) { Write-WmManagedNote -Key 'managed.no_scripts'; return }

    $timeout = [int]$settings.ScriptTimeoutMinutes
    if ($timeout -le 0) { $timeout = 15 }
    $now = [DateTime]::UtcNow
    foreach ($s in $scripts) {
        if ($done[$s.Path] -eq $s.Hash) {
            if (-not $script:WmManagedQuiet) { Write-WmLog -Key 'managed.script_unchanged' -Arguments @($s.Path) -LocalOnly }
            continue
        }
        if ($RetryFailedAfterHours -gt 0 -and $failed[$s.Path]) {
            $f = $failed[$s.Path].Split('|')
            $at = [datetime]::MinValue
            if ($f.Count -eq 2 -and $f[0] -eq $s.Hash -and [datetime]::TryParse($f[1], [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind, [ref]$at)) {
                $age = $now - $at.ToUniversalTime()
                if ($age.TotalHours -ge 0 -and $age.TotalHours -lt $RetryFailedAfterHours) { continue }
            }
        }
        $file = Join-Path $script:WmManagedDir ($s.Path -replace '/', '\')
        Write-WmLog -Key 'managed.script_starting' -Arguments @($s.Path)
        $r = Invoke-WmScriptProcess -File $file -Environment (Get-WmScriptEnvironment $s.Group $s.Path) -TimeoutMinutes $timeout
        Write-WmScriptOutput $r.Output
        if ($r.Errors -and $r.Errors.Trim()) { Write-WmScriptOutput $r.Errors -Prefix '  ! ' }

        if ($null -eq $r.ExitCode -or ($r.ExitCode -ne 0 -and $r.ExitCode -ne 3010)) {
            $failed[$s.Path] = '{0}|{1}' -f $s.Hash, [DateTime]::UtcNow.ToString('o')
            $retry = New-WmText 'managed.retry_next_update'
            if ($RetryFailedAfterHours -gt 0) { $retry = New-WmText 'managed.retry_after_hours' @($RetryFailedAfterHours) }
            if ($null -eq $r.ExitCode) { Write-WmLog -Key 'managed.script_timeout' -Arguments @($s.Path, $timeout, $retry) -Level error }
            else { Write-WmLog -Key 'managed.script_exit_code' -Arguments @($s.Path, $r.ExitCode, $retry) -Level error }
        } else {
            $done[$s.Path] = $s.Hash
            $failed.Remove($s.Path)
            if ($r.ExitCode -eq 3010) {
                $script:WmScriptsNeedReboot = $true
                Write-WmLog -Key 'managed.script_done_reboot' -Arguments @($s.Path)
            } else {
                Write-WmLog -Key 'managed.script_done' -Arguments @($s.Path)
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

# Runs the due jobs of this computer's groups (Invoke-Jobs.ps1, every hour). The start time is recorded
# before the run, so a failed or killed job waits for its next turn instead of repeating every hour.
# Output lines go to Loki unchanged, labelled task="<group>/<name>".
function Invoke-WmGroupJobs {
    param([Parameter(Mandatory = $true)][hashtable]$Config, [Parameter(Mandatory = $true)]$Content)
    $settings = Get-WmManagementSettings $Config
    $jobs = @($Content.Jobs)
    $state = Read-WmTabState $script:WmJobsState
    foreach ($k in @($state.Keys)) { if (-not ($jobs | Where-Object { $_.Path -eq $k })) { $state.Remove($k) } }

    $timeout = [int]$settings.JobTimeoutMinutes
    if ($timeout -le 0) { $timeout = 10 }
    # One time for the whole run: a long job doesn't shift the ones after it
    $now = [DateTime]::UtcNow
    foreach ($j in $jobs) {
        $last = $null
        $parsed = [datetime]::MinValue
        if ($state[$j.Path] -and [datetime]::TryParse($state[$j.Path], [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) { $last = $parsed.ToUniversalTime() }
        if (-not (Test-WmJobDue -Every $j.Every -LastRun $last -Now $now)) { continue }

        $state[$j.Path] = $now.ToString('o')
        try { Save-WmTabState -Path $script:WmJobsState -Map $state } catch { Write-WmLog -Key 'managed.jobs_state_failed' -Arguments @(Get-WmErrorText $_) -Level warn }
        Write-WmLog -Key 'managed.job_starting' -Arguments @($j.Name, $j.Every) -Task $j.Name
        $vars = Get-WmScriptEnvironment $j.Group $j.Path
        $vars['WMANAGER_JOB'] = $j.Name
        $file = Join-Path $script:WmManagedDir ($j.Path -replace '/', '\')
        $r = Invoke-WmScriptProcess -File $file -Environment $vars -TimeoutMinutes $timeout
        Write-WmScriptOutput $r.Output -Task $j.Name -Raw -MaxLength 60000
        if ($r.Errors -and $r.Errors.Trim()) { Write-WmScriptOutput $r.Errors -Prefix '! ' -Task $j.Name }

        if ($null -eq $r.ExitCode) {
            Write-WmLog -Key 'managed.job_timeout' -Arguments @($j.Name, $timeout) -Level error -Task $j.Name
        } elseif ($r.ExitCode -ne 0) {
            Write-WmLog -Key 'managed.job_exit_code' -Arguments @($j.Name, $r.ExitCode) -Level error -Task $j.Name
        } else {
            Write-WmLog -Key 'managed.job_done' -Arguments @($j.Name) -Task $j.Name -LocalOnly
        }
    }
    try { Save-WmTabState -Path $script:WmJobsState -Map $state } catch { }
}
