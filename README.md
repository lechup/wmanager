# wmanager

Provisioning for Windows 11 (Home and Pro) office computers:

- removes Microsoft bloatware and services (Teams, OneDrive, Copilot, Widgets, Xbox, Outlook (new) and more),
- turns off telemetry (down to the minimum the edition allows), ads, suggestions and Bing in search,
- installs Chocolatey and the packages from `choco-reqs.txt`,
- optionally puts computers into groups from a signed management source: extra packages, scripts and scheduled jobs
  (e.g. a daily system report to Loki) per group (see [Computer groups](#computer-groups)),
- registers a package update, every day at 12:00 by default,
- sends logs to Grafana Cloud Loki and pings Healthchecks.io.

The script is safe to run repeatedly: every run brings the computer to the state defined in the configuration.
It speaks English, German, French, Spanish, Italian, Polish, Dutch, Portuguese, Romanian and Czech (see
[Languages](#languages)).
Microsoft Store, Edge, Defender and Windows Update stay.

## Quick start

From a USB drive or a network share:

1. Download wmanager: the ZIP of the latest release (`wmanager-vX.Y.Z.zip` under **Releases** on GitHub), or
   `git clone`, and unpack it.
2. Optionally edit `choco-reqs.txt`, the list of programs (see [choco-reqs.txt](#choco-reqstxt)).
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
[Several companies](#several-companies).

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

## Files

| File | Role |
| --- | --- |
| `run.cmd` | Double-click launcher; elevates and passes parameters through |
| `install.ps1` | Install from the internet: the latest release, checked, then provisioning (see [Quick start](#quick-start)) |
| `init.cmd`, `init.ps1` | Configuration wizard: writes and checks `provision.config.psd1` (Windows PowerShell 5.1 or PowerShell 7, also on Linux) |
| `Provision.ps1` | Main script |
| `Update-Packages.ps1` | Scheduled update, daily by default (`wmanager-Update` task), and retry at sign-in (`wmanager-Retry`) |
| `Invoke-Jobs.ps1` | Group jobs, every hour (`wmanager-Jobs`, only with a management source) |
| `Notify-User.ps1` | Restart notification and a one-time prompt to set the default browser (`wmanager-Notify`) |
| `Restore-Backup.ps1` | Undoes the registry changes made by provisioning (see [Backup and restore](#backup-and-restore)) |
| `provision.config.example.psd1` | Configuration template; the real `provision.config.psd1` stays out of the repo |
| `choco-reqs.txt` | Package list (when there is no management source) |
| `lang\<code>\*.psd1` | Messages in each language (see [Languages](#languages)) |
| `lib\*.ps1` | Stages: shared functions, backup and undo journal, debloat, privacy, Chocolatey, computer groups, wmanager's own updates, scheduled tasks, the configuration wizard |
| `tools/` | For the management source: `groups.ps1` (show, check and edit groups, packages, scripts, jobs and the wmanager version, switch on library items; PowerShell 7 or 5.1), and Linux scripts `new-signing-cert.sh` (once) and `publish.sh` (after every change); `wm.ps1`, a menu over all of them for several companies (see [Several companies](#several-companies)); `build-release.sh` (see [Releases](#releases)) |
| `configs\<company>\` | Optional, on the USB drive: the configuration of each company; `run.cmd` asks which one (see [Several companies](#several-companies)) |
| `library/` | Ready group scripts and jobs to switch on with `tools/groups.ps1 enable` (see [Library](#library-of-ready-scripts-and-jobs)) |
| `examples/management/` | Template of a management source (group map, lists, an example script, the daily system report from the library) |
| `tests\` | Pester tests (list parser, management source checks, app removal, configuration wizard), integration tests, CI scripts, test virtual machines (`tests/vm/`) |
| `.github/workflows/tests.yml` | CI on a GitHub-hosted Windows runner (see [Tests](#tests)) |
| `.github/workflows/release.yml` | Publishes a release when a `vX.Y.Z` tag is pushed (see [Releases](#releases)) |

On the computer everything lands in `C:\ProgramData\wmanager`:
only Administrators and SYSTEM can write there, and only they can read `provision.config.psd1` (which holds the tokens).
If that folder already exists but is a link or is not owned by Administrators or SYSTEM (any user can create folders
in `C:\ProgramData`), provisioning moves it aside to `wmanager.untrusted-<timestamp>` and starts with a fresh one.

## Provisioning steps

1. Check for Windows 11 and administrator rights, the management settings and signing certificate (if set),
   determine the computer name.
2. Check that the Chocolatey, package-list and management servers answer. Without internet the script asks whether
   to go on without installing programs (Enter = stop, nothing changed yet); the scheduled update installs them later.
3. System restore point. If it can't be created, the script asks whether to go on without it (Enter = stop).
   `run.cmd -SkipRestorePoint` skips the restore point and the question.
4. Backup of Store apps and the registry, and the start of the undo journal (see [Backup and restore](#backup-and-restore)).
   If it fails, the script asks the same way.
5. Copy files to `C:\ProgramData\wmanager` and set permissions.
6. Rename the computer (if a name was given; takes effect after a restart).
7. Debloat: apps from the `RemoveAppx` list (from the system image and for all users), OneDrive, policies, Edge.
   For DevHome and the new Outlook it also removes the Windows Update entries (`UScheduler_Oobe`) that would install
   them again minutes after removal. An installation Windows has already started (in the first minutes after setup)
   can still finish once; the next scheduled update removes the app again.
8. Privacy: telemetry, the `DiagTrack` and `dmwappushservice` services, ads, suggestions, local-only search.
9. Chocolatey, package sources, installing the packages from the list (with a management source: the common list
   plus the lists of the computer's groups).
10. Chrome as the default browser for new accounts (DISM); existing users get the Settings page once.
11. Register the scheduled tasks (folder `\wmanager\`; `wmanager-Jobs` only with a management source).

With a management source, provisioning doesn't run the group scripts itself: it runs as the person at the console,
and scripts must run as SYSTEM. `wmanager-Jobs` runs them a few minutes after provisioning (or right after the restart).

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
its state before the very first change (old value and type, or "did not exist"); for a key it deletes (the
`UScheduler_Oobe` entries) that means every value in it, so the key comes back on restore. Each entry is written the moment the
value changes, so an interrupted run loses nothing. It is shared by all provisioning runs.

To undo, run on the computer as administrator:

```powershell
powershell -ExecutionPolicy Bypass -File C:\ProgramData\wmanager\Restore-Backup.ps1
```

It asks for confirmation, then puts every journaled value back (or removes it, and removes keys wmanager created
if they are empty) for the computer and for every profile that still exists. Changes users made later in the same
keys are left alone. It also restores the default apps for new accounts from the first backup (or the Windows defaults
if there were none), lists Store apps
removed since then, and offers to disable the wmanager tasks (otherwise the scheduled update applies debloat again).
With the tasks disabled it also removes the wmanager signing certificate from the trusted root store.
Restart the computer afterwards.

Not undone: removed Store apps (reinstall from the Store) and OneDrive (reinstall from Microsoft), installed
Chocolatey packages, what group scripts changed, the computer name. Settings the scheduled update applies to profiles created after provisioning
are not in the journal, nor are `UScheduler_Oobe` entries that Windows created after provisioning and the scheduled update deleted. Programs and system files can be rolled back with the system restore point.

## choco-reqs.txt

```
googlechrome !noupdate        # install the latest, don't update (it updates itself)
libreoffice-fresh             # latest, kept up to date
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

> Anyone who can change the list behind the URL can install programs as SYSTEM on every computer
> (the part after `|` goes straight to choco, so even `--source` pointing to their own server).
> Use HTTPS only, and a repository with restricted write access, or better a signed management source:
> with `Management.Source` set, `ReqsSources` is not used.

## Computer groups

Optional. A **management source** is a signed folder of plain files that computers download from an `https://` address
(your own web server, a private Git repository), a network share or a local folder (see
[Where to keep the source](#where-to-keep-the-source)).
It holds the common package list, the map of computers to groups, each group's own packages, scripts and jobs, and
the wmanager version the computers run.
Every computer checks it at provisioning and in each scheduled update (the hourly job run at most once a day):

```
manifest.psd1                        generated and signed by tools/publish.sh; don't edit
source-id.txt                        identifier of this source, created by tools/publish.sh; don't copy it to another source
groups.psd1                          computer name -> groups
version.psd1                         wmanager version the computers run (optional; see Updating wmanager)
choco-reqs.txt                       common list (every computer)
groups/<group>/choco-reqs.txt        extra packages for the group (optional)
groups/<group>/scripts/*.ps1         scripts run as SYSTEM when their content changes (optional)
groups/<group>/jobs/<when>/*.ps1     jobs run as SYSTEM on a schedule: hourly, daily, weekly (optional)
groups/<group>/...                   other files the scripts use (installers, drivers...)
```

`groups.psd1`:

```powershell
@{
    Default   = @('all')                                # groups of every computer
    Computers = @{
        'OFFICE-01' = @('accounting')
        'OFFICE-02' = @('accounting', 'floor-1')
    }
}
```

A computer that is not in the map gets only `Default` and the common list. Moving a computer to another group
is a change in `groups.psd1`; nothing has to be done on the computer.

- **Packages:** the group lists use the `choco-reqs.txt` format. A group entry replaces the common entry for the same
  package on that group's computers; if two groups of one computer describe the same package differently, the first
  group in the computer's list wins (with a warning). Packages are never uninstalled, also when a computer leaves a
  group or a package disappears from a list.
- **Scripts:** run by Windows PowerShell 5.1 as SYSTEM, in a separate process, group by group in the order of the map,
  files by name (number them: `10-`, `20-`). They are run by the hourly `wmanager-Jobs` task (first a few minutes after
  provisioning) and checked again by the scheduled update. A script runs once and again whenever its content changes; it
  doesn't run for the same content again. A change in the source reaches a computer within about a day (the hourly
  task fetches the source every 20 hours) or at the scheduled update. Exit code `0` = done, `3010` = done and the computer
  needs a restart (the user gets the notification), anything else, an exception or the time limit
  (`ScriptTimeoutMinutes`, 15 by default) = error: the hourly task and the scheduled update try a failed script again
  after 20 hours (at once if its content changes). A failed script doesn't stop the scripts after it.
  Output goes to the log (and to Loki). Debloat repeats with every scheduled update while a script doesn't, so a script can't
  permanently turn back on something debloat removes. Removing a script or leaving a group doesn't undo what it did.
- **Jobs:** like scripts, but on a schedule: the `wmanager-Jobs` task (SYSTEM) starts every hour and runs each job of the
  computer's groups whose time has come, by folder: `jobs/hourly`, `jobs/daily`, `jobs/weekly`. A computer that was off
  catches up at the next hour it is on. The start time is recorded before the job runs, so a failed job waits for its
  next turn (the error is in the log). Time limit `JobTimeoutMinutes` (10 by default). Every line a job prints goes to
  Loki unchanged, with the label `task="<group>/<file name>"` (`job="jobs"`): print one JSON object per line and Grafana
  can read it with `| json`. The local log is `logs\jobs-YYYY-MM-DD.log`. Example (also in the
  [library](#library-of-ready-scripts-and-jobs)):
  `examples/management/groups/all/jobs/daily/system-report.ps1`, a daily report (model and serial number, disks, RAM,
  uptime, Windows Update, Defender, BitLocker, TPM, Secure Boot, firewall, local administrators, disk health, battery):

  ```
  {service_name="wmanager", task="all/system-report"} | json | kind="disk"
  ```
- **For both:** the working folder is the system TEMP. Use `$PSScriptRoot` or `WMANAGER_GROUP_DIR` (the group's folder)
  for the group's files; other variables: `WMANAGER_GROUP`, `WMANAGER_COMPUTER`, and `WMANAGER_JOB` for jobs. The group
  folders are replaced with every new version of the source, so don't run programs or services from them: copy what
  has to stay (e.g. an agent) elsewhere first. Save files as UTF-8 with BOM (otherwise 5.1 garbles letters outside ASCII).

### How a computer checks the source

`manifest.psd1` lists every file with its SHA256 and carries an Authenticode signature. A computer uses a new version
only when all of this holds:

1. The signature is valid and made with the certificate from the config (`Management.Certificate`, pinned by its
   thumbprint), not with just any trusted certificate.
2. Its `SourceId` is the one in the config (`Management.SourceId`), so a manifest signed with the same key for another
   source (e.g. a test repository) doesn't fit.
3. Its `Serial` is not lower than the version this computer accepted before.
4. Every file it lists downloads and matches its hash, and `groups.psd1` and all lists parse.

Otherwise the new version is rejected (an error in the log) and the last verified copy, in
`C:\ProgramData\wmanager\state\managed` (Administrators and SYSTEM only), is used. If the source can't be reached,
the copy is used too (a warning).

Someone who can change the files at the source (push to the repository, write to the server or the share) but doesn't
have the signing key can't add or change code. They can still: serve an older signed version to a computer that has
none yet (a new or re-provisioned one), and keep computers on the version they already have by withholding newer ones.
So keep write access to the source tight anyway, and when you remove a dangerous script, check new computers after
provisioning.

Windows accepts a self-signed signature only from a certificate in the computer's trusted root store, so provisioning
adds the wmanager certificate to **LocalMachine\Root** (with the friendly name `wmanager-signing`). The certificate is
limited to code signing and is not a CA, so it can't vouch for websites or other certificates; but anything signed with
its key is trusted on the computer, so guard the key. A new certificate in the config replaces the old one at the next run.

### Where to keep the source

A computer reads `<Source>/manifest.psd1`, then every file the manifest lists as `<Source>/<path>`. Anything that
serves files as they are works; no directory listing, API or Git on the server is needed. `Management.Source` can be:

| `Source` | Login | Notes |
| --- | --- | --- |
| `https://files.example.com/wmanager` (your own web server: nginx, IIS...) | optional: `Management.AuthHeader` is sent as the `Authorization` header, e.g. `Basic d21hbmFnZXI6...` for basic auth (`printf 'user:password' \| base64`) or `Bearer ...` | copy the folder there after each `publish.sh`, `manifest.psd1` last |
| `https://raw.githubusercontent.com/<owner>/<repo>/main` (a private GitHub repository) | `token github_pat_...`, a fine-grained token with **Contents: read-only** for this one repository | `git push` after each `publish.sh`; GitHub's cache delays new files by a few minutes |
| `\\server\share\wmanager` | none: the tasks run as SYSTEM, which reaches a share as the computer account | works in a domain, not in a workgroup (use HTTPS there) |
| `C:\wm-source` | none | for tests |

Not supported: plain `http://`, and a token in the address itself (`?sig=...`, presigned links): the file path is added
at the end of the address, so only a fixed login in the header works. Cloud storage that needs a signature per request
or in the address (S3, Azure Blob with SAS) doesn't fit either; a publicly readable bucket works, but then anyone can
read the source (computer names, scripts).

### Setting up (once)

On Linux (needs `openssl`, `osslsigncode`: `sudo apt install osslsigncode`):

1. `tools/new-signing-cert.sh`: creates `~/.wmanager-signing/` with `key.pem` (protected with a passphrase),
   `cert.pem` and `wmanager-signing.cer`. Back up the key and the passphrase; without them you can't sign changes,
   and a new key means a new certificate on every computer.
2. Copy `examples/management/` to a folder of its own. In a Git repository (keep it **private**) keep its
   `.gitattributes` (`* -text`: git must not change line endings, or the hashes and the signature stop matching);
   large files can't go through Git LFS (the repository would hold a pointer instead of the file). A plain folder that
   you copy to a web server or a share needs neither.
3. Edit `groups.psd1`, `choco-reqs.txt` and the groups, then sign and publish (see below). The first `publish.sh`
   creates `source-id.txt` and prints the identifier.
4. In `provision.config.psd1` set `Management`: `Source` (the address or path from
   [Where to keep the source](#where-to-keep-the-source)), `SourceId` (from step 3), `AuthHeader` if the server
   needs a login (e.g. `token github_pat_...`), and put
   `wmanager-signing.cer` next to `provision.config.psd1`. The wizard (`init.cmd` / `pwsh ./init.ps1`) does this:
   it fetches the manifest, offers its identifier, checks the signature with the certificate (on Windows) and copies
   the certificate next to the configuration.

### Making a change

Edit the files by hand, or let `tools/groups.ps1` do it (PowerShell 7, `pwsh`, on Linux or macOS; Windows PowerShell
5.1 works too). It reads the source with the same code as the computers, and its edits change one entry and keep the
rest of each file as it is (comments, order, BOM, line endings):

```bash
src=~/path/to/management
pwsh tools/groups.ps1 $src show                              # groups, computers, how many packages, scripts and jobs
pwsh tools/groups.ps1 $src show OFFICE-03                    # what that computer gets, and which entry wins
pwsh tools/groups.ps1 $src add-computer OFFICE-03 accounting floor-1
pwsh tools/groups.ps1 $src remove-computer OFFICE-03 floor-1 # without groups: out of groups.psd1 altogether
pwsh tools/groups.ps1 $src add-package accounting 'adobereader !noupdate'   # or replaces the line of that package
pwsh tools/groups.ps1 $src add-package common '7zip@24.8.0'
pwsh tools/groups.ps1 $src remove-package floor-1 vlc
pwsh tools/groups.ps1 $src new-script accounting printers    # groups/accounting/scripts/20-printers.ps1
pwsh tools/groups.ps1 $src new-job all weekly cleanup        # groups/all/jobs/weekly/cleanup.ps1
pwsh tools/groups.ps1 $src set-version v0.2.0                # see Updating wmanager below
pwsh tools/groups.ps1 $src check
```

Quote package lines with `' '` (in bash `!` inside `" "` is history expansion). New scripts and jobs come from a
template, as UTF-8 with BOM and CRLF, and scripts are numbered in tens after the last one (they run in name order).
`check` reports what the computers would reject: a `groups.psd1`, `version.psd1` or package list that doesn't parse, a script with a
syntax error, a file name they don't accept. It also warns about what they would ignore or do differently than you
might expect: a group without a folder, a folder no computer uses, scripts and jobs in the wrong folder, a script
with non-ASCII characters and no BOM, a package two groups of one computer describe differently, script numbers of
different widths (`5-a.ps1` runs after `10-b.ps1`). Run in PowerShell 7, it also rejects the PowerShell 7 syntax that
Windows PowerShell 5.1 on the computers doesn't have (`? :`, `??`, `??=`, `&&`, `||`, `?.`). In a Git repository it
looks at the files git will push, as `publish.sh` does. `common` means the common list, so don't name a group that.

Then sign and publish:

```bash
tools/publish.sh ~/path/to/management     # asks for the key passphrase
# in a Git repository:
cd ~/path/to/management && git add -A && git commit -m "..." && git push
# or on a web server or a share: copy the folder, manifest.psd1 last, e.g.
rsync -a --exclude manifest.psd1 --exclude '.*' ~/path/to/management/ server:/var/www/wmanager/ &&
    rsync -a ~/path/to/management/manifest.psd1 server:/var/www/wmanager/
```

In a Git repository `publish.sh` takes the files git will push (tracked ones and new ones that aren't ignored); in a
plain folder, every file except hidden ones. It runs `tools/groups.ps1 check` on exactly these files and doesn't sign
a source with errors (without `pwsh` it warns and checks only file names and BOMs). It checks the names (letters,
digits, `.`, `-`, `_`), refuses links, Git LFS files and a repository without `* -text`, writes the manifest with a new
`Serial` and signs it.

Notes:

- GitHub serves raw files through a cache for a few minutes. A computer that catches the new manifest with an old
  file rejects that version (hash mismatch) and uses it at the next run. Wait a few minutes after pushing before
  provisioning a computer. On your own server the same happens if `manifest.psd1` arrives before the files, hence
  "manifest last".
- The token is stored on every computer (readable only by administrators) and must not expire before you update the
  config on all of them; give it a long expiry and only read access to the source.
- The certificate is valid for 10 years. A signature without a timestamp stops being valid when the certificate expires
  (then computers reject the source, also their saved copy); `WM_TSA=<url> tools/publish.sh ...` adds an RFC 3161
  timestamp, which keeps it valid. Replace the certificate before it expires: `publish.sh` and the computers warn
  60 days ahead.
- The `wmanager-Jobs` task is registered at provisioning when `Management.Source` is set; if you add a management
  source to an existing computer, run provisioning again.
- Script and job output goes through the console code page (e.g. 852 on Polish Windows): characters outside it come
  out as `?`.

### Library of ready scripts and jobs

`library/` holds scripts and jobs for common office settings and checks. `enable` copies one into a group of your
source; the copy is yours: its settings are at the top of the file, and like any group file it runs on the computers
of that group once the source is signed and published.

```bash
pwsh tools/groups.ps1 $src library                           # what there is, and which groups have it
pwsh tools/groups.ps1 $src enable windows-update all         # groups/all/scripts/20-windows-update.ps1
pwsh tools/groups.ps1 $src enable check-disk-space all       # groups/all/jobs/daily/check-disk-space.ps1
pwsh tools/groups.ps1 $src enable check-updates all weekly   # a job on another schedule
tools/publish.sh $src
```

| Name | Kind | What it does | Settings (top of the file) |
| --- | --- | --- | --- |
| `windows-update` | script | Windows Update for Business policies: no automatic restart during active hours, new Windows versions (feature updates) deferred, monthly updates optionally deferred, drivers optionally excluded. Home ignores the deferrals. | active hours (7-19), feature deferral (90 days), quality deferral (0), exclude drivers (no) |
| `power` | script | Screen-off and sleep times, plugged in and on battery; Fast Startup off, so "Shut down" is a real one and pending updates get their restart | 15 / never, 5 / 20 min; Fast Startup off |
| `defender-hardening` | script | Microsoft Defender: potentially unwanted apps blocked, network protection (malicious sites), 14 attack surface reduction rules in **audit mode** (they only record what they would block: event 1122 in the Defender log); after a few weeks without surprises set `$AsrAction = 'Enabled'`. Changes nothing when another antivirus is active; fails when Defender doesn't keep a rule (e.g. a policy overrules it). | PUA, network protection, ASR action, the list of rules |
| `network-hardening` | script | SMBv1 off (exit 3010 when that needs a restart), LLMNR and NetBIOS name guessing off (a common way to capture passwords in an office network), firewall on in every profile. NetBIOS off can stop very old devices (an old NAS) from being found by name; it is set per network adapter present when the script runs. | each of the four on or off |
| `check-disk-space` | job, daily | One JSON line per local disk; **fails** when a disk is low: less than both thresholds free | 15 GB and 10 % |
| `check-updates` | job, daily | Last successful Windows Update installation, a restart pending for too long (pending and the computer up for that many days); **fails** when behind | 40 days, 7 days |
| `check-defender` | job, daily | Real-time protection, signature age, last scan, threats found; **fails** on a problem; passes when another antivirus is registered and Defender is passive | 3 days, 14 days, 1 day |
| `system-report` | job, daily | The daily report described under **Jobs** above (no thresholds) | none |

- **Alerts:** a check job that finds a problem ends with exit code 1, which wmanager logs as an error with
  `job="jobs"`, so one Grafana alert covers every check, e.g. on
  `count_over_time({service_name="wmanager", job="jobs", level="error"} [1d]) > 0`. Its JSON lines
  (`| json | kind="check" | ok="false"`) say what and where.
- **Scripts run once per content**, like every group script: changing a setting runs the script again on every
  computer of the group. Removing a script or a computer leaving the group doesn't undo what it set.
- **New revisions:** each library file starts with `# wmanager library: <name>, revision <n>`, kept in your copy.
  When a newer wmanager brings a newer revision, `check` and `library` say which copies are older; compare the two
  files, carry your settings over, and publish (the computers run the script again). `enable` doesn't overwrite a copy.
- **One copy per computer:** `check` warns when a computer would get the same item from two of its groups (both
  run, and the later one's settings win).

### Updating wmanager

The scripts on the computers (`C:\ProgramData\wmanager`) are the version that provisioned them. With a management
source, `version.psd1` in the source names the version they run, and each computer switches to it at its next
scheduled update; nobody has to visit it. Without a management source, update a computer by provisioning it again.

```bash
pwsh tools/groups.ps1 $src set-version v0.2.0             # every computer
pwsh tools/groups.ps1 $src add-computer OFFICE-07 pilot   # a few computers first...
pwsh tools/groups.ps1 $src set-version v0.3.0 pilot       # ...get the new version a few days earlier
pwsh tools/groups.ps1 $src unset-version pilot            # then they follow the rest again
tools/publish.sh $src
```

`set-version` downloads the release ZIP from GitHub, checks it against the release's `SHA256SUMS`, checks that it is
that version and that it can install itself, and writes the version, the address of the ZIP and its SHA256 to
`version.psd1`. A computer in a group with a version of its own runs that one: its own groups come before the default
ones (`Default`), so a pilot group wins even when a default group has a version too, and among them the `groups.psd1`
order decides; a group may exist only for that, without a folder. Without `SHA256SUMS` to check against (another
`-Url`, or `-Zip` that can't be compared) it warns: whatever file it hashes is what every computer installs. `unset-version` without a group drops the
version for every computer: from then on they keep the one they have. `show` and `show <computer>` print the version.

At the scheduled update (not in the hourly run) a computer whose version differs:

1. downloads the ZIP into `state\self-update` and checks it against the SHA256 from the signed source; it doesn't use
   a file that differs or holds another version;
2. hands the run over to the new version, which copies itself into `C:\ProgramData\wmanager` (the configuration,
   state and logs stay) and does the rest of the scheduled update. It keeps a copy of the old version first: if
   copying stops partway (a file in use, a full disk), it puts the old version back, so old and new files never
   mix.

It installs exactly the named version, also an older one, so going back is `set-version` with the previous release.
If the download fails (a warning) or the new version doesn't install itself (an error), the run goes on with the
version the computer has, and the next scheduled update tries again. The log shows each step
(`wmanager v0.2.0 -> wmanager v0.3.0 ...`), and so does Loki.

- The version and the hash come from the signed source, so only the key holder decides what the computers run: a new
  release on GitHub reaches no computer until you name it, and a changed file on GitHub is refused.
- Releases before self-update (v0.1.0) can't install themselves; `set-version` refuses them.
- `-Url <address>` points the computers elsewhere: an `https://` address without a login (`Management.AuthHeader`
  is not sent there), a share or a folder, e.g. for computers that can't reach GitHub. `-Zip <file>` gives
  `set-version` a local copy to read when it can't fetch that address itself:
  `pwsh tools/groups.ps1 $src set-version v0.2.0 -Url '\\server\wmanager\wmanager-v0.2.0.zip' -Zip ./wmanager-v0.2.0.zip`.
- A newly provisioned computer runs the version it was provisioned with until its first scheduled update.
- The scheduled tasks are not registered again; a new version that needs other tasks does that itself.

### Several companies

wmanager has no server of its own, so looking after several companies takes no extra setup: each company is one
management source, one signing key and one `provision.config.psd1`. The same copy of wmanager and the same tools
serve all of them.

`tools/wm.ps1` (PowerShell 7 on Linux) keeps them in one place and leads you through it: which company, then what to
do, and what comes next. It runs the other tools on the folders of the chosen company. A company's name is the name of
its folders: 2 to 40 letters, digits, `.`, `-`, `_`, with at least one letter.

```
~/wmanager-companies/        another place: the WMANAGER_COMPANIES environment variable
  acme/
    source/                  management source (its own private repository, or a folder copied to its server)
    keys/                    key.pem, cert.pem, wmanager-signing.cer (tools/new-signing-cert.sh)
    config/                  provision.config.psd1 and its wmanager-signing.cer (the wizard)
  globex/
    ...
```

```bash
pwsh tools/wm.ps1                                            # menu: choose a company, then what to do
pwsh tools/wm.ps1 list                                       # the companies and what each still lacks
pwsh tools/wm.ps1 status                                     # the computers of every company, a line each
pwsh tools/wm.ps1 globex status                              # its computers: Healthchecks, last update, errors
pwsh tools/wm.ps1 new globex                                 # key, source, first signature, the wizard
pwsh tools/wm.ps1 globex add-computer OFFICE-07 accounting   # any tools/groups.ps1 command, on its source
pwsh tools/wm.ps1 globex changes                             # what changed since the last signature
pwsh tools/wm.ps1 globex publish                             # those changes, then check and sign; then push or copy it
pwsh tools/wm.ps1 globex config                              # the wizard for its provision.config.psd1
pwsh tools/wm.ps1 usb /media/you/USB/wmanager                # wmanager and every company's configuration
```

- **The menu of a company** shows the groups, adds and removes computers, adds and removes packages, makes a new
  script or job for a group, edits or removes one (the editor, then the check; removal asks first), switches on
  library items, sets the wmanager version, checks, signs and runs the wizard; after a change
  it shows what the signature would publish (`+` added, `~` changed, `-` removed files since the last signature,
  from the hashes in `manifest.psd1`, letter case included) and offers to sign it. `publish` shows the same first and
  asks; with nothing changed it signs only if you say so, and `publish -Yes` signs without asking (for scripts). A
  source signed with another key than the one in `keys/` (after the key was replaced) counts as a change. A new script or job starts from the template of `tools/groups.ps1` and opens in your editor
  (`$VISUAL` or `$EDITOR`, else nano or vi); when you close it, the source is checked, and a mistake opens the file
  again. The list of companies says what each one still lacks: a key, a signature of the latest changes, a
  configuration.
- **`status`** shows what the computers of a company reported: the state of each one's Healthchecks check, its last
  update (time, warnings, errors), the errors of the last 24 hours (jobs included) and the wmanager version it runs,
  with `v0.2.0 -> v0.3.0` while it hasn't switched to the version of the source yet. The version comes from the
  run's last Loki entry (see [Logs and monitoring](#logs-and-monitoring)); computers on v0.2.0 and older don't send
  it, so for them it is the version that started the run. It lists the computers of `groups.psd1` and every computer
  that reported, so one silent for 14 days stands out; `?` marks what a service that didn't answer would know.
  Without `HealthchecksSlugPrefix` only the checks of computers known from `groups.psd1` or Loki count, as the
  project may hold other checks. `pwsh tools/wm.ps1 status` sums up every company in a line. It reads with read-only keys, which `pwsh tools/wm.ps1 <company> monitoring` asks
  for and keeps in `<company>/monitoring.psd1` (only on your computer; the computers have write-only ones):
  - Healthchecks: in the project the computers ping, Settings > API Access > Create API key (read-only);
  - Grafana Cloud: Administration > Access policies, a policy with the `logs:read` scope, then Add token (the user is
    the configuration's `LokiUser`).

  Loki is read 14 days back, as long as Grafana Cloud's free plan keeps logs.
- **`new`** goes step by step: a key of its own, the source from `examples/management/` (never a copy of another
  company's source, whose `source-id.txt` must stay its own), the first signature, which creates `source-id.txt`, and
  the wizard, which already offers that identifier. Each step checks whether it is done, so running `new` again
  carries on where it stopped (a mistyped passphrase, a wizard left for later). A company without a management source
  needs only its configuration: `mkdir -p ~/wmanager-companies/globex`, then `pwsh tools/wm.ps1 globex config`. Its
  programs come from `ReqsSources`, where a relative name means the list next to `run.cmd`, the same for every
  company: give such a company a list of its own at an https:// address or on a share, or a management source.
- **`usb <folder>`** puts wmanager there (the latest release, checked against its SHA-256 sums like `install.ps1`
  does, when the folder has none yet) and the configuration of every company in `configs/<company>/`, with its
  certificate. `run.cmd` from there asks which company the computer is for (with a single company, it doesn't ask).
  `install.ps1` asks the same when you give it the folder (e.g. `\\server\share\wmanager`). wmanager v0.2.0 and older
  don't ask yet: with those, run `run.cmd -ConfigPath E:\wmanager\configs\acme\provision.config.psd1`.
- **A company you already have** moves in by its folders: create `~/wmanager-companies/acme` and move (or link) its
  source to `source`, its key folder to `keys` and its configuration folder to `config`.

What the layout keeps apart:

- **A key per company.** One key could sign every source (each manifest carries its own `SourceId`, so company 2's
  computers reject company 1's source), but each computer trusts its key completely (see
  [How a computer checks the source](#how-a-computer-checks-the-source)). With a key per company, a company that
  leaves, or gets another administrator, takes its own key and source and has no way into the others.
- **A config per company:** its `Management` (address, `SourceId`, login, certificate) and its own monitoring. A
  computer gets only the configuration of its company; the others stay on the drive.
- **Monitoring:** Loki entries have no company label, only the computer name (`host`). To keep companies apart in
  Grafana, give each one its own Grafana Cloud stack (its own `LokiUrl`, `LokiUser`, `LokiToken`), or keep computer
  names unique across companies. In Healthchecks.io the ping key belongs to a project, so a project per company keeps
  their checks and alerts apart.

Without `tools/wm.ps1` it works the same by hand: `tools/groups.ps1` and `tools/publish.sh` take the source folder (and
the key folder) as arguments, `tools/new-signing-cert.sh` the key folder, and `init.ps1 -ConfigPath` the configuration
file. If you copy a source instead of starting from `examples/management/`, delete `source-id.txt` and `manifest.psd1`
from the copy before its first `publish.sh`.

## Scheduled update

- `wmanager-Update` (SYSTEM): scheduled by `UpdateDays` and `UpdateTime`, every day at 12:00 by default
  (`UpdateDays = @('Monday')` makes it weekly). After a missed run it starts right after boot, so a computer that was
  off for a few days catches up with one run.
  It installs Chocolatey if it is missing, fetches the list, installs new packages, upgrades packages that are neither pinned nor `!noupdate`,
  reruns debloat and the privacy settings (`RerunDebloat`; the older name `RerunDebloatWeekly` still works) and
  updates its own schedule if the configuration changed.
- Computers set up before the daily default keep `UpdateDays = @('Monday')` in their `provision.config.psd1`; they
  switch when that file gets the new `UpdateDays` (or loses it), at their next update.
- A computer that is usually off at `UpdateTime` runs the missed update about 10 minutes after every boot (Windows waits
  that long with missed tasks), next to the hourly jobs. Pick an `UpdateTime` when the computers are usually on.
- A package whose program is running (`RunningProcessMap`) is deferred; `wmanager-Retry` tries again 2 minutes after sign-in.
  An empty process list (as for `rustdesk`, which always runs as a service) means the package is never deferred.
- When a restart is needed, `wmanager-Notify` shows the user a notification. The computer never restarts on its own.
- With a management source it also fetches and checks the source and runs the group scripts whose content changed
  or that failed before (after debloat). When the source names another wmanager version, it first switches to it
  (see [Updating wmanager](#updating-wmanager)).
- Runs never overlap. When the hourly `wmanager-Jobs` is busy (e.g. both start after a boot), the update waits up
  to 50 minutes for it; if it is still busy, `wmanager-Retry` does the full run at the next sign-in. The hourly
  run skips its turn when another run is busy, and provisioning waits up to 10 minutes.
- Without internet (the Chocolatey, package-list or management servers don't answer) the update changes nothing
  and reports nothing; `wmanager-Retry` does the full run at the next sign-in.

Manual run: `Start-ScheduledTask -TaskPath '\wmanager\' -TaskName 'wmanager-Update'`.

## Logs and monitoring

- Locally: `C:\ProgramData\wmanager\logs\<provision|update|retry>-YYYY-MM-DD_HHMM.log` and `jobs-YYYY-MM-DD.log`,
  deleted after `LogRetentionDays` (90 days).
  The full Chocolatey output is only in the local log (and in `C:\ProgramData\chocolatey\logs`).
- **Grafana Cloud Loki**: at the end of a run the script pushes the entries over HTTP (`/loki/api/v1/push`), with no agent.
  Labels: `service_name="wmanager"`, `host`, `job` (`provision`, `update`, `retry`, `jobs`), `level`, and `task`
  (`<group>/<name>`) for the output of group jobs.
  When Grafana doesn't respond (or rejects the token), the batch waits in `logs\outbox` and is sent on the next run.
  A batch Loki rejects for good (HTTP 400 or 413, e.g. entries too old) is moved to `logs\outbox\rejected` so it doesn't block newer ones.
  Example query: `{service_name="wmanager", level="error"}`.
  The last entry of each provisioning and update is a JSON line, `{"wmanager_run":"v0.3.0","job":"update","warnings":0,"errors":0}`:
  the version that finished the run (after a self-update that failed, the old one) for `tools/wm.ps1 status`. It goes
  to Loki only, not to the screen or the log file.
- **Healthchecks.io**: a `/start` ping at the beginning (in provisioning: once the computer name is settled), and success
  or `/fail` (with the tail of the log) at the end of provisioning and of the scheduled update. Provisioning stopped before
  the name is settled (e.g. a declined question) sends nothing; the console shows the result.
  The check is created on the first ping (`?create=1`); its name is the computer name (with an optional `HealthchecksSlugPrefix`).

The log file and Loki are in English; the console and the user's notifications in the chosen language (see
[Languages](#languages)).

### Grafana Cloud setup

1. Grafana Cloud → Connections → Loki: note the URL (e.g. `https://logs-prod-012.grafana.net`) and the numeric User.
2. Administration → Cloud access policies: create a policy with only the `logs:write` scope and generate a token.
3. Put `LokiUrl`, `LokiUser` and `LokiToken` in `provision.config.psd1`.

### Healthchecks.io setup

1. Create a project and generate a **Ping key** in its settings.
2. Put it in `HealthchecksPingKey`.
3. After the first provisioning every computer has its own check. Keep its **Period at 1 day** (the update runs every
   day) and set **Grace to 3 days**, so a computer that is off over a weekend raises no alert; connect an e-mail
   notification. With a weekly `UpdateDays`, use a period of 7 days.

## Languages

The screen (console lines, questions, notifications) speaks one of: English (`en`, the default), German (`de`),
French (`fr`), Spanish (`es`), Italian (`it`), Polish (`pl`), Dutch (`nl`), Portuguese (`pt`), Romanian (`ro`) and
Czech (`cs`). The first of these that is set wins:

1. `-Lang` of the script: `run.cmd -Lang de`, `init.cmd -Lang fr`, `pwsh ./init.ps1 -Lang it`, or `-Lang pl` for the
   internet installer;
2. the environment variable `WMANAGER_LANG`, set before the run (`set WMANAGER_LANG=de`, `$env:WMANAGER_LANG = 'de'`)
   in a console that already runs as administrator: `run.cmd` started from a normal console asks for administrator
   rights and continues in a new console, which doesn't get the variable (use `run.cmd -Lang de` there);
3. the Windows display language: the system's for the scheduled tasks (they run as SYSTEM), the signed-in user's for
   the restart notification;
4. English.

The log file and Loki are always in English, so every computer reads the same in Grafana and searches and alerts don't
depend on the language. Yes/no questions take the answer in the chosen language and in English (`y`, `yes`).
The internet installer's own few lines are English (`install.ps1` must stay plain ASCII).

The messages are in `lang\<code>\<area>.psd1`; English is the source, and a message missing in another language falls
back to English. `tests\Lang.Tests.ps1` checks that every language has every message with the same placeholders.
To add a language: copy `lang\en` to `lang\<code>`, translate it and add the code to `$WmLanguages` in `lib\Lang.ps1`.

## Tests

On Windows with Pester 5:

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser
Invoke-Pester .\tests
```

The integration tests (`tests\Managed.Integration.Tests.ps1`) change the computer (trusted root store,
`C:\ProgramData\wmanager`, scheduled tasks), so they are skipped unless `WM_CI_SOURCES` is set; they run in CI.

**CI** (`.github/workflows/tests.yml`, every push and pull request, free on a public repository):

1. Linux: `bash -n` and shellcheck of the shell scripts; `tests/ci/build-sources.sh` builds test management sources
   from `examples/management` and `tests/fixtures/management` and signs them with `tools/publish.sh` and a throwaway key.
2. Windows Server 2025, Windows PowerShell 5.1: every `.ps1`/`.psd1` parsed (and checked for a BOM), the Pester tests,
   then the integration tests: Windows accepts the osslsigncode signature, rejects an older manifest, a manifest of
   another source, a changed file and a changed manifest; a script runs once per content and a failing one every time;
   jobs run when due, their JSON lines reach the Loki batch with the `task` label; the example system report runs;
   the hourly task is registered; the wizard accepts the manifest signed with the source certificate and names
   another signer.
3. Linux, PowerShell 7: the tests of the configuration wizard (`init.ps1` also runs there), the languages,
   `tools/groups.ps1` and `tools/wm.ps1` (a new company signed with osslsigncode, when the runner's version can sign
   PowerShell files).

CI runs on Windows Server, not Windows 11 Home/Pro, so it doesn't replace the checks below.

Before rolling out to computers: Windows 11 Home and Pro virtual machines (with a snapshot), two consecutive runs
(the second run must not report errors), a manual run of the task, a missed schedule, the restart notification,
then one pilot computer for a week.

With a management source, also check on the virtual machine that `Get-AuthenticodeSignature` reports `Valid` for a
manifest signed by `publish.sh` (the signature is made with osslsigncode on Linux), that a changed file and an older
manifest are rejected, and that a script runs once, not again in the next run, and again after it changes; that
`wmanager-Jobs` repeats every hour and the daily report reaches Loki.

### Test virtual machines

`tests/vm/vm.sh` (Linux, KVM/QEMU) sets up Windows 11 Pro and Home virtual machines from the official Polish ISO
(microsoft.com/software-download/windows11), without a product key: unattended installation with TPM 2.0
(swtpm) and Secure Boot (OVMF), a local administrator `tester` signed in automatically, and an OpenSSH server for
commands from the terminal. The machines live in `~/vm/wmanager`, outside the repository.

```bash
sudo apt install -y qemu-system-x86 qemu-utils ovmf swtpm swtpm-tools xorriso
sudo usermod -aG kvm $USER
tests/vm/vm.sh create pro ~/Downloads/Win11_pl.iso    # 30-60 min; done when: tests/vm/vm.sh ssh pro hostname
tests/vm/vm.sh installed pro                          # boot from the disk only from now on
tests/vm/vm.sh stop pro && tests/vm/vm.sh snapshot pro clean
tests/vm/vm.sh start pro
tests/vm/vm.sh deploy pro                             # working tree + example config -> C:\wmanager
tests/vm/vm.sh run pro Provision.ps1 -ComputerName WM-TEST-PRO
tests/vm/vm.sh stop pro && tests/vm/vm.sh revert pro clean
```

`deploy` copies the repository as it is on disk (uncommitted changes included) and `provision.config.example.psd1`,
or the configuration given as the second parameter (with the `.cer` files next to it).

Run one machine at a time (6 GB RAM each). `vm.sh stop` shuts Windows down fully over SSH: the power button only
hibernates the kernel while Fast Startup is on (the Windows default), so a new computer name or a pending update would
wait for a restart. Over SSH there is no console, so provisioning takes the default answers (as in a scheduled task).

## Releases

Computers installed from the internet get the latest release, not whatever is on `main`. To release, after the
changes are merged:

```bash
git tag v0.2.0 && git push origin v0.2.0
```

The `release` workflow checks that the tag is on `main`, builds the files with `tools/build-release.sh` and publishes
them as a GitHub release: `wmanager-v0.2.0.zip` (the repository without `tests/` and `.github/`, plus a `VERSION`
file), `install.ps1` and `SHA256SUMS`. The sums prove a download is complete and intact, not who built it: whoever can
publish releases in the repository decides what computers install, so guard that access (and the main branch). A tag with a suffix, e.g. `v0.2.0-rc1`, becomes a pre-release, which
"latest" skips; install it with `-Tag v0.2.0-rc1`. `tools/build-release.sh v0.2.0 dist` builds the same files
locally, to look at them first.

The logs show the version (`wmanager v0.2.0 provisioning: ...`, also in Loki); a copy run from a git checkout has no
`VERSION` file and logs just `wmanager`. Computers that are already installed don't follow "latest": with a management
source, name the new release in each source (see [Updating wmanager](#updating-wmanager)).

## Limitations

- In Home and Pro, telemetry goes no lower than "Required" (1); level 0 works only in Enterprise/Education.
- Blocking the system from reinstalling apps works only in Enterprise/Education, so debloat repeats with every scheduled update.
- Windows 11 doesn't let a script set the default browser for existing users; they get the Settings page once.
- Requires Chocolatey 2.x (installed automatically).
