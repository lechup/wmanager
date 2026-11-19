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
#   pwsh tools/wm.ps1 new <company>            key, source (from examples/management), first signature, configuration;
#                                              run it again and it carries on where it stopped
#   pwsh tools/wm.ps1 usb <folder>             wmanager (the latest release, when the folder has none) and every
#                                              company's configuration, for run.cmd, which then asks which company
#   pwsh tools/wm.ps1 <company>                the menu of one company
#   pwsh tools/wm.ps1 <company> publish        check and sign its source (tools/publish.sh)
#   pwsh tools/wm.ps1 <company> config         the configuration wizard (init.ps1) for its provision.config.psd1
#   pwsh tools/wm.ps1 <company> <command> ...  a tools/groups.ps1 command on its source, e.g.
#                                              add-computer OFFICE-07 accounting, enable power all, set-version v0.2.0
#
# PowerShell 7 (pwsh) on Linux or macOS; new and publish need bash, openssl and osslsigncode, like the tools they run.
# Messages are in English, like the other tools.
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
Initialize-WmLanguage -Lang 'en' -Root $repo

$script:Self = $PSCommandPath
$script:Tools = $PSScriptRoot
$script:Root = if ($env:WMANAGER_COMPANIES) { $env:WMANAGER_COMPANIES } else { Join-Path $HOME 'wmanager-companies' }
$script:Commands = @('list', 'new', 'usb', 'help')
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

function Read-YesNo {
    param([string]$Prompt, [bool]$Default)
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $answer = Read-Line "$Prompt $hint"
        if (-not $answer) { return $Default }
        if (@('y', 'yes') -contains $answer) { return $true }
        if (@('n', 'no') -contains $answer) { return $false }
        Write-Host '  y or n' -ForegroundColor Yellow
    }
}

# Groups typed as their numbers on the list of the source's groups or as names (a new name makes a new group)
function Read-Groups {
    param($Company, [string]$Prompt, [switch]$Common)
    $names = @(Get-GroupNames $Company)
    if ($Common) { $names = @('common') + $names }
    if ($names.Count -gt 0) {
        Write-Host ('  ' + ((@(for ($i = 0; $i -lt $names.Count; $i++) { '{0}) {1}' -f ($i + 1), $names[$i] })) -join '   '))
    }
    $answer = [string](Read-Line $Prompt)
    return @(foreach ($t in @($answer -split '[\s,]+' | Where-Object { $_ })) {
        $n = 0
        if ([int]::TryParse($t, [ref]$n) -and $n -ge 1 -and $n -le $names.Count) { $names[$n - 1] } else { $t }
    })
}

# ---------------------------------------------------------------------------
# Companies
# ---------------------------------------------------------------------------

# A company's name is the name of its folders, here and on the USB drive (configs\<company>)
function Test-CompanyName {
    param([string]$Name)
    return ($Name -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$' -and $Name -notmatch '\.$' -and
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

function Test-HasKey {
    param($Company)
    return [IO.File]::Exists((Join-Path $Company.Keys 'key.pem'))
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

# Has anything in the source changed since the last signature? The files against the hashes in manifest.psd1;
# hidden files (.git, .gitattributes) don't count, as for tools/publish.sh.
function Test-UnsignedChanges {
    param($Company)
    try { $files = (Import-PowerShellDataFile -LiteralPath (Join-Path $Company.Source 'manifest.psd1')).Files }
    catch { return $true }
    if (-not ($files -is [hashtable])) { return $true }
    $seen = 0
    foreach ($f in Get-ChildItem -LiteralPath $Company.Source -Recurse -File) {
        $rel = [IO.Path]::GetRelativePath($Company.Source, $f.FullName).Replace('\', '/')
        if ($rel -eq 'manifest.psd1') { continue }
        $want = $files[$rel]
        if (-not $want -or $want -ne (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash) { return $true }
        $seen++
    }
    return ($seen -ne $files.Count)
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
    $cer = Join-Path $Company.Keys 'wmanager-signing.cer'
    $dest = Join-Path $Company.ConfigDir 'wmanager-signing.cer'
    if ([IO.File]::Exists($cer) -and -not [IO.File]::Exists($dest)) { Copy-Item -LiteralPath $cer -Destination $dest }
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
        throw "invalid company name '$Name': up to 40 letters, digits, '.', '-', '_' (not list, new, usb or help)"
    }
    $c = Get-CompanyPaths $Name
    New-Item -ItemType Directory -Force -Path $c.Dir | Out-Null

    Write-Step "1/4 Signing key: $($c.Keys)"
    if (Test-HasKey $c) {
        Write-Host '  Already there.'
    } else {
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
        catch { throw "not signed (the reason is above); to carry on: pwsh tools/wm.ps1 new $Name" }
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
        if (Read-YesNo '  Run the wizard now?' $true) { Invoke-Wizard $c }
        else { Write-Host "  Later: pwsh tools/wm.ps1 $Name config" }
    }
    Write-Host ''
    Write-Host ('Company {0}: {1}' -f $Name, (Get-CompanyState $c))
    Write-Host 'Next: computers to groups (the menu of the company), then wmanager onto a USB drive: pwsh tools/wm.ps1 usb <folder>'
}

# ---------------------------------------------------------------------------
# USB drive or share
# ---------------------------------------------------------------------------

# The certificate file a configuration names; $null without a management source
function Get-ConfigCertificate {
    param([string]$Path)
    $m = (Import-PowerShellDataFile -LiteralPath $Path).Management
    if (-not ($m -is [hashtable]) -or -not $m.Source) { return $null }
    if ($m.Certificate) { return [string]$m.Certificate }
    return 'wmanager-signing.cer'
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
    if ($Folder -match '^~') { $Folder = $HOME + $Folder.Substring(1) }
    $Folder = [IO.Path]::GetFullPath($Folder)
    $companies = @(Get-Companies)
    $ready = @($companies | Where-Object { [IO.File]::Exists($_.Config) })
    if ($ready.Count -eq 0) { throw 'no company has a configuration yet: pwsh tools/wm.ps1 <company> config' }
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
    foreach ($c in @($companies | Where-Object { -not [IO.File]::Exists($_.Config) })) {
        Write-Warn "$($c.Name) has no configuration yet, so it isn't on the drive: pwsh tools/wm.ps1 $($c.Name) config"
    }
    foreach ($d in @(Get-ChildItem -LiteralPath $configs -Directory)) {
        if (@($ready | Where-Object { $_.Name -eq $d.Name }).Count -eq 0) {
            Write-Warn "configs/$($d.Name) on the drive is not one of the companies here; left as it is"
        }
    }
    Write-Host ''
    if ($chooses) { Write-Host "Done. On the computer, run.cmd from $Folder asks which company the computer is for." }
    else { Write-Host "Done. On the computer: run.cmd -ConfigPath <this folder>\configs\<company>\provision.config.psd1" }
    Write-Host 'The configurations hold the tokens (Loki, Healthchecks, the source): keep the drive under control.'
}

# ---------------------------------------------------------------------------
# Menus
# ---------------------------------------------------------------------------

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
        Write-Host '  1) show the groups, or what one computer gets'
        Write-Host '  2) add a computer to groups'
        Write-Host '  3) remove a computer from groups'
        Write-Host '  4) add a package (to a group, or to every computer)'
        Write-Host '  5) enable a ready script or job from the library'
        Write-Host '  6) set the wmanager version the computers run'
        Write-Host '  7) check the source'
        Write-Host '  8) sign and publish'
        Write-Host '  9) configuration wizard (provision.config.psd1)'
        Write-Host '  b) back'
        $answer = Read-Line 'Choose'
        if ($null -eq $answer -or $answer -eq 'b' -or $answer -eq 'q') { return }
        try {
            $changed = $false
            switch ($answer) {
                '0' { New-Company $Company.Name }
                '1' {
                    $pc = [string](Read-Line 'Computer (Enter = all groups)')
                    $null = Invoke-Groups $Company 'show' @($pc | Where-Object { $_ })
                }
                '2' { $changed = Add-ComputerStep $Company }
                '3' { $changed = Remove-ComputerStep $Company }
                '4' { $changed = Add-PackageStep $Company }
                '5' { $changed = Enable-LibraryStep $Company }
                '6' { $changed = Set-VersionStep $Company }
                '7' { $null = Invoke-Groups $Company 'check' }
                '8' { Publish-Company $Company }
                '9' { Invoke-Wizard $Company }
                default { if ($answer) { Write-Host '  Choose a number from the list, or b.' -ForegroundColor Yellow } }
            }
            if ($changed -and (Test-UnsignedChanges $Company) -and
                (Read-YesNo 'Sign and publish now? The computers see the change only after that.' $true)) {
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
            } elseif ($answer -eq 'n') {
                $name = [string](Read-Line 'Name of the new company (letters, digits, . - _), e.g. acme')
                if ($name) { New-Company $name }
            } elseif ($answer -eq 'u') {
                $folder = [string](Read-Line 'Folder on the USB drive or the share, e.g. /media/you/USB/wmanager')
                if ($folder) { Copy-ToUsb $folder }
            } elseif ($answer) {
                Write-Host '  Choose a number from the list, n, u or q.' -ForegroundColor Yellow
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
