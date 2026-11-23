# Messages of lib\Managed.ps1: the management source, group scripts and jobs (German).
@{
    'managed.manifest_no_source_id'      = 'Manifest: Quellkennung (SourceId) fehlt oder ist ungültig'
    'managed.manifest_other_source'      = 'Manifest gehört zu einer anderen Quelle ({0}), nicht zu {1} aus der Konfiguration'
    'managed.manifest_no_serial'         = 'Manifest: Seriennummer (Serial) fehlt oder ist ungültig'
    'managed.manifest_no_files'          = 'Manifest: keine Dateiliste (Files)'
    'managed.manifest_bad_path'          = "Manifest: unzulässiger Pfad '{0}'"
    'managed.manifest_lists_itself'      = 'Manifest: Es darf sich nicht selbst auflisten'
    'managed.manifest_bad_hash'          = "Manifest: ungültiger SHA256-Hash für '{0}'"
    'managed.manifest_duplicate_path'    = "Manifest: Pfad '{0}' kommt zweimal vor"

    'managed.groups_unknown_key'         = "groups.psd1: unbekannter Schlüssel '{0}' (zulässig: Default, Computers)"
    'managed.groups_computers_not_table' = "groups.psd1: Computers muss eine Tabelle @{{ 'NAME' = @('Gruppe') }} sein"
    'managed.groups_empty_computer'      = 'groups.psd1: leerer Computername'
    'managed.groups_bad_group'           = "groups.psd1: ungültiger Gruppenname '{0}'"

    'managed.common_list'                = 'gemeinsame Liste'
    'managed.package_group_replaces'     = 'Paket {0}: Der Eintrag der Gruppe {1} ersetzt den Eintrag der gemeinsamen Liste.'
    'managed.package_conflict'           = "Paket {0} ist in '{1}' und '{2}' unterschiedlich beschrieben; der Eintrag aus '{1}' wird verwendet."
    'managed.unknown_period'             = "unbekannte Häufigkeit '{0}'"

    'managed.cert_missing'               = 'Signaturzertifikat nicht gefunden: {0}'
    'managed.cert_private_key'           = '{0} enthält einen privaten Schlüssel; auf die Computer gehört nur die öffentliche .cer'
    'managed.cert_is_ca'                 = '{0} ist das Zertifikat einer Zertifizierungsstelle (CA); wmanager fügt es nicht zu den vertrauenswürdigen hinzu'
    'managed.cert_not_code_signing'      = '{0} ist kein Codesignaturzertifikat (Verwendungszweck Code Signing fehlt)'
    'managed.cert_expired'               = 'Das Signaturzertifikat ist am {0} abgelaufen; nur Signaturen mit Zeitstempel sind noch gültig.'
    'managed.cert_expiring'              = 'Das Signaturzertifikat läuft am {0} ab; bereiten Sie ein neues vor.'
    'managed.cert_previous_removed'      = 'Das vorherige wmanager-Signaturzertifikat wurde aus den vertrauenswürdigen Stammzertifizierungsstellen entfernt ({0}).'
    'managed.cert_added'                 = 'Das wmanager-Signaturzertifikat wurde den vertrauenswürdigen Stammzertifizierungsstellen des Computers hinzugefügt ({0}).'
    'managed.signature_invalid'          = 'ungültige Signatur des Manifests ({0}): {1}'
    'managed.signature_other_cert'       = 'Manifest mit einem anderen Zertifikat ({0}) signiert als dem aus der Konfiguration ({1})'

    'managed.saved_copy_invalid'         = 'Die gespeicherte Kopie der Verwaltungsquelle ist ungültig: {0}'
    'managed.file_error'                 = '{0}: {1}'
    'managed.source_unreachable'         = 'Verwaltungsquelle nicht erreichbar ({0}): {1}'
    'managed.manifest_older'             = 'Manifest {0} ist älter als das zuvor angenommene {1}'
    'managed.manifest_same_serial'       = 'Manifest hat dieselbe Nummer {0} wie das zuvor angenommene, aber andere Dateien'
    'managed.source_unchanged'           = 'Verwaltungsquelle unverändert (Manifest {0}).'
    'managed.download_failed'            = '{0} konnte nicht heruntergeladen werden: {1}'
    'managed.hash_mismatch'              = '{0} hat einen anderen SHA256-Hash als im Manifest (die Datei wurde geändert oder ist noch nicht veröffentlicht)'
    'managed.swap_failed'                = '{0} kann nicht ersetzt werden (verwendet ein Programm Dateien aus diesem Ordner?): {1}'
    'managed.manifest_accepted'          = 'Verwaltungsquelle: Manifest {0} angenommen ({1} Dateien).'

    'managed.no_source'                  = 'Kein Management.Source in der Konfiguration.'
    'managed.new_version_rejected'       = 'Neue Version aus der Verwaltungsquelle abgelehnt: {0}'
    'managed.no_verified_copy'           = 'Keine geprüfte Version der Verwaltungsquelle (sie konnte nicht heruntergeladen werden und es gibt keine Kopie).'
    'managed.using_last_copy'            = 'Die letzte geprüfte Kopie der Verwaltungsquelle wird verwendet (Manifest {0}).'
    'managed.computer_groups'            = 'Gruppen des Computers {0}: {1}.'
    'managed.computer_no_groups'         = 'Computer {0} gehört zu keiner Gruppe (nur gemeinsame Liste).'
    'managed.group_no_files'             = 'Gruppe {0} hat keine Dateien in der Verwaltungsquelle.'
    'managed.source_info'                = 'Verwaltungsquelle: {0} ({1}), Zertifikat {2} ({3}).'

    'managed.scripts_section'            = '--- Gruppenskripts ---'
    'managed.no_scripts'                 = 'Keine Skripts für die Gruppen dieses Computers.'
    'managed.script_unchanged'           = '{0}: unverändert.'
    'managed.script_starting'            = '{0}: wird gestartet.'
    'managed.retry_next_update'          = 'neuer Versuch bei der nächsten Aktualisierung'
    'managed.retry_after_hours'          = 'neuer Versuch in {0} h oder nach einer Änderung des Skripts'
    'managed.script_timeout'             = '{0}: Zeitlimit überschritten ({1} min), abgebrochen; {2}.'
    'managed.script_exit_code'           = '{0}: mit Exitcode {1} beendet; {2}.'
    'managed.script_done_reboot'         = '{0}: fertig, ein Neustart ist erforderlich.'
    'managed.script_done'                = '{0}: fertig.'
    'managed.scripts_state_failed'       = 'Der Zustand der Skripts kann nicht gespeichert werden: {0}'

    'managed.jobs_state_failed'          = 'Der Zustand der Jobs kann nicht gespeichert werden: {0}'
    'managed.job_starting'               = 'Job {0} ({1}): wird gestartet.'
    'managed.job_timeout'                = 'Job {0}: Zeitlimit überschritten ({1} min), abgebrochen.'
    'managed.job_exit_code'              = 'Job {0}: mit Exitcode {1} beendet.'
    'managed.job_done'                   = 'Job {0}: fertig.'
    # version.psd1 ({0}: the entry, e.g. Groups.test.Url; {1}: its value)
    'managed.version_unknown_key'      = 'version.psd1: unbekannter Schlüssel ''{0}'' (zulässig: Version, Url, Sha256, Groups)'
    'managed.version_missing'          = 'version.psd1: {0} fehlt (eine Version braucht Version, Url und Sha256)'
    'managed.version_bad_tag'          = 'version.psd1: {0} ist keine wmanager-Version wie v0.2.0: {1}'
    'managed.version_bad_url'          = 'version.psd1: {0} muss eine https://-Adresse oder ein Pfad sein (C:\..., \\server\share\...): {1}'
    'managed.version_bad_hash'         = 'version.psd1: {0} ist kein SHA256-Hash (64 Hexadezimalziffern)'
    'managed.version_bad_group'        = 'version.psd1: ungültiger Gruppenname in Groups: ''{0}'''
    'managed.version_groups_not_table' = 'version.psd1: Groups muss jeder Gruppe eigene Version, Url und Sha256 geben'
    'managed.cert_next_added'            = 'Die Quelle nennt ihr nächstes Signaturzertifikat ({0}); ihm wird ebenfalls vertraut, bis die Quelle darauf umstellt.'
    'managed.cert_switched'              = 'Die Quelle ist mit dem nächsten Zertifikat {0} signiert: Es ist jetzt das Zertifikat dieses Computers, anstelle von {1}.'
    'managed.cert_next_removed'          = 'Die Quelle nennt das nächste Signaturzertifikat {0} nicht mehr; ihm wird nicht mehr vertraut.'
    'managed.cert_next_invalid'          = 'Das nächste Signaturzertifikat der Quelle ist nicht verwendbar: {0}'
    'managed.cert_change_failed'         = 'Das Signaturzertifikat konnte nicht gewechselt werden: {0}. Dieser Lauf behält das bisherige; der nächste versucht es erneut.'

    # Secrets for scripts and jobs (Secrets in the configuration, # wmanager-secrets: in a script)
    'managed.secret_name_bad'            = 'wmanager-secrets: ''{0}'' ist kein Name eines Geheimnisses (Buchstaben, Ziffern und _, mit einem Buchstaben am Anfang, höchstens 64)'
    'managed.secrets_not_table'          = 'Secrets muss eine Tabelle aus Namen und Werten sein (siehe provision.config.example.psd1)'
    'managed.secrets_bad_name'           = 'Secrets: ''{0}'' ist kein Name eines Geheimnisses (Buchstaben, Ziffern und _, mit einem Buchstaben am Anfang, höchstens 64)'
    'managed.secrets_bad_value'          = 'Secrets: Der Wert von {0} muss Text in einer Zeile sein'
    'managed.secret_missing'             = 'die Konfiguration dieses Computers hat kein Geheimnis {0} (Secrets in provision.config.psd1)'
    'managed.script_not_run'             = '{0}: nicht ausgeführt: {1}; {2}.'
    'managed.job_not_run'                = 'Job {0}: nicht ausgeführt: {1}.'
}
