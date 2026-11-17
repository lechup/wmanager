# Messages of Update-Packages.ps1, the scheduled update (Italian).
@{
    'update.retry_flag_failed' = 'Impossibile salvare il contrassegno di nuovo tentativo: {0}'
    'update.busy'              = 'Un''altra esecuzione di wmanager è ancora in corso; nuovo tentativo al prossimo accesso.'
    # {0}: wmanager and its version, {1}: update or retry (the job, not translated), {2}: the computer name
    'update.start'             = '{0} {1} su {2}'
    'update.offline'           = 'Nessuna connessione a: {0}. Esecuzione saltata, nuovo tentativo al prossimo accesso.'
    'update.deferred'          = 'Rimandato al prossimo accesso: {0}'
    'update.reboot_pending'    = 'Il sistema è in attesa di un riavvio; l''utente riceverà una notifica.'
    'update.run_failed'        = 'Esecuzione interrotta: {0}'
    'update.summary'           = 'Fine: avvisi {0}, errori {1}.'
    # Self-update ({0} of self_update, self_installed and {2} of download_failed, self_update_failed: wmanager and its version)
    'update.self_update'                 = '{0} -> wmanager {1}: l''origine di gestione indica questa versione; download di {2}'
    'update.self_update_group'           = '{0} -> wmanager {1} (gruppo {2}): l''origine di gestione indica questa versione; download di {3}'
    'update.self_update_download_failed' = 'Impossibile scaricare wmanager {0}: {1}. Resta {2}; il prossimo aggiornamento riproverà.'
    'update.self_update_bad_hash'        = 'wmanager {0}: il file scaricato ha SHA256 {1}, ma l''origine di gestione indica {2}; non installato.'
    'update.self_update_not_release'     = 'il file non è la versione {0} di wmanager (wmanager\VERSION manca o indica un''altra versione)'
    'update.self_update_error'           = 'Impossibile preparare wmanager {0}: {1}'
    'update.self_update_handover'        = 'Questa esecuzione passa a wmanager {0}.'
    'update.self_installed'              = '{0} installato; questa esecuzione prosegue con esso.'
    'update.self_install_failed'         = 'Impossibile copiare {0} in {1}: {2}'
    'update.self_update_failed'          = 'wmanager {0} non si è installato (codice di uscita {1}); questa esecuzione prosegue con {2} e il prossimo aggiornamento riproverà.'
}
