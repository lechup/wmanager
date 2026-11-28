# wmanager-server

> The server of wmanager v1 ([Architecture of v1](architecture.md)). It is being built
> ([Implementation plan](implementation.md)): today it has the panel with its accounts and companies, the
> mandatory second factor and the audit log. Computers, statements and jobs come in the next stages.

## Running it

The self-hosting kit in `examples/selfhosted/` runs it with Docker, next to Loki and Grafana
([Hosting Grafana and Loki yourself](monitoring.md#hosting-grafana-and-loki-yourself)), behind Caddy, which gets
the certificates. Until releases publish the image (stage 6), Docker builds it from this repository
(`server/Dockerfile`), so keep the kit in its place in the checkout.

On a server with Docker, three names pointing to it (logs, Grafana, the panel) and ports 80 and 443 open:

```bash
cd examples/selfhosted
./selfhosted.sh init                         # the names, an e-mail for the certificates; .env and secrets/
docker compose up -d --build
./selfhosted.sh create-owner you@example.com # the owner of the server; asks for the password
```

After updating the kit (`git pull`), run `./selfhosted.sh init` again before `docker compose up -d --build`: it adds
what a newer kit needs to `.env` and `secrets/` and keeps the rest. Without the panel's name in `.env`, compose stops
before changing anything. With Caddy on other ports than 443 (`CADDY_HTTPS_PORT`), set `PANEL_PORT_SUFFIX` (e.g.
`:8443`) so the links the panel gives out carry the port.

Then open `https://<the panel's name>`, sign in, and set up the second factor: scan the QR code with an
authenticator app and keep the ten recovery codes it shows once. Later, on the page "Account", add a passkey (a
security key, Windows Hello, a phone) to use instead of the code; the code and the recovery codes keep working. These
passkeys sign in to the panel only: signing what a computer acts on needs a key in `wmanager-sign`, under a relying
party id no web page can claim.

- **The owner** makes companies, invites accounts and puts them into companies. An invited person gets a one-time
  link (valid 7 days) from the owner and sets their own password and second factor; the owner never knows them. A
  lost or expired link is replaced with "New link".
- **A company's page** shows its people and its audit log, checked link by link, with an export as JSON lines (to
  check the hashes) or CSV, and its administrators who sign, with the company's fingerprint.
- **[wmanager-sign](sign.md)** connects with a code from the page "Account", made within 10 minutes of the second factor. It
  works once, for 5 minutes, and nobody else should ever see it. Wrong codes are limited per address and, together,
  to 1000 a minute for the whole server. The token lasts 12 hours and reaches only the sign API. "Disconnect
  wmanager-sign everywhere" ends every token of the account and a code still waiting.
- **Signing keys** are registered from `wmanager-sign`, each with a proof signed by the key that its holder
  registers it for this account on this server (at most 20 an account; it needs `WMANAGER_PUBLIC_URL`). A key counts only once an administrator adds it to a
  signed admin list, after typing its fingerprint.

## What runs

| Container | What it is |
| --- | --- |
| `caddy` | HTTPS for all three names. The only one with ports; at a fixed address in the network `front` |
| `migrate` | the migrations, as the owner of the tables, once at each start; then it ends |
| `wmanager` | `wmanager-server serve`, as an unprivileged user in a distroless image, without capabilities, read-only |
| `postgres` | PostgreSQL 17, with the server's database `wmanager` |
| `loki`, `grafana` | as for today's version; Loki also gets the heads of the server's audit log, and takes no deletions |

Networks keep them apart: only Caddy reaches the server (`front`), only the server and the migrations reach
PostgreSQL (`data`), the server reaches Loki for the heads (`heads`), and Caddy, Loki and Grafana share `logs`.
The last two have no way out. Caddy replaces any `X-Forwarded-For` a browser sends, and the server believes it from
Caddy's address only. Clients that reach Docker over IPv6 come in through Docker's proxy, all from one address, and
share the limits per address: use an A record only, or give Docker's networks IPv6.

The database has two roles, made at PostgreSQL's first start (`postgres/init.sh`):

- `wmanager_owner` owns the tables; the migrations run as it, in their own container. The server's container never
  gets its password.
- `wmanager`, in the group `wmanager_runtime`, is the server's own: it may only read and add audit entries, and it
  can't turn row-level security off. The server, and the migrations after they run, refuse a role that could.

Their passwords are in `secrets/`, a folder only you can open, given to the containers as Docker secrets (files
readable by the containers' own users, which the folder keeps everyone else from); nothing secret is on a command
line or in the environment.

## Settings

The server reads them from the environment (the kit's `docker-compose.yml` sets them), never from its command line:

| Variable | What it is |
| --- | --- |
| `WMANAGER_DATABASE_URL` (or `_FILE`) | the server's role, in `wmanager_runtime` |
| `WMANAGER_MIGRATE_DATABASE_URL` (or `_FILE`) | the role that owns the tables; with it, `serve` migrates first |
| `WMANAGER_LISTEN` | the address it listens on, `127.0.0.1:8080` by default (`:8080` in the image) |
| `WMANAGER_PUBLIC_URL` | the panel's address, for the links it gives out (`https://host[:port]`) |
| `WMANAGER_TRUSTED_PROXIES` | the exact address of Caddy, whose `X-Forwarded-For` it believes; not a whole network |
| `WMANAGER_LOKI_URL`, `WMANAGER_LOKI_TENANT`, `WMANAGER_LOKI_HEAD_EVERY` | where the audit heads go (default tenant `wmanager-server`, every 5 minutes) |

## The audit log off the server

Every few minutes the server writes each chain's newest head to Loki, in the tenant `wmanager-server` (Grafana's
data source "Loki wmanager-server", `{job="audit-head"}`). Check a chain against a head seen there:

```bash
docker compose exec wmanager /usr/local/bin/wmanager-server audit verify company:<id> <seq>:<hash>
```

A head in the kit's Loki is on the same host, so it counts against a database changed by mistake or by someone
who reached only the database; against a hack of the whole host, only a copy elsewhere counts (a Loki of its own,
the SIEM export later, and `wmanager-sign`, which will remember the heads it saw).

## Backup and restore

```bash
./selfhosted.sh backup               # backups/wmanager-<time>.dump, readable by you only
./selfhosted.sh restore <file>       # restores it aside, then swaps it in
```

`restore` restores the dump into a database of its own, as the owner of the tables and in one transaction. Only when
that works does it stop the server, swap the two databases, and start it again; the one before stays as
`wmanager_old` until the next restore. A dump that doesn't restore leaves everything as it was.

The dump holds the values of the secrets the server keeps: store a copy off the server, safely. An older dump ends
before the newest audit heads in Loki, so a check against those heads then says the chain doesn't lead to them:
that is the restore, not a tampering, and the heads from before the dump's time still match.

## Other commands

Run inside the container, e.g. `docker compose exec wmanager /usr/local/bin/wmanager-server <command>`:

| Command | What it does |
| --- | --- |
| `create-owner <e-mail>` | makes the owner (`./selfhosted.sh create-owner` runs it) |
| `unlock <e-mail>` | ends a lockout after wrong second-factor codes |
| `audit verify <chain> [<seq>:<hash>]` | checks a chain, and that it leads to a head seen elsewhere |
| `audit export <chain> json\|csv` | writes a chain |
| `migrate` | migrates the database as the owner of the tables |
| `healthcheck` | Docker's health check |
