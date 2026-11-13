# Backup before provisioning, and the undo journal used by Restore-Backup.ps1.
#
# Each provisioning run writes state\backup\<date>\ (only the first and the latest are kept):
#   appx-installed.csv, appx-provisioned.csv   Store apps before debloat
#   default-associations.xml                   default apps for new accounts (DISM export)
#   machine-NN.reg, user-<profile>-NN.reg      registry branches debloat and privacy change,
#                                              for a person to look at (user files use HKEY_CURRENT_USER)
#   manifest.txt                               which key went to which file, or that it did not exist
# The undo journal state\backup\journal.json is shared by all runs: for every registry value
# wmanager changed, the state before the very first change (see Add-WmJournalEntry in Common.ps1).
# Keep the key lists below in sync with lib\Debloat.ps1 and lib\Privacy.ps1.

$script:WmBackupMachineKeys = @(
    'HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft'
    'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Communications'
    'HKEY_LOCAL_MACHINE\SOFTWARE\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}'
    'HKEY_LOCAL_MACHINE\SOFTWARE\Classes\WOW6432Node\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}'
    'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\DiagTrack'
    'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\dmwappushservice'
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
    if (-not (Test-Path -LiteralPath "Registry::$Key")) { return "BRAK      $Key" }
    & reg.exe export $Key $File /y 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { return "BŁĄD      $Key (reg export $LASTEXITCODE)" }
    if ($HiveRoot) {
        $text = [IO.File]::ReadAllText($File)
        $text = [regex]::Replace($text, '(?im)^\[(-?)' + [regex]::Escape($HiveRoot) + '\\', '[${1}HKEY_CURRENT_USER\')
        [IO.File]::WriteAllText($File, $text, [Text.Encoding]::Unicode)
    }
    return "ZAPISANO  $Key -> $(Split-Path $File -Leaf)"
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
    $assoc = Join-Path $dir 'default-associations.xml'
    & dism.exe /Online /Export-DefaultAppAssociations:"$assoc" 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { $manifest.Add('ZAPISANO  domyślne aplikacje -> default-associations.xml') }
    else { $manifest.Add("BŁĄD      domyślne aplikacje (DISM $LASTEXITCODE)") }

    $n = 0
    foreach ($key in $script:WmBackupMachineKeys) {
        $n++
        $manifest.Add((Export-WmRegKey -Key $key -File (Join-Path $dir ('machine-{0:D2}.reg' -f $n))))
    }
    Invoke-WmForEachUserHive {
        param($root, $name, $sid)
        $hive = ConvertTo-WmRegNativePath $root
        $label = (Split-Path $name -Leaf) -replace '[^A-Za-z0-9_-]', '_'
        $m = 0
        foreach ($k in $script:WmBackupUserKeys) {
            $m++
            $file = Join-Path $dir ('user-{0}-{1:D2}.reg' -f $label, $m)
            $manifest.Add((Export-WmRegKey -Key "$hive\$k" -File $file -HiveRoot $hive))
        }
        $manifest.Add("PROFIL    $name -> user-$label-*.reg (SID: $sid)")
    }
    [IO.File]::WriteAllLines((Join-Path $dir 'manifest.txt'), $manifest.ToArray(), (New-Object System.Text.UTF8Encoding($true)))
    foreach ($line in $manifest) { if ($line -like 'BŁĄD*') { Write-WmLog "Kopia: $line" -Level warn } }

    # Keep the first backup (state before the first provisioning) and the latest one
    $all = @(Get-ChildItem -LiteralPath $script:WmBackupDir -Directory | Sort-Object Name)
    if ($all.Count -gt 2) {
        foreach ($old in $all[1..($all.Count - 2)]) {
            Remove-Item -LiteralPath $old.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    return $dir
}

# ---------------------------------------------------------------------------
# Undo journal
# ---------------------------------------------------------------------------

function Read-WmJournal {
    if (-not (Test-Path -LiteralPath $script:WmJournalFile)) { return }
    $json = [IO.File]::ReadAllText($script:WmJournalFile)
    if (-not $json.Trim()) { return }
    $parsed = ConvertFrom-Json -InputObject $json
    return $parsed
}

# Starts recording; entries from earlier runs are kept, so the journal always holds
# the state from before wmanager touched each value for the first time.
function Start-WmJournal {
    $existing = @(Read-WmJournal)
    $script:WmJournal = New-Object 'System.Collections.Generic.List[object]'
    $script:WmJournalSeen = @{}
    foreach ($e in $existing) {
        $script:WmJournalSeen[(Get-WmJournalId $e.Scope $e.Sid $e.Profile $e.Key $e.Name)] = $true
        $script:WmJournal.Add($e)
    }
}

function Save-WmJournal {
    if ($null -eq $script:WmJournal) { return }
    New-Item -ItemType Directory -Force -Path $script:WmBackupDir -ErrorAction Stop | Out-Null
    $json = ConvertTo-Json -InputObject @($script:WmJournal.ToArray()) -Depth 4
    [IO.File]::WriteAllText($script:WmJournalFile, $json, (New-Object System.Text.UTF8Encoding($false)))
    $script:WmJournal = $null
}

# Puts one journal entry back at $KeyPath: the old value, or no value if there was none.
# A key that wmanager created is removed if nothing else is in it. Returns $true on success.
function Restore-WmJournalEntry {
    param([Parameter(Mandatory = $true)]$Entry, [Parameter(Mandatory = $true)][string]$KeyPath)
    $k = $null
    try {
        if ($Entry.Existed) {
            $k = Open-WmRegKey -Path $KeyPath -Create
            $kind = [Microsoft.Win32.RegistryValueKind]$Entry.Kind
            if ($kind -eq 'DWord') { $value = [int]::Parse([string]$Entry.Value) }
            elseif ($kind -eq 'QWord') { $value = [long]::Parse([string]$Entry.Value) }
            elseif ($kind -eq 'Binary') { $value = [Convert]::FromBase64String([string]$Entry.Value) }
            elseif ($kind -eq 'MultiString') { $value = [string[]]@($Entry.Value) }
            else { $value = [string]$Entry.Value }
            $k.SetValue($Entry.Name, $value, $kind)
            return $true
        }
        $k = Open-WmRegKey -Path $KeyPath -Writable
        if (-not $k) { return $true }
        if ($k.GetValueNames() -contains $Entry.Name) { $k.DeleteValue($Entry.Name, $false) }
        $empty = ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0)
        $k.Close(); $k = $null
        if ($empty -and -not $Entry.KeyExisted) {
            $native = ConvertTo-WmRegNativePath $KeyPath
            $cut = $native.LastIndexOf('\')
            $parent = Open-WmRegKey -Path $native.Substring(0, $cut) -Writable
            if ($parent) {
                try { $parent.DeleteSubKey($native.Substring($cut + 1), $false) } finally { $parent.Close() }
            }
        }
        return $true
    } catch {
        Write-WmLog "Nie udało się przywrócić $KeyPath\$($Entry.Name) : $($_.Exception.Message)" -Level warn
        return $false
    } finally {
        if ($k) { $k.Close() }
    }
}
