# The agent's protocol

> How `wmanager-agent` enrolls a computer and talks to `wmanager-server` (stage 3a of the
> [Implementation plan](implementation.md)). The design behind it is [Enrolling a computer](architecture.md#enrolling-a-computer)
> and [The agent inside](architecture.md#the-agent-inside). The agent trusts the server for nothing it acts on:
> everything that makes a computer run something is a signed statement it checks itself ([Statements](statements.md)).

## The computer's key

The agent makes an ECDSA P-256 key on the computer, in the TPM when there is one (`internal/tpmkey`, NCrypt's
Platform Crypto Provider; the software provider otherwise). It never leaves it. The computer's **id** is the SHA-256
of the key's public key in its PKIX form (SubjectPublicKeyInfo, DER), in lower-case hex; the installer shows its
first 8 characters, which an administrator types when the computer is added to a signed state.

## Enrolling

An administrator makes an **enrollment token** for a company on the company's page in the panel: valid for 7 days
by default (1 hour to 30 days), for a number of computers (1 to 1000). It is shown once, kept as a hash, and ended
on the same page. The installer carries it in its tag (stage 3b), or a person types it.

```
POST /api/agent/v1/enroll
{"token": "...", "public_key": "<SPKI, base64>", "name": "OFFICE-03", "time": "<RFC 3339>", "proof": "<base64>"}
```

- `proof` is the key's ECDSA signature (ASN.1) over the SHA-256 of
  `wmanager-agent enroll v1\0<server>\0<SHA-256 of the token, hex>\0<computer id>\0<name>\0<time>`, where server is
  the server's address as the agent reached it (`https://host[:port]`), so a proof made for one server and token
  can't be used with another. The time is within 10 minutes of the server's.
- The name is the one typed at the computer, 1 to 100 characters with no control or formatting character; only a
  signed state names a computer for good.
- The answer is `{"computer": "<id>", "company": "<the server's id of it>"}`. Each enrollment uses the token once;
  a token used up or ended enrolls nothing more. A computer whose key is enrolled already gets its id again (an
  installer run twice), within the same company only.
- Wrong tokens are limited per address, as wrong codes are.

## Every request after it

Each request carries the computer's signature:

```
Authorization: WM-Agent id=<computer id>, time=<RFC 3339 with nanoseconds>, sig=<base64>
```

`sig` is the key's ECDSA signature (ASN.1) over the SHA-256 of
`wmanager-agent request v1\0<method>\0<path and query>\0<time>\0<SHA-256 of the body, hex>`. The server takes it
only within 5 minutes of its own time, and each signature once: a request seen before is refused. The prefix is
the request's own, so a signature made for a request can't pass for the key of a remote session (v2), which has
another.

## Waiting for news

```
GET /api/agent/v1/poll?lists=<admin lists held>&serial=<serial of the state held>
```

The server answers at once when it has something newer for the computer's company (admin lists after the number
held, a state with a higher serial), else after up to 50 seconds, with nothing new. The answer is
`{"lists": [...], "state": <signed state or null>, "time": "<server time>"}`. The agent checks everything in it
itself; the server's time is only for the agent's display and logs. Each request marks the computer's **last
contact**, which the panel shows and Grafana watches.
