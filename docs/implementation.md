# Implementation plan of v1

> How v1 is built: the releases, the stages of v1.0 with their pull requests, the tools and the tests. The design is
> [Architecture of v1](architecture.md), and the requirements are [Requirements of v1](requirements.md).

## Releases

The list of requirements for v1 is closed (2026-11-27): a new idea goes to a later release. Each release after v1.0 is
designed when its turn comes, so its details are decided with what the releases before it taught.

| Release | Requirements | What it brings |
| --- | --- | --- |
| v1.0 | 1-11, 12, 18, 19, 24, 25, 28 | the core: the server, the agent, the signatures, the company's state, single jobs, the actions approved in advance, updates, the rights of people; today's features on the new base |
| v1.1 | 13, 15, 32, 34, 37, 39, 40, 41 | everyday administration: alerts, Windows Update, staged rollouts, maintenance windows, hardware health, Wi-Fi and VPN profiles, the ready list of packages |
| v1.2 | 14, 27, 29, 30 | security: the compliance report, BitLocker with key escrow, security events, a lost laptop |
| v1.3 | 20, 21, 22, 26, 31, 35, 36 | larger companies: SSO, the SIEM export, the API and webhooks, retention, joining and leaving, hardware records, reports for billing |
| v1.4 | 16, 17, 33, 38 | the network: discovery, Wake-on-LAN, drivers and BIOS, network devices |
| v2 | 23, 42 | remote support (our fork of RustDesk) and computers with Linux |

Remote support waits for v2 because it is the largest part: a fork in Rust and Flutter, kept up with RustDesk's
releases for good.

Today's version, without a server, gets bug fixes only, until stage 7 removes it.

## How we work

- Each stage, or each part of a large one, is a pull request from a branch of its own off `main`, opened when the
  maintainer agrees to it.
- Before the merge: an independent review, and the tests in CI. A pull request is merged when it is ready and tested.
- A test on a virtual machine runs only when the host has the memory for it, and the machine is stopped right after.
- Commit messages say why, not only what.
- Everything in the repository is in English. The panel and the programs speak the ten languages of today.

## Layout and tools

One Go module (Go 1.27) at the top of the repository:

| Folder | What it holds |
| --- | --- |
| `verify/` | the formats of the statements, their strict schemas and the six checks, shared by the server, the agent and the signer, so that all three read a statement the same way |
| `server/` | `wmanager-server`: the panel, the API, the database, the installers |
| `agent/` | `wmanager-agent`: the installer and the service |
| `sign/` | `wmanager-sign` |
| `internal/` | code shared by them that isn't a statement: the installer's tag (`certtag`), the computer's key in the TPM (`tpmkey`) |
| `trials/` | the trials of stage 0, until the stages take their code over |
| as today | the payload: `Provision.ps1`, `lib\`, `lang\`, `Invoke-*.ps1`, `library/` |

The libraries, all with licenses that fit GPL v3 (requirement 9):

| For | Library | License |
| --- | --- | --- |
| the web server and the panel's HTML | Go's own `net/http` and `html/template` | BSD-3-Clause |
| PostgreSQL | pgx | MIT |
| migrations of the database, built into the program | goose | MIT |
| passkeys to sign in to the panel | go-webauthn | BSD-3-Clause |
| TOTP codes | pquerna/otp | Apache-2.0 |
| passwords (argon2id), the Windows service, Windows' APIs | `golang.org/x/crypto`, `golang.org/x/sys` | BSD-3-Clause |
| the computer's key in the TPM | go-attestation or go-tpm, after trial 3 | Apache-2.0 |
| security keys on Linux | libfido2 through cgo, with a thin binding of our own (go-libfido2 is hardly maintained) | BSD-2-Clause |
| Windows Hello | `webauthn.dll`, called through `golang.org/x/sys/windows` | Windows' own |
| the installer's tag | `certificate_tag.go` from Omaha, taken over with its tests (its repository is archived) | Apache-2.0 |

CI:

- **Linux:** `go vet`, `go test` against a real PostgreSQL, `govulncheck`, and `go-licenses`, which fails when a
  dependency's license doesn't fit GPL v3.
- **Windows:** the agent's tests and today's Pester tests.

## Stage 0: trials

Short trials of what could overturn the design, each on a branch of its own. Their results go into
`docs/trials.md`, and code that works is kept for the stages.

1. **FIDO2 signatures from Go:** registering a key with the relying party id `wmanager-sign.invalid`, signing a
   statement and checking it. There is no real key yet, so the trial runs against a software authenticator that
   follows the FIDO2 format. The same trial with a real key comes when there is one, before `wmanager-sign` is used
   on real computers.
2. **The tag in a signed exe:** a Go exe signed with Authenticode, tagged in the "superfluous certificate" mode, on
   Windows 11 with `EnableCertPaddingCheck` on: does Windows still accept the signature, does Defender let it run, and
   what does SmartScreen say about it when it comes from the internet (with the mark of the web)?
3. **The computer's key in the TPM:** making a key that can't leave the TPM, signing with it, and reading its public
   key, from Go, on a Windows 11 virtual machine with a virtual TPM; and what the agent does when there is no TPM.
4. **Defender and Go exe files:** an unsigned and a signed Go exe on a clean Windows 11, which feeds the open
   question of the release certificate.

## Stages of v1.0

### Stage 1: the server's frame

- **1a, data and accounts:**
  - the settings from environment variables and files, never from the command line;
  - PostgreSQL with migrations;
  - companies, accounts and the panel's roles (owner, admin). The server's first owner is made by a command that
    asks for the password in the terminal;
  - sign-in with argon2id, a mandatory TOTP code or passkey, and recovery codes;
  - sessions in cookies (`Secure`, `HttpOnly`, `SameSite=Strict`), CSRF tokens, a strict Content Security Policy,
    rate limits and a lockout;
  - the audit log, each entry holding the hash of the one before, its newest head sent to Loki every few minutes,
    and its export as CSV and JSON (requirement 25);
  - every query limited to the signed-in account's companies, and row-level security in PostgreSQL as a second
    barrier.
- **1b, the panel and the image:**
  - the panel's frame in ten languages, with a test that every language has every message;
  - the Docker image;
  - `examples/selfhosted/` with Caddy, PostgreSQL, Loki and Grafana, and `selfhosted.sh` with backup and restore of
    the database.
- **Tests:** unit tests, and integration tests against PostgreSQL, including tests that one company sees nothing of
  another.

### Stage 2: signatures

- **2a, `verify/`:**
  - the formats and their strict schemas, decoded with `encoding/json/v2` and unknown members rejected. It also
    refuses a name that appears twice and matches names exactly. The old `encoding/json` keeps the last of two equal
    names and binds `"SERIAL"` to `serial`, even with `DisallowUnknownFields` (checked with Go 1.27.4);
  - the six checks;
  - a software authenticator for the tests, with a test for every refusal: a synced key, another company, a wrong
    origin, an old serial, a wrong algorithm.
- **2b, `wmanager-sign` on Linux:**
  - the first admin list and the company's fingerprint, then the changes of the list;
  - showing what is signed, with control characters made visible and the difference from the last verified state;
  - `add-file`, typing secrets, the clock check against the server, the serial numbers;
  - a new key's full fingerprint shown at registration and typed by the administrator, how each person's rights
    change, and the head of the audit log it saw last;
  - a test by hand with a real security key, once there is one;
  - the server's side: storing statements and handing them out.
- **2c:** Windows Hello in `wmanager-sign`.

### Stage 3: the agent and the installer

- **3a, the service and enrollment:**
  - the `wmanager` service as SYSTEM;
  - the computer's key in the TPM and its id;
  - enrollment with a token, the fingerprint typed at the computer, and the first 8 characters of the id shown;
  - long polling and the time of last contact, with Grafana's panel of computers that are off and its alert, read
    from PostgreSQL.
- **3b, the installer:** the installer from the panel, tagged with the company's whole admin chain,
  `wmanager-sign check-installer`, and the list of computers.

### Stage 4: the company's state

- **4a, edited, signed and checked:**
  - editing in the panel: groups, files, package lists, scripts, jobs, triggers, settings, the library;
  - signing in `wmanager-sign`, and the agent's check;
  - the rights of people (requirement 24), with the secrets granted to each person and the `stop` of their own
    jobs.
- **4b, the payload, secrets and logs:**
  - the agent writes the verified copy in the format decided before this part (the proposal: today's
    `manifest.psd1` and `groups.psd1`, so the PowerShell code changes as little as possible), and
    `wmanager-agent verify` lets the payload check that copy;
  - the settings of today's `provision.config.psd1` taken from the state;
  - secrets checked against their hashes and kept for SYSTEM;
  - logs (requirement 19), the way the open question decides (the proposal: through the server);
  - the inventory (requirement 12) from today's daily system report, which the payload runs, and its search in the
    panel.

### Stage 5: jobs and actions

- **5a, single jobs:** the targets, the checks of time and ids, the output as it comes, and the signed `stop`.
- **5b, the actions approved in advance** (requirement 18), with their limits, and isolating a computer
  (requirement 28).

### Stage 6: updates

- the release: a reproducible build (`-trimpath`, a fixed date), the signed `SHA256SUMS` and exe files, and the
  server's image;
- the agent updating itself and the payload, the check on the computer, and going back;
- `wmanager-sign` updating itself, and a new release key, named by a release signed with the old one.

### Stage 7: without the serverless mode

Removing `run.cmd`, `install.ps1`, the wizard, the management source and its tools, and Healthchecks. The
documentation and the ten languages.

### Stage 8: a full test on a virtual machine

The server in Docker on the host. A clean Windows 11 goes through the installer, provisioning, a change of state, a
single job, an update and going back.

## Decisions during the work

Each is asked before its stage, with the [open questions](architecture.md#open-questions) of the design. The first
option is the proposal.

| Decision | Before | Options |
| --- | --- | --- |
| How `wmanager-sign` signs in to the server | 2b | through the browser and back to a local address, as `gh auth login` does / a code from the panel typed into `wmanager-sign` |
| How the agent proves itself to the server | 3a | every request signed with the computer's key in the TPM / TLS with a client certificate of that key, which Caddy would have to pass through |
| The TPM library | 3a | the one trial 3 shows to work |
| What the payload reads | 4b | today's `manifest.psd1` and `groups.psd1`, written by the agent / a new JSON format, with the PowerShell code changed to read it |
