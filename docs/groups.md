# Computer groups

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

## How a computer checks the source

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

**A new key** (`pwsh tools/wm.ps1 <company> rotate-key`) reaches the computers through the source itself, in two
steps. First the source names the next certificate in `next-certificate.cer`, still signed with the current key: a
computer that reads it keeps it in `state\signing-next.cer`, adds it to the root store and accepts either signature
from then on. When the source comes signed with the new key, that certificate replaces the computer's own (the file
next to the installed configuration) and the old one leaves the root store; a source that stops naming it (a change
called off) makes the computers forget it. Each run reports the certificates a computer trusts in its run record, so
`tools/wm.ps1 <company> status` says how many are ready to switch. Provisioning with a configuration (`run.cmd`) makes
a computer forget a next certificate it learned, as does `Restore-Backup.ps1`. A computer that missed the first step rejects the new
signature and keeps its last copy until it gets the new certificate with its configuration (`run.cmd`), as does a
computer provisioned again from a USB drive with the old certificate: put the drive together again after the switch.
A key that leaked is not changed this way (whoever has it could name a certificate too): give the computers a new
configuration with `run.cmd`.

Windows accepts a self-signed signature only from a certificate in the computer's trusted root store, so provisioning
adds the wmanager certificate to **LocalMachine\Root** (with the friendly name `wmanager-signing`). The certificate is
limited to code signing and is not a CA, so it can't vouch for websites or other certificates; but anything signed with
its key is trusted on the computer, so guard the key. A new certificate in the config replaces the old one at the next run.

## Where to keep the source

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

## Setting up (once)

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

## Making a change

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
- The certificate is valid for 20 years (one made before 2026-11: 10 years). `publish.sh` adds an RFC 3161 timestamp
  to the signature (from DigiCert, or Sectigo when DigiCert doesn't answer; the server gets only a hash of the
  signature), and a timestamped signature stays valid after the certificate expires. When no server answers (no
  internet) it signs without one and warns: such a signature stops being valid when the certificate expires (then
  computers reject the source, also their saved copy), and the next signature made with the internet has one again.
  `WM_TSA="<url> [<url>...]"` uses other servers, `WM_TSA=none` signs without one. New versions still need a valid
  certificate: replace it before it expires (`publish.sh` and the computers warn 60 days ahead).
- The `wmanager-Jobs` task is registered at provisioning when `Management.Source` is set; if you add a management
  source to an existing computer, run provisioning again.
- Script and job output goes through the console code page (e.g. 852 on Polish Windows): characters outside it come
  out as `?`.

## Library of ready scripts and jobs

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

## Updating wmanager

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
