# Computer groups: a signed management source with the central group map, package lists, group scripts and jobs.
#
# The source is an https:// prefix (e.g. a private Git repository) or a folder (see examples\management):
#   manifest.psd1                          generated and signed by tools/publish.sh (Authenticode)
#   source-id.txt                          identifier of this source (created by tools/publish.sh)
#   groups.psd1                            computer name -> groups
#   choco-reqs.txt                         the common package list
#   groups/<group>/choco-reqs.txt          extra packages for the group (optional)
#   groups/<group>/scripts/*.ps1           run as SYSTEM (hourly task and scheduled update), again whenever their content changes
#   groups/<group>/jobs/<when>/*.ps1       run as SYSTEM on a schedule: hourly, daily or weekly (Invoke-Jobs.ps1)
#   groups/<group>/...                     any other files the scripts use
#
# The manifest lists every file with its SHA256. A computer accepts a manifest only when its Authenticode
# signature is valid and made with the certificate named in the config, its SourceId is the one from the config
# (a manifest signed for another source doesn't fit), and its Serial is not lower than the one accepted before
# (an old signed manifest can't be replayed). Every downloaded file must match its hash and every list must parse
# before the new version replaces the previous one in state\managed. When the source can't be reached, or its new
# version is rejected, the last verified copy is used.

$script:WmScriptsState      = Join-Path $script:WmStateDir 'scripts-done.txt'
$script:WmScriptsFailed     = Join-Path $script:WmStateDir 'scripts-failed.txt'   # path -> hash|time of the last failure
$script:WmJobsState         = Join-Path $script:WmStateDir 'jobs-state.txt'
$script:WmManagedChecked    = Join-Path $script:WmStateDir 'managed-checked.txt'   # touched at every fetch attempt
$script:WmCertFriendlyName  = 'wmanager-signing'   # marks the certificate wmanager added to the root store
$script:WmCodeSigningOid    = '1.3.6.1.5.5.7.3.3'
$script:WmJobPeriods        = @('hourly', 'daily', 'weekly')
$script:WmManaged           = $null                # content resolved in this run (Get-WmManagedContent)
$script:WmManagedError      = $null
$script:WmManagedQuiet      = $false               # the hourly job run logs only warnings and errors
$script:WmScriptsNeedReboot = $false

# Routine information; left out in the hourly job run so the log and Loki don't fill up with it.
function Write-WmManagedNote {
    param([Parameter(Mandatory = $true)][string]$Message)
    if (-not $script:WmManagedQuiet) { Write-WmLog $Message }
}

# Warnings about the content of the source (e.g. a group without files): reported by the scheduled update,
# not again every hour.
function Write-WmManagedWarning {
    param([Parameter(Mandatory = $true)][string]$Message)
    if (-not $script:WmManagedQuiet) { Write-WmLog $Message -Level warn }
}

# ---------------------------------------------------------------------------
# Checks on the content (no system dependencies, tested in tests\Managed.Tests.ps1)
# ---------------------------------------------------------------------------

# A path from the manifest: relative, '/' separated, letters, digits, '.', '-', '_' only.
# No '.' or '..' segments, no segment ending with a dot (Windows drops it) and no device names (NUL, COM1...).
function Test-WmManagedPath {
    param([AllowEmptyString()][string]$Path)
    if (-not $Path -or $Path -notmatch '^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$') { return $false }
    foreach ($seg in $Path.Split('/')) {
        if ($seg.EndsWith('.')) { return $false }
        if ($seg -match '^(con|prn|aux|nul|com[0-9]|lpt[0-9])(\.|$)') { return $false }
    }
    return $true
}

# Checks the data of manifest.psd1. Returns SourceId, Serial and Files (path -> upper-case SHA256).
# With -SourceId, a manifest of another source is rejected.
function ConvertFrom-WmManifestData {
    param([Parameter(Mandatory = $true)][hashtable]$Data, [string]$SourceId)
    $id = [string]$Data.SourceId
    if ($id -notmatch '^[A-Za-z0-9._-]{8,64}$') { throw 'manifest: brak poprawnego identyfikatora źródła (SourceId)' }
    if ($SourceId -and $id -ne $SourceId) { throw "manifest należy do innego źródła ($id), a nie do $SourceId z konfiguracji" }
    $serial = 0L
    if (-not [long]::TryParse([string]$Data.Serial, [ref]$serial) -or $serial -le 0) {
        throw 'manifest: brak poprawnego numeru Serial'
    }
    if (-not ($Data.Files -is [hashtable])) { throw 'manifest: brak listy plików (Files)' }
    $files = @{}   # case-insensitive, like paths on Windows
    foreach ($p in $Data.Files.Keys) {
        $path = [string]$p
        $hash = [string]$Data.Files[$p]
        if (-not (Test-WmManagedPath $path)) { throw "manifest: niedozwolona ścieżka '$path'" }
        if ($path -ieq 'manifest.psd1') { throw 'manifest: nie może wymieniać samego siebie' }
        if ($hash -notmatch '^[0-9A-Fa-f]{64}$') { throw "manifest: niepoprawna suma SHA256 dla '$path'" }
        if ($files.ContainsKey($path)) { throw "manifest: ścieżka '$path' występuje dwa razy" }
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

function Test-WmGroupName {
    param([AllowEmptyString()][string]$Name)
    return ($Name -match '^[A-Za-z0-9_-][A-Za-z0-9._-]*$' -and (Test-WmManagedPath $Name))
}

# groups.psd1: @{ Default = @('group'); Computers = @{ 'OFFICE-01' = @('group', ...) } }. Throws when invalid.
function Assert-WmGroupMap {
    param([Parameter(Mandatory = $true)][hashtable]$Map)
    foreach ($k in $Map.Keys) {
        if (@('Default', 'Computers') -notcontains $k) { throw "groups.psd1: nieznany klucz '$k' (dozwolone: Default, Computers)" }
    }
    $all = @($Map.Default)
    if ($null -ne $Map.Computers) {
        if (-not ($Map.Computers -is [hashtable])) { throw "groups.psd1: Computers musi być tabelą @{ 'NAZWA' = @('grupa') }" }
        foreach ($k in $Map.Computers.Keys) {
            if (-not [string]$k) { throw 'groups.psd1: pusta nazwa komputera' }
            $all += @($Map.Computers[$k])
        }
    }
    foreach ($g in $all) {
        if ($null -eq $g) { continue }
        if (-not (Test-WmGroupName ([string]$g))) { throw "groups.psd1: niepoprawna nazwa grupy '$g'" }
    }
}

# Groups of one computer: Default (all computers), then its own entry in Computers. The computer name
# is compared without regard to case; each group appears once, in that order.
function Get-WmComputerGroups {
    param([Parameter(Mandatory = $true)][hashtable]$Map, [Parameter(Mandatory = $true)][string]$ComputerName)
    $own = @()
    if ($Map.Computers -is [hashtable]) {
        foreach ($k in $Map.Computers.Keys) { if ([string]$k -ieq $ComputerName) { $own = @($Map.Computers[$k]) } }
    }
    $result = New-Object 'System.Collections.Generic.List[string]'
    foreach ($g in (@($Map.Default) + $own)) {
        if ($null -eq $g -or -not [string]$g) { continue }
        $name = [string]$g
        if (-not ($result | Where-Object { $_ -ieq $name })) { $result.Add($name) }
    }
    return ,$result.ToArray()
}

function Get-WmRequirementSpec {
    param($Item)
    return '{0}|{1}|{2}' -f $Item.Version, $Item.NoUpdate, (@($Item.ExtraArgs) -join ' ')
}

# Joins package lists. $Lists: @{ Label; IsGroup; Items } in order, the common list first.
# A group's entry replaces the common list's entry for the same package; when two groups describe the
# same package differently, the first group wins (with a warning).
function Merge-WmRequirements {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Lists)
    $merged = [ordered]@{}
    $from = @{}
    foreach ($l in $Lists) {
        foreach ($r in @($l.Items)) {
            if ($null -eq $r) { continue }
            $key = $r.Name.ToLowerInvariant()
            if (-not $merged.Contains($key)) { $merged[$key] = $r; $from[$key] = $l; continue }
            $prev = $from[$key]
            $takeOver = $l.IsGroup -and -not $prev.IsGroup
            if ((Get-WmRequirementSpec $merged[$key]) -eq (Get-WmRequirementSpec $r)) {
                # Same entry: the package now belongs to the group, so a later group that differs gets the warning
                if ($takeOver) { $from[$key] = $l }
                continue
            }
            if ($takeOver) {
                Write-WmManagedNote "Paczka $($r.Name): wpis z grupy $($l.Label) zastępuje wpis z listy wspólnej."
                $merged[$key] = $r
                $from[$key] = $l
            } else {
                Write-WmManagedWarning "Paczka $($r.Name) jest różnie opisana w '$($prev.Label)' i '$($l.Label)'; używam wpisu z '$($prev.Label)'."
            }
        }
    }
    return ,@($merged.Values)
}

# The .ps1 files directly in $Folder ('/' at the end) of the manifest, sorted by name (ordinal).
function Get-WmManagedScriptPaths {
    param([Parameter(Mandatory = $true)][hashtable]$Files, [Parameter(Mandatory = $true)][string]$Folder)
    $paths = @($Files.Keys | Where-Object {
        $_.StartsWith($Folder, [StringComparison]::OrdinalIgnoreCase) -and
        $_.Substring($Folder.Length) -notmatch '/' -and $_ -match '\.ps1$' })
    $sorted = [string[]]$paths
    [Array]::Sort($sorted, [StringComparer]::OrdinalIgnoreCase)
    return ,$sorted
}

# Scripts of the given groups: groups/<group>/scripts/*.ps1, groups in order, files by name
# (ordinal, so prefix them with numbers: 10-, 20-...).
function Get-WmGroupScripts {
    param([Parameter(Mandatory = $true)][hashtable]$Files, [AllowEmptyCollection()][string[]]$Groups = @())
    $result = @()
    foreach ($g in $Groups) {
        foreach ($p in (Get-WmManagedScriptPaths -Files $Files -Folder "groups/$g/scripts/")) {
            $result += [pscustomobject]@{ Group = $g; Path = $p; Hash = $Files[$p] }
        }
    }
    return ,$result
}

# Jobs of the given groups: groups/<group>/jobs/hourly|daily|weekly/*.ps1. Name (group/file) labels the
# job's entries in Loki.
function Get-WmGroupJobs {
    param([Parameter(Mandatory = $true)][hashtable]$Files, [AllowEmptyCollection()][string[]]$Groups = @())
    $result = @()
    foreach ($g in $Groups) {
        foreach ($every in $script:WmJobPeriods) {
            foreach ($p in (Get-WmManagedScriptPaths -Files $Files -Folder "groups/$g/jobs/$every/")) {
                $base = [IO.Path]::GetFileNameWithoutExtension($p.Substring($p.LastIndexOf('/') + 1))
                $result += [pscustomobject]@{ Group = $g; Path = $p; Every = $every; Name = "$g/$base" }
            }
        }
    }
    return ,$result
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
        default  { throw "nieznana częstotliwość '$Every'" }
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
    if (-not (Test-Path -LiteralPath $path)) { throw "Brak certyfikatu podpisu $path" }
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($path)
    if ($cert.HasPrivateKey) { throw "$path zawiera klucz prywatny; na komputery trafia tylko publiczny .cer" }
    foreach ($ext in $cert.Extensions) {
        if ($ext -is [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension] -and $ext.CertificateAuthority) {
            throw "$path jest certyfikatem urzędu (CA); wmanager nie doda go do zaufanych"
        }
    }
    $eku = @($cert.Extensions | Where-Object { $_ -is [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] })
    $codeSigning = $eku | ForEach-Object { $_.EnhancedKeyUsages } | Where-Object { $_.Value -eq $script:WmCodeSigningOid }
    if (-not $codeSigning) { throw "$path nie jest certyfikatem do podpisywania kodu (brak Code Signing)" }
    return $cert
}

function Write-WmCertificateExpiry {
    param([Parameter(Mandatory = $true)]$Certificate)
    $left = ($Certificate.NotAfter - (Get-Date)).TotalDays
    if ($left -lt 0) {
        Write-WmLog "Certyfikat podpisu wygasł $($Certificate.NotAfter.ToString('yyyy-MM-dd')); działają tylko podpisy ze znacznikiem czasu." -Level warn
    } elseif ($left -lt 60) {
        Write-WmLog "Certyfikat podpisu wygasa $($Certificate.NotAfter.ToString('yyyy-MM-dd')); przygotuj nowy." -Level warn
    }
}

# Windows accepts the signature of a self-signed certificate only if the certificate is in the computer's
# trusted root store. It is added with a FriendlyName, so a previous wmanager certificate is removed when the
# config gets a new one, and Restore-Backup.ps1 can find it. A certificate that was already there stays as it was.
function Install-WmSigningCertificate {
    param([Parameter(Mandatory = $true)]$Certificate)
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root', 'LocalMachine')
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    try {
        foreach ($c in @($store.Certificates)) {
            if ($c.FriendlyName -eq $script:WmCertFriendlyName -and $c.Thumbprint -ne $Certificate.Thumbprint) {
                $store.Remove($c)
                Write-WmLog "Usunięto z zaufanych poprzedni certyfikat podpisu wmanager ($($c.Thumbprint))."
            }
        }
        if (-not (@($store.Certificates) | Where-Object { $_.Thumbprint -eq $Certificate.Thumbprint })) {
            $copy = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($Certificate.RawData)
            $copy.FriendlyName = $script:WmCertFriendlyName
            $store.Add($copy)
            Write-WmLog "Certyfikat podpisu wmanager dodany do zaufanych głównych urzędów komputera ($($Certificate.Thumbprint))."
        }
    } finally {
        $store.Close()
    }
}

# Removes the certificates wmanager added to the root store. Returns how many.
function Remove-WmSigningCertificates {
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

function Test-WmManifestSignature {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Thumbprint)
    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    if ($sig.Status -ne 'Valid') { throw "podpis manifestu nieprawidłowy ($($sig.Status)): $($sig.StatusMessage)" }
    if (-not $sig.SignerCertificate -or $sig.SignerCertificate.Thumbprint -ne $Thumbprint) {
        throw "manifest podpisany innym certyfikatem ($($sig.SignerCertificate.Thumbprint)) niż ten z konfiguracji ($Thumbprint)"
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
    $ProgressPreference = 'SilentlyContinue'   # the progress bar slows Invoke-WebRequest down a lot in 5.1
    $dir = Split-Path $Destination -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop | Out-Null }
    $src = [string]$Settings.Source
    if ($src -match '^https://') {
        $headers = @{}
        if ($Settings.AuthHeader) { $headers['Authorization'] = [string]$Settings.AuthHeader }
        Invoke-WebRequest -Uri ($src.TrimEnd('/') + '/' + $RelPath) -OutFile $Destination -Headers $headers `
            -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
    } else {
        Copy-Item -LiteralPath (Join-Path $src ($RelPath -replace '/', '\')) -Destination $Destination -Force -ErrorAction Stop
    }
}

# The manifest of the copy in state\managed, if it is still valid for the configured certificate and source.
function Get-WmManagedManifest {
    param([Parameter(Mandatory = $true)][string]$Thumbprint, [Parameter(Mandatory = $true)][string]$SourceId)
    $file = Join-Path $script:WmManagedDir 'manifest.psd1'
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    try {
        Test-WmManifestSignature -Path $file -Thumbprint $Thumbprint
        return (ConvertFrom-WmManifestData -Data (Import-PowerShellDataFile -LiteralPath $file) -SourceId $SourceId)
    } catch {
        Write-WmLog "Zapisana kopia źródła zarządzania jest nieważna: $($_.Exception.Message)" -Level warn
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
        catch { throw "groups.psd1: $($_.Exception.Message)" }
        Assert-WmGroupMap $map
    }
    $lists = @{}   # '' = the common list, otherwise the group name
    foreach ($path in @($Manifest.Files.Keys)) {
        if ($path -ieq 'choco-reqs.txt') { $group = '' }
        elseif ($path -match '^groups/([^/]+)/choco-reqs\.txt$') { $group = $Matches[1] }
        else { continue }
        $text = [IO.File]::ReadAllText((Join-Path $Dir ($path -replace '/', '\')), [Text.Encoding]::UTF8)
        # Plain assignment: ConvertFrom-WmRequirements returns the list as one object (,$items)
        try { $lists[$group] = ConvertFrom-WmRequirements -Text $text }
        catch { throw "${path}: $($_.Exception.Message)" }
    }
    return [pscustomobject]@{ Map = $map; Lists = $lists }
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
    param([Parameter(Mandatory = $true)][hashtable]$Settings, [Parameter(Mandatory = $true)][string]$Thumbprint)
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
            Write-WmLog "Źródło zarządzania niedostępne ($($Settings.Source)): $($_.Exception.Message)" -Level warn
            return $null
        }
        Test-WmManifestSignature -Path $manifestFile -Thumbprint $Thumbprint
        $manifest = ConvertFrom-WmManifestData -Data (Import-PowerShellDataFile -LiteralPath $manifestFile) -SourceId $sourceId

        $current = Get-WmManagedManifest -Thumbprint $Thumbprint -SourceId $sourceId
        if ($current) {
            if ($manifest.Serial -lt $current.Serial) {
                throw "manifest $($manifest.Serial) jest starszy niż przyjęty wcześniej $($current.Serial)"
            }
            if ($manifest.Serial -eq $current.Serial) {
                if (-not (Test-WmSameFiles $manifest.Files $current.Files)) {
                    throw "manifest ma ten sam numer $($manifest.Serial) co przyjęty wcześniej, ale inne pliki"
                }
                Write-WmManagedNote "Źródło zarządzania bez zmian (manifest $($manifest.Serial))."
                return $current
            }
        }

        foreach ($path in @($manifest.Files.Keys | Sort-Object)) {
            $dst = Join-Path $new ($path -replace '/', '\')
            try { Get-WmManagedFile -Settings $Settings -RelPath $path -Destination $dst }
            catch { throw "nie udało się pobrać ${path}: $($_.Exception.Message)" }
            if ((Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash -ne $manifest.Files[$path]) {
                throw "$path ma inną sumę SHA256 niż w manifeście (plik zmieniony albo jeszcze nieopublikowany)"
            }
        }
        $null = Read-WmManagedSnapshot -Dir $new -Manifest $manifest

        # Swap. If the second rename fails, the previous copy goes back, so the run still has one.
        $old = '{0}.old-{1}' -f $script:WmManagedDir, (Get-Date -Format 'yyyyMMddHHmmssfff')
        if (Test-Path -LiteralPath $script:WmManagedDir) {
            try { Move-Item -LiteralPath $script:WmManagedDir -Destination $old -ErrorAction Stop }
            catch { throw "nie mogę podmienić $($script:WmManagedDir) (czy jakiś program używa plików z tego folderu?): $($_.Exception.Message)" }
        }
        try {
            Move-Item -LiteralPath $new -Destination $script:WmManagedDir -ErrorAction Stop
        } catch {
            if (Test-Path -LiteralPath $old) { Move-Item -LiteralPath $old -Destination $script:WmManagedDir -ErrorAction SilentlyContinue }
            throw
        }
        Remove-WmOldManagedCopies
        Write-WmLog "Źródło zarządzania: przyjęto manifest $($manifest.Serial) (plików: $($manifest.Files.Count))."
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
    if (-not $settings) { throw 'Brak Management.Source w konfiguracji.' }
    $sourceId = [string]$settings.SourceId
    # The installed copy of the certificate (Install-WmFiles puts it next to the installed config)
    $cert = Get-WmSigningCertificate -Config $Config -Dir $script:WmRoot
    Install-WmSigningCertificate -Certificate $cert
    Repair-WmManagedSwap

    $manifest = $null
    if (-not $CachedOnly) {
        Write-WmCertificateExpiry $cert
        try {
            $manifest = Update-WmManagedCopy -Settings $settings -Thumbprint $cert.Thumbprint
        } catch {
            Write-WmLog "Odrzucono nową wersję ze źródła zarządzania: $($_.Exception.Message)" -Level error
        }
        try { [IO.File]::WriteAllText($script:WmManagedChecked, [DateTime]::UtcNow.ToString('o')) } catch { }
    }
    if (-not $manifest) {
        $manifest = Get-WmManagedManifest -Thumbprint $cert.Thumbprint -SourceId $sourceId
        if (-not $manifest) { throw 'Brak sprawdzonej wersji źródła zarządzania (nie udało się jej pobrać, a kopii nie ma).' }
        if (-not $CachedOnly) { Write-WmLog "Używam ostatniej sprawdzonej kopii źródła zarządzania (manifest $($manifest.Serial))." -Level warn }
    }

    $snap = Read-WmManagedSnapshot -Dir $script:WmManagedDir -Manifest $manifest
    $groups = Get-WmComputerGroups -Map $snap.Map -ComputerName $script:WmHostName
    if ($groups.Count -gt 0) { Write-WmManagedNote "Grupy komputera $($script:WmHostName): $($groups -join ', ')." }
    else { Write-WmManagedNote "Komputer $($script:WmHostName) nie należy do żadnej grupy (tylko lista wspólna)." }

    $lists = @([pscustomobject]@{ Label = 'lista wspólna'; IsGroup = $false; Items = @($snap.Lists['']) })
    foreach ($g in $groups) {
        $hasFiles = @($manifest.Files.Keys | Where-Object { $_.StartsWith("groups/$g/", [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        if (-not $hasFiles) { Write-WmManagedWarning "Grupa $g nie ma żadnych plików w źródle zarządzania."; continue }
        if ($snap.Lists.ContainsKey($g)) { $lists += [pscustomobject]@{ Label = $g; IsGroup = $true; Items = @($snap.Lists[$g]) } }
    }
    return [pscustomobject]@{
        Serial       = $manifest.Serial
        Groups       = $groups
        Requirements = (Merge-WmRequirements -Lists $lists)
        Scripts      = (Get-WmGroupScripts -Files $manifest.Files -Groups $groups)
        Jobs         = (Get-WmGroupJobs -Files $manifest.Files -Groups $groups)
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
        $script:WmManagedError = $_.Exception.Message
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
    Write-WmLog "Źródło zarządzania: $($settings.Source) ($($settings.SourceId)), certyfikat $($cert.Subject) ($($cert.Thumbprint))."
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
    Write-WmManagedNote '--- Skrypty grup ---'
    $content = Get-WmManagedContent -Config $Config
    $scripts = @($content.Scripts)

    # Forget scripts this computer no longer has: if it joins the group again, they run again
    $done = Read-WmTabState $script:WmScriptsState
    $failed = Read-WmTabState $script:WmScriptsFailed
    foreach ($map in @($done, $failed)) {
        foreach ($k in @($map.Keys)) { if (-not ($scripts | Where-Object { $_.Path -eq $k })) { $map.Remove($k) } }
    }
    try { Save-WmTabState -Path $script:WmScriptsState -Map $done; Save-WmTabState -Path $script:WmScriptsFailed -Map $failed } catch { }
    if ($scripts.Count -eq 0) { Write-WmManagedNote 'Brak skryptów dla grup tego komputera.'; return }

    $timeout = [int]$settings.ScriptTimeoutMinutes
    if ($timeout -le 0) { $timeout = 15 }
    $now = [DateTime]::UtcNow
    foreach ($s in $scripts) {
        if ($done[$s.Path] -eq $s.Hash) {
            if (-not $script:WmManagedQuiet) { Write-WmLog "$($s.Path): bez zmian." -LocalOnly }
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
        Write-WmLog "$($s.Path): uruchamiam."
        $r = Invoke-WmScriptProcess -File $file -Environment (Get-WmScriptEnvironment $s.Group $s.Path) -TimeoutMinutes $timeout
        Write-WmScriptOutput $r.Output
        if ($r.Errors -and $r.Errors.Trim()) { Write-WmScriptOutput $r.Errors -Prefix '  ! ' }

        if ($null -eq $r.ExitCode -or ($r.ExitCode -ne 0 -and $r.ExitCode -ne 3010)) {
            $failed[$s.Path] = '{0}|{1}' -f $s.Hash, [DateTime]::UtcNow.ToString('o')
            $retry = 'ponowię przy następnej aktualizacji'
            if ($RetryFailedAfterHours -gt 0) { $retry = "ponowię za $RetryFailedAfterHours h albo po zmianie skryptu" }
            if ($null -eq $r.ExitCode) { Write-WmLog "$($s.Path): przekroczony czas ($timeout min), przerwany; $retry." -Level error }
            else { Write-WmLog "$($s.Path): zakończony kodem $($r.ExitCode); $retry." -Level error }
        } else {
            $done[$s.Path] = $s.Hash
            $failed.Remove($s.Path)
            if ($r.ExitCode -eq 3010) {
                $script:WmScriptsNeedReboot = $true
                Write-WmLog "$($s.Path): zakończony, wymaga restartu."
            } else {
                Write-WmLog "$($s.Path): zakończony."
            }
        }
        try {
            Save-WmTabState -Path $script:WmScriptsState -Map $done
            Save-WmTabState -Path $script:WmScriptsFailed -Map $failed
        } catch {
            Write-WmLog "Nie mogę zapisać stanu skryptów: $($_.Exception.Message)" -Level warn
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
        try { Save-WmTabState -Path $script:WmJobsState -Map $state } catch { Write-WmLog "Nie mogę zapisać stanu jobów: $($_.Exception.Message)" -Level warn }
        Write-WmLog "Job $($j.Name) ($($j.Every)): uruchamiam." -Task $j.Name
        $vars = Get-WmScriptEnvironment $j.Group $j.Path
        $vars['WMANAGER_JOB'] = $j.Name
        $file = Join-Path $script:WmManagedDir ($j.Path -replace '/', '\')
        $r = Invoke-WmScriptProcess -File $file -Environment $vars -TimeoutMinutes $timeout
        Write-WmScriptOutput $r.Output -Task $j.Name -Raw -MaxLength 60000
        if ($r.Errors -and $r.Errors.Trim()) { Write-WmScriptOutput $r.Errors -Prefix '! ' -Task $j.Name }

        if ($null -eq $r.ExitCode) {
            Write-WmLog "Job $($j.Name): przekroczony czas ($timeout min), przerwany." -Level error -Task $j.Name
        } elseif ($r.ExitCode -ne 0) {
            Write-WmLog "Job $($j.Name): zakończony kodem $($r.ExitCode)." -Level error -Task $j.Name
        } else {
            Write-WmLog "Job $($j.Name): zakończony." -Task $j.Name -LocalOnly
        }
    }
    try { Save-WmTabState -Path $script:WmJobsState -Map $state } catch { }
}
