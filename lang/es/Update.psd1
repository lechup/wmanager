# Messages of Update-Packages.ps1, the scheduled update (Spanish).
@{
    'update.retry_flag_failed' = 'No se puede guardar la marca de reintento: {0}'
    'update.busy'              = 'Sigue en curso otra ejecución de wmanager; se reintentará en el próximo inicio de sesión.'
    # {0}: wmanager and its version, {1}: update or retry (the job, not translated), {2}: the computer name
    'update.start'             = '{0} {1} en {2}'
    'update.offline'           = 'Sin conexión con: {0}. Se omite la ejecución; se reintentará en el próximo inicio de sesión.'
    'update.deferred'          = 'Aplazado hasta el próximo inicio de sesión: {0}'
    'update.reboot_pending'    = 'El sistema está pendiente de reiniciar; el usuario recibirá una notificación.'
    'update.run_failed'        = 'Ejecución detenida: {0}'
    'update.summary'           = 'Fin: advertencias {0}, errores {1}.'
    # Self-update ({0} of self_update, self_installed and {2} of download_failed, self_update_failed: wmanager and its version)
    'update.self_update'                 = '{0} -> wmanager {1}: el origen de administración indica esta versión; descargando {2}'
    'update.self_update_group'           = '{0} -> wmanager {1} (grupo {2}): el origen de administración indica esta versión; descargando {3}'
    'update.self_update_download_failed' = 'No se puede descargar wmanager {0}: {1}. Se mantiene {2}; la próxima actualización lo reintentará.'
    'update.self_update_bad_hash'        = 'wmanager {0}: el archivo descargado tiene SHA256 {1}, pero el origen de administración indica {2}; no se instala.'
    'update.self_update_not_release'     = 'el archivo no es la versión {0} de wmanager (falta wmanager\VERSION o indica otra versión)'
    'update.self_update_error'           = 'No se puede preparar wmanager {0}: {1}'
    'update.self_update_handover'        = 'Esta ejecución pasa a wmanager {0}.'
    'update.self_installed'              = '{0} instalado; esta ejecución continúa con él.'
    'update.self_install_failed'         = 'No se puede copiar {0} en {1}: {2}'
    'update.self_update_failed'          = 'wmanager {0} no se instaló (código de salida {1}); esta ejecución continúa con {2} y la próxima actualización lo reintentará.'
    'update.self_install_restored'       = '{0}; se restauró la versión anterior'
    'update.self_install_not_restored'   = '{0}; tampoco se pudo restaurar la versión anterior ({1}): vuelva a ejecutar Provision.ps1 en este equipo'
}
