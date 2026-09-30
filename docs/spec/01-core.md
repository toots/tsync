# 01 — Foundation layer: lib/core, lib/local, lib/lwt

Scope: `lib/core` (library `tsync_core`), `lib/local/{stdlib,io,device,runtime,tls,desktop_mounts}`,
and the scheduler-binding layer `lib/lwt/{local/io,core}` plus the pattern the rest of `lib/lwt/**` follows.

Structure: this file (§1–§9) is the language-neutral specification: formats, contracts, algorithms,
and the abstract runtime interface (§3.1–§3.2) that a Rust async runtime, a C event loop + thread pool,
or an OCaml 5 effects/domains runtime must each provide. The [OCaml notes](ocaml/01-core.md) hold OCaml
implementation notes: the functor-over-`Io.S` pattern, the Lwt binding, the `lib/lwt` mirror tree, dune
tricks, C stubs, and each Lwt-specific learning translated to effects/domains.


---

## 1. Problem

tsync is a set of cooperating processes (per-domain daemons/frontends, a sync process, one-shot CLI
commands, an Android app) that all speak the same vocabulary about the same store. This layer is that
vocabulary and toolbox, with no configuration and (mostly) no scheduler:

* **Names** — how an item is called by a user (`Logical_key`), how a store files it (`Stored_key`),
  how a frontend refers to it over IPC (`Item_ref`), how content is named (`Chunks.key_of_body`,
  XXH3 dual-seed), where a chunk lives (`Chunk_layout`). Every writer and reader must compute these
  identically across clients, languages (a Python bucket verifier re-implements the chunk key) and
  releases: they are persistent formats.
* **Tools every layer shares** — a durable on-disk work queue, a retry ladder with shared backoff,
  a per-peer health breaker, a bounded concurrency pool, a pooled HTTP client, a line-JSON IPC,
  spill-to-disk listings and an off-heap hash table, metrics, job progress/report, cooperative
  shutdown, a streaming ZIP64 writer, glob matching, logging.
* **Platform facts** (`lib/local`) — EINTR-safe stdlib, filesystem primitives, copy-on-write clone,
  device queue depth, fd limit, directory watch, per-OS paths, TLS backend selection.
* **A narrow runtime interface** — all concurrent logic is written against a small set of runtime
  capabilities (tasks, a resolvable promise, catch/finally, concurrent join, timers with cancellable
  races, mutex/condition, positioned file I/O). §3.1 lists them neutrally; §3.2 lists the ordering and
  atomicity guarantees the logic silently relies on. (How OCaml achieves this — functors over `Io.S`
  applied once to Lwt — is in the [OCaml notes](ocaml/01-core.md).)

It is separate because (a) the naming rules are a cross-client contract that must live in exactly one
place ("one spelling, or two things that can disagree" is the recurring rationale), and (b) keeping the
runtime behind a narrow interface lets logic be tested and reasoned about without naming a scheduler,
and keeps the choice of scheduler in one place (a Duppy/effects migration was explored against exactly
this seam — see the [OCaml notes](ocaml/01-core.md)).

---

## 2. Concepts & data model

### 2.1 Content hashing (XXH3-64, dual seed) — EXACT

* Algorithm: **XXH3-64** (xxHash v0.8 `XXH3_64bits_withSeed`), vendored single header, compiled inline
  (`lib/core/xxhash_stubs.c`). Seeds are small integers **0 and 1**.
* `hash_hex data seed` = `printf "%016Lx"` of the 64-bit result: **16 lowercase hex chars**, zero padded.
* **Chunk key** (`Chunks.key_of_body`, `lib/core/chunks.ml:1`):
  `hex(XXH3_64(body, seed=0)) ^ "-" ^ hex(XXH3_64(body, seed=1))` → 33 chars.
  `is_chunk_key name` ⇔ exactly one `-` at index 16 and both halves are 16 chars of `[0-9a-f]`
  (uppercase rejected). Decides copy/delete during store walks, so it tests what a key *is*.
* Streaming state (`Xxhash.create seed / update / digest`) is the same function as one-shot (the golden
  test checks at XXH3 branch boundaries 0,1,16,17,128,129,240,241,2600, 1 MiB, 1 MiB+1, 8 MiB).
* Known answers (`tests/unit/hash/hash.expected`, also read by a Python implementation):

  | input | seed 0 | seed 1 |
  |---|---|---|
  | `""` | `2d06800538d394c2` | `4dc5b0cc826f6703` |
  | `"hello world"` | `d447b1ea40e6988b` | `b7aeb52a10fdaf2d` |
  | `pattern-8388608` (byte i = (i*31+7) & 0xff) | `29a6314906cb27cd` | `314dbe6e90136337` |

  So the chunk key of `"hello world"` is `d447b1ea40e6988b-b7aeb52a10fdaf2d`.

Other uses of the same dual-seed construction (all `h0 ^ "-" ^ h1`):

| where | input | purpose |
|---|---|---|
| `Stored_key.hash_name` | a child's leaf name | manifest/marker key within a folder namespace |
| `Manifest` h1/h2 (domain layer) | concatenation over chunks of `"<chunkkey>-<len>;"` | whole-file digest, rebuildable from chunk keys without rereading bytes; streamed separately per seed |
| `Manifest` symlink | the target string | h1/h2 of a symlink |
| `Cache_layout.Group.key_of` | concatenation of member chunk keys each followed by `";"` | cache-file name for a group of chunks |
| `Cache_layout.export_record_path` | destination path | fixed-length file name |

`Stored_key.escape` uses **one** seed only: `".tsync-esc-" ^ hex(XXH3(leaf,0))`.

### 2.2 Chunking — EXACT

**Fixed-size, not content-defined.** A file of `size` bytes with per-file `chunk_size` is cut at
multiples of `chunk_size`; every chunk is `chunk_size` bytes except the last (`lib/core/chunks.ml`):

```
count(size, cs)      = size <= 0 ? 0 : ceil(size / cs)
index_of(cs, pos)    = pos / cs
offset_of(cs, i)     = i * cs
length_of(size,cs,i) = max 0 (min cs (size - i*cs))     # 0 past the end; cs=0 → 0
```

* `chunk_size` is recorded **per file in its manifest** and never changes for that file. New files use
  `Conf.chunk_size` if configured, else the primary backend's recommended `capabilities.chunk_size`
  (an http-proxy answers with the serving domain's), else `Conf.default_chunk_size = 8 MiB`
  (`8*1024*1024`), resolved once per process (`lib/domain/remote/remote.ml:95`). Symlink manifests
  carry `chunk_size = default` and no chunks.
* Empty file → 0 chunks.
* Dedup is purely by chunk key equality: two clients cutting the same bytes at the same chunk size
  produce the same keys. Different chunk sizes do not dedup.
* The local cache groups consecutive stored chunks into cache files of ~`cache_chunk_size`
  (default 16 MiB): `chunks_per_group = max 1 ((cache_cs + cs/2) / cs)` (domain layer, noted here
  because it is a function of chunk size).

**Range → pieces** (`Chunks.pieces ~chunk_size ~count ~offset ~length`): returns
`{index; chunk_off; len; dest}` in order, covering `[offset, offset+length)` exactly once, where `dest`
is the offset inside the caller's buffer. Empty if `chunk_size<=0 || length<=0 || offset<0`; stops at
chunk `count` (a range past the end is short, not an error). Examples (`chunk=8`):
`[6,10)` count 3 → `#0[6,8)@0, #1[0,2)@2`; `[12,28)` count 2 → `#1[4,8)@0`; `[16,24)` count 2 → none.

`Chunk_source.t` (how an uploader obtains a chunk's bytes, decided before any I/O):
`Stored of key` (inherited from a previous manifest, nothing to hash/send) | `Mapped of (unit -> bigstring)`
(mmap in place) | `Filled of {len; fill : bigstring -> 'a}` (written into a pooled buffer).

### 2.3 Chunk store layout — EXACT (`lib/core/chunk_layout.ml`)

* `fanout = 3` hex chars → `shards = 4096`; `shard_name n = "%03x"`; `shard_of key` = first 3 chars,
  or `"_"` for a key shorter than 3. `relative_path key = "<shard>/<key>"`. Same layout for the backend
  chunk store and the local chunk cache. Rationale: few hundred files/shard for 10 TB at 8 MiB.
* Given `chunk_prefix = "tsync/<domain>/chunks/"` (from `Conf_parsing`: root `tsync/`, domain root
  `tsync/<d>/`, `manifests/`, `chunks/`, `versions/`, `journal/`, shares at `tsync/shares/`):

| thing | key |
|---|---|
| chunk | `tsync/<d>/chunks/<shard>/<key>` e.g. `tsync/home/chunks/d44/d447b1ea40e6988b-b7aeb52a10fdaf2d` |
| GC "from" space (root renamed away during a collection) | `tsync/<d>/chunks.from/<shard>/<key>` |
| GC run marker | `tsync/<d>/gc-run` (sibling of chunks root) |
| GC run name | `%013.0f` of start time in **milliseconds**, e.g. `1755300000000` |
| GC job request | `tsync/gc-jobs/<d>/<run>/<shard>` |
| verify job request | `tsync/verify-jobs/<d>/<shard>` |
| corruption marker | `tsync/corrupted/<d>/<shard>/<key>` |
| `domain_roots` (all prefixes a domain owns) | `[tsync/<d>/; tsync/corrupted/<d>/; tsync/verify-jobs/<d>/; tsync/gc-jobs/<d>/]` |

* `marker_key k`: rewrite `…/<d>/chunks/<shard>/<chunkkey>` → `tsync/corrupted/<d>/<shard>/<chunkkey>`;
  finds the **last** `/chunks/` segment (a domain named `chunks` must not cut short); `None` for
  anything under `chunks.from/`, for markers, for an empty domain, for a non-shard or non-chunk-key leaf.
  Membership is by prefix, never by leaf shape (a manifest key is shaped like a chunk key).
* `is_marker_key` checks the whole shape (`<root>/corrupted/.../<shard>/<chunkkey>`) so a filesystem
  store's listed-back directories are not markers. `shard_of_job` answers `Some leaf` only if the leaf
  is a shard name.
* A domain literally named `corrupted`, `verify-jobs` or `gc-jobs` would collide — acknowledged, not checked.

### 2.4 Keys

**`Logical_key.t`** = `{prefix; path; kind : File|Dir}` (`lib/core/logical_key.ml`). The user-facing name.

* `to_string = prefix ^ path` (the wire/store spelling; carries no kind). Prefix is the domain's
  `domain_prefix` = `tsync/<d>/manifests/`. Root: path `""`, kind Dir → `tsync/home/manifests/`.
* `path` has no leading/trailing `/` (`Make.file/dir` trim exactly one of each); `leaf` = basename or `""`;
  `parent` of root is root, parent is always Dir; `file_in/dir_in` raise `Invalid_argument` on a File.
* Equality/compare include prefix and kind — a file and a folder with the same path are different keys.
* `rel_of_string s` = `Some (trim (s minus prefix))` iff `s` starts with the domain prefix.

Examples: file `photos/trip/img.jpg` → `"tsync/home/manifests/photos/trip/img.jpg"`, leaf `img.jpg`,
parent `"tsync/home/manifests/photos/trip"`.

**`Stored_key.t`** (`lib/core/stored_key.ml`) — opaque string, constructed only via namers or `listed`
(taking a store's listing at its word). The **inode model**: folders have stable random ids; children
are filed under the parent's id by hash of leaf name, so renaming a folder touches only its own marker.

* Sentinel `".tsync-"`: every store-internal leaf starts with it. `root_id = ".tsync-root"`,
  `trash_id = ".tsync-trash"`. Folder ids are `<12 hex>-<counter>` (minted in the domain layer).
* `namespace ~prefix ~folder_id = prefix ^ folder_id ^ "/"` (ends in `/` ⇒ `is_dir_key`).
* `child_key ~prefix ~folder_id name = prefix ^ folder_id ^ "/" ^ h0(name) ^ "-" ^ h1(name)`.
  E.g. `img.jpg` under `9f3a1c0428b6d5e7` → `9f3a1c0428b6d5e7/066843ea47b80079-e0e3d2bb9b72c14d`.
* `index_key` = `<prefix><id>/.tsync-index` (folder's cache of its children's bodies);
  `anchor_key` = `<prefix><id>/.tsync-parent`; `trash_namespace` = `<prefix>.tsync-trash/`;
  `share_key ~prefix token = prefix ^ token`.
* `parent_folder_id k` = basename of dirname; `folder_id_of ns` = last component of a namespace key.
* `internal_leaf l` ⇔ starts with `.tsync-` and is not an escape handle; `is_internal`,
  `is_child_object k` ⇔ not a dir key and not internal. `path_in ~prefix` strips a prefix (versions
  re-root a manifest key under another prefix sharing the folder id).
* **Mirror escaping** (for a local mirror filing items by real path): a component is kept iff
  `length <= 250` (NAME_MAX 255 minus margin), does not start with `.tsync-`, and has no char in
  `" * : < > ? \ |` or `< 0x20`. Otherwise it becomes `.tsync-esc-<16hex seed0>`. Reserved leaves
  beside mirror entries: `.tsync-name` (real name of an escaped directory), `.tsync-dir` (folder id
  marker). The real name is recovered from the manifest body (files) or `.tsync-name` (dirs).

**`Folder` bodies** (`lib/core/folder.ml`), JSON (Yojson.Basic, compact), filed at a `child_key`:

```json
{"dir":true,"name":"trip","id":"a1b2c3d4e5f6-7"}                       // marker
{"dir":true,"name":"trip","id":"a1b2c3d4e5f6-7","path":"photos/trip"}  // trashed marker
{"parent":"9f3a1c0428b6d5e7","name":"trip"}                            // anchor, at <id>/.tsync-parent
```

A body is a marker iff it parses as an object with `"dir": true` (missing name/id → `""`); anything
else (a file manifest) → `None`. An anchor has no `dir` field. `in_trash a ⇔ a.parent = ".tsync-trash"`.
When a marker and the anchor disagree, the anchor wins (marker is a stale leftover of a move).

**`Item_ref.t`** — how a frontend names an item to the daemon (never a path for directories):
wire forms `"root"`, `"d:<folder id>"`, `"f:<parent folder id>/<leaf>"`. Parsing is total: `d:.tsync-root`
normalises to `Root`; for `f:` the **first** `/` separates (leaf may contain `/`? no — neither id nor
leaf contain `/`; a leaf may contain `:`); empty id or leaf, bare prefix (`"d:"`), or anything else
(including a storage key) → `` `Bad s ``. `to_string` round-trips (Bad returns the original).

### 2.5 Random ids (`lib/core/id.ml`)

* `short ()` — 16 hex chars = two `Random.State.int64 < 2^32` printed `%08Lx%08Lx`, from a private PRNG
  seeded from 8 bytes of `/dev/urandom` (fallback: pid + time µs). The state is tagged with the
  seeding pid and **reseeded in a forked child** (commit a42c99e5: forked frontends drew identical ids).
  For staged-body names, trash entries.
* `token n` — `n` bytes of `/dev/urandom`, hex; raises rather than falling back. For share tokens, client uuid.

### 2.6 Temp names (`lib/local/io/filename.ml`) — cross-module convention

`temp_in dir = dir/".tsync-tmp-<pid>-<seq>.tmp"` (seq per process, from 1); `temp_path p` = temp in
`dirname p`; `scratch_leaf = ".tsync-tmp-scratch.tmp"`. `is_temp_name n` ⇔ prefix `.tsync-tmp-` AND
suffix `.tmp`. `temp_owner` parses the pid (`None` if not ours). Readers/sweepers (and the inotify C
stub, which duplicates the test) use it to hide/skip/reap. A suffix-only test once deleted a user's
`.syncthing.*.tmp` files forever — the prefix is load-bearing.

### 2.7 Durable queue on-disk format (`lib/core/durable_queue.ml`)

* One directory per target and domain (`Records.create ~dir`). Each record is a file named by its id
  containing `J.to_string job` (format owned by the job type; e.g. `Wal.Job`). Written by
  `atomic_write` (temp + rename).
* **Record id**: `sprintf "%020Ld-%08d-%d" (µs since epoch) seq pid`, e.g.
  `00001758000000123456-00000001-4242`. Lexicographic order = chronological; `seq` disambiguates
  within a µs (per `Records.t`); pid separates processes. `list` only considers names whose first char
  is `0-9` (others are temp files, possibly live in another process) and sorts them.
* **Claim lock**: `<dir>.owner` (sibling, not inside), `lockf F_TLOCK` on an fd kept open for the life of
  the claim. Kernel drops it on death.

### 2.8 Other byte formats

* **Listing record** (`lib/core/listing.ml`): concatenated records; `str` = int32-LE length + bytes;
  `int64` = 8 bytes LE. Record layout is the caller's sequence of field writers; decoder reads the same.
* **Hashtbl_mmap** (`lib/core/hashtbl_mmap.ml`): two regions. Blob (file-backed shared mmap of an
  unlinked temp file, initial `max 4096 (64n)` bytes, doubled via `ftruncate`+remap) of appended
  records `[u32le klen][u32le vlen][key][value]`; slot array (Bigarray int64, anonymous, power of two
  `>= max 16 (2n)`) holding `offset+1` (0 = empty). Linear probing from `Hashtbl.hash key land mask`;
  grow slots ×2 when `4*count > 3*slots`, rehash from slots (not blob, which holds superseded
  records). `replace` always appends (old records never reclaimed). No remove. `Int` storable = 8 bytes LE.
* **ZIP64 stream** (`lib/core/zip_stream.ml`): STORED only; every archive ZIP64; version 45; flags
  `0x0808` (bit 3 data descriptor + bit 11 UTF-8). Local header: sig `0x04034b50`, crc/sizes 0,
  extra 20 bytes = ZIP64 tag `0x0001`, len 16, two zero u64. Data descriptor: `0x08074b50`, crc32,
  u64 size ×2. Central entry: made-by `(3<<8)|45`; if size or offset ≥ `0xFFFFFFFF` all three move to
  a 28-byte ZIP64 extra (uncompressed, compressed, offset) with 32-bit fields = `0xFFFFFFFF`; external
  attrs = `(S_IFREG|mode or S_IFDIR|mode) << 16 | (0x10 if dir)`; default mode 0644, dirs 0755 with
  trailing `/`. Finish: ZIP64 EOCD (`0x06064b50`, size 44), locator (`0x07064b50`), EOCD
  (`0x06054b50`, counts min 0xFFFF, sentinels if ≥ 2^32). DOS time from **local** time; pre-1980 →
  date `0x21`, time 0. CRC-32 poly `0xEDB88320`. Caller writes payload bytes; `feed` only advances CRC
  and offset. Golden byte dump: `tests/unit/zip/zip_test.expected`.
* **IPC**: newline-delimited JSON over a Unix stream socket (see §3.8).

### 2.9 Constants table

| constant | value | where |
|---|---|---|
| default chunk size | 8 MiB | `Conf.default_chunk_size` |
| default cache chunk (group) size | 16 MiB | `Conf.default_cache_chunk_size` |
| shard fanout | 3 hex (4096) | `Chunk_layout.fanout` |
| mirror name max | 250 bytes | `Stored_key.name_max` |
| retry attempts (request) | 8 | `Retry.default_attempts` |
| request backoff | `min 20 (0.5·2^min(10,n-1))` × uniform[0.5,1.5) | `Retry.Make` |
| queue backoff | `min 300 (0.5·2^min(10,n-1))`, no jitter | `Durable_queue` |
| queue runaway cap | 100 000 queued → degraded, drop posts | `max_queued` |
| queue settle timeout | 60 s (min with grace when stopping) | `default_settle_timeout` |
| stall warning | 60 s | `stall_warning_interval` |
| shutdown grace | 10 s | `Shutdown.grace` |
| health trip | 2 consecutive failures spanning ≥ 1 s | `trip_after`, `trip_span` |
| health hold | 30 s initial, ×2 per failed probe, cap 300 s | `hold_initial`, `hold_max` |
| health probe timeout | 10 s | `probe_timeout` |
| HTTP keep-alive idle | 60 s | `keep_idle_ns` |
| HTTP sockets per endpoint | 32 | `max_parallel` |
| HTTP excerpt | 200 chars, whitespace runs collapsed, `" ..."` | `Http_client.excerpt` |
| IPC async send timeout | 2 s default | `Ipc.Make.send` |
| subscriber backlog | 256 events (oldest dropped) | `Ipc.Subs.max_queued` |
| change-notice flush / batch | 0.2 s / 512 keys | `Change_notice` |
| metrics window | 10 × 1 s buckets | `Metrics.window` |
| log ring | 50 warn/err | `Log.max_recent` |
| job report interval | 10 s; heap walk every 6th tick | `Job_report` |
| watch drain passes | 64 | `watch_stubs.c` |

---

## 3. Interface

### 3.1 Runtime capability interface (language-neutral)

Everything concurrent in tsync (this layer and every domain subsystem above it) uses only the
capabilities below. Any runtime — Rust async (tokio), a C event loop plus a blocking-I/O thread pool,
OCaml 5 effects (Eio/Picos) with or without domains, or today's Lwt — must provide them. Each module
takes only the groups it needs, so a module that only queues work is not handed a disk.

**R1. Tasks and results**
| capability | contract |
|---|---|
| `spawn_detached(task)` | start a task not awaited by anyone. It **must not fail**: an escaping error is fatal to the process (the task is responsible for catching). |
| `join_all(tasks)` / `map_concurrent(f, xs)` / `for_each_concurrent` | start all at once, wait for all; results keep input order. Width is chosen by the list — callers bound it with a pool (R4). |
| `try/catch`, `finally` | `finally` runs on success, failure and cancellation, then re-raises. |
| one-shot promise + resolver (`wait() -> (future, resolver)`, `resolve_later(resolver, v)`) | resolving never runs the waiter's continuation re-entrantly inside the resolver's caller; resolving twice is an error, so callers guard. Pools and stop-aware sleeps are built from this. |

**R2. Time**
| capability | contract |
|---|---|
| `now_monotonic()` | seconds, arbitrary origin, never steps; for durations and rates only. |
| `sleep(s)` | cancellable. |
| `with_timeout(s, f)` | fails with a *recognisable timeout error* (`is_timeout(e)`) if `f` hasn't finished; `f` is cancelled. |
| `with_stall_timeout(s, f(alive))` | fails like a timeout once `s` seconds pass without `alive()` being called; the watchdog wakes exactly at the deadline (no polling period). |
| `race(fs)` | first to finish wins; **the others are cancelled** (not left running). |
| `is_cancelled(e)` | distinguishes "the caller withdrew" from a failure of the work. |

**R3. Coordination**
| capability | contract |
|---|---|
| `mutex`, `with_lock(m, f)` | released however `f` ends; FIFO. `is_locked`, `has_waiters` for reporting only. |
| `condition`, `wait(c)`, `signal(c)`, `broadcast(c)` | carries no value; a woken waiter re-reads the state it waits on. Signal with no waiter is lost (callers re-check before waiting). |

**R4. Bounded concurrency (pool/semaphore)** — see §3.4 for the full contract. FIFO hand-off,
optional refusal when a waiting-queue cap is reached, named pools reported in status. This is the only
mechanism bounding width; a global scheduler bound is not a substitute (pools bound *working set*:
memory for bodies, round trips in flight, device queue depth).

**R5. File I/O** (EINTR transparently retried everywhere; see §4.2)
| capability | contract |
|---|---|
| POSIX-named calls | `exists, stat, lstat (64-bit sizes), readlink, symlink, rename, unlink, link (EEXIST = a claim), mkdir, rmdir, open, close, read, write, utimes, fsync, fstat, ftruncate, lseek` |
| positioned `pread/pwrite(fd, buf, file_offset, pos, len)` into **off-heap buffers** | offset travels with the call, so many ranges of one file move concurrently through one descriptor. May block the calling worker (today they do). |
| `reserve(fd, size)` | allocate blocks up front (Linux `fallocate`, macOS `F_PREALLOCATE`); "unsupported" is a distinct error the caller maps to `ftruncate`. |
| `read_file_opt`, `write_file`, `readdir_list` | whole-file helpers; readdir excludes `.`/`..`. |
| derived `Fs` operations | §3.3 — written once on top of the above. |

**R6. Sockets** (only for IPC and HTTP): line-oriented Unix-socket client/server (§3.8) and a pooled
HTTP/1.1 connection cache per endpoint with keep-alive, streaming response body and a "connection was
dead, request never left, redial" signal (§3.7).

**R7. Watch/readiness**: wait until an OS descriptor (inotify/kqueue fd) is readable (§4.14).

**R8. Process-wide stop** (§3.5 `Shutdown`): a flag + hooks, and a stop-aware sleep. Not a runtime
feature but every runtime binding must wire it so that cancellation of in-flight waits happens on stop.

### 3.2 Guarantees the domain logic relies on (and which of them come free from Lwt today)

The current runtime is **cooperative and single-threaded**: one OS thread runs all tasks; a task is only
suspended at an explicit await (a `bind` in the monad); blocking system calls either run in a helper
thread pool (Lwt_unix jobs) or block the one thread outright (positioned pread/pwrite, `reserve`,
`statvfs`, `clone`, sync `Ipc.send`, `Unix.lockf`, `mmap`). Consequences the code depends on:

**G1. Atomicity between awaits (free under Lwt).** Any sequence of statements with no await between
them is atomic with respect to every other task. The code relies on this to mutate shared tables
without locks. Examples:
* `Bounded.acquire/release`: check `held < limit` then increment; take waiter from queue then resolve.
* `Bounded.each`: `next ()` pops a job and advances the source between awaits so no two workers see the same job.
* `Ipc.Subs`: "nothing yields between the empty check and the wait" — a publish cannot slip between
  checking the queue empty and waiting on the condition (lost-wakeup freedom).
* `Durable_queue`: `take`, slot replacement (`cancel := true; pending := e`), `active`, `loaded`,
  `jobs` queue, `parked` counters, `put_back` (copy/clear/push/transfer).
* `Health`: read-modify-write of all fields (`check` hands the single probe to exactly one caller).
* `Http_client.call`: "replace the pool only if it is still the one that failed" (compare-and-swap by
  atomicity).
* `Change_notice`: `scheduled` flag + pending set; `Job_report`: `job` ref, `stop` flag.

**G2. Where a task may be suspended.** Only at awaits. The monadic type (`'a t`) marks every
suspension point in the source. Direct-style runtimes lose that visual marker: any call may yield.
Logic whose correctness depends on G1 must keep those critical sections free of calls that can yield
(or take a lock).

**G3. Ordering.** `mutex` is FIFO; pool slots are handed to waiters FIFO (no barging); a durable
queue's `recording` mutex makes record-id order equal queue order; `map_concurrent` preserves input
order in results; condition `broadcast` wakes all waiters.

**G4. Cancellation.** `race`/`with_timeout`/`with_stall_timeout` cancel the losing branch; the
cancellation is delivered as a distinguishable error at the branch's current await (so `finally`
handlers run — pool slots are released, file descriptors closed, watchers unregistered). Retry loops
never retry a cancellation. `Shutdown` is *not* cancellation: it is an explicit `Stopping` error raised
by stop-aware sleeps and checked flags; work already running is allowed to finish or give way at its
next stop-aware wait.

**G5. Blocking-I/O offload.** Directory/stat/open/rename/unlink/read/write through the runtime's
async file layer do not stall other tasks (Lwt: detached thread pool; the pool never shrinks once
grown — Android caps it at 16). Positioned off-heap pread/pwrite do stall the loop today (regular files
are "always ready"); a rewrite may offload them but then must keep G1 for the code around them.

**G6. Timers** fire on the loop; sleeps are cancellable and stop-aware sleeps resolve immediately on
stop.

**G7. Detached tasks** (`spawn_detached`) never propagate errors; each detached body in the code
catches everything (job report loop, change-notice flush, stall watchdog, `forget_pending`).

#### Shared mutable state that would need synchronisation under real parallelism

If a rewrite runs tasks on several threads/domains (OCaml 5 domains, a multi-threaded tokio runtime,
a C thread pool without a single event thread), every item below loses G1 and needs a lock, an atomic,
or confinement to one executor:

| state | module | today's reliance |
|---|---|---|
| pool `held`, `waiting`, waiter queue; `named` registry; `shared_pools` table | Bounded | check-then-act |
| job source cursor inside `each` | Bounded | pop+advance |
| queue `jobs`, `loaded`, `slots` (with `cancel`/`pending`/`failures`), `active`, `parked`, `outcomes`, `failures`, `degraded`, `running` | Durable_queue | lock-free mutation; `recording` mutex only orders writes |
| `owned` claims table; `registry`/`rescans` lists | Durable_queue (process-wide) | append without lock |
| Records `seq`, `dropped` | Durable_queue.Records | increments |
| every field of a `Health.t`; watcher table | Health | read-modify-write; single-probe handout |
| `hooks`, `requested_`, `next_hook` | Shutdown | idempotent flip + hook drain |
| counters' buckets/total/last_sec | Metrics (explicitly "unlocked: one thread") | increments |
| `Job_progress.state` (global) | Job_progress | increments |
| `job` ref, `ticks`, `live`, `stop`, `warned` | Job_report | flags |
| subscriber list, per-sub queues | Ipc.Subs | empty-check-then-wait |
| `woken` flag in `serve` | Ipc | guard against double resolve |
| `cache` field (pool generation) | Http_client | compare-and-replace |
| `table`, `pending`, `scheduled`, `warned` | Change_notice | set + scheduled flag |
| `recent_q`, `min_level`, `prefix`, `active` sink | Log | queue push/pop |
| `clonable` memo, `warned_no_clone` | Bigstring | memo |
| `seeded` PRNG state (pid-tagged) | Id | PRNG state is not thread-safe |
| `temp_seq` | Filename | increment (duplicate temp names under a race ⇒ two writers share a temp file) |
| blob/slots/count | Hashtbl_mmap | not thread-safe by design |
| TLS backend ref | Tls_conf (conduit global) | set once |
| `resolved_chunk_size` memo | Remote (domain layer) | set once |

Also: the `lockf` claim is per-process (POSIX record locks are owned by the process, not the thread),
so the in-process `owned` table is the only thing that stops two threads of one process double-claiming.

### 3.3 Fs.S (derived operations)

| op | contract |
|---|---|
| `mkdir_p` / `ensure_parent` | create missing parents 0755, EEXIST tolerated (races) |
| `atomic_write path data` | write to `temp_path path`, rename over; on failure unlink temp and re-raise |
| `atomic_write_at path ~size f` | temp file, `ftruncate` to `size` first (full disk fails early), `f put` writes positioned pieces (concurrent, out of order ok), rename after `f` returns; every byte must be covered exactly once |
| `reserve ~size fd` | `size=0` noop; platform reserve (Linux `fallocate(fd,0,0,size)`, macOS `F_PREALLOCATE` contig then any + `ftruncate`), fallback `ftruncate` on EOPNOTSUPP/ENOSYS |
| `pwrite_all fd buf ~offset` | loop; `n=0` → `Failure "short write at offset N"` |
| `copy_file ~src ~dst` | 1 MiB buffer loop, dst created/truncated 0644 |
| `read path buf ~offset` / `write` | open per call, lseek, loop until full or EOF; returns bytes moved; write opens `O_RDWR|O_CREAT` |
| `read_file_opt` | `None` on any failure |
| `readdir_list_quiet` | `[]` on `Unix_error` only |
| `is_directory`, `stat_opt`, `stat_opt_large` | any failure → false/None |
| `lstat_kind` | `` `Dir | `File size | `Symlink target | `Missing `` (any error → Missing) |
| `rm_rf` | lstat-based, never follows symlinks, ignores errors/ENOENT |
| `unlink_quiet` | ignores any `Unix_error` |
| `reap_older_than ~cutoff dir` | delete files with mtime < cutoff, prune empty dirs, true if empty after; missing dir = true |
| `zero buf ~pos ~len` | fill with `\0` |

Synchronous helpers (usable before any runtime is running): `mkdir_p_sync`, `open_and_unlink` (fd with no name), `pid_alive`
(`kill pid 0`; EPERM = alive; reused pid reads alive), `disk_space` (statvfs: `avail = f_bavail·f_frsize`,
`free = f_bfree·f_frsize`, `total = f_blocks·f_frsize`; `None` on failure), `load_average` (1-min, `None`
where unavailable, e.g. Android).

### 3.4 Bounded (pools)

```
create ?max_waiting ?name ~max ()      max<1 clamped to 1; name registers for totals (never pruned)
shared ~key ~name ~max ()              process-wide pool memoized by key
use t f                                 slot for duration of f; Busy if queue >= max_waiting
use_or t ~busy f
map_with / iter_with / filter_map_with  whole list, each element through the pool; order kept
each ~width next                        width workers pulling next() until None; first failure stops all, re-raised
in_flight / waiting / width / totals () -> (name, in_flight, waiting, width) list, same-name summed, creation order
```

A pool stands for a **resource** (memory for bodies, round trips in flight, device queue), not a piece
of work; the width belongs to whoever knows what shares the process.

### 3.5 Retry, Health, Shutdown

```
enum Kind { Transient, Permanent }
error Failed { kind, op, detail }        // rendered "op: detail (transient|permanent)"
error Cancelled                          // work no longer wanted: never retried
classify(e)          = Failed{k} -> k ; anything else -> Transient     // requests
classify_in_order(e) = Failed{k} -> k ; anything else -> Permanent     // ordered work
reason(e)            = Failed.detail, else the error's text
backoff(base, cap, n) = min(cap, base * 2^min(10, n-1))                // n is 1-based
held(name, op, health) = Failed{Transient, op = name+" "+op, detail = health.describe()}
with_retry(max_attempts = 8, health = ALWAYS_UP, classify, name, op, f) -> result   // §4.4
```

`Health` (one per peer/member; `ALWAYS_UP` is a shared untracked instance for local stores):
`check() -> Up|Probe|Held`, `is_held()`, `is_down()`, `sampled()`, `answered()`,
`lost(reason) -> Up|Tripped|Held`, `probe_lost(reason)`, `on_held(cb) -> id` / `off(id)` (one-shot
watcher), `describe()` (`"held down for 27s after 2 failures (HTTP 530: …)"` or `""`),
`timed_out()` / `timeouts()`, `json()` (`{"health":{heldUntil, heldUntilLocal "HH:MM:SS", heldSeconds,
failures, reason}}` only when out). Tunables: trip_after, trip_span, hold_initial, hold_max,
probe_timeout (§2.9). Test hooks: `expire()`, `hold_length()`.

`until_held(health, name, op, ask)` = `race[ask(), fail(held(...)) as soon as health trips]`
(cancelling `ask`).

`Shutdown` (process-global): error `Stopping`; `request()` idempotent, runs hooks once in registration
order; `requested()`; `on_request(f) -> unregister` (runs `f` immediately if already requested);
`grace` (10 s, settable); `reset()` (tests); `stop_aware_sleep(s) -> Slept|Stopping` resolves early on stop.

`Stopping` semantics everywhere: never retried, not counted as failure, **work is still owed** (on disk),
unlike `Retry.Cancelled` (work no longer wanted).

### 3.6 Durable_queue (seam used by 3 subsystems)

```
enum Poison { Stop /* leave record on disk */, Drop /* unlink record, mark degraded */ }
struct Stats { queued, in_flight, degraded: bool, bytes: i64 /* keyed weight still owed */ }
trait Job      { to_string(job) -> bytes ; of_string(bytes) -> Option<job> }   // None = unreadable
trait Files    { mkdir_p, atomic_write, readdir_list, readdir_list_quiet, unlink_quiet, is_directory,
                 read_file(path) -> Body(bytes) | Gone | Failed(err) }        // Gone vs Failed matters
Records(dir):  write(id, job) ; update(id, f) /* gone = no-op */ ; complete(id) /* unlink */ ;
               list(wanted: id -> bool) -> [(id, job)] in id order ; dropped() -> count
Queue:
  ordered(name, log, classify, poison, run(id, job))                      // 1 worker, strict order
  keyed(workers=1, weight=0, name, log, key(job), classify, poison,
        run(id, job, cancel_flag))                                        // ≤1 job per key
  post(job)            // write record, then enqueue; returns once durable
  record(job)          // write only (a queue another process runs)
  adopt(id, job)       // enqueue an existing record; idempotent on id
  start(recover=false) ; stop() ; cancel(key) -> bool ; set_paused(b) ; paused()
  stats() ; in_flight() -> [job] ; owed() -> distinct keys ; settle_key(key)
Process-wide: settle_all(timeout=60) ; register_settle(f) ; rescan_all() ; release(dir) ;
              set_stall_warning_interval(s)
```

Consumers: `Deferred` backend replication (`ordered`, poison `Drop`, dir per target+domain),
`Meta_queue` (`ordered`, `Stop`, metadata ops), `Sync_queue` (`keyed`, workers = `max_uploads`,
weight = record size, `Stop`, uploads).

### 3.7 HTTP client

```
trait SocketPool {                 // per-endpoint keep-alive connection cache
  create(keep_idle_ns, parallel) ; error Redial   // pooled connection unusable, request never left
  call(alive_cb, headers, body: off-heap bytes, method, uri) -> (response, body: off-heap bytes)
                                   // alive_cb invoked on headers and each body piece received
}
HttpClient:
  create(name, stall_timeout, classify, health)
  call(headers_thunk, method, body?, uri)           // one attempt (+ one redial)
  call_retry(headers_thunk, method, body?, op, uri) // 5xx/429 -> Failed Transient, retried; others returned
  call_text(...) -> (response, string)
helpers: code(resp), is_ok = 2xx, failed(op, code, body) Transient iff code>=500 || code=429, excerpt(body)
```

### 3.8 IPC wire protocol

* Transport: Unix stream socket; one request = one JSON object on one line (`\n`); one reply line.
  A connection carries many requests until the client closes it.
* Request fields: `action` (string, required), optional `ref` (Item_ref wire form), `domain`
  (absent ⇒ the daemon's only domain), `arg`, plus action-specific fields.
  Example: `{"action":"pin","ref":"f:9f3a1c0428b6d5e7/report.pdf","domain":"home"}`.
* Reply envelope: `{"ok":true, …}` or `{"ok":false,"error":"<message>"}`. `Ipc.request` raises
  `Failure msg` on `ok:false` or non-object.
* Subscription: a handler returning `` `Subscribe topic `` sends its reply, then the connection becomes
  an event stream (no more replies interleave). Topic = domain name; `""` subscribes to all.
  `publish` returns the number of subscribers (0 = nobody listening). Per-subscriber backlog 256;
  overflow drops the oldest with an error log. Stream ends on client EOF or failed write.
* `serve ?subs ?until ~path handler`: mkdir parent 0700, unlink stale socket, one task per connection;
  handler `` `Stop `` or `until` resolving → shutdown listener, unlink socket, return (idempotent wake).
  Per-connection exceptions are swallowed (connection closed).
* `send` (sync, blocking, no timeout) for CLI; `Make.send ?timeout=2.` for in-loop callers.
* Socket paths (`Runtime`): Linux `$XDG_DATA_HOME/tsync/tsync-<domain>.sock` (one daemon process per
  domain), proxy `tsync-http-proxy.sock`, sync `tsync-sync.sock`; macOS one daemon for all domains at
  `~/Library/Group Containers/group.org.feverdreamtv.tsync/tsync/tsync.sock`.
* Change notice (`lib/lwt/core/change_notice.ml`): line `{"action":"changed","domain":d,"keys":[…]}`
  sent via async send to each configured frontend socket; keys deduplicated, flushed every 0.2 s in
  batches ≤ 512; `settle ()` flushes now (before a command exits); failures warned once, never raised.
* Job report line: `{"action":"report","kind","domain","pid","startedAt","uptimeSeconds","intervalSeconds",
  "state":"running|done|failed","memory":{rssBytes,privateBytes,swappedBytes,virtBytes,systemUsedBytes,
  systemTotalBytes},"gc":{heapBytes,topHeapBytes,minorCollections,majorCollections[,liveBytes]},
  "traffic":{bytesUploaded,bytesDownloaded,uploadBytesPerSec,downloadBytesPerSec,chunksHashed,hashesPerSec},
  "backend":{requests,retries,timeouts,failures},"pools":[{name,inFlight,waiting,max}],"uplinks":{…},
  "counters":[[k,v],…][,"error"][,"target"][,"current"][,"progress":{…}][,"backends":[…]]}`.
  `progress` = `{bytesTotal,bytesDone,bytesSkipped,bytesFailed,bytesHandled,bytesRemaining,bytesSent
  [,bytesPerSecAvg][,etaSeconds][,current:{bytesDone,bytesTotal}]}`.

### 3.9 Smaller interfaces

* **Spool**: `create ~dir ~name` (temp file `dir/.tsync-tmp-<pid>-<n>.tmp` — note `name` only shapes the
  temp path's directory, see §9), `append`, `seal` (close THEN mmap whole file; fails "spool … vanished"
  if gone), `close`, `drop` (close quietly + unlink), `reap ~dir` (unlink temp names whose pid is dead, one level).
* **Listing**: `create ~dir ~name ~decode`, `add t fields` (raises `Invalid_argument` once sealed),
  `count`, `iter` (seals on first call, re-walkable), `read`/`next` (pull cursor), `drop`, `reap`.
* **Bigstring**: Bigstringaf + `of_string`, `open_snapshot ?scratch path` (reflink clone, unlinked,
  read-only; falls back to the file itself with one warning per process, memo per directory),
  `map_file ?scratch ~path ~offset ~len ()` (MAP_PRIVATE of a snapshot; read-only fd so a short file
  errors instead of growing), `map_fd`.
* **Hashtbl_mmap** (parameterised by key and value byte encodings): `create n, replace, find, find_opt, mem, length, iter, fold`.
* **Glob**: `of_pattern`, `matches` (`*` no `/`, `?` one non-`/`, `**/` zero or more segments, `**` anything, rest literal).
* **Metrics**: counters (`counter/count/total/rate`), process traffic, hashed, request/retry/timeout/failure
  tallies, `cpu_seconds`, `mem_stats`, `gc_stats`, `live_bytes` (heap walk), `human_bytes`
  (`"%d B"` or `"%.1f KB|MB|GB|TB"`, base 1024), `with_rate`.
* **Job_progress** (process-global): `plan ~basis ~bytes`, `start_entry ~size`, `advance ~bytes ~sent`,
  `settle ~bytes ~sent outcome`, `finish_entry`, `json`.
* **Log**: levels debug<info<warn<err, default min `info`; `set_prefix`; `set_sink`; `recent ()` (last 50
  warn/err, newest first); `Daemon.init` (min level debug; syslog facility DAEMON ident `tsync` with
  LOG_PID, and LOG_PERROR only when stderr is a tty; else stderr sink
  `YYYY-MM-DD HH:MM:SS LEVEL msg`, colored on a tty).
* **Field_spec**: `{name; label; typ : String|Bool|Int; default : string option (None=required,
  Some ""=optional omitted); secret}`; `bool ~default` accepts true/1/yes/on, false/0/no/off
  (case-insensitive), else default; `mask` → `"***"` for set secrets.
* **Device**: `max_concurrency path : int option`, `clone ?scratch ~src () : fd option`.
  `Descriptors.current`, `raise_to ~target`. `Watch.open_dir/fd/drain/close`.
* **Runtime**: `default_paths () = {cache_root; data_dir; config_path}`, socket paths,
  `restart_service`, `log_command`.
* **Tls_conf**: `available ()` (preferred first: openssl, native), `current ()`, `apply (string option)`.
* **Desktop_mounts** (Linux): `mount_points () : (mount, socket) list` — total (C caller).

---

## 4. Behaviour / algorithms

### 4.1 Layering rule (neutral)

1. Every piece of concurrent logic is written against the capability groups of §3.1 it actually uses,
   plus narrow, module-specific capability interfaces for anything the *process* owns (e.g. a queue's
   file operations, a listing's spool, the HTTP socket pool, the IPC transport, a report sender, a link
   governor's JSON). Classification rule: a loop, recursion or sequence of calls is logic; a single call
   the platform or the process makes is a capability.
2. Pure vocabulary (names, formats, classification, backoff formula, disk-space query) never depends
   on the runtime, so consumers needing only names don't link one.
3. One **composition root** per process binds each capability once. Anything that is a registry
   (named pools, queue settle/rescan lists, backend drivers, change-notice table, shutdown hooks) is
   therefore a process-wide singleton; binding twice would split it.
4. Raw OS descriptors cross into logic only through the file-I/O capability; C/FFI conversions stay
   inside the binding.

A rewrite may use generics over small traits (Rust), a vtable struct (C), or plain direct-style calls
into one runtime (OCaml 5 effects) — what matters is the narrow surface, the single composition root,
and preserving (or explicitly replacing with locks) the guarantees G1–G7 of §3.2.

### 4.2 EINTR discipline

The daemon receives SIGCHLD (it shells out to `df`/`diskutil`, forks frontends) and SIGWINCH, and signal
handlers are installed without SA_RESTART, so **every** blocking syscall may fail with EINTR. Rule:
every file/dir syscall — synchronous or async, in any helper — retries on EINTR, and an EINTR must
never be interpreted as an answer. In particular "does this path exist" must be `stat` succeeds →
true, stat fails with a real errno → false, EINTR → retry. (A naive exists-check that said "no" on
EINTR nearly re-minted the client uuid over the live one, abandoning every unfinished WAL record —
commit 37c0d67d.) OCaml-specific mechanics of this are in the [OCaml notes](ocaml/01-core.md).

### 4.3 Bounded pool algorithm

`acquire`: if `held < limit` take a slot; else if `max_waiting` reached answer false (→ `Busy`);
else enqueue a resolver and wait. `release`: if a waiter exists, **hand the slot directly** to it
(`held` unchanged, FIFO, no barging); else `held--`. `use` = acquire; `finalize f release`.
`map_with` = `map_p` of `use` per element (queue unbounded because elements are already in memory).
`each ~width next`: `max 1 width` workers; each loops `next ()`; on a job exception records the first
exception into `stop`, all workers stop taking jobs; after join re-raise it.

### 4.4 Retry ladder (`Retry.Make.with_retry`)

```
go attempt:
  try r = f(); Health.answered h; return r
  with Cancelled | Shutdown.Stopping -> reraise
     | e when Clock.is_cancelled e -> reraise
     | e when classify e = Transient ->
         if Health.lost h (reason e) = `Tripped then warn (describe h)
         if attempt < max_attempts:
            delay = min(20, 0.5 * 2^min(10, attempt-1)) * (0.5 + U[0,1))
            Metrics.retries++; if timeout: Metrics.timeouts++, Health.timed_out h
            log (info if attempt<3 else warn) "name op: reason; retrying (a/max) in Ds"
            Shutdown.Sleep delay -> `Stopping => fail Stopping
            go (attempt+1)
         else out_of_tries
     | e (permanent) -> Health.answered h (an answer about an object proves the link); out_of_tries
out_of_tries e: Metrics.failures++; if Transient: (timeout→count+Health.timed_out);
   fail (e if Failed else Failed{Transient; op = name^" "^op; detail = reason e}); else fail e
```

The loop never refuses because a member is held; whoever has an alternative uses `Health.check`/
`Health_wait` to stop waiting.

### 4.5 Health breaker state machine (`lib/core/health.ml`)

State: `consecutive`, `failing_since`, `last_lost`, `held_until` (0 = not out), `hold`, `probing`.
Time is wall clock (`gettimeofday`).

* `lost` (tracked only): if `consecutive=0` or (not out and `now - last_lost > hold_initial`), start a
  new run (`consecutive=0; failing_since=now`). `consecutive++`, `last_lost=now`.
  * If out: if `probing` or `now >= held_until` (the probe failed, or the hold had lapsed with nobody
    probing) → `hold = min(hold_max, 2·hold)`, `held_until = now+hold`, notify watchers, `` `Tripped ``;
    else `` `Held `` (request already in flight when it went out; not news, no extension).
  * If not out: if `consecutive >= 2` and `now - failing_since >= 1 s` → hold 30 s, notify, `` `Tripped ``;
    else `` `Up `` (a burst in one instant is one bad moment).
* `check`: not out → `` `Up ``; `now < held_until` → `` `Held ``; else extend `held_until = now+hold`,
  `probing=true`, `` `Probe `` (exactly one caller per expiry gets the probe; an unreported probe is
  re-offered at the next expiry).
* `is_held` = out and `now < held_until` (false once a probe is due). `is_down` = out, even if expired
  (a lapsed hold is not an answer).
* `answered`: reset everything (consecutive 0, not out, hold 30 s, sampled).
* `probe_lost`: a deliberate probe that failed puts it out on that alone (`2·hold` if already out, else 30 s).
* Watchers (`on_held`) are one-shot: called and cleared on each trip.

### 4.6 Durable queue algorithms

**Posting.** `post`: if `full` (queue length ≥ 100 000) → set degraded, log once, silently drop.
Else under the `recording` mutex: mint id, `atomic_write` the record, then `take`. The mutex keeps
id order = queue order (a rename replayed backwards loses a file). Returns when durable.
`record` writes only (another process's queue). `adopt` takes an existing record under the same mutex,
ignoring ids already `loaded`.

**take (keyed).** If the key has no slot: create one and enqueue. If a slot exists (running or queued):
set its `cancel := true`, drop any previous `pending` (its record is completed asynchronously — its data
is no longer staged), set `pending := this`. So at most one job per key runs, the newest wins, and
the run function polls `cancel` to stop early.

**Worker loop.**
```
loop:
  if Shutdown.requested: return
  if (queue empty or paused) and not stopping: parked++; announce; wait wake; parked--; loop
  if queue empty: return                      (stopping and drained)
  e = pop; (keyed) active[key] = e
  outcome = run e (catch all)
  (keyed) remove active[key]; outcomes++
  Done           -> clear failures (slot and queue); Records.complete id; requeue=false
  Failed Stopping-> requeue=false (record stays on disk; owed)
  Failed e, classify e = Transient ->
                    Metrics.retries++ (timeouts too); n = ++failures (slot or queue);
                    delay = min(300, 0.5·2^min(10,n-1)); warn; announce; Shutdown.Sleep delay; requeue=true
  Failed e (permanent) -> Metrics.failures++; degraded=true;
                    Drop: log err "(dropped; run tsync mirror)", complete record
                    Stop: log err "(not retrying)", leave record, remove from loaded (so adopt can re-offer)
  if slot.pending exists: clear cancel, enqueue pending        (replacement takes the key)
  elif requeue and not stopping: put_back                      (ordered: at HEAD; keyed: at tail)
  elif keyed: remove slot
  announce; loop
```
Ordered queues retry at the head so later records can't overtake (commit 5dcca235: an rmdir overtaken
by a later mkdir conflicted). Keyed queues retry at the tail so one failing key doesn't stall others.

**Start / recovery / claims.** `start ?recover`: without `recover`, the process **claims** the log dir
(`lockf` on `<dir>.owner`, kept open; if another holds it, proceed anyway without claim — both keep
their own records in memory). With `recover`, register a rescan and have each worker first `rescan`:
`with_claim dir` (only if no process holds the lock and this process doesn't own it) → `resume`: under
the recording mutex, `Records.list ~wanted:(not loaded)`, set degraded if any unreadable record was
dropped, create slots and enqueue in recorded order. `rescan_all` re-reads every recovering queue's log
(daemon calls it when a one-shot command leaves work behind). A watchdog logs a warning every
`stall_warning_interval` if jobs are queued and `outcomes` didn't move.

**Records.list** reads each wanted id: `` `Gone `` (completed meanwhile) → skip silently;
unparseable body → `dropped++`, err log, unlink; `` `Failed exn `` (EMFILE, EIO…) → warn and **leave**.

**Stop / settle.** `stop`: set stopping, broadcast, join workers — a command's queue drains what it
holds; if `Shutdown.requested`, workers return immediately leaving the rest on disk. `settle t` waits on
the `settled` condition until idle, not running, shutdown, or `failures > 0` (target down: warn and
return — queued work is on disk). `settle_key` likewise per key. `settle_all ?timeout` joins all settles
under `with_timeout` (60 s, or `min(timeout, grace)` when stopping), warning on timeout. On
`Shutdown.request` every queue broadcasts its conditions. `stats.degraded = degraded || dropped > 0`;
`stats.bytes` = sum of `weight` over queued+active (keyed).

### 4.7 Shutdown

`request()` flips the flag and runs hooks (sorted by registration id) once. Stop-aware sleeps resolve
`` `Stopping `` immediately; retry ladders fail with `Stopping`; queues stop taking jobs; settle waits are
capped to `grace` (10 s). Everything a stop leaves is on disk (upload records, queued jobs, staged
bodies) and resumes at the next start.

### 4.8 HTTP client call

`call`: `Metrics.requests++`; under `with_stall_timeout timeout` (timer reset by `alive()` after headers
are built and on each response body piece; the request body upload is not "heard"), build headers (may
hit the network, e.g. token mint) then `Pool.call`. If `Pool.Redial` (connection unusable, request never
left), replace the pool **once per generation** (only if `t.cache` is still the one that failed) and try
once more. `call_retry` wraps in `with_retry ~health ~classify`, converting 5xx/429 into
`Failed Transient "HTTP <code>: <excerpt>"`; all other statuses (404 included) return to the caller.
Bodies are bigstrings end to end (`Passthrough`, no copy).

### 4.9 Glob

Recursive backtracking: `**` followed by `/` skips the `**/` and tries the rest at every position from
the current index (so `**/x` matches `x`, `a/x`, `a/b/x`); `**` otherwise tries every position; `*`
tries positions not crossing `/`; `?` one non-`/`; others literal. Used by import excludes (applied to
basenames and paths).

### 4.10 Metrics counter

Ring of 10 one-second buckets indexed `sec mod 10`; on each add/read, zero buckets for elapsed seconds
(at most 10); `rate = sum/10`. Unlocked (single thread). Retries/timeouts/failures counted where they
happen (both the request ladder and the queue).

### 4.11 Job progress estimate

`handled = done + current.done + skipped + failed`; `remaining = max 0 (total - handled)`.
Basis `` `Sent ``: rate = `sent / (now - first_sent_time)` (bytes that reached a store, timed from the
first), published as `bytesPerSecAvg`. Basis `` `Handled ``: rate = `handled / (now - planned_at)`, not
published. `etaSeconds = remaining/rate` only if rate > 0 and remaining > 0. Absent figures are absent
keys. `finish_entry `Skipped/`Failed` charges the entry's planned size.

### 4.12 Snapshots and clones

`Bigstring.open_snapshot`: `Device.clone` stages a clone at `temp_in scratch` or `temp_path src`, opens it
read-only and unlinks it (Linux: `FICLONE` ioctl from a fresh `O_EXCL` 0600 file, unlink on failure;
macOS: `clonefile`). A directory that failed once is remembered (`clonable[dir]=false`) and the file
itself is used thereafter (warn once per process: a truncating writer then means SIGBUS under a
mapping). Mapping is `MAP_PRIVATE` read-only so a short file errors instead of being extended.

### 4.13 Device queue depth

Linux: longest mount point in `/proc/self/mountinfo` covering the path → `major:minor` →
`/sys/dev/block/<mm>` (go to `..` if `partition` exists) → `device/queue_depth` else `queue/nr_requests`
→ `max 2 (min 64 (depth*4))`. macOS: `df -P` → device → `diskutil info`: rotational+USB/FireWire 4,
rotational 8, SSD over USB 16, SSD 64, unknown external 8, else None. Ask once per store.

### 4.14 Directory watch

Linux inotify `IN_CREATE|IN_MOVED_TO|IN_CLOSE_WRITE` non-blocking; macOS kqueue EVFILT_VNODE
`NOTE_WRITE|NOTE_LINK|NOTE_DELETE|NOTE_RENAME` with EV_CLEAR on an O_EVTONLY dir fd. `drain` reads up to
64 passes; returns true if any event is not one of our temp names (Linux) / any event at all (macOS).
`Watch_lwt.wait` waits readable then drains, re-waiting if only own scratch arrived (prevents a
read→snapshot→wake→read OOM loop). Non-recursive; `None` means fall back to polling.

### 4.15 Descriptor limit

`raise_to ~target`: clamp to `rlim_max` if finite; if current ≥ want return current; else try `setrlimit`
halving `want` until accepted or ≤ current. (launchd gives 256.)

---

## 5. Interactions

* **Depends on**: OS only (POSIX, inotify/kqueue, FICLONE/clonefile, statvfs, getrlimit), yojson,
  bigstringaf, cohttp types (only in `Http_client_intf`), mem_usage, syslog (optional), Lwt/cohttp-lwt/
  conduit in the binding layer; `Desktop_mounts` depends on `Conf_parsing` (config) and `Runtime`.
* **Depended on by** (everything):
  * Config (`Conf.S`) satisfies `Logical_key.Domain` and `Chunk_layout.Store`.
  * Backends: `Stored_key`, `Chunk_layout`, `Chunks.key_of_body` (verify on read in local driver, GC,
    integrity), `Http_client` (S3/GCS/http-proxy drivers), `Retry`, `Health`/`Health_wait` (domain store
    failover), `Durable_queue` (deferred replication), `Device.max_concurrency` (local driver pool width),
    `Watch` (local driver change detection), `Bounded`.
  * Remote/chunk store: chunk sizing, `Chunk_source`, `Bounded` pools for chunk buffers, `Metrics.add_*`.
  * Manifest / checkout / cache layout: XXH3 digests, `Chunks.pieces`, `Bigstring`, `Fs.atomic_write_at`,
    `Filename` temps, `Spool`.
  * Sync: `Durable_queue` (`Sync_queue` keyed uploads, `Meta_queue` ordered metadata), `Change_notice`.
  * Ops: `Listing`, `Spool`, `Hashtbl_mmap` (mirror's held set), `Job_progress`/`Job_report`,
    `Zip_stream` (export/share server), `Glob` (import excludes).
  * App/frontends: `Ipc` (every daemon/CLI conversation), `Item_ref` (frontend ↔ daemon), `Runtime`
    paths, `Log`, `Shutdown`, `Tls_conf`, `Descriptors`, `Desktop_mounts` (Linux file-manager
    extensions via C), `Metrics_lwt`, `Uplink_lwt` (governor; separate `tsync_uplink` library).

### 5.1 Hosts: how this layer is repurposed

The same foundation is linked into several hosts; each instantiates the runtime once and picks roles:

| host | what it uses / swaps |
|---|---|
| Linux daemon (`tsync start`) | one process per domain (FUSE frontend) + a sync process; log → syslog (`Log.Daemon.init`, ident `tsync`, facility DAEMON, level debug), log prefix `"[<domain>] "`; raises fd limit to 8192 before forking frontends; per-domain IPC socket `tsync-<domain>.sock`; `Shutdown.request` on unmount/signal; recovering durable queues; `rescan_all` when a one-shot command leaves work behind. |
| macOS daemon + File Provider app | one daemon serving all domains on one socket `tsync.sock` in the app-group container; logs to syslog with LOG_PERROR into `~/Library/Logs/tsync-daemon.log`; fd limit raised (launchd gives 256); File Provider extension talks via IPC and subscribes to change events (daemon never connects out). |
| Android app | runtime embedded in the app process; log sink replaced by logcat (`Log.set_sink`) before anything else; blocking-I/O pool capped at 16 threads; everything reachable from the host must be total (no escaping errors); no daemon socket—requests are answered in-process. |
| http-proxy frontend | one listener for all its domains (`tsync-http-proxy.sock` for control); no IPC socket for status, so it reports `Log.recent()` (last 50 warn/err) over HTTP; uses `Zip_stream` for folder downloads in the share server. |
| One-shot CLI commands (import, export, mirror, gc, rsync…) | synchronous `Ipc.send`/`request` to talk to daemons; durable queues started **without** recover (they claim their log dirs for their lifetime); `Job_report` every 10 s to the daemon so `tsync status` sees them; `settle_all` (≤60 s) before exit; `Change_notice.settle` before exit; log sink wrapped to coexist with a live progress block. |
| Linux desktop file-manager extensions | call `Desktop_mounts.mount_points` across a C boundary (must be total) to learn which mounts are tsync's and their sockets. |
| Tests | replace Clock/Files/Send/Pool/Transport capabilities with doubles; `Shutdown.reset`, `set_stall_warning_interval`, `Health.expire`. |

### 5.2 Main data flows through this layer

1. *Upload*: file bytes → fixed-size cut (`Chunks`) → `Chunk_source` → hashed in place (`key_of_body`)
   → `Chunk_layout.Make.key` → HTTP client/driver under `Bounded` chunk-buffer pool and `Retry` ladder.
   A write is first recorded (`Durable_queue.post`) so a crash leaves it owed.
2. *Read*: range → `Chunks.pieces` → chunk keys → cache (`relative_path`) or backend; verified by
   recomputing `key_of_body`; mismatches filed as `marker_key`.
3. *Frontend request*: `Item_ref` over `Ipc` → daemon resolves via folder ids (`Stored_key`, `Folder`).

---

## 6. Concurrency, durability & failure semantics

* **Atomic file replacement** everywhere via temp name in the same directory + rename; failures unlink
  the temp. Readers never see partial bodies. Temp names carry the pid, so sweepers (`Spool.reap`,
  cache sweeps) remove only dead processes' leftovers.
* **Durable queue**: record is on disk (atomic write; no fsync) before `post` returns; completion =
  unlink. Crash ⇒ records replayed next start (or by `rescan_all`). Replays are idempotent at the
  queue level (`loaded` set; `adopt` idempotent on id) — jobs themselves must tolerate re-run
  (at-least-once). Unreadable records are dropped and the queue flagged degraded (needs `tsync mirror`).
  Claim via `lockf` prevents a recovering process from running records a live command holds in memory.
  Note: no `fsync` of record or directory — durability is against process crash, not power loss.
* **Unlinked-while-open files**: `Hashtbl_mmap` backing, spool→mapping (spool is unlinked only on
  drop/reap), clones (`open_and_unlink`) — nothing to clean up after a kill.
* **Pools**: FIFO hand-off, optional refusal (`Busy`). Named pools are reported in status (`pools`).
  HTTP sockets per endpoint 32 (not the work bound). IPC one task per connection (unbounded).
  Durable queue: 1 worker (ordered) or N (keyed).
* **Shutdown**: cooperative, bounded by 10 s grace; nothing that is owed is lost.
* **Offline**: `Health` takes a member out after 2 failures ≥ 1 s apart and holds 30→300 s; queues
  back off up to 300 s per failure without dropping transient work; `settle` returns early when a
  target is failing so commands don't hang.
* **Advisory channels** (job reports, change notices, subscription events) never fail the caller;
  failures are logged once.
* **Signals**: EINTR retried everywhere (§4.2).
* **Timeouts**: HTTP is a stall timeout (silence), not a latency budget; IPC async send 2 s.

---

## 7. Design choices & rationale

| choice | why (source) | rejected alternative |
|---|---|---|
| Fixed-size chunks, per-file size in manifest | clients agree without talking; ranges map arithmetically; size changeable for new files only | content-defined chunking (not used; no rationale recorded beyond simplicity) |
| XXH3-64 × two seeds, hex, joined by `-` | fast, fixed width, filesystem safe; 128 bits of name; a Python verifier reimplements it | cryptographic hash (not needed: stores are the user's own) |
| Children filed by `hash(leaf)` under a stable folder id | folder rename touches one marker, not the subtree (`stored_key.mli`) | path-keyed manifests |
| Kind not encoded in the key string | a second spelling can disagree (`logical_key.ml`) | trailing `/` for dirs |
| Item_ref ids, not paths | a directory rename changes every descendant path; refs reach system logs, so no user paths unless the caller named one | paths on the wire |
| Stored_key has no `of_string` | a key exists only because a namer built it or a store listed it | free strings |
| Marker membership by prefix, last `/chunks/` | manifest keys look like chunk keys; domain may be named `chunks` | leaf-shape test |
| Temp prefix test not suffix | Syncthing `.tmp` files were deleted and re-downloaded forever (`filename.ml`) | `*.tmp` |
| Durable record before acknowledging a write | crash leaves "owed" evidence | in-memory queue |
| Ordered queue retries at head; keyed at tail | ordering vs. isolation (commit 5dcca235) | uniform requeue |
| `lockf` claim beside the dir | kernel releases on death; directory holds only records | marker files |
| Poison `Stop` vs `Drop` | Drop for rebuildable targets (deferred replica, fixed by mirror); Stop for work others reconcile | single policy |
| `classify` supplied by the job owner | only the owner knows which of its failures clear | queue-side heuristics |
| Unknown exception = Transient (requests) but Permanent in ordered work (`classify_in_order`) | requests: don't abandon work; ordered: a local bug would block everything behind it | — |
| Jittered backoff ×[0.5,1.5) | a fleet failing together doesn't return together | fixed delays |
| Health breaker with single probe | 8 retries against a dead host wastes a minute of reader time | per-request retries only |
| Stall timeout instead of deadline | large bodies on slow links are legitimate; dead pooled connections (no FIN) hang forever | total deadline |
| Pool replaced once per generation on Redial | a torn-down connection stays in cohttp's table as failed | per-request new connection |
| Pooled HTTP per endpoint | per-request connections cap catch-up at dozens req/s and exhaust TIME_WAIT | — |
| Bigstrings for bodies; Hashtbl_mmap; Listing spools | data-sized structures off the GC heap (mirror memory: 140 → 16 words/object) | heap strings/Hashtbl |
| Spool sealed (closed) before mmap | mapping a file still open for append is unsound | map while writing |
| Reflink snapshots for mapping sources | a concurrent truncate under a mapping is SIGBUS, not a short read | read the live file |
| Private PRNG reseeded per pid | a fork inherits PRNG state and drew its parent's ids (a42c99e5); a shared global PRNG's seeding depends on who seeded it first | global PRNG |
| EINTR retried inside every file helper | the failure is invisible to callers; nearly re-minted client uuid (37c0d67d) | caller discipline |
| Runtime interface minimal (§3.1), sequencing helpers derived | every extra capability must be re-provided by every runtime binding | expose the whole runtime API |
| One composition root names the runtime | swap cost confined to one tree (~1000 lines today); an effects-based scheduler migration was costed against it | runtime calls everywhere |
| IPC: daemon never connects out; subscribers connect in | sandboxed extensions can always reach the daemon | daemon pushes to clients |
| Never set TCP_NODELAY on Unix sockets | macOS answers EINVAL once the peer is gone; the accept loop died and the daemon answered nobody | runtime default |
| Subscriber backlog 256, drop oldest | events are hints atop the journal (ponytail note) | unbounded buffers |
| Change notices batched 0.2 s/512 | a 100k-entry catch-up would be 100k round trips | per-key sends |
| Monotonic clock for rates | NTP steps wall time by the intervals rates are read over | wall clock |
| Device concurrency discovered | USB BOT takes 1 command, NVMe hundreds | fixed width |

---

## 8. Invariants the tests pin down

Unit tests (`tests/unit/*`, snapshot `.expected` files are authoritative):

* **hash**: XXH3-64 KAT values above for seeds 0/1 at sizes 0,1,16,17,128,129,240,241,2600,1 MiB,1 MiB+1,8 MiB;
  `hash_hex "" 0 = "2d06800538d394c2"`; chunk key = two digests joined by `-` (shared with Python verifier).
* **chunk_pieces**: exact piece lists (§2.2), always covering the range once; nothing for length 0 or chunk 0.
* **stored_key**: root/trash ids; `img.jpg` → `066843ea47b80079-e0e3d2bb9b72c14d`; same name same key;
  index key `.tsync-index`; listing classification (child / index / namespace / in-flight write).
* **logical_key**: spelling, `path`, `parent`, descending, file-descend refused, `rel_of_string` rejects
  other domains, file≠folder of same path, leading `/` ignored.
* **item_ref**: 16 cases (§2.4) including `d:.tsync-root`→root, colon in names, storage keys → Bad.
* **gc_job**: gc-jobs prefix/key shapes for domains incl. `Jellyfin Media`, `chunks`, `gc-jobs`; non-job keys rejected.
* **temp_names**: ours vs user's names (`.syncthing.*.tmp`, `my.tsync-tmp-1-2.tmp` etc. are user's).
* **id**: forked children draw distinct ids of the same shape.
* **eintr**: both EINTR spellings retried; other errors propagate; shadowed `Sys.file_exists` agrees with stdlib on missing/file/dir/dangling symlink.
* **bounded**: never wider than bound and reaches it; order preserved; bound 0 serialises; `max_waiting`
  refuses rather than queues; slots all return; `each` width, draining, first failure re-raised and stops workers.
* **hashtbl_mmap**: find/mem/length; replace overwrites without growing count; arbitrary byte keys;
  growth past hint; iter/fold each binding once; heap cost a fraction of stdlib Hashtbl.
* **listing**: count before walk; arbitrary field bytes round-trip; re-walkable; add after seal raises and isn't counted.
* **spool_reap**: dead run's spool reaped; user file and live spool kept.
* **bigstring**: mapping survives unlink/republish; short file raises and isn't grown; writes to map don't reach file;
  no clone left behind; snapshot isolation exactly where the FS can clone; bigstring hash = string hash.
* **health**: the full state machine (§4.5): blip, trip on 2nd, reset by answer, single probe among 3,
  probe failure doubles to a cap, in-flight failure no extension, same-instant burst not a trip,
  watchers once, expired hold still `is_down`, isolated old failure not a run, `always_up` never out, timeout tally persists.
* **shutdown**: sleep returns `Stopping` without the clock moving; unregistered hook never runs; late hook runs at once;
  retry ladder gives up on stop with one try and no failure counted.
* **queue_stop / drain_for_stop**: command stop runs all 6 jobs, none owed; process stop returns at once
  having started only the running job, 6 still on disk; drain bounded by grace without cancelling.
* **queue_claim**: claimed log left alone; unclaimed log taken over; no double run while being worked.
* **work/queue_order**: ordered queue keeps record order through transient failure (retry at head), permanent
  failure reported degraded with record kept (Stop) and re-offerable.
* **work/queue_adopt**: adopt idempotent; log holds exactly what was written.
* **work/queue_records**: `wanted` prevents opening; unparseable record dropped with err log; gone record silent;
  unreadable-for-other-reason record left with warn (exact log lines in `.expected`).
* **work/queue_degraded**: dropped unreadable record counted, other jobs run, `degraded=true`.
* **work/queue_stall**: draining queue silent; a stuck queue warns yet still reports jobs as queued.
* **subs / ipc_serve**: multi-request connections, subscribe ack, topic filtering, in-order delivery,
  departed subscriber removed, publish-to-nobody = 0; server stops via handler/until, socket removed, nothing escapes.
* **zip**: exact 1144-byte archive for a fixed member set (dir, text, 300-byte binary, empty, UTF-8 name) and round-trip by an unzipper.
* **http_excerpt**: whitespace flattening and 200-char cut examples.
* **field_spec**: boolean parsing table.
* **metrics**: totals; 10 s window rate = total/10.
* **progress_eta**: no estimate with nothing done; `Handled` basis estimates without publishing a rate; remaining/rate.
* **reserve**: file sized; blocks owned where supported; size 0 is a no-op.
* **glob** (`tests/unit/glob/glob.ml`): the literal/`*`/`?`/`**` cases listed there.
* **desktop_mounts**: mountinfo parsing incl. octal escapes and `fuse.*` type with source `tsync`.

---

## 9. Open questions / inconsistencies

1. **Glob `**/x` over-matches**: `try_from` tries every character offset, not only segment boundaries,
   so `**/.git` also matches `foo.git`, and `src/**/*.ml` matches `src/xfoo.ml`-like shapes. Tests do not
   cover it. A rewrite should decide (segment-boundary semantics is almost certainly intended).
2. **Clock inconsistency**: `Clock.now` is monotonic, but `with_stall_timeout` (Lwt binding), `Health`,
   `Metrics` buckets, `Job_progress` all use `Unix.gettimeofday` (wall clock), which the Clock doc says steps under NTP.
3. **Durable queue has no fsync** (records nor directory): durable across process crash only.
4. `Durable_queue.record` bypasses the `max_queued` check; `full` counts only in-memory queue length,
   not the keyed `pending` slots.
5. Record `seq` is per `Records.t` instance: two `Records.t` on the same dir in one process could mint
   the same id within one microsecond.
6. `Spool.create ~dir ~name`: the path is `temp_path (dir/name)` = `dir/.tsync-tmp-<pid>-<n>.tmp`;
   `name` does not appear in the file name at all (doc says it "makes the path readable").
7. `Spool.seal` uses `stat_opt` (non-LargeFile `st_size`, an OCaml int — fine on 64-bit only).
8. `Hashtbl_mmap.replace` appends forever; heavy rebinding grows the blob unboundedly (no compaction).
   Its hash is OCaml's `Hashtbl.hash` — irrelevant for persistence (in-process only).
9. `Stored_key.escape` uses a single 64-bit hash (collision ⇒ two names share a mirror handle; real name
   recovered from body/marker, but two distinct long names would collide on one path).
10. `Watch.drain` on macOS cannot see names, so the own-scratch wake loop is only fixed on Linux (memory
    note "watch-reports-own-scratch-loop": macOS still open).
11. Domain names `corrupted`, `verify-jobs`, `gc-jobs` collide with sibling roots (acknowledged, unchecked).
12. The `lwt-agnostic-library` skill references stale paths (`lib/io`, `lib/lwt/io`, `lib/utils/retry`);
    actual: `lib/local/io`, `lib/lwt/local/io`, `lib/core/retry.ml`.
13. `Ipc.send` (blocking) has no timeout and reads exactly one line; a wedged daemon hangs a CLI caller.
14. `Log.recent` only records messages that passed `min_level` (at default `info`, all warn/err pass).
15. `lib/app` is not functorised (hundreds of direct Lwt references), so the "one module names the
    scheduler" rule holds for libraries but not for the application layer.

---


---

OCaml implementation notes for this subsystem: [ocaml/01-core.md](ocaml/01-core.md).
