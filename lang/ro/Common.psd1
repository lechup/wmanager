# Messages of lib\Common.ps1 and the shared answers and step names (Romanian).
@{
    'common.yes_words'              = 'd|da'
    'common.no_words'               = 'n|nu'
    'common.hint_default_no'        = '[d/N]'
    'common.hint_default_yes'       = '[D/n]'

    'step.chocolatey'               = 'Chocolatey'
    'step.debloat'                  = 'Curățare sistem'
    'step.default_browser'          = 'Browser implicit'
    'step.schedule'                 = 'Planificator de activități'
    'step.group_jobs'               = 'Lucrările grupurilor'
    'step.packages'                 = 'Pachete'
    'step.privacy'                  = 'Confidențialitate'
    'step.group_scripts'            = 'Scripturile grupurilor'
    'step.notify_settings'          = 'Setări pentru notificări'

    'common.config_missing'         = 'Fișierul de configurare nu a fost găsit: {0}'
    'common.mgmt_source_https'      = "Management.Source: este permisă doar o adresă https:// ('{0}')"
    'common.mgmt_source_full_path'  = "Management.Source: indicați folderul printr-o cale completă ('{0}')"
    'common.mgmt_source_id'         = 'Management.SourceId: identificatorul sursei lipsește sau nu este valid (tools/publish.sh îl scrie în source-id.txt)'
    'common.mgmt_certificate_name'  = "Management.Certificate: doar numele unui fișier aflat lângă fișierul de configurare, fără cale ('{0}')"
    'common.step_failed'            = "Etapa '{0}' s-a oprit: {1}"
    'common.registry_hive_unsupported' = 'Ramură de registry neacceptată: {0}'
    'common.journal_not_saved'      = 'Jurnalul de anulare: starea {0} nu a fost salvată (restaurarea nu va anula această modificare): {1}'
    'common.registry_set_failed'    = 'Nu s-a putut seta {0} : {1}'
    'common.profile_hive_load_failed' = 'Nu se poate încărca registry-ul profilului {0}'
    'common.profile_error'          = 'Eroare la profilul {0}: {1}'
    'common.profile_hive_unload_failed' = 'Nu s-a putut descărca registry-ul profilului {0} (HKU\{1}); o repornire a computerului va rezolva problema.'
    'common.root_is_link'           = 'este o legătură'
    'common.root_not_folder'        = 'nu este un folder'
    'common.root_foreign_owner'     = 'are un proprietar străin ({0})'
    'common.root_moved_aside'       = '{0} {1}; se mută în {2} și se creează din nou.'
    'common.root_moved_backups'     = 'Copiile de rezervă și jurnalul de anulare au rămas în {0}\state\backup și nu vor fi folosite; Restore-Backup.ps1 nu va anula rulările anterioare.'
    'common.icacls_setowner_failed' = 'icacls /setowner a returnat {0} pentru {1}'
    'common.acl_failed'             = 'Nu s-au putut seta permisiunile pentru {0} : {1}'
    'common.icacls_reset_failed'    = 'icacls /reset a returnat {0} pentru {1}'
    'common.acl_extra_access'       = 'au acces și alții: {0}'
    'common.secure_failed'          = 'Nu s-a putut securiza {0} : {1}'
    'common.loki_rejected'          = 'Loki a respins {0} (HTTP {1}), mutat în outbox\rejected: {2}'
    'common.loki_send_failed'       = 'Trimiterea către Loki a eșuat ({0}), se va reîncerca la următoarea rulare: {1}'
    'common.healthchecks_failed'    = 'Ping-ul Healthchecks ({0}) a eșuat: {1}'
    'common.answer_yes_no'        = 'Răspundeți cu d sau n.'
    'common.unknown_language'     = 'Limbă necunoscută ''{0}''; se folosește {1}. Disponibile: {2}.'
    'common.timed_out'            = 'niciun rezultat după {0} s; așteptarea a fost oprită'

    'common.company_question'       = 'Acest dosar conține configurațiile mai multor firme. Pentru care este acest calculator?'
    'common.company_prompt'         = 'Firma (număr sau nume)'
    'common.company_unknown'        = 'Introduceți un număr de la 1 la {0} sau numele firmei.'
    'common.company_config'         = 'Configurația firmei {0}: {1}'
    'common.company_no_console'     = '{0} conține configurațiile mai multor firme și nu este nimeni la consolă care să aleagă una; indicați-o cu -ConfigPath.'
}
