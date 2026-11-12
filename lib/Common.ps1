# Wspólne funkcje: ścieżki, konfiguracja, logi, rejestr, Loki, Healthchecks.
# Zgodne z Windows PowerShell 5.1.

$script:WmRoot       = Join-Path $env:ProgramData 'wmanager'
$script:WmStateDir   = Join-Path $script:WmRoot 'state'
$script:WmLogDir     = Join-Path $script:WmRoot 'logs'
$script:WmLogFile    = $null
$script:WmJob        = 'provision'
$script:WmHostName   = $env:COMPUTERNAME
$script:WmWarnings   = 0
$script:WmErrors     = 0
$script:WmLogBuffer  = New-Object 'System.Collections.Generic.List[object]'

$script:WmRebootFlag  = Join-Path $script:WmStateDir 'reboot-required.flag'
$script:WmRetryFlag   = Join-Path $script:WmStateDir 'retry-pending.flag'
$script:WmPublicState = Join-Path $script:WmStateDir 'public.json'
$script:WmMutexName   = 'Global\wmanager-run'

# PowerShell 5.1 domyślnie nie włącza TLS 1.2
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# ---------------------------------------------------------------------------
# Konfiguracja
# ---------------------------------------------------------------------------

function Import-WmConfig {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Brak pliku konfiguracji: $Path"
    }
    return Import-PowerShellDataFile -LiteralPath $Path
}

function Get-WmSetting {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )
    if ($Config.ContainsKey($Name) -and $null -ne $Config[$Name]) {
        $v = $Config[$Name]
        if ($v -is [string] -and $v -eq '') { return $Default }
        return $v
    }
    return $Default
}

# ---------------------------------------------------------------------------
# Logi
# ---------------------------------------------------------------------------

function Initialize-WmLog {
    param([Parameter(Mandatory = $true)][string]$Job)
    $script:WmJob = $Job
    New-Item -ItemType Directory -Force -Path $script:WmLogDir | Out-Null
    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
    $script:WmLogFile = Join-Path $script:WmLogDir ("{0}-{1}.log" -f $Job, $stamp)
}

function Write-WmLog {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message,
        [ValidateSet('info', 'warn', 'error')][string]$Level = 'info',
        # Tylko do pliku lokalnego (np. pełne wyjście choco), bez wysyłki do Loki
        [switch]$LocalOnly
    )
    $ts = Get-Date
    $line = '{0} [{1}] {2}' -f $ts.ToString('yyyy-MM-dd HH:mm:ss'), $Level.ToUpper(), $Message
    switch ($Level) {
        'warn'  { $script:WmWarnings++; Write-Host $line -ForegroundColor Yellow }
        'error' { $script:WmErrors++;   Write-Host $line -ForegroundColor Red }
        default { if ($LocalOnly) { Write-Host $line -ForegroundColor DarkGray } else { Write-Host $line } }
    }
    if ($script:WmLogFile) {
        try { Add-Content -LiteralPath $script:WmLogFile -Value $line -Encoding UTF8 } catch { }
    }
    if (-not $LocalOnly) {
        $script:WmLogBuffer.Add([pscustomobject]@{ Time = $ts; Level = $Level; Line = $line })
    }
}

function Remove-WmOldLogs {
    param([int]$Days = 90)
    $limit = (Get-Date).AddDays(-$Days)
    Get-ChildItem -LiteralPath $script:WmLogDir -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $limit } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Get-WmLogTail {
    param([int]$Lines = 60)
    $all = @($script:WmLogBuffer | ForEach-Object { $_.Line })
    if ($all.Count -le $Lines) { return ($all -join "`n") }
    return ($all[($all.Count - $Lines)..($all.Count - 1)] -join "`n")
}

# ---------------------------------------------------------------------------
# Blokada przed równoległym uruchomieniem (provisioning i zadanie)
# ---------------------------------------------------------------------------

function Enter-WmLock {
    $m = New-Object System.Threading.Mutex($false, $script:WmMutexName)
    try {
        if ($m.WaitOne(0)) { return $m }
    } catch [System.Threading.AbandonedMutexException] {
        return $m   # poprzedni proces padł, ale blokada jest nasza
    }
    $m.Dispose()
    return $null
}

function Exit-WmLock {
    param($Mutex)
    if ($Mutex) {
        try { $Mutex.ReleaseMutex() } catch { }
        $Mutex.Dispose()
    }
}

# ---------------------------------------------------------------------------
# Rejestr
# ---------------------------------------------------------------------------

function Set-WmRegValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Value,
        [ValidateSet('DWord', 'QWord', 'String', 'ExpandString')][string]$Type = 'DWord'
    )
    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
        return $true
    } catch {
        Write-WmLog "Nie udało się ustawić $Path\$Name : $($_.Exception.Message)" -Level warn
        return $false
    }
}

function Remove-WmRegValue {
    param([string]$Path, [string]$Name)
    if (Test-Path -LiteralPath $Path) {
        Remove-ItemProperty -LiteralPath $Path -Name $Name -Force -ErrorAction SilentlyContinue
    }
}

# Wykonuje $Action dla rejestru każdego profilu użytkownika oraz profilu domyślnego.
# $Action dostaje korzeń w postaci 'Registry::HKEY_USERS\<...>' (odpowiednik HKCU).
function Invoke-WmForEachUserHive {
    param([Parameter(Mandatory = $true)][scriptblock]$Action)

    $targets = @()
    $profiles = Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue |
        Where-Object { -not $_.Special -and $_.LocalPath -and $_.SID -like 'S-1-5-21-*' }
    foreach ($p in $profiles) {
        $dat = Join-Path $p.LocalPath 'NTUSER.DAT'
        if (Test-Path -LiteralPath $dat) {
            $targets += [pscustomobject]@{ Name = $p.LocalPath; Sid = $p.SID; Dat = $dat }
        }
    }
    $defaultDat = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
    if (Test-Path -LiteralPath $defaultDat) {
        $targets += [pscustomobject]@{ Name = 'Default'; Sid = $null; Dat = $defaultDat }
    }

    foreach ($t in $targets) {
        $mount = $null
        if ($t.Sid -and (Test-Path -LiteralPath "Registry::HKEY_USERS\$($t.Sid)")) {
            $root = "Registry::HKEY_USERS\$($t.Sid)"      # profil zalogowany, rejestr już wczytany
        } else {
            $mount = 'WM_' + ($t.Name -replace '[^A-Za-z0-9]', '_')
            & reg.exe load "HKU\$mount" "$($t.Dat)" 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-WmLog "Nie mogę wczytać rejestru profilu $($t.Name)" -Level warn
                continue
            }
            $root = "Registry::HKEY_USERS\$mount"
        }
        try {
            & $Action $root $t.Name
        } catch {
            Write-WmLog "Błąd przy profilu $($t.Name): $($_.Exception.Message)" -Level warn
        } finally {
            if ($mount) {
                [GC]::Collect()
                [GC]::WaitForPendingFinalizers()
                & reg.exe unload "HKU\$mount" 2>&1 | Out-Null
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Uprawnienia do folderu wmanager
# ---------------------------------------------------------------------------

# Folder: zapis tylko SYSTEM i Administrators, Users mogą czytać i uruchamiać.
# Plik konfiguracji (tokeny): tylko SYSTEM i Administrators.
function Set-WmFolderAcl {
    param([Parameter(Mandatory = $true)][string]$Path, [string]$ConfigFile)
    & icacls.exe "$Path" /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /T /C /Q 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-WmLog "icacls zwrócił $LASTEXITCODE dla $Path" -Level warn }
    if ($ConfigFile -and (Test-Path -LiteralPath $ConfigFile)) {
        & icacls.exe "$ConfigFile" /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' /C /Q 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-WmLog "icacls zwrócił $LASTEXITCODE dla $ConfigFile" -Level warn }
    }
}

# ---------------------------------------------------------------------------
# Restart
# ---------------------------------------------------------------------------

function Test-WmPendingReboot {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($k in $keys) { if (Test-Path -LiteralPath $k) { return $true } }
    $sm = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
    if ($sm -and $sm.PendingFileRenameOperations) { return $true }
    $active  = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -ErrorAction SilentlyContinue).ComputerName
    $pending = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -ErrorAction SilentlyContinue).ComputerName
    if ($active -and $pending -and $active -ne $pending) { return $true }
    return $false
}

function Get-WmBootTime {
    return (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
}

# Znacznik "potrzebny restart" z czasem bieżącego startu systemu.
# Po restarcie czas startu się zmienia, więc znacznik przestaje obowiązywać.
function Set-WmRebootFlag {
    New-Item -ItemType Directory -Force -Path $script:WmStateDir | Out-Null
    Set-Content -LiteralPath $script:WmRebootFlag -Value (Get-WmBootTime) -Encoding ASCII
}

function Clear-WmStaleRebootFlag {
    if (Test-Path -LiteralPath $script:WmRebootFlag) {
        $saved = (Get-Content -LiteralPath $script:WmRebootFlag -Raw).Trim()
        if ($saved -ne (Get-WmBootTime)) { Remove-Item -LiteralPath $script:WmRebootFlag -Force -ErrorAction SilentlyContinue }
    }
}

# ---------------------------------------------------------------------------
# JSON (ręcznie, bo ConvertTo-Json w 5.1 potrafi źle zapisać zagnieżdżone tablice)
# ---------------------------------------------------------------------------

function ConvertTo-WmJsonString {
    param([AllowEmptyString()][string]$Text)
    $s = $Text.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
    $s = [regex]::Replace($s, '[\x00-\x1f]', '')
    return '"' + $s + '"'
}

# ---------------------------------------------------------------------------
# Grafana Cloud Loki
# ---------------------------------------------------------------------------

function Send-WmLokiLog {
    param([Parameter(Mandatory = $true)][hashtable]$Config)

    $url   = Get-WmSetting $Config 'LokiUrl' ''
    $user  = Get-WmSetting $Config 'LokiUser' ''
    $token = Get-WmSetting $Config 'LokiToken' ''
    if (-not $url -or -not $token) { return }
    if ($url -notmatch '/loki/api/v1/push$') { $url = $url.TrimEnd('/') + '/loki/api/v1/push' }

    $outbox = Join-Path $script:WmLogDir 'outbox'
    New-Item -ItemType Directory -Force -Path $outbox | Out-Null

    # Bieżący przebieg -> plik w outbox (wysyłany razem z zaległymi)
    if ($script:WmLogBuffer.Count -gt 0) {
        $hostLabel = $script:WmHostName.ToLower()
        $streams = New-Object System.Collections.Generic.List[string]
        $i = 0
        foreach ($level in @('info', 'warn', 'error')) {
            $entries = @($script:WmLogBuffer | Where-Object { $_.Level -eq $level })
            if ($entries.Count -eq 0) { continue }
            $values = New-Object System.Collections.Generic.List[string]
            foreach ($e in $entries) {
                # nanosekundy; +$i zapewnia unikalność i kolejność w obrębie milisekundy
                $ns = ([DateTimeOffset]$e.Time).ToUnixTimeMilliseconds() * 1000000 + $i
                $i++
                $values.Add('[' + (ConvertTo-WmJsonString ([string]$ns)) + ',' + (ConvertTo-WmJsonString $e.Line) + ']')
            }
            $labels = '{"service_name":"wmanager","host":' + (ConvertTo-WmJsonString $hostLabel) +
                      ',"job":' + (ConvertTo-WmJsonString $script:WmJob) +
                      ',"level":' + (ConvertTo-WmJsonString $level) + '}'
            $streams.Add('{"stream":' + $labels + ',"values":[' + ($values -join ',') + ']}')
        }
        $json = '{"streams":[' + ($streams -join ',') + ']}'
        $file = Join-Path $outbox ('{0}-{1}.json' -f (Get-Date -Format 'yyyyMMddHHmmssfff'), $script:WmJob)
        [IO.File]::WriteAllText($file, $json, (New-Object System.Text.UTF8Encoding($false)))
    }

    $pair = '{0}:{1}' -f $user, $token
    $headers = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair)) }

    foreach ($f in (Get-ChildItem -LiteralPath $outbox -Filter '*.json' -File | Sort-Object Name)) {
        try {
            $body = [IO.File]::ReadAllBytes($f.FullName)
            Invoke-RestMethod -Uri $url -Method Post -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 30 -UseBasicParsing | Out-Null
            Remove-Item -LiteralPath $f.FullName -Force
        } catch {
            $msg = "Wysyłka do Loki nie powiodła się ($($f.Name)), spróbuję przy następnym przebiegu: $($_.Exception.Message)"
            Write-Host $msg -ForegroundColor Yellow
            if ($script:WmLogFile) { Add-Content -LiteralPath $script:WmLogFile -Value $msg -Encoding UTF8 }
            break
        }
    }

    # Zaległości starsze niż 30 dni nie mają już sensu
    Get-ChildItem -LiteralPath $outbox -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Healthchecks.io
# ---------------------------------------------------------------------------

function Send-WmHealthcheck {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][ValidateSet('start', 'success', 'fail')][string]$Signal,
        [string]$Body = ''
    )
    $key = Get-WmSetting $Config 'HealthchecksPingKey' ''
    if (-not $key) { return }
    $base   = (Get-WmSetting $Config 'HealthchecksBaseUrl' 'https://hc-ping.com').TrimEnd('/')
    $prefix = Get-WmSetting $Config 'HealthchecksSlugPrefix' ''
    $slug   = ($prefix + $script:WmHostName).ToLower() -replace '[^a-z0-9_-]', '-'
    $suffix = ''
    if ($Signal -eq 'start') { $suffix = '/start' }
    if ($Signal -eq 'fail')  { $suffix = '/fail' }
    $url = '{0}/{1}/{2}{3}?create=1' -f $base, $key, $slug, $suffix
    if ($Body.Length -gt 90000) { $Body = $Body.Substring($Body.Length - 90000) }
    try {
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Body)
        Invoke-RestMethod -Uri $url -Method Post -Body $bytes -ContentType 'text/plain; charset=utf-8' -TimeoutSec 15 -UseBasicParsing | Out-Null
    } catch {
        $msg = "Ping Healthchecks ($Signal) nie powiódł się: $($_.Exception.Message)"
        Write-Host $msg -ForegroundColor Yellow
        if ($script:WmLogFile) { Add-Content -LiteralPath $script:WmLogFile -Value $msg -Encoding UTF8 }
    }
}
