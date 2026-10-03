# WAL and journal — OCaml implementation notes

Companion to the language-neutral spec [../../algorithms/wal-and-journal.md](../../algorithms/wal-and-journal.md).
See [../README.md](../README.md) for how these notes are organised. Formats and interfaces:
[../03-journal-sync.md](../03-journal-sync.md).

## 1. Where each abstraction lives

| Abstract | OCaml |
|---|---|
| entry key | `Journal.Entry_key.t` `{ms; client_uuid}` (`lib/domain/journal/journal.ml`), printed `%013Ld-<uuid>`; `of_string` is the only constructor |
| op vocabulary | `Journal.op` (`` `Put | `Delete | `Mkdir | `Rmdir | `Rename ``), `to_json`/`of_json`, NDJSON `encode`/`decode` |
| journal store seam | `File_store` (`lib/domain/remote/store/file_store/`), host binding `file_store_lwt.ml`; `journal_key` is the only function producing an entry's store key |
| `PUBLISH` | `file_store_lwt.ml` `write_journal_entry` (applied-log `note`, put, `Change_notice.send`), `note_local` for rebuild findings |
| cursor debouncer | `file_store.ml` `note_cursor`/`bump_cursor`/`flush_cursor`, `cursor_flush_interval = 2 s`, state in a global table keyed by cursor object |
| last-sync mark | `read/write_last_sync_key`, `<data_dir>/last-sync-<domain>` |
| applied log | `Applied_entries` (`note`, `since`, `head`, `keys`, `prune`), `keep_days = 30` |
| WAL | `Wal` (`record`, `advance`, `note_failure`, `update_ops`, `complete`, `discharge`, `list`, `owed_metadata`); hand-off `Wal.Owed` |
| metadata queue | `Meta_queue` (ordered durable queue, `Retry.classify_in_order`, poison `Stop`, `parked`, `rearm`) |
| upload queue | `Sync_queue` (keyed pool, `workers = max 1 max_uploads`) |
| poller | `Sync_poller` (`sync_once`, `start`, `sweep_interval = 60 s`, `retry_floor = 2 s`, `held_tick = 0.2 s`) |
| apply pass, handled set, step aside | `Replay.apply_foreign`, `handled_set`, `stepped_aside` (per domain), `unapplied` |
| reconcile | `Replay.reconcile` (`finish_executed`, `resume_prepared`, `replay_unpublished`, `overridden_since`, `adopt_unrecorded`) |
| bridge check, rebuild | `Entry_key.cannot_bridge`, `Resync.run` (`tsync sync [--full]`), `refuse_if_metadata_owed`, `Replay.mark_handled` |
| host wiring | `lib/lwt/domain/sync/sync_lwt.ml`; converge in `Domain_engine.converge` |

## 2. Implementation choices (not spec)

- Upload width is `maxUploads` (default 4); the metadata queue has one worker.
- Reconcile's journal reads (`overridden_since`) are bounded by `Bounded.create ~max:32`, created
  at module scope so overlapping recoveries share one bound.
- Import batches puts into entries of 2000 ops or 10 s; a rebuild reports its findings through
  `note_local` every 64 ops.
- `Applied_entries.prune` is called daily with `keep_bytes = 64 MiB`.
- The applied-log `since` reads shards newest first until it finds the anchor's shard, so its cost
  is proportional to what follows the anchor; `head` reads an 8 KiB tail and the whole shard only
  when the tail holds no complete line.
- Shutdown races the queue drain against 0.8 × grace so the cursor flush still runs.

## 3. Where the code at the spec snapshot differs from the spec

- **No bridge check in the owner.** Only `tsync sync` calls `cannot_bridge`, and only with the
  "oldest key newer than the mark" condition; an empty journal counts as unbridgeable. The poller
  never enters `hold`, has no check for listed entries hidden by the horizon (B2), and a client
  stopped longer than 30 days skips unpruned entries older than the horizon.
- **Mark semantics.** The mark is the newest key applied (before month sharding it was written as `journal_prefix ^ key`) (moved forward per entry, including past
  entries that failed to read), not the pass start bounded by the oldest unhandled entry.
- **Applied-log prune** drops shards by mtime or by the 64 MiB byte cap, folding newest first; it
  can drop the newest shard or shards inside the horizon.
- **Handled set** is loaded once per functor application; `tsync sync` beside a daemon has its own.
- **`get_journal_entry`** turns every error into `None`; the pass then skips the entry without
  stepping it aside and still advances the mark. `overridden_since` has the same hole.
- **Own entries** (`client_uuid = mine`) are skipped by the pass rather than deduplicated by the
  handled set.
- **EXECUTED keeps the original ops**; `Meta_queue` publishes the rewritten ops (`as_published`), so a
  crash between the two makes reconcile publish the originals.
- **Promotion window.** An upload promotes before `Wal.discharge` advances to Executed; a crash in
  between leaves a Prepared record with no staged edit, which reconcile completes without publishing.
- **Upload into a folder whose mkdir is owed**: the upload claims the folder's marker itself
  instead of waiting for the mkdir record to publish.
- **No `base`** field is written in put ops or read from them, and the view does not record whether
  this client wrote it.
- **No re-keying** of stale records and no catch-up gate; no ordering between an upload and an
  earlier unpublished rename of its path.
- **Key minting** is monotonic per process only (`last_ms`), not initialised from used keys; any
  process sharing the uuid mints.
- **Duplicate applied-log lines**: a record noted and then failing its put is noted again on retry.
- **Mixed records** fall through to `replay_unpublished`; INTENT non-metadata records use
  `overridden_since` to drop ops a peer touched later.
- **No fsync** of WAL records or applied-log appends.
