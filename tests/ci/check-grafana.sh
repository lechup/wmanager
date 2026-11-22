#!/usr/bin/env bash
# CI: checks examples/grafana against a real Loki and Grafana in Docker. Loki gets lines like the computers send:
# the messages taken from lang/en (so a reworded message that a rule reads fails here), with Write-WmLog's prefix,
# and run records with the fields Add-WmRunRecord writes. Then: the alert rules load into Loki's ruler; every query
# of the dashboard and of the rules runs; each rule fires for the computers it should and no other; the panels count
# the right computers and show the last run; Grafana imports the dashboard with a Loki data source.
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
curl -fs "$grafana/api/health" >/dev/null || { docker logs "$id-grafana" | tail -20; echo "ERROR: Grafana did not start" >&2; exit 1; }

python3 - "$loki" "$grafana" "$root" "$id-loki" <<'PY'
import base64, glob, json, re, sys, time, urllib.error, urllib.parse, urllib.request
loki, grafana, root, loki_host = sys.argv[1:5]
failures = []

def http(url, data=None, headers=None, method=None):
    req = urllib.request.Request(url, data=data, headers=headers or {}, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
    except urllib.error.URLError as e:
        return 0, str(e)

def check(name, ok, detail=''):
    print(('ok    ' if ok else 'FAIL  ') + name + (f'  ({detail})' if detail and not ok else ''))
    if not ok: failures.append(name)

# --- The English messages, as the computers log them ---------------------------------------------------------
catalog = {}
for f in glob.glob(f'{root}/lang/en/*.psd1'):
    for m in re.finditer(r"^\s*'([\w.]+)'\s*=\s*(?:'((?:[^']|'')*)'|\"([^\"]*)\")", open(f, encoding='utf-8-sig').read(), re.M):
        catalog[m.group(1)] = m.group(2).replace("''", "'") if m.group(2) is not None else m.group(3)
def msg(key, *args): return catalog[key].format(*args)
# The fields of the run record, as Add-WmRunRecord writes them
common = open(f'{root}/lib/Common.ps1', encoding='utf-8-sig').read()
record_fn = common[common.index('function Add-WmRunRecord'):]
record_fn = record_fn[:record_fn.index('\n}')]
for field in ['"wmanager_run":', '"job":', '"warnings":', '"errors":', '"cert":', '"next":']:
    check(f'Add-WmRunRecord writes {field}', field in record_fn)

now = time.time()
H = 3600
def ns(seconds_ago): return str(int((now - seconds_ago) * 1e9))
def line(seconds_ago, level, text):
    return [ns(seconds_ago), time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(now - seconds_ago)) + f' [{level.upper()}] ' + text]
def record(seconds_ago, version, w, e, nxt=''):
    return [ns(seconds_ago - 1), json.dumps({'wmanager_run': version, 'job': 'update', 'warnings': w, 'errors': e, 'cert': 'OLD', 'next': nxt}, separators=(',', ':'))]
def stream(host, job, level, values, task=None):
    labels = {'service_name': 'wmanager', 'host': host, 'job': job, 'level': level}
    if task: labels['task'] = task
    return {'stream': labels, 'values': values}
def run(host, ago, version, w, e, nxt=''):
    return stream(host, 'update', 'info', [line(ago + 300, 'info', msg('update.start', f'wmanager {version}', 'update', host.upper())),
                                           line(ago, 'info', msg('update.summary', w, e)), record(ago, version, w, e, nxt)])
streams = [
    # office-01: a clean update
    run('office-01', H, 'v0.3.0', 0, 0),
    # office-02: errors, a refused source, an expiring certificate, a failed job, a group script that failed hourly
    run('office-02', 2 * H, 'v0.3.0', 1, 2),
    stream('office-02', 'update', 'error', [line(2 * H + 200, 'error', msg('managed.new_version_rejected', 'invalid manifest signature (NotSigned): x')),
                                            line(2 * H + 100, 'error', 'choco upgrade vlc ended with exit code 1')]),
    stream('office-02', 'update', 'warn', [line(2 * H + 250, 'warn', msg('managed.cert_expiring', '2026-12-20'))]),
    stream('office-02', 'jobs', 'error', [line(3 * H, 'error', 'Job all/check-disk-space ended with exit code 1')], task='all/check-disk-space'),
    stream('office-02', 'jobs', 'error', [line(3 * H + 60, 'error', msg('managed.script_exit_code', 'groups/all/scripts/10-power.ps1', 1, 'tried again in 20 hours'))]),
    # office-03: a run with errors, then a clean one on a newer version that names the next certificate
    stream('office-03', 'update', 'info', [record(20 * H, 'v0.3.0', 0, 3), record(4 * H, 'v0.4.0', 0, 0, nxt='NEXT')]),
    # office-04: a self-update whose download fails, a certificate change that failed, an expired certificate
    run('office-04', H, 'v0.3.0', 1, 1),
    stream('office-04', 'update', 'warn', [line(H + 200, 'warn', msg('update.self_update_download_failed', 'v0.4.0', 'timeout', 'wmanager v0.3.0')),
                                           line(H + 150, 'warn', msg('managed.cert_expired', '2026-11-01'))]),
    stream('office-04', 'update', 'error', [line(H + 100, 'error', msg('managed.cert_change_failed', 'access denied'))]),
    # office-05: an hourly job's own output mentions wmanager_run, which is not a run record
    stream('office-05', 'jobs', 'info', [line(2 * H, 'info', 'report: wmanager_run is the field of the run record')], task='all/system-report'),
    # office-silent: last lines five days ago
    run('office-silent', 5 * 24 * H, 'v0.3.0', 0, 0),
]
status, body = http(f'{loki}/loki/api/v1/push', json.dumps({'streams': streams}).encode(), {'Content-Type': 'application/json'})
if status not in (200, 204): sys.exit(f'ERROR: push to Loki: {status} {body}')
time.sleep(2)

def query(expr, instant=True):
    if instant:
        url = f'{loki}/loki/api/v1/query?' + urllib.parse.urlencode({'query': expr, 'time': str(int(now * 1e9))})
    else:
        url = f'{loki}/loki/api/v1/query_range?' + urllib.parse.urlencode(
            {'query': expr, 'start': ns(2 * 24 * H), 'end': ns(0), 'step': '3600', 'limit': 1000})
    status, body = http(url)
    if status != 200: return None, f'{status} {body.strip()[:300]}'
    return json.loads(body)['data'], None
def scalar(data):
    if not data or not data['result']: return 0
    r = data['result'][0]
    return float(r['value'][1] if 'value' in r else r['values'][-1][1])
def by(data, label):
    out = {}
    for r in data['result']:
        out[r['metric'].get(label)] = float(r['value'][1] if 'value' in r else r['values'][-1][1])
    return out

# --- Dashboard ------------------------------------------------------------------------------------------------
dash = json.load(open(f'{root}/examples/grafana/wmanager-dashboard.json'))
results = {}
for panel in dash['panels']:
    for t in panel.get('targets', []):
        expr = t['expr'].replace('$host', '.+').replace('$__interval', '1h')
        data, err = query(expr, t.get('queryType') == 'instant')
        check(f'dashboard "{panel["title"]}" {t["refId"]} runs', err is None, err)
        results[(panel['title'], t['refId'])] = data
def panel(prefix, ref='A'):
    return next(v for (title, r), v in results.items() if title.startswith(prefix) and r == ref)
for prefix, want in [('Computers that reported', 5), ('Computers with errors', 2), ('Silent computers', 1), ('Key change', 1)]:
    check(f'dashboard "{prefix}" = {want}', scalar(panel(prefix)) == want, f'got {scalar(panel(prefix))}')
last = panel('Last run of each computer', 'A')
got = {r['metric']['host']: r['metric']['wmanager_run'] for r in last['result']}
check('last run: each computer once, with the version of its last run',
      got == {'office-01': 'v0.3.0', 'office-02': 'v0.3.0', 'office-03': 'v0.4.0', 'office-04': 'v0.3.0'}, f'got {got}')
check('last run: when, in milliseconds', all(abs(float(r['value'][1]) / 1000 - now) < 24 * H for r in last['result']))
errors = by(panel('Last run of each computer', 'B'), 'host')
check('last run: the errors of the last run (office-03: 0, not 3)', errors == {'office-01': 0, 'office-02': 2, 'office-03': 0, 'office-04': 1}, f'got {errors}')
warnings = by(panel('Last run of each computer', 'C'), 'host')
check('last run: its warnings', warnings == {'office-01': 0, 'office-02': 1, 'office-03': 0, 'office-04': 1}, f'got {warnings}')
versions = by(panel('wmanager versions'), 'wmanager_run')
check('versions: each computer once', versions == {'v0.3.0': 3, 'v0.4.0': 1}, f'got {versions}')
jobs = {(r['metric']['host'], r['metric'].get('task', '')) for r in panel('Failed group jobs')['result']}
check('hourly run: the job by name, and the group script without one', jobs == {('office-02', 'all/check-disk-space'), ('office-02', '')}, f'got {jobs}')

# --- Alert rules ---------------------------------------------------------------------------------------------
status, body = http(f'{loki}/loki/api/v1/rules')
check('the ruler loads the rules', status == 200 and 'WmanagerSilent' in body, f'{status} {body[:300]}')
rules = {m.group(1): m.group(2).strip() for m in re.finditer(r'- alert: (\w+)\n\s+expr: (.+)', open(f'{root}/examples/grafana/wmanager-alerts.yaml').read())}
want = {
    'WmanagerRunErrors': [('office-02', None), ('office-04', None)],
    'WmanagerJobErrors': [('office-02', 'all/check-disk-space')],
    'WmanagerSilent': [('office-silent', None)],
    'WmanagerSourceRejected': [('office-02', None)],
    'WmanagerSelfUpdateFailed': [('office-04', None)],
    'WmanagerCertificateExpiring': [(None, None)],
    'WmanagerCertificateExpired': [(None, None)],
}
check('the rules are the expected ones', sorted(rules) == sorted(want), f'got {sorted(rules)}')
for name, expr in rules.items():
    data, err = query(expr)
    check(f'rule {name} runs', err is None, err)
    if err is None:
        got = sorted(((r['metric'].get('host'), r['metric'].get('task')) for r in data['result']), key=str)
        check(f'rule {name} fires for {want.get(name)}', got == want.get(name), f'got {got}')

# --- Grafana imports the dashboard ---------------------------------------------------------------------------
auth = {'Authorization': 'Basic ' + base64.b64encode(b'admin:wm-check').decode(), 'Content-Type': 'application/json'}
status, body = http(f'{grafana}/api/datasources', json.dumps({'name': 'Loki', 'type': 'loki', 'uid': 'wm-loki',
                    'url': f'http://{loki_host}:3100', 'access': 'proxy'}).encode(), auth)
check('Grafana takes the Loki data source', status == 200, f'{status} {body[:300]}')
status, body = http(f'{grafana}/api/dashboards/import', json.dumps({'dashboard': dash, 'overwrite': True, 'inputs': []}).encode(), auth)
check('Grafana imports the dashboard', status == 200 and '"imported":true' in body.replace(' ', ''), f'{status} {body[:300]}')
status, body = http(f'{grafana}/api/dashboards/uid/wmanager', headers=auth)
imported = json.loads(body)['dashboard'] if status == 200 else {}
variables = {v['name']: v for v in imported.get('templating', {}).get('list', [])}
check('it picks the Loki data source with a variable', variables.get('datasource', {}).get('type') == 'datasource'
      and variables['datasource'].get('query') == 'loki', f'{variables.get("datasource")}')
pattern = re.compile(variables.get('datasource', {}).get('regex', '')[1:-1])
check("the selector leaves out Grafana Cloud's own Loki data sources",
      all(pattern.fullmatch(n) for n in ['grafanacloud-acme-logs', 'Loki', 'Loki acme'])
      and not any(pattern.fullmatch(n) for n in ['grafanacloud-acme-alert-state-history', 'grafanacloud-acme-usage-insights']))
check('every panel reads that data source', all(p['datasource']['uid'] == '${datasource}' for p in imported.get('panels', [])))
# A panel's query through Grafana itself (its Loki plugin, the data source), not only through Loki's API
first = dash['panels'][0]['targets'][0]['expr'].replace('$host', '.+')
status, body = http(f'{grafana}/api/ds/query', json.dumps({'from': 'now-6h', 'to': 'now', 'queries': [
    {'refId': 'A', 'datasource': {'uid': 'wm-loki'}, 'expr': first, 'queryType': 'instant'}]}).encode(), auth)
frames = json.loads(body)['results']['A'].get('frames', []) if status == 200 else []
values = [v for f in frames for v in (f['data']['values'][-1] if f['data']['values'] else [])]
check('Grafana runs a panel query through the data source', status == 200 and values == [5], f'{status} {values} {body[:200]}')

if failures: sys.exit(f'{len(failures)} checks failed')
print('All checks passed.')
PY
