# Messages of lib\Choco.ps1: Chocolatey, the package list, the default browser (Italian).
@{
    'choco.line_no_package'          = 'Riga {0}: nome del pacchetto mancante'
    'choco.line_bad_name'            = 'Riga {0}: nome del pacchetto ''{1}'' non valido'
    'choco.line_bad_version'         = 'Riga {0}: versione ''{1}'' non valida per ''{2}'''
    'choco.line_unknown_option'      = 'Riga {0}: opzione sconosciuta ''{1}'' (consentite: !noupdate, !signer="editore" e i parametri di choco dopo il segno |)'
    'choco.line_duplicate'           = 'Riga {0}: il pacchetto ''{1}'' compare una seconda volta (la prima alla riga {2})'
    'choco.line_bad_signer'          = 'Riga {0}: !signer richiede il nome dell''editore, una sola volta, tra virgolette se contiene spazi (es. !signer="Google LLC")'

    'choco.reqs_file_missing'        = 'file non trovato: {0}'
    'choco.reqs_loaded'              = 'Elenco dei pacchetti caricato da: {0}'
    'choco.reqs_source_failed'       = 'Origine dell''elenco dei pacchetti non disponibile o non valida ({0}): {1}'
    'choco.reqs_using_cache'         = 'Viene usata l''ultima copia dell''elenco scaricata correttamente.'
    'choco.reqs_none'                = 'Nessun elenco dei pacchetti disponibile (nessuna origine risponde e non c''è una copia).'

    'choco.section'                  = '--- Chocolatey ---'
    'choco.already_installed'        = 'Chocolatey è già installato.'
    'choco.installing'               = 'Installazione di Chocolatey da {0}'
    'choco.install_failed'           = 'Installazione di Chocolatey non riuscita.'
    'choco.installed'                = 'Chocolatey installato.'
    'choco.too_old'                  = 'Chocolatey {0} è troppo vecchio, aggiornamento a 2.x.'
    'choco.version_required'         = 'È richiesto Chocolatey 2.x, è installato {0}.'
    'choco.upgraded'                 = 'Chocolatey aggiornato a {0}.'
    'choco.source_disabled'          = 'Origine {0} disattivata.'
    'choco.source_failed'            = 'Impossibile impostare l''origine {0} (codice {1})'
    'choco.source_set'               = 'Origine {0}: {1} (priorità {2}).'

    # {1}: one of the choco.action_* texts, the subject of the sentence
    'choco.needs_restart'            = '{0} : {1} richiede un riavvio.'
    'choco.action_failed'            = '{0} : errore durante {1} (codice {2}), dettagli nel log locale.'
    'choco.action_install'           = 'l''installazione'
    'choco.action_install_version'   = 'l''installazione della versione {0}'
    'choco.action_upgrade'           = 'l''aggiornamento'

    # A download whose checksum doesn't match the package, checked by its signature instead (Invoke-WmChocoPackage)
    'choco.checksum_pinned'          = '{0}: il file scaricato non corrisponde al checksum della versione fissata {1}: l''indirizzo ora fornisce un''altra versione, quindi non viene installato (una versione fissata è solo il file di quella versione).'
    'choco.checksum_own'             = '{0}: il file scaricato non corrisponde al checksum indicato dopo | nell''elenco: non installato.'
    'choco.checksum_no_signer'       = '{0}: il file scaricato non corrisponde al checksum del pacchetto (spesso una nuova versione allo stesso indirizzo prima che il pacchetto venga aggiornato; il prossimo aggiornamento riproverà). Con !signer="editore" nella sua riga dell''elenco, wmanager controlla invece la firma del file.'
    'choco.checksum_check_signature' = '{0}: {1} non corrisponde al checksum del pacchetto; si controlla invece la sua firma di {2}.'
    'choco.signature_no_file'        = '{0}: il file da controllare non c''è più ({1}) e il suo indirizzo non è noto.'
    'choco.signature_download_failed' = '{0}: non è stato possibile scaricare da {1} il file da controllare: {2}'
    'choco.signature_bad'            = '{0}: {1} non ha una firma valida di {2} ({3}): non installato.'
    'choco.signature_ok'             = '{0}: {1} è firmato da {2}: installazione con il suo checksum.'
    'choco.signature_check_failed'   = '{0}: non è stato possibile controllare la firma di {1}: {2}'

    'choco.packages_section'         = '--- Pacchetti ({0} nell''elenco) ---'
    'choco.running_version_deferred' = '{0}: il programma è in esecuzione, cambio di versione rimandato.'
    'choco.version_set'              = '{0}: impostata la versione {1}.'
    'choco.version_pinned'           = '{0}: versione {1} bloccata.'
    'choco.pin_removed'              = '{0}: blocco della versione rimosso.'
    'choco.package_installed'        = '{0}: installato.'
    'choco.running_upgrade_deferred' = '{0}: il programma è in esecuzione, aggiornamento rimandato al prossimo accesso.'
    'choco.package_upgraded'         = '{0}: aggiornato da {1}.'

    'choco.browser_missing'          = '{0} non è installato ({1}), l''impostazione del browser predefinito viene saltata.'
    'choco.browser_set'              = '{0} impostato come browser predefinito per i nuovi account.'
    'choco.browser_dism_failed'      = 'DISM non ha impostato il browser predefinito (codice {0}): {1}'
}
