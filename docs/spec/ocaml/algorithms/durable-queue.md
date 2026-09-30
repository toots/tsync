# Durable queue and crash immunity — OCaml implementation notes

Companion to [../../algorithms/durable-queue.md](../../algorithms/durable-queue.md). Descriptive
notes about the tree at `4c32fa96`; the spec is normative.

## Spec → code

| Spec | Code |
|---|---|
| queue, records, claim, rescan, settle | `lib/core/durable_queue.ml` (`Records`, `Make.Make`, `claim`, `with_claim`, `rescan`, `settle_all`), `durable_queue_intf.ml` |
| scheduler binding; absent vs failed read | `lib/lwt/core/durable_queue_lwt.ml` (`Files.read_file`: `Body`, `Gone`, `Failed`) |
| record id | `%020Ld-%08d-%d` (µs, seq, pid); `list` keeps names starting with a digit |
| ordered / keyed | `Q.ordered` / `Q.keyed`; `put_back` (head vs tail); `take` (slot, `pending`, `cancel`) |
| failure classes | `Retry.classify`, `Retry.classify_in_order`, `Backend.classify`, `Shutdown.Stopping`, `Retry.Cancelled` |
| poison policies | `Durable_queue.Stop` (metadata, uploads), `Drop` (deferred) |
| upload queue | `lib/domain/sync/sync_queue.ml` (ENOENT or `Cancelled` ⇒ abandon) |
| metadata queue, parking, rearm | `lib/domain/sync/meta_queue.ml`; rearm via the "metadata retry" maintenance task |
| WAL log and hand-offs | `lib/domain/checkout/wal/wal.ml` (`Owed`, `log_for`, `discharge`, `list` filtered by client uuid) |
| reconcile, adoption | `lib/domain/sync/replay.ml` (`reconcile_record`, `resume_prepared`, `replay_unpublished`, `adopt_unrecorded`) |
| deferred job log | `lib/backends/api/deferred.ml` (`resumed_starts`, `start_resumed`, `on_recorded`, `post` vs `record`) |
| drain and stop | `Domain_engine.drain` (metadata queue, then uploads, raced against 0.8·grace; `flush_cursor`), `drain_for_stop` |
| one-shot drain | `Oneshot.run` → backend drain → `settle_all` |
| Android lifecycle | `android_jni.ml` `load_domain` (`resume = false`), `start_queue`, `run_maintenance`, no drain |
| Android share and ingest | `Ingest.kt` (`commit` fsyncs staging; `sweepOrphans` 24 h), `MainActivity.kt` share save |
| atomic write | `lib/local/io/fs.ml` `atomic_write`, `with_temp_rename` (no fsync) |
| import spool | `lib/domain/ops/import.ml` (`Skipped_exists` adds no op), `publish.ml` batches (2000 ops / 10 s) |

## Differences from the spec

- **No fsync** of records, their directory, staged data or the client uuid.
- **Claims.** Every runner `lockf`s `<dir>.owner` and runs anyway when another holds it; the WAL
  claim is checked by nobody (reconcile, `tsync sync` and the parent's 60 s metadata rearm read
  every record), so a `Prepared` metadata record can be published by two processes, in either
  order. `lockf` is released by any close of the file in the process.
- **Recorder/resumer roles.** Frontends only `record` deferred jobs and poke the parent; one-shot
  commands run their own posts; Android never resumes; a daemon-less machine leaves a timed-out
  command's records for nobody.
- **`MAX_QUEUED` drops posts** (100 000): the record is not written and the queue is marked
  degraded. The spec never drops for capacity.
- **Drop poison** for deferred jobs unlinks a permanently failing job; **Stop** parks, but upload
  records parked in a long-running process are never re-armed until restart.
- **Record update is not conditional**: a `note_failure` racing a completion in another process
  resurrects the record.
- **Unparseable records** are unlinked by `Records.list` (deferred) or decoded as an empty
  `Intent` (WAL).
- **Promotion precedes `Executed`**, so a crash between them completes the record without
  publishing (see [../04-checkout-cache.md](../04-checkout-cache.md) B.0.1).
- **Import** puts manifests before the batch's journal entry, and a re-run skips existing keys
  without re-emitting their ops: a kill between leaves manifests nobody announces.
- **Android share sheet** calls `finish()` before the commits run; a kill then loses the shared
  files, and the staging copies are swept after 24 h.
- **Camera backup** stores the pass-start MediaStore generation, so failed and unsettled photos
  are never retried.
- **Metadata `Executed`** keeps the original ops, not the as-published ones.

## Resource strategy (not normative)

- `MAX_QUEUED = 100 000` records per queue in memory; the current code refuses (drops) posts past
  it. A rewrite should keep records past the window on disk and load them in id order.
- Upload workers: `maxUploads` (config), keyed parallelism. Ordered queues use one worker, as
  the spec requires.
- `rescan` pokes are debounced at 0.5 s with a 1 s timeout.
