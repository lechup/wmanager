# Messages of lib\Managed.ps1: the management source, group scripts and jobs (Romanian).
@{
    'managed.manifest_no_source_id'      = 'manifest: identificatorul sursei (SourceId) lipsește sau nu este valid'
    'managed.manifest_other_source'      = 'manifestul aparține altei surse ({0}), nu sursei {1} din configurație'
    'managed.manifest_no_serial'         = 'manifest: numărul Serial lipsește sau nu este valid'
    'managed.manifest_no_files'          = 'manifest: lipsește lista de fișiere (Files)'
    'managed.manifest_bad_path'          = "manifest: cale nepermisă '{0}'"
    'managed.manifest_lists_itself'      = 'manifest: nu trebuie să se includă pe sine în listă'
    'managed.manifest_bad_hash'          = "manifest: hash SHA256 nevalid pentru '{0}'"
    'managed.manifest_duplicate_path'    = "manifest: calea '{0}' apare de două ori"

    'managed.groups_unknown_key'         = "groups.psd1: cheie necunoscută '{0}' (permise: Default, Computers)"
    'managed.groups_computers_not_table' = "groups.psd1: Computers trebuie să fie un tabel @{{ 'NUME' = @('grup') }}"
    'managed.groups_empty_computer'      = 'groups.psd1: nume de computer gol'
    'managed.groups_bad_group'           = "groups.psd1: nume de grup nevalid '{0}'"

    'managed.common_list'                = 'lista comună'
    'managed.package_group_replaces'     = 'Pachetul {0}: intrarea grupului {1} înlocuiește intrarea din lista comună.'
    'managed.package_conflict'           = "Pachetul {0} este descris diferit în '{1}' și '{2}'; se folosește intrarea din '{1}'."
    'managed.unknown_period'             = "frecvență necunoscută '{0}'"

    'managed.cert_missing'               = 'Certificatul de semnare nu a fost găsit: {0}'
    'managed.cert_private_key'           = '{0} conține o cheie privată; pe computere ajunge doar fișierul .cer public'
    'managed.cert_is_ca'                 = '{0} este un certificat de autoritate de certificare (CA); wmanager nu îl va adăuga la cele de încredere'
    'managed.cert_not_code_signing'      = '{0} nu este un certificat de semnare a codului (lipsește utilizarea Code Signing)'
    'managed.cert_expired'               = 'Certificatul de semnare a expirat pe {0}; funcționează doar semnăturile cu marcaj de timp.'
    'managed.cert_expiring'              = 'Certificatul de semnare expiră pe {0}; pregătiți unul nou.'
    'managed.cert_previous_removed'      = 'Certificatul de semnare wmanager anterior a fost eliminat din rădăcinile de încredere ({0}).'
    'managed.cert_added'                 = "Certificatul de semnare wmanager a fost adăugat la autoritățile de certificare rădăcină de încredere ale computerului ({0})."
    'managed.signature_invalid'          = 'semnătura manifestului nu este validă ({0}): {1}'
    'managed.signature_other_cert'       = 'manifest semnat cu alt certificat ({0}) decât cel din configurație ({1})'

    'managed.saved_copy_invalid'         = 'Copia salvată a sursei de gestionare nu este validă: {0}'
    'managed.file_error'                 = '{0}: {1}'
    'managed.source_unreachable'         = 'Sursa de gestionare nu este accesibilă ({0}): {1}'
    'managed.manifest_older'             = 'manifestul {0} este mai vechi decât cel acceptat anterior, {1}'
    'managed.manifest_same_serial'       = 'manifestul are același număr {0} ca cel acceptat anterior, dar fișiere diferite'
    'managed.source_unchanged'           = 'Sursa de gestionare nu s-a schimbat (manifest {0}).'
    'managed.download_failed'            = 'nu s-a putut descărca {0}: {1}'
    'managed.hash_mismatch'              = '{0} are alt hash SHA256 decât cel din manifest (fișierul a fost modificat sau nu este încă publicat)'
    'managed.swap_failed'                = 'nu se poate înlocui {0} (folosește vreun program fișiere din acest folder?): {1}'
    'managed.manifest_accepted'          = 'Sursa de gestionare: s-a acceptat manifestul {0} (fișiere: {1}).'

    'managed.no_source'                  = 'Nu există Management.Source în configurație.'
    'managed.new_version_rejected'       = 'S-a respins noua versiune din sursa de gestionare: {0}'
    'managed.no_verified_copy'           = 'Nu există nicio versiune verificată a sursei de gestionare (nu a putut fi descărcată și nu există o copie).'
    'managed.using_last_copy'            = 'Se folosește ultima copie verificată a sursei de gestionare (manifest {0}).'
    'managed.computer_groups'            = 'Grupurile computerului {0}: {1}.'
    'managed.computer_no_groups'         = 'Computerul {0} nu aparține niciunui grup (doar lista comună).'
    'managed.group_no_files'             = 'Grupul {0} nu are fișiere în sursa de gestionare.'
    'managed.source_info'                = 'Sursa de gestionare: {0} ({1}), certificat {2} ({3}).'

    'managed.scripts_section'            = '--- Scripturile grupurilor ---'
    'managed.no_scripts'                 = 'Niciun script pentru grupurile acestui computer.'
    'managed.script_unchanged'           = '{0}: nemodificat.'
    'managed.script_starting'            = '{0}: pornește.'
    'managed.retry_next_update'          = 'se va reîncerca la următoarea actualizare'
    'managed.retry_after_hours'          = 'se va reîncerca peste {0} h sau după modificarea scriptului'
    'managed.script_timeout'             = '{0}: timpul a expirat ({1} min), oprit; {2}.'
    'managed.script_exit_code'           = '{0}: s-a încheiat cu codul de ieșire {1}; {2}.'
    'managed.script_done_reboot'         = '{0}: gata, este necesară o repornire.'
    'managed.script_done'                = '{0}: gata.'
    'managed.scripts_state_failed'       = 'Nu se poate salva starea scripturilor: {0}'

    'managed.jobs_state_failed'          = 'Nu se poate salva starea lucrărilor: {0}'
    'managed.job_starting'               = 'Lucrarea {0} ({1}): pornește.'
    'managed.job_timeout'                = 'Lucrarea {0}: timpul a expirat ({1} min), oprită.'
    'managed.job_exit_code'              = 'Lucrarea {0}: s-a încheiat cu codul de ieșire {1}.'
    'managed.job_done'                   = 'Lucrarea {0}: gata.'
    # version.psd1 ({0}: the entry, e.g. Groups.test.Url; {1}: its value)
    'managed.version_unknown_key'      = 'version.psd1: cheie necunoscută ''{0}'' (permise: Version, Url, Sha256, Groups)'
    'managed.version_missing'          = 'version.psd1: lipsește {0} (o versiune are nevoie de Version, Url și Sha256)'
    'managed.version_bad_tag'          = 'version.psd1: {0} nu este o versiune wmanager precum v0.2.0: {1}'
    'managed.version_bad_url'          = 'version.psd1: {0} trebuie să fie o adresă https:// sau o cale (C:\..., \\server\partajare\...): {1}'
    'managed.version_bad_hash'         = 'version.psd1: {0} nu este un SHA256 (64 de cifre hexazecimale)'
    'managed.version_bad_group'        = 'version.psd1: nume de grup nevalid în Groups: ''{0}'''
    'managed.version_groups_not_table' = 'version.psd1: Groups trebuie să dea fiecărui grup propriile Version, Url și Sha256'
    'managed.cert_next_added'            = 'Sursa indică următorul său certificat de semnare ({0}); este de încredere și el până când sursa trece la el.'
    'managed.cert_switched'              = 'Sursa este semnată cu următorul certificat {0}: acum este cel al acestui calculator, în locul lui {1}.'
    'managed.cert_next_removed'          = 'Sursa nu mai indică următorul certificat de semnare {0}; nu mai este de încredere.'
    'managed.cert_next_invalid'          = 'Următorul certificat de semnare al sursei nu poate fi folosit: {0}'
    'managed.cert_change_failed'         = 'Certificatul de semnare nu a putut fi schimbat: {0}. Această rulare îl păstrează pe cel actual; următoarea încearcă din nou.'
}
