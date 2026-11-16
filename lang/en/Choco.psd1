# Messages of lib\Choco.ps1 (Chocolatey, the package list, the default browser).
@{
    'choco.line_no_package'          = 'Line {0}: no package name'
    'choco.line_bad_name'            = "Line {0}: invalid package name '{1}'"
    'choco.line_bad_version'         = "Line {0}: invalid version '{1}' for '{2}'"
    'choco.line_unknown_option'      = "Line {0}: unknown option '{1}' (allowed: !noupdate, and choco parameters after the | sign)"
    'choco.line_duplicate'           = "Line {0}: package '{1}' appears a second time (first in line {2})"

    'choco.reqs_file_missing'        = 'file not found: {0}'
    'choco.reqs_loaded'              = 'Package list loaded from: {0}'
    'choco.reqs_source_failed'       = 'Package list source unavailable or invalid ({0}): {1}'
    'choco.reqs_using_cache'         = 'Using the last correctly downloaded copy of the list.'
    'choco.reqs_none'                = 'No package list available (no source answers and there is no copy).'

    'choco.section'                  = '--- Chocolatey ---'
    'choco.already_installed'        = 'Chocolatey is already installed.'
    'choco.installing'               = 'Installing Chocolatey from {0}'
    'choco.install_failed'           = 'Chocolatey installation failed.'
    'choco.installed'                = 'Chocolatey installed.'
    'choco.too_old'                  = 'Chocolatey {0} is too old, upgrading to 2.x.'
    'choco.version_required'         = 'Chocolatey 2.x is required, {0} is installed.'
    'choco.upgraded'                 = 'Chocolatey upgraded to {0}.'
    'choco.source_disabled'          = 'Source {0} disabled.'
    'choco.source_failed'            = 'Could not set source {0} (code {1})'
    'choco.source_set'               = 'Source {0}: {1} (priority {2}).'

    # {1}: one of the choco.action_* texts, the subject of the sentence
    'choco.needs_restart'            = '{0} : {1} requires a restart.'
    'choco.action_failed'            = '{0} : {1} failed (code {2}), details in the local log.'
    'choco.action_install'           = 'installation'
    'choco.action_install_version'   = 'installation of version {0}'
    'choco.action_upgrade'           = 'upgrade'

    'choco.packages_section'         = '--- Packages ({0} on the list) ---'
    'choco.running_version_deferred' = '{0}: the program is running, version change deferred.'
    'choco.version_set'              = '{0}: version {1} set.'
    'choco.version_pinned'           = '{0}: version {1} pinned.'
    'choco.pin_removed'              = '{0}: version pin removed.'
    'choco.package_installed'        = '{0}: installed.'
    'choco.running_upgrade_deferred' = '{0}: the program is running, upgrade deferred to the next sign-in.'
    'choco.package_upgraded'         = '{0}: upgraded from {1}.'

    'choco.browser_missing'          = '{0} is not installed ({1}), skipping the default browser setting.'
    'choco.browser_set'              = '{0} set as the default browser for new accounts.'
    'choco.browser_dism_failed'      = 'DISM did not set the default browser (code {0}): {1}'
}
