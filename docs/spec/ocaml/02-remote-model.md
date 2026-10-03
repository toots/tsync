# 02 — The remote data model — OCaml implementation notes

Companion to the language-neutral spec [../02-remote-model.md](../02-remote-model.md). See [README.md](README.md) for how these notes are organised.


## B.1 Runtime-independent OCaml learnings

- **Manifest as a mapped Bigarray (§2.6).** `Manifest.of_file` `mmap`s the sidecar with
  `Unix.map_file` and closes the fd immediately (the mapping holds its own reference);
  keys are substrings read byte-by-byte. Safe only because sidecars are replaced by
  rename (`Io_lwt.Fs.atomic_write`), never truncated in place — truncation would SIGBUS
  every reader. Writers use `put_int32/put_int64` byte loops mirroring the readers so
  the layout has one description. `builder` zeroes the `Bigstring.create` buffer, else
  unset keys hold stale page content.
- **Buffers handed to `put` must own their bytes.** A store may keep sending after `put`
  returns and the key is the hash of what was passed, so the buffer is never reused.
- **Whole-file upload snapshot.** `Bigstring.open_snapshot` + `Bigstring.map_fd` map from
  a snapshot fd so later user writes do not reach mapped pages; a `Unix_error` while
  mapping becomes `Cancelled`.
- **xxHash binding.** `lib/core/xxhash_stubs.c` compiles the vendored header with
  `XXH_INLINE_ALL`; `hash_bigstring_with_seed` hashes a Bigarray in place; streaming
  state is a custom block freed by its finalizer.
- **Id PRNG and fork.** `Id.short` keeps its own `Random.State` tagged with the seeding
  pid (a forked child would replay the parent's sequence); global `Random` was avoided
  because its seeding depended on link order. Under OCaml 5 domains a shared
  `Random.State` is also a data race — use per-domain state.
- **Pool creation order.** Pools are bound with sequential `let`s, not a record literal:
  record field evaluation order is unspecified and the pool registry reports pools in
  creation order (`remote.ml` `pools_for`).
- **Exceptions as protocol.** `Remote.Cancelled = Retry.Cancelled`; `Source_changed`
  registers a printer; claim and tree-walk code branch on `Backend.classify exn`
  (Transient/Permanent), so drivers must raise classifiable exceptions.
- **Yojson** emits assoc fields in the given order (`dir,name,id[,path]`; `parent,name`);
  readers ignore order and extra fields.
- **Types as guards.** `Logical_key.t` vs `Stored_key.t` are distinct abstract types with
  no `Stored_key.of_string`, so a path cannot be used as a backend key by accident;
  `Collection_intf.S` re-exports `phase`/`run` via `type nonrec … = …`. `manifest.mli`
  declares `val recorded_name` twice (accepted by OCaml, cosmetic).
- **Unsigned reads into `int`.** `Manifest.int32_at` yields 0..2³²−1 in a 63-bit int, so
  its negative-length checks are dead code on 64-bit.

## B.2 Lwt / functor-specific learnings

- **Functor over a concurrency signature (§3.1).** Every component is
  `Over (Io : Io.S) (deps…)` returning `Make (C : Conf.S)`; `lib/lwt/domain/remote/*_lwt.ml`
  applies each `Over` exactly once. Solved: one codebase, scheduler swappable, deps
  passed pre-bound (`Store.INODE`, `Layout.OVER`…). Cost: every per-domain table had to
  be hoisted out of `Make` (next point), deep functor chains, and a mirror `lib/lwt`
  tree. Under OCaml 5 direct style the `Io` parameter disappears; `Make (C)` can become
  a plain record/first-class module per domain.
- **Per-domain state must not live in the functor body.** `Make` is applied in many
  modules, so pools, the corruption memo and the cursor debouncer are `Hashtbl`s in the
  `Over` body keyed by prefix; a per-application pool once admitted twice the budget in
  a proxy serving shares beside an engine. Under effects/domains these become
  process-global registries that also need a mutex (see §6.1).
- **Bounded fan-out.** Uploads use `Pools.each ~width` with workers pulling the next
  index instead of `Lwt_list.map_p` over indices (a promise per chunk allocated before
  the first read). Slots are taken inside the per-chunk function, never while holding
  one. Under effects: fibers are equally unbounded if spawned per item — keep the
  worker-pool shape, with a semaphore in place of `Bounded`, and make the index counter
  atomic.
- **Nested pools deadlock.** GC uses `unit_slots` (roots) and `item_slots` (chunks
  within a root); one shared pool deadlocked when every slot held a root awaiting a
  chunk. Same rule holds for semaphores.
- **The monad marks yields.** Every lock-free check-then-act in §6.1 is correct only
  because `let*` is the sole suspension point. In direct style a yield can hide in any
  call, and with domains there is real parallelism: those sites need `Atomic`/`Mutex`.
- **Sharing an in-flight promise** (corruption memo, resolved chunk size) is the Lwt
  idiom for single-flight; under effects use a `Promise`/`Ivar`-like cell guarded by a
  mutex.
- **`Io.async`** (cursor timer) is unsupervised: exceptions are swallowed inside
  `flush_cursor` by design. With effects, spawn under a supervising switch.

## B.3 Code map

| Spec concept | OCaml |
|---|---|
| Dual digest, chunk-key test | `Xxhash`, `Chunks.is_chunk_key` (`lib/core`) |
| Key layout, marker key, shards, run name | `Chunk_layout` (`marker_key`, `shard_name`, `gc_marker_key`, `gc_run_name`), `Stored_key` (`namespace`, `child_key`, `anchor_key`, `index_key`, `trash_namespace`, `share_key`, `is_child_object`, `is_internal`) |
| Logical keys | `Logical_key` (`to_string = prefix ^ path`, root has `path = ""`) |
| Inode / identity layouts | `Layout.Inode`, `Layout.Identity` (`lib/domain/remote/store/layout/layout.ml`) |
| Manifest format | `Manifest` (`builder`, `set`, `seal`, `encode`, `of_string`, `of_file`, `body ~name`, `recorded_name`); the local cache grouping `Manifest.Group` lives here too although it is a local-cache concern |
| Folder marker, anchor, trash entry JSON | `Folder` (`marker_to_string`, `marker_of_string`, `anchor_of_string`, `trash_marker_to_string`, `trash_path_of_string`) |
| Folder index | `Folder_index` (`max_children = 10_000`, `max_bytes = 64 MiB`, `worth_writing`) |
| Versions | `History` (`parse`, `versions_of`, `manifest_of`, `folder_versions`); `save_version` in `File` |
| Run record | `Collection.of_string` / `to_string` (legacy `reconciling`) |
| Corruption marker body | `Corruption_marker` (`lib/backends/api`) |
| Discard job keys and body | `Discard_job` (`lib/backends/api`), `lambda/verify.py` |
| Share manifest | `Share.create` (`lib/domain/ops/share.ml`), `lambda/handler.py` |
| ContentStore | `Remote` (`upload`, `upload_chunks`, `fill`, `publish`, `each_chunk`), `Chunk_store` (`store`, `Dedup`) |
| ManifestStore | `Store` (`put_manifest`, `claim_name`, `claim_folder`, `ensure_folder_id`, `ensure_claimed`, `put_folder_marker`, `put_anchor`, `get_anchor`, `placed`, `filed`, `holder_at`, `marker_id_at`, `put_raw`, `delete_raw`, `copy_manifest`) |
| TreeReader | `Inode_tree` (`children`, `find`, `fold_tree`) |
| ChunkSpace | `Collection` (`head`, `get`, `get_range`, `read_run`, `promote`, `promote_all`, `order_ttl = 5.`) |
| Corruption memo | `Corruption` (`is_marked`, `forget`, `ttl = 5.`) |
| Cursor debouncing | `File_store` (spec: 03) |

## B.4 Where the current code differs from the spec

- **Promotion is a writer duty, not a gate.** `Remote.publish` calls `Collection.promote_all` before
  `St.put_manifest`; it reads the run marker once (`read_run`, parse-based, so an unreadable marker reads
  as idle), promotes only when `local_path` is set, and ignores the result. No other publishing path
  (`copy_manifest`, revert, republish, rsync rename, version snapshot) promotes, and the http-proxy
  server's `Put` is a plain put. See [algorithms/gc.md](algorithms/gc.md).
- **Claims.** `claim_name` reads an empty `put_if_absent` answer as a win (an old http-proxy server
  answers `""`), falls back to a plain `put` on a non-transient error, deletes a disowned marker
  unconditionally, and has no confirmation step. `put_folder_marker` (mkdir, move destination) writes the
  marker with a plain `put` after the anchor; `Retention.restore` does the same with `put_raw`. A claim of a
  slot naming the claimant's id rewrites the anchor without checking whether the folder moved.
- **Markers with an empty id** are classified as markers (`marker_of_string` fills `""`), not as
  unclassifiable.
- **`claim_folder`** reads the marker on every publish into a folder (a `ponytail:` comment).
- **Manifest reader.** `Manifest.int32_at` reads unsigned values into a 63-bit `int`, so its
  negative-length checks never fire; negative `size` and malformed chunk keys are not rejected;
  `manifest.mli` declares `recorded_name` twice.
- **Version timestamps** are `gettimeofday () *. 1e9` as a float (about microsecond resolution), not
  strictly increasing per group.
- **Share reader** (`lambda/handler.py`) lists subfolders from markers without consulting anchors, and
  does not check that `key` lies inside the share's domain.

## B.5 State that relies on cooperative scheduling

The current code runs on a single-threaded cooperative scheduler; the following state is
read-modify-written without locks and needs atomics or locks under preemption or parallelism (spec §6):

| State | Pattern relied on | Consequence if preempted |
|---|---|---|
| Upload worker index (`next` in `each_chunk`) | `i = next; next += 1` | two workers on one index, or one skipped (a NUL key published) |
| Dedup memo (hash table, clear at cap) | unsynchronised insert, clear, lookup | table corruption |
| Corruption memo `marked()` | check the TTL, store the in-flight listing and time before awaiting | duplicate listings; torn fields |
| Per-prefix tables (pools, memos, cursor states, tree-read pool) | find-or-create | two pools for one domain: budget exceeded |
| Resolved chunk size cache | store the future on first call | a benign duplicate request |
| Cursor debouncer (`pending`, `timer_armed`, `last_published`) | forward-only max; arm-once flag | lost bump, or two timers |
| Run-open cache (`order_checked`, `running`) and GC session counters | plain field updates from concurrent promotions | wrong counts; torn cursor fields |
| `fold_tree` frontier (linked list, `parked`, `requests`) | mutated by completions of concurrent fetches | folders skipped or visited twice |
| Entry-key `last_ms`, folder-id lease counter | `ms = max(now, last + 1)`; `next += 1` | duplicate entry keys or folder ids |
| GC in-process `held` flag | check, then await, then set | two collections in one process (G3) |

## B.6 Resource strategy (not normative)

What the current code does to bound resources; the spec leaves these choices to the implementation.

- **Upload**: `each_chunk` runs `width(chunk_slots)` workers pulling the next index (never a promise per
  chunk); `chunk_slots` = `max_chunk_buffers` (≥ 1) bounds chunk bodies in memory for all uploads of a
  domain. Slots are taken inside the per-chunk function, never while holding one. The manifest builder
  keeps its body in a `Bigstring`, off the OCaml heap.
- **Dedup memo**: `Chunk_store.Dedup`, `max_known = 100_000`, cleared (not LRU) at the cap.
- **Downloads**: `downloads` and `ranges` pools, `max_downloads` each, keyed by chunk prefix in a
  global table so every `Remote.Make` application for one domain shares one budget (a per-application
  pool once admitted twice the budget).
- **Tree reads**: a shared "tree reads" pool of `max_downloads` per domain prefix; `fold_tree` keeps up
  to `width(slots)` requests in flight over a doubly linked frontier, one folder per request, or up to
  64 (`max_batch_folders`) with `list_many`.
- **Manifests** from local sidecars are `mmap`ed (`Manifest.of_file`), which the spec now recommends.
- **Run-open cache**: `Collection.order_ttl = 5.` s.
- **Corruption memo**: `ttl = 5.` s.
