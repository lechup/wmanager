# Messages of lib\Choco.ps1: Chocolatey, the package list, the default browser (French).
@{
    'choco.line_no_package'          = 'Ligne {0} : aucun nom de package'
    'choco.line_bad_name'            = "Ligne {0} : nom de package non valide '{1}'"
    'choco.line_bad_version'         = "Ligne {0} : version non valide '{1}' pour '{2}'"
    'choco.line_unknown_option'      = "Ligne {0} : option inconnue '{1}' (autorisés : !noupdate, et les paramètres choco après le signe |)"
    'choco.line_duplicate'           = "Ligne {0} : le package '{1}' apparaît une deuxième fois (première fois à la ligne {2})"

    'choco.reqs_file_missing'        = 'fichier introuvable : {0}'
    'choco.reqs_loaded'              = 'Liste des packages chargée depuis : {0}'
    'choco.reqs_source_failed'       = 'Source de la liste des packages indisponible ou non valide ({0}) : {1}'
    'choco.reqs_using_cache'         = 'Utilisation de la dernière copie correctement téléchargée de la liste.'
    'choco.reqs_none'                = 'Aucune liste de packages disponible (aucune source ne répond et il n''existe aucune copie).'

    'choco.section'                  = '--- Chocolatey ---'
    'choco.already_installed'        = 'Chocolatey est déjà installé.'
    'choco.installing'               = 'Installation de Chocolatey depuis {0}'
    'choco.install_failed'           = 'Échec de l''installation de Chocolatey.'
    'choco.installed'                = 'Chocolatey installé.'
    'choco.too_old'                  = 'Chocolatey {0} est trop ancien, mise à niveau vers 2.x.'
    'choco.version_required'         = 'Chocolatey 2.x est requis, {0} est installé.'
    'choco.upgraded'                 = 'Chocolatey mis à niveau vers {0}.'
    'choco.source_disabled'          = 'Source {0} désactivée.'
    'choco.source_failed'            = 'Impossible de configurer la source {0} (code {1})'
    'choco.source_set'               = 'Source {0} : {1} (priorité {2}).'

    # {1}: one of the choco.action_* texts, the subject of the sentence
    'choco.needs_restart'            = '{0} : {1} nécessite un redémarrage.'
    'choco.action_failed'            = '{0} : {1} a échoué (code {2}), détails dans le journal local.'
    'choco.action_install'           = 'l''installation'
    'choco.action_install_version'   = 'l''installation de la version {0}'
    'choco.action_upgrade'           = 'la mise à niveau'

    'choco.packages_section'         = '--- Packages ({0} dans la liste) ---'
    'choco.running_version_deferred' = '{0} : le programme est en cours d''exécution, changement de version reporté.'
    'choco.version_set'              = '{0} : version {1} définie.'
    'choco.version_pinned'           = '{0} : version {1} épinglée.'
    'choco.pin_removed'              = '{0} : épinglage de version supprimé.'
    'choco.package_installed'        = '{0} : installé.'
    'choco.running_upgrade_deferred' = '{0} : le programme est en cours d''exécution, mise à niveau reportée à la prochaine connexion.'
    'choco.package_upgraded'         = '{0} : mis à niveau depuis {1}.'

    'choco.browser_missing'          = '{0} n''est pas installé ({1}), configuration du navigateur par défaut ignorée.'
    'choco.browser_set'              = '{0} défini comme navigateur par défaut pour les nouveaux comptes.'
    'choco.browser_dism_failed'      = 'DISM n''a pas défini le navigateur par défaut (code {0}) : {1}'
}
