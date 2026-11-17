# Messages of Update-Packages.ps1, the scheduled update (Polish).
@{
    'update.retry_flag_failed' = 'Nie mogę zapisać znacznika ponowienia: {0}'
    'update.busy'              = 'Inny przebieg wmanager wciąż trwa; ponowię przy następnym logowaniu.'
    # {0}: wmanager and its version, {1}: update or retry (the job, not translated), {2}: the computer name
    'update.start'             = '{0} {1} na {2}'
    'update.offline'           = 'Brak połączenia z: {0}. Pomijam przebieg, ponowię przy następnym logowaniu.'
    'update.deferred'          = 'Odłożone do następnego logowania: {0}'
    'update.reboot_pending'    = 'System czeka na restart; użytkownik dostanie powiadomienie.'
    'update.run_failed'        = 'Przebieg przerwany: {0}'
    'update.summary'           = 'Koniec: ostrzeżenia {0}, błędy {1}.'
    # Self-update ({0} of self_update, self_installed and {2} of download_failed, self_update_failed: wmanager and its version)
    'update.self_update'                 = '{0} -> wmanager {1}: źródło zarządzania wskazuje tę wersję; pobieram {2}'
    'update.self_update_group'           = '{0} -> wmanager {1} (grupa {2}): źródło zarządzania wskazuje tę wersję; pobieram {3}'
    'update.self_update_download_failed' = 'Nie mogę pobrać wmanager {0}: {1}. Zostaje {2}; następna aktualizacja spróbuje ponownie.'
    'update.self_update_bad_hash'        = 'wmanager {0}: pobrany plik ma SHA256 {1}, a źródło zarządzania podaje {2}; nie instaluję.'
    'update.self_update_not_release'     = 'plik nie jest wersją {0} wmanager (brak wmanager\VERSION albo podaje inną wersję)'
    'update.self_update_error'           = 'Nie mogę przygotować wmanager {0}: {1}'
    'update.self_update_handover'        = 'Przekazuję ten przebieg do wmanager {0}.'
    'update.self_installed'              = 'Zainstalowano {0}; ten przebieg idzie dalej w tej wersji.'
    'update.self_install_failed'         = 'Nie mogę skopiować {0} do {1}: {2}'
    'update.self_update_failed'          = 'wmanager {0} się nie zainstalował (kod wyjścia {1}); ten przebieg idzie dalej w {2}, następna aktualizacja spróbuje ponownie.'
    'update.self_install_restored'       = '{0}; przywrócono poprzednią wersję'
    'update.self_install_not_restored'   = '{0}; nie udało się też przywrócić poprzedniej wersji ({1}): uruchom ponownie Provision.ps1 na tym komputerze'
}
