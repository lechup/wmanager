#!/usr/bin/env bash
# CI: the installer's tag (internal/certtag) against a real Authenticode signature. A Go exe for Windows is signed
# with osslsigncode by a throwaway leaf certificate under a throwaway CA, with the chain written leaf first, as a
# commercial certificate brings it. Tagging it, re-tagging it, and reading the tag must all leave the signature
# valid. Whether Windows itself accepts it, with EnableCertPaddingCheck on, is trial 2 on a virtual machine.
set -euo pipefail

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$(dirname "$0")/../.."

GOOS=windows GOARCH=amd64 go build -trimpath -o "$work/plain.exe" ./trials/cmd/wmtrial
go build -trimpath -o "$work/wmtrial" ./trials/cmd/wmtrial

cd "$work"
openssl req -x509 -newkey rsa:3072 -sha256 -days 2 -nodes -subj "/CN=wmanager test CA" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign" \
    -keyout ca.key -out ca.pem 2>/dev/null
openssl req -newkey rsa:3072 -sha256 -nodes -subj "/CN=wmanager test signer" -keyout leaf.key -out leaf.csr 2>/dev/null
printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=codeSigning\n' > leaf.ext
openssl x509 -req -in leaf.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 2 -sha256 -extfile leaf.ext \
    -out leaf.pem 2>/dev/null
cat leaf.pem ca.pem > chain.pem # leaf first

osslsigncode sign -certs chain.pem -key leaf.key -h sha256 -in plain.exe -out signed.exe >/dev/null
check() {
    if ! osslsigncode verify -CAfile ca.pem -in "$1" > "$1.verify" 2>&1; then
        echo "::error::the signature of $1 doesn't verify"
        cat "$1.verify"
        exit 1
    fi
    echo "valid: $1"
}
check signed.exe
./wmtrial settag signed.exe tagged.exe '{"server":"https://wm.example.com","token":"ci"}'
check tagged.exe
./wmtrial settag tagged.exe retagged.exe "$(head -c 30000 /dev/zero | tr '\0' 'c')"
check retagged.exe
# The tagged exe reads its own tag only on Windows; here the tool reads it from the file.
size1=$(stat -c %s tagged.exe)
./wmtrial settag retagged.exe tagged-again.exe '{"server":"https://wm.example.com","token":"ci"}'
size2=$(stat -c %s tagged-again.exe)
if [ "$size1" != "$size2" ]; then
    echo "::error::the same tag twice gives $size1 and $size2 bytes: re-tagging grows the file"
    exit 1
fi
check tagged-again.exe
echo "certtag: tags kept the signature valid"
