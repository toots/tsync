# 04 — Checkout & local cache (the local side) — OCaml implementation notes

Companion to the language-neutral spec [../04-checkout-cache.md](../04-checkout-cache.md). See [README.md](README.md) for how these notes are organised.
Related notes: [data-model/local-cache.md](data-model/local-cache.md),
[algorithms/read-path-and-cache.md](algorithms/read-path-and-cache.md),
[algorithms/durable-queue.md](algorithms/durable-queue.md).

## B.0 Where the spec lives in the code (tree at `4c32fa96`)

| Spec concept | Code |
|---|---|
| layout paths, `per`, shards | `lib/domain/cache_layout`, `Conf.chunks_per_group`, `Chunk_layout.shard_of` |
| group, group key | `Manifest.Group` (`key_of`, `of_table`, `all`) |
| mirror entries, memo | `Manifests` (`published` memoised by `(ino,size,mtime)`, FIFO 1024, an implementation choice the spec leaves open; `write` is the sole writer and stamps names; `current` is the single resolution point) |
| staged manifest codec | `Staged_manifest` (`staged_of_string`, `staged_to_string`, version check, `.bad` set-aside in `read`) |
| staged bodies | `Staged_body` (`ensure`, `resize`, `copy_chunk`, `link_group`, `adopt_whole`) |
| staged write path | `Data.write_locked`, `ensure_group_body`, `truncate_locked`, `stage_whole`, `split_whole` (`lib/domain/checkout/content/data.ml`) |
| upload and promotion | `Data.sync`, `upload_staged`, `promote_pending`, `promote`; `File.upload` |
| WAL codec and log | `Wal` (`of_body`, `Job`, `Owed`, `log_for`, `discharge`, `owed_metadata`) |
| file-operation interface | `File_ops.S` (`lib/domain/checkout/ops/file_ops.ml`), implemented by `File.Make_with_layout` |
| tree interface | `Checkout_intf.S`: `Checkout` (full), `Lazy_checkout` (lazy, `PULL.children`) |
| folder-id index | `Folder_ids` (`lookup_id`, `write`/`replace`, `key_of_id`, `whereabouts`, `rebuild`) |
| resync primitives | `Checkout.record`, `Checkout.sweep_stale`, `Cache_layout.clear_projection`, `Cache_layout.sweep_stale` |
| availability | `Checkout.availability` (synchronous, no event loop) |
| maintenance | `Temp_files`, `Staged_orphans` (grace 3600 s, on demand), `Export_records`, `Maintenance_lwt` |
| peer application, publish decisions | `File.apply_foreign_ops`, `File.backend_ops`, `Resolve.Arrival`, `Resolve.Publish` |

## B.0.1 Where the current code differs from the spec

- **Several writer processes.** FUSE children, the converging parent and one-shot `tsync sync`
  all write one cache root; `meta_mutex` (`file.ml`) and `with_key` (`data.ml`) are per-process
  Lwt mutexes, and `File.write` does not take `meta_mutex`. A peer `Delete` applied in the
  parent can discard a staged edit a FUSE child just wrote. The spec makes one owner per domain
  and re-checks staged facts under the key lock (spec §3.2).
- **No fsync.** `Fs.atomic_write` / `with_temp_rename` / `atomic_write_at` rename unsynced temps.
  The spec's primitives fsync the temp before every replace.
- **Release before switch.** `ensure_group_body`'s slow path and `truncate_locked` call
  `Sb.forget` on old bodies before `Mfs.write` writes the new sidecar; a crash between leaves a
  sidecar naming a deleted body, and `Sync_queue` then treats the ENOENT as "nothing owed" and
  abandons the edit.
- **Set-aside sidecars lose their bodies.** `Staged_manifest.fold` skips `.bad` files, so
  `uuids ()` omits their bodies and `Staged_orphans` reaps them on `tsync cache --prune`. The
  set-aside name `<leaf>.bad` also collides with a user file named so.
- **Persisted partial records.** Partial bodies are named `<group key>` with a strict-parsed
  `<group key>.manifest` interval record; the spec keeps held intervals in memory only and names
  partial bodies `.partial`.
- **Undecodable WAL records.** `Wal.Job.of_string` never fails; garbage decodes as an empty
  `Intent` that reconcile deletes, and unknown ops are dropped by `filter_map`.
- **Promotion before `Executed`.** `Data.sync` promotes (deleting the staged sidecar) before
  `Sync_queue.run` calls `W.discharge`; a crash between completes a `Prepared` record without
  publishing its entry.
- **Upload cancellation is cooperative only.** `File.write` calls `cancel_upload`, but nothing
  stops a manifest put already past the cancel check; the spec's edit generation closes this.
- **No read handles in FUSE.** `internal_ops.ml` `read` resolves the key on every call, so a
  peer update between two reads of one descriptor mixes versions; `assemble_to` loops over
  reads the same way.
- **`rmdir` removes non-empty folders**; rename flags (NOREPLACE, EXCHANGE) are ignored; FUSE
  `fsync`/`flush` are no-ops.
- **Directory `stat` mtime is `now`** on every call.
- **Removed-id records (`folders/by-path/`) are never pruned**; `rebuild` calls `unlink_quiet`
  on the `by-path` directory, which fails quietly.
- **Orphan sweep uses a 1 h grace** and runs only on demand; the spec runs it exactly at owner
  start.
- **Revert** puts the manifest and writes the journal entry directly, with no WAL record.
- **No own marker, no staged `base`, no WAL `priors`/`localFrom`, no re-keying, no `exclusive`
  or `base` on writes, no `retain`/`release`**: all are spec additions.
- **The view** is updated only by promotion; an abandoned promotion leaves the old manifest in
  the mirror.


## B.1 Runtime-independent learnings (valid under Lwt or OCaml 5 direct style)

- **Manifests are `mmap`ed, and a cached manifest pins its mapping** (spec §4.2). A `Bigarray`
  mapping is released only when the value is collected, so an unbounded memo of decoded
  manifests held 19,261 live mappings (75 MB of pinned page cache) during an import. Bound any
  cache of mapped values by count, not bytes; FIFO suffices. Memo validity uses `(st_ino,
  st_size, st_mtime)` so a write by another process is noticed without coordination.
- **Chunk bodies live off the OCaml heap** (`Bigstring` = `Bigarray.Array1` of chars, commit
  acf20d86). Group assembly, staged copies and upload fillers allocate `Bigstring.create len`
  per member; `Fs.read/write` take bigstring slices (`Bigarray.Array1.sub`, no copy). Keep
  buffers as bigstrings end to end — a `string`/`bytes` round trip doubles memory for 8 MiB
  chunks.
- **`Manifest.t` is the body itself** (a mapped bigstring); header fields and chunk keys are read
  by offset, never materialized into lists (a 32 GB file has 31,230 keys). Group keys are hashed
  by streaming XXH3 over the member keys (C stub, `XXH_INLINE_ALL`, `XXH3_64bits_withSeed`).
- **Syscall retry wrapper** (`Syscalls.S`): every `stat/open/rename/link/utimes/...` goes through
  an EINTR-retrying layer (commit 37c0d67d: "an interrupted syscall is not an answer"). Missing on
  any one call surfaced as spurious ENOENT/EIO under FUSE signal delivery.
- **`Filename.temp_path` naming** (`.tsync-tmp-<pid>-<seq>.tmp`) is also used by
  `Bigstring.snapshot` (reflink clone via `FICLONE` in `Device.clone`) in the *same directory* as
  the source. On a reflink-capable fs this created/unlinked a temp file in a directory an inotify
  watch was on, so every read woke the poller (OOM loop on a Pi). `O_TMPFILE` does not avoid it
  (closing still fires an event, with no name to filter). Keep scratch out of watched
  directories or filter temp names at the watcher. Clonability is cached per directory; on a
  non-clonable fs the first attempt per directory still creates and unlinks a temp.
- **`atomic_write_at`** `ftruncate`s the temp to the final size before producing pieces (fails
  fast on ENOSPC) and requires every byte to be covered exactly once — the member length check
  is what enforces that.
- **Type-level lifecycle**: `Staged_manifest.state = Owed of staged | Committed of staged *
  Manifest.t`, with `write` only able to produce `Owed`, makes "a mutation silently carries a
  finished upload's commit record" unrepresentable. Keep that shape (sum type, not an option
  field).
- **Decision tables as pure functions over variant "facts"** (`Resolve.Arrival`,
  `Resolve.Publish`) with exhaustive `match`, printed whole by a test. Polymorphic variants for
  small fact enums avoid module dependencies. The enact step pattern-matches `(action, op)` and
  treats impossible pairs as `invalid_arg`.
- **Capability hiding by shadowing**: `File.Local` redefines `St`, `Js`, `Hs`, `R` as empty
  modules (`module St = struct end [@@warning "-60"]`) so nothing under the metadata lock can
  call the store. It is a convention, not a boundary (`C.store` is still reachable); a separate
  functor/module without those arguments would enforce it.
- **Process-wide singletons via top-level `Hashtbl` keyed by directory/root**: because the
  per-domain `Make (C)` functors are applied by many consumers (file ops, diagnostics, share
  server, export, resync), any state that must be unique (WAL log + id counter, both `Owed`
  hand-offs, manifest memo, cache `held` counts) lives *outside* `Make`, in a table keyed by the
  directory, and `Make` looks it up. State accidentally left inside `Make` is duplicated per
  application — this is the case for `Chunk_cache.fetching`/`slots` and `Data`'s pull table
  (spec §9 item 5). Bindings modules (`*_lwt.ml`) apply the outer functors exactly once.
- **Forked processes**: `Id.short` reseeds its PRNG when `getpid` changes (a forked child would
  otherwise mint its parent's uuids). Any per-process table (locks, memos, counters) is copied
  by `fork` and must not be trusted as shared.
- **Synchronous CLI paths** (`Checkout.availability`, `Staged_manifest.sidecar_path`) are plain
  functions outside any functor so a command with no event loop can call them.
- **Yojson** for every small JSON file; `Yojson.Basic.Util.member` returns `` `Null `` on missing
  fields, which is how optional fields (`o`, `z`, `whole`, `published`, `v`) are decoded; wrap
  decoding in `try` and map failure to "set aside" (staged) or "legacy Intent" (WAL).

## B.2 Lwt / functor-specific learnings

- **Functor over a concurrency signature.** Every module is `Over (Io : Io.S) (Fs) (Syscalls)
  (Lock) (Bounded) (Clock) … = struct module Make (C : Conf.S) = … end`; `lib/lwt/domain/…`
  applies them to `Io_lwt.*`. It let tests drive components with fakes and kept the domain
  library free of Lwt. Cost: two-level functor application everywhere, singleton state having to
  be hoisted out of `Make` (B.1), and type-equation noise (`with type 'a io := 'a Io.t and type fd
  = Fs.fd`). Under OCaml 5 direct style the `Io` parameter disappears; the capability parameters
  (Fs, Clock, Bounded, Fetch) remain useful as plain records/first-class modules for testing.
- **The monad marks the yield points, and the code relies on them** (spec §6, "Reliance on
  cooperative scheduling"). Sections written "with no `let*` between lookup and update" —
  `Partial.take`, the `ensure_fetched` table insert (gated by `Io.wait`/`wakeup_later`),
  `with_key`'s holder count, `Partial.publish`'s promise chain — are atomic only because Lwt
  cannot preempt. With effects the yield points become invisible (any call may perform an
  effect); with domains there is real parallelism. Each of those needs a `Mutex`/`Atomic` or
  must be confined to one domain.
- **`Partial.publish` serializes by promise chaining** (`let t = prev >>= write in replace table
  key t`). Direct-style equivalent: a per-body mutex; note the chain entry is never pruned while
  the body stays partial.
- **Fan-out bounds.** `Io.iter_p` over a group's members is unbounded at the cache layer (bounded
  by the wire pools in the chunk store below `Remote`); `Bounded.map_with`/`iter_with` pools
  (`slots`, `piece_slots`, `group_slots`, `metadata_slots`, `dir_slots`, `stat_slots`) bound
  caller-sized fan-outs. **Never take a pool inside the same pool** (a directory holding a slot
  while its entries wait for one deadlocks) — hence two stat pools and recursion outside the
  pool in `Temp_files`. Under effects/domains these become semaphores; the same nesting rule
  applies, and unbounded `iter_p` becomes unbounded fibers.
- **Deadline without cancelling shared work** (`within_deadline`): `Lwt.async` the work, resolve
  a separate `Lwt.wait` promise from it, and `with_timeout` only the waiter — `Lwt.pick`/cancel on
  the work itself would cancel the fetch for every reader joined to it. Direct style: spawn the
  fetch as its own fiber, wait on a promise/ivar with timeout.
- **Fire-and-forget read-ahead** uses `Io.async` with `finalize` decrementing a counter and
  `catch` swallowing errors; an exception escaping `Lwt.async` would reach
  `async_exception_hook` (the engine treats a dead loop as fatal). Keep every detached task
  wrapped.
- **`Owed` hand-off** is a mutable closure field (`take`), not a stream: `signal` returns only
  when the consumer's `take` returns, which is what makes "a delete right after a close finds an
  upload to cancel" hold. A `Lwt_stream`/channel would decouple the two and lose that.
- **`Lock.with_lock` on an Lwt mutex** is non-reentrant: code already holding the metadata lock
  calls the inner `*_body`/unlocked variants (`rename_body`, `write_locked`, `promote` from
  `promote_pending`). Keep the locked/unlocked split explicit in a rewrite.
- **Read-ahead and pull-table counters are `ref`s mutated on the loop**; `pulling_now` is
  deliberately synchronous (a `Hashtbl.fold` that yielded would see the table mutate). With
  domains, protect or confine them.

## Pitfalls met in the File Provider rewrite

- **`syncfs` is not a barrier on macOS.** There is no `syncfs(2)`; the stub falls back to `sync()`,
  which only schedules the flush. A bulk pass that writes without a fsync per file and then relies
  on one `syncfs` before a durable record (a completion record, the last-sync mark) can lose or
  tear those files behind a record that survives the crash. Writes that a later durable record
  depends on keep their own fsync, and their directories are fsynced before the record is written.
  Dropping the per-file fsync made the file-id backfill fast and left exactly that hole.
  Still open: a rebuild fsyncs each entry's data but writes the last-sync mark after a `syncfs`
  only, so a crash right after the mark can lose entries' directory records (never tear them)
  until the next full resync.
- **No store call under the metadata lock.** Creating a file asked the store for its recommended
  chunk size, through the retry ladder, while the request handler held the metadata lock: with the
  store down, every mutation of the domain waited for the ladder to give up. Anything a local
  operation needs from a store is learned beforehand, in the background, or defaulted.
