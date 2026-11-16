# Messages of lib\Install.ps1 (the second step of the installer from the internet).
@{
    'install.config_https_only'     = "Configuration: only an https:// address ('{0}')."
    'install.config_invalid'        = 'The downloaded file is not a valid wmanager configuration: {0}'
    'install.config_cert_missing'   = 'The configuration has a group source, but there is no certificate {0} next to it ({1}): {2}'
    'install.config_question'       = 'Configuration file (provision.config.psd1 from init.cmd): a path, e.g. E:\provision.config.psd1'
    'install.config_question_more'  = 'or \\server\share\wmanager\provision.config.psd1, or an https:// address.'
    'install.config_question_enter' = 'Enter = the example configuration (no Loki, Healthchecks or groups).'
    'install.config_prompt'         = 'Configuration'
    'install.auth_header'           = 'Authorization header, e.g. token github_pat_... (Enter = none)'
    'install.config_fetched'        = 'Configuration downloaded.'
    'install.config_example'        = 'No configuration file: provisioning will use the example.'
    'install.stopped'               = 'Installation stopped.'
}
