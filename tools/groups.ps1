# wmanager: manage a management source (computer groups) from the terminal. Shows what a computer gets, checks
# the source the way the computers read it (lib/Groups.ps1, the same code), and edits groups.psd1, the package
# lists and new scripts and jobs, and sets the wmanager version the computers run (version.psd1). Edits keep the rest
# of each file as it is: comments, order, BOM, line endings (version.psd1 is written whole). Sign and publish
# afterwards with tools/publish.sh (which runs "check" first).
#
#   pwsh tools/groups.ps1 <folder> show [<computer>]
#   pwsh tools/groups.ps1 <folder> check
#   pwsh tools/groups.ps1 <folder> add-computer <computer> <group>...
#   pwsh tools/groups.ps1 <folder> remove-computer <computer> [<group>...]
#   pwsh tools/groups.ps1 <folder> add-package <group|common> <line of choco-reqs.txt>
#   pwsh tools/groups.ps1 <folder> remove-package <group|common> <package>
#   pwsh tools/groups.ps1 <folder> new-script <group> <name>
#   pwsh tools/groups.ps1 <folder> new-job <group> <hourly|daily|weekly> <name>
#   pwsh tools/groups.ps1 <folder> set-version <version> [<group>] [-Url <address>] [-Zip <file>]
#   pwsh tools/groups.ps1 <folder> unset-version [<group>]
#
# PowerShell 7 (pwsh) on Linux or macOS, or Windows PowerShell 5.1. Messages are in English, like the other tools.
# -FileList <file>: check only these paths (one per line, relative, '/'), as publish.sh passes what git will push.
param(
    [Parameter(Position = 0)][string]$Folder,
    [Parameter(Position = 1)][string]$Command,
    [Parameter(Position = 2, ValueFromRemainingArguments = $true)][string[]]$Rest = @(),
    [string]$FileList,
    [string]$Url,
    [string]$Zip
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path (Join-Path $repo 'lib') 'Lang.ps1')
. (Join-Path (Join-Path $repo 'lib') 'Groups.ps1')
Initialize-WmLanguage -Lang 'en' -Root $repo
# Windows PowerShell 5.1 doesn't enable TLS 1.2 by default (set-version downloads from GitHub)
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

$script:ProblemErrors = 0
$script:ProblemWarnings = 0
$script:MergeMessages = New-Object 'System.Collections.Generic.List[object]'

# Merge-WmRequirements (lib/Groups.ps1) reports through these; on a computer they write to the log
function Write-WmManagedNote {
    param([Parameter(Mandatory = $true)][string]$Key, [object[]]$Arguments = @())
    $text = Get-WmText -Key $Key -Arguments $Arguments -English
    $script:MergeMessages.Add([pscustomobject]@{ Key = $Key; Warning = $false; Text = $text })
}
function Write-WmManagedWarning {
    param([Parameter(Mandatory = $true)][string]$Key, [object[]]$Arguments = @())
    $text = Get-WmText -Key $Key -Arguments $Arguments -English
    $script:MergeMessages.Add([pscustomobject]@{ Key = $Key; Warning = $true; Text = $text })
}

function Write-Problem {
    param([ValidateSet('error', 'warning')][string]$Kind, [string]$Text)
    if ($Kind -eq 'error') { $script:ProblemErrors++; Write-Host "ERROR: $Text" -ForegroundColor Red }
    else { $script:ProblemWarnings++; Write-Host "WARNING: $Text" -ForegroundColor Yellow }
}

function Show-Usage {
    Write-Host @'
usage: pwsh tools/groups.ps1 <folder> <command> ...
  show [<computer>]                           what a computer gets (groups, packages, scripts, jobs); without one, an overview
  check                                       check the source the way the computers read it (publish.sh runs it too)
  add-computer <computer> <group>...          put a computer into groups (groups.psd1)
  remove-computer <computer> [<group>...]     take it out of these groups, or out of groups.psd1 altogether
  add-package <group|common> <line>           add a package line to a list, or replace the line of the same package
  remove-package <group|common> <package>     remove a package from a list (computers don't uninstall it)
  new-script <group> <name>                   new script groups/<group>/scripts/<NN>-<name>.ps1 from a template
  new-job <group> <hourly|daily|weekly> <name>  new job groups/<group>/jobs/<when>/<name>.ps1 from a template
  set-version <version> [<group>]             the wmanager release the computers (or a group's) switch to, e.g. v0.2.0
      [-Url <address>] [-Zip <file>]          where they fetch it (default: the GitHub release); a local copy to read
  unset-version [<group>]                     drop that version (the computers keep the one they have)
Quote a package line with ' ' in bash ('7zip@24.8.0 !noupdate', 'vlc | --params "/X"').
'@
}

# ---------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------

function Get-FullPath {
    param([string]$Root, [string]$Rel)
    return [IO.Path]::Combine($Root, $Rel.Replace('/', [IO.Path]::DirectorySeparatorChar))
}

function Test-HasBom {
    param([byte[]]$Bytes)
    return ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF)
}

# Text, BOM and line ending of a file; a missing file is empty, without a BOM, CRLF (like the examples)
function Read-TextFile {
    param([string]$Path)
    if (-not [IO.File]::Exists($Path)) { return [pscustomobject]@{ Text = ''; Bom = $false; NewLine = "`r`n"; Exists = $false } }
    $bytes = [IO.File]::ReadAllBytes($Path)
    $bom = Test-HasBom $bytes
    $start = 0
    if ($bom) { $start = 3 }
    $text = (New-Object System.Text.UTF8Encoding($false)).GetString($bytes, $start, $bytes.Length - $start)
    $nl = "`r`n"
    if ($text.IndexOf([char]10) -ge 0 -and $text.IndexOf("`r`n", [StringComparison]::Ordinal) -lt 0) { $nl = "`n" }
    return [pscustomobject]@{ Text = $text; Bom = $bom; NewLine = $nl; Exists = $true }
}

function Write-TextFile {
    param([string]$Path, [string]$Text, [bool]$Bom)
    $dir = [IO.Path]::GetDirectoryName($Path)
    if (-not [IO.Directory]::Exists($dir)) { [void][IO.Directory]::CreateDirectory($dir) }
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($Bom)))
}

# The files of the source as publish.sh signs them: relative path ('/') -> full path, without hidden ones (.git...)
# and manifest.psd1. In a git repository what git will push (tracked and new files that aren't ignored), otherwise
# every file; links to folders are not followed (publish.sh refuses links). With -FileList, exactly those paths.
function Get-SourceFiles {
    param([string]$Root)
    $files = @{}   # case-insensitive, like the manifest on a computer
    $listed = $null
    if ($FileList) {
        $listed = [IO.File]::ReadAllLines($FileList)
    } elseif (Get-Command git -CommandType Application -ErrorAction SilentlyContinue) {
        # Windows PowerShell 5.1 turns what a program writes to stderr ("not a git repository") into an error,
        # which 'Stop' would throw
        $ErrorActionPreference = 'Continue'
        $inGit = (& git -C $Root rev-parse --is-inside-work-tree 2>$null) -eq 'true'
        if ($inGit) {
            $out = & git -C $Root ls-files -z --cached --others --exclude-standard -- . 2>$null
            $listed = @(([string]($out -join "`n")).Split([char]0) | Where-Object { $_ })
        }
        $ErrorActionPreference = 'Stop'
    }
    if ($null -ne $listed) {
        foreach ($line in $listed) {
            $rel = $line.Trim()
            if (-not $rel -or $rel -ieq 'manifest.psd1' -or ('/' + $rel) -match '/\.') { continue }
            $full = Get-FullPath $Root $rel
            if ([IO.File]::Exists($full)) { $files[$rel] = $full }   # a tracked file deleted here is not published
        }
        return $files
    }
    $todo = New-Object 'System.Collections.Generic.Stack[string]'
    $todo.Push('')
    while ($todo.Count -gt 0) {
        $rel = $todo.Pop()
        $dir = $Root
        if ($rel) { $dir = Get-FullPath $Root $rel.TrimEnd('/') }
        foreach ($d in [IO.Directory]::GetDirectories($dir)) {
            $name = [IO.Path]::GetFileName($d)
            $link = ([IO.File]::GetAttributes($d) -band [IO.FileAttributes]::ReparsePoint) -ne 0
            if (-not $name.StartsWith('.') -and -not $link) { $todo.Push($rel + $name + '/') }
        }
        foreach ($f in [IO.Directory]::GetFiles($dir)) {
            $name = [IO.Path]::GetFileName($f)
            if ($name.StartsWith('.') -or ($rel + $name) -ieq 'manifest.psd1') { continue }
            $files[$rel + $name] = $f
        }
    }
    return $files
}

# ---------------------------------------------------------------------------
# groups.psd1 and the package lists, read as a computer reads them
# ---------------------------------------------------------------------------

# The hashtable of groups.psd1 as a syntax tree, so edits can change one entry and leave the rest of the text alone
function Get-MapAst {
    param([string]$Text, [string]$Name = 'groups.psd1', [string]$Shape = '@{ Default = @(...); Computers = @{ ... } }')
    $tokens = $null
    $errs = $null
    $sb = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errs)
    if (@($errs).Count -gt 0) { throw "$Name, line $($errs[0].Extent.StartLineNumber): $($errs[0].Message)" }
    $ht = $null
    if ($sb.EndBlock -and -not $sb.ParamBlock -and -not $sb.BeginBlock -and -not $sb.ProcessBlock) {
        $st = @($sb.EndBlock.Statements)
        if ($st.Count -eq 1 -and $st[0] -is [System.Management.Automation.Language.PipelineAst]) {
            $el = @($st[0].PipelineElements)
            if ($el.Count -eq 1 -and $el[0] -is [System.Management.Automation.Language.CommandExpressionAst] -and
                $el[0].Expression -is [System.Management.Automation.Language.HashtableAst]) { $ht = $el[0].Expression }
        }
    }
    if (-not $ht) { throw "$Name must hold one hashtable: $Shape" }
    return $ht
}

# The data of groups.psd1 (constants only, like Import-PowerShellDataFile), checked like on a computer
function ConvertTo-GroupMap {
    param([string]$Text)
    $ast = Get-MapAst $Text
    try { $map = $ast.SafeGetValue() }
    catch { throw "groups.psd1 may hold only constant data (strings, @(...), @{...}): $($_.Exception.Message)" }
    Assert-WmGroupMap $map
    return $map
}

function Read-GroupMap {
    param([hashtable]$Files)
    if (-not $Files.ContainsKey('groups.psd1')) { return @{} }
    return ConvertTo-GroupMap (Read-TextFile $Files['groups.psd1']).Text
}

# '' = the common list, otherwise the group. Every entry remembers its list (Source) for "show".
function Read-PackageLists {
    param([hashtable]$Files)
    $lists = @{}
    foreach ($path in @($Files.Keys)) {
        $group = Get-WmListOwner $path
        if ($null -eq $group) { continue }
        try { $items = ConvertFrom-WmRequirements -Text (Read-TextFile $Files[$path]).Text }
        catch { throw "${path}: $(Format-WmErrorText $_ -English)" }
        $label = 'common'
        if ($group) { $label = $group }
        foreach ($i in @($items)) { $i | Add-Member -NotePropertyName Source -NotePropertyValue $label -Force }
        $lists[$group] = $items
    }
    return $lists
}

# version.psd1 checked like on a computer (lib/Groups.ps1), or $null without it
function ConvertTo-Versions {
    param([string]$Text)
    $ast = Get-MapAst $Text 'version.psd1' "@{ Version = 'v0.2.0'; Url = '...'; Sha256 = '...'; Groups = @{ ... } }"
    try { $data = $ast.SafeGetValue() }
    catch { throw "version.psd1 may hold only constant data (strings, @{...}): $($_.Exception.Message)" }
    return ConvertFrom-WmVersionData $data
}

function Read-Versions {
    param([hashtable]$Files)
    if (-not $Files.ContainsKey('version.psd1')) { return $null }
    return ConvertTo-Versions (Read-TextFile $Files['version.psd1']).Text
}

function Format-Wanted {
    param($Wanted)
    if (-not $Wanted) { return 'not set (keeps the version it has)' }
    if ($Wanted.Group) { return "$($Wanted.Version) (group $($Wanted.Group))" }
    return $Wanted.Version
}

# Groups some computer is in: Default and every entry of Computers (case-insensitive table)
function Get-ReferencedGroups {
    param([hashtable]$Map)
    $referenced = @{}
    foreach ($g in @($Map.Default)) { if ($g) { $referenced[[string]$g] = $true } }
    if ($Map.Computers -is [hashtable]) {
        foreach ($c in $Map.Computers.Keys) { foreach ($g in @($Map.Computers[$c])) { if ($g) { $referenced[[string]$g] = $true } } }
    }
    return $referenced
}

function Get-FolderGroups {
    param([hashtable]$Files)
    $names = @{}
    foreach ($p in $Files.Keys) { if ($p -match '^groups/([^/]+)/') { $names[$Matches[1]] = $Matches[1] } }
    return @($names.Values | Sort-Object)
}

# What one computer gets, as lib/Managed.ps1 resolves it: groups, merged packages, scripts and jobs
function Get-ComputerView {
    param([hashtable]$Files, [hashtable]$Map, [hashtable]$Lists, [string]$Computer, $Versions = $null)
    $script:MergeMessages.Clear()
    $c = Resolve-WmComputerContent -Map $Map -Lists $Lists -Files $Files -ComputerName $Computer -Versions $Versions
    $inMap = $false
    if ($Map.Computers -is [hashtable]) { foreach ($k in $Map.Computers.Keys) { if ([string]$k -ieq $Computer) { $inMap = $true } } }
    return [pscustomobject]@{
        Computer = $Computer
        InMap    = $inMap
        Groups   = @($c.Groups)
        Packages = @($c.Requirements | Where-Object { $null -ne $_ })
        Scripts  = @($c.Scripts)
        Jobs     = @($c.Jobs)
        Wmanager = $c.Wmanager
        Messages = $script:MergeMessages.ToArray()   # not @(...): PowerShell 7 fails on @() of a List[object]
    }
}

function Format-Package {
    param($Item)
    $s = $Item.Name
    if ($Item.Version) { $s += '@' + $Item.Version }
    if ($Item.NoUpdate) { $s += ' !noupdate' }
    if (@($Item.ExtraArgs).Count -gt 0) { $s += ' | ' + (@($Item.ExtraArgs) -join ' ') }
    return $s
}

# ---------------------------------------------------------------------------
# show
# ---------------------------------------------------------------------------

function Show-Computer {
    param([hashtable]$Files, [hashtable]$Map, [hashtable]$Lists, [string]$Computer, $Versions = $null)
    $v = Get-ComputerView -Files $Files -Map $Map -Lists $Lists -Computer $Computer -Versions $Versions
    $groups = '(none)'
    if ($v.Groups.Count -gt 0) { $groups = $v.Groups -join ', ' }
    if ($v.InMap) { Write-Host "$($Computer.ToUpperInvariant()): groups $groups" }
    else { Write-Host "$($Computer.ToUpperInvariant()) is not in groups.psd1, so only the default groups: $groups" }
    Write-Host "wmanager: $(Format-Wanted $v.Wmanager)"
    Write-Host ''
    Write-Host "Packages ($($v.Packages.Count)):"
    $width = 0
    foreach ($p in $v.Packages) { $width = [Math]::Max($width, (Format-Package $p).Length) }
    foreach ($p in $v.Packages) { Write-Host ('  {0}   from {1}' -f (Format-Package $p).PadRight($width), $p.Source) }
    Write-Host ''
    Write-Host 'Scripts, in this order (each once, and again when its file changes):'
    if ($v.Scripts.Count -eq 0) { Write-Host '  (none)' }
    foreach ($s in $v.Scripts) { Write-Host "  $($s.Path)" }
    Write-Host ''
    Write-Host 'Jobs:'
    if ($v.Jobs.Count -eq 0) { Write-Host '  (none)' }
    foreach ($j in $v.Jobs) { Write-Host ('  {0,-7} {1}   ({2})' -f $j.Every, $j.Name, $j.Path) }
    $notes = @($v.Messages | Where-Object { -not $_.Warning })
    if ($notes.Count -gt 0) {
        Write-Host ''
        foreach ($n in $notes) { Write-Host "Note: $($n.Text)" }
    }
    foreach ($w in @($v.Messages | Where-Object { $_.Warning })) { Write-Problem warning $w.Text }
}

function Show-Overview {
    param([hashtable]$Files, [hashtable]$Map, [hashtable]$Lists, $Versions = $null)
    $default = @($Map.Default | Where-Object { $_ })
    $defaultText = '(none)'
    if ($default.Count -gt 0) { $defaultText = $default -join ', ' }
    Write-Host "Default groups (every computer): $defaultText"
    $computers = @()
    if ($Map.Computers -is [hashtable]) { $computers = @($Map.Computers.Keys | ForEach-Object { [string]$_ } | Sort-Object) }
    Write-Host "Computers in groups.psd1: $($computers.Count)"
    foreach ($c in $computers) { Write-Host ('  {0,-15}  {1}' -f $c, (@($Map.Computers[$c]) -join ', ')) }
    $common = @($Lists[''] | Where-Object { $null -ne $_ })
    Write-Host "Common list: $($common.Count) packages"
    $line = 'not set (the computers keep the version they have)'
    if ($Versions -and $Versions.Default) { $line = "$($Versions.Default.Version) on every computer" }
    if ($Versions) {
        foreach ($g in @($Versions.Groups.Keys | Sort-Object)) { $line += "; $($Versions.Groups[$g].Version) in group $g" }
    }
    Write-Host "wmanager version: $line"
    Write-Host ''
    $names = @{}
    foreach ($g in $default) { $names[[string]$g] = [string]$g }
    foreach ($c in $computers) { foreach ($g in @($Map.Computers[$c])) { if ($g) { $names[[string]$g] = [string]$g } } }
    foreach ($g in (Get-FolderGroups $Files)) { if (-not $names.ContainsKey($g)) { $names[$g] = $g } }
    Write-Host 'Groups:'
    if ($names.Count -eq 0) { Write-Host '  (none)' }
    foreach ($g in @($names.Values | Sort-Object)) {
        $members = 'every computer'
        if (-not ($default | Where-Object { $_ -ieq $g })) {
            $in = @($computers | Where-Object { @($Map.Computers[$_]) | Where-Object { $_ -ieq $g } })
            $members = "$($in.Count) computers"
            if ($in.Count -eq 1) { $members = '1 computer' }
        }
        $pk = 0
        if ($Lists.ContainsKey($g)) { $pk = @($Lists[$g] | Where-Object { $null -ne $_ }).Count }
        $scripts = Get-WmGroupScripts -Files $Files -Groups @($g)
        $jobs = Get-WmGroupJobs -Files $Files -Groups @($g)
        $sc = @($scripts).Count
        $jb = @($jobs).Count
        $hasFiles = @($Files.Keys | Where-Object { $_.StartsWith("groups/$g/", [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        $extra = ''
        if (-not $hasFiles) {
            $extra = '   (no folder groups/' + $g + '/)'
            if (Test-WmGroupHasVersion $Versions $g) { $extra = '   (only its own wmanager version)' }
        }
        Write-Host ('  {0,-15}  {1,-15}  packages: {2}  scripts: {3}  jobs: {4}{5}' -f $g, $members, $pk, $sc, $jb, $extra)
    }
}

# ---------------------------------------------------------------------------
# check
# ---------------------------------------------------------------------------

# Syntax PowerShell 7 accepts and Windows PowerShell 5.1 doesn't: ?: (ternary), ??, ??=, && and || between commands,
# ?. and ?[]. Run in 5.1, the parser already rejects them; in PowerShell 7 they would pass, and every computer would
# fail on the script.
function Find-Ps7Syntax {
    param($Ast)
    if ($PSVersionTable.PSVersion.Major -lt 6 -or -not $Ast) { return @() }
    $found = $Ast.FindAll({
        param($n)
        $type = $n.GetType().Name
        if ($type -eq 'TernaryExpressionAst' -or $type -eq 'PipelineChainAst') { return $true }
        if ($type -eq 'BinaryExpressionAst' -and [string]$n.Operator -eq 'QuestionQuestion') { return $true }
        if ($type -eq 'AssignmentStatementAst' -and [string]$n.Operator -eq 'QuestionQuestionEquals') { return $true }
        if (($type -eq 'MemberExpressionAst' -or $type -eq 'InvokeMemberExpressionAst' -or $type -eq 'IndexExpressionAst') -and
            $n.PSObject.Properties['NullConditional'] -and $n.NullConditional) { return $true }
        return $false
    }, $true)
    return @($found)
}

function Invoke-Check {
    param([hashtable]$Files)
    foreach ($p in @($Files.Keys | Sort-Object)) {
        if (-not (Test-WmManagedPath $p)) { Write-Problem error "name not allowed: $p (letters, digits, '.', '-', '_'; no Windows device names)" }
    }

    $map = $null
    if (-not $Files.ContainsKey('groups.psd1')) {
        Write-Problem warning 'no groups.psd1: every computer gets only the common list'
        $map = @{}
    } else {
        try { $map = Read-GroupMap $Files } catch { Write-Problem error (Format-WmErrorText $_ -English) }
    }
    if (-not $Files.ContainsKey('choco-reqs.txt')) { Write-Problem warning 'no choco-reqs.txt: the common list is empty' }
    $versions = $null
    try { $versions = Read-Versions $Files } catch { Write-Problem error (Format-WmErrorText $_ -English) }

    $lists = @{}
    $listsOk = $true
    foreach ($path in @($Files.Keys | Sort-Object)) {
        if ($null -eq (Get-WmListOwner $path)) { continue }
        try { $one = Read-PackageLists @{ $path = $Files[$path] }; foreach ($k in $one.Keys) { $lists[$k] = $one[$k] } }
        catch { Write-Problem error (Format-WmErrorText $_ -English); $listsOk = $false }
    }
    foreach ($g in (Get-FolderGroups $Files)) {
        if ($g -ieq 'common') { Write-Problem warning "a group is named 'common': tools/groups.ps1 add-package/remove-package can't edit its list (common means the common list); rename it" }
    }

    foreach ($p in @($Files.Keys | Sort-Object)) {
        if ($p -notmatch '\.(ps1|psd1|psm1)$') { continue }
        $file = Read-TextFile $Files[$p]
        if (-not $file.Bom -and $file.Text -match '[^\x00-\x7F]') {
            Write-Problem warning "$p has non-ASCII characters but no BOM; save it as UTF-8 with BOM (Windows PowerShell 5.1 reads it as ANSI)"
        }
        if ($p -match '^groups/[^/]+/(scripts|jobs)/.*\.ps1$') {
            $tokens = $null
            $errs = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($file.Text, [ref]$tokens, [ref]$errs)
            foreach ($e in @($errs)) { Write-Problem error "$p, line $($e.Extent.StartLineNumber): $($e.Message)" }
            foreach ($n in (Find-Ps7Syntax $ast)) {
                Write-Problem error "$p, line $($n.Extent.StartLineNumber): '$($n.Extent.Text.Split([char]10)[0].Trim())' is PowerShell 7 syntax; the computers run Windows PowerShell 5.1"
            }
        }
        if ($p -match '^groups/[^/]+/scripts/.+/.+\.ps1$') {
            Write-Problem warning "$p is not run: scripts go directly in groups/<group>/scripts/"
        }
        if ($p -match '^groups/[^/]+/jobs/.*\.ps1$' -and $p -notmatch '^groups/[^/]+/jobs/(hourly|daily|weekly)/[^/]+$') {
            Write-Problem warning "$p is not run: jobs go directly in jobs/hourly, jobs/daily or jobs/weekly"
        }
    }

    # Scripts run in name order: 5-a.ps1 sorts after 10-b.ps1
    foreach ($g in (Get-FolderGroups $Files)) {
        $widths = @{}
        foreach ($sp in (Get-WmGroupScripts -Files $Files -Groups @($g))) {
            if ($sp.Path -match '/([0-9]+)-[^/]*$') { $widths[$Matches[1].Length] = $true }
        }
        if ($widths.Count -gt 1) { Write-Problem warning "groups/$g/scripts: number the scripts with the same number of digits (05-, 10-); they run in name order, so 5-a.ps1 runs after 10-b.ps1" }
    }

    if ($null -ne $map) {
        $computers = @()
        if ($map.Computers -is [hashtable]) { $computers = @($map.Computers.Keys | ForEach-Object { [string]$_ } | Sort-Object) }
        foreach ($c in $computers) {
            if (-not (Test-WmComputerName $c)) {
                Write-Problem warning "groups.psd1: '$c' is not a valid Windows computer name (1-15 letters, digits, hyphens), so no computer matches it"
            }
        }
        $referenced = Get-ReferencedGroups $map
        $folders = Get-FolderGroups $Files
        foreach ($g in @($referenced.Keys | Sort-Object)) {
            # A group may exist only for its own wmanager version
            if (-not ($folders | Where-Object { $_ -ieq $g }) -and -not (Test-WmGroupHasVersion $versions $g)) {
                Write-Problem warning "group $g (groups.psd1) has no folder groups/$g/: its computers get nothing from it"
            }
        }
        if ($versions) {
            foreach ($g in @($versions.Groups.Keys | Sort-Object)) {
                if (-not $referenced.ContainsKey($g)) { Write-Problem warning "version.psd1: no computer is in group $g, so its version reaches none" }
            }
        }
        foreach ($g in $folders) {
            if (-not $referenced.ContainsKey($g)) { Write-Problem warning "groups/$g/ is not used: no computer is in group $g" }
        }
        if ($listsOk) {
            # Package conflicts as each computer would report them; '*' stands for the computers not in the map
            $seen = @{}
            foreach ($c in (@($computers) + '*')) {
                $v = Get-ComputerView -Files $Files -Map $map -Lists $lists -Computer $c -Versions $versions
                foreach ($m in @($v.Messages | Where-Object { $_.Key -eq 'managed.package_conflict' })) {
                    if (-not $seen.ContainsKey($m.Text)) { $seen[$m.Text] = $true; Write-Problem warning "groups $($v.Groups -join ', '): $($m.Text)" }
                }
            }
        }
    }
    Write-Host "Checked $($Files.Count) files: $script:ProblemErrors errors, $script:ProblemWarnings warnings."
    return ($script:ProblemErrors -eq 0)
}

# ---------------------------------------------------------------------------
# Edits of groups.psd1: one entry changes, the rest of the text stays as it is
# ---------------------------------------------------------------------------

function Get-KeyName {
    param($KeyAst)
    if ($KeyAst -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return $KeyAst.Value }
    return $KeyAst.Extent.Text
}

function Format-Quoted {
    param([string]$Text)
    return "'" + $Text.Replace("'", "''") + "'"
}

function Format-GroupList {
    param([string[]]$Groups)
    return '@(' + ((@($Groups) | ForEach-Object { Format-Quoted $_ }) -join ', ') + ')'
}

function Get-LineStart {
    param([string]$Text, [int]$Offset)
    if ($Offset -le 0) { return 0 }
    return $Text.LastIndexOf([char]10, $Offset - 1) + 1
}

# Just after the line end (its newline included), or the end of the text
function Get-LineEnd {
    param([string]$Text, [int]$Offset)
    $i = $Text.IndexOf([char]10, $Offset)
    if ($i -lt 0) { return $Text.Length }
    return $i + 1
}

function Get-Indent {
    param([string]$Text, [int]$Offset)
    $start = Get-LineStart $Text $Offset
    return [regex]::Match($Text.Substring($start), '^[ \t]*').Value
}

function Set-TextRange {
    param([string]$Text, [int]$Start, [int]$End, [string]$New)
    return $Text.Substring(0, $Start) + $New + $Text.Substring($End)
}

# Is only whitespace (and an optional ';' or comment) between $From and the end of its line?
function Test-RestOfLineEmpty {
    param([string]$Text, [int]$From)
    $end = Get-LineEnd $Text $From
    return ($Text.Substring($From, $end - $From) -match '^[ \t]*;?[ \t]*(#.*)?\r?\n?$')
}

# The text of groups.psd1 with the entry of $Computer set to $Groups (an empty list removes the entry)
function Set-ComputerEntry {
    param([string]$Text, [string]$NewLine, [string]$Computer, [string[]]$Groups)
    $root = Get-MapAst $Text
    $compPair = @($root.KeyValuePairs | Where-Object { (Get-KeyName $_.Item1) -ieq 'Computers' }) | Select-Object -First 1
    $comp = $null
    if ($compPair) { $comp = $compPair.Item2.Find({ param($a) $a -is [System.Management.Automation.Language.HashtableAst] }, $false) }
    $entry = $null
    if ($comp) { $entry = @($comp.KeyValuePairs | Where-Object { (Get-KeyName $_.Item1) -ieq $Computer }) | Select-Object -First 1 }
    $manual = 'add it to groups.psd1 by hand'
    $remove = @($Groups).Count -eq 0

    if ($entry) {
        if (-not $remove) {
            return Set-TextRange $Text $entry.Item2.Extent.StartOffset $entry.Item2.Extent.EndOffset (Format-GroupList $Groups)
        }
        $s = $entry.Item1.Extent.StartOffset
        $e = $entry.Item2.Extent.EndOffset
        $ls = Get-LineStart $Text $s
        if ($Text.Substring($ls, $s - $ls).Trim() -or -not (Test-RestOfLineEmpty $Text $e)) {
            throw "the entry of $Computer shares its line with other text; remove it from groups.psd1 by hand"
        }
        return Set-TextRange $Text $ls (Get-LineEnd $Text $e) ''
    }
    if ($remove) { return $Text }

    $key = Format-Quoted $Computer
    $value = Format-GroupList $Groups
    if ($comp -and @($comp.KeyValuePairs).Count -gt 0) {
        # After the last entry, with its indent and its '=' column
        $last = @($comp.KeyValuePairs)[-1]
        if (-not (Test-RestOfLineEmpty $Text $last.Item2.Extent.EndOffset)) { throw "Computers is written on one line; $manual" }
        $lineStart = Get-LineStart $Text $last.Item1.Extent.StartOffset
        $lead = (Get-Indent $Text $lineStart) + $key
        $eq = $Text.IndexOf([char]'=', $last.Item1.Extent.EndOffset) - $lineStart
        $pad = ' '
        if ($lead.Length -lt $eq) { $pad = ' ' * ($eq - $lead.Length) }
        $at = Get-LineEnd $Text $last.Item2.Extent.EndOffset
        $line = $lead + $pad + '= ' + $value + $NewLine
        if ($at -eq $Text.Length -and -not $Text.EndsWith("`n")) { $line = $NewLine + $lead + $pad + '= ' + $value }
        return Set-TextRange $Text $at $at $line
    }
    if ($comp) {
        # No entries yet: @{} on one line, or a block with comments only
        $outer = Get-Indent $Text $compPair.Item1.Extent.StartOffset
        $close = $comp.Extent.EndOffset - 1
        $inner = $Text.Substring($comp.Extent.StartOffset, $comp.Extent.EndOffset - $comp.Extent.StartOffset)
        if ($inner.IndexOf([char]10) -lt 0) {
            $block = '@{' + $NewLine + $outer + '    ' + $key + ' = ' + $value + $NewLine + $outer + '}'
            return Set-TextRange $Text $comp.Extent.StartOffset $comp.Extent.EndOffset $block
        }
        $closeLine = Get-LineStart $Text $close
        if ($Text.Substring($closeLine, $close - $closeLine).Trim()) { throw "unusual layout of Computers; $manual" }
        $line = (Get-Indent $Text $close) + '    ' + $key + ' = ' + $value + $NewLine
        return Set-TextRange $Text $closeLine $closeLine $line
    }
    # No Computers yet: before the closing brace of the file's hashtable
    $close = $root.Extent.EndOffset - 1
    $closeLine = Get-LineStart $Text $close
    if ($Text.Substring($closeLine, $close - $closeLine).Trim()) { throw "unusual layout of groups.psd1; $manual" }
    $indent = '    '
    if (@($root.KeyValuePairs).Count -gt 0) { $indent = Get-Indent $Text @($root.KeyValuePairs)[0].Item1.Extent.StartOffset }
    $block = $NewLine + $indent + 'Computers = @{' + $NewLine + $indent + '    ' + $key + ' = ' + $value + $NewLine + $indent + '}' + $NewLine
    return Set-TextRange $Text $closeLine $closeLine $block
}

function Get-OwnGroups {
    param([hashtable]$Map, [string]$Computer)
    if ($Map.Computers -is [hashtable]) {
        foreach ($k in $Map.Computers.Keys) { if ([string]$k -ieq $Computer) { return @($Map.Computers[$k] | Where-Object { $_ } | ForEach-Object { [string]$_ }) } }
    }
    return @()
}

function Update-Computer {
    param([string]$Root, [string]$Computer, [string[]]$Add = @(), [string[]]$Drop = @(), [switch]$RemoveAll)
    if (-not (Test-WmComputerName $Computer)) { throw "'$Computer' is not a valid Windows computer name (1-15 letters, digits, hyphens)" }
    foreach ($g in @($Add) + @($Drop)) { if (-not (Test-WmGroupName $g)) { throw "invalid group name '$g' (letters, digits, '.', '-', '_')" } }
    $path = Get-FullPath $Root 'groups.psd1'
    $file = Read-TextFile $path
    if (-not $file.Exists) {
        $file = [pscustomobject]@{ Text = "# Which groups each computer belongs to (see README: Computer groups).`r`n@{`r`n    Default = @()`r`n}`r`n"; Bom = $true; NewLine = "`r`n"; Exists = $false }
    }
    $map = ConvertTo-GroupMap $file.Text
    $own = @(Get-OwnGroups $map $Computer)
    $want = New-Object 'System.Collections.Generic.List[string]'
    if (-not $RemoveAll) {
        foreach ($g in $own) { if (-not ($Drop | Where-Object { $_ -ieq $g })) { $want.Add($g) } }
        foreach ($g in $Add) { if (-not ($want | Where-Object { $_ -ieq $g })) { $want.Add($g) } }
    }
    $name = $Computer.ToUpperInvariant()
    if ($map.Computers -is [hashtable]) { foreach ($k in $map.Computers.Keys) { if ([string]$k -ieq $Computer) { $name = [string]$k } } }
    $isIn = @($own).Count -gt 0 -or ($map.Computers -is [hashtable] -and @($map.Computers.Keys | Where-Object { [string]$_ -ieq $Computer }).Count -gt 0)
    if (((@($own) -join '|') -ieq ($want.ToArray() -join '|')) -and ($want.Count -gt 0 -or -not $isIn)) {
        Write-Host "No change: $name is in groups $(if ($own.Count) { $own -join ', ' } else { '(none of its own)' })."
        return
    }
    $text = Set-ComputerEntry -Text $file.Text -NewLine $file.NewLine -Computer $name -Groups $want.ToArray()
    # Read back what was written: the map must parse and give exactly the intended groups
    $check = ConvertTo-GroupMap $text
    if (((Get-OwnGroups $check $Computer) -join '|') -ine ($want.ToArray() -join '|')) { throw 'groups.psd1 would not come out as intended; nothing was changed' }
    Write-TextFile $path $text $file.Bom
    if ($want.Count -eq 0) { Write-Host "$name removed from groups.psd1: it gets only the default groups." }
    else { Write-Host "$name is in groups: $($want -join ', ') (groups.psd1)." }
    $missing = @($want | Where-Object { -not [IO.Directory]::Exists((Get-FullPath $Root "groups/$_")) })
    foreach ($g in $missing) { Write-Problem warning "group $g has no folder groups/$g/ yet: add packages, scripts or jobs to it" }
}

# ---------------------------------------------------------------------------
# Edits of the package lists
# ---------------------------------------------------------------------------

function Get-ListPath {
    param([string]$Root, [string]$Target)
    if ($Target -ieq 'common') {
        if ([IO.Directory]::Exists((Get-FullPath $Root 'groups/common'))) {
            throw "'common' means the common list, but there is also a group named common; rename that group to edit its list"
        }
        return 'choco-reqs.txt'
    }
    if (-not (Test-WmGroupName $Target)) { throw "invalid group name '$Target' (letters, digits, '.', '-', '_'), or 'common' for the common list" }
    return "groups/$Target/choco-reqs.txt"
}

# The line index of package $Name in $Lines, or -1
function Find-PackageLine {
    param([string[]]$Lines, [string]$Name)
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        try { $items = @(ConvertFrom-WmRequirements -Text $Lines[$i]) } catch { continue }
        if ($items.Count -eq 1 -and $items[0].Name -ieq $Name) { return $i }
    }
    return -1
}

function Update-PackageList {
    param([string]$Root, [string]$Target, [string]$Line, [string]$Remove)
    $rel = Get-ListPath $Root $Target
    $path = Get-FullPath $Root $rel
    $file = Read-TextFile $path
    $lines = New-Object 'System.Collections.Generic.List[string]'
    if ($file.Text) { $lines.AddRange([string[]]($file.Text -split '\r?\n')) }
    $endsWithNewLine = $file.Text.EndsWith("`n")
    if ($endsWithNewLine) { $lines.RemoveAt($lines.Count - 1) }

    if ($Remove) {
        $i = Find-PackageLine $lines.ToArray() $Remove
        if ($i -lt 0) { throw "$Remove is not on $rel" }
        $old = $lines[$i]
        $lines.RemoveAt($i)
        $message = "Removed from ${rel}: $($old.Trim()) (computers that have it keep it: packages are never uninstalled)."
    } else {
        $items = @()
        try { $items = @(ConvertFrom-WmRequirements -Text $Line) } catch { throw "invalid package line '$Line': $(Format-WmErrorText $_ -English)" }
        if ($items.Count -ne 1) { throw "give one package line, e.g. '7zip@24.8.0 !noupdate'" }
        $i = Find-PackageLine $lines.ToArray() $items[0].Name
        if ($i -ge 0) {
            $old = $lines[$i]
            $comment = [regex]::Match($old, '(?:^|\s)(#.*)$').Groups[1].Value
            $new = $Line.Trim()
            if ($comment) { $new += '   ' + $comment }
            if ($old -ceq $new) { Write-Host "No change: $rel already has $($Line.Trim())."; return }
            $lines[$i] = $new
            $message = "Changed in ${rel}: $($old.Trim()) -> $new"
        } else {
            $lines.Add($Line.Trim())
            $message = "Added to ${rel}: $($Line.Trim())"
        }
    }
    $text = ($lines.ToArray() -join $file.NewLine)
    if ($lines.Count -gt 0) { $text += $file.NewLine }
    # The whole list must still parse (e.g. no package twice), as the computers require
    try { $null = ConvertFrom-WmRequirements -Text $text } catch { throw "${rel} would be invalid: $(Format-WmErrorText $_ -English); nothing was changed" }
    Write-TextFile $path $text $file.Bom
    Write-Host $message
}

# ---------------------------------------------------------------------------
# New scripts and jobs from templates (UTF-8 with BOM, CRLF, as Windows PowerShell 5.1 needs them)
# ---------------------------------------------------------------------------

$script:ScriptTemplate = @'
# Script of group {{GROUP}}. wmanager runs it as SYSTEM in Windows PowerShell 5.1: once, and again whenever this
# file changes. Exit code 0 = done, 3010 = done but the computer needs a restart (the user gets a notification),
# anything else (or an exception) = failed; it runs again 20 hours later. Its output goes to the log and Loki.
# Environment: WMANAGER_GROUP, WMANAGER_COMPUTER, WMANAGER_GROUP_DIR (this group's folder, for its files).
# Keep this file UTF-8 with BOM, otherwise Windows PowerShell 5.1 garbles letters outside ASCII.
$ErrorActionPreference = 'Stop'

# TODO: what {{NAME}} sets up. With 'Stop', check the exit codes of programs yourself, e.g.:
# powercfg.exe /change standby-timeout-ac 0
# if ($LASTEXITCODE -ne 0) { throw "powercfg returned exit code $LASTEXITCODE" }

Write-Output "{{NAME}}: done ($env:WMANAGER_COMPUTER, group $env:WMANAGER_GROUP)."
exit 0
'@

$script:JobTemplate = @'
# Job of group {{GROUP}}, run as SYSTEM {{EVERY}} by the hourly wmanager-Jobs task (folder jobs/{{FOLDER}}).
# Every line it prints goes to Loki unchanged, labelled task="{{GROUP}}/{{NAME}}". Print one JSON object per line,
# then Grafana reads it with: {service_name="wmanager", task="{{GROUP}}/{{NAME}}"} | json
# Exit code 0 = done; anything else is an error in the log. Time limit: JobTimeoutMinutes (10 by default).
# Keep this file UTF-8 with BOM, otherwise Windows PowerShell 5.1 garbles letters outside ASCII.
$ErrorActionPreference = 'Stop'

[pscustomobject]@{
    kind     = '{{NAME}}'
    computer = $env:WMANAGER_COMPUTER
    # TODO: the values to report
} | ConvertTo-Json -Compress
exit 0
'@

function New-GroupFile {
    param([string]$Root, [string]$Group, [string]$Kind, [string]$Every, [string]$Name)
    if (-not (Test-WmGroupName $Group)) { throw "invalid group name '$Group' (letters, digits, '.', '-', '_')" }
    $base = $Name -replace '\.ps1$', ''
    if (-not (Test-WmGroupName $base)) { throw "invalid name '$Name' (letters, digits, '.', '-', '_')" }
    if ($Kind -eq 'script') {
        $dirRel = "groups/$Group/scripts"
        if ($base -notmatch '^[0-9]+-') {
            # Scripts run in name order: number them in tens after the last one
            $last = 0
            $dir = Get-FullPath $Root $dirRel
            if ([IO.Directory]::Exists($dir)) {
                foreach ($f in [IO.Directory]::GetFiles($dir, '*.ps1')) {
                    if ([IO.Path]::GetFileName($f) -match '^([0-9]+)-') { $last = [Math]::Max($last, [int]$Matches[1]) }
                }
            }
            $next = [int]([Math]::Floor($last / 10) * 10 + 10)
            # A third digit would sort 100-x before 20-y (ordinal name order)
            if ($next -gt 99) { throw "the scripts of $Group already reach $last; give the number yourself (e.g. 95-$base) or renumber them" }
            $base = '{0:D2}-{1}' -f $next, $base
        }
        $text = $script:ScriptTemplate
    } else {
        if (@('hourly', 'daily', 'weekly') -notcontains $Every) { throw "a job runs hourly, daily or weekly, not '$Every'" }
        $dirRel = "groups/$Group/jobs/$Every"
        $text = $script:JobTemplate.Replace('{{EVERY}}', @{ hourly = 'every hour'; daily = 'once a day'; weekly = 'once a week' }[$Every]).Replace('{{FOLDER}}', $Every)
    }
    $rel = "$dirRel/$base.ps1"
    $path = Get-FullPath $Root $rel
    if ([IO.File]::Exists($path)) { throw "$rel already exists" }
    # A job's Loki label is group/file name, number included, as Get-WmGroupJobs names it
    $label = $base
    if ($Kind -eq 'script') { $label = $base -replace '^[0-9]+-', '' }
    $text = $text.Replace('{{GROUP}}', $Group).Replace('{{NAME}}', $label)
    $text = ($text -split '\r?\n') -join "`r`n"
    if (-not $text.EndsWith("`r`n")) { $text += "`r`n" }
    Write-TextFile $path $text $true
    Write-Host "Created $rel. Edit it, then: pwsh tools/groups.ps1 <folder> check, and tools/publish.sh."
}

# ---------------------------------------------------------------------------
# version.psd1: the wmanager version the computers run (written whole, from the data)
# ---------------------------------------------------------------------------

$script:ReleaseDownload = 'https://github.com/lechup/wmanager/releases/download'

$script:VersionHeader = @(
    '# The wmanager version the computers of this source run. tools/groups.ps1 set-version and unset-version write'
    '# this file whole, so changes by hand don''t last.'
    '# At its scheduled update a computer downloads the release from Url, installs it only when its SHA256 matches, and'
    '# then runs exactly this version (also an older one). A computer in a group under Groups runs that group''s version:'
    '# its own groups come before the default ones, then the groups.psd1 order decides. Without a version it keeps its own.'
)

function Read-ZipText {
    param($Archive, [string]$Name)
    $entry = $Archive.GetEntry($Name)
    if (-not $entry) { return $null }
    $reader = New-Object System.IO.StreamReader($entry.Open(), [Text.Encoding]::UTF8)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

# Can this Update-Packages.ps1 install itself (Update-Packages.ps1 -SelfInstall, lib/SelfUpdate.ps1)?
function Test-SelfInstall {
    param([string]$Text)
    if (-not $Text) { return $false }
    $tokens = $null
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errs)
    if (-not $ast.ParamBlock) { return $false }
    return [bool](@($ast.ParamBlock.Parameters) | Where-Object { $_.Name.VariablePath.UserPath -eq 'SelfInstall' })
}

# A release as the computers will use it: its SHA256, checked against the release's SHA256SUMS when it has one; the
# version in wmanager/VERSION; and whether it can install itself (releases before self-update, such as v0.1.0, can't).
function Get-ReleaseInfo {
    param([string]$Version, [string]$Url, [string]$Zip)
    if (-not (Test-WmReleaseTag $Version)) { throw "'$Version' is not a wmanager release such as v0.2.0" }
    if (-not $Url) { $Url = "$script:ReleaseDownload/$Version/wmanager-$Version.zip" }
    if (-not (Test-WmReleaseUrl $Url)) { throw "the computers fetch a release from an https:// address or a path (C:\..., \\server\share\...), not from $Url" }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('wmanager-release-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($tmp)
    try {
        $file = $Zip
        if ($file) {
            if (-not [IO.File]::Exists($file)) { throw "file $file not found" }
        } elseif ($Url -match '^https://') {
            $file = Join-Path $tmp "wmanager-$Version.zip"
            Write-Host "Downloading $Url ..."
            $ProgressPreference = 'SilentlyContinue'
            try { Invoke-WebRequest -Uri $Url -OutFile $file -UseBasicParsing -TimeoutSec 300 }
            catch { throw "cannot download $Url ($($_.Exception.Message)); is $Version released? With a copy of the ZIP, give it with -Zip" }
        } elseif ([IO.File]::Exists($Url)) {
            $file = $Url
        } else {
            throw "$Url can't be read from here; give a copy of the ZIP with -Zip"
        }
        $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
        # The release's SHA256SUMS next to the ZIP. Whatever hash goes into version.psd1 is what every computer
        # installs, so say so when the file couldn't be checked against it
        $checked = $false
        if ($Url -match '^https://') {
            $sums = Join-Path $tmp 'SHA256SUMS'
            $name = $Url.Substring($Url.LastIndexOf('/') + 1)
            $got = $true
            try { Invoke-WebRequest -Uri ($Url.Substring(0, $Url.LastIndexOf('/') + 1) + 'SHA256SUMS') -OutFile $sums -UseBasicParsing -TimeoutSec 60 }
            catch { $got = $false }
            if ($got) {
                $line = @([IO.File]::ReadAllLines($sums) | Where-Object { $_ -match ('^[0-9A-Fa-f]{64}\s+\*?' + [regex]::Escape($name) + '$') })
                if ($line.Count -eq 1) {
                    $listed = ($line[0] -split '\s+')[0].ToUpperInvariant()
                    if ($listed -ne $hash) { throw "the SHA256 of the ZIP ($hash) differs from the release's SHA256SUMS ($listed)" }
                    Write-Host "The SHA256 matches the release's SHA256SUMS."
                    $checked = $true
                }
            }
        }
        if (-not $checked) {
            Write-Problem warning "the ZIP was not checked against a SHA256SUMS of the release; the computers will install exactly $file (SHA256 $hash), so make sure it is the release you mean"
        }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($file)
        try {
            $found = Read-ZipText $archive 'wmanager/VERSION'
            if ($null -eq $found) { throw 'the ZIP is not a wmanager release: it has no wmanager/VERSION' }
            if ($found.Trim() -ne $Version) { throw "the ZIP holds wmanager $($found.Trim()), not $Version" }
            if (-not (Test-SelfInstall (Read-ZipText $archive 'wmanager/Update-Packages.ps1'))) {
                throw "wmanager $Version can't install itself (its Update-Packages.ps1 has no -SelfInstall); pick a newer release"
            }
        } finally {
            $archive.Dispose()
        }
        return [pscustomobject]@{ Version = $Version; Url = $Url; Sha256 = $hash }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# version.psd1 of the folder (also a new file git doesn't know yet); empty without it
function Read-VersionFile {
    param([string]$Root)
    $path = Get-FullPath $Root 'version.psd1'
    if (-not [IO.File]::Exists($path)) { return [pscustomobject]@{ Default = $null; Groups = @{} } }
    try { return ConvertTo-Versions (Read-TextFile $path).Text }
    catch { throw "$(Format-WmErrorText $_ -English) (fix or delete version.psd1 first)" }
}

function Format-VersionEntry {
    param($Entry, [string]$Indent)
    return @(
        "${Indent}Version = $(Format-Quoted $Entry.Version)"
        "${Indent}Url     = $(Format-Quoted $Entry.Url)"
        "${Indent}Sha256  = $(Format-Quoted $Entry.Sha256)"
    )
}

# Writes version.psd1 from the data (UTF-8 with BOM, CRLF), read back first the way a computer reads it; deletes it
# when it would be empty. Returns whether the file is there.
function Write-VersionFile {
    param([string]$Root, $Versions)
    $path = Get-FullPath $Root 'version.psd1'
    if (-not $Versions.Default -and $Versions.Groups.Count -eq 0) {
        if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
        return $false
    }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($l in $script:VersionHeader) { $lines.Add($l) }
    $lines.Add('@{')
    if ($Versions.Default) { foreach ($l in (Format-VersionEntry $Versions.Default '    ')) { $lines.Add($l) } }
    if ($Versions.Groups.Count -gt 0) {
        $lines.Add('    Groups  = @{')
        foreach ($g in @($Versions.Groups.Keys | Sort-Object)) {
            $lines.Add("        $(Format-Quoted $g) = @{")
            foreach ($l in (Format-VersionEntry $Versions.Groups[$g] '            ')) { $lines.Add($l) }
            $lines.Add('        }')
        }
        $lines.Add('    }')
    }
    $lines.Add('}')
    $text = ($lines.ToArray() -join "`r`n") + "`r`n"
    $null = ConvertTo-Versions $text
    Write-TextFile $path $text $true
    return $true
}

function Set-Version {
    param([string]$Root, [string]$Version, [string]$Group)
    if ($Group -and -not (Test-WmGroupName $Group)) { throw "invalid group name '$Group' (letters, digits, '.', '-', '_')" }
    $versions = Read-VersionFile $Root
    $info = Get-ReleaseInfo -Version $Version -Url $Url -Zip $Zip
    if ($Group) {
        $versions.Groups.Remove($Group)   # case-insensitive: the new spelling replaces the old entry
        $versions.Groups[$Group] = $info
        Write-Host "version.psd1: group $Group -> wmanager $Version (SHA256 $($info.Sha256))."
        # An invalid groups.psd1 is check's to report; then there is nothing to say about the group here
        $map = $null
        try { $map = Read-GroupMap (Get-SourceFiles $Root) } catch { }
        if ($null -ne $map -and -not (Get-ReferencedGroups $map).ContainsKey($Group)) {
            Write-Problem warning "no computer is in group $Group yet: pwsh tools/groups.ps1 <folder> add-computer <computer> $Group"
        }
    } else {
        $versions.Default = $info
        Write-Host "version.psd1: every computer -> wmanager $Version (SHA256 $($info.Sha256))."
    }
    $null = Write-VersionFile $Root $versions
    Write-Host 'Sign and publish with tools/publish.sh; each computer switches at its next scheduled update.'
}

function Remove-Version {
    param([string]$Root, [string]$Group)
    $versions = Read-VersionFile $Root
    if ($Group) {
        if (-not $versions.Groups.ContainsKey($Group)) { throw "group $Group has no version of its own in version.psd1" }
        $versions.Groups.Remove($Group)
    } else {
        if (-not $versions.Default) { throw 'version.psd1 names no version for every computer' }
        $versions.Default = $null
    }
    if (-not (Write-VersionFile $Root $versions)) {
        Write-Host 'Deleted version.psd1: the computers keep the version they have.'
    } elseif ($Group) {
        Write-Host "version.psd1: group $Group has no version of its own any more; its computers follow the rest."
    } else {
        Write-Host 'version.psd1: no version for every computer any more; they keep the one they have (groups with their own still switch).'
    }
    Write-Host 'Sign and publish with tools/publish.sh.'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if (-not $Folder -or -not $Command) { Show-Usage; exit 2 }
if (-not [IO.Directory]::Exists($Folder)) { Write-Host "ERROR: folder $Folder not found" -ForegroundColor Red; exit 1 }
$root = (Resolve-Path -LiteralPath $Folder).ProviderPath
$args1 = @($Rest | Where-Object { $null -ne $_ })

try {
    switch ($Command) {
        'show' {
            $files = Get-SourceFiles $root
            $map = Read-GroupMap $files
            $lists = Read-PackageLists $files
            $versions = Read-Versions $files
            if ($args1.Count -gt 0) { Show-Computer -Files $files -Map $map -Lists $lists -Computer $args1[0] -Versions $versions }
            else { Show-Overview -Files $files -Map $map -Lists $lists -Versions $versions }
        }
        'check' {
            if (-not (Invoke-Check (Get-SourceFiles $root))) { exit 1 }
        }
        'add-computer' {
            if ($args1.Count -lt 2) { throw 'usage: add-computer <computer> <group>...' }
            Update-Computer -Root $root -Computer $args1[0] -Add @($args1 | Select-Object -Skip 1)
        }
        'remove-computer' {
            if ($args1.Count -lt 1) { throw 'usage: remove-computer <computer> [<group>...]' }
            if ($args1.Count -eq 1) { Update-Computer -Root $root -Computer $args1[0] -RemoveAll }
            else { Update-Computer -Root $root -Computer $args1[0] -Drop @($args1 | Select-Object -Skip 1) }
        }
        'add-package' {
            if ($args1.Count -lt 2) { throw "usage: add-package <group|common> <line of choco-reqs.txt>" }
            Update-PackageList -Root $root -Target $args1[0] -Line (@($args1 | Select-Object -Skip 1) -join ' ')
        }
        'remove-package' {
            if ($args1.Count -ne 2) { throw 'usage: remove-package <group|common> <package>' }
            Update-PackageList -Root $root -Target $args1[0] -Remove $args1[1]
        }
        'new-script' {
            if ($args1.Count -ne 2) { throw 'usage: new-script <group> <name>' }
            New-GroupFile -Root $root -Group $args1[0] -Kind 'script' -Name $args1[1]
        }
        'new-job' {
            if ($args1.Count -ne 3) { throw 'usage: new-job <group> <hourly|daily|weekly> <name>' }
            New-GroupFile -Root $root -Group $args1[0] -Kind 'job' -Every $args1[1] -Name $args1[2]
        }
        'set-version' {
            if ($args1.Count -lt 1 -or $args1.Count -gt 2) { throw 'usage: set-version <version> [<group>] [-Url <address>] [-Zip <file>]' }
            $group = ''
            if ($args1.Count -eq 2) { $group = $args1[1] }
            Set-Version -Root $root -Version $args1[0] -Group $group
        }
        'unset-version' {
            if ($args1.Count -gt 1) { throw 'usage: unset-version [<group>]' }
            $group = ''
            if ($args1.Count -eq 1) { $group = $args1[0] }
            Remove-Version -Root $root -Group $group
        }
        default { Show-Usage; exit 2 }
    }
} catch {
    Write-Host "ERROR: $(Format-WmErrorText $_ -English)" -ForegroundColor Red
    if ($env:WM_DEBUG) { Write-Host $_.ScriptStackTrace }
    exit 1
}
exit 0
