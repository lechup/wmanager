# Requirements of v1

> The requirements for wmanager v1 (server and agent), collected while v1 is being planned. Work on the code starts
> once the list is complete. The design that meets them is [Architecture of v1](architecture.md).

## Requirements

| # | Requirement | Added | In the design |
| --- | --- | --- | --- |
| 1 | **A server is required**: `wmanager-server` and `wmanager-agent`. Without a server wmanager does nothing. | 2026-11-26 | [Parts](architecture.md#parts) |
| 2 | **Sign-in to the panel with a mandatory second factor**, for every account. | 2026-11-26 | [The server inside](architecture.md#the-server-inside) |
| 3 | **The server makes the agent installer** (an exe) for each company. | 2026-11-26 | [Enrolling a computer](architecture.md#enrolling-a-computer) |
| 4 | **Automatic updates** of the agent and of wmanager on the computers, without visiting them. | 2026-11-26 | [Updates](architecture.md#updates) |
| 5 | **Single jobs**: run a script on one computer (or a group) now, and see its output. | 2026-11-26 | [Single jobs](architecture.md#single-jobs) |
| 6 | **The server alone can't make an enrolled computer run code.** Everything a computer acts on is signed by an administrator of its company in `wmanager-sign`, with a security key or Windows Hello. | 2026-11-26 | [Who can make a computer run something](architecture.md#who-can-make-a-computer-run-something) |
| 7 | **Many companies on one server**, each kept apart: its own administrators and admin list, computers, groups, files, secrets, jobs, installers, audit log and Loki tenant. One person may work for several companies. | 2026-11-26 | [Several companies on one server](architecture.md#several-companies-on-one-server) |
| 8 | **A minimal panel**: few screens, plain HTML from the server, no frontend framework and no build step; JavaScript only where the browser needs it (passkeys). | 2026-11-26 | [The server inside](architecture.md#the-server-inside) |
| 9 | **An open-source license**: every part (server, agent, signer, payload) under an OSI-approved license, GPL v3 as today. Only dependencies whose licenses fit it (e.g. MIT, BSD, Apache 2.0, MPL 2.0), and no closed component needed to run it. | 2026-11-26 | [License](architecture.md#license) |
| 10 | **What wmanager does today stays**: the provisioning steps, groups, packages, scripts, jobs, the startup, fixed-time, event and sign-in triggers, run-as user, secrets, the library, the ten languages, Loki and Grafana. | 2026-11-26 | [What stays the same](architecture.md#what-stays-the-same) |
| 11 | **A person at the computer provisions it**, and the passwords are typed there, never stored. | 2026-11-26 | [Enrolling a computer](architecture.md#enrolling-a-computer) |

## Decisions so far

- Go for the server, the agent and `wmanager-sign`. The agent runs today's PowerShell code.
- PostgreSQL for the server's data.
- The company's first admin list is its anchor. Each change is signed by a key from the version before.
- Everything a computer acts on is signed in `wmanager-sign`, a program from the release on the administrator's
  computer, not in the panel: the panel's page comes from the server, so a hacked server could change what is signed
  there.
- Secrets are typed in `wmanager-sign`. The signed state holds a salted hash of each value, and the computer keeps the
  values its scripts need, readable only by SYSTEM, so they work at startup and without a network.
- The serverless mode of today is removed, with no migration: there are no computers in production.

## Waiting to be done

- **An architecture diagram in the documentation**, with its description. It must be visible on GitHub (drawn, not
  text art) and must replace the text diagram in [Parts](architecture.md#parts).
- The [open questions](architecture.md#open-questions) of the design, each before its stage.
