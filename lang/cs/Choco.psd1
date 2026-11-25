# Messages of lib\Choco.ps1: Chocolatey, the package list, the default browser (Czech).
@{
    'choco.line_no_package'          = 'Řádek {0}: chybí název balíčku'
    'choco.line_bad_name'            = "Řádek {0}: neplatný název balíčku '{1}'"
    'choco.line_bad_version'         = "Řádek {0}: neplatná verze '{1}' pro '{2}'"
    'choco.line_unknown_option'      = 'Řádek {0}: neznámá možnost ''{1}'' (povoleno: !noupdate, !signer="vydavatel" a parametry choco za znakem |)'
    'choco.line_duplicate'           = "Řádek {0}: balíček '{1}' se vyskytuje podruhé (poprvé na řádku {2})"
    'choco.line_bad_signer'          = 'Řádek {0}: !signer potřebuje jméno vydavatele, jednou, v uvozovkách, pokud obsahuje mezery (např. !signer="Google LLC")'

    'choco.reqs_file_missing'        = 'soubor nenalezen: {0}'
    'choco.reqs_loaded'              = 'Seznam balíčků načten z: {0}'
    'choco.reqs_source_failed'       = 'Zdroj seznamu balíčků je nedostupný nebo neplatný ({0}): {1}'
    'choco.reqs_using_cache'         = 'Použije se poslední správně stažená kopie seznamu.'
    'choco.reqs_none'                = 'Není k dispozici žádný seznam balíčků (žádný zdroj neodpovídá a kopie neexistuje).'

    'choco.section'                  = '--- Chocolatey ---'
    'choco.already_installed'        = 'Chocolatey je již nainstalováno.'
    'choco.installing'               = 'Instaluje se Chocolatey z {0}'
    'choco.install_failed'           = 'Instalace Chocolatey se nezdařila.'
    'choco.installed'                = 'Chocolatey nainstalováno.'
    'choco.too_old'                  = 'Chocolatey {0} je příliš staré, aktualizuje se na 2.x.'
    'choco.version_required'         = 'Je vyžadováno Chocolatey 2.x, nainstalována je verze {0}.'
    'choco.upgraded'                 = 'Chocolatey aktualizováno na verzi {0}.'
    'choco.source_disabled'          = 'Zdroj {0} zakázán.'
    'choco.source_failed'            = 'Nepodařilo se nastavit zdroj {0} (kód {1})'
    'choco.source_set'               = 'Zdroj {0}: {1} (priorita {2}).'

    # {1}: one of the choco.action_* texts, the subject of the sentence (all three are feminine nouns in Czech)
    'choco.needs_restart'            = '{0} : {1} vyžaduje restart.'
    'choco.action_failed'            = '{0} : {1} se nezdařila (kód {2}), podrobnosti v místním protokolu.'
    'choco.action_install'           = 'instalace'
    'choco.action_install_version'   = 'instalace verze {0}'
    'choco.action_upgrade'           = 'aktualizace'

    # A download whose checksum doesn't match the package, checked by its signature instead (Invoke-WmChocoPackage)
    'choco.checksum_no_signer'       = '{0}: stažený soubor neodpovídá kontrolnímu součtu balíčku (často nová verze na stejné adrese, než se balíček aktualizuje; příští aktualizace to zkusí znovu). S !signer="vydavatel" na jeho řádku seznamu wmanager místo toho ověří podpis souboru.'
    'choco.checksum_check_signature' = '{0}: {1} neodpovídá kontrolnímu součtu balíčku; místo toho se ověřuje jeho podpis od {2}.'
    'choco.signature_no_file'        = '{0}: soubor k ověření už neexistuje ({1}) a jeho adresa není známa.'
    'choco.signature_download_failed' = '{0}: soubor k ověření se nepodařilo stáhnout z {1}: {2}'
    'choco.signature_bad'            = '{0}: {1} nemá platný podpis od {2} ({3}): nenainstalováno.'
    'choco.signature_ok'             = '{0}: {1} je podepsán {2}: instaluje se s jeho vlastním kontrolním součtem.'

    'choco.packages_section'         = '--- Balíčky ({0} na seznamu) ---'
    'choco.running_version_deferred' = '{0}: program je spuštěný, změna verze odložena.'
    'choco.version_set'              = '{0}: nastavena verze {1}.'
    'choco.version_pinned'           = '{0}: verze {1} připnuta.'
    'choco.pin_removed'              = '{0}: připnutí verze odebráno.'
    'choco.package_installed'        = '{0}: nainstalováno.'
    'choco.running_upgrade_deferred' = '{0}: program je spuštěný, aktualizace odložena do příštího přihlášení.'
    'choco.package_upgraded'         = '{0}: aktualizováno z verze {1}.'

    'choco.browser_missing'          = 'Prohlížeč {0} není nainstalován ({1}), nastavení výchozího prohlížeče se přeskakuje.'
    'choco.browser_set'              = 'Prohlížeč {0} nastaven jako výchozí pro nové účty.'
    'choco.browser_dism_failed'      = 'DISM nenastavil výchozí prohlížeč (kód {0}): {1}'
}
