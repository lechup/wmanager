# Messages of lib\Choco.ps1: Chocolatey, the package list, the default browser (German).
@{
    'choco.line_no_package'          = 'Zeile {0}: kein Paketname'
    'choco.line_bad_name'            = "Zeile {0}: ungültiger Paketname '{1}'"
    'choco.line_bad_version'         = "Zeile {0}: ungültige Version '{1}' für '{2}'"
    'choco.line_unknown_option'      = "Zeile {0}: unbekannte Option '{1}' (zulässig: !noupdate sowie choco-Parameter nach dem Zeichen |)"
    'choco.line_duplicate'           = "Zeile {0}: Paket '{1}' kommt ein zweites Mal vor (zuerst in Zeile {2})"

    'choco.reqs_file_missing'        = 'Datei nicht gefunden: {0}'
    'choco.reqs_loaded'              = 'Paketliste geladen aus: {0}'
    'choco.reqs_source_failed'       = 'Quelle der Paketliste nicht verfügbar oder ungültig ({0}): {1}'
    'choco.reqs_using_cache'         = 'Die zuletzt korrekt heruntergeladene Kopie der Liste wird verwendet.'
    'choco.reqs_none'                = 'Keine Paketliste verfügbar (keine Quelle antwortet und es gibt keine Kopie).'

    'choco.section'                  = '--- Chocolatey ---'
    'choco.already_installed'        = 'Chocolatey ist bereits installiert.'
    'choco.installing'               = 'Chocolatey wird von {0} installiert'
    'choco.install_failed'           = 'Die Installation von Chocolatey ist fehlgeschlagen.'
    'choco.installed'                = 'Chocolatey installiert.'
    'choco.too_old'                  = 'Chocolatey {0} ist zu alt, Aktualisierung auf 2.x.'
    'choco.version_required'         = 'Chocolatey 2.x ist erforderlich, installiert ist {0}.'
    'choco.upgraded'                 = 'Chocolatey auf {0} aktualisiert.'
    'choco.source_disabled'          = 'Quelle {0} deaktiviert.'
    'choco.source_failed'            = 'Quelle {0} konnte nicht festgelegt werden (Code {1})'
    'choco.source_set'               = 'Quelle {0}: {1} (Priorität {2}).'

    # {1}: one of the choco.action_* texts, the subject of the sentence
    'choco.needs_restart'            = '{0} : {1} erfordert einen Neustart.'
    'choco.action_failed'            = '{0} : {1} ist fehlgeschlagen (Code {2}), Details im lokalen Protokoll.'
    'choco.action_install'           = 'Installation'
    'choco.action_install_version'   = 'Installation der Version {0}'
    'choco.action_upgrade'           = 'Aktualisierung'

    'choco.packages_section'         = '--- Pakete ({0} auf der Liste) ---'
    'choco.running_version_deferred' = '{0}: Das Programm wird ausgeführt, Versionswechsel zurückgestellt.'
    'choco.version_set'              = '{0}: Version {1} festgelegt.'
    'choco.version_pinned'           = '{0}: Version {1} fixiert.'
    'choco.pin_removed'              = '{0}: Fixierung der Version aufgehoben.'
    'choco.package_installed'        = '{0}: installiert.'
    'choco.running_upgrade_deferred' = '{0}: Das Programm wird ausgeführt, Aktualisierung bis zur nächsten Anmeldung zurückgestellt.'
    'choco.package_upgraded'         = '{0}: aktualisiert von {1}.'

    'choco.browser_missing'          = '{0} ist nicht installiert ({1}), Festlegen des Standardbrowsers wird übersprungen.'
    'choco.browser_set'              = '{0} als Standardbrowser für neue Konten festgelegt.'
    'choco.browser_dism_failed'      = 'DISM hat den Standardbrowser nicht festgelegt (Code {0}): {1}'
}
