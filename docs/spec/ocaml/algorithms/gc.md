# Retention and garbage collection — OCaml implementation notes

Companion to the language-neutral spec [../../algorithms/gc.md](../../algorithms/gc.md). Not normative.
Finding numbers refer to [the 2026-10-01 review](../../review/2026-10-01-rewrite.md).

## Code map

| Spec concept | Code |
|---|---|
| Surviving space S, outgoing space F | `Key.chunks`, `Key.chunks_from` under the collectable main's root; only `Chunk_spaces` and `lib/gc` name F (`tests/store/gc_scoping` lists the sources that do) |
| Collectable (A1) | `Chunk_spaces.of_store`, `collectable`: a store with a `local_path` not on a network filesystem, asked on every use |
| Driver-scoped access (§5.8) | `Chunk_spaces.read`, `twins`, `list`, called by the local driver (`lib/store/local.ml`) |
| Reference classification (§5.3) | `Chunk_spaces.references`: the gate refuses exactly what marking halts on |
| Gate, publish lock, promote (§5.4) | `Chunk_spaces.gate`, `with_publish_lock` (`flock` on `Key.gc_publish_lock`), `promote`, `sync_shards` |
| Run lock | `Chunk_spaces.with_run_lock`: an in-process check-and-set, then `lockf F_TLOCK` on `Key.gc_lock` |
| Run record R | `Gc_record` (`read`, `write`, `clear`, `run_name`; `reconciling` reads as closing) |
| Generation G (§5.6) | `Gc_generation`: `read`, `read_mains` (maximum over mains), `write`, `settle` |
| Every keep or delete decision | `Gc_plan`, pure: `start`, `namespaces`, `closing_generation`, `doomed`, `keep_plan`, `trash`, `purge_order`, `versions`, `journal`, `share`, `unreferenced` (`tests/gc/plan_test`) |
| Phases (§5.5) | `Collector.run ?budget ?pause ?verify ?keep`; outcomes `Completed`, `Suspended`, `Halted` |
| Dry run (§5.9), status | `Collector.dry_run`, `Collector.status` |
| Deletion on copies (§5.7) | `Composite.submit_collection_delete`, the copy job `Collection_delete`, `collection_owed`, `settle_later` (`lib/store/composite.ml`) |
| Queued discards, the bucket function | `Discards` (`add`, `pending`, `remove`), `Bucket_function` (`probe`, `confirmed`, `due`), `Composite.probe`, `outstanding`, `retry_outstanding` |
| Presence memo | `Copy_memo`, which reads G itself; `Chunk_set` holds its keys |
| Retention (§4) | `Retention.Make`: `expire`, `purge`, dry runs unless `apply` |
| Orphan namespaces (§4.6), integrity | `Integrity.Make`: `report`, `repair_tree`, `verify`, `repair_chunks` |
| Shares (§4.5) | `Share.Make`: `create`, `revoke`, `clear_cache`; expiry in `Retention` |
| Tests | `tests/gc/` (`plan_test`, `collector_test`, `resume_test`, `queued_test`, `verify_test`, `retention_test`, `integrity_test`, `share_test`, `mirror_test`), `tests/store/spaces_test`, `tests/store/gc_scoping`, `tests/unit/gc_job` |

The collector takes one session per collectable main, each under that main's run lock; the first
collectable main owes its deletions to every replica and backfill (`targets` in `collector.ml`).

## Where the code departs from the spec

- **The publish lock can starve the collector** (finding 133): it is taken by polling, so a busy
  import holding it shared can keep the collector's exclusive take waiting until it times out.
- **Integrity holds the whole tree before it reports** (finding 85).
- **Collection is refused while a remote copy would be told key by key.** `Collector.run` answers
  `Unsupported`, unless `keep`, when the collecting main owes deletions to a remote copy whose bucket
  function this owner has not confirmed.

## Learnings

- A read that falls back to F holds the publish lock shared. Without it a copy's delete job read a
  chunk from a shard its doom step had not yet emptied, skipped the delete and restored the chunk.
- A best-effort chunk forward can outlive a collection delete on the same copy: the delete takes every
  forward slot first (`without_forwards`).
- A settle that meets the collector's run lock retries (`settle_later`): the job's own attempt runs
  before its record completes, and the collector counts that record as owed.
- Settle never turns G while a run record is present (`Chunk_spaces.run_open`): a run suspended in
  closing still dooms under its odd generation (finding 25).
- A body that cannot be classified is not "no references". `Chunk_spaces.references` answers `Error`
  for a manifest with a malformed key, marking halts with the run left open, and the gate refuses the
  body (finding 3).
- The run lock and the publish lock are two files. A record lock is dropped by any close of its file
  in the process, so a `flock` taken and released on the run lock's file would release the run lock
  (finding 24). Record locks also merge within one process, which is why the in-process check-and-set
  comes first.
- `--verify` reads a promoted chunk with a positioned read, never a mapping: a block the disk cannot
  return fails the read and files a marker, where a mapping kills the process (pitfall A-7.4).
- A chunk is verified once per process (`Chunk_set`), and a resumed run verifies every chunk a unit
  names, since a promotion may precede the kill.
- The dry run holds its referenced set as packed 16-byte keys (`Chunk_set`), not a table of strings
  (finding 82).
- Domain names hold no `/`: keys are parsed by segment, never by searching for `/chunks/`.

## Resource choices (not normative)

- Marking reads one namespace at a time; the promotions of a namespace are made durable with one
  `fsync` per touched shard directory before its cursor is written.
- Copy deletions are recorded in batches of 1000 keys (`delete_batch`).
- The gate waits at most 30 s for the publish lock (`publish_wait`); a settle retries every 2 s while
  the run lock is held (`settle_retry`), one pending attempt per domain.
