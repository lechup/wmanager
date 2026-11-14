# Computer groups: a signed management source with the central group map, package lists and group scripts.
#
# The source is an https:// prefix (e.g. a private Git repository) or a folder (see examples\management):
#   manifest.psd1                     generated and signed by tools/publish.sh (Authenticode)
#   groups.psd1                       computer name -> groups
#   choco-reqs.txt                    the common package list
#   groups/<group>/choco-reqs.txt     extra packages for the group (optional)
#   groups/<group>/scripts/*.ps1      run as SYSTEM, again whenever their content changes
#   groups/<group>/...                any other files the scripts use
#
# The manifest lists every file with its SHA256. A computer accepts a manifest only when its Authenticode
# signature is valid and made with the certificate named in the config, and its Serial is not lower than the
# one accepted before (an old signed manifest can't be replayed). Every downloaded file must match its hash and
# every list must parse before the new version replaces the previous one in state\managed. When the source
# can't be reached, or its new version is rejected, the last verified copy is used.

$script:WmScriptsState      = Join-Path $script:WmStateDir 'scripts-done.txt'
$script:WmCertFriendlyName  = 'wmanager-signing'   # marks the certificate wmanager added to the root store
$script:WmCodeSigningOid    = '1.3.6.1.5.5.7.3.3'
$script:WmManaged           = $null                # content resolved in this run (Get-WmManagedContent)
$script:WmManagedError      = $null
$script:WmScriptsNeedReboot = $false

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

# Checks the data of manifest.psd1. Returns Serial and Files (path -> upper-case SHA256).
function ConvertFrom-WmManifestData {
    param([Parameter(Mandatory = $true)][hashtable]$Data)
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
    return [pscustomobject]@{ Serial = $serial; Files = $files }
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
            if ((Get-WmRequirementSpec $merged[$key]) -eq (Get-WmRequirementSpec $r)) { continue }
            if ($l.IsGroup -and -not $prev.IsGroup) {
                Write-WmLog "Paczka $($r.Name): wpis z grupy $($l.Label) zastępuje wpis z listy wspólnej."
                $merged[$key] = $r
                $from[$key] = $l
            } else {
                Write-WmLog "Paczka $($r.Name) jest różnie opisana w '$($prev.Label)' i '$($l.Label)'; używam wpisu z '$($prev.Label)'." -Level warn
            }
        }
    }
    return ,@($merged.Values)
}

# Scripts of the given groups: groups/<group>/scripts/*.ps1, groups in order, files by name
# (ordinal, so prefix them with numbers: 10-, 20-...).
function Get-WmGroupScripts {
    param([Parameter(Mandatory = $true)][hashtable]$Files, [AllowEmptyCollection()][string[]]$Groups = @())
    $result = @()
    foreach ($g in $Groups) {
        $prefix = "groups/$g/scripts/"
        $paths = @($Files.Keys | Where-Object {
            $_.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and
            $_.Substring($prefix.Length) -notmatch '/' -and $_ -match '\.ps1$' })
        if ($paths.Count -eq 0) { continue }
        $sorted = [string[]]$paths
        [Array]::Sort($sorted, [StringComparer]::OrdinalIgnoreCase)
        foreach ($p in $sorted) { $result += [pscustomobject]@{ Group = $g; Path = $p; Hash = $Files[$p] } }
    }
    return ,$result
}

# ---------------------------------------------------------------------------
# Signing certificate
# ---------------------------------------------------------------------------

# The public certificate from the config, checked: code signing only, not a CA, no private key.
function Get-WmSigningCertificate {
    param([Parameter(Mandatory = $true)][hashtable]$Config, [Parameter(Mandatory = $true)][string]$BaseDir)
    $path = Join-Path $BaseDir (Get-WmCertificateFileName $Config)
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
    if ($cert.NotAfter -lt (Get-Date)) { throw "Certyfikat podpisu wygasł $($cert.NotAfter.ToString('yyyy-MM-dd'))" }
    return $cert
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

# The manifest of the copy in state\managed, if its signature is still valid for the configured certificate.
function Get-WmManagedManifest {
    param([Parameter(Mandatory = $true)][string]$Thumbprint)
    $file = Join-Path $script:WmManagedDir 'manifest.psd1'
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    try {
        Test-WmManifestSignature -Path $file -Thumbprint $Thumbprint
        return (ConvertFrom-WmManifestData (Import-PowerShellDataFile -LiteralPath $file))
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
        try { $lists[$group] = @(ConvertFrom-WmRequirements -Text $text) }
        catch { throw "${path}: $($_.Exception.Message)" }
    }
    return [pscustomobject]@{ Map = $map; Lists = $lists }
}

# A swap interrupted between the two renames leaves only managed.old; put it back.
function Repair-WmManagedSwap {
    $old = "$($script:WmManagedDir).old"
    if ((Test-Path -LiteralPath $old) -and -not (Test-Path -LiteralPath $script:WmManagedDir)) {
        Move-Item -LiteralPath $old -Destination $script:WmManagedDir -ErrorAction Stop
    }
}

# Downloads and checks the current version of the source; when it is valid, it replaces state\managed.
# Returns the accepted manifest, or $null when the manifest could not be downloaded (warning logged).
# Throws when the new version is invalid (signature, serial, hashes, content).
function Update-WmManagedCopy {
    param([Parameter(Mandatory = $true)][hashtable]$Settings, [Parameter(Mandatory = $true)][string]$Thumbprint)
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
        $manifest = ConvertFrom-WmManifestData (Import-PowerShellDataFile -LiteralPath $manifestFile)

        $current = Get-WmManagedManifest -Thumbprint $Thumbprint
        if ($current) {
            if ($manifest.Serial -lt $current.Serial) {
                throw "manifest $($manifest.Serial) jest starszy niż przyjęty wcześniej $($current.Serial)"
            }
            if ($manifest.Serial -eq $current.Serial) {
                if (-not (Test-WmSameFiles $manifest.Files $current.Files)) {
                    throw "manifest ma ten sam numer $($manifest.Serial) co przyjęty wcześniej, ale inne pliki"
                }
                Write-WmLog "Źródło zarządzania bez zmian (manifest $($manifest.Serial))."
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

        $old = "$($script:WmManagedDir).old"
        if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction Stop }
        if (Test-Path -LiteralPath $script:WmManagedDir) { Move-Item -LiteralPath $script:WmManagedDir -Destination $old -ErrorAction Stop }
        Move-Item -LiteralPath $new -Destination $script:WmManagedDir -ErrorAction Stop
        Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction SilentlyContinue
        Write-WmLog "Źródło zarządzania: przyjęto manifest $($manifest.Serial) (plików: $($manifest.Files.Count))."
        return $manifest
    } finally {
        if (Test-Path -LiteralPath $new) { Remove-Item -LiteralPath $new -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Resolve-WmManagedContent {
    param([Parameter(Mandatory = $true)][hashtable]$Config, [Parameter(Mandatory = $true)][string]$BaseDir)
    $settings = Get-WmManagementSettings $Config
    if (-not $settings) { throw 'Brak Management.Source w konfiguracji.' }
    $cert = Get-WmSigningCertificate -Config $Config -BaseDir $BaseDir
    Install-WmSigningCertificate -Certificate $cert
    Repair-WmManagedSwap

    $manifest = $null
    try {
        $manifest = Update-WmManagedCopy -Settings $settings -Thumbprint $cert.Thumbprint
    } catch {
        Write-WmLog "Odrzucono nową wersję ze źródła zarządzania: $($_.Exception.Message)" -Level error
    }
    if (-not $manifest) {
        $manifest = Get-WmManagedManifest -Thumbprint $cert.Thumbprint
        if (-not $manifest) { throw 'Brak sprawdzonej wersji źródła zarządzania (nie udało się jej pobrać, a kopii nie ma).' }
        Write-WmLog "Używam ostatniej sprawdzonej kopii źródła zarządzania (manifest $($manifest.Serial))." -Level warn
    }

    $snap = Read-WmManagedSnapshot -Dir $script:WmManagedDir -Manifest $manifest
    $groups = Get-WmComputerGroups -Map $snap.Map -ComputerName $script:WmHostName
    if ($groups.Count -gt 0) { Write-WmLog "Grupy komputera $($script:WmHostName): $($groups -join ', ')." }
    else { Write-WmLog "Komputer $($script:WmHostName) nie należy do żadnej grupy (tylko lista wspólna)." }

    $lists = @([pscustomobject]@{ Label = 'lista wspólna'; IsGroup = $false; Items = @($snap.Lists['']) })
    foreach ($g in $groups) {
        $hasFiles = @($manifest.Files.Keys | Where-Object { $_.StartsWith("groups/$g/", [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        if (-not $hasFiles) { Write-WmLog "Grupa $g nie ma żadnych plików w źródle zarządzania." -Level warn; continue }
        if ($snap.Lists.ContainsKey($g)) { $lists += [pscustomobject]@{ Label = $g; IsGroup = $true; Items = @($snap.Lists[$g]) } }
    }
    return [pscustomobject]@{
        Serial       = $manifest.Serial
        Groups       = $groups
        Requirements = (Merge-WmRequirements -Lists $lists)
        Scripts      = (Get-WmGroupScripts -Files $manifest.Files -Groups $groups)
    }
}

# The management content for this run, fetched once and reused by the package and script stages.
function Get-WmManagedContent {
    param([Parameter(Mandatory = $true)][hashtable]$Config, [Parameter(Mandatory = $true)][string]$BaseDir)
    if ($script:WmManaged) { return $script:WmManaged }
    if ($script:WmManagedError) { throw $script:WmManagedError }
    try {
        $script:WmManaged = Resolve-WmManagedContent -Config $Config -BaseDir $BaseDir
        return $script:WmManaged
    } catch {
        $script:WmManagedError = $_.Exception.Message
        throw
    }
}

# The package list for this run: from the management source when one is configured, otherwise from ReqsSources.
function Get-WmRequirements {
    param([Parameter(Mandatory = $true)][hashtable]$Config, [Parameter(Mandatory = $true)][string]$BaseDir)
    if (Get-WmManagementSettings $Config) {
        return ,@((Get-WmManagedContent -Config $Config -BaseDir $BaseDir).Requirements)
    }
    return ,@(ConvertFrom-WmRequirements -Text (Get-WmRequirementsText -Config $Config -BaseDir $BaseDir))
}

# Checked before provisioning changes anything: settings and the certificate file.
function Test-WmManagementConfig {
    param([Parameter(Mandatory = $true)][hashtable]$Config, [Parameter(Mandatory = $true)][string]$BaseDir)
    if (-not (Get-WmManagementSettings $Config)) { return }
    $cert = Get-WmSigningCertificate -Config $Config -BaseDir $BaseDir
    Write-WmLog "Źródło zarządzania: $((Get-WmManagementSettings $Config).Source), certyfikat $($cert.Subject) ($($cert.Thumbprint))."
}

# ---------------------------------------------------------------------------
# Group scripts
# ---------------------------------------------------------------------------

# Path -> SHA256 of the last successful run.
function Read-WmScriptsState {
    $map = @{}
    if (Test-Path -LiteralPath $script:WmScriptsState) {
        foreach ($line in [IO.File]::ReadAllLines($script:WmScriptsState)) {
            $p = $line.Split("`t")
            if ($p.Count -ge 2 -and $p[0]) { $map[$p[0]] = $p[1] }
        }
    }
    return $map
}

function Save-WmScriptsState {
    param([Parameter(Mandatory = $true)][hashtable]$Map)
    $lines = @($Map.Keys | Sort-Object | ForEach-Object { "$_`t$($Map[$_])" })
    [IO.File]::WriteAllLines($script:WmScriptsState, [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
}

# Runs one script in its own Windows PowerShell process (so it can't change wmanager's state).
# Returns ExitCode ($null after the timeout, when the process tree is killed), Output and Errors.
function Invoke-WmScriptProcess {
    param(
        [Parameter(Mandatory = $true)][string]$File,
        [Parameter(Mandatory = $true)][string]$WorkDir,
        [hashtable]$Environment = @{},
        [int]$TimeoutMinutes = 15
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$File`""
    $psi.WorkingDirectory = $WorkDir
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

function Write-WmScriptOutput {
    param([AllowEmptyString()][string]$Text, [string]$Prefix = '  ')
    foreach ($l in ($Text -split "\r?\n")) {
        $s = $l.TrimEnd()
        if (-not $s) { continue }
        if ($s.Length -gt 2000) { $s = $s.Substring(0, 2000) + '...' }
        Write-WmLog "$Prefix$s"
    }
}

# Runs the scripts of this computer's groups whose content changed since their last successful run.
# Exit code 0 = done, 3010 = done and a restart is needed; anything else (or the timeout) is an error and
# the script runs again next time. A failed script doesn't stop the ones after it.
function Invoke-WmGroupScripts {
    param([Parameter(Mandatory = $true)][hashtable]$Config, [Parameter(Mandatory = $true)][string]$BaseDir)
    $settings = Get-WmManagementSettings $Config
    if (-not $settings) { return }
    Write-WmLog '--- Skrypty grup ---'
    $content = Get-WmManagedContent -Config $Config -BaseDir $BaseDir
    $scripts = @($content.Scripts)
    if ($scripts.Count -eq 0) { Write-WmLog 'Brak skryptów dla grup tego komputera.'; return }

    $timeout = [int]$settings.ScriptTimeoutMinutes
    if ($timeout -le 0) { $timeout = 15 }
    $done = Read-WmScriptsState
    # Forget scripts this computer no longer has: if it joins the group again, they run again
    foreach ($k in @($done.Keys)) { if (-not ($scripts | Where-Object { $_.Path -eq $k })) { $done.Remove($k) } }

    foreach ($s in $scripts) {
        if ($done[$s.Path] -eq $s.Hash) { Write-WmLog "$($s.Path): bez zmian." -LocalOnly; continue }
        $file = Join-Path $script:WmManagedDir ($s.Path -replace '/', '\')
        $groupDir = Split-Path (Split-Path $file -Parent) -Parent
        Write-WmLog "$($s.Path): uruchamiam."
        $vars = @{ WMANAGER_GROUP = $s.Group; WMANAGER_COMPUTER = $script:WmHostName; WMANAGER_GROUP_DIR = $groupDir }
        $r = Invoke-WmScriptProcess -File $file -WorkDir $groupDir -Environment $vars -TimeoutMinutes $timeout
        Write-WmScriptOutput $r.Output
        if ($r.Errors -and $r.Errors.Trim()) { Write-WmScriptOutput $r.Errors -Prefix '  ! ' }

        if ($null -eq $r.ExitCode) {
            Write-WmLog "$($s.Path): przekroczony czas ($timeout min), przerwany; ponowię w następnym przebiegu." -Level error
        } elseif ($r.ExitCode -eq 0 -or $r.ExitCode -eq 3010) {
            $done[$s.Path] = $s.Hash
            if ($r.ExitCode -eq 3010) {
                $script:WmScriptsNeedReboot = $true
                Write-WmLog "$($s.Path): zakończony, wymaga restartu."
            } else {
                Write-WmLog "$($s.Path): zakończony."
            }
        } else {
            Write-WmLog "$($s.Path): zakończony kodem $($r.ExitCode); ponowię w następnym przebiegu." -Level error
        }
        try { Save-WmScriptsState $done } catch { Write-WmLog "Nie mogę zapisać stanu skryptów: $($_.Exception.Message)" -Level warn }
    }
    try { Save-WmScriptsState $done } catch { }
}
