# Messages of lib\Managed.ps1: the management source, group scripts and jobs (Czech).
@{
    'managed.manifest_no_source_id'      = 'manifest: chybí nebo je neplatný identifikátor zdroje (SourceId)'
    'managed.manifest_other_source'      = 'manifest patří jinému zdroji ({0}), ne {1} z konfigurace'
    'managed.manifest_no_serial'         = 'manifest: chybí nebo je neplatné pořadové číslo (Serial)'
    'managed.manifest_no_files'          = 'manifest: chybí seznam souborů (Files)'
    'managed.manifest_bad_path'          = "manifest: nepovolená cesta '{0}'"
    'managed.manifest_lists_itself'      = 'manifest: nesmí uvádět sám sebe'
    'managed.manifest_bad_hash'          = "manifest: neplatný hash SHA256 pro '{0}'"
    'managed.manifest_duplicate_path'    = "manifest: cesta '{0}' se vyskytuje dvakrát"

    'managed.groups_unknown_key'         = "groups.psd1: neznámý klíč '{0}' (povoleno: Default, Computers)"
    'managed.groups_computers_not_table' = "groups.psd1: Computers musí být tabulka @{{ 'NÁZEV' = @('skupina') }}"
    'managed.groups_empty_computer'      = 'groups.psd1: prázdný název počítače'
    'managed.groups_bad_group'           = "groups.psd1: neplatný název skupiny '{0}'"

    'managed.common_list'                = 'společný seznam'
    'managed.package_group_replaces'     = 'Balíček {0}: záznam skupiny {1} nahrazuje záznam ze společného seznamu.'
    'managed.package_conflict'           = "Balíček {0} je v '{1}' a '{2}' popsán odlišně; použije se záznam z '{1}'."
    'managed.unknown_period'             = "neznámá četnost '{0}'"

    'managed.cert_missing'               = 'Podpisový certifikát nenalezen: {0}'
    'managed.cert_private_key'           = '{0} obsahuje privátní klíč; na počítače patří jen veřejný .cer'
    'managed.cert_is_ca'                 = '{0} je certifikát certifikační autority (CA); wmanager ho nepřidá mezi důvěryhodné'
    'managed.cert_not_code_signing'      = '{0} není certifikát pro podepisování kódu (chybí použití Code Signing)'
    'managed.cert_expired'               = 'Platnost podpisového certifikátu vypršela {0}; fungují už jen podpisy s časovým razítkem.'
    'managed.cert_expiring'              = 'Platnost podpisového certifikátu vyprší {0}; připravte nový.'
    'managed.cert_previous_removed'      = 'Předchozí podpisový certifikát wmanager odebrán z důvěryhodných kořenových certifikátů ({0}).'
    'managed.cert_added'                 = "Podpisový certifikát wmanager přidán do důvěryhodných kořenových certifikačních autorit počítače ({0})."
    'managed.signature_invalid'          = 'neplatný podpis manifestu ({0}): {1}'
    'managed.signature_other_cert'       = 'manifest je podepsán jiným certifikátem ({0}) než certifikátem z konfigurace ({1})'

    'managed.saved_copy_invalid'         = 'Uložená kopie zdroje správy je neplatná: {0}'
    'managed.file_error'                 = '{0}: {1}'
    'managed.source_unreachable'         = 'Zdroj správy je nedostupný ({0}): {1}'
    'managed.manifest_older'             = 'manifest {0} je starší než dříve přijatý {1}'
    'managed.manifest_same_serial'       = 'manifest má stejné číslo {0} jako dříve přijatý, ale jiné soubory'
    'managed.source_unchanged'           = 'Zdroj správy beze změny (manifest {0}).'
    'managed.download_failed'            = 'nepodařilo se stáhnout {0}: {1}'
    'managed.hash_mismatch'              = '{0} má jiný hash SHA256 než v manifestu (soubor byl změněn nebo ještě není publikován)'
    'managed.swap_failed'                = 'nelze nahradit {0} (nepoužívá nějaký program soubory z této složky?): {1}'
    'managed.manifest_accepted'          = 'Zdroj správy: přijat manifest {0} (souborů: {1}).'

    'managed.no_source'                  = 'V konfiguraci chybí Management.Source.'
    'managed.new_version_rejected'       = 'Nová verze ze zdroje správy odmítnuta: {0}'
    'managed.no_verified_copy'           = 'Žádná ověřená verze zdroje správy (nepodařilo se ji stáhnout a kopie neexistuje).'
    'managed.using_last_copy'            = 'Použije se poslední ověřená kopie zdroje správy (manifest {0}).'
    'managed.computer_groups'            = 'Skupiny počítače {0}: {1}.'
    'managed.computer_no_groups'         = 'Počítač {0} nepatří do žádné skupiny (jen společný seznam).'
    'managed.group_no_files'             = 'Skupina {0} nemá ve zdroji správy žádné soubory.'
    'managed.source_info'                = 'Zdroj správy: {0} ({1}), certifikát {2} ({3}).'

    'managed.scripts_section'            = '--- Skripty skupin ---'
    'managed.no_scripts'                 = 'Pro skupiny tohoto počítače nejsou žádné skripty.'
    'managed.script_unchanged'           = '{0}: beze změny.'
    'managed.script_starting'            = '{0}: spouští se.'
    'managed.retry_next_update'          = 'další pokus při příští aktualizaci'
    'managed.retry_after_hours'          = 'další pokus za {0} h nebo po změně skriptu'
    'managed.script_timeout'             = '{0}: vypršel časový limit ({1} min), zastaveno; {2}.'
    'managed.script_exit_code'           = '{0}: skončil s ukončovacím kódem {1}; {2}.'
    'managed.script_done_reboot'         = '{0}: hotovo, je potřeba restart.'
    'managed.script_done'                = '{0}: hotovo.'
    'managed.scripts_state_failed'       = 'Nelze uložit stav skriptů: {0}'

    'managed.jobs_state_failed'          = 'Nelze uložit stav úkolů: {0}'
    'managed.job_starting'               = 'Úkol {0} ({1}): spouští se.'
    'managed.job_timeout'                = 'Úkol {0}: vypršel časový limit ({1} min), zastaven.'
    'managed.job_exit_code'              = 'Úkol {0}: skončil s ukončovacím kódem {1}.'
    'managed.job_done'                   = 'Úkol {0}: hotovo.'
}
