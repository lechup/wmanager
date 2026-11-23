#!/usr/bin/env bash
# wmanager: Grafana and Loki of your own, on a server with Docker (docs/monitoring.md: Hosting Grafana and Loki yourself).
# Run it in this folder, with ../grafana next to it (as in the repository).
#
#   ./selfhosted.sh init                   the server's names, the e-mail for the certificates; writes .env (with a
#                                          Grafana admin password), copies the dashboard
#   ./selfhosted.sh add-company <name>     a Loki tenant for the company (the next number from 1001), its logins
#                                          (a write token for the computers, a read token for tools/wm.ps1 status;
#                                          only their hashes are kept), a Grafana data source and its alert rules,
#                                          and a place for its management source (as "source")
#   ./selfhosted.sh source <name>          the place for the company's management source, for a company added
#                                          without one: sources/<name>, served at https://<logs name>/source/<name>/
#                                          to the computers with a login of its own (Management.AuthHeader)
#   ./selfhosted.sh address <name>         where the computers read the company's source, and its folder here (for
#                                          tools/wm.ps1 <company> target, over ssh)
#   ./selfhosted.sh list                   the companies, their tenant numbers and source addresses
#
# A company's name is the one tools/wm.ps1 uses (letters, digits, . _ -); addresses and file names use it in lower
# case with . and _ as -.
# Then docker compose up -d (after add-company: docker compose restart caddy grafana). init takes its answers from
# LOKI_DOMAIN, GRAFANA_DOMAIN and ACME_EMAIL when they are set. Needs docker, openssl and python3.
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

# Grafana and Loki run as users of their own in the containers: what this writes must be readable to them (.env not)
umask 022
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"
caddy_image=caddy:2.8.4
tenants=caddy/tenants

# The company's name in addresses, file names and Grafana identifiers
slug() { printf '%s' "$1" | tr 'A-Z._' 'a-z--'; }
# The name as tools/wm.ps1 takes it
valid_name() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]{1,39}$ && $1 =~ [A-Za-z] && $1 != *. ]]; }
known() { [[ -f $tenants ]] && awk -v n="$1" '$1 == n { found = 1 } END { exit !found }' "$tenants"; }
domain() { sed -n 's/^LOKI_DOMAIN=//p' .env; }

cmd_init() {
    for c in docker openssl python3; do command -v "$c" >/dev/null || die "$c not found"; done
    [[ -f ../grafana/wmanager-dashboard.json ]] || die "../grafana/wmanager-dashboard.json not found: keep this folder next to examples/grafana"
    mkdir -p caddy/sources sources grafana/provisioning/datasources grafana/provisioning/alerting grafana/dashboards
    touch caddy/push-users caddy/read-users "$tenants"
    cp ../grafana/wmanager-dashboard.json grafana/dashboards/
    chmod -R a+rX loki.yaml Caddyfile grafana   # a checkout made with umask 077 too (nothing secret in them)
    if [[ -f .env ]]; then
        echo ".env is there already; kept. The dashboard is copied again."
        return
    fi
    local loki=${LOKI_DOMAIN:-} grafana=${GRAFANA_DOMAIN:-} email=${ACME_EMAIL:-}
    [[ -n $loki ]] || read -rp "Name of the server the computers send logs to (e.g. logs.example.com): " loki
    [[ -n $grafana ]] || read -rp "Name for Grafana (e.g. grafana.example.com): " grafana
    [[ -n $email ]] || read -rp "E-mail for the certificates (Let's Encrypt): " email
    [[ $loki =~ ^[A-Za-z0-9.-]+$ && $grafana =~ ^[A-Za-z0-9.-]+$ ]] || die "a server name: letters, digits, dots and dashes"
    [[ $email == *@* ]] || die "an e-mail address, please"
    (umask 077; {
        echo "# wmanager: Grafana and Loki of your own (selfhosted.sh init). Both names must point to this server."
        echo "LOKI_DOMAIN=$loki"
        echo "GRAFANA_DOMAIN=$grafana"
        echo "ACME_EMAIL=$email"
        echo "GRAFANA_ADMIN_PASSWORD=$(openssl rand -hex 16)"
        echo "# E-mail for the alerts (Grafana: Alerting > Contact points), e.g. SMTP_HOST=smtp.example.com:587"
        echo "SMTP_ENABLED=false"
        echo "SMTP_HOST="
        echo "SMTP_USER="
        echo "SMTP_PASSWORD="
        echo "SMTP_FROM="
    } > .env)
    echo "Written .env (readable by you only). Grafana: https://$grafana, user admin, the password in .env."
    echo "Next: ./selfhosted.sh add-company <name>, then docker compose up -d"
}

# A password hash for Caddy's basic_auth; the token goes in on stdin, not on a command line
hash_token() {
    printf '%s\n' "$1" | docker run -i --rm "$caddy_image" caddy hash-password | tail -n1
}

cmd_add_company() {
    local name=$1
    valid_name "$name" || die "a company name: 2 to 40 letters, digits, . _ -, with a letter, as tools/wm.ps1 takes it ('$name')"
    [[ -f .env && -f $tenants ]] || die "run ./selfhosted.sh init first"
    local id
    id=$(slug "$name")
    awk -v s="$id" '{ n = tolower($1); gsub(/[._]/, "-", n) } n == s { found = 1 } END { exit !found }' "$tenants" &&
        die "there is a company $name already (or one whose name differs only in case, . or _)"
    local tenant
    tenant=$(awk 'BEGIN { max = 1000 } $2 > max { max = $2 } END { print max + 1 }' "$tenants")
    local write reader
    write=$(openssl rand -hex 24)
    reader=$(openssl rand -hex 24)
    echo "$tenant $(hash_token "$write")" >> caddy/push-users
    echo "$tenant $(hash_token "$reader")" >> caddy/read-users
    echo "$name $tenant" >> "$tenants"

    # Grafana: a Loki data source of the company's tenant, and the alert rules of ../grafana on it
    cat > "grafana/provisioning/datasources/$id.yaml" <<EOF
# The Loki tenant of $name (selfhosted.sh add-company)
apiVersion: 1
datasources:
  - name: Loki $name
    uid: loki-$id
    type: loki
    access: proxy
    url: http://loki:3100
    jsonData:
      httpHeaderName1: X-Scope-OrgID
    secureJsonData:
      httpHeaderValue1: '$tenant'
EOF
    python3 - "$name" "$id" ../grafana/wmanager-alerts.yaml "grafana/provisioning/alerting/$id.yaml" <<'PY'
import hashlib, re, sys
name, id, source, target = sys.argv[1:5]
company = hashlib.sha1(name.encode()).hexdigest()[:8]   # rule uids: at most 40 characters
text = open(source).read()
interval = re.search(r'^\s*interval:\s*(\S+)', text, re.M).group(1)
out = [f'# The wmanager alert rules (../grafana/wmanager-alerts.yaml) on the Loki tenant of {name} (selfhosted.sh add-company)',
       'apiVersion: 1', 'groups:', '  - orgId: 1', f'    name: wmanager {name}', '    folder: wmanager', f'    interval: {interval}', '    rules:']
def q(s): return "'" + s.replace("'", "''") + "'"
for block in re.split(r'\n\s*- alert: ', text)[1:]:
    title = block.split('\n', 1)[0].strip()
    expr = re.search(r'^\s*expr: (.+)$', block, re.M).group(1).strip()
    wait = re.search(r'^\s*for: (\S+)', block, re.M)
    severity = re.search(r'^\s*severity: (\S+)', block, re.M).group(1)
    summary = re.search(r"^\s*summary: '(.*)'$", block, re.M).group(1).replace("''", "'")
    out += [f'      - uid: wm-{company}-{title.lower().removeprefix("wmanager")[:24]}',
            f'        title: {q(name + ": " + title)}',
            '        condition: C',
            '        data:',
            '          - refId: A',
            '            relativeTimeRange: {from: 600, to: 0}',
            f'            datasourceUid: loki-{id}',
            f'            model: {{refId: A, expr: {q(expr)}, queryType: instant, instant: true}}',
            '          - refId: C',
            '            datasourceUid: __expr__',
            '            model: {refId: C, type: threshold, expression: A, conditions: [{evaluator: {type: gt, params: [0]}}]}',
            '        noDataState: OK',
            '        execErrState: Error',
            f'        for: {wait.group(1) if wait else "0s"}',
            f'        labels: {{severity: {severity}, company: {name}}}',
            f'        annotations: {{summary: {q(summary)}}}']
open(target, 'w').write('\n'.join(out) + '\n')
PY
    echo "Company $name: Loki tenant $tenant."
    echo "Its configuration (pwsh tools/wm.ps1 $name config, the Loki questions):"
    echo "  LokiUrl   https://$(domain)"
    echo "  LokiUser  $tenant"
    echo "  LokiToken $write"
    echo "Read-only, for pwsh tools/wm.ps1 $name monitoring (the Grafana Cloud token question): $reader"
    cmd_source "$name" quiet
    echo "The tokens are shown only now (the server keeps their hashes). Then: docker compose restart caddy grafana"
}

# The company's management source: a folder the helper fills (rsync over ssh), served by Caddy to the computers with
# a login of the company's own (Basic, the hash kept), GET only. Not replaced: the computers have its header.
cmd_source() {
    local name=$1 quiet=${2:-}
    known "$name" || die "no company $name here (./selfhosted.sh list)"
    local id snippet
    id=$(slug "$name")
    snippet=caddy/sources/$id.caddy
    [[ -e $snippet ]] && die "$name has its source login already; the computers use its header. To replace it (they then need the new one): rm $snippet, then ./selfhosted.sh source $name"
    mkdir -p caddy/sources "sources/$id"
    local token hash
    token=$(openssl rand -hex 24)
    hash=$(hash_token "$token")
    cat > "$snippet" <<SNIPPET
# The management source of $name (selfhosted.sh source), GET only, with its login (Management.AuthHeader)
@source-$id {
	method GET HEAD
	path /source/$id/*
}
handle @source-$id {
	basic_auth {
		$id $hash
	}
	uri strip_prefix /source/$id
	root * /srv/sources/$id
	file_server
}
SNIPPET
    [[ -n $quiet ]] || echo "Company $name: its management source goes to sources/$id."
    echo "Where its computers read the source (pwsh tools/wm.ps1 $name target, then s):"
    echo "  Source     https://$(domain)/source/$id"
    echo "  AuthHeader Basic $(printf '%s:%s' "$id" "$token" | base64 -w0)"
    [[ -n $quiet ]] || echo "The header is shown only now (the server keeps its hash). Then: docker compose restart caddy"
}

# For tools/wm.ps1 target: one line each, "source <address>" and "folder <path in this folder>"
cmd_address() {
    local name=$1
    known "$name" || die "no company $name here (./selfhosted.sh list)"
    local id
    id=$(slug "$name")
    [[ -e caddy/sources/$id.caddy ]] || die "$name has no place for its source yet: ./selfhosted.sh source $name"
    echo "source https://$(domain)/source/$id"
    echo "folder sources/$id"
}

cmd_list() {
    [[ -s $tenants ]] || { echo "No companies yet: ./selfhosted.sh add-company <name>"; return; }
    local name tenant id where
    while read -r name tenant; do
        id=$(slug "$name")
        where="no source here (./selfhosted.sh source $name)"
        [[ -e caddy/sources/$id.caddy ]] && where="source https://$(domain)/source/$id"
        printf '%-20s Loki tenant %s, %s\n' "$name" "$tenant" "$where"
    done < "$tenants"
}

[[ $# -ge 1 ]] || { sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 1; }
cmd=$1; shift
case $cmd in
    init)        [[ $# -eq 0 ]] || die "usage: $0 init"; cmd_init ;;
    add-company) [[ $# -eq 1 ]] || die "usage: $0 add-company <name>"; cmd_add_company "$1" ;;
    source)      [[ $# -eq 1 ]] || die "usage: $0 source <name>"; [[ -f .env ]] || die "run ./selfhosted.sh init first"; cmd_source "$1" ;;
    address)     [[ $# -eq 1 ]] || die "usage: $0 address <name>"; [[ -f .env ]] || die "run ./selfhosted.sh init first"; cmd_address "$1" ;;
    list)        cmd_list ;;
    *)           die "unknown command $cmd (init, add-company, source, address, list)" ;;
esac
