#!/usr/bin/env bash
# wmanager: create the key and the self-signed certificate that sign the management source.
#
# Usage: tools/new-signing-cert.sh [key-folder]        (default: ~/.wmanager-signing)
#
# Creates in key-folder:
#   key.pem                 private key, protected with a passphrase; never leaves this computer
#   cert.pem                certificate for tools/publish.sh
#   wmanager-signing.cer    public part; goes next to provision.config.psd1 (Management.Certificate)
# The certificate is valid for 10 years and allows code signing only (not a CA), so even a leaked key
# can't be used to issue certificates for websites. Requires openssl.
set -euo pipefail

die() { echo "BŁĄD: $*" >&2; exit 1; }

dir=${1:-$HOME/.wmanager-signing}
command -v openssl >/dev/null || die "brak openssl"
[[ -e $dir/key.pem ]] && die "w $dir już jest key.pem; nie nadpisuję go (nowy klucz = nowy certyfikat na wszystkich komputerach)"

mkdir -p "$dir"
chmod 700 "$dir"
umask 077

echo "Podaj hasło, którym zostanie zabezpieczony klucz (pytanie pojawi się dwa razy)."
openssl req -x509 -newkey rsa:3072 -sha256 -days 3650 -subj "/CN=wmanager signing" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" \
    -keyout "$dir/key.pem" -out "$dir/cert.pem"
openssl x509 -in "$dir/cert.pem" -outform DER -out "$dir/wmanager-signing.cer"
chmod 644 "$dir/cert.pem" "$dir/wmanager-signing.cer"

thumb=$(openssl x509 -in "$dir/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)
cat <<EOF

Gotowe. Odcisk certyfikatu (SHA1): $thumb
- Skopiuj $dir/wmanager-signing.cer obok provision.config.psd1 (pendrive lub udział).
- Zrób kopię zapasową $dir/key.pem w bezpiecznym miejscu i zapamiętaj hasło:
  bez klucza nie podpiszesz kolejnych zmian, a nowy klucz trzeba wgrać na każdy komputer.
EOF
