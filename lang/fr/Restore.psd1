# Messages of Restore-Backup.ps1 (French).
@{
    'restore.no_backup'                 = 'Aucune sauvegarde dans {0} : wmanager n''a pas été exécuté ici.'
    'restore.lock_wait'                 = 'Une autre exécution de wmanager est en cours (p. ex. travaux de groupe) ; attente de 10 minutes maximum...'
    'restore.lock_busy'                 = 'Une autre exécution de wmanager est toujours en cours. Réessayez dans un instant.'
    'restore.journal_read_failed'       = 'Impossible de lire le journal d''annulation : {0}'
    'restore.start'                     = '{0} : restauration sur {1}. Journal d''annulation : {2} valeur(s) de l''ordinateur, {3} valeur(s) des utilisateurs ; sauvegardes : {4}.'
    'restore.confirm'                   = 'Annuler les modifications de wmanager ?'
    'restore.cancelled'                 = 'Annulé, rien n''a été modifié.'
    'restore.profile_not_found'         = 'Le profil {0} n''existe pas ou n''a pas pu être chargé ; ses paramètres n''ont pas été restaurés.'
    'restore.registry_summary'          = 'Registre : {0} valeur(s) restaurée(s) sur {1}.'
    'restore.store_apps_removed'        = 'Applications du Store supprimées depuis la sauvegarde {0} ({1}) ; réinstallez-les depuis le Store si nécessaire :'
    'restore.onedrive_removed'          = 'OneDrive a été désinstallé ; si vous en avez besoin, réinstallez-le depuis le site de Microsoft.'
    'restore.confirm_disable_tasks'     = 'Désactiver les tâches wmanager ? Sinon, la mise à jour planifiée supprimera de nouveau les applications et modifiera de nouveau les paramètres.'
    'restore.tasks_disabled'            = 'Tâches wmanager désactivées ({0}).'
    'restore.tasks_kept'                = 'Les tâches wmanager restent activées ; la mise à jour planifiée appliquera de nouveau les paramètres.'
    'restore.certificate_removed'       = 'Certificat de signature wmanager supprimé du magasin de confiance ({0}).'
    'restore.certificate_remove_failed' = 'Impossible de supprimer le certificat de signature wmanager du magasin de confiance : {0}'
    'restore.stopped'                   = 'Restauration interrompue : {0}'
    'restore.summary'                   = 'Terminé : avertissements {0}, erreurs {1}. Journal : {2}'
    'restore.finished_with_errors'      = 'Restauration terminée avec des erreurs. Consultez le journal ci-dessus.'
    'restore.finished'                  = 'Restauration terminée. Redémarrez l''ordinateur pour que les paramètres prennent effet.'

    # Accounts: a separate administrator, the person signed in a standard user (lib\Accounts.ps1)
    'restore.confirm_admin_again'                = 'Rendre les droits d''administrateur aux personnes que l''installation a rendues utilisateurs standard ?'
    'restore.admin_again'                        = '{0} est de nouveau administrateur.'
    'restore.admin_again_failed'                 = '{0} n''a pas pu redevenir administrateur : {1}'
    'restore.admin_account_stays'                = 'Le compte administrateur {0} reste (de nouveau visible sur l''écran de connexion) ; supprimez-le à la main s''il ne sert plus.'
}
