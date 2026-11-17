# Messages of lib\Managed.ps1 (the management source, group scripts and jobs).
@{
    'managed.manifest_no_source_id'      = 'manifest: missing or invalid source identifier (SourceId)'
    'managed.manifest_other_source'      = 'manifest belongs to another source ({0}), not to {1} from the configuration'
    'managed.manifest_no_serial'         = 'manifest: missing or invalid Serial number'
    'managed.manifest_no_files'          = 'manifest: no file list (Files)'
    'managed.manifest_bad_path'          = "manifest: path not allowed '{0}'"
    'managed.manifest_lists_itself'      = 'manifest: it must not list itself'
    'managed.manifest_bad_hash'          = "manifest: invalid SHA256 hash for '{0}'"
    'managed.manifest_duplicate_path'    = "manifest: path '{0}' appears twice"

    'managed.groups_unknown_key'         = "groups.psd1: unknown key '{0}' (allowed: Default, Computers)"
    'managed.groups_computers_not_table' = "groups.psd1: Computers must be a table @{{ 'NAME' = @('group') }}"
    'managed.groups_empty_computer'      = 'groups.psd1: empty computer name'
    'managed.groups_bad_group'           = "groups.psd1: invalid group name '{0}'"

    'managed.common_list'                = 'common list'
    'managed.package_group_replaces'     = 'Package {0}: the entry of group {1} replaces the entry of the common list.'
    'managed.package_conflict'           = "Package {0} is described differently in '{1}' and '{2}'; using the entry from '{1}'."
    'managed.unknown_period'             = "unknown frequency '{0}'"

    'managed.cert_missing'               = 'Signing certificate not found: {0}'
    'managed.cert_private_key'           = '{0} contains a private key; only the public .cer goes to the computers'
    'managed.cert_is_ca'                 = '{0} is a certificate authority (CA) certificate; wmanager will not add it to the trusted ones'
    'managed.cert_not_code_signing'      = '{0} is not a code signing certificate (no Code Signing usage)'
    'managed.cert_expired'               = 'The signing certificate expired on {0}; only signatures with a timestamp still work.'
    'managed.cert_expiring'              = 'The signing certificate expires on {0}; prepare a new one.'
    'managed.cert_previous_removed'      = 'Removed the previous wmanager signing certificate from the trusted roots ({0}).'
    'managed.cert_added'                 = "The wmanager signing certificate was added to the computer's trusted root authorities ({0})."
    'managed.signature_invalid'          = 'invalid manifest signature ({0}): {1}'
    'managed.signature_other_cert'       = 'manifest signed with another certificate ({0}) than the one from the configuration ({1})'

    'managed.saved_copy_invalid'         = 'The saved copy of the management source is invalid: {0}'
    'managed.file_error'                 = '{0}: {1}'
    'managed.source_unreachable'         = 'Management source unreachable ({0}): {1}'
    'managed.manifest_older'             = 'manifest {0} is older than the previously accepted {1}'
    'managed.manifest_same_serial'       = 'manifest has the same number {0} as the previously accepted one, but different files'
    'managed.source_unchanged'           = 'Management source unchanged (manifest {0}).'
    'managed.download_failed'            = 'could not download {0}: {1}'
    'managed.hash_mismatch'              = '{0} has a different SHA256 hash than in the manifest (the file was changed or is not published yet)'
    'managed.swap_failed'                = 'cannot replace {0} (is a program using files from this folder?): {1}'
    'managed.manifest_accepted'          = 'Management source: accepted manifest {0} ({1} files).'

    'managed.no_source'                  = 'No Management.Source in the configuration.'
    'managed.new_version_rejected'       = 'Rejected the new version from the management source: {0}'
    'managed.no_verified_copy'           = 'No verified version of the management source (it could not be downloaded and there is no copy).'
    'managed.using_last_copy'            = 'Using the last verified copy of the management source (manifest {0}).'
    'managed.computer_groups'            = 'Groups of computer {0}: {1}.'
    'managed.computer_no_groups'         = 'Computer {0} belongs to no group (common list only).'
    'managed.group_no_files'             = 'Group {0} has no files in the management source.'
    'managed.source_info'                = 'Management source: {0} ({1}), certificate {2} ({3}).'

    'managed.scripts_section'            = '--- Group scripts ---'
    'managed.no_scripts'                 = 'No scripts for the groups of this computer.'
    'managed.script_unchanged'           = '{0}: unchanged.'
    'managed.script_starting'            = '{0}: starting.'
    'managed.retry_next_update'          = 'will retry at the next update'
    'managed.retry_after_hours'          = 'will retry in {0} h or after the script changes'
    'managed.script_timeout'             = '{0}: timed out ({1} min), stopped; {2}.'
    'managed.script_exit_code'           = '{0}: ended with exit code {1}; {2}.'
    'managed.script_done_reboot'         = '{0}: done, a restart is needed.'
    'managed.script_done'                = '{0}: done.'
    'managed.scripts_state_failed'       = 'Cannot save the state of the scripts: {0}'

    'managed.jobs_state_failed'          = 'Cannot save the state of the jobs: {0}'
    'managed.job_starting'               = 'Job {0} ({1}): starting.'
    'managed.job_timeout'                = 'Job {0}: timed out ({1} min), stopped.'
    'managed.job_exit_code'              = 'Job {0}: ended with exit code {1}.'
    'managed.job_done'                   = 'Job {0}: done.'
    # version.psd1 ({0}: the entry, e.g. Groups.test.Url; {1}: its value)
    'managed.version_unknown_key'      = 'version.psd1: unknown key ''{0}'' (allowed: Version, Url, Sha256, Groups)'
    'managed.version_missing'          = 'version.psd1: {0} is missing (a version needs Version, Url and Sha256)'
    'managed.version_bad_tag'          = 'version.psd1: {0} is not a wmanager release such as v0.2.0: {1}'
    'managed.version_bad_url'          = 'version.psd1: {0} must be an https:// address or a path (C:\..., \\server\share\...): {1}'
    'managed.version_bad_hash'         = 'version.psd1: {0} is not a SHA256 (64 hexadecimal digits)'
    'managed.version_bad_group'        = 'version.psd1: invalid group name in Groups: ''{0}'''
    'managed.version_groups_not_table' = 'version.psd1: Groups must give each group its own Version, Url and Sha256'
}
