# Messages of lib\Install.ps1, the second step of the installer from the internet (Romanian).
@{
    'install.config_https_only'     = "Configurație: doar o adresă https:// ('{0}')."
    'install.config_invalid'        = 'Fișierul descărcat nu este o configurație wmanager validă: {0}'
    'install.config_cert_missing'   = 'Configurația are o sursă pentru grupuri, dar lângă ea nu există certificatul {0} ({1}): {2}'
    'install.config_question'       = 'Fișierul de configurare (provision.config.psd1 din init.cmd): o cale, de ex. E:\provision.config.psd1'
    'install.config_question_more'  = 'sau \\server\share\wmanager\provision.config.psd1, ori o adresă https://.'
    'install.config_question_enter' = 'Enter = configurația exemplu (fără Loki, Healthchecks sau grupuri).'
    'install.config_prompt'         = 'Configurație'
    'install.auth_header'           = 'Antetul Authorization, de ex. token github_pat_... (Enter = niciunul)'
    'install.config_fetched'        = 'Configurația a fost descărcată.'
    'install.config_example'        = 'Niciun fișier de configurare: provizionarea va folosi exemplul.'
    'install.stopped'               = 'Instalarea s-a oprit.'
    'install.config_question_folder' = 'Sau un dosar; dacă conține configurațiile mai multor firme (configs\<firma>\), alegeți una.'
    'install.config_folder_empty'   = 'Niciun provision.config.psd1 în {0} și nici în dosare de firme (configs\<firma>\ sau <firma>\).'
}
