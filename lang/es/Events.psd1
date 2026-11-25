# Mensajes de los scripts de evento (Invoke-Event.ps1, lib\Managed.ps1).
@{
    'events.starting'          = '{0} ({1}): iniciando.'
    'events.script_done'       = '{0}: hecho.'
    'events.script_exit_code'  = '{0}: terminó con el código de salida {1}.'
    'events.script_timeout'    = '{0}: tiempo agotado ({1} min), detenido.'
    'events.script_not_run'    = '{0}: no se ejecutó: {1}.'
    'events.script_restart'    = '{0}: hecho; pide un reinicio, que no se hace por un evento.'
    'events.run_failed'        = 'El script de evento {0} se detuvo: {1}'
    'events.no_copy'           = 'No hay copia verificada de la fuente: el script de evento {0} no se ejecutó.'
    'events.busy'              = 'El script de evento {0} no se ejecutó: otro seguía en marcha después de {1} min.'
    'events.not_here'          = '{0}: ya no es un script de evento de este equipo; la próxima ejecución horaria quita sus tareas.'
    'events.changed'           = '{0}: sus eventos cambiaron; la próxima ejecución horaria crea sus tareas de nuevo.'
}
