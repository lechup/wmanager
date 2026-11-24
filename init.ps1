<#
.SYNOPSIS
    wmanager: configuration wizard. Writes provision.config.psd1 next to run.cmd.

.DESCRIPTION
    Asks, in the user's language, for the settings most computers need (update time, Grafana Cloud Loki,
    Healthchecks.io, the management source of computer groups), checks them (a test line to Loki, an optional test
    ping, the signed manifest of the source) and writes provision.config.psd1. It starts from the existing file (or
    from provision.config.example.psd1) and changes only those values, so comments and the other settings stay; the
    previous file is kept as provision.config.psd1.bak-<time>. Runs in Windows PowerShell 5.1 and PowerShell 7
    (Windows or Linux); it needs no administrator rights and changes nothing else.

.PARAMETER ConfigPath
    Where to write the configuration. Defaults to provision.config.psd1 next to this script.

.PARAMETER Lang
    Language of the questions: en, de, fr, es, it, pl, nl, pt, ro, cs. Without it: WMANAGER_LANG, then the display
    language, then English. Yes/no questions also take y and n.

.PARAMETER DefaultSourceId
    The identifier of the management source (its source-id.txt) to offer when the source can't be read, instead of
    the one saved in the file; tools/wm.ps1 passes the one of the company's source.

.EXAMPLE
    .\init.cmd
.EXAMPLE
    pwsh ./init.ps1 -Lang pl
#>
[CmdletBinding()]
param([string]$ConfigPath, [string]$Lang, [string]$DefaultSourceId)

$ErrorActionPreference = 'Stop'
. (Join-Path (Join-Path $PSScriptRoot 'lib') 'Lang.ps1')
. (Join-Path (Join-Path $PSScriptRoot 'lib') 'Init.ps1')
. (Join-Path (Join-Path $PSScriptRoot 'lib') 'Groups.ps1')   # Test-WmAccountName
Initialize-WmLanguage -Lang $Lang
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'provision.config.psd1' }
$ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
$configDir = Split-Path $ConfigPath -Parent
$example = Join-Path $PSScriptRoot 'provision.config.example.psd1'

# An error that stops the wizard: the text of New-WmError in the user's language (its message is English);
# anything else as PowerShell shows it, with where it happened.
trap {
    $reason = $null
    try { $reason = Get-WmErrorText $_ } catch { }
    if ($null -eq $reason -or $reason -is [string]) { break }
    Write-Host ''
    Write-Host (Format-WmErrorText $_) -ForegroundColor Red
    exit 1
}

# --- Questions ------------------------------------------------------------------------------------------------
$script:EmptyReads = 0

# $Prompt and $Hint are texts already in the user's language; no $Hint = "invalid answer".
function Read-Answer {
    param([string]$Prompt, [string]$Default = '', [scriptblock]$Valid, [string]$Hint)
    if (-not $Hint) { $Hint = Get-WmText 'init.invalid_answer' }
    while ($true) {
        $shown = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
        $a = Read-Host $shown
        if ($null -eq $a) {
            # end of redirected input: don't ask forever
            if (++$script:EmptyReads -gt 3) { throw (New-WmError 'init.no_answer') }
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
        if ($null -eq $a -and ++$script:EmptyReads -gt 3) { throw (New-WmError 'init.no_answer') }
    } else { $a = [Net.NetworkCredential]::new('', (Read-Host $Prompt -AsSecureString)).Password }
    return ([string]$a).Trim()
}

# Yes or no in the user's language; y/yes and n/no always work.
function Read-YesNo {
    param([string]$Prompt, [bool]$Default)
    return Read-WmYesNo -Prompt $Prompt -Default $Default   # the same question as provisioning's (lib\Lang.ps1)
}

function Write-Section { param([string]$Title) Write-Host ''; Write-Host "--- $Title ---" -ForegroundColor Cyan }
function Write-Ok { param([string]$Text) Write-Host "  OK: $Text" -ForegroundColor Green }
function Write-Problem { param([string]$Text) Write-Host ('  ' + (Get-WmText 'init.warning' @($Text))) -ForegroundColor Yellow }

# A setting of the current configuration (empty when missing).
function Get-Current {
    param([string]$Name, $Default = '')
    if ($script:cur.ContainsKey($Name) -and $null -ne $script:cur[$Name]) { return $script:cur[$Name] }
    return $Default
}

# --- Start ------------------------------------------------------------------------------------------------------
Write-Host (Get-WmText 'init.title') -ForegroundColor Cyan
Write-Host (Get-WmText 'init.will_write' @($ConfigPath))
Write-Host (Get-WmText 'init.enter_default')

# The settings the wizard writes; it changes them in place, so they must be in the file, one per line
$names = @('UpdateTime', 'UpdateDays', 'LokiUrl', 'LokiUser', 'LokiToken', 'HealthchecksPingKey', 'HealthchecksSlugPrefix',
           'Source', 'SourceId', 'AuthHeader', 'Certificate')
$base = $example
if (Test-Path -LiteralPath $ConfigPath) {
    if (Read-YesNo (Get-WmText 'init.file_exists') $true) { $base = $ConfigPath }
}
$script:cur = Import-PowerShellDataFile -LiteralPath $base
$text = [IO.File]::ReadAllText($base)
$missing = @(Get-WmConfigTextProblems -Text $text -Names $names)
if ($missing.Count -gt 0 -and $base -ne $example) {
    # e.g. a file from before computer groups: start from the example, keeping these answers as the defaults
    Write-Problem (Get-WmText 'init.file_lacks_settings' @($missing -join ', '))
    if (-not (Read-YesNo (Get-WmText 'init.start_from_example') $true)) {
        throw (New-WmError 'init.stopped_missing_settings')
    }
    $text = [IO.File]::ReadAllText($example)
    $missing = @(Get-WmConfigTextProblems -Text $text -Names $names)
}
if ($missing.Count -gt 0) { throw (New-WmError 'init.example_lacks_settings' @($missing -join ', ')) }
$management = Get-Current 'Management' @{}
if (-not ($management -is [hashtable])) { $management = @{} }

# --- 1. Scheduled update ----------------------------------------------------------------------------------------
Write-Section (Get-WmText 'init.section_update')
$time = Read-Answer (Get-WmText 'init.update_time') (Get-Current 'UpdateTime' '12:00') `
    { Test-WmUpdateTime $args[0] } (Get-WmText 'init.update_time_hint')
$currentDays = @(Get-Current 'UpdateDays' $script:WmEveryDay)
if ($currentDays.Count -eq 0) { $currentDays = $script:WmEveryDay }   # @() schedules nothing; offer the default
$label = Get-WmUpdateDaysLabel $currentDays
$choicePrompt = Get-WmText 'init.days'
if (-not $label) { $choicePrompt += ' ' + (Get-WmText 'init.days_keep' @($currentDays -join ', ')) }
$choice = Read-Answer $choicePrompt $label { (-not $args[0]) -or @(Get-WmUpdateDaysChoice $args[0]).Count -gt 0 } (Get-WmText 'init.days_hint')
$days = if ($choice) { @(Get-WmUpdateDaysChoice $choice) } else { $currentDays }
$text = Set-WmConfigText $text 'UpdateTime' (ConvertTo-WmPsdString $time)
$text = Set-WmConfigText $text 'UpdateDays' (ConvertTo-WmPsdArray $days)

# --- 2. Loki ----------------------------------------------------------------------------------------------------
Write-Section (Get-WmText 'init.section_loki')
$lokiUrl = [string](Get-Current 'LokiUrl')
$off = if ($lokiUrl) { Get-WmText 'init.loki_off_dash' } else { Get-WmText 'init.loki_off_enter' }
$lokiUrl = Read-Answer (Get-WmText 'init.loki_url' @($off)) $lokiUrl `
    { $args[0] -eq '-' -or -not $args[0] -or $args[0] -match '^https://' } (Get-WmText 'init.loki_url_hint')
if ($lokiUrl -and $lokiUrl -ne '-') {
    $lokiUser = Read-Answer (Get-WmText 'init.loki_user') ([string](Get-Current 'LokiUser')) { $args[0] -match '^\d+$' } (Get-WmText 'init.loki_user_hint')
    $lokiToken = [string](Get-Current 'LokiToken')
    $prompt = if ($lokiToken) { Get-WmText 'init.loki_token_keep' } else { Get-WmText 'init.loki_token' }
    do { $t = Read-Secret $prompt; if ($t) { $lokiToken = $t } } while (-not $lokiToken)
    Write-Host ('  ' + (Get-WmText 'init.loki_sending'))
    $problem = Test-WmLoki -Url $lokiUrl -User $lokiUser -Token $lokiToken
    if ($problem) {
        Write-Problem $problem
        if (-not (Read-YesNo (Get-WmText 'init.loki_save_anyway') $false)) { throw (New-WmError 'init.stopped_loki') }
    } else { Write-Ok (Get-WmText 'init.loki_ok') }
} else { $lokiUrl = ''; $lokiUser = ''; $lokiToken = '' }
$text = Set-WmConfigText $text 'LokiUrl' (ConvertTo-WmPsdString $lokiUrl)
$text = Set-WmConfigText $text 'LokiUser' (ConvertTo-WmPsdString $lokiUser)
$text = Set-WmConfigText $text 'LokiToken' (ConvertTo-WmPsdString $lokiToken)

# --- 3. Healthchecks --------------------------------------------------------------------------------------------
Write-Section (Get-WmText 'init.section_healthchecks')
$savedKey = [string](Get-Current 'HealthchecksPingKey')
$prompt = if ($savedKey) { Get-WmText 'init.healthchecks_key_keep' } else { Get-WmText 'init.healthchecks_key' }
while ($true) {
    $k = Read-Secret $prompt
    if ($k -eq '-') { $pingKey = ''; break }
    if (-not $k) { $pingKey = $savedKey; break }   # a mistyped key before doesn't throw the saved one away
    if (Test-WmPingKey $k) { $pingKey = $k; break }
    Write-Problem (Get-WmText 'init.healthchecks_key_hint')
}
$prefix = [string](Get-Current 'HealthchecksSlugPrefix')
if ($pingKey) {
    $prefix = Read-Answer (Get-WmText 'init.healthchecks_prefix') $prefix { $args[0] -match '^[A-Za-z0-9_-]*$' } (Get-WmText 'init.healthchecks_prefix_hint')
    if (Read-YesNo (Get-WmText 'init.healthchecks_test_ping' @($prefix.ToLowerInvariant() + 'init')) $false) {
        $problem = Test-WmHealthchecks -BaseUrl ([string](Get-Current 'HealthchecksBaseUrl' 'https://hc-ping.com')) -PingKey $pingKey -SlugPrefix $prefix
        if ($problem) {
            Write-Problem $problem
            if (-not (Read-YesNo (Get-WmText 'init.healthchecks_save_anyway') $false)) { throw (New-WmError 'init.stopped_healthchecks') }
        } else { Write-Ok (Get-WmText 'init.healthchecks_ok') }
    }
}
$text = Set-WmConfigText $text 'HealthchecksPingKey' (ConvertTo-WmPsdString $pingKey)
$text = Set-WmConfigText $text 'HealthchecksSlugPrefix' (ConvertTo-WmPsdString $prefix)

# --- 4. Management source of computer groups --------------------------------------------------------------------
Write-Section (Get-WmText 'init.section_groups')
$source = [string]$management.Source
$off = if ($source) { Get-WmText 'init.groups_off_dash' } else { Get-WmText 'init.groups_off_enter' }
$source = Read-Answer (Get-WmText 'init.source' @($off)) $source `
    { $args[0] -eq '-' -or -not $args[0] -or (Test-WmManagementSource $args[0]) } (Get-WmText 'init.source_hint')
$sourceId = ''; $authHeader = ''; $certName = [string]$management.Certificate
if (-not $certName) { $certName = 'wmanager-signing.cer' }
$certCopy = $null
if ($source -and $source -ne '-') {
    $authHeader = [string]$management.AuthHeader
    if ($source -match '^https://') {
        $prompt = if ($authHeader) { Get-WmText 'init.auth_header_keep' } else { Get-WmText 'init.auth_header' }
        $a = Read-Secret $prompt
        if ($a -eq '-') { $authHeader = '' } elseif ($a) { $authHeader = $a }
    } else { $authHeader = '' }

    $certDest = Join-Path $configDir $certName
    $certDefault = if (Test-Path -LiteralPath $certDest) { $certDest } else { '' }
    do {
        $certPath = Read-Answer (Get-WmText 'init.cert_file') $certDefault `
            { $args[0] -and (Test-Path -LiteralPath $args[0] -PathType Leaf) } (Get-WmText 'init.cert_file_hint')
        $certPath = (Resolve-Path -LiteralPath $certPath).ProviderPath   # also ~ and relative paths
        $cert = Import-WmCertificateFile $certPath
        $problem = if ($cert) { Get-WmSigningCertificateProblem $cert } else { Get-WmText 'init.cert_not_certificate' }
        if ($problem) { Write-Problem $problem; $certDefault = '' }
    } while ($problem)
    Write-Host ('  ' + (Get-WmText 'init.cert_info' @($cert.Subject, $cert.Thumbprint, $cert.NotAfter.ToString('yyyy-MM-dd'))))
    if ($certPath -ne [IO.Path]::GetFullPath($certDest)) { $certCopy = $certPath }

    $manifest = $null; $manifestId = ''; $signer = $null
    if ($source -notmatch '^https://' -and -not $script:WmIsWindows) {
        Write-Host ('  ' + (Get-WmText 'init.source_path_unchecked'))
        $manifestId = '-'
    } else { try {
        $manifest = Get-WmSourceManifest -Source $source -AuthHeader $authHeader
        $data = Import-PowerShellDataFile -LiteralPath $manifest
        $manifestId = [string]$data.SourceId
        Write-Ok (Get-WmText 'init.manifest_info' @($data.Serial, @($data.Files.Keys).Count, $manifestId))
        $signer = Test-WmManifestSigner -ManifestPath $manifest -CertificatePath $certPath
        if ($signer -eq 'ok') { Write-Ok (Get-WmText 'init.manifest_signed') }
        elseif ($signer -eq 'skipped') { Write-Host ('  ' + (Get-WmText 'init.signature_unchecked')) }
        else { Write-Problem $signer }
    } catch {
        Write-Problem (Get-WmText 'init.manifest_failed' @(Get-WmErrorText $_))
    } finally {
        if ($manifest) { Remove-Item -LiteralPath $manifest -Force -ErrorAction SilentlyContinue }
    } }
    $unchecked = $manifestId -eq '-'
    if ($unchecked) { $manifestId = '' }
    # The identifier of the manifest just fetched, else the one of -DefaultSourceId (the source folder itself), and
    # the saved one only without both. The same source with another identifier than saved means it was replaced: say so.
    $savedId = [string]$management.SourceId
    $freshId = if ($manifestId) { $manifestId } else { $DefaultSourceId }
    $idDefault = if ($freshId) { $freshId } else { $savedId }
    if ($freshId -and $savedId -and $freshId -ne $savedId -and $source -eq [string]$management.Source) {
        Write-Problem (Get-WmText 'init.source_id_changed' @($savedId))
    }
    $sourceId = Read-Answer (Get-WmText 'init.source_id') $idDefault { Test-WmSourceId $args[0] } (Get-WmText 'init.source_id_hint')
    if ($manifestId -and $sourceId -ne $manifestId) { Write-Problem (Get-WmText 'init.source_id_mismatch' @($manifestId)) }
    if (-not $unchecked -and (-not $manifestId -or $sourceId -ne $manifestId -or ($signer -and $signer -notin @('ok', 'skipped'))) -and
        -not (Read-YesNo (Get-WmText 'init.source_save_anyway') $false)) {
        throw (New-WmError 'init.stopped_source')
    }
} else { $source = '' }
$text = Set-WmConfigText $text 'Source' (ConvertTo-WmPsdString $source)
$text = Set-WmConfigText $text 'SourceId' (ConvertTo-WmPsdString $sourceId)
$text = Set-WmConfigText $text 'AuthHeader' (ConvertTo-WmPsdString $authHeader)
$text = Set-WmConfigText $text 'Certificate' (ConvertTo-WmPsdString $certName)

# --- Accounts ---------------------------------------------------------------------------------------------------
# A separate administrator account and the person signed in a standard user (lib\Accounts.ps1). Only the name is
# kept: the passwords are typed at each computer during provisioning.
Write-Section (Get-WmText 'init.section_accounts')
Write-Host ('  ' + (Get-WmText 'init.admin_account_note'))
$admin = Read-Answer (Get-WmText 'init.admin_account') ([string](Get-Current 'AdminAccount' '')) `
    { $args[0] -eq '' -or $args[0] -eq '-' -or (Test-WmAccountName $args[0]) } (Get-WmText 'init.admin_account_hint')
if ($admin -eq '-') { $admin = '' }
$text = Set-WmConfigTextOrAdd $text 'AdminAccount' (ConvertTo-WmPsdString $admin) @(
    'A local administrator account provisioning creates, hidden from the sign-in screen; the person signed in becomes'
    'a standard user. Both passwords are typed at the computer during provisioning, kept nowhere. Empty = off.')

# --- Saving -----------------------------------------------------------------------------------------------------
Write-Section (Get-WmText 'init.section_save')
# The new file must be a valid data file before it replaces the old one
$new = "$ConfigPath.new"
Write-WmConfigFile -Path $new -Text $text
try { $null = Import-PowerShellDataFile -LiteralPath $new }
catch { Remove-Item -LiteralPath $new -Force; throw (New-WmError 'init.new_config_invalid' @(Get-WmErrorText $_)) }
if (Test-Path -LiteralPath $ConfigPath) {
    $backup = '{0}.bak-{1}' -f $ConfigPath, (Get-Date -Format 'yyyyMMddHHmmss')
    Copy-Item -LiteralPath $ConfigPath -Destination $backup
    Write-Host ('  ' + (Get-WmText 'init.previous_file' @($backup)))
}
Move-Item -LiteralPath $new -Destination $ConfigPath -Force
if ($certCopy) {
    Copy-Item -LiteralPath $certCopy -Destination (Join-Path $configDir $certName) -Force
    Write-Host ('  ' + (Get-WmText 'init.cert_copied' @($certName)))
}
Write-Ok (Get-WmText 'init.saved' @($ConfigPath))
Write-Host ''
Write-Host (Get-WmText 'init.next_copy')
Write-Host (Get-WmText 'init.next_tokens')
Write-Host (Get-WmText 'init.next_other_settings')
