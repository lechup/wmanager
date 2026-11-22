#!/usr/bin/env bash
# CI: checks examples/selfhosted end to end with Docker: init, two companies, docker compose up (certificates of
# Caddy's own instead of Let's Encrypt), then the logins and the tenants as the computers and tools/wm.ps1 meet them
# (a write token only sends, a read token only reads and can't delete, a company sees only its own lines, a wrong login
# and other paths are refused), and Grafana: the data source of each company reads its tenant only, the dashboard and the alert
# rules are provisioned.
#
# Usage: tests/ci/check-selfhosted.sh            (needs docker with compose, curl, openssl and python3)
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
project=wmself$$
cleanup() {
    (cd "$work/examples/selfhosted" 2>/dev/null && docker compose -p "$project" down -v >/dev/null 2>&1) || true
    rm -rf "$work"
}
trap cleanup EXIT
fail() { echo "FAIL  $*"; failures=$((failures + 1)); }
ok() { echo "ok    $*"; }
failures=0

mkdir -p "$work/examples"
cp -r "$root/examples/selfhosted" "$root/examples/grafana" "$work/examples/"
cd "$work/examples/selfhosted"
free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'; }
http_port=$(free_port)
https_port=$(free_port)
export CADDY_HTTP_PORT=$http_port CADDY_HTTPS_PORT=$https_port CADDY_GLOBAL=local_certs
LOKI_DOMAIN=loki.localhost GRAFANA_DOMAIN=grafana.localhost ACME_EMAIL=ci@example.test ./selfhosted.sh init
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

docker compose -p "$project" up -d
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

if (( failures > 0 )); then
    docker compose -p "$project" logs --tail 30
    echo "$failures checks failed"
    exit 1
fi
echo 'All checks passed.'
