# Messages of Restore-Backup.ps1 (Romanian).
@{
    'restore.no_backup'                 = 'Nicio copie de rezervă în {0}: wmanager nu a rulat aici.'
    'restore.lock_wait'                 = 'O altă rulare wmanager este în curs (de ex. lucrările grupurilor); se așteaptă până la 10 minute...'
    'restore.lock_busy'                 = 'O altă rulare wmanager este încă în curs. Încercați din nou peste puțin timp.'
    'restore.journal_read_failed'       = 'Nu se poate citi jurnalul de anulare: {0}'
    'restore.start'                     = '{0}: restaurare pe {1}. Jurnalul de anulare: valori pentru computer {2}, pentru utilizatori {3}; copii de rezervă: {4}.'
    'restore.confirm'                   = 'Anulați modificările făcute de wmanager?'
    'restore.cancelled'                 = 'Anulat, nu s-a modificat nimic.'
    'restore.profile_not_found'         = 'Profilul {0} nu există sau nu a putut fi încărcat; setările lui nu au fost restaurate.'
    'restore.registry_summary'          = 'Registry: valori restaurate {0} din {1}.'
    'restore.store_apps_removed'        = 'Aplicații din Store eliminate de la copia de rezervă {0} ({1}); reinstalați-le din Store dacă este nevoie:'
    'restore.onedrive_removed'          = 'OneDrive a fost dezinstalat; dacă este necesar, instalați-l din nou de pe site-ul Microsoft.'
    'restore.confirm_disable_tasks'     = 'Dezactivați activitățile wmanager? Altfel, actualizarea programată va elimina aplicațiile și va modifica setările din nou.'
    'restore.tasks_disabled'            = 'Activitățile wmanager au fost dezactivate ({0}).'
    'restore.tasks_kept'                = 'Activitățile wmanager rămân activate; actualizarea programată va aplica din nou setările.'
    'restore.certificate_removed'       = 'Certificatul de semnare wmanager a fost eliminat din depozitul de certificate de încredere ({0}).'
    'restore.certificate_remove_failed' = 'Nu s-a putut elimina certificatul de semnare wmanager din depozitul de certificate de încredere: {0}'
    'restore.stopped'                   = 'Restaurarea s-a oprit: {0}'
    'restore.summary'                   = 'Gata. Avertismente: {0}, erori: {1}. Jurnal: {2}'
    'restore.finished_with_errors'      = 'Restaurarea s-a încheiat cu erori. Verificați jurnalul de mai sus.'
    'restore.finished'                  = 'Restaurarea s-a încheiat. Reporniți computerul pentru ca setările să intre în vigoare.'

    # Accounts: a separate administrator, the person signed in a standard user (lib\Accounts.ps1)
    'restore.confirm_admin_again'                = 'Le redați drepturile de administrator persoanelor pe care configurarea le-a făcut utilizatori standard?'
    'restore.admin_again'                        = '{0} este din nou administrator.'
    'restore.admin_again_failed'                 = '{0} nu a putut redeveni administrator: {1}'
    'restore.admin_account_stays'                = 'Contul de administrator {0} rămâne (din nou vizibil pe ecranul de conectare); eliminați-l manual dacă nu mai e necesar.'
}
