#!/usr/bin/env bash
# CI: builds signed test management sources for tests/Managed.Integration.Tests.ps1, with tools/publish.sh
# and a throwaway key.
#
# Usage: tests/ci/build-sources.sh <output-folder>          (needs openssl and osslsigncode)
# Output:
#   wmanager-signing.cer   the test certificate
#   v1/, v2/               the same source; v2 changes groups/ci/scripts/10-marker.ps1 (higher Serial)
#   other/                 the same files under another source identifier
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

"$root/tools/publish.sh" "$src" "$keys"
cp -r "$src" "$out/v1"

printf '# v2\r\n' >> "$src/groups/ci/scripts/10-marker.ps1"
"$root/tools/publish.sh" "$src" "$keys"
cp -r "$src" "$out/v2"

rm "$src/manifest.psd1" "$src/source-id.txt"
"$root/tools/publish.sh" "$src" "$keys"
cp -r "$src" "$out/other"

echo "Test sources in $out: v1 ($(cat "$out/v1/source-id.txt")), v2, other ($(cat "$out/other/source-id.txt"))."
