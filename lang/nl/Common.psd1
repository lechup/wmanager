# Messages of lib\Common.ps1 and the shared answers and step names (Dutch).
@{
    'common.yes_words'              = 'j|ja'
    'common.no_words'               = 'n|nee'
    'common.hint_default_no'        = '[j/N]'
    'common.hint_default_yes'       = '[J/n]'

    'step.chocolatey'               = 'Chocolatey'
    'step.debloat'                  = 'Opschonen'
    'step.default_browser'          = 'Standaardbrowser'
    'step.schedule'                 = 'Taakplanner'
    'step.group_jobs'               = 'Groepsopdrachten'
    'step.jobs_times'               = 'Tijden van de taken'
    'step.event_tasks'              = 'Taken van de gebeurtenisscripts'
    'step.packages'                 = 'Pakketten'
    'step.privacy'                  = 'Privacy'
    'step.group_scripts'            = 'Groepsscripts'
    'step.notify_settings'          = 'Instellingen voor meldingen'

    'common.config_missing'         = 'Configuratiebestand niet gevonden: {0}'
    'common.mgmt_source_https'      = "Management.Source: alleen een https://-adres is toegestaan ('{0}')"
    'common.mgmt_source_full_path'  = "Management.Source: geef de map op als volledig pad ('{0}')"
    'common.mgmt_source_id'         = 'Management.SourceId: bron-ID ontbreekt of is ongeldig (tools/publish.sh schrijft deze naar source-id.txt)'
    'common.mgmt_certificate_name'  = "Management.Certificate: alleen een bestandsnaam naast het configuratiebestand, zonder pad ('{0}')"
    'common.step_failed'            = "Stap '{0}' gestopt: {1}"
    'common.registry_hive_unsupported' = 'Niet-ondersteunde registercomponent: {0}'
    'common.journal_not_saved'      = 'Wijzigingsjournaal: de status van {0} is niet opgeslagen (herstellen maakt dit niet ongedaan): {1}'
    'common.registry_set_failed'    = 'Kan {0} niet instellen: {1}'
    'common.profile_hive_load_failed' = 'Kan het register van profiel {0} niet laden'
    'common.profile_error'          = 'Fout bij profiel {0}: {1}'
    'common.profile_hive_unload_failed' = 'Kan het register van profiel {0} niet loskoppelen (HKU\{1}); opnieuw opstarten van de computer lost dit op.'
    'common.root_is_link'           = 'is een koppeling'
    'common.root_not_folder'        = 'is geen map'
    'common.root_foreign_owner'     = 'heeft een onverwachte eigenaar ({0})'
    'common.root_moved_aside'       = '{0} {1}; wordt verplaatst naar {2} en opnieuw aangemaakt.'
    'common.root_moved_backups'     = 'Back-ups en het wijzigingsjournaal zijn achtergebleven in {0}\state\backup en worden niet gebruikt; Restore-Backup.ps1 maakt eerdere uitvoeringen niet ongedaan.'
    'common.icacls_setowner_failed' = 'icacls /setowner retourneerde {0} voor {1}'
    'common.acl_failed'             = 'Kan de machtigingen van {0} niet instellen: {1}'
    'common.icacls_reset_failed'    = 'icacls /reset retourneerde {0} voor {1}'
    'common.acl_extra_access'       = 'ook anderen hebben toegang: {0}'
    'common.secure_failed'          = 'Kan {0} niet beveiligen: {1}'
    'common.loki_rejected'          = 'Loki heeft {0} geweigerd (HTTP {1}), verplaatst naar outbox\rejected: {2}'
    'common.loki_send_failed'       = 'Verzenden naar Loki is mislukt ({0}), nieuwe poging bij de volgende uitvoering: {1}'
    'common.healthchecks_failed'    = 'Healthchecks-ping ({0}) is mislukt: {1}'
    'common.answer_yes_no'        = 'Antwoord met j of n.'
    'common.unknown_language'     = 'Onbekende taal ''{0}''; {1} wordt gebruikt. Beschikbaar: {2}.'
    'common.timed_out'            = 'geen resultaat na {0} s; wachten gestopt'

    'common.company_question'       = 'Deze map bevat de configuraties van meerdere bedrijven. Voor welk bedrijf is deze computer?'
    'common.company_prompt'         = 'Bedrijf (nummer of naam)'
    'common.company_unknown'        = 'Typ een nummer van 1 tot {0}, of de naam van het bedrijf.'
    'common.company_config'         = 'Configuratie van {0}: {1}'
    'common.company_no_console'     = '{0} bevat de configuraties van meerdere bedrijven en er is niemand aan de console om er een te kiezen; geef die op met -ConfigPath.'

    # Accounts: a separate administrator, the person signed in a standard user (lib\Accounts.ps1)
    'step.accounts'                              = 'Accounts'
}
