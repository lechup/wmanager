# Messages of Update-Packages.ps1, the scheduled update (Portuguese).
@{
    'update.retry_flag_failed' = 'Não é possível guardar a marca de nova tentativa: {0}'
    'update.busy'              = 'Ainda está em curso outra execução do wmanager; nova tentativa no próximo início de sessão.'
    # {0}: wmanager and its version, {1}: update or retry (the job, not translated), {2}: the computer name
    'update.start'             = '{0} {1} em {2}'
    'update.offline'           = 'Sem ligação a: {0}. A ignorar a execução, nova tentativa no próximo início de sessão.'
    'update.deferred'          = 'Adiado para o próximo início de sessão: {0}'
    'update.reboot_pending'    = 'O sistema está a aguardar um reinício; o utilizador vai receber uma notificação.'
    'update.run_failed'        = 'Execução interrompida: {0}'
    'update.summary'           = 'Fim: avisos {0}, erros {1}.'
    # Self-update ({0} of self_update, self_installed and {2} of download_failed, self_update_failed: wmanager and its version)
    'update.self_update'                 = '{0} -> wmanager {1}: a origem de gestão indica esta versão; a transferir {2}'
    'update.self_update_group'           = '{0} -> wmanager {1} (grupo {2}): a origem de gestão indica esta versão; a transferir {3}'
    'update.self_update_download_failed' = 'Não é possível transferir o wmanager {0}: {1}. Mantém-se {2}; a próxima atualização tenta de novo.'
    'update.self_update_bad_hash'        = 'wmanager {0}: o ficheiro transferido tem SHA256 {1}, mas a origem de gestão indica {2}; não instalado.'
    'update.self_update_not_release'     = 'o ficheiro não é a versão {0} do wmanager (falta wmanager\VERSION ou indica outra versão)'
    'update.self_update_error'           = 'Não é possível preparar o wmanager {0}: {1}'
    'update.self_update_handover'        = 'Esta execução passa para o wmanager {0}.'
    'update.self_installed'              = '{0} instalado; esta execução continua com ele.'
    'update.self_install_failed'         = 'Não é possível copiar {0} para {1}: {2}'
    'update.self_update_failed'          = 'O wmanager {0} não se instalou (código de saída {1}); esta execução continua com {2} e a próxima atualização tenta de novo.'
    'update.self_install_restored'       = '{0}; a versão anterior foi reposta'
    'update.self_install_not_restored'   = '{0}; também não foi possível repor a versão anterior ({1}): execute novamente o Provision.ps1 neste computador'
}
