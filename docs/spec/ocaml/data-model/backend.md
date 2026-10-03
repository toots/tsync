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
| File manifest | `Manifest`; `Remote.Make.publish`, `put_manifest`, `delete_slot`, `rename_file` |
| Folder, namespace, child slot | `Folder_id`, `Key.namespace`, `Key.child`, `Key.is_child_of` |
| Folder marker, anchor, trash entry | `Folder`; `Key.anchor`, `Key.trash_entry`; written by `Tree.Make` only |
| Version | `Key.version`; `Remote.Make.save_version`, `list_versions`, `all_versions`, `revert` |
| Journal entry, cursor | `Journal`, `Entry_key.journal_key`, `Key.cursor` |
| Folder index | `Folder_index`; `Tree.Make.children ~write_index` |
| Collection run, generation, spaces | `Gc_record`, `Gc_generation`, `Chunk_spaces`; the collector is `lib/gc/collector.ml` |
| Corruption marker | `Corruption_marker.body`, `Key.marker`, `Key.chunk_of_marker`; read by `Remote.Make.is_marked` and `Integrity.report` |
| Verify job, discard job | `Key.verify_job`, `Key.discard_job` and their parsers; `Composite.queue_verification`, `Discards`, `Composite.submit_collection_delete` |
| Share, share artifact cache | `Share.Make`: `create`, `revoke`, `clear_cache`; `Key.share`, `Key.share_cache` |
| Deferred debt (§2.20) | `Composite.job`, `Composite.record`; one `Dqueue` log per copy under `deferred-pending/<domain>/<escaped name>/` |
| Members and roles (§5.3) | `Composite`: `role`, `members`, `readable`, `in_read_order`, `guard` |
| Minting (§6.1) | `Identity.mint`, `Folder_id.mint` |
| Claim and confirmation (§6.2) | `Tree.Make.claim`, `confirm`; driven by `Outbound.ensure_folder_id`, `claim_place`, `record_claim`, `run_claim`, `set_folder_aside` |
| Settling by the anchor (§6.3) | `Tree.Make.placed`, `holder_at`; applied to every child in `children` and to every segment in `find` |
| Placement, trash, restore (§6.4) | `Tree.Make.place`, `move`, `trash`, `restore` |
| Removing a disowned marker (§6.5) | `Tree.Make.remove_marker_if` |
| Placement decisions | `Conflict.publish`, enacted by `Outbound.publish_op` |
| Trash expiry and purge (§8) | `Retention.Make.expire`, `purge`; the order is `Gc_plan.purge_order` |
| Tree findings and repair (§10) | `Integrity.Make.report`, `repair_tree`: `Twice`, `Disowned`, `Trashed_live`, `Unanchored`, `Orphan`, and the tombstone count |
| Member-to-member mirror | `Store_mirror.Make.mirror` |

## Departures from the spec

- **Not every won claim is confirmed.** `claim_place` (a published mkdir) records a pending
  confirmation; the claim `ensure_folder_id` makes for a folder with no local id does not.
  Placements by a move or a restore are not confirmed (review finding 122).
- **The confirmation is timed on the wall clock.** `run_claim` sleeps until
  `landed + claim_settle` by `Unix.gettimeofday` (review finding 140).
- **Claim and placement are bounded.** `Tree.claim` and `Tree.place` retry an empty or disowned
  slot at most 8 times, then fail LOAD.
- **No conditional delete.** The store contract has none, so `remove_marker_if` reads the slot and
  deletes plainly when the marker still names the id; §6.5 allows this.

## Learnings

- **One function writes markers.** Inside `Tree.Make`, `claim_text` is the only path from a
  marker body to the store, and it is `put_if_absent`. The plain `put` there writes anchors, trash
  entries and folder indexes.
- **An answer that is not a marker is read back.** `claim` and `place` classify what
  `put_if_absent` returned and, unless it is a marker, read the slot; an empty slot goes round
  again. A store that does not arbitrate therefore costs a read, never a false win.
- **Classification of a slot is one function**: `classify_slot` answers filed, disowned, file or
  unclassifiable, and `claim`, `confirm`, `place` and `holder_at` all go through it or through
  `placed`.
- **The anchor is the commit point of a placement**: `place` writes it before the marker's
  create-if-absent, `trash` writes the entry, then the anchor, then removes the live marker.
  `anchor_in_trash` (integrity repair) is itself a create-if-absent, so a restore racing the
  repair keeps its live anchor.
- **A claim of a slot that already names the candidate** writes the missing anchor, holds when
  the anchor agrees, and fails LINK when the anchor places the folder elsewhere.
- **A trashed folder is its newest entry, whole.** `Tree.trashed` groups entries by folder id and
  takes name, path and time from one entry, never the best of each field (B-10.10).
- **Purge re-reads the anchor before each namespace** and stops when it finds the folder live
  (`Retention.purge_folder`). It deletes everything a namespace lists except the anchor leaf, so
  the folder index goes and the anchor stays as a tombstone; the trash entries go last.
- **Destructive passes default to a dry run.** `Retention.expire`, `purge` and
  `Integrity.repair_tree`, `repair_chunks` take `?apply`; without it they read, decide and report.
