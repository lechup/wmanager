# wmanager: several companies from one place. Each company has its own folder under ~/wmanager-companies (another
# place: the WMANAGER_COMPANIES environment variable):
#   <company>/source/   its management source (a private Git repository, or a folder copied to a server or a share)
#   <company>/keys/     its signing key (tools/new-signing-cert.sh); stays on this computer, never in the source
#   <company>/config/   its provision.config.psd1 and the certificate next to it (the wizard, init.ps1)
# Without arguments it asks which company and what to do, and says what comes next; the commands below do the same
# without the menu. It runs the other tools (groups.ps1, publish.sh, new-signing-cert.sh, init.ps1) on the folders of
# the chosen company. docs/companies.md.
#
#   pwsh tools/wm.ps1                          the menu
#   pwsh tools/wm.ps1 list                     the companies and their state
#   pwsh tools/wm.ps1 status                   the computers of every company, one line each (Healthchecks, Loki)
#   pwsh tools/wm.ps1 backup [<folder>]        every company as an archive (default ~/wmanager-backups)
#   pwsh tools/wm.ps1 restore <archive>        a company back from its archive (never over one that is here)
#   pwsh tools/wm.ps1 new <company>            key, source (from examples/management), first signature, configuration;
#                                              run it again and it carries on where it stopped
#   pwsh tools/wm.ps1 usb <folder>             wmanager (the latest release, when the folder has none) and every
#                                              company's configuration, for run.cmd, which then asks which company
#   pwsh tools/wm.ps1 <company>                the menu of one company
#   pwsh tools/wm.ps1 <company> status         its computers: Healthchecks, the last update, errors, wmanager version
#   pwsh tools/wm.ps1 <company> monitoring     the read-only keys status needs (kept in <company>/monitoring.psd1)
#   pwsh tools/wm.ps1 <company> changes        what changed in its source since the last signature
#   pwsh tools/wm.ps1 <company> publish        those changes, then check and sign them (tools/publish.sh) and send
#                                              them where the computers read it; -Yes: without asking, for scripts
#   pwsh tools/wm.ps1 <company> sync           send the signed source where the computers read it, and check they can
#   pwsh tools/wm.ps1 <company> target         where that is: a Git repository (gh can create it), a folder, or the
#                                              wmanager server of examples/selfhosted
#   pwsh tools/wm.ps1 <company> backup [<f>]   the company as an archive
#   pwsh tools/wm.ps1 <company> rotate-key     a new signing key: the computers get its certificate first, then the
#                                              switch (run it again); or call it off
#   pwsh tools/wm.ps1 <company> config         the configuration wizard (init.ps1) for its provision.config.psd1
#   pwsh tools/wm.ps1 <company> secret         the secrets its scripts name (# wmanager-secrets:) and its
#                                              configuration has (names only); secret <name>: add or change one
#                                              (typed without being shown), secret <name> remove
#   pwsh tools/wm.ps1 <company> <command> ...  a tools/groups.ps1 command on its source, e.g.
#                                              add-computer OFFICE-07 accounting, enable power all, set-version v0.2.0
#
# PowerShell 7 (pwsh) on Linux; new and publish need bash, openssl and osslsigncode, like the tools they run. New scripts
# and jobs open in $VISUAL or $EDITOR (else nano or vi). Messages are in English, like the other tools.
param(
    [Parameter(Position = 0)][string]$First,
    [Parameter(Position = 1)][string]$Second,
    [Parameter(Position = 2, ValueFromRemainingArguments = $true)][string[]]$Rest = @(),
    [string]$Url,
    [string]$Zip,
    [switch]$Yes
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path (Join-Path $repo 'lib') 'Lang.ps1')
. (Join-Path (Join-Path $repo 'lib') 'Groups.ps1')   # the version each computer should run, as the computers work it out
. (Join-Path (Join-Path $repo 'lib') 'Init.ps1')     # ConvertTo-WmPsdString for monitoring.psd1
Initialize-WmLanguage -Lang 'en' -Root $repo

$script:Self = $PSCommandPath
$script:Tools = $PSScriptRoot
# A full path: the .NET calls, the cmdlets and the bash tools must all read it the same way
# Relative to the current location of PowerShell ($PWD, also when this runs inside a session that went elsewhere)
function ConvertTo-FullPath {
    param([string]$Path)
    if ($Path -match '^~(/|$)') { $Path = $HOME + $Path.Substring(1) }
    return [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
}

$script:Root = if ($env:WMANAGER_COMPANIES) { ConvertTo-FullPath $env:WMANAGER_COMPANIES } else { Join-Path $HOME 'wmanager-companies' }
$script:Commands = @('list', 'new', 'usb', 'status', 'backup', 'restore', 'help')
$script:Releases = 'https://github.com/lechup/wmanager/releases'

function Show-Usage {
    foreach ($line in [IO.File]::ReadAllLines($script:Self)) {
        if ($line -notmatch '^#') { break }
        Write-Host ($line -replace '^# ?', '')
    }
}

function Write-Step {
    param([string]$Text)
    Write-Host ''
    Write-Host $Text -ForegroundColor Cyan
}

function Write-Warn {
    param([string]$Text)
    Write-Host "WARNING: $Text" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Questions
# ---------------------------------------------------------------------------

# A line typed at the terminal, trimmed; $null at the end of the input (piped input that ran out)
function Read-Line {
    param([string]$Prompt)
    $answer = Read-Host $Prompt
    if ($null -eq $answer) { return $null }
    return $answer.Trim()
}

# Groups typed as their numbers on the list of the source's groups or as names (a new name makes a new group). A
# number that isn't on the list is asked again: it would otherwise become a group of that name.
function Read-Groups {
    param($Company, [string]$Prompt, [switch]$Common)
    $names = @(Get-GroupNames $Company)
    if ($Common) { $names = @('common') + $names }
    if ($names.Count -gt 0) {
        Write-Host ('  ' + ((@(for ($i = 0; $i -lt $names.Count; $i++) { '{0}) {1}' -f ($i + 1), $names[$i] })) -join '   '))
    }
    while ($true) {
        $answer = [string](Read-Line $Prompt)
        $picked = New-Object System.Collections.Generic.List[string]
        $wrong = @()
        foreach ($t in @($answer -split '[\s,]+' | Where-Object { $_ })) {
            $n = 0
            if (-not [int]::TryParse($t, [ref]$n)) { $picked.Add($t) }
            elseif ($n -ge 1 -and $n -le $names.Count) { $picked.Add($names[$n - 1]) }
            else { $wrong += $t }
        }
        if ($wrong.Count -eq 0) { return @($picked) }
        Write-Host ('  Not on the list: {0}. Numbers from 1 to {1}, or names.' -f ($wrong -join ', '), $names.Count) -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# Companies
# ---------------------------------------------------------------------------

# A company's name is the name of its folders, here and on the USB drive (configs\<company>). At least two characters
# and a letter: run.cmd and the menu take a number as a place on the list, and n, u, q, b are menu choices.
function Test-CompanyName {
    param([string]$Name)
    return ($Name -match '^[A-Za-z0-9][A-Za-z0-9._-]{1,39}$' -and $Name -match '[A-Za-z]' -and $Name -notmatch '\.$' -and
            $Name -notmatch '^(con|prn|aux|nul|com[0-9]|lpt[0-9])(\.|$)' -and $script:Commands -notcontains $Name)
}

function Get-CompanyPaths {
    param([string]$Name)
    $dir = Join-Path $script:Root $Name
    $configDir = Join-Path $dir 'config'
    return [pscustomobject]@{
        Name      = $Name
        Dir       = $dir
        Source    = Join-Path $dir 'source'
        Keys      = Join-Path $dir 'keys'
        ConfigDir = $configDir
        Config    = Join-Path $configDir 'provision.config.psd1'
    }
}

function Get-Companies {
    if (-not [IO.Directory]::Exists($script:Root)) { return @() }
    return @(Get-ChildItem -LiteralPath $script:Root -Directory | Where-Object { Test-CompanyName $_.Name } |
        Sort-Object Name | ForEach-Object { Get-CompanyPaths $_.Name })
}

function Get-Company {
    param([string]$Name)
    if (-not (Test-CompanyName $Name) -or -not [IO.Directory]::Exists((Join-Path $script:Root $Name))) {
        throw "no company '$Name' in $($script:Root) (the companies: pwsh tools/wm.ps1 list; a new one: pwsh tools/wm.ps1 new <company>)"
    }
    return Get-CompanyPaths $Name
}

# The whole key: tools/new-signing-cert.sh writes key.pem first and the certificates only when the passphrase was
# given, so a key.pem alone is a key that wasn't finished
function Test-HasKey {
    param($Company)
    $key = Join-Path $Company.Keys 'key.pem'
    return ([IO.File]::Exists($key) -and (Get-Item -LiteralPath $key).Length -gt 0 -and
            [IO.File]::Exists((Join-Path $Company.Keys 'cert.pem')) -and [IO.File]::Exists((Join-Path $Company.Keys 'wmanager-signing.cer')))
}

# The groups of a company's source: its group folders and the groups groups.psd1 names
function Get-GroupNames {
    param($Company)
    $names = New-Object System.Collections.Generic.List[string]
    $dir = Join-Path $Company.Source 'groups'
    if ([IO.Directory]::Exists($dir)) { foreach ($d in Get-ChildItem -LiteralPath $dir -Directory) { $names.Add($d.Name) } }
    try {
        $map = Import-PowerShellDataFile -LiteralPath (Join-Path $Company.Source 'groups.psd1')
        foreach ($g in @($map.Default)) { if ($g) { $names.Add([string]$g) } }
        if ($map.Computers -is [hashtable]) {
            foreach ($v in $map.Computers.Values) { foreach ($g in @($v)) { if ($g) { $names.Add([string]$g) } } }
        }
    } catch { }
    return @($names | Sort-Object -Unique)
}

# The files tools/publish.sh signs, relative, with '/': in a Git repository what git would push (tracked files and new
# ones that aren't ignored), otherwise every file; never hidden ones (.git, .gitattributes) or manifest.psd1. Letter
# case counts, as on a web server: Foo.txt and foo.txt are two files (publish.sh refuses such a pair).
function Get-SignedFiles {
    param([string]$Source)
    $list = $null
    if (Get-Command git -CommandType Application -ErrorAction SilentlyContinue) {
        $inside = & git -C $Source rev-parse --is-inside-work-tree 2>$null
        if ($LASTEXITCODE -eq 0 -and $inside -eq 'true') {
            $list = @(& git -C $Source ls-files --cached --others --exclude-standard -- . 2>$null |
                Where-Object { Test-Path -LiteralPath (Join-Path $Source $_) })
        }
    }
    if ($null -eq $list) {
        $list = @(Get-ChildItem -LiteralPath $Source -Recurse -File -Force |
            ForEach-Object { [IO.Path]::GetRelativePath($Source, $_.FullName).Replace('\', '/') })
    }
    return @($list | Where-Object { $_ -ne 'manifest.psd1' -and "/$_" -notmatch '/\.' } | Sort-Object -Unique -CaseSensitive)
}

# SHA256 of a file, kept while its size and time stay the same: the menus redraw the state of every company
$script:HashCache = @{}
function Get-CachedHash {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path
    $key = '{0}|{1}|{2}' -f $Path, $item.Length, $item.LastWriteTimeUtc.Ticks
    if (-not $script:HashCache.ContainsKey($key)) { $script:HashCache[$key] = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
    return $script:HashCache[$key]
}

# The certificate that signed manifest.psd1 (its Authenticode block): its SHA1 thumbprint, $null without a signature
function Get-ManifestSigner {
    param([string]$Path)
    $text = [IO.File]::ReadAllText($Path)
    $m = [regex]::Match($text, '(?s)# SIG # Begin signature block\r?\n(.*?)# SIG # End signature block')
    if (-not $m.Success) { return $null }
    $b64 = (($m.Groups[1].Value -split '\r?\n') | ForEach-Object { $_ -replace '^# ', '' }) -join ''
    $cms = New-Object System.Security.Cryptography.Pkcs.SignedCms
    $cms.Decode([Convert]::FromBase64String($b64))
    return $cms.SignerInfos[0].Certificate.Thumbprint
}

# What changed in the source since the last signature: its files against the hashes in manifest.psd1, and its
# signer against the company's key. Added, Changed, Removed (relative paths); First: never signed; Unreadable: the
# reason a manifest.psd1 can't be read; OtherKey: the thumbprint of the certificate that signed it, when keys/ holds
# another one; Serial and Created of the manifest.
function Get-SourceChanges {
    param($Company)
    if (-not [IO.Directory]::Exists($Company.Source)) { throw "$($Company.Name) has no source yet: pwsh tools/wm.ps1 new $($Company.Name)" }
    $files = @(Get-SignedFiles $Company.Source)
    $result = [pscustomobject]@{
        First = $false; Unreadable = ''; OtherKey = ''; Serial = ''; Created = ''; Added = @(); Changed = @(); Removed = @()
        Files = $files   # what a signature publishes (sync sends these)
    }
    $path = Join-Path $Company.Source 'manifest.psd1'
    if (-not [IO.File]::Exists($path)) {
        $result.First = $true
        $result.Added = $files
        return $result
    }
    $manifest = $null
    try { $manifest = Import-PowerShellDataFile -LiteralPath $path } catch { $result.Unreadable = $_.Exception.Message }
    if (-not $result.Unreadable -and -not ($manifest.Files -is [hashtable])) { $result.Unreadable = 'it has no Files table' }
    if ($result.Unreadable) { return $result }
    $result.Serial = [string]$manifest.Serial
    $result.Created = [string]$manifest.Created
    # The paths as the manifest writes them, letter case included (a PowerShell hashtable would ignore it)
    $signed = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    foreach ($k in $manifest.Files.Keys) { $signed[[string]$k] = [string]$manifest.Files[$k] }
    $here = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($f in $files) { [void]$here.Add($f) }
    $result.Added = @($files | Where-Object { -not $signed.ContainsKey($_) })
    $result.Changed = @($files | Where-Object { $signed.ContainsKey($_) -and $signed[$_] -ne (Get-CachedHash (Join-Path $Company.Source $_)) })
    $result.Removed = @($signed.Keys | Where-Object { -not $here.Contains($_) } | Sort-Object -CaseSensitive)
    # Signed by another key than the company's (it was replaced): computers set up with the new certificate reject it
    $cert = Join-Path $Company.Keys 'wmanager-signing.cer'
    if ([IO.File]::Exists($cert)) {
        try {
            $signer = Get-ManifestSigner $path
            $own = [Security.Cryptography.X509Certificates.X509Certificate2]::new($cert).Thumbprint
            if ($signer -and $signer -ne $own) { $result.OtherKey = $signer }
        } catch { }
    }
    return $result
}

function Test-SourceChanged {
    param($Changes)
    return ($Changes.First -or $Changes.Unreadable -or $Changes.OtherKey -or
            ($Changes.Added.Count + $Changes.Changed.Count + $Changes.Removed.Count) -gt 0)
}

# Has anything in the source changed since the last signature?
function Test-UnsignedChanges {
    param($Company)
    return (Test-SourceChanged (Get-SourceChanges $Company))
}

# What the next signature would publish: + added, ~ changed, - removed
function Show-SourceChanges {
    param($Company, $Changes)
    if ($null -eq $Changes) { $Changes = Get-SourceChanges $Company }
    if ($Changes.First) {
        # publish.sh writes source-id.txt first, and signs it too
        $count = $Changes.Added.Count
        if ($Changes.Added -notcontains 'source-id.txt') { $count++ }
        Write-Host "  Never signed: the first signature publishes $(Format-Count $count 'file')."
        return
    }
    if ($Changes.Unreadable) {
        Write-Host "  manifest.psd1 can't be read ($($Changes.Unreadable)); the next signature writes it anew." -ForegroundColor Yellow
        return
    }
    $when = ''
    if ($Changes.Created) { $when = ", $($Changes.Created)" }
    if ($Changes.OtherKey) {
        Write-Host "  ! Signed with another key (certificate $($Changes.OtherKey)) than the one in keys/: sign again with it." -ForegroundColor Yellow
    }
    if (($Changes.Added.Count + $Changes.Changed.Count + $Changes.Removed.Count) -eq 0) {
        if (-not $Changes.OtherKey) { Write-Host "  Nothing changed since the last signature (manifest $($Changes.Serial)$when)." }
        return
    }
    Write-Host "  Since the last signature (manifest $($Changes.Serial)$when):"
    foreach ($f in $Changes.Added) { Write-Host "    + $f" -ForegroundColor Green }
    foreach ($f in $Changes.Changed) { Write-Host "    ~ $f" -ForegroundColor Yellow }
    foreach ($f in $Changes.Removed) { Write-Host "    - $f" -ForegroundColor Red }
}

# What a company has and what it still lacks, in a few words
function Get-CompanyState {
    param($Company)
    $parts = New-Object System.Collections.Generic.List[string]
    $hasKey = Test-HasKey $Company
    if (-not [IO.Directory]::Exists($Company.Source)) {
        $parts.Add($(if ($hasKey) { 'no source' } else { 'no management source' }))
    } else {
        try {
            $map = Import-PowerShellDataFile -LiteralPath (Join-Path $Company.Source 'groups.psd1')
            $n = 0
            if ($map.Computers -is [hashtable]) { $n = $map.Computers.Count }
            $parts.Add($(if ($n -eq 1) { '1 computer' } else { "$n computers" }))
        } catch {
            $parts.Add('groups.psd1 unreadable')
        }
        $versionFile = Join-Path $Company.Source 'version.psd1'
        if ([IO.File]::Exists($versionFile)) {
            try {
                $v = (Import-PowerShellDataFile -LiteralPath $versionFile).Version
                if ($v) { $parts.Add("wmanager $v") }
            } catch {
                $parts.Add('version.psd1 unreadable')
            }
        }
        $changes = Get-SourceChanges $Company
        if ($changes.First) { $parts.Add('not signed yet') }
        elseif ($changes.OtherKey) { $parts.Add('signed with another key') }
        elseif (Test-SourceChanged $changes) { $parts.Add('changes not signed yet') }
        if (-not $hasKey) { $parts.Add('no signing key') }
    }
    if (-not [IO.File]::Exists($Company.Config)) { $parts.Add('no configuration yet') }
    else {
        try {
            $missing = @((Get-MissingSecrets $Company).Keys)
            if ($missing.Count -eq 1) { $parts.Add("secret $($missing[0]) missing") }
            elseif ($missing.Count -gt 1) { $parts.Add("secrets $($missing -join ', ') missing") }
        } catch { $parts.Add('Secrets unreadable') }
    }
    if ([IO.File]::Exists((Join-Path $Company.Dir 'key-change.psd1'))) { $parts.Add('key change in progress') }
    return ($parts -join ', ')
}

function Show-Companies {
    $companies = @(Get-Companies)
    if ($companies.Count -eq 0) {
        Write-Host "No companies in $($script:Root) yet: pwsh tools/wm.ps1 new <company>"
        return
    }
    foreach ($c in $companies) { Write-Host ('{0,-20} {1}' -f $c.Name, (Get-CompanyState $c)) }
    # Folders whose names can't be a company's (a command, a number...) are left out: say so
    foreach ($d in @(Get-ChildItem -LiteralPath $script:Root -Directory | Where-Object { -not (Test-CompanyName $_.Name) })) {
        Write-Warn "$($d.Name) in $($script:Root) is left out: a company's name has 2 to 40 letters, digits, '.', '-', '_', with a letter, and isn't list, new, usb, status, backup, restore or help"
    }
}

# ---------------------------------------------------------------------------
# The other tools
# ---------------------------------------------------------------------------

# Runs a program in this terminal without capturing anything, so it can ask for a passphrase. Its PATH starts with
# the folder of this pwsh: tools/publish.sh checks the source with pwsh even when pwsh isn't on PATH.
function Invoke-Native {
    param([string]$File, [string[]]$Arguments, [hashtable]$Environment = @{})
    $psi = New-Object System.Diagnostics.ProcessStartInfo $File
    foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.Environment['PATH'] = (Split-Path (Get-Process -Id $PID).Path -Parent) + [IO.Path]::PathSeparator + $env:PATH
    foreach ($k in $Environment.Keys) { $psi.Environment[$k] = [string]$Environment[$k] }
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.WaitForExit()
    return $p.ExitCode
}

# A tools/groups.ps1 command on the company's source; $true when it succeeded (it says what went wrong itself)
function Invoke-Groups {
    param($Company, [string]$Command, [string[]]$Arguments = @(), [hashtable]$Named = @{})
    if (-not [IO.Directory]::Exists($Company.Source)) {
        throw "$($Company.Name) has no source yet: pwsh tools/wm.ps1 new $($Company.Name)"
    }
    $global:LASTEXITCODE = 0
    & (Join-Path $script:Tools 'groups.ps1') $Company.Source $Command @Arguments @Named | Out-Host
    return ($global:LASTEXITCODE -eq 0)
}

# Checks and signs the source with the company's key (tools/publish.sh), then sends it where the computers read it.
# First it shows what the signature publishes and asks (-Confirmed: the caller already did; also for sending): nothing
# changed means no signature unless you want one (e.g. after a new certificate), and an offer to send what was signed
# before (a push that failed, say). Returns what Sync-Company's check found, $null when nothing was sent.
function Publish-Company {
    param($Company, [switch]$Confirmed, [switch]$Wait)
    if (-not [IO.Directory]::Exists($Company.Source)) { throw "$($Company.Name) has no source yet: pwsh tools/wm.ps1 new $($Company.Name)" }
    if (-not (Test-HasKey $Company)) { throw "$($Company.Name) has no signing key in $($Company.Keys): pwsh tools/wm.ps1 new $($Company.Name)" }
    $target = Get-PublishTarget $Company
    $sign = $true
    $changed = $true
    # A script naming a secret the configuration lacks doesn't run on the computers: say so, it is no reason not to sign
    try {
        $missing = Get-MissingSecrets $Company
        foreach ($n in $missing.Keys) {
            Write-Warn "$($missing[$n] -join ', ') name the secret $n, which $($Company.Name)'s configuration doesn't have: they won't run (pwsh tools/wm.ps1 $($Company.Name) secret $n, then run.cmd with it)"
        }
    } catch { Write-Warn "the secrets of the configuration can't be read: $(Format-WmErrorText $_ -English)" }
    if (-not $Confirmed) {
        $changes = Get-SourceChanges $Company
        Show-SourceChanges $Company $changes
        $changed = Test-SourceChanged $changes
        $sign = if ($changed) { Read-WmYesNo 'Sign and publish this?' $true } else { Read-WmYesNo 'Sign it again anyway?' $false }
        if (-not $sign) { Write-Host '  Not signed.' }
    }
    if ($sign) {
        # With a place to send it to, publish.sh leaves out its "now push / copy it" (this does it next)
        $quiet = @{}
        if ($target) { $quiet['WM_PUBLISH_SENT_BY_CALLER'] = '1' }
        $code = Invoke-Native 'bash' @((Join-Path $script:Tools 'publish.sh'), $Company.Source, $Company.Keys) $quiet
        if ($code -ne 0) { throw 'not signed (the reason is above)' }
    } elseif ($changed) {
        return $null
    }
    if (-not $target) {
        if ($sign) { Write-Host "  To send it from here next time: pwsh tools/wm.ps1 $($Company.Name) target" }
        return $null
    }
    if ($Confirmed -or (Read-WmYesNo "Send it where the computers read it ($target)?" $sign)) { return (Sync-Company $Company -Wait:$Wait) }
    return $null
}

# The configuration wizard for the company's provision.config.psd1, with its certificate next to it
function Invoke-Wizard {
    param($Company)
    New-Item -ItemType Directory -Force -Path $Company.ConfigDir | Out-Null
    # The certificate of the key that signs the source, also after the key was replaced: the computers check the
    # source with the certificate next to the configuration, so another one would make them reject it
    $cer = Join-Path $Company.Keys 'wmanager-signing.cer'
    $dest = Join-Path $Company.ConfigDir 'wmanager-signing.cer'
    if ([IO.File]::Exists($cer)) {
        if (-not [IO.File]::Exists($dest)) {
            Copy-Item -LiteralPath $cer -Destination $dest
        } elseif ((Get-FileHash -LiteralPath $cer).Hash -ne (Get-FileHash -LiteralPath $dest).Hash) {
            Copy-Item -LiteralPath $cer -Destination $dest -Force
            Write-Warn "config/wmanager-signing.cer was another certificate than the one of the key in keys/; replaced (computers set up with the old one need the new one too)"
        }
    }
    # The identifier of the source, offered while the computers can't read the source yet
    $id = ''
    $idFile = Join-Path $Company.Source 'source-id.txt'
    if ([IO.File]::Exists($idFile)) { $id = [IO.File]::ReadAllText($idFile).Trim() }
    $global:LASTEXITCODE = 0
    & (Join-Path $repo 'init.ps1') -ConfigPath $Company.Config -DefaultSourceId $id
    if ($global:LASTEXITCODE -ne 0) { throw 'the wizard stopped (the reason is above)' }
    Write-Host ''
    Write-Host 'For the computers: pwsh tools/wm.ps1 usb <folder> puts wmanager and the configuration of every company'
    Write-Host 'onto a USB drive or a share; run.cmd from there asks which company the computer is for.'
}

# ---------------------------------------------------------------------------
# A new company
# ---------------------------------------------------------------------------

# Every step checks whether it's done, so running it again carries on after a step that stopped
function New-Company {
    param([string]$Name)
    if (-not (Test-CompanyName $Name)) {
        throw "invalid company name '$Name': 2 to 40 letters, digits, '.', '-', '_', with a letter (not list, new, usb, status, backup, restore or help)"
    }
    # Folders that differ only in letter case would be one folder on the USB drive (configs\<company>)
    $other = @(Get-Companies | Where-Object { $_.Name -ieq $Name -and $_.Name -cne $Name })
    if ($other.Count -gt 0) { throw "there is a company $($other[0].Name) already; names that differ only in letter case would mix up on a USB drive" }
    $c = Get-CompanyPaths $Name
    New-Item -ItemType Directory -Force -Path $c.Dir | Out-Null

    Write-Step "1/4 Signing key: $($c.Keys)"
    if (Test-HasKey $c) {
        Write-Host '  Already there.'
    } else {
        Write-Host '  A key of its own: a company that leaves takes its key and has no way into the others.'
        $null = New-KeyFolder $c.Keys "pwsh tools/wm.ps1 new $Name"
    }

    Write-Step "2/4 Management source: $($c.Source)"
    if ([IO.Directory]::Exists($c.Source)) {
        Write-Host '  Already there.'
    } else {
        Copy-Item -LiteralPath (Join-Path $repo 'examples/management') -Destination $c.Source -Recurse
        Write-Host '  Copied from examples/management: groups.psd1 (computers and their groups), choco-reqs.txt (programs'
        Write-Host '  of every computer) and groups/. Change them from the menu of the company, or by hand.'
    }

    Write-Step '3/4 First signature (it gives the source its identifier, source-id.txt)'
    if ([IO.File]::Exists((Join-Path $c.Source 'manifest.psd1'))) {
        Write-Host '  Already signed.'
    } else {
        try { $null = Publish-Company $c -Confirmed }
        catch { throw "$(Format-WmErrorText $_ -English); to carry on: pwsh tools/wm.ps1 new $Name" }
    }

    Write-Step "4/4 Configuration for the computers: $($c.Config)"
    if ([IO.File]::Exists($c.Config)) {
        Write-Host "  Already there; to change it: pwsh tools/wm.ps1 $Name config"
    } else {
        Write-Host '  The computers read the source from a private Git repository or from a folder (a web server, a share).'
        if (-not (Get-PublishTarget $c)) {
            if (Read-WmYesNo '  Set up where it goes now?' $true) { Set-PublishTarget $c }
            else { Write-Host "  Later: pwsh tools/wm.ps1 $Name target" }
        }
        Write-Host '  The wizard asks for the address the computers read it from, then for the update time, Loki and'
        Write-Host '  Healthchecks (all optional).'
        if (Read-WmYesNo '  Run the wizard now?' $true) { Invoke-Wizard $c }
        else { Write-Host "  Later: pwsh tools/wm.ps1 $Name config" }
    }
    Write-Host ''
    Write-Host ('Company {0}: {1}' -f $Name, (Get-CompanyState $c))
    Write-Host 'Next: computers to groups (the menu of the company), then wmanager onto a USB drive: pwsh tools/wm.ps1 usb <folder>'
}

# ---------------------------------------------------------------------------
# USB drive or share
# ---------------------------------------------------------------------------

# The certificate file a configuration names; $null without a management source. Only a file name next to the
# configuration, as provisioning accepts it (Get-WmCertificateFileName): it is joined into paths on the drive.
function Get-ConfigCertificate {
    param([string]$Path)
    $m = (Import-PowerShellDataFile -LiteralPath $Path).Management
    if (-not ($m -is [hashtable]) -or -not $m.Source) { return $null }
    $name = if ($m.Certificate) { [string]$m.Certificate } else { 'wmanager-signing.cer' }
    if ($name -match '[\\/:]' -or @('.', '..') -contains $name.Trim()) {
        throw "Management.Certificate in $Path is not a plain file name ('$name')"
    }
    return $name
}

# SHA256SUMS of the latest release into $Work; returns the release's tag. install.ps1's functions read it.
function Get-LatestSums {
    param([string]$Work)
    $sums = Join-Path $Work 'SHA256SUMS'
    try { Invoke-WebRequest -Uri "$($script:Releases)/latest/download/SHA256SUMS" -OutFile $sums -TimeoutSec 60 }
    catch { throw "can't reach the wmanager releases ($($script:Releases)): $($_.Exception.Message)" }
    return ((Get-WmZipName -SumsFile $sums) -replace '^wmanager-(.+)\.zip$', '$1')
}

function New-WorkFolder {
    $work = Join-Path ([IO.Path]::GetTempPath()) ('wmanager-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    return $work
}

# The tag of the latest wmanager release
function Get-LatestTag {
    $WmInstallNoRun = $true   # install.ps1 only defines its functions (here, in this function)
    . (Join-Path $repo 'install.ps1')
    $work = New-WorkFolder
    try { return Get-LatestSums $work }
    finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

# The latest release into $Folder, checked against its SHA256SUMS the way install.ps1 checks it
function Save-Release {
    param([string]$Folder)
    $WmInstallNoRun = $true
    . (Join-Path $repo 'install.ps1')
    $work = New-WorkFolder
    try {
        $tag = Get-LatestSums $work
        $zipName = "wmanager-$tag.zip"
        Write-Host "Downloading wmanager $tag from $($script:Releases)..."
        $zip = Join-Path $work $zipName
        Invoke-WebRequest -Uri "$($script:Releases)/download/$tag/$zipName" -OutFile $zip -TimeoutSec 300
        Assert-WmSha256 -File $zip -SumsFile (Join-Path $work 'SHA256SUMS')
        Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $work 'unpacked')
        Copy-Item -Path (Join-Path $work 'unpacked/wmanager/*') -Destination $Folder -Recurse -Force
        Write-Host "wmanager $tag (SHA-256 checked) copied to $Folder."
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# wmanager and the configuration of every company into a folder on a USB drive or a share: run.cmd from there asks
# which company the computer is for (configs\<company>\, lib\Common.ps1 Find-WmConfig)
function Copy-ToUsb {
    param([string]$Folder)
    if (-not $Folder) { throw 'usage: pwsh tools/wm.ps1 usb <folder>, e.g. /media/you/USB/wmanager' }
    $Folder = ConvertTo-FullPath $Folder
    $companies = @(Get-Companies)
    $ready = @($companies | Where-Object { [IO.File]::Exists($_.Config) })
    if ($ready.Count -eq 0) { throw 'no company has a configuration yet: pwsh tools/wm.ps1 <company> config' }
    # A USB drive (FAT, exFAT, NTFS) doesn't tell letter case apart: acme and Acme would share one folder there
    $clash = @($companies | Group-Object { $_.Name.ToLowerInvariant() } | Where-Object { $_.Count -gt 1 } | Select-Object -First 1)
    if ($clash.Count -gt 0) {
        throw "the companies $(@($clash[0].Group.Name) -join ' and ') differ only in letter case and would be one folder on the drive; rename one"
    }
    New-Item -ItemType Directory -Force -Path $Folder | Out-Null

    if ([IO.File]::Exists((Join-Path $Folder 'Provision.ps1'))) {
        $versionFile = Join-Path $Folder 'VERSION'
        $what = if ([IO.File]::Exists($versionFile)) { 'wmanager ' + [IO.File]::ReadAllText($versionFile).Trim() } else { 'wmanager' }
        Write-Host "$what is already in $Folder; kept (for the latest release, empty the folder first)."
    } else {
        Save-Release $Folder
    }
    if ([IO.File]::Exists((Join-Path $Folder 'provision.config.psd1'))) {
        Write-Warn "$Folder has its own provision.config.psd1, which run.cmd uses without asking for the company; remove it to choose"
    }
    # A wmanager older than the choice of company would not look into configs\ and would use the example configuration
    $common = Join-Path (Join-Path $Folder 'lib') 'Common.ps1'
    $chooses = [IO.File]::Exists($common) -and [IO.File]::ReadAllText($common).Contains('function Find-WmConfig')
    if (-not $chooses) {
        Write-Warn ("this wmanager doesn't ask for the company yet (it's older than that): on the computer give the configuration " +
            'yourself, e.g. run.cmd -ConfigPath E:\wmanager\configs\<company>\provision.config.psd1, or empty the folder and copy a newer release')
    }

    $configs = Join-Path $Folder 'configs'
    foreach ($c in $ready) {
        $dest = Join-Path $configs $c.Name
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        Copy-Item -LiteralPath $c.Config -Destination (Join-Path $dest 'provision.config.psd1') -Force
        $cert = Get-ConfigCertificate $c.Config
        if ($cert) {
            $from = Join-Path $c.ConfigDir $cert
            if ([IO.File]::Exists($from)) { Copy-Item -LiteralPath $from -Destination (Join-Path $dest $cert) -Force }
            else { Write-Warn "$($c.Name): no $cert next to its configuration, so provisioning stops for it (pwsh tools/wm.ps1 $($c.Name) config)" }
        }
        Write-Host "  configs/$($c.Name)"
    }
    $without = @($companies | Where-Object { -not [IO.File]::Exists($_.Config) })
    foreach ($d in @(Get-ChildItem -LiteralPath $configs -Directory)) {
        if (@($ready | Where-Object { $_.Name -eq $d.Name }).Count -gt 0) { continue }
        if (@($without | Where-Object { $_.Name -eq $d.Name }).Count -gt 0) {
            Write-Warn "$($d.Name) has no configuration here now, but the drive still has configs/$($d.Name) from before, which run.cmd offers; remove it if it is out of date"
        } else {
            Write-Warn "configs/$($d.Name) on the drive is not one of the companies here; left as it is"
        }
    }
    foreach ($c in $without) {
        if (-not [IO.Directory]::Exists((Join-Path $configs $c.Name))) {
            Write-Warn "$($c.Name) has no configuration yet, so it isn't on the drive: pwsh tools/wm.ps1 $($c.Name) config"
        }
    }
    Write-Host ''
    if ($chooses) { Write-Host "Done. On the computer, run.cmd from $Folder asks which company the computer is for." }
    else { Write-Host "Done. On the computer: run.cmd -ConfigPath <this folder>\configs\<company>\provision.config.psd1" }
    Write-Host 'The configurations hold the tokens (Loki, Healthchecks, the source) and the secrets of the scripts: keep the drive under control.'
}

# ---------------------------------------------------------------------------
# The computers: what Healthchecks and Loki know, read with read-only keys kept on this computer
# ---------------------------------------------------------------------------

$script:StatusDays = 14   # how far back Loki is read (Grafana Cloud's free plan keeps 14 days)
# Lines per Loki request (Grafana Cloud's limit); more are read page by page. WMANAGER_LOKI_PAGE: for the tests.
$script:LokiPage = if ($env:WMANAGER_LOKI_PAGE) { [int]$env:WMANAGER_LOKI_PAGE } else { 5000 }
$script:LokiPages = 20
# The prefix Write-WmLog (lib/Common.ps1) puts before each line it sends to Loki
$script:LogPrefix = '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d \[[A-Z]+\] '

# https only, except on this computer (the tests' stand-in servers)
function Test-ServiceUrl {
    param([string]$Url)
    return ($Url -match '^https://[^/]' -or $Url -match '^http://(127\.0\.0\.1|localhost)(:\d+)?(/|$)')
}

# A secret typed at the terminal without showing it. Piped input: as it comes, but not printed back as Read-Host
# would, so a secret passed by a script doesn't end up in its output either.
function Read-Secret {
    param([string]$Prompt)
    if ([Console]::IsInputRedirected) {
        Write-Host "${Prompt}: " -NoNewline
        $line = [Console]::In.ReadLine()
        Write-Host ''
        if ($null -eq $line) { return '' }
        return $line.Trim()
    }
    $secure = Read-Host $Prompt -AsSecureString
    return ([Net.NetworkCredential]::new('', $secure).Password).Trim()
}

# A file only you can read: created so (no moment with the umask's mode), and checked
# -New: only a file that isn't there yet (an IOException otherwise)
function Write-PrivateFile {
    param([string]$Path, [string]$Text, [switch]$New)
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Text)
    if ($IsWindows) { [IO.File]::WriteAllBytes($Path, $bytes); return }
    $mode = [IO.UnixFileMode]'UserRead, UserWrite'
    $opts = New-Object IO.FileStreamOptions
    $opts.Mode = if ($New) { [IO.FileMode]::CreateNew } else { [IO.FileMode]::Create }
    $opts.Access = [IO.FileAccess]::Write
    $opts.UnixCreateMode = $mode
    $fs = New-Object IO.FileStream($Path, $opts)
    try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
    [IO.File]::SetUnixFileMode($Path, $mode)   # a file that was there keeps its mode otherwise
    if ([IO.File]::GetUnixFileMode($Path) -ne $mode) { throw "can't make $Path readable by you only" }
}

# <company>/monitoring.psd1: the read-only keys of its Healthchecks project and Grafana Cloud stack. Never on the
# computers or the drive: the computers have write-only ones in their configuration.
function Get-MonitoringPath {
    param($Company)
    return (Join-Path $Company.Dir 'monitoring.psd1')
}

function Read-Monitoring {
    param($Company)
    $path = Get-MonitoringPath $Company
    if (-not [IO.File]::Exists($path)) { return $null }
    return (Import-PowerShellDataFile -LiteralPath $path)
}

function Test-HasMonitoringKeys {
    param($Monitoring)
    return ($null -ne $Monitoring -and ($Monitoring.HealthchecksApiKey -or $Monitoring.LokiReadToken))
}

# Where the company's computers send their logs and pings: from its provision.config.psd1. The Healthchecks API is
# healthchecks.io for hc-ping.com, and the same address without /ping for a server of your own, unless
# monitoring.psd1 names another (HealthchecksApiUrl).
function Read-Reporting {
    param($Company, $Monitoring)
    if (-not [IO.File]::Exists($Company.Config)) { throw "$($Company.Name) has no configuration yet: pwsh tools/wm.ps1 $($Company.Name) config" }
    $cfg = Import-PowerShellDataFile -LiteralPath $Company.Config
    $loki = ([string]$cfg.LokiUrl).TrimEnd('/') -replace '/loki/api/v1/push$', ''
    $hcBase = if ($cfg.HealthchecksBaseUrl) { ([string]$cfg.HealthchecksBaseUrl).TrimEnd('/') } else { 'https://hc-ping.com' }
    $hcApi = if ($hcBase -match '^https://hc-ping\.com$') { 'https://healthchecks.io' } else { $hcBase -replace '/ping$', '' }
    if ($Monitoring -and $Monitoring.HealthchecksApiUrl) { $hcApi = ([string]$Monitoring.HealthchecksApiUrl).TrimEnd('/') }
    return [pscustomobject]@{
        LokiUrl    = $loki
        LokiUser   = [string]$cfg.LokiUser
        HasLoki    = [bool]($loki -and $cfg.LokiToken)
        HasPings   = [bool]$cfg.HealthchecksPingKey
        HcApiUrl   = $hcApi
        SlugPrefix = ([string]$cfg.HealthchecksSlugPrefix).ToLowerInvariant() -replace '[^a-z0-9_-]', '-'
    }
}

# Asks for the read-only keys and keeps them in <company>/monitoring.psd1 (readable by you only)
function Set-Monitoring {
    param($Company)
    $r = Read-Reporting $Company $null
    if (-not $r.HasPings -and -not $r.HasLoki) {
        throw "the configuration of $($Company.Name) sends nothing to Healthchecks or Loki; set them up first: pwsh tools/wm.ps1 $($Company.Name) config"
    }
    $old = @{}
    try { $read = Read-Monitoring $Company; if ($read) { $old = $read } }
    catch { Write-Warn "$(Get-MonitoringPath $Company) can't be read ($($_.Exception.Message)); asking for the keys anew" }
    Write-Step "Read-only access for the status of the computers of $($Company.Name)"
    Write-Host '  The keys stay on this computer, in' (Get-MonitoringPath $Company)
    $hcKey = [string]$old.HealthchecksApiKey
    if ($r.HasPings) {
        Write-Host '  Healthchecks: in the project the computers ping, Settings > API Access > Create API key (read-only).'
        $hint = if ($hcKey) { 'Enter = keep the one you have, - = none' } else { 'Enter = none' }
        $a = Read-Secret "  Healthchecks read-only API key ($hint)"
        if ($a -eq '-') { $hcKey = '' } elseif ($a) { $hcKey = $a }
    }
    $lokiToken = [string]$old.LokiReadToken
    if ($r.HasLoki) {
        Write-Host '  Grafana Cloud: Administration > Access policies > a policy with the logs:read scope, then Add token.'
        Write-Host "  (The user is the configuration's LokiUser, $($r.LokiUser).)"
        $hint = if ($lokiToken) { 'Enter = keep the one you have, - = none' } else { 'Enter = none' }
        $a = Read-Secret "  Grafana Cloud token with logs:read ($hint)"
        if ($a -eq '-') { $lokiToken = '' } elseif ($a) { $lokiToken = $a }
    }
    $text = @(
        '# Read-only access for pwsh tools/wm.ps1 <company> status. Written by it; it stays on this computer, never on the'
        '# drive or the computers (they have write-only keys in provision.config.psd1).'
        '@{'
        '    # Healthchecks: the read-only API key of the project the computers ping'
        "    HealthchecksApiKey = $(ConvertTo-WmPsdString $hcKey)"
        '    # Its API address, when it is neither healthchecks.io nor the HealthchecksBaseUrl of the configuration without /ping'
        "    HealthchecksApiUrl = $(ConvertTo-WmPsdString ([string]$old.HealthchecksApiUrl))"
        '    # Grafana Cloud: a token with the logs:read scope (with the LokiUser and LokiUrl of the configuration)'
        "    LokiReadToken      = $(ConvertTo-WmPsdString $lokiToken)"
        '}'
        ''
    ) -join "`n"
    $path = Get-MonitoringPath $Company
    Write-PrivateFile $path $text
    Write-Host "  Saved: $path"
}

# Healthchecks: every check of the project, by slug, with its state and last ping
function Get-HealthchecksStatus {
    param($Reporting, $Monitoring)
    if (-not (Test-ServiceUrl $Reporting.HcApiUrl)) { throw "the Healthchecks API must be an https:// address ('$($Reporting.HcApiUrl)')" }
    $resp = Invoke-RestMethod -Uri "$($Reporting.HcApiUrl)/api/v3/checks/" -Headers @{ 'X-Api-Key' = [string]$Monitoring.HealthchecksApiKey } -TimeoutSec 20
    $result = @{}
    foreach ($c in @($resp.checks)) {
        if ($c.slug) { $result[[string]$c.slug] = [pscustomobject]@{ Status = [string]$c.status; LastPing = ConvertTo-Time $c.last_ping } }
    }
    return $result
}

# A time from an API (an ISO 8601 text, or what ConvertFrom-Json already made of it); $null for none
function ConvertTo-Time {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [datetime]) { return ([datetimeoffset]$Value.ToUniversalTime()).ToLocalTime() }
    return [datetimeoffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture).ToLocalTime()
}

function ConvertFrom-LokiTime {
    param([string]$Nanoseconds)
    return [datetimeoffset]::FromUnixTimeMilliseconds([long]($Nanoseconds.Substring(0, $Nanoseconds.Length - 6))).ToLocalTime()
}

function Invoke-Loki {
    param($Reporting, $Monitoring, [string]$Path, [System.Collections.Specialized.OrderedDictionary]$Query)
    if (-not (Test-ServiceUrl $Reporting.LokiUrl)) { throw "LokiUrl must be an https:// address ('$($Reporting.LokiUrl)')" }
    $pair = '{0}:{1}' -f $Reporting.LokiUser, $Monitoring.LokiReadToken
    $headers = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair)) }
    $q = @($Query.Keys | ForEach-Object { '{0}={1}' -f $_, [uri]::EscapeDataString([string]$Query[$_]) }) -join '&'
    return Invoke-RestMethod -Uri "$($Reporting.LokiUrl)$Path`?$q" -Headers $headers -TimeoutSec 30
}

function New-HostRecord {
    return [pscustomobject]@{ Version = $null; VersionAt = $null; FromRecord = $false; LastRun = $null; Warnings = 0; Errors = 0
                              Errors24h = 0; Cert = ''; Next = '' }
}

# Loki: for each computer (the host label, lowercase) its last run and the errors of the last 24 hours, jobs
# included. The version is the one of the newest run record (Add-WmRunRecord: the version that finished the run);
# computers older than that record only have the run's start line, which names the version that started it. The
# lines are always English, after the prefix of Write-WmLog, so fixed patterns read every computer.
function Get-LokiStatus {
    param($Reporting, $Monitoring)
    $now = [datetimeoffset]::UtcNow
    $ns = { param($t) [string]($t.ToUnixTimeMilliseconds() * 1000000) }
    $start = & $ns $now.AddDays(-$script:StatusDays)
    $query = '{service_name="wmanager", job=~"update|retry|provision"} |~ `^\{"wmanager_run"|^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d \[[A-Z]+\] (wmanager( v\S+)? (update|retry) on |wmanager( v\S+)? provisioning: |End: warnings |Done: \d+ warnings)`'
    $result = @{}
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $end = & $ns $now
    # Newest first, a page at a time: with many computers 14 days hold more lines than one request returns, and the
    # computer that stopped updating is the one whose lines are oldest
    for ($page = 0; $page -lt $script:LokiPages; $page++) {
        $runs = Invoke-Loki $Reporting $Monitoring '/loki/api/v1/query_range' ([ordered]@{
            query = $query; start = $start; end = $end; limit = $script:LokiPage; direction = 'backward'
        })
        $count = 0; $fresh = 0; $oldest = $end
        foreach ($s in @($runs.data.result)) {
            $hostName = [string]$s.stream.host
            foreach ($v in @($s.values)) {
                $count++
                if ([decimal]$v[0] -lt [decimal]$oldest) { $oldest = [string]$v[0] }
                if (-not $hostName -or -not $seen.Add("$hostName $($v[0]) $($v[1])")) { continue }
                $fresh++
                if (-not $result.ContainsKey($hostName)) { $result[$hostName] = New-HostRecord }
                Add-LokiLine $result[$hostName] (ConvertFrom-LokiTime $v[0]) ([string]$v[1])
            }
        }
        if ($count -lt $script:LokiPage -or $fresh -eq 0) { break }
        $end = $oldest
    }
    $errors = Invoke-Loki $Reporting $Monitoring '/loki/api/v1/query' ([ordered]@{
        query = 'sum by (host) (count_over_time({service_name="wmanager", level="error"}[24h]))'
        time  = (& $ns $now)
    })
    foreach ($e in @($errors.data.result)) {
        $hostName = [string]$e.metric.host
        if (-not $hostName) { continue }
        if (-not $result.ContainsKey($hostName)) { $result[$hostName] = New-HostRecord }
        $result[$hostName].Errors24h = [int][double]$e.value[1]
    }
    return $result
}

# One line of a run into what is known of its computer
function Add-LokiLine {
    param($Record, [datetimeoffset]$At, [string]$Line)
    if ($Line.StartsWith('{"wmanager_run"')) {
        $run = $Line | ConvertFrom-Json
        if (-not $Record.FromRecord -or $At -gt $Record.VersionAt) {
            $Record.FromRecord = $true
            $Record.VersionAt = $At
            $Record.Version = if ($run.wmanager_run) { [string]$run.wmanager_run } else { '?' }
            $Record.Cert = [string]$run.cert   # the signing certificates it trusts (a key change)
            $Record.Next = [string]$run.next
        }
        if ($null -eq $Record.LastRun -or $At -ge $Record.LastRun) { $Record.LastRun = $At; $Record.Warnings = [int]$run.warnings; $Record.Errors = [int]$run.errors }
        return
    }
    $text = $Line -replace $script:LogPrefix, ''
    if ($text -match '^wmanager(?: (v\S+))? (?:update|retry) on |^wmanager(?: (v\S+))? provisioning: ') {
        if (-not $Record.FromRecord -and ($null -eq $Record.VersionAt -or $At -gt $Record.VersionAt)) {
            $Record.VersionAt = $At
            $Record.Version = if ($Matches[1]) { $Matches[1] } elseif ($Matches[2]) { $Matches[2] } else { '?' }
        }
    } elseif ($text -match '^End: warnings (\d+), errors (\d+)' -or $text -match '^Done: (\d+) warnings, (\d+) errors') {
        if ($null -eq $Record.LastRun -or $At -gt $Record.LastRun) { $Record.LastRun = $At; $Record.Warnings = [int]$Matches[1]; $Record.Errors = [int]$Matches[2] }
    }
}

function Format-Count {
    param([int]$Count, [string]$Thing)
    if ($Count -eq 1) { return "1 $Thing" }
    return "$Count ${Thing}s"
}

# How long ago, short: (45m), (5h), (3d)
function Format-Age {
    param($Time)
    if ($null -eq $Time) { return '' }
    $span = [datetimeoffset]::Now - $Time
    if ($span.TotalMinutes -lt 60) { return '({0}m)' -f [int][math]::Max(0, [math]::Floor($span.TotalMinutes)) }
    if ($span.TotalHours -lt 48) { return '({0}h)' -f [int][math]::Floor($span.TotalHours) }
    return '({0}d)' -f [int][math]::Floor($span.TotalDays)
}

# The computers of a company: the ones groups.psd1 names and the ones Healthchecks or Loki know, with what each
# reported. HcOk/LokiOk: $null = not asked (no key or not set up), $false = the service failed (see Problems).
function Get-ComputerStatus {
    param($Company)
    $m = Read-Monitoring $Company
    if (-not (Test-HasMonitoringKeys $m)) {
        throw "no read-only keys for $($Company.Name) yet: pwsh tools/wm.ps1 $($Company.Name) monitoring"
    }
    $r = Read-Reporting $Company $m
    $problems = New-Object System.Collections.Generic.List[string]
    $hc = $null; $hcOk = $null
    if ($m.HealthchecksApiKey -and $r.HasPings) {
        try { $hc = Get-HealthchecksStatus $r $m; $hcOk = $true } catch { $hcOk = $false; $problems.Add("Healthchecks: $($_.Exception.Message)") }
    }
    $loki = $null; $lokiOk = $null
    if ($m.LokiReadToken -and $r.HasLoki) {
        try { $loki = Get-LokiStatus $r $m; $lokiOk = $true } catch { $lokiOk = $false; $problems.Add("Loki: $($_.Exception.Message)") }
    }

    # The names: groups.psd1's spelling, otherwise what reported, in capitals (Windows computer names)
    $names = @{}
    $map = $null
    $versions = $null
    try {
        $map = Import-PowerShellDataFile -LiteralPath (Join-Path $Company.Source 'groups.psd1')
        if ($map.Computers -is [hashtable]) { foreach ($k in $map.Computers.Keys) { $names[([string]$k).ToLowerInvariant()] = [string]$k } }
    } catch { }
    try {
        $vf = Join-Path $Company.Source 'version.psd1'
        if ([IO.File]::Exists($vf)) { $versions = ConvertFrom-WmVersionData (Import-PowerShellDataFile -LiteralPath $vf) }
    } catch { }
    if ($loki) { foreach ($k in $loki.Keys) { if (-not $names.ContainsKey($k)) { $names[$k] = $k.ToUpperInvariant() } } }
    # Healthchecks: a computer's check is the configuration's prefix + its name, as the computers ping it. Without a
    # prefix the project's other checks can't be told apart: only the computers known from groups.psd1 or Loki.
    $checks = @{}
    $otherChecks = 0
    if ($hc) {
        foreach ($slug in $hc.Keys) {
            if ($r.SlugPrefix -and -not $slug.StartsWith($r.SlugPrefix)) { continue }
            $name = $slug.Substring($r.SlugPrefix.Length)
            if (-not $r.SlugPrefix -and -not $names.ContainsKey($name)) { $otherChecks++; continue }
            $checks[$name] = $hc[$slug]
            if (-not $names.ContainsKey($name)) { $names[$name] = $name.ToUpperInvariant() }
        }
    }
    # "Silent" only when every service that was asked answered: a failed one knows nothing either way
    $allAnswered = ($hcOk -ne $false) -and ($lokiOk -ne $false) -and ($hcOk -or $lokiOk)

    $rows = foreach ($k in ($names.Keys | Sort-Object)) {
        $h = $checks[$k]
        $l = if ($loki) { $loki[$k] } else { $null }
        $want = $null
        if ($versions -and $map) {
            $groups = Get-WmComputerGroups -Map $map -ComputerName $names[$k]
            $w = Get-WmWantedVersion $versions (Get-WmVersionGroupOrder -Map $map -Groups $groups)
            if ($w) { $want = $w.Version }
        }
        $flags = New-Object System.Collections.Generic.List[string]
        if ($h -and $h.Status -eq 'down') { $flags.Add('down') }
        if ($l -and ($l.Errors -gt 0 -or $l.Errors24h -gt 0)) { $flags.Add('errors') }
        if ($want -and $l -and $l.Version -and $l.Version -ne '?' -and $l.Version -ne $want) { $flags.Add('version') }
        if ($allAnswered -and -not $h -and -not $l) { $flags.Add('silent') }
        [pscustomobject]@{ Name = $names[$k]; Check = $h; Log = $l; Want = $want; Flags = @($flags) }
    }
    return [pscustomobject]@{
        Rows = @($rows); Problems = @($problems); HcOk = $hcOk; LokiOk = $lokiOk; OtherChecks = $otherChecks
    }
}

function Show-ComputerStatus {
    param($Company)
    $s = Get-ComputerStatus $Company
    foreach ($p in $s.Problems) { Write-Warn $p }
    if ($s.Rows.Count -eq 0) { Write-Host "No computers of $($Company.Name) in groups.psd1, Healthchecks or Loki yet."; return }
    $format = '{0,-16} {1,-14} {2,-24} {3,-24} {4}'
    Write-Host ($format -f 'Computer', 'Healthchecks', 'Last update', 'Result', 'wmanager')
    # '-' nothing reported, '?' the service failed, empty: not asked
    $none = @{ $true = '-'; $false = '?' }
    foreach ($row in $s.Rows) {
        $check = ''
        if ($row.Check) { $check = ('{0} {1}' -f $row.Check.Status, (Format-Age $row.Check.LastPing)).Trim() }
        elseif ($null -ne $s.HcOk) { $check = $none[[bool]$s.HcOk] }
        $last = ''; $result = ''; $version = ''
        if ($row.Log) {
            $last = '-'; $result = '-'; $version = '-'
            if ($row.Log.LastRun) {
                $last = '{0} {1}' -f $row.Log.LastRun.ToString('yyyy-MM-dd HH:mm'), (Format-Age $row.Log.LastRun)
                $result = if ($row.Log.Errors) { Format-Count $row.Log.Errors 'error' } elseif ($row.Log.Warnings) { Format-Count $row.Log.Warnings 'warning' } else { 'ok' }
            }
            if ($row.Log.Errors24h) { $result = ('{0}, {1} errors/24h' -f $result, $row.Log.Errors24h).TrimStart('-, ') }
            if ($row.Log.Version) { $version = $row.Log.Version }
        } elseif ($null -ne $s.LokiOk) {
            $last = $result = $version = $none[[bool]$s.LokiOk]
        }
        if ($row.Flags -contains 'version') { $version = "$version -> $($row.Want)" }
        $color = if ($row.Flags -contains 'down' -or $row.Flags -contains 'errors') { 'Red' } elseif ($row.Flags.Count -gt 0) { 'Yellow' } else { 'Gray' }
        Write-Host ($format -f $row.Name, $check, $last, $result, $version) -ForegroundColor $color
    }
    Write-Host ''
    Write-Host (Format-StatusSummary $s)
    $line = Format-KeyChangeLine $Company $s
    if ($line) { Write-Host "$line; then: pwsh tools/wm.ps1 $($Company.Name) rotate-key" -ForegroundColor Cyan }
    Write-Host "Loki: the last $($script:StatusDays) days. (5h) = 5 hours ago; - = nothing reported; ? = the service didn't answer;"
    Write-Host 'a -> b = runs a, switches to b at its next update.'
    if ($s.OtherChecks -gt 0) {
        Write-Host "$($s.OtherChecks) other checks of the Healthchecks project left out: without HealthchecksSlugPrefix only the computers known from groups.psd1 or Loki count."
    }
}

function Format-StatusSummary {
    param($Status)
    $parts = @('{0} computers' -f $Status.Rows.Count)
    foreach ($f in @(@('down', 'down'), @('errors', 'with errors'), @('version', 'not on their version yet'),
                     @('silent', "silent for $($script:StatusDays) days"))) {
        $n = @($Status.Rows | Where-Object { $_.Flags -contains $f[0] }).Count
        if ($n -gt 0) { $parts += "$n $($f[1])" }
    }
    if ($parts.Count -eq 1 -and $Status.Problems.Count -eq 0) { $parts += 'all fine' }
    return ($parts -join ', ')
}

# One line per company: the summary of its computers
function Show-AllStatus {
    $companies = @(Get-Companies)
    if ($companies.Count -eq 0) { Write-Host "No companies in $($script:Root) yet: pwsh tools/wm.ps1 new <company>"; return }
    foreach ($c in $companies) {
        try {
            $s = Get-ComputerStatus $c
            $line = Format-StatusSummary $s
            if ($s.Problems.Count -gt 0) { $line += ' (' + ($s.Problems -join '; ') + ')' }
            $kcLine = Format-KeyChangeLine $c $s
            if ($kcLine) { $line += "; $kcLine" }
        } catch {
            $line = Format-WmErrorText $_ -English
        }
        Write-Host ('{0,-20} {1}' -f $c.Name, $line)
    }
}

# ---------------------------------------------------------------------------
# Where the computers read the source: sending the signed source there, and checking they can see it
# ---------------------------------------------------------------------------

# How long the check waits for an address that still gives the old manifest (a host such as GitHub keeps raw files up
# to 5 minutes). WMANAGER_TEST_WAIT: for the tests.
$script:PublishWaitSeconds = if ($env:WMANAGER_TEST_WAIT) { [int]$env:WMANAGER_TEST_WAIT } else { 300 }

# <company>/publish.psd1: where "sync" sends the signed source. 'git' = the source is a Git repository of its own,
# sync commits and pushes it; anything else is a folder: a path on this computer (e.g. a mounted share) or
# user@host:/path (rsync). $null when not set; throws when the file can't be read.
function Get-PublishTargetPath {
    param($Company)
    return (Join-Path $Company.Dir 'publish.psd1')
}

function Get-PublishTarget {
    param($Company)
    $path = Get-PublishTargetPath $Company
    if (-not [IO.File]::Exists($path)) { return $null }
    try { $target = [string](Import-PowerShellDataFile -LiteralPath $path).Target }
    catch { throw "$path can't be read ($($_.Exception.Message)); set it again: pwsh tools/wm.ps1 $($Company.Name) target" }
    if ($target) { return $target }
    return $null
}

function Save-PublishTarget {
    param($Company, [string]$Target)
    Write-PrivateFile (Get-PublishTargetPath $Company) (@(
        '# Where pwsh tools/wm.ps1 sync sends the signed source (written by "wm.ps1 <company> target"): git, or a folder'
        '# (a path on this computer, or user@host:/path for rsync).'
        '@{'
        "    Target = $(ConvertTo-WmPsdString $Target)"
        '}'
        '') -join "`n")
}

function Test-RemoteFolder {
    param([string]$Target)
    return ($Target -match '^[^/\s:]+:' -and $Target -notmatch '^[A-Za-z]:')
}

# A path inside a folder target: rsync's "host:" alone is the home folder, "host:/" would be the root
function Join-Target {
    param([string]$Target, [string]$Name)
    if ($Target.EndsWith(':')) { return "$Target$Name" }
    return ($Target.TrimEnd('/') + '/' + $Name)
}

function Invoke-Git {
    param([string]$Dir, [string[]]$Arguments)
    $out = & git -C $Dir @Arguments 2>&1
    return [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Text = (@($out | ForEach-Object { "$_" }) -join "`n").Trim() }
}

# The source as a Git repository of its own (its top folder): one inside a bigger work tree (a whole
# ~/wmanager-companies, a home folder) would push the other companies, configurations and keys with it
function Test-OwnGitRepository {
    param([string]$Dir)
    if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) { return $false }
    $r = Invoke-Git $Dir @('rev-parse', '--show-prefix')
    return ($r.Ok -and $r.Text -eq '')
}

# The branch, also before its first commit
function Get-GitBranch {
    param([string]$Dir)
    $r = Invoke-Git $Dir @('symbolic-ref', '--short', 'HEAD')
    if (-not $r.Ok) { throw "no branch in $Dir`: $($r.Text)" }
    return $r.Text
}

# The address raw.githubusercontent.com serves a GitHub repository's files at, for Management.Source; $null for
# another host
function Get-RawGitHubUrl {
    param([string]$Remote, [string]$Branch)
    if ($Remote -match '^(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)([^/]+)/([^/]+?)(?:\.git)?/?$') {
        return "https://raw.githubusercontent.com/$($Matches[1])/$($Matches[2])/$Branch"
    }
    return $null
}

# A word for a POSIX shell on the other end of ssh: in single quotes; a leading ~/ is the home folder, where ssh and
# rsync start anyway, so it goes (inside quotes the shell wouldn't expand it)
function ConvertTo-ShellWord {
    param([string]$Text)
    if ($Text.StartsWith('~/')) { $Text = $Text.Substring(2) }
    return "'" + $Text.Replace("'", "'\''") + "'"
}

# What the server of examples/selfhosted says about the company (selfhosted.sh address, over ssh): the address the
# computers read its source from, and the folder there that sync fills
function Get-ServerAddress {
    param([string]$Server, [string]$Kit, [string]$Name)
    $command = "$(ConvertTo-ShellWord "$Kit/selfhosted.sh") address $Name"
    Write-Host "  Asking $Server (ssh)..."
    $out = @(& ssh -- $Server $command)
    if ($LASTEXITCODE -ne 0) {
        throw "the server didn't say where the source of $Name goes (ssh code $LASTEXITCODE, the reason is above): is examples/selfhosted in $Kit there, with ./selfhosted.sh add-company $Name (or source $Name)?"
    }
    $url = ($out | Where-Object { $_ -match '^source https://\S+$' } | Select-Object -First 1) -replace '^source ', ''
    $folder = ($out | Where-Object { $_ -match '^folder sources/[a-z0-9-]+$' } | Select-Object -First 1) -replace '^folder ', ''
    if (-not $url -or -not $folder) { throw "the server's answer isn't selfhosted.sh's: $($out -join ' | ')" }
    return [pscustomobject]@{ Url = $url; Folder = $folder }
}

# Management.Source and AuthHeader of the company's configuration, in its text (the comments and other settings kept)
function Set-ConfigSource {
    param($Company, [string]$Source, [string]$AuthHeader)
    $text = [IO.File]::ReadAllText($Company.Config)
    $text = Set-WmConfigText $text 'Source' (ConvertTo-WmPsdString $Source)
    $text = Set-WmConfigText $text 'AuthHeader' (ConvertTo-WmPsdString $AuthHeader)
    Write-WmConfigFile -Path $Company.Config -Text $text
}

# The server of examples/selfhosted: selfhosted.sh says where the source goes (sync sends it there with rsync over ssh)
# and the address the computers read it from, which it offers to put in the configuration with the header selfhosted.sh
# printed. $false: nothing saved.
function Set-ServerTarget {
    param($Company)
    foreach ($tool in @('ssh', 'rsync')) {
        if (-not (Get-Command $tool -CommandType Application -ErrorAction SilentlyContinue)) {
            throw "$tool not found (sudo apt install $(if ($tool -eq 'ssh') { 'openssh-client' } else { 'rsync' }))"
        }
    }
    Write-Host '  The server and the folder of examples/selfhosted on it, e.g. admin@logs.example.com:/srv/wmanager/examples/selfhosted'
    $answer = [string](Read-Line '  As user@host:/path (Enter = back)')
    if (-not $answer) { return $false }
    if ($answer -notmatch '^([^\s/:-][^\s/:]*):(\S+)$') { throw "give it as user@host:/path, without spaces ('$answer')" }
    $server = $Matches[1]; $kit = $Matches[2].TrimEnd('/')
    $there = Get-ServerAddress $server $kit $Company.Name
    $target = "${server}:$kit/$($there.Folder)"
    Save-PublishTarget $Company $target
    Write-Host "  Saved: sync sends the signed source to $target with rsync, manifest.psd1 last."
    Write-Host "  The computers read it from $($there.Url), with the AuthHeader selfhosted.sh printed for $($Company.Name)."
    $now = Get-ConfigSource $Company
    if ($now.Source -eq $there.Url) { return $true }
    if (-not [IO.File]::Exists($Company.Config)) {
        Write-Host "  Put them in its configuration: pwsh tools/wm.ps1 $($Company.Name) config"
        return $true
    }
    if (-not (Read-WmYesNo "  Put that address and header in the configuration (Management.Source, AuthHeader)?" $true)) {
        Write-Host "  Later: pwsh tools/wm.ps1 $($Company.Name) config"
        return $true
    }
    while ($true) {
        $header = Read-Secret '  The AuthHeader selfhosted.sh printed (Basic ..., not shown; Enter = later)'
        if (-not $header) { Write-Host "  Later: pwsh tools/wm.ps1 $($Company.Name) config"; return $true }
        if ($header -match '^Basic [A-Za-z0-9+/]+={0,2}$') { break }
        Write-Host '  That is not it: the whole line after "AuthHeader", "Basic" and the rest.' -ForegroundColor Yellow
    }
    Set-ConfigSource $Company $there.Url $header
    Write-Host "  The configuration reads the source from $($there.Url) now."
    if ($now.Source) {
        Write-Warn "computers set up with the configuration before keep reading $($now.Source): they read the server once they get this one (run.cmd with it); until then they don't get what is sent there"
    }
    return $true
}

# Asks where the computers read the source from and gets it ready: a Git repository of its own (made here if needed,
# with a private GitHub repository by gh, or a remote you give), a folder, or the server of examples/selfhosted. Keeps
# the answer in <company>/publish.psd1. Nothing is sent before the source is signed: then it offers to send it
# (Sync-Company).
function Set-PublishTarget {
    param($Company)
    Assert-Source $Company
    Write-Step "Where the computers of $($Company.Name) read the source from"
    $now = $null
    try { $now = Get-PublishTarget $Company } catch { Write-Warn $_.Exception.Message }
    if ($now) { Write-Host "  Now: $now" }
    Write-Host '  g) a Git repository (private), pushed to its remote: GitHub, GitLab, a server of your own'
    Write-Host '  f) a folder: a share mounted here (e.g. /mnt/server/wmanager/acme) or user@host:/path (rsync over ssh)'
    Write-Host '  s) the wmanager server of examples/selfhosted (rsync over ssh; the computers read it with its login)'
    while ($true) {
        $answer = [string](Read-Line 'Choose (Enter = leave it as it is)')
        if (-not $answer) { return }
        if (@('g', 'f', 's') -contains $answer) { break }
        Write-Host '  g, f, s or Enter.' -ForegroundColor Yellow
    }
    $src = $Company.Source
    if ($answer -eq 's') {
        if (-not (Set-ServerTarget $Company)) { return }
    } elseif ($answer -eq 'f') {
        $folder = [string](Read-Line 'The folder (a path here, or user@host:/path)')
        if (-not $folder) { return }
        if (-not (Test-RemoteFolder $folder)) {
            $folder = ConvertTo-FullPath $folder
            if (-not [IO.Directory]::Exists($folder)) {
                if (-not (Read-WmYesNo "  $folder doesn't exist. Create it (for a share: only once it is mounted)?" $false)) { return }
                New-Item -ItemType Directory -Force -Path $folder | Out-Null
            }
        }
        Save-PublishTarget $Company $folder
        Write-Host "  Saved: sync copies the signed source to $folder, manifest.psd1 last."
        Write-Host '  The computers read that folder by its own address in Management.Source (e.g. \\server\share\wmanager\acme).'
    } else {
        if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) { throw 'git not found (sudo apt install git)' }
        if (-not (Test-OwnGitRepository $src)) {
            $top = Invoke-Git $src @('rev-parse', '--show-toplevel')
            if ($top.Ok) { Write-Warn "$src is inside the Git repository $($top.Text), which must not get the configurations and keys next to it: the source gets a repository of its own" }
            if (-not (Read-WmYesNo "  Make $src a Git repository of its own (git init)?" $true)) { return }
            $r = Invoke-Git $src @('init', '-q', '-b', 'main')
            if (-not $r.Ok) { throw "git init failed: $($r.Text)" }
            # Git must keep the bytes as signed (line endings): what examples/management has, and publish.sh checks
            $attributes = Join-Path $src '.gitattributes'
            if (-not [IO.File]::Exists($attributes)) { [IO.File]::WriteAllText($attributes, "* -text`n") }
            Write-Host '  Made it a Git repository.'
        }
        $branch = Get-GitBranch $src
        $remote = Invoke-Git $src @('remote', 'get-url', 'origin')
        $url = $null
        if ($remote.Ok) {
            $url = $remote.Text
            Write-Host "  Its remote: $url"
        } else {
            # gh signed in: its exit code (its text says "not logged into" when it isn't)
            $gh = $false
            if (Get-Command gh -CommandType Application -ErrorAction SilentlyContinue) {
                $null = & gh auth status 2>&1
                $gh = $LASTEXITCODE -eq 0
            }
            if ($gh) {
                $name = "wmanager-$($Company.Name)"
                if (Read-WmYesNo "  Create a private GitHub repository $name with gh?" $true) {
                    if ((Invoke-Native 'gh' @('repo', 'create', $name, '--private', '--source', $src, '--remote', 'origin')) -ne 0) {
                        throw 'gh repo create failed (the reason is above)'
                    }
                    $url = (Invoke-Git $src @('remote', 'get-url', 'origin')).Text
                }
            }
            if (-not $url) {
                $url = [string](Read-Line '  Address of its (private) remote repository, e.g. git@github.com:you/wmanager-acme.git (Enter = later)')
                if (-not $url) { Write-Host "  Later: git -C $src remote add origin <address>, then pwsh tools/wm.ps1 $($Company.Name) target"; return }
                $r = Invoke-Git $src @('remote', 'add', 'origin', $url)
                if (-not $r.Ok) { throw "git remote add failed: $($r.Text)" }
            }
        }
        Save-PublishTarget $Company 'git'
        Write-Host '  Saved: sync commits the signed source and pushes it.'
        $raw = Get-RawGitHubUrl $url $branch
        if ($raw) {
            Write-Host "  The computers read it from $raw"
            Write-Host '  with a read-only token in Management.AuthHeader (token github_pat_...: a fine-grained token of this'
            Write-Host '  repository with Contents: Read-only).'
            if ((Get-ConfigSource $Company).Source -ne $raw) { Write-Host "  Put that address in the configuration: pwsh tools/wm.ps1 $($Company.Name) config" }
        } else {
            Write-Host '  The computers read it from its raw https:// address on that server, in Management.Source.'
        }
    }
    # Only a signed source goes out: the computers reject files that don't match the manifest
    $changes = Get-SourceChanges $Company
    if (Test-SourceChanged $changes) {
        Write-Host "  It goes there once signed: pwsh tools/wm.ps1 $($Company.Name) publish"
    } elseif (Read-WmYesNo '  Send the signed source there now?' $true) {
        $null = Sync-Company $Company
    }
}

# --- Secrets for scripts: Secrets = @{ ... } in the company's configuration (docs/groups.md) ----------------------
# A script or job names the ones it needs ("# wmanager-secrets: ShareUser, SharePassword") and the computer gives it
# those from its configuration. Values are typed without being shown and are never printed here.

# The secrets the company's signed scripts and jobs name: name -> the files that name it (a line with a name that
# isn't one is left out here; groups.ps1 check reports it)
function Get-SourceSecretNeeds {
    param($Company)
    $needs = [ordered]@{}
    if (-not [IO.Directory]::Exists($Company.Source)) { return $needs }
    foreach ($rel in @(Get-SignedFiles $Company.Source | Sort-Object)) {
        if ($rel -notmatch '^groups/[^/]+/(scripts|jobs|logon|startup|events)/.*\.ps1$') { continue }
        try { $names = Get-WmScriptSecretNames ([IO.File]::ReadAllText((Join-Path $Company.Source $rel))) } catch { continue }
        foreach ($n in $names) {
            $key = @($needs.Keys | Where-Object { $_ -ieq $n }) | Select-Object -First 1
            if (-not $key) { $key = $n; $needs[$key] = New-Object System.Collections.Generic.List[string] }
            $needs[$key].Add($rel)
        }
    }
    return $needs
}

# The names of the secrets in the company's configuration (never the values)
function Get-ConfigSecretNames {
    param($Company)
    if (-not [IO.File]::Exists($Company.Config)) { return @() }
    return @((Get-WmSecrets (Import-PowerShellDataFile -LiteralPath $Company.Config)).Keys | Sort-Object)
}

# Secrets the scripts name that the configuration doesn't have: name -> files
function Get-MissingSecrets {
    param($Company)
    $have = @(Get-ConfigSecretNames $Company)
    $missing = [ordered]@{}
    $needs = Get-SourceSecretNeeds $Company
    foreach ($n in $needs.Keys) { if (-not ($have | Where-Object { $_ -ieq $n })) { $missing[$n] = $needs[$n] } }
    return $missing
}

function Show-Secrets {
    param($Company)
    $have = @(Get-ConfigSecretNames $Company)
    $needs = Get-SourceSecretNeeds $Company
    if ($have.Count -eq 0 -and $needs.Count -eq 0) {
        Write-Host "  No secrets. A script names the ones it needs in a line '# wmanager-secrets: ShareUser, SharePassword';"
        Write-Host "  add each: pwsh tools/wm.ps1 $($Company.Name) secret <name>"
        return
    }
    foreach ($n in $have) {
        $key = @($needs.Keys | Where-Object { $_ -ieq $n }) | Select-Object -First 1
        $use = if ($key) { 'used by ' + ($needs[$key] -join ', ') } else { 'no script names it' }
        Write-Host ('  {0,-24} {1}' -f $n, $use)
    }
    $missing = Get-MissingSecrets $Company
    foreach ($n in $missing.Keys) {
        Write-Warn "$n is named by $($missing[$n] -join ', ') but isn't in the configuration (those don't run): pwsh tools/wm.ps1 $($Company.Name) secret $n"
    }
}

# The configuration with the text changed, read back first the way the computers read it
function Save-ConfigSecretText {
    param($Company, [string]$Text)
    $data = ConvertFrom-WmConfigText $Text
    $null = Get-WmSecrets $data
    Write-WmConfigFile -Path $Company.Config -Text $Text
    return $data
}

# Adds or changes a secret: the value is typed without being shown (and so stays out of the shell's history)
function Set-Secret {
    param($Company, [string]$Name)
    if (-not (Test-WmSecretName $Name)) { throw "'$Name' is not a secret's name: letters, digits and _, starting with a letter, at most 64" }
    if (-not [IO.File]::Exists($Company.Config)) { throw "$($Company.Name) has no configuration yet: pwsh tools/wm.ps1 $($Company.Name) config" }
    $had = @(Get-ConfigSecretNames $Company | Where-Object { $_ -ieq $Name }).Count -gt 0
    $value = Read-Secret "  The value of $Name (not shown; spaces at the ends are dropped; Enter = leave it)"
    if (-not $value) { Write-Host '  Nothing changed.'; return $false }
    $text = Set-WmConfigSecretText ([IO.File]::ReadAllText($Company.Config)) $Name $value
    $data = Save-ConfigSecretText $Company $text
    if ([string]$data.Secrets[$Name] -cne $value) { throw "the configuration doesn't read back $Name as typed; check $($Company.Config)" }
    Write-Host "  $Name $(if ($had) { 'changed' } else { 'added' }) in $($Company.Config)."
    Write-SecretsNext $Company
    return $true
}

function Remove-Secret {
    param($Company, [string]$Name)
    if (-not [IO.File]::Exists($Company.Config)) { throw "$($Company.Name) has no configuration yet" }
    $text = Remove-WmConfigSecretText ([IO.File]::ReadAllText($Company.Config)) $Name
    if ($null -eq $text) { throw "$($Company.Name)'s configuration has no secret $Name" }
    $null = Save-ConfigSecretText $Company $text
    Write-Host "  $Name removed from $($Company.Config)."
    $missing = Get-MissingSecrets $Company
    $key = @($missing.Keys | Where-Object { $_ -ieq $Name }) | Select-Object -First 1
    if ($key) { Write-Warn "$($missing[$key] -join ', ') name ${Name}: they won't run on computers with this configuration" }
    Write-SecretsNext $Company
}

function Write-SecretsNext {
    param($Company)
    Write-Host '  The computers get it with this configuration: run.cmd with it (pwsh tools/wm.ps1 usb <folder>); the ones set up'
    Write-Host '  before keep the secrets they had. Like the tokens, it is plain text in the file: keep the drive under control.'
}

# The menu step: the list, then a name to add, change or remove
function Edit-SecretsStep {
    param($Company)
    Show-Secrets $Company
    $name = [string](Read-Line 'Secret to add or change (Enter = back)')
    if (-not $name) { return }
    if (@(Get-ConfigSecretNames $Company | Where-Object { $_ -ieq $name }).Count -gt 0) {
        $what = [string](Read-Line "  $name is there: c) change its value, r) remove it (Enter = back)")
        if ($what -eq 'r') { Remove-Secret $Company $name; return }
        if ($what -ne 'c') { return }
    }
    $null = Set-Secret $Company $name
}

# Management.Source and AuthHeader of the company's configuration
function Get-ConfigSource {
    param($Company)
    $m = $null
    if ([IO.File]::Exists($Company.Config)) { $m = (Import-PowerShellDataFile -LiteralPath $Company.Config).Management }
    if (-not ($m -is [hashtable])) { $m = @{} }
    return [pscustomobject]@{ Source = ([string]$m.Source).TrimEnd('/'); AuthHeader = [string]$m.AuthHeader }
}

# The manifest a folder target has now (SourceId, Serial, Files), $null for none: sending must not replace a newer
# manifest (computers that took it reject an older one) or another source's (a folder typed by mistake)
function Read-TargetManifest {
    param([string]$Target)
    $file = Join-Path ([IO.Path]::GetTempPath()) ('wmanager-target-' + [guid]::NewGuid().ToString('N') + '.psd1')
    try {
        if (Test-RemoteFolder $Target) {
            # No manifest there yet (the first time) is no error, in any language: --ignore-missing-args, then whether
            # it came. rsync's words are shown for a real failure; ssh asks for a password on the terminal, not here.
            $said = @(& rsync -q --ignore-missing-args (Join-Target $Target 'manifest.psd1') $file 2>&1 | ForEach-Object { "$_" })
            $code = $LASTEXITCODE
            if ($code -ne 0) {
                $said | ForEach-Object { Write-Host "  $_" }
                throw "can't reach $Target (rsync code $code, the reason is above)"
            }
            if (-not [IO.File]::Exists($file)) { return $null }
        } else {
            $there = Join-Path $Target 'manifest.psd1'
            if (-not [IO.File]::Exists($there)) { return $null }
            Copy-Item -LiteralPath $there -Destination $file
        }
        try { return (Import-PowerShellDataFile -LiteralPath $file) }
        catch { throw "the manifest.psd1 in $Target can't be read ($($_.Exception.Message)); look at that folder before sending to it" }
    } finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}

function Assert-TargetManifest {
    param($Theirs, $Ours, [string]$Target)
    if ($null -eq $Theirs) { return }
    if ([string]$Theirs.SourceId -ne [string]$Ours.SourceId) {
        throw "$Target holds another source (SourceId $($Theirs.SourceId), not $($Ours.SourceId)); check the folder: pwsh tools/wm.ps1 <company> target"
    }
    if ([long]$Theirs.Serial -gt [long]$Ours.Serial) {
        throw "$Target has a newer manifest ($($Theirs.Serial)) than this source ($($Ours.Serial)): signed elsewhere? Bring this copy up to date, or sign again here, before sending"
    }
}

# Git: commit what a signature publishes, then push. The same line-ending check as publish.sh: git must keep the
# bytes, or the hashes and the signature stop matching.
function Send-Git {
    param($Company, $Changes)
    $src = $Company.Source
    if (-not (Test-OwnGitRepository $src)) { throw "$src is not a Git repository of its own: pwsh tools/wm.ps1 $($Company.Name) target" }
    $r = Invoke-Git $src @('add', '-A', '--', '.')
    if (-not $r.Ok) { throw "git add failed: $($r.Text)" }
    # After the add: git reads .gitattributes from the folder, else from the index, which now matches it
    $paths = @(@($Changes.Files) + 'manifest.psd1')
    $attrs = (Invoke-Git $src (@('check-attr', 'text', '--') + $paths)).Text -split "`n"
    $bad = @($attrs | Where-Object { $_ -and $_ -notmatch ': text: unset$' })
    if ($bad.Count -gt 0) {
        throw "git would change the line endings of: $(($bad | ForEach-Object { ($_ -split ':')[0] }) -join ', '); add the line '* -text' to $src/.gitattributes"
    }
    $staged = @((Invoke-Git $src @('diff', '--cached', '--name-status', '--', '.')).Text -split "`n" | Where-Object { $_ })
    if ($staged.Count -gt 0) {
        $subject = "Manifest $($Changes.Serial): $(Format-Count $staged.Count 'file')"
        $r = Invoke-Git $src @('commit', '-q', '-m', $subject, '-m', (@($staged | Select-Object -First 40) -join "`n"))
        if (-not $r.Ok) { throw "git commit failed: $($r.Text)" }
        Write-Host "  Committed: $subject"
    }
    $branch = Get-GitBranch $src
    $upstream = Invoke-Git $src @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}')
    $push = if ($upstream.Ok) { @('-C', $src, 'push') } else { @('-C', $src, 'push', '-u', 'origin', $branch) }
    if ((Invoke-Native 'git' $push) -ne 0) { throw 'git push failed (the reason is above); sync again when it works' }
    Write-Host '  Pushed.'
}

# A folder: the files whose content differs from what the folder's manifest lists (rsync compares by itself), then
# manifest.psd1 under another name, renamed last. A computer reading meanwhile may get a file newer than its manifest
# and skip that run; its next check gets the whole new version.
function Send-Folder {
    param($Company, $Changes, [string]$Target, $Ours)
    $src = $Company.Source
    $remote = Test-RemoteFolder $Target
    if ($remote) {
        if (-not (Get-Command rsync -CommandType Application -ErrorAction SilentlyContinue)) { throw 'rsync not found (sudo apt install rsync)' }
    } elseif (-not [IO.Directory]::Exists($Target)) {
        throw "$Target doesn't exist: is the share mounted? (a new folder: pwsh tools/wm.ps1 $($Company.Name) target)"
    }
    $theirs = Read-TargetManifest $Target
    Assert-TargetManifest $theirs $Ours $Target
    $files = @($Changes.Files)
    if ($remote) {
        $list = Join-Path ([IO.Path]::GetTempPath()) ('wmanager-sync-' + [guid]::NewGuid().ToString('N'))
        try {
            [IO.File]::WriteAllLines($list, [string[]]$files)
            if ((Invoke-Native 'rsync' @('-rtq', "--files-from=$list", "$src/", (Join-Target $Target ''))) -ne 0) { throw 'rsync failed (the reason is above)' }
        } finally {
            Remove-Item -LiteralPath $list -Force -ErrorAction SilentlyContinue
        }
        # rsync writes a temporary file and renames it
        if ((Invoke-Native 'rsync' @('-tq', (Join-Path $src 'manifest.psd1'), (Join-Target $Target 'manifest.psd1'))) -ne 0) { throw 'rsync failed (the reason is above)' }
        Write-Host "  Sent $(Format-Count ($files.Count + 1) 'file') to $Target with rsync, manifest.psd1 last."
    } else {
        $known = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
        if ($theirs -and $theirs.Files -is [hashtable]) { foreach ($k in $theirs.Files.Keys) { $known[[string]$k] = [string]$theirs.Files[$k] } }
        $copied = 0
        foreach ($rel in $files) {
            $to = Join-Path $Target $rel
            $hash = Get-CachedHash (Join-Path $src $rel)
            if ($known.ContainsKey($rel) -and $known[$rel] -eq $hash -and [IO.File]::Exists($to)) { continue }
            New-Item -ItemType Directory -Force -Path (Split-Path $to -Parent) | Out-Null
            Copy-Item -LiteralPath (Join-Path $src $rel) -Destination $to -Force
            $copied++
        }
        $next = Join-Path $Target 'manifest.psd1.new'
        Copy-Item -LiteralPath (Join-Path $src 'manifest.psd1') -Destination $next -Force
        Move-Item -LiteralPath $next -Destination (Join-Path $Target 'manifest.psd1') -Force
        Write-Host "  Copied $(Format-Count $copied 'changed file') and manifest.psd1 (last) to $Target; files removed from the source stay there, the computers ignore them."
    }
}

# Sends the signed source where the computers read it (publish.psd1), then checks they can see it. Only a source
# without changes since its signature: computers reject files that don't match the manifest. Returns what the check
# found: $true (they get it), $false (they don't, or not yet), $null (an address this computer can't check).
# -Wait: wait for a host's cache without asking (-Yes, scripts).
function Sync-Company {
    param($Company, [switch]$Wait)
    Assert-Source $Company
    $target = Get-PublishTarget $Company
    if (-not $target) { throw "no place to send the source to yet: pwsh tools/wm.ps1 $($Company.Name) target" }
    $changes = Get-SourceChanges $Company
    if ($changes.First) { throw "the source isn't signed yet: pwsh tools/wm.ps1 $($Company.Name) publish" }
    if (Test-SourceChanged $changes) {
        throw "the source has changes that aren't signed (pwsh tools/wm.ps1 $($Company.Name) changes); the computers would reject them: sign them first"
    }
    $ours = Import-PowerShellDataFile -LiteralPath (Join-Path $Company.Source 'manifest.psd1')
    if ($target -eq 'git') { Send-Git $Company $changes }
    else { Send-Folder $Company $changes $target $ours }
    return (Test-Published $Company ([string]$ours.Serial) -Wait:$Wait)
}

# Does the address the computers read (Management.Source) give the manifest just sent? The computers read https://
# addresses and Windows paths; a path can't be checked from here. WMANAGER_TEST_LOCAL_HTTP: the tests' stand-in server.
function Test-Published {
    param($Company, [string]$Serial, [switch]$Wait)
    $s = Get-ConfigSource $Company
    if (-not $s.Source) { Write-Warn "the configuration has no Management.Source yet, so no computer reads this source: pwsh tools/wm.ps1 $($Company.Name) config"; return $null }
    $readable = $s.Source -match '^https://' -or ($env:WMANAGER_TEST_LOCAL_HTTP -and $s.Source -match '^http://127\.0\.0\.1[:/]')
    if (-not $readable) {
        if ($s.Source -match '^[A-Za-z][A-Za-z0-9+.-]*://') { Write-Warn "the computers read only https:// addresses (and Windows paths), not $($s.Source): fix Management.Source"; return $false }
        Write-Host "  The computers read $($s.Source): it can't be checked from here."
        return $null
    }
    $headers = @{}
    if ($s.AuthHeader) { $headers['Authorization'] = $s.AuthHeader }
    $deadline = (Get-Date).AddSeconds($script:PublishWaitSeconds)
    $asked = [bool]$Wait
    while ($true) {
        $seen = $null
        $file = Join-Path ([IO.Path]::GetTempPath()) ('wmanager-check-' + [guid]::NewGuid().ToString('N') + '.psd1')
        try {
            Invoke-WebRequest -Uri "$($s.Source)/manifest.psd1" -OutFile $file -Headers $headers -TimeoutSec 30 | Out-Null
            $seen = [string](Import-PowerShellDataFile -LiteralPath $file).Serial
        } catch {
            Write-Warn "the computers' address $($s.Source) didn't give the manifest: $($_.Exception.Message) (check Management.Source and AuthHeader)"
            return $false
        } finally {
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        }
        if ($seen -eq $Serial) { Write-Host "  The computers can read manifest $Serial now ($($s.Source))." -ForegroundColor Green; return $true }
        if ((Get-Date) -gt $deadline) { Write-Warn "$($s.Source) still gives manifest $seen, not $Serial; check again later: pwsh tools/wm.ps1 $($Company.Name) sync"; return $false }
        if (-not $asked) {
            Write-Host "  $($s.Source) still gives manifest $seen (a host like GitHub keeps files up to 5 minutes)."
            if (-not (Read-WmYesNo '  Wait until it gives the new one (up to 5 minutes)?' $true)) { return $false }
            $asked = $true
        }
        Start-Sleep -Seconds 5
    }
}

# ---------------------------------------------------------------------------
# Backup: a company as one archive, and back
# ---------------------------------------------------------------------------

$script:BackupRoot = Join-Path $HOME 'wmanager-backups'

# A path with its links resolved (realpath -m: also for a folder that isn't there yet)
function Resolve-RealPath {
    param([string]$Path)
    $real = & realpath -m -- $Path 2>$null
    if ($LASTEXITCODE -eq 0 -and $real) { return [string]$real }
    return $Path
}

# The whole folder of a company in <folder>/<company>-<UTC time>.tar.gz, readable by you only: its source (with its
# Git history), its key (protected by its passphrase), its configuration and the read-only keys (tokens in plain
# text, as on the USB drive). Linked folders (docs/companies.md says a company may link its folders) go in with what they
# hold. Not inside the companies folder: the next backup would hold the last one.
function Backup-Company {
    param($Company, [string]$Folder)
    if (-not (Get-Command tar -CommandType Application -ErrorAction SilentlyContinue)) { throw 'tar not found' }
    $Folder = if ($Folder) { ConvertTo-FullPath $Folder } else { $script:BackupRoot }
    $root = (Resolve-RealPath $script:Root).TrimEnd('/') + '/'
    if (((Resolve-RealPath $Folder).TrimEnd('/') + '/').StartsWith($root, [StringComparison]::Ordinal)) {
        throw "a backup can't go into $($script:Root) (the next backup would hold it); choose another folder"
    }
    if (-not [IO.Directory]::Exists($Folder)) {
        New-Item -ItemType Directory -Force -Path $Folder | Out-Null
        if (-not $IsWindows) { [IO.File]::SetUnixFileMode($Folder, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute') }
    }
    # A name no backup has yet, made readable by you only before tar writes into it (tar keeps that mode)
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + 'Z'
    $archive = $null
    for ($i = 1; -not $archive; $i++) {
        if ($i -gt 50) { throw "too many backups of $($Company.Name) at $stamp in $Folder" }
        $name = if ($i -eq 1) { "$($Company.Name)-$stamp.tar.gz" } else { "$($Company.Name)-$stamp-$i.tar.gz" }
        $try = Join-Path $Folder $name
        if ([IO.File]::Exists($try)) { continue }
        Write-PrivateFile $try '' -New
        $archive = $try
    }
    $code = Invoke-Native 'tar' @('-czf', $archive, '--dereference', '-C', $script:Root, $Company.Name)
    $count = 0
    if ($code -eq 0) {
        $count = (& tar -tzf $archive 2>$null | Measure-Object).Count
        if ($LASTEXITCODE -ne 0) { $count = 0 }
    }
    if ($code -ne 0 -or $count -eq 0) {
        # A backup that failed or can't be read back must not sit among the good ones
        Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
        throw "the backup of $($Company.Name) failed (tar code $code; the reason is above)"
    }
    $size = (Get-Item -LiteralPath $archive).Length
    Write-Host ('  {0}: {1} ({2} entries, {3:N0} KB)' -f $Company.Name, $archive, $count, ($size / 1KB))
    return $archive
}

# Every company; one that fails doesn't stop the others, and the end says which failed
function Backup-AllCompanies {
    param([string]$Folder)
    $companies = @(Get-Companies)
    if ($companies.Count -eq 0) { throw "no companies in $($script:Root) yet" }
    Write-Step 'Backups'
    $failed = New-Object System.Collections.Generic.List[string]
    foreach ($c in $companies) {
        try { $null = Backup-Company $c $Folder }
        catch { Write-Host "  $($c.Name): ERROR: $(Format-WmErrorText $_ -English)" -ForegroundColor Red; $failed.Add($c.Name) }
    }
    Write-Host '  They hold the signing keys (protected by their passphrases) and the tokens of the configurations:'
    Write-Host '  keep them somewhere safe, not on the USB drive. Back: pwsh tools/wm.ps1 restore <archive>'
    if ($failed.Count -gt 0) { throw "no backup of $($failed -join ', ') (above)" }
}

# A company back from a backup. The archive must hold one company's folder (a folder with source, keys or config)
# and no links (backups have none) or paths outside it. It is unpacked into a hidden folder of the companies folder,
# checked there and only then renamed into place, so a failure leaves nothing behind; a company that is here already
# is never overwritten (move it away first).
function Restore-Company {
    param([string]$Archive)
    if (-not $Archive) { throw 'usage: pwsh tools/wm.ps1 restore <archive>' }
    $Archive = ConvertTo-FullPath $Archive
    if (-not [IO.File]::Exists($Archive)) { throw "no file $Archive" }
    if (-not (Get-Command tar -CommandType Application -ErrorAction SilentlyContinue)) { throw 'tar not found' }
    $listing = @(& tar -tvzf $Archive 2>$null)
    if ($LASTEXITCODE -ne 0 -or $listing.Count -eq 0) { throw "$Archive is not a backup of wm.ps1 (tar can't read it)" }
    $links = @($listing | Where-Object { $_ -match '^[lh]' })
    if ($links.Count -gt 0) { throw "$Archive holds links ($($links[0].Trim())); a backup of wm.ps1 has none: not restored" }
    $entries = @(& tar -tzf $Archive 2>$null)
    $bad = @($entries | Where-Object { $_ -match '^/' -or "/$_/" -match '/\.\./' })
    if ($bad.Count -gt 0) { throw "$Archive has paths outside a company's folder ($($bad[0])); not restored" }
    $tops = @($entries | ForEach-Object { ($_ -split '/')[0] } | Where-Object { $_ } | Sort-Object -Unique -CaseSensitive)
    if ($tops.Count -ne 1 -or -not (Test-CompanyName $tops[0])) {
        throw "$Archive holds $($tops -join ', '), not one company's folder; not restored"
    }
    $name = $tops[0]
    $existing = @(Get-Companies | Where-Object { $_.Name -ieq $name })
    if ($existing.Count -gt 0) {
        throw "there is a company $($existing[0].Name) already; restore never overwrites one: move $($existing[0].Dir) away first"
    }
    New-Item -ItemType Directory -Force -Path $script:Root | Out-Null
    $staging = Join-Path $script:Root ('.restore-' + [guid]::NewGuid().ToString('N'))   # hidden: never a company
    New-Item -ItemType Directory -Path $staging | Out-Null
    try {
        $code = Invoke-Native 'tar' @('-xzf', $Archive, '-C', $staging, '--no-same-owner')
        if ($code -ne 0) { throw "restoring $name failed (tar code $code, the reason is above); nothing was restored" }
        $unpacked = Join-Path $staging $name
        $parts = @('source', 'keys', 'config') | Where-Object { [IO.Directory]::Exists((Join-Path $unpacked $_)) }
        if (-not [IO.Directory]::Exists($unpacked) -or @($parts).Count -eq 0) {
            throw "$Archive holds no company's folder (source, keys or config in $name); not restored"
        }
        if (@(Get-ChildItem -LiteralPath $unpacked -Recurse -Force | Where-Object { $_.LinkType }).Count -gt 0) {
            throw "$Archive unpacked into links; not restored"
        }
        Move-Item -LiteralPath $unpacked -Destination (Join-Path $script:Root $name)
    } finally {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
    $c = Get-CompanyPaths $name
    Write-Host "Restored $name into $($c.Dir): $(Get-CompanyState $c)"
    Write-Host "Its menu: pwsh tools/wm.ps1 $name"
}

# ---------------------------------------------------------------------------
# Key change, with a time when the computers trust both keys (lib/Managed.ps1 does their side)
# ---------------------------------------------------------------------------

# A signing key in $Dir made by tools/new-signing-cert.sh (it asks for the passphrase), unless the folder has a whole
# one; an empty key.pem (a creation stopped at the passphrase) goes first, a key.pem without its certificates stops it
function New-KeyFolder {
    param([string]$Dir, [string]$CarryOn)
    if (Test-HasKey ([pscustomobject]@{ Keys = $Dir })) { return $false }
    $key = Join-Path $Dir 'key.pem'
    if ([IO.File]::Exists($key) -and (Get-Item -LiteralPath $key).Length -gt 0) {
        throw "$Dir has a key.pem but no certificates (cert.pem, wmanager-signing.cer); make them from that key, or move it away and run: $CarryOn"
    }
    if ([IO.File]::Exists($key)) { Remove-Item -LiteralPath $key }
    if ((Invoke-Native 'bash' @((Join-Path $script:Tools 'new-signing-cert.sh'), $Dir)) -ne 0) {
        throw "no key (the reason is above); to carry on: $CarryOn"
    }
    return $true
}

function Get-CertThumbprint {
    param([string]$Path)
    return [Security.Cryptography.X509Certificates.X509Certificate2]::new($Path).Thumbprint
}

# <company>/key-change.psd1: where a key change stands, so a step that stopped (a mistyped passphrase, a push that
# failed) is carried on, not started again. State: naming (the new key's certificate goes into the source, signed
# with the current key), named (the computers are getting it), switching, calling-off. Thumbprint: the new key's.
function Get-KeyChangePath { param($Company) return (Join-Path $Company.Dir 'key-change.psd1') }

function Read-KeyChange {
    param($Company)
    $path = Get-KeyChangePath $Company
    if (-not [IO.File]::Exists($path)) { return $null }
    try { return (Import-PowerShellDataFile -LiteralPath $path) }
    catch { throw "$path can't be read ($($_.Exception.Message)); look at it before going on with the key change" }
}

function Save-KeyChange {
    param($Company, [string]$State, [string]$Thumbprint)
    Write-PrivateFile (Get-KeyChangePath $Company) (@(
        '# Where the key change of this company stands (pwsh tools/wm.ps1 <company> rotate-key writes it; do not edit).'
        '@{'
        "    State      = $(ConvertTo-WmPsdString $State)"
        "    Thumbprint = $(ConvertTo-WmPsdString $Thumbprint)"
        '}'
        '') -join "`n")
}

function Get-KeyChangeKeys { param($Company) return (Join-Path $Company.Dir 'keys-new') }
function Get-NamedCertPath { param($Company) return (Join-Path $Company.Source 'next-certificate.cer') }

# A computer that trusts the new certificate (its last run record names it as next, or as its own)
function Test-TrustsCertificate {
    param($Row, [string]$Thumbprint)
    return [bool]($Row.Log -and ($Row.Log.Next -eq $Thumbprint -or $Row.Log.Cert -eq $Thumbprint))
}

# How many computers trust the new certificate; $null when it can't be told (no read-only keys, Loki didn't answer)
function Get-KeyChangeReadiness {
    param($Company, [string]$Thumbprint, $Status)
    if ($null -eq $Status) { try { $Status = Get-ComputerStatus $Company } catch { return $null } }
    if (-not $Status.LokiOk) { return $null }
    $notReady = @($Status.Rows | Where-Object { -not (Test-TrustsCertificate $_ $Thumbprint) } | ForEach-Object Name)
    return [pscustomobject]@{ Ready = $Status.Rows.Count - $notReady.Count; Total = $Status.Rows.Count; NotReady = $notReady }
}

# A key change under way: "Key change: 8 of 10 computers trust the new certificate", or $null
function Format-KeyChangeLine {
    param($Company, $Status)
    $kc = $null
    try { $kc = Read-KeyChange $Company } catch { return 'key change: key-change.psd1 unreadable' }
    if ($null -eq $kc -or $kc.State -ne 'named') { if ($kc) { return "key change: $($kc.State), not finished (rotate-key)" }; return $null }
    $r = Get-KeyChangeReadiness $Company $kc.Thumbprint $Status
    if ($null -eq $r) { return "key change: how many computers trust the new certificate can't be told without Loki" }
    return "key change: $($r.Ready) of $($r.Total) computers trust the new certificate"
}

# rotate-key: starts a key change, carries on a step that stopped, or switches / calls it off
function Invoke-KeyChange {
    param($Company)
    Assert-Source $Company
    $kc = Read-KeyChange $Company
    if ($null -eq $kc) {
        if (-not (Test-HasKey $Company)) { throw "$($Company.Name) has no signing key yet: pwsh tools/wm.ps1 new $($Company.Name)" }
        $changes = Get-SourceChanges $Company
        if ($changes.OtherKey) {
            throw "the source is signed with another key ($($changes.OtherKey)) than the one in keys/, and no key change is under way: if keys/ is the wrong key, put the right one back; to sign with keys/ anyway (the computers trust only a key they were told about): pwsh tools/wm.ps1 $($Company.Name) publish"
        }
        if ([IO.File]::Exists((Get-NamedCertPath $Company))) {
            throw "the source names a next certificate (next-certificate.cer) but no key change is under way: remove the file and sign, or restore <company>/key-change.psd1 and keys-new/ from a backup"
        }
        Start-KeyChange $Company
        return
    }
    switch ($kc.State) {
        'naming' { Send-NewCertificate $Company ([string]$kc.Thumbprint) }
        'named' { Complete-KeyChange $Company ([string]$kc.Thumbprint) }
        'switching' { Switch-SigningKey $Company ([string]$kc.Thumbprint) }
        'calling-off' { Stop-KeyChange $Company ([string]$kc.Thumbprint) }
        default { throw "key-change.psd1 has an unknown state '$($kc.State)'" }
    }
}

function Start-KeyChange {
    param($Company)
    Write-Step "A new signing key for $($Company.Name), in two steps"
    Write-Host '  1. Now: a new key; its certificate goes into the source, signed still with the current key. From their next'
    Write-Host '     update the computers trust both keys.'
    Write-Host "  2. Later, when the computers have it (pwsh tools/wm.ps1 $($Company.Name) status shows how many): rotate-key"
    Write-Host '     again switches to the new key. A computer that missed step 1 needs its configuration again (run.cmd).'
    Write-Host '  A key that leaked is not changed this way (whoever has it could name a certificate too): give the computers a'
    Write-Host '  new configuration and certificate with run.cmd instead.'
    # Only this change goes out with the signature: other changes are signed with their own look (publish)
    if (Test-SourceChanged (Get-SourceChanges $Company)) {
        throw "the source has changes that aren't signed (pwsh tools/wm.ps1 $($Company.Name) changes): sign them (publish) or undo them first"
    }
    if (-not (Read-WmYesNo 'Start the key change?' $true)) { return }
    $keys = Get-KeyChangeKeys $Company
    Write-Host '  The new key gets a passphrase of its own.'
    if (-not (New-KeyFolder $keys "pwsh tools/wm.ps1 $($Company.Name) rotate-key")) { Write-Host "  The new key is in $keys already." }
    $thumb = Get-CertThumbprint (Join-Path $keys 'wmanager-signing.cer')
    Save-KeyChange $Company 'naming' $thumb
    Send-NewCertificate $Company $thumb -Confirmed
}

# Step 1: the source names the new certificate, signed with the current key
function Send-NewCertificate {
    param($Company, [string]$Thumbprint, [switch]$Confirmed)
    $keys = Get-KeyChangeKeys $Company
    if (-not (Test-HasKey ([pscustomobject]@{ Keys = $keys })) -or (Get-CertThumbprint (Join-Path $keys 'wmanager-signing.cer')) -ne $Thumbprint) {
        throw "$keys doesn't hold the new key ($Thumbprint) any more; put it back from a backup, or remove key-change.psd1 and next-certificate.cer and sign (that ends the change)"
    }
    Copy-Item -LiteralPath (Join-Path $keys 'wmanager-signing.cer') -Destination (Get-NamedCertPath $Company) -Force
    Write-Host '  The source names the new certificate (next-certificate.cer); signing it with the current key:'
    $null = Publish-Company $Company -Confirmed:$Confirmed
    if (Test-SourceChanged (Get-SourceChanges $Company)) { Write-Host "  Not signed; to carry on: pwsh tools/wm.ps1 $($Company.Name) rotate-key"; return }
    Save-KeyChange $Company 'named' $Thumbprint
    Write-Host ''
    Write-Host "  Next: once the computers have it (pwsh tools/wm.ps1 $($Company.Name) status), pwsh tools/wm.ps1 $($Company.Name) rotate-key"
    if (-not (Get-PublishTarget $Company)) { Write-Host '  First send the signed source where the computers read it (push it, or copy it).' }
}

# Step 2: switch, or call it off. The switch asks with the default no: the computers that didn't report in the last
# days (or aren't in groups.psd1) aren't counted, and they would be cut off.
function Complete-KeyChange {
    param($Company, [string]$Thumbprint)
    Write-Step "Key change of $($Company.Name): the new certificate $Thumbprint"
    $r = Get-KeyChangeReadiness $Company $Thumbprint $null
    if ($null -eq $r) {
        Write-Host "  How many computers have it can't be told here (read-only keys and Loki: pwsh tools/wm.ps1 $($Company.Name) monitoring)."
    } else {
        Write-Host "  $($r.Ready) of $($r.Total) computers trust it (computers silent for $($script:StatusDays) days aren't counted)."
        if ($r.NotReady.Count -gt 0) { Write-Host "  Not yet: $($r.NotReady -join ', '). After the switch they need their configuration again (run.cmd)." }
    }
    Write-Host '  s) switch to the new key now'
    Write-Host '  c) call the change off (the computers forget the new certificate)'
    while ($true) {
        $answer = [string](Read-Line 'Choose (Enter = later)')
        if (-not $answer) { return }
        if (@('s', 'c') -contains $answer) { break }
        Write-Host '  s, c or Enter.' -ForegroundColor Yellow
    }
    if ($answer -eq 'c') {
        if (-not (Read-WmYesNo 'Call the key change off?' $true)) { return }
        Save-KeyChange $Company 'calling-off' $Thumbprint
        Stop-KeyChange $Company $Thumbprint
        return
    }
    if (-not (Read-WmYesNo "Switch $($Company.Name) to the new key?" $false)) { return }
    Save-KeyChange $Company 'switching' $Thumbprint
    Switch-SigningKey $Company $Thumbprint
}

# Each step checks whether it is done, so running it again carries on where it stopped
function Switch-SigningKey {
    param($Company, [string]$Thumbprint)
    $named = Get-NamedCertPath $Company
    if ([IO.File]::Exists($named)) { Remove-Item -LiteralPath $named -Force }
    $keys = Get-KeyChangeKeys $Company
    if ([IO.Directory]::Exists($keys)) {
        if ([IO.Directory]::Exists($Company.Keys)) {
            $old = Get-FreeFolderName $Company.Dir 'keys-old'
            Move-Item -LiteralPath $Company.Keys -Destination $old
            Write-Host "  The previous key moved to $old (keep it until every computer has switched)."
        }
        Move-Item -LiteralPath $keys -Destination $Company.Keys
    }
    if (-not (Test-HasKey $Company) -or (Get-CertThumbprint (Join-Path $Company.Keys 'wmanager-signing.cer')) -ne $Thumbprint) {
        throw "$($Company.Keys) doesn't hold the new key ($Thumbprint); look at keys/, keys-new/ and keys-old-*/ before going on"
    }
    # The configuration for new computers gets the new certificate
    if ([IO.File]::Exists($Company.Config)) {
        $name = Get-ConfigCertificate $Company.Config
        if (-not $name) { $name = 'wmanager-signing.cer' }
        Copy-Item -LiteralPath (Join-Path $Company.Keys 'wmanager-signing.cer') -Destination (Join-Path $Company.ConfigDir $name) -Force
        Write-Host "  config/$name is the new certificate: put it on the USB drive again (pwsh tools/wm.ps1 usb <folder>)."
    }
    Write-Host '  Signing the source with the new key:'
    $null = Publish-Company $Company -Confirmed
    if (Test-SourceChanged (Get-SourceChanges $Company)) { Write-Host "  Not signed; to carry on: pwsh tools/wm.ps1 $($Company.Name) rotate-key"; return }
    Remove-Item -LiteralPath (Get-KeyChangePath $Company) -Force
    Write-Host "  $($Company.Name) is signed with the new key."
}

function Stop-KeyChange {
    param($Company, [string]$Thumbprint)
    $named = Get-NamedCertPath $Company
    if ([IO.File]::Exists($named)) { Remove-Item -LiteralPath $named -Force }
    Write-Host '  Signing the source (without the new certificate) with the current key:'
    $null = Publish-Company $Company -Confirmed
    if (Test-SourceChanged (Get-SourceChanges $Company)) { Write-Host "  Not signed; to carry on: pwsh tools/wm.ps1 $($Company.Name) rotate-key"; return }
    $keys = Get-KeyChangeKeys $Company
    if ([IO.Directory]::Exists($keys)) {
        $kept = Get-FreeFolderName $Company.Dir 'keys-called-off'
        Move-Item -LiteralPath $keys -Destination $kept
        Write-Host "  The new key moved to $kept."
    }
    Remove-Item -LiteralPath (Get-KeyChangePath $Company) -Force
    Write-Host '  The key change is called off.'
}

# A folder name that isn't taken: <base>-<date>, -2, -3...
function Get-FreeFolderName {
    param([string]$Dir, [string]$Base)
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd')
    for ($i = 1; ; $i++) {
        $name = if ($i -eq 1) { "$Base-$stamp" } else { "$Base-$stamp-$i" }
        if (-not (Test-Path -LiteralPath (Join-Path $Dir $name))) { return (Join-Path $Dir $name) }
    }
}

# ---------------------------------------------------------------------------
# Menus
# ---------------------------------------------------------------------------

function Show-StatusStep {
    param($Company)
    $m = $null
    try { $m = Read-Monitoring $Company } catch { }
    if (-not (Test-HasMonitoringKeys $m)) {
        Write-Host '  The status needs read-only keys of Healthchecks and Grafana Cloud (the computers have write-only ones).'
        if (-not (Read-WmYesNo '  Set them up now?' $true)) { return }
        Set-Monitoring $Company
    }
    Show-ComputerStatus $Company
}

function Add-ComputerStep {
    param($Company)
    $pc = [string](Read-Line 'Computer name (e.g. OFFICE-07)')
    if (-not $pc) { return $false }
    $groups = @(Read-Groups $Company 'Its groups: numbers or names, separated by spaces (a new name makes a new group)')
    if ($groups.Count -eq 0) { return $false }
    return (Invoke-Groups $Company 'add-computer' (@($pc) + $groups))
}

function Remove-ComputerStep {
    param($Company)
    $pc = [string](Read-Line 'Computer name')
    if (-not $pc) { return $false }
    $groups = @(Read-Groups $Company 'Groups it leaves (Enter = all of them)')
    return (Invoke-Groups $Company 'remove-computer' (@($pc) + $groups))
}

function Add-PackageStep {
    param($Company)
    $target = @(Read-Groups $Company 'For a group, or common for every computer' -Common)
    if ($target.Count -ne 1) { return $false }
    $line = [string](Read-Line 'One package, as a line of choco-reqs.txt (e.g. vlc@3.0.21 or googlechrome !noupdate)')
    if (-not $line) { return $false }
    return (Invoke-Groups $Company 'add-package' @($target[0], $line))
}

# Opens a file in the editor of this terminal ($VISUAL, $EDITOR, else nano or vi) and waits until it is closed.
# $EDITOR may carry its own options (e.g. "code --wait"), so it goes through sh.
function Open-Editor {
    param([string]$Path)
    $editor = @($env:VISUAL, $env:EDITOR) | Where-Object { $_ } | Select-Object -First 1
    if (-not $editor) {
        $editor = @('nano', 'vi') | Where-Object { Get-Command $_ -CommandType Application -ErrorAction SilentlyContinue } |
            Select-Object -First 1
    }
    if (-not $editor) {
        Write-Host "  No editor found (set EDITOR); edit it yourself: $Path"
        $null = Read-Line 'Enter when it is ready'
        return
    }
    Write-Host "  Opening it in $editor; save it and close the editor to go on."
    $code = Invoke-Native 'sh' @('-c', "$editor `"`$1`"", 'sh', $Path)
    if ($code -ne 0) { Write-Warn "the editor ended with code $code" }
}

# A new script (runs once, and again when it changes) or job (hourly, daily or weekly) for a group: the file from
# the tools/groups.ps1 template, opened in the editor, then the check of the source until it passes or you leave it
function New-GroupFileStep {
    param($Company, [ValidateSet('script', 'job', 'logon', 'startup', 'event')][string]$Kind)
    $group = @(Read-Groups $Company 'For the group (a new name makes a new group)')
    if ($group.Count -ne 1) { return $false }
    $arguments = @($group[0])
    $dir = Join-Path (Join-Path (Join-Path $Company.Source 'groups') $group[0]) $(if ($Kind -in @('logon', 'startup')) { $Kind } elseif ($Kind -eq 'event') { 'events' } else { 'scripts' })
    if ($Kind -eq 'job') {
        $every = [string](Read-Line 'How often: hourly, daily or weekly (Enter = daily)')
        if (-not $every) { $every = 'daily' }
        $arguments += $every
        $dir = Join-Path (Join-Path (Join-Path (Join-Path $Company.Source 'groups') $group[0]) 'jobs') $every
    }
    $example = @{ script = 'install-printer'; job = 'check-backup'; logon = 'network-drive'; startup = 'clean-temp'; event = 'after-wake' }[$Kind]
    $what = @{ script = 'script'; job = 'job'; logon = 'sign-in script'; startup = 'startup script'; event = 'event script' }[$Kind]
    $name = [string](Read-Line "Name of the $what, e.g. $example")
    if (-not $name) { return $false }
    $before = @(if ([IO.Directory]::Exists($dir)) { Get-ChildItem -LiteralPath $dir -File -Filter '*.ps1' | ForEach-Object FullName })
    if (-not (Invoke-Groups $Company "new-$Kind" ($arguments + $name))) { return $false }
    # A script gets a number for its place in the order (e.g. 20-install-printer.ps1)
    $path = @(Get-ChildItem -LiteralPath $dir -File -Filter '*.ps1' | ForEach-Object FullName | Where-Object { $before -notcontains $_ }) |
        Select-Object -First 1
    if (-not $path) { return $true }
    Edit-UntilChecked $Company $path
    return $true
}

# Opens the file in the editor, then checks the source; while the check fails, offers to open it again
function Edit-UntilChecked {
    param($Company, [string]$Path)
    Open-Editor $Path
    while (-not (Invoke-Groups $Company 'check')) {
        if (-not (Read-WmYesNo 'Open it again to fix it?' $true)) { break }
        Open-Editor $Path
    }
}

# One of a list, by its number or its text (any letter case: the item as the list writes it); asked again for an
# answer that isn't on it. $null: Enter, nothing chosen.
function Read-Choice {
    param([string[]]$Items, [string]$Prompt)
    for ($i = 0; $i -lt $Items.Count; $i++) { Write-Host ('  {0,2}) {1}' -f ($i + 1), $Items[$i]) }
    while ($true) {
        $answer = [string](Read-Line $Prompt)
        if (-not $answer) { return $null }
        $named = @($Items | Where-Object { $_ -ieq $answer })
        if ($named.Count -gt 0) { return $named[0] }
        $n = 0
        if ([int]::TryParse($answer, [ref]$n) -and $n -ge 1 -and $n -le $Items.Count) { return $Items[$n - 1] }
        Write-Host ('  Not on the list: {0}. A number from 1 to {1} or a name, or Enter for none.' -f $answer, $Items.Count) -ForegroundColor Yellow
    }
}

function Assert-Source {
    param($Company)
    if (-not [IO.Directory]::Exists($Company.Source)) { throw "$($Company.Name) has no source yet: pwsh tools/wm.ps1 new $($Company.Name)" }
}

# The packages of a list, the common one or a group's: their names, as remove-package takes them. Read line by line,
# so a list with a mistake (a duplicate, a bad line) still shows what it has and can be mended.
function Get-ListPackages {
    param($Company, [string]$Target)
    if ($Target -ne 'common' -and -not (Test-WmGroupName $Target)) { throw "invalid group name '$Target'" }
    $rel = if ($Target -eq 'common') { 'choco-reqs.txt' } else { "groups/$Target/choco-reqs.txt" }
    $path = Join-Path $Company.Source $rel
    if (-not [IO.File]::Exists($path)) { return @() }
    $names = foreach ($raw in ([IO.File]::ReadAllText($path).TrimStart([char]0xFEFF) -split '\r?\n')) {
        $line = ($raw -replace '(^|\s)#.*$', '').Trim()
        if ($line -match '^([A-Za-z0-9][A-Za-z0-9._-]*)') { $Matches[1] }
    }
    return @($names | Select-Object -Unique)
}

function Remove-PackageStep {
    param($Company)
    Assert-Source $Company
    $target = @(Read-Groups $Company 'From the list of a group, or common (every computer)' -Common)
    if ($target.Count -ne 1) { return $false }
    $names = @(Get-ListPackages $Company $target[0])
    if ($names.Count -eq 0) { Write-Host "  The list of $($target[0]) has no packages."; return $false }
    $name = Read-Choice $names 'Package to remove (number or name; Enter = none)'
    if (-not $name) { return $false }
    return (Invoke-Groups $Company 'remove-package' @($target[0], $name))
}

# The scripts and jobs the computers get, from the files a signature publishes (letter case as the computers read
# it: any case for the folders and .ps1): Rel (the path in the source), Path, Kind (script or job)
function Get-GroupFiles {
    param($Company)
    return @(foreach ($rel in @(Get-SignedFiles $Company.Source)) {
        if ($rel -imatch '^groups/[^/]+/scripts/[^/]+\.ps1$') { $kind = 'script' }
        elseif ($rel -imatch '^groups/[^/]+/jobs/(hourly|daily|weekly)/[^/]+\.ps1$') { $kind = 'job' }
        elseif ($rel -imatch '^groups/[^/]+/logon/[^/]+\.ps1$') { $kind = 'logon' }
        elseif ($rel -imatch '^groups/[^/]+/startup/[^/]+\.ps1$') { $kind = 'startup' }
        elseif ($rel -imatch '^groups/[^/]+/events/[^/]+\.ps1$') { $kind = 'event' }
        else { continue }
        [pscustomobject]@{ Rel = $rel; Path = Join-Path $Company.Source $rel; Kind = $kind }
    })
}

# Edit or remove a script or job of a group
function Edit-GroupFileStep {
    param($Company)
    Assert-Source $Company
    $files = @(Get-GroupFiles $Company)
    if ($files.Count -eq 0) { Write-Host '  The groups have no scripts or jobs yet (7, 8, 20, 21 and 22 make new ones).'; return $false }
    $rel = Read-Choice @($files | ForEach-Object Rel) 'Which one (number; Enter = none)'
    if (-not $rel) { return $false }
    $file = $files | Where-Object { $_.Rel -ceq $rel } | Select-Object -First 1
    while ($true) {
        $what = [string](Read-Line 'e = edit it, r = remove it (Enter = neither)')
        if (-not $what) { return $false }
        if (@('e', 'r') -contains $what) { break }
        Write-Host '  e, r or Enter.' -ForegroundColor Yellow
    }
    if ($what -eq 'e') {
        if ($file.Kind -eq 'script') {
            Write-Host '  A changed script runs again on every computer of its group, once (even for a comment): mind'
            Write-Host '  what running it twice does.'
        }
        Edit-UntilChecked $Company $file.Path
        return $true
    }
    if ($file.Kind -ne 'job') { Write-Host '  The computers keep what it did; it just won''t run again.' }
    else { Write-Host '  The computers stop running it at their next update.' }
    if (-not (Read-WmYesNo "Remove $rel?" $false)) { return $false }
    Remove-Item -LiteralPath $file.Path
    Write-Host "  Removed $rel."
    # What the group is left with (e.g. a group in groups.psd1 without files any more)
    $null = Invoke-Groups $Company 'check'
    return $true
}

function Enable-LibraryStep {
    param($Company)
    if (-not (Invoke-Groups $Company 'library')) { return $false }
    $name = [string](Read-Line 'Name to enable (from the list above)')
    if (-not $name) { return $false }
    $group = @(Read-Groups $Company 'For the group')
    if ($group.Count -ne 1) { return $false }
    return (Invoke-Groups $Company 'enable' @($name, $group[0]))
}

function Set-VersionStep {
    param($Company)
    $version = Read-Line 'wmanager version, e.g. v0.2.0 (Enter = the latest release; - = no version: computers keep theirs)'
    if ($null -eq $version) { return $false }
    $group = [string](Read-Line 'Only for one group? Its name (Enter = every computer)')
    $groupArg = @($group | Where-Object { $_ })
    if ($version -eq '-') { return (Invoke-Groups $Company 'unset-version' $groupArg) }
    if (-not $version) {
        $version = Get-LatestTag
        Write-Host "  The latest release: $version"
    }
    # Every computer (or the group's) installs it at its next update: ask, the default being no
    $who = if ($group) { "the computers of group $group" } else { 'every computer' }
    if (-not (Read-WmYesNo "  $who switches to wmanager $version at its next update. Set it?" $false)) { return $false }
    return (Invoke-Groups $Company 'set-version' (@($version) + $groupArg))
}

function Invoke-CompanyMenu {
    param($Company)
    while ($true) {
        Write-Host ''
        Write-Host ('{0}: {1}' -f $Company.Name, (Get-CompanyState $Company)) -ForegroundColor Cyan
        $setUp = (Test-HasKey $Company) -and [IO.File]::Exists((Join-Path $Company.Source 'manifest.psd1')) -and
                 [IO.File]::Exists($Company.Config)
        if (-not $setUp) { Write-Host '  0) finish setting it up (key, source, first signature, configuration)' }
        Write-Host '  1) status of the computers (Healthchecks, Loki)'
        Write-Host '  2) show the groups, or what one computer gets'
        Write-Host '  3) add a computer to groups'
        Write-Host '  4) remove a computer from groups'
        Write-Host '  5) add a package (to a group, or to every computer)'
        Write-Host '  6) remove a package'
        Write-Host '  7) new script for a group (from a template, in your editor)'
        Write-Host '  8) new job for a group: hourly, daily or weekly (from a template, in your editor)'
        Write-Host '  9) edit or remove a script or job of a group'
        Write-Host ' 10) enable a ready script or job from the library'
        Write-Host ' 11) set the wmanager version the computers run'
        Write-Host ' 12) check the source, and what changed since the last signature'
        Write-Host ' 13) sign, and send it where the computers read it'
        Write-Host ' 14) configuration wizard (provision.config.psd1)'
        Write-Host ' 15) read-only keys for the status (Healthchecks, Grafana Cloud)'
        Write-Host ' 16) where the computers read the source from (Git repository or folder)'
        Write-Host ' 17) a backup of this company (an archive of its source, key and configuration)'
        Write-Host ' 18) change the signing key, with a time when the computers trust both'
        Write-Host ' 19) secrets for scripts (passwords in the configuration, not in the source)'
        Write-Host ' 20) new sign-in script for a group: runs as the user at every sign-in (e.g. a network drive)'
        Write-Host ' 21) new startup script for a group: runs as SYSTEM at every start of the computer'
        Write-Host ' 22) new event script for a group: runs as SYSTEM at an event (network, wake, lock, unlock, a log)'
        Write-Host '  b) back'
        $answer = Read-Line 'Choose'
        if ($null -eq $answer -or $answer -eq 'b' -or $answer -eq 'q') { return }
        try {
            $changed = $false
            switch ($answer) {
                '0' { New-Company $Company.Name }
                '1' { Show-StatusStep $Company }
                '2' {
                    $pc = [string](Read-Line 'Computer (Enter = all groups)')
                    $null = Invoke-Groups $Company 'show' @($pc | Where-Object { $_ })
                }
                '3' { $changed = Add-ComputerStep $Company }
                '4' { $changed = Remove-ComputerStep $Company }
                '5' { $changed = Add-PackageStep $Company }
                '6' { $changed = Remove-PackageStep $Company }
                '7' { $changed = New-GroupFileStep $Company 'script' }
                '8' { $changed = New-GroupFileStep $Company 'job' }
                '9' { $changed = Edit-GroupFileStep $Company }
                '10' { $changed = Enable-LibraryStep $Company }
                '11' { $changed = Set-VersionStep $Company }
                '12' {
                    $null = Invoke-Groups $Company 'check'
                    Show-SourceChanges $Company
                }
                '13' { $null = Publish-Company $Company }
                '14' { Invoke-Wizard $Company }
                '15' { Set-Monitoring $Company }
                '16' { Set-PublishTarget $Company }
                '18' { Invoke-KeyChange $Company }
                '19' { Edit-SecretsStep $Company }
                '20' { $changed = New-GroupFileStep $Company 'logon' }
                '21' { $changed = New-GroupFileStep $Company 'startup' }
                '22' { $changed = New-GroupFileStep $Company 'event' }
                '17' {
                    $folder = [string](Read-Line "Folder for the archive (Enter = $($script:BackupRoot))")
                    $null = Backup-Company $Company $folder
                    Write-Host '  It holds the signing key (protected by its passphrase) and the tokens: keep it safe.'
                }
                default { if ($answer) { Write-Host '  Choose a number from the list, or b.' -ForegroundColor Yellow } }
            }
            if ($changed) {
                $changes = Get-SourceChanges $Company
                if (Test-SourceChanged $changes) {
                    Show-SourceChanges $Company $changes
                    if (Read-WmYesNo 'Sign and publish now? The computers see the change only after that.' $true) {
                        $null = Publish-Company $Company -Confirmed
                    }
                }
            }
        } catch {
            Write-Host "ERROR: $(Format-WmErrorText $_ -English)" -ForegroundColor Red
        }
    }
}

function Invoke-Menu {
    while ($true) {
        $companies = @(Get-Companies)
        Write-Host ''
        Write-Host "Companies in $($script:Root):" -ForegroundColor Cyan
        if ($companies.Count -eq 0) { Write-Host '  none yet' }
        for ($i = 0; $i -lt $companies.Count; $i++) {
            Write-Host ('  {0}) {1,-20} {2}' -f ($i + 1), $companies[$i].Name, (Get-CompanyState $companies[$i]))
        }
        Write-Host '  s) status of the computers of every company'
        Write-Host '  n) a new company'
        Write-Host '  u) wmanager and the configurations onto a USB drive or a share'
        Write-Host '  k) a backup of every company (archives)'
        Write-Host '  r) a company back from a backup'
        Write-Host '  q) quit'
        $answer = Read-Line 'Choose'
        if ($null -eq $answer -or $answer -eq 'q') { return }
        try {
            $n = 0
            $named = @($companies | Where-Object { $_.Name -eq $answer })
            if ([int]::TryParse($answer, [ref]$n) -and $n -ge 1 -and $n -le $companies.Count) {
                Invoke-CompanyMenu $companies[$n - 1]
            } elseif ($named.Count -eq 1) {
                Invoke-CompanyMenu $named[0]
            } elseif ($answer -eq 's') {
                Show-AllStatus
            } elseif ($answer -eq 'n') {
                $name = [string](Read-Line 'Name of the new company (letters, digits, . - _), e.g. acme')
                if ($name) { New-Company $name }
            } elseif ($answer -eq 'k') {
                $folder = [string](Read-Line "Folder for the archives (Enter = $($script:BackupRoot))")
                Backup-AllCompanies $folder
            } elseif ($answer -eq 'r') {
                $archive = [string](Read-Line 'The archive (a .tar.gz from a backup)')
                if ($archive) { Restore-Company $archive }
            } elseif ($answer -eq 'u') {
                $folder = [string](Read-Line 'Folder on the USB drive or the share, e.g. /media/you/USB/wmanager')
                if ($folder) { Copy-ToUsb $folder }
            } elseif ($answer) {
                Write-Host '  Choose a number from the list, s, n, u, k, r or q.' -ForegroundColor Yellow
            }
        } catch {
            Write-Host "ERROR: $(Format-WmErrorText $_ -English)" -ForegroundColor Red
        }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {
    if (-not $First) {
        Invoke-Menu
    } elseif ($First -eq 'list') {
        Show-Companies
    } elseif ($First -eq 'new') {
        if (-not $Second) { throw 'usage: pwsh tools/wm.ps1 new <company>' }
        New-Company $Second
    } elseif ($First -eq 'usb') {
        Copy-ToUsb $Second
    } elseif ($First -eq 'backup') {
        # "backup acme" means acme's backup, not a folder ./acme for every company's archives
        if ($Second -and @(Get-Companies | Where-Object { $_.Name -ieq $Second }).Count -gt 0) {
            throw "$Second is a company: pwsh tools/wm.ps1 $Second backup [<folder>] backs it up; pwsh tools/wm.ps1 backup [<folder>] backs up every company"
        }
        Backup-AllCompanies $Second
    } elseif ($First -eq 'restore') {
        Restore-Company $Second
    } elseif ($First -eq 'status') {
        Show-AllStatus
    } elseif ($First -eq 'help') {
        Show-Usage
    } else {
        $company = Get-Company $First
        if (-not $Second) {
            Invoke-CompanyMenu $company
        } elseif ($Second -eq 'publish') {
            # Exit code 1 when the computers' address didn't give what was sent (scripts can tell)
            if ((Publish-Company $company -Confirmed:$Yes -Wait:$Yes) -eq $false) { exit 1 }
        } elseif ($Second -eq 'sync') {
            if ((Sync-Company $company -Wait:$Yes) -eq $false) { exit 1 }
        } elseif ($Second -eq 'target') {
            Set-PublishTarget $company
        } elseif ($Second -eq 'rotate-key') {
            Invoke-KeyChange $company
        } elseif ($Second -eq 'backup') {
            $null = Backup-Company $company @($Rest | Where-Object { $_ })[0]
        } elseif ($Second -eq 'changes') {
            Show-SourceChanges $company
        } elseif ($Second -eq 'config') {
            Invoke-Wizard $company
        } elseif ($Second -eq 'status') {
            Show-ComputerStatus $company
        } elseif ($Second -eq 'monitoring') {
            Set-Monitoring $company
        } elseif ($Second -eq 'secret') {
            $words = @($Rest | Where-Object { $_ })
            if ($words.Count -eq 0) { Show-Secrets $company }
            elseif ($words.Count -eq 1) { $null = Set-Secret $company $words[0] }
            elseif ($words.Count -eq 2 -and $words[1] -eq 'remove') { Remove-Secret $company $words[0] }
            else { throw "usage: pwsh tools/wm.ps1 $($company.Name) secret [<name> [remove]]" }
        } else {
            $named = @{}
            if ($Url) { $named['Url'] = $Url }
            if ($Zip) { $named['Zip'] = $Zip }
            if (-not (Invoke-Groups $company $Second @($Rest | Where-Object { $null -ne $_ }) $named)) { exit 1 }
        }
    }
} catch {
    Write-Host "ERROR: $(Format-WmErrorText $_ -English)" -ForegroundColor Red
    if ($env:WM_DEBUG) { Write-Host $_.ScriptStackTrace }
    exit 1
}
exit 0
