# Messages of Update-Packages.ps1 (the scheduled update).
@{
    'update.retry_flag_failed' = 'Cannot save the retry mark: {0}'
    'update.busy'              = 'Another wmanager run is still in progress; will retry at the next sign-in.'
    # {0}: wmanager and its version, {1}: update or retry (the job, not translated), {2}: the computer name
    'update.start'             = '{0} {1} on {2}'
    'update.offline'           = 'No connection to: {0}. Skipping the run, will retry at the next sign-in.'
    'update.deferred'          = 'Deferred to the next sign-in: {0}'
    'update.reboot_pending'    = 'The system is waiting for a restart; the user will get a notification.'
    'update.run_failed'        = 'Run stopped: {0}'
    'update.summary'           = 'End: warnings {0}, errors {1}.'
}
