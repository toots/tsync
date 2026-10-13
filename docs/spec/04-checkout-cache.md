# 04 — Checkout: local formats and the file-operation interface

This file owns two things:

1. **Every local on-disk format** of a domain's checkout: the mirror, the folder-id index, the
   staged tree, the chunk cache files, the upload records and the local intents (§2).
2. **The file-operation interface** that frontends and the request handler drive, with the
   local behaviour of each operation (§3–§4).

Everything here is local to one machine and is written only by the domain's owner (P1,
[07](07-daemon-cli.md) §2.2). Related rules owned elsewhere, referenced and not restated:

| Subject | Owner |
|---|---|
| What the owner owns; authoritative vs rebuildable entities; invariants | [data-model/local-cache.md](data-model/local-cache.md) |
| Durable write primitives, ordering rules R1–R6, the durable queue, acknowledgement points | [algorithms/durable-queue.md](algorithms/durable-queue.md) |
| Reading bytes, cache fills, verification, read-ahead, pins, the cache cap | [algorithms/read-path-and-cache.md](algorithms/read-path-and-cache.md) |
| Before-values, upload, fetch, push, projection, recovery | [algorithms/publication.md](algorithms/publication.md) |
| Enacting a merge, conflicted-copy names | [algorithms/conflict-resolution.md](algorithms/conflict-resolution.md) |
| Leaf escaping, temporary names, random ids, chunk keys and sharding | [01](01-core.md) |
| Manifest and folder-marker bytes | [02](02-remote-model.md) |
| Sync state, applied log, feed keys, commands, client identity | [03](03-journal-sync.md) |
| Arrival by state (`tsync sync --full`), import, export and their records | [05](05-ops-config.md) |
| Ownership lock, pause flag, kept walk, resync generation | [07](07-daemon-cli.md) |
| Request handler, item references, path validation for caller-supplied paths | [08](08-frontends.md), [security-model](algorithms/security-model.md) |

In this file "the mirror" is the local manifest mirror, filed by real path. With the staged
edits laid over it, it is the client's **local tree**
([publication](algorithms/publication.md) §3.2).

---

## 1. Problem

The backend files content by hash and folders by id, so it cannot cheaply answer "what is in
this folder", "what is this file called" or "what bytes are at offset N", and it may be
unreachable. The checkout exists to:

1. answer every namespace question from the local tree, without the network (a full checkout's
   tree is the whole answer: a name it lacks is a name the domain does not have);
2. serve file bytes from a content-addressed chunk cache that fetches only what is read;
3. hold unpublished writes (the staged tree), the sole copy of that data, in a store that
   neither the cache cap nor an arrival can reach;
4. record, before a key changes, the main's value at it; apply the change at once; leave the
   upload to a queue and the commit to the cycle;
5. map stable folder ids to paths and back.

---

## 2. Local on-disk formats

Every optional field and optional file below has a stated meaning when absent. No operation
requires rewriting a valid existing file into another form.

### 2.1 Layout

```
<cache_root>/<domain>/
  manifests/<escaped path>                     mirror entry of a file (manifest bytes)
  manifests/<escaped dir>/                     mirror entry of a folder (a directory)
  manifests/<escaped dir>/.tsync-dir           folder marker
  manifests/<escaped dir>/.tsync-name          name marker (only when the dir's leaf is escaped)
  manifests/<escaped dir>/.tsync-fid-<hex16>   file-id marker of a file entry (§2.3)
  scratch/<escaped path>                       frontend scratch; wiped by `full_resync` ([07](07-daemon-cli.md))
  file-ids-complete                            file-id record: a backfill pass completed (§4.10)
  file-ids-index                               file-id index snapshot, only between a clean stop and the next start (§2.3)
  scratch/.tsync-walk                          kept walk of a whole-domain listing ([08 §2.5](08-frontends.md#25-cursors-and-anchors))
  chunks/<shard>/<group key>                   whole cache body
  chunks/<shard>/<group key>.partial           partial cache body
  chunks/<shard>/<group key>.pin               pin
  staged/manifests/<escaped path>              staged manifest
  staged/manifests/<dir>/.tsync-bad-<leaf>     set-aside staged manifest (or `.tsync-bad-<n>-<leaf>`)
  staged/chunks/<body id>                      staged group body
  staged/whole/<body id>                       staged whole body
  folders/<folder id>                          reverse index entry
  folders/by-path/<md5 hex>                    removed-id record
  exports/…                                    export records ([05](05-ops-config.md))
  applied/<YYYY-MM>.log                        applied log ([03](03-journal-sync.md))
<data_dir>/sync/<domain>/…                                     sync state ([03](03-journal-sync.md) §2.7–2.8)
<data_dir>/uploads-pending/<domain>/<record id>               upload record (§2.8)
<data_dir>/intents-pending/<domain>/<record id>               local intent (§2.8)
<data_dir>/<log>/<domain>/<id>.bad                            set-aside record (or `.bad.<n>`)
```

- `<escaped path>` escapes each `/`-separated component with the mirror escaping of
  [01](01-core.md) §2.8. `<shard>` is the chunk-store shard of the group key
  ([01](01-core.md)), so the cache tree fans out like the backend's chunk tree.
- An **internal leaf** begins with `.tsync-` and is not an escape handle (`.tsync-esc-`). Every
  listing and walk of the mirror, the scratch tree and the staged tree skips internal leaves.
  Temporary files ([01](01-core.md) §2.9) are internal leaves.
- Folders exist only in the mirror. The staged tree has directories only as containers of
  staged manifests.
- Directories under `<cache_root>/<domain>`, `<data_dir>/sync`, `<data_dir>/uploads-pending` and
  `<data_dir>/intents-pending` are created 0700 and their files 0600 ([durable-queue](algorithms/durable-queue.md) §3.2).

### 2.2 Identifiers and derived names

- **Chunks per group.** For a manifest with chunk size `cs` and the configured
  `CACHE_CHUNK_SIZE` `cc`: `per = 1` if `cs ≤ 0`, else `per = max(1, ⌊(cc + ⌊cs/2⌋) / cs⌋)`
  (rounded to nearest). `per` is computed from **the manifest's own chunk size**, so a version
  written under another setting groups by its own chunks.
- **Group.** Group `g` of a manifest with `n` chunks covers chunk indices
  `[g·per, min(n, g·per + per))`. Member `i` sits at offset `Σ size(j)` over the group's earlier
  members; the group's size is the sum of its members' sizes. Only a file's last chunk may be
  short.
- **Group key.** `hex16(H₀) "-" hex16(H₁)`, where `H_s` is XXH3-64 with seed `s` over the
  concatenation, for each member in index order, of the member's chunk key string followed by
  `;`. It has the shape of a chunk key but is never one. It is not `<first>-<last>`: two groups
  can share both ends and differ inside. Two files with identical groups share one body.
- **Staged body id.** 16 lowercase hex characters, a short random id ([01](01-core.md) §2.10).

### 2.3 Mirror entries and markers

- **File entry** `manifests/<escaped path>`: exactly a manifest body ([02](02-remote-model.md)),
  whose recorded name is the real leaf of the path. Every write stamps the recorded name, so a
  file needs no name marker even when its leaf is escaped. For a path with no staged edit the
  entry is the file's local value; for a path with a staged edit it is the edit's base (§4.2). A
  file entry that does not decode is skipped by listings and answers CORRUPT to reads and stats of
  its path; an arrival by state replaces it.
- **Folder entry**: a directory. Its **folder marker** `.tsync-dir` holds the same JSON as a
  backend folder marker ([02](02-remote-model.md)): `{"dir":true,"name":"<real leaf>","id":"<folder id>"}`.
  Readers ignore unknown fields. A marker whose `dir` is not `true`, or whose `id` is missing or
  violates the folder-id grammar, is treated as absent: the folder has no id here (operations
  beneath it are UNPREPARED until an arrival by state). The root has no marker; its id is `.tsync-root`.
- **Name marker** `.tsync-name`: the raw real leaf bytes, no newline, present only in a folder
  whose leaf is escaped. It is rewritten whenever the folder is recorded, so mtime sweeps see it
  as live.
- **File-id marker.** The file id ([01 §2.7](01-core.md#27-item-references)) of a file entry with
  real leaf `l` is the marker `.tsync-fid-<hex16(XXH3-64(l, 0))>` in the entry's directory; its body
  is the 32-digit id, a newline, then `l`'s bytes. It belongs to the entry iff the body's leaf equals
  `l`. Replacing the entry at the same path keeps the marker; a rename moves it with the entry (the
  leaf rewritten), written before the source entry is removed; a removal deletes it after the entry.
  The marker is written, durably, with the entry that first occupies a path (create, merge,
  pull). An entry found without a valid marker gets a fresh one at owner start (§4.10);
  nothing on a read path writes a marker.
- **Pull marker** (lazy tree only) `.tsync-pulled`, in a folder entry and in the mirror's root: the
  wall-clock time of the last completed pull of that folder, decimal epoch milliseconds. Written
  atomically after the pull's entries. Absent means never pulled. It says that a view exists and how
  old it is, which bounds how long the view is answered while the store is silent; whether a view
  is fresh is never judged from it
  ([android §3.2](frontends/android.md#32-freshness-without-a-background-cycle)).
- **Folder position** (lazy tree only) `.tsync-position`, beside the pull marker: the number of the
  log entry the folder's view is at, in its written form ([03](03-journal-sync.md) §2.4). Written
  atomically and durably with the merge that brings the view there. Absent means never pulled.
- **View hold** (lazy tree only) `.tsync-view-hold`, beside the pull marker: decimal epoch
  milliseconds until which the folder's view is answered whatever its age. Written atomically by a
  restore, on the folder of each file it pins and on every ancestor, and only ever raised. Absent
  or past means no hold.
- **File-id index.** The owner resolves a file id to a path through an index in memory, kept with
  every marker it writes, moves or removes. The markers are its truth: a lookup answers a path only
  when that path's marker holds the id. A clean stop writes the index to `file-ids-index`, one
  record per file: the 32-digit id, a space, the path, a NUL byte. The next start reads it and
  removes it durably before any marker can change; it cannot be stale, because only an owner writes
  markers, and a marker change after the snapshot is written removes it. Without the snapshot (a crash, a first start) the start builds the index from the
  markers in the background, and marker changes made meanwhile are applied when it completes.
  Building it reads every marker, which takes minutes on a large domain, so it never runs inside a
  request: a request resolving a file id waits for the index before it takes the metadata
  serialisation ([08 §2.2](08-frontends.md#22-item-references)), within its deadline.
- Mirror entries are replaced only by rename, never modified in place, so a reader SHOULD read
  them by mapping them read-only.
- Mirror files are projections: they are written by *replace*, and made durable when a later
  step relies on them ([durable-queue](algorithms/durable-queue.md) §3.2, R2, R5).

### 2.4 Folder-index files

- **Reverse entry** `folders/<folder id>`: JSON `{"parent":"<folder id>","name":"<real leaf>"}`.
  An entry exists only for a folder whose parent has an id.
- **Removed-id record** `folders/by-path/<md5 hex>`: the name is the lowercase hex MD5 of the
  domain's key prefix ([01](01-core.md)) followed by the folder's path; the body is a folder
  id, and readers trim surrounding whitespace.
- Reverse entries are projections of the mirror's folder ids; removed-id records are history
  (§4.9).

### 2.5 Staged manifest

Version 2, one JSON object per locally edited path:

```json
{"v":2,"name":"report.txt","size":34,"mtime":1727600000.25,"chunkSize":8388608,
 "slots":[{}, {"u":"9f3c1a2b4d5e6f70"}, {"u":"9f3c1a2b4d5e6f70","o":8388608}, {"z":true}],
 "uploaded":"<base64 of a manifest body>"}
```

| Field | Meaning | Reader rule |
|---|---|---|
| `v` | format version, `2`; writers MUST write it | greater than 2: unparseable (set aside). Readers SHOULD accept it absent or below 2, meaning 2 |
| `name` | real leaf; stamped on every write and move | required string |
| `size` | the file's size; authoritative (not derived from body lengths) | required integer ≥ 0 |
| `mtime` | seconds since the epoch (wall time) | required number, integer or fractional |
| `chunkSize` | chunk size of the edit; writers MUST write it | integer > 0. Readers SHOULD accept it absent, meaning the default chunk size ([01](01-core.md)) |
| `slots` | one slot per chunk index | array; absent (and no `whole`): empty |
| `whole` | body id of a whole-file body | string; when present, `slots` is ignored |
| `h1` | the whole-file digest of a `whole` body: the key's `content_id`, computed at adoption with the edit's `chunkSize` (§4.3) | 16 lowercase hex; ignored without `whole`. Readers SHOULD accept it absent with `whole`, computing the digest from the body when it is first needed |
| `uploaded` | the upload's result: standard padded base64 of the manifest the upload produced | present: **Uploaded**; absent: **Owed**. A value that does not decode to a manifest reads as Owed (the upload is redone; dedup makes it free) |

A slot is one of:

- `{}` **Inherit**: chunk `i` of the mirror entry at the same path (the *base*);
- `{"z":true}` **Zero**: a hole, reading as zeros, with no bytes on disk;
- `{"u":"<body id>"}` or `{"u":"<body id>","o":<offset>}` **Staged**: the chunk's bytes start at
  byte `offset` (absent: 0; writers omit it when 0) of staged body `<body id>`. Writers MUST NOT
  put `u` and `z` in one slot; readers SHOULD accept both, meaning Staged.

Readers ignore unknown fields. Writers MUST write exactly `⌈size / chunkSize⌉` slots; readers
SHOULD accept more (the extra ones are ignored) or fewer (the missing ones mean Zero).

- The state (Owed or Uploaded) is part of the type: a local mutation can only produce Owed,
  which is what retires an upload's result.
- **Set-aside.** An unparseable staged manifest ([durable-queue](algorithms/durable-queue.md)
  R6) is renamed, in its directory, to `.tsync-bad-<escaped leaf>`, or
  `.tsync-bad-<n>-<escaped leaf>` with `n` the smallest integer ≥ 2 not taken: an internal leaf
  ([01](01-core.md) §2.9) that no user name escapes to. Any file of the staged manifest tree that
  does not decode is a set-aside manifest, whatever its name: it is kept in place, reported, never
  listed. A file that decodes is a staged edit, whatever its name.

### 2.6 Staged bodies

- **Group body** `staged/chunks/<body id>`: bytes in one group's layout (§2.2), sparse. A body is
  only as long as the writes that reached it; within the edit's size, bytes past its end read as
  zeros.
- **Whole body** `staged/whole/<body id>`: a complete file handed over by a frontend. It is never
  modified in place: any byte-level edit first splits it into group bodies (§4.3).
- A staged body is authoritative data; it is written by *in-place data* and made durable at
  sync and close ([durable-queue](algorithms/durable-queue.md) §3.2).

### 2.7 Cache files

- **Whole body** `<group key>`: exactly the group's bytes; its existence means *whole*. It is
  created only by the install step of [read-path-and-cache](algorithms/read-path-and-cache.md)
  §4.5 (verified, data fsynced, then renamed into place) or by a hard link from a staged body at
  promotion (§4.8). Writers MUST NOT install a body that was not verified. Readers SHOULD accept
  a whole body whether or not it was verified when written, meaning whole; an owner MAY
  re-verify any whole body at any time and MUST remove one that fails (CORRUPT).
- **Partial body** `<group key>.partial`: a sparse file in group layout, filled by range
  fetches. Which intervals it holds is known only to the owner's memory; nothing on disk
  records it, and every partial body is removed at owner start (§4.10).
- **Pin** `<group key>.pin`: an empty file whose modification time, in seconds since the epoch,
  is the pin's deadline. A pin may exist without a body.
- **Other files.** Writers MUST NOT produce any other file in the cache tree besides
  temporaries. Readers SHOULD accept other files, meaning "not a whole body": a file with another
  suffix, and a body `<group key>` that has any companion `<group key>.<suffix>` other than
  `.pin`. At owner start the owner removes them, a body before its companions (§4.10).

### 2.8 Upload records and local intents

Two durable-queue logs ([durable-queue](algorithms/durable-queue.md) §4.1; record ids are
submission ids).

**Upload record** `<data_dir>/uploads-pending/<domain>/<record id>`: one per file whose staged
content the upload queue owes the main. Body, a JSON object:

```json
{"file":["3f9a0c1b2d4e-40a","report.txt"],"attempts":2,
 "lastError":{"kind":"transient/link","detail":"connection reset"}}
```

| Field | Rule |
|---|---|
| `file` | the file key ([03](03-journal-sync.md) §2.3): folder id and leaf. The file's current path is found through the folder-id index, so a record follows its file through a folder rename |
| `attempts` | integer ≥ 0; absent: 0 |
| `lastError` | optional `{"kind", "detail"}`; `kind` is a failure-kind name of [failure-model](algorithms/failure-model.md) §3.1 in lowercase. Only reported, never acted on |

A file rename and a move aside rewrite the record's key with the staged manifest they move.

**Local intent** `<data_dir>/intents-pending/<domain>/<record id>`: one per namespace operation
whose local steps are in progress (§4.5). Body, a JSON object:

```json
{"op":{"op":"rename","key":"b/new.txt","src":"a/old.txt","is_dir":false}}
```

| Field | Rule |
|---|---|
| `op` | one feed op ([03](03-journal-sync.md) §2.9). An op this reader does not know makes the record unparseable (set aside), never run with the op dropped |

Readers ignore unknown fields. An intent is created before the first local step and removed after
the last; it is never published, and it says nothing about what is owed to the main.

- **Set-aside name** (both logs, and the sync state): `<id>.bad`, or `<id>.bad.<n>` with the
  smallest free `n ≥ 2`. It never matches the record-name grammar, so no queue lists it.

### 2.9 Files specified elsewhere

Sync state, applied log: [03](03-journal-sync.md). Export records:
[05](05-ops-config.md). Deferred job logs: [06](06-backends.md). Ownership lock, pause flag, kept
walk and resync generation: [07](07-daemon-cli.md). Client uuid and folder-id leases:
[03](03-journal-sync.md) §2.1.

---

## 3. The file-operation interface

### 3.1 Conventions

- Operations name items by logical key (a domain-relative path and a kind). The request handler
  resolves item references to keys ([08](08-frontends.md)).
- Failures are reported as failure kinds ([failure-model](algorithms/failure-model.md)). POSIX
  frontends map them to errno values ([08](08-frontends.md)).
- Operations that take a filesystem path supplied by a client (`write_whole` source,
  `assemble_to` and `fetch_range` destinations) MUST receive it only from the request handler
  after its path validation ([security-model](algorithms/security-model.md)); the interface
  itself trusts the path.
- Unless an operation is marked *network*, it touches no store and succeeds offline.
- Every operation is performed by the owner. An acknowledgement follows the levels of
  [durable-queue](algorithms/durable-queue.md) §6.

### 3.2 Serialisation within the owner

Two kinds of in-process lock serialise every check-then-act on local state (P1):

- **The metadata lock** (one per domain): every namespace change — mkdir, rmdir, rename,
  delete, symlink, revert's install, the enactment of a merge, lazy pulls, folder-index
  rebuild — together with the before-values and the local intent of such a change, and the
  choice of a batch and the `Won` step of a push ([publication](algorithms/publication.md) §4.5).
- **The key lock** (one per logical key): every content change of the key — write, truncate,
  create, whole-file handover, sync, close, the upload's result, promotion — and every removal,
  move or discard of the key's staged edit, whoever performs it.

Rules:

1. Lock order: the metadata lock before any key lock; several key locks in ascending key order.
   A holder of a key lock never waits for the metadata lock.
2. A step that acts on a fact about a key's staged edit (it exists, it is Owed, it is
   Uploaded) reads that fact while holding the key lock. A decision taken under the metadata
   lock alone is re-checked under the key lock, and re-decided if the fact changed. (Otherwise a
   merge that installs the main's removal, decided while no edit existed, discards an edit written
   a moment later.)
3. The metadata lock is never held across a store request or a cache fetch.
4. A key lock MAY be held across a cache fetch or a single store request, each bounded by
   `STEP_DEADLINE`; on expiry the operation fails with DEADLINE and changes nothing.
5. Reads take no lock; they rely on read handles (§3.3) and on the ordering of promotion
   (§4.7).
6. Each key has an **edit generation**, an in-memory counter incremented by every content change
   of the key under its key lock. The upload commits only if the generation is the one it read
   (§4.6).

### 3.3 Read handles

A **read handle** is how every reader inside the owner reads: a frontend opens one per open file
(FUSE) or per provider request, and a materialisation holds one for its duration. The handle is
also the **read stream id** of sequential detection
([read-path-and-cache](algorithms/read-path-and-cache.md) §4.7).

- `open_read(key)` resolves the key once (§4.2) and binds the handle to the key's **lineage**:
  its current content, and every later content produced by this client's own changes to the
  key (writes, truncates, promotion of those edits).
- Reads through the handle see the lineage's current content. A local write through any path is
  visible to every handle of the key.
- A change that is not in the lineage (the main's version installed by a merge, a local delete of
  the key, a replacing rename over it) **ends** the lineage: the handle keeps reading the
  content it had at that moment, as POSIX keeps an unlinked open file readable.
  - A published version is held by its manifest, and its chunks are fetched by key as needed.
    If the store no longer holds them (collected), the read fails ABSENT; it never serves
    another version.
  - A staged edit that is moved aside by a merge stays in the lineage under its new name.
  - Staged bodies referenced by a handle are not released until the handle closes
    ([durable-queue](algorithms/durable-queue.md) R3).
- A rename of the key (local, or a move aside) moves the handle's key with it.
- **Retention.** `retain(key)` returns a retention of the key's current content, mirror entry or
  staged, as it is at that instant; reads through it behave as a handle whose lineage has ended.
  `release(retention)` ends it. A frontend uses it to keep an open-and-unlinked file readable
  ([fuse](frontends/fuse.md) §4.10).
- Handles and retentions live in the owner's memory; a crash closes them all.

### 3.4 Operations

| Operation | Effect | Level / errors |
|---|---|---|
| `kind(key)` | Dir if the mirror holds a folder; File if it holds a file entry or a staged edit exists; else Absent | — |
| `stat(key)` | §3.6 | ABSENT |
| `resolve(key)` | the staged edit (with its base, if any), else the mirror entry, else nothing (§4.2) | — |
| `list_children(prefix)` | files and folders directly under `prefix` (§3.5) | lazy tree: *network*; a failed pull propagates |
| `list_tree(prefix)` | every file under `prefix`, recursively | — |
| `open_read`, `read(handle, off, buf)`, `close_read` | §3.3; bytes by [read-path-and-cache](algorithms/read-path-and-cache.md). A read is short only at end of file | *network* for uncached bytes; DEADLINE after `READ_DEADLINE` |
| `readlink(key)` | the target of a symlink manifest | ABSENT, INVALID if not a link |
| `content_id(key)` | the item identity of the key's content: the whole-file digest `h1` ([02](02-remote-model.md)) of the mirror entry, of an Uploaded staged edit, or of a whole-body staged edit (computed at adoption with the chunk size the upload will use); none for an Owed staged edit with slots | — |
| `write(key, off, bytes)` | §4.3 | visible; *network* only to copy inherited bytes |
| `truncate(key, size)` | §4.3 | visible; as write |
| `create(key, exclusive)` | an empty staged edit, replacing any content (O_TRUNC); with `exclusive`, EXISTS if the key exists | visible |
| `write_whole(key, src, base?, exclusive)` | adopt the complete file at `src` as the key's content, then close (§4.3, §4.4); `src` no longer exists at its path afterwards. With `exclusive`, EXISTS if the key exists; with a stale `base`, the write lands as a conflicted copy ([conflict-resolution](algorithms/conflict-resolution.md) §7) | durable |
| `sync(key)` | §4.4 | durable |
| `close(key)` | §4.4 | durable |
| `delete(key)` | §4.5 | durable |
| `mkdir(key, exclusive)` | §4.5; an existing folder is success unless `exclusive` (then EXISTS); an existing file is EXISTS | durable; UNPREPARED if the parent has no id |
| `rmdir(key)` | §4.5; removes the folder only if it is empty (no file, folder or staged edit beneath), as one step; EXISTS otherwise | durable; UNPREPARED |
| `remove_tree(key)` | §4.5; removes the folder and everything beneath it | durable; UNPREPARED |
| `rename(src, dst, exclusive)` | §4.5 | durable; UNPREPARED for folders whose parent has no id |
| `symlink(key, target, exclusive)` | §4.5; REFUSED unless the domain's symlink policy keeps links; with `exclusive`, EXISTS if the key exists | durable |
| `retain(key)`, `release(retention)` | §3.3 | — |
| `evict(key)` | removes every cache body of the key's mirror entry and their pins; never touches staged content or the mirror entry | visible; reference-blind: a body another file shares goes too and is refetched on demand |
| `pin(key, keep)` ("make available offline") | [read-path-and-cache](algorithms/read-path-and-cache.md) §4.8 | durable; *network* |
| `unpin(key)` | removes the pins of the key's groups | visible; reference-blind, like `evict` |
| `assemble_to(key, dst)` | the whole content into `dst` through one read handle, then `dst`'s mtime set to the content's mtime. `dst` MUST NOT exist: it is created exclusively, without following links, mode 0600 ([security-model](algorithms/security-model.md) §7.3) | *network*; EXISTS if `dst` exists |
| `fetch_range(key, dst, off, len)` | the bytes `[off, off+len)` into a new file `dst` (created as for `assemble_to`) at the same offsets, with a hole before them; the file ends where the bytes end (short at end of content; a range wholly past the end yields an empty file). Staged edits and holes are served from staged state; only the chunks covering the range are fetched | *network* |
| `revert(key, version)` | §4.6 | durable; *network*; ABSENT if no such version |

The enactment of a merge, recovery and the upload job are not frontend operations; their local
steps are §4.5–§4.7 and [conflict-resolution](algorithms/conflict-resolution.md) §4.

**`rename(src, dst, exclusive)`** follows POSIX: with `exclusive`, EXISTS if `dst` exists. Otherwise
a file replaces an existing file; a folder replaces an existing **empty** folder; a folder onto a
non-empty folder, a file onto a folder, and a folder onto a file are EXISTS (POSIX frontends map
them to ENOTEMPTY, EISDIR and ENOTDIR). A rename onto itself succeeds and changes nothing; a
folder into its own subtree is INVALID; an atomic exchange is not offered.

### 3.5 The local tree: full and lazy

A domain's tree is either **full** (desktop hosts) or **lazy** (Android); the host chooses
([08](08-frontends.md)). Both expose the same operations; they differ in what absence means.

**Listing** (both):
- names are real: escaped leaves are resolved through the file entry's recorded name or the
  folder's name marker;
- internal leaves, set-aside manifests and undecodable file entries are skipped;
- a staged edit wins over the mirror entry of the same path, and a staged-only file is
  listed;
- a folder's mtime is the time of the last change to its set of children (an entry added,
  removed or renamed in or out), as recorded here; it is stable between such changes.

**Full tree.** Absence in the local tree is absence in the domain, as of the position, or this
client's own pending removal. Listing never touches the network. The tree changes by local
operations and by merges, an arrival by state included
([publication](algorithms/publication.md) §4.7): it installs only the keys where the main
differs, keeps chunks and staged data, and never clears the tree. `clear_projection()` removes
the scratch tree only.

**Lazy tree.** Absence means "not fetched". The mirror holds the folders that were pulled, each
with the position its view is at (§2.3). A key in a folder never pulled has no local value and no
before-value, and an operation that would change one is UNPREPARED until the folder is pulled.
What a pull does, and what a push requires of the folders held, is
[publication](algorithms/publication.md) §4.11; when the host pulls is
[android](frontends/android.md) §3.2. On this side a pull:
- is refused as UNPREPARED when the folder has no local id;
- changes the folder's keys only by enacting a merge
  ([conflict-resolution](algorithms/conflict-resolution.md) §4), under the metadata lock: a name a
  pending command removes stays hidden, a name a pending command creates stays shown, and staged
  edits are kept;
- changes nothing when it fails;
- writes the folder's position and its pull marker (§2.3) when it completes;
- never writes to the store.

### 3.6 Stat and availability

- **stat** of a folder: a directory, mode 0755, link count 2, size 0, mtime as in listings.
  Of a file: the staged edit's size and mtime if any, else the mirror entry's; a symlink
  manifest is a symbolic link (mode 0777, size = target length); otherwise a regular file mode
  0644. Owner and group are the owner process's; ctime equals mtime.
- **availability** of a file:
  - `cached` if a staged edit exists;
  - else, over the mirror entry's groups: `pinned` if every group has a whole body and a
    live pin (deadline ≥ now), reporting the earliest deadline; `cached` if every group has a
    whole body; otherwise `online-only` (a partly cached file is online-only);
  - an undecodable entry is `online-only`.
  Availability is computed from files the owner replaces atomically, so a non-owner MAY compute
  it for an advisory answer ([07](07-daemon-cli.md) §2.2).

---

## 4. Behaviour

### 4.1 Names, markers and moves in the mirror

- Creating a path creates each missing component escaped; an escaped folder component gets a
  name marker.
- Every local move of a folder goes through one routine: move the mirror directory, rewrite the
  name marker from the destination leaf (if escaped), rewrite the folder marker's `name`, the
  removed-id record and the reverse entry (§4.9). A folder moved any other way becomes
  unreachable by id.
- Moving a file rewrites its entry so that the recorded name matches the new leaf.
- A move that would land on an escape handle already used by a different real name is refused
  as EXISTS ([01](01-core.md) §2.8).

### 4.2 Resolution

The single resolution point for a key: the staged edit if a staged manifest exists at the path
(Owed or Uploaded), with the mirror entry at the same path as its base; else the
mirror entry; else nothing. A staged Inherit slot with no base, or whose base lacks that
chunk, is CORRUPT, never zeros. A mirror entry whose chunk list has a hole is CORRUPT.

### 4.3 Staged writes

All steps below run under the key lock and end by incrementing the edit generation. The first
mutation of a key that has no before-value records one first: the content identity of the key's
mirror entry, or ∅ when it has none ([publication](algorithms/publication.md) §4.1).

**Base state** of a mutation (`staged_for`):
- a staged edit with a whole body: first **split** it: for each group of the domain's current
  chunk size, a new group body holding that group's bytes, one slot per chunk; replace the
  staged manifest; release the whole body once the new manifest is durable (R3);
- an Uploaded staged edit whose key has no before-value: its commit happened; promote it first
  (§4.7), then continue from the mirror entry, so an edit's base is always the value its
  before-value names;
- any other staged edit: as is (an Uploaded edit becomes Owed with the same slots);
- no edit, a mirror entry: every slot Inherit, size and chunk size from the entry, mtime now;
- neither: empty, with the domain's chunk size.

**`write(key, off, bytes)`**:
1. `st := staged_for(key)`; `new_size := max(st.size, off + len)`; extend the slots with Zero up
   to `⌈new_size / chunkSize⌉`.
2. For each chunk touched, **ensure the group body** (below), then write the chunk's slice
   into it at `slot.offset + chunk offset`.
3. Replace the staged manifest if its size or slots changed (*replace*: never torn). The mtime
   becomes now; the owner MAY hold the new mtime in memory until the next manifest write,
   sync or close.
4. Release every body the old manifest named and the new one does not, only after the new
   manifest is durable; otherwise leave them to the owner-start sweep (§4.10).

**Ensure the group body** for the group holding chunk `i` (the whole group is staged, never
part of it, because the group key covers every member):
- **Fast path**: every non-Zero member is Staged in one body at its layout offset, and that
  body has link count 1. Grow the body to the layout length if needed and turn the group's Zero
  members into Staged slots of that body (the sparse region reads as zeros).
- **Slow path**: create a new body of the layout length. For each member the write does not
  fully cover: a Staged member is copied from its old body; an Inherit member is copied from a
  **whole, verified** cache body of the base's group
  ([read-path-and-cache](algorithms/read-path-and-cache.md) §4.5; this may fetch); a Zero member
  is left sparse. Every member's slot then names the new body.
- A body whose link count is greater than 1 shares its inode with a cache body and MUST NOT be
  written in place.

**`truncate(key, size)`**: cut or extend the slots to `⌈size / chunkSize⌉` (extension with
Zero); fix the new last chunk: a Staged chunk's body is resized so the chunk ends at the new
length, an Inherit chunk whose inherited length differs from the new length gets its group
staged (slow path, covering nothing) and then resized; replace the manifest with the new size;
release unnamed bodies as in `write`.

**`create(key, exclusive)`**: with `exclusive`, EXISTS if the key exists (a folder, a file entry
or a staged edit). Otherwise replace the staged manifest with an empty edit (size 0, no slots, the
domain's chunk size); release the old bodies as in `write`.

**`write_whole(key, src, base?, exclusive)`**:
0. With `exclusive`, EXISTS if the key exists. With `base` different from `content_id(key)`, the
   key becomes `aside(key)` for the steps below; the reply names the original key as it now
   resolves ([conflict-resolution](algorithms/conflict-resolution.md) §7).
1. Adopt `src` as a new whole body: rename it into `staged/whole/<new id>`; across filesystems,
   copy it, fsync the copy, then unlink `src`.
2. fsync the body and its directory; durably replace the staged manifest with `whole` set and
   size and mtime taken from `src`. Compute the body's whole-file digest (the key's `content_id`)
   with the chunk size the upload will use, and record it as the manifest's `h1`. When the
   digest equals the key's `content_id` before the write, nothing changes: the body is released
   and no upload is queued (a replay of content the key already has).
3. Release the old bodies after the manifest is durable; then close (§4.4).

**Reading staged content**: a whole body is read directly. Otherwise per chunk: Staged reads the
body at `offset + chunk offset`, with zeros past the body's end (within the edit's size); Zero
reads zeros; Inherit reads the base's chunk through the cache. A Staged slot whose body does not
exist is CORRUPT; a body that cannot be opened or read fails with its failure kind. Neither is
ever read as zeros.

### 4.4 Sync and close

- **`sync(key)`** (the frontend's `fsync`): under the key lock, fsync every body the staged
  manifest names that was written since the last sync (all of them after an owner restart),
  fsync the directories of bodies created since then, durably replace the staged
  manifest, and make the key's before-value durable. No staged edit: nothing to do.
- **`close(key)`** (the frontend's last close after a modification, or the end of a handover):
  sync, then post an upload record for the key. The post is
  durable before `close` returns. A close without a staged edit, or without modification since the
  last close, posts nothing.

### 4.5 Namespace operations

Each runs under the metadata lock, in this order: a durable local intent (§2.8) when the local
half is more than one atomic step; the before-value of each key the operation changes and that
has none; the local half, its effects made durable; the removal of every before-value the local
value returned to; the feed line; the removal of the intent; the acknowledgement
([publication](algorithms/publication.md) §4.1, [durable-queue](algorithms/durable-queue.md)
§7.4). A local half that fails undoes nothing it did not do: its intent is completed at once or
at owner start, and the failure is returned. Completing an intent is idempotent: a removal acts
on the folder holding the recorded id, a rename moves only when the source is present and the
destination absent, and a mkdir creates the folder with the recorded id unless a folder holds it.

| Operation | Local half | Keys changed |
|---|---|---|
| `delete(key)` | take the key lock; discard the staged edit (its bodies released after the discard is durable, and not before open handles close) and its upload record; remove the mirror entry; MAY evict its cache bodies | the file key |
| `mkdir(key, exclusive)` | parent id required; an existing folder: nothing to do (EXISTS with `exclusive`); otherwise mint a folder id, which is final; create the directory, marker, reverse entry and removed-id record | the new folder's key, from ∅ |
| `rmdir(key)` | parent id required; read the folder's id; in one step under the lock, refuse a folder with any child (mirror entry, folder or staged edit) as EXISTS, else remove it; keep the removed-id record | the folder's key, to ∅ |
| `remove_tree(key)` | one local intent; the key locks of every staged key beneath; then, children before parents, every file beneath as `delete` does and every folder as `rmdir` does, the folder itself last. One feed line holds a `delete` per file and an `rmdir` per folder, in that order | every file key beneath, to ∅; every folder key beneath and the folder's own, to ∅ |
| `rename(src, dst, exclusive)` of a file | the POSIX rules of §3.4; take the key locks of `src` and `dst`; replacing an existing `dst` discards `dst`'s staged edit and mirror entry (an open handle on it keeps its content, §3.3); move the staged manifest, its upload record and the mirror entry (§4.1), re-stamping names | the source key, to ∅; the destination key |
| `rename(src, dst, exclusive)` of a folder | the POSIX rules of §3.4; the parent of `src` must have an id; take the key locks of every staged key under the folder; move the mirror directory and the staged directory; reparent the id (§4.9) | the folder's key, and nothing beneath it |
| `symlink(key, target)` | write a symlink manifest as the key's mirror entry, under the key's lock | the file key |

- `remove_tree` is not one command: the theory removes a folder only when it is empty, so the
  pending set gets one command per item removed, pushed like any other. A file a peer added
  beneath meanwhile brings its folder back at the next arrival
  ([conflict-resolution](algorithms/conflict-resolution.md) §8.1).
- A file created and deleted before any push leaves no before-value: the delete brings the key
  back to ∅, its before-value.
- A folder renamed and renamed back leaves none either.
- A rename of a file onto itself, or any operation that changes no key, records nothing.

The enactment of a merge ([conflict-resolution](algorithms/conflict-resolution.md) §4) uses these
same local steps and locks; a move aside is `rename`'s local half.

### 4.6 Upload

The upload job for an upload record ([publication](algorithms/publication.md) §4.2,
[durable-queue](algorithms/durable-queue.md) §4.9):

1. Under the key lock, read the key's state and its edit generation `g`:
   - an **Owed** staged edit: continue at step 2;
   - an **Uploaded** staged edit, or **no staged edit**: complete the record.
2. Without the lock, upload the chunks the main lacks ([02](02-remote-model.md) §4.1): Inherit
   slots reuse the base's chunk keys (no upload); Zero slots and bytes past the slots are zero
   chunks; Staged slots read their bodies (§4.3, never zeros for an unreadable body); a whole
   body is uploaded whole. Build the manifest.
3. Under the key lock: if the edit generation is no longer `g`, end CANCELLED (a later close or
   the owner-start adoption owes the newer state). Otherwise durably replace the staged manifest
   as **Uploaded** with that manifest.
4. Complete the record and wake the cycle.

- The job writes chunks and nothing else: no manifest, no log entry, no tree record. What it
  uploaded becomes part of the main's tree only when the cycle commits the key's command, which
  carries the manifest ([publication](algorithms/publication.md) §4.5).
- A whole body is never modified in place, so a whole-body upload needs no snapshot. Group bodies
  may be written during step 2; step 3's generation check discards what that upload read.
- A commit refused for missing chunks is the push's to handle
  ([publication §4.5](algorithms/publication.md#45-push)); the staged bodies it needs are still
  held (§4.7).

**`revert(key, version)`** (versioning required; *network*): fetch the version's manifest; under
the metadata lock and the key lock, record the key's before-value if it has none, discard the
staged edit (the user asked for the version), increment the edit generation, and durably install
the version's manifest as the key's mirror entry. It is a local operation like any other: the
cycle commits it, and the commit's gate checks that the main still holds the version's chunks.

### 4.7 Promotion

Promotion turns a committed staged edit into the mirror entry. It runs under the key lock, after
the `Won` step of a push for every staged edit of the batch whose before-value that step dropped,
and at owner start for every Uploaded staged edit whose key has no before-value (§4.10). Each
step is idempotent.

1. Re-read the staged manifest. If it is not Uploaded, stop: a later mutation retired the
   upload's result, and its own close or adoption owes the newer state.
2. Chunked edits: for each group of the uploaded manifest whose members are all Staged or Zero
   and at least one Staged:
   - if every Staged member sits in one body at its layout offset: resize that body to the
     group's size (zeros for Zero members), fsync it, and hand it to the cache by hard link
     (§4.8);
   - otherwise, or when links are unsupported: install the group from the staged bytes as a
     whole body ([read-path-and-cache](algorithms/read-path-and-cache.md) §4.5).
   Groups with an Inherit member keep their key; a cached body for them is still right. A whole
   edit hands nothing to the cache.
3. Durably replace the mirror entry with the uploaded manifest.
4. Release the staged manifest and fsync its directory.
5. Release the staged bodies, except those an open read handle references (released when the
   last such handle closes).

A staged edit is never promoted before its commit: until the entry that carries its manifest
exists, nothing on the main names its chunks, and the staged bodies are the only bytes a refused
commit can upload them from again.

The order is load-bearing: a reader that resolved either representation finds its bytes still
on disk, because bodies go last and a cache body is a second name for the same inode.

### 4.8 Handing a staged body to the cache

- A hard link from the staged body's path to `chunks/<shard>/<group key>`, never a rename: both
  names stay readable across the flip.
- Before linking, a partial body of the same group is removed under the cache's body lock
  ([read-path-and-cache](algorithms/read-path-and-cache.md) §4.4).
- EEXIST: the cache already holds that group whole (content addressing makes it equal); done.
- EPERM, ENOSYS, EOPNOTSUPP, EXDEV or EMLINK: links are unsupported on this cache root; the owner
  remembers this for its lifetime and installs by copy instead. Any other error fails the
  promotion step with its kind.
- After linking, the body's mtime is set to now, so the cap does not see it as old as the
  write.

### 4.9 Folder-id index

- `lookup_id(key)`: the root's id is `.tsync-root`; any other folder's is its marker's. A
  lookup **never mints**: minting on a read would recreate a deleted folder from a `stat`.
- `write(key, marker)`: if the folder already holds a different id, answer *held(id)* and change
  nothing (references never change under a folder); else `replace`.
- `replace(key, marker)`: create the directory chain; rewrite the name marker if the leaf is
  escaped; write the folder marker; write the removed-id record; if the parent has an id, write
  the reverse entry with the parent's id and **the leaf of `key`** (not the marker's name,
  which may spell a pre-move leaf).
- `lookup_id_removed(key)`: the live id, else the removed-id record's id. The record outlives
  the folder so the change feed can name an item under a removed or moved folder.
- `key_of_id(id)`: climb reverse entries to `.tsync-root` with a seen set (a cycle answers
  nothing), fold the names into a path, and accept it only if `lookup_id(path) = id`. A stale
  entry costs an answer, never a wrong folder.
- `whereabouts(key)`: *live(id)*; else, through the removed-id record, *moved(id, key_of_id(id))*
  or *removed(id)*; else *unknown*.
- `forget(key)`: remove every folder marker under the subtree and the removed-id record.
- `reparent(src, dst)`: after a move, rewrite the moved folder's marker name, reverse entry and
  removed-id record.
- `rebuild()`: walk the mirror; for every folder with a marker under a parent with an id, write
  the reverse entry; a folder without a marker cuts the chain (its children get no entry); then
  remove every reverse entry not written by the walk (the `by-path` directory is not an entry).
  Removed-id records whose path holds no live folder and whose modification time is older than
  `REMOVED_ID_RETENTION` are removed.

### 4.10 Owner start: local recovery

Before the first cycle ([07](07-daemon-cli.md) §3.2), with no request served yet, the owner
brings the checkout to a consistent state:

1. Remove temporary files in the domain's local areas whose owning process is not alive
   ([01](01-core.md) §2.9).
2. Remove every cache file that is not a whole body or a pin (§2.7), each body before its
   companions.
3. Read every file of the staged manifest tree. Rename each one that does not decode and whose
   name is not already a set-aside name to its set-aside name (§2.5); report every
   set-aside manifest. The set of **named bodies** is every body id named by a decodable manifest,
   plus, for each set-aside manifest, every maximal run of exactly 16 lowercase hex characters in
   its bytes. False positives only keep a body longer.
4. Recover the sync state: the local intents (completed as §4.5 says), the arrival record and
   the before-values
   ([publication §4.8](algorithms/publication.md#48-crash-recovery) steps 1–3). This needs no
   network.
5. Promote every Uploaded staged edit whose key has no before-value (§4.7): its commit happened.
6. Release every staged body not in the named set. The release is exact, with no grace
   period, because only the owner writes the staged tree and nothing else runs yet.
7. **Adopt** every Owed staged edit that no upload record names: post a fresh record for it (the
   crash fell between a write and its close).
8. Anchor the cache counts ([read-path-and-cache](algorithms/read-path-and-cache.md) §4.9); this
   MAY run lazily.
9. Load the file-id index (§2.3) from its snapshot and remove the snapshot, else start building
   it in the background; then give a file-id marker to every mirror file entry without a valid one, durably. On a lazy
   tree this covers the entries present. A crash midway leaves entries without a marker, which the
   next start completes; no id was reported for them yet. Once a pass completes, the
   **file-id record** says so durably and later starts skip this step: every write path gives an id
   from then on, and a bulk pass that writes markers without a fsync each (an arrival by state)
   re-mints a torn one when it is redone.

The in-flight record is recovered by the first cycle, which needs the store
([publication](algorithms/publication.md) §4.8).

Set-aside manifests are never adopted, promoted or removed automatically. Status reports them;
only an explicit user request ([07](07-daemon-cli.md)) removes one, after which its bodies become
unnamed.

### 4.11 Periodic maintenance

Run by the owner ([07](07-daemon-cli.md) §6); each task is independent and a failing task does
not stop the others.

| Task | Rule | Owner of the rule |
|---|---|---|
| Cache cap | after every upload and every `HOUSEKEEPING_INTERVAL` | [read-path-and-cache](algorithms/read-path-and-cache.md) §4.9 |
| Applied-log prune | daily | [03](03-journal-sync.md) |
| Export-record sweep | daily | [05](05-ops-config.md) |
| Removed-id records | daily, the retention rule of §4.9 | this file |
| Temporary files | daily, §4.10 step 1 | [01](01-core.md) §2.9 |

---

## 5. Parameters

| Name | Recommended | Constraint / effect |
|---|---|---|
| `CACHE_CHUNK_SIZE` | 16 MiB | the local disk unit; with 8 MiB chunks, `per = 2` |
| `STEP_DEADLINE` | 15 s | bound on a store request or fetch made under a key lock |
| `REMOVED_ID_RETENTION` | `FEED_RETENTION` ([03](03-journal-sync.md) §5) | MUST NOT be shorter: a feed line naming the folder may still be read |
| `HOUSEKEEPING_INTERVAL` | 60 s | cap cadence |

---

## 6. Conformance

An implementation MUST exhibit the following.

**Formats**
- Group keys and `per` follow §2.2 exactly; a group shared by two files has one key and one
  body path.
- A staged manifest round-trips slots with offsets; a manifest without `v`, `o` or
  `chunkSize` decodes as specified; a version-3 manifest is set aside, never decoded.
- An upload record or a local intent with an unknown op or a torn body is set aside and reported,
  never completed. An upload record follows its file through a rename of the file and of any
  folder above it.

**Staged writes**
- A 2-byte write into chunk 1 of a published 3-chunk file (one chunk per group) stages exactly
  that chunk (slots Inherit, Staged, Inherit); a full overwrite of the chunk stages it without
  copying; an append grows the slots; truncating to within chunk 1 cuts the slots; growing adds
  Zero slots that read as zeros.
- An edit inside one chunk of a cold file fetches that chunk only; an aligned whole-chunk write
  and a grow fetch nothing; on publish only Staged chunks are uploaded and Inherit chunks keep
  their keys.
- With several chunks per group, a small write stages the whole group in one body at layout
  offsets; reads merge staged and inherited bytes.
- A write that must copy an inherited member copies it from a whole, verified cache body.
- A byte write into a whole-body edit splits it into group bodies first.
- A handed-over whole file is moved into the staged tree, not copied, when on the same
  filesystem; its mtime becomes the published mtime; `content_id` is known at once and equals
  the published `h1`.
- Only `close` (and a handover) posts an upload; write, truncate and create post nothing. Staged
  edits survive removal of the whole chunk cache, and restart recovery uploads and commits them.
- The first mutation of a clean key records its before-value; a second mutation does not change
  it; a mutation that brings the key back to it removes it.
- Deleting a staged file releases its bodies; the cache cap never counts or removes staged
  bodies.
- `exclusive` create, mkdir, symlink, handover and rename answer EXISTS on an existing name and
  change nothing; a handover with a stale `base` lands as a conflicted copy and leaves the key's
  content unchanged.

**Upload and promotion**
- A one-chunk edit of a published file uploads one chunk object, and no other object.
- An upload redone after a lost result uploads nothing (dedup); a replayed promotion uploads
  nothing.
- A write that arrives while an upload is in flight wins: the upload ends CANCELLED and the
  main holds the newer content once its close is uploaded and committed.
- Reads and writes concurrent with a promotion all succeed: readers always get full-length, exact
  bytes, and alternating whole-file handovers never publish a mixed body. A write inside the
  promotion window retires the pending promotion.
- A staged edit is not promoted before its commit: with pushes held, an Uploaded edit keeps its
  staged bodies, and a commit refused for missing chunks uploads them again and succeeds.
- An upload record whose staged edit vanished is completed and uploads nothing.
- A whole-file promotion leaves the cache without the file's groups.

**Crashes** (each at every step, [durable-queue](algorithms/durable-queue.md) §8)
- A crash between a group body's creation and the manifest that names it leaves the previous
  edit intact and readable; the new body is released at the next owner start.
- A set-aside staged manifest's bodies survive the owner-start sweep.
- A staged edit with no upload record is adopted at owner start; one with no before-value takes
  its base's identity; a local intent and an arrival record left by a kill are completed.

**Namespace and index**
- Absence in the local tree is domain absence, answered without touching the store (full tree).
- Lazy tree: listing a folder on a device that never synced fetches that folder only and
  takes folder ids from the store; a remote delete prunes the entry; a pull is never skipped
  because of pending work, yet local unpublished creations stay listed and local unpublished
  removals are not listed back; a pull that meets a clashing pending edit keeps it as a conflicted
  copy; a failed pull changes nothing.
- After a rename, only the new name is listed and resolvable.
- `fetch_range` writes the range at its true offset into a new file with a hole before it and
  ends where the range ends; a range past the end is short and one wholly past the end yields an
  empty file; only the covering chunks become local; staged edits and grow holes are served from
  staged state. `assemble_to` and `fetch_range` refuse an existing destination.
- A file opened, then unlinked or replaced, keeps reading its content through a retention until
  released.
- `evict` never removes staged content.
- A renamed file's and folder's recorded names follow the rename; escaped names list as real
  names.
- The folder index never names a parent on a child's behalf; a minted folder resolves at every
  depth; a rename keeps the id; a removed folder is unresolvable by `lookup_id` but found by
  `whereabouts`; a corrupted reverse entry never resolves to another folder and `rebuild` fixes
  it; a cycle resolves to nothing; `write` refuses to change a held id and `replace` changes it.
- `rmdir` refuses a folder holding a file, a folder or a staged edit, and changes nothing.
- `rename` follows the POSIX replacement rules of §3.4.
- A merge that installs the main's removal of a file that has a staged edit here never discards
  the edit, whatever the interleaving with a concurrent write.
- An arrival by state changes the mirror only where the main differs, keeps chunks and staged
  data, reports its changes as feed ops (`delete`, `rmdir` with id, a folder move as `rename`),
  and changes nothing after a walk that failed.

---

## 7. Rationale

| Choice | Reason |
|---|---|
| Staged data in its own tree, not a spared region of the cache | The cap and an arrival cannot delete sole-copy bytes because they cannot address them, not because a filter spares them. |
| Mirror filed by real path with escape handles and name markers | A walkable tree without the network, and names safe on FAT and NTFS. |
| Group of several chunks per local file | Network granularity (the chunk) differs from disk granularity; fewer files and walks. |
| Group key hashed over member keys | Two groups sharing first and last chunk once aliased and served wrong bytes. |
| Staged body per group in group layout, promoted by hard link | Promotion by copy wrote a large file twice. |
| The upload's result inside the staged manifest | One atomic object; a later write retires it naturally. |
| Upload commits only on an unchanged edit generation | A cooperative cancel alone let a torn manifest reach the store. |
| One metadata lock that never spans a store request | A slow link must not freeze the mount. |
| Key-lock re-check of staged facts | A decision taken without it discarded a fresh local edit when a merge installed a removal. |
| Partial bodies live only for the owner's lifetime | No record on disk can ever claim bytes the disk lacks, whatever crashes or power losses happen; a restart costs a few range refetches. |
| Set-aside names are internal leaves | A user's file named `x.bad` is not a set-aside object. |
