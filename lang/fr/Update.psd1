# Messages of Update-Packages.ps1, the scheduled update (French).
@{
    'update.retry_flag_failed' = 'Impossible d''enregistrer le marqueur de nouvelle tentative : {0}'
    'update.busy'              = 'Une autre exécution de wmanager est toujours en cours ; nouvelle tentative à la prochaine connexion.'
    # {0}: wmanager and its version, {1}: update or retry (the job, not translated), {2}: the computer name
    'update.start'             = '{0} {1} sur {2}'
    'update.offline'           = 'Pas de connexion à : {0}. Exécution ignorée, nouvelle tentative à la prochaine connexion.'
    'update.deferred'          = 'Reporté à la prochaine connexion : {0}'
    'update.reboot_pending'    = 'Le système attend un redémarrage ; l''utilisateur recevra une notification.'
    'update.run_failed'        = 'Exécution interrompue : {0}'
    'update.summary'           = 'Fin : avertissements {0}, erreurs {1}.'
    # Self-update ({0} of self_update, self_installed and {2} of download_failed, self_update_failed: wmanager and its version)
    'update.self_update'                 = '{0} -> wmanager {1} : la source de gestion indique cette version ; téléchargement de {2}'
    'update.self_update_group'           = '{0} -> wmanager {1} (groupe {2}) : la source de gestion indique cette version ; téléchargement de {3}'
    'update.self_update_download_failed' = 'Impossible de télécharger wmanager {0} : {1}. {2} reste en place ; la prochaine mise à jour réessaiera.'
    'update.self_update_bad_hash'        = 'wmanager {0} : le fichier téléchargé a le SHA256 {1}, mais la source de gestion indique {2} ; non installé.'
    'update.self_update_not_release'     = 'le fichier n''est pas la version {0} de wmanager (wmanager\VERSION manque ou indique une autre version)'
    'update.self_update_error'           = 'Impossible de préparer wmanager {0} : {1}'
    'update.self_update_handover'        = 'Cette exécution est confiée à wmanager {0}.'
    'update.self_installed'              = '{0} installé ; cette exécution continue avec lui.'
    'update.self_install_failed'         = 'Impossible de copier {0} dans {1} : {2}'
    'update.self_update_failed'          = 'wmanager {0} ne s''est pas installé (code de sortie {1}) ; cette exécution continue avec {2}, et la prochaine mise à jour réessaiera.'
}
