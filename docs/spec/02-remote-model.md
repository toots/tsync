# 02 — The remote data model

Scope: `lib/domain/manifest`, `lib/domain/remote` (`remote.ml`, `chunks/chunk_store`,
`store/{layout,store,inode_tree,file_store,history,gc,corruption}`), their Lwt
instantiations in `lib/lwt/domain/remote`, and the pure vocabulary they stand on in
`lib/core` (`stored_key`, `logical_key`, `chunks`, `chunk_layout`, `chunk_source`,
`folder`, `xxhash`, `id`). The collector driver `lib/domain/ops/gc.ml` and the trash /
versions expiry in `lib/domain/ops/retention.ml` are covered here as far as they define
what lives on the store; their CLI and scheduling belong to the ops spec.

This file is the language-neutral specification; the [OCaml notes](ocaml/02-remote-model.md) collect OCaml-specific
implementation notes.

---


## 1. Problem

tsync stores a user's tree on a dumb key/value object store (S3, GCS, a local directory,
or another tsync over HTTP). The store offers only `put/get/get_range/head/delete/copy/
list_prefix` and one conditional write (`put_if_absent`). On top of that the remote model
has to provide:

- **Content-addressed, deduplicated file bodies.** A file is cut into fixed-size chunks
  named by the hash of their bytes. Identical content is stored once per domain; an
  unchanged chunk is never re-sent; any client can verify any chunk against its name.
- **A cheap, rename-stable directory tree.** Directories are identified by a stable
  random id, not by their path, so renaming/moving a folder rewrites *one* object
  (the marker under the parent), never its descendants.
- **Lazy access.** A reader resolves a path to one small manifest object with one GET
  per path segment, then fetches only the chunks (or byte ranges of chunks) it needs.
- **History.** Previous manifests (versions), deleted folders (trash) and a shared
  journal of operations (the journal format itself is spec'd elsewhere).
- **Reclaiming space.** Unreferenced chunks are collected by a resumable mark-by-move
  collection that is safe against concurrent writers who have never heard of it.
- **Integrity.** Stores that verify chunks file corruption markers; the upload path
  must not dedup against a chunk known to be bad.

It is a separate abstraction because every layer above (mirror, frontends, sync,
shares, CLI) speaks **logical keys** (domain-relative paths); only this layer knows the
**stored keys** (hashed, id-based) and the binary manifest format.

---

## 2. Concepts & data model

### 2.1 Hashes

All naming uses **XXH3-64** (xxHash v3, 64-bit variant, `XXH3_64bits_withSeed`),
rendered as 16 lowercase hex chars (`%016Lx`). A "dual digest" is the same input hashed
with seed 0 and seed 1, joined by `-`: `"<h(seed0)>-<h(seed1)>"`, 33 bytes. Not
cryptographic; the pair gives 128 bits against accidental collision.

| Name | Input | Shape |
|---|---|---|
| chunk key | chunk bytes | `hex16(xxh3(b,0)) "-" hex16(xxh3(b,1))` |
| leaf-name hash (child key) | UTF-8/raw bytes of the leaf name | same shape |
| manifest whole-file digest `h1`,`h2` | streaming over `"<chunkkey>-<len>;"` for each chunk in order | `h1`=seed0, `h2`=seed1, each 16 hex (stored separately, no dash) |
| cache group key | streaming over `"<memberkey>;"` for each member | dual digest shape |
| symlink digest | target string | `h1 = xxh3(target,0)`, `h2 = xxh3(target,1)` |
| mirror escape handle | leaf | `.tsync-esc-` + hex16(xxh3(leaf,0)) |

Verified values (computed with the vendored `xxhash.h`):

```
xxh3 dual("hello world") = d447b1ea40e6988b-b7aeb52a10fdaf2d
xxh3 dual("")            = 2d06800538d394c2-4dc5b0cc826f6703   (key of an empty chunk)
xxh3 dual("img.jpg")     = 066843ea47b80079-e0e3d2bb9b72c14d   (pinned in tests/unit/stored_key)
xxh3 dual("hello.txt")   = 285b8db6c3eef5e0-7b23aee4b1561b8f
xxh3 dual("Photos")      = 857fcda0047eeab4-a677d171b8d38674
```

`Chunks.is_chunk_key name` ⇔ exactly one `-` at index 16 and both halves are 16 chars of
`[0-9a-f]`. Used whenever walking a store decides copy/delete: it says what a name *is*,
never what it is not.

### 2.2 Chunking

- `chunk_size` default **8 MiB** (`Conf.default_chunk_size = 8*1024*1024`). Resolution
  for *new* files, once per process: config `chunkSize` → `Backend.caps.chunk_size` of
  the domain's store (an http-proxy answers the serving domain's own) → default.
  Existing files always use the `chunk_size` recorded in their manifest.
- `count(size) = 0 if size<=0 else ceil(size/chunk_size)`; chunk `i` covers
  `[i*chunk_size, min((i+1)*chunk_size, size))`; `length_of i = max 0 (min chunk_size (size - i*chunk_size))`.
- **An empty regular file has exactly one chunk key: the key of the empty body**
  (`2d06…-4dc5…`), because the uploader uses `max 1 count`. A symlink has zero.
- `pieces ~chunk_size ~count ~offset ~length` → ordered list of
  `{index; chunk_off; len; dest}` covering the range once, truncated at `count`.
- Chunks are **per domain**: no cross-domain dedup (a domain is deleted with one prefix
  delete).

### 2.3 Backend key layout (everything a domain puts on a store)

`root_prefix = "tsync/"`, per domain `D`:

```
tsync/<D>/manifests/                      domain_prefix   (the inode tree)
tsync/<D>/manifests/<folder_id>/          a folder's namespace
tsync/<D>/manifests/<folder_id>/<h1>-<h2> child: file manifest OR folder marker (h = dual(leaf name))
tsync/<D>/manifests/<folder_id>/.tsync-parent   the folder's anchor (JSON)
tsync/<D>/manifests/<folder_id>/.tsync-index    folder index cache (binary, optional)
tsync/<D>/manifests/.tsync-root/…         root folder's namespace (root id = ".tsync-root")
tsync/<D>/manifests/.tsync-trash/<16hex>  trashed folder markers (JSON, with "path")
tsync/<D>/chunks/<sss>/<chunkkey>         chunk bodies; sss = first 3 hex chars of key
tsync/<D>/chunks.from/<sss>/<chunkkey>    only during a GC run on a local main: the space being collected
tsync/<D>/gc-run                          GC run marker (JSON), main store only
tsync/<D>/gc-run.lock                     lockf file beside it (filesystem only; not a store object)
tsync/<D>/versions/<folder_id>/<h1>-<h2>/<unix_ns>   manifest version snapshots
tsync/<D>/journal/<YYYY-MM>/<13-digit-ms>-<client_uuid>  journal entries (NDJSON; format in journal spec)
tsync/<D>/cursor                          newest published entry key (text)
tsync/corrupted/<D>/<sss>/<chunkkey>      corruption marker for that chunk (JSON)
tsync/verify-jobs/<D>/<sss>               request: verify shard (empty body)
tsync/gc-jobs/<D>/<run>/<name>            request: delete these chunk keys (newline-separated keys)
tsync/shares/<token>                      share manifests (fixed root; spec'd with shares)
```

Notes:

- The corruption / job roots are **siblings of `tsync/<D>/`**, not children
  (`Chunk_layout.domain_roots` lists all four prefixes a domain owns). Derived from
  `chunk_prefix` by taking everything up to the first `/` as store root. A domain named
  `corrupted`, `verify-jobs` or `gc-jobs` would collide; not checked.
- Shard fan-out: 3 hex chars → **4096 shards** (`shard_name n = %03x`). A key shorter
  than 3 chars would go under `_` (never happens for real keys).
- `gc_run_name started = sprintf "%013.0f" (started*1000.)` (milliseconds).
- `Chunk_layout.marker_key` maps `…/<D>/chunks/<sss>/<key>` → `<root>corrupted/<D>/<sss>/<key>`,
  matching the **last** `/chunks/` segment (a domain called `chunks` must not cut short),
  and returns `None` for anything under `chunks.from/`, for markers themselves, for an
  empty domain, and for manifests (which are spelled like chunk keys but are not under
  `/chunks/`). Membership is by prefix, never by the shape of the leaf.
- **Reserved sentinel** `.tsync-`: every internal leaf starts with it (`.tsync-root`,
  `.tsync-trash`, `.tsync-index`, `.tsync-parent`, `.tsync-dir`, `.tsync-name`,
  `.tsync-tmp-<pid>-<seq>.tmp` temp files, `.tsync-esc-<hex16>` escape handles).
  `internal_leaf l = starts_with ".tsync-" && not escaped`. `is_child_object k = not
  dir-key && not internal` — what a namespace listing offers as a real child.
- A "directory key" is one ending in `/` (filesystem stores list the namespace itself).

### 2.4 Two key types

- **`Logical_key.t`** = `{prefix = domain_prefix; path; kind = File|Dir}`. `to_string =
  prefix ^ path` (e.g. `tsync/photos/manifests/2024/img.jpg`), root has `path=""`,
  `leaf` is the basename, `parent` of root is root. Leading/trailing `/` trimmed on
  construction. This is what every upper layer and the journal speak.
- **`Stored_key.t`** = opaque string naming an object in one space; no `of_string`
  (built by a namer or taken from a listing via `listed`). Constructors:
  `in_space ~prefix path`, `namespace ~prefix ~folder_id = prefix^id^"/"`,
  `child_key ~prefix ~folder_id name = prefix^id^"/"^dual(name)`,
  `index_key`, `anchor_key`, `trash_namespace`, `share_key`, `under k name = k^name`.
  Inspectors: `parent_folder_id k` (basename of dirname), `folder_id_of ns`,
  `path_in ~prefix k`, `is_dir_key`, `is_index_key`, `is_internal`, `is_child_object`.

Mapping (`Layout.Inode`):

```
manifest_key(K)       = child_key(prefix=domain_prefix, folder_id = id(parent(K)), leaf(K))
folder_marker_key(K)  = manifest_key(K)            (None for root)
folder_id(K)          = local lookup (Folder_ids, from the mirror's .tsync-dir markers)
```

A file and a folder of the same name in the same parent would collide at one key; the
object at that key is one or the other (classified by body).

`Layout.Identity` is the degenerate layout used by share serving: the logical string
*is* the backend key (`in_space ~prefix:""`), `folder_id K = leaf K`, no markers.

Example: domain `photos`, folder `Photos` at root with id `3f2a9c1b7d4e-1a`, file
`Photos/hello.txt`:

```
tsync/photos/manifests/.tsync-root/857fcda0047eeab4-a677d171b8d38674   ← marker for "Photos"
tsync/photos/manifests/3f2a9c1b7d4e-1a/.tsync-parent                   ← anchor of Photos
tsync/photos/manifests/3f2a9c1b7d4e-1a/285b8db6c3eef5e0-7b23aee4b1561b8f ← manifest of hello.txt
tsync/photos/chunks/d44/d447b1ea40e6988b-b7aeb52a10fdaf2d               ← its only chunk ("hello world")
```

### 2.5 Folder ids

`<first 12 hex chars of client_uuid>-<counter in lowercase hex>`, e.g. `3f2a9c1b7d4e-1a`.

- `client_uuid` = 32 hex chars from 16 bytes of `/dev/urandom`, stored in
  `<data_dir>/client-uuid`, created by write-tmp + `link` so concurrent processes agree.
- Counter blocks of 1024 are leased per process by `O_CREAT|O_EXCL` of
  `<data_dir>/id-leases/<block hex>`; next block = highest existing + 1; a forked child
  leases its own. Counter = `block*1024 + next`.
- Reserved ids: `.tsync-root` (domain root namespace), `.tsync-trash`.
- An id minted locally is only a **candidate**; the id actually used is the one the
  store accepts via the claim (§4.3).

### 2.6 Manifest (file) body — binary, `tsyncm03`

Little-endian, fixed header then variable fields; no escaping anywhere.

```
off  len  field
0    8    magic "tsyncm03"
8    8    size        int64   logical file size in bytes
16   8    mtime       IEEE-754 double bits (seconds since epoch, fractional)
24   4    chunk_size  int32
28   4    count       int32   number of chunk keys
32   4    name_len    int32
36   4    link_len    int32   0 for a regular file
40   16   h1          ASCII hex (whole-file digest, seed 0)
56   16   h2          ASCII hex (seed 1)
72   name_len         leaf name bytes (arbitrary bytes)
..   link_len         symlink target bytes
..   count*33         chunk keys "<16hex>-<16hex>", in index order, no separators
```

Total length **must equal** `72 + name_len + link_len + 33*count`; otherwise
`Malformed`. Other decode failures: shorter than 72, bad magic, negative lengths.
Decoders never parse keys eagerly: key `i` is the substring at `keys_at + 33*i`, so a
32 GB file's 31,230 keys cost no heap when the manifest is `mmap`ed (`of_file`).

Semantics:

- `name` is the leaf name **as recorded at write time**. It is *not* authoritative when
  the location yields a name (a key built from the path). It exists because some
  locations are one-way (`<folder-id>/<hash>`, `.tsync-esc-<hash>` cache leaves,
  version keys, trash).
- `h1/h2` = whole-file digest over the ordered `"<key>-<len>;"` strings (§2.1), so a
  changed file's digest is recomputed from chunk keys without re-reading untouched bytes.
- Symlink: `count = 0`, `link_len > 0`, `size = len(target)`,
  `chunk_size = 8388608` (default, only to keep the field well-formed),
  `h1/h2 = xxh3(target, 0/1)`.
- Regular empty file: `size 0`, `count 1`, key = empty-body key.

Byte-exact example: `hello.txt`, content `hello world` (11 bytes), mtime
`1759140000.5`, chunk_size 8 MiB. `h = dual("d447b1ea40e6988b-b7aeb52a10fdaf2d-11;")
= d94b4e9626fdc9c1-f3f6d793ca1ea424`. 114 bytes:

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

Writer API: `builder ~name ~size ~chunk_size ~mtime ~symlink ~count` allocates the whole
body zeroed (a never-set key is 33 NULs, which no store can hold), `set b i key`
(rejects width ≠ 33), `seal b ~h1 ~h2` (rejects width ≠ 16) returns the buffer itself.
`encode` = builder+set+seal. `to_string ~name m` re-encodes with a different name (used
for version snapshots/trash); `body ~name m` returns the original bytes when the recorded
name already equals `name`.

`Manifest.Group` (local-cache concern, defined here because it is derived only from a
manifest): stored chunks are grouped `per = chunks_per_group ~chunk_size
~cache_chunk_size = max 1 round(cache_chunk_size/chunk_size)` (cache default 16 MiB → 2
stored chunks per group). Group `g` covers indices `[g*per, min(n,(g+1)*per))`, its cache
filename is the dual digest over `"<member>;"` of member keys (not first-last — runs of
identical chunks would alias), `offset` is a prefix sum of member lengths.

### 2.7 Folder marker (JSON)

At `manifests/<parent_id>/<dual(name)>`:

```json
{"dir":true,"name":"Photos","id":"3f2a9c1b7d4e-1a"}
```

Classified as a marker iff it parses as a JSON object with `"dir": true`. Missing
`name`/`id` read as `""`. Serialized by `Yojson.Basic.to_string` in the field order
above, no whitespace.

### 2.8 Anchor (JSON)

At `manifests/<folder_id>/.tsync-parent` — where the folder says it lives:

```json
{"parent":".tsync-root","name":"Photos"}
```

No `"dir"` field, so it never classifies as a marker. `in_trash a ⇔ a.parent = ".tsync-trash"`.
A marker at `manifests/P/<dual(N)>` naming id `I` is **filed here** iff
anchor(I) = `{parent=P; name=N}`, or I has no anchor (pre-anchor data: marker taken at
its word). Otherwise the marker is **disowned** (left behind by a move) and is ignored by
every reader.

### 2.9 Trash marker (JSON)

At `manifests/.tsync-trash/<Id.short()>` (16 hex from a per-process PRNG):

```json
{"dir":true,"name":"Photos","id":"3f2a9c1b7d4e-1a","path":"Archive/Photos"}
```

`path` is the domain-relative path at deletion time (for listing/restore). The folder's
anchor is rewritten to `{"parent":".tsync-trash","name":"Photos"}`. The subtree
(`manifests/<id>/…`) is untouched and unreachable from the root.

### 2.10 Folder index (binary, `tsyncidx1`)

At `manifests/<folder_id>/.tsync-index`. A cache of children's bodies so a folder read
is list + 1 GET instead of list + N GETs on stores with no multi-object read.

```
"tsyncidx1"
repeat:  be32 len | key bytes (full Stored_key string)
         be32 len | etag bytes
         be32 len | body bytes
```

Big-endian lengths (unlike the manifest). An entry is used only if the *current* listing
reports the same `etag` for that key. Only entries whose listing carried an etag are
written. Any parse error ⇒ treated as no index.
Constants: `max_children = 10_000` (not written above), `max_bytes = 64 MiB` (not read
above, judged from listing size). `worth_writing ~covered ~total = total > 1 && total <=
10000 && covered*4 < total*3` (rewrite when < 75 % covered).

### 2.11 Versions

`save_version K` (only when `Conf.versioning`): if the current manifest object exists,
server-side `copy` it to

```
tsync/<D>/versions/<folder_id>/<dual(leaf)>/<unix time in ns, decimal>
e.g. tsync/photos/versions/3f2a9c1b7d4e-1a/285b8db6c3eef5e0-7b23aee4b1561b8f/1759140000500000000
```

The "grouping key" is the manifest key with `domain_prefix` stripped
(`<folder_id>/<dual(leaf)>`), so versions follow a *folder* rename (id stable) but not a
*file* rename (leaf hash changes). A deleted file = a grouping key with versions and no
live manifest at `domain_prefix ^ grouping`. The body is the old manifest verbatim, so
its recorded name is how a deleted file's name is recovered. `History.parse` splits a
version key at its last `/` into `(grouping, timestamp)`.

### 2.12 GC run marker (JSON)

At `tsync/<D>/gc-run` on the **main store only**:

```json
{"phase":"marking","started":1759140000.123,"cursor":"m/3f2a9c1b7d4e-1a"}
```

`phase ∈ opening|marking|abandoning|closing` (legacy `reconciling` reads as `closing`);
cursor meaning depends on phase: marking → last finished namespace name (`m/<id>` or
`v/<id>`), abandoning/closing → last finished shard (`abc`). Unparseable ⇒ read as idle
by `read_run` (with a warning), but *presence* alone makes lookups use two spaces.

### 2.13 Corruption marker (JSON) and job bodies

`tsync/corrupted/<D>/<sss>/<key>`; the key is the finding, the body optional detail,
all fields optional and unknown ones ignored (written by this client for local stores,
by a bucket function for S3/GCS):

```json
{"computed":"0123456789abcdef-fedcba9876543210","size":8388608,"at":1759140000.5,"reason":"EIO"}
```

An unparseable body is still a marker. Discard request body
(`tsync/gc-jobs/<D>/<run>/<name>`): backend keys joined by `\n`. Verify request
(`tsync/verify-jobs/<D>/<sss>`): empty.

### 2.14 Journal / cursor objects (key shapes only)

Entry key `"%013Ld-%s" ms client_uuid`, stored at `journal/<YYYY-MM (UTC)>/<entrykey>`.
Cursor object body = the entry key string. Local `data_dir/last-sync-<D>` holds the last
applied entry key (written by tmp+rename). Details in the journal spec.

---

## 3. Interface

### 3.1 The seams

Each component below is an abstract interface instantiated **per domain** from a domain
configuration record, which supplies: the prefixes of §2.3, the domain's composite store
(reads walk members in order, writes land on every main, deferred targets catch up
later), the individual `members` with roles (main / replica / deferred / read-only),
limits (`max_chunk_buffers`, `max_downloads`), `versioning`, optional `chunk_size`,
`cache_root`, `data_dir`. All operations are asynchronous (futures/tasks). Process-wide
state (pools, memos, debouncers, GC-open cache) is keyed by the domain's prefix, never by
instance: a process creates several instances per domain (uploader, import, share
server, diagnostics) and they must share one budget and one view.

**ContentStore** (upload/download of file bodies):

```
upload(key: LogicalKey, src_path, mtime, chunk_size, cancel?: flag,
       on_progress?: (bytes:int, sent:bool) -> ()) -> Manifest
    errors: Cancelled, Source_changed(path), Stopping (shutdown), backend errors
upload_chunks(key, size, chunk_size, mtime,
       source: index -> ChunkSource, cancel?) -> Manifest
get_chunk(chunk_key) -> bytes                    // downloads pool
get_verified_chunk(chunk_key) -> bytes           // fails unless hash(body)==key after ≤2 reads
get_chunk_range(chunk_key, offset, length) -> bytes   // ranges pool
fast_read: bool                                   // from the store
chunk_size() -> int                               // config → store caps → 8 MiB, cached per process
known_chunk_count() -> int
fetch_manifest(key) -> Manifest?                  // None for unresolved/absent/undecodable
```

`ChunkSource` (decided with no I/O): `Stored(key)` — reuse, neither read nor sent |
`Mapped(() -> bytes)` — bytes produced in place (mmap), inside a buffer slot |
`Filled(len, fill(buffer))` — caller writes exactly `len` bytes into a pooled buffer.

**ManifestStore** (manifest objects by logical key + raw objects by stored key):

```
put_manifest(key, body)                       // may claim the parent folder chain
get_manifest_state(key) -> Body(bytes) | Absent | Unresolved
head_manifest(key) -> Entry?     delete_manifest(key)
copy_manifest(src, dst)                       // server copy then delete src; dst folders may be claimed
ensure_folder_id(dir_key) -> id               // claim self+ancestors if unknown locally
claim_folder(dir_key, id?) -> Held | Taken(other_id)
ensure_claimed(dir_key)                       // Taken ⇒ transient failure
put_folder_marker(dir_key)                    // anchor first, then marker
put_anchor(folder_id, parent, name); get_anchor(folder_id) -> Anchor?
placed(folder_id, at) -> Here | Elsewhere(anchor) | Unanchored
filed(bkey, marker) -> Here | Elsewhere(anchor)
marker_id_at(bkey) -> id?   holder_at(bkey) -> id?     // holder = marker minus disowned
list_namespace(folder_id) -> [Entry]
get_object(bkey) / get_object_opt(bkey) / get_objects(entries, pool?) -> [(bkey, bytes?)]
list_many?(folder_ids) -> [ListedFolder]      // only if the store has a native one
put_raw(bkey, bytes); delete_raw(bkey) -> existed
```

`Unresolved` = this client does not know the key's folder id (says nothing about the
store); `Absent` = the store has nothing. A caller that memoizes answers must not
memoize `Unresolved`.

**TreeReader** (the folder tree by id):

```
Entry = { bkey, body: Dir(marker) | File(manifest) }
Unusable = Unreadable(err) | Unclassifiable(err) | Disowned(anchor)
OnUnusable = Fail | Skip(report(bkey, Unusable))
children(folder_id, on_unusable=Fail, refresh_index=false, on_index?, pool?) -> [Entry]
find(folder_id, names[]) -> File(entry) | Folder(id) | Missing
fold_tree(folder_id, root_key, f(acc, containing_dir_key, entry) -> acc, acc0, ...) -> acc
```

**JournalStore**: `write_journal_entry(ops, entry_key?) -> entry_key`,
`write_journal_entry_body(bytes, entry_key?)`, `bump_cursor`, `note_cursor` (never
publishes inline), `flush_cursor`, `fetch_cursor`, `wait_cursor_change(last_seen?)`,
`read/write_last_sync_key` (local), `list_journal_keys(start_after?)` (sorted),
`get_journal_entry`, `journal_entry_published`, `rename_file(src, dst)` (= copy_manifest),
`head_manifest_opt`. The host binding also records every published entry in the local
applied-entries log *before* publishing it and sends a change notice.

**History**: `version_dir(key) -> bkey?`, `save_version(key)` (best effort, 10 s deadline
including retries, errors logged), `list_versions(key)`, `get_version(vkey)`; pure helpers
`parse(vkey) -> (grouping, ts)?`, `versions_of(grouping)`, `manifest_of(grouping)`,
`folder_versions(folder_id)`.

**ChunkSpace** (GC-aware chunk lookup): `read_run/write_run/clear_run`,
`head/get/get_range(chunk_key)` across both spaces, `promote(chunk_key) -> moved`,
`promote_all(count, key_at)`.

**Corruption**: `list() -> {entries, unverified, unreachable}`, `member_entries(member,
max_keys?) -> Unverified | Entries`, `detail(entry) -> MarkerBody?`, `is_marked(key)`
(TTL memo), `forget(key)`, `invalidate()`.

**ChunkStore** (internal to ContentStore): `store(ChunkSource) -> (key, sent)`,
`fetch`, `fetch_verified`, `fetch_range`, `known_count`; parametrised by put /
backend_key / present / fetch / corrupt / cleared / three pools / max_known.

**KeyLayout** (logical → stored): `manifest_key(key) -> bkey?`,
`folder_marker_key(key) -> bkey?`, `folder_id(key) -> id?`. Two implementations: *Inode*
(ids from local folder markers) and *Identity* (logical string is the backend key; used
by share serving).

### 3.1b How hosts use these

| Host | Instantiates | Role / differences |
|---|---|---|
| Daemon (Linux FUSE, CLI `tsync mount`) | all components, Inode layout | full read/write; uploader drives ContentStore + ManifestStore + JournalStore |
| macOS File Provider extension | ContentStore (`upload` for re-import), ManifestStore, TreeReader | same model; whole-file uploads from the extension's snapshot |
| Android app | same as daemon (embedded core) | same keys and formats; only the frontend differs |
| http-proxy server | TreeReader/ManifestStore for `list_many`, share serving with **Identity** layout | answers `list_many`/`get_many` natively for its clients; never refreshes indexes for shares |
| CLI one-shots (import, export, gc, expire, data-integrity, diagnostics) | ContentStore, ChunkSpace, Corruption, History, Retention | GC only where the main has a local path |

Host rows other than the daemon are as seen from this subsystem; the frontends spec owns
the details. All hosts read and write the same on-store formats; nothing here is host-specific except
whether a local path exists (GC, promotion) and whether the caller may write the folder
index.

### 3.2 Required backend contract

- `put` last-writer-wins, **atomic visibility** (object absent or whole — local stores
  stage `.tsync-tmp-<pid>-<seq>.tmp` then rename).
- `put_if_absent ~key ~data` → the body that holds the key afterwards (ours if we won).
  Object stores use a generation/`If-None-Match` precondition; filesystems use
  `link` (fails with EEXIST). A store that cannot arbitrate raises non-transiently.
- `get_opt` → `None` iff absent; `get_range` returns exactly `length` bytes (short only at
  EOF) or `None` if absent; `delete` returns whether it existed; `delete_multi` treats
  absent as success and pages; `copy` server-side; `list_prefix` returns `file_entry =
  {key; size; last_modified; etag option}`; filesystem listings include directory keys
  (ending `/`) and arbitrary order.
- Optional: `get_many` (native batch), `list_many` (http-proxy: listing + bodies for up
  to `max_batch_folders = 64` folders), `discard` (queue deletes to a bucket function),
  `verify_all`, `local_path` (grants rename/rm within the tree), `fast_read`, `watch`,
  `capabilities` (`chunk_size`, `max_concurrency`, `verified`, `share_url`).
  Batch packing: ≤ 256 keys, ≤ 8 MiB per request.

---

## 4. Behaviour / algorithms

### 4.1 Upload (`Remote.fill` + `publish`)

1. `count = max 1 (Chunks.count size chunk_size)`; allocate `Manifest.builder` with
   `name = leaf key`.
2. Run `each_chunk`: `W = width(chunk_slots)` workers each pulling the next index (never
   one promise per chunk — a terabyte file would allocate millions). Per index:
   - if `!cancel` → `Cancelled`; if shutdown requested → `Shutdown.Stopping`.
   - `source i` (no I/O) gives a `Chunk_source`.
   - `Chunk_store.store`: `Stored k` → `(k, false)` without a slot. `Mapped`/`Filled` →
     take a **chunk buffer slot**, obtain bytes, `key = dual(bytes)`, then
     `known?` = *corruption marker?* (if marked → not known) → *session memo?* →
     `Collection.head` (presence, either GC space). Known → remember, `sent=false`. Else
     `put chunks/<sss>/<key>`, clear any corruption memo entry for it, remember,
     `sent=true`.
   - `Manifest.set table i key`; `on_progress ~bytes:len ~sent` (inside the slot; must
     not block).
3. `publish`: re-check cancel/shutdown; compute `h1,h2` from keys; seal; if versioning,
   `save_version key` (best effort); **`Collection.promote_all`** over all keys (no-op
   unless a GC run marker exists on the main); `St.put_manifest` (claims the parent
   folder chain first, §4.3); if `cancel` was set while the put was in flight, delete the
   manifest again and raise `Cancelled` (chunks are left: content-addressed, reused by
   the successor).

`upload ~src_path` specifics: `fstat` the source fd, open a **snapshot** of the file
(`Bigstring.open_snapshot`, a reflink/copy so later user writes do not reach the pages),
size from the snapshot, chunks `mmap`ed from it (map failure ⇒ `Cancelled`). After all
chunks, `fstat` the original again; if `st_size` or `st_mtime` changed ⇒
`Source_changed` and nothing is published.

`upload_chunks` is the partial-rewrite path: unchanged chunks are `` `Stored key``
(taken on trust — a corrupt inherited chunk stays corrupt; repair is `tsync
data-integrity --repair`).

Memo: `Dedup` hashtable, cap `max_known = 100_000` (settable); at cap it is **cleared**
(not LRU). Not pre-populated by listing (cost would scale with the archive).

### 4.2 Download

- `get_chunk k` = under `downloads` pool slot (`max_downloads`), `Collection.get k`.
- `get_chunk_range` = under the separate `ranges` pool (`max_downloads` wide) — a
  waiting reader must not queue behind prefetch whole-chunk fetches.
- `get_verified_chunk` = fetch, check `dual(body) = k`; on mismatch fetch once more (same
  route); second mismatch ⇒ `Backend_error "chunk K: what the store holds does not hash to it"`.
- Pools are keyed by `chunk_prefix` in a global table, so every `Remote.Make`
  application for one domain (uploader, import, share server…) shares one budget.
- `Collection.get/head/get_range` during a GC run (only when main has `local_path`):
  try main at `chunks/…` then `chunks.from/…`, then fall back to the composite. Whether a
  run is open is cached for `order_ttl = 5 s`; on a total miss with the cache saying
  idle, the marker is re-read for real before answering "absent" (so a stale cache can
  cost latency but never a false miss).
- `fetch_manifest key` = `get_manifest_state`; `Unresolved`, `Absent` or undecodable body
  ⇒ `None` (a write caught mid-flight reads as no metadata).

### 4.3 Folder identity: claim protocol

`claim_name ~key ~id` (the marker *is* the claim):

1. `bkey = folder_marker_key key`, `parent = folder_id (parent key)`; unresolved ⇒ fail.
2. `held = put_if_absent bkey {"dir":true,"name":leaf,"id":id}`. If the store raises a
   *transient* error ⇒ propagate (caller retries). A non-transient error (store cannot
   arbitrate) ⇒ warn once per process and do a plain `put` (last writer wins; the old
   race returns).
3. If `held` is a marker for another id `m`:
   - if `m` is filed here (anchor agrees or absent) ⇒ `` `Taken m``;
   - if `m`'s anchor places it elsewhere ⇒ the marker is stale: delete it and retry
     the claim.
4. Else (we won, or it already named our id) ⇒ `put_anchor id {parent; name}` ⇒ `` `Held``.

`ensure_folder_id key` (idempotent, local-first): if the local mirror records an id,
return it (no round trip). Else `ensure_folder_id (parent key)` recursively, mint a
candidate id, `claim_name`; the id is ours on `Held` or the winner's on `Taken`; record
it locally via `Folder_ids.write` (which may answer `` `Held other`` if a local marker
appeared meanwhile — then `other` wins).

`claim_folder ?id key` (called on every publish into a folder via `ensure_manifest_key →
claim_parent`):

- root ⇒ `Held`.
- No id known locally: consult `Folder_ids.whereabouts`: `Moved` ⇒ `Held` (layout files
  by the old id); `Removed` ⇒ transient failure (don't resurrect); `Live`/`Unknown` ⇒
  claim parent, then `ensure_folder_id`.
- Id known: read the marker at its key; same id ⇒ `Held` (one GET per publish —
  `ponytail:` noted); otherwise claim parent then `claim_name`.

`ensure_claimed` turns `Taken` into a **transient** failure: the other folder's own
queued creation moves it aside, and the waiting op is retried.

`put_folder_marker key` (explicit mkdir publish): ensure parent id, ensure own id, write
**anchor first**, then plain `put` of the marker.

### 4.4 Folder move / rename / delete (store side)

Performed by the checkout/ops layer through these primitives (ordering matters):

- **Rename/move folder**: write anchor `{new_parent,new_name}` → write new marker under
  new parent → delete old marker. From the moment the anchor lands the old marker is
  disowned even if its delete is lost. Descendants untouched.
- **Rename file**: `copy_manifest` = server-side copy to the new key + delete old; then
  the body is re-put with the new leaf name (`Manifest.body ~name`), because a copy does
  not rewrite the recorded name.
- **Delete folder (to trash)**: put trash marker `manifests/.tsync-trash/<short>` (with
  `path`) → anchor to `.tsync-trash` → delete the live marker.
- **Restore** (`Retention.restore path`): find trash marker by `path`; need the parent's
  id locally (else `Parent_unknown`); anchor to new parent → put live marker → delete
  trash entry (already gone ⇒ logged). O(1): subtree untouched; no journal entry is
  written (peers learn by resync).
- **Delete file**: `delete_manifest`; history remains in `versions/`.

### 4.5 Reading the tree (`Inode_tree`)

`children ~folder_id`:

1. `list_namespace` (`list_prefix manifests/<id>/`); report the `.tsync-index` key to
   `on_index`; keep `is_child_object` entries.
2. If the domain has exactly one readable member and an index is listed (≤ 64 MiB):
   read it; use cached bodies whose recorded etag equals the listing's etag.
3. Fetch the rest via `get_objects` (native `get_many` or bounded fan-out on `slots`,
   default a shared pool "tree reads" of `max_downloads` keyed by domain prefix).
4. If `refresh_index` and `worth_writing`, write a new index (best effort, errors logged).
   Only `tsync sync --full`-style walkers that may write pass this; read-only domains
   and share serving never do.
5. Classify each body: marker JSON ⇒ `Dir`; else `Manifest.of_string` ⇒ `File`; else
   `Unclassifiable` (a write in flight). A key listed but gone on read ⇒ `Unreadable`
   (permanent "not found").
6. Policy: `` `Fail`` ⇒ any `Unreadable` fails the folder (a deleter must not mistake it
   for absence); unclassifiable is silently skipped. `` `Skip f`` ⇒ report each and
   continue; if the whole batch failed with a *permanent* error, redo key-by-key so one
   bad object does not cost its siblings.
7. For each `Dir`, read the subfolder's anchor (bounded by `slots`) and drop disowned
   markers (reported as `` `Disowned anchor`` under `Skip`).

`find ~folder_id names`: per segment one `get_opt` of `child_key(id, name)`, no
listing; a file in a non-final position ⇒ `Missing`; disowned marker ⇒ `Missing`;
unparseable body ⇒ fail (not `Missing`).

`fold_tree`: depth-first, folder visited before its descent, `f acc key entry` gets the
real logical key of the containing folder (built from marker names). Prefetching: a
doubly-linked frontier list in visit order; up to `width(slots)` requests in flight,
each asking the first unrequested folders (1 per request, or up to 64 with
`list_many`); an answered folder is replaced in the frontier by its subfolders; a folder
omitted from a `list_many` answer is fetched singly; request slot freed when all folders
of that request have been consumed. Under `Skip`, a folder failing *transiently* is
retried once after the whole walk; a second failure is reported under its namespace key.

### 4.6 Folder index lifecycle

Nothing on the write path maintains it; the listing is the truth; any mismatch costs a
read per stale child. Disabled (neither read nor written) when the domain has more than
one readable member — a body from store B must not be recorded against store A's etag.
Deleters (`purge`, `expire`) must name it via `on_index`, since no fold yields it.

### 4.7 Cursor debouncing (`File_store`)

A store rate-limits writes to one name (~1/s). `bump_cursor ek`: if ≥
`cursor_flush_interval` (2 s) since last publish ⇒ publish now; else record as pending
(forward-only max) and arm a timer to publish the newest after the interval.
`flush_cursor` publishes pending (serialized by a mutex, errors swallowed). State is
global per cursor key. Every bump must be followed by a flush before exit.
`list_journal_keys` sorts by `(ms, uuid)` (filesystem listings are unordered) and drops
names that are not entry keys (e.g. month directories).

### 4.8 Versions & retention (`Retention.expire ~cutoff`)

Order: (1) trash markers older than cutoff (by listing `last_modified`) whose folder
anchor is still in trash (or absent): delete whole subtree from `fold_tree` (incl.
indexes) then the trash marker last; a trash entry whose folder is anchored elsewhere is
skipped loudly. (2) Versions with timestamp < cutoff (ns); then version directory keys
with no survivors. (3) Journal entries with ms < cutoff except the one the cursor names.
Deletes in `Batch.per_delete` batches through the composite (all stores). Expire leaves
unreferenced chunks; reclaiming them is GC.

### 4.9 Garbage collection (mark by move)

Only possible when the domain's **main** store has `local_path` (a filesystem);
otherwise `Unsupported`. Object-store replicas/backfill targets (`deferred` members) are
told which keys to delete. One run per machine enforced by `lockf` on
`<root>/tsync/<D>/gc-run.lock` (plus an in-process flag).

Phases (each recorded in `gc-run` *before* the step it names):

1. **Opening**: `rename chunks/ → chunks.from/` (skip if `chunks.from` exists; ENOENT
   ok). `chunks/` is not recreated; writers `ensure_parent` on put.
2. Enumerate namespaces: directory names under `manifests/` (encoded `m/<id>`) and
   `versions/` (`v/<id>`), sorted; skip those `≤ cursor`. Record **Marking**.
3. **Marking**, one namespace at a time (cursor saved after each): list it (with the
   trailing `/` — omitting it would list nothing and discard the whole store), take
   `is_child_object` keys; per key (concurrently on `unit_slots`) read body: marker ⇒
   nothing; manifest ⇒ its chunk keys; **unparseable ⇒ abort the run with nothing
   discarded**. For each chunk (on `item_slots`, a separate pool to avoid nested-pool
   deadlock) `promote` = `rename chunks.from/sss/k → chunks/sss/k` (ENOENT ⇒ mkdir parent
   and retry once; second ENOENT ⇒ already moved). Optional `--verify`: re-hash each
   chunk promoted *by this call*; mismatch or unreadable ⇒ put a corruption marker on
   the main; match ⇒ delete any stale marker.
4. **Closing** (recorded before the first shard): for each shard present in either
   space, sorted, after cursor: list `chunks.from/sss/`, keep only chunk-key names, and
   for each ask `head chunks/sss/k` on the main — present ⇒ re-uploaded during the run,
   not garbage; absent ⇒ doomed. Pool doomed keys across shards; flush when ≥
   `delete_batch` keys (default `Batch.per_delete`), or 5 s since last flush, or there
   are no copies. Flush = for every deferred member: `discard` (`Queued` ⇒ durable
   request under `gc-jobs/<D>/<run>/<last shard>`; `Unsupported` ⇒ `delete_multi`); then
   delete corruption markers for the doomed keys on the main and on directly-deleting
   copies; then unlink the shard directories in `chunks.from/`; then save cursor = last
   shard. Copies are deleted **before** the main discards (crash ⇒ idempotent repeat,
   never a leak).
5. Finish: `rm -rf chunks.from/`, delete `gc-run`.

**Abandoning** (`gc --abort` or `keep`): every shard in `chunks.from/` is carried back:
if the surviving shard dir doesn't exist, rename the whole directory; else choose the
cheaper of pushing the few surviving chunks down then renaming (cost `k+1`) vs moving
the missing ones across (`m-k`); then remove the old shard dir; cursor per shard. Once
abandoning, a resumed run stays abandoning. Loops until `chunks.from/` has no shards.

Runs are resumable at any point (budget `--budget`, `units` per step, `pause`),
concurrency from `caps.max_concurrency` (default 8, clamped ≥1). Outstanding
`gc-jobs` on copies are reported at start; `retry_outstanding` re-puts them to re-fire
the bucket notification.

**Writer obligation during a run**: `promote_all` over all chunk keys immediately before
publishing a manifest. This (not the presence check) is what makes chunks skipped by the
session memo, chunks written before the rename, and uploads in flight across the open
survive. Promotion is idempotent and a no-op outside a run.

### 4.10 Corruption memo

`is_marked` lists every member's `corrupted/<D>/` (members whose `caps.verified` is false
are skipped as `Unverified`) at most once per `ttl = 5 s`, shared per chunk prefix; a
failed listing = nothing marked (an unreachable store must not stop uploads). `forget k`
after a successful re-upload. Only keys of full marker shape count (a filesystem lists
the shard directory it created).

---

## 5. Interactions

Depends on:

- **Backend** (`Backend.S`, composite `Conf.store`, `members`, `Batched`, `Retry.classify`
  transient/permanent, `Write_guard`, `Discard_job`, `Corruption_marker`).
- **Cache layout / Folder_ids** (local `.tsync-dir` markers and reverse index):
  `lookup_id`, `lookup_id_removed` (used for parent resolution so a removal under a
  since-moved folder still reaches the store), `whereabouts`, `write`.
- **Journal** for `folder_id()` minting, `Entry_key`, `encode/decode`.
- **Conf** (prefixes, limits), **Io/Bounded/Syscalls/Fs/Lock/Clock** signatures,
  `Shutdown`, `Metrics`, `Change_notice`, `Applied_entries` (Lwt File_store wrapper).

Used by:

- **Uploader / staged writes / import / FileProvider re-import** → `Remote.upload`,
  `upload_chunks`, `Store.put_manifest/claim_folder/put_folder_marker`, `File_store`
  journal writes and cursor.
- **Checkout (mirror, pulls, reads, cache groups)** → `fetch_manifest`, `get_chunk*`,
  `Inode_tree.find/children`, `Manifest.Group`.
- **Sync / resync / mirror** → `Inode_tree.fold_tree` (with `refresh_index`), journal
  listing, cursor watch.
- **Ops**: `Gc` (Collection), `Retention` (trash, versions, journal expiry),
  `Integrity` / `data-integrity` (anchors, disowned markers, corruption), rename.
- **Share server** → `Layout.Identity`, `Inode_tree` read-only.
- **Local cache** → `Manifest.of_file` on mmapped sidecars (replaced only by rename).

Main flows:

- *Write a file*: FS write → staged → uploader `upload_chunks` → chunks put/deduped →
  versions snapshot → promote_all → claim folder chain → put manifest → journal entry
  (local log then store) → cursor bump.
- *Open a file lazily*: path → `Folder_ids` ids (or `Inode_tree.find` one GET per
  segment) → manifest → `pieces` → cache group → `get_chunk_range`/`get_chunk`.
- *Resync*: `fold_tree` from `.tsync-root`, rebuild mirror markers from `Dir` entries,
  manifests from `File` entries, index written where worth it.

---

## 6. Concurrency, durability & failure semantics

- **Atomicity unit = one object.** No multi-object transactions. Correctness rests on
  orderings: chunks before manifest; `promote_all` before manifest; anchor before
  marker; trash marker before anchor before marker delete; subtree delete before trash
  marker delete; copies' deletes before main discard; GC phase recorded before its step.
- **Crash during upload**: orphaned chunks (reclaimed by GC); no manifest ⇒ file not
  visible. Crash after manifest before journal ⇒ the mirror still owes the entry
  (uploader's job).
- **Cancel** while manifest put is in flight ⇒ manifest deleted again (cleanup failure
  logged, not raised).
- **Concurrent writers to the same file**: last-writer-wins on the manifest key
  (conflict detection lives above, in the sync layer).
- **Concurrent folder creation**: arbitrated by `put_if_absent`; loser adopts winner's id.
  Stores that cannot arbitrate degrade to last-writer-wins with one warning.
- **Pools**: `chunk_slots` (max `max_chunk_buffers`, ≥1) bounds bytes in memory for all
  uploads of a domain; `downloads` and `ranges` (each `max_downloads`); `tree reads`
  (`max_downloads`, shared per domain prefix). Slots are taken inside the per-chunk
  function (never hold a slot while asking for one). GC uses two pools by nesting depth.
- **Idempotence**: chunk put (same name ⇒ same bytes), promote, discard requests (keyed
  by run+cursor), `delete_multi` (absent ok), GC resume, claim (same id ⇒ Held).
- **Offline**: reads fail; `Unresolved` vs `Absent` distinction avoids caching a
  non-answer; corruption listing failure ⇒ "nothing marked"; version snapshot failures
  swallowed (10 s deadline).
- **Durable local state** touched here: `client-uuid`, `id-leases/`, `last-sync-<D>`
  (tmp+rename). Session memos (dedup, corruption, GC TTL, resolved chunk size) are RAM.

---

### 6.1 Correctness that silently relies on cooperative scheduling

The implementation runs on a single-threaded cooperative scheduler: code between two
suspension points is never interleaved with other tasks. The following shared state is
read-modify-written without locks and would race under preemptive threads or parallel
workers; a rewrite with real parallelism must add atomics/locks (or confine the state to
one thread):

| State | Pattern relied on | Consequence if preempted |
|---|---|---|
| Upload worker index counter (`next` in `each_chunk`) | `i = next; next += 1` | two workers upload the same chunk index / one index skipped (manifest keeps a NUL key ⇒ publish of an invalid body) |
| Dedup memo (hash map + clear-at-cap) | unsynchronised insert/clear/lookup | map corruption |
| Corruption memo `marked()` | check TTL, then store the in-flight listing future and timestamp *before* awaiting, so concurrent askers share one request | duplicate listings; torn `keys`/`loaded` fields |
| Process-wide tables keyed by prefix (pools, corruption memos, cursor states, tree-read pool) | find-or-create | two pools/memos for one domain ⇒ budget exceeded twice over |
| Resolved chunk size cache | store the future on first call | benign duplicate capability request |
| Cursor debouncer (`pending`, `timer_armed`, `last_published`) | forward-only max; arm-once flag | lost bump (peers never see last entry) or double timers; the publish itself is mutex-serialised |
| GC-open cache (`order_checked`, `running`) and GC session counters/`work`/`at` | plain field updates from concurrent promote tasks | wrong counts; cursor fields torn |
| `fold_tree` frontier (doubly linked list, `parked` table, `requests` counter) | mutated by completions of concurrent fetches | corrupted frontier ⇒ folders skipped or visited twice |
| Journal entry-key `last_ms`, folder-id lease counter | `ms = max(now, last+1)`; `next += 1` | duplicate entry keys / duplicate folder ids (the id-lease file protects only across processes) |
| GC in-process `held` flag | check-then-set before taking the lockf | two collections in one process step one run (loses chunks) |

Not affected: `Manifest` builder `set` (disjoint byte ranges per index), and everything
arbitrated by the store (`put_if_absent`, renames).

## 7. Design choices & rationale

| Choice | Why (source) | Tempting alternative rejected |
|---|---|---|
| Folders keyed by stable id; children by hash of leaf | rename touches one object; hashed leaf is fixed-length and filesystem-safe (`stored_key.mli`, `layout.ml`) | path-keyed objects: a folder rename would rewrite the whole subtree |
| Folder id **claimed** via `put_if_absent`, not minted | two clients creating one dir both wrote the marker; loser's subtree silently unreachable (commit 284521fd) | local mint + plain put |
| Anchor `.tsync-parent` inside the folder's namespace | a lost delete after a move left two markers → folder at two paths; the anchor decides (c3ae1e7c); also protects trash expiry from deleting restored folders (47 real cases) | trusting markers alone |
| Binary manifest with fixed 33-byte keys | O(1) key access, mmap without heap for huge files; no escaping of names (`manifest.ml` header) | JSON (earlier formats); per-chunk lengths (derived instead) |
| Name recorded in manifest body | some locations are one-way hashes (version keys, trash, escaped cache leaves) (`manifest.mli`) | — |
| Group cache key hashes all members | first/last would alias runs of identical chunks → wrong bytes served | `"<first>-<last>"` |
| Dedup memo bounded, cleared at cap, never pre-listed | listing scales with whole archive (`chunk_store.ml`) | listing the chunk prefix at start; LRU |
| Corruption checked before memo | a marked chunk must be re-uploaded or bad bytes propagate to every file sharing it | presence == healthy |
| GC marks by **rename** not hardlink | link fallback rewrote the live set on exFAT/Android/network FS; leftover space *is* the garbage, deleted by name (18e77119) | hardlink mark; reconcile by asking every copy about 4096 shards |
| Writers never learn about GC except `promote_all` at publish | clients unaware of a run write to `chunks/` which survives | redirecting writes |
| GC marker on main only, not through the composite | replicas would carry a marker about a run that is not theirs | composite write |
| Copies deleted before main discard; discard requests durable before main proceeds | crash ⇒ idempotent repeat instead of permanent leak (nothing walks copies later) | reverse order |
| Folder index validated by etag only | S3 mtimes are whole seconds; same-size rewrite invisible (f1766969) | size+mtime validation |
| Pools keyed globally by prefix | `Remote.Make` applied per role; per-application pools admitted N× the budget | pool per functor application |
| Separate `ranges` pool | a 128 KiB read queued behind 8×1 MiB prefetches = 6 s on a phone | one download pool |
| Cursor debounced ≥ 2 s | stores 429 more than ~1 write/s to one name | publish every bump |
| Snapshot + fstat check on whole-file upload | chunks must describe bytes the file held together | reading the live file |

---

## 8. Invariants the tests pin down

- `tests/unit/stored_key` (snapshot): root/trash ids; `img.jpg` under
  `9f3a1c0428b6d5e7` ⇒ `9f3a1c0428b6d5e7/066843ea47b80079-e0e3d2bb9b72c14d`; same name ⇒
  same key; index key `…/.tsync-index`; listing classification (child vs index vs
  namespace vs temp file).
- `tests/unit/layout`: chunk shard path `abc/<key>`, key recoverable by basename, short
  key under `_`; journal month shard incl. year boundary, ordering preserved; entry-key
  parsing rejects month dirs/short/non-numeric/missing uuid; corruption `marker_key` —
  a marker earns none, `chunks.from` none, a manifest none, empty domain none, shard dir
  is not a marker; discard request body round trips (pinned against the bucket's Python).
- `tests/unit/folder_index` (snapshot): no index ⇒ 3 child reads + 1 index write;
  indexed ⇒ 1 index read, 0 child reads; one child rewritten ⇒ 1+1 reads and rewrite;
  a reader that may not write never writes; two readable stores ⇒ index neither read
  nor written.
- `tests/unit/tree_children`: empty namespace listed as dir key yields no children;
  classification by body; unusable reported once not raised, `Fail` skips
  unclassifiable too; one unreadable object doesn't cost siblings under `Skip`, `Fail`
  refuses the folder; `fold_tree` lists each folder once, overlapped but ≤ pool width,
  DFS order independent of width; `list_many` batching (root alone, rest in batches),
  omitted folders fetched singly; disowned marker skipped and reported with anchor;
  unanchored folder listed at both places.
- `tests/unit/tree_find`: file at root, non-ASCII two deep, folder answers its id, `[]`
  answers itself, unknown ⇒ Missing, file has nothing under it.
- `tests/backends/claim` (+ conformance against real stores): many clients claiming one
  name ⇒ exactly one wins and all adopt it; later claim on taken name; free name;
  released then reclaimed; nothing left over.
- `tests/unit/dedup`: corrupt key ⇒ absent without consulting store; remembered key ⇒
  present with no round trip; unknown ⇒ store asked; memo bounded and cleared at cap.
- `tests/content/known_chunks`, `upload_fanout`, `mirror_pools`, `batch_nesting`,
  `walk_fanout`: bounded concurrency, memo non-empty after upload.
- `tests/content/verified_fetch`: good body 1 read; unverified path accepts mangled;
  mangled once ⇒ reread; wrong twice ⇒ refused after exactly 2 reads.
- `tests/content/corruption`: good upload unmarked; store reports verified; scrambled
  body filed under its key with `computed`; marked chunk re-uploaded not deduped; good
  write clears marker; no empty marker shard remains.
- `tests/unit/chunk_space`: idle ⇒ one space, other never consulted; non-collectable
  store never grows a second lookup; mid-run found in either space; promoting; reads work
  after the discarded space is gone.
- `tests/backends/gc_cost`: one namespace per unit; resume doesn't re-find work; closing
  asks copies nothing but deletes; interrupted abandonment stays abandonment; many roots
  with fewer slots than roots (no deadlock); shards skipped by cursor still swept;
  collecting uses only `rename` on the filesystem; copies told nothing about the run.
- `tests/backends/gc_targets`: chunk re-uploaded mid-run is not deleted off copies.
- `tests/backends/gc_queued`: `Queued` discard returns without touching the copy; request
  reported as outstanding; can be re-sent; once consumed, reclaimed chunk and its marker
  gone, live chunk untouched; requests never mistaken for chunks.
- `tests/unit/gc_job`: two runs 0.5 s apart get distinct names; request not a chunk.
- `tests/scenario/upload`, `upload_gone`: round trip through read path; upload whose
  staged bytes vanished publishes no entry and no manifest.
- `tests/unit/manifest_naming`: recorded name vs key leaf across rename, escaping,
  staged-then-renamed.

---

## 9. Open questions / inconsistencies

1. **GC TOCTOU window for local writers.** `promote_all` reads the run marker *before*
   `put_manifest`. If a run opens between that read (None) and the put, and the target
   namespace was already marked (or is new and missed by enumeration), deduplicated
   chunks sitting in `chunks.from/` are never promoted and are reclaimed. Small window,
   but no lock/recheck closes it.
2. **GC and http-proxy clients.** `promote` needs `local_path`; a client reaching the
   main through an http-proxy has none, so `promote_all` reads the run marker through
   the proxy and then promotes nothing. Its deduped chunks (memo or `head` via the proxy,
   which also finds `chunks.from`) are not rescued unless the proxy server does it on
   its side — no code for that was found under `lib/app/frontends/http_proxy`.
3. `Manifest.int32_at` reads unsigned 32-bit into a 63-bit int, so the "negative
   length" checks never fire on 64-bit; a count ≥ 2³¹ is accepted if the length matches.
4. `manifest.mli` declares `recorded_name` twice (cosmetic).
5. Versions follow folder renames but **not file renames** (grouping key includes the
   leaf hash); after a rename the old versions appear as a "deleted file".
6. Version snapshot is a composite `copy` that fans out to every main; version
   timestamps are `gettimeofday*1e9` as float → ~µs resolution.
7. `claim_folder` costs one GET per publish into a folder (acknowledged `ponytail:`).
8. `Chunk_layout` root collisions for domains named `corrupted`/`verify-jobs`/`gc-jobs`
   are unchecked (acknowledged).
9. `upload_chunks` `` `Stored`` chunks bypass corruption checks (documented, deliberate).
10. The GC lockfile is on the main's filesystem; two hosts sharing a main over a network
    FS could both step a run (acknowledged).
11. The folder index is written only by `refresh_index` callers and disabled for
    multi-store domains; on those, S3/GCS resyncs stay at list + N GETs.
12. Manifest body `name` is written with the key's leaf, but `copy_manifest` leaves the
    old name in the body until the caller re-puts it; a reader using `recorded_name`
    in that window sees the old name (callers are told to prefer the key's leaf).

---


---

OCaml implementation notes for this subsystem: [ocaml/02-remote-model.md](ocaml/02-remote-model.md).
