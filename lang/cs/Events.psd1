# Zprávy skriptů událostí (Invoke-Event.ps1, lib\Managed.ps1).
@{
    'events.starting'          = '{0} ({1}): spouští se.'
    'events.script_done'       = '{0}: hotovo.'
    'events.script_exit_code'  = '{0}: skončil s návratovým kódem {1}.'
    'events.script_timeout'    = '{0}: vypršel čas ({1} min), zastaven.'
    'events.script_not_run'    = '{0}: nespuštěn: {1}.'
    'events.script_restart'    = '{0}: hotovo; žádá o restart, který se při události nedělá.'
    'events.run_failed'        = 'Skript události {0} se zastavil: {1}'
    'events.no_copy'           = 'Žádná ověřená kopie zdroje: skript události {0} se nespustil.'
    'events.busy'              = 'Skript události {0} se nespustil: jiný ještě běžel po {1} min.'
    'events.not_here'          = '{0}: už to není skript událostí tohoto počítače; příští hodinový běh odstraní jeho úlohy.'
    'events.changed'           = '{0}: jeho události se změnily; příští hodinový běh vytvoří jeho úlohy znovu.'
}
