# Mensagens dos scripts de evento (Invoke-Event.ps1, lib\Managed.ps1).
@{
    'events.starting'          = '{0} ({1}): a iniciar.'
    'events.script_done'       = '{0}: feito.'
    'events.script_exit_code'  = '{0}: terminou com o código de saída {1}.'
    'events.script_timeout'    = '{0}: tempo esgotado ({1} min), parado.'
    'events.script_not_run'    = '{0}: não foi executado: {1}.'
    'events.script_restart'    = '{0}: feito; pede um reinício, que não é feito por um evento.'
    'events.run_failed'        = 'O script de evento {0} parou: {1}'
    'events.no_copy'           = 'Não há cópia verificada da fonte: o script de evento {0} não foi executado.'
    'events.busy'              = 'O script de evento {0} não foi executado: outro ainda estava a correr após {1} min.'
    'events.not_here'          = '{0}: já não é um script de evento deste computador; a próxima execução horária remove as suas tarefas.'
    'events.changed'           = '{0}: os seus eventos mudaram; a próxima execução horária cria as suas tarefas de novo.'
}
