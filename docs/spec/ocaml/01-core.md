# 01 — Foundation: lib/core — OCaml implementation notes

Companion to the spec [../01-core.md](../01-core.md); not normative. The foundation is one library,
`tsync_core` (`lib/core`), over the vendored scheduler (`vendor/duppy`) and the vendored xxHash
header (`vendor/xxhash`). The HTTP discipline (§10) is `lib/http`, the IPC framing (§11) `lib/ipc`.
Bodies and memory are in [memory.md](memory.md).

## C.1 Where each spec concept lives

| Spec concept | OCaml |
|---|---|
| keys and prefixes (§2.1) | `Names.valid_key`, `valid_prefix`, `check_key`, `check_prefix`; `Key.t` and `Key.prefix` are `private string`, built by a namer or by the validating `Key.of_string` / `Key.v` / `Key.prefix_of_string` |
| domain names (§2.2) | `Names.domain_name_error ?local_store`, `Names.reserved_roots`; `Domain_name.t` (`of_string`, `v`) |
| leaves and paths (§2.3) | `Names.valid_leaf`, `valid_path`, `user_path` (strips one leading and one trailing `/`) |
| logical keys (§2.4) | no type: a path is a validated string taken apart by `Names.leaf_of`, `parent_of`, `join`, `is_under`; the domain prefix is `Key.manifests`; the kind is read from local state (`Mirror.kind`), never from the spelling |
| folder ids (§2.5) | `Folder_id.t` (`root`, `trash`, `of_string`, `v`, `mint ~uuid ~counter`); grammar in `Names.valid_folder_id` |
| stored keys (§2.6) | `Key.namespace`, `Key.child` (namespace and `Xxh.dual leaf`), `Key.anchor`, `Key.index`, `Key.trash_entry`; readers `Key.leaf`, `parent_segment`, `is_internal_leaf`, `is_child_of`, `folder_of_namespace_key` |
| item references (§2.7) | `Names.item_ref` (`Root`, `Dir`, `File_id`, `File`), `parse_ref` (a `result`, so total), `ref_to_string`, `dir_ref`, `valid_file_id`; a malformed one is answered INVALID in `Handler.resolve_ref` |
| mirror escaping (§2.8) | `Names.storable`, `escape`, `escape_path`, `name_max_local`, `is_internal_local`; the taken-handle refusal is `Mirror.check_handle` |
| temporary names (§2.9) | `Names.is_temp_name`, `temp_owner`, `temp_name`; `Fs.temp_in`, `Fs.sweep_temps`; the local store's random form is `temp_name` in `lib/store/local.ml` |
| random ids (§2.10) | `Ids.urandom` (raises, no fallback), `token`, `secret`, `short` |
| hash (§3.1) | `Xxh.string`, `bigstring`, `hex16`, `dual`, `dual_bigstring`, the streaming `dual_create` / `dual_update_*` / `dual_digest`; stubs in `xxh_stubs.c`; known answers in `tests/unit/hash` |
| chunk keys (§3.2) | `Chunk_key.t` (`of_string`, `v` raising CORRUPT, `of_body`, `of_bigstring`, `empty`); the shape test is `Names.is_chunk_key`; membership in the chunk space is `Key.chunk_of`, by prefix |
| other digests (§3.3) | `Key.child` (leaf hash), `Manifest.digest_of` (whole file), `Manifest.symlink` (target), `Names.escape` (seed 0 only) |
| chunking (§3.4) | `Chunking.count`, `offset`, `length`, `index`, `pieces` |
| chunk size (§3.5) | `Chunking.default_chunk_size`, `chunk_size_min`, `chunk_size_max`, `chunk_size_read_max`; the choice is `chunk_size` in `Remote.Make`, which answers the default until a background fiber has the main's recommendation; the validator's range check is in `lib/config/config.ml`; the reader's is `Manifest.check_readable` |
| shards (§3.6) | `Names.shard`, `valid_shard`, `Chunk_key.shard`, `Key.shard_prefix`, `Key.chunk` |
| monotonic clock (§4) | `Rt.now` (`Duppy.time`, `CLOCK_MONOTONIC`); `Health.create ?now` takes a clock for tests |
| mapping immutable data (§5, §12) | `Fs.map_fd`, `Fs.map_file` (private, read-only descriptor, so a short file is an error); `Fs.read_fd_bigstring` where a mapping could fault |
| runtime (§6.1, §6.2) | `Rt`, C.2 |
| EINTR (§6.3) | `Fs.eintr`, `Fs.sys`, `Fs.opt`; `Fs.exists` is `Fs.stat_opt`; the stubs of `sys_stubs.c` loop on EINTR themselves |
| local filesystem helpers (§6.4) | `Fs.opt` (absent only for ENOENT and ENOTDIR), `stat_opt`, `lstat_opt`, `kind`, `read_file_opt`, `readdir_opt`; `replace`, `durable_replace`, `create_if_absent`; `write_all` and `pwrite_all` (no progress is a LOCAL failure); `rm_rf` (by `lstat`); `reserve`; `disk_space` (`None` when unknown); `unlink_quiet` is the one best-effort helper |
| scheduling (§6.5) | `Rt.execution`, `Rt.within`, C.3 |
| retry ladder (§7) | `Retry.ladder ?attempts ?deadline ?health ~op`, `Retry.delay`, `Retry.until_held`; kinds from `Fail.classify`; a stall is `Fail.t.stalled`, tallied by `Health.timed_out` |
| breaker (§8) | `Health` (`lost`, `check`, `is_held`, `is_down`, `answered`, `probe_lost`, `on_trip`, `timeouts`, `describe`, `state`), `Health.always_up`; each driver makes its own cell, the local store included (`Local.create`) |
| stop (§9) | `Stop.request`, `requested`, `on_request`, `check`, `wait`, `sleep`, `grace` |
| HTTP discipline (§10) | `Tsync_http.Client` (`endpoint`, `request ?stall ?headers ?body`, `excerpt`), `Codec`, `Transport` over `Http_ssl` or `Http_native` |
| IPC framing (§11) | `Ipc` (`serve`, `publish`, `Client`, `call`, `call_bulk`, `call_stream`, `advisory`); the parameters are `Ipc.max_line`, `line_deadline`, `max_connections`, `subscriber_backlog` |
| files that change under the reader (§12) | `Bulk.upload_file` in `lib/sync/bulk.ml`: positioned reads (`Fs.pread_full`) and an `fstat` before and after; nothing maps a user file. `Fs.clone` has no caller under `lib/` |
| ZIP64 (§13) | `Zip` (`create`, `add_dir`, `add_file`, `finish`, `crc_update`) |
| directory watch (§14) | `Dir_watch` (`open_`, `wait`, `close`): inotify on Linux, events for temporary names dropped by `Names.is_temp_name`, at most 64 reads per drain. On macOS `open_` answers `None` and the consumer (`lib/store/local.ml`) polls |
| glob (§17) | `Glob.matches` |

With no counterpart in spec 01: `Fail` (failure-model), `Dqueue` (durable-queue), `Manifest` and
`Folder` (02), `Keyed_locks` (04), `Cancel`, `Narrate`, `Display`, `Log` and `Usage` (07),
`Field_spec` (05, 06), `Chunk_set`, `Bigstring`, `Text`, `Registry`.

## C.2 The runtime (spec §6.1, §6.2)

`Rt` is direct style: a fiber is a duppy task, and a wait is `Rt.suspend`. The scheduler starts at
the first `Rt.spawn` or `Rt.run_sync`, on a pool of 2 to 8 domains with at most 256 blocking
threads.

| Capability | `Rt` |
|---|---|
| R1 spawn detached | `spawn`: a cancellation ends the fiber silently, any other escaping exception is logged through `Log.err` and the process continues |
| R1 join all, map | `all`, `both`, `map_concurrently`, `iter_concurrently` (a fiber per element); `map_bounded`, `iter_bounded`, `each` (`width` workers pulling) |
| R1 finally | `Fun.protect ~finally` |
| R1 promise | `Promise` (`resolve` raises when resolved twice, `try_resolve` answers `false`); waiters are woken after the promise's lock is released |
| R2 time | `now`, `sleep`, `timer`, `with_timeout`, `with_stall_timeout`, `first`, `is_cancelled`, `check`; a timeout is `Rt.Timeout`, a cancellation `Rt.Cancelled` |
| R3 coordination | `Fmutex` (FIFO, handed to the oldest live waiter), `Condition`, `Signal` (a versioned broadcast, so a wake between the check and the wait is not lost) |
| R4 bounded concurrency | `Semaphore` (`try_acquire` never passes a waiter; a width below 1 is 1; `stats` feeds the status report) |
| R5 file I/O | `Fs`; a system call inside a `` `Threaded `` fiber blocks that fiber's thread only |
| R6 sockets | `Tsync_http.Transport`, `Ipc` |
| R7 readiness | `wait_readable`, `wait_writable` |
| R8 stop | `Stop` |
| entering from a foreign thread | `run_sync` (the main thread, FUSE workers, JNI) |

- **Atomicity is by lock or atomic, never by confinement** (§6.2): fibers resume on any domain.
  State in this library is behind a `Mutex` (`Health.t`, `Stop` hooks, `Ids` generator, `Log`
  recent lines, `Keyed_locks` table) or an `Atomic` (`Stop` flag, `Names.temp_name` counter,
  `Log.min_level`, `Log.sink`). `Chunk_set` is unsynchronised and says so: its owner's lock covers
  it.
- **Process-wide registries** are `Registry.t` values (store drivers, frontends, hosts), filled at
  module initialisation before any fiber runs and only read afterwards, so they carry no lock.
- **Stop is not cancellation**: `Stop.Stopping` and `Rt.Cancelled` are two exceptions, and
  `Retry.ladder` re-raises both before it classifies anything.

## C.3 Scheduling on duppy (spec §6.5)

The scheduler's priority type is duppy's execution class, so the three kinds are the three classes:

| Spec kind | Class | How duppy runs it |
|---|---|---|
| may-block | `` `Threaded `` | on an auxiliary thread of a worker's domain, holding one of the 256 blocking slots |
| non-blocking I/O | `` `Immediate `` | on the worker itself; no slot |
| time-sensitive | `` `Direct `` | on the worker itself, ranked before any `` `Threaded `` task; no slot |

- A fiber starts `` `Threaded ``. `Rt.within cls fn` moves the calling fiber into `cls` for `fn` and
  back; nesting the same class costs nothing. The class lives in the fiber's context and
  `Rt.suspend` resumes under it, which is how a kind survives its own waits.
- A detached fiber takes its class from `Rt.spawn ?execution`. A child (`async`, `all`, `first`, and
  so `with_timeout`) starts in its parent's class, so a race built inside a region stays in it.
- The tasks that only wake a fiber (a timer firing, a descriptor becoming ready) are `` `Immediate ``.
- Socket reads and writes try the call in the caller's class and enter `` `Immediate `` only when it
  would block, for the wait and the retry (`Transport.plain`, `Http_ssl.ssl_retry`, the line reader
  of `Ipc`). The IPC and HTTP accept loops and each IPC connection are `` `Immediate `` fibers;
  `Dir_watch.wait` runs `` `Immediate ``.
- `Ipc.serve` answers `ping` itself and runs the handler through `Rt.within`, in the class its
  `?execution` gives the request. The supervisor names `uplink` `` `Direct ``.
- Entering `` `Threaded `` waits for a slot, and that wait is not cancellable.
- An `` `Immediate `` or `` `Direct `` region stalls its worker for as long as it runs. `Log` writes
  to a sink that can block, so `Rt` reports a detached fiber's failure from `` `Threaded ``.

## C.4 Where the code departs from the spec

Numbers are findings of [the review](../../review/2026-10-01-rewrite.md) that are still open.

- **Redial (§10).** `Client.request` sends a request again on a fresh connection when a pooled one
  fails while the request is written or closes before any byte of an answer. Such a request may
  have left; the spec resends only one that did not.
- **Stall progress (§10).** `Client` counts each slice of a request body the transport accepts.
  Bytes still in the kernel's send buffer after the last slice are not heard (23).
- **The lessee's renewal is not independent of may-block work (§6.5).** The uplink ticker is a
  `` `Threaded `` fiber, because its tick also probes stores and saves state; only the renewal
  request and its timeout run `` `Direct ``. With every slot held the ticker does not wake. The
  owner's answer, the admitter's timer and the liveness answer are independent. The control law's
  computation runs inside that tick, as may-block work.
- **Wall clock for a duration (§4).** `Display` measures a command's elapsed time and its
  10-second progress interval with `Unix.gettimeofday`. The claim confirmation in `lib/sync` is
  timed on the wall clock too (140).
- **EINTR outside `Fs` (§6.3).** `Sys.readdir` in `Import_plan`, `Rsync` and `Export`,
  `In_channel` in `Kept_walk`, and `Sys.file_exists` in `bin/` are not retried. Some callers use a
  bare `Unix.stat` (111).
- **Detached failure (§6.1 R1).** A detached fiber that raises is logged and ends; the process is
  not stopped, and nothing restarts the fiber.
- **Store-root temporaries (§2.9).** Nothing sweeps the local store's random-form temporaries (122).
- **`Rt.Condition.wait`** does not keep mutual exclusion when its waiter is cancelled (112); it has
  no caller.
- **`Ipc.serve`** changes the process-wide `umask` around its bind while other domains create
  files (115).
- The blocking-thread pool grows to its 256 slots and never shrinks (94).

## C.5 Learnings

- **A system `Mutex` never spans a wait.** A fiber that suspends may resume on another system
  thread, which cannot unlock it; `Rt.within` is such a point. `Mutex.protect` guards a few
  statements, `Rt.Fmutex` a hold that waits. `Keyed_locks` shows the split: a `Mutex` over its
  table, an `Fmutex` per key held across the caller's work.
- **Nothing is called under a lock.** `Health.lost` takes its watchers out under the mutex and
  runs them after; `Promise` wakes its waiters after unlocking; `Stop.request` copies its hooks,
  then runs them. A callback that re-enters the same module would otherwise lock twice, which
  OCaml 5 raises on (A-2.4).
- **A cancelled wait withdraws itself.** `Rt.suspend`'s `register` returns how to remove what it
  queued, and every queue honours it (`Fmutex`, `Condition`, `Semaphore`, `Signal`, `Promise`,
  `Health.on_trip` through `Retry.until_held`). A hand-off whose waiter answers `false` goes to the
  next one, so a slot is never given to a fiber that left. A descriptor wait is re-armed every 30 s
  so a cancelled one does not stay registered.
- **`Rt.first` cancels its losers and waits for them**, so none outlives the call holding a
  descriptor its caller is about to close. `~detach:true` is for a loser cancellation cannot
  interrupt, a blocking system call: the store probe, the status probes.
- **Fan-out by pulling.** `map_bounded` and `each` run `width` workers over a shared cursor and
  allocate nothing per element up front; `all` and `map_concurrently` start a fiber per element and
  suit lists whose length the code fixes (C-1.1).
- **Domains start late.** `Rt` starts the scheduler at first use, since a process with a second
  domain cannot fork (B-4.4).
- **No `Lazy.t` on the pool** (B-10.1): forcing one from two domains raises. No library under
  `lib/` uses one.
- **C stubs release the runtime lock around every call that can block** (`pread`, `pwrite`,
  `fsync`, `flock`, `statfs`, `fallocate`, the clone, the bigstring hash): a stub blocked while
  holding it stalls every domain at the next stop-the-world section (B-3.2). A path is copied to a
  C buffer first, `errno` is saved before the lock is retaken, and a bigarray's data is used in
  place since it never moves.
- **One C file, per-OS blocks.** `sys_stubs.c` has one `#if defined(__linux__)` block and one
  `__APPLE__` block defining the same functions. A call a platform lacks fails at run time with
  `ENOSYS` (the macOS watch) instead of breaking the build.
- **Signals are taken, not handled.** `Owner.stop_on_signals` blocks SIGTERM and SIGINT and reads
  them with `Thread.wait_signal` on its own thread; `Fs.ignore_sigpipe` is the only
  `Sys.set_signal`. A Stdlib `Sys` or channel call reports EINTR as a `Sys_error` string, which
  `Fs.eintr` does not match (B-3.1): file calls go through `Fs`.
- **Types carry the validation.** `Key.t`, `Key.prefix`, `Chunk_key.t`, `Folder_id.t` and
  `Domain_name.t` are `private string`: readable as strings, built only by a namer or a validating
  constructor. `of_string` answers an option or a result, `v` raises INVALID (CORRUPT for a chunk
  key read from a store).
- **Failures are data.** `Fail.E` carries the kind, and `Retry.ladder` decides on the kind alone.
  `Fs.sys` turns a `Unix_error` into a classified failure where it happens.
- **The short-id generator is locked and tagged with its pid** (`Ids.short`), so a forked child
  reseeds and two domains never share a draw (B-4.1).
- **Self-registration needs `-linkall`** (B-11.1): each driver, frontend and TLS library registers
  in a top-level `let ()` and its dune stanza carries `(library_flags (-linkall))`; without it an
  unreferenced module is dropped and its name is unknown at run time.
- **A clock passed in makes the breaker testable**: `Health.create ?now`.
