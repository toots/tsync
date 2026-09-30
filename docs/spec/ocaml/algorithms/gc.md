# Retention and garbage collection — OCaml implementation notes

Companion to the language-neutral spec [../../algorithms/gc.md](../../algorithms/gc.md). Source
references are at commit `4c32fa96`.

## Code map

| Spec concept | Code |
|---|---|
| Surviving space S | `tsync/<D>/chunks/<sss>/<key>` on the first `Main` member with `local_path` (`Chunk_layout.key`) |
| Outgoing space F | `tsync/<D>/chunks.from/<sss>/<key>` (`L.from_prefix`, `L.from_key`) |
| Run record R | `Collection.read_run` / `write_run` / `clear_run`, written to the main directly (`marker_store`) — `lib/domain/remote/store/gc/collection.ml` |
| Run lock | `lockf F_TLOCK` on `tsync/<D>/gc-run.lock` plus the in-process `held` flag — `lib/domain/ops/gc.ml` `take_lock` |
| Namespace tags | `m/<id>`, `v/<id>` from `readdir` of `manifests/` and `versions/` — `gc.ml` `namespaces`, `encode`, `decode` |
| Directory prefix with trailing separator | `prefix_of_namespace` |
| Chunks named by a body | `referenced_chunks` (reads through the composite `B.get`; any failure aborts) |
| promote | `Collection.promote` (rename, `ensure_parent`, retry once; result ignored by writers) |
| Writer duty (today's substitute for the gate) | `Collection.promote_all`, called by `Remote.publish` before `St.put_manifest` |
| Two-space reads | `Collection.head` / `get` / `get_range`, `candidates`, `missed` |
| Writer memo | `Chunk_store.Dedup` (process lifetime, `max_known` 100 000, cleared at cap) |
| Start and phase dispatch | `Gc.start` |
| Marking | `mark_one`, `mark_root`, `step` |
| verify_promoted | `gc.ml` (main only; `Corruption_marker`) |
| Closing | `begin_closing`, `orphans_in_shard`, `close_batch` (`delete_batch` = `Batch.per_delete` = 1000, `checkpoint_interval` = 5 s), `flush_close` |
| Finish, abandoning | `discard_from_space`, `finish`, `carry_over`, `push_down`, `move_across`, `keep_one`, `abort` |
| Parameters | `run ?budget ?(units=256) ?pause ?concurrency ?delete_batch ?keep ?verify`; concurrency from `caps.max_concurrency`, default 8 |
| Discard requests | `Backend.discard` → `tsync/gc-jobs/<D>/<run>/<last shard>`; `outstanding`, `retry_outstanding`; bucket side `run_gc_job`, `may_delete` in `lambda/verify.py` |
| Copies | `Backend.deferred` = replica ∪ backfill; `Backend.main` = first `Main` only |
| Copy fill from F | `Deferred.source_body` with `chunk_from_prefix`; `ensured` memo (100 000) — `lib/backends/api/deferred.ml` |
| Retention | `Retention.expire`, `purge_trashed`, `still_trashed`, `collect_namespace` — `lib/domain/ops/retention.ml` |

## Where the current code differs from the spec

The spec's interlock (a gate in the collectable main's driver, a publish lock, per-shard doom steps,
deletes routed through copies' job logs, the memo horizon) is not implemented. What exists instead, and
the gaps it leaves:

- **Writer duty checked once, before the put.** `promote_all` reads R, and if absent promotes nothing;
  a run opening between that read and `put_manifest` lets closing reclaim a deduplicated chunk (a
  millisecond window, wider under retries). No lock is shared between writers and the collector.
- **Proxy writers promote nothing.** `promote` needs `local_path`, which an http-proxy member lacks, and
  the http-proxy server's `Put` is a plain put. A chunk remembered by a remote writer's dedup memo and
  moved to F by the open is reclaimed if its new manifest lands in a namespace already marked or created
  after enumeration. The server's raw `get`/`head` of `chunks/…` also do not look in F, so remote
  clients cannot read chunks not yet marked during a run.
- **Promotion races closing.** Closing decides "doomed" by `head` in S, then deletes on copies, then
  unlinks F. A promotion landing after the lookup keeps the chunk on the main while copies are told to
  delete it; one landing after the unlink finds nothing, and the writer ignores the `false`.
- **Memos outlive a run.** The dedup memo and inherited `Stored` chunks are trusted forever; after a
  completed run deleted a chunk, a later publish from the memo names a chunk that exists nowhere.
- **Other publishing paths.** `Store.copy_manifest` (file rename), rsync `Rename_in_domain`, the
  `Republish_here` re-publish, `revert`, and version snapshots make references visible without
  promoting. A cross-folder rename during marking with versioning off can move the only reference from
  an unmarked namespace into a marked one.
- **Copies.** Queued discard requests are applied whenever the bucket function runs, without re-check;
  direct deletes by the collector do not invalidate the daemon's `ensured` memo.
- **Unreadable R** reads as idle for `promote_all` (parse-based) but as open for lookups
  (presence-based).
- **A vanished manifest aborts marking** (`B.get` fails on a listed key), leaving the run open.
- **Exclusion.** `take_lock` checks `held`, awaits the lock file, and only then sets `held`, so two
  sessions in one process could both pass (record locks merge within a process). Only `tsync gc` drives
  a collection today, once per process. The lock file is on the main's filesystem, so two hosts sharing
  it over a network filesystem are not excluded.
- **Only the first main is collected**; a domain whose first main is remote is refused even when a later
  main is local; other mains are never told deletes.
- **Trash purge** checks "still trashed" once, then deletes the subtree; a restore in between is deleted
  with it.

## Implementation notes for the spec's locks

- The run lock must stay a POSIX record lock (`lockf`/`fcntl`) on `gc-run.lock` so older collectors and
  newer ones exclude each other.
- The publish lock must not conflict with it. On Linux, `flock` locks and `fcntl` record locks are
  independent, so `flock(LOCK_SH)` / `flock(LOCK_EX)` on the same file gives a reader/writer lock that an
  older collector's `lockf` neither blocks nor is blocked by. Verify the independence on each target
  kernel (BSD-derived systems implement both on shared structures) before relying on it there; a byte
  range of the same file under `fcntl` is not an option, because an older collector's `lockf(0)` locks
  the whole file.
- `lockf` needs the file open for writing; `flock` works on any open descriptor.
- Record locks merge within one process, which is why the in-process check-and-set is needed at all.

## Tests today

`tests/scenario/gc`, `tests/scenario/expire`, `tests/backends/gc_cost`, `gc_targets`, `gc_queued`,
`tests/unit/gc_job`, `tests/unit/chunk_space`, `tests/content/promote_race`. None covers the races
above.

## Resource strategy (not normative)

- `concurrency`: the store's `caps.max_concurrency` (default 8, clamped ≥ 1), overridable; it sizes two
  pools, `unit_slots` (manifests) and `item_slots` (chunks within a manifest). One shared pool deadlocked
  when every slot held a manifest waiting for a chunk slot; with both at width *w*, the peak is *w²*
  chunk operations.
- `units` per step: 256 namespaces or shards between budget and pause checks.
- Readers cache "is a run open" for 5 s (`order_ttl`); a miss always re-reads the marker.
- Copy deletions: the spec now routes them through the owner's durable records and the restore check
  of replication §4.8; the current code calls `discard` / `delete_multi` directly from `flush_close`,
  after `Write_guard.ensure`, with no durable record and no restore check.
- The collection generation (`tsync/<D>/gc-generation`, and `generation` in the run record) does not
  exist in the current code. `Collection.of_string` ignores unknown fields, so today's binaries read a
  new-format run record fine; they never read or write the generation object.
