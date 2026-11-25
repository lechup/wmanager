# Messages of lib\Choco.ps1: Chocolatey, the package list, the default browser (French).
@{
    'choco.line_no_package'          = 'Ligne {0} : aucun nom de package'
    'choco.line_bad_name'            = "Ligne {0} : nom de package non valide '{1}'"
    'choco.line_bad_version'         = "Ligne {0} : version non valide '{1}' pour '{2}'"
    'choco.line_unknown_option'      = 'Ligne {0} : option inconnue ''{1}'' (autorisés : !noupdate, !signer="éditeur", et les paramètres choco après le signe |)'
    'choco.line_duplicate'           = "Ligne {0} : le package '{1}' apparaît une deuxième fois (première fois à la ligne {2})"
    'choco.line_bad_signer'          = 'Ligne {0} : !signer demande le nom de l''éditeur, une seule fois, entre guillemets s''il contient des espaces (ex. !signer="Google LLC")'

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

    # A download whose checksum doesn't match the package, checked by its signature instead (Invoke-WmChocoPackage)
    'choco.checksum_pinned'          = '{0} : le fichier téléchargé ne correspond pas à la somme de contrôle de la version épinglée {1} : l''adresse fournit maintenant une autre version, il n''est donc pas installé (une version épinglée, c''est uniquement le fichier de cette version).'
    'choco.checksum_own'             = '{0} : le fichier téléchargé ne correspond pas à la somme de contrôle donnée après | dans la liste : non installé.'
    'choco.checksum_no_signer'       = '{0} : le fichier téléchargé ne correspond pas à la somme de contrôle du package (souvent une nouvelle version à la même adresse avant la mise à jour du package ; la prochaine mise à jour réessaiera). Avec !signer="éditeur" sur sa ligne de la liste, wmanager vérifie plutôt la signature du fichier.'
    'choco.checksum_check_signature' = '{0} : {1} ne correspond pas à la somme de contrôle du package ; vérification de sa signature par {2} à la place.'
    'choco.signature_no_file'        = '{0} : le fichier à vérifier n''existe plus ({1}) et son adresse est inconnue.'
    'choco.signature_download_failed' = '{0} : le fichier à vérifier n''a pas pu être téléchargé depuis {1} : {2}'
    'choco.signature_bad'            = '{0} : {1} n''est pas valablement signé par {2} ({3}) : non installé.'
    'choco.signature_ok'             = '{0} : {1} est signé par {2} : installation avec sa propre somme de contrôle.'
    'choco.signature_check_failed'   = '{0} : la signature de {1} n''a pas pu être vérifiée : {2}'

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
