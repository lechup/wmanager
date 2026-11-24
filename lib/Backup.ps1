# Backup before provisioning, and the undo journal used by Restore-Backup.ps1.
#
# Each provisioning run writes state\backup\<date>\ (only the first, marked with first.txt, and the
# latest are kept):
#   appx-installed.csv, appx-provisioned.csv   Store apps before debloat
#   oem-default-associations.xml or .none      default apps for new accounts (the file DISM import
#                                              writes), or a marker that there were none
#   machine-NN.reg, user-<profile>-NN.reg      registry branches debloat and privacy change,
#                                              for a person to look at (user files use HKEY_CURRENT_USER)
#   manifest.txt                               which key went to which file, or that it did not exist
# The undo journal state\backup\journal.jsonl is shared by all runs: for every registry value
# wmanager changed, the state before the very first change (see Add-WmJournalEntry in Common.ps1).
# Keep the key lists below in sync with lib\Debloat.ps1, lib\Privacy.ps1 and lib\Accounts.ps1.

$script:WmOemAssocFile = Join-Path $env:SystemRoot 'System32\OEMDefaultAssociations.xml'

$script:WmBackupMachineKeys = @(
    'HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft'
    'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Communications'
    'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe'
    'HKEY_LOCAL_MACHINE\SOFTWARE\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}'
    'HKEY_LOCAL_MACHINE\SOFTWARE\Classes\WOW6432Node\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}'
    'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\DiagTrack'
    'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\dmwappushservice'
    'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts'
)

# Relative to each user's hive
$script:WmBackupUserKeys = @(
    'Software\Policies\Microsoft'
    'Software\Microsoft\Windows\CurrentVersion\Run'
    'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    'Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'
    'Software\Microsoft\Windows\CurrentVersion\Privacy'
    'Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement'
    'Software\Microsoft\Windows\CurrentVersion\GameDVR'
    'Software\Microsoft\Windows\CurrentVersion\Search'
    'Software\Microsoft\Windows\CurrentVersion\SearchSettings'
    'Software\Microsoft\Siuf\Rules'
    'System\GameConfigStore'
)

# Exports one key with reg.exe. With -HiveRoot (HKEY_USERS\<id>) the file is rewritten to
# HKEY_CURRENT_USER, so that user can import it. Returns a line for manifest.txt.
function Export-WmRegKey {
    param([Parameter(Mandatory = $true)][string]$Key, [Parameter(Mandatory = $true)][string]$File, [string]$HiveRoot)
    if (-not (Test-Path -LiteralPath "Registry::$Key")) { return "MISSING   $Key" }
    & reg.exe export $Key $File /y 2>&1 | Out-Null
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        Write-WmLog -Key 'backup.reg_export_failed' -Arguments @($Key, $code) -Level warn
        return "ERROR     $Key (reg export $code)"
    }
    if ($HiveRoot) {
        $text = [IO.File]::ReadAllText($File)
        $text = [regex]::Replace($text, '(?im)^\[(-?)' + [regex]::Escape($HiveRoot) + '\\', '[${1}HKEY_CURRENT_USER\')
        [IO.File]::WriteAllText($File, $text, [Text.Encoding]::Unicode)
    }
    return "SAVED     $Key -> $(Split-Path $File -Leaf)"
}

# Writes a new backup folder and returns its path. Throws if the app lists can't be saved.
function Backup-WmState {
    New-Item -ItemType Directory -Force -Path $script:WmBackupDir -ErrorAction Stop | Out-Null
    Set-WmExplicitAcl -Path $script:WmBackupDir   # other users' settings: administrators only
    $dir = Join-Path $script:WmBackupDir (Get-Date -Format 'yyyy-MM-dd_HHmmss')
    New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop | Out-Null

    Get-AppxPackage -AllUsers -ErrorAction Stop |
        Select-Object Name, Version, Architecture, PackageFullName, NonRemovable, SignatureKind |
        Export-Csv -LiteralPath (Join-Path $dir 'appx-installed.csv') -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
    Get-AppxProvisionedPackage -Online -ErrorAction Stop |
        Select-Object DisplayName, Version, PackageName |
        Export-Csv -LiteralPath (Join-Path $dir 'appx-provisioned.csv') -NoTypeInformation -Encoding UTF8 -ErrorAction Stop

    $manifest = New-Object 'System.Collections.Generic.List[string]'
    # Default apps for new accounts: DISM import (used for the default browser) writes this file.
    # (dism /Export-DefaultAppAssociations would export the current user's choices instead.)
    if (Test-Path -LiteralPath $script:WmOemAssocFile) {
        Copy-Item -LiteralPath $script:WmOemAssocFile -Destination (Join-Path $dir 'oem-default-associations.xml') -ErrorAction Stop
        $manifest.Add('SAVED     default apps for new accounts -> oem-default-associations.xml')
    } else {
        [IO.File]::WriteAllText((Join-Path $dir 'oem-default-associations.none'), '')
        $manifest.Add('MISSING   default apps for new accounts (Windows defaults) -> oem-default-associations.none')
    }

    $n = 0
    foreach ($key in $script:WmBackupMachineKeys) {
        $n++
        $manifest.Add((Export-WmRegKey -Key $key -File (Join-Path $dir ('machine-{0:D2}.reg' -f $n))))
    }
    $profileNo = @{ N = 0 }   # numbered, so two profiles with similar folder names never share files
    Invoke-WmForEachUserHive {
        param($root, $name, $sid)
        $hive = ConvertTo-WmRegNativePath $root
        $profileNo.N++
        $label = 'p{0:D2}-{1}' -f $profileNo.N, ((Split-Path $name -Leaf) -replace '[^A-Za-z0-9_-]', '_')
        $m = 0
        foreach ($k in $script:WmBackupUserKeys) {
            $m++
            $file = Join-Path $dir ('user-{0}-{1:D2}.reg' -f $label, $m)
            $manifest.Add((Export-WmRegKey -Key "$hive\$k" -File $file -HiveRoot $hive))
        }
        $manifest.Add("PROFILE   $name -> user-$label-*.reg (SID: $sid)")
    }
    [IO.File]::WriteAllLines((Join-Path $dir 'manifest.txt'), $manifest.ToArray(), (New-Object System.Text.UTF8Encoding($true)))

    # Keep the first backup (state before the first provisioning) and this one. The first is marked
    # with first.txt rather than found by date: the clock of a new computer may be wrong.
    $first = Get-WmFirstBackup
    if (-not $first) {
        [IO.File]::WriteAllText((Join-Path $dir 'first.txt'), '')
        $first = Get-Item -LiteralPath $dir
    }
    foreach ($old in @(Get-ChildItem -LiteralPath $script:WmBackupDir -Directory)) {
        if ($old.FullName -ne $first.FullName -and $old.FullName -ne $dir) {
            Remove-Item -LiteralPath $old.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    return $dir
}

function Get-WmFirstBackup {
    Get-ChildItem -LiteralPath $script:WmBackupDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'first.txt') } | Select-Object -First 1
}

# Default apps for new accounts as in the backup: the saved file again, or the Windows defaults
# if there was none. Does nothing if they did not change since the backup.
function Restore-WmDefaultAssociations {
    param([Parameter(Mandatory = $true)][string]$BackupDir)
    $saved = Join-Path $BackupDir 'oem-default-associations.xml'
    $none  = Join-Path $BackupDir 'oem-default-associations.none'
    $current = $script:WmOemAssocFile
    if (Test-Path -LiteralPath $saved) {
        if ((Test-Path -LiteralPath $current) -and
            (Get-FileHash -LiteralPath $current).Hash -eq (Get-FileHash -LiteralPath $saved).Hash) { return }
        $out = & dism.exe /Online /Import-DefaultAppAssociations:"$saved" 2>&1
    } elseif (Test-Path -LiteralPath $none) {
        if (-not (Test-Path -LiteralPath $current)) { return }
        $out = & dism.exe /Online /Remove-DefaultAppAssociations 2>&1
    } else {
        return
    }
    if ($LASTEXITCODE -eq 0) { Write-WmLog -Key 'backup.default_apps_restored' }
    else { Write-WmLog -Key 'backup.default_apps_restore_failed' -Arguments @($LASTEXITCODE, ($out -join ' ')) -Level warn }
}

# ---------------------------------------------------------------------------
# Undo journal (entries are written by Add-WmJournalEntry in Common.ps1)
# ---------------------------------------------------------------------------

# Reads journal.jsonl. Refuses a file not owned by SYSTEM/Administrators (it drives registry writes
# with admin rights); skips a damaged line (e.g. the last one after a crash).
function Read-WmJournal {
    if (-not (Test-Path -LiteralPath $script:WmJournalFile)) { return }
    $owner = (Get-Acl -LiteralPath $script:WmJournalFile).GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    if ($script:WmAdminSids -notcontains $owner) { throw (New-WmError 'backup.journal_foreign_owner' @($script:WmJournalFile, $owner)) }
    foreach ($line in [IO.File]::ReadAllLines($script:WmJournalFile)) {
        if (-not $line.Trim()) { continue }
        try { ConvertFrom-Json -InputObject $line }
        catch { Write-WmLog -Key 'backup.journal_bad_line' -Level warn }
    }
}

# Starts recording. Entries from earlier runs stay, so the journal always holds the state
# from before wmanager touched each value (and each key) for the first time.
function Start-WmJournal {
    $script:WmJournalSeen = @{}
    $script:WmJournalKeys = @{}
    foreach ($e in @(Read-WmJournal)) {
        $script:WmJournalSeen[(Get-WmJournalId $e.Scope $e.Sid $e.Profile $e.Key $e.Name)] = $true
        $keyId = Get-WmJournalId $e.Scope $e.Sid $e.Profile $e.Key ''
        if (-not $script:WmJournalKeys.ContainsKey($keyId)) {
            $script:WmJournalKeys[$keyId] = @{ Existed = [bool]$e.KeyExisted; Ancestor = [string]$e.Ancestor }
        }
    }
    New-Item -ItemType Directory -Force -Path $script:WmBackupDir -ErrorAction Stop | Out-Null
    if (-not (Test-Path -LiteralPath $script:WmJournalFile)) { [IO.File]::WriteAllText($script:WmJournalFile, '') }
    & icacls.exe "$($script:WmJournalFile)" /setowner '*S-1-5-32-544' /Q 2>&1 | Out-Null
    $script:WmJournalOn = $true
}

function Stop-WmJournal {
    $script:WmJournalOn = $false
}

# Puts one journal entry back: the old value, or no value if there was none. Keys wmanager created
# are removed while empty, up to the nearest key that existed before. $HiveRoot (HKEY_USERS\<id>)
# is the hive of the profile for user entries. Returns $true on success.
function Restore-WmJournalEntry {
    param([Parameter(Mandatory = $true)]$Entry, [string]$HiveRoot = '')
    $keyPath = [string]$Entry.Key
    $stopAt = [string]$Entry.Ancestor
    if ($HiveRoot) {
        $keyPath = "$HiveRoot\$keyPath"
        $stopAt = if ($stopAt) { "$HiveRoot\$stopAt" } else { $HiveRoot }
    }
    $k = $null
    try {
        # Read-only first: a value already in its journaled state needs no write (e.g. a protected value that
        # wmanager couldn't change in the first place, where opening the key for writing is denied)
        $current = Get-WmRegValueState -Path $keyPath -Name ([string]$Entry.Name)
        if ($Entry.Existed) {
            if ($current -and $current.Kind -eq [string]$Entry.Kind -and
                (Test-WmSameJournalValue $current.Value $Entry.Value)) { return $true }
            $k = Open-WmRegKey -Path $keyPath -Create
            $kind = [Microsoft.Win32.RegistryValueKind]$Entry.Kind
            if ($kind -eq 'DWord') { $value = [int]::Parse([string]$Entry.Value) }
            elseif ($kind -eq 'QWord') { $value = [long]::Parse([string]$Entry.Value) }
            elseif ($kind -eq 'Binary') { $value = [Convert]::FromBase64String([string]$Entry.Value) }
            elseif ($kind -eq 'MultiString') { $value = [string[]]@($Entry.Value) }
            else { $value = [string]$Entry.Value }
            $k.SetValue($Entry.Name, $value, $kind)
            return $true
        }
        if ($current) {
            $k = Open-WmRegKey -Path $keyPath -Writable
            if ($k) { $k.DeleteValue($Entry.Name, $false); $k.Close(); $k = $null }   # gone in between: nothing to do
        }
        if (-not $Entry.KeyExisted -and $stopAt) {
            $path = ConvertTo-WmRegNativePath $keyPath
            while ($path.StartsWith($stopAt + '\', [StringComparison]::OrdinalIgnoreCase)) {
                $cut = $path.LastIndexOf('\')
                $node = Open-WmRegKey -Path $path
                if ($node) {
                    $empty = ($node.ValueCount -eq 0 -and $node.SubKeyCount -eq 0)
                    $node.Close()
                    if (-not $empty) { break }
                    $parent = Open-WmRegKey -Path $path.Substring(0, $cut) -Writable
                    if ($parent) { try { $parent.DeleteSubKey($path.Substring($cut + 1), $false) } finally { $parent.Close() } }
                }
                $path = $path.Substring(0, $cut)
            }
        }
        return $true
    } catch {
        Write-WmLog -Key 'backup.value_restore_failed' -Arguments @("$keyPath\$($Entry.Name)", (Get-WmErrorText $_)) -Level warn
        return $false
    } finally {
        if ($k) { $k.Close() }
    }
}
