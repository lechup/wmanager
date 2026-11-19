#!/usr/bin/env bash
# wmanager: generate manifest.psd1 for a management folder and sign it (Authenticode, osslsigncode).
#
# Usage: tools/publish.sh <management-folder> [key-folder]
#   key-folder holds key.pem and cert.pem from tools/new-signing-cert.sh (default: ~/.wmanager-signing).
#   WM_TSA=<RFC 3161 timestamp server URL> also adds a timestamp, so the signature stays valid after the
#   certificate expires (e.g. WM_TSA=http://timestamp.digicert.com).
#
# Before signing it checks the content with tools/groups.ps1 check (needs pwsh) and refuses a source the computers
# would reject. The manifest lists every file of the folder with its SHA256, except manifest.psd1 and hidden files
# (.git, .gitattributes...); computers use a file only if it matches. In a git repository the list is what git
# will push (tracked files and new files that aren't ignored), so it matches what the computers download.
# On the first run it creates source-id.txt, the identifier of this source (Management.SourceId in the config).
# Run it after every change, then commit and push, or copy the folder to the server or share (manifest.psd1 last).
# Requires osslsigncode (apt install osslsigncode), openssl and sha256sum; pwsh for the check.
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; }

[[ $# -ge 1 ]] || die "usage: $0 <management-folder> [key-folder]"
tools=$(cd "$(dirname "$0")" && pwd)
dir=$1
keydir=${2:-$HOME/.wmanager-signing}
command -v osslsigncode >/dev/null || die "osslsigncode not found (sudo apt install osslsigncode)"
[[ -d $dir ]] || die "folder $dir not found"
[[ -f $keydir/key.pem && -f $keydir/cert.pem ]] || die "no key.pem and cert.pem in $keydir (create them with tools/new-signing-cert.sh)"
keydir=$(cd "$keydir" && pwd)
cd "$dir"

openssl x509 -in "$keydir/cert.pem" -noout -checkend 0 >/dev/null ||
    die "the signing certificate has expired; create a new one (tools/new-signing-cert.sh in another folder) and install it on the computers"
openssl x509 -in "$keydir/cert.pem" -noout -checkend $((60 * 86400)) >/dev/null ||
    warn "the signing certificate expires within 60 days; prepare a new one (tools/new-signing-cert.sh in another folder)"

# --- Source identifier -------------------------------------------------------------------
id_re='^[A-Za-z0-9._-]{8,64}$'
if [[ ! -f source-id.txt ]]; then
    [[ -f manifest.psd1 ]] && die "manifest.psd1 exists but source-id.txt is missing; restore that file (otherwise the computers reject new versions)"
    tr -d '\n' < /proc/sys/kernel/random/uuid > source-id.txt
    echo "New management source, identifier: $(cat source-id.txt)"
    echo "Put it in provision.config.psd1: Management.SourceId. Don't copy source-id.txt to other sources."
fi
source_id=$(tr -d ' \r\n' < source-id.txt)
[[ $source_id =~ $id_re ]] || die "source-id.txt: invalid identifier '$source_id' (8-64 characters: letters, digits, . - _)"

# --- Files -----------------------------------------------------------------------
in_git=0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 && in_git=1
rels=()
if (( in_git )); then
    # Paths relative to this folder; a tracked file deleted here is left out (git add -A removes it)
    while IFS= read -r -d '' f; do
        [[ $f == manifest.psd1 || /$f == */.* ]] && continue
        [[ -e $f || -L $f ]] || continue
        rels+=("$f")
    done < <(git ls-files -z --cached --others --exclude-standard -- . | LC_ALL=C sort -zu)
else
    while IFS= read -r -d '' f; do rels+=("${f#./}"); done < <(
        find . ! -type d ! -path '*/.*' ! -path './manifest.psd1' -print0 | LC_ALL=C sort -z)
fi
[[ ${#rels[@]} -gt 0 ]] || die "folder $dir is empty"

# The same rules as Test-WmManagedPath on the computers
name_re='^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$'
device_re='^(con|prn|aux|nul|com[0-9]|lpt[0-9])(\.|$)'
for rel in "${rels[@]}"; do
    [[ -L $rel ]] && die "$rel is a symbolic link; git would push only the path, not the file"
    [[ -f $rel ]] || die "$rel is not a regular file"
    [[ $rel =~ $name_re ]] || die "name not allowed: $rel (only letters, digits, dot, hyphen, underscore)"
    IFS=/ read -ra segs <<< "$rel"
    for s in "${segs[@]}"; do
        [[ $s == *. ]] && die "a name can't end with a dot: $rel"
        [[ ${s,,} =~ $device_re ]] && die "name reserved in Windows: $rel"
    done
done
dups=$(printf '%s\n' "${rels[@]}" | tr '[:upper:]' '[:lower:]' | sort | uniq -d)
[[ -z $dups ]] || die "files that differ only in letter case (Windows can't tell them apart): $dups"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The content, read the way the computers read it (tools/groups.ps1 check: groups.psd1, the package lists, script
# syntax, BOMs, unused or missing groups, package conflicts). A source the computers would reject isn't signed.
if command -v pwsh >/dev/null; then
    printf '%s\n' "${rels[@]}" > "$tmp/files.txt"
    pwsh -NoProfile -File "$tools/groups.ps1" . check -FileList "$tmp/files.txt" ||
        die "the source has errors (above); nothing was signed"
else
    warn "pwsh (PowerShell 7) not found: groups.psd1, the package lists and the scripts were not checked"
    [[ -f groups.psd1 ]] || warn "no groups.psd1: every computer gets only the common list"
    [[ -f choco-reqs.txt ]] || warn "no choco-reqs.txt: the common list will be empty"
    # Windows PowerShell 5.1 reads a file without a BOM as ANSI, which breaks Polish letters
    for rel in "${rels[@]}"; do
        case $rel in
            *.ps1|*.psd1|*.psm1)
                if LC_ALL=C grep -qP '[\x80-\xFF]' -- "$rel" && [[ $(head -c3 -- "$rel" | od -An -tx1 | tr -d ' \n') != efbbbf ]]; then
                    warn "$rel has non-ASCII characters but no BOM; save it as UTF-8 with BOM"
                fi ;;
        esac
    done
fi

# Git must keep the bytes exactly as they are here, otherwise hashes and the signature stop matching.
# Git LFS would put a pointer in the repository instead of the file.
if (( in_git )); then
    bad=$(printf '%s\n' manifest.psd1 "${rels[@]}" | git check-attr --stdin text | grep -v ': text: unset$' || true)
    [[ -z $bad ]] || die "git would change the line endings of these files; add the line '* -text' to .gitattributes:
$bad"
    lfs=$(printf '%s\n' "${rels[@]}" | git check-attr --stdin filter | grep -vE ': filter: (unspecified|unset)$' || true)
    [[ -z $lfs ]] || die "these files go through a git filter (e.g. Git LFS), so the repository would hold something else:
$lfs"
fi

# --- Serial: higher than the previous one, even if the clock went back ----------------
serial=$(date -u +%Y%m%d%H%M%S)
if [[ -f manifest.psd1 ]]; then
    prev=$(tr -d '\r' < manifest.psd1 | grep -aoE '^[[:space:]]*Serial[[:space:]]*=[[:space:]]*[0-9]+' | grep -oE '[0-9]+$' | head -n1 || true)
    if [[ -n $prev ]] && (( prev >= serial )); then serial=$((prev + 1)); fi
fi

# --- Manifest (UTF-8 with BOM, CRLF) ----------------------------------------------------
{
    printf '\xef\xbb\xbf# wmanager management manifest: generated by tools/publish.sh, do not edit by hand.\r\n'
    printf '@{\r\n'
    printf "    SourceId = '%s'\r\n" "$source_id"
    printf '    Serial   = %s\r\n' "$serial"
    printf "    Created  = '%s'\r\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '    Files    = @{\r\n'
    for rel in "${rels[@]}"; do
        printf "        '%s' = '%s'\r\n" "$rel" "$(sha256sum -- "$rel" | cut -d' ' -f1 | tr '[:lower:]' '[:upper:]')"
    done
    printf '    }\r\n}\r\n'
} > "$tmp/manifest.psd1"

# --- Signature ------------------------------------------------------------------------
sign_args=(-certs "$keydir/cert.pem" -key "$keydir/key.pem" -h sha256 -n wmanager)
[[ -n ${WM_TSA:-} ]] && sign_args+=(-t "$WM_TSA")
sign_args+=(-in "$tmp/manifest.psd1" -out "$tmp/signed.psd1")
if grep -q 'ENCRYPTED' "$keydir/key.pem"; then
    read -rsp "Signing key passphrase: " pw
    echo >&2
    out=$(osslsigncode sign "${sign_args[@]}" -readpass <(printf '%s' "$pw") 2>&1) || die "signing failed:
$out"
    unset pw
else
    out=$(osslsigncode sign "${sign_args[@]}" 2>&1) || die "signing failed:
$out"
fi

verify_args=(-CAfile "$keydir/cert.pem" -in "$tmp/signed.psd1")
[[ -n ${WM_TSA:-} ]] && verify_args+=(-TSA-CAfile /etc/ssl/certs/ca-certificates.crt)
out=$(osslsigncode verify "${verify_args[@]}" 2>&1) || die "the signature does not verify:
$out"

mv "$tmp/signed.psd1" manifest.psd1
thumb=$(openssl x509 -in "$keydir/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)
echo "Signed manifest $serial (${#rels[@]} files), source $source_id, certificate $thumb."
# WM_PUBLISH_SENT_BY_CALLER: tools/wm.ps1 sends it next
if [[ -n ${WM_PUBLISH_SENT_BY_CALLER:-} ]]; then
    :
elif (( in_git )); then
    echo "Now commit and push the changes: git add -A && git commit -m '...' && git push"
else
    echo "Now copy the folder to the source (web server or share), manifest.psd1 last."
fi
