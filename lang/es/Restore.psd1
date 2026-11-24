# Messages of Restore-Backup.ps1 (Spanish).
@{
    'restore.no_backup'                 = 'No hay copia de seguridad en {0}: wmanager no se ha ejecutado aquí.'
    'restore.lock_wait'                 = 'Hay otra ejecución de wmanager en curso (p. ej. trabajos de grupo); esperando hasta 10 minutos...'
    'restore.lock_busy'                 = 'Sigue en curso otra ejecución de wmanager. Inténtalo de nuevo en un momento.'
    'restore.journal_read_failed'       = 'No se puede leer el diario de cambios: {0}'
    'restore.start'                     = '{0}: restaurando en {1}. Diario: {2} valores del equipo, {3} valores de usuario; copias de seguridad: {4}.'
    'restore.confirm'                   = '¿Deshacer los cambios de wmanager?'
    'restore.cancelled'                 = 'Cancelado; no se ha cambiado nada.'
    'restore.profile_not_found'         = 'El perfil {0} no existe o no se pudo cargar; su configuración no se ha restaurado.'
    'restore.registry_summary'          = 'Valores del Registro restaurados: {0} de {1}.'
    'restore.store_apps_removed'        = 'Aplicaciones de Microsoft Store quitadas desde la copia de seguridad {0} ({1}); vuelve a instalarlas desde Microsoft Store si las necesitas:'
    'restore.onedrive_removed'          = 'OneDrive se desinstaló; si lo necesitas, vuelve a instalarlo desde el sitio web de Microsoft.'
    'restore.confirm_disable_tasks'     = '¿Deshabilitar las tareas de wmanager? Si no, la actualización programada volverá a quitar las aplicaciones y a cambiar la configuración.'
    'restore.tasks_disabled'            = 'Tareas de wmanager deshabilitadas ({0}).'
    'restore.tasks_kept'                = 'Las tareas de wmanager siguen habilitadas; la actualización programada volverá a aplicar la configuración.'
    'restore.certificate_removed'       = 'Certificado de firma de wmanager quitado del almacén de confianza ({0}).'
    'restore.certificate_remove_failed' = 'No se pudo quitar el certificado de firma de wmanager del almacén de confianza: {0}'
    'restore.stopped'                   = 'Restauración detenida: {0}'
    'restore.summary'                   = 'Listo: {0} advertencias, {1} errores. Registro: {2}'
    'restore.finished_with_errors'      = 'La restauración terminó con errores. Revisa el registro de arriba.'
    'restore.finished'                  = 'Restauración terminada. Reinicia el equipo para que se aplique la configuración.'

    # Accounts: a separate administrator, the person signed in a standard user (lib\Accounts.ps1)
    'restore.confirm_admin_again'                = '¿Devolver los derechos de administrador a las personas que la instalación convirtió en usuarios estándar?'
    'restore.admin_again'                        = '{0} vuelve a ser administrador.'
    'restore.admin_again_failed'                 = '{0} no pudo volver a ser administrador: {1}'
    'restore.admin_account_stays'                = 'La cuenta de administrador {0} se queda (de nuevo visible en la pantalla de inicio de sesión); elimínela a mano si no hace falta.'
}
