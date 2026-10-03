# Local state of one client for one domain — OCaml implementation notes

Companion to [../../data-model/local-cache.md](../../data-model/local-cache.md). Not normative. The
formats and operations are mapped in [../04-checkout-cache.md](../04-checkout-cache.md) and
[../03-journal-sync.md](../03-journal-sync.md).

## Code map

`<C>` = `<cache_root>/<domain>` (`Mirror.root`), `<D>` = `<data_dir>`.

| Entity | Representation | Code |
|---|---|---|
| Owner, ownership lock (§2) | `Paths.ownership_lock`, a `flock` | `Owner.acquire`, `release`, `holder` (`lib/owner`) |
| File entry, own and file-id markers (§3.1) | `<C>/manifests/<escaped path>`, `.tsync-own-<hex16>`, `.tsync-fid-<hex16>` | `Mirror` |
| Folder entry, folder and name markers | a directory, `.tsync-dir`, `.tsync-name` | `Mirror`; marker JSON by `Folder` |
| File-id index snapshot and record | `<C>/file-ids-index`, `<C>/file-ids-complete` | `Mirror.save_file_ids`, `load_file_ids`, `backfill_file_ids` |
| Pull marker, view hold (lazy tree) | `.tsync-pulled`, `.tsync-view-hold` in the folder | `Engine`: `pulled_at`, `view_hold`, `hold_views` |
| Reverse entry, removed-id record (§3.2) | `<C>/folders/<id>`, `<C>/folders/by-path/<md5>` | `Mirror`: `key_of_id`, `lookup_id_removed`, `whereabouts`, `rebuild_index`, `sweep_removed_records` |
| Cache body, partial body, pin (§3.3, §3.4) | `<C>/chunks/<shard>/<group key>`, `.partial`, `.pin` | `Cache` |
| Staged manifest, set-aside (§3.5) | `<C>/staged/manifests/<escaped path>`, `.tsync-bad-…` | `Staged` |
| Staged bodies | `<C>/staged/chunks/<id>`, `<C>/staged/whole/<id>` | `Staged`: `open_body`, `read_body`, `body_links` |
| WAL record (§3.6) | `<D>/journal-pending/<domain>/<entry key>` | `Wal`; `Dqueue.Records`; the two queues in `Local_ops` |
| Deferred job logs (§3.7) | `<D>/deferred-pending/<domain>/<escaped member>/`, and `.discards/` beside it | `Composite`, `Discards` (`lib/store`) |
| Applied log (§3.8) | `<C>/applied/<YYYY-MM>.log` | `Applied` |
| Last-sync mark (§3.9) | `<D>/last-sync-<domain>` | `Mark` |
| Resync generation, feed watermark, dropped-shard record | `<D>/resync-<domain>`, `<D>/feed-watermark-<domain>`, `<D>/feed-dropped-<domain>` | `Engine`: `resync_generation`, `stamp_generation`, `cursor`, `changes_since`, `prune_applied` |
| Pause flag | `<D>/paused/<domain>` | `Engine.pause_flag`, `set_paused` |
| Export records (§3.10) | `<C>/exports/` | `Export` (`sweep_records`) |
| Pending claim confirmations (§3.10a) | `<D>/claims-pending/<domain>/<record id>` | `Outbound`: `claim_queue`, `record_claim`, `run_claim` |
| Kept walk, scratch (§3.11) | `<C>/scratch/.tsync-walk`, `<C>/scratch/` | `Kept_walk`, `Handler` (`lib/owner`) |
| Temporaries | `.tsync-tmp-<pid>-<seq>.tmp` | `Names.temp_name`, `is_temp_name`, `temp_owner`; `Fs.sweep_temps` |
| Client uuid, id leases (§3.12) | `<D>/client-uuid`, `<D>/id-leases/<hex block>` | `Identity` |
| Locks and edit generations (§3.13) | memory | `Local_ops.with_meta`, `with_key`; `Keyed_locks` |
| Read handles, retentions | memory | `Local_ops`: `handles`, `body_refs`, `deferred_release` |
| Cache body locks, held intervals, in-flight table, counts | memory | `Cache.t` |
| Handled set, stepped-aside set, cursor debouncer | memory | `Applied`, `Outbound.stepped_aside`, `Journal.t` |
| Owner start, local recovery (04 §4.10) | — | `Engine.start`: `recover_local`, `reconcile`, `adopt_unrecorded` |

## Departures from the spec

- **A write's staged manifest is not durable until `sync` or `close`**, and a first write's new
  body is not fsynced before the manifest that names it (review finding 20).
- **Mirror entries are read into the heap**, not mapped
  ([../04-checkout-cache.md](../04-checkout-cache.md)).
- **Owner start walks the whole of `<C>`** for temporaries before serving (review finding 88).
- **An unparseable last-sync mark is left in place**: `Mark.read` reports it and answers no mark,
  and nothing sets the file aside (review finding 125).

## Learnings

- **One process, one engine.** `Owner.acquire` takes the lock; `Tsync_domain.Domain.engine`
  applies `Engine.Make` once, so the in-memory state of §3.13 is the values of that one functor
  body. Frontends reach it through the owner's request handler, never by applying the functor
  themselves.
- **A non-owner only submits.** It creates a record with `Dqueue.Records.create` under a
  submission id and pokes the owner; `Engine.poll` rescans, and the metadata queue re-keys the
  record with a minted entry key (`rescan_logs`).
- **Everything a non-owner may read is replaced by rename.** `Mirror` and `Staged` write through
  `Fs.replace` or `Fs.durable_replace`; pins are empty files whose mtime is the deadline.
- **Temporaries name their owner.** `Fs.sweep_temps` removes a temporary whose pid is dead, or one
  naming no owner once it is older than the given age; listings of the mirror and the staged tree
  skip temporary names, so a write in flight is never an entry.
- **Unnamed staged bodies are released exactly at owner start.** `recover_local` builds the named
  set from every decodable edit, plus every run of 16 hex characters in a set-aside manifest,
  then releases the rest: nothing else writes the staged tree yet.
- **Machine-wide identity is outside the lock.** `Identity.client_uuid` and the lease minter use
  `Fs.create_if_absent`; a lease is taken again when the pid changes.
- **The handled set is loaded once**, by `Engine.start` (`Applied.load`); `Applied.note` keeps it
  and the log in step under one mutex.
