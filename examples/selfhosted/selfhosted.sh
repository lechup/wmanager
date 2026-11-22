#!/usr/bin/env bash
# wmanager: Grafana and Loki of your own, on a server with Docker (README: Hosting Grafana and Loki yourself).
# Run it in this folder, with ../grafana next to it (as in the repository).
#
#   ./selfhosted.sh init                   the server's names, the e-mail for the certificates; writes .env (with a
#                                          Grafana admin password), copies the dashboard
#   ./selfhosted.sh add-company <name>     a Loki tenant for the company (the next number from 1001), its logins
#                                          (a write token for the computers, a read token for tools/wm.ps1 status;
#                                          only their hashes are kept), a Grafana data source and its alert rules
#   ./selfhosted.sh list                   the companies and their tenant numbers
#
# Then docker compose up -d (after add-company: docker compose restart caddy grafana). init takes its answers from
# LOKI_DOMAIN, GRAFANA_DOMAIN and ACME_EMAIL when they are set. Needs docker, openssl and python3.
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

here=$(cd "$(dirname "$0")" && pwd)
cd "$here"
caddy_image=caddy:2.8.4
tenants=caddy/tenants

cmd_init() {
    for c in docker openssl python3; do command -v "$c" >/dev/null || die "$c not found"; done
    [[ -f ../grafana/wmanager-dashboard.json ]] || die "../grafana/wmanager-dashboard.json not found: keep this folder next to examples/grafana"
    mkdir -p caddy grafana/provisioning/datasources grafana/provisioning/alerting grafana/dashboards
    touch caddy/push-users caddy/read-users "$tenants"
    cp ../grafana/wmanager-dashboard.json grafana/dashboards/
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
    umask 077
    {
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
    } > .env
    echo "Written .env (readable by you only). Grafana: https://$grafana, user admin, the password in .env."
    echo "Next: ./selfhosted.sh add-company <name>, then docker compose up -d"
}

# A password hash for Caddy's basic_auth; the token goes in on stdin, not on a command line
hash_token() {
    printf '%s\n' "$1" | docker run -i --rm "$caddy_image" caddy hash-password | tail -n1
}

cmd_add_company() {
    local name=$1
    [[ $name =~ ^[a-z0-9][a-z0-9-]{1,39}$ ]] || die "a company name: 2 to 40 lowercase letters, digits and dashes ('$name')"
    [[ -f .env && -f $tenants ]] || die "run ./selfhosted.sh init first"
    awk -v n="$name" '$1 == n { found = 1 } END { exit !found }' "$tenants" && die "there is a company $name already"
    local tenant
    tenant=$(awk 'BEGIN { max = 1000 } $2 > max { max = $2 } END { print max + 1 }' "$tenants")
    local write read
    write=$(openssl rand -hex 24)
    read=$(openssl rand -hex 24)
    echo "$tenant $(hash_token "$write")" >> caddy/push-users
    echo "$tenant $(hash_token "$read")" >> caddy/read-users
    echo "$name $tenant" >> "$tenants"

    # Grafana: a Loki data source of the company's tenant, and the alert rules of ../grafana on it
    cat > "grafana/provisioning/datasources/$name.yaml" <<EOF
# The Loki tenant of $name (selfhosted.sh add-company)
apiVersion: 1
datasources:
  - name: Loki $name
    uid: loki-$name
    type: loki
    access: proxy
    url: http://loki:3100
    jsonData:
      httpHeaderName1: X-Scope-OrgID
    secureJsonData:
      httpHeaderValue1: '$tenant'
EOF
    python3 - "$name" ../grafana/wmanager-alerts.yaml "grafana/provisioning/alerting/$name.yaml" <<'PY'
import hashlib, re, sys
name, source, target = sys.argv[1:4]
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
            f'            datasourceUid: loki-{name}',
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
    local domain
    domain=$(sed -n 's/^LOKI_DOMAIN=//p' .env)
    echo "Company $name: Loki tenant $tenant."
    echo "Its configuration (pwsh tools/wm.ps1 $name config, the Loki questions):"
    echo "  LokiUrl   https://$domain"
    echo "  LokiUser  $tenant"
    echo "  LokiToken $write"
    echo "Read-only, for pwsh tools/wm.ps1 $name monitoring (the Grafana Cloud token question): $read"
    echo "The tokens are shown only now (the server keeps their hashes). Then: docker compose restart caddy grafana"
}

cmd_list() {
    [[ -s $tenants ]] || { echo "No companies yet: ./selfhosted.sh add-company <name>"; return; }
    awk '{ printf "%-20s Loki tenant %s\n", $1, $2 }' "$tenants"
}

[[ $# -ge 1 ]] || { sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 1; }
cmd=$1; shift
case $cmd in
    init)        [[ $# -eq 0 ]] || die "usage: $0 init"; cmd_init ;;
    add-company) [[ $# -eq 1 ]] || die "usage: $0 add-company <name>"; cmd_add_company "$1" ;;
    list)        cmd_list ;;
    *)           die "unknown command $cmd (init, add-company, list)" ;;
esac
