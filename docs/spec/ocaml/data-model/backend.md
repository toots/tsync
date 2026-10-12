# Data model (backend) — OCaml implementation notes

Companion to [../../data-model/backend.md](../../data-model/backend.md). Not normative. Formats and
the store-side seams are in [../02-remote-model.md](../02-remote-model.md); collection in
[../algorithms/gc.md](../algorithms/gc.md); members and copies in
[../algorithms/replication.md](../algorithms/replication.md).

## Code map

| Entity or rule | Code |
|---|---|
| Domain scope, sibling trees (§2.1, §5.4) | `Domain_name`, `Key.domain_prefix`, `Key.roots`, `Names.reserved_roots` |
| Chunk | `Chunk_key`, `Key.chunk`; `Remote.Make.put_chunk`, `get_chunk`, `get_verified_chunk` |
| File manifest | `Manifest`; `Remote.Make.put_manifest`, called by `Projection.Make.apply` only |
| Folder, namespace, child slot | `Folder_id`, `Key.namespace`, `Key.child`, `Key.is_child_of` |
| Folder marker, anchor | `Folder`; `Key.anchor`; written by `Projection.Make.apply` only |
| Version | `Key.version`; `Remote.Make.save_version`, `list_versions`, `all_versions`, `get_version` |
| Log entry, tree head, takeover, void, cursor | `Log_entry`, `Log_store`; `Key.log_entry`, `tree_head`, `takeover`, `void`, `cursor` |
| Folder index | `Folder_index`; `Tree.Make.children ~write_index` |
| Collection run, generation, spaces | `Gc_record`, `Gc_generation`, `Chunk_spaces`; the collector is `lib/gc/collector.ml` |
| Corruption marker | `Corruption_marker.body`, `Key.marker`, `Key.chunk_of_marker`; read by `Remote.Make.is_marked` and `Integrity.report` |
| Verify job, discard job | `Key.verify_job`, `Key.discard_job` and their parsers; `Composite.queue_verification`, `Discards`, `Composite.submit_collection_delete` |
| Share, share artifact cache | `Share.Make`: `create`, `revoke`, `clear_cache`; `Key.share`, `Key.share_cache` |
| Deferred debt (§2.20) | `Composite.job`, `Composite.record`; one `Dqueue` log per copy under `deferred-pending/<domain>/<escaped name>/` |
| Members and roles (§5.3) | `Composite`: `role`, `members`, `readable`, `in_read_order`, `guard` |
| Minting (§2.4) | `Identity.mint`, `Folder_id.mint` |
| Apply (§6.1) | `Projection.Make.apply`: `held_at` reads the slots of a pass, `save_replaced` saves a version from the body read (`Remote.save_version ~body`) and passes only `Missing_chunks`; a failed write stops the commands not started, a failed lease test every write; `Cycle.project` raises the tree head after it |
| Settling by the anchor (§6.2) | `placed` in `Tree.Make`, applied to every marker in `children` and to every segment in `find` |
| Expiry (§8) | `Retention.Make.expire`; the decisions are `Gc_plan.versions`, `log`, `takeovers`, `share` |
| Tree findings (05 §4.10) | `Integrity.Make.report`: `Behind`, or the findings `Disowned`, `Unmarked`, `Unaccounted` |
| Member-to-member mirror | `Store_mirror.Make.mirror` |

## Departures from the spec

None of its own: the projector's lease and the repeat of a write whose answer was lost are in
[../algorithms/publication.md](../algorithms/publication.md).

## Learnings

- **One function writes the tree.** `Projection.Make.apply` is the only path from a marker, an
  anchor or a manifest to the store, and every write of it is plain. `Tree.Make` writes folder
  indexes and nothing else.
- **A reader classifies a child in one function**: `classify_child` answers marker, manifest or
  unclassifiable for `children` and `find` alike, and a marker then goes through `placed`. The
  projection reads the slot it is about to change through its own `held`.
- **The anchor is written before the marker it validates**: pass 2 of `apply` writes every anchor,
  pass 3 the markers. Pass 4 deletes a removed folder's index, then its anchor.
- **Destructive passes default to a dry run.** `Retention.expire` and `Integrity.repair_chunks`
  take `?apply`; without it they read, decide and report.
