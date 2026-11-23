#!/usr/bin/env bash
# wmanager: create the key and the self-signed certificate that sign the management source.
#
# Usage: tools/new-signing-cert.sh [key-folder]        (default: ~/.wmanager-signing)
#
# Creates in key-folder:
#   key.pem                 private key, protected with a passphrase; never leaves this computer
#   cert.pem                certificate for tools/publish.sh
#   wmanager-signing.cer    public part; goes next to provision.config.psd1 (Management.Certificate)
# The certificate is valid for 20 years and allows code signing only (not a CA), so even a leaked key
# can't be used to issue certificates for websites. Requires openssl.
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

dir=${1:-$HOME/.wmanager-signing}
command -v openssl >/dev/null || die "openssl not found"
[[ -e $dir/key.pem ]] && die "$dir already holds key.pem; not overwriting it (a new key means a new certificate on every computer)"

mkdir -p "$dir"
chmod 700 "$dir"
umask 077

echo "Enter the passphrase that will protect the key (you will be asked twice)."
# key.pem didn't exist before (checked above): a run that stops (passphrases that don't match, Ctrl+C) removes what
# it wrote, so the next run can start again instead of refusing an empty key.pem
cleanup() { rm -f "$dir/key.pem" "$dir/cert.pem" "$dir/wmanager-signing.cer"; }
trap 'cleanup; exit 130' INT TERM
if ! openssl req -x509 -newkey rsa:3072 -sha256 -days 7300 -subj "/CN=wmanager signing" \
        -addext "basicConstraints=critical,CA:FALSE" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=codeSigning" \
        -keyout "$dir/key.pem" -out "$dir/cert.pem" ||
   ! openssl x509 -in "$dir/cert.pem" -outform DER -out "$dir/wmanager-signing.cer"; then
    cleanup
    die "no key was created (the reason is above); run this again"
fi
trap - INT TERM
chmod 644 "$dir/cert.pem" "$dir/wmanager-signing.cer"

thumb=$(openssl x509 -in "$dir/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)
cat <<EOF

Done. Certificate thumbprint (SHA1): $thumb
- Copy $dir/wmanager-signing.cer next to provision.config.psd1 (USB drive or share).
- Back up $dir/key.pem somewhere safe and remember the passphrase:
  without the key you can't sign further changes, and a new key means a new certificate on every computer.
EOF
