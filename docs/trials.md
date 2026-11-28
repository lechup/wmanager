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
and reports *user verified* and *backup eligible* as expected. The code for both is in `sign/internal/fido`
(stages 2b and 2c); the tries wait for a security key, and for a virtual machine with Windows Hello set up.

## Trial 2: the tag in a signed exe

**Before the virtual machine, in CI** (`tests/ci/check-certtag.sh`): a Go exe signed by `osslsigncode` with a
leaf certificate under a CA, the chain written leaf first as a commercial certificate brings it, stays valid for
`osslsigncode verify` after a tag, a 30 kB tag, and the first tag again (the file doesn't grow). A first version
of `certtag`, which re-encoded the signature with `encoding/asn1` as Omaha does, would have broken this: DER sorts a
SET OF, so about half of all two-certificate chains were refused. It now keeps the signature's bytes and only
replaces its certificates, in their order. A fuzz test (`FuzzGetSet`) finds no input that crashes it.

**On Windows** (2026-11-28, before the tag moved to its OID of 2.25 from a UUID, with a certificate written by
`crypto/x509` under the example number 32473; to be done again with the 2.25 OID and the hand-written certificate
before stage 3b relies on it; Windows 11 Pro build 26300, a virtual machine with a TPM 2.0 from swtpm;
`trials/vm/stage0.ps1`): a Go exe signed with Authenticode by a self-signed certificate trusted on that machine.

| File | Signature, padding check off | Signature, `EnableCertPaddingCheck` on |
| --- | --- | --- |
| signed | Valid | Valid |
| tagged (a 50-byte tag) | Valid | Valid |
| tagged again (a 30 kB tag) | Valid | Valid |
| data appended after the signature (the old way, a control) | Valid | NotSigned |

- The tag keeps the signature valid with the padding check on, which refuses the old way: the check was really on.
- The tagged exe reads its own tag.
- **SmartScreen:** an exe marked as downloaded from the internet and opened from Explorer is blocked as an
  "unrecognized app", tagged or not, signed by the trusted self-signed certificate or unsigned alike. SmartScreen
  judges by reputation, which a self-signed certificate never has. So a self-signed release certificate (one of the
  three the release may use, as decided) means an installer checked with `wmanager-sign check-installer` or taken
  from GitHub. An installer copied from a USB drive carries no mark of the web and isn't checked by SmartScreen.
- `Import-Certificate` is refused for the Root store on this build (also as SYSTEM); `certutil -addstore` works.

## Trial 3: the computer's key in the TPM

On the same virtual machine (the TPM: `TPM-Version:2.0`, maker IBM, from swtpm), with `internal/tpmkey`:

| Run as | Provider | Made | Signed | Opened again | Deleted |
| --- | --- | --- | --- | --- | --- |
| an administrator (SSH) | Platform Crypto Provider (TPM) | 438 ms | 47 ms, verifies | the same key | yes |
| an administrator (SSH) | Software Key Storage Provider | 12 ms | 1 ms, verifies | the same key | yes |
| SYSTEM (a scheduled task, as the agent will run) | Platform Crypto Provider (TPM) | 224 ms | 49 ms, verifies | the same key | yes |
| SYSTEM | Software Key Storage Provider | 21 ms | 1 ms, verifies | the same key | yes |

- An ECDSA P-256 machine key in the TPM works for SYSTEM, which is how the agent runs: made once at enrollment,
  then about 50 ms a signature, fine for signing the agent's requests.
- The software provider is the fallback for a computer without a TPM (the key then stays on the disk, protected by
  Windows, not by a chip).
- CI's Windows runner tests the key's life with the software provider (`internal/tpmkey`); it has no TPM.

## Trial 4: Defender and Go exe files

On the same virtual machine, with real-time protection on and cloud protection (MAPS 2): Defender
(signatures 1.437.1.0, engine 1.1.25080.5) found no threat in the Go exe unsigned, signed or tagged, by a scan of
each file, and none ran into a detection. A single trial on one machine and one day: Defender's cloud verdicts
change, so the release's exe files are still to be signed (the release certificate, stage 3).

## What the trials decide

- **The installer's tag** (the superfluous certificate) works with Windows' strict check: the plan stays.
- **The computer's key in the TPM**, for SYSTEM, through NCrypt: the plan stays; the software provider is the
  fallback without a TPM.
- **The release certificate:** SmartScreen blocks a downloaded installer without reputation, so the proposal (a
  publicly trusted certificate) stands; asked before stage 3.
- **Still open:** the FIDO2 trial with a real key (trial 1), once there is one.
