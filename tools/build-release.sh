#!/usr/bin/env bash
# wmanager: builds the files of a release from a git tag (.github/workflows/release.yml runs it; it also runs
# locally, to look at a release before publishing it).
#
# Usage: tools/build-release.sh <tag> <output-folder>          e.g. tools/build-release.sh v0.1.0 dist
#
# Creates in output-folder:
#   wmanager-<tag>.zip   the files of the tag, without tests/ and .github/, plus VERSION; the folder inside is wmanager/
#   install.ps1          the installer the one-liner downloads (also in the ZIP)
#   SHA256SUMS           SHA-256 of both, checked by install.ps1 before it runs anything
# Needs git, zip and sha256sum.
set -euo pipefail

die() { echo "BŁĄD: $*" >&2; exit 1; }

[[ $# -eq 2 ]] || die "użycie: $0 <tag> <folder-wyjściowy>"
tag=$1
[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || die "tag w formacie vX.Y.Z albo vX.Y.Z-rc1 ('$tag')"
for c in git zip sha256sum; do command -v "$c" >/dev/null || die "brak $c"; done
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
git -C "$root" rev-parse -q --verify "refs/tags/$tag^{commit}" >/dev/null || die "brak tagu $tag"

mkdir -p "$2"
out=$(cd "$2" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# git archive applies .gitattributes, so the scripts keep CRLF and their BOM, as Windows PowerShell 5.1 needs
git -C "$root" archive --format=tar --prefix=wmanager/ "$tag" | tar -x -C "$work"
rm -rf "$work/wmanager/tests" "$work/wmanager/.github"
printf '%s\r\n' "$tag" > "$work/wmanager/VERSION"

# The same tag gives the same ZIP: file times from the tagged commit, fixed order, no extra attributes
stamp=$(git -C "$root" log -1 --format=%ct "$tag^{commit}")
find "$work/wmanager" -exec touch -h -d "@$stamp" {} +
rm -f "$out/wmanager-$tag.zip"
# zip stores local time: TZ=UTC makes the ZIP the same on every machine
(cd "$work" && find wmanager -print | LC_ALL=C sort | TZ=UTC zip -qX -@ "$out/wmanager-$tag.zip")
cp "$work/wmanager/install.ps1" "$out/install.ps1"
(cd "$out" && sha256sum "wmanager-$tag.zip" install.ps1 > SHA256SUMS)
echo "Gotowe: $out/wmanager-$tag.zip, install.ps1, SHA256SUMS"
