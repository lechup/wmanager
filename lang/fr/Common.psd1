# Messages of lib\Common.ps1 and the shared answers and step names (French).
@{
    'common.yes_words'              = 'o|oui'
    'common.no_words'               = 'n|non'
    'common.hint_default_no'        = '[o/N]'
    'common.hint_default_yes'       = '[O/n]'

    'step.chocolatey'               = 'Chocolatey'
    'step.debloat'                  = 'Allègement'
    'step.default_browser'          = 'Navigateur par défaut'
    'step.schedule'                 = 'Planificateur de tâches'
    'step.group_jobs'               = 'Travaux de groupe'
    'step.jobs_times'               = 'Heures des tâches'
    'step.event_tasks'              = 'Tâches des scripts d''événement'
    'step.packages'                 = 'Packages'
    'step.privacy'                  = 'Confidentialité'
    'step.group_scripts'            = 'Scripts de groupe'
    'step.notify_settings'          = 'Paramètres de notification'

    'common.config_missing'         = 'Fichier de configuration introuvable : {0}'
    'common.mgmt_source_https'      = "Management.Source : seule une adresse https:// est autorisée ('{0}')"
    'common.mgmt_source_full_path'  = "Management.Source : indiquez le dossier par un chemin complet ('{0}')"
    'common.mgmt_source_id'         = 'Management.SourceId : identifiant de source manquant ou non valide (tools/publish.sh l''écrit dans source-id.txt)'
    'common.mgmt_certificate_name'  = "Management.Certificate : uniquement un nom de fichier situé à côté du fichier de configuration, sans chemin ('{0}')"
    'common.step_failed'            = "Étape '{0}' interrompue : {1}"
    'common.registry_hive_unsupported' = 'Ruche du Registre non prise en charge : {0}'
    'common.journal_not_saved'      = 'Journal d''annulation : l''état de {0} n''a pas été enregistré (la restauration ne l''annulera pas) : {1}'
    'common.registry_set_failed'    = 'Impossible de définir {0} : {1}'
    'common.profile_hive_load_failed' = 'Impossible de charger le Registre du profil {0}'
    'common.profile_error'          = 'Erreur avec le profil {0} : {1}'
    'common.profile_hive_unload_failed' = 'Impossible de décharger le Registre du profil {0} (HKU\{1}) ; un redémarrage de l''ordinateur résoudra le problème.'
    'common.root_is_link'           = 'est un lien'
    'common.root_not_folder'        = 'n''est pas un dossier'
    'common.root_foreign_owner'     = 'a un propriétaire inattendu ({0})'
    'common.root_moved_aside'       = '{0} {1} ; il est déplacé vers {2} et recréé.'
    'common.root_moved_backups'     = 'Les sauvegardes et le journal d''annulation sont restés dans {0}\state\backup et ne seront pas utilisés ; Restore-Backup.ps1 n''annulera pas les exécutions précédentes.'
    'common.icacls_setowner_failed' = 'icacls /setowner a renvoyé {0} pour {1}'
    'common.acl_failed'             = 'Impossible de définir les autorisations de {0} : {1}'
    'common.icacls_reset_failed'    = 'icacls /reset a renvoyé {0} pour {1}'
    'common.acl_extra_access'       = 'd''autres y ont aussi accès : {0}'
    'common.secure_failed'          = 'Impossible de sécuriser {0} : {1}'
    'common.loki_rejected'          = 'Loki a rejeté {0} (HTTP {1}), déplacé vers outbox\rejected : {2}'
    'common.loki_send_failed'       = 'Échec de l''envoi vers Loki ({0}), nouvelle tentative à la prochaine exécution : {1}'
    'common.healthchecks_failed'    = 'Échec du ping Healthchecks ({0}) : {1}'
    'common.answer_yes_no'        = 'Répondez o ou n.'
    'common.unknown_language'     = 'Langue inconnue ''{0}'' ; utilisation de {1}. Langues disponibles : {2}.'
    'common.timed_out'            = 'aucun résultat après {0} s ; attente interrompue'

    'common.company_question'       = 'Ce dossier contient les configurations de plusieurs entreprises. Pour laquelle est cet ordinateur ?'
    'common.company_prompt'         = 'Entreprise (numéro ou nom)'
    'common.company_unknown'        = 'Tapez un numéro de 1 à {0}, ou le nom de l''entreprise.'
    'common.company_config'         = 'Configuration de {0} : {1}'
    'common.company_no_console'     = '{0} contient les configurations de plusieurs entreprises et personne n''est à la console pour en choisir une ; indiquez-la avec -ConfigPath.'

    # Accounts: a separate administrator, the person signed in a standard user (lib\Accounts.ps1)
    'step.accounts'                              = 'Comptes'
}
