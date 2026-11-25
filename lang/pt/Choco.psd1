# Messages of lib\Choco.ps1: Chocolatey, the package list, the default browser (Portuguese).
@{
    'choco.line_no_package'          = 'Linha {0}: sem nome de pacote'
    'choco.line_bad_name'            = 'Linha {0}: nome de pacote inválido ''{1}'''
    'choco.line_bad_version'         = 'Linha {0}: versão inválida ''{1}'' para ''{2}'''
    'choco.line_unknown_option'      = 'Linha {0}: opção desconhecida ''{1}'' (permitidos: !noupdate, !signer="editor" e parâmetros do choco depois do sinal |)'
    'choco.line_duplicate'           = 'Linha {0}: o pacote ''{1}'' aparece pela segunda vez (a primeira na linha {2})'
    'choco.line_bad_signer'          = 'Linha {0}: !signer precisa do nome do editor, uma só vez, entre aspas se tiver espaços (p. ex. !signer="Google LLC")'

    'choco.reqs_file_missing'        = 'ficheiro não encontrado: {0}'
    'choco.reqs_loaded'              = 'Lista de pacotes carregada de: {0}'
    'choco.reqs_source_failed'       = 'Origem da lista de pacotes indisponível ou inválida ({0}): {1}'
    'choco.reqs_using_cache'         = 'A usar a última cópia da lista transferida corretamente.'
    'choco.reqs_none'                = 'Nenhuma lista de pacotes disponível (nenhuma origem responde e não há cópia).'

    'choco.section'                  = '--- Chocolatey ---'
    'choco.already_installed'        = 'O Chocolatey já está instalado.'
    'choco.installing'               = 'A instalar o Chocolatey a partir de {0}'
    'choco.install_failed'           = 'A instalação do Chocolatey falhou.'
    'choco.installed'                = 'Chocolatey instalado.'
    'choco.too_old'                  = 'O Chocolatey {0} é demasiado antigo, a atualizar para 2.x.'
    'choco.version_required'         = 'É necessário o Chocolatey 2.x, está instalado o {0}.'
    'choco.upgraded'                 = 'Chocolatey atualizado para {0}.'
    'choco.source_disabled'          = 'Origem {0} desativada.'
    'choco.source_failed'            = 'Não foi possível definir a origem {0} (código {1})'
    'choco.source_set'               = 'Origem {0}: {1} (prioridade {2}).'

    # {1}: one of the choco.action_* texts, the subject of the sentence
    'choco.needs_restart'            = '{0} : {1} requer um reinício.'
    'choco.action_failed'            = '{0} : {1} falhou (código {2}), detalhes no registo local.'
    'choco.action_install'           = 'a instalação'
    'choco.action_install_version'   = 'a instalação da versão {0}'
    'choco.action_upgrade'           = 'a atualização'

    # A download whose checksum doesn't match the package, checked by its signature instead (Invoke-WmChocoPackage)
    'choco.checksum_pinned'          = '{0}: o ficheiro transferido não corresponde à soma de verificação da versão fixada {1}: o endereço serve agora outra versão, por isso não é instalado (uma versão fixada é só o ficheiro dessa versão).'
    'choco.checksum_own'             = '{0}: o ficheiro transferido não corresponde à soma de verificação indicada depois de | na lista: não instalado.'
    'choco.checksum_no_signer'       = '{0}: o ficheiro transferido não corresponde à soma de verificação do pacote (muitas vezes uma versão nova no mesmo endereço antes de o pacote ser atualizado; a próxima atualização tenta de novo). Com !signer="editor" na sua linha da lista, o wmanager verifica antes a assinatura do ficheiro.'
    'choco.checksum_check_signature' = '{0}: {1} não corresponde à soma de verificação do pacote; verifica-se antes a sua assinatura de {2}.'
    'choco.signature_no_file'        = '{0}: o ficheiro a verificar já não existe ({1}) e o seu endereço não é conhecido.'
    'choco.signature_download_failed' = '{0}: não foi possível transferir de {1} o ficheiro a verificar: {2}'
    'choco.signature_bad'            = '{0}: {1} não tem uma assinatura válida de {2} ({3}): não instalado.'
    'choco.signature_ok'             = '{0}: {1} está assinado por {2}: a instalar com a sua própria soma de verificação.'
    'choco.signature_check_failed'   = '{0}: não foi possível verificar a assinatura de {1}: {2}'

    'choco.packages_section'         = '--- Pacotes ({0} na lista) ---'
    'choco.running_version_deferred' = '{0}: o programa está em execução, alteração de versão adiada.'
    'choco.version_set'              = '{0}: versão {1} definida.'
    'choco.version_pinned'           = '{0}: versão {1} fixada.'
    'choco.pin_removed'              = '{0}: fixação da versão removida.'
    'choco.package_installed'        = '{0}: instalado.'
    'choco.running_upgrade_deferred' = '{0}: o programa está em execução, atualização adiada para o próximo início de sessão.'
    'choco.package_upgraded'         = '{0}: atualizado da versão {1}.'

    'choco.browser_missing'          = '{0} não está instalado ({1}), a ignorar a definição do browser predefinido.'
    'choco.browser_set'              = '{0} definido como browser predefinido para novas contas.'
    'choco.browser_dism_failed'      = 'O DISM não definiu o browser predefinido (código {0}): {1}'
}
