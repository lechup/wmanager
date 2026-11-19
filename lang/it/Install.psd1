# Messages of lib\Install.ps1, the second step of the installer from the internet (Italian).
@{
    'install.config_https_only'     = 'Configurazione: solo un indirizzo https:// (''{0}'').'
    'install.config_invalid'        = 'Il file scaricato non è una configurazione di wmanager valida: {0}'
    'install.config_cert_missing'   = 'La configurazione ha un''origine dei gruppi, ma accanto non c''è il certificato {0} ({1}): {2}'
    'install.config_question'       = 'File di configurazione (provision.config.psd1 da init.cmd): un percorso, ad es. E:\provision.config.psd1'
    'install.config_question_more'  = 'o \\server\share\wmanager\provision.config.psd1, o un indirizzo https://.'
    'install.config_question_enter' = 'Invio = la configurazione di esempio (senza Loki, Healthchecks né gruppi).'
    'install.config_prompt'         = 'Configurazione'
    'install.auth_header'           = 'Intestazione Authorization, ad es. token github_pat_... (Invio = nessuna)'
    'install.config_fetched'        = 'Configurazione scaricata.'
    'install.config_example'        = 'Nessun file di configurazione: il provisioning userà quello di esempio.'
    'install.stopped'               = 'Installazione interrotta.'
    'install.config_question_folder' = 'Oppure una cartella; se contiene le configurazioni di più aziende (configs\<azienda>\), ne scegli una.'
    'install.config_folder_empty'   = 'Nessun provision.config.psd1 in {0}, né in cartelle di aziende (configs\<azienda>\ o <azienda>\).'
}
