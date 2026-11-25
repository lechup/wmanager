# Messaggi degli script di evento (Invoke-Event.ps1, lib\Managed.ps1).
@{
    'events.starting'          = '{0} ({1}): avvio.'
    'events.script_done'       = '{0}: fatto.'
    'events.script_exit_code'  = '{0}: terminato con codice di uscita {1}.'
    'events.script_timeout'    = '{0}: tempo scaduto ({1} min), fermato.'
    'events.script_not_run'    = '{0}: non eseguito: {1}.'
    'events.script_restart'    = '{0}: fatto; chiede un riavvio, che per un evento non si fa.'
    'events.run_failed'        = 'Lo script di evento {0} si è fermato: {1}'
    'events.no_copy'           = 'Nessuna copia verificata della sorgente: lo script di evento {0} non è stato eseguito.'
    'events.busy'              = 'Lo script di evento {0} non è stato eseguito: un altro era ancora in corso dopo {1} min.'
    'events.not_here'          = '{0}: non è più uno script di evento di questo computer; la prossima esecuzione oraria rimuove le sue attività.'
    'events.changed'           = '{0}: i suoi eventi sono cambiati; la prossima esecuzione oraria ricrea le sue attività.'
}
