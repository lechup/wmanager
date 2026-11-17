# Messages of Update-Packages.ps1, the scheduled update (German).
@{
    'update.retry_flag_failed' = 'Die Markierung für den erneuten Versuch kann nicht gespeichert werden: {0}'
    'update.busy'              = 'Ein anderer wmanager-Durchlauf ist noch aktiv; neuer Versuch bei der nächsten Anmeldung.'
    # {0}: wmanager and its version, {1}: update or retry (the job, not translated), {2}: the computer name
    'update.start'             = '{0} {1} auf {2}'
    'update.offline'           = 'Keine Verbindung zu: {0}. Der Durchlauf wird übersprungen, neuer Versuch bei der nächsten Anmeldung.'
    'update.deferred'          = 'Bis zur nächsten Anmeldung zurückgestellt: {0}'
    'update.reboot_pending'    = 'Das System wartet auf einen Neustart; der Benutzer erhält eine Benachrichtigung.'
    'update.run_failed'        = 'Durchlauf abgebrochen: {0}'
    'update.summary'           = 'Ende: Warnungen {0}, Fehler {1}.'
    # Self-update ({0} of self_update, self_installed and {2} of download_failed, self_update_failed: wmanager and its version)
    'update.self_update'                 = '{0} -> wmanager {1}: die Verwaltungsquelle nennt diese Version; Download von {2}'
    'update.self_update_group'           = '{0} -> wmanager {1} (Gruppe {2}): die Verwaltungsquelle nennt diese Version; Download von {3}'
    'update.self_update_download_failed' = 'wmanager {0} kann nicht heruntergeladen werden: {1}. {2} bleibt; das nächste Update versucht es erneut.'
    'update.self_update_bad_hash'        = 'wmanager {0}: die heruntergeladene Datei hat SHA256 {1}, die Verwaltungsquelle nennt {2}; nicht installiert.'
    'update.self_update_not_release'     = 'die Datei ist nicht die wmanager-Version {0} (wmanager\VERSION fehlt oder nennt eine andere Version)'
    'update.self_update_error'           = 'wmanager {0} kann nicht vorbereitet werden: {1}'
    'update.self_update_handover'        = 'Dieser Durchlauf wird an wmanager {0} übergeben.'
    'update.self_installed'              = '{0} installiert; dieser Durchlauf geht damit weiter.'
    'update.self_install_failed'         = '{0} kann nicht nach {1} kopiert werden: {2}'
    'update.self_update_failed'          = 'wmanager {0} hat sich nicht installiert (Exitcode {1}); dieser Durchlauf geht mit {2} weiter, das nächste Update versucht es erneut.'
}
