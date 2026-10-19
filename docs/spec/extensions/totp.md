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

**The second record says where it came from.** After a fold that moved a conflicted copy to a
digest id (rule 5), the machine that applied it writes that record again with
` (conflicted copy from <client>)` appended to its issuer, or to its account when the issuer is
empty, `<client>` taken from the copy's name ([conflict-resolution §5](../algorithms/conflict-resolution.md#5-conflicted-copy-name))
and `modified` kept. The user sees `Foo Provider` and `Foo Provider (conflicted copy from
laptop)` and keeps the right one. It is a write after the fold, not part of it, since sealing
draws a nonce: two machines that relabel concurrently write the same plaintext, and the copies
that leaves fold by rule 4. A label that already ends with the suffix is not written again.

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
| `add` / `totp_add` | `uri`, or `secret` with `issuer?` and `account?` | adds one record from an `otpauth://totp/` URI (§5.1) or from a bare secret (§5.3); replies with its id |
| `code` / `totp_code` | `id` | the record's current code and seconds left; no seed, no labels |
| `list` / `totp_list` | `filter?` | every record whose issuer or account contains `filter` (case-insensitive): id, issuer, account, code, seconds left; ordered by issuer, then account, then id; `outdated` and `pulledAt` when answered from the last view ([README §4.1](README.md#41-where-they-live)) |
| `rename` / `totp_rename` | `id`, `issuer?`, `account?` | edits the labels and sets `modified` |
| `remove` / `totp_remove` | `id` | removes the record, one that does not open included: removing needs no plaintext |
| `import` / `totp_import` | `text` | adds one record per line of a plain-text export (§5.2); replies with what it added, skipped and refused |
| `export` / `totp_export` | `passphrase` | one `otpauth://totp/` URI per record, the way out of tsync, and the ids of the records that do not open, which the CLI names on stderr so none is left behind unnoticed |

- `list` never carries a seed. `export` is the only verb that returns one. K lives in the owner,
  so the CLI's `export` reaches it through the request handler like any verb; an app MUST NOT
  offer `totp_export`.
- `export` needs the domain's passphrase each time, even on an unlocked vault: any process of the
  user can reach the owner, and the passphrase is what tells the user's request from theirs. It
  is checked against the keyring like an unlock (vault §6), with the secret key this machine is
  enrolled with; a wrong one is refused DENIED (`denied`), one too short INVALID. The CLI asks
  once per domain.
- An `id` names a record of this extension or is refused `invalid`; a well-formed id with no
  record is `not_found`.
- A refusal names what is wrong, never the value given: a URI, a line or a secret may hold a seed.
- The CLI takes a URI or a secret as `-` to read it from standard input, so that no seed sits in
  the shell's history or in the process list.

### 5.1 `otpauth` URIs

- Form: `otpauth://totp/<label>?secret=…[&issuer=…][&algorithm=…][&digits=…][&period=…]`, as
  written by the Google Authenticator key-URI format. Percent-decoding applies to the label and
  every value.
- The scheme is matched in any case, and the type is what lies between `otpauth://` and the next
  `/` or `?`.
- The label is `issuer:account` or `account`, split on its first literal `:` before decoding, so
  that a `:` written `%3A` belongs to the issuer or the account. A label with no literal `:` whose
  decoded form holds one is split there: some services encode the separator. The `issuer`
  parameter, when present, is the issuer; the label's issuer is used only without it. Written
  back (`export`), an empty issuer with an account holding a `:` gives the label `:account`.
- `secret` is base32, accepted in any case and with or without padding, its trailing bits
  ignored as other authenticators ignore them (a secret whose length is no multiple of 8 ends in
  a partial symbol), stored as §2 says.
- `digits` and `period` are decimal digits only.
  Missing parameters take `SHA1`, `6`, `30`. Any value outside §2's rules is refused `invalid`.
- `otpauth://hotp/` is refused `invalid`. An HOTP counter changes at each code, and two
  machines using one seed would hand out the same counter.
- Unknown parameters are ignored.

### 5.2 Plain-text import

The plain-text export of another authenticator (Ente Auth writes this form, and its encrypted
export decrypts to it): `otpauth://` URIs, one per line, or several on a line separated by `,` or
`;`.

- A `,` or `;` separates two entries only where the next entry, after spaces, starts with
  `otpauth://`: a label left unencoded may hold either character.
- Entries are trimmed; empty ones are skipped. Each other is added as `add` would (§5.1), into one
  domain.
- A refused entry is reported by its line number (and its rank on the line, when the line has
  several) and reason, never by its content (it holds a seed), and the others go on.
- A line whose issuer, account and code fields equal those of a record of the domain, or of an
  earlier line, is skipped as already there: importing one file twice adds nothing.
- Line numbers count from 1 and include empty lines, so they match an editor's.

### 5.3 A bare secret

Services that show a QR code usually offer the same seed as text ("enter this code instead"): a
base32 secret alone, with the account named beside it.

- `secret` is read as §5.1 reads the URI's: any case, with or without padding, and also with
  spaces, which services print to group the text; stored as §2 says.
- `issuer` and `account` are as §2 says; not both empty. The code fields take `SHA1`, `6` and
  `30`, the values such a text code implies.
- A request with both `uri` and `secret`, or neither, is refused `invalid`.

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
- `add` of the secret `jbsw y3dp ehpk 3pxp` with issuer `GitHub` and account `me` stores the same
  record as the URI `otpauth://totp/GitHub:me?secret=JBSWY3DPEHPK3PXP&issuer=GitHub`; a secret
  with no issuer and no account, or with a `uri` too, is refused and writes nothing.
- `list` replies hold no seed. `export` then `add` of each URI reproduces every record's fields
  but `modified`, an issuer or account holding `:` included.
- `add` of `otpauth://totp?secret=JBSWY3DPEHPK3PXP`, or of an `hotp` URI, is refused with a
  reason that holds no part of the URI; a 26-symbol secret whose last symbol has bits set is
  accepted.
- A record that does not open can be removed by id; `export` names it on stderr.
- `import` of three lines (a URI, an empty line, an `hotp` URI) adds one record and refuses line
  3 without echoing it; importing the same text again adds nothing and skips one; the `export`
  of a domain imports into an empty domain as the same records.
- Two machines rename one record concurrently: after both fold, one record remains at its id
  with the newer labels, and no copy.
- Two copies with different code fields fold into two records, both still producing their codes;
  the one moved from the copy is listed with ` (conflicted copy from <client>)` after its issuer,
  and a second fold changes nothing.
- A record with a CORRUPT plaintext is reported and survives a fold.
- Every verb on a locked vault is refused `locked` and changes nothing.
- On a lazy tree with the store down after a list: `list` answers every record with its current
  code, `outdated`; `add` is answered, the record listed at once and pushed when the store returns.
- `export` with no passphrase, a wrong one or another domain's is refused and returns no URI.
