# Content of a management source without system dependencies: paths, the group map, package lists and how they
# combine, the scripts and jobs of a computer's groups, the wmanager version (version.psd1), computer names. Platform-neutral: lib\Managed.ps1 and
# lib\Choco.ps1 load it on the computers, tools/groups.ps1 on the administrator's machine (also Linux), so both
# read a source the same way. Needs lib\Lang.ps1 (New-WmError). Merge-WmRequirements reports through
# Write-WmManagedNote and Write-WmManagedWarning, which the caller defines.
# Tested in tests\Managed.Tests.ps1, tests\Requirements.Tests.ps1 and tests\Groups.Tests.ps1.

function Test-WmComputerName {
    param([string]$Name)
    # NetBIOS: 1-15 characters, letters/digits/hyphen, not all digits, no hyphen at the start or end
    return ($Name -match '^(?![0-9]+$)[A-Za-z0-9](?:[A-Za-z0-9-]{0,13}[A-Za-z0-9])?$')
}

# A local account name the configuration may give (AdminAccount): up to 20 letters, digits, '.', '-', '_', starting
# with a letter or digit (Windows allows more, but these work in every tool and language)
function Test-WmAccountName {
    param([string]$Name)
    return ($Name -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,19}$' -and $Name -notmatch '\.$')
}

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

function Test-WmGroupName {
    param([AllowEmptyString()][string]$Name)
    return ($Name -match '^[A-Za-z0-9_-][A-Za-z0-9._-]*$' -and (Test-WmManagedPath $Name))
}

# groups.psd1: @{ Default = @('group'); Computers = @{ 'OFFICE-01' = @('group', ...) } }. Throws when invalid.
function Assert-WmGroupMap {
    param([Parameter(Mandatory = $true)][hashtable]$Map)
    foreach ($k in $Map.Keys) {
        if (@('Default', 'Computers') -notcontains $k) { throw (New-WmError 'managed.groups_unknown_key' @($k)) }
    }
    $all = @($Map.Default)
    if ($null -ne $Map.Computers) {
        if (-not ($Map.Computers -is [hashtable])) { throw (New-WmError 'managed.groups_computers_not_table') }
        foreach ($k in $Map.Computers.Keys) {
            if (-not [string]$k) { throw (New-WmError 'managed.groups_empty_computer') }
            $all += @($Map.Computers[$k])
        }
    }
    foreach ($g in $all) {
        if ($null -eq $g) { continue }
        if (-not (Test-WmGroupName ([string]$g))) { throw (New-WmError 'managed.groups_bad_group' @($g)) }
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
                Write-WmManagedNote -Key 'managed.package_group_replaces' -Arguments @($r.Name, $l.Label)
                $merged[$key] = $r
                $from[$key] = $l
            } else {
                Write-WmManagedWarning -Key 'managed.package_conflict' -Arguments @($r.Name, $prev.Label, $l.Label)
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

# The scripts in groups/<group>/<folder>/*.ps1 of the given groups, groups in order, files by name. Name (group/file)
# labels their entries in Loki.
function Get-WmGroupFolderScripts {
    param([Parameter(Mandatory = $true)][hashtable]$Files, [AllowEmptyCollection()][string[]]$Groups = @(),
          [Parameter(Mandatory = $true)][string]$Folder)
    $result = @()
    foreach ($g in $Groups) {
        foreach ($p in (Get-WmManagedScriptPaths -Files $Files -Folder "groups/$g/$Folder/")) {
            $base = [IO.Path]::GetFileNameWithoutExtension($p.Substring($p.LastIndexOf('/') + 1))
            $result += [pscustomobject]@{ Group = $g; Path = $p; Hash = $Files[$p]; Name = "$g/$base" }
        }
    }
    return ,$result
}

# Sign-in scripts: groups/<group>/logon/*.ps1, at every sign-in, as the user who signs in (Invoke-Logon.ps1)
function Get-WmGroupLogonScripts {
    param([Parameter(Mandatory = $true)][hashtable]$Files, [AllowEmptyCollection()][string[]]$Groups = @())
    # (not "return (...)": that would unroll the list, which has to stay one object, also when empty)
    Get-WmGroupFolderScripts -Files $Files -Groups $Groups -Folder 'logon'
}

# Startup scripts: groups/<group>/startup/*.ps1, at every start of the computer, as SYSTEM, before anyone signs in
# (Invoke-Startup.ps1)
function Get-WmGroupStartupScripts {
    param([Parameter(Mandatory = $true)][hashtable]$Files, [AllowEmptyCollection()][string[]]$Groups = @())
    Get-WmGroupFolderScripts -Files $Files -Groups $Groups -Folder 'startup'
}

# Jobs of the given groups: groups/<group>/jobs/hourly|daily|weekly/*.ps1. Name (group/file) labels the
# job's entries in Loki.
function Get-WmGroupJobs {
    param([Parameter(Mandatory = $true)][hashtable]$Files, [AllowEmptyCollection()][string[]]$Groups = @())
    $result = @()
    foreach ($g in $Groups) {
        foreach ($every in @('hourly', 'daily', 'weekly')) {
            foreach ($p in (Get-WmManagedScriptPaths -Files $Files -Folder "groups/$g/jobs/$every/")) {
                $base = [IO.Path]::GetFileNameWithoutExtension($p.Substring($p.LastIndexOf('/') + 1))
                $result += [pscustomobject]@{ Group = $g; Path = $p; Every = $every; Name = "$g/$base"; Hash = $Files[$p] }
            }
        }
    }
    return ,$result
}

# ---------------------------------------------------------------------------
# Secrets for scripts and jobs: Secrets = @{ Name = 'value' } in the company's configuration (on the computer only
# administrators read it). A script or job names the ones it needs in a comment line
#   # wmanager-secrets: ShareUser, SharePassword
# and gets only those, as $env:WMANAGER_SECRET_SHAREUSER... (lib\Managed.ps1).
# ---------------------------------------------------------------------------

# A secret's name: letters, digits and _, starting with a letter, at most 64 characters
function Test-WmSecretName {
    param([string]$Name)
    return ($Name -cmatch '^[A-Za-z][A-Za-z0-9_]{0,63}$')
}

# The secrets a script or job names in its "# wmanager-secrets:" lines (anywhere in the file), each once, as
# written. Throws on a name that isn't one.
function Get-WmScriptSecretNames {
    param([AllowEmptyString()][string]$Text)
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($Text -split "\r?\n")) {
        if ($line -notmatch '^\s*#\s*wmanager-secrets\s*:(.*)$') { continue }
        foreach ($n in @($Matches[1].Trim() -split '[,\s]+' | Where-Object { $_ })) {
            if (-not (Test-WmSecretName $n)) { throw (New-WmError 'managed.secret_name_bad' @($n)) }
            if (-not ($names | Where-Object { $_ -ieq $n })) { $names.Add($n) }
        }
    }
    return ,$names.ToArray()
}

# Who a script or job runs as: 'system' (the default) or 'user', from a comment line "# wmanager-run-as: user"
# (anywhere in the file). As the user it runs in the session of each signed-in person: a script once per person and
# content, a job on its schedule per person. Throws on another value or on more than one such line.
function Get-WmScriptRunAs {
    param([AllowEmptyString()][string]$Text)
    $found = @(foreach ($line in ($Text -split "\r?\n")) {
        if ($line -match '^\s*#\s*wmanager-run-as\s*:(.*)$') { $Matches[1].Trim() }
    })
    if ($found.Count -eq 0) { return 'system' }
    if ($found.Count -gt 1) { throw (New-WmError 'managed.run_as_twice') }
    if (@('user', 'system') -notcontains $found[0].ToLowerInvariant()) { throw (New-WmError 'managed.run_as_bad' @($found[0])) }
    return $found[0].ToLowerInvariant()
}

# ---------------------------------------------------------------------------
# A time for a daily or weekly job: a comment line "# wmanager-at: 18:00" (every day), "Mon-Fri 18:00" or
# "Mon,Wed,Fri 07:30" in jobs/daily, "Fri 17:00" (one day) in jobs/weekly. The job then runs at that time (the
# wmanager-Jobs task gets it as a trigger), or at the next hour the computer is on when it was off then.
# ---------------------------------------------------------------------------

$script:WmWeekDays = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')

# English day names (Mon or Monday, any case), a list (Mon,Wed) or a range (Mon-Fri, also Fri-Mon over the weekend),
# as full names, Monday first; $null for anything else
function ConvertFrom-WmDayList {
    param([string]$Text)
    $index = @{}
    for ($i = 0; $i -lt 7; $i++) { $index[$script:WmWeekDays[$i].Substring(0, 3).ToLowerInvariant()] = $i }
    $pick = New-Object bool[] 7
    foreach ($part in ($Text -split ',')) {
        $ends = @($part.Trim() -split '-')
        if ($ends.Count -gt 2) { return $null }
        $at = @(foreach ($e in $ends) {
            $e = $e.Trim().ToLowerInvariant()
            $key = if ($e.Length -ge 3) { $e.Substring(0, 3) } else { '' }
            if (-not $index.ContainsKey($key) -or -not $script:WmWeekDays[$index[$key]].ToLowerInvariant().StartsWith($e)) { return $null }
            $index[$key]
        })
        $i = $at[0]
        while ($true) { $pick[$i] = $true; if ($i -eq $at[-1]) { break }; $i = ($i + 1) % 7 }
    }
    return @(for ($i = 0; $i -lt 7; $i++) { if ($pick[$i]) { $script:WmWeekDays[$i] } })
}

# The time a job declares: $null without a "# wmanager-at:" line, else Time (HH:mm), Days (full names, Monday first)
# and Text (as written, for the log). $Every: the job's folder. Throws on a line it can't read, a second one, one in an
# hourly job, or a weekly job with other than one day.
function Get-WmJobAt {
    param([AllowEmptyString()][string]$Text, [Parameter(Mandatory = $true)][string]$Every)
    $found = @(foreach ($line in ($Text -split "\r?\n")) {
        if ($line -match '^\s*#\s*wmanager-at\s*:(.*)$') { $Matches[1].Trim() }
    })
    if ($found.Count -eq 0) { return $null }
    if ($found.Count -gt 1) { throw (New-WmError 'managed.at_twice') }
    $at = $found[0]
    if ($Every -eq 'hourly') { throw (New-WmError 'managed.at_hourly') }
    # Days may have spaces around their commas and dashes ("Mon, Wed, Fri 07:30", "Mon - Fri 18:00")
    if ($at -notmatch '^(?:(?<days>.*\S)\s+)?(?<time>[0-9]{1,2}:[0-9]{2})$') { throw (New-WmError 'managed.at_bad' @($at)) }
    $time = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($Matches['time'], 'H:mm', [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None, [ref]$time)) { throw (New-WmError 'managed.at_bad' @($at)) }
    $days = $script:WmWeekDays
    if ($Matches['days']) {
        $days = ConvertFrom-WmDayList $Matches['days']
        if ($null -eq $days -or $days.Count -eq 0) { throw (New-WmError 'managed.at_bad' @($at)) }
    }
    if ($Every -eq 'weekly' -and (-not $Matches['days'] -or @($days).Count -ne 1)) { throw (New-WmError 'managed.at_weekly_day' @($at)) }
    return [pscustomobject]@{ Time = $time.ToString('HH:mm'); Days = @($days); Text = $at }
}

# The Secrets of a configuration, checked: an empty table without the setting. Throws when it isn't a table, a name
# isn't one, or a value isn't text on one line.
function Get-WmSecrets {
    param([Parameter(Mandatory = $true)][hashtable]$Config)
    $s = $Config['Secrets']
    if ($null -eq $s) { return @{} }
    if (-not ($s -is [hashtable])) { throw (New-WmError 'managed.secrets_not_table') }
    foreach ($k in @($s.Keys)) {
        if (-not (Test-WmSecretName ([string]$k))) { throw (New-WmError 'managed.secrets_bad_name' @($k)) }
        $v = $s[$k]
        if (-not ($v -is [string]) -or $v -eq '' -or $v -match '[\r\n]') { throw (New-WmError 'managed.secrets_bad_value' @($k)) }
    }
    return $s
}

# The text with every value replaced by ***, the longest first: what a script prints doesn't put a secret into the
# log or Loki
function Hide-WmSecrets {
    param([AllowEmptyString()][string]$Text, [AllowEmptyCollection()][string[]]$Values = @())
    if (-not $Text) { return $Text }
    foreach ($v in @($Values | Where-Object { $_ } | Sort-Object Length -Descending)) { $Text = $Text.Replace($v, '***') }
    return $Text
}

# Which list a path of the source is: '' for the common choco-reqs.txt, the group for groups/<group>/choco-reqs.txt,
# $null for any other file
function Get-WmListOwner {
    param([string]$Path)
    if ($Path -ieq 'choco-reqs.txt') { return '' }
    if ($Path -match '^groups/([^/]+)/choco-reqs\.txt$') { return $Matches[1] }
    return $null
}

# ---------------------------------------------------------------------------
# version.psd1: the wmanager version the computers of the source run (tools/groups.ps1 set-version writes it)
#   @{ Version = 'v0.2.0'; Url = 'https://.../wmanager-v0.2.0.zip'; Sha256 = '<64 hex>'
#      Groups  = @{ 'test' = @{ Version = ...; Url = ...; Sha256 = ... } } }
# Both parts are optional; a version always comes with the address of its release ZIP and the ZIP's SHA256.
# ---------------------------------------------------------------------------

# A release tag: v1.2.3, optionally with a suffix (v1.2.3-rc1)
function Test-WmReleaseTag {
    param([AllowEmptyString()][string]$Tag)
    return ($Tag.Length -le 64 -and $Tag -match '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$')
}

# Where the computers fetch a release ZIP: an https:// address or a path (C:\..., \\server\share\...)
function Test-WmReleaseUrl {
    param([AllowEmptyString()][string]$Url)
    return ($Url -match '^https://[^\s]+$' -or $Url -match '^[A-Za-z]:\\[^\r\n]+$' -or $Url -match '^\\\\[^\\\s]+\\[^\r\n]+$')
}

# One version entry ($Prefix names it in errors: '' or 'Groups.<group>.')
function ConvertFrom-WmVersionEntry {
    param([Parameter(Mandatory = $true)][hashtable]$Data, [string]$Prefix = '')
    foreach ($k in $Data.Keys) {
        if (@('Version', 'Url', 'Sha256') -notcontains $k) { throw (New-WmError 'managed.version_unknown_key' @("$Prefix$k")) }
    }
    foreach ($k in @('Version', 'Url', 'Sha256')) {
        if (-not $Data.ContainsKey($k) -or -not [string]$Data[$k]) { throw (New-WmError 'managed.version_missing' @("$Prefix$k")) }
    }
    $version = [string]$Data.Version
    $url = [string]$Data.Url
    $sha = [string]$Data.Sha256
    if (-not (Test-WmReleaseTag $version)) { throw (New-WmError 'managed.version_bad_tag' @("${Prefix}Version", $version)) }
    if (-not (Test-WmReleaseUrl $url)) { throw (New-WmError 'managed.version_bad_url' @("${Prefix}Url", $url)) }
    if ($sha -notmatch '^[0-9A-Fa-f]{64}$') { throw (New-WmError 'managed.version_bad_hash' @("${Prefix}Sha256")) }
    return [pscustomobject]@{ Version = $version; Url = $url; Sha256 = $sha.ToUpperInvariant() }
}

# The data of version.psd1, checked. Returns Default (the entry for every computer, or $null) and Groups
# (group -> entry, names compared without regard to case). Throws when invalid.
function ConvertFrom-WmVersionData {
    param([Parameter(Mandatory = $true)][hashtable]$Data)
    $own = @{}
    foreach ($k in $Data.Keys) {
        if ($k -eq 'Groups') { continue }
        if (@('Version', 'Url', 'Sha256') -notcontains $k) { throw (New-WmError 'managed.version_unknown_key' @($k)) }
        $own[$k] = $Data[$k]
    }
    $default = $null
    if ($own.Count -gt 0) { $default = ConvertFrom-WmVersionEntry -Data $own }
    $groups = @{}
    if ($null -ne $Data.Groups) {
        if (-not ($Data.Groups -is [hashtable])) { throw (New-WmError 'managed.version_groups_not_table') }
        foreach ($g in $Data.Groups.Keys) {
            $name = [string]$g
            if (-not (Test-WmGroupName $name)) { throw (New-WmError 'managed.version_bad_group' @($name)) }
            if (-not ($Data.Groups[$g] -is [hashtable])) { throw (New-WmError 'managed.version_groups_not_table') }
            $groups[$name] = ConvertFrom-WmVersionEntry -Data $Data.Groups[$g] -Prefix "Groups.$name."
        }
    }
    return [pscustomobject]@{ Default = $default; Groups = $groups }
}

# The version for a computer in these groups (in the order they are tried): the entry of the first group that has
# one, otherwise the default. Returns Version, Url, Sha256 and Group ('' = the default), or $null when the source
# names none for it. Groups is case-insensitive, like group names everywhere.
function Get-WmWantedVersion {
    param($Versions, [string[]]$Groups = @())
    if ($null -eq $Versions) { return $null }
    foreach ($g in $Groups) {
        if ($Versions.Groups.ContainsKey($g)) {
            $e = $Versions.Groups[$g]
            return [pscustomobject]@{ Version = $e.Version; Url = $e.Url; Sha256 = $e.Sha256; Group = $g }
        }
    }
    if ($Versions.Default) {
        $e = $Versions.Default
        return [pscustomobject]@{ Version = $e.Version; Url = $e.Url; Sha256 = $e.Sha256; Group = '' }
    }
    return $null
}

# Does version.psd1 give this group a version of its own? (Such a group needs no folder.)
function Test-WmGroupHasVersion {
    param($Versions, [string]$Group)
    if ($null -eq $Versions) { return $false }
    return $Versions.Groups.ContainsKey($Group)
}

# For the version a computer's own groups come before the default ones (Default, every computer): the more specific
# group wins, so a pilot group still gets its version when a default group has one too.
function Get-WmVersionGroupOrder {
    param([Parameter(Mandatory = $true)][hashtable]$Map, [string[]]$Groups = @())
    $default = @($Map.Default | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $own = @(); $shared = @()
    foreach ($g in $Groups) {
        if ($default | Where-Object { $_ -ieq $g }) { $shared += $g } else { $own += $g }
    }
    return ,@($own + $shared)
}

# What a computer gets from a source: its groups, the common list and its groups' lists merged, the scripts and
# jobs of its groups, and the wmanager version it should run (Wmanager: the version of its own groups first, in their
# order, then of the default groups, then the one for every computer; see Get-WmWantedVersion). $Files: the paths
# of the source (the manifest's Files); $Lists: '' = the common list, otherwise group -> its parsed list; $Versions:
# ConvertFrom-WmVersionData of version.psd1, or $null. A group without files is reported (Write-WmManagedWarning)
# and skipped, unless version.psd1 gives it a version: a group may exist only for that.
function Resolve-WmComputerContent {
    param([Parameter(Mandatory = $true)][hashtable]$Map, [Parameter(Mandatory = $true)][hashtable]$Lists,
          [Parameter(Mandatory = $true)][hashtable]$Files, [Parameter(Mandatory = $true)][string]$ComputerName,
          $Versions = $null)
    $groups = Get-WmComputerGroups -Map $Map -ComputerName $ComputerName
    $toMerge = @([pscustomobject]@{ Label = (New-WmText 'managed.common_list'); IsGroup = $false; Items = @($Lists['']) })
    foreach ($g in $groups) {
        $hasFiles = @($Files.Keys | Where-Object { $_.StartsWith("groups/$g/", [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        if (-not $hasFiles) {
            if (-not (Test-WmGroupHasVersion $Versions $g)) { Write-WmManagedWarning -Key 'managed.group_no_files' -Arguments @($g) }
            continue
        }
        if ($Lists.ContainsKey($g)) { $toMerge += [pscustomobject]@{ Label = $g; IsGroup = $true; Items = @($Lists[$g]) } }
    }
    return [pscustomobject]@{
        Groups       = $groups
        Requirements = (Merge-WmRequirements -Lists $toMerge)
        Scripts      = (Get-WmGroupScripts -Files $Files -Groups $groups)
        Jobs         = (Get-WmGroupJobs -Files $Files -Groups $groups)
        LogonScripts = (Get-WmGroupLogonScripts -Files $Files -Groups $groups)
        StartupScripts = (Get-WmGroupStartupScripts -Files $Files -Groups $groups)
        Wmanager     = (Get-WmWantedVersion -Versions $Versions -Groups (Get-WmVersionGroupOrder -Map $Map -Groups $groups))
    }
}

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
