# Statements

> The JSON form of what a computer acts on, as `verify/` reads it (stage 2a of the
> [Implementation plan](implementation.md)). The design behind them is
> [Signed statements](architecture.md#signed-statements).

A statement travels as its exact bytes with one signature:

```json
{"statement": "<the bytes, base64>", "key": "<the signing key's id>",
 "authenticator_data": "<base64>", "client_data_json": "<base64>", "signature": "<base64>"}
```

The key signs its authenticator data followed by the SHA-256 of the client data, which holds the SHA-256 of the
statement's bytes as its challenge (relying party `wmanager-sign.invalid`, origin `wmanager-sign:v1`). Nothing is put
into a canonical form: the hash is of the bytes as they are.

Every statement is a JSON object with exactly the members of its type, each once, in its exact case and, at its top
level, none missing or null (the members marked so below may be left out; a list or map inside, such as a
computer's groups, may be empty); an unknown member, a missing one, a member twice, another case or
data after the object refuse it. Its size is checked before anything is read: an admin list up to 256 KiB, a state
up to 8 MiB, a job or a stop up to 1 MiB, a session up to 16 KiB. Except for the first admin list, which is checked
against the fingerprint first, the signature is checked before the statement is read. Every one has:

| Member | What it is |
| --- | --- |
| `format` | `1` |
| `type` | `admins`, `state`, `job`, `stop` or `session` |
| `signed_at` | when `wmanager-sign` signed it (RFC 3339) |
| `company` | the company's id (64 hex characters), in every statement but the first admin list |

Hashes are SHA-256 in lower-case hex. A key's id is the SHA-256 of its COSE public key, which names its algorithm
(ES256 on P-256, EdDSA on Ed25519, RS256 of 2048 to 4096 bits with exponent 65537). Names (of administrators,
computers, people) have 1 to 100 characters, with no control or formatting character (no bidirectional override)
and no space around them. Paths have letters, digits, `-`, `_`, `.` and `/`, are relative, and have no part `.` or
`..`.

## admins

```json
{"format": 1, "type": "admins", "signed_at": "2026-11-28T09:00:00Z",
 "nonce": "<128 random bits, the first version only>", "sequence": 1,
 "administrators": [{"name": "Anna", "keys": [{"id": "<key id>", "cose": "<COSE key, base64>"}]}]}
```

- The first version (`sequence` 1) has a `nonce` and no `company` or `previous` (the three may each be left out); it
  is signed by one of its own keys. Its hash is the company's id, and the first 128 bits of that, as
  `7F3A-91C2-...`, are the company's fingerprint.
- Each later version has the next `sequence`, the `company`, `previous` (the hash of the version before) and no
  `nonce`, and is signed by a key of the version before.
- A key appears once in the whole list; 1 to 100 administrators, 1 to 20 keys each; `sequence` at most 2^53.
- **A chain received later must start with the one held**, byte for byte: a computer, or `wmanager-sign`, refuses
  an older chain or one that leaves its own at any list, since either could bring back a key removed since.

## state

```json
{"format": 1, "type": "state", "signed_at": "...", "company": "...", "serial": 42,
 "server": "https://wm.example.com", "release": "<hash of the release certificate (DER)>",
 "computers": [{"id": "<hash of its public key>", "name": "OFFICE-03", "groups": ["office"]}],
 "files": {"groups/office/choco-reqs.txt": "<hash>"},
 "version": {"name": "v1.0.0", "files": {"Provision.ps1": "<hash>"}},
 "secrets": {"wifi-office": "<salted hash of the value>"}}
```

- Signed by a key of the newest admin list; its `serial` must be higher than the last state the computer has, and at
  most 2^53 (so a server reporting a huge serial can't make `wmanager-sign` sign the last one there is).
- `server` is `https://host[:port]`, written in lower case, with no user, path, query or fragment: a server can't
  move the computers.
- A computer has at most 100 groups, each once.
- Groups and secret names: a letter or digit, then up to 62 of letters, digits, `.`, `_` and `-`.

The people who are not administrators, with their keys, units and rights, join the state in stage 4.

## job

```json
{"format": 1, "type": "job", "signed_at": "...", "company": "...", "id": "<128 random bits>",
 "computers": ["<computer id>"], "script": "<hash>", "run_as": "system", "secrets": [],
 "start_after": "...", "expires": "...", "limit": 600}
```

`run_as` is `system` or `user`; `expires` is after `start_after` and `signed_at`, and at most 7 days after
`signed_at`; `limit` is 1 second to a day; computers and secrets each once. When a job may run (the time floor, ids seen before) is stage 5.

## stop

```json
{"format": 1, "type": "stop", "signed_at": "...", "company": "...", "job": "<job id>", "computers": ["<computer id>"]}
```

## session

```json
{"format": 1, "type": "session", "signed_at": "...", "company": "...", "id": "<128 random bits>",
 "computer": "<computer id>", "person": "Anna", "viewer_key": "<base64>",
 "may": ["screen", "keyboard", "files", "privacy"], "open_by": "...", "max_length": 3600}
```

`person` is the name the admin list gives the key that signed it (the black screen of privacy mode shows it);
`open_by` is within 15 minutes of `signed_at`; `max_length` is a minute to 12 hours. Remote support comes in v2.
