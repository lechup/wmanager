# Shared functions: paths, configuration, logs, registry, Loki, Healthchecks.
# Compatible with Windows PowerShell 5.1.

$script:WmRoot       = Join-Path $env:ProgramData 'wmanager'
$script:WmStateDir   = Join-Path $script:WmRoot 'state'
$script:WmLogDir     = Join-Path $script:WmRoot 'logs'
$script:WmLogFile    = $null
$script:WmJob        = 'provision'
$script:WmHostName   = $env:COMPUTERNAME
$script:WmWarnings   = 0
$script:WmErrors     = 0
$script:WmLogBuffer  = New-Object 'System.Collections.Generic.List[object]'

$script:WmRebootKey   = 'SOFTWARE\wmanager\RebootRequired'   # under HKLM, volatile
$script:WmRetryFlag   = Join-Path $script:WmStateDir 'retry-pending.flag'
$script:WmPublicState = Join-Path $script:WmStateDir 'public.json'
$script:WmMutexName   = 'Global\wmanager-run'

$script:WmBackupDir   = Join-Path $script:WmStateDir 'backup'
$script:WmManagedDir  = Join-Path $script:WmStateDir 'managed'   # verified copy of the management source (lib\Managed.ps1)
$script:WmJournalFile = Join-Path $script:WmBackupDir 'journal.jsonl'
$script:WmJournalOn   = $false  # undo journal records only during provisioning (see lib\Backup.ps1)
$script:WmJournalSeen = @{}     # value id -> $true
$script:WmJournalKeys = @{}     # key id -> state of the key before wmanager first touched it
$script:WmHiveContext = $null   # the user hive Invoke-WmForEachUserHive is working on

# PowerShell 5.1 doesn't enable TLS 1.2 by default
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# ---------------------------------------------------------------------------
# Configuration
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

# The Management section (computer groups, see lib\Managed.ps1), or $null when no source is set.
# Throws when the source is neither an https:// address nor a full folder path, or SourceId is missing.
function Get-WmManagementSettings {
    param([Parameter(Mandatory = $true)][hashtable]$Config)
    $m = Get-WmSetting $Config 'Management' $null
    if (-not ($m -is [hashtable]) -or -not $m.Source) { return $null }
    $src = [string]$m.Source
    if ($src -match '^[A-Za-z][A-Za-z0-9+.-]*://') {
        if ($src -notmatch '^https://') { throw "Management.Source: dozwolony jest tylko adres https:// ('$src')" }
    } elseif (-not [IO.Path]::IsPathRooted($src)) {
        throw "Management.Source: folder trzeba podać pełną ścieżką ('$src')"
    }
    if ([string]$m.SourceId -notmatch '^[A-Za-z0-9._-]{8,64}$') {
        throw 'Management.SourceId: brak albo niepoprawny identyfikator źródła (zapisuje go tools/publish.sh w source-id.txt)'
    }
    return $m
}

# File name of the public signing certificate, kept next to the configuration file; $null without a management source.
function Get-WmCertificateFileName {
    param([Parameter(Mandatory = $true)][hashtable]$Config)
    $m = Get-WmManagementSettings $Config
    if (-not $m) { return $null }
    $name = [string]$m.Certificate
    if (-not $name) { $name = 'wmanager-signing.cer' }
    if ($name -ne (Split-Path $name -Leaf)) { throw "Management.Certificate: sama nazwa pliku obok pliku konfiguracji, bez ścieżki ('$name')" }
    return $name
}

# ---------------------------------------------------------------------------
# Logs
# ---------------------------------------------------------------------------

# -Daily: one file per day (the hourly job run), instead of one per run.
function Initialize-WmLog {
    param([Parameter(Mandatory = $true)][string]$Job, [switch]$Daily)
    $script:WmJob = $Job
    New-Item -ItemType Directory -Force -Path $script:WmLogDir | Out-Null
    $stamp = if ($Daily) { Get-Date -Format 'yyyy-MM-dd' } else { Get-Date -Format 'yyyy-MM-dd_HHmm' }
    $script:WmLogFile = Join-Path $script:WmLogDir ("{0}-{1}.log" -f $Job, $stamp)
}

function Write-WmLog {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message,
        [ValidateSet('info', 'warn', 'error')][string]$Level = 'info',
        # Local file only (e.g. full choco output), not sent to Loki
        [switch]$LocalOnly,
        # Group job the entry belongs to: the 'task' label in Loki
        [string]$Task = '',
        # To Loki without the time and level prefix (job output, e.g. JSON lines)
        [switch]$Raw
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
        $lokiLine = if ($Raw) { $Message } else { $line }
        $script:WmLogBuffer.Add([pscustomobject]@{ Time = $ts; Level = $Level; Line = $lokiLine; Task = $Task })
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
# Network
# ---------------------------------------------------------------------------

# Servers the run needs: the Chocolatey install script, the enabled package sources, and the management
# source (or, without one, the package-list URLs). Returns the hosts that did not answer at all
# (empty = online). Any HTTP answer, even an error status, counts as reachable.
function Get-WmUnreachableHosts {
    param([Parameter(Mandatory = $true)][hashtable]$Config)
    $urls = @(Get-WmSetting $Config 'ChocolateyInstallUrl' 'https://community.chocolatey.org/install.ps1')
    foreach ($s in @(Get-WmSetting $Config 'ChocolateySources' @())) {
        if ($s.Url -and $s.Enabled -ne $false) { $urls += $s.Url }
    }
    $mg = $null
    try { $mg = Get-WmManagementSettings $Config } catch { }   # an invalid setting is reported by the stage using it
    if ($mg) {
        if ([string]$mg.Source -match '^https://') { $urls += [string]$mg.Source }
    } else {
        foreach ($s in @(Get-WmSetting $Config 'ReqsSources' @())) {
            if ($s -match '^https?://') { $urls += $s }
        }
    }
    $bad = @()
    $checked = @{}
    foreach ($u in $urls) {
        try { $uri = [uri]$u } catch { continue }
        $origin = $uri.GetLeftPart([UriPartial]::Authority)
        if ($checked.ContainsKey($origin)) { continue }
        $checked[$origin] = $true
        try {
            Invoke-WebRequest -Uri $origin -Method Head -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop | Out-Null
        } catch {
            if (-not $_.Exception.Response) { $bad += $uri.Host }
        }
    }
    return $bad
}

# ---------------------------------------------------------------------------
# Stages
# ---------------------------------------------------------------------------

# Runs one stage. An exception is logged as an error (so the run reports a failure),
# but the stages after it still run. Returns $true when the stage finished without one.
function Invoke-WmStep {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][scriptblock]$Action)
    try {
        $null = & $Action
        return $true
    } catch {
        Write-WmLog "Etap '$Name' przerwany: $($_.Exception.Message)" -Level error
        return $false
    }
}

# ---------------------------------------------------------------------------
# Lock against concurrent runs (provisioning and the scheduled task)
# ---------------------------------------------------------------------------

function Enter-WmLock {
    $m = New-Object System.Threading.Mutex($false, $script:WmMutexName)
    try {
        if ($m.WaitOne(0)) { return $m }
    } catch [System.Threading.AbandonedMutexException] {
        return $m   # the previous process died, but the lock is ours
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
# Registry
# ---------------------------------------------------------------------------

# 'HKLM:\X' or 'Registry::HKEY_USERS\Y' -> 'HKEY_LOCAL_MACHINE\X' or 'HKEY_USERS\Y'
function ConvertTo-WmRegNativePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $p = $Path -replace '^Registry::', ''
    $p = $p -replace '^HKLM:\\?', 'HKEY_LOCAL_MACHINE\'
    return $p.TrimEnd('\')
}

# Opens a key with the .NET API: read-only, -Writable, or -Create (creates missing keys). $null if missing.
function Open-WmRegKey {
    param([Parameter(Mandatory = $true)][string]$Path, [switch]$Writable, [switch]$Create)
    $hive, $sub = (ConvertTo-WmRegNativePath $Path) -split '\\', 2
    $base = switch ($hive) {
        'HKEY_LOCAL_MACHINE' { [Microsoft.Win32.Registry]::LocalMachine }
        'HKEY_USERS'         { [Microsoft.Win32.Registry]::Users }
        default              { throw "Nieobsługiwana gałąź rejestru: $hive" }
    }
    if ($Create) { return $base.CreateSubKey($sub) }
    return $base.OpenSubKey($sub, [bool]$Writable)
}

function Get-WmJournalId {
    param($Scope, $Sid, $ProfileName, $Key, $Name)
    $who = if ($Sid) { $Sid } else { $ProfileName }
    return ('{0}|{1}|{2}|{3}' -f $Scope, $who, $Key, $Name).ToLowerInvariant()
}

# The nearest existing parent of a key that does not exist (native path).
function Get-WmExistingAncestor {
    param([Parameter(Mandatory = $true)][string]$NativePath)
    $p = $NativePath
    while ($p.LastIndexOf('\') -gt 0) {
        $p = $p.Substring(0, $p.LastIndexOf('\'))
        if ($p.IndexOf('\') -lt 0) { break }   # hive root
        $k = Open-WmRegKey -Path $p
        if ($k) { $k.Close(); return $p }
    }
    return $p
}

# Undo journal: before wmanager changes a registry value for the first time, the previous state
# (value and type, or "did not exist") is appended to journal.jsonl right away, one JSON line per
# value, so an interrupted run loses nothing. Values in user hives are stored relative to the hive,
# with the profile's SID and path. For a key that did not exist, Ancestor is its nearest existing
# parent: Restore-Backup.ps1 removes the keys wmanager created up to there, if they are empty.
# If the old state can't be read, no entry is written (a wrong entry would make restore delete data).
function Add-WmJournalEntry {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Name)
    if (-not $script:WmJournalOn) { return }
    $native = ConvertTo-WmRegNativePath $Path
    $scope = 'machine'; $sid = ''; $profileName = ''; $key = $native; $hiveRoot = ''
    $ctx = $script:WmHiveContext
    if ($ctx) {
        $root = ConvertTo-WmRegNativePath $ctx.Root
        if ($native.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
            $scope = 'user'; $sid = [string]$ctx.Sid; $profileName = [string]$ctx.Profile; $hiveRoot = $root
            $key = $native.Substring($root.Length + 1)
        }
    }
    $id = Get-WmJournalId $scope $sid $profileName $key $Name
    if ($script:WmJournalSeen.ContainsKey($id)) { return }
    $keyId = Get-WmJournalId $scope $sid $profileName $key ''

    $entry = [ordered]@{ Scope = $scope; Sid = $sid; Profile = $profileName; Key = $key; Name = $Name
                         KeyExisted = $true; Ancestor = ''; Existed = $false; Kind = ''; Value = $null }
    $k = $null
    try {
        $k = Open-WmRegKey -Path $native
        # The key's state is taken once, before wmanager's first change in it
        if (-not $script:WmJournalKeys.ContainsKey($keyId)) {
            $state = @{ Existed = [bool]$k; Ancestor = '' }
            if (-not $k) {
                $anc = Get-WmExistingAncestor $native
                if ($hiveRoot) { $anc = $anc.Substring([Math]::Min($anc.Length, $hiveRoot.Length)).TrimStart('\') }
                $state.Ancestor = $anc
            }
            $script:WmJournalKeys[$keyId] = $state
        }
        $entry.KeyExisted = $script:WmJournalKeys[$keyId].Existed
        $entry.Ancestor = $script:WmJournalKeys[$keyId].Ancestor
        if ($k -and ($k.GetValueNames() -contains $Name)) {
            $kind = $k.GetValueKind($Name)
            $raw = $k.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $entry.Existed = $true
            $entry.Kind = [string]$kind
            if ($kind -eq 'Binary') { $entry.Value = [Convert]::ToBase64String([byte[]]$raw) }
            elseif ($kind -eq 'MultiString') { $entry.Value = [string[]]$raw }
            else { $entry.Value = [string]$raw }
        }
        $line = ConvertTo-Json -InputObject ([pscustomobject]$entry) -Compress -Depth 4
        [IO.File]::AppendAllText($script:WmJournalFile, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
        $script:WmJournalSeen[$id] = $true
    } catch {
        Write-WmLog "Dziennik zmian: nie zapisano stanu $native\$Name (przywracanie go nie cofnie): $($_.Exception.Message)" -Level warn
    } finally {
        if ($k) { $k.Close() }
    }
}

# -OnError info: for keys that are sometimes protected, where access denied is expected.
function Set-WmRegValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Value,
        [ValidateSet('DWord', 'QWord', 'String', 'ExpandString')][string]$Type = 'DWord',
        [ValidateSet('warn', 'info')][string]$OnError = 'warn'
    )
    Add-WmJournalEntry -Path $Path -Name $Name
    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
        return $true
    } catch {
        Write-WmLog "Nie udało się ustawić $Path\$Name : $($_.Exception.Message)" -Level $OnError
        return $false
    }
}

function Remove-WmRegValue {
    param([string]$Path, [string]$Name)
    if ($null -ne (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue)) {
        Add-WmJournalEntry -Path $Path -Name $Name
        Remove-ItemProperty -LiteralPath $Path -Name $Name -Force -ErrorAction SilentlyContinue
    }
}

# Runs $Action against the registry of every user profile and the default profile.
# $Action receives the root as 'Registry::HKEY_USERS\<...>' (the HKCU equivalent), the profile path
# ('Default' for the default profile) and the SID ($null for the default profile).
# Local and domain accounts have SIDs S-1-5-21-*, Entra ID (Azure AD) accounts S-1-12-1-*.
# User profiles that could not be processed are left in $script:WmHiveSkipped.
function Invoke-WmForEachUserHive {
    param([Parameter(Mandatory = $true)][scriptblock]$Action)

    $script:WmHiveSkipped = @()
    $targets = @()
    $profiles = Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue |
        Where-Object { -not $_.Special -and $_.LocalPath -and ($_.SID -like 'S-1-5-21-*' -or $_.SID -like 'S-1-12-1-*') }
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
            $root = "Registry::HKEY_USERS\$($t.Sid)"      # signed-in profile, hive already loaded
        } else {
            $mount = 'WM_' + ($t.Name -replace '[^A-Za-z0-9]', '_')
            & reg.exe load "HKU\$mount" "$($t.Dat)" 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-WmLog "Nie mogę wczytać rejestru profilu $($t.Name)" -Level warn
                if ($t.Sid) { $script:WmHiveSkipped += $t.Name }
                continue
            }
            $root = "Registry::HKEY_USERS\$mount"
        }
        try {
            $script:WmHiveContext = @{ Root = $root; Profile = $t.Name; Sid = $t.Sid }
            & $Action $root $t.Name $t.Sid
        } catch {
            if ($t.Sid) { $script:WmHiveSkipped += $t.Name }
            Write-WmLog "Błąd przy profilu $($t.Name): $($_.Exception.Message)" -Level warn
        } finally {
            $script:WmHiveContext = $null
            if ($mount) {
                # A leftover handle keeps the hive loaded; a still-loaded Default profile breaks sign-in of new
                # accounts (they get a temporary profile), so retry and report a failure as an error
                $unloaded = $false
                for ($try = 1; $try -le 5 -and -not $unloaded; $try++) {
                    [GC]::Collect()
                    [GC]::WaitForPendingFinalizers()
                    & reg.exe unload "HKU\$mount" 2>&1 | Out-Null
                    $unloaded = ($LASTEXITCODE -eq 0)
                    if (-not $unloaded) { Start-Sleep -Seconds 2 }
                }
                if (-not $unloaded) {
                    Write-WmLog "Nie udało się odłączyć rejestru profilu $($t.Name) (HKU\$mount); pomoże restart komputera." -Level error
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# wmanager folder permissions
# ---------------------------------------------------------------------------

$script:WmAdminSids = @('S-1-5-18', 'S-1-5-32-544')   # SYSTEM, Administrators
$script:WmUsersSid  = 'S-1-5-32-545'

# Replaces the whole ACL with explicit entries only (nothing inherited from the parent):
# Full Control for $FullControl, Read & Execute for $ReadExecute. On a folder the entries apply to its contents.
function Set-WmExplicitAcl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$FullControl = $script:WmAdminSids,
        [string[]]$ReadExecute = @()
    )
    $isDir = Test-Path -LiteralPath $Path -PathType Container
    $acl = New-WmExplicitAcl -Directory:$isDir -FullControl $FullControl -ReadExecute $ReadExecute
    if ($isDir) { [IO.Directory]::SetAccessControl($Path, $acl) } else { [IO.File]::SetAccessControl($Path, $acl) }
}

# The security descriptor used by Set-WmExplicitAcl (also for creating a folder with it directly).
function New-WmExplicitAcl {
    param([switch]$Directory, [string[]]$FullControl = $script:WmAdminSids, [string[]]$ReadExecute = @())
    $isDir = [bool]$Directory
    if ($isDir) {
        $acl = New-Object System.Security.AccessControl.DirectorySecurity
        $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    } else {
        $acl = New-Object System.Security.AccessControl.FileSecurity
        $inherit = [System.Security.AccessControl.InheritanceFlags]::None
    }
    $acl.SetAccessRuleProtection($true, $false)
    $grants = @()
    foreach ($s in $FullControl) { $grants += ,@($s, [System.Security.AccessControl.FileSystemRights]::FullControl) }
    foreach ($s in $ReadExecute) { $grants += ,@($s, [System.Security.AccessControl.FileSystemRights]::ReadAndExecute) }
    foreach ($g in $grants) {
        $sid = New-Object System.Security.Principal.SecurityIdentifier($g[0])
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, $g[1], $inherit,
                    [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
    }
    return $acl
}

# SIDs other than $Allowed that have any Allow entry on the path.
function Get-WmUnexpectedAclSids {
    param([Parameter(Mandatory = $true)][string]$Path, [string[]]$Allowed = $script:WmAdminSids)
    $rules = (Get-Acl -LiteralPath $Path).GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])
    return @($rules | Where-Object { $_.AccessControlType -eq 'Allow' -and $Allowed -notcontains $_.IdentityReference.Value } |
             ForEach-Object { $_.IdentityReference.Value } | Select-Object -Unique)
}

# Prepares C:\ProgramData\wmanager before anything is written there. Any user can create folders
# in ProgramData, so an existing folder that is a link or is not owned by SYSTEM/Administrators
# may have been planted (its owner can always change the ACL); it is moved aside, not reused.
function Initialize-WmRoot {
    if (Test-Path -LiteralPath $script:WmRoot) {
        $item = Get-Item -LiteralPath $script:WmRoot -Force
        $reason = $null
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { $reason = 'jest dowiązaniem' }
        elseif (-not $item.PSIsContainer) { $reason = 'nie jest folderem' }
        else {
            $owner = (Get-Acl -LiteralPath $script:WmRoot).GetOwner([System.Security.Principal.SecurityIdentifier]).Value
            if ($script:WmAdminSids -notcontains $owner) { $reason = "ma obcego właściciela ($owner)" }
        }
        if ($reason) {
            $aside = '{0}.untrusted-{1}' -f $script:WmRoot, (Get-Date -Format 'yyyyMMddHHmmss')
            Write-WmLog "$($script:WmRoot) $reason; przenoszę do $aside i tworzę od nowa." -Level warn
            Move-Item -LiteralPath $script:WmRoot -Destination $aside -ErrorAction Stop
            if (Test-Path -LiteralPath (Join-Path $aside 'state\backup')) {
                Write-WmLog "Kopie i dziennik zmian zostały w $aside\state\backup i nie będą używane; Restore-Backup.ps1 nie cofnie wcześniejszych przebiegów." -Level warn
            }
        }
    }
    # A new folder is created with its final ACL in one step, so no user can put anything in it first
    if (-not (Test-Path -LiteralPath $script:WmRoot)) {
        $acl = New-WmExplicitAcl -Directory -ReadExecute @($script:WmUsersSid)
        [IO.Directory]::CreateDirectory($script:WmRoot, $acl) | Out-Null
    }
    New-Item -ItemType Directory -Force -Path $script:WmStateDir, $script:WmLogDir, (Join-Path $script:WmRoot 'lib') -ErrorAction Stop | Out-Null
    # Lock down everything before anything is read from the folder (e.g. the undo journal)
    Set-WmFolderAcl -Path $script:WmRoot
}

# Folder: owned by Administrators; only SYSTEM and Administrators can write; Users can read and execute.
# Everything inside only inherits the folder's ACL (explicit entries are removed).
# Configuration file (tokens), state\backup and state\managed: SYSTEM and Administrators only.
# Checked after setting; a failure is an error.
function Set-WmFolderAcl {
    param([Parameter(Mandatory = $true)][string]$Path, [string]$ConfigFile)
    & icacls.exe "$Path" /setowner '*S-1-5-32-544' /T /C /Q 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-WmLog "icacls /setowner zwrócił $LASTEXITCODE dla $Path" -Level warn }
    try {
        Set-WmExplicitAcl -Path $Path -ReadExecute @($script:WmUsersSid)
    } catch {
        Write-WmLog "Nie udało się ustawić uprawnień $Path : $($_.Exception.Message)" -Level error
    }
    & icacls.exe (Join-Path $Path '*') /reset /T /C /Q 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-WmLog "icacls /reset zwrócił $LASTEXITCODE dla $Path" -Level warn }
    # Private: the config (tokens), the backups (other users' settings), the management copy (group scripts)
    foreach ($private in @($ConfigFile, (Join-Path $Path 'provision.config.psd1'), $script:WmBackupDir, $script:WmManagedDir) | Select-Object -Unique) {
        if (-not $private -or -not (Test-Path -LiteralPath $private)) { continue }
        try {
            Set-WmExplicitAcl -Path $private
            $extra = @(Get-WmUnexpectedAclSids -Path $private)
            if ($extra.Count -gt 0) { throw "dostęp mają też: $($extra -join ', ')" }
        } catch {
            Write-WmLog "Nie udało się zabezpieczyć $private : $($_.Exception.Message)" -Level error
        }
    }
}

# ---------------------------------------------------------------------------
# Console
# ---------------------------------------------------------------------------

function Test-WmInteractive {
    if (-not [Environment]::UserInteractive) { return $false }
    if ([Environment]::GetCommandLineArgs() | Where-Object { $_ -match '^-NonI' }) { return $false }
    try { if ([Console]::IsInputRedirected) { return $false } } catch { return $false }
    return $true
}

# Yes/no question at the console. Enter, or no console at all, gives the default (no, unless -DefaultYes).
function Confirm-WmContinue {
    param([Parameter(Mandatory = $true)][string]$Question, [switch]$DefaultYes)
    if (-not (Test-WmInteractive)) { return [bool]$DefaultYes }
    $hint = if ($DefaultYes) { '[T/n]' } else { '[t/N]' }
    $answer = (Read-Host "$Question $hint").Trim()
    if (-not $answer) { return [bool]$DefaultYes }
    return ($answer -match '^(t|tak|y|yes)$')
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

# "Restart needed" flag: a volatile registry key. Windows keeps volatile keys only in memory,
# so the flag disappears by itself at the next restart. (Comparing boot times was unreliable:
# Windows shifts the reported boot time when the clock is corrected, e.g. after sleep.)
# Notify-User.ps1 checks the same key. Users can read it (HKLM\SOFTWARE permissions).
function Set-WmRebootFlag {
    $lm = [Microsoft.Win32.Registry]::LocalMachine
    # The parent must not be volatile (CreateSubKey would create missing parents with the same option)
    $lm.CreateSubKey((Split-Path $script:WmRebootKey -Parent)).Close()
    $k = $lm.CreateSubKey($script:WmRebootKey, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
                          [Microsoft.Win32.RegistryOptions]::Volatile)
    try { $k.SetValue('Since', (Get-Date).ToString('o')) } finally { $k.Close() }
}

# ---------------------------------------------------------------------------
# JSON (built by hand, because ConvertTo-Json in 5.1 can mangle nested arrays)
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

    # Current run -> a file in outbox (sent together with the backlog)
    if ($script:WmLogBuffer.Count -gt 0) {
        $hostLabel = $script:WmHostName.ToLower()
        $streams = New-Object System.Collections.Generic.List[string]
        $i = 0
        # One stream per level and job (entries outside jobs have no task label)
        $tasks = @($script:WmLogBuffer | ForEach-Object { [string]$_.Task } | Sort-Object -Unique)
        foreach ($level in @('info', 'warn', 'error')) {
            foreach ($task in $tasks) {
                $entries = @($script:WmLogBuffer | Where-Object { $_.Level -eq $level -and [string]$_.Task -eq $task })
                if ($entries.Count -eq 0) { continue }
                $values = New-Object System.Collections.Generic.List[string]
                foreach ($e in $entries) {
                    # nanoseconds; +$i keeps entries unique and ordered within a millisecond
                    $ns = ([DateTimeOffset]$e.Time).ToUnixTimeMilliseconds() * 1000000 + $i
                    $i++
                    $values.Add('[' + (ConvertTo-WmJsonString ([string]$ns)) + ',' + (ConvertTo-WmJsonString $e.Line) + ']')
                }
                $labels = '{"service_name":"wmanager","host":' + (ConvertTo-WmJsonString $hostLabel) +
                          ',"job":' + (ConvertTo-WmJsonString $script:WmJob) +
                          ',"level":' + (ConvertTo-WmJsonString $level)
                if ($task) { $labels += ',"task":' + (ConvertTo-WmJsonString $task) }
                $labels += '}'
                $streams.Add('{"stream":' + $labels + ',"values":[' + ($values -join ',') + ']}')
            }
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
            $err = $_
            $status = 0
            if ($err.Exception.Response) { try { $status = [int]$err.Exception.Response.StatusCode } catch { } }
            if ($status -eq 400 -or $status -eq 413) {
                # Loki will never accept this batch (e.g. entries too old, too large): move it aside
                # so newer batches are not stuck behind it. Other errors (auth, 429, 5xx, network) keep the queue.
                $rejected = Join-Path $outbox 'rejected'
                New-Item -ItemType Directory -Force -Path $rejected | Out-Null
                Move-Item -LiteralPath $f.FullName -Destination $rejected -Force -ErrorAction SilentlyContinue
                $msg = "Loki odrzucił $($f.Name) (HTTP $status), przeniesiono do outbox\rejected: $($err.Exception.Message)"
                Write-Host $msg -ForegroundColor Yellow
                if ($script:WmLogFile) { Add-Content -LiteralPath $script:WmLogFile -Value $msg -Encoding UTF8 }
                continue
            }
            $msg = "Wysyłka do Loki nie powiodła się ($($f.Name)), spróbuję przy następnym przebiegu: $($err.Exception.Message)"
            Write-Host $msg -ForegroundColor Yellow
            if ($script:WmLogFile) { Add-Content -LiteralPath $script:WmLogFile -Value $msg -Encoding UTF8 }
            break
        }
    }

    # Backlog older than 30 days is no longer worth sending
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
