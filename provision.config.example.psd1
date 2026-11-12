# Konfiguracja wmanager. Skopiuj jako provision.config.psd1 i uzupełnij.
# Prawdziwy plik (z tokenami) NIE trafia do repo, leży obok skryptu na pendrivie lub udziale.
@{
    # --- Lista paczek -------------------------------------------------------
    # Źródła choco-reqs.txt sprawdzane po kolei; pierwsze dostępne wygrywa.
    # Ścieżka względna liczy się od folderu, w którym leży skrypt.
    ReqsSources = @(
        # 'https://raw.githubusercontent.com/lechup/wmanager/main/choco-reqs.txt'
        # '\\serwer\udzial\wmanager\choco-reqs.txt'
        'choco-reqs.txt'
    )

    # --- Chocolatey -----------------------------------------------------------
    ChocolateyInstallUrl = 'https://community.chocolatey.org/install.ps1'

    # Priority: 1 = sprawdzane pierwsze, 2 = drugie..., 0 = bez priorytetu (na końcu).
    ChocolateySources = @(
        @{ Name = 'chocolatey'; Url = 'https://community.chocolatey.org/api/v2/'; Priority = 0; Enabled = $true }
        # Własne repo na później:
        # @{ Name = 'firma'; Url = 'https://nexus.example.pl/repository/choco/'; Priority = 1; Enabled = $true; User = ''; Password = '' }
    )

    # --- Cotygodniowa aktualizacja -------------------------------------------
    UpdateDays = @('Monday')       # Monday, Tuesday, ... (można kilka)
    UpdateTime = '12:00'           # HH:mm, czas lokalny

    # Pomijaj paczkę, której program właśnie działa; spróbuj przy następnym logowaniu.
    SkipRunningPackages = $true

    # Procesy, po których rozpoznajemy, że program z paczki działa.
    # Paczki spoza tej mapy: sprawdzana jest nazwa procesu równa nazwie paczki.
    RunningProcessMap = @{
        'googlechrome'      = @('chrome')
        'libreoffice-fresh' = @('soffice', 'soffice.bin')
        'libreoffice-still' = @('soffice', 'soffice.bin')
        'sumatrapdf'        = @('SumatraPDF')
        '7zip'              = @('7zFM', '7zG')
        'vlc'               = @('vlc')
        'notepadplusplus'   = @('notepad++')
        'rustdesk'          = @('rustdesk')
        'firefox'           = @('firefox')
    }

    # Uruchamiaj debloat i ustawienia prywatności także co tydzień
    # (duże aktualizacje Windows potrafią przywrócić aplikacje).
    RerunDebloatWeekly = $true

    # --- Debloat ---------------------------------------------------------------
    Debloat = @{
        RemoveApps = $true    # usuwanie pakietów z listy RemoveAppx
        OneDrive   = $true    # odinstalowanie i blokada OneDrive
        Policies   = $true    # zasady: Teams, Copilot, Recall, Widgets, Cortana, Phone Link, Game Bar
        Edge       = $true    # wyciszenie Edge (pasek boczny, zakupy, Startup Boost)
    }
    Privacy = $true           # telemetria, reklamy, sugestie, Bing w wyszukiwarce

    # Pakiety Appx do usunięcia (wzorce -like). Dopisz/usuń według potrzeb.
    RemoveAppx = @(
        # Teams
        'MSTeams'
        'MicrosoftTeams'
        # Copilot i Microsoft 365
        'Microsoft.Copilot'
        'Microsoft.Windows.Ai.Copilot.Provider'
        'Microsoft.MicrosoftOfficeHub'
        # Widgets, News, Weather, Bing
        'MicrosoftWindows.Client.WebExperience'
        'Microsoft.BingNews'
        'Microsoft.BingWeather'
        'Microsoft.BingSearch'
        # Xbox i gry
        'Microsoft.GamingApp'
        'Microsoft.XboxApp'
        'Microsoft.Xbox.TCUI'
        'Microsoft.XboxGamingOverlay'
        'Microsoft.XboxGameOverlay'
        'Microsoft.XboxIdentityProvider'
        'Microsoft.XboxSpeechToTextOverlay'
        'Microsoft.MicrosoftSolitaireCollection'
        # Pozostałe
        'Clipchamp.Clipchamp'
        'Microsoft.YourPhone'
        'Microsoft.549981C3F5F10'                     # Cortana
        'Microsoft.OutlookForWindows'
        'microsoft.windowscommunicationsapps'         # Poczta i Kalendarz
        'Microsoft.Todos'
        'MicrosoftCorporationII.MicrosoftFamily'
        'Microsoft.WindowsFeedbackHub'
        'Microsoft.GetHelp'
        'Microsoft.Getstarted'                        # Wskazówki
        'Microsoft.PowerAutomateDesktop'
        'Microsoft.WindowsMaps'
        'Microsoft.Windows.DevHome'
        'MicrosoftCorporationII.QuickAssist'          # Pomoc zdalna
    )

    # --- Domyślna przeglądarka -------------------------------------------------
    DefaultBrowser = @{
        Package = 'googlechrome'
        Name    = 'Google Chrome'
        ProgId  = 'ChromeHTML'
    }

    # --- Nazwa komputera ---------------------------------------------------------
    # Pytaj o nazwę, gdy nie podano -ComputerName (Enter = bez zmian).
    PromptComputerName = $true

    # --- Logi i monitoring ----------------------------------------------------
    LogRetentionDays = 90

    # Grafana Cloud Loki (push HTTP). Puste = nie wysyłaj.
    LokiUrl   = ''   # np. https://logs-prod-012.grafana.net
    LokiUser  = ''   # numeryczny User z Grafana Cloud
    LokiToken = ''   # token z uprawnieniem tylko logs:write

    # Healthchecks.io. Pusty klucz = nie pinguj.
    HealthchecksBaseUrl    = 'https://hc-ping.com'
    HealthchecksPingKey    = ''
    HealthchecksSlugPrefix = ''   # np. 'wm-' -> check "wm-biuro-01"
}
