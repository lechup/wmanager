# Messages of lib\Choco.ps1: Chocolatey, the package list, the default browser (Romanian).
@{
    'choco.line_no_package'          = 'Linia {0}: lipsește numele pachetului'
    'choco.line_bad_name'            = "Linia {0}: nume de pachet nevalid '{1}'"
    'choco.line_bad_version'         = "Linia {0}: versiune nevalidă '{1}' pentru '{2}'"
    'choco.line_unknown_option'      = 'Linia {0}: opțiune necunoscută ''{1}'' (permise: !noupdate, !signer="editor" și parametrii choco după semnul |)'
    'choco.line_duplicate'           = "Linia {0}: pachetul '{1}' apare a doua oară (prima dată în linia {2})"
    'choco.line_bad_signer'          = 'Linia {0}: !signer necesită numele editorului, o singură dată, între ghilimele dacă are spații (de ex. !signer="Google LLC")'

    'choco.reqs_file_missing'        = 'fișierul nu a fost găsit: {0}'
    'choco.reqs_loaded'              = 'Lista de pachete a fost încărcată din: {0}'
    'choco.reqs_source_failed'       = 'Sursa listei de pachete nu este disponibilă sau nu este validă ({0}): {1}'
    'choco.reqs_using_cache'         = 'Se folosește ultima copie descărcată corect a listei.'
    'choco.reqs_none'                = 'Nu este disponibilă nicio listă de pachete (nicio sursă nu răspunde și nu există o copie).'

    'choco.section'                  = '--- Chocolatey ---'
    'choco.already_installed'        = 'Chocolatey este deja instalat.'
    'choco.installing'               = 'Se instalează Chocolatey de la {0}'
    'choco.install_failed'           = 'Instalarea Chocolatey a eșuat.'
    'choco.installed'                = 'Chocolatey a fost instalat.'
    'choco.too_old'                  = 'Chocolatey {0} este prea vechi, se actualizează la 2.x.'
    'choco.version_required'         = 'Este necesar Chocolatey 2.x, este instalat {0}.'
    'choco.upgraded'                 = 'Chocolatey a fost actualizat la {0}.'
    'choco.source_disabled'          = 'Sursa {0} a fost dezactivată.'
    'choco.source_failed'            = 'Nu s-a putut seta sursa {0} (cod {1})'
    'choco.source_set'               = 'Sursa {0}: {1} (prioritate {2}).'

    # {1}: one of the choco.action_* texts, the subject of the sentence
    'choco.needs_restart'            = '{0} : {1} necesită o repornire.'
    'choco.action_failed'            = '{0} : {1} a eșuat (cod {2}), detalii în jurnalul local.'
    'choco.action_install'           = 'instalarea'
    'choco.action_install_version'   = 'instalarea versiunii {0}'
    'choco.action_upgrade'           = 'actualizarea'

    # A download whose checksum doesn't match the package, checked by its signature instead (Invoke-WmChocoPackage)
    'choco.checksum_pinned'          = '{0}: fișierul descărcat nu corespunde sumei de control a versiunii fixate {1}: adresa oferă acum o altă versiune, deci nu a fost instalat (o versiune fixată înseamnă doar fișierul acelei versiuni).'
    'choco.checksum_own'             = '{0}: fișierul descărcat nu corespunde sumei de control date după | în listă: nu a fost instalat.'
    'choco.checksum_no_signer'       = '{0}: fișierul descărcat nu corespunde sumei de control a pachetului (adesea o versiune nouă la aceeași adresă înainte ca pachetul să fie actualizat; următoarea actualizare încearcă din nou). Cu !signer="editor" pe linia sa din listă, wmanager verifică în schimb semnătura fișierului.'
    'choco.checksum_check_signature' = '{0}: {1} nu corespunde sumei de control a pachetului; se verifică în schimb semnătura sa de la {2}.'
    'choco.signature_no_file'        = '{0}: fișierul de verificat nu mai există ({1}), iar adresa sa nu este cunoscută.'
    'choco.signature_download_failed' = '{0}: fișierul de verificat nu a putut fi descărcat de la {1}: {2}'
    'choco.signature_bad'            = '{0}: {1} nu are o semnătură validă de la {2} ({3}): nu a fost instalat.'
    'choco.signature_ok'             = '{0}: {1} este semnat de {2}: se instalează cu propria sa sumă de control.'
    'choco.signature_check_failed'   = '{0}: semnătura lui {1} nu a putut fi verificată: {2}'

    'choco.packages_section'         = '--- Pachete (în listă: {0}) ---'
    'choco.running_version_deferred' = '{0}: programul rulează, schimbarea versiunii este amânată.'
    'choco.version_set'              = '{0}: a fost setată versiunea {1}.'
    'choco.version_pinned'           = '{0}: versiunea {1} a fost fixată.'
    'choco.pin_removed'              = '{0}: fixarea versiunii a fost eliminată.'
    'choco.package_installed'        = '{0}: instalat.'
    'choco.running_upgrade_deferred' = '{0}: programul rulează, actualizarea este amânată până la următoarea conectare.'
    'choco.package_upgraded'         = '{0}: actualizat de la {1}.'

    'choco.browser_missing'          = '{0} nu este instalat ({1}), se omite setarea browserului implicit.'
    'choco.browser_set'              = '{0} a fost setat ca browser implicit pentru conturile noi.'
    'choco.browser_dism_failed'      = 'DISM nu a setat browserul implicit (cod {0}): {1}'
}
