# 05 — Domain config and whole-domain operations — OCaml implementation notes

Companion to the language-neutral spec [../05-ops-config.md](../05-ops-config.md). See [README.md](README.md) for how these notes are organised.


## B.1 Runtime-independent learnings (valid under OCaml 5 direct style too)

- **Domain Context as a first-class module** (spec §3.1). `Conf.S` is a module type; `Domain.of_config` returns a
  packed module built with `(module struct … end)`. Derived contexts (`reading_from`, `reading_at_most`) are
  `include C` plus overridden values: an override must be complete. `reading_from` has to replace *every* read
  entry point, `watch`, the batch reads and `health` (d2d5cfd6): a missed one silently reads through the
  composite while listings come from the chosen store. A plain record of closures would make the missing
  field a type error.
- **Driver-field registry is a global ref set by a top-level `let () =` in `domain.ml`** (spec §2.1). The strict
  backend-key check therefore depends on the `Domain` library being linked and initialised before parsing; a
  tool linking only `Conf_parsing` parses without it. Explicit registration would remove the link-order
  dependency.
- **Yojson.Basic `Util.to_bool` / `to_string` raise `Type_error`** rather than `Failure`, so a missing
  `versioning` or `name` gives an unfriendly message (B.4). `refuse_unknown` runs before field
  reads, so typos are reported first.
- **Off-heap bulk state** (spec §4.1, §4.3, §4.6): listings are spilled with `Buffer.add_int32_le`/`add_int64_le` into a
  spool file, sealed, then `Bigstring.map_file`d; `add` after seal raises because a mapping is sound only while
  the file stays as mapped. The mirror's destination view is `Hashtbl_mmap` (string→int), not `Hashtbl`: half a
  million keys on the heap were most of a resync's memory. Tests assert this by sampling `Gc` live words when the
  first object finishes (`tests/unit/mirror_pools`: 16 words/object, threshold 50; `import_listing`: fewer live
  words than files).
- **Spool reaping by pid** (spec §4.1): temp names embed the owning pid; `reap` unlinks only files whose pid is dead,
  which is what makes the machine-wide spool dirs safe to share.
- **`Unix.lockf` merges locks held by the same process** (spec §4.9), so the kernel lock alone does not exclude two
  sessions in one process; hence the extra `held` flag, which B.4 notes is set too late.
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
  (spec §4.1, §4.6, §4.9): never take a slot of pool P while holding a slot of P. Mirror takes probe then copy
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
- **The monad marks the yield points** that the spec §5 atomicity list's arguments rest on (e.g. `Batch.publish`
  swaps the spool after a `let*`; gc `take_lock` sets `held` after one). Direct style removes that marker; with
  OCaml 5 domains, all of that state needs `Atomic`/`Mutex`, and "check then set across a yield" patterns become
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

## B.3 Mapping to the current code

| Spec concept | Current code |
|---|---|
| parser and validation | `lib/domain/config/parsing/conf_parsing.ml` (`load`, `of_json`, `refuse_unknown`, `parse_backend`, `parse_frontend`, `validate_roles`, `parse_size`) |
| Domain Context | `Conf.S` / `Conf_lwt.S` (a first-class module) |
| building a domain | `lib/domain/config/domain/domain.ml` (`of_config`, `build_backends`, `reading_from`, `reading_at_most`, `start_resumed`, `set_on_recorded`) |
| operations | `lib/domain/ops/{import,export,rsync,mirror,resync,retention,gc,integrity,share,publish,batch,listing}.ml`, bound to Lwt in `lib/lwt/domain/ops/*_lwt.ml`, driven by `lib/app/cli/cmd_*.ml` |

## B.4 Where the current code differs from the spec

- **Mirror** (`lib/gc/store_mirror.ml`) compares mutable keys by body: each one is read from both stores inside a sequential filter, before the concurrent copy loop. Copies are plain `put`s, and progress is reported only when a batch ends.

**Config.**
- Frontend objects keep every key as an option (`parse_frontend`): `{"type":"fuse","mountPoin":"/x"}`
  is accepted and the domain mounts at the default (finding G1). Backend keys are checked only when
  the driver field registry is loaded (a global ref set by `domain.ml`'s top-level `let () =`); a
  tool linking only `Conf_parsing` skips the check.
- Non-string option and field values are stringified; floats, objects and null are silently
  dropped. A bool option that is neither a true nor a false spelling falls back to its default.
- Duplicate backend names are accepted; `build_backends` keys traffic, admission and built tables by
  name, and two deferred targets with one name share one log directory (finding G2). Duplicate
  domain names and duplicate frontends are accepted (`pick_domain` takes the first).
- Domain names are not validated (security finding S4).
- A missing `versioning` or `name` raises `Yojson…Type_error` instead of a sentence.
- `tls` is not validated. `Domain.default_domain` trusts a recorded name when the config cannot be
  read.
- DOCUMENTATION.md (troubleshooting, and near line 1042) says unrecognised fields pass through.

**Operations.**
- Rsync builds its whole entry list in memory (`entries_of`), reads domain facts from the mirror
  with a store fallback (`manifest_at`), and `Rename_in_domain` re-reads the mirror and calls
  `Option.get`, failing on a store-only manifest (finding G4). A skipped symlink under `skip` is
  labelled `Source_missing`; under `follow` a dangling target fails in `stat`.
- Import reaps a dead run's journal batch instead of publishing it; the re-run does not re-emit
  ops for files the dead run uploaded. Glob `**/X` matches at every character offset, so
  `**/.git` matches `foo.git` (finding G11).
- Import and rsync write the mirror directly whatever process they run in.
- `tsync mirror` lists and copies the domain prefix before chunks, so a destination can briefly hold
  manifests whose chunks are missing.
- `cannot_bridge` treats an empty journal as unbridgeable.
- Trash restore publishes no journal entry (peers learn only by resync). Purge's collection may
  leave folder anchors behind.
- Expire's version-directory filter is `List.mem` over survivors (O(expired × surviving)); its stats
  omit trash deletions; expired share manifests are never deleted.
- Integrity finds orphans only when a main has a `local_path` (a readdir of the store directory).
- Share reads through the composite and writes to one member without checking the object is there;
  `--token` accepts any non-empty hex and overwrites an existing link with a plain `put`; there is no
  revoke.
- GC's in-process `held` flag is checked, then set after an await (`take_lock`), so two sessions in
  one process could both pass; POSIX `lockf` merges same-process locks (finding G3). Nothing reaches
  this today (one session per `tsync gc` process).
- The `mirror.mli` doc refers to `Checkout.resync`, a stale name for `tsync mirror`.

## B.5 Conformance checks in the current test suite

| Area | Tests |
|---|---|
| config | `tests/unit/conf` |
| import | `import_batching`, `import_listing`, `import_progress`, `scenario/import_export` |
| export | `ops/export`, `unit/export_record`, `unit/export_cli` |
| rsync | `unit/rsync_plan` (decision table only), `live/rsync` |
| mirror | `unit/mirror_pools` (≈16 live words per object, threshold 50), `unit/mirror_probe`, `scenario/resync` |
| resync | `ops/resync` |
| retention, gc | `scenario/expire`, `scenario/gc`, `backends/gc_cost`, `gc_targets`, `gc_queued`, `unit/gc_job`, `unit/gc_report`, `content/promote_race` |
| integrity | `ops/integrity_tree` |
| share | `unit/share` |
| write guard | `backends/write_guard` |

Not covered today: frontend option keys, duplicate names, domain-name grammar, rsync `act` on a
store-only manifest, same-process gc exclusion, share token collisions and revoke.

## B.6 Resource strategy (implementation choices, not spec)

The normative spec leaves concurrency widths and memory strategy to the implementation (P6). What
the current code does, and why:

- **Listing spool** (import, mirror, rsync): records appended to `<cache_root>/<op>/<name><temp
  suffix naming the owning pid>`; strings `int32_le length ++ bytes`, ints `int64_le`; sealed, then
  mapped and read once or several times; `reap` removes spools of dead pids. The spec only requires
  such files to be temporaries.
- **Import** spills its plan to disk (a million paths ≈ 100 MB otherwise); only the cycle-guard set
  grows, per directory.
- **Export** runs `max_downloads` workers (overridable with `-j` through `reading_at_most`) pulling
  chunks in file order from a shared cursor, so open files stay ≤ workers.
- **Mirror**: source listing spooled a batch of shards at a time; destination view in `Hashtbl_mmap`;
  copy pool `max_chunk_buffers`, probe pool `max(8, 4 × max_chunk_buffers)`, in flight
  `4 × probe`; probe and copy slots taken one after the other, never nested.
- **Resync** walk width = `-j` (default 32).
- **Expire/purge** delete in batches of 1000 (the S3/GCS bulk-delete cap).
- **Atomicity inside an operation** (was spec §5): the batch (appends and swaps serialised), export's
  job cursor, once-only open/finish, first-writer-wins outcome, mirror's cursor and counters,
  resync's pending ops and counters, gc counters and progress throttle.
