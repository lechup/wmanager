# Messages of lib\Choco.ps1: Chocolatey, the package list, the default browser (Dutch).
@{
    'choco.line_no_package'          = 'Regel {0}: geen pakketnaam'
    'choco.line_bad_name'            = "Regel {0}: ongeldige pakketnaam '{1}'"
    'choco.line_bad_version'         = "Regel {0}: ongeldige versie '{1}' voor '{2}'"
    'choco.line_unknown_option'      = 'Regel {0}: onbekende optie ''{1}'' (toegestaan: !noupdate, !signer="uitgever", en choco-parameters na het teken |)'
    'choco.line_duplicate'           = "Regel {0}: pakket '{1}' komt een tweede keer voor (eerst in regel {2})"
    'choco.line_bad_signer'          = 'Regel {0}: !signer heeft de naam van de uitgever nodig, één keer, tussen aanhalingstekens als die spaties bevat (bijv. !signer="Google LLC")'

    'choco.reqs_file_missing'        = 'bestand niet gevonden: {0}'
    'choco.reqs_loaded'              = 'Pakketlijst geladen van: {0}'
    'choco.reqs_source_failed'       = 'Bron van de pakketlijst niet beschikbaar of ongeldig ({0}): {1}'
    'choco.reqs_using_cache'         = 'De laatste correct gedownloade kopie van de lijst wordt gebruikt.'
    'choco.reqs_none'                = 'Geen pakketlijst beschikbaar (geen enkele bron antwoordt en er is geen kopie).'

    'choco.section'                  = '--- Chocolatey ---'
    'choco.already_installed'        = 'Chocolatey is al geïnstalleerd.'
    'choco.installing'               = 'Chocolatey wordt geïnstalleerd vanaf {0}'
    'choco.install_failed'           = 'Installatie van Chocolatey is mislukt.'
    'choco.installed'                = 'Chocolatey geïnstalleerd.'
    'choco.too_old'                  = 'Chocolatey {0} is te oud, wordt bijgewerkt naar 2.x.'
    'choco.version_required'         = 'Chocolatey 2.x is vereist, {0} is geïnstalleerd.'
    'choco.upgraded'                 = 'Chocolatey bijgewerkt naar {0}.'
    'choco.source_disabled'          = 'Bron {0} uitgeschakeld.'
    'choco.source_failed'            = 'Kan bron {0} niet instellen (code {1})'
    'choco.source_set'               = 'Bron {0}: {1} (prioriteit {2}).'

    # {1}: one of the choco.action_* texts, the subject of the sentence
    'choco.needs_restart'            = '{0} : {1} vereist opnieuw opstarten.'
    'choco.action_failed'            = '{0} : {1} is mislukt (code {2}), details in het lokale logboek.'
    'choco.action_install'           = 'installeren'
    'choco.action_install_version'   = 'installeren van versie {0}'
    'choco.action_upgrade'           = 'bijwerken'

    # A download whose checksum doesn't match the package, checked by its signature instead (Invoke-WmChocoPackage)
    'choco.checksum_no_signer'       = '{0}: het gedownloade bestand komt niet overeen met de controlesom van het pakket (vaak een nieuwe versie op hetzelfde adres voordat het pakket is bijgewerkt; de volgende update probeert het opnieuw). Met !signer="uitgever" op zijn regel in de lijst controleert wmanager in plaats daarvan de handtekening van het bestand.'
    'choco.checksum_check_signature' = '{0}: {1} komt niet overeen met de controlesom van het pakket; in plaats daarvan wordt de handtekening van {2} gecontroleerd.'
    'choco.signature_no_file'        = '{0}: het te controleren bestand is er niet meer ({1}) en het adres ervan is onbekend.'
    'choco.signature_download_failed' = '{0}: het te controleren bestand kon niet worden gedownload van {1}: {2}'
    'choco.signature_bad'            = '{0}: {1} is niet geldig ondertekend door {2} ({3}): niet geïnstalleerd.'
    'choco.signature_ok'             = '{0}: {1} is ondertekend door {2}: installeren met zijn eigen controlesom.'

    'choco.packages_section'         = '--- Pakketten ({0} op de lijst) ---'
    'choco.running_version_deferred' = '{0}: het programma is actief, versiewijziging uitgesteld.'
    'choco.version_set'              = '{0}: versie {1} ingesteld.'
    'choco.version_pinned'           = '{0}: versie {1} vastgezet.'
    'choco.pin_removed'              = '{0}: versie niet langer vastgezet.'
    'choco.package_installed'        = '{0}: geïnstalleerd.'
    'choco.running_upgrade_deferred' = '{0}: het programma is actief, bijwerken uitgesteld tot de volgende aanmelding.'
    'choco.package_upgraded'         = '{0}: bijgewerkt van {1}.'

    'choco.browser_missing'          = '{0} is niet geïnstalleerd ({1}), instellen van de standaardbrowser wordt overgeslagen.'
    'choco.browser_set'              = '{0} ingesteld als standaardbrowser voor nieuwe accounts.'
    'choco.browser_dism_failed'      = 'DISM heeft de standaardbrowser niet ingesteld (code {0}): {1}'
}
