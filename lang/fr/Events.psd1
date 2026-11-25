# Messages des scripts d'événement (Invoke-Event.ps1, lib\Managed.ps1).
@{
    'events.starting'          = '{0} ({1}) : démarrage.'
    'events.script_done'       = '{0} : terminé.'
    'events.script_exit_code'  = '{0} : terminé avec le code de sortie {1}.'
    'events.script_timeout'    = '{0} : délai dépassé ({1} min), arrêté.'
    'events.script_not_run'    = '{0} : n''a pas été lancé : {1}.'
    'events.script_restart'    = '{0} : terminé ; il demande un redémarrage, qui n''est pas fait pour un événement.'
    'events.run_failed'        = 'Le script d''événement {0} s''est arrêté : {1}'
    'events.no_copy'           = 'Aucune copie vérifiée de la source : le script d''événement {0} n''a pas été lancé.'
    'events.busy'              = 'Le script d''événement {0} n''a pas été lancé : un autre tournait encore après {1} min.'
    'events.not_here'          = '{0} : n''est plus un script d''événement de cet ordinateur ; la prochaine exécution horaire supprime ses tâches.'
    'events.changed'           = '{0} : ses événements ont changé ; la prochaine exécution horaire recrée ses tâches.'
}
