# Chocolatey: installation, sources, the choco-reqs.txt list and package sync.

$script:WmChocoExe = Join-Path $env:ProgramData 'chocolatey\bin\choco.exe'
$script:WmReqsCache = Join-Path $script:WmStateDir 'choco-reqs.cache.txt'
# Publishers whose signature vouches for a package's download when its checksum doesn't match, for packages without
# !signer on their line: Google publishes every Chrome at the same address, so the package's checksum is often behind
$script:WmKnownSigners = @{ 'googlechrome' = 'Google LLC' }
# What the last choco command wrote (Invoke-WmChoco)
$script:WmChocoOutput = @()

# The list parser (ConvertFrom-WmRequirements) is in Groups.ps1: the group tool uses it on Linux too.
. (Join-Path $PSScriptRoot 'Groups.ps1')



# ---------------------------------------------------------------------------
# Fetching the list
# ---------------------------------------------------------------------------

function Get-WmRequirementsText {
    param([Parameter(Mandatory = $true)][hashtable]$Config, [Parameter(Mandatory = $true)][string]$BaseDir)

    foreach ($src in @(Get-WmSetting $Config 'ReqsSources' @('choco-reqs.txt'))) {
        if (-not $src) { continue }
        try {
            if ($src -match '^https?://') {
                $resp = Invoke-WebRequest -Uri $src -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
                $text = $resp.Content
                if ($text -is [byte[]]) { $text = [Text.Encoding]::UTF8.GetString($text) }
            } else {
                $path = $src
                if (-not [IO.Path]::IsPathRooted($path)) { $path = Join-Path $BaseDir $path }
                if (-not (Test-Path -LiteralPath $path)) { throw (New-WmError 'choco.reqs_file_missing' @($path)) }
                $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
            }
            $null = ConvertFrom-WmRequirements -Text $text   # validate before caching the copy
            New-Item -ItemType Directory -Force -Path $script:WmStateDir | Out-Null
            [IO.File]::WriteAllText($script:WmReqsCache, $text, (New-Object System.Text.UTF8Encoding($false)))
            Write-WmLog -Key 'choco.reqs_loaded' -Arguments @($src)
            return $text
        } catch {
            Write-WmLog -Key 'choco.reqs_source_failed' -Arguments @($src, (Get-WmErrorText $_)) -Level warn
        }
    }

    if (Test-Path -LiteralPath $script:WmReqsCache) {
        Write-WmLog -Key 'choco.reqs_using_cache' -Level warn
        return (Get-Content -LiteralPath $script:WmReqsCache -Raw -Encoding UTF8)
    }
    throw (New-WmError 'choco.reqs_none')
}

# ---------------------------------------------------------------------------
# Chocolatey
# ---------------------------------------------------------------------------

# The command line for the log, with secret values (passwords, keys) replaced by ***.
function Format-WmChocoArgs {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments)
    $secretFlags = @('-p', '--password', '--cp', '--certpassword', '-k', '--key', '--apikey', '--api-key')
    $out = @()
    $maskNext = $false
    foreach ($a in $Arguments) {
        if ($maskNext) { $out += '***'; $maskNext = $false; continue }
        if ($a -match '^(-{1,2}[A-Za-z-]+)[=:]' -and $secretFlags -contains $Matches[1]) { $out += "$($Matches[1])=***"; continue }
        $out += $a
        if ($secretFlags -contains $a) { $maskNext = $true }
    }
    return ($out -join ' ')
}

function Invoke-WmChoco {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    Write-WmLog ('choco ' + (Format-WmChocoArgs $Arguments)) -LocalOnly
    $output = & $script:WmChocoExe @Arguments 2>&1
    $code = $LASTEXITCODE
    $script:WmChocoOutput = @($output | ForEach-Object { "$_".TrimEnd() })
    foreach ($s in $script:WmChocoOutput) {
        if ($s) { Write-WmLog "  $s" -LocalOnly }
    }
    return $code
}

# The download a package's install script refused because its checksum doesn't match the package, from choco's
# output: File (where choco keeps it) and Url (https only, else $null); $null when that isn't why choco failed
function Get-WmChecksumMismatch {
    param([AllowEmptyCollection()][string[]]$Output)
    $url = $null
    foreach ($l in @($Output)) {
        # "Downloading <package> 64 bit" and, on the next line, "  from 'https://...'"
        if ($l -match "^\s*from '(?<url>[^']+)'\s*$") {
            $url = $Matches['url']   # read before the next -match replaces $Matches
            if ($url -notmatch '^https://') { $url = $null }
            continue
        }
        if ($l -match "Checksum for '(?<file>[^']+)' did not meet '") {
            if (-not [IO.Path]::IsPathRooted($Matches['file'])) { return $null }
            return [pscustomobject]@{ File = $Matches['file']; Url = $url }
        }
    }
    return $null
}

# The publisher whose signature vouches for the downloads of a package from the list: its !signer, else built in
function Get-WmPackageSigner {
    param([Parameter(Mandatory = $true)]$Requirement)
    if ($Requirement.Signer) { return [string]$Requirement.Signer }
    $key = ([string]$Requirement.Name).ToLowerInvariant()
    if ($script:WmKnownSigners.ContainsKey($key)) { return $script:WmKnownSigners[$key] }
    return $null
}

# Downloads $Url to $Path (its folder made when missing)
function Save-WmWebFile {
    param([Parameter(Mandatory = $true)][string]$Url, [Parameter(Mandatory = $true)][string]$Path)
    New-Item -ItemType Directory -Force -Path (Split-Path $Path) | Out-Null
    $client = New-Object System.Net.WebClient
    try { $client.DownloadFile($Url, $Path) } finally { $client.Dispose() }
}

# A file's Authenticode signature: Valid, Name (the CN of the signer's certificate, $null without one), Why (the status)
function Get-WmFileSigner {
    param([Parameter(Mandatory = $true)][string]$Path)
    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    $name = $null
    if ($sig.SignerCertificate) { $name = $sig.SignerCertificate.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) }
    return [pscustomobject]@{ Valid = ([string]$sig.Status -eq 'Valid'); Name = $name; Why = [string]$sig.Status }
}

# The SHA-256 checksum (lower case) of a file whose Authenticode signature is valid and by $Signer (the CN): Hash,
# else $null; Name (the signer), Why (the status, and the signer when it is someone else). The file stays open, others
# may only read it, from the signature to the checksum, so it can't be replaced in between.
function Get-WmSignedFileHash {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Signer)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $by = Get-WmFileSigner -Path $Path
        if (-not $by.Valid -or $by.Name -ine $Signer) {
            $why = if ($by.Name) { '{0}, {1}' -f $by.Why, $by.Name } else { $by.Why }
            return [pscustomobject]@{ Hash = $null; Name = $by.Name; Why = $why }
        }
        $hash = (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash.ToLowerInvariant()
        return [pscustomobject]@{ Hash = $hash; Name = $by.Name; Why = $by.Why }
    } finally { $stream.Dispose() }
}

# choco install or upgrade of a package from the list ($Arguments), with its exit code. When the package's install
# script refuses a download whose checksum doesn't match the package (a new version at the same address before the
# package is updated, as Chrome's often is), the download's Authenticode signature vouches for it instead: valid, and
# by the publisher of the package (Get-WmPackageSigner). choco then runs once more with that file's own checksum: it
# keeps a download that failed the check and uses a copy that matches the checksum given, so only that file gets
# installed (downloaded again only if it was gone, and then checked against the same checksum). choco doesn't
# remember checksums given this way for later upgrades. Not for a pinned version (the address now serves another
# version, which choco would record as the pinned one) or a checksum given after | in the list (that exact file was
# asked for). The checksum given applies to every download of the package: one with a second download that still
# matched the package fails the second run (nothing unchecked gets installed).
function Invoke-WmChocoPackage {
    param([Parameter(Mandatory = $true)]$Requirement, [Parameter(Mandatory = $true)][string[]]$Arguments)
    $code = Invoke-WmChoco $Arguments
    if ($code -in @(0, 1641, 3010)) { return $code }
    $mismatch = Get-WmChecksumMismatch -Output $script:WmChocoOutput
    if (-not $mismatch) { return $code }
    $name = $Requirement.Name
    if ($Requirement.Pinned) { Write-WmLog -Key 'choco.checksum_pinned' -Arguments @($name, $Requirement.Version) -Level error; return $code }
    if (@($Arguments -match '^--?(checksum(64|x64)?|download-?checksum(-?x64)?)(=|$)').Count -gt 0) {
        Write-WmLog -Key 'choco.checksum_own' -Arguments @($name) -Level error
        return $code
    }
    $signer = Get-WmPackageSigner $Requirement
    if (-not $signer) { Write-WmLog -Key 'choco.checksum_no_signer' -Arguments @($name) -Level warn; return $code }
    $file = $mismatch.File
    $leaf = Split-Path $file -Leaf
    Write-WmLog -Key 'choco.checksum_check_signature' -Arguments @($name, $leaf, $signer)
    try {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            if (-not $mismatch.Url) { Write-WmLog -Key 'choco.signature_no_file' -Arguments @($name, $leaf) -Level error; return $code }
            try { Save-WmWebFile -Url $mismatch.Url -Path $file } catch {
                Write-WmLog -Key 'choco.signature_download_failed' -Arguments @($name, (Get-WmSafeUrl $mismatch.Url), (Get-WmErrorText $_)) -Level error
                return $code
            }
        }
        # choco checks the copy it uses against this checksum, so what it installs is the file whose signature was checked
        $checked = Get-WmSignedFileHash -Path $file -Signer $signer
        if (-not $checked.Hash) {
            Write-WmLog -Key 'choco.signature_bad' -Arguments @($name, $leaf, $signer, $checked.Why) -Level error
            return $code
        }
        $hash = $checked.Hash
    } catch {
        # Never the end of the other packages
        Write-WmLog -Key 'choco.signature_check_failed' -Arguments @($name, $leaf, (Get-WmErrorText $_)) -Level error
        return $code
    }
    Write-WmLog -Key 'choco.signature_ok' -Arguments @($name, $leaf, $checked.Name)
    return (Invoke-WmChoco ($Arguments + @("--checksum=$hash", "--checksum64=$hash", '--checksumtype=sha256', '--checksumtype64=sha256')))
}

# An address for the log, sent to Loki too: without a login or a query (a token may be in either)
function Get-WmSafeUrl {
    param([string]$Url)
    try { return ([uri]$Url).GetComponents([UriComponents]::SchemeAndServer -bor [UriComponents]::Path, [UriFormat]::UriEscaped) }
    catch { return '(address)' }
}

function Get-WmChocoLines {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $output = & $script:WmChocoExe @Arguments 2>$null
    return @($output | Where-Object { "$_" -match '\|' } | ForEach-Object { "$_" })
}

function Get-WmChocoVersion {
    foreach ($l in @(& $script:WmChocoExe --version 2>$null)) {
        if ("$l" -match '^\s*(\d+)\.(\d+)') { return [version]"$($Matches[1]).$($Matches[2])" }
    }
    return $null
}

function Install-WmChocolatey {
    param([Parameter(Mandatory = $true)][hashtable]$Config)
    Write-WmLog -Key 'choco.section'
    if (Test-Path -LiteralPath $script:WmChocoExe) {
        Write-WmLog -Key 'choco.already_installed'
    } else {
        $url = Get-WmSetting $Config 'ChocolateyInstallUrl' 'https://community.chocolatey.org/install.ps1'
        Write-WmLog -Key 'choco.installing' -Arguments @($url)
        $installer = Join-Path $env:TEMP 'wmanager-choco-install.ps1'
        Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer 2>&1
        foreach ($l in $out) { Write-WmLog "  $l" -LocalOnly }
        Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $script:WmChocoExe)) { throw (New-WmError 'choco.install_failed') }
        Write-WmLog -Key 'choco.installed'
    }
    $env:Path = "$env:Path;$(Split-Path $script:WmChocoExe)"

    # In 1.x 'choco list' shows the remote feed instead of installed packages, so 2.x is required
    $ver = Get-WmChocoVersion
    if (-not $ver -or $ver.Major -lt 2) {
        Write-WmLog -Key 'choco.too_old' -Arguments @($ver)
        Invoke-WmChoco @('upgrade', 'chocolatey', '-y', '--no-progress') | Out-Null
        $ver = Get-WmChocoVersion
        if (-not $ver -or $ver.Major -lt 2) { throw (New-WmError 'choco.version_required' @($ver)) }
        Write-WmLog -Key 'choco.upgraded' -Arguments @($ver)
    }

    Invoke-WmChoco @('feature', 'enable', '-n', 'allowGlobalConfirmation') | Out-Null
    Invoke-WmChoco @('feature', 'enable', '-n', 'useRememberedArgumentsForUpgrades') | Out-Null
    Invoke-WmChoco @('feature', 'disable', '-n', 'showDownloadProgress') | Out-Null
    Set-WmChocoSources -Config $Config
}

function Set-WmChocoSources {
    param([Parameter(Mandatory = $true)][hashtable]$Config)
    foreach ($s in @(Get-WmSetting $Config 'ChocolateySources' @())) {
        if (-not $s.Name) { continue }
        if ($s.Enabled -eq $false) {
            Invoke-WmChoco @('source', 'disable', '-n', $s.Name) | Out-Null
            Write-WmLog -Key 'choco.source_disabled' -Arguments @($s.Name)
            continue
        }
        $a = @('source', 'add', '-n', $s.Name, '-s', $s.Url, '--priority', [string][int]$s.Priority)
        if ($s.User) { $a += @('-u', $s.User, '-p', $s.Password) }
        $code = Invoke-WmChoco $a
        Invoke-WmChoco @('source', 'enable', '-n', $s.Name) | Out-Null
        if ($code -ne 0) { Write-WmLog -Key 'choco.source_failed' -Arguments @($s.Name, $code) -Level warn }
        else { Write-WmLog -Key 'choco.source_set' -Arguments @($s.Name, $s.Url, [int]$s.Priority) }
    }
}

function Get-WmInstalledPackages {
    $map = @{}
    foreach ($l in (Get-WmChocoLines @('list', '--limit-output'))) {
        $p = $l.Split('|')
        $map[$p[0].ToLowerInvariant()] = $p[1]
    }
    return $map
}

function Get-WmPins {
    $map = @{}
    foreach ($l in (Get-WmChocoLines @('pin', 'list', '--limit-output'))) {
        $p = $l.Split('|')
        $map[$p[0].ToLowerInvariant()] = $p[1]
    }
    return $map
}

function Get-WmOutdated {
    $map = @{}
    foreach ($l in (Get-WmChocoLines @('outdated', '--limit-output', '--ignore-pinned'))) {
        $p = $l.Split('|')   # name|current|available|pinned
        $map[$p[0].ToLowerInvariant()] = $p[2]
    }
    return $map
}

function Test-WmPackageRunning {
    param([Parameter(Mandatory = $true)][string]$Name, [hashtable]$ProcessMap)
    $procs = @()
    if ($ProcessMap -and $ProcessMap.ContainsKey($Name)) { $procs = @($ProcessMap[$Name]) }
    else { $procs = @(($Name -replace '\.(install|portable)$', '')) }
    foreach ($p in $procs) {
        if (Get-Process -Name $p -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}

function Test-WmChocoSuccess {
    param([int]$Code, [string]$Name, $Action)
    if ($Code -eq 0) { return $true }
    if ($Code -in @(1641, 3010)) {
        Write-WmLog -Key 'choco.needs_restart' -Arguments @($Name, $Action)
        $script:WmChocoNeedsReboot = $true
        return $true
    }
    # $Action: New-WmText of choco.action_install, choco.action_install_version or choco.action_upgrade, the
    # subject of both sentences (in Polish all three are feminine, as the sentences expect)
    Write-WmLog -Key 'choco.action_failed' -Arguments @($Name, $Action, $Code) -Level error
    return $false
}

# Brings packages to the state in the list. Packages not on the list are left alone.
#   -Upgrade      upgrades packages that are neither pinned nor !noupdate (scheduled update)
#   -SkipRunning  skips packages whose program is running; returns them as "deferred"
function Sync-WmPackages {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Requirements,
        [switch]$Upgrade,
        [switch]$SkipRunning,
        [hashtable]$ProcessMap
    )
    Write-WmLog -Key 'choco.packages_section' -Arguments @($Requirements.Count)
    $script:WmChocoNeedsReboot = $false
    $deferred = @()
    $installed = Get-WmInstalledPackages
    $pins = Get-WmPins
    $outdated = @{}
    if ($Upgrade) { $outdated = Get-WmOutdated }

    foreach ($r in $Requirements) {
        $key = $r.Name.ToLowerInvariant()
        $current = $installed[$key]
        $extra = @($r.ExtraArgs)

        if ($r.Pinned) {
            if ($current -ne $r.Version) {
                if ($current -and $SkipRunning -and (Test-WmPackageRunning $r.Name $ProcessMap)) {
                    Write-WmLog -Key 'choco.running_version_deferred' -Arguments @($r.Name) -Level warn
                    $deferred += $r.Name
                    continue
                }
                if ($pins.ContainsKey($key)) {
                    Invoke-WmChoco @('pin', 'remove', '-n', $r.Name) | Out-Null
                    $pins.Remove($key)   # so the pin is added back below, even if it had the same version
                }
                $code = Invoke-WmChocoPackage $r (@('upgrade', $r.Name, '--version', $r.Version, '--allow-downgrade', '-y', '--no-progress') + $extra)
                if (Test-WmChocoSuccess $code $r.Name (New-WmText 'choco.action_install_version' @($r.Version))) {
                    Write-WmLog -Key 'choco.version_set' -Arguments @($r.Name, $r.Version)
                } else { continue }
            }
            if ($pins[$key] -ne $r.Version) {
                if ($pins.ContainsKey($key)) { Invoke-WmChoco @('pin', 'remove', '-n', $r.Name) | Out-Null }
                Invoke-WmChoco @('pin', 'add', '-n', $r.Name, '--version', $r.Version) | Out-Null
                Write-WmLog -Key 'choco.version_pinned' -Arguments @($r.Name, $r.Version)
            }
            continue
        }

        # Unpinned version: remove the pin if it is left over from an earlier list
        if ($pins.ContainsKey($key)) {
            Invoke-WmChoco @('pin', 'remove', '-n', $r.Name) | Out-Null
            Write-WmLog -Key 'choco.pin_removed' -Arguments @($r.Name)
            if ($Upgrade -and -not $r.NoUpdate) { $outdated[$key] = '(unpinned)' }   # only the key is used below
        }

        if (-not $current) {
            $code = Invoke-WmChocoPackage $r (@('install', $r.Name, '-y', '--no-progress') + $extra)
            if (Test-WmChocoSuccess $code $r.Name (New-WmText 'choco.action_install')) { Write-WmLog -Key 'choco.package_installed' -Arguments @($r.Name) }
            continue
        }

        if ($Upgrade -and -not $r.NoUpdate -and $outdated.ContainsKey($key)) {
            if ($SkipRunning -and (Test-WmPackageRunning $r.Name $ProcessMap)) {
                Write-WmLog -Key 'choco.running_upgrade_deferred' -Arguments @($r.Name) -Level warn
                $deferred += $r.Name
                continue
            }
            $code = Invoke-WmChocoPackage $r (@('upgrade', $r.Name, '-y', '--no-progress') + $extra)
            if (Test-WmChocoSuccess $code $r.Name (New-WmText 'choco.action_upgrade')) {
                Write-WmLog -Key 'choco.package_upgraded' -Arguments @($r.Name, $current)
            }
        }
    }
    return ,$deferred
}

# ---------------------------------------------------------------------------
# Default browser (for new accounts; existing users click once in Settings)
# ---------------------------------------------------------------------------

function Set-WmDefaultBrowser {
    param([Parameter(Mandatory = $true)][hashtable]$Config)
    $b = Get-WmSetting $Config 'DefaultBrowser' $null
    if (-not $b -or -not $b.ProgId) { return }
    if (-not (Test-Path -LiteralPath "Registry::HKEY_CLASSES_ROOT\$($b.ProgId)")) {
        Write-WmLog -Key 'choco.browser_missing' -Arguments @($b.Name, $b.ProgId) -Level warn
        return
    }
    $xmlPath = Join-Path $script:WmStateDir 'DefaultAssociations.xml'
    $assoc = foreach ($id in @('http', 'https', '.htm', '.html')) {
        '  <Association Identifier="{0}" ProgId="{1}" ApplicationName="{2}" />' -f $id, $b.ProgId, $b.Name
    }
    $xml = @('<?xml version="1.0" encoding="UTF-8"?>', '<DefaultAssociations>') + $assoc + @('</DefaultAssociations>')
    [IO.File]::WriteAllLines($xmlPath, $xml, (New-Object System.Text.UTF8Encoding($false)))
    $out = & dism.exe /Online /Import-DefaultAppAssociations:"$xmlPath" 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-WmLog -Key 'choco.browser_set' -Arguments @($b.Name)
    } else {
        Write-WmLog -Key 'choco.browser_dism_failed' -Arguments @($LASTEXITCODE, ($out -join ' ')) -Level warn
    }
}
