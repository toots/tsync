# 03 — Journal and sync: formats and interfaces — OCaml implementation notes

Companion to [../03-journal-sync.md](../03-journal-sync.md). Not normative. The protocol and the
conflict tables are mapped in [algorithms/wal-and-journal.md](algorithms/wal-and-journal.md) and
[algorithms/conflict-resolution.md](algorithms/conflict-resolution.md); the local formats in
[04-checkout-cache.md](04-checkout-cache.md).

## Code map

| Spec concept | Code |
|---|---|
| Client uuid, folder-id leases (§2.1) | `Identity` (`lib/checkout`): `client_uuid`, `minter`, `mint` |
| Entry key (§2.2) | `Entry_key`: `parse`, `make`, `of_time`, `month`, `compare`, `journal_key`; minting in `Entry_key.minter` / `mint` |
| Journal ops (§2.3) | `Op`: `to_json`, `of_json` (`None` for an unknown op, `Bad` for a known op with a bad field), `paths`, `encode_entry`, `decode_entry` |
| Journal entry, cursor (§2.4–2.5), the store seam (§3.1) | `Journal`: `list_entries`, `read_entry`, `entry_exists`, `write_entry`, `cursor_read`, `cursor_token`, `cursor_wait`, `note`, `bump`, `flush` |
| Last-sync mark (§2.6) | `Mark`: `read`, `write` |
| Applied log (§2.7, §3.2) | `Applied`: `load`, `note`, `contains`, `keys`, `head`, `since`, `prune` |
| WAL record (§2.8) | `Wal`: `encode`, `decode`, `is_metadata`, `puts_only`, `subject`, `carry_fids`; the log is `Dqueue.Records` over `<data_dir>/journal-pending/<domain>` |
| Conflicted-copy name (§2.9) | `Conflict.conflict_name`, picked free by `Local_ops.aside_name` |
| `PUBLISH` (§3.3) | `Outbound.publish_entry`, reached through `discharge` and `discharge_executed` |
| Replication engine (§3.4) | `Engine.Make`: `reconcile`, `apply_pass`, `apply_entry`, `rebuild`, `resync`, `unapplied`, `bridge`, `cannot_bridge` |
| Poller (§3.5) | `Engine.Make`: `poller`, `poll`, `wake_poller` |
| Outbound queues (§3.6) | two `Dqueue.t` over the one WAL, created in `Local_ops` (`uploads`, `metadata`), run by `Outbound.run_upload` and `run_metadata` |
| Conflict decisions (§3.7) | `Conflict`: `arrival`, `publish`, `clashed`, `publish_clashed`, `describe` |
| Fact gathering and enactment | arrival: `Engine.read_ahead`, `apply_op`; publish: `Outbound.publish_op` |
| Change feed over the applied log | `Engine.Make`: `cursor`, `changes_since`, `stamp_generation`, `prune_applied` |
| Parameters | `Outbound.horizon`, `list_slack`, `rekey_age`, `sweep`, `retry_floor`, `claim_settle`; `Journal.cursor_interval` |

`Engine.Make (C)` is one functor chain, each layer including the one below: `Local_ops` (local
state and file operations), `Outbound` (publishing and the queue runners), `Bulk`, `Import`,
`Rsync`, then `Engine` (arrival, passes, rebuild, start and drain). `Tsync_domain.Domain.engine`
applies it once per domain, in the owner.

## Departures from the spec

- **The mark is not part of the journal seam.** `mark_read` and `mark_write` are `Mark.read` and
  `Mark.write`, taking the data directory.
- **`rebuild_done` is not a separate operation.** `Engine.rebuild` notes the listed keys, moves the
  mark and reopens the gate itself.
- **A failed pass is retried after `retry_floor`**, with a log line each time (review finding
  145).
- **An upload waits for its dependencies by polling**, 5 times a second, re-reading metadata
  records (`Outbound.wait_dependencies`, review finding 143).
- **A store read can still happen under the metadata lock** during arrival, for an edit reached
  only through an owed rename of ours (review finding 52).
- **revive-ours publishes with no WAL record** (review finding 39).

## Learnings

- **`Entry_key.t` is a private string** whose only constructors are `parse`, `make` and `of_time`.
  `parse` takes the last `/` segment, so a listing path, a cursor body and an applied-log field all
  go through it; `journal_key` is the one function that spells the store key.
- **Ops are an ordinary closed variant** with record payloads (`Op.t`). `of_json` separates the
  two reader rules by type: `None` is an op to ignore, `Bad` makes the entry CORRUPT.
  `Wal.decode` turns both into "unparseable", so a record is never run with an op dropped, while
  `Applied` drops an undecodable op from its line.
- **The conflict tables are pure and printed whole.** `Conflict.arrival` and `Conflict.publish`
  are total functions over closed variants; `tests/sync/formats_test` prints every row to its
  `.expected` file, so a policy change shows as a diff.
- **Store answers are read ahead, then looked up under the lock.** `read_ahead` fills an `answers`
  record of hash tables; under `with_meta` a missing answer raises `Exit`, which `apply_entry`
  reports as a LOCAL failure, so the pass fails and retries instead of stepping the entry aside.
  Store work an enactment owes is queued with `defer` and run after the lock is released.
- **Failure policy is a match on `Fail.kind`.** In `apply_pass`: `Stop.Stopping` and
  `Rt.Cancelled` propagate; a retryable kind fails the pass; CORRUPT or INVALID on the read, and
  any other failure of the enactment, step the entry aside and hold the mark below it. A handler
  added on these paths changes policy.
- **The poller waits on three things at once**: `Journal.cursor_wait`, the poll signal and a
  `sweep` sleep, raced with `Rt.first ~detach:true`. Whether to list is then decided from the
  cursor token, the time of the last listing and the signal's version, never from which branch
  won.
- **One pass or rebuild at a time**: `pass_lock`, an `Rt.Fmutex`. The deferred list is a plain
  `ref` because only the holder touches it.
- **The catch-up gate carries an epoch.** `close_gate` counts link failures; a pass reads
  `gate_epoch` when it starts and `open_gate ~since` opens only if no failure came meanwhile, so a
  pass that began before an outage cannot let the queues publish after it.
- **Each piece of shared state has its own small lock.** The minter, the lease minter, the cursor
  debouncer (`pending`, `armed`, `last_publish`), the handled set and the stepped-aside table each
  sit behind a `Mutex`; flags are `Atomic`. The cursor put itself is serialised by an `Rt.Fmutex`,
  which a fiber may hold across the request.
- **The debouncer is one spawned fiber per armed interval.** `note` arms it under the mutex;
  the fiber sleeps, disarms and flushes. A failed flush is logged and dropped: the cursor is a
  hint.
- **The applied log appends with one `Fs.append_durable`** under the log's mutex, after the
  handled-set test, so a key is written at most once and the record is durable before `note`
  returns. The shard is the month of handling, read from the clock at each append.
- **Identity files are arbitrated by `Fs.create_if_absent`** (B-4.2). The lease minter records the
  pid it leased under and leases again when `getpid` differs (B-4.3).
- **Stale keys are replaced at EXECUTED.** `mark_executed` re-keys a record older than `rekey_age`
  with `Dqueue.Records.rekey` before writing the ops it will publish, in one durable update.
- **Scenario tests are snapshot tests** (`tests/sync/*_test.ml` against `<name>.expected`):
  `two_clients_test` applies `Engine.Make` twice over one local store in one process, each client
  with its own data and cache directories. Output is diffed, never matched by substring.
