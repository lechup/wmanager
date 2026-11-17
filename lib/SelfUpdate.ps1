# wmanager updates itself: the signed management source names the version the computers run (version.psd1, read
# by lib\Groups.ps1), and the scheduled update switches to it:
#   1. Get-WmSelfUpdateRelease downloads the release ZIP into state\self-update (Administrators and SYSTEM only),
#      checks its SHA256 against the one in the signed source and unpacks it;
#   2. Invoke-WmSelfInstall runs the new version's Update-Packages.ps1 -SelfInstall, which copies the new version
#      into the installed folder (Copy-WmProgramFiles of the new version) and does the scheduled update itself.
# The new version installs itself, so a release that adds or moves files needs no help from the old one. Releases
# without -SelfInstall (v0.1.0) can't be installed this way; tools/groups.ps1 set-version refuses them.
# Needs lib\Common.ps1 and lib\Managed.ps1.

$script:WmSelfUpdateDir = Join-Path $script:WmStateDir 'self-update'

# Copies the program files of a wmanager folder ($From: an unpacked release or a checkout) into the installed folder.
# The message catalogs first: the scheduled tasks and the notification run from this copy, and new code must not
# meet old catalogs; files a newer version no longer has are removed (all *.psd1 are loaded). VERSION last, so a copy
# cut short keeps the old version number and the next scheduled update copies again.
function Copy-WmProgramFiles {
    param([Parameter(Mandatory = $true)][string]$From, [Parameter(Mandatory = $true)][string]$To)
    $srcLang = Join-Path $From 'lang'
    $dstLang = Join-Path $To 'lang'
    New-Item -ItemType Directory -Force -Path $dstLang -ErrorAction Stop | Out-Null
    Copy-Item -Path (Join-Path $srcLang '*') -Destination $dstLang -Recurse -Force -ErrorAction Stop
    foreach ($old in @(Get-ChildItem -LiteralPath $dstLang -Recurse -File)) {
        if (-not (Test-Path -LiteralPath (Join-Path $srcLang $old.FullName.Substring($dstLang.Length + 1)))) {
            Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $To 'lib') -ErrorAction Stop | Out-Null
    Copy-Item -Path (Join-Path $From 'lib\*.ps1') -Destination (Join-Path $To 'lib') -Force -ErrorAction Stop
    foreach ($f in @('Provision.ps1', 'Update-Packages.ps1', 'Invoke-Jobs.ps1', 'Notify-User.ps1', 'Restore-Backup.ps1', 'run.cmd', 'choco-reqs.txt')) {
        $p = Join-Path $From $f
        if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination $To -Force -ErrorAction Stop }
    }
    Get-ChildItem -LiteralPath $To -Recurse -File -Include '*.ps1', '*.psd1', '*.cmd' -ErrorAction SilentlyContinue |
        Unblock-File -ErrorAction SilentlyContinue
    # A copy without VERSION (a git checkout) must not leave an older release's version in the logs
    $version = Join-Path $From 'VERSION'
    if (Test-Path -LiteralPath $version) { Copy-Item -LiteralPath $version -Destination $To -Force -ErrorAction Stop }
    else { Remove-Item -LiteralPath (Join-Path $To 'VERSION') -Force -ErrorAction SilentlyContinue }
}

# The version of the installed copy (its VERSION file), '' without one
function Get-WmInstalledVersion {
    $file = Join-Path $script:WmRoot 'VERSION'
    if (Test-Path -LiteralPath $file) { return ([IO.File]::ReadAllText($file)).Trim() }
    return ''
}

# The release this computer should switch to, ready to install: Version and Folder (the unpacked wmanager folder).
# $null when there is no management source, the source can't be read (the package stage reports that), it names no
# version for this computer or names the one running, or the release can't be prepared (logged: a download that
# fails is a warning and is tried again at the next update; a file that doesn't match is an error).
function Get-WmSelfUpdateRelease {
    param([Parameter(Mandatory = $true)][hashtable]$Config)
    if (-not (Get-WmManagementSettings $Config)) { return $null }
    try { $content = Get-WmManagedContent -Config $Config } catch { return $null }
    $want = $content.Wmanager
    if (-not $want -or $want.Version -eq $script:WmVersion) { return $null }

    if ($want.Group) {
        Write-WmLog -Key 'update.self_update_group' -Arguments @((Get-WmName), $want.Version, $want.Group, $want.Url)
    } else {
        Write-WmLog -Key 'update.self_update' -Arguments @((Get-WmName), $want.Version, $want.Url)
    }
    $dir = $script:WmSelfUpdateDir
    try {
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction Stop }
        New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop | Out-Null
    } catch {
        Write-WmLog -Key 'update.self_update_error' -Arguments @($want.Version, (Get-WmErrorText $_)) -Level error
        return $null
    }
    $zip = Join-Path $dir ('wmanager-{0}.zip' -f $want.Version)
    try {
        # Without Management.AuthHeader: that login is for the management source, not for the release server
        Get-WmRemoteFile -Location $want.Url -Destination $zip
    } catch {
        Write-WmLog -Key 'update.self_update_download_failed' -Arguments @($want.Version, (Get-WmErrorText $_), (Get-WmName)) -Level warn
        return $null
    }
    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
    if ($hash -ne $want.Sha256) {
        Write-WmLog -Key 'update.self_update_bad_hash' -Arguments @($want.Version, $hash, $want.Sha256) -Level error
        return $null
    }
    try {
        $out = Join-Path $dir 'unpacked'
        Expand-Archive -LiteralPath $zip -DestinationPath $out -Force -ErrorAction Stop
        $folder = Join-Path $out 'wmanager'
        $versionFile = Join-Path $folder 'VERSION'
        $found = ''
        if (Test-Path -LiteralPath $versionFile) { $found = ([IO.File]::ReadAllText($versionFile)).Trim() }
        if ($found -ne $want.Version -or -not (Test-Path -LiteralPath (Join-Path $folder 'Update-Packages.ps1'))) {
            throw (New-WmError 'update.self_update_not_release' @($want.Version))
        }
    } catch {
        Write-WmLog -Key 'update.self_update_error' -Arguments @($want.Version, (Get-WmErrorText $_)) -Level error
        return $null
    }
    return [pscustomobject]@{ Version = $want.Version; Folder = $folder }
}

# Runs the new version's Update-Packages.ps1 -SelfInstall (unpacked by Get-WmSelfUpdateRelease) and waits for it;
# returns its exit code. WaitForExit, not -Wait, which would also wait for every program the run started.
function Invoke-WmSelfInstall {
    param([Parameter(Mandatory = $true)][string]$Folder, [string]$Lang)
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -SelfInstall' -f (Join-Path $Folder 'Update-Packages.ps1')
    if ($Lang -match '^[A-Za-z]{2}$') { $arguments += ' -Lang ' + $Lang }
    $p = Start-Process -FilePath $ps -ArgumentList $arguments -NoNewWindow -PassThru
    $null = $p.Handle   # keeps the exit code readable after the process ends (Windows PowerShell 5.1)
    $p.WaitForExit()
    return $p.ExitCode
}
