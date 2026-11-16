# Messages of lib\Common.ps1 and the shared answers and step names (German).
@{
    'common.yes_words'              = 'j|ja'
    'common.no_words'               = 'n|nein'
    'common.hint_default_no'        = '[j/N]'
    'common.hint_default_yes'       = '[J/n]'

    'step.chocolatey'               = 'Chocolatey'
    'step.debloat'                  = 'Bereinigung'
    'step.default_browser'          = 'Standardbrowser'
    'step.schedule'                 = 'Aufgabenplanung'
    'step.group_jobs'               = 'Gruppenjobs'
    'step.packages'                 = 'Pakete'
    'step.privacy'                  = 'Datenschutz'
    'step.group_scripts'            = 'Gruppenskripts'
    'step.notify_settings'          = 'Benachrichtigungseinstellungen'

    'common.config_missing'         = 'Konfigurationsdatei nicht gefunden: {0}'
    'common.mgmt_source_https'      = "Management.Source: Nur eine https://-Adresse ist zulässig ('{0}')"
    'common.mgmt_source_full_path'  = "Management.Source: Geben Sie den Ordner als vollständigen Pfad an ('{0}')"
    'common.mgmt_source_id'         = 'Management.SourceId: Quellkennung fehlt oder ist ungültig (tools/publish.sh schreibt sie in source-id.txt)'
    'common.mgmt_certificate_name'  = "Management.Certificate: Nur ein Dateiname neben der Konfigurationsdatei, ohne Pfad ('{0}')"
    'common.step_failed'            = "Schritt '{0}' abgebrochen: {1}"
    'common.registry_hive_unsupported' = 'Nicht unterstützte Registrierungsstruktur: {0}'
    'common.journal_not_saved'      = 'Änderungsjournal: Der Zustand von {0} wurde nicht gespeichert (die Wiederherstellung macht ihn nicht rückgängig): {1}'
    'common.registry_set_failed'    = '{0} konnte nicht festgelegt werden: {1}'
    'common.profile_hive_load_failed' = 'Die Registrierung des Profils {0} kann nicht geladen werden'
    'common.profile_error'          = 'Fehler beim Profil {0}: {1}'
    'common.profile_hive_unload_failed' = 'Die Registrierung des Profils {0} konnte nicht entladen werden (HKU\{1}); ein Neustart des Computers hilft.'
    'common.root_is_link'           = 'ist ein Link'
    'common.root_not_folder'        = 'ist kein Ordner'
    'common.root_foreign_owner'     = 'hat einen fremden Besitzer ({0})'
    'common.root_moved_aside'       = '{0} {1}; wird nach {2} verschoben und neu angelegt.'
    'common.root_moved_backups'     = 'Sicherungen und das Änderungsjournal sind in {0}\state\backup verblieben und werden nicht verwendet; Restore-Backup.ps1 macht frühere Durchläufe nicht rückgängig.'
    'common.icacls_setowner_failed' = 'icacls /setowner hat {0} für {1} zurückgegeben'
    'common.acl_failed'             = 'Die Berechtigungen von {0} konnten nicht festgelegt werden: {1}'
    'common.icacls_reset_failed'    = 'icacls /reset hat {0} für {1} zurückgegeben'
    'common.acl_extra_access'       = 'auch andere haben Zugriff: {0}'
    'common.secure_failed'          = '{0} konnte nicht geschützt werden: {1}'
    'common.loki_rejected'          = 'Loki hat {0} abgelehnt (HTTP {1}), nach outbox\rejected verschoben: {2}'
    'common.loki_send_failed'       = 'Senden an Loki fehlgeschlagen ({0}), neuer Versuch beim nächsten Durchlauf: {1}'
    'common.healthchecks_failed'    = 'Healthchecks-Ping ({0}) fehlgeschlagen: {1}'
    'common.answer_yes_no'        = 'Antworten Sie mit j oder n.'
    'common.unknown_language'     = 'Unbekannte Sprache ''{0}''; verwendet wird {1}. Verfügbar: {2}.'
    'common.timed_out'            = 'kein Ergebnis nach {0} s; Warten abgebrochen'
}
