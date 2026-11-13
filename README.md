# wmanager

Provisioning for Windows 11 (Home and Pro) office computers:

- removes Microsoft bloatware and services (Teams, OneDrive, Copilot, Widgets, Xbox, Outlook (new) and more),
- turns off telemetry (down to the minimum the edition allows), ads, suggestions and Bing in search,
- installs Chocolatey and the packages from `choco-reqs.txt`,
- registers a weekly package update (Monday 12:00 by default),
- sends logs to Grafana Cloud Loki and pings Healthchecks.io.

The script is safe to run repeatedly: every run brings the computer to the state defined in the configuration.
Microsoft Store, Edge, Defender and Windows Update stay.

## Quick start

1. Copy `provision.config.example.psd1` to `provision.config.psd1` and fill it in (Loki, Healthchecks, list sources).
2. Put the whole folder on a USB drive or a network share.
3. On the computer, run `run.cmd` (it asks for administrator rights by itself).
4. Enter a computer name, or press Enter to keep the current one.
5. Restart the computer when it finishes.

You can also pass the name up front: `run.cmd -ComputerName OFFICE-03`.
Provisioning is meant to be run by a person at the console: when a safety step fails (restore point, backup,
no internet), it asks whether to continue. Without a console the answer is "no" and provisioning stops before
changing anything.

## Files

| File | Role |
| --- | --- |
| `run.cmd` | Double-click launcher; elevates and passes parameters through |
| `Provision.ps1` | Main script |
| `Update-Packages.ps1` | Weekly update (`wmanager-Update` task) and retry at sign-in (`wmanager-Retry`) |
| `Notify-User.ps1` | Restart notification and a one-time prompt to set the default browser (`wmanager-Notify`) |
| `Restore-Backup.ps1` | Undoes the registry changes made by provisioning (see [Backup and restore](#backup-and-restore)) |
| `provision.config.example.psd1` | Configuration template; the real `provision.config.psd1` stays out of the repo |
| `choco-reqs.txt` | Package list |
| `lib\*.ps1` | Stages: shared functions, backup and undo journal, debloat, privacy, Chocolatey, scheduled tasks |
| `tests\` | Pester tests for the list parser |

On the computer everything lands in `C:\ProgramData\wmanager`:
only Administrators and SYSTEM can write there, and only they can read `provision.config.psd1` (which holds the tokens).
If that folder already exists but is a link or is not owned by Administrators or SYSTEM (any user can create folders
in `C:\ProgramData`), provisioning moves it aside to `wmanager.untrusted-<timestamp>` and starts with a fresh one.

## Provisioning steps

1. Check for Windows 11 and administrator rights, determine the computer name.
2. Check that the Chocolatey and package-list servers answer. Without internet the script asks whether to go on
   without installing programs (Enter = stop, nothing changed yet); the weekly task installs them later.
3. System restore point. If it can't be created, the script asks whether to go on without it (Enter = stop).
   `run.cmd -SkipRestorePoint` skips the restore point and the question.
4. Backup of Store apps and the registry, and the start of the undo journal (see [Backup and restore](#backup-and-restore)).
   If it fails, the script asks the same way.
5. Copy files to `C:\ProgramData\wmanager` and set permissions.
6. Rename the computer (if a name was given; takes effect after a restart).
7. Debloat: apps from the `RemoveAppx` list (for all users and from the system image), OneDrive, policies, Edge.
8. Privacy: telemetry, the `DiagTrack` and `dmwappushservice` services, ads, suggestions, local-only search.
9. Chocolatey, package sources, installing the packages from the list.
10. Chrome as the default browser for new accounts (DISM); existing users get the Settings page once.
11. Register the scheduled tasks (folder `\wmanager\`).

User settings are applied to every existing profile and to the default profile (new accounts).

### OneDrive

If Desktop, Documents or Pictures are redirected to OneDrive in any profile (local, domain or Entra ID account),
or a profile's registry cannot be checked, the script **does not remove** OneDrive on that computer
and writes a warning to the log.

## Backup and restore

Before changing anything, provisioning writes a backup to `C:\ProgramData\wmanager\state\backup\<date>\`
(readable only by Administrators and SYSTEM; the first backup, marked with `first.txt`, and the latest one are kept):

| File | Content |
| --- | --- |
| `appx-installed.csv`, `appx-provisioned.csv` | Store apps installed for users and in the system image |
| `oem-default-associations.xml` or `.none` | Default apps for new accounts (`System32\OEMDefaultAssociations.xml`, which DISM import writes), or a marker that there were none |
| `machine-NN.reg`, `user-pNN-<profile>-NN.reg` | Registry branches that debloat and privacy change; user files use `HKEY_CURRENT_USER`, so that user can import them |
| `manifest.txt` | Which key went to which file, and which keys did not exist |

The undo journal `state\backup\journal.jsonl` records, for every registry value wmanager changes during provisioning,
its state before the very first change (old value and type, or "did not exist"). Each entry is written the moment the
value changes, so an interrupted run loses nothing. It is shared by all provisioning runs.

To undo, run on the computer as administrator:

```powershell
powershell -ExecutionPolicy Bypass -File C:\ProgramData\wmanager\Restore-Backup.ps1
```

It asks for confirmation, then puts every journaled value back (or removes it, and removes keys wmanager created
if they are empty) for the computer and for every profile that still exists. Changes users made later in the same
keys are left alone. It also restores the default apps for new accounts from the first backup (or the Windows defaults
if there were none), lists Store apps
removed since then, and offers to disable the wmanager tasks (otherwise the weekly run applies debloat again).
Restart the computer afterwards.

Not undone: removed Store apps (reinstall from the Store) and OneDrive (reinstall from Microsoft), installed
Chocolatey packages, the computer name. Settings the weekly run applies to profiles created after provisioning
are not in the journal. Programs and system files can be rolled back with the system restore point.

## choco-reqs.txt

```
googlechrome !noupdate        # install the latest, don't update (it updates itself)
libreoffice-fresh             # latest, updated weekly
libreoffice-fresh@latest      # same thing, written explicitly
7zip@24.8.0                   # pinned version (choco pin), never updated
vlc | --params "/NoDesktopShortcut"   # extra choco parameters
```

- Write a pinned version exactly as `choco list` shows it (e.g. `24.8.0`).
- Changing the version number in the list changes the installed version on the next run (downgrades too).
- A new package on the list is installed on the next run. Packages removed from the list are not uninstalled.
- The list is validated before use; an invalid line (unknown option, duplicate) rejects the whole source and the script moves on to the next one.

The list sources (`ReqsSources`) are tried in order: URL, share, file next to the script.
The last valid copy is kept in `C:\ProgramData\wmanager\state\choco-reqs.cache.txt` and is used when no source responds.

> Anyone who can change the list behind the URL can install programs as SYSTEM on every computer.
> Use HTTPS only, and a repository with restricted write access.

## Weekly update

- `wmanager-Update` (SYSTEM): scheduled by `UpdateDays` and `UpdateTime`; after a missed run it starts right after boot.
  It installs Chocolatey if it is missing, fetches the list, installs new packages, upgrades packages that are neither pinned nor `!noupdate`,
  reruns debloat (`RerunDebloatWeekly`) and updates its own schedule if the configuration changed.
- A package whose program is running (`RunningProcessMap`) is deferred; `wmanager-Retry` tries again 2 minutes after sign-in.
  An empty process list (as for `rustdesk`, which always runs as a service) means the package is never deferred.
- When a restart is needed, `wmanager-Notify` shows the user a notification. The computer never restarts on its own.
- Without internet (the Chocolatey and package-list servers don't answer) the weekly run changes nothing and reports
  nothing; `wmanager-Retry` does the full weekly run at the next sign-in.

Manual run: `Start-ScheduledTask -TaskPath '\wmanager\' -TaskName 'wmanager-Update'`.

## Logs and monitoring

- Locally: `C:\ProgramData\wmanager\logs\<provision|update|retry>-YYYY-MM-DD_HHMM.log`, deleted after `LogRetentionDays` (90 days).
  The full Chocolatey output is only in the local log (and in `C:\ProgramData\chocolatey\logs`).
- **Grafana Cloud Loki**: at the end of a run the script pushes the entries over HTTP (`/loki/api/v1/push`), with no agent.
  Labels: `service_name="wmanager"`, `host`, `job` (`provision`, `update`, `retry`), `level`.
  When Grafana doesn't respond (or rejects the token), the batch waits in `logs\outbox` and is sent on the next run.
  A batch Loki rejects for good (HTTP 400 or 413, e.g. entries too old) is moved to `logs\outbox\rejected` so it doesn't block newer ones.
  Example query: `{service_name="wmanager", level="error"}`.
- **Healthchecks.io**: a `/start` ping at the beginning (in provisioning: once the computer name is settled), and success
  or `/fail` (with the tail of the log) at the end of provisioning and of the weekly update. Provisioning stopped before
  the name is settled (e.g. a declined question) sends nothing; the console shows the result.
  The check is created on the first ping (`?create=1`); its name is the computer name (with an optional `HealthchecksSlugPrefix`).

Log messages, console output and user notifications are in Polish.

### Grafana Cloud setup

1. Grafana Cloud → Connections → Loki: note the URL (e.g. `https://logs-prod-012.grafana.net`) and the numeric User.
2. Administration → Cloud access policies: create a policy with only the `logs:write` scope and generate a token.
3. Put `LokiUrl`, `LokiUser` and `LokiToken` in `provision.config.psd1`.

### Healthchecks.io setup

1. Create a project and generate a **Ping key** in its settings.
2. Put it in `HealthchecksPingKey`.
3. After the first provisioning every computer has its own check. Set its **Period to 7 days** and **Grace to 2 days**
   (an auto-created check has a 1-day period) and connect an e-mail notification.

## Tests

On Windows with Pester 5:

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser
Invoke-Pester .\tests
```

Before rolling out to computers: Windows 11 Home and Pro virtual machines (with a snapshot), two consecutive runs
(the second run must not report errors), a manual run of the task, a missed schedule, the restart notification,
then one pilot computer for a week.

## Limitations

- In Home and Pro, telemetry goes no lower than "Required" (1); level 0 works only in Enterprise/Education.
- Blocking the system from reinstalling apps works only in Enterprise/Education, so debloat repeats every week.
- Windows 11 doesn't let a script set the default browser for existing users; they get the Settings page once.
- Requires Chocolatey 2.x (installed automatically).
