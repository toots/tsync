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
