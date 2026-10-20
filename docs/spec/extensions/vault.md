# Vault

This file is normative. It owns the encryption every extension's records share: the data key,
the secret key and the passphrase, the keyring and its slots, the record envelope, unlocking, and
rotation. The
security rules for where keys and passphrases may live are
[security-model §10.6](../algorithms/security-model.md#106-vault-keys-and-passphrases). What an
extension and a record are is the [extensions README](README.md).

---

## 1. Problem

Extension records are secrets, and the store's provider sees every object in plaintext
([security-model §3.1](../algorithms/security-model.md#31-non-goals)). The records are encrypted
before they reach a file. Every machine of the user must read them, and the store must not be
enough to read them, so the key is wrapped and the wrapped key travels with the records. It is
wrapped under two secrets, as 1Password does: a passphrase the user chooses and remembers, and a
generated secret key the user's machines keep. Whoever reads the store holds neither, and a weak
passphrase cannot be guessed offline without the secret key. Each machine unwraps K once and keeps
it, and the secret key, in the OS keystore.

## 2. Keys

| Name | What | Made |
|---|---|---|
| **K** | the data key: 32 bytes, encrypts every record of the domain | once per domain, at init, from the CSPRNG |
| **key id** | 8 bytes naming K, written as 16 lowercase hex | with K, from the CSPRNG |
| **secret key** | 16 bytes, shown to the user in base32 (§2.1) | at init, and at a change that asks for a new one (§7), from the CSPRNG |
| **secret key id** | 8 bytes naming the secret key, 16 lowercase hex: the first 8 bytes of SHA-256 of `"tsync-vault-secret-key/"` ‖ secret key | with the secret key |
| **passphrase** | chosen by the user: at least `VAULT_MIN_PASSPHRASE` characters (§2.2) | at init and at each passphrase change |
| **KEK** | 32 bytes, wraps K in one slot | Argon2id of the passphrase and the slot's salt, keyed with the secret key (§4.2) |

- Each domain has its own vault: K, key id, secret key and passphrase are per domain.
- Every random value here is drawn from the operating system's CSPRNG, with no fallback
  ([01 §2.10](../01-core.md#210-random-identifiers)).
- The secret key never reaches the store. Its 128 bits are the protection against an offline
  guess by anyone who reads the keyring from the store; the passphrase is the protection against
  anyone who obtains a machine's secret key without the user.
- The secret key id lets a client tell a wrong secret key from a wrong passphrase before any
  derivation. It reveals nothing of a 128-bit key.

### 2.1 Secret key spelling

- Written as the 16 bytes in Crockford base32 (alphabet `0123456789abcdefghjkmnpqrstvwxyz`),
  most significant bit first, padded with zero bits to 26 characters, lower case, in groups
  `5-5-5-5-6` joined by `-`.
- Input is normalised before decoding: spaces and `-` removed, folded to lower case, `i` and `l`
  read as `1`, `o` read as `0`. Anything that is not then 26 characters of the alphabet, with
  the two padding bits zero, is refused as malformed, before any key derivation.
- An app MAY also offer it as a QR code holding exactly that spelling.

### 2.2 Passphrase

- The passphrase is the UTF-8 bytes the user typed, with leading and trailing white space removed
  and nothing else changed. A client MUST NOT normalise, fold case or transliterate it: two
  machines must derive from the same bytes.
- It is at least `VAULT_MIN_PASSPHRASE` characters (Unicode scalar values) long; anything shorter is
  refused INVALID before any derivation. There is no other strength rule.
- It is never shown back, written anywhere or logged
  ([security-model §10.6](../algorithms/security-model.md#106-vault-keys-and-passphrases)). A
  terminal or an app asks for a new one twice and refuses a mismatch before sending it.

### 2.3 Generated passphrases

A CLI or app that asks for a new passphrase (§3, §7) SHOULD offer to generate one: words are
what a user can remember and type on every machine.

- `n` words, each drawn uniformly from the CSPRNG by rejection sampling from the EFF large word
  list (eff.org/dice, CC BY 3.0 US) less its four hyphenated words, 7772 words bundled with
  tsync, joined by `-`, in lower case: about 12.9 bits a word.
- A passphrase suggestion is 6 words (about 77 bits), which §2.2's length always admits.
- It is shown once, for the user to write down, and is then a passphrase like any other. The
  CLI's `init`, `passphrase` and `rekey` take `--generate` for it.

## 3. Initialising

`tsync vault init` (action `vault_init`) creates the domain's vault.

1. It is refused unless this client uses an extension of the domain
   ([README §3](README.md#3-opting-in)), or the domain uses `encryptFiles`
   ([file-encryption §2](../algorithms/file-encryption.md#2-turning-it-on)), which gives it a vault
   too. A domain may already have a vault another client made;
   this client then unlocks it (§6) instead.
2. It brings the local tree to the main's first (a cycle on a full tree, a pull of `/.tsync-ext/`
   on a lazy one), and is refused if that fails or a keyring exists. Init is a user's one-time
   act, so a refusal costs a retry, never a second vault.
3. It takes the user's passphrase (`passphrase` in `vault_init`), checks §2.2, draws K, the key id
   and the secret key, writes the keyring with one `secret-key` slot (§4), and keeps K and the
   secret key on this machine (§6).
4. It shows the secret key once: on the terminal for the CLI, in the reply of `vault_init` for an
   app, which SHOULD offer it as text and as a QR code, and MUST ask the user to confirm it was
   saved before leaving the screen, offering the emergency kit (§3.1). Afterwards only the kit
   shows it again
   ([security-model §10.6](../algorithms/security-model.md#106-vault-keys-and-passphrases)).

The secret key and the passphrase together are the user's way into the vault from a new machine:
the secret key is what 1Password calls the Emergency Kit. A user who forgets the passphrase, or
loses the secret key with every machine that kept it, has lost the records. Nothing recovers
them.

### 3.1 Emergency kit

The kit is a page the user prints or keeps offline: what a new machine needs besides the
passphrase.

- `tsync vault kit` (action `vault_kit`) needs an enrolled machine and the passphrase
  (`passphrase`), checked against the keyring as an unlock is, and answers the secret key. Init
  and a re-key (§7.2) offer it with the secret key they show: the CLI's `--kit FILE` writes the
  page from that secret key, with no second passphrase.
- The page holds the domain's name, the date, the secret key in its spelling (§2.1) and as a QR
  code of exactly that spelling, an empty box for the user to write the passphrase in by hand,
  and the steps to unlock on a new machine. It holds no passphrase and no K.
- The CLI writes it as one self-contained HTML file (`--output FILE`, created with mode 0600 and
  never replaced) for the browser to print; an app opens the platform's print dialog on it. The
  file is the secret key in plain text: the CLI says to print it and delete it.
- A wrong passphrase is DENIED and shows nothing; a machine not enrolled is refused `locked`.

## 4. The keyring

### 4.1 Format

The keyring is the file `/.tsync-ext/vault/keyring`: one JSON object, UTF-8.

```json
{"keyId":"9f3c2a7d1e4b8c06",
 "slots":[{"id":"5b1e0c9a7f2d4e38","kind":"secret-key","secretKeyId":"c41d7e0a92f63b58",
           "kdf":{"alg":"argon2id","memKiB":65536,"iterations":3,"parallelism":1,
                  "salt":"<b64url, 16 bytes>"},
           "nonce":"<b64url, 24 bytes>","wrapped":"<b64url, 48 bytes>","created":1760500000}]}
```

| key | rule |
|---|---|
| `keyId` | the key id of K, 16 lowercase hex |
| `slots` | non-empty array; each slot wraps the same K |
| slot `id` | 16 lowercase hex from the CSPRNG; unique in the keyring |
| slot `kind` | `secret-key` (the passphrase with the secret key, §4.2); other kinds are reserved (per-device keys) |
| slot `secretKeyId` | on a `secret-key` slot: the id of the secret key it is keyed with |
| slot `created` | epoch seconds; informative |
| `kdf`, `nonce`, `wrapped` | the wrapping (§4.2); present on a `secret-key` slot |

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
KEK     = Argon2id(password = passphrase bytes, salt, secret = secret key,
                   memKiB, iterations, parallelism, length 32)
wrapped = XChaCha20-Poly1305-Seal(KEK, nonce, K, ad = "tsync-vault-slot/" keyId "/" slot id)
```

- The secret key is Argon2id's secret value K (RFC 9106 §3.1), so neither secret alone derives
  the KEK.

- Argon2id is version 0x13 (RFC 9106). XChaCha20-Poly1305 is the AEAD of
  draft-irtf-cfrg-xchacha, with a 24-byte nonce drawn from the CSPRNG for each wrap.
- Writers use `memKiB` ≥ `VAULT_KDF_MIN_MEM`, `iterations` ≥ 2 and `parallelism` = 1, and
  SHOULD use the recommended values of §9.
- A reader MUST refuse to derive with `memKiB` above `VAULT_KDF_MAX_MEM`, `iterations` above
  `VAULT_KDF_MAX_ITERATIONS` or `parallelism` above `VAULT_KDF_MAX_PARALLELISM`, and with
  `parallelism` or `iterations` below 1 or `memKiB` below 8 × `parallelism` (RFC 9106's own
  floor). Such a slot is skipped as unusable and reported. The keyring arrives from the store, and
  the limits keep a slot from asking a phone for more memory than it has, or the derivation from
  running on values it is not defined for.
- A `secret-key` slot whose `secretKeyId` is not the secret key's is not derived for. Of the
  slots of the secret key given, a reader derives for at most `VAULT_MAX_SLOTS`, in slot id
  order; the others are skipped as unusable. Each derivation costs up to the limits above, so the
  count bounds one unlock, however many machines are enrolled.
- An unwrap that fails authentication means a wrong passphrase for that slot; the next slot is
  tried. Every slot failing is "wrong passphrase". No slot for the secret key given is "wrong
  secret key", said before any derivation; slots for it that are all unusable are refused
  `invalid`, naming them as unusable.

### 4.3 Concurrent changes

Two clients that rewrite the keyring concurrently leave a conflicted copy beside it. The vault's
fold ([README §4.2](README.md#42-the-fold)) settles it:

- **Same `keyId`.** The keyring becomes the union of the slots of every copy, by slot id (for
  one id, the slot whose canonical JSON is bytewise greatest), written canonically at `keyring`.
  The copies are removed. The fold needs no key.
- **Different `keyId`.** Two inits raced. The keyring at `keyring` is the domain's vault; the
  copy is not folded and is reported. Each machine that holds the copy's K (the one that made
  it, and any unlocked from it before the race settled) keeps it cached: when that machine is
  unlocked with the domain's passphrase and secret key (§6), it re-encrypts every record whose envelope names
  the copy's key id under the domain's K, in every extension's folder whether this client uses
  that extension or not, pulling each first on a lazy tree; then it removes the copy and its own
  old K. Until every record is re-encrypted the old K is kept: a re-encryption that fails fails
  the unlock and leaves both the old K and the vault as they were, for the next unlock. Two machines
  doing so concurrently leave conflicted copies of equal plaintext, which the extension's fold
  settles. Once no machine holding the copy's K is left, the records under it cannot be read;
  status keeps reporting them.

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
ad       = "tsync-vault/" extension-name "/" key id in 16 lowercase hex
```

- `ciphertext ‖ tag = XChaCha20-Poly1305-Seal(K, nonce, plaintext, ad)`. The plaintext is the
  extension's record ([totp §2](totp.md#2-record)).
- The associated data binds a record to its extension and to the key id its header names, so a
  body moved into another extension's folder, or with an altered key id, does not open. It does not bind the record id: a fold may rename a record without
  rewriting it ([README §4.2](README.md#42-the-fold)).
- Each write of a record draws a new nonce, so a record written twice has two different bodies.
- A body shorter than 52 bytes, with another magic, or failing authentication under K is
  CORRUPT: it is reported by name, kept, and never overwritten by a fold. A body naming another
  key id than the keyring's is **under another key** while a keyring copy (§4.3) names that key
  id: it waits for the step of §4.3, and is reported as such. With no such copy it is CORRUPT:
  this version re-keys nothing (§7), so no other key id is legitimate.

## 6. Unlocking and the keystore

A machine's vault for a domain is **unlocked** when it holds K for the keyring's key id, and
**locked** otherwise.

- A machine is **enrolled** in a domain's vault when it holds the secret key of one of the
  keyring's `secret-key` slots. Status says so.
- `tsync vault unlock` reads the passphrase from the terminal without echo, or from standard input
  with `--stdin`, and on a machine not enrolled the secret key the same way (one line each, the
  passphrase first). The action `vault_unlock` takes `passphrase` and, when the machine is not
  enrolled, `secretKey` (§2.1 spelling); a `secretKey` given to an enrolled machine replaces the
  one it holds. Unlock is refused `invalid` with "this machine needs the vault's secret key"
  when it holds none and none is given. It tries each slot (§4.2).
- On success the owner keeps K and the secret key in the host's keystore. A host with no usable
  keystore keeps them in the owner's memory until the owner exits, and never writes them to
  disk. Where each host keeps them:
  [security-model §10.6](../algorithms/security-model.md#106-vault-keys-and-passphrases).
- At owner start, K is read from the keystore, before any vault verb is answered; a read never
  replaces a K the owner already holds. A cached K whose key id is not the keyring's leaves the
  vault locked (§4.3 says what unlocking then does with it).
- A machine adopts only a K it unwrapped itself, with a passphrase, from the domain's keyring. A
  machine encrypts only under the keyring's key id. A keyring replaced in the store by one with
  another key id therefore locks every machine; none of them writes records under the new key
  until its user unlocks it with that keyring's secrets.
- `tsync vault lock` (action `vault_lock`) removes K from the keystore and from memory, and keeps
  the secret key: the machine stays enrolled, and the next unlock asks only for the passphrase.
  `--forget` (`forget` in the action) also removes the secret key. A K whose key id is not the
  keyring's (§4.3, §7.2) is the only key to the records still under it: a lock, an auto-lock and a
  policy keep it, in memory and in the keystore, until the unlock that re-encrypts them. It never
  unlocks the vault.
- Operations that need K on a locked vault are refused `locked`
  ([failure-model §7.2](../algorithms/failure-model.md#72-client-error-codes)). Folds and
  arrivals that need no plaintext go on.

### 6.1 The keystore

What every host's keystore does; where each host keeps it is
[security-model §10.6](../algorithms/security-model.md#106-vault-keys-and-passphrases). A domain
has at most two entries: the key id and K of its last unlock, and the secret key id and secret key
it is enrolled with, named apart. A host provides three calls, `put(name, id, secret)` (replacing
the entry), `get(name)` and `delete(name)`; the names are the domain and the domain followed by
`/secret-key`, which no domain name can be.

- **Unlock** writes the entry, then answers. A keystore that refuses the write, or a host with
  none, leaves K in memory: the unlock still succeeds, status says `cached: memory`, and the
  failure is logged once with the keystore's reason, never with K.
- **Owner start** reads the domain's entry. One for the keyring's key id unlocks the vault with
  `cached: keystore`. One for another key id is held as the K of §4.3, the vault staying locked:
  the next unlock re-encrypts under the domain's K and replaces the entry. A read that fails leaves
  the vault locked, and status reports the keystore's reason. A keystore may come up after the
  owner (a desktop session that starts after it): until K is held or dropped, a verb that needs the
  vault reads again, at most once per `VAULT_KEYSTORE_RETRY`. A K this owner held or dropped is never
  read back, so an entry a failed delete left behind does not return.
- **Lock** deletes the domain's K entry (and with `forget` its secret key entry), then forgets
  each entry deleted. Both deletes are attempted. One that fails leaves what that entry held, in
  the keystore and in memory, and the lock is refused `internal` with the keystore's reason: a
  lock that did not happen is never reported as done, and status says what is still held. A K
  held in memory alone (`cached: memory`) is dropped whatever its delete does, the failure
  logged: a host with no keystore reachable still locks. A K kept for §4.3 stays, and so does
  one while the keyring does not read, since it may be that K; that lock is refused.
- A keystore entry is only ever read by the owner of its domain, on the machine that wrote it. It
  never needs user interaction to be read: an entry the platform would guard with a prompt or a
  biometric is not used, since the owner reads it unattended at start.
- Removing a domain from the config does not delete its entry; `tsync vault lock` before
  removing it does.

### 6.2 Auto-lock

A domain MAY have its vault lock on its own (`vaultLock`,
[05 §2.1](../05-ops-config.md#21-schema-and-validation)). It is off unless configured: on a
user's own machines `vault lock` is the control (§6), and an organisation that wants unattended
machines locked states a policy from its server.

- **Triggers**, each optional:
  - `idleMinutes` (1 to 1440): no request that needs K for that long. Folds, arrivals and other
    background work are not use.
  - `onScreenLock`: the user's session locks or the machine sleeps. The host reports it by
    sending `vault_lock` with `reason: "screen"` to every domain it serves; the owner locks only
    a domain whose policy in force sets `onScreenLock`, and answers the others without locking.
    Who reports it on each host:
    [security-model §10.6](../algorithms/security-model.md#106-vault-keys-and-passphrases).
  - `maxHours` (1 to 720): that long since the unlock, whatever the use.
- **The policy in force** is the strictest of the domain's own and the one its main states: the
  smaller of each limit, and `onScreenLock` when either sets it. A client tightens what its main
  states and never loosens it. It is learned and kept like the extensions
  ([05 §2.1](../05-ops-config.md#21-schema-and-validation) rule 4); until a main's is learned, the
  domain's own applies.
- **Locking** is §6's lock without `forget`: the machine stays enrolled, and the next unlock asks
  for the passphrase. Status says why the vault was locked (`lockedBy`: `idle`, `screen` or
  `age`) until the next unlock, and an app or the tray says it when it next shows the vault.
- **No keystore.** While a policy is in force, an unlock keeps K in the owner's memory only
  (`cached: memory`), and the domain's K entry is deleted at owner start and when a policy is
  learned. A restart of the owner or of the machine therefore leaves the vault locked. The secret
  key entry stays, and so does a K of §4.3 (§6).
- A policy learned while the vault is unlocked applies at once, counting from the last use and
  from the unlock as they were.

### 6.3 Machines

Each enrolled machine has an entry naming it, so the user sees which machines can read the vault
and notices a new one.

- The entry is `/.tsync-ext/vault/machines/<client uuid>`
  ([03](../03-journal-sync.md)), sealed under K like a record (§5, extension name `vault`):
  `{"name", "enrolled", "lastUnlock", "seen", "modified"}`, epoch seconds but for `name`, which
  is the host's name (1 to 256 bytes) until the user gives another (`tsync vault machines --name
  NAME`, action `vault_machines` with `name`). `seen` lists the client uuids of the entries this
  machine has acknowledged; a reader takes it as empty when absent.
- A machine writes its entry at init, at a re-key, and at an unlock that enrolls it, and refreshes
  `lastUnlock` at an unlock when it is a day old. `lock --forget` removes it.
- `tsync vault machines` (action `vault_machines`, needs K) lists the entries by name, with when
  each enrolled and last unlocked, this machine marked (`machines`: `id`, `this`, and `name`,
  `enrolled`, `lastUnlock` for an entry that opens). Entries that do not open are listed by id.
- **A new machine.** An entry whose id is not in this machine's own `seen` is new to it. While the
  vault is unlocked, status lists the new ones' names under `newMachines`, and so does the
  domain's `status` ([08](../08-frontends.md)), from what the owner last read: at an unlock, a
  listing, a vault status, and when an entry arrives. The menu model shows a row for each
  ([menu-model §5](../frontends/menu-model.md#5-rows)), and an app's vault screen says it. Enrolling acknowledges the entries already
  there, and listing the machines acknowledges every one it shows: no clock decides what is new.
- The list is informative, not a control: any machine holding K can write an entry, and removing
  one revokes nothing. Revoking is a re-key (§7.2).

## 7. Rotation

- **Passphrase change.** `tsync vault passphrase` (action `vault_passphrase`) needs an unlocked,
  enrolled vault. It takes the new passphrase (`passphrase`, §2.2), adds a `secret-key` slot for
  it under the machine's secret key, removes every other `secret-key` slot, and writes the
  keyring. K and every record stay as they are, and so do the other machines' secret keys: they
  unlock with the new passphrase.
- **New secret key.** With `--new-secret-key` (`newSecretKey` in the action) the change also draws
  a new secret key, keys the new slot with it, keeps it on this machine and shows it once (§3
  step 4). Every other machine then needs the new secret key at its next unlock.
- A change does not revoke the old secrets from anyone who also holds an old keyring: the
  domain's versions keep the previous keyring
  ([05 §4.8](../05-ops-config.md#48-deleted-files-and-retention)), and its old slot wraps the
  same K. Revoking leaked secrets needs a new K.
### 7.1 Deleting the vault

`tsync vault delete` (action `vault_delete`) removes the domain's vault for good: the whole
`/.tsync-ext/` folder (the keyring and every extension's records), and this machine's keystore
entries.

- It needs no passphrase and no secret key: forgetting the passphrase is the reason to delete and
  start again. It is refused `invalid` unless the request names the domain again (`confirm`, the
  domain's name); the CLI asks for it on the terminal, an app asks the user to confirm in its own
  words, naming the domain and saying every record is lost.
- The files go first, then this machine's entries. An entry the keystore will not remove (one an
  earlier build of the program wrote, which macOS keeps for its owner) does not undo the delete:
  the reply says which entry is left and why, and the vault is gone.
- Other machines find the vault gone at their next arrival: they are locked, then have no vault
  and forget the K they held, in memory and in the keystore, the first time a verb or status
  reads the keyring absent.
- On a lazy tree, delete pulls the root and `/.tsync-ext/` first, so a vault made since the last
  pull is deleted rather than reported gone. Their secret key entries go when their user runs `lock --forget`
  or deletes there too.
- The files go the way any deleted file goes: in a versioned domain they stay in its versions
  until retention removes them ([05 §4.8](../05-ops-config.md#48-deleted-files-and-retention)),
  sealed, as they were.
- A client that does not use an extension of the domain is refused, as for every vault verb
  (README §3).

### 7.2 Re-key

`tsync vault rekey` (action `vault_rekey`) replaces K, the key id and the secret key. It is how a
lost or stolen machine is revoked: that machine holds the secret key and K, and a passphrase
change alone leaves both valid (§7).

- It needs an unlocked, enrolled vault and the passphrase (`passphrase`). It takes a new one
  (`newPassphrase`, §2.2) or keeps the current one; a CLI or app SHOULD suggest a new one when a
  machine was lost.
- It draws a new K, key id and secret key, writes a keyring holding one `secret-key` slot for
  them, and keeps the new secret key on this machine before anything else, so whatever follows
  fails, this machine can still unlock.
- It then re-encrypts every record under the old key id as §4.3 does for a copy's K, in every
  extension's folder, pulling each first on a lazy tree, and keeps the old K until it is done;
  then it keeps the new K (§6). A re-encryption that fails leaves the old K held, and is resumed
  at this machine's next unlock, with the new secret key; the reply then says why (`pending`). The
  old K is then written to the keystore whatever the policy (§6).
  Either way the reply carries the new secret key, shown once and offering the kit (§3.1). The
  appearance (§8.1), unsealed, stays.
- It rewrites the machine list (§6.3) with this machine alone.
- Every other machine is locked when it sees the new keyring (§6) and is no longer enrolled: its
  unlock asks for the new secret key, and status says its secret key was replaced
  (`secretKeyReplaced`). A machine that
  wrote records under the old K before it saw the new keyring re-encrypts them at its next unlock
  (§4.3).
- **What it protects:** every record from then on, and the current body of every record. The
  domain's versions keep earlier bodies under the old K
  ([05 §4.8](../05-ops-config.md#48-deleted-files-and-retention)): whoever kept the old K reads
  those until retention removes them.
- Two re-keys racing leave two keyrings of different key ids, which §4.3 settles.

## 8. Commands

Every verb needs a serving owner ([README §6](README.md#6-commands-and-actions)): K may live
only in the owner's memory. Offline, `status` and `unlock` read the last view of the keyring;
`init`, `passphrase` and `delete` need the current one
([README §4.1](README.md#41-where-they-live)). An unlock checked against the last view lets a
passphrase that another machine has since replaced unlock this one until it pulls again: it still
needs this machine's secret key, so it grants nothing this machine did not already hold.

| verb / action | needs K | does |
|---|---|---|
| `init` / `vault_init` | — | §3 |
| `unlock` / `vault_unlock` | — | §6 |
| `lock` / `vault_lock` | — | §6; with `reason: "screen"`, §6.2 |
| `passphrase` / `vault_passphrase` | yes | §7 |
| `delete` / `vault_delete` | — | §7.1 |
| `rekey` / `vault_rekey` | yes | §7.2 |
| `kit` / `vault_kit` | — | §3.1 |
| `machines` / `vault_machines` | yes | §6.3 |
| `status` / `vault_status` | — | initialised or not; key id; locked or unlocked; enrolled or not; where K is cached (`keystore`, `memory`); the auto-lock policy in force and where each part comes from (§6.2), and `lockedBy`; slot count by kind; unusable slots; keyring copies; the appearance (§8.1). Each extension's `list` reports its records that do not open, under another key or CORRUPT, by id |
| `appearance` / `vault_appearance` | yes | §8.1 |

`vault_init`, `vault_rekey`, `vault_kit`, and `vault_passphrase` with a new secret key, are the
only replies that carry a secret: the secret key.

- `init`, `unlock`, `passphrase`, `rekey` and `kit` derive keys at up to the limits of §4.2 and init resyncs the
  domain first, so each is a bulk action
  ([07 §4.3](../07-daemon-cli.md#43-deadlines-bulk-actions-and-the-liveness-probe)): a reply that timed out while the work went on would lose the
  secret key init and a re-key show once.
- The keyring's fold (§4.3) runs where this client may write the domain. On a read-only domain
  status and unlock read the keyring as it is, copies and all.

Refusals: init over a keyring EXISTS (`exists`); unlock or passphrase with no keyring ABSENT
(`not_found`), with a CORRUPT keyring `internal` (status answers both as a state); a passphrase
shorter than §2.2 allows, a malformed secret key, or no secret key on a machine not enrolled
INVALID (`invalid`); a wrong passphrase or a wrong secret key DENIED (`denied`), each saying which;
a passphrase change on a locked or not enrolled vault `locked`.

### 8.1 Appearance

A machine may show several domains' vaults side by side: every picker that lists codes, logins or
passkeys names each row's domain ([README §6.1](README.md#61-several-domains)). The appearance
lets the user tell the vaults apart at a glance; it marks a vault, never a record.

- **A colour, always.** Without a choice, it is the key id's: `palette[k mod 10]`, `k` the key
  id's first byte, from the palette `#2563eb #dc2626 #16a34a #9333ea #ea580c #0d9488 #db2777
  #ca8a04 #4f46e5 #475569`. Every machine computes the same colour with nothing written, and two
  vaults rarely share one. The user may choose another, `#rrggbb`.
- **An icon, if the user gives one:** stored as a square PNG, at most 256 pixels a side and 64
  KiB, told by its signature and its IHDR chunk; the owner refuses anything else INVALID.
- **Any image becomes one in the client**, which has the platform's decoder and sends only the
  stored form: the owner's socket takes a request of at most 1 MiB, less than a photo. The CLI,
  where the build links FFmpeg, takes a file or an `http(s)` URL: it sends a PNG already in the
  stored form as it is, and otherwise the image's first frame as shown (turned as its display
  matrix asks), its centre square scaled to 256 pixels, halved until its PNG fits 64 KiB. A build
  without FFmpeg takes only the stored form, and says so. An app converts with its platform's
  image API.
- **The mark** is the icon when there is one; otherwise tsync's icon in the vault's colour.
- **Where it is drawn:** beside a vault's name, at the level that names the vault, never on a
  record's row. A picker listing one domain's records draws no mark; one listing several groups
  the rows by domain under a header naming it, and the header carries the mark. A sheet that
  names the domain an item is saved to or read from draws the mark beside that name when the
  machine has several. A screen about the vault itself (its settings, its status) draws it as
  its own. Everything else about a row stays as it is.
- **Where it lives:** `/.tsync-ext/vault/appearance/appearance`, a JSON object `{"color"?,
  "icon"? (base64), "modified"}`, in a folder of its own so the keyring's fold (§4.3) never takes
  it for a copy. It is **not sealed**: a locked vault's rows need it, and it holds nothing secret.
  An icon is readable by whoever reads the store; it should not be a sensitive image.
- **Concurrent changes:** a reader takes the newest of the file and its conflicted copies by
  `modified`, passing over one that does not read; a write replaces the file and removes the
  copies.
- **Changing it** (`tsync vault appearance --color C | --default-color, --icon IMAGE | --no-icon`,
  action `vault_appearance`: `color` and `icon` each a string to set, `null` to clear, absent to
  keep) is a vault write: it needs an unlocked vault, like every verb that changes the vault.
- `vault_status` answers `appearance`: `color` (the one in force), `colorChosen`, and `icon`
  (base64) when there is one; none without a keyring.

## 9. Parameters

| name | value | rule |
|---|---|---|
| `VAULT_KDF_MEM` / `VAULT_KDF_ITERATIONS` / `VAULT_KDF_PARALLELISM` | 64 MiB / 3 / 1 | writers' recommended values (RFC 9106 second recommendation) |
| `VAULT_KDF_MIN_MEM` | 19 MiB | writers MUST NOT go below |
| `VAULT_KDF_MAX_MEM` / `VAULT_KDF_MAX_ITERATIONS` / `VAULT_KDF_MAX_PARALLELISM` | 256 MiB / 10 / 4 | readers refuse above; MUST fit the smallest host that unlocks |
| `VAULT_MAX_SLOTS` | 8 | slots one unlock derives for |
| `VAULT_MIN_PASSPHRASE` | 16 | characters of a chosen passphrase |
| `VAULT_KEYSTORE_RETRY` | 60 s | between reads of a keystore whose last read failed (§6.1) |

## 10. Conformance

- Argon2id and XChaCha20-Poly1305 reproduce the test vectors of RFC 9106 §5.3 and of
  draft-irtf-cfrg-xchacha appendix A.
- A secret key prints as 26 characters in groups `5-5-5-5-6`; its input survives upper case,
  spaces, missing dashes and the `i l o` substitutions; a 25- or 27-character input or one with
  non-zero padding bits is refused before derivation.
- A passphrase of 15 characters is refused before derivation, one of 16 accepted, and one with
  surrounding spaces derives like the same without them; `Ünïcode passphrase` and its NFD form
  are two passphrases.
- The right passphrase with the wrong secret key fails as "wrong secret key" without a
  derivation; the right secret key with the wrong passphrase fails as "wrong passphrase"; either
  secret alone, in any slot, derives nothing that unwraps K.
- A machine not enrolled is refused unlock without the secret key, and unlocks with both; after a
  lock it unlocks with the passphrase alone; after a lock with `forget` it needs both again.
- A change with a new secret key shows it once; another machine enrolled with the old one is
  refused "wrong secret key" until given the new one.
- Init on a domain with no extension, offline, or over an existing keyring is refused and writes
  nothing. After init the store holds a keyring and no plaintext key or passphrase.
- Unlock with the passphrase succeeds; any other passphrase fails as "wrong passphrase"; a slot
  above a `VAULT_KDF_MAX_*` limit, with `parallelism` 0 or with `memKiB` 1 is skipped and reported
  without being derived; a ninth slot is skipped.
- Writing the keyring twice with the same content gives identical bytes. A keyring with an
  unknown slot kind and unknown members unlocks through its known slot, and keeps the unknown
  slot through a rewrite.
- Two clients each add a slot concurrently: after both fold, the keyring holds both slots and no
  copy, and no further copy appears.
- Two clients init concurrently: the second keyring stays as a reported copy; after the second
  machine unlocks with the first's passphrase and secret key, its records open under the domain's K, the copy is
  gone, and no record was lost.
- An envelope with a flipped bit, another magic, or moved into another extension's folder does
  not open, is reported CORRUPT and is never overwritten. Two writes of one plaintext give two
  bodies.
- With `idleMinutes: 1`, the vault locks a minute after the last code was read and not before;
  a listing that needs no K does not keep it unlocked. With `maxHours: 1`, it locks an hour after
  the unlock while codes are read every minute. Status then says `lockedBy` `idle` or `age`.
- A `vault_lock` with `reason: "screen"` locks a domain whose policy sets `onScreenLock` and
  leaves one without a policy unlocked.
- A main stating `idleMinutes: 10` and a domain configuring 30 lock after 10; configuring 5
  locks after 5. A domain configuring `onScreenLock` behind a main that states nothing locks on
  the screen lock.
- With a policy in force, unlock leaves no K entry in the keystore, and an owner restart finds
  the vault locked; a policy learned after an unlock deletes the entry.
- `kit` with the passphrase answers the secret key the machine is enrolled with, and with another
  passphrase is DENIED and answers nothing; the CLI's file has mode 0600 and holds the spelling
  and a QR code that decodes to it.
- A second machine's unlock that enrolls it is listed by `machines` on the first, which reports it
  once in `newMachines`; `lock --forget` on the second removes its entry.
- After `rekey`, every record opens under the new key id and none under the old; another machine
  is refused "wrong secret key" with the old secret key and unlocks with the new one; `machines`
  lists the re-keying machine alone; a record the other machine wrote under the old K before it
  saw the new keyring opens under the new key id after its unlock.
- A keyring replaced by one with another key id locks the machine; it writes no record until it
  is unlocked with that keyring's secrets.
- After a passphrase change, only the new passphrase unlocks the current keyring, with the same
  secret key, and every record still opens.
- Delete without the domain's name is refused and changes nothing; with it, the domain has no
  vault and no record, this machine has no keystore entry, init then succeeds, and another
  machine finds itself without a vault after its next arrival.
- Lock removes K: a restart of the owner finds the vault locked.
- On a host with a keystore, a restart of the owner after an unlock finds the vault unlocked with
  `cached: keystore`, and after a lock finds it locked, still enrolled, with no K entry left; on a
  host without one, a restart finds it locked and not enrolled, and status said `cached: memory`.
- An envelope whose key id is altered does not open under K. With no keyring copy naming that
  key id it is reported CORRUPT, not under another key.
- Two machines holding a losing keyring's K both unlock with the domain's secrets: every record
  ends under the domain's K, one file per record, after the folds.

## 11. Later

- **Quick unlock**: Touch ID, Android biometrics or fprintd unlocking a vault that auto-lock
  (§6.2) locked, from a keystore entry the platform releases only after the user's biometric.
  Such an entry needs the user present, so the owner cannot read it at start (§6.1).
- **Per-machine slots**: a key each machine keeps, wrapping K in a slot of its own, so the machine
  list (§6.3) is a control and a re-key reaches the remaining machines without the new secret key
  being typed on each.
