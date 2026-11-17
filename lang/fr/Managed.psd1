# Messages of lib\Managed.ps1: the management source, group scripts and jobs (French).
@{
    'managed.manifest_no_source_id'      = 'manifeste : identifiant de source (SourceId) manquant ou non valide'
    'managed.manifest_other_source'      = 'le manifeste appartient à une autre source ({0}), et non à {1} de la configuration'
    'managed.manifest_no_serial'         = 'manifeste : numéro Serial manquant ou non valide'
    'managed.manifest_no_files'          = 'manifeste : aucune liste de fichiers (Files)'
    'managed.manifest_bad_path'          = "manifeste : chemin non autorisé '{0}'"
    'managed.manifest_lists_itself'      = 'manifeste : il ne doit pas se lister lui-même'
    'managed.manifest_bad_hash'          = "manifeste : hachage SHA256 non valide pour '{0}'"
    'managed.manifest_duplicate_path'    = "manifeste : le chemin '{0}' apparaît deux fois"

    'managed.groups_unknown_key'         = "groups.psd1 : clé inconnue '{0}' (autorisées : Default, Computers)"
    'managed.groups_computers_not_table' = "groups.psd1 : Computers doit être une table @{{ 'NOM' = @('groupe') }}"
    'managed.groups_empty_computer'      = 'groups.psd1 : nom d''ordinateur vide'
    'managed.groups_bad_group'           = "groups.psd1 : nom de groupe non valide '{0}'"

    'managed.common_list'                = 'liste commune'
    'managed.package_group_replaces'     = 'Package {0} : l''entrée du groupe {1} remplace celle de la liste commune.'
    'managed.package_conflict'           = "Le package {0} est décrit différemment dans '{1}' et '{2}' ; utilisation de l'entrée de '{1}'."
    'managed.unknown_period'             = "fréquence inconnue '{0}'"

    'managed.cert_missing'               = 'Certificat de signature introuvable : {0}'
    'managed.cert_private_key'           = '{0} contient une clé privée ; seul le .cer public est déployé sur les ordinateurs'
    'managed.cert_is_ca'                 = '{0} est un certificat d''autorité de certification (CA) ; wmanager ne l''ajoutera pas aux certificats de confiance'
    'managed.cert_not_code_signing'      = '{0} n''est pas un certificat de signature de code (pas d''utilisation Code Signing)'
    'managed.cert_expired'               = 'Le certificat de signature a expiré le {0} ; seules les signatures horodatées fonctionnent encore.'
    'managed.cert_expiring'              = 'Le certificat de signature expire le {0} ; préparez-en un nouveau.'
    'managed.cert_previous_removed'      = 'Ancien certificat de signature wmanager supprimé des racines de confiance ({0}).'
    'managed.cert_added'                 = "Le certificat de signature wmanager a été ajouté aux autorités de certification racines de confiance de l'ordinateur ({0})."
    'managed.signature_invalid'          = 'signature du manifeste non valide ({0}) : {1}'
    'managed.signature_other_cert'       = 'manifeste signé avec un autre certificat ({0}) que celui de la configuration ({1})'

    'managed.saved_copy_invalid'         = 'La copie enregistrée de la source de gestion n''est pas valide : {0}'
    'managed.file_error'                 = '{0} : {1}'
    'managed.source_unreachable'         = 'Source de gestion inaccessible ({0}) : {1}'
    'managed.manifest_older'             = 'le manifeste {0} est plus ancien que le manifeste {1} accepté précédemment'
    'managed.manifest_same_serial'       = 'le manifeste a le même numéro {0} que celui accepté précédemment, mais des fichiers différents'
    'managed.source_unchanged'           = 'Source de gestion inchangée (manifeste {0}).'
    'managed.download_failed'            = 'impossible de télécharger {0} : {1}'
    'managed.hash_mismatch'              = '{0} a un hachage SHA256 différent de celui du manifeste (le fichier a été modifié ou n''est pas encore publié)'
    'managed.swap_failed'                = 'impossible de remplacer {0} (un programme utilise-t-il des fichiers de ce dossier ?) : {1}'
    'managed.manifest_accepted'          = 'Source de gestion : manifeste {0} accepté (fichiers : {1}).'

    'managed.no_source'                  = 'Aucun Management.Source dans la configuration.'
    'managed.new_version_rejected'       = 'Nouvelle version de la source de gestion rejetée : {0}'
    'managed.no_verified_copy'           = 'Aucune version vérifiée de la source de gestion (le téléchargement a échoué et il n''existe aucune copie).'
    'managed.using_last_copy'            = 'Utilisation de la dernière copie vérifiée de la source de gestion (manifeste {0}).'
    'managed.computer_groups'            = 'Groupes de l''ordinateur {0} : {1}.'
    'managed.computer_no_groups'         = 'L''ordinateur {0} n''appartient à aucun groupe (liste commune uniquement).'
    'managed.group_no_files'             = 'Le groupe {0} n''a aucun fichier dans la source de gestion.'
    'managed.source_info'                = 'Source de gestion : {0} ({1}), certificat {2} ({3}).'

    'managed.scripts_section'            = '--- Scripts de groupe ---'
    'managed.no_scripts'                 = 'Aucun script pour les groupes de cet ordinateur.'
    'managed.script_unchanged'           = '{0} : inchangé.'
    'managed.script_starting'            = '{0} : démarrage.'
    'managed.retry_next_update'          = 'nouvelle tentative à la prochaine mise à jour'
    'managed.retry_after_hours'          = 'nouvelle tentative dans {0} h ou après modification du script'
    'managed.script_timeout'             = '{0} : délai dépassé ({1} min), arrêté ; {2}.'
    'managed.script_exit_code'           = '{0} : terminé avec le code de sortie {1} ; {2}.'
    'managed.script_done_reboot'         = '{0} : terminé, un redémarrage est nécessaire.'
    'managed.script_done'                = '{0} : terminé.'
    'managed.scripts_state_failed'       = 'Impossible d''enregistrer l''état des scripts : {0}'

    'managed.jobs_state_failed'          = 'Impossible d''enregistrer l''état des travaux : {0}'
    'managed.job_starting'               = 'Travail {0} ({1}) : démarrage.'
    'managed.job_timeout'                = 'Travail {0} : délai dépassé ({1} min), arrêté.'
    'managed.job_exit_code'              = 'Travail {0} : terminé avec le code de sortie {1}.'
    'managed.job_done'                   = 'Travail {0} : terminé.'
    # version.psd1 ({0}: the entry, e.g. Groups.test.Url; {1}: its value)
    'managed.version_unknown_key'      = 'version.psd1 : clé inconnue ''{0}'' (autorisées : Version, Url, Sha256, Groups)'
    'managed.version_missing'          = 'version.psd1 : {0} manque (une version demande Version, Url et Sha256)'
    'managed.version_bad_tag'          = 'version.psd1 : {0} n''est pas une version de wmanager comme v0.2.0 : {1}'
    'managed.version_bad_url'          = 'version.psd1 : {0} doit être une adresse https:// ou un chemin (C:\..., \\serveur\partage\...) : {1}'
    'managed.version_bad_hash'         = 'version.psd1 : {0} n''est pas un SHA256 (64 chiffres hexadécimaux)'
    'managed.version_bad_group'        = 'version.psd1 : nom de groupe non valide dans Groups : ''{0}'''
    'managed.version_groups_not_table' = 'version.psd1 : Groups doit donner à chaque groupe ses propres Version, Url et Sha256'
}
