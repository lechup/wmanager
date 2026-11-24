# Messages of Restore-Backup.ps1 (Polish).
@{
    'restore.no_backup'                 = 'Brak kopii w {0}: wmanager nie był tu uruchamiany.'
    'restore.lock_wait'                 = 'Trwa inny przebieg wmanager (np. joby grup); czekam do 10 minut...'
    'restore.lock_busy'                 = 'Inny przebieg wmanager wciąż trwa. Spróbuj za chwilę.'
    'restore.journal_read_failed'       = 'Nie mogę odczytać dziennika zmian: {0}'
    'restore.start'                     = '{0}: przywracanie na {1}. Dziennik: {2} wartości komputera, {3} wartości użytkowników; kopii: {4}.'
    'restore.confirm'                   = 'Cofnąć zmiany wmanagera?'
    'restore.cancelled'                 = 'Anulowano, nic nie zmieniono.'
    'restore.profile_not_found'         = 'Profil {0} nie istnieje albo nie dało się go wczytać; jego ustawień nie przywrócono.'
    'restore.registry_summary'          = 'Rejestr: przywrócono {0} z {1} wartości.'
    'restore.store_apps_removed'        = 'Aplikacje ze Sklepu usunięte od kopii {0} ({1}); w razie potrzeby zainstaluj je ze Sklepu:'
    'restore.onedrive_removed'          = 'OneDrive był odinstalowany; jeśli jest potrzebny, zainstaluj go ponownie ze strony Microsoftu.'
    'restore.confirm_disable_tasks'     = 'Wyłączyć zadania wmanager? Inaczej zaplanowana aktualizacja znowu usunie aplikacje i zmieni ustawienia.'
    'restore.tasks_disabled'            = 'Zadania wmanager wyłączone ({0}).'
    'restore.tasks_kept'                = 'Zadania wmanager zostają włączone; zaplanowana aktualizacja znowu zastosuje ustawienia.'
    'restore.certificate_removed'       = 'Certyfikat podpisu wmanager usunięty z zaufanych ({0}).'
    'restore.certificate_remove_failed' = 'Nie udało się usunąć certyfikatu podpisu wmanager z zaufanych: {0}'
    'restore.stopped'                   = 'Przywracanie przerwane: {0}'
    'restore.summary'                   = 'Koniec: ostrzeżenia {0}, błędy {1}. Log: {2}'
    'restore.finished_with_errors'      = 'Przywracanie zakończone z błędami. Sprawdź log powyżej.'
    'restore.finished'                  = 'Przywracanie zakończone. Uruchom ponownie komputer, żeby ustawienia zadziałały.'

    # Accounts: a separate administrator, the person signed in a standard user (lib\Accounts.ps1)
    'restore.confirm_admin_again'                = 'Przywrócić uprawnienia administratora osobom, które provisioning zrobił zwykłymi użytkownikami?'
    'restore.admin_again'                        = '{0} jest znowu administratorem.'
    'restore.admin_again_failed'                 = 'Nie udało się przywrócić uprawnień administratora dla {0}: {1}'
    'restore.admin_account_stays'                = 'Konto administratora {0} zostaje (znowu widoczne na ekranie logowania); usuń je ręcznie, jeśli jest niepotrzebne.'
}
