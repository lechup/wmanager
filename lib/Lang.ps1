# Messages in the user's language (README, "Languages"). Platform-neutral: the wizard uses it on Linux too.
#
# Catalogs: lang\<code>\<area>.psd1, each a hashtable of key -> text with String.Format placeholders ({0}, {1}).
# English (lang\en) is complete and the fallback for a key missing in another language. The screen (console,
# questions, notifications) uses the chosen language; the log file and Loki always get English (Write-WmLog).
# The language: -Lang of the script > WMANAGER_LANG > the Windows display language > English.

$script:WmLanguages = @('en', 'de', 'fr', 'es', 'it', 'pl', 'nl', 'pt', 'ro', 'cs')
$script:WmLang = 'en'
$script:WmTextEn = @{}   # English
$script:WmTextUi = @{}   # the chosen language over English

# 'pl', 'pl-PL', 'de_DE.UTF-8' -> 'pl', 'de'; $null for a language wmanager doesn't have.
function ConvertTo-WmLanguageCode {
    param([string]$Value)
    if (-not $Value) { return $null }
    $code = ($Value.Trim() -split '[-_.@]')[0].ToLowerInvariant()
    if ($script:WmLanguages -contains $code) { return $code }
    return $null
}

# The first supported of: the requested language, WMANAGER_LANG, the display language; English otherwise.
function Resolve-WmLanguage {
    param([string]$Requested)
    foreach ($candidate in @($Requested, $env:WMANAGER_LANG, [Globalization.CultureInfo]::CurrentUICulture.Name)) {
        $code = ConvertTo-WmLanguageCode $candidate
        if ($code) { return $code }
    }
    return 'en'
}

# All catalogs of one language as one hashtable.
function Import-WmCatalog {
    param([Parameter(Mandatory = $true)][string]$Folder)
    $table = @{}
    if (-not (Test-Path -LiteralPath $Folder)) { return $table }
    foreach ($file in (Get-ChildItem -LiteralPath $Folder -Filter '*.psd1' -File | Sort-Object Name)) {
        $data = Import-PowerShellDataFile -LiteralPath $file.FullName
        foreach ($key in $data.Keys) { $table[$key] = [string]$data[$key] }
    }
    return $table
}

# Loads English and the chosen language. $Root: the folder with lang\ (default: the parent of lib\).
function Initialize-WmLanguage {
    param([string]$Lang, [string]$Root)
    if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
    $folder = Join-Path $Root 'lang'
    $script:WmLang = Resolve-WmLanguage $Lang
    $script:WmTextEn = Import-WmCatalog (Join-Path $folder 'en')
    $script:WmTextUi = $script:WmTextEn.Clone()
    if ($script:WmLang -ne 'en') {
        $ui = Import-WmCatalog (Join-Path $folder $script:WmLang)
        foreach ($key in $ui.Keys) { $script:WmTextUi[$key] = $ui[$key] }
    }
}

# A text to render later in each language (an argument of another text, or the reason in an error).
function New-WmText {
    param([Parameter(Mandatory = $true)][string]$Key, [object[]]$Arguments = @())
    return [pscustomobject]@{ PSTypeName = 'WmText'; Key = $Key; Arguments = @($Arguments) }
}

# The text of a key in the chosen language (or in English with -English), with its arguments; an argument that is
# itself a WmText is rendered in the same language. An unknown key shows itself, so it is noticed, not hidden.
function Get-WmText {
    param([Parameter(Mandatory = $true)][string]$Key, [object[]]$Arguments = @(), [switch]$English)
    $table = if ($English) { $script:WmTextEn } else { $script:WmTextUi }
    $format = $table[$Key]
    if ($null -eq $format) { $format = $script:WmTextEn[$Key] }
    $values = @(foreach ($a in @($Arguments)) {
        if ($a -is [psobject] -and $a.PSObject.TypeNames -contains 'WmText') { Get-WmText -Key $a.Key -Arguments $a.Arguments -English:$English }
        else { $a }
    })
    if ($null -eq $format) { return "[$Key] " + ($values -join ' ') }
    return [string]::Format($format, [object[]]$values)
}

# An exception whose message is English (for anything that shows it raw) and which carries the text, so the screen
# can show it in the user's language: throw (New-WmError 'key' @(...)).
function New-WmError {
    param([Parameter(Mandatory = $true)][string]$Key, [object[]]$Arguments = @())
    $text = New-WmText -Key $Key -Arguments $Arguments
    $ex = New-Object System.Exception -ArgumentList (Get-WmText -Key $Key -Arguments $Arguments -English)
    $ex.Data['WmText'] = $text
    return $ex
}

# The reason of an error as an argument for Get-WmText/Write-WmLog: the WmText of New-WmError, or the plain message.
function Get-WmErrorText {
    param([Parameter(Mandatory = $true)]$ErrorRecord)
    $ex = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ErrorRecord.Exception } else { $ErrorRecord }
    if ($ex.Data -and $ex.Data.Contains('WmText')) { return $ex.Data['WmText'] }
    return $ex.Message
}

# The reason of an error as text: in the user's language (or English with -English) for an error of New-WmError,
# the plain message otherwise.
function Format-WmErrorText {
    param([Parameter(Mandatory = $true)]$ErrorRecord, [switch]$English)
    $reason = Get-WmErrorText $ErrorRecord
    if ($reason -is [string]) { return $reason }
    return Get-WmText -Key $reason.Key -Arguments $reason.Arguments -English:$English
}

# A yes/no answer: the words of the chosen language and the English ones. $null for anything else.
function ConvertFrom-WmYesNo {
    param([string]$Answer)
    $a = ([string]$Answer).Trim().ToLowerInvariant()
    if (-not $a) { return $null }
    $yes = @((Get-WmText 'common.yes_words') -split '\|') + @('y', 'yes')
    $no = @((Get-WmText 'common.no_words') -split '\|') + @('n', 'no')
    if ($yes -contains $a) { return $true }
    if ($no -contains $a) { return $false }
    return $null
}

Initialize-WmLanguage
