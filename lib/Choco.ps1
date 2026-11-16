# Chocolatey: installation, sources, the choco-reqs.txt list and package sync.

$script:WmChocoExe = Join-Path $env:ProgramData 'chocolatey\bin\choco.exe'
$script:WmReqsCache = Join-Path $script:WmStateDir 'choco-reqs.cache.txt'

# ---------------------------------------------------------------------------
# List parser (no system dependencies, tested in tests\Requirements.Tests.ps1)
# ---------------------------------------------------------------------------

function Split-WmArgumentString {
    param([AllowEmptyString()][string]$Text)
    $result = @()
    if (-not $Text) { return ,$result }
    foreach ($m in [regex]::Matches($Text, '"[^"]*"|''[^'']*''|\S+')) {
        $v = $m.Value
        if ($v.Length -ge 2 -and $v.StartsWith('"') -and $v.EndsWith('"')) { $v = $v.Substring(1, $v.Length - 2) }
        $result += $v
    }
    return ,$result
}

function ConvertFrom-WmRequirements {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    $items = @()
    $seen = @{}
    $lineNo = 0
    $Text = $Text.TrimStart([char]0xFEFF)   # BOM from a file downloaded over HTTP
    foreach ($raw in ($Text -split "\r?\n")) {
        $lineNo++
        # comment: # at the start of a line or after whitespace
        $line = ($raw -replace '(^|\s)#.*$', '').Trim()
        if (-not $line) { continue }

        $extra = ''
        $pipe = $line.IndexOf('|')
        if ($pipe -ge 0) {
            $extra = $line.Substring($pipe + 1).Trim()
            $line = $line.Substring(0, $pipe).Trim()
        }

        $tokens = @($line -split '\s+' | Where-Object { $_ })
        if ($tokens.Count -eq 0) { throw (New-WmError 'choco.line_no_package' @($lineNo)) }

        $spec = $tokens[0]
        $name = $spec
        $version = $null
        $at = $spec.IndexOf('@')
        if ($at -ge 0) {
            $name = $spec.Substring(0, $at)
            $version = $spec.Substring($at + 1)
        }
        if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw (New-WmError 'choco.line_bad_name' @($lineNo, $name)) }

        $pinned = $false
        if ($null -ne $version) {
            if ($version -eq '' -or $version -ieq 'latest') {
                $version = $null
            } elseif ($version -match '^[0-9][0-9A-Za-z.+-]*$') {
                $pinned = $true
            } else {
                throw (New-WmError 'choco.line_bad_version' @($lineNo, $version, $name))
            }
        }

        $noUpdate = $false
        foreach ($flag in ($tokens | Select-Object -Skip 1)) {
            switch -Regex ($flag) {
                '^!noupdate$' { $noUpdate = $true }
                default { throw (New-WmError 'choco.line_unknown_option' @($lineNo, $flag)) }
            }
        }

        $key = $name.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { throw (New-WmError 'choco.line_duplicate' @($lineNo, $name, $seen[$key])) }
        $seen[$key] = $lineNo

        $items += [pscustomobject]@{
            Name      = $name
            Version   = $version      # $null = latest
            Pinned    = $pinned
            NoUpdate  = $noUpdate
            ExtraArgs = (Split-WmArgumentString $extra)
            Line      = $lineNo
        }
    }
    return ,$items
}

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
    foreach ($l in $output) {
        $s = "$l".TrimEnd()
        if ($s) { Write-WmLog "  $s" -LocalOnly }
    }
    return $code
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
                $code = Invoke-WmChoco (@('upgrade', $r.Name, '--version', $r.Version, '--allow-downgrade', '-y', '--no-progress') + $extra)
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
            $code = Invoke-WmChoco (@('install', $r.Name, '-y', '--no-progress') + $extra)
            if (Test-WmChocoSuccess $code $r.Name (New-WmText 'choco.action_install')) { Write-WmLog -Key 'choco.package_installed' -Arguments @($r.Name) }
            continue
        }

        if ($Upgrade -and -not $r.NoUpdate -and $outdated.ContainsKey($key)) {
            if ($SkipRunning -and (Test-WmPackageRunning $r.Name $ProcessMap)) {
                Write-WmLog -Key 'choco.running_upgrade_deferred' -Arguments @($r.Name) -Level warn
                $deferred += $r.Name
                continue
            }
            $code = Invoke-WmChoco (@('upgrade', $r.Name, '-y', '--no-progress') + $extra)
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
