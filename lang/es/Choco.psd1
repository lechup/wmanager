# Messages of lib\Choco.ps1: Chocolatey, the package list, the default browser (Spanish).
@{
    'choco.line_no_package'          = 'Línea {0}: falta el nombre del paquete'
    'choco.line_bad_name'            = 'Línea {0}: nombre de paquete no válido ''{1}'''
    'choco.line_bad_version'         = 'Línea {0}: versión no válida ''{1}'' para ''{2}'''
    'choco.line_unknown_option'      = 'Línea {0}: opción desconocida ''{1}'' (se permiten: !noupdate, !signer="editor" y parámetros de choco tras el signo |)'
    'choco.line_duplicate'           = 'Línea {0}: el paquete ''{1}'' aparece por segunda vez (la primera, en la línea {2})'
    'choco.line_bad_signer'          = 'Línea {0}: !signer necesita el nombre del editor, una sola vez, entre comillas si tiene espacios (p. ej. !signer="Google LLC")'

    'choco.reqs_file_missing'        = 'no se encuentra el archivo: {0}'
    'choco.reqs_loaded'              = 'Lista de paquetes cargada desde: {0}'
    'choco.reqs_source_failed'       = 'Origen de la lista de paquetes no disponible o no válido ({0}): {1}'
    'choco.reqs_using_cache'         = 'Se usa la última copia de la lista descargada correctamente.'
    'choco.reqs_none'                = 'No hay ninguna lista de paquetes disponible (ningún origen responde y no hay copia).'

    'choco.section'                  = '--- Chocolatey ---'
    'choco.already_installed'        = 'Chocolatey ya está instalado.'
    'choco.installing'               = 'Instalando Chocolatey desde {0}'
    'choco.install_failed'           = 'No se pudo instalar Chocolatey.'
    'choco.installed'                = 'Chocolatey instalado.'
    'choco.too_old'                  = 'Chocolatey {0} es demasiado antiguo; actualizando a 2.x.'
    'choco.version_required'         = 'Se requiere Chocolatey 2.x y está instalado {0}.'
    'choco.upgraded'                 = 'Chocolatey actualizado a {0}.'
    'choco.source_disabled'          = 'Origen {0} deshabilitado.'
    'choco.source_failed'            = 'No se pudo configurar el origen {0} (código {1})'
    'choco.source_set'               = 'Origen {0}: {1} (prioridad {2}).'

    # {1}: one of the choco.action_* texts, the subject of the sentence
    'choco.needs_restart'            = '{0} : {1} requiere reiniciar.'
    'choco.action_failed'            = '{0} : {1} ha fallado (código {2}); detalles en el registro local.'
    'choco.action_install'           = 'la instalación'
    'choco.action_install_version'   = 'la instalación de la versión {0}'
    'choco.action_upgrade'           = 'la actualización'

    # A download whose checksum doesn't match the package, checked by its signature instead (Invoke-WmChocoPackage)
    'choco.checksum_no_signer'       = '{0}: el archivo descargado no coincide con la suma de comprobación del paquete (a menudo una versión nueva en la misma dirección antes de que se actualice el paquete; la próxima actualización lo reintentará). Con !signer="editor" en su línea de la lista, wmanager comprueba en su lugar la firma del archivo.'
    'choco.checksum_check_signature' = '{0}: {1} no coincide con la suma de comprobación del paquete; se comprueba en su lugar su firma de {2}.'
    'choco.signature_no_file'        = '{0}: el archivo que comprobar ya no está ({1}) y no se conoce su dirección.'
    'choco.signature_download_failed' = '{0}: no se pudo descargar de {1} el archivo que comprobar: {2}'
    'choco.signature_bad'            = '{0}: {1} no tiene una firma válida de {2} ({3}): no se instala.'
    'choco.signature_ok'             = '{0}: {1} está firmado por {2}: se instala con su propia suma de comprobación.'

    'choco.packages_section'         = '--- Paquetes ({0} en la lista) ---'
    'choco.running_version_deferred' = '{0}: el programa está en ejecución; cambio de versión aplazado.'
    'choco.version_set'              = '{0}: versión {1} establecida.'
    'choco.version_pinned'           = '{0}: versión {1} fijada.'
    'choco.pin_removed'              = '{0}: fijación de versión quitada.'
    'choco.package_installed'        = '{0}: instalado.'
    'choco.running_upgrade_deferred' = '{0}: el programa está en ejecución; actualización aplazada hasta el próximo inicio de sesión.'
    'choco.package_upgraded'         = '{0}: actualizado desde {1}.'

    'choco.browser_missing'          = '{0} no está instalado ({1}); se omite la configuración del navegador predeterminado.'
    'choco.browser_set'              = '{0} establecido como navegador predeterminado para cuentas nuevas.'
    'choco.browser_dism_failed'      = 'DISM no estableció el navegador predeterminado (código {0}): {1}'
}
