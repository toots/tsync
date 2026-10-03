# Conflict resolution — OCaml implementation notes

Companion to the language-neutral spec [../../algorithms/conflict-resolution.md](../../algorithms/conflict-resolution.md).
See [../README.md](../README.md) for how these notes are organised.

## 1. Where each abstraction lives

| Abstract | OCaml |
|---|---|
| Arrival and Publish tables, `clashed` | `Resolve.Arrival.decide`, `Resolve.Publish.decide`, `clashed` (`lib/domain/checkout/file/resolve.ml`); printed exhaustively by `tests/unit/resolve` |
| Arrival fact gathering, translation, enactment | `Local.Peer_entry.gather`, `local_folder`, `renamed_since`, `renamed_onto`, `enact`, `apply` (`file.ml`) |
| Read-ahead, ancestor adoption, missing answer | `Foreign.read_ahead`, `adopt_ancestor_ids`, `adopt_folder_id`, exception ``Unread (`Marker k | `Manifest k)`` → `Retry.Transient` |
| Publish gathering and enactment, "as it is here now" | `Backend_half.gather_*`, `enact`, `as_published`, `backend_ops` |
| Conflict name, aside | `conflict_key`, `aside_name`, `move_aside`, `publish_aside` |
| Rescue | `Peer_entry.rescue_staged` |
| Retire stale source | `Peer_entry.retire_stale_copy` (`Folders.forget`, `Folders.reparent`) |
| Retarget | `Peer_entry.retarget_our_rename` + `W.update_ops` |
| Claims, anchors, trash | `St.claim_folder`, `placed`, `get_anchor`, `put_folder_marker`, `retire_to_trash`, `remove_old_marker` |
| Two-client rows | `tests/scenario/conflicts` (snapshot `.expected`); publish races in `tests/scenario/sync` |

Facts, actions and endings are ordinary closed variants: exhaustiveness across the table is the point.
The metadata lock (`meta_mutex`) lives in `File.Local`, where the store modules are shadowed, so code
under the lock has no name through which to reach the store.

## 2. Where the code at the spec snapshot differs from the spec

- **Occupant model.** The code gathers independent booleans (`renamed_onto`, `folder`, `staged`,
  `another_folder` …) whose product has 65 Arrival situations, several impossible; the spec uses one
  occupant per name. There is no `folder(published)` vs `folder(ours)` distinction: a published
  folder yields to a put (A3 in the code), and a published file is not moved aside for a folder.
- **Store-current reconciliation.** `delete` and file `rename` arrivals consult no store record; a
  re-applied or late delete removes a file a later write restored. Folder arrivals do not consult the
  anchor (`place(id)`), and there is no `fill-vacated`.
- **No `renamed_onto` for `delete` or rename destinations**: B renaming x over f while A deletes f,
  and A renaming onto the destination of B's pending rename, diverge.
- **Retarget order**: the file is moved before the record is rewritten; a crash between re-derives a
  second aside name.
- **Retire stale source** moves and forgets before re-pointing the id.
- **Rescue** flattens rescued staged files beside the removed folder; unpublished subfolders vanish.
  Their additions under our unpublished rmdir are not rescued (they end in the trash).
- **Publish side**: no expected prior records, so `delete` and file `rename` never detect a record
  changed since; puts have no base check; rename-dir has no `trashed` fact (a rename published after a
  peer's rmdir pulls the folder out of the trash); a file rename versions only the source.
- **Revert** does not version the replaced content.
- **`base`** is not implemented: neither on `write` from a frontend nor in put entries (A2a, P1's
  base comparison and the re-check at version save).
