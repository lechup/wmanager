# Messages of Update-Packages.ps1, the scheduled update (Dutch).
@{
    'update.retry_flag_failed' = 'Kan de markering voor een nieuwe poging niet opslaan: {0}'
    'update.busy'              = 'Er loopt nog een andere wmanager-uitvoering; nieuwe poging bij de volgende aanmelding.'
    # {0}: wmanager and its version, {1}: update or retry (the job, not translated), {2}: the computer name
    'update.start'             = '{0} {1} op {2}'
    'update.offline'           = 'Geen verbinding met: {0}. Uitvoering overgeslagen, nieuwe poging bij de volgende aanmelding.'
    'update.deferred'          = 'Uitgesteld tot de volgende aanmelding: {0}'
    'update.reboot_pending'    = 'Het systeem wacht op opnieuw opstarten; de gebruiker krijgt een melding.'
    'update.run_failed'        = 'Uitvoering gestopt: {0}'
    'update.summary'           = 'Einde: waarschuwingen {0}, fouten {1}.'
    # Self-update ({0} of self_update, self_installed and {2} of download_failed, self_update_failed: wmanager and its version)
    'update.self_update'                 = '{0} -> wmanager {1}: de beheerbron noemt deze versie; {2} wordt gedownload'
    'update.self_update_group'           = '{0} -> wmanager {1} (groep {2}): de beheerbron noemt deze versie; {3} wordt gedownload'
    'update.self_update_download_failed' = 'Kan wmanager {0} niet downloaden: {1}. {2} blijft; de volgende update probeert het opnieuw.'
    'update.self_update_bad_hash'        = 'wmanager {0}: het gedownloade bestand heeft SHA256 {1}, maar de beheerbron noemt {2}; niet geïnstalleerd.'
    'update.self_update_not_release'     = 'het bestand is niet de wmanager-versie {0} (wmanager\VERSION ontbreekt of noemt een andere versie)'
    'update.self_update_error'           = 'Kan wmanager {0} niet voorbereiden: {1}'
    'update.self_update_handover'        = 'Deze uitvoering wordt overgedragen aan wmanager {0}.'
    'update.self_installed'              = '{0} geïnstalleerd; deze uitvoering gaat daarmee verder.'
    'update.self_install_failed'         = 'Kan {0} niet naar {1} kopiëren: {2}'
    'update.self_update_failed'          = 'wmanager {0} heeft zichzelf niet geïnstalleerd (afsluitcode {1}); deze uitvoering gaat verder met {2} en de volgende update probeert het opnieuw.'
}
