# File encryption

This file is normative. It owns how a domain keeps file contents unreadable to the storage layer:
which files are encrypted, the keys, how chunks are sealed and named, the manifest that marks an
encrypted file, switching a file either way, and what every part of tsync does with an encrypted
file.

## 1. Goal and threat model

**Encryption keeps the storage layer from reading a file's contents.** The storage layer is
whoever can read the objects a domain writes, chunks and manifests: in practice a third-party
storage platform and its operators. It is assumed able to read every object and to write any
object, and is never given a key.

Trusted, as for any domain ([security-model](security-model.md)):

- **The user's machines** (every client of the domain) and **the user's http-proxy server**. They
  hold plaintext where their role keeps files today; that is not a leak.

Out of scope, here as for plain files ([security-model §3.1](security-model.md#31-non-goals)):

- **Integrity against the storage layer.** A storage layer that writes objects can delete files,
  roll a file back to an older version, put one file's valid manifest at another's place, serve
  different states to different clients, or damage chunks. Encryption does not prevent that; it
  only ensures that none of it reveals a byte of an encrypted file (§3.2).
- **Names and structure.** A file's name, its folder, its size, its timestamps and the shape of the
  tree stay readable to the storage layer: they live in the log and the tree. Hiding them is left
  to a later version (encrypted folders), which this format leaves room for.
- **A leaked K.** A re-key ([vault §7.2](../extensions/vault.md#72-re-key)) seals what is written
  from then on under a new K, and keeps the old K as a retired key
  ([vault §4.1](../extensions/vault.md#41-format)) so the files sealed under it stay readable:
  they are not re-sealed. Whoever holds a leaked K reads every file sealed under it, and every
  version, until those files are rewritten and their versions expire.
- **Clients that are not updated.** A build that does not know this file writes new files plain
  and cannot read encrypted ones. Every client of a domain is updated together; keeping them so is
  the user's.

## 2. Turning it on

- **`encryptFiles`** is a domain-wide setting ([05 §2.1](../05-ops-config.md#21-schema-and-validation)):
  - behind an http-proxy main, the server states it in `/domain-settings`
    ([backends/http-proxy §8.4](../backends/http-proxy.md#84-capabilities)) and every client uses
    the server's value; a client configuring another value is refused (05 rule 3);
  - on a plain store, which states nothing (05 rule 2), each client's own config decides, and every
    client of the domain MUST configure the same value. Setup writes it explicitly, true or false.
- **Setup always asks, and the default is off.** Every frontend that creates a domain or its first
  client config (`tsync init`, the macOS setup) offers *Encrypt new files*, unchecked. Choosing it
  creates the vault as part of setup ([vault §3](../extensions/vault.md#3-initialising)) if the
  domain has none. The Android app follows its server and offers nothing. Nothing turns it on by
  itself.
- `encryptFiles: true` gives the domain a vault even when it lists no extension
  ([extensions README §3](../extensions/README.md#3-opting-in)), and so does a keyring already in
  the store: turning `encryptFiles` off never takes the vault verbs away from a domain whose
  encrypted files need them.
- It can be turned on later, and off. Either applies to files whose first version is written from
  then on (§3). **Turning it off while encrypted files exist is the user's choice:** they stay
  encrypted and readable with the vault, and can no longer be decrypted (§4) until it is on again.
  The docs say to decrypt them first.

## 3. Which files are encrypted

### 3.1 The rule

- **A new file** is encrypted when its first version is written while the domain uses
  `encryptFiles: true`. Behind an http-proxy main, a client that has not yet learned the server's
  settings holds a new file's first version, staged, until it has: a setting not yet learned is
  never read as false. A server that answers without stating it (one older than this version,
  [backends/http-proxy §8.4](../backends/http-proxy.md#84-capabilities)) has no file encryption:
  its absence is `false`, and status says the server does not support it.
- **A file keeps what it is.** A new version, a rename, a move, or a copy within the domain of an
  encrypted file stays encrypted; of a plain file, plain. A switch (§4) is the only change.
- A **symlink** is never encrypted: its target is a name.
- A **conflicted copy** keeps the encryption of the version it was made from: a copy of a plain
  version that was already published hides nothing by being sealed, and needs no vault.

### 3.2 A downgrade is never written plain

A storage layer can put a `tsyncm03` manifest, which carries no MAC, at the place of an encrypted
file: the file's own plain version from before it was encrypted, for instance. Writing the next
edit by "a plain file stays plain" would then upload it plain.

- Each client keeps, per file it has seen, whether it has seen it encrypted (a `tsyncm04` body
  with bit 0 set). A client that then finds a `tsyncm03` value for that file treats it as a
  **downgrade**: it writes the next version encrypted, and reports the file ("this file was
  encrypted and now reads plain; its next version is encrypted").
- A deliberate decryption (§4) writes a **plain `tsyncm04`** (bit 0 clear), whose MAC only a holder
  of K can produce and which names the encrypted version it decrypts (`from`, §7). It lifts the
  record only on a client with K whose MAC check passes and whose last encrypted version of that
  file is the one `from` names: a plain `tsyncm04` replayed at another file's place, or at this
  file's place over a later encrypted version, lifts nothing. A locked client keeps the record.
- What remains: a file a client has never seen encrypted, replaced before the client first reads
  it. The client then writes it as the plain file it appears to be.

## 4. Encrypting or decrypting a file

While the domain uses `encryptFiles: true`, a user can switch a file either way:

| Where | How |
|---|---|
| CLI | `tsync encrypt PATH…`, `tsync decrypt PATH…`; a folder recurses |
| macOS | Finder's context menu, *Encrypt* or *Decrypt*, beside *Copy Share URL* |
| Linux | Dolphin's context menu, the same entries |
| Android | The item's long-press menu, beside *Share link* |

- **Encrypt** writes a new version with the same bytes, sealed (`tsyncm04`, bit 0 set). **Decrypt**
  writes a new version with the same bytes plain, as a plain `tsyncm04` (bit 0 clear, §3.2). Either
  needs an unlocked vault, reads the whole file and uploads every chunk once. It is a write like
  any other: it publishes, conflicts and is versioned as one.
- **Earlier versions keep what they were.** Encrypting a file leaves its plain versions in the
  domain's history until retention removes them; the command and the menu say so, and
  `tsync expire` can remove them sooner ([05 §4.8](../05-ops-config.md#48-deleted-files-and-retention)).
- **A switch can race an edit** on another machine, as any two writes do: the main's value keeps
  the name and the other becomes the conflicted copy, which keeps its own encryption (§3.1).
  `encrypt` reports, after its commit, any file under its
  paths that still reads plain.
- A menu shows only the entry that applies: *Encrypt* on a plain file, *Decrypt* on an encrypted
  one, neither on a symlink or while the domain does not use `encryptFiles`. A folder offers both,
  for what it holds.

## 5. Keys

Three keys are derived from the vault's K with keyed BLAKE2b (RFC 7693) whose output length is 32
bytes, set in the parameter block (not a truncated longer output), each over its own context:

| key | derivation | use |
|---|---|---|
| `Kc` | `BLAKE2b(outlen = 32, key = K, "tsync-file-chunk-key")` | seals chunks |
| `Kn` | `BLAKE2b(outlen = 32, key = K, "tsync-file-chunk-nonce")` | derives each chunk's nonce |
| `Km` | `BLAKE2b(outlen = 32, key = K, "tsync-file-manifest-mac")` | authenticates a manifest |

They are derived when the vault is unlocked and forgotten with K; none is written anywhere
([security-model §10.6](security-model.md#106-vault-keys-and-passphrases)).

## 6. Chunks

- An encrypted file is cut exactly as a plain file is ([01 §3.4](../01-core.md#34-fixed-size-chunking)):
  chunk `i` holds plaintext bytes `[i·chunk_size, …)`.
- **Sealing is deterministic.** For a plaintext chunk `p`:
  - `nonce = BLAKE2b(outlen = 24, key = Kn, p)`;
  - `body = nonce ‖ XChaCha20-Poly1305-Seal(Kc, nonce, p, ad = "tsync-file-chunk/" key_id)`, `key_id`
    in its 16 lowercase hex characters ([vault §2](../extensions/vault.md#2-keys));
  - the body is `len(p) + 40` bytes. Equal plaintext chunks of the domain seal to equal bodies.
- **Opening** checks the tag, then derives the nonce again from the plaintext and checks it equals
  the body's: a body sealed with any other nonce does not open.
- **A new version is sealed under the current K.** Of a file sealed under a retired key, its
  inherited chunks are opened and sealed again: the first edit after a re-key uploads every chunk
  once.
- **A sealed chunk is named like any chunk**, by the dual digest of its bytes
  ([02 §2.1](../02-remote-model.md#21-digests)): here the sealed bytes. Equal sealed bodies
  deduplicate, and a new version uploads only the chunks whose plaintext changed. Sealed and plain
  chunks share the key space and never collide in a way that matters: they digest different bytes.
- **Anyone can check a sealed chunk against its key without K**: garbage collection, mirrors,
  replicas, repair, `data-integrity` and an http-proxy server work on sealed chunks unchanged, on
  every backend.
- **A sealed chunk that does not open** (its tag, or its nonce, fails) while its bytes match its key
  is not damage a copy can mend: every copy is the same bytes. It is reported against the file as
  CORRUPT `sealed` and is not a repair target ([05 §4.10](../05-ops-config.md#410-integrity)); a
  chunk whose bytes do not match its key is damage as for any chunk, and is repaired as one.
- The nonce is keyed with `Kn`, so holding a file does not let anyone without K confirm, from the
  store alone, that the domain holds it (§10).

## 7. Manifest: binary `tsyncm04`

The manifest of an encrypted file, or of a file decrypted on purpose (§3.2), is a `tsyncm04` body.
Every other file's stays `tsyncm03`, byte for byte
([02 §2.6](../02-remote-model.md#26-file-manifest-binary-tsyncm03)); every manifest written before
this version reads as before.

```
off  len  field
0    8    magic "tsyncm04"
8    64   size, mtime, chunk_size, count, name_len, link_len, h1, h2: as tsyncm03 at 8 … 71
72   4    flags       unsigned 32-bit; bit 0 = encrypted; other bits 0
76   16   key_id      ASCII lowercase hex, the vault key id (vault §2)
92   32   mac         BLAKE2b(outlen = 32, key = Km, the body with mac zeroed and the name bytes left out)
124  name_len         leaf name bytes, recorded at write time
..   count × e        chunk entries, in index order: the chunk key (33 bytes), then, when bit 0 is
                      set, the chunk's 24-byte nonce (e = 57); with bit 0 clear, e = 33
..   32               from, with bit 0 clear only: h1 then h2 of the version decrypted (§3.2)
```

- **Reader.** A body with magic `tsyncm04` MUST be rejected as malformed if it is shorter than 124
  bytes, has `size < 0`, `link_len ≠ 0`, a flag bit other than bit 0, a `key_id` that is not 16
  lowercase hex characters, or a length other than `124 + name_len + e × count` (+ 32 with bit 0
  clear, below), computed without overflow. `size` is the plaintext size; with bit 0 set, chunk `i` covers
  plaintext bytes as in tsyncm03 and its sealed body is 40 bytes longer.
- **`from`**, with bit 0 clear only: 32 bytes after the chunk entries, the `h1` and `h2` of the
  encrypted version this one decrypts, as its header carries them (§3.2). The MAC covers it.
- **Which K.** `key_id` names the vault's K or one of its retired keys
  ([vault §4.1](../extensions/vault.md#41-format)); the file's keys (§5) derive from that K. A
  `key_id` the keyring does not hold is CORRUPT `sealed`: no machine can open it.
- **Digests.** `h1`/`h2` are computed as for tsyncm03 from the chunk keys and the stored lengths
  (sealed lengths when encrypted). The same content under the same K gives the same digests, so
  "same content" holds between two encrypted versions as between two plain ones, and never between
  a plain and an encrypted one.
- **The MAC** covers every byte but the recorded name and itself: the size, mtime, chunk size,
  count, digests, flags, key id and every chunk entry, nonces included. It shows that a holder of K
  wrote the body as it is: a plain `tsyncm04` is a deliberate decryption (§3.2), and an encrypted
  one's chunks are the ones written, in their order, each bound to its body by its nonce. It does
  not bind a body to its place or version (§1). The name is left out because a body copied to a
  new location keeps its old name until it is re-put (02 §2.6). A reader with K checks the MAC
  before reading a chunk, and a reader that reads a chunk checks its bytes against its key and its
  nonce against the entry's.
- **A reader without K** (a locked vault) reads the header and the entries, so listing, stat,
  versions, garbage collection, mirroring and data-integrity work; the size it lists is the
  header's, checked only once the vault is unlocked. It cannot read the contents (§8).
- **A reader that does not know `tsyncm04`**, an earlier build, rejects it as not a manifest and
  serves nothing.
- Byte-exact test vectors, as 02 §2.6 has for tsyncm03, come with the implementation of this file.

## 8. Writing, reading and a locked vault

- **Adoption seals.** An encrypted file's version is sealed when the owner adopts it
  ([04 §4.3](../04-checkout-cache.md)): its chunk keys, `h1`/`h2` and content id are those of the
  sealed chunks from the start, so the before-guard, the no-op check and a frontend's content id
  agree with what is published. On a locked vault an encrypted version is not adopted: it stays
  staged, the write's caller is answered UNPREPARED/`locked`, and it is adopted once the vault is
  unlocked.
- **The upload job seals** a version whose keys it computes, as a byte-level write's are
  ([04 §4.6](../04-checkout-cache.md)): the write was answered at its `close`, and its bytes are
  the user's. On a locked vault the job does not run; the version waits, staged, counted in status
  as waiting for the vault, and is sealed and uploaded once the vault is unlocked. No write that
  was answered done is refused later, and nothing of either kind reaches the store plain.
- **No vault** (`encryptFiles: true` and no keyring, or a vault deleted): new and switched
  versions wait as on a locked vault, and status says the domain encrypts files but has no vault
  and how to make one (`tsync vault init`).
- **Reading** fetches sealed chunks and opens them with `Kc`, after the manifest's MAC. A sealed
  chunk is fetched whole, never by range: its tag covers the whole body, and no byte of it is
  served before the tag and the nonce check. A range read of an encrypted file fetches the chunks
  its range covers ([read-path-and-cache §4.4](read-path-and-cache.md#44-range-fill)).
- **The chunk cache keeps sealed bodies**, as fetched and as uploaded, named by their keys
  ([data-model/local-cache](../data-model/local-cache.md)): a group body of an encrypted file is
  the concatenation of its members' sealed bodies, member `i` at the sum of the sealed lengths
  before it. A staged body is plaintext, so promoting an encrypted version writes the sealed group
  into the cache instead of linking the staged body
  ([04 §4.7](../04-checkout-cache.md)); the slow path of an edit opens an Inherit member from its
  sealed cache body before copying it into the plaintext staged body (04 §4.3). Both need the K
  the version is sealed under, which its adoption already held.
- **Plaintext on the user's disk** exists where tsync keeps a file's bytes before sealing or after
  opening: staged bodies (an encrypted version waiting for the vault included), whole-file upload
  snapshots ([02 §4.1](../02-remote-model.md)), export and rsync temporaries, and every local copy a
  frontend keeps (a materialised Finder file, Linux's full tree, a file kept offline on Android).
  The user's machines are trusted (§1). **Locking the vault does not encrypt any of it**: it is not
  protection at rest, which is the disk's.
- **Unlocking is always an explicit act of the user** in tsync's own tools: `tsync vault unlock`,
  the macOS menu's *Unlock…*, the Android Vault screen. Opening a file never prompts for the
  passphrase, and no frontend unlocks on a file's behalf
  ([extensions README §5](../extensions/README.md#5-host-adapters)).
- **On a locked vault** a file whose content is local opens; one that needs a fetch fails
  UNPREPARED/`locked` ([failure-model](failure-model.md)), which each frontend reports its own way:
  an error naming the vault in Finder, `EACCES` in FUSE, a refused open in the Android documents
  provider. Listing and stat work.

## 9. Elsewhere

### 9.1 The http-proxy server

The server relays sealed chunks and `tsyncm04` manifests. It is trusted (§1) but holds no K: it
never opens an encrypted file. It states `encryptFiles` with its other settings (§2).

### 9.2 Sharing an encrypted file

A share link is the user's decision to make a file readable to whoever holds the link, and so to
the storage layer, which keeps what a share serves. It is never made implicitly.

- **The sharing machine decrypts.** `tsync share` of an encrypted file (or of a folder holding
  one), and the menus' *Copy Share URL*, ask once for confirmation naming the trade-off: *"Sharing
  stores a readable copy of this file in your storage until the link expires or is revoked."*
  Without it, nothing is shared. With it, the machine, whose vault MUST be unlocked, writes the
  plaintext artifacts the share serves into the share cache
  ([02 §2.14](../02-remote-model.md#214-share-manifest-json-and-share-artifacts)): the assembled
  file, a folder archive, an HLS playlist's segments as the share needs them.
- **Whoever serves the link needs no key**: a bucket's share function or the http-proxy server
  serves those artifacts as it serves any.
- **A preview image** of an encrypted file is made only for such a share, by the sharing machine,
  under the same confirmation.
- The artifacts are removed when the share expires or is revoked, as share artifacts are. A share
  of an encrypted file serves only the artifacts the sharing machine wrote, which name the version
  shared: whoever serves the link never assembles a `tsyncm04` file. An encrypted file edited
  after it was shared keeps serving the version shared until the user shares it again.

### 9.3 The rest

- **`tsync status`** says, per domain, whether it uses `encryptFiles`, whether the vault is unlocked
  on this machine, how many versions wait for it, and any downgrade found (§3.2).
- **Versions, expire and gc** see sealed chunks and `tsyncm04` bodies as ordinary chunks and
  manifests.
- **Export and rsync out** write plaintext, and need an unlocked vault for an encrypted file.
- **Data integrity** checks sealed chunks against their keys without K; with an unlocked vault it
  also checks each `tsyncm04` manifest's MAC and opens its chunks.
- **`tsync vault delete`** destroys K, and with it every encrypted file and version of the domain.
  While the domain holds encrypted files it asks a second confirmation naming how many, after the
  domain's name (`confirmFiles`, the count, [vault §7.1](../extensions/vault.md#71-deleting-the-vault)).
  It is the user's decision; tsync says what it costs. The domain then has no vault (§8).

## 10. What the storage layer learns

About an encrypted file, from the store alone:

- its name, folder, size, timestamps, chunk count and key id;
- which of its chunks equal another sealed chunk of the domain, and so which chunk ranges changed
  between two of its versions, and whether two encrypted files are equal (equal digests);
- which chunks are fetched, and when, as clients read lazily.

Never a byte of its contents. Without K it cannot tell whether the domain holds a file it knows,
unless it can make a holder of K store content of its choosing, in which case deduplication tells
it whether those chunks were there already.

## 11. Conformance

- A chunk sealed twice under one K gives the same body; under two K, bodies with no key in common.
  A body with one byte changed fails its tag; one sealed with another nonce fails the nonce check.
  Either is reported CORRUPT `sealed` and is not repaired.
- A `tsyncm03` manifest written before this version reads, and its file opens, with `encryptFiles`
  on or off; an edit of it stays `tsyncm03`.
- With `encryptFiles: true`, a new file is adopted and uploaded as `tsyncm04` with sealed chunks,
  and its content id at adoption equals its published `h1`; a new version that changes one chunk
  uploads one chunk. With it off, a new version of that file is still encrypted; a new file is
  plain.
- `tsync encrypt` of a plain file writes an encrypted `tsyncm04` version with the same plaintext;
  its plain version stays in history. `tsync decrypt` writes a plain `tsyncm04`.
- A client that saw a file encrypted and then reads a `tsyncm03` value for it writes the next
  version encrypted and reports a downgrade; after a plain `tsyncm04` from `decrypt`, it writes the
  next version plain.
- A `tsyncm04` body with a chunk entry swapped for another, its size changed or a flag flipped
  fails the MAC on a client with K.
- With the vault locked: listing and stat of an encrypted file work, opening one not cached fails
  UNPREPARED/`locked` on every frontend, a new encrypted version stays staged, and no plaintext
  reaches the store.
- Sharing an encrypted file without the confirmation shares nothing; with it, the share function
  serves the plaintext the sharing machine wrote, and revoking the share removes it.
- Behind an http-proxy main, a client that has not learned `encryptFiles` holds a new file; one
  that learned `true` encrypts it.
- An earlier build reading a `tsyncm04` manifest reports it malformed and serves nothing.
- After a re-key, a file sealed under the old K opens on every unlocked client and is not
  re-uploaded; its next edit is sealed under the new K. After two inits raced, the files the
  losing machine sealed open once its K is retired.
- A plain `tsyncm04` put at the place of another file, or over a later encrypted version of its
  own file, lifts no downgrade record; the next version is written encrypted.
- A server that answers `/domain-settings` without `encryptFiles`, or only `/chunk-size`, gets new
  files plain.
- A sealed chunk is never served from a range fetch; the cache holds an encrypted file's groups
  sealed, and promoting its version writes them sealed.
