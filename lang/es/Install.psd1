# Messages of lib\Install.ps1, the second step of the installer from the internet (Spanish).
@{
    'install.config_https_only'     = 'Configuración: solo una dirección https:// (''{0}'').'
    'install.config_invalid'        = 'El archivo descargado no es una configuración válida de wmanager: {0}'
    'install.config_cert_missing'   = 'La configuración tiene un origen de grupos, pero no hay ningún certificado {0} junto a ella ({1}): {2}'
    'install.config_question'       = 'Archivo de configuración (provision.config.psd1 de init.cmd): una ruta, p. ej. E:\provision.config.psd1'
    'install.config_question_more'  = 'o \\server\share\wmanager\provision.config.psd1, o una dirección https://.'
    'install.config_question_enter' = 'Intro = la configuración de ejemplo (sin Loki, Healthchecks ni grupos).'
    'install.config_prompt'         = 'Configuración'
    'install.auth_header'           = 'Encabezado Authorization, p. ej. token github_pat_... (Intro = ninguno)'
    'install.config_fetched'        = 'Configuración descargada.'
    'install.config_example'        = 'No hay archivo de configuración: el aprovisionamiento usará el de ejemplo.'
    'install.stopped'               = 'Instalación detenida.'
    'install.config_question_folder' = 'O una carpeta; si contiene las configuraciones de varias empresas (configs\<empresa>\), eliges una.'
    'install.config_folder_empty'   = 'No hay provision.config.psd1 en {0} ni en carpetas de empresas (configs\<empresa>\ o <empresa>\).'
}
