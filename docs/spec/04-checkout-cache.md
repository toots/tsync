# 04 — Checkout & local cache (the local side)

Scope: `lib/domain/checkout/{chunks,content,file,lazy_checkout,maintenance,manifests,ops,staged,wal}`,
`lib/domain/cache_layout`, and their Lwt bindings under `lib/lwt/domain/{checkout,cache_layout}`.
Everything here is local to one client machine. The backend key layout, the manifest binary
format, the journal and the upload/metadata queues are other subsystems; they appear here only
through the interfaces this one calls.

This file is the language-neutral specification. The [OCaml notes](ocaml/04-checkout-cache.md) hold OCaml-specific
implementation notes.


> **Terminology.** In this file "the mirror" always means the **local manifest mirror**
> (`<cache_root>/<domain>/manifests/`), this client's projection of the domain's namespace.
> Unrelated commands with similar names are specified elsewhere: `tsync mirror` (backend-to-backend
> copy) and `tsync sync` / `sync --full` (catching up / rebuilding this local mirror from the
> store) are in `05-ops-config.md`; this file only specifies the primitives they call
> (`record`, `sweep_stale`, `clear_projection`, `Folder_ids.rebuild`).

## 1. Problem

tsync presents a remote store (S3/GCS/disk/another tsync) as a folder. The backend holds only
**hashed, content-addressed objects** (chunk keys, manifests filed under `<folder-id>/<hash of
name>`), so it cannot answer "what is in folder X", "what is this file called", or "what bytes
are at offset N" cheaply. The local side exists to:

1. **Mirror the domain's namespace** locally, filed by real path (the *manifest mirror*), so
   `readdir`/`stat`/`lookup` never touch the network. The mirror is *the whole answer*: a name it
   does not hold is a name the domain does not have (as of the journal entries applied).
2. **Serve bytes lazily** from a content-addressed *chunk cache* that fetches only the ranges a
   reader touches, with read-ahead for sequential streams, bounded disk (a cap with LRU-by-mtime
   eviction) and pinning.
3. **Hold unpublished local writes** (*staged* manifests + *staged bodies*) — the only copy of
   the user's data until uploaded — in a store the cache cap and a resync can never reach.
4. **Turn a local write into a published version** crash-safely: WAL intent record → upload →
   commit record → local promotion (hard-link the staged body into the cache) → published sidecar.
5. **Record every metadata op (mkdir/rmdir/rename/delete) as an intent before doing it**, apply
   its local half immediately (offline-capable), and hand the backend half to a queue.
6. **Apply peers' journal entries** to the mirror, resolving clashes with unpublished local work
   (conflicted copies, never data loss).
7. **Map folder ids ↔ paths** (folder markers + reverse index), because backend keys hang off
   stable folder ids, not paths.

Why separate abstractions: the four on-disk stores have different *ownership and deletability*:

| Store | Truth? | Deletable by | Rebuilt by |
|---|---|---|---|
| manifest mirror (`manifests/`) | projection of the store | resync sweep, peer ops | resync walk / poller |
| folder index (`folders/`) | projection of the markers | rebuild | `Folder_ids.rebuild` |
| chunk cache (`chunks/`) | projection of backend chunks | cap, `forget`, anytime | any read |
| staged (`staged/`) | **sole copy** of user data | only promotion / discard / orphan sweep with grace | never |
| WAL (`<data_dir>/journal-pending/<domain>/`) | sole record of owed work | discharge / reconcile | never |

Commit 2d0f0fc9 and 75c90fdd made this structural: the cap *cannot* reach staged bytes because
they live in a different store, not because a filter spares them.

---

## 2. Concepts & data model

### 2.1 Identifiers and hashes

- **Logical_key**: a domain-relative path plus a kind (`File` | `Dir`). Root is the empty path.
  `Logical_key.path`, `leaf`, `parent`, `file_in parent name`, `dir_in parent name`.
- **Chunk key**: `"<h1>-<h2>"`, each 16 lowercase hex = XXH3-64 of the chunk bytes with seed 0 and
  seed 1. (Defined by the manifest/remote subsystems; opaque here.)
- **Group (cache chunk)**: a run of `per` consecutive stored chunks of one manifest, cached as
  **one local file**. `per = Conf.chunks_per_group ~chunk_size ~cache_chunk_size =
  if chunk_size <= 0 then 1 else max 1 ((cache_chunk_size + chunk_size/2) / chunk_size)`
  (round to nearest). Defaults: `chunk_size = 8 MiB`, `cache_chunk_size = 16 MiB` → `per = 2`.
  Group `g` covers indices `[g*per, min(n, g*per+per))`. `per` is computed from the **file's own
  manifest chunk_size**, so a file uploaded under a different setting still groups by its body.
- **Group key**: XXH3-64 streaming hash (seeds 0 and 1) over `member_key_0 ";" member_key_1 ";" …`,
  rendered `"<16hex>-<16hex>"` (same shape as a chunk key). Not `<first>-<last>`: two groups can
  share first/last and differ inside. Two files whose chunks group identically share one body on
  disk and one download.
- **Group layout**: member `i` sits at `offset(i) = Σ size(j) for j<i` within the group body;
  `bytes(group) = Σ size`. Only the last chunk of a file may be short.
- **Staged body uuid**: `Id.short()` = 16 hex chars (64 random bits, per-process PRNG reseeded
  after fork).
- **Folder id**: minted per client by `Journal.folder_id` = `"<first 12 chars of client uuid>-<hex
  counter>"`; root is the literal `.tsync-root`; trash is `.tsync-trash`.
- **Entry key** (WAL record id / journal entry): `"%013Ld-%s"` = milliseconds since epoch
  (13 digits, zero padded) `-` client uuid. Sorting by `Entry_key.compare` = replay order.
- **Name escaping** (`Stored_key.escape leaf`): a leaf is *storable* iff `length ≤ 250` bytes, does
  not start with `.tsync-`, and contains none of `" * : < > ? \ |` or control chars `< 0x20`.
  Storable leaves are used verbatim; otherwise the on-disk leaf is
  `".tsync-esc-" ^ XXH3_64_hex(leaf, seed 0)` (lossy; real name is recorded elsewhere).
  `escape_path` escapes each `/`-separated component.
- **Internal leaf**: `internal_leaf l = starts_with ".tsync-" l && not (starts_with ".tsync-esc-" l)`.
  Every walker/listing skips internal leaves (markers, temp files).
- **Temp files**: `atomic_write` writes `<dir>/.tsync-tmp-<pid>-<seq>.tmp` then `rename`s over the
  target (no fsync). `is_temp_name` = prefix `.tsync-tmp-` and suffix `.tmp`; `temp_owner` parses
  `<pid>`.

### 2.2 On-disk layout (exact)

```
<cache_root>/<domain>/
  manifests/<escaped real path>          published manifest mirror (one binary manifest body per file)
      <dir>/.tsync-dir                   folder marker JSON {"dir":true,"name":<real leaf>,"id":<folder id>}
      <dir>/.tsync-name                  real name, only inside a dir whose on-disk leaf is escaped
  scratch/<escaped real path>            .fuse_hidden* scratch files (FUSE frontend); wiped by resync
  chunks/<xxx>/<group key>               cache body, one per Manifest.Group (sparse while partial)
  chunks/<xxx>/<group key>.manifest      partial record: present ⇔ body incomplete
  chunks/<xxx>/<group key>.pin           pin marker; its mtime IS the deadline (Unix time)
  staged/manifests/<escaped real path>   staged sidecar JSON (unpublished edits), same tree shape as manifests/
  staged/manifests/<...>.bad             undecodable sidecar moved aside (never deleted)
  staged/chunks/<uuid>                   staged body: one per cache group, in the group's byte layout (sparse)
  staged/whole/<uuid>                    whole file adopted from a frontend (FileProvider/Android share)
  folders/<folder id>                    reverse index entry JSON {"parent":<parent id>,"name":<real leaf>}
  folders/by-path/<md5hex(Logical_key.to_string key)>   last id a path named (outlives the folder)
  exports/<xxh3(dst,0)>-<xxh3(dst,1)>    in-flight `tsync export` record per destination file
  applied/<YYYY-MM>.log                  journal entries this client published/applied (Applied_entries)
<data_dir>/journal-pending/<domain>/<entry key>        WAL record JSON (one file per unit of work)
<data_dir>/journal-pending/<domain>.owner              flock-style ownership lock of that dir (Durable_queue)
```

`<xxx>` = `Chunk_layout.shard_of key` = first 3 chars of the key (4096 shards), `_` if shorter —
shared with the backend chunk store's sharding. Example:
`<root>/testdom/chunks/abb/abbd5be7f7f1ea08-164c4bd493e0e119`.

The manifest and scratch trees mirror each other by real path; everything under `chunks/` and
`staged/chunks|whole` is keyed by content or opaque id. Directories exist **only** in the manifest
mirror (a mkdir is a real directory there).

### 2.3 Formats

**Published sidecar** (`manifests/<path>`): the binary manifest body exactly as stored on the
backend (see manifest subsystem), with its recorded `name` stamped to the key's leaf on every
write (`Manifests.write` is the sole writer). A file needs no `.tsync-name` marker because the
body carries the name. Read by `mmap` (`Manifest.of_file`); malformed ⇒ treated as absent.

**Folder marker** `.tsync-dir`: `{"dir":true,"name":"Photos","id":"3f2a9c1e0b7d-1a"}`
(same JSON as a backend folder marker). Root's id is implicit (`.tsync-root`).

**Name marker** `.tsync-name`: the raw real leaf bytes, no newline. Written by `ensure_dirs`
(only if absent) and rewritten on every resync visit / reparent (so mtime-based sweeps see it live).

**Reverse index** `folders/<id>`: `{"parent":".tsync-root","name":"Photos"}`.
**by-path** `folders/by-path/<md5>`: the id string (trimmed on read).

**Staged sidecar** (version 2), JSON:
```json
{"v":2,"name":"report.txt","size":34,"mtime":1727600000.25,"chunkSize":8388608,
 "slots":[{}, {"u":"9f3c1a2b4d5e6f70"}, {"u":"9f3c1a2b4d5e6f70","o":8388608}, {"z":true}],
 "published":"<base64 of manifest body>"}
```
- `slots[i]`: `{}` = **Inherit** (published manifest's chunk i), `{"z":true}` = **Zero** (hole,
  reads zeros, no disk), `{"u":uuid[,"o":offset]}` = **Staged** at byte `offset` (omitted when 0)
  of `staged/chunks/<uuid>`.
- `"whole":uuid` replaces `"slots"` for a frontend-adopted whole file (`staged/whole/<uuid>`).
- `"published"` present ⇔ state **Committed** (upload done, promotion pending); absent ⇔ **Owed**.
- `"v"` > 2 ⇒ decode fails ⇒ sidecar moved to `<path>.bad` (never decoded into something it does
  not mean). Missing `"v"` accepted; missing `chunkSize` ⇒ `Conf.default_chunk_size`; missing
  `"o"` ⇒ 0 (pre-offset sidecars: one body per chunk, each at 0 — still readable, promoted by copy).
- `size` is authoritative (not derived from body lengths), so truncate is metadata + ≤1 boundary
  fixup.

**Partial record** `<body>.manifest`: text, one line per member that holds anything,
`"<i> <a> <b>\n"` meaning member `i` holds chunk-local bytes `[a,b)`, sorted by `i`. Example:
```
0 0 4
2 0 2
```
Parser is **strict**: any bad line ⇒ whole record reads as *nothing held* (a torn write means
nothing is trusted). Constraint per line: `i ≥ 0 && 0 ≤ a < b`.

**Pin** `<body>.pin`: empty file; `utimes(deadline, deadline)`.

**WAL record** (`journal-pending/<domain>/<entry key>`), JSON:
```json
{"state":"prepared","attempts":2,
 "ops":[{"op":"rename","key":"b/new.txt","src":"a/old.txt","is_dir":false,"size":1234}],
 "lastError":{"kind":"transient","detail":"connection reset"}}
```
- `state` ∈ `intent|prepared|executed`; unknown ⇒ `intent` (never claim a later state than
  earned). No `committed` state: the record is deleted when the entry is published.
- `ops`: journal op JSON (`put{key,size}`, `delete{key}`, `mkdir{key,id?}`, `rmdir{key,id?}`,
  `rename{key=dst,src,is_dir,id?,size?}`) — owned by the journal subsystem.
- A body with no JSON envelope (legacy: one op per line) decodes as `Intent`, attempts 0.
- `Job.of_string` never fails (legacy fallback), so the durable queue never sees `Unreadable`.

**Export record**: owned by `ops/export` (only its path and the sweep live here).

### 2.4 Types

```
listed        = { key: Logical_key; size: int; mtime: float }
availability  = Online_only | Cached | Pinned of float(earliest deadline)
slot          = Staged {uuid; offset} | Inherit | Zero
staged        = { s_name; s_size: int64; s_mtime; s_chunk_size; s_slots: slot[]; s_whole: uuid option }
state         = Owed of staged | Committed of staged * Manifest.t
Wal.state     = Intent | Prepared | Executed
Wal.record    = { ops: Journal.op list; state; attempts: int; last_error: (Transient|Permanent, string) option }
served        = { bytes: int; fetched: int (bytes over the wire); from_backend: bool }
fetch         = { waited: bool; pulled: int }
held (cache)  = { files; bytes; pinned_bytes; next_expiry; anchored }   -- per chunks root, in-process
Sweep.swept   = { files: int; bytes: int }
Sweep.trigger = Periodic of seconds | After_upload | On_demand
```

### 2.5 Constants

| Constant | Value | Where |
|---|---|---|
| default chunk size | 8 MiB | conf |
| default cache chunk (group) size | 16 MiB | conf |
| default `max_downloads` | 8 | conf_parsing |
| manifest memo capacity | 1024 entries per domain, FIFO eviction | manifests.ml |
| read deadline (`Chunk_cache.read_deadline`) | 15 s (mutable ref) | chunk_cache.ml |
| default pin keep | 10 days | chunk_cache.ml |
| mtime touch interval (read keeps body warm) | 60 s | chunk_cache.ml |
| cache `slots` (open-descriptor bound for group fetch / range fill) | `max_downloads` | chunk_cache |
| cache stat pools | `metadata_slots`=64, `dir_slots`=16 (never nested in each other) | chunk_cache |
| `piece_slots` (pieces of one read) | `4*max(1,max_downloads)` | data.ml |
| `group_slots` (materialization) | `4*max(1,max_downloads)` | data.ml |
| read-ahead bytes / max groups / max loops | 4 MiB / 8 / 4 concurrent | data.ml |
| pull table: idle expiry / cap / reported / rate window | 8 s / 256 / 16 / 2 s | data.ml |
| staged orphan grace | 3600 s | maintenance_lwt |
| export record retention | 30 days | maintenance_lwt |
| applied-entries prune: keep bytes / interval | 64 MiB / daily | maintenance_lwt |
| temp-file sweep stat pool | 64 | temp_files.ml |
| resync sweep mtime slack | cutoff − 1 s | checkout.ml, cache_layout.ml |

---

## 3. Interface

Every component is written against injected capabilities — a filesystem, retrying syscalls, a
mutex, a bounded-concurrency pool, a clock/timeout, and the domain's configuration — and is
instantiated once per domain. Several of its tables must exist exactly once per process per
domain (or per cache root), however many consumers use the component; see §6.

### 3.1 Seams (several implementations / chosen by the caller)

**`Checkout_intf.S`** — the published tree (two implementations: full `Checkout`, and
`Lazy_checkout` which pulls a folder from the store when listed).
```
rename      : src_key -> dst_key -> unit            // moves mirror entry, re-stamps name, reparents folder id
create_dir  : key -> unit                           // mkdir -p in mirror, writing .tsync-name for escaped comps
delete_dir  : key -> unit                           // rm -rf mirror subtree
list_children : prefix -> (listed list * string list /*real subdir names*/)
list_tree   : prefix -> listed list                 // recursive
ensure_root : unit -> unit
record      : parent -> on_other:(Replace|Keep) -> Inode_tree.entry -> (key * (Same|Changed|Replaced of old_id))
sweep_stale : cutoff -> Journal.op list             // after a complete resync walk
```
Listing invariants: internal leaves filtered; names are real (escaped resolved via markers or the
manifest body's recorded name); **staged entries win** for the same key and are listed even if
never published (merge = staged @ published-minus-staged-keys). Unreadable manifest ⇒ entry
skipped.

`record` semantics: for `Dir marker` → key `parent/<marker.name>`; `Replace` → `Folder_ids.replace`
(resync restates store's id), `Keep` → `Folder_ids.write` (browse keeps held id). Answer
`Changed` if none held, `Same` if same id, `Replaced old` otherwise. For `File manifest` → key
`parent/<recorded_name>`, `Mf.write`, answer `Same` iff previous published manifest had equal
`h1, size, mtime, symlink`.

**`File_ops.S`** (`ops/file_ops.ml`) — what a frontend (FUSE, FileProvider, Android, share server)
and the queues drive. Implemented by `File.Make_with_layout`; tests stub it.
```
kind           : t -> Dir|File|Absent              // from the mirror only
published      : t -> Manifest option
stat           : t -> LargeFile.stats option       // synthesized (see §4.10)
readlink       : t -> string option
list_children  : prefix -> (listed list * (name * float option) list)
list_tree      : prefix -> listed list
resolve        : t -> (Staged of staged * Manifest option | Published of Manifest) option
read           : ?stream -> t -> buf -> offset:int64 -> int      // short only at EOF
write          : t -> buf -> offset:int64 -> int
truncate       : t -> int64 -> unit
create         : t -> unit                          // O_TRUNC: empty staged file
write_whole    : t -> src_path -> unit              // adopt a finished file (rename/copy)
close          : t -> unit                          // queue upload iff staged
ensure_cached  : ?keep -> t -> unit                 // fetch all + pin (default 10 d)
assemble_to    : t -> dst_path -> unit              // whole file to a real path, mtime set
fetch_range    : t -> dst_path -> offset -> length -> int   // range into dst at same offset
evict          : t -> unit                          // drop cached groups, keep sidecar
delete / mkdir / rmdir / rename ~src ~dst / symlink ~target / revert ?version
apply_delete   : t -> unit                          // backend delete + local clear (replay path)
upload         : ?cancel -> t -> unit               // pool's call: D.sync or symlink manifest put
queue_put / resume_put / resume_meta / redo_local   // WAL plumbing (§4.6)
cancel_upload  : t -> bool
apply_foreign_ops : Journal.op list -> unit         // peer entries (§4.8)
enforce_chunk_cap, chunk_stats, chunk_residency, staged_count, downloads_*,
uploads_in_flight, downloading_now, download_progress, read_ahead_in_flight,
meta_locked, meta_waiters                           // diagnostics
```
`File` also exposes to the upload pool (`Owing`): `record_key`, `record_size` (sum of `Put` sizes),
`upload`, `set_in_flight`, `set_canceller`; and to the metadata queue (`Publishing`):
`backend_ops : op list -> op list` (the backend half; answers what to publish instead).

**`Chunk_cache.Fetch`** — what the cache needs from the network (satisfied by `Remote.S`):
`get_chunk ~chunk_key`, `get_chunk_range ~chunk_key ~offset ~length`, `fast_read : bool`
(a local-disk store: whole body costs ≈ a range).

**`Wal_intf.RECORDS`** (durable-queue record half): `create ~dir`, `write t ~id r`,
`update t id f`, `complete t id`, `list ?wanted t`. **`OWED`**: `create`, `signal`, `consume`,
`idle`.

**`PULL`** (for the lazy checkout): `children ~folder_id -> Inode_tree.entry list`. The
production implementation lists the folder's namespace on the store, **fails** on any child it
cannot read (never skips), and never refreshes the store's folder index (a browse is a read; the
store may be read-only for this client).

**`Cache_layout.FS`** = `Fs.S` + `record_dir_name path name` (write-if-absent) +
`real_dir_name dir_path name` (name, or `.tsync-name` content when escaped; `""` if missing).

### 3.2 Internals (single implementation)

- **`Manifests.S`** (per-file resolution): `root`, `path key`, `ensure_parent`, `published key`
  (memoized by `(ino,size,mtime)`), `write key m` (sole writer; stamps name), `delete`,
  `current key` (**the single resolution point**: staged edits if a sidecar exists, else
  published), `forget`, `memo_size`.
- **`Staged_manifest.S`**: `root`, `path`, `exists` (a *directory* at the path is not an edit),
  `read` (→ `Owed|Committed`, bad ⇒ `.bad` + None), `read_edits`, `write` (always `Owed`, stamps
  name), `commit key staged published` (→ `Committed`), `delete`, `rename`, `fold ~rel_dir ~deep`,
  `list`, `uuids` (every body any sidecar names), `entries`.
- **`Staged_body`**: `path`, `ensure ~uuid ~len` (create/grow, never shrink), `resize` (exact),
  `write`, `read_into`, `copy` (body→body), `copy_chunk ~group ~index` (published→body via
  `Cache.read_into`), `forget`, `link_group ~uuid ~len ~group` (publish by hard link),
  `whole_path`, `adopt_whole ~src ~uuid` (rename, EXDEV ⇒ copy+unlink), `whole_read_into`,
  `whole_forget`.
- **`Chunk_cache`**: `exists group`, `ensure ?force`, `ensure_fetched ?force → fetch`,
  `put_group ~group ~member`, `read_into ~group ~index buf ~chunk_off → served`,
  `link_in ~src ~group → bool`, `pin ~group ~until`, `unpin`, `forget`, `in_flight`, `stats →
  (files, bytes, pinned_bytes)`, `enforce_cap → swept`.
- **`Partial`**: pure `missing ~have ~want`, `interval`, `is_record`; stateful `recorded`, `load`,
  `reset`, `start`, `take`, `publish ~complete`, `drop`, `drop_beside`.
- **`Data.S`**: `pread ~id ?stream ~manifest`, `pread_key`, `published`, `write`, `truncate`,
  `create`, `sync key ?cancel` (upload + promote), `stage_whole`, `ensure_local ?keep`,
  `assemble_to`, `fetch_range`, `chunk_residency`, `forget_chunks`, `discard_staged`,
  `staged_body_path`, `enforce_chunk_cap`, `chunk_stats`, stats/progress accessors.
- **`Folder_ids.S`**: `marker_name`, `lookup_id`, `lookup_id_removed`, `ref_of_key → Root |
  Dir id | File (parent_id, leaf)`, `write → Written | Held id`, `replace`, `key_of_id ~root id`,
  `whereabouts → Live id | Moved (id, key) | Removed id | Unknown`, `forget`, `reparent`, `rebuild`.
- **`Cache_layout.S`**: `record_dir_name`, `real_dir_name`, `clear_projection` (rm -rf
  `scratch/`), `sweep_stale ~cutoff` (reap `folders/` entries with mtime < cutoff−1, prune empty
  dirs).
- **`Checkout.availability : locality -> key -> availability`** (synchronous, for the CLI and
  FileProvider): staged sidecar exists ⇒ `Cached`; else map the published sidecar; if any group
  body is absent or has a `.manifest` beside it ⇒ `Online_only`; if every group has a live pin
  (`.pin` mtime ≥ now) ⇒ `Pinned (min deadline)`; else `Cached`. Unreadable ⇒ `Online_only`.
  Wire spelling: `online-only | cached | pinned`.
- **`Resolve`**: pure decision tables (§4.8, §4.9).
- **Maintenance**: `Temp_files`, `Staged_orphans`, `Export_records`, and `Maintenance_lwt` task
  list (§4.11).

### 3.3 Error cases

- A manifest with a hole in its chunk list (group missing for an index) ⇒ `Backend_error "manifest
  <id>: missing chunk <i>"`; a staged `Inherit` slot with no base ⇒ `Backend_error "staged <id>:
  chunk <i> inherits nothing"` — never serve zeros as content.
- A fetched member whose length ≠ manifest's size ⇒ `Backend_error "chunk <k>: have N bytes,
  manifest says M"`; the atomic write fails, nothing lands.
- `read_into` exceeding 15 s ⇒ scheduler timeout (FUSE answers EIO); the fetch continues.
- Folder ops under a parent with no known id ⇒ `Backend_error "<key>: this client holds no id for
  the folder it is in; run 'tsync sync' first"` (refused before anything changes).
- `symlink` with policy ≠ `Keep` ⇒ `EPERM`.
- `upload` for a key with neither staged data nor a symlink manifest ⇒ `ENOENT` (the pool must
  not publish an entry for bytes never sent).
- `revert` with no versions ⇒ `Failure "no versions for <rel>"`.

### 3.4 How hosts repurpose this subsystem

The same components are assembled differently per host. The choice that differs is the
**published-tree implementation** (full vs lazy) and which operations a frontend drives.

| Host | Tree | Instantiates | Role / differences |
|---|---|---|---|
| Linux/macOS daemon, FUSE frontend (`tsync mount`) | full checkout (absence = domain does not have it) | file ops, data, chunk cache, staged, WAL, maintenance | FUSE is served one process per binding (byte `read`/`write`/`truncate`, `close` queues upload, `scratch/` holds `.fuse_hidden*`). **Every process serving a domain runs its own upload and metadata queues** (it sends only what it was handed; a process without queues accepts writes it never sends). The **converge** process (the parent that forked the frontends) additionally runs WAL reconcile, the change poller (`apply_foreign_ops`) and maintenance. All processes share one cache root on disk. |
| macOS File Provider extension | full checkout | same engine; frontend uses `availability`, `write_whole` (the system hands back complete files ⇒ `staged/whole`, adopted by rename), `assemble_to`/`fetch_range` into a system-chosen path, `ensure_cached` (pin) | Whole-file promotion leaves the chunk cache empty (the extension keeps its own copy). |
| Android app | **lazy checkout** (absence = not fetched yet; listing a folder pulls it from the store and prunes) | same engine over the lazy tree | Share-sheet saves use `write_whole`. Storage may not support hard links ⇒ promotion falls back to writing groups. |
| http-proxy / share server | reads only | its own data-layer instance over the domain's cache (`pread`), no staged writes | Serves shared files through the chunk cache; its pull table is not visible over IPC. |
| CLI (`tsync ls`, `tsync cache --prune`, export, import, resync) | full checkout, synchronous reads | `availability` (no event loop), maintenance tasks, resync/import walks writing via `record` | `tsync cache --prune` runs exactly the on-demand task list. Export uses `assemble_to` and `exports/` records. |

### 3.5 Item operations (the contract frontends depend on)

These are the per-item operations every frontend drives (FUSE directly in-process; File
Provider, Android, CLI and share clients through daemon IPC verbs `list_dir`, `list_all`,
`create`, `write`, `delete`, `rename`, `mkdir`, `rmdir`, `symlink`, `evict`, `restore`
(= make available offline / pin), `ensure_cached` (= materialize to a path), `fetch_range`,
`revert`; the IPC wire format is specified with the frontends). `t` is a logical key.
"Mirror" = local manifest mirror; "staged" = staged sidecar + bodies; "WAL" = intent log;
"uploader" = the process's upload queue; "meta queue" = its metadata queue. Unless stated, an
operation needs **no network**.

| Operation | Preconditions | Effect (in order) | Postcondition | Errors |
|---|---|---|---|---|
| `kind t` | — | stat mirror path | `Dir` if a directory, `File` if a sidecar file, else `Absent` (staged-only files read `Absent` here; use `stat`/`resolve`) | — |
| `stat t` | — | mirror dir ⇒ dir stat; else `resolve` | staged size/mtime win over published; symlink ⇒ `S_LNK`; `None` if neither | — |
| `resolve t` | — | read staged sidecar, else published | `Staged(edits, base?)` \| `Published m` \| `None` | — |
| `list_children prefix` | — | readdir mirror + staged tree (lazy tree: first pull from store unless an owed metadata op touches this folder) | files (key,size,mtime; staged wins), real subdir names, dir mtime `None` | lazy tree: store listing failure propagates, nothing pruned |
| `list_tree prefix` | — | recursive walk of both trees | every file under prefix | — |
| `read ?stream t buf off` | — | resolve; serve pieces from staged bodies / zeros / cache (fetching missing ranges); may start read-ahead | bytes returned, short only at EOF; 0 for unknown key; cache may gain bodies | 15 s deadline ⇒ timeout (EIO); hole in manifest ⇒ `Backend_error`; ENOENT after one retry |
| `write t buf off` | — | cancel any upload of `t`; under per-key lock: stage the group(s) touched (copying inherited/old bytes as needed, possibly fetching them), write bytes into staged body, write sidecar (`Owed`, mtime now) | staged size = max(old, off+len); **no WAL record yet** | fetch errors when an inherited chunk must be copied |
| `truncate t n` | — | cancel upload; under per-key lock: cut/extend slots, forget unreferenced bodies, fix boundary chunk, write sidecar | staged size = n; growth reads as zeros | as `write` |
| `create t` | — | under per-key lock: discard any staged bodies, write empty sidecar | staged empty file (O_TRUNC) | — |
| `write_whole t src` | `src` is a complete file | under per-key lock: discard staged bodies, rename `src` into `staged/whole/<uuid>` (copy+unlink across filesystems), sidecar `whole` with src size/mtime | `src` no longer exists at its path | rename/copy errors |
| `close t` | — | if a staged sidecar exists: new WAL record `Prepared [Put(rel,size)]`, hand to uploader | upload owed and durable | — |
| `upload t` (uploader only) | record owes `t` | staged ⇒ upload chunks/whole, write commit record into sidecar, promote (link bodies into cache, write published sidecar, delete staged sidecar, forget bodies); symlink ⇒ put manifest | published version on store; uploader then publishes journal entry, bumps cursor, deletes WAL record | ENOENT if nothing staged (entry must not be published); network errors retried by the queue; superseded write ⇒ promotion abandoned |
| `delete t` | — | meta lock; cancel upload; WAL `Intent [Delete]`; evict chunks, discard staged, delete sidecar; WAL → `Prepared`, hand to meta queue | gone locally at once; store delete (with version save if versioning) happens later | — |
| `mkdir t` | parent folder has a known id | meta lock; WAL Intent `[Mkdir(rel, id)]` (id = existing or freshly minted); create dir + `.tsync-dir`; → meta queue | folder exists locally with its final id | parent without id ⇒ "run 'tsync sync' first" |
| `rmdir t` | parent id known | meta lock; read folder id; WAL Intent `[Rmdir(rel,id)]`; `rm -rf` mirror subtree; → meta queue | gone locally; store retires it to trash later (subtree recoverable until expiry) | parent without id |
| `rename src dst` | for a folder: parent of src has an id | meta lock; cancel upload at dst; size = staged-or-published; WAL Intent `[Rename{src,dst,is_dir,id,size}]`; move staged sidecar(s) and mirror entry, re-stamp names, reparent folder id; cancel+re-queue uploads owed under moved staged files; if a never-published staged file just moved, complete the record (nothing owed) else → meta queue | moved locally at once | as mkdir for folders |
| `symlink target t` | policy `Keep` | meta lock; cancel upload; write symlink manifest into mirror; WAL `Prepared [Put]` → uploader (publishes the manifest) | link exists locally | `EPERM` for other policies |
| `evict t` | — | drop every cache group body of the published manifest (and their pins/records) | sidecar kept; file stays listed; re-fetches on demand; shared bodies of other files go too | — |
| `ensure_cached ?keep t` (IPC `restore`) | — | plan groups (fetch manifest from store if the mirror lacks it); fetch all (bounded); pin each group until now+keep (default 10 d) | reads served locally; cap spares them until the deadline; repeat moves deadline | network |
| `assemble_to t dst` (IPC `ensure_cached`) | — | fetch plan, then read whole content through the read path into `dst` (truncated), set mtime | `dst` is a regular file with the content; cache populated (not pinned) | network |
| `fetch_range t dst off len` | — | read range through read path; write into `dst` (created, not truncated) at same offset | returns bytes served (short at EOF); only covering chunks fetched | network |
| `revert ?version t` | versioning on the store; **online** | pick version (given ts, or latest by timestamp); fetch it; cancel upload; put it as `t`'s manifest on the store; install in mirror + discard staged; write journal `Put` + bump cursor | `t` equals that version everywhere | "no versions for …"; network |
| `apply_delete t` (replay only) | — | backend delete (with version) then local clear | — | network |
| `cancel_upload t` | — | ask uploader to stop an in-flight send | `true` if one was running (close re-queues) | — |
| `queue_put / resume_put / resume_meta / redo_local` | WAL plumbing, §4.6 | | | |
| `apply_foreign_ops ops` (poller only) | — | §4.8 | mirror reflects peer's ops; own unpublished work kept as conflicted copies | transient failure ⇒ entry re-read |

Diagnostics (`chunk_stats`, `chunk_residency`, `staged_count`, `uploads_in_flight`,
`downloading_now`, `download_progress`, `downloads_in_flight`, `read_ahead_in_flight`,
`meta_locked`, `meta_waiters`, `enforce_chunk_cap`) are read-only apart from the cap sweep.

---

## 4. Behaviour / algorithms

### 4.1 Name escaping and markers in the mirror

`ensure_dirs root rel`: for each component `c`, `enc = escape c`, `mkdir -p root/…/enc`; if
escaped, `record_dir_name (dir/.tsync-name) c` (only if absent). A file's escaped leaf is resolved
through its manifest body's recorded name; a directory's through `.tsync-name`. `Checkout.rename`
of a directory rewrites `.tsync-name` from the destination leaf (if escaped) and calls
`Folders.reparent` (rewrites `.tsync-dir` with the new leaf, the by-path entry and the reverse
index). Renaming a file re-writes the manifest through `Mf.write` so the body's recorded name
matches the new leaf. **Every local directory move must go through here**, or the folder becomes
unreachable by id.

### 4.2 Manifest memo

Per `(cache_root, domain)` a table `key → {ino,size,mtime,manifest}` plus an insertion FIFO,
capacity 1024. `published key`: `stat`; missing ⇒ forget + None; memo hit iff ino/size/mtime all
match; else `mmap` + memoize (evicting oldest beyond 1024). Rationale: a memoised manifest pins its
mmap; unbounded, an import of 19,261 files pinned 75 MB of page cache. FIFO not LRU: walks touch
each key once. `write`/`delete`/`rename` `forget` first.

### 4.3 Chunk cache read path (`read_into ~group ~index buf ~chunk_off`)

```
want = len(buf); off = group.offset(index) + chunk_off
if exists(group) [body present && no .manifest]:
    read_or_refetch(fetched=0, from_backend=false)
elif F.fast_read:
    f = within_deadline(ensure_fetched group)      // whole group
    read_or_refetch(fetched=f.pulled, from_backend=f.waited)
else:
    upto = min(chunk_off+want, group.size(index))
    fetched = within_deadline(fill group index want=(chunk_off, upto))
    read_or_refetch(fetched, from_backend = fetched>0)

read_or_refetch: n = pread(body, off); touch(body)
    if n == want → done
    else / on ENOENT → refetch: within_deadline(ensure_fetched ~force:true); pread again; from_backend=true
    (one retry only; a second failure is real)
```
A range reader **never waits for an in-flight whole-group fetch** (commit 6bd091b6): the
prefetch may have just started a 16 MiB fetch; waiting turns 100 KB into seconds and loses the
FUSE descriptor on phones. Two writers of one region write identical bytes at identical offsets,
so duplication is harmless.

`touch`: if body mtime older than 60 s, `utimes(now)` — keeps a frequently read body warm for the
mtime-ordered cap without an inode write per 128 KiB read.

`within_deadline work`: run `work` detached (async) and resolve a promise with its outcome; wait
on that promise with `Clock.with_timeout 15s`. Timing out abandons only this waiter; the fetch
completes for the cache and for joined readers.

### 4.4 Group fetch, range fill, and the partial record

**`ensure_fetched ?force group`** — in-flight dedup keyed by group key:
1. If `fetching[key]` exists → await it; answer `{waited = entry.from_backend; pulled = 0}` (a
   joiner pulled nothing — crediting joiners would count one fetch many times).
2. Else create entry, insert into table **before** any work can run (work is gated on a wakeup
   fired after insertion), then: if `!force && exists group` → nothing; else set
   `from_backend=true` (before taking the slot: the slot wait is network cost) and `pulled ←
   fetch group`. Always remove the entry in `finally`.

**`fetch group`** under `slots` (bounded by `max_downloads`; bounds *open destinations*, not wire
requests — a fetch opens its target before waiting for a download slot; without it 247 fds in
200 ms on a 250 MB file):
- If a partial record exists → `complete_body`: load held intervals; for every member not held
  whole (`interval = Some (0, size)`), `get_chunk`, check size, `pwrite` at its offset —
  **concurrently** (one task per missing member, unbounded at this layer); then drop the record (this publishes the
  body as whole); answer bytes fetched.
- Else `write_group`: `atomic_write_at body ~size:group.bytes` — `ftruncate` the temp to full size
  first (full disk fails before paying for bytes), fetch every member concurrently, check sizes,
  `pwrite` each at its offset, rename. Then drop any stale record. Answer `group.bytes`.
  A forced refetch of a whole body always takes this path (replacement, not in-place writes).

**`fill group ~index ~want:(lo,hi)`** (range fill), under `slots`:
1. `here = exists(body file)`. If here → `held = Part.load` (memory first, else parse beside);
   else `Part.reset` (a record whose body the cap took is about nothing), `held = nothing`.
2. `missing ~have:(interval held index) ~want` → `None` ⇒ return 0.
3. If body not here: `ensure_parent`, `Part.start` (atomic write of an **empty** record
   **before** the first byte — crash leaves "claims less than disk holds").
4. `get_chunk_range(member_key, lo, hi-lo)`; if 0 bytes ⇒ return 0.
5. `counted_write` a `pwrite` at `group.offset(index)+lo` (extends a sparse file).
6. `Part.take key index (lo, lo+got)` — synchronous in-memory widen (no yield between read and
   update ⇒ atomic w.r.t. concurrent fills).
7. `Part.publish key body ~complete:(whole group)` — serialized per body by chaining onto the
   previous publish promise; *reads the current in-memory view when its turn comes* (last one out
   decides); if every member is whole → delete the record (body now whole); else atomic-write the
   rendered record.

**`Partial.missing ~have ~want`** (one interval per member, never a set):
```
have=None           → Some want
want ⊆ have         → None
want entirely left  (d ≤ a) → Some (c, a)      // fetches the hole between too
want entirely right (c ≥ b) → Some (b, d)
want ⊋ have (c<a && d>b)    → Some (c, d)      // refetch the middle rather than split
c < a               → Some (c, a)
else                → Some (b, d)
widen (after fetch): (min a c, max b d)
```
Worst case per read is one gap inside one stored chunk; no interval algebra.

**Invariant**: a body is whole ⇔ it exists and no `.manifest` is beside it. Every path preserves
"on crash, the record claims ≤ what the disk holds": record before bytes; extend after bytes land;
eviction removes body **before** record (a record without body reads as empty group); `link_in`
removes a partial body+record before linking.

### 4.5 Local write path (staged)

All mutations of one key are serialized by a **per-key mutex** (`with_key`, table entry removed
when holder count drops to 0). Reads do not take it (a verify-read of a large file must not block
a promotion, and vice versa). `File.write`/`truncate` first `cancel_upload key` (an in-flight
upload reading the bodies must stop or it publishes torn content; close re-queues).

**`staged_for key`** (base state for a mutation):
- sidecar with `s_whole = Some uuid` → `split_whole` first (a whole body cannot be partially
  addressed): chunk it at the domain's current chunk size into per-group staged bodies in group
  layout (new uuid at each group start, `ensure` to layout length, copy each chunk, slot =
  `Staged{uuid, offset}`), write sidecar (`s_whole=None`), forget whole body; recurse.
- sidecar exists → use it.
- none, published exists → slots all `Inherit`, size/chunk_size from published, mtime now.
- none, nothing published → empty, chunk_size = `R.chunk_size ()`.

**`write key buf ~offset`**:
```
st = staged_for key; base = published key; cs = st.s_chunk_size
new_size = max(st.s_size, offset+len); grow slots to count(new_size, cs) with Zero
covers(j) = write fully covers chunk j (by new_size lengths)
for i in first..last chunk touched:
    ensure_group_body(base, st, covers, i)
    slot i must now be Staged{uuid, body_off}; pwrite slice at body_off + chunk_off
Mfs.write key {st with mtime = now}              // bytes before sidecar
return len
```
**`ensure_group_body`** — the whole *group* containing `i` is staged, never part of it (the group
key covers all members):
- `per` from `(st.s_chunk_size, cache_chunk_size)`; members `[first..last]` with layout offsets.
- **Fast path**: if all non-Zero members are `Staged` in one uuid at their layout offsets →
  `ensure(uuid, body_len)` and turn remaining `Zero` members into `Staged{uuid, offset}` (sparse
  region = zeros).
- **Slow path**: mint uuid, `ensure(uuid, body_len)`; for each member not covered by this write:
  `Staged b` → copy from old body; `Inherit` → `copy_chunk` from the published group via the cache
  (`read_into`, may fetch); `Zero` → nothing. Set every member's slot to the new body; then
  `forget` every old uuid no longer named (by difference: group members share bodies).
- Commit 99ec3cb6: previously one body per chunk and promotion re-read/re-wrote them (520 MB of
  local writes for a 260 MB file).

**`truncate key size`**: slots cut/grown to `count(size)` (grow ⇒ `Zero`); forget bodies no longer
named (by difference); fix the new last chunk: `Staged` → `resize(uuid, offset+len)`; `Zero` →
nothing; `Inherit` whose inherited length ≠ new length → `ensure_group_body(covers=never)` then
resize. Sidecar written with `mtime=now`.

**`create key`** (O_TRUNC): discard existing bodies; write empty sidecar (size 0, no slots,
domain chunk size). **`stage_whole key ~src_path`**: discard bodies; `adopt_whole` (rename, or
copy on EXDEV); sidecar with `s_whole`, size/mtime from `stat(src)`.

**Reading staged content** (`pread_staged`): `s_whole` → read that file; else per piece: `Staged`
→ read body at `offset+chunk_off`, zero-fill any short tail (a body is only as long as the writes
that reached it); `Zero` → zeros; `Inherit` → cache `read_into` from the base group (credited to
the pull table).

`mutated` (mtime := now) on every write is what **retires a Committed record**: the rewritten
sidecar is `Owed` again, so a pending promotion notices and aborts.

### 4.6 WAL, intents and the owed hand-off

One record file per unit of work, id = entry key (the *same* key later names the published
journal entry and the cursor peers compare — no second spelling). Directory per domain
(`<data_dir>/journal-pending/<domain>`) because ops carry domain-relative keys.

Singletons per process (keyed by directory): the `RECORDS` log (own id counter) and two `Owed`
hand-offs — `owed` (puts → upload pool, drained in parallel) and `meta_owed` (metadata backend
halves → metadata queue, drained in recorded order). One consumer each; a second `consume`
displaces the first; `idle` resets to a no-op taker (record stays written).

`Owed.signal t x = t.take x`: returns when the consumer has *taken* the record (so a delete right
after a close finds an upload to cancel); never blocks when nobody consumes (the record already
persists the work).

API: `record key ops` (Intent), `write key record`, `advance key state`, `note_failure key kind
detail` (attempts+1, lastError; state unchanged), `complete key` (unlink), `find`, `update_ops`,
`list` (this client's uuid only, sorted by `Entry_key.compare`), `owed_metadata` (records with no
`Put`), `discharge ~publish ~cursor key ops`:
```
advance key Executed → publish key ops (journal entry) → cursor key (bump) → complete key
```
A crash in any window leaves a record reconcile can finish by asking the backend.

**Put**: `close key` → if staged sidecar exists, `queue_put` → `hand_over W.owed (fresh entry
key) [Put(rel, s_size)]` = write record `{state=Prepared}` then `signal`. `Prepared` = local half
done, backend half owed.

**Metadata op** (`owing ops local_half`):
```
ek = fresh entry key
W.record ek ops                       // Intent, before anything changes locally
r = local_half()                      // on exception: W.complete ek; re-raise
if r = Nothing  → W.complete ek       // the store is owed no word (e.g. rename of a never-published staged file)
else            → hand_over meta_owed ek ops   // rewrite as Prepared + signal
```
All metadata mutations run under the **single global metadata mutex** (`with_meta`) held only
inside a component that is structurally unable to call the store (it is not given the store
interfaces at all): a slow/absent link can never freeze the mount while the lock is held.

**Reconcile** (owned by `sync/replay.ml`, uses this API; listed for the recovery contract):

| state at startup | action |
|---|---|
| `Executed` | if journal entry already published → complete; else write entry under the same key, bump cursor, complete |
| `Prepared`, single `Put` | `resume_put` (re-signal under same key if staged or symlink manifest exists; else complete) |
| `Prepared`, metadata | `resume_meta` (re-signal to meta queue) |
| `Intent`, metadata | `redo_local` each op (idempotent), then `resume_meta` as Prepared |
| `Intent`, with put | drop ops another client touched since this key; apply meta ops; resume put or publish meta entry; complete if nothing left |
| staged sidecar with no record | `queue_put` under a fresh key (crash between staging and recording) |
| failure | `note_failure` and leave it for next start |

`redo_local` per op (under meta lock): `Put` no-op; `Delete` → `clear_local`; `Mkdir` → create
dir + write id; `Rmdir` → delete dir only if it still holds that id; `Rename` → only if source
present and destination absent.

### 4.7 Upload and promotion (local write → published version)

`File.upload key` (called by the upload pool): staged ⇒ `Data.sync`; else symlink manifest ⇒
`St.put_manifest`; else ENOENT.

**`Data.sync key ?cancel`**:
```
match Mfs.read key:
  None             → ()
  Committed _      → promote_pending key            // crash after commit: no re-upload
  Owed staged      → published = upload_staged key staged ?cancel
                     (Mfs.commit key staged published — written BEFORE any local move)
                     promote_pending key
```
`upload_staged`: `s_whole` → `R.upload ~src_path:whole_path` (remote snapshots the file by reflink
where the fs can clone, else maps it — see remote subsystem); chunked → `R.upload_chunks ~size
~chunk_size ~mtime ~source` where `source i` is decided I/O-free: beyond slots or `Zero` →
`Filled zeros`; `Inherit` → `Stored (base key i)` (no re-upload of unchanged chunks; error if no
base); `Staged` → `Filled` reading the body (missing/short body ⇒ zero tail). Holes are still
real chunks with keys.

`promote_pending key` (under the per-key lock): re-read sidecar; only if still `Committed
(staged, published)` → `promote`; otherwise log "superseded before promotion" and stop (a write
since retired the record; its own close/next start queues the upload owed).

**`promote`** (every step idempotent; readers may run concurrently):
- whole: `Mf.write key published` → `Mfs.delete key` → `whole_forget`. The cache deliberately
  gets **none** of the file's chunks (the FileProvider keeps its own copy; caching would double
  disk).
- chunked: for each published group that is `touched` (some member `Staged`) **and** `local`
  (every member `Staged` or `Zero`):
  - if all members share one body at the group's layout offsets → `Sb.link_group ~uuid
    ~len:staged_layout_len ~group`: refuse unless `len = group.bytes`; `resize(uuid, len)` (zeros
    for unwritten members, cut anything past the last); `Chunk_cache.link_in ~src` (hard link).
    If link unsupported/false → `write_group`.
  - else `Chunk_cache.put_group ~member` (each member filled from staged into its own buffer).
  Untouched groups keep their key; any cached body for them is still right.
  Then `Mf.write key published` → `Mfs.delete key` → `discard_bodies staged`.
  **Order is load-bearing** (commit 6933cc16): bodies go last, after the published sidecar and
  the removal of the staged sidecar, so a reader resolving the key finds whichever representation
  it lands on still on disk. `pread_key` additionally retries once on ENOENT (resolution and read
  are separate steps).

**`Chunk_cache.link_in ~src ~group`**: if `links_supported = Some false` → false. Else: if a
partial body occupies the destination, unlink it and its record (else it would be published as
the group); `link(src, dst)`; count the size; `utimes(dst, now)` (else the cap sees it as old as
the write). EEXIST → true (already published; idempotent). EPERM/ENOSYS/EOPNOTSUPP/EXDEV →
remember `Some false` process-wide (some Android storage shims) and return false. Other errors →
false without remembering. A link, not a rename: both names stay readable across the flip.

`put_group`: no-op if body exists whole; else `write_group` then drop any record.

### 4.8 Peer entries (`apply_foreign_ops ops`)

Two phases so the store is never read under the metadata lock (commits e8fe2452, ab3811bd):

1. **Read ahead** (no lock): `owed = W.owed_metadata()`; for each op adopt ancestor folder ids
   top-down from the store's markers (`adopt_ancestor_ids`: a `Put` materializes parent dirs with
   no id; adopt only, never mint — minting forks the namespace). Then repeatedly *survey*: run
   `gather` + `Resolve.Arrival.decide` against an answer cache `reads = {markers, manifests}`;
   when a lookup hits a missing answer it raises `Unread`, which is filled from the store
   (`St.holder_at` for markers; `R.fetch_manifest` for manifests — only if the parent folder has a
   local id) and the pass restarts. `Mkdir` with no id that will `Make_folder` → adopt the id from
   the store marker. Only `Write_theirs`/`Adopt_theirs_at_destination` decisions fetch manifests.
2. **Apply** under the meta lock, from `reads` alone: re-read `owed_metadata`; for each op
   `gather → decide → enact actions in order`. If a needed answer is missing (local state changed
   since read-ahead) → fail `Retry.Transient "changed here while the entry was being read"`; the
   poller re-reads the entry. Failures propagate: the poller must not advance past an entry it
   could not apply.

`gather` resolves where the op lands here: a path a peer names is walked through
`Folder_ids.whereabouts` — a folder this client moved since is followed by id **only if the store
still files that id under the op's name**; a file the peer names is followed through this
client's own unpublished file renames (`renamed_since`, chain bounded by count).

**Arrival decision table** (`Resolve.Arrival.decide`; full product printed by `tests/unit/resolve`):

| facts | decision |
|---|---|
| Put | `[Retarget_our_rename if renamed_onto] ++ [Our_folder_aside Published_as_rename if our folder with id there / Here_only if without id] ++ [Our_staged_file_aside if staged && !renamed_onto] ++ [Write_theirs]` |
| Delete, staged here | Skip (Ours_publishes_later) — the edit outlives the removal |
| Delete, not staged | Remove_file |
| Mkdir, folder already here elsewhere (by id) | Skip (Already_applied) |
| Mkdir | `[Our_staged_file_aside if staged file at name] ++ [Our_folder_aside as rename if another folder there] ++ [Make_folder]` |
| Rmdir, path held by another folder | Skip (Held_by_another) |
| Rmdir, by id or at path | Rescue_staged_under; Remove_folder |
| Rename folder, our op on it owed | Skip (Ours_publishes_later) |
| … source gone | Skip (Nothing_to_move) |
| … already there | Skip (Already_applied) |
| … destination holds same folder | Retire_stale_source |
| … destination holds another folder | Our_folder_aside as rename; Move_folder |
| … destination free | Move_folder (staged content under it moves with it) |
| Rename file | `[Our_staged_file_aside if destination staged] ++ [Move_file if source here else Adopt_theirs_at_destination]` |

Enactments: *aside* = move to a free conflict name (§4.9) via `rename_local` (staged sidecar moves
too; owed uploads cancelled and re-queued under the new path); `Our_staged_file_aside` also
`queue_put`s the copy; `Our_folder_aside Published_as_rename` records a metadata rename op
(owed) from where the store files it; `Rescue_staged_under` moves every staged file under the
removed folder to conflict names beside the folder (sorted by path for deterministic numbering);
`Write_theirs` cancels any upload and writes the peer's manifest; `Remove_file` = cancel upload +
`clear_local` (evict chunks, discard staged, delete sidecar); `Make_folder` = create dir + write
op's id (final from mkdir); `Retire_stale_source` = move source aside, `forget` its folder ids,
`reparent` destination; `Retarget_our_rename` = move ours aside and rewrite (via `W.update_ops`)
every owed rename onto that name to target the conflict name.

### 4.9 Publishing own metadata (`backend_ops`, the metadata queue's call)

`gather` attempts the store side first where the store is the arbiter (`claim_folder`, file
rename), then decides (`Resolve.Publish.decide`):

| facts | actions; ending |
|---|---|
| Put | ; Publish |
| Delete, a file holds the name here again | ; Nothing_owed |
| Delete, gone here | Remove_from_store (save version if versioning, delete manifest); Publish |
| Mkdir, no id | Put_marker; Publish |
| Mkdir, gone here / store files it elsewhere | ; Nothing_owed |
| Mkdir, store granted the name (`claim_folder` → Held) | ; Publish |
| Mkdir, name taken by another id | Ours_aside; Again (decide afresh) |
| Rmdir, no id | ; Publish |
| Rmdir, already in trash / never published | ; Nothing_owed |
| Rmdir, published | Retire_to_trash; Publish |
| Rename folder, gone here / never published | ; Nothing_owed |
| Rename folder, store already files it here | ; Publish |
| Rename folder, name taken | Ours_aside_as_rename; Superseded |
| Rename folder, free | Move_marker; Publish |
| Rename file moved / landed (src gone, dst there) | ; Publish |
| Rename file failed, source still on store | ; Retry (re-raise the failure) |
| Rename file, source gone, ours staged | Queue_upload; Superseded |
| Rename file, source gone, ours published | Republish_here (put manifest + journal entry + bump cursor); Superseded |
| Rename file, source gone, nothing here | ; Nothing_owed |

Endings: `Publish` → answer `[op as published]` (a folder's `Mkdir`/`Rename` dst is rewritten to
where it is **here now**, found by id — a local rename may have moved it); `Nothing_owed` → `[]`;
`Again` → recurse; `Superseded` → raise `Retry.Cancelled`; `Retry` → raise the move's failure.
File rename on the backend: save version of src, `Js.rename_file`, then **unconditionally**
rewrite the destination manifest's recorded name (a backend move does not rewrite the body).
Folder move: put new marker (+anchor) first, then remove the old marker only if it still names
this id (crash leaves a stale marker readers skip, not an unlisted folder). Retire to trash:
put a trash marker `{name,id,path}` at `<trash ns>/<Id.short>`, then anchor to trash, then remove
the old marker.

**Conflict names** (`conflict_key ~n key`): file `name (conflicted copy from <client>)ext` (ext =
from last `.`), `n>1`: `(conflicted copy <n> from <client>)`. Folders keep the whole leaf (no ext
split). `aside_name` picks the first `n ≥ 1` where the mirror has nothing **and** no staged sidecar
exists.

### 4.10 Materialization, pinning, stat, listing

- `stat`: mirror entry is a directory ⇒ dir stat (0755, nlink 2, size 0, mtime now); else
  `current`: staged → regular file with staged size/mtime; published symlink → `S_LNK`, 0777,
  size = target length; published → regular 0644. uid/gid = process's, ino 0, atime now,
  ctime = mtime.
- `ensure_local ?keep key`: `fetch_plan` = published → all groups; staged with base → only groups
  with some `Inherit` member; staged without base → none; not in mirror → `R.fetch_manifest`,
  write sidecar, all groups. Fetch groups (bounded by `group_slots`), count a completed download,
  then pin every group until `now + keep` (pin needs a body to stand beside, so after fetch).
- `assemble_to key ~dst_path`: fetch plan, then read through `pread_key` in `cache_chunk_size`
  buffers into `dst_path` (O_TRUNC), then `utimes` to the staged/published mtime. Progress span
  total = bytes to fetch + file size (a bar that stops at fetch end looks like a hang); concurrent
  materializations of one key share a row (holder count).
- `fetch_range`: create `dst` (not truncated), read the range, write at same offset.
- Pinning: `pin` = create `.pin` if absent, `utimes(until)`; re-pin moves deadline; no-op when
  body absent. `unpin` removes marker. `forget` unpins, unlinks body and record.
- `chunk_residency`: published → sum of `member_count` of groups whose body is whole; staged whole
  → (n, n); staged chunked → `Staged|Zero` count as present, `Inherit` checks its group.
- `evict key` = `forget_chunks`: drop every group body of the published manifest — **reference
  blind** (a body shared with another file goes too; it re-fetches on demand; this avoids
  refcounting).

### 4.11 Read-ahead and the pull table

`pread ~id ?stream ~manifest buf ~offset`: split `[offset, offset+min(want, size-offset))` into
per-chunk pieces (`Chunks.pieces`), each served into its slice of `buf` concurrently under
`piece_slots`; answer = leading run of complete pieces (a short piece in the middle ends the
count). Sequential detection per **stream** (`id` or `id\0stream` — two descriptors keep their
own position): if `last_read_end[stream] = offset` → `read_ahead`; then store `offset+got`.

`read_ahead`: `window = min 8 (max 1 (4 MiB / (per*chunk_size)))` groups; from the group the read
is in (`first = group_start(last chunk read)`) through `first + (window+1)*per - 1`, sequentially
`ensure_fetched` each group; fire only if `readahead_in_flight < 4`; fire-and-forget (async,
errors swallowed), counted from before it starts. At defaults window = 1, i.e. current group + 1
ahead.

Pull table (`pulling_now`): per file `{bytes pulled, size, started, rate over ≥2 s window}`,
credited only with bytes that actually crossed the wire; entries idle > 8 s (or with negative idle
— clock stepped) pruned; ≤256 entries; top 16 by bytes reported. Per `Data.Make` instance (only
the one behind IPC is visible).

### 4.12 Cache cap (`enforce_cap`)

`held` counters per chunks root (in-process), maintained by `counted_write` (size delta before/
after every write into a body name: new file +1 file, size difference, disappeared −1), `link_in`,
`forget`, `pin/unpin`. `anchor()`: if the root does not exist → zero counts; else first call walks
once (`entries`: readdir 4096 shards under `dir_slots`=16, stat each under `metadata_slots`=64;
`.manifest` records skipped, `.pin` → (body, mtime)).

```
anchor()
if now < next_expiry && !(max_cache set && bytes - pinned_bytes > cap): return nothing
walk → bodies, pins
unlink lapsed pins (deadline < now); recount from walk (exact) with live pins
if over cap:
   candidates = bodies not pinned, sorted by mtime ascending (coldest first)
   while bytes - pinned_bytes > cap: unlink body; dropped; then drop its .manifest (after!)
return {files, bytes} dropped
```
Pinned bytes neither evicted nor counted. Best-effort: a body deleted under a reader is
re-fetched (`read_into` retry). Triggers: `After_upload` and `Periodic housekeeping_interval`
(domain engine) — reads alone grow the store, so periodic is required.

### 4.13 Folder id index

- `lookup_id key`: root → `.tsync-root`; else `.tsync-dir` marker's id. **Never mints** (minting
  on a read would recreate a deleted folder from a stat).
- `write key marker`: if the folder holds a different id → `Held id` (references never change
  under a folder); else `replace`.
- `replace`: mkdir -p; rewrite `.tsync-name` if leaf escaped; write `.tsync-dir`; write
  `by-path/<md5(key)>` = id; if parent has an id, write `folders/<id>` = `{parent, name = leaf of
  key}` (name from where it sits, not from the marker — a moved marker spells the old leaf). A
  parent with no id ⇒ unindexed until recorded.
- `lookup_id_removed`: live id, else `by-path` (the id outlives the folder so ops recorded under
  it stay nameable; on disk because the applying process is not the describing one).
- `key_of_id ~root id`: climb `folders/<id>` → parent … → `.tsync-root`, with a seen-set (cycle
  ⇒ None); fold names into a key; **verify** `lookup_id(key) = Some id` before believing it (stale
  entry costs an answer, never a wrong folder). Reads only.
- `whereabouts key`: `Live id` | via by-path id: `Moved (id, where key_of_id says)` or
  `Removed id` | `Unknown`.
- `ref_of_key`: path "" → `Root`; own marker → `Dir id`; else parent marker → `File (id, leaf)`.
- `forget key`: recursively unlink `.tsync-dir` under the subtree and the by-path entry.
- `rebuild`: walk the mirror; for a directory with a marker under a marked parent, write
  `folders/<id>`; a directory without a marker cuts the chain (children get `parent=None`, not
  the nearest marked ancestor); then unlink every `folders/<id>` not seen. (Note: `by-path/` is a
  directory inside `folders/` and is not in `seen`; `unlink_quiet` on a directory fails quietly.)

### 4.14 Resync support

Full resync (`ops/resync`, another subsystem) does: `clear_projection` (rm `scratch/` only),
walk the store writing through `Checkout.record ~on_other:`Replace` (rewrites every live manifest,
marker and name marker in place — mount keeps serving), then, **only if the walk reached
everything**, `Checkout.sweep_stale ~cutoff:walk_start` and `Cache_layout.sweep_stale`. Chunks
and staged data are never touched (content addressing keeps chunks valid; staged is sole copy).

`Checkout.sweep_stale` (cutoff − 1 s for coarse mtime clocks): walk the mirror; a directory whose
`.tsync-dir` mtime is stale was not visited ⇒ `rm -rf` it whole and report `Rename{src=here,
dst=key_of_id(id), is_dir, id}` if the index now places that id elsewhere, else `Rmdir(rel, id)`;
nothing beneath is reported. A stale file → unlink and report `Delete rel` (internal leaves
unlinked silently). Directories left empty are removed. Ops returned in walk order.

### 4.15 Lazy checkout (Android)

`Lazy_checkout` wraps `Checkout` with a different meaning of absence ("not fetched yet"):
`list_children ~prefix` first `pull`s: skip if the folder has no local id, or if any owed metadata
record names a key directly in this folder (a listing would undo an unpublished mkdir/rename);
else `Pull.children ~folder_id` from the store, `record ~on_other:`Keep` each, and **prune** the
published entries not in the listing (files via `Manifests.delete`, dirs via `delete_dir`). Staged
entries are never pruned. The pull fails (rather than skips) on an unreadable child, so a partial
listing never prunes.

### 4.16 Maintenance sweeps

| Task | Trigger | Rule |
|---|---|---|
| mirror temp files | on demand (`tsync cache --prune`) | walk `manifests/` (stats in pool of 64, recursion outside the pool); unlink non-dir entries whose name is a tsync temp name whose owning pid is dead |
| staged orphans | on demand | unlink files in `staged/chunks` and `staged/whole` not named by any sidecar (`uuids()`) **and** mtime ≤ now − 3600 s; then prune empty dirs under `staged/manifests` |
| export records | on demand | unlink `exports/*` with mtime ≤ now − 30 days |
| applied journal entries | on demand + daily | `Applied_entries.prune ~keep_days ~keep_bytes:64 MiB` |
| chunk cap | after upload + periodic | §4.12 (engine) |

`run_task` logs and swallows a failing sweep (siblings unaffected). The grace period is what lets
the orphan sweep run without a lock against a live domain (a body is created before the sidecar
naming it).

---

## 5. Interactions

**Depends on**
- `Remote.S` (remote subsystem): `get_chunk`, `get_chunk_range`, `fast_read`, `chunk_size`,
  `upload_chunks`, `upload` (whole file, reflink snapshot), `fetch_manifest`.
- `File_store.S` (`Js`): `write_journal_entry`, `bump_cursor`, `rename_file`, `head_manifest_opt`,
  `journal_entry_published`.
- `Store.S` (`St`): `put_manifest`, `delete_manifest`, `put_raw/delete_raw`, `marker_id_at`,
  `holder_at`, `claim_folder`, `placed`, `get_anchor/put_anchor`, `put_folder_marker`,
  `ensure_folder_id`.
- `History.S`: `save_version`, `list_versions`, `version_dir`, `get_version`.
- `Layout.S`: `folder_marker_key` (backend key of a folder's marker under its parent's id).
- `Journal`: entry keys, folder ids, client uuid, op JSON; `Applied_entries` (prune).
- `Manifest` (format, `Group`), `Chunks` (piece math), `Chunk_layout` (sharding), `Stored_key`
  (escaping), `Folder` (marker JSON), `Durable_queue` (record store), `Inode_tree` (entries from a
  store walk), `Conf`.

**Depended on by**
- Frontends (FUSE incl. `hidden_ops` → `scratch_path`; FileProvider → `availability`,
  `write_whole`, `assemble_to`, `fetch_range`; Android → `Lazy_checkout`, `write_whole`; share
  server) through `File_ops.S`.
- `sync/replay.ml` (WAL reconcile), `sync_lwt` (poller → `apply_foreign_ops`; upload pool →
  `Owing`, `Wal.owed`, `discharge`; metadata queue → `backend_ops`, `Wal.meta_owed`).
- `ops/resync` (`record`, `sweep_stale`, `clear_projection`, `Folder_ids.rebuild`),
  `ops/export` (`export_record_path`, `assemble_to`), IPC handler, diagnostics, domain engine
  (maintenance tasks).

**Main flows**
1. *Cold read*: FUSE read → `File.read` → `Data.pread_key` → `Mf.current` (staged? published?) →
   `pread` → pieces → `Chunk_cache.read_into` → `fill` (range GET) → pwrite into sparse body +
   partial record → pread → bytes; sequential ⇒ read-ahead `ensure_fetched` next group.
2. *Write & close*: `write` (cancel upload, stage group body, sidecar) … `close` → WAL `Put`
   record (Prepared) → upload pool → `File.upload` → `Data.sync` → upload chunks → `commit`
   sidecar → promote (link bodies into cache, write published sidecar, delete staged) → pool
   `discharge` (Executed → journal entry → cursor → drop record) → cap `After_upload`.
3. *mkdir offline*: `mkdir` (meta lock; parent id required) → WAL Intent → create dir + marker
   (minted id) → Prepared → meta queue retries until online → `backend_ops` (`claim_folder`) →
   publish entry.
4. *Peer put arrives*: poller → `apply_foreign_ops` → read ahead (adopt ids, fetch manifest) →
   lock → decide → aside own staged copy if any → write their manifest to the mirror (chunks
   fetched lazily later).

---

## 6. Concurrency, durability & failure semantics

**Locks**
- Global metadata mutex (per `File.Make_with_layout` instance): all metadata mutations, peer
  application, conflict asides, `install_version`, `adopt_id`. Never held across a store call
  (enforced structurally: the locked component has no store handle). Observable via `meta_locked`/`meta_waiters`.
- Per-key data mutex (`Data.with_key`): write, truncate, create, stage_whole, discard_staged,
  promote_pending. Reads are lock-free and survive promotion by ordering + one retry.
- Per-body publish chain for partial records; synchronous in-memory `take` (single event loop
  provides atomicity — every writer runs on the one loop).

**Pools** (see memory note *read-path pools*): `chunk_cache.slots` bounds descriptors (one per
group fetch or range fill) at `max_downloads`, **not** wire requests — `write_group` and
`complete_body` fan out over all members unbounded; the wire bound is `chunk_store.downloads`
/ `chunk_store.ranges` below `Remote`. A test supplying its own `Fetch` bypasses those pools.
`piece_slots` and `group_slots` are separate pools from `slots` (nesting a pool in itself
deadlocks). Stat walks use two separate pools for directory vs entry level for the same reason.

**Several processes share one cache root** (frontend processes + converge process + CLI
commands). Everything on disk is designed to be safe under that (atomic renames, content-addressed
names, idempotent steps, mtime/pid-based sweeps, the durable queue's per-directory owner lock so
only one process drains a domain's WAL). The in-memory tables below are **per process only**.

**Singletons that must be one per process/domain**: WAL log + both `Owed` (keyed by dir), manifest
memo (keyed by root+domain), cache `held` counts (keyed by chunks root), `Folder_ids` (applied
once), `Partial` tables. Two memos over one tree would serve stale manifests; two WAL logs would
keep separate id counters. Note `Chunk_cache.fetching` (dedup) and `slots` are per `Data.Make`
instance; `Data.Make` is applied once per consumer (File, diagnostics, share server, export), so
dedup does not span consumers.

**Durability**
- All small metadata files use `atomic_write` = temp + rename, **no fsync** (survives process
  crash; power loss may lose recent renames).
- Staged write order: bytes → sidecar. Crash ⇒ at worst an unreferenced body (reaped after 1 h).
- Upload order: `commit` (sidecar gains `published`) before any local move; crash before ⇒
  re-upload identical bytes (dedup makes it cheap: "bytes uploaded by re-upload: 0"); after ⇒
  replay only local moves.
- Promotion order: link/put groups → published sidecar → delete staged sidecar → forget bodies.
- Cache body: whole bodies appear atomically (rename); partial bodies are covered by the record
  ordering rules (§4.4).
- WAL: Intent before local half (metadata); Prepared on hand-off; Executed → entry → cursor →
  delete.
- Undecodable staged sidecar ⇒ renamed `.bad`, never deleted, skipped by listings/folds.

**Reliance on cooperative, single-threaded scheduling** (a rewrite with preemptive threads or
parallel executors must add locks here):
- `Partial.take` reads and updates the in-memory held-interval table with no yield in between;
  two concurrent fills of one body are correct only because nothing else runs in that window.
- `Partial.publish` chains onto the previous publish promise and replaces the table entry with no
  yield between lookup and insertion.
- `ensure_fetched`: lookup of the in-flight table, creation and insertion of the entry happen
  without a yield (the work is gated on a wakeup fired after insertion); two callers could
  otherwise both start a fetch.
- The per-key lock table (`with_key`) creates entries and counts holders without a mutex.
- Pull-table credit (`credit_pull`), progress spans, read-ahead loop counter, manifest memo
  insertion/eviction, the cache `held` counters (`counted_write` does stat → write → stat and
  applies a delta; concurrent writers to one body are serialized only by the loop), `links_supported`.
- `Owed.signal` / `consume` swap a single mutable taker.
- `pulling_now` must not yield while folding the table (it is mutated by reads on the same loop).
Under true parallelism each of these becomes a mutex- or atomic-protected structure; `take` +
`publish` for one body in particular must be one critical section per body.

**Offline**: reads of cached/partially cached bytes are local; uncached reads fail within 15 s
(EIO), the fetch continuing. All mutations are local-first; backend halves wait in queues.
Listings never touch the network (except `Lazy_checkout`, which skips pruning on failure).

**Idempotence**: `redo_local`, every promotion step, `link_in` (EEXIST ⇒ ok), `put_group`
(exists ⇒ no-op), `ensure_fetched` (exists ⇒ no-op), pin (moves deadline), `record` (rewrites).

**Crash-left garbage and who reaps it**: temp files (dead pid) → temp sweep; staged bodies with no
sidecar → orphan sweep (grace 1 h); partial record without body → treated as empty group, reset on
next fill; stale `folders/` entries → `rebuild`/`sweep_stale`; stale mirror entries → resync sweep.

---

## 7. Design choices & rationale

| Choice | Why (source) | Rejected alternative |
|---|---|---|
| Staged data in its own store, not a spared region of the cache | cap/resync *cannot* delete sole-copy bytes (75c90fdd, 2d0f0fc9) | filter in the cap |
| Mirror filed by real path with escaped handles + name markers | walkable tree without the network; FAT/NTFS-safe names | hashed keys like the backend |
| Group = several stored chunks in one local file | network granularity (8 MiB chunk) ≠ disk granularity (16 MiB); fewer files | one file per chunk |
| Group key = hash of member keys | two groups sharing first/last differ inside; aliasing served wrong bytes | `<first>-<last>` |
| Partial bodies with one interval per member | a few-byte read no longer costs a 16 MiB group (b0ea0213); no interval-set algebra | all-or-nothing bodies; interval sets |
| Absence of `.manifest` = whole | keeps the old "name exists ⇒ whole" contract for every caller | a completeness flag inside the body |
| Range reads don't wait for in-flight group fetches | playback stalls/phone descriptor loss (6bd091b6) | join the in-flight fetch |
| 15 s read deadline, fetch continues detached | a suspend froze 44 s on a FUSE reader with the link down (0f9a529e) | unbounded retry ladder |
| Staged body per group in the group's layout; promote by hard link | 520 MB → 260 MB local writes for a 260 MB file (99ec3cb6, 4d12062f) | per-chunk bodies, copy on promote |
| Link, not rename, on promote | both names readable across the flip | rename (empties staged name at the instant) |
| Link support probed once, remembered | Android storage shims lack links; fallback writes the group | per-group probing |
| Bodies deleted last in promotion + one ENOENT retry | rclone verify-read hit ENOENT and deleted its copy (6933cc16) | lock reads against promotion |
| Commit record inside the sidecar (base64 manifest) | one atomic file; a later write naturally retires it | separate commit file |
| `Owed` vs `Committed` as a type, write can only produce Owed | a mutation cannot carry a finished upload's record past its bytes | a mutable `published` field |
| WAL record id = entry key | one unit of work keeps one name through queue, journal and cursor; driving recovery from the staged tree minted new keys and once left 295 orphans (wal.mli) | queue-minted ids |
| No `Committed` WAL state | saves a disk write per upload; reconcile asks the backend | extra state |
| Metadata intent before local half | crash between would leave a change nothing owed (8616490a) | record after |
| One global metadata lock that cannot reach the store | slow link must not freeze the mount | per-key locks (ponytail: add if contention measured) |
| Peer entries: read ahead, then apply from answers | slow link holds up that entry only (e8fe2452) | fetch under lock |
| Folder ids minted locally, final at mkdir; name clashes become conflicted copies | best-effort conflicts: resolve now, lose nothing, copies when in doubt | re-id on clash |
| Cap by mtime with a 60 s touch | cheap LRU approximation; no inode write per read | atime / access log |
| Cap uses in-process counts, one anchoring walk | status polls and post-upload checks walked 4096 shards (82e0adea) | walk every time; persisted counts (ponytail note) |
| Pin = marker whose mtime is the deadline | follows content across renames, shared by all files using the body (9b794f0c) | per-file pin list |
| Evict/forget_chunks are reference-blind | avoids refcounting; re-fetch on demand | refcounts |
| Whole-file promotion leaves cache empty | FileProvider keeps its own copy; avoid doubling disk | cache it |
| Manifest memo bounded FIFO(1024) | each memo pins an mmap; 75 MB pinned in an import | unbounded / LRU |
| Resync rewrites in place then sweeps by mtime | clearing first served an empty tree for minutes and dropped valid chunks (1e85630b) | clear + rebuild |
| Temp file names carry pid | sweep can run against a live domain; unique per call avoids ENOENT races | `path ^ ".tmp"`; suffix-only test matched user files (Syncthing re-download loop) |
| Staged orphan sweep uses a grace period | no lock needed; body precedes sidecar | lock the domain |

Related memory: *watch-reports-own-scratch-loop* — the reflink snapshot used when uploading a
whole staged file / local-store object creates `.tsync-tmp-*` in the watched directory; watchers
must ignore temp names (fixed in `Watch.drain`; `O_TMPFILE` does not help). Relevant if a rewrite
places any temp file in a watched directory.

---

## 8. Invariants the tests pin down

Snapshot tests (`<exe>.expected`); these are acceptance criteria.

**`tests/content/chunk_cache`**
- Two concurrent `ensure` of a cold group → one GET; first answers `backend=true pulled=16`, the
  joiner `backend=true pulled=0`.
- Body path = `<domain>/chunks/<first 3 chars>/<group key>`.
- After eviction a read re-fetches; `force` re-fetches a present body.
- Trio group (4+4+2 bytes): reading member 0 asks only `[0,4)` of member 0; body is 10 bytes with
  offsets 0/4/8; reading all three makes it whole (`partial=false`); peak concurrent GETs for a
  whole-group fetch = member count.
- `fast_read` store: a member read fetches the whole group (no ranges).
- A read proceeds while a whole-group fetch is held in flight; the group still arrives.
- A group shared by two files has the same key.
- Missing chunk → `Backend_error("no such chunk: …")`, in_flight back to 0.
- Read touches mtime; cap none = no-op; cap 20 drops coldest; cap 0 drops all including a partial
  body **and its record together**; re-read after refetch.
- Pin spares a body at cap 0; re-pin moves the deadline; lapsed pin is dropped then the body;
  unpin/forget clear pinned bytes.
- `link_in`: one body, two names; publishing twice ok; length mismatch refused; body readable
  after the staged name goes, no refetch; cap 0 never touches staged bodies.

**`tests/unit/partial_intervals`**: the `missing` table in §4.4 exactly (e.g. holds `[0,2)` wants
`[6,8)` → fetch `[2,8)`; holds `[3,5)` wants `[0,8)` → fetch `[0,8)`).

**`tests/content/partial_local`**: a file with every group present but one partly filled reads as
cloud; once filled, local (and stays local).

**`tests/unit/staged_codec`**: offsets round-trip (`aaaa@0 aaaa@8 aaaa@16`, one body); pre-offset
sidecars decode to offset 0 per body; a newer-version sidecar is not decoded and is set aside.

**`tests/scenario/staged`**: slot evolution — `[ISI]` after a 2-byte write in chunk 1, `[ISS]`
after whole-chunk overwrite, append grows slots, truncate to 10 → `[IS]`, grow to 20 → `[ISZ]`
with zeros, sync publishes; a 1-chunk edit adds 1 chunk object; replayed promotion uploads 0
bytes; re-upload without the commit record uploads 0 bytes (dedup); a write into the promote
window wins ("YYYYYYYY…"); handed-over whole file is moved, not copied; a byte write splits a whole
file into slots; whole file uploaded as-is; `create` → size 0; grouped: a 2-byte write stages the
whole group `[SSS]`.

**`tests/scenario/staged_groups`**: a write covering the file ⇒ one body; a partial write stages
exactly its group (`[SSSIII]` for per=3), reads merge staged + inherited; whole-file promotion
leaves the cache at 0/6.

**`tests/content/promote_race`**: reads and writes concurrent with a promotion all succeed (8
readers; mutation-checked).

**`tests/content/demand_paging`, `fetch_range`, `read_ahead`, `read_fanout`, `fetch_fanout`,
`download_progress`, `pulling`, `cache_cap`, `absent_probe`, `read_offline`**:
- Reads fetch only the chunks they touch (0/3 → 1/3 → 2/3 → 3/3); `fetch_range` serves a range
  without materializing, dst file size = end of range.
- Two streams on one file keep separate read-ahead positions.
- One read does not trigger read-ahead; a second sequential read fetches current + next group.
- A 200-piece read never exceeds its slot count but is not serialized; a 200-group fetch keeps
  open files ≤ slots + 4.
- Progress is monotone, covers fetch + reassembly, overlapping materializations share one row;
  a cached/staged file still reports reassembly.
- Pull rows: cold read attributed to its file with wire bytes and whole-file size; re-reading
  local data adds nothing; one fetch credited once; idle rows vanish; already-local groups not
  credited.
- Mirror absence = domain absence, answered without touching the backend.
- Offline read fails within its deadline; the fetch lands; next read is local.

**`tests/unit/folder_ids`** (25 checks): parent never named on a child's behalf; minted folder
resolves to its path at every level; rename keeps id; delete ⇒ unresolvable; corrupted entry does
not resolve to another folder and rebuild fixes it; lost index answers nothing until rebuild;
rebuild prunes departed and recovers escaped names; unbounded depth; cycle ⇒ None; a folder
holding an id refuses another via `write`, `replace` takes it.

**`tests/unit/manifest_naming`**: renames re-stamp recorded names; escaped file/dir names shown
real; staged rename re-stamps staged name.

**`tests/unit/manifests_memo`**, **`wal_log`**, **`owed`**: memo shared across applications,
per-domain; WAL log shared per domain; `Owed` semantics (§4.6).

**`tests/unit/sweep_scope`**: temp sweep removes dead-owner temps only; staged sweep with 1 h
grace removes only the 2 h-old orphan; export record sweep keeps yesterday's, removes a 40-day one.

**`tests/unit/resolve`**: the full Arrival and Publish decision tables (§4.8, §4.9).
**`tests/scenario/conflicts`**, **`meta_offline`**, **`lazy_owed`**, **`upload_gone`**,
**`rename_listing`**, **`ops/rename`**, **`ops/resync`**: conflicted copies per the tables; offline
metadata survives and publishes later; a lazy browse does not undo an owed mkdir/removal; an
upload whose staged bytes vanished publishes no entry and is no longer owed; resync rewrites the
mirror in place, keeps chunks, reports drops as ops (`Delete`, `Rmdir(id)`, folder move as
`Rename`), does not sweep after an incomplete walk.

---

## 9. Open questions / inconsistencies

1. **No fsync anywhere in the cache/WAL/staged path** (`atomic_write` is temp+rename). Crash
   safety claims hold for process crashes, not power loss (rename may be persisted before data on
   some filesystems → zero-length sidecars/records). A rewrite should decide explicitly.
2. **`ensure_group_body` slow path forgets stale bodies before the caller writes the new
   sidecar.** A crash between `Sb.forget old` and `Mfs.write` leaves the on-disk sidecar naming a
   deleted body → reads of those members raise ENOENT (retry then fail); the sidecar's other
   members are fine. Similarly `truncate_locked` forgets bodies before writing the sidecar. This
   contradicts the "bytes before sidecar, crash leaves at worst an unreferenced body" contract.
3. Stale doc references: `Cache_layout.clear` (mentioned in `Folder_ids`, `Staged_manifest`,
   `Chunk_cache.anchor` comments) no longer exists — `clear_projection` only removes `scratch/`
   and resync no longer drops chunks or the index; `Staged_orphans` cites
   `Staged_body.stage_slot` (removed in 99ec3cb6); `Staged_manifest` comment mentions
   `s_published` (now the `Committed` variant).
4. `Folder_ids.rebuild` iterates `folders/` and calls `unlink_quiet` on `by-path` (a directory);
   harmless but by-path entries are never pruned — they grow with every folder path ever seen.
5. `Chunk_cache` in-flight dedup and `slots` are per `Data.Make` application, and `Data.Make` is
   applied per consumer (File, diagnostics, share server, export) — two consumers in one process
   can fetch the same group concurrently and each hold `max_downloads` descriptors. `held` counts
   are shared per root; other *processes* writing the same cache drift the count (acknowledged).
6. `Checkout.availability` reports a partly cached file as `Online_only` (ponytail note).
7. `Partial.publish`'s serialization chain entry is removed only by `reset/drop`; a body that stays
   partial forever keeps its entry (bounded by distinct partial bodies seen in the process).
8. `read_ahead` uses `Manifest.Group.of_table ~per i` stepping `i` by `per` from `first`; with
   `hi` clamped to `n-1` the last partial group is included. Window formula means default
   lookahead is exactly one group (16 MiB) — confirm this is intended for high-latency links.
9. `Wal.Job.of_string` never returns `None`, so garbage in the WAL dir decodes as an empty
   `Intent` record (ops `[]`), which reconcile then completes (deletes). Intended ("legacy"), but
   it silently discards any unparseable record.
10. `Staged_manifest.exists` returns false for a directory at the sidecar path; `fold` skips
    `.bad` files — but `list`/`uuids` therefore ignore `.bad` sidecars' bodies, so the orphan
    sweep will reap the bodies a set-aside sidecar named after 1 h, making `.bad` preservation
    largely moot.
11. `stat` for directories reports mtime = now on every call (directory mtimes are not tracked).
12. **The metadata mutex is per process**, and so is the per-key data mutex, yet several
    processes share the mirror and staged tree (a FUSE frontend process mutates locally and
    promotes its own uploads while the converge process applies peers' entries and reconciles). Nothing on disk serializes a
    frontend's `rename` against the converge process's `apply_foreign_ops` or a promotion. The
    code comments assume "one lock" suffices; cross-process exclusion appears to rest on the
    frontend/converge split of duties and on idempotent, rename-based steps. A rewrite should
    either confirm this or add a per-domain file lock.
13. Per-key `with_key` locks and the global meta lock are independent; `File.rename` moves staged
    sidecars under the meta lock without taking the per-key data lock of the moved key, relying on
    `cancel_upload` + re-queue. A concurrent write to the source key during a rename is not
    obviously excluded.

---


---

OCaml implementation notes for this subsystem: [ocaml/04-checkout-cache.md](ocaml/04-checkout-cache.md).
