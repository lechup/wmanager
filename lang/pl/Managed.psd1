# Messages of lib\Managed.ps1: the management source, group scripts and jobs (Polish).
@{
    'managed.manifest_no_source_id'      = 'manifest: brak poprawnego identyfikatora źródła (SourceId)'
    'managed.manifest_other_source'      = 'manifest należy do innego źródła ({0}), a nie do {1} z konfiguracji'
    'managed.manifest_no_serial'         = 'manifest: brak poprawnego numeru Serial'
    'managed.manifest_no_files'          = 'manifest: brak listy plików (Files)'
    'managed.manifest_bad_path'          = "manifest: niedozwolona ścieżka '{0}'"
    'managed.manifest_lists_itself'      = 'manifest: nie może wymieniać samego siebie'
    'managed.manifest_bad_hash'          = "manifest: niepoprawna suma SHA256 dla '{0}'"
    'managed.manifest_duplicate_path'    = "manifest: ścieżka '{0}' występuje dwa razy"

    'managed.groups_unknown_key'         = "groups.psd1: nieznany klucz '{0}' (dozwolone: Default, Computers)"
    'managed.groups_computers_not_table' = "groups.psd1: Computers musi być tabelą @{{ 'NAZWA' = @('grupa') }}"
    'managed.groups_empty_computer'      = 'groups.psd1: pusta nazwa komputera'
    'managed.groups_bad_group'           = "groups.psd1: niepoprawna nazwa grupy '{0}'"

    'managed.common_list'                = 'lista wspólna'
    'managed.package_group_replaces'     = 'Paczka {0}: wpis z grupy {1} zastępuje wpis z listy wspólnej.'
    'managed.package_conflict'           = "Paczka {0} jest różnie opisana w '{1}' i '{2}'; używam wpisu z '{1}'."
    'managed.unknown_period'             = "nieznana częstotliwość '{0}'"
    'managed.at_bad'                     = 'wmanager-at: ''{0}'' to nie godzina w rodzaju 18:00, Mon-Fri 18:00 albo Mon,Wed 07:30 (angielskie nazwy dni)'
    'managed.at_twice'                   = 'więcej niż jedna linia wmanager-at'
    'managed.at_hourly'                  = 'zadanie co godzinę działa co godzinę: wmanager-at jest dla zadań dziennych i tygodniowych'
    'managed.at_weekly_day'              = 'wmanager-at: ''{0}'': zadanie tygodniowe podaje jeden dzień, np. Fri 17:00'
    'managed.job_first_time'             = 'Zadanie {0} działa o {1}: pierwszy raz wtedy.'
    'managed.event_none'                 = 'skrypt zdarzenia podaje swoje zdarzenie w linii "# wmanager-event: network" (network, wake, lock, unlock albo dziennik i identyfikator zdarzenia)'
    'managed.event_bad'                  = 'wmanager-event: ''{0}'' to ani network, wake, lock, unlock, ani dziennik i identyfikator zdarzenia, np. System 7040 [źródło]'
    'managed.event_twice'                = 'wmanager-event: ''{0}'' podane dwa razy'
    'managed.event_gap_bad'              = 'wmanager-event-gap: ''{0}'' to nie liczba minut od 0 do 1440'
    'managed.event_gap_twice'            = 'więcej niż jedna linia wmanager-event-gap'

    'managed.cert_missing'               = 'Brak certyfikatu podpisu {0}'
    'managed.cert_private_key'           = '{0} zawiera klucz prywatny; na komputery trafia tylko publiczny .cer'
    'managed.cert_is_ca'                 = '{0} jest certyfikatem urzędu (CA); wmanager nie doda go do zaufanych'
    'managed.cert_not_code_signing'      = '{0} nie jest certyfikatem do podpisywania kodu (brak Code Signing)'
    'managed.cert_expired'               = 'Certyfikat podpisu wygasł {0}; działają tylko podpisy ze znacznikiem czasu.'
    'managed.cert_expiring'              = 'Certyfikat podpisu wygasa {0}; przygotuj nowy.'
    'managed.cert_previous_removed'      = 'Usunięto z zaufanych poprzedni certyfikat podpisu wmanager ({0}).'
    'managed.cert_added'                 = 'Certyfikat podpisu wmanager dodany do zaufanych głównych urzędów komputera ({0}).'
    'managed.signature_invalid'          = 'podpis manifestu nieprawidłowy ({0}): {1}'
    'managed.signature_other_cert'       = 'manifest podpisany innym certyfikatem ({0}) niż ten z konfiguracji ({1})'

    'managed.saved_copy_invalid'         = 'Zapisana kopia źródła zarządzania jest nieważna: {0}'
    'managed.file_error'                 = '{0}: {1}'
    'managed.source_unreachable'         = 'Źródło zarządzania niedostępne ({0}): {1}'
    'managed.manifest_older'             = 'manifest {0} jest starszy niż przyjęty wcześniej {1}'
    'managed.manifest_same_serial'       = 'manifest ma ten sam numer {0} co przyjęty wcześniej, ale inne pliki'
    'managed.source_unchanged'           = 'Źródło zarządzania bez zmian (manifest {0}).'
    'managed.download_failed'            = 'nie udało się pobrać {0}: {1}'
    'managed.hash_mismatch'              = '{0} ma inną sumę SHA256 niż w manifeście (plik zmieniony albo jeszcze nieopublikowany)'
    'managed.swap_failed'                = 'nie mogę podmienić {0} (czy jakiś program używa plików z tego folderu?): {1}'
    'managed.manifest_accepted'          = 'Źródło zarządzania: przyjęto manifest {0} (plików: {1}).'

    'managed.no_source'                  = 'Brak Management.Source w konfiguracji.'
    'managed.new_version_rejected'       = 'Odrzucono nową wersję ze źródła zarządzania: {0}'
    'managed.no_verified_copy'           = 'Brak sprawdzonej wersji źródła zarządzania (nie udało się jej pobrać, a kopii nie ma).'
    'managed.using_last_copy'            = 'Używam ostatniej sprawdzonej kopii źródła zarządzania (manifest {0}).'
    'managed.computer_groups'            = 'Grupy komputera {0}: {1}.'
    'managed.computer_no_groups'         = 'Komputer {0} nie należy do żadnej grupy (tylko lista wspólna).'
    'managed.group_no_files'             = 'Grupa {0} nie ma żadnych plików w źródle zarządzania.'
    'managed.source_info'                = 'Źródło zarządzania: {0} ({1}), certyfikat {2} ({3}).'

    'managed.scripts_section'            = '--- Skrypty grup ---'
    'managed.no_scripts'                 = 'Brak skryptów dla grup tego komputera.'
    'managed.script_unchanged'           = '{0}: bez zmian.'
    'managed.script_starting'            = '{0}: uruchamiam.'
    'managed.retry_next_update'          = 'ponowię przy następnej aktualizacji'
    'managed.retry_after_hours'          = 'ponowię za {0} h albo po zmianie skryptu'
    'managed.script_timeout'             = '{0}: przekroczony czas ({1} min), przerwany; {2}.'
    'managed.script_exit_code'           = '{0}: zakończony kodem {1}; {2}.'
    'managed.script_done_reboot'         = '{0}: zakończony, wymaga restartu.'
    'managed.script_done'                = '{0}: zakończony.'
    'managed.scripts_state_failed'       = 'Nie mogę zapisać stanu skryptów: {0}'

    'managed.jobs_state_failed'          = 'Nie mogę zapisać stanu jobów: {0}'
    'managed.job_starting'               = 'Job {0} ({1}): uruchamiam.'
    'managed.job_timeout'                = 'Job {0}: przekroczony czas ({1} min), przerwany.'
    'managed.job_exit_code'              = 'Job {0}: zakończony kodem {1}.'
    'managed.job_done'                   = 'Job {0}: zakończony.'
    # version.psd1 ({0}: the entry, e.g. Groups.test.Url; {1}: its value)
    'managed.version_unknown_key'      = 'version.psd1: nieznany klucz ''{0}'' (dozwolone: Version, Url, Sha256, Groups)'
    'managed.version_missing'          = 'version.psd1: brak {0} (wersja wymaga Version, Url i Sha256)'
    'managed.version_bad_tag'          = 'version.psd1: {0} nie jest wersją wmanager w rodzaju v0.2.0: {1}'
    'managed.version_bad_url'          = 'version.psd1: {0} musi być adresem https:// albo ścieżką (C:\..., \\serwer\udział\...): {1}'
    'managed.version_bad_hash'         = 'version.psd1: {0} nie jest sumą SHA256 (64 cyfry szesnastkowe)'
    'managed.version_bad_group'        = 'version.psd1: niepoprawna nazwa grupy w Groups: ''{0}'''
    'managed.version_groups_not_table' = 'version.psd1: Groups musi podawać każdej grupie jej własne Version, Url i Sha256'
    'managed.cert_next_added'            = 'Źródło wskazuje swój następny certyfikat podpisu ({0}); jemu też ufamy, dopóki źródło się na niego nie przełączy.'
    'managed.cert_switched'              = 'Źródło jest podpisane następnym certyfikatem {0}: teraz to certyfikat tego komputera, zamiast {1}.'
    'managed.cert_next_removed'          = 'Źródło nie wskazuje już następnego certyfikatu podpisu {0}; nie jest już zaufany.'
    'managed.cert_next_invalid'          = 'Następnego certyfikatu podpisu ze źródła nie da się użyć: {0}'
    'managed.cert_change_failed'         = 'Nie udało się zmienić certyfikatu podpisu: {0}. Ten przebieg zostaje przy dotychczasowym; następny spróbuje ponownie.'

    # Secrets for scripts and jobs (Secrets in the configuration, # wmanager-secrets: in a script)
    'managed.secret_name_bad'            = 'wmanager-secrets: ''{0}'' nie jest nazwą sekretu (litery, cyfry i _, na początku litera, najwyżej 64)'
    'managed.secrets_not_table'          = 'Secrets musi być tabelą nazw i wartości (zob. provision.config.example.psd1)'
    'managed.secrets_bad_name'           = 'Secrets: ''{0}'' nie jest nazwą sekretu (litery, cyfry i _, na początku litera, najwyżej 64)'
    'managed.secrets_bad_value'          = 'Secrets: wartość {0} musi być tekstem w jednej linii'
    'managed.secret_missing'             = 'konfiguracja tego komputera nie ma sekretu {0} (Secrets w provision.config.psd1)'
    'managed.script_not_run'             = '{0}: nie uruchomiony: {1}; {2}.'
    'managed.job_not_run'                = 'Job {0}: nie uruchomiony: {1}.'
    'managed.run_as_bad'                 = 'wmanager-run-as: ''{0}'' to ani user, ani system'
    'managed.run_as_twice'               = 'wmanager-run-as występuje więcej niż raz'
    'managed.sessions_failed'            = 'Nie da się odczytać zalogowanych użytkowników, więc skrypty i joby uruchamiane jako użytkownik czekają: {0}'
}
