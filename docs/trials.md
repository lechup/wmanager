# Trials of stage 0

> The short trials of what could overturn the design of v1, before its stages are built
> ([Implementation plan](implementation.md#stage-0-trials)). Each says what was tried, how, and what it showed.

The code is on the branch of this document:

| Code | What it is | Kept for |
| --- | --- | --- |
| `verify/` | checks 3 to 5 of a statement's signature, and reading a key's COSE public key | stage 2a |
| `verify/softkey/` | a software FIDO2 authenticator, for tests only | the tests of every stage |
| `internal/certtag/` | the installer's tag (from Omaha's `certificate_tag`) | stage 3b (server) and 3a (agent) |
| `internal/tpmkey/` | the computer's key in the TPM, through NCrypt | stage 3a |
| `trials/` | `wmtrial` and the virtual machine script | removed once the stages take the code over |

## Trial 1: FIDO2 signatures from Go

**Tried:** checking a signature the way the agent will (checks 3 to 5 of
[Signed statements](architecture.md#signed-statements)), for ES256, EdDSA and RS256, against a software
authenticator that builds the authenticator data and the signature as a security key does. There is no real key yet.

**Showed:**

- A good signature passes for all three algorithms, also with the public key read from its COSE form, as a key gives
  it at registration.
- Each of these is refused, and the tests check the reason: another relying party, no touch, no PIN, a synced
  passkey (*backup eligible*, or *backed up* alone), attested data or extensions in a signature, a web page's
  origin, `crossOrigin: true`, a registration (`webauthn.create`) instead of a signature, an unknown member of the
  client data, a member twice, a member in other case, another statement's hash, a changed byte in the
  authenticator data or the signature, extra bytes after the authenticator data, and a signature with another
  algorithm than the one pinned for the key.
- A key's COSE form is accepted only as a real key writes it: one canonical CBOR encoding (no unknown labels, no
  byte string written as an array, shortest integers, no tags), P-256 on the curve, an Ed25519 key not of small
  order (with the identity point as the key, a fixed signature verifies on any message), and RSA of 2048 to 4096
  bits with exponent 65537.
- `encoding/json/v2` with `RejectUnknownMembers` refuses a member twice and a member in other case. The old
  `encoding/json` keeps the last of two members and binds `"SERIAL"` to `serial`, even with `DisallowUnknownFields`
  (checked with Go 1.27.4).

**Still open:** the same with a real security key (libfido2 on Linux) and with Windows Hello (`webauthn.dll`), once
there is a key: that a real key signs the client data hash we give it for the relying party `wmanager-sign.invalid`,
and reports *user verified* and *backup eligible* as expected.

## Trial 2: the tag in a signed exe

**Before the virtual machine, in CI** (`tests/ci/check-certtag.sh`): a Go exe signed by `osslsigncode` with a
leaf certificate under a CA, the chain written leaf first as a commercial certificate brings it, stays valid for
`osslsigncode verify` after a tag, a 30 kB tag, and the first tag again (the file doesn't grow). A first version
of `certtag`, which re-encoded the signature with `encoding/asn1` as Omaha does, would have broken this: DER sorts a
SET OF, so about half of all two-certificate chains were refused. It now keeps the signature's bytes and only
replaces its certificates, in their order. A fuzz test (`FuzzGetSet`) finds no input that crashes it.

**On Windows:** waiting for the virtual machine run (Windows' own check, `EnableCertPaddingCheck`, Defender,
SmartScreen).

## Trial 3: the computer's key in the TPM

Waiting for the virtual machine run.

## Trial 4: Defender and Go exe files

Waiting for the virtual machine run.
