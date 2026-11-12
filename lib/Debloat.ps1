# Debloat: app removal, OneDrive, policies that keep them from coming back, toning down Edge.

function Remove-WmAppxPackages {
    param([string[]]$Patterns)

    $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)
    foreach ($pattern in $Patterns) {
        if (-not $pattern) { continue }

        $installed = @(Get-AppxPackage -AllUsers -Name $pattern -ErrorAction SilentlyContinue)
        foreach ($pkg in $installed) {
            try {
                Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
                Write-WmLog "Usunięto aplikację $($pkg.Name)"
            } catch {
                Write-WmLog "Nie udało się usunąć $($pkg.Name): $($_.Exception.Message)" -Level warn
            }
        }

        foreach ($prov in ($provisioned | Where-Object { $_.DisplayName -like $pattern })) {
            try {
                Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
                Write-WmLog "Usunięto z obrazu systemu $($prov.DisplayName)"
            } catch {
                Write-WmLog "Nie udało się usunąć z obrazu $($prov.DisplayName): $($_.Exception.Message)" -Level warn
            }
        }
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
    if ($redirected.Count -gt 0) {
        foreach ($r in $redirected) { Write-WmLog "Folder przekierowany do OneDrive: $r" -Level warn }
        Write-WmLog 'Pomijam usuwanie OneDrive na tym komputerze, żeby nie odciąć plików użytkowników.' -Level warn
        return
    }

    Get-Process -Name 'OneDrive' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    # System-wide installation
    foreach ($setup in @("$env:SystemRoot\System32\OneDriveSetup.exe", "$env:SystemRoot\SysWOW64\OneDriveSetup.exe")) {
        if (Test-Path -LiteralPath $setup) {
            $p = Start-Process -FilePath $setup -ArgumentList '/uninstall' -Wait -PassThru -WindowStyle Hidden
            Write-WmLog "OneDriveSetup /uninstall ($setup) zakończony kodem $($p.ExitCode)"
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
                $p = Start-Process -FilePath $exe -ArgumentList $argStr.Trim() -Wait -PassThru -WindowStyle Hidden
                Write-WmLog "Odinstalowanie $($u.DisplayName) zakończone kodem $($p.ExitCode)"
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
    Write-WmLog 'OneDrive usunięty i zablokowany.'
}

function Set-WmDebloatPolicies {
    # Teams: built-in chat and automatic installation
    Set-WmRegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Chat' 'ChatIcon' 3 | Out-Null
    # This key is sometimes protected by TrustedInstaller; access denied is not a critical error
    try {
        $k = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Communications'
        if (-not (Test-Path -LiteralPath $k)) { New-Item -Path $k -Force -ErrorAction Stop | Out-Null }
        New-ItemProperty -LiteralPath $k -Name 'ConfigureChatAutoInstall' -Value 0 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
    } catch {
        Write-WmLog 'Brak dostępu do ConfigureChatAutoInstall (chroniony klucz), pomijam.'
    }

    # Copilot and Recall
    Set-WmRegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1 | Out-Null
    Set-WmRegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1 | Out-Null
    Set-WmRegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'AllowRecallEnablement' 0 | Out-Null

    # Widgets / News and Interests
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
        try {
            if (-not (Test-Path -LiteralPath $adv)) { New-Item -Path $adv -Force -ErrorAction Stop | Out-Null }
            New-ItemProperty -LiteralPath $adv -Name 'TaskbarDa' -Value 0 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        } catch { }
    }
    Write-WmLog 'Zasady blokujące Teams, Copilot, Recall, Widgets, Cortana, Phone Link i Game Bar ustawione.'
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
    Write-WmLog 'Edge wyciszony zasadami.'
}

function Invoke-WmDebloat {
    param([Parameter(Mandatory = $true)][hashtable]$Config)
    $d = Get-WmSetting $Config 'Debloat' @{}
    Write-WmLog '--- Debloat ---'
    if ($d.RemoveApps) { Remove-WmAppxPackages -Patterns (Get-WmSetting $Config 'RemoveAppx' @()) }
    if ($d.OneDrive)   { Remove-WmOneDrive }
    if ($d.Policies)   { Set-WmDebloatPolicies }
    if ($d.Edge)       { Set-WmEdgePolicies }
}
