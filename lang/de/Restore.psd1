# Messages of Restore-Backup.ps1 (German).
@{
    'restore.no_backup'                 = 'Keine Sicherung in {0}: wmanager wurde hier nicht ausgeführt.'
    'restore.lock_wait'                 = 'Ein anderer wmanager-Durchlauf ist aktiv (z. B. Gruppenjobs); es wird bis zu 10 Minuten gewartet...'
    'restore.lock_busy'                 = 'Ein anderer wmanager-Durchlauf ist noch aktiv. Versuchen Sie es gleich noch einmal.'
    'restore.journal_read_failed'       = 'Das Änderungsjournal kann nicht gelesen werden: {0}'
    'restore.start'                     = '{0}: Wiederherstellung auf {1}. Journal: {2} Computerwerte, {3} Benutzerwerte; Sicherungen: {4}.'
    'restore.confirm'                   = 'Die Änderungen von wmanager rückgängig machen?'
    'restore.cancelled'                 = 'Abgebrochen, es wurde nichts geändert.'
    'restore.profile_not_found'         = 'Das Profil {0} ist nicht vorhanden oder konnte nicht geladen werden; seine Einstellungen wurden nicht wiederhergestellt.'
    'restore.registry_summary'          = 'Registrierung: {0} von {1} Werten wiederhergestellt.'
    'restore.store_apps_removed'        = 'Seit der Sicherung {0} entfernte Store-Apps ({1}); installieren Sie sie bei Bedarf erneut aus dem Store:'
    'restore.onedrive_removed'          = 'OneDrive wurde deinstalliert; installieren Sie es bei Bedarf erneut von der Microsoft-Website.'
    'restore.confirm_disable_tasks'     = 'Die wmanager-Aufgaben deaktivieren? Andernfalls entfernt die geplante Aktualisierung die Apps erneut und ändert die Einstellungen wieder.'
    'restore.tasks_disabled'            = 'wmanager-Aufgaben deaktiviert ({0}).'
    'restore.tasks_kept'                = 'Die wmanager-Aufgaben bleiben aktiviert; die geplante Aktualisierung wendet die Einstellungen erneut an.'
    'restore.certificate_removed'       = 'wmanager-Signaturzertifikat aus dem Speicher vertrauenswürdiger Zertifikate entfernt ({0}).'
    'restore.certificate_remove_failed' = 'Das wmanager-Signaturzertifikat konnte nicht aus dem Speicher vertrauenswürdiger Zertifikate entfernt werden: {0}'
    'restore.stopped'                   = 'Wiederherstellung abgebrochen: {0}'
    'restore.summary'                   = 'Fertig: {0} Warnungen, {1} Fehler. Protokoll: {2}'
    'restore.finished_with_errors'      = 'Die Wiederherstellung wurde mit Fehlern abgeschlossen. Prüfen Sie das Protokoll oben.'
    'restore.finished'                  = 'Die Wiederherstellung ist abgeschlossen. Starten Sie den Computer neu, damit die Einstellungen wirksam werden.'

    # Accounts: a separate administrator, the person signed in a standard user (lib\Accounts.ps1)
    'restore.confirm_admin_again'                = 'Die Personen, die die Einrichtung zu Standardbenutzern gemacht hat, wieder zu Administratoren machen?'
    'restore.admin_again'                        = '{0} ist wieder Administrator.'
    'restore.admin_again_failed'                 = '{0} konnte nicht wieder Administrator werden: {1}'
    'restore.admin_account_stays'                = 'Das Administratorkonto {0} bleibt (wieder auf dem Anmeldebildschirm sichtbar); bei Bedarf von Hand entfernen.'
}
