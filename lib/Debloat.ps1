# Debloat: app removal, OneDrive, policies that keep them from coming back, toning down Edge.

function Remove-WmAppxPackages {
    param([string[]]$Patterns)
    $Patterns = @($Patterns | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    if ($Patterns.Count -eq 0) { return }

    # The system image first, then the installed copies: a profile created in between can't get an app back from
    # the image, and the image entries are still there to remove (current Windows 11 builds, seen on 26300, also
    # take an app out of the image when it is removed for all users; removing it there afterwards fails with
    # "path not found"). Every image package once, even when several patterns match it.
    try {
        $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop)
    } catch {
        $provisioned = @()
        Write-WmLog -Key 'debloat.image_read_failed' -Arguments @(Get-WmErrorText $_) -Level warn
    }
    foreach ($prov in $provisioned) {
        $name = $prov.DisplayName
        if (-not ($Patterns | Where-Object { $name -like $_ })) { continue }
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
            Write-WmLog -Key 'debloat.image_removed' -Arguments @($name)
        } catch {
            # Gone in the meantime (e.g. together with a package removed just before): done, not a failure
            if (-not (Test-WmProvisioned $prov.PackageName)) {
                Write-WmLog -Key 'debloat.image_removed_gone' -Arguments @($name)
            } else {
                Write-WmLog -Key 'debloat.image_remove_failed' -Arguments @($name, (Get-WmErrorText $_)) -Level warn
            }
        }
    }

    foreach ($pattern in $Patterns) {
        # asked again for every pattern, so an app already removed by an earlier pattern isn't listed
        # (no match is not an error; an error means the app list can't be read)
        try {
            $installed = @(Get-AppxPackage -AllUsers -Name $pattern -ErrorAction Stop)
        } catch {
            Write-WmLog -Key 'debloat.installed_read_failed' -Arguments @($pattern, (Get-WmErrorText $_)) -Level warn
            continue
        }
        foreach ($pkg in $installed) {
            try {
                Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
                Write-WmLog -Key 'debloat.app_removed' -Arguments @($pkg.Name)
            } catch {
                Write-WmLog -Key 'debloat.app_remove_failed' -Arguments @($pkg.Name, (Get-WmErrorText $_)) -Level warn
            }
        }
    }
}

# Windows Update installs some apps again after setup: updaters under UScheduler_Oobe (run by usoclient.exe)
# brought DevHome back about a minute after it was removed (build 26300). The updater of an app on the
# RemoveAppx list is removed; its values go to the undo journal first, so Restore-Backup.ps1 brings it back.
$script:WmUSchedulerOobeKey = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe'
$script:WmAppReinstallUpdaters = [ordered]@{
    'DevHomeUpdate' = 'Microsoft.Windows.DevHome'
    'OutlookUpdate' = 'Microsoft.OutlookForWindows'
}

function Disable-WmAppReinstall {
    param([string[]]$Patterns)
    $Patterns = @($Patterns | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    foreach ($updater in $script:WmAppReinstallUpdaters.Keys) {
        $app = $script:WmAppReinstallUpdaters[$updater]
        if (-not ($Patterns | Where-Object { $app -like $_ })) { continue }
        $path = "$script:WmUSchedulerOobeKey\$updater"
        # One updater failing must not stop the app removal that follows
        try {
            $k = Open-WmRegKey -Path $path
            if (-not $k) { continue }
            try { $names = @($k.GetValueNames()); $subKeys = $k.SubKeyCount } finally { $k.Close() }
            if ($names.Count -eq 0 -and $subKeys -eq 0) { continue }   # nothing in it for Windows Update to run
            # The journal holds named values only: without a full record the key stays
            if ($subKeys -gt 0 -or $names -contains '') {
                Write-WmLog -Key 'debloat.updater_skipped_subkeys' -Arguments @($path) -Level warn
                continue
            }
            foreach ($name in $names) { Add-WmJournalEntry -Path $path -Name $name }
            if ($script:WmJournalOn) {
                # Deleting is not like overwriting a value: without the journal entries the key would be lost for good
                $native = ConvertTo-WmRegNativePath $path
                if (@($names | Where-Object { -not $script:WmJournalSeen.ContainsKey((Get-WmJournalId 'machine' '' '' $native $_)) }).Count -gt 0) {
                    Write-WmLog -Key 'debloat.updater_skipped_journal' -Arguments @($path) -Level warn
                    continue
                }
            }
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
            Write-WmLog -Key 'debloat.updater_removed' -Arguments @($app, $updater)
        } catch {
            Write-WmLog -Key 'debloat.updater_remove_failed' -Arguments @($path, (Get-WmErrorText $_)) -Level warn
        }
    }
}

# Whether a package is still in the system image; when that can't be checked, it counts as still there.
function Test-WmProvisioned {
    param([Parameter(Mandatory = $true)][string]$PackageName)
    try {
        return [bool](@(Get-AppxProvisionedPackage -Online -ErrorAction Stop) | Where-Object { $_.PackageName -eq $PackageName })
    } catch {
        return $true
    }
}

# Returns the profiles whose Desktop/Documents/Pictures point to OneDrive.
function Get-WmOneDriveRedirectedProfiles {
    $script:WmOdRedirected = @()
    Invoke-WmForEachUserHive {
        param($root, $name)
        $key = "$root\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
        $props = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if ($props) {
            foreach ($folder in @('Desktop', 'Personal', 'My Pictures')) {
                $val = $props.$folder
                if ($val -and $val -match 'OneDrive') {
                    $script:WmOdRedirected += "$name ($folder -> $val)"
                }
            }
        }
    }
    return $script:WmOdRedirected
}

function Remove-WmOneDrive {
    $redirected = @(Get-WmOneDriveRedirectedProfiles)
    $unchecked = @($script:WmHiveSkipped)   # a profile we could not check might be redirected too
    if ($redirected.Count -gt 0 -or $unchecked.Count -gt 0) {
        foreach ($r in $redirected) { Write-WmLog -Key 'debloat.onedrive_redirected' -Arguments @($r) -Level warn }
        foreach ($u in $unchecked) { Write-WmLog -Key 'debloat.profile_unchecked' -Arguments @($u) -Level warn }
        Write-WmLog -Key 'debloat.onedrive_skipped' -Level warn
        return
    }

    Get-Process -Name 'OneDrive' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    # System-wide installation
    foreach ($setup in @("$env:SystemRoot\System32\OneDriveSetup.exe", "$env:SystemRoot\SysWOW64\OneDriveSetup.exe")) {
        if (Test-Path -LiteralPath $setup) {
            try {
                $p = Start-Process -FilePath $setup -ArgumentList '/uninstall' -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
                Write-WmLog -Key 'debloat.onedrive_setup_exit' -Arguments @($setup, $p.ExitCode)
            } catch {
                Write-WmLog -Key 'debloat.onedrive_setup_failed' -Arguments @($setup, (Get-WmErrorText $_)) -Level warn
            }
        }
    }
    # Per-machine installation (Program Files)
    foreach ($base in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue | ForEach-Object {
            $u = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
            if ($u -and $u.DisplayName -like 'Microsoft OneDrive*' -and $u.UninstallString) {
                $cmd = $u.UninstallString
                if ($cmd -match '^"([^"]+)"\s*(.*)$') { $exe = $Matches[1]; $argStr = $Matches[2] }
                else { $exe = ($cmd -split ' ', 2)[0]; $argStr = ($cmd -split ' ', 2)[1] }
                if ($argStr -notmatch '/silent') { $argStr = "$argStr /silent" }
                try {
                    $p = Start-Process -FilePath $exe -ArgumentList $argStr.Trim() -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
                    Write-WmLog -Key 'debloat.uninstall_exit' -Arguments @($u.DisplayName, $p.ExitCode)
                } catch {
                    Write-WmLog -Key 'debloat.uninstall_failed' -Arguments @($u.DisplayName, (Get-WmErrorText $_)) -Level warn
                }
            }
        }
    }

    # Per-user installations: remove the autostart entry and installer from profiles (the policy below blocks sync)
    Invoke-WmForEachUserHive {
        param($root, $name)
        Remove-WmRegValue -Path "$root\Software\Microsoft\Windows\CurrentVersion\Run" -Name 'OneDrive'
        Remove-WmRegValue -Path "$root\Software\Microsoft\Windows\CurrentVersion\Run" -Name 'OneDriveSetup'
    }

    # Block sync and hide it in Explorer
    Set-WmRegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 1 | Out-Null
    Set-WmRegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSync' 1 | Out-Null
    foreach ($clsid in @('HKLM:\SOFTWARE\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}',
                         'HKLM:\SOFTWARE\Classes\WOW6432Node\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}')) {
        if (Test-Path -LiteralPath $clsid) { Set-WmRegValue $clsid 'System.IsPinnedToNameSpaceTree' 0 | Out-Null }
    }
    Write-WmLog -Key 'debloat.onedrive_removed'
}

function Set-WmDebloatPolicies {
    # Teams: built-in chat and automatic installation
    Set-WmRegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Chat' 'ChatIcon' 3 | Out-Null
    # This key is sometimes protected by TrustedInstaller; access denied is not a critical error
    Set-WmRegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Communications' 'ConfigureChatAutoInstall' 0 -OnError info | Out-Null

    # Copilot and Recall
    Set-WmRegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1 | Out-Null
    Set-WmRegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1 | Out-Null
    Set-WmRegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'AllowRecallEnablement' 0 | Out-Null

    # Widgets / News and Interests. Once the UCPD driver is active (some time after setup) it blocks powershell.exe
    # from writing this policy; set at provisioning, it is left alone afterwards (Set-WmRegValue skips a value
    # that is already set), and a refused write still warns: then the policy is really not in effect
    Set-WmRegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0 | Out-Null

    # Cortana
    Set-WmRegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortana' 0 | Out-Null

    # Phone Link
    Set-WmRegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableMmx' 0 | Out-Null

    # Game Bar / game recording
    Set-WmRegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0 | Out-Null

    # Per-user settings (all profiles + the default profile)
    Invoke-WmForEachUserHive {
        param($root, $name)
        Set-WmRegValue "$root\Software\Policies\Microsoft\Windows\WindowsCopilot" 'TurnOffWindowsCopilot' 1 | Out-Null
        Set-WmRegValue "$root\Software\Microsoft\Windows\CurrentVersion\GameDVR" 'AppCaptureEnabled' 0 | Out-Null
        Set-WmRegValue "$root\System\GameConfigStore" 'GameDVR_Enabled' 0 | Out-Null
        $adv = "$root\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
        Set-WmRegValue $adv 'TaskbarMn' 0 | Out-Null            # Teams chat icon
        Set-WmRegValue $adv 'ShowCopilotButton' 0 | Out-Null
        # TaskbarDa (Widgets) is sometimes protected in newer builds; the AllowNewsAndInterests policy turns it off anyway
        Set-WmRegValue $adv 'TaskbarDa' 0 -OnError info | Out-Null
    }
    Write-WmLog -Key 'debloat.policies_set'
}

function Set-WmEdgePolicies {
    $edge = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
    Set-WmRegValue $edge 'HubsSidebarEnabled' 0 | Out-Null             # sidebar (including Copilot)
    Set-WmRegValue $edge 'EdgeShoppingAssistantEnabled' 0 | Out-Null   # shopping
    Set-WmRegValue $edge 'StartupBoostEnabled' 0 | Out-Null
    Set-WmRegValue $edge 'BackgroundModeEnabled' 0 | Out-Null
    Set-WmRegValue $edge 'HideFirstRunExperience' 1 | Out-Null
    Set-WmRegValue $edge 'ShowRecommendationsEnabled' 0 | Out-Null
    Set-WmRegValue $edge 'PersonalizationReportingEnabled' 0 | Out-Null
    Set-WmRegValue $edge 'DefaultBrowserSettingEnabled' 0 | Out-Null   # don't ask to be the default
    Write-WmLog -Key 'debloat.edge_quieted'
}

# Whether the scheduled update reruns debloat and privacy: RerunDebloat, or the older name RerunDebloatWeekly
# (from when the update ran once a week); on by default.
function Test-WmRerunDebloat {
    param([Parameter(Mandatory = $true)][hashtable]$Config)
    return [bool](Get-WmSetting $Config 'RerunDebloat' (Get-WmSetting $Config 'RerunDebloatWeekly' $true))
}

function Invoke-WmDebloat {
    param([Parameter(Mandatory = $true)][hashtable]$Config)
    $d = Get-WmSetting $Config 'Debloat' @{}
    Write-WmLog -Key 'debloat.section'
    if ($d.RemoveApps) {
        $patterns = Get-WmSetting $Config 'RemoveAppx' @()
        Disable-WmAppReinstall -Patterns $patterns   # first, so Windows Update can't put an app back in between
        Remove-WmAppxPackages -Patterns $patterns
    }
    if ($d.OneDrive)   { Remove-WmOneDrive }
    if ($d.Policies)   { Set-WmDebloatPolicies }
    if ($d.Edge)       { Set-WmEdgePolicies }
}
