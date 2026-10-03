# Retention and garbage collection — OCaml implementation notes

Companion to the language-neutral spec [../../algorithms/gc.md](../../algorithms/gc.md).

## Code map

| Spec concept | Code |
|---|---|
| Surviving space S, outgoing space F | `tsync/<D>/chunks/`, `tsync/<D>/chunks.from/` under the collectable main's root; only `Chunk_spaces` and `lib/gc` name F (`tests/store/gc_scoping` lists them) |
| Collectable (A1) | `Chunk_spaces.of_store`: a store with a `local_path` not on a network filesystem |
| Driver-scoped access (§5.8) | `Local.create` routes every chunk read, delete and listing through `Chunk_spaces.read`, `twins`, `list` |
| Reference classification | `Chunk_spaces.references`: the gate refuses exactly what marking halts on |
| Gate, publish lock, promote | `Chunk_spaces.gate`, `with_publish_lock` (`flock` on `gc-publish.lock`), `promote` + `sync_shards` |
| Run lock | `Chunk_spaces.with_run_lock`: in-process check-and-set, then `lockf F_TLOCK` on `gc-run.lock` |
| Run record R | `Gc_record` (typed; `reconciling` reads as closing) |
| Generation G | `Gc_generation`: `read`, `read_mains` (maximum over mains), `write`, `settle` |
| Every keep/delete decision | `Gc_plan` (pure; `tests/gc/plan_test`) |
| Phases, dry run | `Collector.run ?budget ?pause ?verify ?keep`, `Collector.dry_run` |
| Copy deletions, settling | `Composite.submit_collection_delete` (owner queue or inbox), `collection_owed`, `settle_later` |
| Copy presence memo | `Copy_memo`, which reads G itself |

## Lessons

- A read that falls back to F must hold the publish lock shared: under load, a copy's delete job
  running in the owner read a chunk from a shard its doom step had not yet emptied, skipped the
  delete and restored the chunk (`tests/gc/collector_test` under 10 concurrent instances: 2/10
  without the lock, 0/10 with it).
- A best-effort chunk forward can outlive a collection delete on the same copy; the delete takes every
  forward slot first.
- A settle that meets the collector's run lock must retry: the job's own attempt runs before its record
  completes, and the collector counts that record as owed, so neither would settle.
- Domain names hold no `/`: keys are parsed by segment. Searching for the last `/chunks/` raised for a
  domain named `chunks`.

## Gaps

- Queued discards (a copy with a bucket function) are not built: no driver supports `discard`.
- Crash tests stop at unit boundaries (`budget` 0), not inside a unit.

## Implementation notes for the spec's locks

- The run lock must stay a POSIX record lock (`lockf`/`fcntl`) on `gc-run.lock` so older collectors and
  newer ones exclude each other.
- The publish lock lives on its own file, `gc-publish.lock`: POSIX drops a process's record locks at
  any close of the file they lock, and macOS implements `flock` and `fcntl` on shared structures. An
  older writer's gate, which takes `flock` on `gc-run.lock`, is not excluded by a newer collector.
- `lockf` needs the file open for writing; `flock` works on any open descriptor.
- Record locks merge within one process, which is why the in-process check-and-set is needed at all.

## Tests

`tests/gc/plan_test` (every decision), `tests/gc/collector_test` (a local main and replica: survey,
run, stepping, a mid-run publication, abort, verify, halt, exclusion, the generation),
`tests/store/spaces_test` (the driver's scoping and the gate), `tests/store/gc_scoping`.

## Resource strategy (not normative)

- Marking reads one namespace at a time, sequentially; promotions of a namespace are made durable with
  one `fsync` per touched shard before its cursor is written.
- Copy deletions are recorded in batches of 1000 keys.
- The gate waits at most 30 s for the shared publish lock; a settle retries every 2 s while the run
  lock is held, one pending attempt per domain.
