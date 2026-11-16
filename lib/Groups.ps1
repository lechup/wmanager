# Content of a management source without system dependencies: paths, the group map, package lists and how they
# combine, the scripts and jobs of a computer's groups, computer names. Platform-neutral: lib\Managed.ps1 and
# lib\Choco.ps1 load it on the computers, tools/groups.ps1 on the administrator's machine (also Linux), so both
# read a source the same way. Needs lib\Lang.ps1 (New-WmError). Merge-WmRequirements reports through
# Write-WmManagedNote and Write-WmManagedWarning, which the caller defines.
# Tested in tests\Managed.Tests.ps1, tests\Requirements.Tests.ps1 and tests\Groups.Tests.ps1.

$script:WmJobPeriods = @('hourly', 'daily', 'weekly')

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
        foreach ($every in $script:WmJobPeriods) {
            foreach ($p in (Get-WmManagedScriptPaths -Files $Files -Folder "groups/$g/jobs/$every/")) {
                $base = [IO.Path]::GetFileNameWithoutExtension($p.Substring($p.LastIndexOf('/') + 1))
                $result += [pscustomobject]@{ Group = $g; Path = $p; Every = $every; Name = "$g/$base" }
            }
        }
    }
    return ,$result
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
