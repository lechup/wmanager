# Chocolatey: instalacja, źródła, lista choco-reqs.txt i synchronizacja paczek.

$script:WmChocoExe = Join-Path $env:ProgramData 'chocolatey\bin\choco.exe'
$script:WmReqsCache = Join-Path $script:WmStateDir 'choco-reqs.cache.txt'

# ---------------------------------------------------------------------------
# Parser listy (bez zależności od systemu, testowany w tests\Requirements.Tests.ps1)
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
    $Text = $Text.TrimStart([char]0xFEFF)   # BOM z pliku pobranego przez HTTP
    foreach ($raw in ($Text -split "\r?\n")) {
        $lineNo++
        # komentarz: # na początku linii albo po białym znaku
        $line = ($raw -replace '(^|\s)#.*$', '').Trim()
        if (-not $line) { continue }

        $extra = ''
        $pipe = $line.IndexOf('|')
        if ($pipe -ge 0) {
            $extra = $line.Substring($pipe + 1).Trim()
            $line = $line.Substring(0, $pipe).Trim()
        }

        $tokens = @($line -split '\s+' | Where-Object { $_ })
        if ($tokens.Count -eq 0) { throw "Linia ${lineNo}: brak nazwy paczki" }

        $spec = $tokens[0]
        $name = $spec
        $version = $null
        $at = $spec.IndexOf('@')
        if ($at -ge 0) {
            $name = $spec.Substring(0, $at)
            $version = $spec.Substring($at + 1)
        }
        if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "Linia ${lineNo}: niepoprawna nazwa paczki '$name'" }

        $pinned = $false
        if ($null -ne $version) {
            if ($version -eq '' -or $version -ieq 'latest') {
                $version = $null
            } elseif ($version -match '^[0-9][0-9A-Za-z.+-]*$') {
                $pinned = $true
            } else {
                throw "Linia ${lineNo}: niepoprawna wersja '$version' dla '$name'"
            }
        }

        $noUpdate = $false
        foreach ($flag in ($tokens | Select-Object -Skip 1)) {
            switch -Regex ($flag) {
                '^!noupdate$' { $noUpdate = $true }
                default { throw "Linia ${lineNo}: nieznana opcja '$flag' (dozwolone: !noupdate, a parametry choco po znaku |)" }
            }
        }

        $key = $name.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { throw "Linia ${lineNo}: paczka '$name' występuje drugi raz (pierwszy raz w linii $($seen[$key]))" }
        $seen[$key] = $lineNo

        $items += [pscustomobject]@{
            Name      = $name
            Version   = $version      # $null = najnowsza
            Pinned    = $pinned
            NoUpdate  = $noUpdate
            ExtraArgs = (Split-WmArgumentString $extra)
            Line      = $lineNo
        }
    }
    return ,$items
}

# ---------------------------------------------------------------------------
# Pobranie listy
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
                if (-not (Test-Path -LiteralPath $path)) { throw "brak pliku $path" }
                $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
            }
            $null = ConvertFrom-WmRequirements -Text $text   # walidacja przed zapisaniem kopii
            New-Item -ItemType Directory -Force -Path $script:WmStateDir | Out-Null
            [IO.File]::WriteAllText($script:WmReqsCache, $text, (New-Object System.Text.UTF8Encoding($false)))
            Write-WmLog "Lista paczek pobrana z: $src"
            return $text
        } catch {
            Write-WmLog "Źródło listy niedostępne lub błędne ($src): $($_.Exception.Message)" -Level warn
        }
    }

    if (Test-Path -LiteralPath $script:WmReqsCache) {
        Write-WmLog 'Używam ostatniej poprawnie pobranej kopii listy.' -Level warn
        return (Get-Content -LiteralPath $script:WmReqsCache -Raw -Encoding UTF8)
    }
    throw 'Brak dostępnej listy paczek (żadne źródło nie odpowiada i nie ma kopii).'
}

# ---------------------------------------------------------------------------
# Chocolatey
# ---------------------------------------------------------------------------

function Invoke-WmChoco {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    Write-WmLog ('choco ' + ($Arguments -join ' ')) -LocalOnly
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

function Install-WmChocolatey {
    param([Parameter(Mandatory = $true)][hashtable]$Config)
    Write-WmLog '--- Chocolatey ---'
    if (Test-Path -LiteralPath $script:WmChocoExe) {
        Write-WmLog 'Chocolatey już zainstalowany.'
    } else {
        $url = Get-WmSetting $Config 'ChocolateyInstallUrl' 'https://community.chocolatey.org/install.ps1'
        Write-WmLog "Instaluję Chocolatey z $url"
        $installer = Join-Path $env:TEMP 'wmanager-choco-install.ps1'
        Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer 2>&1
        foreach ($l in $out) { Write-WmLog "  $l" -LocalOnly }
        Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $script:WmChocoExe)) { throw 'Instalacja Chocolatey nie powiodła się.' }
        Write-WmLog 'Chocolatey zainstalowany.'
    }
    $env:Path = "$env:Path;$(Split-Path $script:WmChocoExe)"

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
            Write-WmLog "Źródło $($s.Name) wyłączone."
            continue
        }
        $a = @('source', 'add', '-n', $s.Name, '-s', $s.Url, '--priority', [string][int]$s.Priority)
        if ($s.User) { $a += @('-u', $s.User, '-p', $s.Password) }
        $code = Invoke-WmChoco $a
        Invoke-WmChoco @('source', 'enable', '-n', $s.Name) | Out-Null
        if ($code -ne 0) { Write-WmLog "Nie udało się ustawić źródła $($s.Name) (kod $code)" -Level warn }
        else { Write-WmLog "Źródło $($s.Name): $($s.Url) (priorytet $([int]$s.Priority))." }
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
        $p = $l.Split('|')   # nazwa|obecna|dostępna|przypięta
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
    param([int]$Code, [string]$Name, [string]$Action)
    if ($Code -eq 0) { return $true }
    if ($Code -in @(1641, 3010)) {
        Write-WmLog "$Name : $Action wymaga restartu."
        $script:WmChocoNeedsReboot = $true
        return $true
    }
    Write-WmLog "$Name : $Action nie powiodło się (kod $Code), szczegóły w logu lokalnym." -Level error
    return $false
}

# Doprowadza paczki do stanu z listy. Paczek spoza listy nie rusza.
#   -Upgrade      aktualizuje paczki bez przypięcia i bez !noupdate (cotygodniowe zadanie)
#   -SkipRunning  pomija paczki, których program działa; zwraca je jako "odłożone"
function Sync-WmPackages {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Requirements,
        [switch]$Upgrade,
        [switch]$SkipRunning,
        [hashtable]$ProcessMap
    )
    Write-WmLog "--- Paczki ($($Requirements.Count) na liście) ---"
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
                    Write-WmLog "$($r.Name): program działa, zmiana wersji odłożona." -Level warn
                    $deferred += $r.Name
                    continue
                }
                if ($pins.ContainsKey($key)) { Invoke-WmChoco @('pin', 'remove', '-n', $r.Name) | Out-Null }
                $code = Invoke-WmChoco (@('upgrade', $r.Name, '--version', $r.Version, '--allow-downgrade', '-y', '--no-progress') + $extra)
                if (Test-WmChocoSuccess $code $r.Name "instalacja wersji $($r.Version)") {
                    Write-WmLog "$($r.Name): ustawiona wersja $($r.Version)."
                } else { continue }
            }
            if ($pins[$key] -ne $r.Version) {
                if ($pins.ContainsKey($key)) { Invoke-WmChoco @('pin', 'remove', '-n', $r.Name) | Out-Null }
                Invoke-WmChoco @('pin', 'add', '-n', $r.Name, '--version', $r.Version) | Out-Null
                Write-WmLog "$($r.Name): przypięta wersja $($r.Version)."
            }
            continue
        }

        # Wersja nieprzypięta: zdejmij przypięcie, jeśli zostało z wcześniejszej listy
        if ($pins.ContainsKey($key)) {
            Invoke-WmChoco @('pin', 'remove', '-n', $r.Name) | Out-Null
            Write-WmLog "$($r.Name): zdjęto przypięcie wersji."
            if ($Upgrade -and -not $r.NoUpdate) { $outdated[$key] = 'po zdjęciu przypięcia' }
        }

        if (-not $current) {
            $code = Invoke-WmChoco (@('install', $r.Name, '-y', '--no-progress') + $extra)
            if (Test-WmChocoSuccess $code $r.Name 'instalacja') { Write-WmLog "$($r.Name): zainstalowano." }
            continue
        }

        if ($Upgrade -and -not $r.NoUpdate -and $outdated.ContainsKey($key)) {
            if ($SkipRunning -and (Test-WmPackageRunning $r.Name $ProcessMap)) {
                Write-WmLog "$($r.Name): program działa, aktualizacja odłożona do następnego logowania." -Level warn
                $deferred += $r.Name
                continue
            }
            $code = Invoke-WmChoco (@('upgrade', $r.Name, '-y', '--no-progress') + $extra)
            if (Test-WmChocoSuccess $code $r.Name 'aktualizacja') {
                Write-WmLog "$($r.Name): zaktualizowano z $current."
            }
        }
    }
    return ,$deferred
}

# ---------------------------------------------------------------------------
# Domyślna przeglądarka (dla nowych kont; obecni klikają raz w Ustawieniach)
# ---------------------------------------------------------------------------

function Set-WmDefaultBrowser {
    param([Parameter(Mandatory = $true)][hashtable]$Config)
    $b = Get-WmSetting $Config 'DefaultBrowser' $null
    if (-not $b -or -not $b.ProgId) { return }
    if (-not (Test-Path -LiteralPath "Registry::HKEY_CLASSES_ROOT\$($b.ProgId)")) {
        Write-WmLog "$($b.Name) nie jest zainstalowana ($($b.ProgId)), pomijam ustawienie domyślnej przeglądarki." -Level warn
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
        Write-WmLog "$($b.Name) ustawiona jako domyślna przeglądarka dla nowych kont."
    } else {
        Write-WmLog "DISM nie ustawił domyślnej przeglądarki (kod $LASTEXITCODE): $($out -join ' ')" -Level warn
    }
}
