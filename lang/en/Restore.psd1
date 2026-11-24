# Messages of Restore-Backup.ps1.
@{
    'restore.no_backup'                 = 'No backup in {0}: wmanager has not run here.'
    'restore.lock_wait'                 = 'Another wmanager run is in progress (e.g. group jobs); waiting up to 10 minutes...'
    'restore.lock_busy'                 = 'Another wmanager run is still in progress. Try again in a moment.'
    'restore.journal_read_failed'       = 'Cannot read the undo journal: {0}'
    'restore.start'                     = '{0}: restoring on {1}. Journal: {2} computer values, {3} user values; backups: {4}.'
    'restore.confirm'                   = 'Undo wmanager''s changes?'
    'restore.cancelled'                 = 'Cancelled, nothing was changed.'
    'restore.profile_not_found'         = 'Profile {0} does not exist or could not be loaded; its settings were not restored.'
    'restore.registry_summary'          = 'Registry: restored {0} of {1} values.'
    'restore.store_apps_removed'        = 'Store apps removed since backup {0} ({1}); reinstall them from the Store if needed:'
    'restore.onedrive_removed'          = 'OneDrive was uninstalled; if it is needed, install it again from the Microsoft website.'
    'restore.confirm_disable_tasks'     = 'Disable the wmanager tasks? Otherwise the scheduled update will remove the apps and change the settings again.'
    'restore.tasks_disabled'            = 'wmanager tasks disabled ({0}).'
    'restore.tasks_kept'                = 'The wmanager tasks stay enabled; the scheduled update will apply the settings again.'
    'restore.certificate_removed'       = 'wmanager signing certificate removed from the trusted store ({0}).'
    'restore.certificate_remove_failed' = 'Could not remove the wmanager signing certificate from the trusted store: {0}'
    'restore.stopped'                   = 'Restore stopped: {0}'
    'restore.summary'                   = 'Done: {0} warnings, {1} errors. Log: {2}'
    'restore.finished_with_errors'      = 'Restore finished with errors. Check the log above.'
    'restore.finished'                  = 'Restore finished. Restart the computer so that the settings take effect.'

    # Accounts: a separate administrator, the person signed in a standard user (lib\Accounts.ps1)
    'restore.confirm_admin_again'                = 'Make the people provisioning made standard users administrators again?'
    'restore.admin_again'                        = '{0} is an administrator again.'
    'restore.admin_again_failed'                 = '{0} couldn''t be made an administrator again: {1}'
    'restore.admin_account_stays'                = 'The administrator account {0} stays (shown on the sign-in screen again); remove it by hand if it is not needed.'
}
