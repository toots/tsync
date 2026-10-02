# 04 — Checkout: local formats and the file-operation interface

This file owns two things:

1. **Every local on-disk format** of a domain's checkout: the mirror, the folder-id index, the
   staged tree, the chunk cache files and the WAL record (§2).
2. **The file-operation interface** that frontends and the request handler drive, with the
   local behaviour of each operation (§3–§4).

Everything here is local to one machine and is written only by the domain's owner (P1,
[07](07-daemon-cli.md) §2.2). Related rules owned elsewhere, referenced and not restated:

| Subject | Owner |
|---|---|
| What the owner owns; authoritative vs rebuildable entities; invariants | [data-model/local-cache.md](data-model/local-cache.md) |
| Durable write primitives, ordering rules R1–R6, the durable queue, acknowledgement points | [algorithms/durable-queue.md](algorithms/durable-queue.md) |
| Reading bytes, cache fills, verification, read-ahead, pins, the cache cap | [algorithms/read-path-and-cache.md](algorithms/read-path-and-cache.md) |
| WAL state machine, publishing, reconcile, applying peers' entries | [algorithms/wal-and-journal.md](algorithms/wal-and-journal.md) |
| Arrival and Publish decisions, conflicted-copy names, asides | [algorithms/conflict-resolution.md](algorithms/conflict-resolution.md) |
| Leaf escaping, temporary names, random ids, chunk keys and sharding | [01](01-core.md) |
| Manifest and folder-marker bytes | [02](02-remote-model.md) |
| Applied log, last-sync mark, entry keys, journal ops, client identity | [03](03-journal-sync.md) |
| Resync, import, export and their records | [05](05-ops-config.md) |
| Ownership lock, pause flag, kept walk, resync generation | [07](07-daemon-cli.md) |
| Request handler, item references, path validation for caller-supplied paths | [08](08-frontends.md), [security-model](algorithms/security-model.md) |

In this file "the mirror" is the local manifest mirror: this client's projection of the
domain's namespace, filed by real path.

---

## 1. Problem

The backend files content by hash and folders by id, so it cannot cheaply answer "what is in
this folder", "what is this file called" or "what bytes are at offset N", and it may be
unreachable. The checkout exists to:

1. answer every namespace question from the mirror, without the network (a full checkout's
   mirror is the whole answer: a name it lacks is a name the domain does not have);
2. serve file bytes from a content-addressed chunk cache that fetches only what is read;
3. hold unpublished writes (the staged tree), the sole copy of that data, in a store that
   neither the cache cap nor a resync can reach;
4. record every change as owed work before doing it, apply its local half at once, and hand
   the store half to a queue;
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
  manifests/<escaped dir>/.tsync-own-<hex16>   own marker of a file entry this client stored
  manifests/<escaped dir>/.tsync-fid-<hex16>   file-id marker of a file entry (§2.3)
  scratch/<escaped path>                       frontend scratch; wiped by resync ([07](07-daemon-cli.md))
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
<data_dir>/journal-pending/<domain>/<entry key>               WAL record
<data_dir>/journal-pending/<domain>/<submission id>           WAL record submitted by a non-owner, until re-keyed
<data_dir>/journal-pending/<domain>/<id>.bad                  set-aside WAL record (or `.bad.<n>`)
<data_dir>/claims-pending/<domain>/<record id>                pending folder-claim confirmation
```

- `<escaped path>` escapes each `/`-separated component with the mirror escaping of
  [01](01-core.md) §2.8. `<shard>` is the chunk-store shard of the group key
  ([01](01-core.md)), so the cache tree fans out like the backend's chunk tree.
- An **internal leaf** begins with `.tsync-` and is not an escape handle (`.tsync-esc-`). Every
  listing and walk of the mirror, the scratch tree and the staged tree skips internal leaves.
  Temporary files ([01](01-core.md) §2.9) are internal leaves.
- Folders exist only in the mirror. The staged tree has directories only as containers of
  staged manifests.
- Directories under `<cache_root>/<domain>`, `<data_dir>/journal-pending` and
  `<data_dir>/claims-pending` are created 0700 and their files 0600 ([durable-queue](algorithms/durable-queue.md) §3.2).

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
  file needs no name marker even when its leaf is escaped. A file entry that does not decode is
  skipped by listings and answers CORRUPT to reads and stats of its path; a resync replaces it.
- **Folder entry**: a directory. Its **folder marker** `.tsync-dir` holds the same JSON as a
  backend folder marker ([02](02-remote-model.md)): `{"dir":true,"name":"<real leaf>","id":"<folder id>"}`.
  Readers ignore unknown fields. A marker whose `dir` is not `true`, or whose `id` is missing or
  violates the folder-id grammar, is treated as absent: the folder has no id here (operations
  beneath it are UNPREPARED until a resync). The root has no marker; its id is `.tsync-root`.
- **Name marker** `.tsync-name`: the raw real leaf bytes, no newline, present only in a folder
  whose leaf is escaped. It is rewritten whenever the folder is recorded, so mtime sweeps see it
  as live.
- **The view.** A path's file entry is this client's *view* of the path
  ([conflict-resolution](algorithms/conflict-resolution.md) §3.3): the record this client last
  installed from a peer's entry, applied, or itself stored. An upload that stored a manifest makes
  it the path's file entry even when the promotion of that upload is later abandoned (§4.6); a
  local rename moves the entry; a local delete removes it.
- **Own marker.** The view also records whether this client stored it (*own*). The marker of a
  file entry with real leaf `l` is `.tsync-own-<hex16(XXH3-64(l, 0))>` in the entry's directory;
  its body is `l`'s bytes. The view is own iff the marker exists and its body equals the leaf. It
  is written, durably, after the entry when this client's upload or republish stored the entry's
  manifest; it is removed before the entry is replaced by any other record (a peer's, a resync's,
  a pull's) and when the entry is removed; a file rename moves it with the entry. An entry
  without a marker is not own; a lost marker reads as not own, which only falls back to the conflict rule used without `base`.
- **File-id marker.** The file id ([01 §2.7](01-core.md#27-item-references)) of a file entry with
  real leaf `l` is the marker `.tsync-fid-<hex16(XXH3-64(l, 0))>` in the entry's directory; its body
  is the 32-digit id, a newline, then `l`'s bytes. It belongs to the entry iff the body's leaf equals
  `l`. Replacing the entry at the same path keeps the marker; a rename moves it with the entry (the
  leaf rewritten), written before the source entry is removed; a removal deletes it after the entry.
  The marker is written, durably, with the entry that first occupies a path (create, peer put,
  resync, pull). An entry found without a valid marker gets a fresh one at owner start (§4.10);
  nothing on a read path writes a marker.
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
- Both are projections of the mirror's folder ids, except that removed-id records are history
  (§4.9).

### 2.5 Staged manifest

Version 2, one JSON object per locally edited path:

```json
{"v":2,"name":"report.txt","size":34,"mtime":1727600000.25,"chunkSize":8388608,
 "slots":[{}, {"u":"9f3c1a2b4d5e6f70"}, {"u":"9f3c1a2b4d5e6f70","o":8388608}, {"z":true}],
 "published":"<base64 of a manifest body>"}
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
| `base` | the **base** of the edit ([conflict-resolution](algorithms/conflict-resolution.md) §3.3): the content identity `h1` of the view the edit started from | 16 lowercase hex, or `null` for *none* (the edit started from no record); absent: *unknown* |
| `published` | the commit record: standard padded base64 of the manifest the upload produced | present: **Committed**; absent: **Owed**. A value that does not decode to a manifest reads as Owed (the upload is redone; dedup makes it free) |

A slot is one of:

- `{}` **Inherit**: chunk `i` of the published manifest at the same path (the *base*);
- `{"z":true}` **Zero**: a hole, reading as zeros, with no bytes on disk;
- `{"u":"<body id>"}` or `{"u":"<body id>","o":<offset>}` **Staged**: the chunk's bytes start at
  byte `offset` (absent: 0; writers omit it when 0) of staged body `<body id>`. Writers MUST NOT
  put `u` and `z` in one slot; readers SHOULD accept both, meaning Staged.

Readers ignore unknown fields. Writers MUST write exactly `⌈size / chunkSize⌉` slots; readers
SHOULD accept more (the extra ones are ignored) or fewer (the missing ones mean Zero).

- The state (Owed or Committed) is part of the type: a local mutation can only produce Owed,
  which is what retires a pending promotion (§4.7).
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

### 2.8 WAL record

`<data_dir>/journal-pending/<domain>/<entry key>`, one per unit of owed work. The file name is
the entry key the work will be published under ([03](03-journal-sync.md) §2.2). Only the owner
mints entry keys. A record submitted by a non-owner
([durable-queue](algorithms/durable-queue.md) §4.2) is named with a submission id instead
(`<20-digit µs>-<8-digit seq>-<pid>`), and the owner re-keys it when it adopts it. The body is a
JSON object:

```json
{"state":"intent","attempts":2,
 "ops":[{"op":"rename","key":"b/new.txt","src":"a/old.txt","is_dir":false,"size":1234}],
 "priors":{"0":"3f2a9c1e0b7d4455"},
 "localFrom":{"0":"a/old (conflicted copy from laptop).txt"},
 "fids":{"0":"6c1e0b9a2f4d47e8a3b5c7d9e1f20384"},
 "lastError":{"kind":"transient/link","detail":"connection reset"}}
```

| Field | Rule |
|---|---|
| `state` | `intent`, `prepared` or `executed` ([wal-and-journal](algorithms/wal-and-journal.md) §4.1). Any other string reads as `intent`: a record never claims a state it did not earn |
| `attempts` | integer ≥ 0; absent: 0 |
| `ops` | array of journal ops ([03](03-journal-sync.md) §2.3). Every element MUST decode; a record with an op this reader does not know is unparseable (set aside), never run with the op dropped |
| `priors` | optional object mapping an op's index (decimal string) to the **expected prior record** of that op ([conflict-resolution](algorithms/conflict-resolution.md) §3.3), for `delete` and file `rename` ops only: the prior's content identity `h1` (16 lowercase hex), or `null` for *none*. An index absent from the object (or no `priors` field) means *unknown*. Local only: never published |
| `localFrom` | optional object mapping an op's index to the path the file occupies locally until the op's move is redone; written only while a retargeted record is in `intent` ([conflict-resolution](algorithms/conflict-resolution.md) §4.6) and removed with the move to `prepared`. Local only |
| `fids` | optional object mapping an op's index to the file id ([01 §2.7](01-core.md#27-item-references)) of the file a `put`, `delete` or file `rename` op names, read when the local operation ran, before a delete removed its marker. Copied as `fid` into the op's applied-log copy when the entry is noted ([03 §2.7](03-journal-sync.md#27-applied-log-local)). An index without one: the applied-log copy carries none. Local only: never published |
| `lastError` | optional `{"kind", "detail"}`; `kind` is a failure-kind name of [failure-model](algorithms/failure-model.md) §3.1 in lowercase. Readers SHOULD accept `transient` and `permanent` (meaning a retryable and a non-retryable kind); writers MUST NOT produce them. Only reported, never acted on |

Readers ignore unknown fields; an op index in `priors`, `localFrom` or `fids`
that names no op, or a value of the wrong type, makes the record unparseable.

Writers MUST NOT produce the following forms; readers SHOULD accept them as stated:
- a record whose `ops` is an empty array: it owes nothing and is completed, not set aside;
- an **op-list body**, one that is not a JSON object with a `state` field: a sequence of journal
  ops, one JSON object per line, empty lines ignored, meaning state `intent`, attempts 0, no other
  field. If any non-empty line does not decode, or the body yields no op, the record is
  unparseable.

- A record is a **metadata record** iff it has at least one op and no `put`. Record kinds are
  [wal-and-journal](algorithms/wal-and-journal.md) §4.1.
- **Re-keying** renames the record file to its new name in one atomic rename followed by a
  directory fsync, so at every instant exactly one of the two names exists. The new key is freshly
  minted by the owner, and no other process creates entry-key names, so the target never exists
  (an implementation MAY use a no-replace rename where the platform has one).
- **Set-aside name**: `<id>.bad`, or `<id>.bad.<n>` with the smallest free `n ≥ 2`. It never
  matches the record-name grammar, so no queue lists it.
- A record whose entry key names another client is never run nor deleted, and is reported
  ([durable-queue](algorithms/durable-queue.md) §4.2).

### 2.9 Pending folder-claim confirmation

`<data_dir>/claims-pending/<domain>/<record id>`, a durable-queue log
([durable-queue](algorithms/durable-queue.md) §4.1; record ids are submission ids). One record per
tentative claim that awaits confirmation ([data-model/backend](data-model/backend.md) §6.2 owns the
protocol). The owner writes it durably when the claim's create-if-absent has landed, before any
content is filed under the tentative id, and removes it once the claim is final or has been set
aside. Body, a JSON object:

```json
{"id":"3f2a9c1e0b7d-1a","parent":".tsync-root","name":"Photos","landedAt":1727600000.25,
 "attempts":0,"lastError":{"kind":"transient/link","detail":"connection reset"}}
```

| Field | Rule |
|---|---|
| `id` | the tentative folder id (*I*); required, folder-id grammar ([01](01-core.md)) |
| `parent` | the parent folder id (*P*) the slot hangs from; required |
| `name` | the real leaf (*N*) claimed; required |
| `landedAt` | wall time, seconds since the epoch, at which the create-if-absent was answered. The confirmation is due at `landedAt + claim_settle`. A re-claim (§6.2 step 3, empty or disowned slot) replaces the record with a new `landedAt` |
| `attempts`, `lastError` | as in the WAL record (§2.8); only reported |

Readers ignore unknown fields; a record missing a required field is unparseable (set aside). The
folder's current local path is found from `id` through the folder-id index (§4.9), never stored.
At most one record per `id`: a new claim of an id that already has a record replaces it.

### 2.10 Files specified elsewhere

Applied log and last-sync mark: [03](03-journal-sync.md). Export records:
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
  delete, symlink, revert's install, the application of a peer's entry, conflict asides, lazy
  pulls, resync's record and sweep, folder-index rebuild — and every WAL record creation for
  such a change.
- **The key lock** (one per logical key): every content change of the key — write, truncate,
  create, whole-file handover, sync, close, the upload's commit, promotion — and every removal,
  move or discard of the key's staged edit, whoever performs it.

Rules:

1. Lock order: the metadata lock before any key lock; several key locks in ascending key order.
   A holder of a key lock never waits for the metadata lock.
2. A step that acts on a fact about a key's staged edit (it exists, it is Owed, it is
   Committed) reads that fact while holding the key lock. A decision taken under the metadata
   lock alone is re-checked under the key lock, and re-decided if the fact changed. (Otherwise a
   peer's delete, decided while no edit existed, discards an edit written a moment later.)
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
- A change that is not in the lineage (a peer's version applied to the key, a local delete of
  the key, a replacing rename over it) **ends** the lineage: the handle keeps reading the
  content it had at that moment, as POSIX keeps an unlinked open file readable.
  - A published version is held by its manifest, and its chunks are fetched by key as needed.
    If the store no longer holds them (collected), the read fails ABSENT; it never serves
    another version.
  - A staged edit that is moved aside by a conflict stays in the lineage under its new name.
  - Staged bodies referenced by a handle are not released until the handle closes
    ([durable-queue](algorithms/durable-queue.md) R3).
- A rename of the key (local or a peer's) moves the handle's key with it.
- **Retention.** `retain(key)` returns a retention of the key's current content, published or
  staged, as it is at that instant; reads through it behave as a handle whose lineage has ended.
  `release(retention)` ends it. A frontend uses it to keep an open-and-unlinked file readable
  ([fuse](frontends/fuse.md) §4.10).
- Handles and retentions live in the owner's memory; a crash closes them all.

### 3.4 Operations

| Operation | Effect | Level / errors |
|---|---|---|
| `kind(key)` | Dir if the mirror holds a folder; File if it holds a file entry or a staged edit exists; else Absent | — |
| `stat(key)` | §3.6 | ABSENT |
| `resolve(key)` | the staged edit (with its base, if any), else the published manifest, else nothing (§4.2) | — |
| `list_children(prefix)` | files and folders directly under `prefix` (§3.5) | lazy tree: *network*; a failed pull propagates |
| `list_tree(prefix)` | every file under `prefix`, recursively | — |
| `open_read`, `read(handle, off, buf)`, `close_read` | §3.3; bytes by [read-path-and-cache](algorithms/read-path-and-cache.md). A read is short only at end of file | *network* for uncached bytes; DEADLINE after `READ_DEADLINE` |
| `readlink(key)` | the target of a symlink manifest | ABSENT, INVALID if not a link |
| `content_id(key)` | the item identity of the key's content: the whole-file digest `h1` ([02](02-remote-model.md)) of the published record, or of a whole-body staged edit (computed at adoption with the chunk size the upload will use); none for a staged edit with slots | — |
| `write(key, off, bytes)` | §4.3 | visible; *network* only to copy inherited bytes |
| `truncate(key, size)` | §4.3 | visible; as write |
| `create(key, exclusive)` | an empty staged edit, replacing any content (O_TRUNC); with `exclusive`, EXISTS if the key exists | visible |
| `write_whole(key, src, base?, exclusive)` | adopt the complete file at `src` as the key's content, then close (§4.3, §4.4); `src` no longer exists at its path afterwards. With `exclusive`, EXISTS if the key exists; with a stale `base`, the write lands as a conflicted copy ([conflict-resolution](algorithms/conflict-resolution.md) §4.9) | durable |
| `sync(key)` | §4.4 | durable |
| `close(key)` | §4.4 | durable |
| `delete(key)` | §4.5 | durable |
| `mkdir(key, exclusive)` | §4.5; an existing folder is success unless `exclusive` (then EXISTS); an existing file is EXISTS | durable; UNPREPARED if the parent has no id |
| `rmdir(key)` | §4.5; removes the folder only if it is empty (no file, folder or staged edit beneath), as one step; EXISTS otherwise | durable; UNPREPARED |
| `rename(src, dst, exclusive)` | §4.5 | durable; UNPREPARED for folders whose parent has no id |
| `symlink(key, target, exclusive)` | §4.5; REFUSED unless the domain's symlink policy keeps links; with `exclusive`, EXISTS if the key exists | durable |
| `retain(key)`, `release(retention)` | §3.3 | — |
| `evict(key)` | removes every cache body of the key's published version and their pins; never touches staged content or the mirror entry | visible; reference-blind: a body another file shares goes too and is refetched on demand |
| `pin(key, keep)` ("make available offline") | [read-path-and-cache](algorithms/read-path-and-cache.md) §4.8 | durable; *network* |
| `unpin(key)` | removes the pins of the key's groups | visible; reference-blind, like `evict` |
| `assemble_to(key, dst)` | the whole content into `dst` through one read handle, then `dst`'s mtime set to the content's mtime. `dst` MUST NOT exist: it is created exclusively, without following links, mode 0600 ([security-model](algorithms/security-model.md) §7.3) | *network*; EXISTS if `dst` exists |
| `fetch_range(key, dst, off, len)` | the bytes `[off, off+len)` into a new file `dst` (created as for `assemble_to`) at the same offsets, with a hole before them; the file ends where the bytes end (short at end of content; a range wholly past the end yields an empty file). Staged edits and holes are served from staged state; only the chunks covering the range are fetched | *network* |
| `revert(key, version)` | §4.6 | durable; *network*; ABSENT if no such version |

Peer application, reconcile and the queues' jobs are not frontend operations; their local
steps are §4.5–§4.7 and [wal-and-journal](algorithms/wal-and-journal.md).

**`rename(src, dst, exclusive)`** follows POSIX: with `exclusive`, EXISTS if `dst` exists. Otherwise
a file replaces an existing file; a folder replaces an existing **empty** folder; a folder onto a
non-empty folder, a file onto a folder, and a folder onto a file are EXISTS (POSIX frontends map
them to ENOTEMPTY, EISDIR and ENOTDIR). A rename onto itself succeeds and changes nothing; a
folder into its own subtree is INVALID; an atomic exchange is not offered.

### 3.5 The published tree: full and lazy

A domain's tree is either **full** (desktop hosts) or **lazy** (Android); the host chooses
([08](08-frontends.md)). Both expose the same operations; they differ in what absence means.

**Listing** (both):
- names are real: escaped leaves are resolved through the file entry's recorded name or the
  folder's name marker;
- internal leaves, set-aside manifests and undecodable file entries are skipped;
- a staged edit wins over the published entry of the same path, and a staged-only file is
  listed;
- a folder's mtime is the time of the last change to its set of children (an entry added,
  removed or renamed in or out), as recorded here; it is stable between such changes.

**Full tree.** Absence in the mirror is absence in the domain, as of the entries applied.
Listing never touches the network. The resync primitives ([05](05-ops-config.md) owns resync):
- `record(parent, entry, on_other)`: writes one store-walk entry into the mirror. A folder
  marker is recorded at `parent/<marker name>`; with `on_other = replace` the store's id
  replaces any held id, with `keep` a held id is kept (§4.9). A file manifest is written at
  `parent/<recorded name>`. The answer is *same*, *changed* or *replaced(old id)*; a file is
  *same* iff the previous entry had equal first chunk key, size, mtime and link target.
- `sweep_stale(cutoff)`: after a complete walk only, removes every mirror entry not rewritten
  since `cutoff − 1 s` (coarse mtimes). A stale folder is removed whole and reported as a
  `rename` to where the folder index now places its id, else as `rmdir(path, id)`; nothing
  beneath it is reported. A stale file is reported as `delete`. Emptied directories are
  removed. Ops are returned in walk order.
- `clear_projection()`: removes the scratch tree only.

**Lazy tree.** Absence means "not fetched". When the host pulls a folder is
[android](frontends/android.md) §3.2. A **pull** of one folder:
- is refused as UNPREPARED when the folder has no local id;
- reads the store's listing of the folder; a child that cannot be read fails the whole pull
  (never skipped), and a failed pull changes nothing;
- records each child with `on_other = keep`, then removes every published entry directly in the
  folder that the listing lacks;
- is **overlaid** with the owed work touching the folder, never skipped because of it: a name an
  owed operation removes or renames away stays hidden, a name an owed operation creates or
  renames in stays shown, and staged edits are kept. A record that cannot be discharged therefore
  never freezes a folder;
- never writes to the store.

### 3.6 Stat and availability

- **stat** of a folder: a directory, mode 0755, link count 2, size 0, mtime as in listings.
  Of a file: the staged edit's size and mtime if any, else the published manifest's; a symlink
  manifest is a symbolic link (mode 0777, size = target length); otherwise a regular file mode
  0644. Owner and group are the owner process's; ctime equals mtime.
- **availability** of a file:
  - `cached` if a staged edit exists;
  - else, over the published version's groups: `pinned` if every group has a whole body and a
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
(Owed or Committed), with the published manifest at the same path as its base; else the
published manifest; else nothing. A staged Inherit slot with no base, or whose base lacks that
chunk, is CORRUPT, never zeros. A published manifest whose chunk list has a hole is CORRUPT.

### 4.3 Staged writes

All steps below run under the key lock and end by incrementing the edit generation.

**Base state** of a mutation (`staged_for`):
- a staged edit with a whole body: first **split** it: for each group of the domain's current
  chunk size, a new group body holding that group's bytes, one slot per chunk; replace the
  staged manifest; release the whole body once the new manifest is durable (R3);
- a staged edit: as is;
- no edit, a published manifest: every slot Inherit, size and chunk size from the manifest,
  mtime now, `base` = the manifest's `h1`;
- neither: empty, with the domain's chunk size, `base` = none.

A put published for the edit carries its `base` ([03](03-journal-sync.md) §2.3), omitted when
unknown.

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
   resolves ([conflict-resolution](algorithms/conflict-resolution.md) §4.9).
1. Adopt `src` as a new whole body: rename it into `staged/whole/<new id>`; across filesystems,
   copy it, fsync the copy, then unlink `src`.
2. fsync the body and its directory; durably replace the staged manifest with `whole` set and
   size and mtime taken from `src`, and `base` = the supplied `base`, else the view's `h1`
   (none without a view). Compute the body's whole-file digest (the key's `content_id`)
   with the chunk size the upload will use, and record it as the manifest's `h1`. When the
   digest equals the key's `content_id` before the write, nothing changes: the body is released
   and no upload is queued (a replay of content the store already has).
3. Release the old bodies after the manifest is durable; then close (§4.4).

**Reading staged content**: a whole body is read directly. Otherwise per chunk: Staged reads the
body at `offset + chunk offset`, with zeros past the body's end (within the edit's size); Zero
reads zeros; Inherit reads the base's chunk through the cache. A Staged slot whose body does not
exist is CORRUPT; a body that cannot be opened or read fails with its failure kind. Neither is
ever read as zeros.

### 4.4 Sync and close

- **`sync(key)`** (the frontend's `fsync`): under the key lock, fsync every body the staged
  manifest names that was written since the last sync (all of them after an owner restart),
  fsync the directories of bodies created since then, and durably replace the staged
  manifest. No staged edit: nothing to do.
- **`close(key)`** (the frontend's last close after a modification, or the end of a handover):
  sync, then post a WAL record `Prepared [put(path, size)]` to the upload queue, with the
  staged size at that moment. The post is durable before `close` returns. A close without a
  staged edit, or without modification since the last close, posts nothing.

### 4.5 Namespace operations

Each runs under the metadata lock with the WAL sequence of
[wal-and-journal](algorithms/wal-and-journal.md) §4.2 (durable `Intent` before the local half,
local effects durable, then `Prepared`, then acknowledgement,
[durable-queue](algorithms/durable-queue.md) §7.4). A local half that fails completes its
record and returns the failure. A local half that leaves the store owed nothing completes its
record. A `delete` or file `rename` record carries the expected prior record of the path it removes
or overwrites on the store (§2.8): the view of that path when the local half ran.

| Operation | Local half | Store owed? |
|---|---|---|
| `delete(key)` | take the key lock; discard the staged edit (its bodies released after the discard is durable, and not before open handles close); remove the mirror entry; MAY evict its cache bodies | yes iff the mirror held a published entry or the staged edit was Committed |
| `mkdir(key, exclusive)` | parent id required; an existing folder: nothing to do (EXISTS with `exclusive`); otherwise mint a folder id; create the directory, marker, reverse entry and removed-id record. The record carries the id, which is final | yes |
| `rmdir(key)` | parent id required; read the folder's id; in one step under the lock, refuse a folder with any child (mirror entry, folder or staged edit) as EXISTS, else remove it; keep the removed-id record | yes, unless the folder was never published |
| `rename(src, dst, exclusive)` | the POSIX rules of §3.4; take the key locks of `src`, `dst` and every staged key under a moved folder; for a folder, the parent of `src` must have an id; replacing an existing `dst` discards `dst`'s staged edit and mirror entry (an open handle on it keeps its content, §3.3); move the staged manifests and the mirror entry (§4.1), re-stamping names; for a folder, reparent its id (§4.9); re-post the upload of every moved staged edit under the new key, with a record key minted after the rename's | yes, unless the source was a never-published staged file |
| `symlink(key, target)` | post `Prepared [put]`, then write a symlink manifest into the mirror, both under the key's lock (the upload puts the manifest; one that finds no link owes nothing) | yes (as an upload) |

The Arrival decisions and their enactment for a peer's entry
([conflict-resolution](algorithms/conflict-resolution.md) §4.1–§4.6) use these same local steps
and locks; an aside moves a staged edit with `rename`'s local half.

### 4.6 Upload, commit and publishing a Put

The upload job for a WAL record with a `put(path)` op (the upload queue's job,
[durable-queue](algorithms/durable-queue.md) §4.9):

1. Under the key lock, read the key's state and its edit generation `g`:
   - an **Owed** staged edit: continue at step 2;
   - a **Committed** staged edit: advance the record to `Executed` if it is not, then promote
     (§4.7) and discharge;
   - a symlink manifest in the mirror and no staged edit: put that manifest (idempotent), then
     discharge;
   - **no staged edit**: ask the store whether a manifest exists at the path. Present: ensure
     the mirror holds a manifest for the path (fetch the store's if the mirror has none), then
     discharge. Absent: complete the record without publishing. No answer: the failure's kind
     (the record stays owed). ([durable-queue](algorithms/durable-queue.md) §7.3)
2. Without the lock, upload the chunks through the GC interlock ([gc](algorithms/gc.md) §4.4):
   Inherit slots reuse the base's chunk keys (no upload); Zero slots and bytes past the slots
   are zero chunks; Staged slots read their bodies (§4.3, never zeros for an unreadable body); a
   whole body is uploaded whole. Build the manifest.
3. Under the key lock: if the edit generation is no longer `g`, end CANCELLED (a later close or
   the owner-start adoption owes the newer state). Otherwise put the manifest on the store; then
   durably replace the path's mirror entry with it and write its own marker (the view, §2.3:
   Inherit slots stay valid, because the new manifest reuses the base's chunk key and size at
   every Inherit index); then durably replace the staged manifest as **Committed** with that
   manifest and with `base` set to its `h1` (it is now the view a later edit starts from).
4. Advance the WAL record to `Executed` (durable).
5. Promote (§4.7).
6. Discharge ([wal-and-journal](algorithms/wal-and-journal.md) §4.2).

A whole body is never modified in place, so a whole-body upload needs no snapshot. Group bodies
may be written during step 2; step 3's generation check discards what that upload read.

**`revert(key, version)`** (versioning required; *network*): fetch the version's manifest;
under the metadata lock and the key lock, discard the staged edit (the user asked for the
version), increment the edit generation, and durably post `Prepared [put(path, size)]`; then put
the version's manifest on the store through the GC interlock (after saving the current one as a
version, [02](02-remote-model.md)); install it in the mirror durably; the upload queue then
discharges the record by the "no staged edit" rule.

### 4.7 Promotion

Promotion turns a Committed staged edit into the published mirror entry. It runs under the key
lock, at the end of an upload and for every Committed edit at owner start (§4.10). Each step is
idempotent.

1. Re-read the staged manifest. If it is not Committed, stop: a later mutation retired the
   commit record, and its own close or adoption owes the newer state. The mirror entry already
   holds the stored manifest (§4.6 step 3).
2. Chunked edits: for each group of the published manifest whose members are all Staged or Zero
   and at least one Staged:
   - if every Staged member sits in one body at its layout offset: resize that body to the
     group's size (zeros for Zero members), fsync it, and hand it to the cache by hard link
     (§4.8);
   - otherwise, or when links are unsupported: install the group from the staged bytes as a
     whole body ([read-path-and-cache](algorithms/read-path-and-cache.md) §4.5).
   Groups with an Inherit member keep their key; a cached body for them is still right. A whole
   edit hands nothing to the cache.
3. Durably replace the mirror entry with the committed manifest.
4. Release the staged manifest and fsync its directory.
5. Release the staged bodies, except those an open read handle references (released when the
   last such handle closes).

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
  the folder so ops recorded under a removed or moved folder stay nameable.
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

Before reconcile ([07](07-daemon-cli.md) §3.2), with no request served yet, the owner brings the
checkout to a consistent state:

1. Remove temporary files in the domain's local areas whose owning process is not alive
   ([01](01-core.md) §2.9).
2. Remove every cache file that is not a whole body or a pin (§2.7), each body before its
   companions.
3. Read every file of the staged manifest tree. Rename each one that does not decode and whose
   name is not already a set-aside name to its set-aside name (§2.5); report every
   set-aside manifest. The set of **named bodies** is every body id named by a decodable manifest,
   plus, for each set-aside manifest, every maximal run of exactly 16 lowercase hex characters in
   its bytes. False positives only keep a body longer.
4. Promote every Committed staged edit (§4.7). This needs no network.
5. Release every staged body not in the named set. The release is exact, with no grace
   period, because only the owner writes the staged tree and nothing else runs yet.
6. Reconcile the WAL ([wal-and-journal](algorithms/wal-and-journal.md) §4.7), then **adopt**
   every Owed staged edit that no WAL `put` record names: post a fresh `Prepared [put(path,
   size)]` for it (the crash fell between a write and its close).
7. Anchor the cache counts ([read-path-and-cache](algorithms/read-path-and-cache.md) §4.9); this
   MAY run lazily.
8. Give a file-id marker (§2.3) to every mirror file entry without a valid one, durably. On a lazy
   tree this covers the entries present. A crash midway leaves entries without a marker, which the
   next start completes; no id was reported for them yet.

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
| `REMOVED_ID_RETENTION` | the journal retention horizon ([wal-and-journal](algorithms/wal-and-journal.md) §4.8) | MUST NOT be shorter: a peer op naming the folder may still arrive |
| `HOUSEKEEPING_INTERVAL` | 60 s | cap cadence |

---

## 6. Conformance

An implementation MUST exhibit the following.

**Formats**
- Group keys and `per` follow §2.2 exactly; a group shared by two files has one key and one
  body path.
- A staged manifest round-trips slots with offsets; a manifest without `v`, `o` or
  `chunkSize` decodes as specified; a version-3 manifest is set aside, never decoded.
- A WAL record with an unknown op, a torn body or an empty op-list body is set aside and
  reported, never completed. `priors` and `localFrom` round-trip; a record without `priors` has
  unknown expected priors.
- A re-key leaves exactly one of the two record names at every kill point.

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
  edits survive removal of the whole chunk cache, and restart recovery publishes them.
- Deleting a staged file releases its bodies; the cache cap never counts or removes staged
  bodies.
- `exclusive` create, mkdir, symlink, handover and rename answer EXISTS on an existing name and
  change nothing; a handover with a stale `base` lands as a conflicted copy and leaves the key's
  content unchanged.

**Upload and promotion**
- A one-chunk edit of a published file uploads one chunk object.
- A replayed promotion uploads nothing; an upload redone after a lost commit record uploads
  nothing (dedup).
- A write that arrives while an upload is in flight wins: the upload ends CANCELLED and the
  store holds the newer content once its close is uploaded.
- Reads and writes concurrent with a promotion all succeed: readers always get full-length, exact
  bytes, and alternating whole-file handovers never publish a mixed body. A write inside the
  promotion window retires the pending promotion.
- After an upload stored a manifest and its promotion was abandoned, the path's mirror entry is
  that manifest.
- An upload whose staged edit vanished publishes an entry only if the store holds a manifest at
  the path.
- A whole-file promotion leaves the cache without the file's groups.

**Crashes** (each at every step, [durable-queue](algorithms/durable-queue.md) §8)
- A crash between a group body's creation and the manifest that names it leaves the previous
  edit intact and readable; the new body is released at the next owner start.
- A set-aside staged manifest's bodies survive the owner-start sweep.
- A staged edit with no WAL record is adopted at owner start.

**Namespace and index**
- Mirror absence is domain absence, answered without touching the store (full tree).
- Lazy tree: listing a folder on a device that never synced fetches that folder only and
  recovers folder ids from the store; a remote delete prunes the entry; a pull is never skipped
  because of owed work, yet local unpublished creations stay listed and local unpublished
  removals are not listed back; a failed pull prunes nothing.
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
- A peer's delete of a file that has a staged edit here never discards the edit, whatever the
  interleaving with a concurrent write.
- Resync rewrites the mirror in place, keeps chunks and staged data, reports removals as ops
  (`delete`, `rmdir` with id, a folder move as `rename`), and does not sweep after an
  incomplete walk.

---

## 7. Rationale

| Choice | Reason |
|---|---|
| Staged data in its own tree, not a spared region of the cache | The cap and resync cannot delete sole-copy bytes because they cannot address them, not because a filter spares them. |
| Mirror filed by real path with escape handles and name markers | A walkable tree without the network, and names safe on FAT and NTFS. |
| Group of several chunks per local file | Network granularity (the chunk) differs from disk granularity; fewer files and walks. |
| Group key hashed over member keys | Two groups sharing first and last chunk once aliased and served wrong bytes. |
| Staged body per group in group layout, promoted by hard link | Promotion by copy wrote a large file twice. |
| Commit record inside the staged manifest | One atomic object; a later write retires it naturally. |
| Upload commits only on an unchanged edit generation | A cooperative cancel alone let a torn manifest reach the store. |
| One metadata lock that never spans a store request | A slow link must not freeze the mount. |
| Key-lock re-check of staged facts | A decision taken without it discarded a fresh local edit on a peer's delete. |
| Partial bodies live only for the owner's lifetime | No record on disk can ever claim bytes the disk lacks, whatever crashes or power losses happen; a restart costs a few range refetches. |
| Set-aside names are internal leaves | A user's file named `x.bad` is not a set-aside object. |
