# 05 — Domain config and whole-domain operations — OCaml implementation notes

Companion to the language-neutral spec [../05-ops-config.md](../05-ops-config.md). See [README.md](README.md) for how these notes are organised.


## B.1 Runtime-independent learnings (valid under OCaml 5 direct style too)

- **Domain Context as a first-class module** (§2.4). `Conf.S` is a module type; `Domain.of_config` returns a
  packed module built with `(module struct … end)`. Derived contexts (`reading_from`, `reading_at_most`) are
  `include C` plus overridden values: an override must be complete. `reading_from` has to replace *every* read
  entry point, `watch`, the batch reads and `health` (d2d5cfd6): a missed one silently reads through the
  composite while listings come from the chosen store. A plain record of closures would make the missing
  field a type error.
- **Driver-field registry is a global ref set by a top-level `let () =` in `domain.ml`** (§2.1). The strict
  backend-key check therefore depends on the `Domain` library being linked and initialised before parsing; a
  tool linking only `Conf_parsing` parses without it. Explicit registration would remove the link-order
  dependency.
- **Yojson.Basic `Util.to_bool` / `to_string` raise `Type_error`** rather than `Failure`, so a missing
  `versioning` or `name` gives an unfriendly message (Open question 4). `refuse_unknown` runs before field
  reads, so typos are reported first.
- **Off-heap bulk state** (§4.3, §4.6): listings are spilled with `Buffer.add_int32_le`/`add_int64_le` into a
  spool file, sealed, then `Bigstring.map_file`d; `add` after seal raises because a mapping is sound only while
  the file stays as mapped. The mirror's destination view is `Hashtbl_mmap` (string→int), not `Hashtbl`: half a
  million keys on the heap were most of a resync's memory. Tests assert this by sampling `Gc` live words when the
  first object finishes (`tests/unit/mirror_pools`: 16 words/object, threshold 50; `import_listing`: fewer live
  words than files).
- **Spool reaping by pid** (§2.5): temp names embed the owning pid; `reap` unlinks only files whose pid is dead,
  which is what makes the machine-wide spool dirs safe to share.
- **`Unix.lockf` merges locks held by the same process** (§4.9), so the kernel lock alone does not exclude two
  sessions in one process; hence the extra `held` flag (and Open question 18).
- **Which errno means "held"** (`EAGAIN | EACCES | EDEADLK`) is platform-decided, so it lives in the binding
  (`gc_lwt.ml`), not the collector.
- **`Printexc.register_printer`** for `Gc.Unsupported`/`Busy` so the message reaches the user unwrapped.
- **`Id.token` reads `/dev/urandom` and raises** rather than falling back (share tokens need
  unguessability); the write-path PRNG carries its own state tagged with the pid so a forked child does not
  replay its parent's ids.
- **Polymorphic variants for decision types** (`Rsync.source/target/skip`, `Export.outcome/event`, mirror's
  `on_entry` outcome) keep callers free of the defining module; the rsync `decide` is a pure function so the
  whole table is unit-tested without I/O (`tests/unit/rsync_plan`).
- **`String.escaped dst`** in the export header makes any destination path one header line; the header is
  compared whole, never parsed.
- **`Unix.realpath` raises** on dangling paths; import falls back to the unresolved path.

## B.2 Lwt / functor-specific learnings

- **Pattern.** Every op is `Over (Io) (Dep1) … (DepN)` over a small concurrency signature (`Io.S`: bind,
  catch, finalize, iter_p …), with an inner `Make (C : Conf.S with type 'a io = 'a Io.t)`. The Lwt instance is
  a one-line `include X.Over (Io_lwt.Core) (…_lwt) …` in `lib/lwt/domain/ops/*_lwt.ml`, and `Conf_lwt.S` fixes
  `'a io = 'a Lwt.t` via `include Conf_lwt.Monad`. What it bought: the ops name no scheduler and can be tested
  over fakes. What it cost: long functor argument lists that are pure plumbing, and **module-level state per
  functor application** — each `Make (C)` gets its own pools (mirror `copy_pool`/`probe_pool`), its own gc
  progress table and its own gc `held` flag, so two applications for one domain would not share bounds or the
  lock flag. Under OCaml 5 direct style these become ordinary functions taking a context record, and the
  per-domain state must be explicit (owned by the context or a registry).
- **Pools are semaphores** (`Bounded`: `use`, `map_with`, `filter_map_with`, `each ~width`). The deadlock rule
  (§4.6, §4.9): never take a slot of pool P while holding a slot of P. Mirror takes probe then copy
  sequentially; gc uses `unit_slots` for roots and `item_slots` for chunks *by nesting depth*, not by phase —
  the code notes it "has fallen into more than once". Under effects the same rule holds for any semaphore.
- **Worker pull vs fan-out.** `Pools.each ~width f` runs `width` workers each pulling `f ()` until `None`; used
  where the item count is the data's (mirror entries, export chunks). A fan-out (`Lwt_list.map_p`,
  `Io.iter_p`) allocates one promise per item up front even when a pool bounds execution: mirror's old shape
  cost 140 live words/object before the first copy. GC still does `iter_p` over the roots of a namespace and
  the chunks of a root (bounded in execution by pools, not in allocation) — one manifest of 100k chunks makes
  100k pending promises. Under effects this is unbounded fibers; use a worker loop.
- **`Pools.each` stops every worker at the first exception**, so export's per-file work is wrapped
  (`guarded`) to settle the file as failed and never raise.
- **The monad marks the yield points** that §6.1's cooperative-safety arguments rest on (e.g. `Batch.publish`
  swaps the spool after a `let*`; gc `take_lock` sets `held` after one). Direct style removes that marker; with
  OCaml 5 domains, all §6.1 state needs `Atomic`/`Mutex`, and "check then set across a yield" patterns become
  real races even on one domain if fibers interleave at effects.
- **Memoising a promise** (`export.opened`: `job.opening <- Some (open_job …)`) is how concurrent workers share
  one open; in direct style this needs a once-cell or a mutex around the open.
- **`Io.finalize`** carries every cleanup (listings, spools, batch, gc lock release); `Io.catch` wraps
  per-entry work in import/rsync/export. Exceptions from a `Failure` inside a bind propagate as rejected
  promises, which is why gc manifest-parse failure (`failwith`) aborts the whole `run` and still releases the
  lock through `finalize`.
- **No `Lwt.async`** in this subsystem; concurrency is always joined (`Pools.each`, `iter_p`, `map_with`).
  Integrity `verify` follows stores with `iter_p` (width = number of members, fixed by config).
- **Resync reuses the daemon's queues in-process** (`Sq.start`, `Mq.start`) via the `SYNC` signature binding
  `Sync_lwt.*`, so a one-shot sync drains exactly as the daemon would.
