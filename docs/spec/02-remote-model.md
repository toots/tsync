# 02 — The remote data model

This file owns every **byte-level format and key spelling** of what a domain stores on a backend, the
readers each format requires,
and the **remote interface** above the store: the content store, the manifest store, the tree reader
and history.

**Core** formats are frozen and MUST be read and written exactly as specified here, with no migration:
chunks and chunk keys, manifests, folder markers, anchors, trash entries, versions, and the journal and
cursor ([03-journal-sync.md](03-journal-sync.md)). **Ephemeral** formats (collection state and the lock
file, verify and discard jobs, corruption markers, share manifests and the share cache, the folder index)
MAY change when there is a real need.

Related: the entities, invariants and folder-identity protocol are in
[data-model/backend.md](data-model/backend.md); retention and garbage collection, including the
collection interlock, in [algorithms/gc.md](algorithms/gc.md); the hash function, chunking, chunk keys
and key grammar in [01-core.md](01-core.md); journal and cursor formats in
[03-journal-sync.md](03-journal-sync.md); the store contract in [06-backends.md](06-backends.md).
Implementation notes: [ocaml/02-remote-model.md](ocaml/02-remote-model.md).

---

## 1. Problem

tsync stores a user's tree on a key/value object store (S3, GCS, a local directory, or another tsync
over HTTP) that offers put, get, ranged get, head, delete, server-side copy, prefix listing and one
conditional write (create-if-absent). On top of it this layer provides:

- **Content-addressed, deduplicated file bodies.** A file is cut into fixed-size chunks named by the
  digest of their bytes; identical content is stored once per domain; an unchanged chunk is never
  re-sent.
- **A rename-stable directory tree.** Folders are identified by stable ids, not paths, so moving a
  folder rewrites a constant number of objects, never its descendants.
- **Lazy access.** A reader resolves a path with one read per segment, then fetches only the chunks, or
  byte ranges of chunks, it needs.
- **History** (versions, trash) and **integrity** (corruption markers).

Every layer above speaks **logical keys** (domain-relative paths); only this layer knows **stored keys**
(hashed, id-based) and the binary formats.

---

## 2. Formats and key spellings

### 2.1 Digests

The **dual digest** of a byte string is the chunk-key construction of [01-core.md](01-core.md) (XXH3-64
with seeds 0 and 1, each rendered as 16 lowercase hex characters, joined by `-`; 33 characters). It is a
non-cryptographic checksum. It names:

| Name | Input | Shape |
|---|---|---|
| chunk key | the chunk's bytes | dual digest |
| leaf hash (child key) | the leaf name's bytes | dual digest |
| manifest whole-file digest `h1`, `h2` | the concatenation, in chunk order, of `"<chunk key>-<length in decimal>;"` | `h1` = seed 0, `h2` = seed 1, each 16 hex, stored separately |
| symlink digest | the target's bytes | `h1` = seed 0, `h2` = seed 1 |

Test vectors:

```
dual("hello world") = d447b1ea40e6988b-b7aeb52a10fdaf2d
dual("")            = 2d06800538d394c2-4dc5b0cc826f6703   (the empty chunk)
dual("img.jpg")     = 066843ea47b80079-e0e3d2bb9b72c14d
dual("hello.txt")   = 285b8db6c3eef5e0-7b23aee4b1561b8f
dual("Photos")      = 857fcda0047eeab4-a677d171b8d38674
```

A name **is a chunk key** iff it is exactly 33 characters, `-` at index 16, and both halves are 16
characters of `[0-9a-f]`. Whenever a walk of a store decides to copy or delete, this test says what a
name is; membership in a space is decided by key prefix, never by the shape of the leaf alone.

### 2.2 Chunking facts the formats depend on

Chunking is specified in [01-core.md](01-core.md). The formats rely on: a regular file of size *s* cut
with chunk size *c* has `max(1, ceil(s / c))` chunks, so **an empty regular file names exactly one
chunk, the empty chunk**; a symlink names none. Existing files keep the chunk size recorded in their
manifest.

### 2.3 Backend key layout

Store root `tsync/`; per domain `D` (a valid domain name, [01-core.md](01-core.md)):

```
tsync/D/manifests/                              the manifest area
tsync/D/manifests/<folder id>/                  a folder's namespace
tsync/D/manifests/<folder id>/<leaf hash>       child: file manifest or folder marker
tsync/D/manifests/<folder id>/.tsync-parent     the folder's anchor
tsync/D/manifests/<folder id>/.tsync-index      folder index (optional)
tsync/D/manifests/.tsync-root/…                 the root folder's namespace
tsync/D/manifests/.tsync-trash/<16 hex>         trash entries
tsync/D/chunks/<sss>/<chunk key>                chunks, surviving space; sss = first 3 hex of the key
tsync/D/chunks.from/<sss>/<chunk key>           outgoing space, only during a collection run
tsync/D/gc-run                                  collection run record, collectable main only
tsync/D/gc-generation                           collection generation, first collectable main only
tsync/D/gc-run.lock                             lock file (filesystem stores only; not a store object;
                                                MAY exist before any collection ran)
tsync/D/versions/<folder id>/<leaf hash>/<ns>   version snapshots
tsync/D/journal/<YYYY-MM>/<entry key>           journal entries (format: 03-journal-sync.md)
tsync/D/cursor                                  cursor (format: 03-journal-sync.md)
tsync/corrupted/D/<sss>/<chunk key>             corruption marker
tsync/verify-jobs/D/<sss>                       verify job
tsync/gc-jobs/D/<run>/<shard>                   discard job
tsync/shares/<token>                            share manifest (store-wide, not per domain)
tsync/shares/cache/<token>.data                 assembled share artifact, by token
tsync/shares/cache/<h1>-<h2>.data               assembled file, by whole-file digest
```

Rules:

- **Shards.** `sss` is the first three characters of the chunk key: 4096 shards `000`…`fff`. A shard name
  is exactly three lowercase hex characters.
- **Sibling trees.** `corrupted`, `verify-jobs`, `gc-jobs` and `shares` are siblings of the domain trees,
  so one literal prefix covers every domain for notification filters, IAM conditions and lifecycle
  rules. Their names are reserved ([01-core.md §2.2 Domain names](01-core.md#22-domain-names)).
- **Corruption marker key from a chunk key.** `…/D/chunks/<sss>/<key>` maps to
  `tsync/corrupted/D/<sss>/<key>`, matching the **last** `/chunks/` segment. There is no marker key for
  anything under `chunks.from/`, for a marker, for a manifest, or when the domain is empty.
- **Internal leaves.** Every internal leaf starts with the sentinel `.tsync-` (`.tsync-root`,
  `.tsync-trash`, `.tsync-parent`, `.tsync-index`). A namespace listing's **child objects** are the
  listed keys whose leaf is not internal. Store listings never contain directory keys or a store's own
  temporary files ([06-backends.md §3.6](06-backends.md#36-list_prefix)).
- **Prefixes.** A key never ends in `/`; the prefix of a namespace or shard is its key followed by `/`
  ([01-core.md §2.1](01-core.md#21-store-keys-and-prefixes)). Listing a namespace without the `/`
  matches a different set of keys.

Example: domain `photos`, folder `Photos` at the root with id `3f2a9c1b7d4e-1a`, file
`Photos/hello.txt` containing `hello world`:

```
tsync/photos/manifests/.tsync-root/857fcda0047eeab4-a677d171b8d38674     marker for "Photos"
tsync/photos/manifests/3f2a9c1b7d4e-1a/.tsync-parent                     anchor of Photos
tsync/photos/manifests/3f2a9c1b7d4e-1a/285b8db6c3eef5e0-7b23aee4b1561b8f manifest of hello.txt
tsync/photos/chunks/d44/d447b1ea40e6988b-b7aeb52a10fdaf2d                its only chunk
```

### 2.4 Logical keys and stored keys

The logical key grammar and the logical-to-stored mapping are owned by [01-core.md](01-core.md). The
spellings this layer produces:

```
namespace(id)          = tsync/D/manifests/<id>/
child_key(id, name)    = namespace(id) ^ dual(name)
manifest_key(K)        = child_key(folder id of parent(K), leaf(K))
folder_marker_key(K)   = manifest_key(K)            (none for the root)
anchor_key(id)         = namespace(id) ^ ".tsync-parent"
index_key(id)          = namespace(id) ^ ".tsync-index"
trash_key(r)           = tsync/D/manifests/.tsync-trash/<r>
```

The folder id of a logical key comes from local state (the owner's record of settled ids), never from
the path. A client that holds no id for a folder cannot name its children on the store (**unresolved**),
which says nothing about what the store holds.

Share serving uses the **identity layout**: the share names stored keys directly (§2.14), and folders
are named by id; no local ids are involved.

### 2.5 Folder ids

The folder-id grammar is owned by
[01-core.md §2.5](01-core.md#25-folder-ids); client identity, leases and minting by
[03-journal-sync.md §2.1](03-journal-sync.md#21-client-identity-and-folder-id-leases-local); arbitration
by [data-model/backend.md §6](data-model/backend.md#6-folder-identity-arbitration). Reserved ids used in
this layout: `.tsync-root` (the root's namespace) and `.tsync-trash` (the trash namespace). Example
minted id: `3f2a9c1b7d4e-1a`.

### 2.6 File manifest: binary `tsyncm03`

Little-endian, a fixed header then variable fields, no escaping. A body with another magic is not a
manifest.

```
off  len  field
0    8    magic "tsyncm03"
8    8    size        signed 64-bit: logical file size in bytes
16   8    mtime       IEEE-754 double (seconds since the epoch)
24   4    chunk_size  unsigned 32-bit
28   4    count       unsigned 32-bit: number of chunk keys
32   4    name_len    unsigned 32-bit
36   4    link_len    unsigned 32-bit; 0 for a regular file
40   16   h1          ASCII hex, whole-file digest, seed 0
56   16   h2          ASCII hex, seed 1
72   name_len         leaf name bytes, recorded at write time
..   link_len         symlink target bytes
..   count × 33       chunk keys, in index order, no separators
```

**Reader.** A body MUST be rejected as malformed if it is shorter than 72 bytes, has another magic, has
`size < 0`, or its length differs from `72 + name_len + link_len + 33 × count` (computed without
overflow). A chunk key that is not a well-formed chunk key (§2.1) makes the manifest malformed when that
key is used; a reader MUST NOT fetch or trust it. A reader MUST NOT serve bytes of a range that no key
covers (a count too small for the size): that range reads as damaged, never as zeros. A reader need not
parse keys eagerly: key *i* is the 33 bytes at `72 + name_len + link_len + 33·i`. A manifest read from
local disk MAY, and SHOULD, be read through an immutable memory mapping: a manifest file is only ever
replaced by rename, never modified in place.

**Writer.** A writer MUST write `count = max(1, ceil(size / chunk_size))` with `chunk_size > 0` for a
regular file, and for a symlink `count = 0`, `link_len > 0`, `size` = the target's length, `chunk_size =
8388608`, `h1`/`h2` = the symlink digest. It MUST compute `h1`/`h2` from the keys and lengths (§2.1), so
a partial rewrite needs no reread of unchanged bytes. The recorded name is the leaf of the key the body
is written to; a body copied to a new location keeps its old name until re-put.

Byte-exact example: `hello.txt`, content `hello world`, mtime `1759140000.5`, chunk size 8 MiB;
`h = dual("d447b1ea40e6988b-b7aeb52a10fdaf2d-11;") = d94b4e9626fdc9c1-f3f6d793ca1ea424`; 114 bytes:

```
0000  74 73 79 6e 63 6d 30 33 0b 00 00 00 00 00 00 00  tsyncm03........
0010  00 00 20 28 96 36 da 41 00 00 80 00 01 00 00 00  .. (.6.A........
0020  09 00 00 00 00 00 00 00 64 39 34 62 34 65 39 36  ........d94b4e96
0030  32 36 66 64 63 39 63 31 66 33 66 36 64 37 39 33  26fdc9c1f3f6d793
0040  63 61 31 65 61 34 32 34 68 65 6c 6c 6f 2e 74 78  ca1ea424hello.tx
0050  74 64 34 34 37 62 31 65 61 34 30 65 36 39 38 38  td447b1ea40e6988
0060  62 2d 62 37 61 65 62 35 32 61 31 30 66 64 61 66  b-b7aeb52a10fdaf
0070  32 64                                            2d
```

### 2.7 Folder marker (JSON)

At `child_key(parent id, name)`:

```json
{"dir":true,"name":"Photos","id":"3f2a9c1b7d4e-1a"}
```

- **Writer**: exactly these three fields in this order, no whitespace.
- **Reader**: a body is a folder marker iff it parses as a JSON object with `"dir": true`. Field order
  and unknown fields are ignored. Readers SHOULD accept a marker with a missing or non-string `name` or `id`
  (meaning an empty one); writers MUST NOT produce it. A marker whose
  `id` is not a folder id ([01-core.md §2.5](01-core.md#25-folder-ids)), including an empty one, is
  **unclassifiable**: skipped like
  a write in flight, never adopted, and it references no chunk.

### 2.8 Anchor (JSON)

At `anchor_key(id)`:

```json
{"parent":".tsync-root","name":"Photos"}
```

- It has no `"dir"` field, so it never classifies as a marker.
- **Reader**: both `parent` and `name` MUST be strings, else the body is not an anchor and the folder
  reads as unanchored. Unknown fields are ignored. "In trash" ⇔ `parent = ".tsync-trash"`.
- A marker at `child_key(P, N)` naming *I* is filed iff anchor(*I*) = `{parent: P, name: N}` or *I* has
  no anchor ([data-model/backend.md](data-model/backend.md) §6.3).

### 2.9 Trash entry (JSON)

At `trash_key(<16 lowercase hex, random>)`:

```json
{"dir":true,"name":"Photos","id":"3f2a9c1b7d4e-1a","path":"Archive/Photos"}
```

- A folder-marker body plus `path`, the domain-relative path at deletion time.
- **Reader**: read as a folder marker (§2.7); readers SHOULD accept an entry without a string `path` (meaning
  a trash entry for expiry and repair that cannot be found by path for restore); writers MUST NOT
  produce it.
- The trashed folder's anchor is `{"parent":".tsync-trash","name":<its name>}`.

### 2.10 Folder index (binary `tsyncidx1`)

At `index_key(id)`. A cache of the namespace's child bodies, so a folder read costs one listing and one
read instead of one read per child.

```
"tsyncidx1"
repeat:  be32 length | key bytes (the full stored key)
         be32 length | entity tag bytes
         be32 length | body bytes
```

- Lengths are big-endian (unlike the manifest). Only children whose listing carried an entity tag are
  written.
- **Reader**: any parse error means "no index". An entry is used only if the current listing reports the
  same entity tag for that key. An index whose listed size exceeds `index_max_bytes` (64 MiB) is not
  read.
- **Writer**: only a walker allowed to write, only for a domain with exactly one readable member, only
  when `1 < children ≤ index_max_children` (10 000) and fewer than 75 % of the children were served from
  the existing index.

### 2.11 Versions

```
tsync/D/versions/<folder id>/<leaf hash>/<timestamp>
e.g. tsync/photos/versions/3f2a9c1b7d4e-1a/285b8db6c3eef5e0-7b23aee4b1561b8f/1759140000500000000
```

- The body is the replaced manifest body, verbatim.
- The **history group** is `<folder id>/<leaf hash>`: the manifest key minus `tsync/D/manifests/`.
- `timestamp` is a decimal count of nanoseconds since the epoch. Writers MUST make timestamps strictly
  increasing per group (a later snapshot in the same nanosecond takes the previous timestamp plus one).
- **Reader**: split a version key at its last `/` into (group, timestamp); a timestamp that is not a
  decimal integer makes the key not a version.

### 2.12 Collection run record and generation (JSON)

**Run record** at `tsync/D/gc-run` on the collectable main only:

```json
{"phase":"marking","started":1759140000.123,"cursor":"m/3f2a9c1b7d4e-1a"}
{"phase":"closing","started":1759140000.123,"cursor":"a3f","generation":7}
```

- `phase` ∈ `opening`, `marking`, `abandoning`, `closing`. Readers SHOULD accept
  `reconciling` (meaning `closing`); writers MUST NOT produce it.
- `started`: seconds since the epoch; a reader accepts an integer or a float. The **run name** is
  `started × 1000` rounded, zero-padded to 13 decimal digits.
- `cursor`: marking → the last finished namespace, `m/<folder id>` (manifest area) or `v/<folder id>`
  (version area), which sort all `m/` before `v/`; closing and abandoning → the last finished shard; `""`
  = none. A missing `cursor` reads as `""`.
- **Presence** of the object means a run is open, whatever its body. A body that does not parse, or
  names an unknown phase, is an **unreadable run**: readers and the gate treat the run as open; the
  collector treats it as abandoning ([algorithms/gc.md](algorithms/gc.md)).
- `generation` (written from the closing phase on): the odd collection generation of this run, an
  integer ≥ 1. Writers MUST include it in every closing record. Readers SHOULD accept a closing record
  without it (meaning G is odd for as long as the record is present); a collector resuming one assigns it
  a fresh odd generation before its next doom step
  ([algorithms/gc.md §5.5](algorithms/gc.md#55-the-collector-phase-by-phase)). Readers MUST ignore
  unknown fields.

**Generation** at `tsync/D/gc-generation`, on the first collectable main of the domain:

```json
{"generation":8}
```

- An integer ≥ 0 that only increases. Even: no collection has deletions on copies in flight. Odd: one
  has ([algorithms/gc.md §5.6](algorithms/gc.md#56-the-generation-and-presence-memos)).
- Written with a plain put, only by the collecting owner holding the run lock.
- **Reader**: absent reads as 0. A body that does not parse, or a value that is not a non-negative
  integer, reads as odd (memos untrusted) and is reported. Unknown fields are ignored.

### 2.13 Corruption marker, verify job, discard job

**Corruption marker** at `tsync/corrupted/D/<sss>/<chunk key>`. The key is the finding; the body is
optional detail:

```json
{"computed":"0123456789abcdef-fedcba9876543210","size":8388608,"at":1759140000.5,"reason":"EIO"}
```

- `computed` and `size` describe wrong bytes; `reason` (without `computed`) an unreadable chunk; `at` is
  seconds since the epoch, integer or float.
- **Reader**: every field is optional; unknown fields are ignored; an empty or unparseable body is still
  a marker. Only a key whose leaf is a well-formed chunk key counts (filesystem stores also list shard
  directories).

**Verify job** at `tsync/verify-jobs/D/<sss>`, empty body: "check every chunk under
`tsync/D/chunks/<sss>/`". A key counts as a verify job iff, after `tsync/verify-jobs/`, it splits from the
right into `<domain>/<shard>` with a valid shard.

**Discard job** at `tsync/gc-jobs/D/<run>/<shard>`:

- `<run>` is the collection's run name (§2.12); `<shard>` is the last shard of the batch.
- Body: full chunk keys (`tsync/D/chunks/<sss>/<chunk key>`) joined by `\n`; no trailing newline
  required; empty lines ignored.
- **Probe**: the reserved run name `0000000000000` with shard `000` and an empty body is the
  bucket-function probe; its procedure is [backends/object-store-common.md](backends/object-store-common.md)
  ("The probe"). An empty request deletes nothing.
- **Reader**: a key counts as a discard job iff, after `tsync/gc-jobs/`, it splits from the right into
  `<domain>/<run>/<shard>` with a valid shard and a non-empty domain and run. A listed key under the
  prefix that does not parse this way is not a job. The executor deletes only lines that are chunk keys
  of that same domain's surviving space; it refuses and logs any other line.

### 2.14 Share manifest (JSON) and share artifacts

At `tsync/shares/<token>`. `token` is 32 lowercase hex characters from 16 random bytes; readers accept
any non-empty lowercase hex token of at most 64 characters (caller-supplied tokens exist).

```json
{"v":1,"expires":1767225600,"domain":"Files","type":"file","key":"tsync/Files/manifests/<folder id>/<leaf hash>","filename":"report.pdf"}
{"v":1,"expires":1767225600,"domain":"Files","type":"dir","folderId":"<folder id>","filename":"2024.zip"}
```

- `expires`: seconds since the epoch. A share of the whole domain has `folderId = ".tsync-root"` and
  `filename = "<domain>.zip"`.
- **Reader**: `v` MUST be `1`; `domain` MUST be a valid domain name; for `file`, `key` MUST lie under
  `tsync/<domain>/manifests/` and be a child key; for `dir`, `folderId` MUST be a folder id ([01-core.md §2.5](01-core.md#25-folder-ids)).
  Otherwise the share is refused. Unknown fields are ignored.
- **Artifacts**: `tsync/shares/cache/<token>.data` (a download of that share) and
  `tsync/shares/cache/<h1>-<h2>.data` (a file by whole-file digest). Readers SHOULD
  accept a `tsync/shares/<name>.data` object directly under the share tree (meaning a share artifact,
  never a share manifest; clear-cache and expiry delete it); writers MUST NOT produce it.

---

## 3. Interface

### 3.1 The seams

Each component is instantiated per domain from the domain context ([05-ops-config.md](05-ops-config.md)):
prefixes, the composite store, the individual members with roles, versioning, chunk size and local
roots. Process-wide state (memos, cursor debouncing, the run-open cache) is keyed by the domain, never by
instance: several instances of one domain in one process share one view.

**ContentStore** (file bodies):

```
upload(key, source_path, mtime, chunk_size, cancel?, on_progress?) -> Manifest
    errors: Cancelled, SourceChanged(path), Stopping, MissingChunks(keys), store failures
upload_chunks(key, size, chunk_size, mtime, source: index -> ChunkSource, cancel?) -> Manifest
get_chunk(chunk key) -> bytes
get_verified_chunk(chunk key) -> bytes          // fails unless dual(body) = key within two reads
get_chunk_range(chunk key, offset, length) -> bytes
chunk_size() -> int                              // config, else the store's advertised size, else 8 MiB
fetch_manifest(key) -> Manifest | None           // None: unresolved, absent or undecodable
```

`ChunkSource`, decided without I/O: `Stored(key)` (reuse a key; neither read nor sent), `Mapped(bytes)`
(bytes produced in place, for example by mapping the source), `Filled(length, fill)` (the caller writes
exactly `length` bytes into a buffer).

**ManifestStore** (manifests by logical key, raw objects by stored key):

```
put_manifest(key, body)                // resolves or claims the parent chain; gated on a collectable main
get_manifest_state(key) -> Body(bytes) | Absent | Unresolved
head_manifest(key) -> Entry?           delete_manifest(key)
copy_manifest(src, dst)                // server-side copy then delete of src; gated
ensure_folder_id(dir key) -> id        // local first; otherwise claims self and ancestors
claim_folder(dir key, id?) -> Held | Taken(id)
place_folder(dir key)                  // the placement procedure for a settled id
trash_folder(dir key, id)              // entry, anchor, then marker removal
restore_folder(path) -> Restored | NotInTrash | ParentUnknown
remove_stale_marker(slot, expected id?)
confirm_pending_claims()               // runs the confirmations owed
get_anchor(id) -> Anchor?   placed(id, at) -> Here | Elsewhere(anchor) | Unanchored
holder_at(slot) -> id?                 // the filed marker's id, disowned ones read as none
list_namespace(id) -> [Entry]   get_object(key)   get_objects(keys)   list_many?(ids)
```

`Unresolved` means this client holds no id for the key's folder; `Absent` means the store holds nothing
there. A caller that memoizes answers MUST NOT memoize `Unresolved`. There is no operation that writes a
folder marker with a plain put.

**TreeReader** (the folder tree by id):

```
Entry     = { key, body: Dir(marker) | File(manifest) }
Unusable  = Unreadable(error) | Unclassifiable(error) | Disowned(anchor)
OnUnusable = Fail | Skip(report)
children(id, on_unusable = Fail, refresh_index = false) -> [Entry]
find(id, names) -> File(entry) | Folder(id) | Missing
fold_tree(id, root key, f(acc, containing dir key, entry) -> acc, acc0, on_unusable?) -> acc
```

**History**: `save_version(key)` (best effort, bounded by `snapshot_deadline`, recommended 10 s including
retries; failures logged), `list_versions(key)`, `get_version(version key)`, `revert(key, version key)`
(a gated copy onto the live location), and the pure helpers `parse(version key) -> (group, timestamp)?`,
`versions_of(group)`, `manifest_of(group)`, `folder_versions(id)`.

**ChunkSpace** (reads of the collected main during a run): `head`, `get`, `get_range` across both
spaces ([algorithms/gc.md](algorithms/gc.md) §5.8), `run_present()`, and `generation()` (G, §2.12). Promotion is performed only by
the gate of the collectable main's driver ([algorithms/gc.md](algorithms/gc.md) §5.4); no other
component promotes.

**Corruption**: `list() -> {entries, unverified, unreachable}`, `is_marked(key)` (memo, §4.7),
`forget(key)`, `detail(entry)`.

**KeyLayout** (logical to stored): `manifest_key`, `folder_marker_key`, `folder_id`; two realisations,
the *inode* layout (ids from local state) and the *identity* layout (share serving).

### 3.2 How hosts use these

| Host | Uses | Differences |
|---|---|---|
| Domain owner (desktop, embedded mobile core) | every component, inode layout | full read and write |
| File-provider extension | ContentStore, ManifestStore, TreeReader, through its owner | whole-file uploads from snapshots |
| http-proxy server | TreeReader and ManifestStore for batched folder reads; share serving with the identity layout; its local store driver's gate and two-space reads for remote writers and readers | never writes folder indexes for shares |
| One-shot commands (import, export, gc, expire, integrity, diagnostics) | as needed, through or as the owner | collection only where a collectable main is local |

### 3.3 What this layer requires of the store

The store contract is [06-backends.md §3](06-backends.md#3-the-store-contract). One reading rule is
this layer's: an empty or unparseable answer to create-if-absent is read back, never taken as "won"
([data-model/backend.md §6.2](data-model/backend.md#62-claiming-a-name-for-a-new-folder)).

---

## 4. Behaviour

### 4.1 Upload

1. `count = max(1, ceil(size / chunk_size))`; build a manifest with the key's leaf as recorded name.
2. For each chunk index: stop with `Cancelled` or `Stopping` if asked; obtain a `ChunkSource`; for
   `Stored(k)` keep `k`; otherwise obtain the bytes, compute the key, and decide whether the chunk is
   known:
   - marked corrupt on a member read by the domain (§4.7): **not** known;
   - otherwise in the dedup memo, if the memo may be relied on
     ([algorithms/gc.md §5.6](algorithms/gc.md#56-the-generation-and-presence-memos)): known;
   - otherwise a presence check: known if present (on a collectable main the driver answers from
     both collection spaces, [algorithms/gc.md §5.8](algorithms/gc.md#58-chunk-access-is-scoped-by-the-driver)).

   Unknown chunks are put; a successful put clears the chunk's corruption memo entry. Record the key in
   the manifest and report progress (a progress callback MUST NOT block).
3. **Publish**: re-check cancel and shutdown; compute `h1`/`h2`; seal; if versioning, `save_version`;
   `put_manifest`. On a collectable main the put goes through the gate; a `MissingChunks` refusal makes
   the uploader drop those keys from its memo, re-send them from the source it holds, and publish again
   (a `Stored` chunk has no source here: the refusal propagates to the caller, which re-reads the bytes
   from its local copy or reports the file damaged). If `cancel` was set while the put was in flight,
   delete the manifest again and fail `Cancelled` (chunks stay: a successor reuses them).

**Whole-file upload** reads from a snapshot of the source taken when it starts (a copy or reflink), so
later writes do not reach the bytes being hashed, and compares the source's size and modification time
after the last chunk: a change fails `SourceChanged` and publishes nothing.

**Partial rewrite** (`upload_chunks`) passes unchanged chunks as `Stored` keys, taken on trust from the
manifest being rewritten; the gate on the main is what verifies them.

**Dedup memo**: never pre-populated by listing (that cost would scale with the archive); it is an
optimisation only, since the gate on a collectable main checks presence
([algorithms/gc.md §5.4](algorithms/gc.md#54-the-collection-interlock)), and it is subject to
[algorithms/gc.md §5.6](algorithms/gc.md#56-the-generation-and-presence-memos).

### 4.2 Download

- A waiting reader's range read MUST NOT queue behind whole-chunk prefetches.
- Readers never handle collection spaces: a collectable main's driver answers chunk reads from both
  ([algorithms/gc.md §5.8](algorithms/gc.md#58-chunk-access-is-scoped-by-the-driver)).
- `get_verified_chunk` fetches, checks `dual(body) = key`, fetches once more on mismatch, and fails the
  second mismatch naming the key.
- `fetch_manifest` answers `None` for an unresolved key, an absent object, or a body that is not a
  manifest (a write in flight). A store failure MUST propagate as a failure, never as `None`
  ([algorithms/failure-model.md](algorithms/failure-model.md)).

### 4.3 Folders

The protocol (claim, confirmation, placement, trash, restore, stale-marker removal) is
[data-model/backend.md](data-model/backend.md) §6. This layer adds:

- `ensure_folder_id(K)` is local first: an id the owner already holds costs no round trip. Otherwise it
  ensures the parent, mints a candidate, claims, records the resulting id (its own on a win, the
  holder's on `Taken`) in local state, and queues the claim's confirmation durably. If local state
  already recorded another id for `K` meanwhile, that id wins.
- `claim_folder(K)` on publish: the root is always held. For a folder with no local id, local state is
  consulted first: a folder this client moved away is held (content is filed by its id); a folder this
  client removed fails transiently (a publish must not resurrect it); otherwise the parent chain and the
  folder are claimed. For a folder with a local id whose claim is final, no store read is needed.
- `ensure_claimed(K)` turns `Taken` into a transient failure: the conflict tables set one folder aside,
  and the waiting operation is retried.
- `restore_folder(path)` needs the destination parent's id locally (else `ParentUnknown`) and writes no
  journal entry; peers learn of it by resync.

### 4.4 Files (store side)

- **Rename**: snapshot the source's version (if versioning), server-side copy to the destination (gated),
  delete the source, then re-put the body with the new leaf as recorded name.
- **Delete**: snapshot (if versioning), delete the manifest; history remains in the version area.
- **Revert**: a gated copy of a version body onto the live location, preceded by a snapshot of the live
  body.

### 4.5 Reading the tree

`children(id)`:

1. List the namespace; keep child objects; note the index key if listed.
2. If the domain has exactly one readable member and an index is listed within `index_max_bytes`, read
   it and use entries whose entity tag matches the listing.
3. Fetch the rest (native batched reads where the store has them).
4. If `refresh_index` and the write rule of §2.10 holds, rewrite the index (best effort; errors logged).
5. Classify each body: folder marker, else manifest, else **unclassifiable** (a write in flight). A key
   listed but gone on read is **unreadable** (a permanent "not found" for that child).
6. Policy: `Fail` fails the folder on any unreadable child (a deleter must not take it for an empty
   folder) and skips unclassifiable ones; `Skip` reports each unusable child and continues, and if a
   whole batch failed permanently, retries child by child so one bad object does not cost its siblings.
7. For each folder marker, read the subfolder's anchor and drop disowned markers (reported as
   `Disowned` under `Skip`).

`find(id, names)`: one read of `child_key(id, name)` per segment, no listing; a file in a non-final
position, an absent child or a disowned marker answer `Missing`; an unparseable body fails.

`fold_tree`: depth first, each folder visited before its descent, `f` receiving the real logical key of
the containing folder (built from marker names). Prefetching is allowed provided the visit order is
unchanged; a folder omitted from a batched answer is fetched singly. Under `Skip`, a folder failing
transiently is retried once after the walk, then reported.

### 4.6 Folder index lifecycle

Nothing on the write path maintains an index: the listing is the truth, and a stale entry costs one read.
Deleters (purge) MUST delete indexes explicitly, since no tree walk yields them as children.

### 4.7 Corruption memo

`is_marked` lists every member's corruption markers for the domain at most once per `corruption_ttl`
(recommended 5 s), shared per domain. Members that do not verify chunks are skipped. A listing that
fails counts as "nothing marked" for that member (an unreachable store must not stop uploads), and is
reported. `forget(key)` follows a successful re-upload.

---

## 5. Interactions

- **Below**: the composite store and its members, the retry classification, the write guard, deferred
  jobs ([06-backends.md](06-backends.md), [algorithms/replication.md](algorithms/replication.md)).
- **Beside**: local state for folder ids and whereabouts ([data-model/local-cache.md](data-model/local-cache.md));
  the journal for client identity and entry keys ([03-journal-sync.md](03-journal-sync.md)).
- **Above**: the uploader and staged writes (upload, manifest store, journal writes); the read path
  (manifests, chunks, tree find); sync and resync (tree fold, journal); whole-domain operations
  (retention, collection, integrity, mirror, rsync, share).

Main flows:

- *Write a file*: staged → `upload_chunks` → chunks put or deduplicated → version snapshot → claim the
  folder chain → gated manifest put → journal entry → cursor bump.
- *Open a file lazily*: path → local ids (or `find`, one read per segment) → manifest → byte ranges →
  chunks.
- *Resync*: `fold_tree` from the root; markers become local folders with their ids, manifests become
  local manifests; indexes rewritten where worth it.

---

## 6. Concurrency, durability and failure

- **Atomicity unit is one object.** Correctness rests on the ordering rules of
  [data-model/backend.md](data-model/backend.md) §4.3.
- **Crash during upload**: orphan chunks (reclaimed by a collection); no manifest, so the file is not
  visible. A crash after the manifest and before the journal entry is recovered by the writer's WAL.
- **Concurrent writers to one file**: last writer wins on the manifest key; conflicts are detected in
  the sync layer.
- **Idempotence**: chunk put, promotion, discard requests (named by run and shard), batched deletes
  (absent is success), collection resume, a claim of a slot already naming the claimant's id.
- **Offline**: reads fail; `Unresolved` is never cached; a corruption listing failure reads as "nothing
  marked"; version snapshot failures are logged and swallowed within `snapshot_deadline`.
- **Shared in-process state** MUST be updated atomically with respect to concurrent tasks: upload index
  allocation, the dedup and corruption memos, the per-domain registries, the run-open
  cache, the tree-walk frontier, and the counters for entry keys, version timestamps and folder ids.
- **Durable local state** used here: the client id, folder-id leases, pending claim confirmations
  ([data-model/local-cache.md](data-model/local-cache.md)). Memos are memory only.

---

## 7. Design choices and rationale

| Choice | Why | Rejected alternative |
|---|---|---|
| Folders keyed by stable id; children by leaf hash | a move rewrites a constant number of objects; the hashed leaf is fixed-length and filesystem-safe | path-keyed objects (a folder move rewrites its subtree) |
| Folder ids claimed with create-if-absent, then confirmed | two clients creating one folder must agree; a stale delete or an unarbitrating server must not strand a subtree | local mint and plain put |
| Anchor inside the folder's namespace | a lost delete after a move would otherwise show a folder at two paths; also keeps expiry from deleting a restored folder | trusting markers alone |
| Binary manifest with fixed 33-byte keys | O(1) key access, mappable without heap for huge files, no escaping | JSON; per-chunk lengths |
| Recorded name in the manifest body | version keys and shares are one-way hashes | — |
| Dedup memo never pre-listed | listing scales with the archive | pre-listing |
| Corruption checked before the memo | a marked chunk must be re-sent, or bad bytes spread to every file sharing it | presence means healthy |
| Folder index validated by entity tag only | object stores report whole seconds; a same-size rewrite within a second is invisible to size and time | size and time validation |
| Range reads never wait behind prefetches | a small read queued behind whole-chunk prefetches stalls on slow links | one queue for all downloads |
| Snapshot and change check on whole-file upload | the chunks must describe bytes the file held together | reading the live file |

---

## 8. Conformance

An implementation MUST exhibit these observable properties:

- **Key spellings.** The digests of §2.1 match the test vectors; `img.jpg` under folder
  `9f3a1c0428b6d5e7` is `…/9f3a1c0428b6d5e7/066843ea47b80079-e0e3d2bb9b72c14d`; equal names give equal
  keys under any folder; listing classification separates children, indexes and anchors.
- **Layout.** A chunk key maps to shard `sss` and back by basename; a corruption marker key exists only for a surviving-space chunk; discard and verify job keys
  parse as §2.13 and are never mistaken for chunks; a discard body round-trips between client and
  bucket function.
- **Manifest.** The example of §2.6 is produced byte for byte; every malformation of §2.6 is rejected;
  an empty regular file names the empty chunk once; a symlink names none.
- **Run record and generation readers.** A closing run record without `generation` makes G read as odd
  while it is present; an absent generation object reads as 0 and an unparseable one as odd; phase
  `reconciling` reads as closing; a share with unknown fields is served; a `.data` object directly under
  the share tree is never read as a share.
- **Folder index.** Without an index: one read per child and one index write; with a valid index: one
  index read and no child reads; one child rewritten: one extra read and a rewrite; a reader not allowed
  to write never writes; a domain with two readable members neither reads nor writes one.
- **Tree reads.** An empty namespace yields no children; classification is by body; one unreadable child
  does not cost its siblings under `Skip` and fails the folder under `Fail`; a fold lists each folder
  once, in a visit order independent of prefetching; batched listings are used
  and omitted folders fetched singly; a disowned marker is skipped and reported; an unanchored folder is
  listed where its marker says.
- **Uploads.** A marked chunk is re-sent rather than deduplicated; a remembered chunk is not re-checked
  while the memo may be relied on; an upload whose source changed or vanished publishes
  nothing; a `MissingChunks` refusal leads to a re-send and a successful publish.
- **Deduplication.** Identical bytes are one chunk object whatever the file or name; re-uploading
  identical content adds no chunk object; zero-filled chunks share one key; a 0-byte file names the
  empty chunk once. Identical content yields identical `h1`/`h2`; the `h1` of an empty regular file is
  `06b4b04bae2346bf`.
- **Recorded name.** A written manifest records the leaf of the key it is written to, whatever name the
  caller supplied.
- **Folder moves.** Moving a folder changes no key of any object under it; the folder is listed exactly
  once afterwards.
- **Versions.** With versioning on, each overwrite and each delete leaves the prior manifest body as a
  version, and a rename leaves a version under the old name.
- **Side trees.** A run started at `1755300000.5` names its discard jobs under `1755300000500`; two runs
  0.5 s apart get different names; domain names containing spaces work; a job key with a missing run, a
  bad shard, a trailing `/` or an empty domain is refused.
- **Chunk size and source changes.** New files use the configured chunk size, else the store's
  advertised one, else 8 MiB; a source modified during a whole-file upload publishes nothing.
- **Corruption markers.** A verifying store files a marker recording the computed digest when a body
  does not hash to its key; a good rewrite clears it; a corruption listing distinguishes a store that
  found nothing from a store nothing checks.
- **Verified fetch.** A good body costs one read; a body mangled once is re-read; a body wrong twice is
  refused after exactly two reads.
