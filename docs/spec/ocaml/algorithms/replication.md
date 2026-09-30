# Multi-store replication — OCaml implementation notes

Companion to the language-neutral spec [../../algorithms/replication.md](../../algorithms/replication.md). Source references are at commit `4c32fa96`.

## Code map

| Spec concept | Code |
|---|---|
| Roles, read order, configuration rules | `role = Main \| Replica \| Backfill \| ReadOnly`, `order_backends`, `validate_roles` (`lib/domain/config/parsing/conf_parsing.ml`) |
| Construction | `Domain.of_config` → `build_backends` → `Domain_store.make ~mains ~targets ~archives` (`lib/domain/config/domain/domain.ml`, `lib/backends/api/domain_store.ml`) |
| Source = mains only | `make ~mains ~targets:[] ~archives:[]` inside `Domain_store.make` |
| Write fan-out, fill, skip | `write`, `fill`, `D.skip` (`excluded = Stored_key.is_index_key`; journal prefix and cursor key when `reads_reach = false`) |
| Copy target, reads-reach bit | `Deferred.make ~reads_reach:(role = Replica)` (`lib/backends/api/deferred.ml`) |
| Job log, records | `Durable_queue.ordered` with `Records` at `<data_dir>/deferred-pending/<domain>/<escape name>/`, JSON `{"op":"put"\|"copy"\|"delete"\|"delete_multi",…}`; `escape` keeps `[A-Za-z0-9._-]` |
| Per-log claim lock | `lockf` on `<dir>.owner`, `claim`/`with_claim`/`release` (`lib/core/durable_queue.ml`) |
| In-memory cap, backoff, settle | `max_queued = 100_000`, `Retry.backoff ~base:0.5 ~cap:300.`, `default_settle_timeout = 60.` |
| Chunk forward | `forward_chunk`, `max_chunk_forwards` = `maxChunkBuffers` (32 when not given), `room_for` = the link admission's `try_admit` |
| Memo | `ensured`, `known_shards`, `max_ensured = 100_000`, `learn_shard` over `Chunk_layout.shard_prefix` |
| From-space fallback | `chunk_from_prefix` = `tsync/<d>/chunks.from/` |
| `chunk_names` | `chunk_keys` (manifest parse, `[]` otherwise) |
| Drop → degraded | `poison = Drop`, `Q.stats.degraded` |
| Read path | `read`, `walk`, `ask_member ?probing ~others`, `Health_wait.until_held` |
| Health | `Health` (`trip_after 2`, `trip_span 1.`, `hold_initial 30.`, `hold_max 300.`, `probe_timeout 10.`), `check → Up \| Held \| Probe` |
| Batches | `get_many`/`list_many` on the first readable member, `passed_over`, per-key `read` fallback |
| Write guard | `Write_guard.ensure`/`look`/`probe` on the cursor key (`lib/backends/api/write_guard.ml`) |
| Mirror | `tsync mirror`, `lib/domain/ops/mirror.ml` (`resync ?source ?scope`) |
| Verification, markers | local `verifyWrites`, `lambda/verify.py`, `verify_all` → `tsync/verify-jobs/<d>/<shard>`, markers at `tsync/corrupted/<d>/<shard>/<key>` |
| Integrity repair | `Integrity.repair` / `verify` / `follow` (`lib/domain/ops/integrity.ml`), `tsync data-integrity` |
| Collection on copies | `Gc.flush_close` (`discard` → `tsync/gc-jobs/<d>/<run>/<shard>`, or `delete_multi`), `orphans_in_shard` recheck (`lib/domain/ops/gc.ml`) |
| Resumer | daemon `resume = true`, `Domain.start_resumed` after fork (`launcher.ml`), `rescan_all` on the 60 s housekeeping sweep (`domain_engine.ml`) and the IPC `rescan` from `set_on_recorded` |
| Settle / drain | `Queues.register_settle chunks_quiet`, the `Domain_store` drain hook → `settle_all` |
| Tests | `tests/backends/{fallback,held_failover,main_down,deferred,deferred_shards,deferred_governed,backfill,write_guard,gc_targets,gc_queued}`, `tests/unit/queue_claim` |

## Where the current code differs from the spec

- **Jobs replay the operation, not the source's state.** `Job_put` reads the main and does nothing when the key is gone ("a later delete job says so"); `Job_delete` deletes unconditionally; `Job_copy` runs `Target.copy` and falls back to a rebuild of `dst` only on failure. Correctness then needs one global order of runs, which two processes (a one-shot command and the daemon each running their own records against one member) and two machines do not give: a command's `Delete(k)` can run after the daemon's later `Put(k)` has landed, leaving the copy without a key the main holds.
- **Multi-main writes.** All mains are written in order, then the copies are filled. A failure on a later main leaves earlier mains holding a write that no copy owes. `delete` returns "any main removed", not the first main's answer.
- **Permanent failures drop.** `poison = Drop` deletes the record and sets `degraded` in `Q.stats`, in memory only: the work is lost and a restart reports the copy healthy. The spec parks the record instead (degraded while parked).
- **Queue overflow drops.** Past `max_queued` in-memory jobs, new jobs are not recorded and the target is marked degraded.
- **`R5`: spurious drops under collection.** A `Put(manifest)` whose chunk the collection discarded after the manifest was overwritten fails Permanent "not found" and is dropped; there is no re-read of the referrer.
- **Collection deletes bypass the logs.** `Gc.flush_close` calls `discard` or `delete_multi` on each copy directly, after the main's shard was already discarded; nothing records the owed deletions durably, and nothing re-checks or restores.
- **The memo survives collections.** GC deletes chunks from copies directly (or through a queued discard), bypassing the worker; a long-lived process's `ensured` still lists them, and a later manifest job can skip the chunk and put the manifest without it. Nothing polls the run marker, and nothing restores a chunk re-referenced between GC's recheck and the copy's delete (or the discard's late consumption).
- **Capabilities** with the main held answer from the replica alone, chunk size included; `verified` merges only the members asked.
- **Duplicate member names** are accepted (findings G2): `build_backends` keys `traffic`, `admissions` and `built` by name, and two copies with one name share one log directory.
- **Mirror order.** `resync` copies whatever the listing yields, in listing order, so an interrupted member-to-member mirror can leave a manifest without its chunks. Mutable keys are compared by size only.
- **Android never resumes** (findings G7): `load_domain` builds with `resume = false`, which claims the logs and never rescans; records left by a killed app process are never replayed on the device.
- **Health windows use the wall clock** (`Health.now = Unix.gettimeofday`, findings G12).

## Resource choices (not normative, P6)

- Chunk forwards per copy: at most `maxChunkBuffers` (the chunk buffer budget, default 4 in config; 32 in `Deferred` when not given), since a forward keeps its body alive.
- Memo cap: `max_ensured = 100_000` keys, then a full reset of `ensured` and `known_shards` together.
- In-memory job window: `max_queued = 100_000` (today past it new jobs are dropped and the target degraded; the spec keeps them on disk).
- Mirror pools: copy = chunk buffer budget; probe = max(8, 4 × copy); in flight = 4 × probe; listings spooled to disk, chunks one batch of shards at a time.

## Runtime-independent learnings

- The chunk memo reset is all-or-nothing on purpose: resetting `ensured` without `known_shards` leaves a shard "known" whose keys were forgotten, and those keys are never relearnt.
- `Durable_queue.claim` merges in-process: two targets with the same log directory in one process do not detect each other. Refusing duplicate names at configuration is the only reliable guard.
- `deferred_shards` is the test that keeps the memo honest: 40 manifests × 4 chunks over 4 shards → 0 HEADs, 4 shard listings, 160 chunk puts; again under new names → 0/0/0.

## Lwt-specific learnings

- `forward_chunk` relies on `Lwt.async` running the spawned `put` synchronously up to the admission's `acquire`, so `room_for` (`try_admit`) and the take are atomic. A direct-style port needs the spec's single-step `try_acquire`.
- `ensured`, `known_shards`, `chunks_in_flight` and `running` are unguarded mutable state; `chunks_in_flight ≥ max` and the increment are one step only because nothing yields between them.
- A copy cut short by a stop stays owed: `Job_copy` re-raises `Shutdown.Stopping` instead of falling back to a rebuild (commit c3c4a983).
