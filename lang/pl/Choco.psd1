# Messages of lib\Choco.ps1: Chocolatey, the package list, the default browser (Polish).
@{
    'choco.line_no_package'          = 'Linia {0}: brak nazwy paczki'
    'choco.line_bad_name'            = "Linia {0}: niepoprawna nazwa paczki '{1}'"
    'choco.line_bad_version'         = "Linia {0}: niepoprawna wersja '{1}' dla '{2}'"
    'choco.line_unknown_option'      = 'Linia {0}: nieznana opcja ''{1}'' (dozwolone: !noupdate, !signer="wydawca", a parametry choco po znaku |)'
    'choco.line_duplicate'           = "Linia {0}: paczka '{1}' występuje drugi raz (pierwszy raz w linii {2})"
    'choco.line_bad_signer'          = 'Linia {0}: !signer wymaga nazwy wydawcy, raz, w cudzysłowie, gdy ma spacje (np. !signer="Google LLC")'

    'choco.reqs_file_missing'        = 'brak pliku {0}'
    'choco.reqs_loaded'              = 'Lista paczek pobrana z: {0}'
    'choco.reqs_source_failed'       = 'Źródło listy niedostępne lub błędne ({0}): {1}'
    'choco.reqs_using_cache'         = 'Używam ostatniej poprawnie pobranej kopii listy.'
    'choco.reqs_none'                = 'Brak dostępnej listy paczek (żadne źródło nie odpowiada i nie ma kopii).'

    'choco.section'                  = '--- Chocolatey ---'
    'choco.already_installed'        = 'Chocolatey już zainstalowany.'
    'choco.installing'               = 'Instaluję Chocolatey z {0}'
    'choco.install_failed'           = 'Instalacja Chocolatey nie powiodła się.'
    'choco.installed'                = 'Chocolatey zainstalowany.'
    'choco.too_old'                  = 'Chocolatey {0} jest za stary, aktualizuję do 2.x.'
    'choco.version_required'         = 'Wymagany Chocolatey 2.x, zainstalowany jest {0}.'
    'choco.upgraded'                 = 'Chocolatey zaktualizowany do {0}.'
    'choco.source_disabled'          = 'Źródło {0} wyłączone.'
    'choco.source_failed'            = 'Nie udało się ustawić źródła {0} (kod {1})'
    'choco.source_set'               = 'Źródło {0}: {1} (priorytet {2}).'

    # {1}: one of the choco.action_* texts, the subject of the sentence
    'choco.needs_restart'            = '{0} : {1} wymaga restartu.'
    'choco.action_failed'            = '{0} : {1} nie powiodła się (kod {2}), szczegóły w logu lokalnym.'
    'choco.action_install'           = 'instalacja'
    'choco.action_install_version'   = 'instalacja wersji {0}'
    'choco.action_upgrade'           = 'aktualizacja'

    # A download whose checksum doesn't match the package, checked by its signature instead (Invoke-WmChocoPackage)
    'choco.checksum_no_signer'       = '{0}: pobrany plik nie zgadza się z sumą kontrolną paczki (często nowa wersja pod tym samym adresem, zanim paczkę zaktualizowano; następna aktualizacja spróbuje znowu). Z !signer="wydawca" w jej linii na liście wmanager sprawdza zamiast tego podpis pliku.'
    'choco.checksum_check_signature' = '{0}: {1} nie zgadza się z sumą kontrolną paczki; zamiast niej sprawdzam podpis {2}.'
    'choco.signature_no_file'        = '{0}: pliku do sprawdzenia już nie ma ({1}), a jego adres nie jest znany.'
    'choco.signature_download_failed' = '{0}: nie udało się pobrać pliku do sprawdzenia z {1}: {2}'
    'choco.signature_bad'            = '{0}: {1} nie ma ważnego podpisu {2} ({3}): nie zainstalowano.'
    'choco.signature_ok'             = '{0}: {1} ma podpis {2}: instaluję go z jego własną sumą kontrolną.'

    'choco.packages_section'         = '--- Paczki ({0} na liście) ---'
    'choco.running_version_deferred' = '{0}: program działa, zmiana wersji odłożona.'
    'choco.version_set'              = '{0}: ustawiona wersja {1}.'
    'choco.version_pinned'           = '{0}: przypięta wersja {1}.'
    'choco.pin_removed'              = '{0}: zdjęto przypięcie wersji.'
    'choco.package_installed'        = '{0}: zainstalowano.'
    'choco.running_upgrade_deferred' = '{0}: program działa, aktualizacja odłożona do następnego logowania.'
    'choco.package_upgraded'         = '{0}: zaktualizowano z {1}.'

    'choco.browser_missing'          = '{0} nie jest zainstalowana ({1}), pomijam ustawienie domyślnej przeglądarki.'
    'choco.browser_set'              = '{0} ustawiona jako domyślna przeglądarka dla nowych kont.'
    'choco.browser_dism_failed'      = 'DISM nie ustawił domyślnej przeglądarki (kod {0}): {1}'
}
