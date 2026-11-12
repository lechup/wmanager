# Runs in the signed-in user's session (no administrator rights).
# 1. If a restart is needed after an update: a notification asking for a restart.
# 2. Once per user: if the default browser differs from the configured one, opens Settings.

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
        # Fallback: a plain message box that closes itself after 5 minutes
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

# --- 2. Default browser (one-time) -------------------------------------------
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
