# wmanager configuration. Copy to provision.config.psd1 and fill it in.
# The real file (with tokens) does NOT go into the repo; it sits next to the script on the USB drive or share.
@{
    # --- Package list -------------------------------------------------------
    # Sources of choco-reqs.txt, checked in order; the first available one wins.
    # A relative path is resolved from the script's folder.
    # Not used when Management.Source is set (the list then comes from the management source).
    ReqsSources = @(
        # 'https://raw.githubusercontent.com/lechup/wmanager/main/choco-reqs.txt'
        # '\\server\share\wmanager\choco-reqs.txt'
        'choco-reqs.txt'
    )

    # --- Computer groups (optional) -----------------------------------------------
    # Signed management source: the common package list, the map of computers to groups, and each
    # group's packages, scripts and jobs. See docs/groups.md. Empty Source = off.
    Management = @{
        # https:// address of the folder (e.g. a private repository) or a full folder path (\\server\share\...)
        Source      = ''   # e.g. 'https://raw.githubusercontent.com/<owner>/<management-repo>/main'
        # Identifier of the source (source-id.txt, printed by tools/publish.sh); a manifest of another source is rejected
        SourceId    = ''
        # Authorization header for a private repository, e.g. 'token github_pat_...' (read-only token)
        AuthHeader  = ''
        # Public part of the signing certificate (tools/new-signing-cert.sh), next to this file
        Certificate = 'wmanager-signing.cer'
        # Time limit for one group script; the scheduled update stops after 2 hours in total
        ScriptTimeoutMinutes = 15
        # Time limit for one job; the hourly job run stops after 1 hour in total
        JobTimeoutMinutes = 10
    }

    # --- Chocolatey -----------------------------------------------------------
    ChocolateyInstallUrl = 'https://community.chocolatey.org/install.ps1'

    # Priority: 1 = checked first, 2 = second..., 0 = no priority (checked last).
    ChocolateySources = @(
        @{ Name = 'chocolatey'; Url = 'https://community.chocolatey.org/api/v2/'; Priority = 0; Enabled = $true }
        # Your own repository, for later:
        # @{ Name = 'company'; Url = 'https://nexus.example.com/repository/choco/'; Priority = 1; Enabled = $true; User = ''; Password = '' }
    )

    # --- Scheduled update ----------------------------------------------------
    # Every day by default; e.g. @('Monday') = once a week. A day the computer was off is caught up after boot.
    UpdateDays = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')
    UpdateTime = '12:00'           # HH:mm, local time

    # Skip a package whose program is running right now; retry at the next sign-in.
    SkipRunningPackages = $true

    # Processes that show a package's program is running.
    # Packages not in this map: a process named like the package is checked.
    # An empty list (@()) means: never treat the package as running (e.g. a program that runs as a service).
    RunningProcessMap = @{
        'googlechrome'      = @('chrome')
        'libreoffice-fresh' = @('soffice', 'soffice.bin')
        'libreoffice-still' = @('soffice', 'soffice.bin')
        'sumatrapdf'        = @('SumatraPDF')
        '7zip'              = @('7zFM', '7zG')
        'vlc'               = @('vlc')
        'notepadplusplus'   = @('notepad++')
        'rustdesk'          = @()   # runs as a service all the time; checking the process would defer it forever
        'firefox'           = @('firefox')
    }

    # Also run debloat and the privacy settings in every scheduled update
    # (major Windows updates can bring apps back). The older name RerunDebloatWeekly still works.
    RerunDebloat = $true

    # --- Debloat ---------------------------------------------------------------
    Debloat = @{
        RemoveApps = $true    # remove the packages listed in RemoveAppx
        OneDrive   = $true    # uninstall and block OneDrive
        Policies   = $true    # policies: Teams, Copilot, Recall, Widgets, Cortana, Phone Link, Game Bar
        Edge       = $true    # tone down Edge (sidebar, shopping, Startup Boost)
    }
    Privacy = $true           # telemetry, ads, suggestions, Bing in search

    # Appx packages to remove (-like patterns). Add or remove as needed.
    RemoveAppx = @(
        # Teams
        'MSTeams'
        'MicrosoftTeams'
        # Copilot and Microsoft 365
        'Microsoft.Copilot'
        'Microsoft.Windows.Ai.Copilot.Provider'
        'Microsoft.MicrosoftOfficeHub'
        # Widgets, News, Weather, Bing
        'MicrosoftWindows.Client.WebExperience'
        'Microsoft.BingNews'
        'Microsoft.BingWeather'
        'Microsoft.BingSearch'
        # Xbox and games
        'Microsoft.GamingApp'
        'Microsoft.XboxApp'
        'Microsoft.Xbox.TCUI'
        'Microsoft.XboxGamingOverlay'
        'Microsoft.XboxGameOverlay'
        'Microsoft.XboxIdentityProvider'
        'Microsoft.XboxSpeechToTextOverlay'
        'Microsoft.MicrosoftSolitaireCollection'
        # Other
        'Clipchamp.Clipchamp'
        'Microsoft.YourPhone'
        'Microsoft.549981C3F5F10'                     # Cortana
        'Microsoft.OutlookForWindows'
        'microsoft.windowscommunicationsapps'         # Mail and Calendar
        'Microsoft.Todos'
        'MicrosoftCorporationII.MicrosoftFamily'
        'Microsoft.WindowsFeedbackHub'
        'Microsoft.GetHelp'
        'Microsoft.Getstarted'                        # Tips
        'Microsoft.PowerAutomateDesktop'
        'Microsoft.WindowsMaps'
        'Microsoft.Windows.DevHome'
        'MicrosoftCorporationII.QuickAssist'          # Quick Assist
    )

    # --- Default browser -------------------------------------------------------
    DefaultBrowser = @{
        Package = 'googlechrome'
        Name    = 'Google Chrome'
        ProgId  = 'ChromeHTML'
    }

    # --- Computer name -----------------------------------------------------------
    # Ask for the name when -ComputerName is not given (Enter = keep current).
    PromptComputerName = $true

    # --- Logs and monitoring --------------------------------------------------
    LogRetentionDays = 90

    # Grafana Cloud Loki (HTTP push). Empty = don't send.
    LokiUrl   = ''   # e.g. https://logs-prod-012.grafana.net
    LokiUser  = ''   # numeric User from Grafana Cloud
    LokiToken = ''   # token with the logs:write scope only

    # Healthchecks.io. Empty key = don't ping.
    HealthchecksBaseUrl    = 'https://hc-ping.com'
    HealthchecksPingKey    = ''
    HealthchecksSlugPrefix = ''   # e.g. 'wm-' -> check "wm-office-01"
}
