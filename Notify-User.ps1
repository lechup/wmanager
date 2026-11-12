# Uruchamiany w sesji zalogowanego użytkownika (bez uprawnień administratora).
# 1. Jeśli po aktualizacji potrzebny jest restart: powiadomienie z prośbą o restart.
# 2. Raz na użytkownika: jeśli domyślna przeglądarka jest inna niż ustalona, otwiera Ustawienia.

$ErrorActionPreference = 'SilentlyContinue'
$root       = Join-Path $env:ProgramData 'wmanager'
$stateDir   = Join-Path $root 'state'
$rebootFlag = Join-Path $stateDir 'reboot-required.flag'
$publicFile = Join-Path $stateDir 'public.json'

function Show-WmToast {
    param([string]$Title, [string]$Text)
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
        $t = [Security.SecurityElement]::Escape($Title)
        $b = [Security.SecurityElement]::Escape($Text)
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml("<toast duration=`"long`"><visual><binding template=`"ToastGeneric`"><text>$t</text><text>$b</text></binding></visual></toast>")
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show([Windows.UI.Notifications.ToastNotification]::new($xml))
    } catch {
        # Zapasowo zwykłe okienko, które samo zniknie po 5 minutach
        (New-Object -ComObject WScript.Shell).Popup($Text, 300, $Title, 64) | Out-Null
    }
}

# --- 1. Restart -------------------------------------------------------------
if (Test-Path -LiteralPath $rebootFlag) {
    $saved = (Get-Content -LiteralPath $rebootFlag -Raw).Trim()
    $boot  = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
    if ($saved -eq $boot) {
        Show-WmToast 'Potrzebny restart komputera' 'Zainstalowano aktualizacje programów. Uruchom ponownie komputer, gdy będzie Ci wygodnie.'
    }
}

# --- 2. Domyślna przeglądarka (jednorazowo) ----------------------------------
if (Test-Path -LiteralPath $publicFile) {
    $public = Get-Content -LiteralPath $publicFile -Raw | ConvertFrom-Json
    $progId = $public.DefaultBrowserProgId
    $name   = $public.DefaultBrowserName
    $marker = 'HKCU:\Software\wmanager'
    $asked  = (Get-ItemProperty -LiteralPath $marker -Name 'DefaultBrowserPrompted' -ErrorAction SilentlyContinue).DefaultBrowserPrompted
    if ($progId -and -not $asked -and (Test-Path -LiteralPath "Registry::HKEY_CLASSES_ROOT\$progId")) {
        $current = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice' -ErrorAction SilentlyContinue).ProgId
        if ($current -ne $progId) {
            Show-WmToast 'Ustaw domyślną przeglądarkę' "Za chwilę otworzą się Ustawienia. Wybierz $name jako domyślną przeglądarkę."
            Start-Sleep -Seconds 5
            Start-Process "ms-settings:defaultapps?registeredAppMachine=$([uri]::EscapeDataString($name))"
        }
        if (-not (Test-Path -LiteralPath $marker)) { New-Item -Path $marker -Force | Out-Null }
        New-ItemProperty -LiteralPath $marker -Name 'DefaultBrowserPrompted' -Value 1 -PropertyType DWord -Force | Out-Null
    }
}
