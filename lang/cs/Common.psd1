# Messages of lib\Common.ps1 and the shared answers and step names (Czech).
@{
    'common.yes_words'              = 'a|ano'
    'common.no_words'               = 'n|ne'
    'common.hint_default_no'        = '[a/N]'
    'common.hint_default_yes'       = '[A/n]'

    'step.chocolatey'               = 'Chocolatey'
    'step.debloat'                  = 'Pročištění systému'
    'step.default_browser'          = 'Výchozí prohlížeč'
    'step.schedule'                 = 'Plánovač úloh'
    'step.group_jobs'               = 'Úkoly skupin'
    'step.packages'                 = 'Balíčky'
    'step.privacy'                  = 'Ochrana osobních údajů'
    'step.group_scripts'            = 'Skripty skupin'
    'step.notify_settings'          = 'Nastavení oznámení'

    'common.config_missing'         = 'Konfigurační soubor nenalezen: {0}'
    'common.mgmt_source_https'      = "Management.Source: povolena je jen adresa https:// ('{0}')"
    'common.mgmt_source_full_path'  = "Management.Source: zadejte složku jako úplnou cestu ('{0}')"
    'common.mgmt_source_id'         = 'Management.SourceId: chybí nebo je neplatný identifikátor zdroje (tools/publish.sh ho zapisuje do source-id.txt)'
    'common.mgmt_certificate_name'  = "Management.Certificate: jen název souboru vedle konfiguračního souboru, bez cesty ('{0}')"
    'common.step_failed'            = "Krok '{0}' přerušen: {1}"
    'common.registry_hive_unsupported' = 'Nepodporovaný podregistr: {0}'
    'common.journal_not_saved'      = 'Deník změn: stav {0} nebyl uložen (obnovení ho nevrátí): {1}'
    'common.registry_set_failed'    = 'Nepodařilo se nastavit {0} : {1}'
    'common.profile_hive_load_failed' = 'Nelze načíst registr profilu {0}'
    'common.profile_error'          = 'Chyba u profilu {0}: {1}'
    'common.profile_hive_unload_failed' = 'Nepodařilo se uvolnit registr profilu {0} (HKU\{1}); pomůže restart počítače.'
    'common.root_is_link'           = 'je odkaz'
    'common.root_not_folder'        = 'není složka'
    'common.root_foreign_owner'     = 'má cizího vlastníka ({0})'
    'common.root_moved_aside'       = '{0} {1}; přesune se do {2} a vytvoří se znovu.'
    'common.root_moved_backups'     = 'Zálohy a deník změn zůstaly v {0}\state\backup a nebudou použity; Restore-Backup.ps1 nevrátí změny dřívějších běhů.'
    'common.icacls_setowner_failed' = 'icacls /setowner vrátil {0} pro {1}'
    'common.acl_failed'             = 'Nepodařilo se nastavit oprávnění {0} : {1}'
    'common.icacls_reset_failed'    = 'icacls /reset vrátil {0} pro {1}'
    'common.acl_extra_access'       = 'přístup mají i další: {0}'
    'common.secure_failed'          = 'Nepodařilo se zabezpečit {0} : {1}'
    'common.loki_rejected'          = 'Loki odmítl {0} (HTTP {1}), přesunuto do outbox\rejected: {2}'
    'common.loki_send_failed'       = 'Odeslání do Loki se nezdařilo ({0}), další pokus při příštím běhu: {1}'
    'common.healthchecks_failed'    = 'Ping Healthchecks ({0}) se nezdařil: {1}'
    'common.answer_yes_no'        = 'Odpovězte a nebo n.'
    'common.unknown_language'     = 'Neznámý jazyk ''{0}''; používá se {1}. K dispozici: {2}.'
    'common.timed_out'            = 'žádný výsledek po {0} s; čekání ukončeno'
}
