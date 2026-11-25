# Messages of lib\Common.ps1 and the shared answers and step names (English: complete, the fallback).
@{
    'common.yes_words'              = 'y|yes'
    'common.no_words'               = 'n|no'
    'common.hint_default_no'        = '[y/N]'
    'common.hint_default_yes'       = '[Y/n]'

    'step.chocolatey'               = 'Chocolatey'
    'step.debloat'                  = 'Debloat'
    'step.default_browser'          = 'Default browser'
    'step.schedule'                 = 'Task Scheduler'
    'step.group_jobs'               = 'Group jobs'
    'step.jobs_times'               = 'Times of the jobs'
    'step.event_tasks'              = 'Event script tasks'
    'step.packages'                 = 'Packages'
    'step.privacy'                  = 'Privacy'
    'step.group_scripts'            = 'Group scripts'
    'step.notify_settings'          = 'Notification settings'

    'common.config_missing'         = 'Configuration file not found: {0}'
    'common.mgmt_source_https'      = "Management.Source: only an https:// address is allowed ('{0}')"
    'common.mgmt_source_full_path'  = "Management.Source: give the folder as a full path ('{0}')"
    'common.mgmt_source_id'         = 'Management.SourceId: missing or invalid source identifier (tools/publish.sh writes it to source-id.txt)'
    'common.mgmt_certificate_name'  = "Management.Certificate: only a file name next to the configuration file, without a path ('{0}')"
    'common.step_failed'            = "Step '{0}' stopped: {1}"
    'common.registry_hive_unsupported' = 'Unsupported registry hive: {0}'
    'common.journal_not_saved'      = 'Undo journal: the state of {0} was not saved (restore will not undo it): {1}'
    'common.registry_set_failed'    = 'Could not set {0} : {1}'
    'common.profile_hive_load_failed' = 'Cannot load the registry of profile {0}'
    'common.profile_error'          = 'Error with profile {0}: {1}'
    'common.profile_hive_unload_failed' = 'Could not unload the registry of profile {0} (HKU\{1}); restarting the computer will help.'
    'common.root_is_link'           = 'is a link'
    'common.root_not_folder'        = 'is not a folder'
    'common.root_foreign_owner'     = 'has a foreign owner ({0})'
    'common.root_moved_aside'       = '{0} {1}; moving it to {2} and starting anew.'
    'common.root_moved_backups'     = 'Backups and the undo journal stayed in {0}\state\backup and will not be used; Restore-Backup.ps1 will not undo earlier runs.'
    'common.icacls_setowner_failed' = 'icacls /setowner returned {0} for {1}'
    'common.acl_failed'             = 'Could not set the permissions of {0} : {1}'
    'common.icacls_reset_failed'    = 'icacls /reset returned {0} for {1}'
    'common.acl_extra_access'       = 'others have access too: {0}'
    'common.secure_failed'          = 'Could not secure {0} : {1}'
    'common.loki_rejected'          = 'Loki rejected {0} (HTTP {1}), moved to outbox\rejected: {2}'
    'common.loki_send_failed'       = 'Sending to Loki failed ({0}), will try at the next run: {1}'
    'common.healthchecks_failed'    = 'Healthchecks ping ({0}) failed: {1}'
    'common.answer_yes_no'        = 'Answer y or n.'
    'common.unknown_language'     = 'Unknown language ''{0}''; using {1}. Available: {2}.'
    'common.timed_out'            = 'no result after {0} s; stopped waiting'

    'common.company_question'       = 'This folder holds the configurations of several companies. Which one is this computer for?'
    'common.company_prompt'         = 'Company (number or name)'
    'common.company_unknown'        = 'Type a number from 1 to {0}, or the name of the company.'
    'common.company_config'         = 'Configuration of {0}: {1}'
    'common.company_no_console'     = '{0} holds the configurations of several companies and nobody is at the console to choose one; give it with -ConfigPath.'

    # Accounts: a separate administrator, the person signed in a standard user (lib\Accounts.ps1)
    'step.accounts'                              = 'Accounts'
}
