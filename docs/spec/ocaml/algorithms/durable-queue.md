# Durable queue and crash immunity — OCaml implementation notes

Companion to [../../algorithms/durable-queue.md](../../algorithms/durable-queue.md). Not normative.
Finding numbers refer to [the 2026-10-01 review](../../review/2026-10-01-rewrite.md).

## Spec → code

| Spec | Code |
|---|---|
| Primitives (§3.2) | `Fs.durable_replace`, `Fs.replace`, `Fs.create_if_absent`, `Fs.create_if_absent_locked`, `Fs.mkdir_p`, `Fs.append_durable`, `Fs.release`, `Fs.fsync_dir` (`lib/core/fs.ml`) |
| Log, record, id grammar (§4.1) | `Dqueue.Records` (`open_`, `create`, `read`, `update`, `replace`, `complete`, `list`), `Dqueue.valid_id`, `Dqueue.submission_id` (`lib/core/dqueue.ml`) |
| Set aside, R6 | `Records.set_aside`, `Records.set_aside_records`; a record that cannot be read stays in place and is retried (`decode_record`, `` `Unreadable ``) |
| Submission, hold, release order (§4.2) | `Records.create`, `Records.create_held`, `Records.hold`, `Records.is_held`; `Dqueue.rescan` skips a held record and every later one of the same pid |
| Re-key of an adopted WAL record | `Records.rekey`, the `rekey` argument of `Dqueue.start` and `rescan` (`Engine.rescan_logs` mints an entry key) |
| `post`, `adopt`, `update`, `complete` (§4.3) | `Dqueue.post`, `adopt`, `Records.update`, `Records.complete` |
| Ordered and keyed queues (§4.5) | `Dqueue.create ~ordered`; `ordered_worker`, `keyed_worker`, coalescing in `take` |
| Outcomes (§4.6) | `run_one`, `failed`; `Rt.Cancelled` completes, `Stop.Stopping` leaves the record, `Fail.retryable` decides retry or park; `Dqueue.backoff` |
| Parking, re-arm (§4.7) | `Dqueue.parked`, `Dqueue.rearm`, `rearm_interval`; `Engine.rearm` from the owner's `housekeeping` (`lib/owner/owner.ml`) and from the retry request |
| Settle, pause (§4.8) | `Dqueue.settle`, `settle_timeout`, `pause`, `resume`; `Engine.drain`, `Composite.settle` |
| Job kind | `'job Dqueue.kind` (`decode`, `encode`, `key`, `note`, `accepts`); two queues share the WAL through `accepts` |
| The logs of a domain | the WAL with its `uploads` (keyed) and `metadata` (ordered) queues (`lib/sync/local_ops.ml`), `claims` (`lib/sync/outbound.ml`), one copy log per replica or backfill (`lib/store/composite.ml`), pending discards (`lib/store/discards.ml`) |
| Start and recovery | `Engine.start`: `recover_local`, `Dqueue.start`, `reconcile`, `rescan_logs`, `adopt_unrecorded` |
| Bulk publisher (§7.3) | `Bulk.batches` (`lib/sync/bulk.ml`): a record held from birth, rewritten to the ops whose store half happened, then adopted |
| Non-owner submitter | `Composite.create ~owner:false`: `submit` creates the record and calls `poke` |
| Tests | `tests/unit/dqueue_test`, `dqueue_raise_test`, `tests/sync/recover_test`, `tests/gc/queued_test` |

## Departures from the spec

- **Every record is loaded.** `post` and `rescan` take each record into memory; nothing stays on disk
  past a window (§4.4 leaves this to the implementation). `loaded`, `order` and `ready` are lists, so a
  backlog of hundreds of thousands of records makes start-up and each rescan quadratic (finding 90).
- **The `claims` queue is not re-armed while the owner runs.** `Engine.rearm` covers the upload,
  metadata and copy queues only (§4.7 asks it of every queue).
- **A keyed queue retries UNEXPLAINED at the tail** (`failed`), as failure-model §7.1 asks; the outcome
  table of §4.6 lists it as non-retryable.
- **`settle` polls.** It samples the queue every 50 ms instead of waiting on a condition; a
  cancellation ends it.
- **No watchdog per queue** (finding 43). Status counts retrying and parked records; a queue whose
  worker waits at a closed gate looks like one that is working.
- **A first write's body is not fsynced before its staged manifest names it** (finding 20, rule R2).
- **A failed local half is not rolled back** (finding 108): `delete` drops the staged edit before the
  mirror removal, and an I/O error in between leaves the old content visible.
- **Revive-ours publishes without a record** (finding 39): see
  [conflict-resolution](conflict-resolution.md).

## Learnings

- Only `Stop.Stopping` ends a worker. A read error on a record (`EMFILE`, `EIO`) is an outcome like any
  other: the ordered worker backs off at the head, the keyed worker requeues the key (finding 8).
- Under a stop, `settle` returns once no job is running, and a worker takes no other: the running job
  finishes within the grace `Engine.drain` gives it, and the next record is not started (finding 123).
- A keyed slot is finished exactly once, in a `Fun.protect`, on every path out of a run
  (pitfall C-7.10).
- A descriptor that holds a record's lock is the caller's only once the lock is taken: `Records.hold`
  closes it on every failure (pitfall C-7.10).
- A held record is rewritten before its hold is released, never after: a rescan between the two would
  adopt the full record (`Bulk.batches`).
- A retried record is superseded when a newer job for its key arrived meanwhile; its record is completed
  then, and a record left behind is adopted again by the next rescan.
- `Records.update` never resurrects a record completed meanwhile; both run under the record's mutex.
