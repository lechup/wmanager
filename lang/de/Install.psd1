# Messages of lib\Install.ps1, the second step of the installer from the internet (German).
@{
    'install.config_https_only'     = "Konfiguration: nur eine https://-Adresse ('{0}')."
    'install.config_invalid'        = 'Die heruntergeladene Datei ist keine gültige wmanager-Konfiguration: {0}'
    'install.config_cert_missing'   = 'Die Konfiguration hat eine Gruppenquelle, aber daneben liegt kein Zertifikat {0} ({1}): {2}'
    'install.config_question'       = 'Konfigurationsdatei (provision.config.psd1 aus init.cmd): ein Pfad, z. B. E:\provision.config.psd1'
    'install.config_question_more'  = 'oder \\server\share\wmanager\provision.config.psd1 oder eine https://-Adresse.'
    'install.config_question_enter' = 'Enter = die Beispielkonfiguration (ohne Loki, Healthchecks und Gruppen).'
    'install.config_prompt'         = 'Konfiguration'
    'install.auth_header'           = 'Authorization-Header, z. B. token github_pat_... (Enter = keiner)'
    'install.config_fetched'        = 'Konfiguration heruntergeladen.'
    'install.config_example'        = 'Keine Konfigurationsdatei: Die Einrichtung verwendet das Beispiel.'
    'install.stopped'               = 'Installation abgebrochen.'
    'install.config_question_folder' = 'Oder ein Ordner; enthält er die Konfigurationen mehrerer Firmen (configs\<Firma>\), wählen Sie eine aus.'
    'install.config_folder_empty'   = 'Keine provision.config.psd1 in {0}, auch nicht in Ordnern von Firmen (configs\<Firma>\ oder <Firma>\).'
}
