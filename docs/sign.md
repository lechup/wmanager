# wmanager-sign

> The signer of wmanager v1 ([Architecture of v1](architecture.md#wmanager-sign)). It is being built
> ([Implementation plan](implementation.md)): today it connects to the server, makes and registers signing keys,
> keeps and signs each company's chain of admin lists, and signs its states, single jobs and stops, and new values
> of its secrets, and adds files from your own disk; it checks the companies' audit logs. Windows Hello comes in
> stage 2c.

`wmanager-sign` runs on the administrator's own computer, never on the server. A server, even a hacked one, can't
make it sign anything it didn't show, and can't make it take an admin list that doesn't follow the one it holds.

## Building it

Releases will publish it, checked against the signed `SHA256SUMS` (stage 6). Until then, build it from this
repository on Linux, with libfido2:

```bash
sudo apt-get install libfido2-dev        # Debian, Ubuntu; Fedora: libfido2-devel
go build -tags fido2 -o wmanager-sign ./sign/cmd/wmanager-sign
```

Without `-tags fido2` it builds without security keys: it connects and shows, but can't sign.

The security key must speak FIDO2 (not only U2F) and have a PIN set (`fido2-token -S <device>`, or the key maker's
tool) or a fingerprint of its own. A phone or a password manager's passkey is synced between devices, and is
refused.

## First steps

1. **Connect.** On the panel's page "Account", choose "Connect wmanager-sign": it shows a code for 5 minutes. Then:

   ```bash
   wmanager-sign connect https://wm.example.com
   ```

   and type the code (it isn't shown as you type). The connection lasts 12 hours; then make a new code. It works
   over SSH too: the code is typed wherever `wmanager-sign` runs.

2. **Make a signing key** on your security key, with its PIN and two touches:

   ```bash
   wmanager-sign key new
   ```

   It registers the key with the server, with the key's proof that you register it for your account on this
   server, and shows the key's fingerprint: 32 characters, like `F154-46CC-3083-D07B-FE21-A17F-F9CB-565D`. An
   administrator adds your key to a company by typing them. **Read them out in person or by phone**, never through
   the panel or an e-mail, which a hacked server could change.

   Make a second key on a second security key, so that losing one doesn't lock you out.

3. **A new company:** its first administrator makes its first admin list, with their name and key:

   ```bash
   wmanager-sign company init Acme
   ```

   It shows the company's fingerprint, and keeps the list even when the server's answer is lost on the way (it
   gives the server the list the next time). **Write it down and keep it**: computers are checked against it when they
   are installed, and other administrators type it in. The panel shows it too, but a hacked server could show
   another one there.

4. **A company that has a list already:** take its chain, typing its fingerprint as it was written down or as an
   administrator reads it to you:

   ```bash
   wmanager-sign company trust Acme
   ```

## The admin list

```bash
wmanager-sign admins Acme               # the administrators and their keys
wmanager-sign admins add Acme           # a new administrator: their name, and their key's fingerprint typed
wmanager-sign admins add-key Acme       # another key for an administrator
wmanager-sign admins remove-key Acme    # a lost or leaked key
wmanager-sign admins remove Acme        # an administrator
wmanager-sign fingerprint Acme          # the company's fingerprint
wmanager-sign                           # your companies, and the lists new since you looked
```

Each change is a new admin list, signed by a key of the list before. `wmanager-sign` shows what changes (`+` for
what is added, `-` for what is removed), with every key's fingerprint, and signs only when you type `yes`. Names
are shown as they are signed: anything but printable ASCII appears as its code (e.g. `<U+202E>`), and a name with a
control or formatting character is refused.

A **leaked key**: sign a list without it at once. If the server may be hacked too, it can keep that list from the
computers: install them again.

## States

What the company's computers have (their groups, files, wmanager's version and secrets) is a signed **state**.
Changes are made in the panel (stage 4a) and wait there as drafts; `wmanager-sign` shows each one and signs it:

```bash
wmanager-sign                  # each company's state, and how many drafts wait
wmanager-sign sign Acme        # pick a draft, see what it changes, and sign it
```

It shows the difference from the newest state it has checked itself, not from what the server says:

```
State 2 of Acme (7F3A-91C2-04BD-E85F-2C6B-90AE-5D17-3B48):
Computers:
  + OFFICE-07 (13123709), groups: office, finance
  - OFFICE-03 (63c34cb3)
Files:
  ~ groups/office/hello.ps1 (+1 -1)
         1   Write-Output 'hello'
         2 - Write-Output 'old'
         2 + Write-Output 'bye'
```

- A new file is shown whole, a changed one as its changed lines with two around each. Each is fetched by its hash
  and checked; a file that can't be shown isn't signed. That includes a file that isn't text, unless it was added
  here with `add-file` (see below).
- The difference is from the newer of the state it verified and the one it signed itself, which it keeps even
  when the server doesn't show it. When the computers report a newer state than either, it signs nothing. When
  some computers may have another state (one signed by an administrator removed since, or one signed here that
  the server never got, next to another administrator's with its serial), the difference from that one is shown
  too.
- A secret whose value the server lacks (a state signed here may never have reached it) is typed again.
- A change of wmanager's version or of the release certificate is shown with the new hashes; until stage 6
  `wmanager-sign` doesn't check them against the signed releases, and says so.
- **A new computer** is added only with the first 8 characters of its id typed, as its installer showed them.
- **A new secret's value** is typed here, twice; `wmanager-sign` makes its salt and puts its hash into the state,
  and gives the value and the salt to the server.
- The serial is one more than the highest it knows.
- States signed by others are shown, in short, as they arrive, checked against the newest admin list. One signed
  by a key removed since is kept apart: the next state is shown against it too, and has a higher serial.

## Jobs and secrets

A single job's draft (from the panel, stage 4a; when a computer runs it is stage 5) is signed the same way, with
`wmanager-sign sign Acme`:

```
Job 85f0c63c8e4ecdf41b0650b01b7926de of Acme (7F3A-91C2-04BD-E85F-2C6B-90AE-5D17-3B48):
Computers (1): OFFICE-07
  from the groups finance, as the state verified here has them
Runs as SYSTEM: everything on these computers.
Secrets it may use: wifi
From 2026-11-28 13:22 until 2026-11-29 13:22, for at most 10m0s each time.
The script (2 lines):
       1 | Restart-Service Spooler
       2 | Write-Output 'done'
```

- Its groups become their computers when it is signed, from the state verified here; a computer or a secret that
  state doesn't have is refused. Its id is made here, and it expires at most 7 days after signing.
- A **stop** names a signed job and some of its computers: it stops the job where it runs, and refuses it where it
  comes later. `wmanager-sign` fetches the job by its id, checks its signature against the company's chain (an
  administrator removed since may have signed it), and shows it whole before signing the stop.
- **A secret's new value** is typed here and goes into the next state, with nothing else changed:

  ```bash
  wmanager-sign secret set Acme wifi-office
  ```

## Files from your own disk

A file that isn't text (an installer, a driver) can't be shown, so it is never signed from the panel. Add it from
your own disk instead, at its path in the company's state:

```bash
wmanager-sign add-file Acme groups/office/files/printer-driver.cab ~/Downloads/driver.cab
```

`wmanager-sign` hashes the file as it reads it, gives it to the server (up to 4 GB; the server checks the hash), and
signs the next state with it, showing it as added from that file and its size. It remembers the file as added
here, so a later state that keeps it, or names it at another path, is shown and signed here; another
administrator's `wmanager-sign`, which didn't add it, signs no state that adds it.

## The audit log

Each time `wmanager-sign` lists your companies, it reads each company's whole audit log from the server, links it
itself from the first entry (each entry's hash is the SHA-256 of the hash before and the entry's bytes), and checks
that it leads to the newest entry it saw from that server. It shows that entry as `<number>:<hash>`, which can be
compared with the heads in Loki (`wmanager-server audit verify company:<id> <number>:<hash>`). When the history no
longer leads there (changed, or restored from an older backup), it says so, keeps the entry it saw, and the run
ends with an error. Once you know why (a server moved or restored), take the log as it is now:

```bash
wmanager-sign audit accept Acme
```

## What it refuses

- **A chain that doesn't start with the one it holds**, whatever id the server lists the company under. A server
  showing an older chain gets the lists it lacks back (from an administrator), and nothing is signed on the older
  one. A server showing a chain that leaves the held one, or another chain for the company, is an alarm (it could
  bring back a removed key): nothing is signed, and the other administrators should know.
- **A key whose fingerprint wasn't typed.** The server only says which keys its members registered; the 32
  characters typed, as the key's owner reads them out, decide which one goes into the list.
- **A clock more than 10 minutes off the server's**, before it signs.
- **A state it can't show whole**, another state with the serial it holds (an alarm), and a newer one not signed
  by a key of the newest admin list.
- **A synced passkey**, and a key made without your PIN (or fingerprint) and touch.

## What it keeps

In a folder only you can open: `$WMANAGER_SIGN_HOME`, or `~/.config/wmanager-sign`.

| File | What it is |
| --- | --- |
| `server` | the server connected last |
| `servers/<host>[_<port>]/token.json` | the connection's token, until it ends |
| `servers/<host>[_<port>]/keys.json` | the signing keys made here: their public keys and credential ids |
| `companies/<id>.json` | each company's fingerprint, the whole chain it checked, the name it had when it was taken, the id each server gives it, the newest state it checked, the newest it signed, one signed by an administrator removed since, the newest audit entry it saw from each server, and the files added here |

A company is kept under its own id (the hash of its first admin list), not under the id a server gives it: a
server that lists it again under a new id meets the chain held. Commands find a company by the name it had when it
was taken, and say so when the server now calls it otherwise.

The chains are what protects you against a server that lies about them: keep the folder in your backups. The
signing keys themselves never leave the security keys. They are discoverable (resident) credentials of the relying
party `wmanager-sign.invalid`, which no website can claim, so the same security key also signs from another
computer, where `wmanager-sign` finds which of its keys signed by the signature. Each key made takes one of the
security key's places for them.

Other commands: `wmanager-sign key list` lists the keys made here; `wmanager-sign disconnect` forgets the
connection here (the panel's "Disconnect wmanager-sign everywhere" ends it on the server too).

Options before the command: `-server https://...` for another server than the one connected last, and `-lang` for
the language (or `WMANAGER_LANG`, then the system's). Its messages are in English for now; the other nine languages
come with the rest of stage 2b.
