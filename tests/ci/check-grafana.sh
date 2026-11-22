#!/usr/bin/env bash
# CI: checks examples/grafana against a real Loki and Grafana in Docker. Loki gets lines like the computers send
# (Write-WmLog's prefix, run records, job errors), then: the alert rules load into Loki's ruler; every query of the
# dashboard and of the rules runs; the ones that count computers give what the lines say; Grafana imports the
# dashboard with a Loki data source.
#
# Usage: tests/ci/check-grafana.sh            (needs docker, curl and python3)
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
loki_image=grafana/loki:3.3.2
grafana_image=grafana/grafana:11.4.0
id=wm-check-$$
work=$(mktemp -d)
cleanup() {
    docker rm -f "$id-loki" "$id-grafana" >/dev/null 2>&1 || true
    docker network rm "$id" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

# Loki with its ruler reading the rules file (tenant "fake": no authentication)
mkdir -p "$work/rules/fake"
cp "$root/examples/grafana/wmanager-alerts.yaml" "$work/rules/fake/"
chmod -R a+rX "$work"
cat > "$work/loki.yaml" <<'EOF'
auth_enabled: false
server:
  http_listen_port: 3100
common:
  path_prefix: /tmp/loki
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory
  storage:
    filesystem:
      chunks_directory: /tmp/loki/chunks
      rules_directory: /tmp/loki/rules
schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h
limits_config:
  reject_old_samples: false
# The test's lines are hours and days old but pushed now: they stay in the ingester (a chunk older than
# max_chunk_age would be cut and flushed away from the queries at once), and every range asks the ingester
ingester:
  max_chunk_age: 720h
querier:
  query_ingesters_within: 0
ruler:
  storage:
    type: local
    local:
      directory: /etc/loki/rules
  rule_path: /tmp/loki/rules-temp
  enable_api: true
EOF

docker network create "$id" >/dev/null
docker run -d --name "$id-loki" --network "$id" -p 127.0.0.1::3100 \
    -v "$work/loki.yaml:/etc/loki/config.yaml:ro" -v "$work/rules:/etc/loki/rules:ro" \
    "$loki_image" -config.file=/etc/loki/config.yaml >/dev/null
docker run -d --name "$id-grafana" --network "$id" -p 127.0.0.1::3000 \
    -e GF_SECURITY_ADMIN_PASSWORD=wm-check -e GF_ANALYTICS_REPORTING_ENABLED=false "$grafana_image" >/dev/null
loki=http://127.0.0.1:$(docker port "$id-loki" 3100 | head -n1 | sed 's/.*://')
grafana=http://127.0.0.1:$(docker port "$id-grafana" 3000 | head -n1 | sed 's/.*://')
for _ in $(seq 1 90); do curl -fs "$loki/ready" >/dev/null 2>&1 && break; sleep 1; done
curl -fs "$loki/ready" >/dev/null || { docker logs "$id-loki" | tail -20; echo "ERROR: Loki did not start" >&2; exit 1; }
for _ in $(seq 1 90); do curl -fs "$grafana/api/health" >/dev/null 2>&1 && break; sleep 1; done

python3 - "$loki" "$grafana" "$root/examples/grafana/wmanager-dashboard.json" "$id-loki" <<'PY'
import base64, json, re, sys, time, urllib.error, urllib.parse, urllib.request
loki, grafana, dashboard_file, loki_host = sys.argv[1:5]
failures = []

def http(url, data=None, headers=None, method=None):
    req = urllib.request.Request(url, data=data, headers=headers or {}, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()

# --- Lines like the computers send ---------------------------------------------------------------------------
now = time.time()
def ns(seconds_ago): return str(int((now - seconds_ago) * 1e9))
def prefixed(seconds_ago, level, text):
    return [ns(seconds_ago), time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(now - seconds_ago)) + f' [{level.upper()}] ' + text]
def record(seconds_ago, version, w, e, cert='OLD', nxt=''):
    return [ns(seconds_ago - 1), json.dumps({'wmanager_run': version, 'job': 'update', 'warnings': w, 'errors': e, 'cert': cert, 'next': nxt}, separators=(',', ':'))]
def stream(host, job, level, values, task=None):
    labels = {'service_name': 'wmanager', 'host': host, 'job': job, 'level': level}
    if task: labels['task'] = task
    return {'stream': labels, 'values': values}
H = 3600
streams = [
    # office-01: a clean update
    stream('office-01', 'update', 'info', [prefixed(H + 300, 'info', 'wmanager v0.3.0 update on OFFICE-01'),
                                           prefixed(H, 'info', 'End: warnings 0, errors 0.'), record(H, 'v0.3.0', 0, 0)]),
    # office-02: errors, a refused source, an expiring certificate, a failed job
    stream('office-02', 'update', 'info', [prefixed(2 * H + 300, 'info', 'wmanager v0.3.0 update on OFFICE-02'),
                                           prefixed(2 * H, 'info', 'End: warnings 1, errors 2.'), record(2 * H, 'v0.3.0', 1, 2)]),
    stream('office-02', 'update', 'error', [prefixed(2 * H + 200, 'error', 'Rejected the new version from the management source: invalid manifest signature (NotSigned): x'),
                                            prefixed(2 * H + 100, 'error', 'choco upgrade vlc ended with exit code 1')]),
    stream('office-02', 'update', 'warn', [prefixed(2 * H + 250, 'warn', 'The signing certificate expires on 2026-12-20; prepare a new one.')]),
    stream('office-02', 'jobs', 'error', [prefixed(3 * H, 'error', 'Job all/check-disk-space ended with exit code 1')], task='all/check-disk-space'),
    # office-03: a key change, ready for the next certificate
    stream('office-03', 'update', 'info', [prefixed(4 * H, 'info', 'End: warnings 0, errors 0.'), record(4 * H, 'v0.4.0', 0, 0, nxt='NEXT')]),
    # office-silent: last update five days ago
    stream('office-silent', 'update', 'info', [prefixed(5 * 24 * H, 'info', 'wmanager v0.3.0 update on OFFICE-SILENT'),
                                               prefixed(5 * 24 * H - 60, 'info', 'End: warnings 0, errors 0.')]),
]
status, body = http(f'{loki}/loki/api/v1/push', json.dumps({'streams': streams}).encode(), {'Content-Type': 'application/json'})
if status not in (200, 204): sys.exit(f'ERROR: push to Loki: {status} {body}')
time.sleep(2)

def query(expr, instant=True):
    if instant:
        url = f'{loki}/loki/api/v1/query?' + urllib.parse.urlencode({'query': expr, 'time': str(int(now * 1e9))})
    else:
        url = f'{loki}/loki/api/v1/query_range?' + urllib.parse.urlencode(
            {'query': expr, 'start': ns(7 * 24 * H), 'end': ns(0), 'step': '3600', 'limit': 1000})
    status, body = http(url)
    if status != 200: return None, f'{status} {body.strip()}'
    return json.loads(body)['data'], None

def scalar(data):
    if not data or not data['result']: return 0
    return float(data['result'][0]['value'][1])

def check(name, ok, detail=''):
    print(('ok    ' if ok else 'FAIL  ') + name + (f'  ({detail})' if detail and not ok else ''))
    if not ok: failures.append(name)

# --- Dashboard: every query runs; the counts are right ----------------------------------------------------------
dash = json.load(open(dashboard_file))
expected = {
    'Computers that reported (24 h)': 3,
    'Computers with errors (24 h)': 1,
    'Silent computers': 1,
    'Key change: computers that trust the next certificate (24 h)': 1,
}
for panel in dash['panels']:
    for t in panel.get('targets', []):
        expr = t['expr'].replace('$host', '.+').replace('$__interval', '1h')
        data, err = query(expr, t.get('queryType') == 'instant')
        check(f'dashboard "{panel["title"]}" {t["refId"]} runs', err is None, err)
        if err is None and panel['title'] in expected and t['refId'] == 'A':
            check(f'dashboard "{panel["title"]}" = {expected[panel["title"]]}', scalar(data) == expected[panel['title']], f'got {scalar(data)}')
        if err is None and panel['title'] == 'wmanager versions (24 h)':
            got = {r['metric'].get('wmanager_run'): float(r['value'][1]) for r in data['result']}
            check('dashboard versions: v0.3.0 x2, v0.4.0 x1', got == {'v0.3.0': 2, 'v0.4.0': 1}, f'got {got}')
        if err is None and panel['title'].startswith('Last runs') and t['refId'] == 'A':
            hosts = sorted(r['metric']['host'] for r in data['result'])
            check('dashboard last runs: office-01, office-02, office-03', hosts == ['office-01', 'office-02', 'office-03'], f'got {hosts}')

# --- Alert rules: Loki's ruler loads them, and each finds what it should --------------------------------------
status, body = http(f'{loki}/loki/api/v1/rules')
check('the ruler loads the rules', status == 200 and 'WmanagerSilent' in body, f'{status} {body[:300]}')
rules = {}
for m in re.finditer(r'- alert: (\w+)\n\s+expr: (.+)', open(dashboard_file.replace('wmanager-dashboard.json', 'wmanager-alerts.yaml')).read()):
    rules[m.group(1)] = m.group(2).strip()
want = {
    'WmanagerRunErrors': ['office-02'],
    'WmanagerJobErrors': ['office-02'],
    'WmanagerSilent': ['office-silent'],
    'WmanagerSourceRejected': ['office-02'],
    'WmanagerSelfUpdateFailed': [],
    'WmanagerCertificateExpiring': [None],
}
check('six rules', sorted(rules) == sorted(want), f'got {sorted(rules)}')
for name, expr in rules.items():
    data, err = query(expr)
    check(f'rule {name} runs', err is None, err)
    if err is None:
        hosts = sorted((r['metric'].get('host') for r in data['result']), key=lambda h: h or '')
        check(f'rule {name} fires for {want.get(name)}', hosts == want.get(name), f'got {hosts}')

# --- Grafana imports the dashboard -------------------------------------------------------------------------------
auth = {'Authorization': 'Basic ' + base64.b64encode(b'admin:wm-check').decode(), 'Content-Type': 'application/json'}
status, body = http(f'{grafana}/api/datasources', json.dumps({'name': 'Loki', 'type': 'loki', 'uid': 'wm-loki',
                    'url': f'http://{loki_host}:3100', 'access': 'proxy'}).encode(), auth)
check('Grafana takes the Loki data source', status == 200, f'{status} {body[:300]}')
status, body = http(f'{grafana}/api/dashboards/import', json.dumps({'dashboard': dash, 'overwrite': True,
                    'inputs': [{'name': 'DS_LOKI', 'type': 'datasource', 'pluginId': 'loki', 'value': 'wm-loki'}]}).encode(), auth)
check('Grafana imports the dashboard', status == 200 and '"imported":true' in body.replace(' ', ''), f'{status} {body[:300]}')
status, body = http(f'{grafana}/api/dashboards/uid/wmanager', headers=auth)
check('the imported dashboard uses the data source', status == 200 and 'wm-loki' in body and '${DS_LOKI}' not in body, f'{status}')

if failures: sys.exit(f'{len(failures)} checks failed')
print('All checks passed.')
PY
