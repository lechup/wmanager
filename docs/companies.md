# Several companies

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
pwsh tools/wm.ps1 globex publish                             # those changes, then check, sign and send them
pwsh tools/wm.ps1 globex target                              # where the computers read it: Git repository or folder
pwsh tools/wm.ps1 globex sync                                # send the signed source there again, and check it
pwsh tools/wm.ps1 globex config                              # the wizard for its provision.config.psd1
pwsh tools/wm.ps1 globex secret SharePassword                # a secret for its scripts, typed without being shown
pwsh tools/wm.ps1 usb /media/you/USB/wmanager                # wmanager and every company's configuration
pwsh tools/wm.ps1 globex rotate-key                          # a new signing key, in two steps
pwsh tools/wm.ps1 backup                                     # every company as an archive, in ~/wmanager-backups
pwsh tools/wm.ps1 restore ~/wmanager-backups/globex-20261120-101500.tar.gz
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
  run's last Loki entry (see [Logs and monitoring](monitoring.md)); computers on v0.2.0 and older don't send
  it, so for them it is the version that started the run. It lists the computers of `groups.psd1` and every computer
  that reported, so one silent for 14 days stands out; `?` marks what a service that didn't answer would know.
  Without `HealthchecksSlugPrefix` only the checks of computers known from `groups.psd1` or Loki count, as the
  project may hold other checks. `pwsh tools/wm.ps1 status` sums up every company in a line. It reads with read-only keys, which `pwsh tools/wm.ps1 <company> monitoring` asks
  for and keeps in `<company>/monitoring.psd1` (only on your computer; the computers have write-only ones):
  - Healthchecks: in the project the computers ping, Settings > API Access > Create API key (read-only);
  - Grafana Cloud: Administration > Access policies, a policy with the `logs:read` scope, then Add token (the user is
    the configuration's `LokiUser`).

  Loki is read 14 days back, as long as Grafana Cloud's free plan keeps logs.
- **Where the computers read the source** is set once per company (`target`, kept in `<company>/publish.psd1`):
  - a Git repository of its own: the helper makes the source one if needed (`git init`, with a `.gitattributes`
    that keeps the bytes as signed; a source inside a bigger work tree, e.g. a whole `~/wmanager-companies`, gets a
    repository of its own, so the configurations and keys next to it are never pushed), creates a private GitHub
    repository with `gh repo create --private` when `gh` is signed in, or adds the remote you give. For GitHub it
    names the address for `Management.Source` (`https://raw.githubusercontent.com/<owner>/<repo>/<branch>`, with a
    fine-grained read-only token in `Management.AuthHeader`);
  - a folder: a share mounted on your computer (it must exist: a share that isn't mounted isn't filled on your
    disk), or `user@host:/path` (rsync over ssh);
  - the wmanager server of `examples/selfhosted` (see [Hosting Grafana and Loki yourself](monitoring.md#hosting-grafana-and-loki-yourself)):
    rsync over ssh into the company's folder there, read by the computers at `https://<logs name>/source/<company>`
    with its login; the helper asks the server for both and offers to put them in the configuration.

  Only a signed source goes out, with no changes since its signature (the computers would reject them). After
  signing, `publish` (and the menu) offers to send it: a commit listing the files and a push (git must keep the line
  endings, as `publish.sh` checks), or the changed files and then `manifest.psd1` under another name, renamed last.
  A folder whose manifest is newer, or belongs to another source, isn't overwritten. Files removed from the source
  stay in a folder; the computers ignore them. Then it fetches `manifest.psd1` from the address the computers read
  (`Management.Source`, with its `AuthHeader`) and says whether they get the new one; GitHub keeps raw files up to 5
  minutes, so it offers to wait. A `\\server\share` address can't be checked from Linux. `publish -Yes` signs, sends
  and waits without asking; it and `sync` end with code 1 when the computers' address doesn't give what was sent.
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
- **`backup [<folder>]`** (or `<company> backup`) puts each company's folder into `<company>-<UTC time>.tar.gz`,
  readable by you only: the source with its Git history, the key (protected by its passphrase), the configuration
  and the read-only keys (tokens in plain text, as on the USB drive). Linked folders go in with what they hold. A
  company that fails doesn't stop the others; the end names it. Keep the archives somewhere safe, away from the USB
  drive; without the key a company's computers need a new certificate. `restore <archive>` brings a company back, on
  another computer too: it accepts only an archive of one company's folder (with no links or paths outside it),
  unpacks it into a hidden folder first and moves it into place only when it is whole, and never overwrites a company
  that is there.
- **`rotate-key`** changes a company's signing key with a time when the computers trust both: it makes the new key
  (`keys-new/`, a passphrase of its own), names its certificate in the source and signs it with the current key (a
  source with other changes not signed yet is refused first). Run again once `<company> status` shows the computers
  have it, it switches (asked with the default no: computers silent for 14 days aren't counted): the previous key goes
  to `keys-old-<date>` (keep it until every computer has switched), the new one to `keys/`, the configuration gets the
  new certificate (put the USB drive together again), and the source is signed with the new key. It can also call the
  change off. Where the change stands is kept in `<company>/key-change.psd1`, so a step that stopped (a mistyped
  passphrase, a push that failed) is carried on by running it again. See
  [How a computer checks the source](groups.md#how-a-computer-checks-the-source).
- **`secret`** keeps the passwords the company's scripts need in its configuration, not in its source: `secret <name>`
  adds or changes one (typed without being shown), `secret` lists the names with the scripts that use them and the ones
  missing, `secret <name> remove` takes one out. The computers get them with the configuration (the USB drive). See
  [Secrets for scripts](groups.md#secrets-for-scripts).
- **A company you already have** moves in by its folders: create `~/wmanager-companies/acme` and move (or link) its
  source to `source`, its key folder to `keys` and its configuration folder to `config`.

What the layout keeps apart:

- **A key per company.** One key could sign every source (each manifest carries its own `SourceId`, so company 2's
  computers reject company 1's source), but each computer trusts its key completely (see
  [How a computer checks the source](groups.md#how-a-computer-checks-the-source)). With a key per company, a company that
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
