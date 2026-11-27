# Architecture of wmanager v1: server and agent

> **Status: a design for review. Nothing in it is built yet.** wmanager today works as the other documents describe.
> This document is the plan for v1, and every stage below is a pull request of its own. The requirements it must
> meet are in [Requirements of v1](requirements.md); those marked "to design" there are not covered here yet.

wmanager today needs no server. A person provisions a computer from a USB drive or with the one-liner. After that the
computer pulls a signed management source (a Git repository, a web server or a share). It runs only what that
source's key has signed.

In v1 a server is required, and four things come with it:

- a sign-in to the panel with a mandatory second factor;
- the agent installer, made by the server for each company;
- updates of the agent and of wmanager itself, without visiting the computers;
- single jobs on one computer or a group, with the output in the panel.

One property must survive the move: **the server alone cannot make a computer run anything.** Every script, package
list, setting, secret value, wmanager version and single job that a computer acts on is signed by an administrator
of that company. The signer is a program on the administrator's own computer, not the panel. A hacked server can
read and withhold, but it can't make an enrolled computer run code. A new computer is safe only when its installer
is checked (see [What a hacked server can and can't do](#what-a-hacked-server-can-and-cant-do)).

## What stays the same

- **What runs on the computer:** the provisioning steps (debloat, privacy, accounts, Chocolatey, backup and
  `Restore-Backup.ps1`), groups, packages, scripts, jobs, the startup, fixed-time, event and sign-in triggers, run-as
  user, secrets masked in the output, and the library. This is the PowerShell code of today, run by the agent in
  Windows PowerShell 5.1.
- **The scheduled tasks** (`wmanager-Update`, `-Jobs`, `-Logon`, `-Startup`, `-Event-*`, `-Notify`) stay in v1. The
  agent replaces how a computer *gets* its content, and adds what needs a live connection.
- **A person at the computer for provisioning.** The installer runs in a console and asks for the computer name and the
  passwords typed at the computer, as `run.cmd` does today.
- **The ten languages**, on the computer, in the panel and in `wmanager-sign`.
- **Loki and Grafana**, and the self-hosting kit in `examples/selfhosted/`.

## Parts

```
 administrator                            wmanager-server (Linux, Docker, behind Caddy)
 ┌──────────────────────────┐   HTTPS     ┌───────────────────────────────────────────┐   ┌────────────┐
 │ browser: the panel       │ ──────────▶ │ panel and API (Go, HTML from templates)   │──▶│ PostgreSQL │
 │  (password + 2nd factor) │             │ companies, computers, groups, files,      │   └────────────┘
 │ wmanager-sign            │ ──────────▶ │ statements and signatures, jobs, output,  │──▶ Loki (logs)
 │  (shows and signs with a │  signatures │ audit log, installers                     │
 │  security key or Windows │             └───────────────────────────────────────────┘
 │  Hello)                  │                                  ▲ HTTPS, always opened by the computer
 └──────────────────────────┘                                  │ (long poll; no open port on the computer)
                                                   wmanager-agent (Windows service, SYSTEM)
                                                     checks every signature, keeps the verified copy,
                                                     runs the PowerShell code, sends output and logs
```

| Part | What it is |
| --- | --- |
| `wmanager-server` | One Go program in a Docker image, with PostgreSQL. It serves the panel (HTML rendered on the server, with a small JavaScript file for passkeys and no build step) and the API for agents and for `wmanager-sign`. |
| `wmanager-agent` | One Go program for Windows. Started by hand it is the installer; after that it runs as the `wmanager` service as SYSTEM. It lives in `C:\Program Files\wmanager`, and its data stays in `C:\ProgramData\wmanager` with today's protection (SYSTEM and Administrators only). |
| the payload | Today's PowerShell code (`Provision.ps1`, `lib\`, `lang\`, `Invoke-*.ps1`), released as the ZIP it is today. |
| `wmanager-sign` | One Go program for the administrator's computer, on Linux and Windows first. It shows what is to be signed and signs it with the administrator's security key. |

All four come from the same release and the same repository (`server/`, `agent/`, `sign/`, with the PowerShell code
where it is now).

## Several companies on one server

One server holds many companies, and each is kept apart:

- **What is the company's own:** its administrators and admin list (so its fingerprint), computers, groups, files,
  settings, secrets, single jobs, installers and audit log. Every row in the database belongs to one company, and
  every query of the panel and the API is limited to the companies of the signed-in account.
- **The computers stay apart too.** A computer enrolled for a company accepts only statements signed by that
  company's admin list. A statement names its company by the company's id (from its first admin list), so one signed for another company
  is refused, even when the same person, with the same key, administers both.
- **Logs:** each company's lines go to its own Loki tenant, as in today's self-hosting kit.
- **People:** one account may belong to several companies, with a role in each. The panel shows the companies it
  belongs to and switches between them. In `wmanager-sign`, one key may be on the admin lists of several companies.
- **The server's owner** makes companies and accounts. Like anyone's, the owner's changes reach a company's
  computers only when a key on that company's admin list signs them.

## Who can make a computer run something

### Keys

| Key | Where it is | What it signs | Who checks it |
| --- | --- | --- | --- |
| A company administrator's signing key | a FIDO2 security key (e.g. YubiKey) or Windows Hello, tied to that device (no passkey synced between devices), used only by `wmanager-sign` | the company's admin lists, its states and its single jobs | the agent, before acting |
| The release key | with the maintainer, off the server | each release's `SHA256SUMS` (every file, including the Linux `wmanager-sign`), and the Windows exe files (Authenticode) | Windows, the agent (the payload and its own updates), `wmanager-sign` (its own updates, and a version before it signs it) |
| A computer's key | made on the computer at enrollment, in the TPM when there is one; the computer's id is the SHA-256 of its public key | the computer's sign-in to the server | the server |
| The server's TLS certificate | Caddy (Let's Encrypt) | the connection | the agent and the browser |

The companies' own signing keys of today (`~/wmanager-companies/<company>/keys`, `osslsigncode`, `publish.sh`,
`rotate-key`, `next-certificate.cer`) are not needed any more.

The release certificate that the agent accepts is named in the company's signed state. So if the release key has to
change (lost or leaked), the administrators move their computers to the new one with a signed state. The installer
brings the current certificate with it.

### The admin list of a company

Every company has an **admin list**: its administrators and the public keys of their signing keys, with a sequence
number.

- **The first version is made by the first administrator in `wmanager-sign`.** It holds that administrator's key and
  is signed by it. Its SHA-256 is the company's id. The first 128 bits of it are the company's **fingerprint**, shown
  as 32 characters, e.g. `7F3A-91C2-04BD-E85F-2C6B-90AE-5D17-3B48`. Write it down when the company is made. The panel shows it too, but a
  hacked server could lie in the panel as well.
- **Each later version must have the next sequence number, name the hash of the version before, and be signed by a
  key from it.** That covers adding an administrator, adding a second key, and removing a lost or leaked one.
- **A computer always checks the whole chain**, from the first version, against the fingerprint, so a fingerprint is
  never just claimed. The installer brings the whole chain (see [Enrolling a computer](#enrolling-a-computer)).
- **Every administrator should have two signing keys** (two security keys, or one and Windows Hello), or the company
  should have two administrators. If every key is lost, no computer accepts anything new any more. The way back is the
  same as for a leaked key today: a person runs a new installer at each computer.
- **A leaked key:** sign an admin list without it at once. If the server may be hacked too, the computers may never
  get that list (the server can withhold it), so enroll them again.

### Signed statements

Everything a computer acts on reaches it as a **statement**: the exact bytes of a JSON document, plus a signature over
its SHA-256. The agent hashes the bytes it gets, so nothing needs to be put into a canonical form.

Every statement has a format version, its type and the time it was signed, all set by `wmanager-sign`. Every
statement but the first admin list also names the company's id. The first admin list can't hold its own hash, so it
holds a random 128-bit value instead, which makes each company's id unique.

| Statement | Contents (in short) |
| --- | --- |
| `admins` | sequence number, hash of the previous version, administrators with their keys' public keys and algorithms |
| `state` | serial number, the server's address, the release certificate, the computers (id, name, groups), every file with its SHA-256 (package lists, the groups' scripts, jobs and triggers, the settings), the wmanager version with the hashes of its files, a salted SHA-256 of each secret's value: today's `manifest.psd1` and `groups.psd1`, as JSON |
| `job` | a random 128-bit id, the ids of the computers it targets, the script's SHA-256, run as SYSTEM or the user, the secrets it may use, a time to start after, an expiry (at most 7 days after signing), a time limit |
| `stop` | the id of a job, and the computers to stop it on: it stops the job when it runs, and refuses it when it arrives later |

`wmanager-sign` makes the serial numbers and job ids, not the server. A new state's serial is one more than the
highest it knows of: the highest it has signed itself, the newest state it has verified, and the highest the
computers report. So a server restored from an older backup, or a state another administrator signed, doesn't make
the computers refuse the next one. (The computers' reports come through the server: a lie there can only make a
serial higher.)

`wmanager-sign` signs only when its clock is within 10 minutes of the server's. A hacked server can use that only to
stop signing, and a wrong clock on the administrator's computer can't stamp a statement far in the future.

**Signatures** are FIDO2 assertions (the format behind passkeys, ES256, EdDSA or RS256). The key signs its
*authenticator data* followed by the SHA-256 of a client data JSON. `wmanager-sign` builds that JSON itself, with
the statement's hash as the challenge. With a security key on Linux only that hash reaches the key.

The agent accepts a statement only when all of this holds:

1. its format version and type are known, and it has exactly the fields of that type (an unknown field is refused);
2. its company is the computer's company (the id), so a statement signed for another company of the same
   administrator is refused;
3. the client data has the type `webauthn.get`, exactly the origin `wmanager-sign:v1`, no `crossOrigin: true`, and
   the hash of the statement as its challenge;
4. the authenticator data has the hash of the relying party id `wmanager-sign.invalid`, with *user present* and
   *user verified* set (a touch, and a PIN or biometrics), and *backup eligible* not set (a synced passkey is
   refused);
5. the signature is valid, with the algorithm the admin list names for that key, for a key in the company's current
   admin list;
6. it fits what the computer already has: an admin list has the next sequence number and the previous hash; a state
   has a higher serial than the last one; for a job, see [Single jobs](#single-jobs).

Signing keys are separate from the keys used to sign in to the panel. A browser always puts the page's own
`https://` address in the origin, so no web page, including one served by a hacked server, can make a signature with
the origin `wmanager-sign:v1`. That holds even when the administrator touches the key thinking it is a sign-in. The
relying party id `wmanager-sign.invalid` is a second barrier: no website can claim it.

`wmanager-sign` registers a signing key only when it is tied to its device (*backup eligible* not set), over USB, NFC
or built into the computer. Windows' dialog may offer a phone or another passkey manager. Those keys are synced, and
they are refused.

The *backup eligible* flag is what the key itself reports. A passkey manager or a software authenticator that lies
about it would pass, unless registration also checks the key's attestation against a list of allowed models (see
[Open questions](#open-questions)). A new key needs a signature from an administrator who sees it in `wmanager-sign`,
so the server can't add such a key. An administrator who registers one weakens only their own companies.

### wmanager-sign

The panel is for viewing and preparing. Changes are made there and wait as unsigned statements. `wmanager-sign`
signs them:

```
$ wmanager-sign
acme (7F3A-91C2-04BD-E85F-2C6B-90AE-5D17-3B48)  2 waiting
 1) state 42: groups/office/choco-reqs.txt  +1 line, groups/office/jobs/daily/backup.ps1  new (38 lines)
 2) job: OFFICE-03, OFFICE-07  "restart-spooler.ps1" (12 lines) as SYSTEM, expires 27.11. 18:00
Show and sign (1-2), quit (q)?
```

- **It is a program from the signed release**, downloaded from GitHub (not from the server).
  - The release key's fingerprint is published outside the releases too (in the README and `docs/releases.md` in the
    repository), so the first download can be checked by hand with a command given there.
  - After that it checks its own updates against the release's signed `SHA256SUMS`.
  - A new release key reaches it the way a new certificate reaches the computers today: a release signed with the
    old key names the next one. The details come in stage 6.
- **It shows everything before it signs:** there is no signing without showing. A state is shown as the differences
  from the last state it has verified itself. A job is shown with the script in full, the computers, the user it runs
  as, the secrets and the expiry. Names of computers and the members of groups come from the last verified state, not
  from the server's list.
- **What it shows is what is signed.** Every control character, bidirectional override and non-ASCII character in
  everything it shows is shown visibly (e.g. `<U+202E>`): scripts, computer and group names, settings, package lines,
  secret names and the names of added files. So text can't be hidden or reordered on the screen. File paths are
  limited to letters, digits, `-`, `_`, `.` and `/`.
- **Files that aren't text** (installers, drivers) are added with `wmanager-sign add-file` from the administrator's
  own disk. It hashes the file it read and sends it to the server. Such a file uploaded in the panel can't be signed.
- **Secrets are typed in `wmanager-sign`**, not in the panel. It makes a random 128-bit salt for the value and puts
  the SHA-256 of the company's id, the secret's name, the salt and the value into the next state. It sends the value
  and the salt to the server (see [The company's state](#the-companys-state)).
- **New computers are added by their id.** The installer shows the computer's id at the end (its first 8
  characters), and `wmanager-sign` asks for them when the computer is added to the state. So the server can't swap
  two waiting computers.
- **The company chain:** it keeps each company's fingerprint after the first use, and refuses an admin list that
  doesn't follow the chain. It makes the first admin list of a new company, adds and removes administrators and keys,
  and prints the fingerprint. It also checks an installer file (`wmanager-sign check-installer <file>`): the release
  signature and the chain in its tag.
- **Keys:** on Linux, a FIDO2 security key over USB or NFC (libfido2). On Windows, Windows Hello or a security key,
  through Windows' own WebAuthn API, which takes any relying party id and the client data from a desktop program. To
  check on a VM in stage 2: that this works with Windows Hello. macOS comes later.
- **`wmanager-sign` offers no signing from a phone.** This is the price of the property above.

### What a hacked server can and can't do

Someone in control of the server (or of Caddy, or of the database) **can**:

- read everything the server holds: computers, groups, scripts, output, logs and **the secrets' values**;
- stop sending admin lists, states, jobs or updates, or delay them. That includes an admin list that removes a leaked
  key;
- show a false picture in the panel (wrong names, statuses or output);
- stop a single job before it starts;
- start an [action approved in advance](#actions-approved-in-advance) at a bad time (e.g. restart every computer),
  within its limits;
- enroll a computer of its own with a valid token (it gets what a new computer gets);
- fool a **new** computer, unless its enrollment is checked as [Enrolling a computer](#enrolling-a-computer)
  describes. It can serve an installer of its own or a false chain, or hand it an older signed state (as today).

It **can't**, on an enrolled computer:

- run a script, or change a group's content, a package list, a setting, a secret's value or the wmanager version;
- make an administrator sign something other than what `wmanager-sign` shows;
- add an administrator or a key to a company;
- run a single job twice, after its expiry, or on a computer it doesn't target;
- stop a job that is running, or make a computer go back to an older agent or state;
- move the computers to another server (the address is part of the signed state).

What remains:

- **A compromised computer of an administrator.** Malware there can change what `wmanager-sign` signs. It can also
  ask the key for a signature itself, through Windows' WebAuthn API or libfido2 (where the PIN passes through the
  computer). It still needs a touch. Keep that computer clean.
- **A leaked key together with a hacked server** is a takeover, because the server can withhold the list that removes
  the key.
- **A computer restored from a snapshot** forgets the jobs it ran after the snapshot. It may run one again that hasn't
  expired.

## Enrolling a computer

1. **The installer is made in the panel.** An administrator picks the company, how long it is valid (7 days by
   default) and how many computers may use it. The server takes the release's `wmanager-agent.exe` and adds a **tag**:
   the server's address, the enrollment token and the company's whole admin chain.
   - The tag is a certificate of its own, added to the signature's set of certificates, which the signature doesn't
     cover. This is the "superfluous certificate" way of Omaha's `certificate_tag`, which Google uses for Chrome's
     installers. The older way of appending the data after the signature fails when Windows' stricter check of the
     signature padding is on (`EnableCertPaddingCheck`).
   - Anyone can tag a file, so the agent reads the tag strictly. It trusts nothing in it that it can't check (the
     chain against the fingerprint typed in).
   - Each tagged file has its own hash, so SmartScreen judges it only by the certificate. To check in stage 3: how
     Windows and SmartScreen treat it.
2. **Check that the installer is genuine.** A hacked server could serve an installer of its own, and a false program
   shows whatever fingerprint it likes. So the exe must come with one of these:
   - Windows shows the name on a publicly trusted release certificate (see [Open questions](#open-questions)). It is
     the maintainer's or their company's legal name, given in `docs/releases.md`. Compare it carefully: a company
     with a similar name could get a certificate of its own.
   - It was checked with `wmanager-sign check-installer` on the administrator's computer before it went on the USB
     drive.
   - It is the untagged exe, downloaded from GitHub.

   With a self-signed release certificate, only the last two help.
3. **A person at the computer runs it** (it asks for administrator rights). In the computer's language it shows the
   company and the server. Then it asks the person to type the fingerprint written down when the company was made,
   and checks the chain against it. Then it asks for the computer name.
4. **It enrolls the computer.** The computer makes its own key (in the TPM when there is one), and its id is the
   SHA-256 of the public key. It sends the public key with the token. From then on it signs in with that key, and
   the token is no longer needed. The installer holds a token, so treat it like the USB drive with configurations
   today. The computer is in no group of its own until an administrator adds it, by its id and name, in a signed state.
   The installer shows the first 8 characters of the id at the end, for that.
5. **It provisions the computer.** It fetches the signed state, checks it, installs the service and the payload, and
   runs provisioning in the same console (with the passwords typed at the computer). Then it registers the tasks as
   today.

The untagged release exe asks for the server address and a code made in the panel, and also for the fingerprint.

## The company's state

- **In the panel:** groups and their computers, package lists, scripts, jobs and triggers (by hand or from the
  library), the settings that live in `provision.config.psd1` today (update time, removed apps, Chocolatey sources,
  administrator account and more), and the wmanager version. Secrets and files that aren't text go in through
  `wmanager-sign`.
- **A change waits as a new state** until it is signed in `wmanager-sign`, then the server offers it to the
  computers.
- **The agent checks the state** (see [Signed statements](#signed-statements)), and that every file matches its hash.
  Then it writes the verified copy, with the statement and its signature, to `state\managed`, where the scheduled
  tasks already read it. Today every task checks the source's signature again each time it reads that copy. In v1 the
  payload asks the agent to do it (`wmanager-agent verify`), with the same code the agent uses.
- **Secrets:**
  - The agent fetches the values of the secrets that its computer's scripts declare (`# wmanager-secrets:`), each
    with its salt. It checks each against the hash in the signed state, and refuses one that doesn't match. A hacked
    server can read the values, but it can't change them.
  - The salt is not in the state, so the hashes that every computer of the company gets don't help to guess a weak
    password.
  - The computer keeps the values it needs in a file that SYSTEM owns, protected with DPAPI, so startup and event
    scripts, and laptops without a network, have them too. That stops plain reading of the file, not a local
    administrator, who can become SYSTEM. It is the same as today, where `provision.config.psd1` holds them.
  - A script gets only those it declares, as today, masked in its output.
- **When the server can't be reached** the computer goes on with its last verified copy, as today.

## Single jobs

- **In the panel:** the computers or groups, a script (from the library or typed), run as SYSTEM or as the signed-in
  user, the secrets, an expiry (24 hours by default, at most 7 days) and a time limit. Then signing in
  `wmanager-sign`. A group is turned into its computers' ids when the job is signed: `wmanager-sign` takes them from
  the last state it verified and shows them. A computer added to the group later doesn't run the job.
- **The agent runs a job only when** all the checks of [Signed statements](#signed-statements) pass, and also:
  - it names the computer's id;
  - the time is between its start and its expiry. The agent counts the time as at least the time of the newest
    statement it has verified, so a clock that went back can't revive an expired job. It raises that floor only from
    statements at most 24 hours ahead of its own clock;
  - the computer hasn't run this id before, and no `stop` for it has arrived. The agent writes the id down before it
    starts the job. It forgets an id only when that floor is 60 days past the job's expiry, so a clock thrown forward
    and then set back doesn't make it forget too early.
- **It runs the job with today's runner** (secrets masked, time limit, the user's session for run-as user).
- **The output** reaches the panel as it is written, with the exit code and the time taken, and goes to Loki like a
  group job's.
- **A computer that is off** gets the job when it comes back, unless it has expired. The panel shows *waiting*,
  *running*, *done*, *failed* or *expired* for each computer.
- **Stopping a job:**
  - Before it starts, the server can simply not hand it out, so this needs no signature.
  - Stopping a job that is running needs a signed `stop`, because killing a firmware update or a disk change midway
    does harm.
  - A signed `stop` that arrives before its job is kept, and the job is refused when it comes.

### Actions approved in advance

Some actions are needed often and do no harm beyond their timing: restart, a Defender scan, an inventory refresh, the
update now, a diagnostics bundle, Wake-on-LAN, and isolating a computer (the firewall lets through only the wmanager
server) and lifting that. They are started from the panel with one click, without a key:

- **The state lists them.** Each action has its script (from the library), the groups that may run it, run as SYSTEM
  or the user, and the limits of its parameters. A parameter is only a number within bounds or a choice from a fixed
  list (e.g. a restart delay of 0-240 minutes), never free text. Each action also has a limit of runs per hour.
- **The administrator signs that list once**, with the state, in `wmanager-sign`.
- **The panel asks the agent to run an action.** The agent runs it only when it is in its verified state, the
  computer is in one of its groups, the parameters fit their limits and the limit of runs isn't used up.
- **Anything else is signed each time:** any other script, installing or removing a program, and a message to users
  (free text from a hacked server would be a ready phishing message).
- **Wake-on-LAN:** the panel asks an agent in the same network to wake a computer. The target is a computer from the
  signed state, and the agent takes its MAC address from there.

## Updates

- **One release tag** builds the payload ZIP, `wmanager-agent.exe`, `wmanager-sign` (Windows and Linux), the server
  image (`ghcr.io/lechup/wmanager-server`) and `SHA256SUMS`.
  - The release key signs `SHA256SUMS`, which covers every file, including the payload and the Linux `wmanager-sign`
    that Authenticode can't sign. The format of that signature is chosen in stage 6.
  - The release key also signs the Windows exe files with Authenticode.
  - The build stays reproducible, as it is today.
- **The company's state names the version** with the SHA-256 of its files, the same as `version.psd1` today. A group
  may have its own version (a pilot group first), and going back is naming the older version. `wmanager-sign` checks
  the hashes against the release's signed `SHA256SUMS` before signing.
- **The server keeps a copy of the releases its companies use**, so computers don't need to reach GitHub.
- **The agent:**
  - It checks the files against the hashes in the state, the signed `SHA256SUMS` and the release certificate named in
    the state.
  - It installs the payload the way the self-update does today, then replaces itself and restarts the service.
  - The new agent must pass a check on the computer itself within 10 minutes: start, verify the current state, and
    run the payload's self-test. Reaching the server is not part of it, so a server can't cause a rollback.
  - If the check fails, the old agent comes back and the version is marked failed. It is not tried again until the
    state names another version.
- **The server** is updated with a new image. It updates its database when it starts, and accepts agents of its own
  and the previous minor version.

## Moving or rebuilding the server

- **Moving to another server:**
  - Restore a backup of the database there, then sign a state with the new address. The computers switch to it.
  - The old server must keep working until all of them have switched.
  - The computers sign in to the new server with the keys it has from the backup.
- **The old server is lost** (no backup, or the domain is gone): the computers can't learn a new address. Enroll them
  again, with a person at each computer.
- **After a hack:**
  - Set up a clean server from a backup. The signed data can't have been changed, but check the accounts.
  - Then change every secret, because the attacker could read them. Change the TLS keys and the accounts' passwords
    too.
  - Then move as above.
- **A database restored from an older backup** doesn't stop the computers. The serial numbers and job ids come from
  `wmanager-sign`, so the next state is still higher (see [Signed statements](#signed-statements)), and no job id
  repeats.

## Logs and monitoring

- **Logs stay on our side.** The payload writes the same lines as today, and the agent sends them to the server.
  Computers hold no Loki token.
  - The panel shows job output, the runs and the audit log from PostgreSQL.
  - The server passes the full logs to the company's tenant in Loki next to the server (the self-hosting kit), with
    today's Grafana dashboard and alerts. The run records that the dashboard reads stay.
  - Grafana Cloud remains an option, not the default.
- **Healthchecks.io goes.** Each connection of an agent is its sign of life, and the server stores the time it was
  last seen. Grafana reads it from PostgreSQL (a read-only user), for a panel of computers that are off and an alert,
  next to the Loki dashboard of today.

## The server inside

- **Sign-in:** a password (argon2id) and a mandatory second factor: a passkey or a TOTP code, with recovery codes.
  It applies to every account, with rate limits and a lockout.
- **Roles:** the *owner* of the server makes companies and accounts. A company *admin* edits it and prepares
  statements (signing still needs a key in the company's admin list). A *viewer* only reads.
- **Audit log:** who did what and when, including sign-ins and signatures, in the panel and in Loki.
- **The panel is minimal:** few screens (companies, computers, groups and their files, jobs, installers, accounts,
  audit log), HTML from Go templates, no frontend framework and no build step. JavaScript only for passkeys, in one
  small static file. A strict Content Security Policy (no inline scripts), CSRF tokens, and sessions kept in the
  database.
- **Data:** PostgreSQL, with the files kept by their SHA-256. `selfhosted.sh` gets backup and restore of the
  database.

## The agent inside

- **Connection:** HTTPS long polling. The agent asks "anything for me?" and the server answers at once or after up to
  60 seconds. A job starts within seconds, and it works through proxies (the agent reads Windows' proxy settings).
- **Its own data** is in `C:\ProgramData\wmanager\state\agent`: the computer's identity, the admin chain, the last
  serial, the time of the newest statement it verified, the ids of the jobs it ran (60 days), the versions that failed,
  and the secrets of its scripts (SYSTEM only, DPAPI).
- **Tests:** the signature checks and the protocol run on Linux (`go test`, a test server); the service, the TPM key
  and the payload on the Windows runner, as today.

## From today to v1

| Today | In v1 |
| --- | --- |
| `run.cmd`, `install.ps1`, `configs\<company>\` on the USB drive | the installer exe per company (still a person at the computer) |
| `provision.config.psd1` on the drive and on the computer | settings in the signed state; the computer keeps its key and its scripts' secrets (SYSTEM only) |
| `Secrets` in `provision.config.psd1` | typed in `wmanager-sign`, the salted hash in the signed state, the value on the server and on the computers that need it |
| `groups.psd1` (computer name to groups) | the computers in the signed state, by id (the hash of the computer's key) and name |
| `init.ps1` (wizard) | the panel |
| the management source: `manifest.psd1` with Authenticode, `publish.sh`, a Git repository, a web server or a share | the company's state on the server, signed in `wmanager-sign` |
| the companies' signing keys, `rotate-key`, `next-certificate.cer` | the admin list and its chain |
| `tools/groups.ps1`, `tools/wm.ps1` | the panel and `wmanager-sign`; the library stays |
| `version.psd1` and the self-update | the version in the signed state; the agent updates itself and the payload |
| Healthchecks.io | the server's last seen time, in Grafana from PostgreSQL |
| Loki straight from the computers, with a token | Loki through the server |
| the scheduled tasks and everything they run | the same |

There are no computers in production on today's version, so v1 doesn't migrate them. Without a server, wmanager does
nothing in v1.

## Stages

Each is a pull request of its own, with a review and tests before the merge.

1. **The server's frame:** the Go module, PostgreSQL with migrations, accounts with the mandatory second factor,
   companies, roles, the audit log, the panel's frame in ten languages, the Docker image in `examples/selfhosted/`,
   and CI on Linux with PostgreSQL.
2. **Signatures:**
   - the statement formats and their strict schemas;
   - one verification package shared by the server, the agent and the signer;
   - `wmanager-sign`, with a security key on Linux first, then Windows Hello: showing, `add-file`, secrets, the
     first admin list and its changes;
   - tests with a software authenticator, also for refusals (a synced key, another company, a wrong origin, an old
     serial), and by hand with a real key.
3. **Agent and installer:** the service, the computer's key and id, enrollment, the tagged installer from the panel
   with the whole chain, `check-installer`, the fingerprint typed at the computer, the sign of life, and the list of
   computers.
4. **The company's state:** editing in the panel, signing, and the agent's check, which hands the copy to the
   payload (and `wmanager-agent verify` for it). Settings from the state, secrets checked against their hashes and
   kept for SYSTEM, logs through the server.
5. **Single jobs:** targets, the time and id checks, the output, and the signed `stop`.
6. **Updates:** the release with the signed `SHA256SUMS`, the signed exe files and the server image, and the
   self-update of the agent and the payload, with the check on the computer and going back.
7. **Without the serverless mode:** removing `run.cmd`, `install.ps1`, the wizard, the source and its tools, and
   Healthchecks. The documentation and the languages.
8. **A full test on a VM:** the server in Docker on the host. A clean Windows 11 goes through the installer,
   provisioning, a change of state, a single job, an update and going back.

## Open questions

Each will be asked before the stage it belongs to. The first option is the proposal.

| Question | Options |
| --- | --- |
| The release certificate (stage 3) | publicly trusted (a paid certificate or signing service): Windows shows the name on the certificate, so a false installer stands out / self-signed: free, but Windows warns about an unknown publisher at every install, so a new computer is safe only with an exe checked in `wmanager-sign check-installer` or taken from GitHub |
| Where releases are signed (stage 6) | by the maintainer, after checking that the CI build is reproducible / in CI, with the key or a signing service reached from GitHub |
| Automatic updates (stage 6) | an administrator signs each version (a reminder when one comes out) / a signed rule "follow the releases, N days after the pilot group", which lets the release key reach the computers alone |
| New computers (stage 3) | a new computer gets the content of the default groups (`Default`) until a signed state lists it / it gets nothing until then |
| Logs (stage 4) | through the server / straight to Loki as today |
| Signing keys (stage 2) | trust what the key reports (*backup eligible*) / also check its attestation against a list of allowed models, which keeps out passkey managers that lie about it but needs that list kept up to date |
| Remote support: who allows a session (requirement 42) | the technician's key signs the session in the viewer, a program from the release like `wmanager-sign`, and the computer checks it against the signed state: a hacked server can't open a session / the server allows it after the panel's sign-in with its second factor: simpler, but a hacked server gets the screen of every computer, against requirement 6 / the server allows it and the person at the computer accepts each session: safe, but no help when nobody is there |
| Remote support: where the viewer runs (requirement 42) | a program from the release, started from the panel by a link / in the browser: RustDesk's own web client is not open source (self-hosting it is a paid feature), so it would be ours to write, and its code would come from the server, so it can't hold the key that allows a session |

## License

Every part (the server, the agent, `wmanager-sign`, the payload) stays under GPL v3, like wmanager today. Each
dependency must have an open-source license that fits GPL v3 (MIT, BSD, Apache 2.0, MPL 2.0, LGPL). Running
wmanager needs no closed component. The libraries named in this design fit: libfido2 (BSD), and Omaha's
`certificate_tag` (Apache 2.0). CI will list the licenses of the Go modules and fail on one that doesn't fit.

## Not in v1

- a remote terminal. Remote desktop is requirement 42, still to design;
- computers with macOS, and `wmanager-sign` on macOS;
- computers with Linux: they come after Windows (requirement 23);
- more than one server instance;
- secrets the server can't read;
- signing from a phone;
- checking the attestation of signing keys, unless the open question above decides otherwise;
- more than one signature per statement. It would have to cover every statement: a script signed once, run as
  SYSTEM, can change anything on the computer, the admin list too;
- noticing on the computer that a server withholds newer statements.

## Projects we looked at

Checked in November 2026. All of them can run anything on every computer once someone controls the server.

| Project | Close to v1 in | Why not |
| --- | --- | --- |
| [Tactical RMM](https://github.com/amidaware/tacticalrmm) | all four needs: TOTP, installers per client, agent self-update, scripts on one or many | not an open-source license (Tactical RMM License 1.0); a code-signed agent from $55 a month; its documentation advises antivirus exclusions |
| [MeshCentral](https://github.com/Ylianst/MeshCentral) | second factor, installers per device group, agent self-update, commands on one or many; Apache 2.0 | remote access first: no scheduled jobs, no groups with packages, no software installs |
| [NetLock RMM](https://github.com/0x101-Cyber-Security/NetLock-RMM) | second factor, installers, agent self-update, jobs, software from Chocolatey or Winget | open core: public commits paused, free for up to 25 devices |
| [Fleet](https://github.com/fleetdm/fleet) | scripts on one computer | built around osquery; software installs and automatic fixes in the paid tier |
