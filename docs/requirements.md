# Requirements of v1

> The requirements for wmanager v1 (server and agent). The list is closed (2026-11-27): a new idea goes to a later
> release, as requirement 43 went to v2. The design that meets them is [Architecture of v1](architecture.md), and the order of the work is the
> [Implementation plan](implementation.md), with what each release brings.

## Requirements

| # | Requirement | Added | Release | In the design |
| --- | --- | --- | --- | --- |
| 1 | **A server is required**: `wmanager-server` and `wmanager-agent`. Without a server wmanager does nothing. | 2026-11-26 | v1.0 | [Parts](architecture.md#parts) |
| 2 | **Sign-in to the panel with a mandatory second factor**, for every account. | 2026-11-26 | v1.0 | [The server inside](architecture.md#the-server-inside) |
| 3 | **The server makes the agent installer** (an exe) for each company. | 2026-11-26 | v1.0 | [Enrolling a computer](architecture.md#enrolling-a-computer) |
| 4 | **Automatic updates** of the agent and of wmanager on the computers, without visiting them. | 2026-11-26 | v1.0 | [Updates](architecture.md#updates) |
| 5 | **Single jobs**: run a script on one computer (or a group) now, and see its output. | 2026-11-26 | v1.0 | [Single jobs](architecture.md#single-jobs) |
| 6 | **The server alone can't make an enrolled computer run code.** Everything a computer acts on is signed in `wmanager-sign`, with a security key or Windows Hello, by an administrator of its company or by a person the company's signed state gives that right. | 2026-11-26 | v1.0 | [Who can make a computer run something](architecture.md#who-can-make-a-computer-run-something) |
| 7 | **Many companies on one server**, each kept apart: its own administrators and admin list, computers, groups, files, secrets, jobs, installers, audit log and Loki tenant. One person may work for several companies. | 2026-11-26 | v1.0 | [Several companies on one server](architecture.md#several-companies-on-one-server) |
| 8 | **A minimal panel**: few screens, plain HTML from the server, no frontend framework and no build step; JavaScript only where the browser needs it (passkeys). | 2026-11-26 | v1.0 | [The server inside](architecture.md#the-server-inside) |
| 9 | **An open-source license**: every part (server, agent, signer, payload) under an OSI-approved license, GPL v3 as today (the fork of RustDesk for remote support stays AGPL-3.0). Only dependencies whose licenses fit it (e.g. MIT, BSD, Apache 2.0, MPL 2.0), and no closed component needed to run it. | 2026-11-26 | v1.0 | [License](architecture.md#license) |
| 10 | **What wmanager does today stays**: the provisioning steps, groups, packages, scripts, jobs, the startup, fixed-time, event and sign-in triggers, run-as user, secrets, the library, the ten languages, Loki and Grafana. | 2026-11-26 | v1.0 | [What stays the same](architecture.md#what-stays-the-same) |
| 11 | **A person at the computer provisions it**, and the passwords are typed there, never stored. | 2026-11-26 | v1.0 | [Enrolling a computer](architecture.md#enrolling-a-computer) |
| 12 | **Inventory with search**: hardware, programs and their versions, the Windows version, BitLocker, TPM, Secure Boot, Defender, local administrators and the last signed-in user, searchable across a company's computers (e.g. "Chrome older than X"). | 2026-11-26 | v1.0 | [Inventory](architecture.md#inventory) |
| 13 | **Alerts**: a computer that is off, low disk space, a pending restart, old Defender signatures, a failed job; by e-mail and webhook. | 2026-11-26 | v1.1 | to design |
| 14 | **A compliance report per company** (CSV and PDF): BitLocker, firewall, updates and more, e.g. for a client's audit or NIS2. | 2026-11-26 | v1.2 | to design |
| 15 | **Windows Update under control**: the state of each computer, installing now or at a set time, and a restart the user can postpone. | 2026-11-26 | v1.1 | to design |
| 16 | **Network discovery**: the agent finds devices without an agent in its local network (printers, NAS, unknown computers). | 2026-11-26 | v1.4 | to design |
| 17 | **Wake-on-LAN**: an agent wakes a computer that is off in the same network. | 2026-11-26 | v1.4 | to design |
| 18 | **One-click actions in the panel, approved in advance**: an administrator signs once a list of actions without free parameters (restart, Defender scan, inventory refresh, update now, a diagnostics bundle; Wake-on-LAN with requirement 17), and the panel starts them without a key. Anything else (any script, installing or removing a program, a message to users) is signed every time. | 2026-11-26 | v1.0 | [Actions approved in advance](architecture.md#actions-approved-in-advance) |
| 19 | **Logs on our side**: job output, runs and the audit log in the panel (PostgreSQL); the computers' full logs in Loki next to the server (the self-hosting kit), with Grafana; Grafana Cloud only as an option. | 2026-11-26 | v1.0 | [Logs and monitoring](architecture.md#logs-and-monitoring) |
| 20 | **SSO for the panel**: OIDC and SAML (Entra ID, Google Workspace, Keycloak, Authentik), roles from the provider's groups, MFA required at the provider. SSO opens only the panel: signing still needs a key in `wmanager-sign`. | 2026-11-26 | v1.3 | to design |
| 21 | **Export to a SIEM, per company**: the audit log and security events from the computers (Defender detections, refused signatures, new computers), as syslog over TLS (JSON or CEF), a webhook or OpenTelemetry; enough for Splunk, Elastic, Sentinel and Wazuh. | 2026-11-26 | v1.3 | to design |
| 22 | **API and webhooks**: a REST API with narrowly scoped tokens, and events sent to webhooks (e.g. a ticketing system). | 2026-11-26 | v1.3 | to design |
| 23 | **Computers with Linux**, after Windows: the same server, agent and signatures, with a payload for Linux (apt or dnf, bash scripts, systemd timers). | 2026-11-26 | v2 | to design |
| 24 | **Rights of people to units**: a person who is not an administrator gets rights to groups (e.g. one site of a company) and to single computers: seeing their data, the actions approved in advance, remote sessions and single jobs, and remote work (requirement 43). Only the company's administrators give them. | 2026-11-26, extended 2026-11-27 | v1.0 | [People and their rights](architecture.md#people-and-their-rights) |
| 25 | **An audit log that can't be changed unnoticed** (each entry holds the hash of the one before), exportable. | 2026-11-26 | v1.0 | [The server inside](architecture.md#the-server-inside) |
| 26 | **Retention of logs and output per company**, with deletion after it (GDPR). | 2026-11-26 | v1.3 | to design |
| 27 | **BitLocker with key escrow**: turning BitLocker on, and the recovery keys kept on the server (which can read them, as it can read secrets). | 2026-11-26 | v1.2 | to design |
| 28 | **Isolating a computer**: an action approved in advance in which the firewall cuts the computer off from everything but the wmanager server, e.g. when an infection is suspected; another action lifts it. | 2026-11-26 | v1.0 | [Actions approved in advance](architecture.md#actions-approved-in-advance) |
| 29 | **Security events**: failed sign-ins, changes to the local Administrators, new services and programs, USB drives plugged in; to the alerts and the SIEM export. | 2026-11-26 | v1.2 | to design |
| 30 | **A lost laptop**: locked the next time it reaches the server, and wiped on request; always signed in `wmanager-sign`. | 2026-11-26 | v1.2 | to design |
| 31 | **An employee joining and leaving**: a ready flow for the account, groups and drives; on leaving, the account disabled, the data kept safe and the computer provisioned again. Passwords as in requirement 11. | 2026-11-26 | v1.3 | to design |
| 32 | **Staged rollouts**: a pilot group first also for packages and for big Windows updates (e.g. 24H2 to 25H2), not only for the wmanager version. | 2026-11-26 | v1.1 | to design |
| 33 | **Drivers and BIOS**: updates with the makers' tools (Dell Command Update, Lenovo System Update, HP). | 2026-11-26 | v1.4 | to design |
| 34 | **Maintenance windows**: when a group may restart and install, with a notice to the user before a restart. | 2026-11-26 | v1.1 | to design |
| 35 | **Hardware records**: a computer assigned to a person and a site, its purchase date, warranty and notes. | 2026-11-26 | v1.3 | to design |
| 36 | **Reports for billing**: the number of computers per company per month, and the job history, e.g. for invoices. | 2026-11-26 | v1.3 | to design |
| 37 | **Hardware health**: SMART of the disks, battery wear, Windows activation, certificates about to expire. | 2026-11-26 | v1.1 | to design |
| 38 | **Network devices**: the agent pings routers, printers and NAS and queries them over SNMP; the internet link of each site is watched. | 2026-11-26 | v1.4 | to design |
| 39 | **Wi-Fi profiles per group**: WPA2 and WPA3 Personal, the network's password a secret; WPA2 and WPA3 Enterprise (802.1X, PEAP or EAP-TLS) with the account or certificate it needs. | 2026-11-26 | v1.1 | to design |
| 40 | **VPN profiles per group**: the VPN built into Windows (IKEv2, SSTP, L2TP), WireGuard and OpenVPN; the programs from Chocolatey, the keys and passwords secrets. | 2026-11-26 | v1.1 | to design |
| 41 | **A ready list of packages to choose from**, not installed by default: wmanager suggests Chocolatey packages (Chrome, LibreOffice, Adobe Acrobat Reader, 7-Zip, VLC, RustDesk, Notepad++), and an administrator picks the ones a group gets. Nothing is installed on every computer unless a package list says so. | 2026-11-26 | v1.1 | to design |
| 42 | **Remote support built into wmanager**: our own fork of RustDesk (AGPL-3.0, under a name of its own), with the roles of its ID server and relay moved into `wmanager-server`. The part on the computer is set up by the agent and takes its password from a variable, never from a command line; the server never knows that password. A second factor before every connection. Everything is started from the web panel; technicians connect with a separate viewer that signs in with the same accounts and rights as the panel (SSO, roles limited to groups). **Privacy mode**: the computer's screen black and its keyboard and mouse blocked during a session, as a right of its own; the black screen shows who is working and since when, and turning it on is logged. | 2026-11-27 | v2 | [Remote support](architecture.md#remote-support) |
| 43 | **Remote work for people who are not administrators**: an employee works from elsewhere on a computer given to them, in their own Windows account without administrator rights (the computer refuses an account that is an administrator, and a UAC prompt can't be answered from afar). They sign in to the panel and start from there; the connection goes through the viewer of remote support, a program from the release, not through the browser. A second factor before every connection that the computer checks itself: the person's FIDO2 security key or Windows Hello, or a TOTP code set up at that computer, whose secret is only there and in the person's authenticator app, accepted only from the person's own viewer. The computer's screen is black, showing who works and since when, and its keyboard and mouse are blocked. | 2026-11-28 | v2 | [Remote work](architecture.md#remote-work) |

## Decisions so far

- Go for the server, the agent and `wmanager-sign`. The agent runs today's PowerShell code.
- PostgreSQL for the server's data.
- The company's first admin list is its anchor. Each change is signed by a key from the version before.
- Everything a computer acts on is signed in `wmanager-sign`, a program from the release on the signer's own
  computer, not in the panel: the panel's page comes from the server, so a hacked server could change what is signed
  there.
- One-click actions are approved in advance: their scripts and parameter limits are in the signed state, and the
  server decides only when and on which computers they run. A hacked server can start them at a bad time, never other
  code.
- Logs: what the panel shows in PostgreSQL, the full logs in Loki next to the server.
- Secrets are typed in `wmanager-sign`. The signed state holds a salted hash of each value, and the computer keeps the
  values its scripts need, readable only by SYSTEM, so they work at startup and without a network.
- The serverless mode of today is removed, with no migration: there are no computers in production.
- Remote support: the viewer is a program from the release, opened from the panel by a link. It signs nothing: it
  asks `wmanager-sign`, which shows each session and signs it with the technician's key. The computer checks that
  signature against the signed state, so the panel's sign-in alone opens no session.
- Remote work (requirement 43) goes through the viewer, not the browser: the panel's pages and scripts come from the
  server, so a hacked server could watch a session in a browser, type into it as the employee and take the Windows
  password typed there. Its second factor is checked by the computer, a key in the signed state or a TOTP code set up
  at that computer and taken only from the viewer the state names, since a hacked server could skip one only the
  server checks or connect with a code it phished.
- Rights of people: the units are groups and single computers. The rights the computer checks (remote sessions,
  single jobs) are in the signed state, given by an administrator in `wmanager-sign`; seeing the data and the
  actions approved in advance are checked by the server. A person's jobs may use only the secrets granted to that
  person, and a person stops only the jobs they signed.
- A new key is added only with its full fingerprint (128 bits) typed in the administrator's `wmanager-sign`, so the
  server can't swap it.
- The audit log's newest head is written down off the server: `wmanager-sign` remembers the head it saw last, and
  the head goes to Loki and later to the SIEM export, which count when they are on another host.

## Waiting to be done

- The [open questions](architecture.md#open-questions) of the design and the
  [decisions during the work](implementation.md#decisions-during-the-work), each before its stage.
- Requirements marked "to design": their place in [Architecture of v1](architecture.md), when their release comes.
