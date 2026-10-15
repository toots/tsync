# TOTP extension

This file is normative. It owns the `totp` extension: its record, its fold, code generation and
its commands. It is an extension as the [README](README.md) defines one, and its records are
vault envelopes ([vault §5](vault.md#5-record-envelope)). It has no host adapter and defines no
capabilities: every command works on every host.

---

## 1. Problem

Two-factor seeds live on one phone; losing the phone means a recovery procedure at every
service. With this extension tsync keeps the seeds in the user's own storage, encrypted, and
every machine of the user generates the same codes.

## 2. Record

One record per account, at `/.tsync-ext/totp/<record id>`. Its plaintext is one JSON object,
UTF-8:

```json
{"issuer":"GitHub","account":"me@example.com","secret":"JBSWY3DPEHPK3PXP",
 "algorithm":"SHA1","digits":6,"period":30,"modified":1760500000}
```

| key | type | rule |
|---|---|---|
| `issuer` | string | the service; may be empty |
| `account` | string | the account at the service; may be empty, not when `issuer` is |
| `secret` | string | the seed in RFC 4648 base32, upper case, no padding; decodes to 1 to 128 bytes |
| `algorithm` | `"SHA1"` \| `"SHA256"` \| `"SHA512"` | the HMAC hash |
| `digits` | int, 6 to 8 | |
| `period` | int, 1 to 300 | seconds |
| `modified` | int | epoch seconds of the last change a user made |

- Every key is required. A plaintext that breaks a rule is CORRUPT: reported by record id, never
  used, never folded away.
- Readers ignore unknown members, and a rewrite keeps them.
- `secret`, `algorithm`, `digits` and `period` are the record's **code fields**. A record's code
  fields never change: a change of seed is a new record and the removal of the old one. Only
  `issuer` and `account` are edited, and an edit sets `modified`.

## 3. Fold

The grouped fold ([README §4.3](README.md#43-the-grouped-fold)), with the code fields as key
fields. A seed changed in place, which §2 forbids, therefore survives as a second record.

A removal on one machine and an edit on another keep the edited record, as the merge keeps any
edited file ([conflict-resolution §8.1](../algorithms/conflict-resolution.md#81-where-every-byte-ends-up)).

## 4. Code generation

A code is the TOTP of RFC 6238 with `T0 = 0`:

```
counter = floor(unix_time / period)                     as an 8-byte big-endian integer
mac     = HMAC-<algorithm>(base32-decode(secret), counter)
offset  = mac[len(mac) − 1] & 0x0f
value   = (mac[offset] & 0x7f) << 24 | mac[offset+1] << 16 | mac[offset+2] << 8 | mac[offset+3]
code    = value mod 10^digits, in decimal, zero-padded to digits
```

- `unix_time` is the host's wall clock ([01 §4](../01-core.md#4-time-p5)). tsync does not
  correct a skewed clock; it reports the seconds left in the current period,
  `period − unix_time mod period`, with each code.
- Codes are computed by the owner on request and are never stored.

## 5. Commands

Every verb is of access class **owner**
([07 §2.5](../07-daemon-cli.md#25-one-shot-commands)) and needs K.

| verb / action | request | does |
|---|---|---|
| `add` / `totp_add` | `uri` | adds one record from an `otpauth://totp/` URI (§5.1); replies with its id |
| `list` / `totp_list` | `filter?` | every record whose issuer or account contains `filter` (case-insensitive): id, issuer, account, code, seconds left; ordered by issuer, then account, then id |
| `rename` / `totp_rename` | `id`, `issuer?`, `account?` | edits the labels and sets `modified` |
| `remove` / `totp_remove` | `id` | removes the record |
| `export` (CLI only) | — | prints one `otpauth://totp/` URI per record, the way out of tsync |

- `list` never carries a seed. `export` is the only verb that prints one, and it has no action:
  a seed reaches no app through the request handler.
- An `id` names a record of this extension or is refused `invalid`; a well-formed id with no
  record is `not_found`.

### 5.1 `otpauth` URIs

- Form: `otpauth://totp/<label>?secret=…[&issuer=…][&algorithm=…][&digits=…][&period=…]`, as
  written by the Google Authenticator key-URI format. Percent-decoding applies to the label and
  every value.
- The label is `issuer:account` or `account`. The `issuer` parameter, when present, is the
  issuer; the label's issuer is used only without it.
- `secret` is base32, accepted in any case and with or without padding, stored as §2 says.
  Missing parameters take `SHA1`, `6`, `30`. Any value outside §2's rules is refused `invalid`.
- `otpauth://hotp/` is refused `invalid`. An HOTP counter changes at each code, and two
  machines using one seed would hand out the same counter.
- Unknown parameters are ignored.

## 6. Conformance

- The RFC 6238 appendix B vectors, 8 digits, period 30: seed `12345678901234567890` with SHA1
  gives `94287082` at 59, `07081804` at 1111111109, `89005924` at 1234567890 and `65353130` at
  20000000000; the 32-byte seed `12345678901234567890123456789012` with SHA256 gives `46119246`
  at 59; the 64-byte seed `1234567890` × 6 followed by `1234` with SHA512 gives `90693936` at 59.
  Codes keep their leading zeros.
- `add` of `otpauth://totp/ACME%20Co:john@example.com?secret=JBSWY3DPEHPK3PXP&issuer=ACME%20Co`
  stores issuer `ACME Co`, account `john@example.com`, SHA1, 6 digits, period 30. A lower-case or
  padded secret is stored upper case without padding. An `hotp` URI, 9 digits, an unknown
  algorithm or an empty secret is refused and writes nothing.
- The store holds no seed, label or code in plaintext after `add`.
- `list` replies hold no seed. `export` then `add` of each URI reproduces every record's fields
  but `modified`.
- Two machines rename one record concurrently: after both fold, one record remains at its id
  with the newer labels, and no copy.
- Two copies with different code fields fold into two records, both still producing their codes.
- A record with a CORRUPT plaintext is reported and survives a fold.
- Every verb on a locked vault is refused `locked` and changes nothing.
