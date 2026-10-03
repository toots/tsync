# Multi-store replication — OCaml implementation notes

Companion to the language-neutral spec [../../algorithms/replication.md](../../algorithms/replication.md).
Not normative. Finding numbers refer to [the 2026-10-01 review](../../../review/2026-10-01-rewrite.md).

## Code map

| Spec concept | Code |
|---|---|
| Roles, read order (§3.1) | `Composite.role`, `role_of_string`, `read_rank`, `in_read_order` (`lib/store/composite.ml`) |
| Configuration rules (§3.2) | domain validation in `lib/config/config.ml`: names unique ignoring case, no replica or backfill without a main; backends sorted by `read_rank` |
| Construction (§4.1) | `Composite.create`; `Composite.store` is the composite, `Composite.source` the mains alone, where copy jobs read (`make_store ~source_only`) |
| Job log, records (§3.3) | `Composite.job`, `record`, `encode_record`, `decode_record`; `<data_dir>/deferred-pending/<domain>/<escape_name>/`, run by an ordered `Dqueue` |
| Pending discards | `Discards`, at `<log dir>.discards/` |
| Write path (§4.2) | `put`, `put_if_absent`, `put_if_unchanged`, `write_all`, `fill`, `skip` |
| Accepting at a copy, submission | `submit`: the owner posts, any other process creates the record and calls `poke` |
| Chunk forward | `forward_chunk`, bounded by the copy's `forwards` semaphore (`max_forwards = 4`), `Store.Best_effort` |
| Running jobs (§4.3) | `run_job`, `run_job_body`, `sync`, `ensure_chunk`; three restarts when the referrer changed |
| Chunk memo (§4.4) | `Copy_memo` (`look`, `trusted`, `holds`, `note`, `learn_shard`, `forget`), its keys in a `Chunk_set` |
| Single runner (§4.5) | `Composite.start`, `rescan`, `rearm`, `pause`, `resume`, `settle`, called by `Engine` |
| Read path (§4.6) | `ask`, `walk`, `read`, `unreachable_of`; `compute_checksum` over the readable members only |
| Batches | `get_many`, `list_many` of the first readable member |
| Capabilities (§4.7) | the `capabilities` field built in `make_store`; `function_confirmed` |
| Verification requests | `Composite.queue_verification`, `Integrity.verify` (`lib/gc/integrity.ml`) |
| Deletions on copies outside the worker (§4.8) | the `Collection_delete` job, `without_forwards`, `check_discards`, `poll_discards`, `collection_owed`, `settle_generation`, `settle_later` |
| Bucket function probe | `Bucket_function`, `run_probe`, `probe_due`; a confirmation is saved at `<log dir>.function` |
| Write guard (§4.9) | `Composite.guard`, `probe_main` |
| Mirror (§4.10) | `Store_mirror.Make.mirror` (`lib/gc/store_mirror.ml`) |
| Integrity repair (§4.11) | `Integrity.Make`: `repair_chunks`, `repair_tree`; `Corruption_marker`; `Local.create ?verify_writes` |
| Degraded, status | `Composite.copy_stats`, `Composite.parked` |
| Tests | `tests/store/composite_test`, `copy_memo_test`, `tests/gc/queued_test`, `mirror_test`, `verify_test` |

The outgoing chunk space is not named here: `ensure_chunk` reads the plain chunk key from the source,
and the local driver falls back to it through `Chunk_spaces.read`
([gc](gc.md)).

## Where the code departs from the spec

- **A batch read of a member that is held down raises UNREACHABLE** (`batch_reachable`), where §4.6
  answers empty and sends each key back through `read`. Answering empty turned live folders into
  orphans in callers that took the batch as final (finding 26).
- **`fast_read` and `locality` are fixed from the first readable member** (finding 98), whatever
  member answers a read.
- **A forward's body is outside the chunk buffer budget** (finding 141): up to `max_forwards` bodies
  per copy stay alive beside the buffers the upload path counts.
- **Mirror lists whole areas on both sides** (findings 83, 149): `--path` builds every chunk key and
  probes each serially, and the chunk area is 4096 shard listings per side.
- **Concurrency is bounded per job, not per device** (finding 87): the copy job, the mirror and the
  upload path each have their own bound against one disk.

## Resource choices (not normative)

- Chunk forwards per copy: `max_forwards = 4`, taken with `Rt.Semaphore.try_acquire`, so the check and
  the take are one step.
- The memo holds 16 packed bytes per chunk (`Chunk_set`), and empties itself past its maximum together
  with its known shards.
- The mapped pages of a chunk are dropped once it is sent to a copy (`Fs.drop_mapped_pages`):
  [../memory.md](../memory.md) M.2.

## Learnings

- A job carries no body and reads the source when it runs, so order between logs, and a parked job run
  after later ones, converge on the mains' state.
- A chunk names nothing, whatever its bytes decode as: `sync` decides by the key (`Key.chunk_of`),
  never by parsing the body, and a copied chunk is hashed against its key first (`sound_chunk`), so a
  main's rotten chunk parks its copy instead of spreading (pitfall A-7.14; findings 63, 65).
- The memo is asked through a view taken after the source read (`Copy_memo.look`): a caller never
  learns whether a collection is in flight, and under an odd or unreadable G the view records nothing
  and presence is confirmed afresh.
- A discard request merged while a poll was reading it is not removed by that poll
  (`Discards.remove ~seen`, finding 61).
- The function probe uses a request name of its own run, and an unconfirmed probe is taken back on
  every path, also when the wait raises (finding 62, pitfall C-7.10).
- A deferred settle (`settle_later`) can outlive the case that started it and write under a scratch
  root being removed: tests remove their root with `Test_support.remove_root` (pitfall B-12.11).
