# Messages of the event scripts (Invoke-Event.ps1, lib\Managed.ps1).
@{
    'events.starting'          = '{0} ({1}): starting.'
    'events.script_done'       = '{0}: done.'
    'events.script_exit_code'  = '{0}: ended with exit code {1}.'
    'events.script_timeout'    = '{0}: timed out ({1} min), stopped.'
    'events.script_not_run'    = '{0}: didn''t run: {1}.'
    'events.script_restart'    = '{0}: done; it asks for a restart, which isn''t made for an event.'
    'events.run_failed'        = 'The event script {0} stopped: {1}'
    'events.no_copy'           = 'No verified copy of the source: the event script {0} didn''t run.'
    'events.busy'              = 'The event script {0} didn''t run: another one was still running after {1} min.'
    'events.not_here'          = '{0}: not an event script of this computer any more; the next hourly run removes its tasks.'
    'events.changed'           = '{0}: its events changed; the next hourly run makes its tasks again.'
}
