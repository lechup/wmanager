#!/usr/bin/env bash
# CI: builds signed test management sources for tests/Managed.Integration.Tests.ps1, with tools/publish.sh
# and a throwaway key, and checks the timestamps of publish.sh: from the default servers, none and a warning when no
# server answers, none with WM_TSA=none.
#
# Usage: tests/ci/build-sources.sh <output-folder>          (needs openssl, osslsigncode and the internet)
# Output:
#   wmanager-signing.cer   the test certificate
#   v1/, v2/               the same source, timestamped; v2 changes groups/ci/scripts/10-marker.ps1 (higher Serial)
#   expired-signing.cer    a certificate that expired yesterday
#   ci-tsa.cer             the certificate of a test timestamp server (osslsigncode's own)
#   expired/               v1 signed with the expired certificate, timestamped by the test server while it was valid
#   expired-nots/          the same without a timestamp
#   other/                 the same files under another source identifier
#   next-signing.cer       a second test certificate, for a key change (lib/Managed.ps1)
#   rot1/                  v2 naming next-signing.cer as its next certificate, signed with the first key
#   rotcancel/             rot1 without it again (a key change called off), first key
#   rot2/                  rot1 without it, signed with the second key (the switch)
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
[[ $# -eq 1 ]] || { echo "usage: $0 <output-folder>" >&2; exit 1; }
mkdir -p "$1"
out=$(cd "$1" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

keys=$work/keys
mkdir -p "$keys"
openssl req -x509 -newkey rsa:3072 -sha256 -days 400 -nodes -subj "/CN=wmanager CI" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" \
    -keyout "$keys/key.pem" -out "$keys/cert.pem" 2>/dev/null
openssl x509 -in "$keys/cert.pem" -outform DER -out "$out/wmanager-signing.cer"

src=$work/src
cp -r "$root/examples/management" "$src"
cp -r "$root/tests/fixtures/management/." "$src/"

die() { echo "ERROR: $*" >&2; exit 1; }
# Does the source's manifest have a timestamp?
stamped() { osslsigncode verify -CAfile "$2/cert.pem" -ignore-crl -in "$1/manifest.psd1" 2>&1 | grep -q 'Timestamp time:'; }

"$root/tools/publish.sh" "$src" "$keys"
stamped "$src" "$keys" || die "v1 has no timestamp: neither DigiCert nor Sectigo answered?"
cp -r "$src" "$out/v1"

# --- publish.sh without a timestamp ---------------------------------------------------------------------------
chk=$work/chk
cp -r "$src" "$chk"
said=$(WM_TSA='http://127.0.0.1:9 http://127.0.0.1:8' "$root/tools/publish.sh" "$chk" "$keys" 2>&1) ||
    { echo "$said"; die "publish.sh didn't sign when no timestamp server answered"; }
grep -q 'WARNING: no timestamp server answered' <<< "$said" && grep -q '^  http://127.0.0.1:8: ' <<< "$said" &&
    grep -q ', no timestamp\.$' <<< "$said" || { echo "$said"; die "publish.sh didn't warn of the missing timestamp"; }
stamped "$chk" "$keys" && die "a timestamp from servers that don't answer"
said=$(WM_TSA=none "$root/tools/publish.sh" "$chk" "$keys" 2>&1) || { echo "$said"; die "publish.sh with WM_TSA=none"; }
grep -q 'timestamp server' <<< "$said" && { echo "$said"; die "WM_TSA=none warned of the timestamp"; }
stamped "$chk" "$keys" && die "a timestamp with WM_TSA=none"
said=$(WM_TSA='ftp://timestamp.example' "$root/tools/publish.sh" "$chk" "$keys" 2>&1) && die "publish.sh took WM_TSA=ftp://..."
grep -q 'is not a timestamp server address' <<< "$said" || { echo "$said"; die "a wrong WM_TSA, not said"; }
echo "publish.sh: timestamped by default, a warning without a server, none with WM_TSA=none."

# --- A certificate that expired -------------------------------------------------------------------------------
# Expired yesterday; osslsigncode's own timestamp server, at a time the certificate was valid, stands in for
# DigiCert's (Windows trusts it once it is in the root store). publish.sh refuses an expired certificate, so
# osslsigncode signs v1's manifest itself.
now=$(date -u +%s)
at() { date -u -d "@$1" +%Y%m%d%H%M%SZ; }
exp=$work/expired
tsa=$work/tsa
mkdir -p "$exp" "$tsa"
openssl req -x509 -newkey rsa:3072 -sha256 -nodes -subj "/CN=wmanager CI expired" \
    -not_before "$(at $((now - 3 * 86400)))" -not_after "$(at $((now - 86400)))" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" \
    -keyout "$exp/key.pem" -out "$exp/cert.pem" 2>/dev/null
openssl x509 -in "$exp/cert.pem" -outform DER -out "$out/expired-signing.cer"
openssl req -x509 -newkey rsa:3072 -sha256 -nodes -subj "/CN=wmanager CI timestamps" \
    -not_before "$(at $((now - 10 * 86400)))" -not_after "$(at $((now + 3650 * 86400)))" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,timeStamping" \
    -keyout "$tsa/key.pem" -out "$tsa/cert.pem" 2>/dev/null
openssl x509 -in "$tsa/cert.pem" -outform DER -out "$out/ci-tsa.cer"
osslsigncode remove-signature -in "$out/v1/manifest.psd1" -out "$work/unsigned.psd1" >/dev/null
for kind in expired expired-nots; do
    cp -r "$out/v1" "$out/$kind"
    rm "$out/$kind/manifest.psd1"
done
osslsigncode sign -certs "$exp/cert.pem" -key "$exp/key.pem" -h sha256 -n wmanager \
    -TSA-certs "$tsa/cert.pem" -TSA-key "$tsa/key.pem" -TSA-time $((now - 2 * 86400)) \
    -in "$work/unsigned.psd1" -out "$out/expired/manifest.psd1" >/dev/null
osslsigncode sign -certs "$exp/cert.pem" -key "$exp/key.pem" -h sha256 -n wmanager \
    -in "$work/unsigned.psd1" -out "$out/expired-nots/manifest.psd1" >/dev/null

printf '# v2\r\n' >> "$src/groups/ci/scripts/10-marker.ps1"
"$root/tools/publish.sh" "$src" "$keys"
cp -r "$src" "$out/v2"

rm "$src/manifest.psd1" "$src/source-id.txt"
"$root/tools/publish.sh" "$src" "$keys"
cp -r "$src" "$out/other"

# A key change: the next certificate in the source, signed with the first key, then the switch to the second key
next=$work/next
mkdir -p "$next"
openssl req -x509 -newkey rsa:3072 -sha256 -days 400 -nodes -subj "/CN=wmanager CI next" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" \
    -keyout "$next/key.pem" -out "$next/cert.pem" 2>/dev/null
openssl x509 -in "$next/cert.pem" -outform DER -out "$out/next-signing.cer"
rot=$work/rot
cp -r "$out/v2" "$rot"
cp "$out/next-signing.cer" "$rot/next-certificate.cer"
"$root/tools/publish.sh" "$rot" "$keys"
cp -r "$rot" "$out/rot1"
rm "$rot/next-certificate.cer"
"$root/tools/publish.sh" "$rot" "$keys"
cp -r "$rot" "$out/rotcancel"
"$root/tools/publish.sh" "$rot" "$next"
cp -r "$rot" "$out/rot2"

echo "Test sources in $out: v1 ($(cat "$out/v1/source-id.txt")), v2, other ($(cat "$out/other/source-id.txt")), rot1, rotcancel, rot2, expired, expired-nots."
