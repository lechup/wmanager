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

# Jobs of the given groups: groups/<group>/jobs/hourly|daily|weekly/*.ps1. Name (group/file) labels the
# job's entries in Loki.
function Get-WmGroupJobs {
    param([Parameter(Mandatory = $true)][hashtable]$Files, [AllowEmptyCollection()][string[]]$Groups = @())
    $result = @()
    foreach ($g in $Groups) {
        foreach ($every in @('hourly', 'daily', 'weekly')) {
            foreach ($p in (Get-WmManagedScriptPaths -Files $Files -Folder "groups/$g/jobs/$every/")) {
                $base = [IO.Path]::GetFileNameWithoutExtension($p.Substring($p.LastIndexOf('/') + 1))
                $result += [pscustomobject]@{ Group = $g; Path = $p; Every = $every; Name = "$g/$base" }
            }
        }
    }
    return ,$result
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

# The version for a computer in these groups: the entry of its first group that has one, otherwise the default.
# Returns Version, Url, Sha256 and Group ('' = the default), or $null when the source names none for it.
function Get-WmWantedVersion {
    param($Versions, [string[]]$Groups = @())
    if ($null -eq $Versions) { return $null }
    foreach ($g in $Groups) {
        foreach ($k in @($Versions.Groups.Keys)) {
            if ($k -ieq $g) {
                $e = $Versions.Groups[$k]
                return [pscustomobject]@{ Version = $e.Version; Url = $e.Url; Sha256 = $e.Sha256; Group = $k }
            }
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
    return [bool](@($Versions.Groups.Keys) | Where-Object { $_ -ieq $Group })
}

# What a computer gets from a source: its groups, the common list and its groups' lists merged, the scripts and
# jobs of its groups, and the wmanager version it should run (Wmanager, see Get-WmWantedVersion). $Files: the paths
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
        Wmanager     = (Get-WmWantedVersion -Versions $Versions -Groups $groups)
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
