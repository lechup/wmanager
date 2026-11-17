# Messages of Update-Packages.ps1, the scheduled update (Romanian).
@{
    'update.retry_flag_failed' = 'Nu se poate salva marcajul de reîncercare: {0}'
    'update.busy'              = 'O altă rulare wmanager este încă în curs; se va reîncerca la următoarea conectare.'
    # {0}: wmanager and its version, {1}: update or retry (the job, not translated), {2}: the computer name
    'update.start'             = '{0} {1} pe {2}'
    'update.offline'           = 'Nicio conexiune la: {0}. Se omite rularea; se va reîncerca la următoarea conectare.'
    'update.deferred'          = 'Amânat până la următoarea conectare: {0}'
    'update.reboot_pending'    = 'Sistemul așteaptă o repornire; utilizatorul va primi o notificare.'
    'update.run_failed'        = 'Rularea s-a oprit: {0}'
    'update.summary'           = 'Sfârșit: avertismente {0}, erori {1}.'
    # Self-update ({0} of self_update, self_installed and {2} of download_failed, self_update_failed: wmanager and its version)
    'update.self_update'                 = '{0} -> wmanager {1}: sursa de gestionare indică această versiune; se descarcă {2}'
    'update.self_update_group'           = '{0} -> wmanager {1} (grupul {2}): sursa de gestionare indică această versiune; se descarcă {3}'
    'update.self_update_download_failed' = 'Nu se poate descărca wmanager {0}: {1}. Rămâne {2}; următoarea actualizare va reîncerca.'
    'update.self_update_bad_hash'        = 'wmanager {0}: fișierul descărcat are SHA256 {1}, dar sursa de gestionare indică {2}; nu se instalează.'
    'update.self_update_not_release'     = 'fișierul nu este versiunea {0} a wmanager (wmanager\VERSION lipsește sau indică altă versiune)'
    'update.self_update_error'           = 'Nu se poate pregăti wmanager {0}: {1}'
    'update.self_update_handover'        = 'Această rulare este predată către wmanager {0}.'
    'update.self_installed'              = '{0} instalat; această rulare continuă cu el.'
    'update.self_install_failed'         = 'Nu se poate copia {0} în {1}: {2}'
    'update.self_update_failed'          = 'wmanager {0} nu s-a instalat (cod de ieșire {1}); această rulare continuă cu {2}, iar următoarea actualizare va reîncerca.'
}
