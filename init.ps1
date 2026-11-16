<#
.SYNOPSIS
    wmanager: configuration wizard. Writes provision.config.psd1 next to run.cmd.

.DESCRIPTION
    Asks in Polish for the settings most computers need (update time, Grafana Cloud Loki, Healthchecks.io,
    the management source of computer groups), checks them (a test line to Loki, an optional test ping, the
    signed manifest of the source) and writes provision.config.psd1. It starts from the existing file (or from
    provision.config.example.psd1) and changes only those values, so comments and the other settings stay; the
    previous file is kept as provision.config.psd1.bak-<time>. Runs in Windows PowerShell 5.1 and PowerShell 7
    (Windows or Linux); it needs no administrator rights and changes nothing else.

.PARAMETER ConfigPath
    Where to write the configuration. Defaults to provision.config.psd1 next to this script.

.EXAMPLE
    .\init.cmd
.EXAMPLE
    pwsh ./init.ps1
#>
[CmdletBinding()]
param([string]$ConfigPath)

$ErrorActionPreference = 'Stop'
. (Join-Path (Join-Path $PSScriptRoot 'lib') 'Init.ps1')
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'provision.config.psd1' }
$ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
$configDir = Split-Path $ConfigPath -Parent
$example = Join-Path $PSScriptRoot 'provision.config.example.psd1'

# --- Questions ------------------------------------------------------------------------------------------------
$script:EmptyReads = 0

function Read-Answer {
    param([string]$Prompt, [string]$Default = '', [scriptblock]$Valid, [string]$Hint = 'Niepoprawna odpowiedź.')
    while ($true) {
        $shown = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
        $a = Read-Host $shown
        if ($null -eq $a) {
            # end of redirected input: don't ask forever
            if (++$script:EmptyReads -gt 3) { throw 'Brak odpowiedzi; kreator przerwany.' }
            $a = ''
        }
        $a = $a.Trim()
        if (-not $a) { $a = $Default }
        if (-not $Valid -or (& $Valid $a)) { return $a }
        Write-Host "  $Hint" -ForegroundColor Yellow
    }
}

function Read-Secret {
    param([string]$Prompt)
    $redirected = $true
    try { $redirected = [Console]::IsInputRedirected } catch { }
    if ($redirected) {
        $a = Read-Host $Prompt
        if ($null -eq $a -and ++$script:EmptyReads -gt 3) { throw 'Brak odpowiedzi; kreator przerwany.' }
    } else { $a = [Net.NetworkCredential]::new('', (Read-Host $Prompt -AsSecureString)).Password }
    return ([string]$a).Trim()
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default)
    $hint = if ($Default) { '[T/n]' } else { '[t/N]' }
    $a = Read-Answer "$Prompt $hint" '' { $args[0] -match '^(|t|tak|y|yes|n|nie|no)$' } 'Odpowiedz t albo n.'
    if (-not $a) { return $Default }
    return $a -match '^(t|tak|y|yes)$'
}

function Write-Section { param([string]$Title) Write-Host ''; Write-Host "--- $Title ---" -ForegroundColor Cyan }
function Write-Ok { param([string]$Text) Write-Host "  OK: $Text" -ForegroundColor Green }
function Write-Problem { param([string]$Text) Write-Host "  Uwaga: $Text" -ForegroundColor Yellow }

# A setting of the current configuration (empty when missing).
function Get-Current {
    param([string]$Name, $Default = '')
    if ($script:cur.ContainsKey($Name) -and $null -ne $script:cur[$Name]) { return $script:cur[$Name] }
    return $Default
}

# --- Start ------------------------------------------------------------------------------------------------------
Write-Host 'wmanager: kreator konfiguracji' -ForegroundColor Cyan
Write-Host "Zapisze: $ConfigPath"
Write-Host 'Enter przyjmuje wartość w nawiasie. Tokeny i klucze nie są wyświetlane przy wpisywaniu.'

# The settings the wizard writes; it changes them in place, so they must be in the file, one per line
$names = @('UpdateTime', 'UpdateDays', 'LokiUrl', 'LokiUser', 'LokiToken', 'HealthchecksPingKey', 'HealthchecksSlugPrefix',
           'Source', 'SourceId', 'AuthHeader', 'Certificate')
$base = $example
if (Test-Path -LiteralPath $ConfigPath) {
    if (Read-YesNo 'Ten plik już istnieje. Zmienić jego ustawienia (n = zacząć od pliku przykładowego)?' $true) { $base = $ConfigPath }
}
$script:cur = Import-PowerShellDataFile -LiteralPath $base
$text = [IO.File]::ReadAllText($base)
$missing = @(Get-WmConfigTextProblems -Text $text -Names $names)
if ($missing.Count -gt 0 -and $base -ne $example) {
    # e.g. a file from before computer groups: start from the example, keeping these answers as the defaults
    Write-Problem "w tym pliku brakuje ustawień albo są zapisane w kilku liniach: $($missing -join ', ')."
    if (-not (Read-YesNo 'Zacząć od pliku przykładowego? Odpowiedzi z obecnego pliku będą domyślne; inne własne zmiany przeniesiesz ręcznie ze starego pliku (zostanie jako .bak).' $true)) {
        throw 'Przerwano: dopisz brakujące ustawienia (wzór: provision.config.example.psd1) albo zacznij od pliku przykładowego.'
    }
    $text = [IO.File]::ReadAllText($example)
    $missing = @(Get-WmConfigTextProblems -Text $text -Names $names)
}
if ($missing.Count -gt 0) { throw "Plik przykładowy nie ma ustawień: $($missing -join ', ')." }
$management = Get-Current 'Management' @{}
if (-not ($management -is [hashtable])) { $management = @{} }

# --- 1. Scheduled update ----------------------------------------------------------------------------------------
Write-Section 'Aktualizacja programów'
$time = Read-Answer 'Godzina aktualizacji (HH:mm), najlepiej gdy komputery są zwykle włączone' (Get-Current 'UpdateTime' '12:00') `
    { Test-WmUpdateTime $args[0] } 'Podaj godzinę w formacie HH:mm, np. 12:00.'
$currentDays = @(Get-Current 'UpdateDays' $script:WmEveryDay)
if ($currentDays.Count -eq 0) { $currentDays = $script:WmEveryDay }   # @() schedules nothing; offer the default
$label = Get-WmUpdateDaysLabel $currentDays
$choicePrompt = 'Dni: c = codziennie, r = robocze (pn-pt), p = tylko poniedziałek'
if (-not $label) { $choicePrompt += " (Enter = bez zmian: $($currentDays -join ', '))" }
$choice = Read-Answer $choicePrompt $label { (-not $args[0]) -or @(Get-WmUpdateDaysChoice $args[0]).Count -gt 0 } 'Wpisz c, r albo p.'
$days = if ($choice) { @(Get-WmUpdateDaysChoice $choice) } else { $currentDays }
$text = Set-WmConfigText $text 'UpdateTime' (ConvertTo-WmPsdString $time)
$text = Set-WmConfigText $text 'UpdateDays' (ConvertTo-WmPsdArray $days)

# --- 2. Loki ----------------------------------------------------------------------------------------------------
Write-Section 'Grafana Cloud Loki: logi z komputerów (opcjonalnie)'
$lokiUrl = [string](Get-Current 'LokiUrl')
$off = if ($lokiUrl) { ' (- = bez Loki)' } else { ' (Enter = bez Loki)' }
$lokiUrl = Read-Answer "Adres Loki, np. https://logs-prod-012.grafana.net$off" $lokiUrl `
    { $args[0] -eq '-' -or -not $args[0] -or $args[0] -match '^https://' } 'Adres musi zaczynać się od https://'
if ($lokiUrl -and $lokiUrl -ne '-') {
    $lokiUser = Read-Answer 'User (liczba z Grafana Cloud)' ([string](Get-Current 'LokiUser')) { $args[0] -match '^\d+$' } 'Podaj sam numer użytkownika.'
    $lokiToken = [string](Get-Current 'LokiToken')
    $prompt = if ($lokiToken) { 'Token z zakresem logs:write (Enter = bez zmian)' } else { 'Token z zakresem logs:write' }
    do { $t = Read-Secret $prompt; if ($t) { $lokiToken = $t } } while (-not $lokiToken)
    Write-Host '  Wysyłam do Loki linię testową (job="init")...'
    $problem = Test-WmLoki -Url $lokiUrl -User $lokiUser -Token $lokiToken
    if ($problem) {
        Write-Problem $problem
        if (-not (Read-YesNo 'Zapisać te ustawienia Loki mimo to?' $false)) { throw 'Przerwano: popraw ustawienia Loki i uruchom kreator jeszcze raz.' }
    } else { Write-Ok 'Loki przyjął linię testową.' }
} else { $lokiUrl = ''; $lokiUser = ''; $lokiToken = '' }
$text = Set-WmConfigText $text 'LokiUrl' (ConvertTo-WmPsdString $lokiUrl)
$text = Set-WmConfigText $text 'LokiUser' (ConvertTo-WmPsdString $lokiUser)
$text = Set-WmConfigText $text 'LokiToken' (ConvertTo-WmPsdString $lokiToken)

# --- 3. Healthchecks --------------------------------------------------------------------------------------------
Write-Section 'Healthchecks.io: alarm, gdy komputer przestanie się aktualizować (opcjonalnie)'
$savedKey = [string](Get-Current 'HealthchecksPingKey')
$prompt = if ($savedKey) { 'Ping key projektu (Enter = bez zmian, - = bez Healthchecks)' } else { 'Ping key projektu (Enter = bez Healthchecks)' }
while ($true) {
    $k = Read-Secret $prompt
    if ($k -eq '-') { $pingKey = ''; break }
    if (-not $k) { $pingKey = $savedKey; break }   # a mistyped key before doesn't throw the saved one away
    if (Test-WmPingKey $k) { $pingKey = $k; break }
    Write-Problem 'Ping key ma 22 znaki (litery, cyfry, - i _).'
}
$prefix = [string](Get-Current 'HealthchecksSlugPrefix')
if ($pingKey) {
    $prefix = Read-Answer 'Przedrostek nazw checków, np. wm- (Enter = bez)' $prefix { $args[0] -match '^[A-Za-z0-9_-]*$' } 'Tylko litery, cyfry, - i _.'
    if (Read-YesNo "Wysłać testowy ping? Healthchecks utworzy check '$($prefix.ToLowerInvariant())init', który potem możesz usunąć." $false) {
        $problem = Test-WmHealthchecks -BaseUrl ([string](Get-Current 'HealthchecksBaseUrl' 'https://hc-ping.com')) -PingKey $pingKey -SlugPrefix $prefix
        if ($problem) {
            Write-Problem $problem
            if (-not (Read-YesNo 'Zapisać ten klucz mimo to?' $false)) { throw 'Przerwano: popraw klucz Healthchecks i uruchom kreator jeszcze raz.' }
        } else { Write-Ok 'Healthchecks przyjął ping.' }
    }
}
$text = Set-WmConfigText $text 'HealthchecksPingKey' (ConvertTo-WmPsdString $pingKey)
$text = Set-WmConfigText $text 'HealthchecksSlugPrefix' (ConvertTo-WmPsdString $prefix)

# --- 4. Management source of computer groups --------------------------------------------------------------------
Write-Section 'Grupy komputerów: podpisane źródło zarządzania (opcjonalnie, README: Computer groups)'
$source = [string]$management.Source
$off = if ($source) { ' (- = bez grup)' } else { ' (Enter = bez grup)' }
$source = Read-Answer "Źródło: adres https:// folderu albo pełna ścieżka$off" $source `
    { $args[0] -eq '-' -or -not $args[0] -or (Test-WmManagementSource $args[0]) } 'Podaj adres https:// albo pełną ścieżkę folderu.'
$sourceId = ''; $authHeader = ''; $certName = [string]$management.Certificate
if (-not $certName) { $certName = 'wmanager-signing.cer' }
$certCopy = $null
if ($source -and $source -ne '-') {
    $authHeader = [string]$management.AuthHeader
    if ($source -match '^https://') {
        $prompt = if ($authHeader) { 'Nagłówek Authorization (Enter = bez zmian, - = bez)' } else { 'Nagłówek Authorization dla prywatnego repo, np. token github_pat_... (Enter = bez)' }
        $a = Read-Secret $prompt
        if ($a -eq '-') { $authHeader = '' } elseif ($a) { $authHeader = $a }
    } else { $authHeader = '' }

    $certDest = Join-Path $configDir $certName
    $certDefault = if (Test-Path -LiteralPath $certDest) { $certDest } else { '' }
    do {
        $certPath = Read-Answer 'Plik certyfikatu podpisu (wmanager-signing.cer z tools/new-signing-cert.sh)' $certDefault `
            { $args[0] -and (Test-Path -LiteralPath $args[0] -PathType Leaf) } 'Nie ma takiego pliku.'
        $certPath = (Resolve-Path -LiteralPath $certPath).ProviderPath   # also ~ and relative paths
        $cert = Import-WmCertificateFile $certPath
        $problem = if ($cert) { Get-WmSigningCertificateProblem $cert } else { 'to nie jest plik certyfikatu (.cer)' }
        if ($problem) { Write-Problem $problem; $certDefault = '' }
    } while ($problem)
    Write-Host "  Certyfikat: $($cert.Subject), odcisk $($cert.Thumbprint), ważny do $($cert.NotAfter.ToString('yyyy-MM-dd'))"
    if ($certPath -ne [IO.Path]::GetFullPath($certDest)) { $certCopy = $certPath }

    $manifest = $null; $manifestId = ''; $signer = $null
    if ($source -notmatch '^https://' -and -not $script:WmIsWindows) {
        Write-Host '  Ścieżki Windows nie sprawdzę z tego systemu; sprawdzi ją komputer przy provisioningu.'
        $manifestId = '-'
    } else { try {
        $manifest = Get-WmSourceManifest -Source $source -AuthHeader $authHeader
        $data = Import-PowerShellDataFile -LiteralPath $manifest
        $manifestId = [string]$data.SourceId
        Write-Ok "manifest $($data.Serial), plików: $(@($data.Files.Keys).Count), identyfikator źródła $manifestId"
        $signer = Test-WmManifestSigner -ManifestPath $manifest -CertificatePath $certPath
        if ($signer -eq 'ok') { Write-Ok 'manifest jest podpisany tym certyfikatem.' }
        elseif ($signer -eq 'skipped') { Write-Host '  Podpisu nie sprawdzam (Authenticode jest tylko w Windows); sprawdzi go komputer przy provisioningu.' }
        else { Write-Problem $signer }
    } catch {
        Write-Problem "nie udało się pobrać manifest.psd1: $($_.Exception.Message)"
    } finally {
        if ($manifest) { Remove-Item -LiteralPath $manifest -Force -ErrorAction SilentlyContinue }
    } }
    $unchecked = $manifestId -eq '-'
    if ($unchecked) { $manifestId = '' }
    # The identifier of the manifest just fetched; the saved one only when the source couldn't be read.
    # The same source with another identifier than saved means it was replaced: say so.
    $savedId = [string]$management.SourceId
    $idDefault = if ($manifestId) { $manifestId } else { $savedId }
    if ($manifestId -and $savedId -and $manifestId -ne $savedId -and $source -eq [string]$management.Source) {
        Write-Problem "to samo źródło ma teraz inny identyfikator niż zapisany ($savedId); upewnij się, że nikt go nie podmienił."
    }
    $sourceId = Read-Answer 'Identyfikator źródła (source-id.txt, wypisał go tools/publish.sh)' $idDefault { Test-WmSourceId $args[0] } `
        '8-64 znaki: litery, cyfry, . - _'
    if ($manifestId -and $sourceId -ne $manifestId) { Write-Problem "manifest ma inny identyfikator ($manifestId): komputer go odrzuci." }
    if (-not $unchecked -and (-not $manifestId -or $sourceId -ne $manifestId -or ($signer -and $signer -notin @('ok', 'skipped'))) -and
        -not (Read-YesNo 'Zapisać to źródło mimo to?' $false)) {
        throw 'Przerwano: popraw źródło grup i uruchom kreator jeszcze raz.'
    }
} else { $source = '' }
$text = Set-WmConfigText $text 'Source' (ConvertTo-WmPsdString $source)
$text = Set-WmConfigText $text 'SourceId' (ConvertTo-WmPsdString $sourceId)
$text = Set-WmConfigText $text 'AuthHeader' (ConvertTo-WmPsdString $authHeader)
$text = Set-WmConfigText $text 'Certificate' (ConvertTo-WmPsdString $certName)

# --- Saving -----------------------------------------------------------------------------------------------------
Write-Section 'Zapis'
# The new file must be a valid data file before it replaces the old one
$new = "$ConfigPath.new"
Write-WmConfigFile -Path $new -Text $text
try { $null = Import-PowerShellDataFile -LiteralPath $new }
catch { Remove-Item -LiteralPath $new -Force; throw "Nowa konfiguracja jest niepoprawna, nic nie zmieniłem: $($_.Exception.Message)" }
if (Test-Path -LiteralPath $ConfigPath) {
    $backup = '{0}.bak-{1}' -f $ConfigPath, (Get-Date -Format 'yyyyMMddHHmmss')
    Copy-Item -LiteralPath $ConfigPath -Destination $backup
    Write-Host "  Poprzedni plik: $backup"
}
Move-Item -LiteralPath $new -Destination $ConfigPath -Force
if ($certCopy) {
    Copy-Item -LiteralPath $certCopy -Destination (Join-Path $configDir $certName) -Force
    Write-Host "  Certyfikat skopiowany obok konfiguracji: $certName"
}
Write-Ok "zapisano $ConfigPath"
Write-Host ''
Write-Host 'Dalej: skopiuj cały folder wmanagera razem z tym plikiem na pendrive albo udział i na komputerze uruchom run.cmd.'
Write-Host 'Plik zawiera tokeny: trzymaj pendrive pod kontrolą. Pozostałe ustawienia (aplikacje do usunięcia, przeglądarka,'
Write-Host 'źródła Chocolatey) zmienisz w tym pliku ręcznie; listę programów w choco-reqs.txt.'
