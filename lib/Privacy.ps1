# Privacy: telemetry, ads, suggestions, Bing in search. Registry only (Home has no gpedit).

function Get-WmEditionTelemetryLevel {
    # Level 0 (Security) works only in Enterprise/Education; in Home/Pro the lowest is 1 (Required).
    $caption = (Get-CimInstance -ClassName Win32_OperatingSystem).Caption
    if ($caption -match 'Enterprise|Education') { return 0 }
    return 1
}

function Invoke-WmPrivacy {
    Write-WmLog -Key 'privacy.section'

    $level = Get-WmEditionTelemetryLevel
    $dc = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'
    Set-WmRegValue $dc 'AllowTelemetry' $level | Out-Null
    Set-WmRegValue $dc 'MaxTelemetryAllowed' $level | Out-Null
    Set-WmRegValue $dc 'DoNotShowFeedbackNotifications' 1 | Out-Null
    Set-WmRegValue $dc 'AllowDeviceNameInTelemetry' 0 | Out-Null
    Set-WmRegValue $dc 'LimitDiagnosticLogCollection' 1 | Out-Null
    Set-WmRegValue $dc 'LimitDumpCollection' 1 | Out-Null
    Write-WmLog -Key 'privacy.telemetry_level' -Arguments @($level)

    foreach ($svc in @('DiagTrack', 'dmwappushservice')) {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($s) {
            try {
                # The startup type lives in the service key's Start value; recorded for Restore-Backup.ps1
                Add-WmJournalEntry -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$svc" -Name 'Start'
                if ($s.Status -ne 'Stopped') { Stop-Service -Name $svc -Force -ErrorAction Stop }
                Set-Service -Name $svc -StartupType Disabled -ErrorAction Stop
                Write-WmLog -Key 'privacy.service_disabled' -Arguments @($svc)
            } catch {
                Write-WmLog -Key 'privacy.service_failed' -Arguments @($svc, (Get-WmErrorText $_)) -Level warn
            }
        }
    }

    # Ads and "consumer" content (some of this works only in Enterprise/Education, but it does no harm)
    Set-WmRegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' 'DisabledByGroupPolicy' 1 | Out-Null
    $cc = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'
    Set-WmRegValue $cc 'DisableWindowsConsumerFeatures' 1 | Out-Null
    Set-WmRegValue $cc 'DisableSoftLanding' 1 | Out-Null
    Set-WmRegValue $cc 'DisableCloudOptimizedContent' 1 | Out-Null
    Set-WmRegValue $cc 'DisableConsumerAccountStateContent' 1 | Out-Null

    # Activity history
    $sys = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
    Set-WmRegValue $sys 'EnableActivityFeed' 0 | Out-Null
    Set-WmRegValue $sys 'PublishUserActivities' 0 | Out-Null
    Set-WmRegValue $sys 'UploadUserActivities' 0 | Out-Null

    # Local-only search
    $ws = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'
    Set-WmRegValue $ws 'AllowCloudSearch' 0 | Out-Null
    Set-WmRegValue $ws 'ConnectedSearchUseWeb' 0 | Out-Null
    Set-WmRegValue $ws 'DisableWebSearch' 1 | Out-Null
    Set-WmRegValue $ws 'EnableDynamicContentInWSB' 0 | Out-Null

    # Typing personalization
    Set-WmRegValue 'HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization' 'AllowInputPersonalization' 0 | Out-Null

    Invoke-WmForEachUserHive {
        param($root, $name)

        $cdm = "$root\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
        foreach ($v in @(
            'ContentDeliveryAllowed', 'FeatureManagementEnabled', 'OemPreInstalledAppsEnabled',
            'PreInstalledAppsEnabled', 'PreInstalledAppsEverEnabled', 'SilentInstalledAppsEnabled',
            'SoftLandingEnabled', 'SubscribedContentEnabled', 'SystemPaneSuggestionsEnabled',
            'RotatingLockScreenEnabled', 'RotatingLockScreenOverlayEnabled',
            'SubscribedContent-310093Enabled', 'SubscribedContent-338387Enabled', 'SubscribedContent-338388Enabled',
            'SubscribedContent-338389Enabled', 'SubscribedContent-338393Enabled', 'SubscribedContent-353694Enabled',
            'SubscribedContent-353696Enabled', 'SubscribedContent-353698Enabled')) {
            Set-WmRegValue $cdm $v 0 | Out-Null
        }

        Set-WmRegValue "$root\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" 'Enabled' 0 | Out-Null
        Set-WmRegValue "$root\Software\Microsoft\Windows\CurrentVersion\Privacy" 'TailoredExperiencesWithDiagnosticDataEnabled' 0 | Out-Null
        Set-WmRegValue "$root\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement" 'ScoobeSystemSettingEnabled' 0 | Out-Null
        Set-WmRegValue "$root\Software\Microsoft\Siuf\Rules" 'NumberOfSIUFInPeriod' 0 | Out-Null

        $adv = "$root\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
        Set-WmRegValue $adv 'Start_IrisRecommendations' 0 | Out-Null       # recommendations in the Start menu
        Set-WmRegValue $adv 'Start_AccountNotifications' 0 | Out-Null
        Set-WmRegValue $adv 'ShowSyncProviderNotifications' 0 | Out-Null   # ads in Explorer

        $search = "$root\Software\Microsoft\Windows\CurrentVersion\Search"
        Set-WmRegValue $search 'BingSearchEnabled' 0 | Out-Null
        Set-WmRegValue $search 'CortanaConsent' 0 | Out-Null
        Set-WmRegValue "$root\Software\Microsoft\Windows\CurrentVersion\SearchSettings" 'IsDynamicSearchBoxEnabled' 0 | Out-Null
        Set-WmRegValue "$root\Software\Policies\Microsoft\Windows\Explorer" 'DisableSearchBoxSuggestions' 1 | Out-Null

        $ucc = "$root\Software\Policies\Microsoft\Windows\CloudContent"
        Set-WmRegValue $ucc 'DisableTailoredExperiencesWithDiagnosticData' 1 | Out-Null
        Set-WmRegValue $ucc 'DisableWindowsSpotlightFeatures' 1 | Out-Null
        Set-WmRegValue $ucc 'DisableThirdPartySuggestions' 1 | Out-Null
    }
    Write-WmLog -Key 'privacy.done'
}
