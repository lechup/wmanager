# wmanager: several companies from one place. Each company has its own folder under ~/wmanager-companies (another
# place: the WMANAGER_COMPANIES environment variable):
#   <company>/source/   its management source (a private Git repository, or a folder copied to a server or a share)
#   <company>/keys/     its signing key (tools/new-signing-cert.sh); stays on this computer, never in the source
#   <company>/config/   its provision.config.psd1 and the certificate next to it (the wizard, init.ps1)
# Without arguments it asks which company and what to do, and says what comes next; the commands below do the same
# without the menu. It runs the other tools (groups.ps1, publish.sh, new-signing-cert.sh, init.ps1) on the folders of
# the chosen company. README, "Several companies".
#
#   pwsh tools/wm.ps1                          the menu
#   pwsh tools/wm.ps1 list                     the companies and their state
#   pwsh tools/wm.ps1 status                   the computers of every company, one line each (Healthchecks, Loki)
#   pwsh tools/wm.ps1 new <company>            key, source (from examples/management), first signature, configuration;
#                                              run it again and it carries on where it stopped
#   pwsh tools/wm.ps1 usb <folder>             wmanager (the latest release, when the folder has none) and every
#                                              company's configuration, for run.cmd, which then asks which company
#   pwsh tools/wm.ps1 <company>                the menu of one company
#   pwsh tools/wm.ps1 <company> status         its computers: Healthchecks, the last update, errors, wmanager version
#   pwsh tools/wm.ps1 <company> monitoring     the read-only keys status needs (kept in <company>/monitoring.psd1)
#   pwsh tools/wm.ps1 <company> publish        check and sign its source (tools/publish.sh)
#   pwsh tools/wm.ps1 <company> config         the configuration wizard (init.ps1) for its provision.config.psd1
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
    [string]$Zip
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path (Join-Path $repo 'lib') 'Lang.ps1')
. (Join-Path (Join-Path $repo 'lib') 'Groups.ps1')   # the version each computer should run, as the computers work it out
Initialize-WmLanguage -Lang 'en' -Root $repo

$script:Self = $PSCommandPath
$script:Tools = $PSScriptRoot
# A full path: the .NET calls, the cmdlets and the bash tools must all read it the same way
function ConvertTo-FullPath {
    param([string]$Path)
    if ($Path -match '^~(/|$)') { $Path = $HOME + $Path.Substring(1) }
    return [IO.Path]::GetFullPath($Path)
}

$script:Root = if ($env:WMANAGER_COMPANIES) { ConvertTo-FullPath $env:WMANAGER_COMPANIES } else { Join-Path $HOME 'wmanager-companies' }
$script:Commands = @('list', 'new', 'usb', 'status', 'help')
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
# ones that aren't ignored), otherwise every file; never hidden ones (.git, .gitattributes) or manifest.psd1
function Get-SignedFiles {
    param([string]$Source)
    $list = $null
    if (Get-Command git -CommandType Application -ErrorAction SilentlyContinue) {
        $inside = & git -C $Source rev-parse --is-inside-work-tree 2>$null
        if ($LASTEXITCODE -eq 0 -and $inside -eq 'true') {
            $list = @(& git -C $Source ls-files --cached --others --exclude-standard -- . 2>$null |
                Where-Object { [IO.File]::Exists((Join-Path $Source $_)) })
        }
    }
    if ($null -eq $list) {
        $list = @(Get-ChildItem -LiteralPath $Source -Recurse -File -Force |
            ForEach-Object { [IO.Path]::GetRelativePath($Source, $_.FullName).Replace('\', '/') })
    }
    return @($list | Where-Object { $_ -ne 'manifest.psd1' -and "/$_" -notmatch '/\.' } | Sort-Object -Unique)
}

# Has anything in the source changed since the last signature? Its files against the hashes in manifest.psd1.
function Test-UnsignedChanges {
    param($Company)
    try { $signed = (Import-PowerShellDataFile -LiteralPath (Join-Path $Company.Source 'manifest.psd1')).Files }
    catch { return $true }
    if (-not ($signed -is [hashtable])) { return $true }
    $files = @(Get-SignedFiles $Company.Source)
    if ($files.Count -ne $signed.Count) { return $true }
    foreach ($rel in $files) {
        $want = $signed[$rel]
        if (-not $want -or $want -ne (Get-FileHash -LiteralPath (Join-Path $Company.Source $rel) -Algorithm SHA256).Hash) { return $true }
    }
    return $false
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
        if (-not [IO.File]::Exists((Join-Path $Company.Source 'manifest.psd1'))) { $parts.Add('not signed yet') }
        elseif (Test-UnsignedChanges $Company) { $parts.Add('changes not signed yet') }
        if (-not $hasKey) { $parts.Add('no signing key') }
    }
    if (-not [IO.File]::Exists($Company.Config)) { $parts.Add('no configuration yet') }
    return ($parts -join ', ')
}

function Show-Companies {
    $companies = @(Get-Companies)
    if ($companies.Count -eq 0) {
        Write-Host "No companies in $($script:Root) yet: pwsh tools/wm.ps1 new <company>"
        return
    }
    foreach ($c in $companies) { Write-Host ('{0,-20} {1}' -f $c.Name, (Get-CompanyState $c)) }
}

# ---------------------------------------------------------------------------
# The other tools
# ---------------------------------------------------------------------------

# Runs a program in this terminal without capturing anything, so it can ask for a passphrase. Its PATH starts with
# the folder of this pwsh: tools/publish.sh checks the source with pwsh even when pwsh isn't on PATH.
function Invoke-Native {
    param([string]$File, [string[]]$Arguments)
    $psi = New-Object System.Diagnostics.ProcessStartInfo $File
    foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.Environment['PATH'] = (Split-Path (Get-Process -Id $PID).Path -Parent) + [IO.Path]::PathSeparator + $env:PATH
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

# Checks and signs the source with the company's key (tools/publish.sh, which says what to do next: push or copy)
function Publish-Company {
    param($Company)
    if (-not [IO.Directory]::Exists($Company.Source)) { throw "$($Company.Name) has no source yet: pwsh tools/wm.ps1 new $($Company.Name)" }
    if (-not (Test-HasKey $Company)) { throw "$($Company.Name) has no signing key in $($Company.Keys): pwsh tools/wm.ps1 new $($Company.Name)" }
    $code = Invoke-Native 'bash' @((Join-Path $script:Tools 'publish.sh'), $Company.Source, $Company.Keys)
    if ($code -ne 0) { throw 'not signed (the reason is above)' }
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
        throw "invalid company name '$Name': 2 to 40 letters, digits, '.', '-', '_', with a letter (not list, new, usb or help)"
    }
    # Folders that differ only in letter case would be one folder on the USB drive (configs\<company>)
    $other = @(Get-Companies | Where-Object { $_.Name -ieq $Name -and $_.Name -cne $Name })
    if ($other.Count -gt 0) { throw "there is a company $($other[0].Name) already; names that differ only in letter case would mix up on a USB drive" }
    $c = Get-CompanyPaths $Name
    New-Item -ItemType Directory -Force -Path $c.Dir | Out-Null

    Write-Step "1/4 Signing key: $($c.Keys)"
    $key = Join-Path $c.Keys 'key.pem'
    if (Test-HasKey $c) {
        Write-Host '  Already there.'
    } elseif ([IO.File]::Exists($key) -and (Get-Item -LiteralPath $key).Length -gt 0) {
        throw "$($c.Keys) has a key.pem but no certificates (cert.pem, wmanager-signing.cer); make them from that key, or move it away and run: pwsh tools/wm.ps1 new $Name"
    } else {
        # An empty key.pem is what a creation stopped at the passphrase leaves
        if ([IO.File]::Exists($key)) { Remove-Item -LiteralPath $key }
        Write-Host '  A key of its own: a company that leaves takes its key and has no way into the others.'
        if ((Invoke-Native 'bash' @((Join-Path $script:Tools 'new-signing-cert.sh'), $c.Keys)) -ne 0) {
            throw "no key (the reason is above); to carry on: pwsh tools/wm.ps1 new $Name"
        }
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
        try { Publish-Company $c }
        catch { throw "$(Format-WmErrorText $_ -English); to carry on: pwsh tools/wm.ps1 new $Name" }
    }

    Write-Step "4/4 Configuration for the computers: $($c.Config)"
    if ([IO.File]::Exists($c.Config)) {
        Write-Host "  Already there; to change it: pwsh tools/wm.ps1 $Name config"
    } else {
        Write-Host '  The computers read the source from where you put it, either:'
        Write-Host "  - a private Git repository: cd $($c.Source); git init; git add -A; git commit -m 'Management source';"
        Write-Host '    then add the remote and push;'
        Write-Host '  - or a folder on a web server or a share: copy the folder there, manifest.psd1 last.'
        Write-Host '  The wizard asks for that address, then for the update time, Loki and Healthchecks (all optional).'
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
    Write-Host 'The configurations hold the tokens (Loki, Healthchecks, the source): keep the drive under control.'
}

# ---------------------------------------------------------------------------
# The computers: what Healthchecks and Loki know, read with read-only keys kept on this computer
# ---------------------------------------------------------------------------

$script:StatusDays = 14   # how far back Loki is read (Grafana Cloud's free plan keeps 14 days)

# https only, except on this computer (the tests' stand-in servers)
function Test-ServiceUrl {
    param([string]$Url)
    return ($Url -match '^https://[^/]' -or $Url -match '^http://(127\.0\.0\.1|localhost)(:\d+)?(/|$)')
}

# A single-quoted PowerShell string
function ConvertTo-PsdLiteral {
    param([AllowEmptyString()][string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

# A secret typed at the terminal without showing it (piped input: as it comes)
function Read-Secret {
    param([string]$Prompt)
    if ([Console]::IsInputRedirected) { return [string](Read-Line $Prompt) }
    $secure = Read-Host $Prompt -AsSecureString
    return ([Net.NetworkCredential]::new('', $secure).Password).Trim()
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

# Where the company's computers send their logs and pings: from its provision.config.psd1
function Read-Reporting {
    param($Company)
    if (-not [IO.File]::Exists($Company.Config)) { throw "$($Company.Name) has no configuration yet: pwsh tools/wm.ps1 $($Company.Name) config" }
    $cfg = Import-PowerShellDataFile -LiteralPath $Company.Config
    $loki = [string]$cfg.LokiUrl
    $loki = ($loki -replace '/loki/api/v1/push$', '').TrimEnd('/')
    $hcBase = if ($cfg.HealthchecksBaseUrl) { [string]$cfg.HealthchecksBaseUrl } else { 'https://hc-ping.com' }
    # The API of healthchecks.io for hc-ping.com; a server of your own has both under one address (.../ping)
    $hcApi = if ($hcBase -match '^https://hc-ping\.com/?$') { 'https://healthchecks.io' } else { ($hcBase.TrimEnd('/') -replace '/ping$', '') }
    return [pscustomobject]@{
        LokiUrl     = $loki
        LokiUser    = [string]$cfg.LokiUser
        HasLoki     = [bool]($loki -and $cfg.LokiToken)
        HasPings    = [bool]$cfg.HealthchecksPingKey
        HcApiUrl    = $hcApi
        SlugPrefix  = [string]$cfg.HealthchecksSlugPrefix
    }
}

# Asks for the read-only keys and keeps them in <company>/monitoring.psd1 (readable by you only)
function Set-Monitoring {
    param($Company)
    $r = Read-Reporting $Company
    if (-not $r.HasPings -and -not $r.HasLoki) {
        throw "the configuration of $($Company.Name) sends nothing to Healthchecks or Loki; set them up first: pwsh tools/wm.ps1 $($Company.Name) config"
    }
    $old = Read-Monitoring $Company
    if ($null -eq $old) { $old = @{} }
    Write-Step "Read-only access for the status of the computers of $($Company.Name)"
    Write-Host '  The keys stay on this computer, in' (Get-MonitoringPath $Company)
    $hcKey = [string]$old.HealthchecksApiKey
    $hcUrl = if ($old.HealthchecksApiUrl) { [string]$old.HealthchecksApiUrl } else { $r.HcApiUrl }
    if ($r.HasPings) {
        Write-Host "  Healthchecks: in the project the computers ping, Settings > API Access > Create API key (read-only)."
        $hint = if ($hcKey) { 'Enter = keep the one you have, - = none' } else { 'Enter = none' }
        $a = Read-Secret "  Healthchecks read-only API key ($hint)"
        if ($a -eq '-') { $hcKey = '' } elseif ($a) { $hcKey = $a }
    }
    $lokiToken = [string]$old.LokiReadToken
    if ($r.HasLoki) {
        Write-Host "  Grafana Cloud: Administration > Access policies > a policy with the logs:read scope, then Add token."
        Write-Host "  (The user is the configuration's LokiUser, $($r.LokiUser).)"
        $hint = if ($lokiToken) { 'Enter = keep the one you have, - = none' } else { 'Enter = none' }
        $a = Read-Secret "  Grafana Cloud token with logs:read ($hint)"
        if ($a -eq '-') { $lokiToken = '' } elseif ($a) { $lokiToken = $a }
    }
    $text = @(
        '# Read-only access for pwsh tools/wm.ps1 <company> status. Written by it; it stays on this computer, never on the'
        '# drive or the computers (they have write-only keys in provision.config.psd1).'
        '@{'
        '    # Healthchecks: the read-only API key of the project the computers ping, and the address of its API'
        "    HealthchecksApiKey = $(ConvertTo-PsdLiteral $hcKey)"
        "    HealthchecksApiUrl = $(ConvertTo-PsdLiteral $hcUrl)"
        '    # Grafana Cloud: a token with the logs:read scope (with the LokiUser and LokiUrl of the configuration)'
        "    LokiReadToken      = $(ConvertTo-PsdLiteral $lokiToken)"
        '}'
    ) -join "`n"
    $path = Get-MonitoringPath $Company
    [IO.File]::WriteAllText($path, $text + "`n")
    if (-not $IsWindows) { & chmod 600 $path }
    Write-Host "  Saved: $path"
}

# Healthchecks: the check of each computer (slug = the prefix of the configuration + the computer name, as the
# computers ping it), by computer name in lowercase
function Get-HealthchecksStatus {
    param($Reporting, $Monitoring)
    $url = ([string]$Monitoring.HealthchecksApiUrl).TrimEnd('/')
    if (-not (Test-ServiceUrl $url)) { throw "HealthchecksApiUrl must be an https:// address ('$url')" }
    $resp = Invoke-RestMethod -Uri "$url/api/v3/checks/" -Headers @{ 'X-Api-Key' = [string]$Monitoring.HealthchecksApiKey } -TimeoutSec 30
    $result = @{}
    $prefix = $Reporting.SlugPrefix.ToLowerInvariant() -replace '[^a-z0-9_-]', '-'
    foreach ($c in @($resp.checks)) {
        $slug = [string]$c.slug
        if (-not $slug -or ($prefix -and -not $slug.StartsWith($prefix))) { continue }
        $result[$slug.Substring($prefix.Length)] = [pscustomobject]@{ Status = [string]$c.status; LastPing = ConvertTo-Time $c.last_ping }
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
    param($Reporting, $Monitoring, [string]$Path, [hashtable]$Query)
    if (-not (Test-ServiceUrl $Reporting.LokiUrl)) { throw "LokiUrl must be an https:// address ('$($Reporting.LokiUrl)')" }
    $pair = '{0}:{1}' -f $Reporting.LokiUser, $Monitoring.LokiReadToken
    $headers = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair)) }
    $q = @($Query.Keys | ForEach-Object { '{0}={1}' -f $_, [uri]::EscapeDataString([string]$Query[$_]) }) -join '&'
    return Invoke-RestMethod -Uri "$($Reporting.LokiUrl)$Path`?$q" -Headers $headers -TimeoutSec 60
}

# Loki: for each computer (the host label, lowercase) its last run (the start line names the wmanager version, the
# summary line the warnings and errors) and the errors of the last 24 hours, jobs included. The log lines are
# always English, so the same patterns read every computer.
function Get-LokiStatus {
    param($Reporting, $Monitoring)
    $now = [datetimeoffset]::UtcNow
    $ns = { param($t) [string]($t.ToUnixTimeMilliseconds() * 1000000) }
    $runs = Invoke-Loki $Reporting $Monitoring '/loki/api/v1/query_range' @{
        query     = '{service_name="wmanager", job=~"update|retry|provision"} |~ `^(wmanager( v\S+)? (update|retry) on |wmanager( v\S+)? provisioning: |End: warnings |Done: \d+ warnings)`'
        start     = (& $ns $now.AddDays(-$script:StatusDays))
        end       = (& $ns $now)
        limit     = 5000
        direction = 'backward'
    }
    $result = @{}
    foreach ($s in @($runs.data.result)) {
        $hostName = [string]$s.stream.host
        if (-not $hostName) { continue }
        if (-not $result.ContainsKey($hostName)) {
            $result[$hostName] = [pscustomobject]@{ Version = $null; VersionAt = $null; LastRun = $null; Warnings = 0; Errors = 0; Errors24h = 0 }
        }
        $r = $result[$hostName]
        foreach ($v in @($s.values)) {
            $at = ConvertFrom-LokiTime $v[0]
            $line = [string]$v[1]
            if ($line -match '^wmanager(?: (v\S+))? (?:update|retry) on |^wmanager(?: (v\S+))? provisioning: ') {
                if ($null -eq $r.VersionAt -or $at -gt $r.VersionAt) {
                    $r.VersionAt = $at
                    $r.Version = if ($Matches[1]) { $Matches[1] } elseif ($Matches[2]) { $Matches[2] } else { '?' }
                }
            } elseif ($line -match '^End: warnings (\d+), errors (\d+)' -or $line -match '^Done: (\d+) warnings, (\d+) errors') {
                if ($null -eq $r.LastRun -or $at -gt $r.LastRun) { $r.LastRun = $at; $r.Warnings = [int]$Matches[1]; $r.Errors = [int]$Matches[2] }
            }
        }
    }
    $errors = Invoke-Loki $Reporting $Monitoring '/loki/api/v1/query' @{
        query = 'sum by (host) (count_over_time({service_name="wmanager", level="error"}[24h]))'
        time  = (& $ns $now)
    }
    foreach ($e in @($errors.data.result)) {
        $hostName = [string]$e.metric.host
        if (-not $hostName) { continue }
        if (-not $result.ContainsKey($hostName)) {
            $result[$hostName] = [pscustomobject]@{ Version = $null; VersionAt = $null; LastRun = $null; Warnings = 0; Errors = 0; Errors24h = 0 }
        }
        $result[$hostName].Errors24h = [int][double]$e.value[1]
    }
    return $result
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
# reported. Returns the rows; -Quiet doesn't print them (the summary of every company).
function Get-ComputerStatus {
    param($Company)
    $r = Read-Reporting $Company
    $m = Read-Monitoring $Company
    if ($null -eq $m -or (-not $m.HealthchecksApiKey -and -not $m.LokiReadToken)) {
        throw "no read-only keys for $($Company.Name) yet: pwsh tools/wm.ps1 $($Company.Name) monitoring"
    }
    $problems = New-Object System.Collections.Generic.List[string]
    $hc = $null
    if ($m.HealthchecksApiKey -and $r.HasPings) {
        try { $hc = Get-HealthchecksStatus $r $m } catch { $problems.Add("Healthchecks: $($_.Exception.Message)") }
    }
    $loki = $null
    if ($m.LokiReadToken -and $r.HasLoki) {
        try { $loki = Get-LokiStatus $r $m } catch { $problems.Add("Loki: $($_.Exception.Message)") }
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
    foreach ($k in @(@($hc.Keys) + @($loki.Keys))) {
        if ($k -and -not $names.ContainsKey($k)) { $names[$k] = $k.ToUpperInvariant() }
    }

    $rows = foreach ($k in ($names.Keys | Sort-Object)) {
        $h = if ($hc) { $hc[$k] } else { $null }
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
        if ($want -and $l -and $l.Version -and $l.Version -ne $want) { $flags.Add('version') }
        if (-not $h -and -not $l) { $flags.Add('silent') }
        [pscustomobject]@{
            Name = $names[$k]; Check = $h; Log = $l; Want = $want; Flags = @($flags)
        }
    }
    return [pscustomobject]@{ Rows = @($rows); Problems = @($problems); HasPings = [bool]$hc; HasLoki = [bool]$loki }
}

function Show-ComputerStatus {
    param($Company)
    $s = Get-ComputerStatus $Company
    foreach ($p in $s.Problems) { Write-Warn $p }
    if ($s.Rows.Count -eq 0) { Write-Host "No computers of $($Company.Name) in groups.psd1, Healthchecks or Loki yet."; return }
    $format = '{0,-16} {1,-14} {2,-24} {3,-24} {4}'
    Write-Host ($format -f 'Computer', 'Healthchecks', 'Last update', 'Result', 'wmanager')
    foreach ($row in $s.Rows) {
        $check = '-'
        if ($row.Check) { $check = ('{0} {1}' -f $row.Check.Status, (Format-Age $row.Check.LastPing)).Trim() }
        elseif (-not $s.HasPings) { $check = '' }
        $last = '-'; $result = '-'; $version = '-'
        if ($row.Log) {
            if ($row.Log.LastRun) {
                $last = '{0} {1}' -f $row.Log.LastRun.ToString('yyyy-MM-dd HH:mm'), (Format-Age $row.Log.LastRun)
                $result = if ($row.Log.Errors) { "$($row.Log.Errors) errors" } elseif ($row.Log.Warnings) { "$($row.Log.Warnings) warnings" } else { 'ok' }
            }
            if ($row.Log.Errors24h) { $result = ('{0}, {1} errors/24h' -f $result, $row.Log.Errors24h).TrimStart('-, ') }
            if ($row.Log.Version) { $version = $row.Log.Version }
        } elseif (-not $s.HasLoki) { $last = ''; $result = ''; $version = '' }
        if ($row.Flags -contains 'version') { $version = "$version -> $($row.Want)" }
        $color = if ($row.Flags -contains 'down' -or $row.Flags -contains 'errors') { 'Red' } elseif ($row.Flags.Count -gt 0) { 'Yellow' } else { 'Gray' }
        Write-Host ($format -f $row.Name, $check, $last, $result, $version) -ForegroundColor $color
    }
    Write-Host ''
    Write-Host (Format-StatusSummary $s)
    Write-Host "Loki: the last $($script:StatusDays) days; (5h) = 5 hours ago, '-' = nothing reported, 'a -> b' = on a, switches to b at its next update."
}

function Format-StatusSummary {
    param($Status)
    $count = { param($f) @($Status.Rows | Where-Object { $_.Flags -contains $f }).Count }
    $parts = @('{0} computers' -f $Status.Rows.Count)
    foreach ($f in @(@('down', 'down'), @('errors', 'with errors'), @('version', 'not on their version yet'), @('silent', 'never reported'))) {
        $n = & $count $f[0]
        if ($n -gt 0) { $parts += "$n $($f[1])" }
    }
    if ($parts.Count -eq 1) { $parts += 'all fine' }
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
        } catch {
            $line = Format-WmErrorText $_ -English
        }
        Write-Host ('{0,-20} {1}' -f $c.Name, $line)
    }
}

# ---------------------------------------------------------------------------
# Menus
# ---------------------------------------------------------------------------

function Show-StatusStep {
    param($Company)
    $m = Read-Monitoring $Company
    if ($null -eq $m -or (-not $m.HealthchecksApiKey -and -not $m.LokiReadToken)) {
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
    $line = [string](Read-Line 'Package: a line of choco-reqs.txt, e.g. 7zip or vlc --version 3.0.21')
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
    param($Company, [ValidateSet('script', 'job')][string]$Kind)
    $group = @(Read-Groups $Company 'For the group (a new name makes a new group)')
    if ($group.Count -ne 1) { return $false }
    $arguments = @($group[0])
    $dir = Join-Path (Join-Path (Join-Path $Company.Source 'groups') $group[0]) 'scripts'
    if ($Kind -eq 'job') {
        $every = [string](Read-Line 'How often: hourly, daily or weekly (Enter = daily)')
        if (-not $every) { $every = 'daily' }
        $arguments += $every
        $dir = Join-Path (Join-Path (Join-Path (Join-Path $Company.Source 'groups') $group[0]) 'jobs') $every
    }
    $example = if ($Kind -eq 'script') { 'install-printer' } else { 'check-backup' }
    $name = [string](Read-Line "Name of the $Kind, e.g. $example")
    if (-not $name) { return $false }
    $before = @(if ([IO.Directory]::Exists($dir)) { Get-ChildItem -LiteralPath $dir -File -Filter '*.ps1' | ForEach-Object FullName })
    if (-not (Invoke-Groups $Company "new-$Kind" ($arguments + $name))) { return $false }
    # A script gets a number for its place in the order (e.g. 20-install-printer.ps1)
    $path = @(Get-ChildItem -LiteralPath $dir -File -Filter '*.ps1' | ForEach-Object FullName | Where-Object { $before -notcontains $_ }) |
        Select-Object -First 1
    if (-not $path) { return $true }
    Open-Editor $path
    while (-not (Invoke-Groups $Company 'check')) {
        if (-not (Read-WmYesNo 'Open it again to fix it?' $true)) { break }
        Open-Editor $path
    }
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
        Write-Host '  6) new script for a group (from a template, in your editor)'
        Write-Host '  7) new job for a group: hourly, daily or weekly (from a template, in your editor)'
        Write-Host '  8) enable a ready script or job from the library'
        Write-Host '  9) set the wmanager version the computers run'
        Write-Host ' 10) check the source'
        Write-Host ' 11) sign and publish'
        Write-Host ' 12) configuration wizard (provision.config.psd1)'
        Write-Host ' 13) read-only keys for the status (Healthchecks, Grafana Cloud)'
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
                '6' { $changed = New-GroupFileStep $Company 'script' }
                '7' { $changed = New-GroupFileStep $Company 'job' }
                '8' { $changed = Enable-LibraryStep $Company }
                '9' { $changed = Set-VersionStep $Company }
                '10' { $null = Invoke-Groups $Company 'check' }
                '11' { Publish-Company $Company }
                '12' { Invoke-Wizard $Company }
                '13' { Set-Monitoring $Company }
                default { if ($answer) { Write-Host '  Choose a number from the list, or b.' -ForegroundColor Yellow } }
            }
            if ($changed -and (Test-UnsignedChanges $Company) -and
                (Read-WmYesNo 'Sign and publish now? The computers see the change only after that.' $true)) {
                Publish-Company $Company
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
            } elseif ($answer -eq 'u') {
                $folder = [string](Read-Line 'Folder on the USB drive or the share, e.g. /media/you/USB/wmanager')
                if ($folder) { Copy-ToUsb $folder }
            } elseif ($answer) {
                Write-Host '  Choose a number from the list, s, n, u or q.' -ForegroundColor Yellow
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
    } elseif ($First -eq 'status') {
        Show-AllStatus
    } elseif ($First -eq 'help') {
        Show-Usage
    } else {
        $company = Get-Company $First
        if (-not $Second) {
            Invoke-CompanyMenu $company
        } elseif ($Second -eq 'publish') {
            Publish-Company $company
        } elseif ($Second -eq 'config') {
            Invoke-Wizard $company
        } elseif ($Second -eq 'status') {
            Show-ComputerStatus $company
        } elseif ($Second -eq 'monitoring') {
            Set-Monitoring $company
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
