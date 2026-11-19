# Messages of lib\Install.ps1, the second step of the installer from the internet (Czech).
@{
    'install.config_https_only'     = "Konfigurace: jen adresa https:// ('{0}')."
    'install.config_invalid'        = 'Stažený soubor není platná konfigurace wmanager: {0}'
    'install.config_cert_missing'   = 'Konfigurace má zdroj skupin, ale vedle ní chybí certifikát {0} ({1}): {2}'
    'install.config_question'       = 'Konfigurační soubor (provision.config.psd1 z init.cmd): cesta, např. E:\provision.config.psd1'
    'install.config_question_more'  = 'nebo \\server\share\wmanager\provision.config.psd1, nebo adresa https://.'
    'install.config_question_enter' = 'Enter = ukázková konfigurace (bez Loki, Healthchecks a skupin).'
    'install.config_prompt'         = 'Konfigurace'
    'install.auth_header'           = 'Hlavička Authorization, např. token github_pat_... (Enter = žádná)'
    'install.config_fetched'        = 'Konfigurace stažena.'
    'install.config_example'        = 'Bez konfiguračního souboru: zřizování použije ukázkovou konfiguraci.'
    'install.stopped'               = 'Instalace přerušena.'
    'install.config_question_folder' = 'Nebo složka; obsahuje-li konfigurace několika firem (configs\<firma>\), jednu vyberete.'
    'install.config_folder_empty'   = 'Žádný provision.config.psd1 v {0} ani ve složkách firem (configs\<firma>\ nebo <firma>\).'
}
