# Local state of one client for one domain — OCaml implementation notes

Companion to [../../data-model/local-cache.md](../../data-model/local-cache.md). Descriptive notes
about the tree at `4c32fa96`; the spec is normative.

## Entity → current representation

`<C>` = `<cache_root>/<domain>`, `<D>` = `<data_dir>`.

| Entity | Current representation | Code |
|---|---|---|
| folder entry, markers | directory under `<C>/manifests/`, `.tsync-dir`, `.tsync-name` | `Cache_layout`, `Folder` (marker JSON) |
| file entry | manifest body at `<C>/manifests/<escaped path>`, `mmap`ed | `Manifests` |
| reverse entry, removed-id record | `<C>/folders/<id>`, `<C>/folders/by-path/<md5>` | `Folder_ids` |
| cache body, partial record, pin | `<C>/chunks/<shard>/<group key>`, `.manifest`, `.pin` | `Chunk_cache`, `Partial` |
| staged manifest, set-aside | `<C>/staged/manifests/<path>`, `<path>.bad` | `Staged_manifest` |
| staged body | `<C>/staged/chunks/<id>`, `<C>/staged/whole/<id>` | `Staged_body` |
| WAL record, claim | `<D>/journal-pending/<domain>/<entry key>`, `<D>/journal-pending/<domain>.owner` (`lockf`) | `Wal`, `Durable_queue.Records` |
| applied log | `<C>/applied/<YYYY-MM>.log` | `Applied_entries` |
| last-sync mark, resync generation | `<D>/last-sync-<domain>`, `<D>/resync-<domain>` | `Journal`, IPC handler |
| export record | `<C>/exports/<xxh3 pair of dst>` | `ops/export.ml`, `Export_records` |
| kept walk | `<C>/scratch/.tsync-list-all` | IPC handler |
| deferred job log | `<D>/deferred-pending/<domain>/<escaped target>/` + `.owner` | `lib/backends/api/deferred.ml` |
| client uuid, leases | `<D>/client-uuid`, `<D>/id-leases/<hex block>` | `Journal` |

## Differences from the spec

- **Processes.** The launcher parent converges (reconcile over all WAL records, `adopt_unrecorded`,
  the poller, maintenance) while each forked frontend runs its own upload and metadata queues over
  the same WAL directory and mutates the mirror and staged tree under its own in-process locks.
  `tsync sync` can run reconcile and peer application beside the daemon. No cross-process lock
  guards the mirror, the staged tree or the WAL (the `.owner` claim is taken by every runner and
  checked by nobody). The spec has one owner per domain.
- **Durability.** No fsync on staged sidecars, WAL records, partial records, deferred records or
  the client uuid; export and the local backend do fsync.
- **F9 order**, **F10 set-aside bodies**, **empty-Intent WAL decode**: see
  [../04-checkout-cache.md](../04-checkout-cache.md) B.0.1.
- **Dedupe set** loaded once per process, so the daemon and `tsync sync` could re-apply each
  other's entries.
- **Android** builds its domain with `resume = false`: deferred jobs a killed app process left
  are never replayed. The share sheet finishes the activity before the commits run.
- **Growth**: removed-id records and id leases are never removed.
