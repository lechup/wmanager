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
    # Self-update ({0} of self_update, self_installed and {2} of download_failed, self_update_failed: wmanager and its version)
    'update.self_update'                 = '{0} -> wmanager {1}: the management source names this version; downloading {2}'
    'update.self_update_group'           = '{0} -> wmanager {1} (group {2}): the management source names this version; downloading {3}'
    'update.self_update_download_failed' = 'Cannot download wmanager {0}: {1}. Staying on {2}; the next update tries again.'
    'update.self_update_bad_hash'        = 'wmanager {0}: the downloaded file has SHA256 {1}, but the management source names {2}; not installed.'
    'update.self_update_not_release'     = 'the file is not the wmanager {0} release (wmanager\VERSION is missing or names another version)'
    'update.self_update_error'           = 'Cannot prepare wmanager {0}: {1}'
    'update.self_update_handover'        = 'Handing this run over to wmanager {0}.'
    'update.self_installed'              = '{0} installed; this run continues with it.'
    'update.self_install_failed'         = 'Cannot copy {0} into {1}: {2}'
    'update.self_update_failed'          = 'wmanager {0} did not install itself (exit code {1}); this run continues with {2}, and the next update tries again.'
    'update.self_install_restored'       = '{0}; the previous version was put back'
    'update.self_install_not_restored'   = '{0}; putting the previous version back failed too ({1}): run Provision.ps1 on this computer again'
}
