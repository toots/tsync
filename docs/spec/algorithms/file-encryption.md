# File encryption

This file is normative. It owns how a domain encrypts file contents before they reach the store:
which files are encrypted, the keys, how chunks are sealed and named, the manifest that marks an
encrypted file, switching a file either way, and what every part of tsync does with an encrypted
file.

## 1. Problem

The store's provider reads every object a domain writes
([security-model §3.1](security-model.md#31-non-goals)). The vault already keeps a key the store
never sees ([vault](../extensions/vault.md)). File encryption seals a file's contents under that key
before upload, so the provider holds only ciphertext for it, while deduplication, partial uploads,
lazy reads, mirrors and garbage collection keep working on what it holds.

### 1.1 Non-goals

- **Names and structure.** A file's name, its folder, its size, its timestamps and the shape of the
  tree stay readable to the provider: they live in the log and the tree, not in a file's contents.
  Hiding them is left to a later version (encrypted folders), which this format leaves room for.
- **A new K.** Re-keying is not specified here ([vault §7.2](../extensions/vault.md#72-new-k)). The
  key id an encrypted manifest carries (§6) is there so a later version can.
- **History.** Encrypting a file does not rewrite its earlier versions (§4).

## 2. Turning it on

- A domain encrypts new files when its main states **`encryptFiles: true`**. It is a domain-wide
  setting ([05 §2.1](../05-ops-config.md#21-schema-and-validation), rules 1 to 4): every client of
  one main uses the value the main states, and a client configuring another value is refused by
  rule 3. Behind an http-proxy the server's value holds.
- `encryptFiles` needs the domain's vault. A domain stating it uses the vault even when it lists no
  extension ([extensions README §3](../extensions/README.md#3-opting-in)).
- **Setup always asks, and the default is off.** Every frontend that creates a domain (`tsync init`,
  the macOS setup, the Android first connection to a server whose domain does not state it yet)
  offers *Encrypt new files*, unchecked. Choosing it creates the vault as part of setup
  ([vault §3](../extensions/vault.md#3-initialising)). Nothing turns it on by itself.
- It can be turned on later, and off again. Either applies to files whose first version is written
  from then on (§3). A file keeps what it is: a plain file stays plain and an encrypted file stays
  encrypted, until a user switches it (§4).

## 3. Which files are encrypted

- **A new file** is encrypted when its first version is written while the domain states
  `encryptFiles: true`. The decision is taken when the version's content is sealed for upload
  ([publication](publication.md), upload first): a file created before the client has learned the
  setting waits, staged, until it has, and is never uploaded plain by default.
- **Encryption is sticky.** A new version, a rename, a move, or a copy within the domain of an
  encrypted file stays encrypted, whatever the setting is now. A plain file stays plain.
- A **symlink** is never encrypted: its target is a name (§1.1).
- A **conflicted copy** keeps the encryption of the version it was made from.

## 4. Encrypting or decrypting a file

With the domain stating `encryptFiles: true`, a user can switch a file either way:

| Where | How |
|---|---|
| CLI | `tsync encrypt PATH…`, `tsync decrypt PATH…`; a folder recurses |
| macOS | Finder's context menu, *Encrypt* or *Decrypt*, beside *Copy Share URL* |
| Linux | Dolphin's context menu, the same entries |
| Android | The item's long-press menu, beside *Share link* |

- Switching writes a new version of the file: the same bytes, sealed (`tsyncm04`) or plain
  (`tsyncm03`). It needs an unlocked vault (§8), reads the whole file and uploads every chunk once.
  It is a write like any other: it publishes, conflicts and is versioned as one.
- **Earlier versions keep what they were.** Encrypting a file leaves its plain versions in the
  domain's history until retention removes them; the command and the menu say so, and
  `tsync expire` can remove them sooner ([05 §4.8](../05-ops-config.md#48-deleted-files-and-retention)).
  Decrypting leaves the encrypted versions.
- A menu shows only the entry that applies: *Encrypt* on a plain file, *Decrypt* on an encrypted
  one, neither on a symlink or when the domain does not state `encryptFiles`. A folder offers both,
  for what it holds.

## 5. Keys

Three keys are derived from the vault's K with keyed BLAKE2b-256 (RFC 7693), each with its own
context:

| key | derivation | use |
|---|---|---|
| `Kc` | `BLAKE2b-256(key = K, "tsync-file-chunk-key")` | seals chunks |
| `Kn` | `BLAKE2b-256(key = K, "tsync-file-chunk-nonce")` | derives each chunk's nonce |
| `Km` | `BLAKE2b-256(key = K, "tsync-file-manifest-mac")` | authenticates a manifest |

They are derived when the vault is unlocked and forgotten with K; none is written anywhere
([security-model §10.6](security-model.md#106-vault-keys-and-passphrases)).

## 6. Chunks

- An encrypted file is cut exactly as a plain file is ([01 §3.4](../01-core.md#34-fixed-size-chunking)):
  chunk `i` holds plaintext bytes `[i·chunk_size, …)`.
- **Sealing is deterministic.** For a plaintext chunk `p`:
  - `nonce = BLAKE2b-192(key = Kn, p)`;
  - `body = nonce ‖ XChaCha20-Poly1305-Seal(Kc, nonce, p, ad = "tsync-file-chunk/" key_id)`;
  - the body is `len(p) + 40` bytes. Equal plaintext chunks of the domain seal to equal bodies.
- **A sealed chunk is named like any chunk**, by the dual digest of its bytes
  ([02 §2.1](../02-remote-model.md#21-digests)): here the sealed bytes. Equal sealed bodies
  deduplicate, and a new version uploads only the chunks whose plaintext changed. Sealed and plain
  chunks share the key space and never collide in a way that matters: they digest different bytes.
- **Anyone can check a sealed chunk against its key without K**: garbage collection, mirrors,
  replicas, `data-integrity` and an http-proxy server work on sealed chunks unchanged.
- **Authenticity comes from the tag**, not the digest, which is not cryptographic
  ([security-model §3.1](security-model.md#31-non-goals)). A body whose tag fails is damaged
  (CORRUPT), never content.
- The nonce is keyed with `Kn`, so holding a file does not let anyone confirm that the domain
  stores it.

## 7. Manifest: binary `tsyncm04`

An encrypted file's manifest is a `tsyncm04` body. A plain file's stays `tsyncm03`, byte for byte
([02 §2.6](../02-remote-model.md#26-file-manifest-binary-tsyncm03)); every manifest written before
this version reads as before.

```
off  len  field
0    8    magic "tsyncm04"
8    64   size, mtime, chunk_size, count, name_len, link_len, h1, h2: as tsyncm03 at 8 … 71
72   4    flags       unsigned 32-bit; bit 0 = encrypted (always set); other bits 0
76   16   key_id      ASCII lowercase hex, the vault key id (vault §2)
92   32   mac         BLAKE2b-256(key = Km, the body with mac zeroed and the name bytes left out)
124  name_len         leaf name bytes, recorded at write time
..   count × 33       chunk keys of the sealed chunks, in index order
```

- **Reader.** A body with magic `tsyncm04` MUST be rejected as malformed if it is shorter than 124
  bytes, has `size < 0`, `link_len ≠ 0`, a `flags` value other than 1, or a length other than
  `124 + name_len + 33 × count`. `size` is the plaintext size; chunk `i` covers plaintext bytes as
  in tsyncm03, and its sealed body is 40 bytes longer.
- **Digests.** `h1`/`h2` are computed as for tsyncm03 from the sealed chunks' keys and sealed
  lengths. They identify the sealed content: the same plaintext under the same K gives the same
  digests, so "same content" holds between encrypted versions as between plain ones, and never
  between a plain and an encrypted version.
- **The MAC** covers every byte but the recorded name and itself: the size, mtime, chunk size,
  count, digests, flags, key id and every chunk key. A reader with K MUST check it before reading
  any chunk and reject a body that fails (CORRUPT): the provider cannot swap, reorder, drop or
  truncate an encrypted file's chunks, nor change its size. The name is left out because a body
  copied to a new location keeps its old name until it is re-put (02 §2.6).
- **A reader without K** (a locked vault, a server without the key) reads the header and the keys,
  so listing, stat, versions, garbage collection, mirroring and data-integrity work. It cannot read
  the contents (§8).
- **A reader that does not know `tsyncm04`**, an earlier build, rejects it as "not a manifest". It
  never serves sealed bytes as a file's content. All clients of a domain are updated together.

## 8. Reading, writing and a locked vault

- **Writing** an encrypted file (a new one under `encryptFiles`, a new version of an encrypted one,
  or `encrypt`) seals each chunk before upload and writes `tsyncm04`. On a locked vault the
  content stays staged and the upload waits; it is never uploaded plain, and the file is reported
  as waiting for the vault ([05 §3](../05-ops-config.md), status).
- **Reading** fetches sealed chunks and opens them with `Kc` after the manifest's MAC. The chunk
  cache keeps sealed bodies, as fetched ([data-model/local-cache](../data-model/local-cache.md)):
  plaintext exists on disk only where a frontend already keeps a file's local copy (a materialised
  Finder file, Linux's full tree, a file kept offline on Android).
- **Unlocking is always an explicit act of the user** in tsync's own tools: `tsync vault unlock`,
  the macOS menu's *Unlock…*, the Android Vault screen. Opening a file never prompts for the
  passphrase, and no frontend unlocks on a file's behalf
  ([extensions README §5](../extensions/README.md#5-host-adapters)).
- **On a locked vault** a file whose content is local opens; one that needs a fetch fails LOCKED
  (`locked`), which each frontend reports its own way: an error naming the vault in Finder,
  `EACCES` in FUSE, a refused open in the Android documents provider. Listing and stat work.

## 9. Elsewhere

- **The http-proxy server** relays sealed chunks and `tsyncm04` manifests without the key, always.
- **Shares and streaming** of an encrypted file (share links, folder archives, HLS playlists)
  serve its plaintext only while the server's own vault is unlocked, by `tsync vault unlock` run
  on the server. Nothing unlocks a server by itself: not a start, not a share. A server with no
  keystore holds K in memory only, and is locked again by any restart. While locked, such a share
  answers that the file is locked, and the share's page says so; plain files' shares are unaffected.
- **`tsync status`** says, per domain, whether `encryptFiles` is stated, whether the vault is
  unlocked on this machine, and how many uploads wait for it.
- **Versions, expire and gc** see sealed chunks and `tsyncm04` bodies as ordinary chunks and
  manifests.
- **Export and rsync out** write plaintext, and need an unlocked vault for an encrypted file.
- **Data integrity** checks sealed chunks against their keys without K; with an unlocked vault it
  also checks each encrypted manifest's MAC.

## 10. What the provider learns

Per encrypted file: its name, folder, size, timestamps, chunk count, the key id, and which of its
chunks equal another sealed chunk of the domain. Never a byte of its contents, nor whether it
equals a file the provider holds.

## 11. Conformance

- A chunk sealed twice under one K gives the same body; under two K, two bodies with no key in
  common. A body with one byte changed fails its tag and reads CORRUPT.
- A `tsyncm03` manifest written before this version reads, and its file opens, with
  `encryptFiles` on or off.
- With `encryptFiles: true`, a new file is uploaded as `tsyncm04` with sealed chunks; a new version
  that changes one chunk uploads one chunk. With it turned off, a new version of that file is
  still encrypted; a new file is plain.
- `tsync encrypt` of a plain file writes a `tsyncm04` version with the same plaintext; its plain
  version stays in history. `tsync decrypt` writes it back as `tsyncm03`.
- A `tsyncm04` body with a chunk key swapped for another sealed chunk's, or its size changed,
  fails the MAC and reads CORRUPT on a client with K.
- With the vault locked: listing and stat of an encrypted file work, opening one not cached fails
  LOCKED on every frontend, a new encrypted file stays staged, and no plaintext reaches the store.
- An http-proxy server whose vault is locked serves a plain file's share and refuses an encrypted
  file's with "locked"; after `tsync vault unlock` on the server it serves both.
- An earlier build reading a `tsyncm04` manifest reports it malformed and serves nothing.
