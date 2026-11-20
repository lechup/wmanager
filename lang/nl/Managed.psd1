# Messages of lib\Managed.ps1: the management source, group scripts and jobs (Dutch).
@{
    'managed.manifest_no_source_id'      = 'manifest: bron-ID (SourceId) ontbreekt of is ongeldig'
    'managed.manifest_other_source'      = 'manifest hoort bij een andere bron ({0}), niet bij {1} uit de configuratie'
    'managed.manifest_no_serial'         = 'manifest: volgnummer (Serial) ontbreekt of is ongeldig'
    'managed.manifest_no_files'          = 'manifest: geen bestandslijst (Files)'
    'managed.manifest_bad_path'          = "manifest: pad niet toegestaan '{0}'"
    'managed.manifest_lists_itself'      = 'manifest: het mag zichzelf niet vermelden'
    'managed.manifest_bad_hash'          = "manifest: ongeldige SHA256-hash voor '{0}'"
    'managed.manifest_duplicate_path'    = "manifest: pad '{0}' komt twee keer voor"

    'managed.groups_unknown_key'         = "groups.psd1: onbekende sleutel '{0}' (toegestaan: Default, Computers)"
    'managed.groups_computers_not_table' = "groups.psd1: Computers moet een tabel zijn @{{ 'NAAM' = @('groep') }}"
    'managed.groups_empty_computer'      = 'groups.psd1: lege computernaam'
    'managed.groups_bad_group'           = "groups.psd1: ongeldige groepsnaam '{0}'"

    'managed.common_list'                = 'gemeenschappelijke lijst'
    'managed.package_group_replaces'     = 'Pakket {0}: de vermelding van groep {1} vervangt de vermelding van de gemeenschappelijke lijst.'
    'managed.package_conflict'           = "Pakket {0} is verschillend beschreven in '{1}' en '{2}'; de vermelding uit '{1}' wordt gebruikt."
    'managed.unknown_period'             = "onbekende frequentie '{0}'"

    'managed.cert_missing'               = 'Ondertekeningscertificaat niet gevonden: {0}'
    'managed.cert_private_key'           = '{0} bevat een persoonlijke sleutel; alleen de openbare .cer gaat naar de computers'
    'managed.cert_is_ca'                 = '{0} is een certificaat van een certificeringsinstantie (CA); wmanager voegt het niet toe aan de vertrouwde certificaten'
    'managed.cert_not_code_signing'      = '{0} is geen certificaat voor ondertekening van code (geen Code Signing-gebruik)'
    'managed.cert_expired'               = 'Het ondertekeningscertificaat is verlopen op {0}; alleen handtekeningen met een tijdstempel werken nog.'
    'managed.cert_expiring'              = 'Het ondertekeningscertificaat verloopt op {0}; bereid een nieuw certificaat voor.'
    'managed.cert_previous_removed'      = 'Het vorige ondertekeningscertificaat van wmanager is verwijderd uit de vertrouwde basiscertificeringsinstanties ({0}).'
    'managed.cert_added'                 = "Het ondertekeningscertificaat van wmanager is toegevoegd aan de vertrouwde basiscertificeringsinstanties van de computer ({0})."
    'managed.signature_invalid'          = 'ongeldige handtekening van het manifest ({0}): {1}'
    'managed.signature_other_cert'       = 'manifest ondertekend met een ander certificaat ({0}) dan dat uit de configuratie ({1})'

    'managed.saved_copy_invalid'         = 'De opgeslagen kopie van de beheerbron is ongeldig: {0}'
    'managed.file_error'                 = '{0}: {1}'
    'managed.source_unreachable'         = 'Beheerbron onbereikbaar ({0}): {1}'
    'managed.manifest_older'             = 'manifest {0} is ouder dan het eerder geaccepteerde {1}'
    'managed.manifest_same_serial'       = 'manifest heeft hetzelfde nummer {0} als het eerder geaccepteerde, maar andere bestanden'
    'managed.source_unchanged'           = 'Beheerbron ongewijzigd (manifest {0}).'
    'managed.download_failed'            = 'kan {0} niet downloaden: {1}'
    'managed.hash_mismatch'              = '{0} heeft een andere SHA256-hash dan in het manifest (het bestand is gewijzigd of nog niet gepubliceerd)'
    'managed.swap_failed'                = 'kan {0} niet vervangen (gebruikt een programma bestanden uit deze map?): {1}'
    'managed.manifest_accepted'          = 'Beheerbron: manifest {0} geaccepteerd ({1} bestanden).'

    'managed.no_source'                  = 'Geen Management.Source in de configuratie.'
    'managed.new_version_rejected'       = 'Nieuwe versie van de beheerbron geweigerd: {0}'
    'managed.no_verified_copy'           = 'Geen geverifieerde versie van de beheerbron (downloaden is mislukt en er is geen kopie).'
    'managed.using_last_copy'            = 'De laatste geverifieerde kopie van de beheerbron wordt gebruikt (manifest {0}).'
    'managed.computer_groups'            = 'Groepen van computer {0}: {1}.'
    'managed.computer_no_groups'         = 'Computer {0} hoort bij geen enkele groep (alleen de gemeenschappelijke lijst).'
    'managed.group_no_files'             = 'Groep {0} heeft geen bestanden in de beheerbron.'
    'managed.source_info'                = 'Beheerbron: {0} ({1}), certificaat {2} ({3}).'

    'managed.scripts_section'            = '--- Groepsscripts ---'
    'managed.no_scripts'                 = 'Geen scripts voor de groepen van deze computer.'
    'managed.script_unchanged'           = '{0}: ongewijzigd.'
    'managed.script_starting'            = '{0}: wordt gestart.'
    'managed.retry_next_update'          = 'nieuwe poging bij de volgende update'
    'managed.retry_after_hours'          = 'nieuwe poging over {0} uur of na een wijziging van het script'
    'managed.script_timeout'             = '{0}: time-out ({1} min), gestopt; {2}.'
    'managed.script_exit_code'           = '{0}: beëindigd met afsluitcode {1}; {2}.'
    'managed.script_done_reboot'         = '{0}: voltooid, opnieuw opstarten is vereist.'
    'managed.script_done'                = '{0}: voltooid.'
    'managed.scripts_state_failed'       = 'Kan de status van de scripts niet opslaan: {0}'

    'managed.jobs_state_failed'          = 'Kan de status van de opdrachten niet opslaan: {0}'
    'managed.job_starting'               = 'Opdracht {0} ({1}): wordt gestart.'
    'managed.job_timeout'                = 'Opdracht {0}: time-out ({1} min), gestopt.'
    'managed.job_exit_code'              = 'Opdracht {0}: beëindigd met afsluitcode {1}.'
    'managed.job_done'                   = 'Opdracht {0}: voltooid.'
    # version.psd1 ({0}: the entry, e.g. Groups.test.Url; {1}: its value)
    'managed.version_unknown_key'      = 'version.psd1: onbekende sleutel ''{0}'' (toegestaan: Version, Url, Sha256, Groups)'
    'managed.version_missing'          = 'version.psd1: {0} ontbreekt (een versie heeft Version, Url en Sha256 nodig)'
    'managed.version_bad_tag'          = 'version.psd1: {0} is geen wmanager-versie zoals v0.2.0: {1}'
    'managed.version_bad_url'          = 'version.psd1: {0} moet een https://-adres of een pad zijn (C:\..., \\server\share\...): {1}'
    'managed.version_bad_hash'         = 'version.psd1: {0} is geen SHA256 (64 hexadecimale cijfers)'
    'managed.version_bad_group'        = 'version.psd1: ongeldige groepsnaam in Groups: ''{0}'''
    'managed.version_groups_not_table' = 'version.psd1: Groups moet elke groep een eigen Version, Url en Sha256 geven'
    'managed.cert_next_added'            = 'De bron noemt zijn volgende ondertekeningscertificaat ({0}); dat wordt ook vertrouwd tot de bron erop overstapt.'
    'managed.cert_switched'              = 'De bron is ondertekend met het volgende certificaat {0}: dat is nu het certificaat van deze computer, in plaats van {1}.'
    'managed.cert_next_removed'          = 'De bron noemt het volgende ondertekeningscertificaat {0} niet meer; het wordt niet meer vertrouwd.'
    'managed.cert_next_invalid'          = 'Het volgende ondertekeningscertificaat van de bron is niet bruikbaar: {0}'
    'managed.cert_change_failed'         = 'Het ondertekeningscertificaat kon niet worden gewisseld: {0}. Deze run houdt het huidige; de volgende probeert het opnieuw.'
}
