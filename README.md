# wmanager

Provisioning for Windows 11 (Home and Pro) office computers:

- removes Microsoft bloatware and services (Teams, OneDrive, Copilot, Widgets, Xbox, Outlook (new) and more),
- turns off telemetry (down to the minimum the edition allows), ads, suggestions and Bing in search,
- installs Chocolatey and the packages from `choco-reqs.txt`,
- optionally puts computers into groups from a signed management source: extra packages, scripts and scheduled jobs
  (e.g. a daily system report to Loki) per group (see [Computer groups](docs/groups.md)),
- registers a package update, every day at 12:00 by default,
- sends logs to Grafana Cloud Loki and pings Healthchecks.io.

The script is safe to run repeatedly: every run brings the computer to the state defined in the configuration.
It speaks English, German, French, Spanish, Italian, Polish, Dutch, Portuguese, Romanian and Czech (see
[Languages](docs/languages.md)).
Microsoft Store, Edge, Defender and Windows Update stay.

## Quick start

From a USB drive or a network share:

1. Download wmanager: the ZIP of the latest release (`wmanager-vX.Y.Z.zip` under **Releases** on GitHub), or
   `git clone`, and unpack it.
2. Optionally edit `choco-reqs.txt`, the list of programs (see [choco-reqs.txt](docs/provisioning.md#choco-reqstxt)).
3. Run the configuration wizard: `init.cmd` on Windows, or `pwsh ./init.ps1` on Linux or macOS (PowerShell 7).
   It asks for the update time, Grafana Cloud Loki, Healthchecks.io and the management source of computer groups,
   checks them (a test line to Loki, an optional test ping, the signed manifest of the source) and writes
   `provision.config.psd1`. Every answer is optional; without the file at all, provisioning uses the example
   configuration (no Loki, no Healthchecks). Other settings (apps to remove, default browser, Chocolatey sources)
   are edited in the file by hand.
4. Put the whole folder on a USB drive or a network share. `provision.config.psd1` holds the tokens: keep the drive
   under control.
5. On the computer, run `run.cmd` (it asks for administrator rights by itself) and enter a computer name, or press
   Enter to keep the current one.
6. The first run takes about half an hour, mostly downloading the programs. Restart the computer when it finishes.
   From then on it updates itself every day at 12:00; logs are in `C:\ProgramData\wmanager\logs`.

You can also pass the name up front: `run.cmd -ComputerName OFFICE-03`.

**Several companies** on one USB drive: put each company's configuration in `configs\<company>\` next to `run.cmd`
(`configs\acme\provision.config.psd1`, with its certificate when it has a management source) instead of
`provision.config.psd1`. `run.cmd` then asks which company the computer is for; `run.cmd -ConfigPath <file>` picks one
without asking. On Linux, `pwsh tools/wm.ps1` keeps the companies and prepares the drive for you; see
[Several companies](docs/companies.md).

Straight from the internet, without a USB drive: prepare `provision.config.psd1` with the wizard (steps 2-3) and put it
on a share or at an https:// address (e.g. a private repository; with a management source, the certificate next to
it). Then, on the computer, in PowerShell started as administrator:

```powershell
irm https://github.com/lechup/wmanager/releases/latest/download/install.ps1 | iex
```

It downloads the latest release, checks the ZIP against the release's SHA-256 sums (a complete, intact download),
asks where the configuration is (a path, also one pasted in quotes, a folder with the configurations of several
companies, which then asks which one, or an https:// address with an optional `Authorization` header; Enter = the
example configuration) and runs provisioning the way `run.cmd` does, in Windows
PowerShell 5.1. It uses the download links, not the GitHub API (60 requests an hour per address). With parameters:

```powershell
& ([scriptblock]::Create((irm https://github.com/lechup/wmanager/releases/latest/download/install.ps1))) -ComputerName OFFICE-03 -Config \\server\share\wmanager\provision.config.psd1
```

Provisioning is meant to be run by a person at the console: when a safety step fails (restore point, backup,
no internet), it asks whether to continue. Without a console the answer is "no" and provisioning stops before
changing anything.

## Documentation

- [Provisioning](docs/provisioning.md): what a run does, backup and restore, `choco-reqs.txt`, the scheduled update
- [Computer groups](docs/groups.md): the signed management source: groups, packages, scripts and jobs, where to keep
  it, setting it up, making a change, the library, updating wmanager
- [Several companies](docs/companies.md): `tools/wm.ps1`, the companies' configurations, keys, sources and the USB
  drive
- [Logs and monitoring](docs/monitoring.md): Loki, Grafana Cloud, the dashboard and alerts, hosting Grafana and Loki
  yourself, Healthchecks.io
- [Languages](docs/languages.md): the languages, how one is chosen, adding a message or a language
- [Tests](docs/testing.md): Pester, CI, test virtual machines
- [Releases](docs/releases.md): publishing a version

## Files

| File | Role |
| --- | --- |
| `run.cmd` | Double-click launcher; elevates and passes parameters through |
| `install.ps1` | Install from the internet: the latest release, checked, then provisioning (see [Quick start](#quick-start)) |
| `init.cmd`, `init.ps1` | Configuration wizard: writes and checks `provision.config.psd1` (Windows PowerShell 5.1 or PowerShell 7, also on Linux) |
| `Provision.ps1` | Main script |
| `Update-Packages.ps1` | Scheduled update, daily by default (`wmanager-Update` task), and retry at sign-in (`wmanager-Retry`) |
| `Invoke-Jobs.ps1` | Group jobs, every hour (`wmanager-Jobs`, only with a management source) |
| `Invoke-Logon.ps1` | The groups' sign-in scripts, as the user who signs in (`wmanager-Logon`, only with a management source) |
| `Notify-User.ps1` | Restart notification and a one-time prompt to set the default browser (`wmanager-Notify`) |
| `Restore-Backup.ps1` | Undoes the registry changes made by provisioning (see [Backup and restore](docs/provisioning.md#backup-and-restore)) |
| `provision.config.example.psd1` | Configuration template; the real `provision.config.psd1` stays out of the repo |
| `choco-reqs.txt` | Package list (when there is no management source) |
| `lang\<code>\*.psd1` | Messages in each language (see [Languages](docs/languages.md)) |
| `lib\*.ps1` | Stages: shared functions, backup and undo journal, debloat, privacy, Chocolatey, computer groups, wmanager's own updates, scheduled tasks, the configuration wizard |
| `tools/` | For the management source: `groups.ps1` (show, check and edit groups, packages, scripts, jobs and the wmanager version, switch on library items; PowerShell 7 or 5.1), and Linux scripts `new-signing-cert.sh` (once) and `publish.sh` (after every change); `wm.ps1`, a menu over all of them for several companies (see [Several companies](docs/companies.md)); `build-release.sh` (see [Releases](docs/releases.md)) |
| `configs\<company>\` | Optional, on the USB drive: the configuration of each company; `run.cmd` asks which one (see [Several companies](docs/companies.md)) |
| `library/` | Ready group scripts and jobs to switch on with `tools/groups.ps1 enable` (see [Library](docs/groups.md#library-of-ready-scripts-and-jobs)) |
| `examples/grafana/` | A Grafana dashboard and Loki alert rules for the computers' lines (see [Grafana dashboard and alerts](docs/monitoring.md#grafana-dashboard-and-alerts)) |
| `examples/selfhosted/` | Loki, Grafana and Caddy of your own with Docker, a tenant per company (see [Hosting Grafana and Loki yourself](docs/monitoring.md#hosting-grafana-and-loki-yourself)) |
| `examples/management/` | Template of a management source (group map, lists, an example script, the daily system report from the library) |
| `docs/` | The documentation (see [Documentation](#documentation)) |
| `tests\` | Pester tests (list parser, management source checks, app removal, configuration wizard), integration tests, CI scripts, test virtual machines (`tests/vm/`) |
| `.github/workflows/tests.yml` | CI on a GitHub-hosted Windows runner (see [Tests](docs/testing.md)) |
| `.github/workflows/release.yml` | Publishes a release when a `vX.Y.Z` tag is pushed (see [Releases](docs/releases.md)) |

On the computer everything lands in `C:\ProgramData\wmanager`:
only Administrators and SYSTEM can write there, and only they can read `provision.config.psd1` (which holds the tokens).
If that folder already exists but is a link or is not owned by Administrators or SYSTEM (any user can create folders
in `C:\ProgramData`), provisioning moves it aside to `wmanager.untrusted-<timestamp>` and starts with a fresh one.

## Limitations

- In Home and Pro, telemetry goes no lower than "Required" (1); level 0 works only in Enterprise/Education.
- Blocking the system from reinstalling apps works only in Enterprise/Education, so debloat repeats with every scheduled update.
- Windows 11 doesn't let a script set the default browser for existing users; they get the Settings page once.
- Requires Chocolatey 2.x (installed automatically).
