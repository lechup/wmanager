# Logs and monitoring

- Locally: `C:\ProgramData\wmanager\logs\<provision|update|retry>-YYYY-MM-DD_HHMM.log` and `jobs-YYYY-MM-DD.log`,
  deleted after `LogRetentionDays` (90 days).
  The full Chocolatey output is only in the local log (and in `C:\ProgramData\chocolatey\logs`).
- **Grafana Cloud Loki**: at the end of a run the script pushes the entries over HTTP (`/loki/api/v1/push`), with no agent.
  Labels: `service_name="wmanager"`, `host`, `job` (`provision`, `update`, `retry`, `jobs`), `level`, and `task`
  (`<group>/<name>`) for the output of group jobs.
  When Grafana doesn't respond (or rejects the token), the batch waits in `logs\outbox` and is sent on the next run.
  A batch Loki rejects for good (HTTP 400 or 413, e.g. entries too old) is moved to `logs\outbox\rejected` so it doesn't block newer ones.
  Example query: `{service_name="wmanager", level="error"}`.
  The last entry of each provisioning and update is a JSON line,
  `{"wmanager_run":"v0.3.0","job":"update","warnings":0,"errors":0,"cert":"<thumbprint>","next":""}`: the version that
  finished the run (after a self-update that failed, the old one) and the signing certificates the computer trusts
  (`next`: during a key change), for `tools/wm.ps1 status`. It goes to Loki only, not to the screen or the log file.
- **Healthchecks.io**: a `/start` ping at the beginning (in provisioning: once the computer name is settled), and success
  or `/fail` (with the tail of the log) at the end of provisioning and of the scheduled update. Provisioning stopped before
  the name is settled (e.g. a declined question) sends nothing; the console shows the result.
  The check is created on the first ping (`?create=1`); its name is the computer name (with an optional `HealthchecksSlugPrefix`).

The log file and Loki are in English; the console and the user's notifications in the chosen language (see
[Languages](languages.md)).

## Grafana Cloud setup

1. Grafana Cloud → Connections → Loki: note the URL (e.g. `https://logs-prod-012.grafana.net`) and the numeric User.
2. Administration → Cloud access policies: create a policy with only the `logs:write` scope and generate a token.
3. Put `LokiUrl`, `LokiUser` and `LokiToken` in `provision.config.psd1`.

## Grafana dashboard and alerts

`examples/grafana/` has a dashboard and alert rules for the lines wmanager sends (they are English on every computer,
so the same patterns read all of them):

- `wmanager-dashboard.json`: Dashboards > New > Import, upload the file; the Loki selector at the top picks the data
  source the computers send to (in Grafana Cloud `grafanacloud-<stack>-logs`; with several companies on one Grafana,
  one each). Computers that reported and those with errors in the last
  24 hours, silent computers (lines in the last 14 days, none in the last 3), the computers whose last run trusts the
  next certificate during a key change, the last run of each computer (the wmanager version that finished it, when,
  warnings, errors), the versions in use (each computer once, by its last run), error lines over time, failed group
  jobs and errors of the hourly run, and the errors and warnings themselves; a Computer filter at the top. The last
  runs, versions and key change come from the run records of wmanager v0.3.0 and later.
- `wmanager-alerts.yaml`: alert rules in the Loki ruler format, evaluated every 15 minutes: errors of an update,
  provisioning or the hourly run's group scripts and source; a failed group job (by name); a silent computer; a
  management source the computer rejected; a wmanager version or signing certificate that didn't switch (a download
  that keeps failing included); a signing certificate that expires within 60 days, and one that has expired. Load them
  into the Loki ruler of the stack (`lokitool rules load wmanager-alerts.yaml`, with a token that has `rules:write`),
  or make a Grafana alert rule from each `expr` (Alerts & IRM > Alert rules > New alert rule, the Loki data source)
  and set "Alert state if no data" to Normal: a healthy result is empty. Send them where you want (contact points).

"Silent" means no line for 3 days. A computer that updates once a week and runs no daily job (the example source has
the daily system report) looks silent between its updates: use `8d` in the rule and the panel for it. A computer
silent longer than the logs are kept (14 days on Grafana Cloud's free plan) drops out of both; Healthchecks keeps it.

CI checks both against a real Loki and Grafana (`tests/ci/check-grafana.sh`): lines like the computers send, built
from the English messages in `lang/en` (a reworded message that a rule reads fails there) and the run record's fields;
every query runs, each rule fires for the computers it should and no other, the panels count the right computers and
show the last run, the ruler loads the rules, Grafana imports the dashboard.

## Hosting Grafana and Loki yourself

`examples/selfhosted/` runs Loki, Grafana and Caddy with Docker on a server of your own, for any number of companies.
Caddy gets the certificates (Let's Encrypt) and checks the logins; Loki keeps each company apart (a tenant each) and
the logs 90 days (`retention_period` in `loki.yaml`); Grafana gets a data source and the alert rules of each company
and the dashboard, ready. The same server can hold each company's management source, which the helper sends there,
instead of a private GitHub repository. A small server (2 GB of memory) is enough for dozens of computers; the logs are a few MB a
day per computer.

On the server, with Docker, the `examples` folder of the repository (or the release) and two names pointing to it:

```bash
cd examples/selfhosted
./selfhosted.sh init                  # the names (e.g. logs.example.com, grafana.example.com), the e-mail for the certificates
./selfhosted.sh add-company acme      # prints LokiUrl, LokiUser, LokiToken, a read-only token, and Source and AuthHeader
docker compose up -d                  # after another add-company: docker compose restart caddy grafana
```

- **A company's login** is its tenant number (`LokiUser`, from 1001 on) with a write token (`LokiToken`), as Grafana
  Cloud's: give them to the wizard (`pwsh tools/wm.ps1 acme config`). The read-only token goes to
  `pwsh tools/wm.ps1 acme monitoring` (the Grafana Cloud question) for `status`. A write token only sends and a read
  token only reads; a company reads only its own lines. The server keeps only the tokens' hashes: `add-company` shows
  them once.
- **The management source** of a company is `sources/<company>` on the server, served at
  `https://<logs name>/source/<company>/` to its computers with a login of its own: the `Source` and `AuthHeader`
  (`Basic ...`) that `add-company` prints, for `Management.Source` and `Management.AuthHeader`. Only GET, no folder
  listing, and one company's header doesn't read another's source. On your computer, `pwsh tools/wm.ps1 acme target`,
  `s`, with the server and the kit's folder there (e.g. `admin@logs.example.com:/srv/wmanager/examples/selfhosted`):
  the helper asks `selfhosted.sh address acme` over ssh where it goes, then `sync` and `publish` send it there with
  rsync, and it offers to put the address and header in the configuration. Computers set up before with another
  address keep reading that one until they get the new configuration (`run.cmd` with it). For a company added before
  this, `./selfhosted.sh source acme` makes its place; the login isn't replaced (the computers have its header).
- **Grafana** is at `https://<grafana name>`, user `admin`, the password in `.env`. The alert rules (one set per
  company, named `<company>: ...`) go to its contact points: fill in the SMTP lines of `.env` for e-mail, or add
  another contact point (Alerting > Contact points).
- **Healthchecks** can run on the same server as well (its own image): `HealthchecksBaseUrl` in the configuration
  names its ping address for the computers, `HealthchecksApiUrl` in the company's `monitoring.psd1` its API for
  `status`.
- **Back up** the Docker volumes (`loki-data`, `grafana-data`) and the folder (`.env`, `caddy/`; `sources/` is a copy
  of what you sign, which `sync` sends again) if the logs matter.
- **A kit set up before** the management sources: `./selfhosted.sh init` again (it keeps `.env`) makes their folders,
  then `docker compose up -d` (Caddy gets the new folder).

CI runs the kit end to end (`tests/ci/check-selfhosted.sh`): init, two companies, `docker compose up` with Caddy's own
certificates, the logins and tenants (a read token doesn't send or delete, a write token doesn't read, a company
doesn't see another's lines), the management sources (each read with its own header only, GET only, no listing, no
way out with `..`), and Grafana's data sources, dashboard and alert rules. The helper's side (`target`, `s`, then
`sync` with rsync over ssh) is in `tests/Wm.Tests.ps1`.

## Healthchecks.io setup

1. Create a project and generate a **Ping key** in its settings.
2. Put it in `HealthchecksPingKey`.
3. After the first provisioning every computer has its own check. Keep its **Period at 1 day** (the update runs every
   day) and set **Grace to 3 days**, so a computer that is off over a weekend raises no alert; connect an e-mail
   notification. With a weekly `UpdateDays`, use a period of 7 days.
