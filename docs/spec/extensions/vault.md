# Vault

This file is normative. It owns the encryption every extension's records share: the data key,
the passphrase, the keyring and its slots, the record envelope, unlocking, and rotation. The
security rules for where keys and passphrases may live are
[security-model §10.6](../algorithms/security-model.md#106-vault-keys-and-passphrases). What an
extension and a record are is the [extensions README](README.md).

---

## 1. Problem

Extension records are secrets, and the store's provider sees every object in plaintext
([security-model §3.1](../algorithms/security-model.md#31-non-goals)). The records are encrypted
before they reach a file. Every machine of the user must read them, and the store must not be
enough to read them, so the key is wrapped under a passphrase and the wrapped key travels with
the records. Each machine unwraps it once and keeps it in the OS keystore.

## 2. Keys

| Name | What | Made |
|---|---|---|
| **K** | the data key: 32 bytes, encrypts every record of the domain | once per domain, at init, from the CSPRNG |
| **key id** | 8 bytes naming K, written as 16 lowercase hex | with K, from the CSPRNG |
| **passphrase** | 16 bytes, shown to the user in base32 (§2.1) | at init and at each passphrase change, from the CSPRNG |
| **KEK** | 32 bytes, wraps K in one slot | Argon2id of the passphrase and the slot's salt (§4.2) |

- Each domain has its own vault: K, key id and passphrase are per domain.
- Every random value here is drawn from the operating system's CSPRNG, with no fallback
  ([01 §2.10](../01-core.md#210-random-identifiers)).
- The passphrase is never chosen by the user. Its 128 bits are the protection against an offline
  guess by anyone who reads the keyring from the store.

### 2.1 Passphrase spelling

- Written as the 16 bytes in Crockford base32 (alphabet `0123456789abcdefghjkmnpqrstvwxyz`),
  most significant bit first, padded with zero bits to 26 characters, lower case, in groups
  `5-5-5-5-6` joined by `-`.
- Input is normalised before decoding: spaces and `-` removed, folded to lower case, `i` and `l`
  read as `1`, `o` read as `0`. Anything that is not then 26 characters of the alphabet, with
  the two padding bits zero, is refused as malformed, before any key derivation.

## 3. Initialising

`tsync vault init` (action `vault_init`) creates the domain's vault.

1. It is refused unless the domain lists at least one extension
   ([05 §2.1](../05-ops-config.md#21-schema-and-validation)).
2. It brings the local tree to the main's first (a cycle on a full tree, a pull of `/.tsync-ext/`
   on a lazy one), and is refused if that fails or a keyring exists. Init is a user's one-time
   act, so a refusal costs a retry, never a second vault.
3. It draws K, the key id and a passphrase, writes the keyring with one passphrase slot (§4),
   and caches K (§6).
4. It shows the passphrase once: on the terminal for the CLI, in the reply of `vault_init` for an
   app, which SHOULD offer it as text and as a QR code. tsync never shows it again
   ([security-model §10.6](../algorithms/security-model.md#106-vault-keys-and-passphrases)).

A user who loses the passphrase and every machine's cached K has lost the records. Nothing
recovers them.

## 4. The keyring

### 4.1 Format

The keyring is the file `/.tsync-ext/vault/keyring`: one JSON object, UTF-8.

```json
{"keyId":"9f3c2a7d1e4b8c06",
 "slots":[{"id":"5b1e0c9a7f2d4e38","kind":"passphrase",
           "kdf":{"alg":"argon2id","memKiB":65536,"iterations":3,"parallelism":1,
                  "salt":"<b64url, 16 bytes>"},
           "nonce":"<b64url, 24 bytes>","wrapped":"<b64url, 48 bytes>","created":1760500000}]}
```

| key | rule |
|---|---|
| `keyId` | the key id of K, 16 lowercase hex |
| `slots` | non-empty array; each slot wraps the same K |
| slot `id` | 16 lowercase hex from the CSPRNG; unique in the keyring |
| slot `kind` | `passphrase`; other kinds are reserved (per-device keys, a user-chosen passphrase) |
| slot `created` | epoch seconds; informative |
| `kdf`, `nonce`, `wrapped` | the wrapping (§4.2); present on a `passphrase` slot |

- `b64url` is base64url without padding.
- **Readers** accept members in any order and ignore unknown members. A slot of an unknown kind
  is skipped when unlocking, kept when the keyring is rewritten, and counted in status.
- **Writers** write the canonical form: members in the order of the table, no whitespace, slots
  sorted by `id` ascending, a slot of an unknown kind written as it was read. Two writers of the
  same keyring content then write the same bytes, which the fold relies on (§4.3).
- A keyring that does not parse, or has no slot, is CORRUPT; the vault stays locked and status
  reports it.

### 4.2 Wrapping a slot

```
KEK     = Argon2id(password = passphrase bytes, salt, memKiB, iterations, parallelism, length 32)
wrapped = XChaCha20-Poly1305-Seal(KEK, nonce, K, ad = "tsync-vault-slot/" keyId "/" slot id)
```

- Argon2id is version 0x13 (RFC 9106). XChaCha20-Poly1305 is the AEAD of
  draft-irtf-cfrg-xchacha, with a 24-byte nonce drawn from the CSPRNG for each wrap.
- Writers use `memKiB` ≥ `VAULT_KDF_MIN_MEM`, `iterations` ≥ 2 and `parallelism` = 1, and
  SHOULD use the recommended values of §9.
- A reader MUST refuse to derive with `memKiB` above `VAULT_KDF_MAX_MEM`, `iterations` above
  `VAULT_KDF_MAX_ITERATIONS` or `parallelism` above `VAULT_KDF_MAX_PARALLELISM`. Such a slot is
  skipped as unusable and reported. The keyring arrives from the store, and the limits keep a
  slot from asking a phone for more memory than it has.
- An unwrap that fails authentication means a wrong passphrase for that slot; the next slot is
  tried. Every slot failing is "wrong passphrase".

### 4.3 Concurrent changes

Two clients that rewrite the keyring concurrently leave a conflicted copy beside it. The vault's
fold ([README §4.2](README.md#42-the-fold)) settles it:

- **Same `keyId`.** The keyring becomes the union of the slots of every copy, by slot id (for
  one id, the slot whose canonical JSON is bytewise greatest), written canonically at `keyring`.
  The copies are removed. The fold needs no key.
- **Different `keyId`.** Two inits raced. The keyring at `keyring` is the domain's vault; the
  copy is not folded and is reported. The machine that made the copy holds the copy's K in its
  keystore: when that machine is unlocked with the domain's passphrase (§6), it re-encrypts
  every record whose envelope names the copy's key id under the domain's K, then removes the copy
  and its own old K. Only that machine holds the old K, so no other client rewrites those
  records.

A slot removed concurrently with another keyring change comes back from the union. Status lists
the slots, so the user sees it.

## 5. Record envelope

Every record body is:

```
envelope = "tsv1"          4 bytes, magic
           key id          8 bytes
           nonce          24 bytes, from the CSPRNG for each write
           ciphertext      the plaintext's length
           tag            16 bytes
ad       = "tsync-vault/" extension-name
```

- `ciphertext ‖ tag = XChaCha20-Poly1305-Seal(K, nonce, plaintext, ad)`. The plaintext is the
  extension's record ([wifi §2](wifi.md#2-record)).
- The associated data binds a record to its extension, so a body moved into another extension's
  folder does not open. It does not bind the record id: a fold may rename a record without
  rewriting it ([README §4.2](README.md#42-the-fold)).
- Each write of a record draws a new nonce, so a record written twice has two different bodies.
- A body shorter than 52 bytes, with another magic, or failing authentication under K is
  CORRUPT: it is reported by name, kept, and never overwritten by a fold. A body naming another
  key id than the keyring's is not CORRUPT: it waits for the step of §4.3, and is reported as
  under another key.

## 6. Unlocking and the keystore

A machine's vault for a domain is **unlocked** when it holds K for the keyring's key id, and
**locked** otherwise.

- `tsync vault unlock` reads the passphrase from the terminal without echo, or from standard input
  with `--stdin`. The action `vault_unlock` takes it as `passphrase`. Either tries each
  `passphrase` slot (§4.2).
- On success the owner caches K in the host's keystore, under the domain and the key id. A host
  with no usable keystore keeps K in the owner's memory until the owner exits, and never writes
  it to disk. Where each host keeps it:
  [security-model §10.6](../algorithms/security-model.md#106-vault-keys-and-passphrases).
- At owner start, K is read from the keystore. A cached K whose key id is not the keyring's
  leaves the vault locked (§4.3 says what unlocking then does with it).
- A machine adopts only a K it unwrapped itself, with a passphrase, from the domain's keyring. A
  machine encrypts only under the keyring's key id. A keyring replaced in the store by one with
  another key id therefore locks every machine; none of them writes records under the new key
  until its user unlocks it with that keyring's passphrase.
- `tsync vault lock` (action `vault_lock`) removes K from the keystore and from memory.
- Operations that need K on a locked vault are refused `locked`
  ([failure-model §7.2](../algorithms/failure-model.md#72-client-error-codes)). Folds and
  arrivals that need no plaintext go on.

## 7. Rotation

- **Passphrase change.** `tsync vault passphrase` (action `vault_passphrase`) needs an unlocked
  vault. It draws a new passphrase, adds a slot for it, removes every other `passphrase` slot,
  writes the keyring and shows the new passphrase once (§3 step 4). K and every record stay as
  they are.
- A passphrase change does not revoke the old passphrase from anyone who also holds an old
  keyring: the domain's versions keep the previous keyring
  ([05 §4.8](../05-ops-config.md#48-deleted-files-and-retention)), and its old slot wraps the
  same K. Revoking a leaked passphrase needs a new K.
- **New K.** Not specified in this version. The key id in every envelope is there so a later
  version can re-key with no format change.

## 8. Commands

Every verb is of access class **owner**
([07 §2.5](../07-daemon-cli.md#25-one-shot-commands)): K may live only in the owner's memory.

| verb / action | needs K | does |
|---|---|---|
| `init` / `vault_init` | — | §3 |
| `unlock` / `vault_unlock` | — | §6 |
| `lock` / `vault_lock` | — | §6 |
| `passphrase` / `vault_passphrase` | yes | §7 |
| `status` / `vault_status` | — | initialised or not; key id; locked or unlocked; where K is cached (`keystore`, `memory`); slot count by kind; unusable slots; keyring copies and records under another key; CORRUPT bodies by name |

`vault_init` and `vault_passphrase` are the only replies that carry a secret.

## 9. Parameters

| name | value | rule |
|---|---|---|
| `VAULT_KDF_MEM` / `VAULT_KDF_ITERATIONS` / `VAULT_KDF_PARALLELISM` | 64 MiB / 3 / 1 | writers' recommended values (RFC 9106 second recommendation) |
| `VAULT_KDF_MIN_MEM` | 19 MiB | writers MUST NOT go below |
| `VAULT_KDF_MAX_MEM` / `VAULT_KDF_MAX_ITERATIONS` / `VAULT_KDF_MAX_PARALLELISM` | 256 MiB / 10 / 4 | readers refuse above; MUST fit the smallest host that unlocks |

## 10. Conformance

- Argon2id and XChaCha20-Poly1305 reproduce the test vectors of RFC 9106 §5.3 and of
  draft-irtf-cfrg-xchacha appendix A.
- A passphrase prints as 26 characters in groups `5-5-5-5-6`; its input survives upper case,
  spaces, missing dashes and the `i l o` substitutions; a 25- or 27-character input or one with
  non-zero padding bits is refused before derivation.
- Init on a domain with no extension, offline, or over an existing keyring is refused and writes
  nothing. After init the store holds a keyring and no plaintext key or passphrase.
- Unlock with the passphrase succeeds; any other passphrase fails as "wrong passphrase"; a slot
  above a `VAULT_KDF_MAX_*` limit is skipped and reported without being derived.
- Writing the keyring twice with the same content gives identical bytes. A keyring with an
  unknown slot kind and unknown members unlocks through its known slot, and keeps the unknown
  slot through a rewrite.
- Two clients each add a slot concurrently: after both fold, the keyring holds both slots and no
  copy, and no further copy appears.
- Two clients init concurrently: the second keyring stays as a reported copy; after the second
  machine unlocks with the first's passphrase, its records open under the domain's K, the copy is
  gone, and no record was lost.
- An envelope with a flipped bit, another magic, or moved into another extension's folder does
  not open, is reported CORRUPT and is never overwritten. Two writes of one plaintext give two
  bodies.
- A keyring replaced by one with another key id locks the machine; it writes no record until it
  is unlocked with that keyring's passphrase.
- After a passphrase change, only the new passphrase unlocks the current keyring, and every
  record still opens.
- Lock removes K: a restart of the owner finds the vault locked.
