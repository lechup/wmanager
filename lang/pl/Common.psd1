# Messages of lib\Common.ps1 and the shared answers and step names (Polish).
@{
    'common.yes_words'              = 't|tak'
    'common.no_words'               = 'n|nie'
    'common.hint_default_no'        = '[t/N]'
    'common.hint_default_yes'       = '[T/n]'

    'step.chocolatey'               = 'Chocolatey'
    'step.debloat'                  = 'Debloat'
    'step.default_browser'          = 'Domyślna przeglądarka'
    'step.schedule'                 = 'Harmonogram zadań'
    'step.group_jobs'               = 'Joby grup'
    'step.jobs_times'               = 'Godziny zadań'
    'step.event_tasks'              = 'Zadania skryptów zdarzeń'
    'step.packages'                 = 'Paczki'
    'step.privacy'                  = 'Prywatność'
    'step.group_scripts'            = 'Skrypty grup'
    'step.notify_settings'          = 'Ustawienia dla powiadomień'

    'common.config_missing'         = 'Brak pliku konfiguracji: {0}'
    'common.mgmt_source_https'      = "Management.Source: dozwolony jest tylko adres https:// ('{0}')"
    'common.mgmt_source_full_path'  = "Management.Source: folder trzeba podać pełną ścieżką ('{0}')"
    'common.mgmt_source_id'         = 'Management.SourceId: brak albo niepoprawny identyfikator źródła (zapisuje go tools/publish.sh w source-id.txt)'
    'common.mgmt_certificate_name'  = "Management.Certificate: sama nazwa pliku obok pliku konfiguracji, bez ścieżki ('{0}')"
    'common.step_failed'            = "Etap '{0}' przerwany: {1}"
    'common.registry_hive_unsupported' = 'Nieobsługiwana gałąź rejestru: {0}'
    'common.journal_not_saved'      = 'Dziennik zmian: nie zapisano stanu {0} (przywracanie go nie cofnie): {1}'
    'common.registry_set_failed'    = 'Nie udało się ustawić {0} : {1}'
    'common.profile_hive_load_failed' = 'Nie mogę wczytać rejestru profilu {0}'
    'common.profile_error'          = 'Błąd przy profilu {0}: {1}'
    'common.profile_hive_unload_failed' = 'Nie udało się odłączyć rejestru profilu {0} (HKU\{1}); pomoże restart komputera.'
    'common.root_is_link'           = 'jest dowiązaniem'
    'common.root_not_folder'        = 'nie jest folderem'
    'common.root_foreign_owner'     = 'ma obcego właściciela ({0})'
    'common.root_moved_aside'       = '{0} {1}; przenoszę do {2} i tworzę od nowa.'
    'common.root_moved_backups'     = 'Kopie i dziennik zmian zostały w {0}\state\backup i nie będą używane; Restore-Backup.ps1 nie cofnie wcześniejszych przebiegów.'
    'common.icacls_setowner_failed' = 'icacls /setowner zwrócił {0} dla {1}'
    'common.acl_failed'             = 'Nie udało się ustawić uprawnień {0} : {1}'
    'common.icacls_reset_failed'    = 'icacls /reset zwrócił {0} dla {1}'
    'common.acl_extra_access'       = 'dostęp mają też: {0}'
    'common.secure_failed'          = 'Nie udało się zabezpieczyć {0} : {1}'
    'common.loki_rejected'          = 'Loki odrzucił {0} (HTTP {1}), przeniesiono do outbox\rejected: {2}'
    'common.loki_send_failed'       = 'Wysyłka do Loki nie powiodła się ({0}), spróbuję przy następnym przebiegu: {1}'
    'common.healthchecks_failed'    = 'Ping Healthchecks ({0}) nie powiódł się: {1}'
    'common.answer_yes_no'        = 'Odpowiedz t albo n.'
    'common.unknown_language'     = 'Nieznany język ''{0}''; używam {1}. Dostępne: {2}.'
    'common.timed_out'            = 'brak wyniku po {0} s; przerwano oczekiwanie'

    'common.company_question'       = 'Ten folder zawiera konfiguracje kilku firm. Dla której jest ten komputer?'
    'common.company_prompt'         = 'Firma (numer albo nazwa)'
    'common.company_unknown'        = 'Wpisz numer od 1 do {0} albo nazwę firmy.'
    'common.company_config'         = 'Konfiguracja firmy {0}: {1}'
    'common.company_no_console'     = '{0} zawiera konfiguracje kilku firm, a przy konsoli nie ma nikogo, kto wybierze jedną; podaj ją w -ConfigPath.'

    # Accounts: a separate administrator, the person signed in a standard user (lib\Accounts.ps1)
    'step.accounts'                              = 'Konta'
}
