# Backend driver: `local` (a directory on this machine, or a mounted NAS)

Implements [the store contract](../06-backends.md) (§3.1) over a POSIX filesystem. This file says how each contract operation is realised and where the driver is weaker or stronger than the contract; it does not restate the contract.

Code: `lib/backends/drivers/local/local_backend.ml` (driver, a functor over the I/O seams), `lib/lwt/backends/drivers/local/local_backend_lwt.ml` (instance + registration), `lib/local/io/{filename,fs}.ml` (temp names, `mkdir -p`, `rm -rf`), `lib/local/device/` (queue depth, reflink clone, directory watch), `lib/core/bigstring.ml` (`map_file`).

---

## 1. Role

- The only driver with `local_path = Some root`: the store *is* a tree, and callers may treat it as one (rename, rmdir, statvfs). That grant is what makes it the only store a chunk collection can run on (§9).
- The only driver with `fast_read = true`: reading a whole cache chunk costs about what a range does, so the chunk cache fetches whole groups from it.
- Linkless: no `link` (network link name), `health = always_up`, not wrapped in the counting/admission wrapper (§3.2 of the contract: stores with `local_path` are neither counted nor gated), no uplink probe.
- No retry ladder of its own. Every call is one attempt; the kind attached to a failure (§6) is for the caller (composite fallthrough, deferred target, uploader).

## 2. Configuration

Backend object in a domain's `backends` list:

| JSON field | Type | Default | Meaning |
|---|---|---|---|
| `type` | `"local"` | — | selects this driver |
| `name`, `role` | string | — | generic (see contract §2.5) |
| `path` | string | **required** | store root directory. Missing → `Failure "local backend: missing field: path"`. Used verbatim: not expanded (`~`), not made absolute, not required to exist (directories are created on first write). |
| `verifyWrites` | bool | `true` | read back every chunk after writing it and file/clear its corruption marker (§7). Accepts JSON bool, or strings `true/1/yes/on`, `false/0/no/off` (case-insensitive); anything else → default. |
| `link` | — | — | **refused**: `backend <name>: "link" names a link, and a local store has none`. |

Unknown fields are refused by the generic config parser (driver spec lists `path`, `verifyWrites`). Registry field spec: `path` (String, label "Local path", no default), `verifyWrites` (Bool, default `"true"`). Nothing is secret.

Instance construction (`make ~verify_writes ~root`) allocates, per instance: a walk pool of 64 slots (§8), a lazily-created scratch directory, a lazily-probed device concurrency, and a watcher table (§6). Nothing touches the disk at construction.

## 3. On-disk layout

- Key `k` ↔ file `<root>/<k>` (`resolve "" = root`, else `root ^ "/" ^ k`). Keys are used as relative paths byte-for-byte; `/` is the separator. No escaping.
- Dir-marker keys (ending `/`) ↔ real directories. There is no zero-byte object for them.
- Staging names: `<dir of target>/.tsync-tmp-<pid>-<seq>.tmp`, `seq` a per-process counter (unique per call, so two concurrent writers of one key never share a temp file). A name is a temp name iff it starts with `.tsync-tmp-` **and** ends with `.tmp` (prefix is the discriminator; a pure `.tmp` suffix test once hid users' `.syncthing.*.tmp`). `pid` lets a sweeper tell a crashed writer's leftover from a live one.
- Read scratch directory: `<root>/.tsync-tmp-scratch.tmp`, mode 0700, created on first read (`EEXIST` fine; any other failure → no scratch, clones stage beside the object). It is itself a temp name, so listings hide it.
- GC artefacts that live beside the layout because the store is a tree (owned by GC, see §9): `<root>/tsync/<domain>/chunks.from/` (from-space of an open collection) and a lock file `<root>/<gc-run marker key>.lock`.

Consequence of mapping keys to paths (deviation from an object store): the key space must be prefix-free between objects and directories. Key `a` and key `a/b` cannot coexist (`ENOTDIR`/`EISDIR` on write → Permanent). tsync's layout never needs both.

## 4. Primitives

**stage(tmp, body)**: `open(tmp, O_WRONLY|O_CREAT, 0644)`; `pwrite` the whole body from offset 0 in a loop (a 0-byte write mid-body → failure "short write at offset N"); **`fsync(fd)`**; `close`. Opened for writing even when the body is empty (Windows refuses to flush a read-only handle; and a zero-length write would otherwise create nothing).

**write(path, body)**: `mkdir -p dirname(path)` (0755, `EEXIST` tolerated, walks up with `stat`); `tmp = temp_path(path)`; `stage(tmp, body)`; `rename(tmp, path)`. On failure the temp file is **not** removed (§12).

Why fsync before rename: rename/link commit to the filesystem journal ahead of delayed allocation; without the flush a crash can leave the final name on an empty file. The containing directory is **not** fsynced, so a crash after `put` returns can lose the rename (the key reads as its previous version or absent) but never exposes a truncated body.

**map(path, offset=0, len=size)**: `len = 0` → empty buffer without opening. Otherwise take a read descriptor on a *snapshot* and `mmap(PROT_READ, MAP_SHARED)` `[offset, offset+len)`:
- Snapshot = copy-on-write clone: Linux `FICLONE` ioctl from `src` onto a fresh `O_EXCL 0600` temp file in the scratch directory (or beside `src` when no scratch is given), which is then opened read-only and unlinked at once; macOS `clonefile()`. The clone shares extents, costs no space or time proportional to the file, and is immune to later writes to `src`.
- Where the filesystem cannot clone (ext4, tmpfs, NFS, SMB, ZFS-without-reflink…) the file itself is opened read-only and mapped. The per-directory answer is memoised for the process (one failed attempt per directory); a single warning is logged per process.
- The descriptor is closed right after mapping; the mapping keeps the inode alive.
- Correctness does **not** depend on the clone: a published name is only ever replaced by rename (a new inode) and never written through or truncated, so a mapping of the old inode keeps serving the bytes it was made from.
- Bodies never land on the process heap; bytes are read when pages are touched.

**claim(path, body)**: `mkdir -p dirname`; `stage(tmp, body)`; `link(tmp, path)`; always `unlink(tmp)` afterwards (errors ignored). `link` succeeds → this caller won; `EEXIST` → map the existing file and return it. `link`, not `rename`, because rename replaces silently. The winner's body is complete the instant its name appears.

**prune_marker_dirs(marker_path)**: `rmdir` the marker's parent, grandparent and great-grandparent (`<shard>/`, `<domain>/`, `corrupted/`), each failure ignored (non-empty or concurrently recreated). Keeps an emptied shard from listing as a stray entry.

## 5. Operations

| Contract op | Realisation |
|---|---|
| `put k body` | dir key → `mkdir -p <root>/<k>` (body ignored). Else `write(path, body)`, then if `verifyWrites` → `verify_written k` (§7). |
| `put_if_absent k body` | `claim(path, body)`. Returns the argument buffer itself on a win, the mapped existing body on `EEXIST`. The existing body is mapped **without** the scratch directory (a clone, if any, is staged beside the claim key). |
| `get k` | `map(<root>/<k>)` via scratch. `ENOENT` → Permanent failure (contract: missing = failure). |
| `get_opt k` | as `get`; `ENOENT` → `None`. |
| `get_range k off len` | `stat` → `size`; `n = max 0 (min len (size − off))`; `map(path, off, n)` via scratch. Never more than `len`; short only at EOF; `off ≥ size` → empty buffer (not `None`). `ENOENT` → `None`. Clamping is mandatory: mapping past EOF is a SIGBUS on first touch, not a short read. |
| `head_opt k` | `stat` (follows symlinks). Directory → `{size=0; last_modified=st_mtime; etag=None}`; else `{size=st_size; last_modified=st_mtime; etag=None}`. `ENOENT` → `None`. No etag: size+mtime is all a filesystem offers (mtime has sub-second precision on most local filesystems). |
| `delete k` | `head_opt` then `rm -rf <root>/<k>` (lstat-based, does not follow symlinks; `ENOENT` and per-entry unlink/rmdir errors swallowed); if `k` is a corruption-marker key → `prune_marker_dirs`. Returns `head_opt ≠ None`. |
| `delete_multi ks` | `delete` each, sequentially, in order. Absent keys succeed. |
| `copy src dst` | src dir key → `mkdir -p <root>/<dst>` (children are not copied). Else `link(src, dst)` first (no parent check: the stat is a third to half the cost on bulk paths). `EEXIST` → success (destination kept as is). `ENOENT` (first time) → `mkdir -p dirname(dst)`, retry once; second `ENOENT` is the source's. `EXDEV`, `EMLINK`, `EPERM`, `EOPNOTSUPP` → body copy: `map(src)` (no scratch) then `write(dst)`. Other errno → failure named for the **source** key (link's errno speaks for the destination, which misleads). Hard links are safe because names are never written through. |
| `list_prefix ?max_keys p` | Level-order walk from `<root>/<p>` (§8). Emits regular files as `{key=<p-relative path>; size; mtime; etag=None}`; recurses into directories; ignores other file types (symlinks are `stat`ed, so a symlink to a file is listed as a file). Temp names are skipped (never listed, never deleted). A directory with no (non-temp) children whose key ends in `/` is emitted as its dir-marker key `{size=0; last_modified=0}` — matching S3's zero-byte marker (the root of a prefix without trailing `/` is not). `ENOENT` anywhere → skipped. `ENOTDIR` on the prefix itself → the prefix is a file: emit it as one entry. Result sorted by key, then truncated to `max_keys` (no early stop). |
| `watch k last_seen` | §6. |
| `get_many`, `list_many` | `None` (filesystem reads are not round trips; the generic batcher fans `get_opt` out). |
| `verify_all` | `Unsupported` — every write is already checked; `tsync gc --verify` is the sweep. |
| `discard` | `Unsupported` — GC on a local main already deletes on the machine it runs on (§9). |
| `capabilities _` | `{share_url=None; chunk_size=None; max_concurrency=Device.max_concurrency(root); verified=verifyWrites}`; the prefix is ignored. |
| `fast_read` | `true`. |
| `local_path` | `Some root`. |
| `health` | `always_up`. |

Prefix/key semantics note: `list_prefix p` resolves `p` as a path, so it matches only whole path components (`tsync/d/chunks/ab` lists the directory `ab`, not keys starting `ab…`). tsync only lists directory-shaped prefixes (ending `/`) or single files, where this equals object-store semantics.

## 6. Watch (cursor wait)

- Watches `dirname(<root>/<k>)`, never the object: writes rename a new inode into place, so a watch on the name would follow an inode unlinked a moment later.
- One watcher per directory per store instance, opened on first `watch` and kept for the process (never closed; the set is bounded by the domains served). A failed open (directory missing, platform without support) is not cached, so a later call retries.
- Linux: `inotify_init1(IN_NONBLOCK|IN_CLOEXEC)` + `inotify_add_watch(dir, IN_CREATE|IN_MOVED_TO|IN_CLOSE_WRITE)` (close-write rather than modify: one wake per written file, not per `write()`). macOS: `open(dir, O_EVTONLY|O_CLOEXEC)` + `kqueue` `EVFILT_VNODE` with `EV_ADD|EV_CLEAR` and `NOTE_WRITE|NOTE_LINK|NOTE_DELETE|NOTE_RENAME` (`EV_CLEAR` or the queue stays readable forever). Other platforms: no watcher.
- `wait` = wait for the descriptor to become readable, then drain (≤ 64 non-blocking read/`kevent` passes, `EINTR` retried). The drain reports "changed" if any event is nameless or names a non-temp entry; if every event named a temp name (Linux only; kqueue events carry no names) the wait resumes. This filter exists because a read's own reflink staging used to wake the reader, which read again — an unbounded loop that ended in OOM. The scratch directory (§3) removes the cause on every platform; the filter is the belt.
- `watch` = race the wait against `default_watch_interval` (2 s). Timeout → return. Any other failure of the wait → sleep 2 s, return. No watcher → sleep 2 s, return. `last_seen` is ignored: the caller always re-reads and compares.
- Non-recursive: only direct children of the cursor's directory (`tsync/<domain>/`) wake it — the cursor itself, the GC run marker, the lock file, a new subdirectory. Spurious wakes are allowed by the contract.
- If the watched directory is deleted and recreated, the cached watcher goes silent (inotify `IN_IGNORED` / kqueue `NOTE_DELETE`): the store degrades to 2 s polling for the rest of the process. Never late beyond the cap, so the contract holds.

## 7. Verified writes and corruption markers

Enabled by `verifyWrites` (default on). Performed inside `put`, after the rename, only for keys that have a corruption-marker key (chunk keys under `tsync/<domain>/chunks/<shard>/<h1>-<h2>`; not `chunks.from/`, not manifests, not markers). Covers every way a chunk lands on this store (uploader, http-proxy frontend PUTs, mirror, repair, deferred forwards) because it sits in the driver.

1. Map the just-written file (**read back**; never hash the argument, which may alias a buffer its owner has reused — hashing it would agree with itself).
2. Read fails (exception of any kind, e.g. `EIO`) → write marker `{"reason": "<exception text>", "at": <now>}`.
3. `key_of_body(read) = leaf` → `unlink(marker)`; if that removed something → `prune_marker_dirs`.
4. Otherwise → write marker `{"computed": "<h1>-<h2>", "size": <read length>, "at": <now>}`.
5. Verification never fails the `put` (the bytes are already published; a raised error would lose the finding). A failure *writing the marker* does propagate.

Marker writes use `write` (temp + fsync + rename) and are not themselves verified. Order is verify-then-act (cloud side is act-then-verify because its events are at-least-once and unordered; here the writer is local and the rename already happened).

Strength: the read-back usually comes from the page cache, so it proves the bytes survived tsync's own pipeline and the filesystem write path, not that the medium holds them. Media rot is found by `tsync gc --verify` (reads on keep) or a later read. `capabilities.verified = verifyWrites`, so an operator who turns it off makes "no markers" read as "nobody looked", not "clean".

`delete` of a marker key prunes its directories; GC deletes a chunk's marker with the chunk.

## 8. Concurrency and memory

- `list_prefix`: breadth-first by level. Per level, 8 directory workers pull directories from a shared list; within a directory, 8 entry workers (`64 / 8`) pull names from a shared list; each `stat` holds one slot of the per-store 64-slot walk pool, **only around the stat** (a pool held across recursion deadlocks: outer levels hold every slot while inner ones wait). Workers pulling from a list, not a task per entry: a task per entry once kept ~100 MB of pending tasks alive for 500k manifests. Peak concurrent stats per store: 64 across all concurrent walks.
- `max_concurrency` (reported in caps, read by GC for its per-step pools with default 8 when `None`, and by the http-proxy frontend to size its listener): probed once per store, lazily, on first `capabilities`.
  - Linux: find the mount covering `root` in `/proc/self/mountinfo` (longest mount-point prefix; field 3 = `major:minor`); `/sys/dev/block/<maj:min>` (if it has a `partition` file, use its parent disk); read `device/queue_depth`, else `queue/nr_requests`; `d > 0` → `max(2, min(64, 4·d))`, else `None`. USB Bulk-Only enclosures report 1 → 4.
  - macOS: `df -P <root>` → device node; `diskutil info <dev>` → `Solid State` / `Protocol` / `Device Location`: HDD on USB/FireWire → 4; other HDD → 8; SSD on USB → 16; other SSD → 64; unknown but external → 8; else `None`. Any subprocess failure → `None`.
- No per-store limit on concurrent `put`/`get`: callers' pools bound them. Local stores are exempt from the uplink gate.
- Memory: bodies are mmapped (off-heap, paged on demand); `put` writes the caller's buffer directly. `list_prefix` materialises the full listing (sorted) before returning.

## 9. GC and discard through `local_path`

`discard` is `Unsupported`; instead GC requires the **main** to have `local_path` and operates on the tree directly (full algorithm: [05-ops-config §4.9](../05-ops-config.md)). What it relies on from this driver/filesystem:

- Opening a run: `rename(<root>/tsync/<d>/chunks, <root>/tsync/<d>/chunks.from)` — atomic, same parent. `chunks/` is not recreated; every writer's `mkdir -p` makes it reappear.
- Marking (promotion): per live chunk, `rename(chunks.from/<shard>/<k>, chunks/<shard>/<k>)` (parent made on `ENOENT`, tried once). Moves, never copies: a filesystem without hard links would otherwise rewrite the whole live set (test-pinned: 0 `copy` calls).
- Abandoning: whole-shard `rename(chunks.from/<shard>, chunks/<shard>)` when the destination is absent/empty; `ENOTEMPTY|EEXIST|ENOTDIR|EISDIR` → per-chunk moves.
- Closing: per shard, `unlink` each remaining name in `chunks.from/<shard>/` then `rmdir`. Copies (replicas/backfills) get `delete_multi` first.
- Mutual exclusion: `lockf(F_TLOCK)` on `<root>/<gc-run key>.lock`, released by the kernel on death.
- Reads during a run look in `chunks/` then `chunks.from/` (the collection layer asks for both keys).
- Other `local_path` users: disk-space reports (`statvfs(root)`), integrity's namespace listing (`readdir` of the domain prefix), the FUSE frontend's hidden files.

## 10. Error mapping

Wrapped as `Retry.Failed {kind; op = "local <op>"; detail = "<key>: <strerror>"}` in `put_if_absent`, `get`, `get_opt`, `get_range`, `copy` (link path):

| errno | kind |
|---|---|
| `EIO ENOSPC EMFILE ENFILE EAGAIN EINTR EBUSY` | Transient (clears when the condition does) |
| anything else (`EACCES EPERM EROFS ENOTDIR EISDIR ENAMETOOLONG ELOOP ESTALE …`) | Permanent (someone has to act) |

Not wrapped (raw `Unix_error` or `Failure` escapes): `put` (including `mkdir -p`, stage, rename, marker write), `head_opt` (non-`ENOENT`), `delete`, `delete_multi`, `list_prefix` (non-`ENOENT`/`ENOTDIR`), `copy`'s body-copy fallback, "short write". The generic classifier treats unrecognised exceptions as **Transient**, so e.g. `EACCES` on `put` is Transient while `EACCES` on `get` is Permanent.

Absence: `get` → Permanent via `ENOENT`; `get_opt`/`get_range`/`head_opt` → `None`.

## 11. Consistency the driver relies on from the filesystem

- `rename(2)` atomically replaces the target within one directory; `link(2)` fails `EEXIST` atomically. Both are what make `put` last-writer-wins without partial reads and `put_if_absent` a real precondition.
- Unlinked-but-open/mapped inodes stay readable (POSIX). This is what makes mmapped reads safe across GC and replacement.
- Directory reads are consistent enough that a just-renamed name is visible to the next `stat`/`readdir` on the same host (read-your-writes on one machine).
- Writes are durable in order (body before name), not durable on return (no directory fsync).

## 12. Deviations from the contract (weaker or stronger)

Stronger:
- Reads are consistent immediately after writes (no eventual consistency); listings see a write as soon as it is renamed.
- `put_if_absent` returns the winner's complete body with no window.
- `copy` is O(1) where links work.

Weaker / different:
- `delete` of a **dir-marker key** removes the whole subtree, not a zero-byte object. `delete` swallows per-entry unlink/rmdir errors and still reports `true` if the key existed — so `delete_multi` can "succeed" having removed nothing (e.g. `EACCES`), contrary to "delete all or raise".
- `copy` of a dir key creates an empty directory; `copy` onto an existing destination keeps the destination (`EEXIST` → success) rather than overwriting it. Safe for content-addressed chunks; would be wrong for a mutable key.
- `list_prefix` matches whole path components only; `max_keys` does not stop the walk early.
- `head_opt` never has an etag; `last_modified` of a dir marker from listing is 0 but from `head_opt` is the directory's mtime.
- Error kinds are inconsistent across ops (§10).
- Orphaned temp files: a failed `stage`/`rename` in `put`, or a crash, leaves `.tsync-tmp-*.tmp` in the store; they are hidden from listings but nothing sweeps the store root for them (the pid-based temp sweeper walks the client's manifest mirror, not stores).
- `watch` ignores `last_seen`.

## 13. Network filesystems (NAS: NFS, SMB/CIFS, sshfs/FUSE)

The driver has no NAS mode; each mechanism degrades as follows.

| Mechanism | On a network mount |
|---|---|
| Watch | inotify/kqueue deliver only this host's own changes; a writer on another machine never raises an event, so the cursor wait is plain 2 s polling. Local writers still wake at once. |
| `max_concurrency` | Linux: network/FUSE mounts have anonymous `0:N` device numbers with no `/sys/dev/block` entry → `None` (GC falls back to 8). macOS: `diskutil` does not describe an SMB/NFS source → `None` unless flagged external. |
| Reflink clone | Unsupported → the file itself is mapped (one warning per process). |
| `copy` | Hard links: NFS supports them; SMB often answers `EPERM`/`EOPNOTSUPP` → body copy (read + write over the wire). |
| `put` | `fsync` is a server round trip per object (NFS COMMIT). Rename is atomic on NFS/SMB servers for a single client. |
| `put_if_absent` | NFS `LINK` is atomic on the server, but a retransmitted `LINK` whose first attempt succeeded can answer `EEXIST` (if the server's duplicate-request cache misses it): the winner then reads back its own body as "the other writer's", which is still the correct answer. SMB hard-link support varies; where `link` is refused the claim fails Permanent (there is no fallback for claims). |
| mmap reads | Pages fault in over the network on touch. If another host deletes a file this host has mapped and not yet paged in (e.g. GC on another machine), NFS may return `ESTALE`, delivered as SIGBUS on page fault rather than as an error. |
| GC lock | `lockf` over NFS depends on the lock manager (NLM/NFSv4); over SMB it is advisory at best. Two hosts collecting one NAS main are not reliably excluded. |
| Error kinds | `ESTALE`, `ETIMEDOUT`, `EHOSTDOWN` map to Permanent (§10), though they are often transient on a NAS. |

Recommended topology (not enforced): at most one host runs GC against a NAS main; other hosts should reach it through an http-proxy frontend on the host that mounts it, rather than mounting it themselves.

## 14. Test-pinned invariants

- **durable_writes**: `put` and `put_if_absent` each publish exactly one temp file, and it was `fsync`ed before its `rename`/`link` (syscall order recorded; the count guards against a vacuous pass).
- **claim**: concurrent `put_if_absent` on one name → exactly one winner, all others receive the winner's body; a later claim on a taken name gets the existing body; a free name returns the caller's own body and stores it; `delete` returns `true` then `false`; after release the next claimant wins; no temp files or extra objects remain.
- **get_range**: exact slices at start/middle/end/whole; `[size−3, size+97)` → 3 bytes; offset past end → 0 bytes; absent key → `None`; bytes compared against the local slice, not just counted.
- **writes_in_flight**: a staged temp file is neither listed nor deleted; a user file named `.syncthing.*.tmp` is listed.
- **local_watch**: missing directory → no watcher; a rename into the directory wakes a watcher promptly; `watch` on the cursor returns promptly (< 1 s) after a write; a drained watcher blocks again; reads of the object do not wake a watcher on its directory; after reads, the only temp-named entry at the root is the scratch directory and the object's directory holds none; `watch` on a quiet directory returns at the cap (≥ 1 s).
- **corruption**: a good upload files no marker and caps report `verified`; a scrambled body is filed under its chunk's marker key with the hash it computed; a marked chunk is re-uploaded rather than deduped; the good rewrite clears the marker; no empty marker shard directories remain.
- **gc_cost / gc_targets / gc_queued**: a collection on a local main uses rename only (0 `copy` calls), never lists or marks replicas, deletes reclaimed chunks from copies first.

## 15. Open questions

1. `delete` swallowing unlink errors (§12) makes a failed GC delete on a local *copy* look successful. Should `rm -rf` failures other than `ENOENT` raise?
2. Error-kind inconsistency (§10): `put`'s raw errors classify as Transient, so a read-only or permission-denied store retries/queues forever instead of reporting a Permanent fault.
3. No sweeper for orphaned `.tsync-tmp-*.tmp` in store roots.
4. Linux device lookup: mount-point matching is a plain string prefix (`/mnt/tsync` also "covers" `/mnt/tsync2/...` if the latter is on a shorter mount); mountinfo's `\040` escapes are not decoded; a relative or symlinked `path` is not canonicalised before matching; btrfs and dm/LUKS volumes report `0:N`/`nr_requests` rather than hardware depth.
5. mmap turns media errors (`EIO`) and NFS `ESTALE` into SIGBUS at page-touch time, including inside `verify_written`'s hash; the "unreadable" marker path only catches errors raised by open/stat/mmap themselves.
6. No directory fsync after rename: acceptable for chunks (re-uploadable) — is it acceptable for the cursor and journal on a local main?
7. `watch` could honour `last_seen` by reading the cursor before waiting (cheap locally).
