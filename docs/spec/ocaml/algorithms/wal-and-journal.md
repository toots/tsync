# WAL and journal — OCaml implementation notes

Companion to the language-neutral spec [../../algorithms/wal-and-journal.md](../../algorithms/wal-and-journal.md).
Not normative. Formats and interfaces: [../03-journal-sync.md](../03-journal-sync.md). Finding numbers
refer to [the 2026-10-01 review](../../review/2026-10-01-rewrite.md).

## Where each abstraction lives

| Spec | Code (`lib/sync/`) |
|---|---|
| Entry key, minting | `Entry_key.t` (a private string), `parse`, `make`, `of_time`, `month`, `journal_key`; `Entry_key.minter`, `mint`, seeded in `local_ops.ml` from the WAL's ids, and in `Engine.start` from the applied log and the mark |
| Op vocabulary | `Op.t` (`Put` with `base`, `Delete`, `Mkdir`, `Rmdir`, `Rename`), `encode_entry`, `decode_entry` |
| Journal store, cursor | `Journal`: `list_entries`, `read_entry`, `entry_exists`, `write_entry`, `cursor_read`, `cursor_token`, `cursor_wait` |
| Cursor debouncer (§4.2) | `Journal.note`, `bump`, `flush`; `cursor_interval`; one `Journal.t` per domain in the owner |
| Last-sync mark | `Mark.read`, `Mark.write` (`<data_dir>/last-sync-<domain>`) |
| Applied log, change feed | `Applied`: `load`, `contains`, `note`, `head`, `since`, `prune`; `Engine.changes_since`, `prune_applied` |
| WAL record, states (§4.1) | `Wal.record` (`state`, `ops`, `priors`, `local_from`, `fids`, `last_error`), `Wal.encode`, `decode`; the log is a `Dqueue.Records` directory |
| Writer, metadata op | `record_intent`, `prepare`, `record_owed`, `with_intent`, `abandon` under `with_meta` (`local_ops.ml`) |
| Writer, content | `post_put` (`outbound.ml`), reached from `close` through `post_put_hook` |
| Metadata queue | `metadata` (ordered), `run_metadata`, `publish_op` (`outbound.ml`) |
| Upload queue | `uploads` (keyed, `max_uploads` workers), `run_upload`, `run_one_upload`, `publish_landed` |
| `MARK_EXECUTED`, re-keying | `mark_executed`, `is_stale`, `rekey_age`, `Dqueue.Records.rekey` |
| `PUBLISH` | `publish_entry`: `Applied.note`, `Journal.write_entry`, the change hook, `Journal.note`; `discharge`, `discharge_executed` |
| Rule 7, dependency wait | `depends_on`, `wait_dependencies` |
| Rule 9, catch-up gate | `wait_gate`, `open_gate`, `close_gate`, `gate_epoch`, `note_link_failure` |
| Poller, sweep (§4.3) | `poller`, `poll`, `wake_poller` (`engine.ml`); `Outbound.sweep`, `retry_floor` |
| Apply pass, step aside (§4.4) | `apply_pass`, `apply_entry`, `apply_op`; `stepped_aside`, `Engine.unapplied` |
| Reconcile (§4.7) | `Engine.start`: `recover_local`, `reconcile`, `rescan_logs`, `adopt_unrecorded`; the local redo is `redo` (`local_ops.ml`) |
| Bridge check, hold, rebuild (§4.8) | `cannot_bridge`, `hold`, `Engine.bridge`, `rebuild`, `resync`; `Outbound.horizon`, `list_slack` |
| Drain order | `Engine.drain`: metadata, uploads, `Journal.flush`, the copies |
| Batch puts | `Bulk.batches` (`bulk.ml`) |
| Tests | `tests/sync/` (`formats_test`, `recover_test`, `two_clients_test`, `offline_test`, `poller_retry_test`, `feed_test`, `legacy_entry_test`, `rebuild_race_test`) |

`Engine.Make` includes `Outbound.Make`, which includes `Local_ops.Make`: one functor application per
domain holds the WAL, both queues, the mirror, the staged tree and the cache.

## Where the code departs from the spec

- **Revive-ours publishes without a WAL record** (finding 39): see
  [conflict-resolution](conflict-resolution.md).
- **Store reads under the metadata lock remain on one path** (finding 52, rule 11): an edit reached
  only through an owed rename of ours.
- **The dependency wait polls** (finding 143). `wait_dependencies` re-reads the loaded metadata records
  every 0.2 s; behind a stuck head that is thousands of record reads a second across waiting uploads.
- **"Behind" leaves out own-id and below-mark entries** (finding 118, `lib/owner/report.ml`): status can
  report nothing behind while entries are due.
- **Each status call reads every WAL record** (finding 91, `Engine.activity`).
- **`rsync --move` can publish the source's delete before the destination's put** (finding 121).
- **Stepped-aside entries are kept in memory** (`stepped_aside`). They are found again by the first
  pass after a restart, since nothing noted them in the applied log.

## Learnings

- The mark is a time, not the newest key applied: `apply_pass` writes the pass start minus
  `list_slack`, bounded by the oldest entry it stepped aside, and only moves it forward.
- The applied log is the dedupe set, not the mark: an entry is due when it is inside the horizon and
  not in `Applied`. Own entries are noted before they are put, so the pass skips them by the same test.
- A pass that began before the last link failure does not reopen the gate (`gate_epoch`, finding 51).
- The poller's sweep is timed from the last listing, never from a wait's expiry, and a failed pass
  goes through the same classification as a queue job; the loop ends only on `Stop.Stopping`
  (finding 7).
- An EXECUTED record is never decided again: `run_metadata` and `reconcile` hand it to
  `discharge_executed`, which only asks whether the entry is there (finding 10).
- An INTENT record met by the metadata queue is redone under the metadata lock, which its creator
  holds until it prepares, before anything is published.
- A due entry that vanished between the listing and its read is evidence of pruning: the pass holds
  for a rebuild instead of skipping it.
- A rebuild's sweep spares what local work touched since the walk began (`note_touched`,
  `was_touched`): the walk runs for minutes against a mount that stays writable (finding 13).
- Only the fids `apply_op` reported go into the applied log: a peer's paths are not this client's
  (pitfall A-6.25).
