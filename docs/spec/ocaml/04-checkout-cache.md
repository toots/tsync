# 04 — Checkout: local formats and the file-operation interface — OCaml implementation notes

Companion to [../04-checkout-cache.md](../04-checkout-cache.md). Not normative. Related notes:
[data-model/local-cache.md](data-model/local-cache.md),
[algorithms/read-path-and-cache.md](algorithms/read-path-and-cache.md),
[algorithms/durable-queue.md](algorithms/durable-queue.md), [memory.md](memory.md).

## Code map

`Local_ops`, `Outbound` and `Engine` below are layers of the one functor `Engine.Make`
([03-journal-sync.md](03-journal-sync.md)); `Mirror`, `Staged`, `Cache` and `Identity` are
`lib/checkout`.

| Spec concept | Code |
|---|---|
| Layout, escaping, internal leaves (§2.1) | `Mirror.path`, `Staged.manifest_path` / `body_path` / `whole_path`, `Cache.whole_path`; `Names.escape`, `escape_path`, `is_internal_local`, `is_temp_name` |
| `per`, group, group key (§2.2) | `Cache.per`, `group_of`, `groups`, `group_index`, `group_key` |
| File entry, own marker (§2.3) | `Mirror`: `file`, `manifest`, `write_file`, `remove_file`, `move_file`, `is_own` |
| File-id marker and index | `Mirror`: `file_id`, `ensure_file_id`, `path_of_file_id`, `load_file_ids`, `save_file_ids`, `await_file_ids`, `backfill_file_ids` |
| Pull marker, view hold | `Engine`: `pulled_at`, `view_hold`, `hold_views` |
| Folder entry, folder-id index (§2.4, §4.9) | `Mirror`: `folder_id`, `record_folder`, `mkdir_without_id`, `remove_folder`, `move_folder`, `lookup_id_removed`, `key_of_id`, `whereabouts`, `forget_subtree`, `rebuild_index`, `sweep_removed_records` |
| Staged manifest (§2.5) | `Staged`: `encode`, `decode`, `read`, `write`, `remove`, `move`, `fold`, `edits`, `set_aside_path` |
| Staged bodies (§2.6) | `Staged`: `new_body_id`, `open_body`, `read_body`, `write_body_at`, `body_size`, `body_links` |
| Cache files (§2.7) | `Cache`: `ensure_whole`, `read_piece`, `verified_member`, `pin`, `unpin`, `evict`, `adopt_body`, `sweep_at_start`, `enforce_cap` |
| WAL record (§2.8) | `Wal`; the log is `Dqueue.Records` |
| Pending claim confirmation (§2.9) | `Outbound`: `claim_kind`, `claim_queue`, `record_claim`, `run_claim` |
| File-operation interface (§3.4) | `Engine_intf.S`, implemented by `Local_ops.Make` |
| Metadata lock, key locks, edit generation (§3.2) | `Local_ops`: `with_meta`, `with_key`, `with_keys`, `generation`, `bump`, over `Keyed_locks` |
| Read handles, retention (§3.3) | `Local_ops`: `open_read`, `read`, `close_read`, `retain`, `release`, `end_lineage`, `move_handles` |
| Resolution (§4.2) | `Local_ops.resolve` |
| Staged writes (§4.3) | `Local_ops`: `staged_for`, `ensure_group`, `write`, `truncate`, `create`, `write_whole`, `write_edit`, `release_unnamed`, `read_staged` |
| Sync and close (§4.4) | `Local_ops.sync`, `close`; the record is posted by `Outbound.post_put` |
| Namespace operations (§4.5) | `Local_ops`: `delete`, `mkdir`, `rmdir`, `rename`, `symlink`; the WAL sequence is `with_intent` (`record_intent`, `prepare`, `abandon`); the redo is `redo` |
| Upload and commit (§4.6) | `Outbound.run_upload`, `run_one_upload`; `Engine.revert` |
| Promotion, hand-over to the cache (§4.7–4.8) | `Local_ops.promote`, `Cache.adopt_body` |
| Full tree: record and sweep (§3.5) | inside `Engine.rebuild` |
| Lazy tree: pull | `Engine`: `pull`, `pull_folder`, `refresh_file` |
| Stat, availability (§3.6) | `Local_ops.stat`, `availability`; `Cache.availability`, `Cache.resident` |
| Owner start (§4.10) | `Engine.start`: `recover_local`, `reconcile`, `adopt_unrecorded` |
| Maintenance (§4.11) | `Engine`: `trim_cache`, `prune_applied`, `daily_maintenance`; `Export.sweep_records` |

## Departures from the spec

- **Mirror entries are read, not mapped.** `Mirror.file` reads the entry into a string and decodes
  it (`Manifest.decode`); §2.3 recommends a read-only mapping.
- **No `STEP_DEADLINE`.** The manifest put that `run_one_upload` makes under the key lock is bounded
  only by the store's own deadlines and retries. The one deadline in this layer is
  `Cache.read_deadline`.
- **`revert` holds both locks across the store.** `Engine.revert` calls `R.revert`, which snapshots
  the current version and puts the manifest, inside `with_meta` and `with_key` (§3.2 rule 3).
- **Promotion ends the lineage.** `promote` calls `end_lineage` before it removes the staged
  manifest, so a handle open across a promotion keeps reading the edit as it was, and holds its
  bodies until it closes. A later write is not visible through that handle (§3.3).
- **A write's manifest is not durable.** `write_edit` replaces the staged manifest without a
  directory fsync when no body goes away; the bodies and the manifest become durable at `sync`
  and `close` (review finding 20).
- **`create` takes the key lock only**, so it can race a `mkdir` of the same name (review finding
  120).
- **A local half that fails after discarding state is abandoned** as it stands (review finding
  108). A reader that resolved a whole body can lose it to the split of a first write (review
  finding 109).
- **The rebuild sweeps by what the walk saw, not by mtime.** `Engine.rebuild` removes every entry
  whose path the walk did not yield, sparing paths changed during the walk (`was_touched`) and
  files with a staged edit. There is no `record` / `sweep_stale(cutoff)` pair.
- **Owner start lists every cache shard** before it serves (`Cache.sweep_at_start`, review finding
  88); dead temporaries are swept behind the start.
- **The cache cap** runs on housekeeping passes but does not count growth between them (review
  finding 34), and counts an in-flight fetch's
  temporary as a body (review finding 135). An eviction can be undone by a fetch in flight (review
  finding 134).
- **Prefetch** is spawned per sequential read for the current and the next group, uncapped per
  handle, and recomputes the file's groups each time (review findings 35 and 80).

## Learnings

- **The commit record is a constructor argument.** `Staged.state = Owed | Committed of
  Manifest.t`: a Committed edit always carries the manifest its upload stored, and every mutation
  in `Local_ops` writes `state = Owed`.
- **Any file of the staged tree that decodes is an edit, whatever its name**; `Staged.fold`
  yields the rest as `` `Bad ``. The set-aside prefix is an internal leaf, so no user name escapes
  to it (A-1.9). `recover_local` reads a bad manifest's bytes before renaming it: its bodies are
  named from those bytes.
- **`with_meta` is reentrant by holder identity** (`Rt.self`, `Rt.same`), so a request handler
  resolves a reference and acts on it in one hold (`Engine_intf.S.atomically`). A wait or a hold
  longer than 2 s is logged with the call stack (A-2.5).
- **Lock order is in the helpers.** `with_keys` sorts and deduplicates its paths, and namespace
  operations take `with_key` inside `with_meta`. `Keyed_locks` drops the entry of a key nobody holds, waits
  for or ever bumped, so a walk locking every path leaves nothing behind.
- **Body release is reference-counted against ended lineages.** `end_lineage` freezes every open
  handle of a path and counts its bodies in `body_refs`, in one hold of `handles_m`;
  `release_body` on a counted body records it in `deferred_release`, and `close_read` releases it
  when the count reaches zero.
- **Bodies made for an edit are released if the edit is never written.** `with_new_bodies`
  collects the bodies its function registers and, on an exception, releases those the staged
  manifest on disk does not name (C-7.10).
- **Bodies before manifest before release.** `write_edit` fsyncs the bodies, replaces the manifest
  durably, then releases the bodies the new manifest does not name; `promote` hands bodies to the cache, writes the
  mirror entry, removes the staged manifest, and releases bodies last.
- **`close` posts through a forward reference.** `Local_ops.post_put_hook` is a `ref` that
  `Outbound` sets to `post_put`, because the layer that owns `close` is included by the layer
  that owns the queues. A close without a write since the last one posts nothing (`dirty`).
- **The upload commits on an unchanged generation.** `run_one_upload` reads the edit and its
  generation under the key lock, uploads chunks without it, and under the lock again fails
  `Rt.Cancelled` if the generation moved or the job was cancelled.
- **The file-id index is a state machine**: `Unbuilt | Building | Ready | Saved`. Marker changes
  made during a build are queued and applied when it completes; the first change after a snapshot
  was saved removes the snapshot; a failed build returns to `Unbuilt` (A-11.19).
- **A bulk pass writes without a fsync each.** `Mirror` writes take `~durable:false`; the rebuild
  then calls `Fs.syncfs` once on the mirror root, before the applied log and the mark claim the
  result. A non-durable write still fsyncs its data, so an entry is never torn (B-1.12).
- **A reader's deadline does not cancel the fetch.** `Cache.within_deadline` runs the work in a
  spawned fiber resolving a promise; the reader waits on the promise with `Rt.with_timeout` and
  fails DEADLINE, and the fetch lands for the next reader.
- **Cache group state is kept only while it says something.** `Cache.using` drops a group's entry
  once nobody uses it and it holds no interval; a generation is never repeated, so a state made
  again is not taken for the one dropped.
- **`await_upload` polls** every 0.1 s until the staged edit is gone, the domain is paused or a
  record naming the path is retrying or parked (a `ponytail:` comment names a per-key signal as
  the upgrade).
