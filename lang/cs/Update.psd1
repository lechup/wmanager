# Messages of Update-Packages.ps1, the scheduled update (Czech).
@{
    'update.retry_flag_failed' = 'Nelze uložit značku opakování: {0}'
    'update.busy'              = 'Jiný běh wmanager stále probíhá; další pokus při příštím přihlášení.'
    # {0}: wmanager and its version, {1}: update or retry (the job, not translated), {2}: the computer name
    'update.start'             = '{0} {1} na {2}'
    'update.offline'           = 'Nelze se připojit k: {0}. Běh se přeskakuje, další pokus při příštím přihlášení.'
    'update.deferred'          = 'Odloženo do příštího přihlášení: {0}'
    'update.reboot_pending'    = 'Systém čeká na restart; uživatel dostane oznámení.'
    'update.run_failed'        = 'Běh přerušen: {0}'
    'update.summary'           = 'Konec. Upozornění: {0}, chyby: {1}.'
    # Self-update ({0} of self_update, self_installed and {2} of download_failed, self_update_failed: wmanager and its version)
    'update.self_update'                 = '{0} -> wmanager {1}: zdroj správy určuje tuto verzi; stahuje se {2}'
    'update.self_update_group'           = '{0} -> wmanager {1} (skupina {2}): zdroj správy určuje tuto verzi; stahuje se {3}'
    'update.self_update_download_failed' = 'wmanager {0} nelze stáhnout: {1}. Zůstává {2}; další aktualizace to zkusí znovu.'
    'update.self_update_bad_hash'        = 'wmanager {0}: stažený soubor má SHA256 {1}, ale zdroj správy uvádí {2}; neinstaluje se.'
    'update.self_update_not_release'     = 'soubor není verze {0} wmanager (wmanager\VERSION chybí nebo uvádí jinou verzi)'
    'update.self_update_error'           = 'wmanager {0} nelze připravit: {1}'
    'update.self_update_handover'        = 'Tento běh se předává wmanager {0}.'
    'update.self_installed'              = '{0} nainstalován; tento běh pokračuje s ním.'
    'update.self_install_failed'         = '{0} nelze zkopírovat do {1}: {2}'
    'update.self_update_failed'          = 'wmanager {0} se nenainstaloval (návratový kód {1}); tento běh pokračuje s {2} a další aktualizace to zkusí znovu.'
}
