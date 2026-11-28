#!/usr/bin/env bash
# CI: checks examples/selfhosted end to end with Docker: init, two companies, docker compose up (certificates of
# Caddy's own instead of Let's Encrypt), then the logins and the tenants as the computers and tools/wm.ps1 meet them
# (a write token only sends, a read token only reads and can't delete, a company sees only its own lines, a wrong login
# and other paths are refused), the management sources (each company's computers read only theirs, with its header,
# GET only, no listing, no way out with ..), and Grafana: the data source of each company reads its tenant only, the
# dashboard and the alert rules are provisioned. And wmanager-server: built from this repository, behind Caddy, with its
# PostgreSQL roles; the owner made with selfhosted.sh, a sign-in, its headers, the audit heads in Loki, a backup and a
# restore.
#
# Usage: tests/ci/check-selfhosted.sh            (needs docker with compose, curl, openssl and python3)
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
project=wmself$$
export COMPOSE_PROJECT_NAME=$project   # selfhosted.sh's own docker compose commands reach the same project
export WMANAGER_IMAGE=wmanager-server:ci-$project   # built for this run, removed after it
cleanup() {
    (cd "$work/examples/selfhosted" 2>/dev/null && docker compose -p "$project" down -v >/dev/null 2>&1) || true
    docker image rm "$WMANAGER_IMAGE" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT
fail() { echo "FAIL  $*"; failures=$((failures + 1)); }
ok() { echo "ok    $*"; }
failures=0

mkdir -p "$work/examples"
cp -r "$root/examples/selfhosted" "$root/examples/grafana" "$work/examples/"
# What server/Dockerfile builds from (the compose file's build context is the repository's top)
cp -r "$root/go.mod" "$root/go.sum" "$root/verify" "$root/internal" "$root/server" "$root/.dockerignore" "$work/"
cd "$work/examples/selfhosted"
free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'; }
http_port=$(free_port)
https_port=$(free_port)
export CADDY_HTTP_PORT=$http_port CADDY_HTTPS_PORT=$https_port CADDY_GLOBAL=local_certs
export PANEL_PORT_SUFFIX=":$https_port" WMANAGER_LOKI_HEAD_EVERY=3s
LOKI_DOMAIN=loki.localhost GRAFANA_DOMAIN=grafana.localhost PANEL_DOMAIN=panel.localhost ACME_EMAIL=ci@example.test \
    ./selfhosted.sh init
[[ $(stat -c %a secrets) == 700 ]] || { echo "ERROR: secrets/ can be opened by others" >&2; exit 1; }
for f in postgres-password owner-password server-password database-url migrate-database-url; do
    [[ -s secrets/$f && $(stat -c %a "secrets/$f") == 444 ]] || { echo "ERROR: secrets/$f missing or not 444" >&2; exit 1; }
    grep -qF "$(cat "secrets/$f")" .env && { echo "ERROR: secrets/$f is in .env" >&2; exit 1; }
done
./selfhosted.sh add-company acme > acme.txt
./selfhosted.sh add-company globex > globex.txt
./selfhosted.sh list
token() { sed -n "s/^  LokiToken //p" "$1"; }
reader() { sed -n 's/^Read-only, for .*question): //p' "$1"; }
user() { sed -n "s/^  LokiUser  //p" "$1"; }
acme_user=$(user acme.txt); acme_write=$(token acme.txt); acme_read=$(reader acme.txt)
globex_user=$(user globex.txt); globex_write=$(token globex.txt); globex_read=$(reader globex.txt)
[[ $acme_user == 1001 && $globex_user == 1002 && -n $acme_write && -n $acme_read && $acme_write != "$acme_read" ]] ||
    { cat acme.txt globex.txt; echo "ERROR: add-company didn't give the tenants and tokens" >&2; exit 1; }
grep -q "$acme_write" caddy/push-users && { echo "ERROR: a token is kept in the clear" >&2; exit 1; }
header() { sed -n "s/^  AuthHeader //p" "$1"; }
acme_header=$(header acme.txt); globex_header=$(header globex.txt)
[[ $acme_header == Basic\ * && $globex_header == Basic\ * && $acme_header != "$globex_header" ]] ||
    { echo "ERROR: add-company didn't give the source logins" >&2; exit 1; }
[[ $(./selfhosted.sh address acme) == $'source https://loki.localhost/source/acme\nfolder sources/acme' ]] ||
    { ./selfhosted.sh address acme; echo "ERROR: address doesn't say where acme's source is" >&2; exit 1; }
# What tools/wm.ps1 sync would have sent (rsync into the folder "address" names)
printf '@{ Serial = 7 }\r\n' > sources/acme/manifest.psd1
mkdir -p sources/acme/groups/all && printf 'Write-Output 1\r\n' > sources/acme/groups/all/job.ps1
printf '@{ Serial = 3 }\r\n' > sources/globex/manifest.psd1

docker compose -p "$project" up -d --build
loki() { curl -sk --resolve "loki.localhost:$https_port:127.0.0.1" "$@"; }
grafana() { curl -sk --resolve "grafana.localhost:$https_port:127.0.0.1" "$@"; }
for _ in $(seq 1 120); do
    [[ $(loki -o /dev/null -w '%{http_code}' "https://loki.localhost:$https_port/loki/api/v1/labels" -u "$acme_user:$acme_read") == 200 ]] && break
    sleep 1
done
for _ in $(seq 1 120); do grafana -f "https://grafana.localhost:$https_port/api/health" >/dev/null 2>&1 && break; sleep 1; done

push() {   # <user:token> <host label>: one line, as Send-WmLokiLog sends it; prints the HTTP status
    local ns
    ns=$(python3 -c 'import time; print(int(time.time() * 1e9))')
    loki -o /dev/null -w '%{http_code}' -u "$1" -H 'Content-Type: application/json' \
        --data "{\"streams\":[{\"stream\":{\"service_name\":\"wmanager\",\"host\":\"$2\",\"job\":\"update\",\"level\":\"info\"},\"values\":[[\"$ns\",\"End: warnings 0, errors 0.\"]]}]}" \
        "https://loki.localhost:$https_port/loki/api/v1/push"
}
hosts() {   # <user:token>: the hosts that user's tenant has
    loki -u "$1" "https://loki.localhost:$https_port/loki/api/v1/label/host/values" |
        python3 -c 'import json, sys; d = json.load(sys.stdin); print(",".join(sorted(d.get("data") or [])))' 2>/dev/null
}
code() { loki -o /dev/null -w '%{http_code}' "$@"; }

# --- Loki through Caddy: the logins --------------------------------------------------------------------------
[[ $(push "$acme_user:$acme_write" office-acme) == 204 ]] && ok 'a computer of acme sends with its write token' || fail 'acme write token sends'
[[ $(push "$globex_user:$globex_write" office-globex) == 204 ]] && ok 'a computer of globex sends' || fail 'globex sends'
[[ $(push "$acme_user:$acme_read" office-acme) == 401 ]] && ok 'a read token does not send' || fail 'a read token sends'
[[ $(push "$acme_user:wrong" office-acme) == 401 ]] && ok 'a wrong token does not send' || fail 'a wrong token sends'
[[ $(push "$globex_user:$acme_write" office-acme) == 401 ]] && ok "acme's token is not globex's login" || fail "acme's token works as globex"
[[ $(code -u "$acme_user:$acme_write" "https://loki.localhost:$https_port/loki/api/v1/labels") == 401 ]] && ok 'a write token does not read' || fail 'a write token reads'
[[ $(code -u "$acme_user:$acme_read" -X POST "https://loki.localhost:$https_port/loki/api/v1/delete?query=%7Bhost%3D%22office-acme%22%7D&start=1") == 404 ]] &&
    ok 'a read token does not delete' || fail 'a read token reaches the delete API'
[[ $(code -u "$acme_user:$acme_read" -X POST --data 'query={host="office-acme"}' "https://loki.localhost:$https_port/loki/api/v1/query") == 404 ]] &&
    ok 'reading is GET only' || fail 'reading takes POST'
[[ $(code "https://loki.localhost:$https_port/") == 404 ]] && ok 'nothing else is served' || fail 'other paths answer'
sleep 2
[[ $(hosts "$acme_user:$acme_read") == office-acme ]] && ok 'acme reads only its own computers (tools/wm.ps1 status)' || fail "acme reads $(hosts "$acme_user:$acme_read")"
[[ $(hosts "$globex_user:$globex_read") == office-globex ]] && ok 'globex reads only its own' || fail "globex reads $(hosts "$globex_user:$globex_read")"

# --- The management sources, as the computers read them (Management.Source and AuthHeader) ---------------------
src="https://loki.localhost:$https_port/source"
[[ $(loki -H "Authorization: $acme_header" "$src/acme/manifest.psd1") == $'@{ Serial = 7 }\r' ]] &&
    ok "acme's computers read its source, byte for byte" || fail "acme's source with its header"
[[ $(code -H "Authorization: $acme_header" "$src/acme/groups/all/job.ps1") == 200 ]] && ok 'and the files under it' || fail 'a file in a subfolder'
[[ $(code "$src/acme/manifest.psd1") == 401 ]] && ok 'not without the header' || fail 'the source without a login'
[[ $(code -H "Authorization: $globex_header" "$src/acme/manifest.psd1") == 401 ]] && ok "not with globex's header" || fail "globex reads acme's source"
[[ $(code -H "Authorization: $acme_header" "$src/globex/manifest.psd1") == 401 ]] && ok "acme's header doesn't read globex's" || fail "acme reads globex's source"
[[ $(code --path-as-is -H "Authorization: $acme_header" "$src/acme/../globex/manifest.psd1") != 200 ]] && ok 'no way out of the folder with ..' || fail 'acme reaches globex with ..'
[[ $(code -H "Authorization: $acme_header" "$src/acme/") == 404 ]] && ok 'no folder listing' || fail 'a folder is listed'
[[ $(code -H "Authorization: $acme_header" -X PUT --data x "$src/acme/manifest.psd1") == 404 ]] && ok 'reading only (GET)' || fail 'the source takes PUT'
[[ $(code -H "Authorization: $acme_header" "$src/nobody/manifest.psd1") == 404 ]] && ok 'no other company' || fail 'an unknown company answers'
[[ $(code -u "$acme_user:$acme_read" "$src/acme/manifest.psd1") == 401 ]] && ok "Loki's read token is not the source login" || fail 'the Loki token reads the source'

# --- Grafana ---------------------------------------------------------------------------------------------------
password=$(sed -n 's/^GRAFANA_ADMIN_PASSWORD=//p' .env)
g() { grafana -u "admin:$password" -H 'Content-Type: application/json' "$@"; }
ds=$(g "https://grafana.localhost:$https_port/api/datasources")
echo "$ds" | grep -q '"uid":"loki-acme"' && echo "$ds" | grep -q '"uid":"loki-globex"' && ok 'a data source per company' || fail "data sources: $ds"
count_in() {   # <data source uid> <host>: how many lines of that host it reads in the last hour
    g -X POST "https://grafana.localhost:$https_port/api/ds/query" --data \
        "{\"from\":\"now-1h\",\"to\":\"now\",\"queries\":[{\"refId\":\"A\",\"datasource\":{\"uid\":\"$1\"},\"expr\":\"sum(count_over_time({service_name=\\\"wmanager\\\", host=\\\"$2\\\"}[1h]))\",\"queryType\":\"instant\"}]}" |
        python3 -c '
import json, sys
d = json.load(sys.stdin)
values = [v for f in d["results"]["A"].get("frames", []) for v in (f["data"]["values"][-1] if f["data"]["values"] else [])]
print(int(sum(values)) if values else 0)'
}
[[ $(count_in loki-acme office-acme) -ge 1 ]] && ok "Grafana reads acme's lines through acme's data source" || fail "acme's data source reads $(count_in loki-acme office-acme)"
[[ $(count_in loki-globex office-acme) == 0 ]] && ok "globex's data source doesn't see acme's computers" || fail "globex sees acme"
[[ $(g -o /dev/null -w '%{http_code}' "https://grafana.localhost:$https_port/api/dashboards/uid/wmanager") == 200 ]] && ok 'the dashboard is there' || fail 'no dashboard'
rules=$(g "https://grafana.localhost:$https_port/api/v1/provisioning/alert-rules")
n=$(echo "$rules" | python3 -c 'import json, sys; print(len(json.load(sys.stdin)))')
want=$(( 2 * $(grep -c -- '- alert:' ../grafana/wmanager-alerts.yaml) ))
[[ $n == "$want" ]] && ok "the alert rules of both companies ($n)" || fail "alert rules: $n, not $want"
echo "$rules" | grep -q '"title":"acme: WmanagerSilent"' && ok 'the rules are named by company' || fail 'rule titles'

# --- wmanager-server behind Caddy -------------------------------------------------------------------------------
panel() { curl -sk --resolve "panel.localhost:$https_port:127.0.0.1" "$@"; }
purl="https://panel.localhost:$https_port"
for _ in $(seq 1 120); do [[ $(panel -o /dev/null -w '%{http_code}' "$purl/healthz") == 200 ]] && break; sleep 1; done
[[ $(panel -o /dev/null -w '%{http_code}' "$purl/healthz") == 200 ]] && ok 'the panel answers through Caddy' || fail 'no panel'
owner_pw=$(openssl rand -hex 12)
if printf '%s\n' "$owner_pw" | ./selfhosted.sh create-owner owner@example.test | grep -q 'owner owner@example.test made'; then
    ok 'create-owner makes the owner, the password from a pipe'
else
    fail 'create-owner'
fi
signin() {   # prints the status and the redirect of a sign-in with the owner's password
    panel -o /dev/null -w '%{http_code} %{redirect_url}' --data-urlencode email=owner@example.test \
        --data-urlencode "password=$1" "$purl/signin"
}
[[ $(signin "$owner_pw") == "303 $purl/signin/totp" ]] && ok 'the owner signs in, then sets up the second factor' || fail "sign-in: $(signin "$owner_pw")"
[[ $(signin wrong-password-here) == '401 ' ]] && ok 'a wrong password is refused' || fail 'a wrong password'
hdrs=$(panel -D - -o /dev/null "$purl/signin")
echo "$hdrs" | grep -qi "^content-security-policy: default-src 'none'" && echo "$hdrs" | grep -qi '^strict-transport-security:' &&
    ok "the panel's headers (CSP, HSTS)" || fail "headers: $hdrs"
[[ $(panel -o /dev/null -w '%{http_code}' -H 'Sec-Fetch-Site: cross-site' --data email=x "$purl/signin") == 403 ]] &&
    ok 'a form from another site is refused' || fail 'a cross-site form'
panel -o /dev/null -H 'X-Forwarded-For: 203.0.113.77' --data email=nobody@example.test --data password=x "$purl/signin"
sleep 1
docker compose -p "$project" logs wmanager 2>&1 | grep -q '203\.0\.113\.77' &&
    fail "a browser's own X-Forwarded-For was believed" || ok "a browser's own X-Forwarded-For is not believed"
server_secrets=$(docker inspect "$(docker compose -p "$project" ps -q wmanager)" --format '{{range .Mounts}}{{.Destination}} {{end}}')
[[ $server_secrets == *database-url* && $server_secrets != *migrate-database-url* ]] &&
    ok "the server's container doesn't get the owner's password" || fail "the server's mounts: $server_secrets"
[[ $(docker compose -p "$project" exec -T grafana wget -qO- --header 'X-Scope-OrgID: wmanager-server' \
        --post-data '' 'http://loki:3100/loki/api/v1/delete?query=%7Bjob%3D%22audit-head%22%7D&start=1' 2>/dev/null; echo "rc=$?") != rc=0 ]] &&
    ok "Loki takes no deletion of the audit heads" || fail 'Loki deletes over its API'
heads=''
for _ in $(seq 1 30); do
    heads=$(docker compose -p "$project" exec -T grafana wget -qO- --header 'X-Scope-OrgID: wmanager-server' \
        'http://loki:3100/loki/api/v1/query_range?query=%7Bjob%3D%22audit-head%22%7D&limit=10' 2>/dev/null || true)
    [[ $heads == *'\"chain\":\"server\"'* ]] && break
    sleep 2
done
[[ $heads == *'\"chain\":\"server\"'* ]] && ok "the audit log's head reaches Loki" || fail "no audit head in Loki: $heads"
# A file in the volume of the files added with add-file, as the server keeps one, to see it backed up and put back
server_id=$(docker compose -p "$project" ps -q wmanager)
mkdir -p filetest/c1 && echo 'a driver' > filetest/c1/f1
tar -C filetest -cf filetest.tar . && docker cp -a - "$server_id":/var/lib/wmanager/files < filetest.tar
./selfhosted.sh backup > backup.txt
dump=$(sed -n 's/^Written \(backups\/[^ ]*\.dump\)\..*/\1/p' backup.txt)
[[ -s $dump && $(stat -c %a "$dump") == 600 ]] && ok 'a backup, readable by its owner only' || fail "backup: $(cat backup.txt)"
files_tar=${dump%.dump}.files.tar
[[ -s $files_tar && $(stat -c %a "$files_tar") == 600 ]] && tar -tf "$files_tar" | grep -qx './c1/f1' &&
    ok 'the files added with add-file, backed up next to the dump' || fail "the files' backup: $(cat backup.txt)"
head -c 2000 "$dump" > backups/broken.dump
if ./selfhosted.sh restore backups/broken.dump > broken.txt 2>&1; then
    fail 'a broken dump restored'
else
    [[ $(signin "$owner_pw") == "303 $purl/signin/totp" ]] && ok 'a broken dump leaves the server as it was' ||
        fail "after a broken dump: $(cat broken.txt)"
fi
if ./selfhosted.sh restore "$dump" > restore.txt 2>&1; then
    for _ in $(seq 1 60); do [[ $(panel -o /dev/null -w '%{http_code}' "$purl/healthz") == 200 ]] && break; sleep 1; done
    [[ $(signin "$owner_pw") == "303 $purl/signin/totp" ]] && ok 'after a restore the owner still signs in' || fail 'sign-in after the restore'
    [[ $(docker cp "$(docker compose -p "$project" ps -q wmanager)":/var/lib/wmanager/files/c1/f1 - | tar -xO) == 'a driver' ]] &&
        ok 'after a restore the files added with add-file are still there' || fail 'the files after the restore'
else
    fail "restore: $(cat restore.txt)"
fi

if (( failures > 0 )); then
    docker compose -p "$project" logs --tail 30
    echo "$failures checks failed"
    exit 1
fi
echo 'All checks passed.'
