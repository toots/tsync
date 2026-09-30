# Data model (backend) — OCaml implementation notes

Companion to the language-neutral spec [../../data-model/backend.md](../../data-model/backend.md).
Formats and store-interface notes are in [../02-remote-model.md](../02-remote-model.md); collection notes
in [../algorithms/gc.md](../algorithms/gc.md).

## Where each entity lives in the code

| Entity | Code |
|---|---|
| Folder marker, anchor, trash entry | `lib/core/folder.ml`; written by `Store` (`claim_name`, `put_folder_marker`, `put_anchor`), `File.Backend_half` (`retire_to_trash`, `remove_old_marker`, `Move_marker`), `Retention.restore` |
| Claim protocol | `Store.claim_name`, `ensure_folder_id`, `claim_folder`, `ensure_claimed` (`lib/domain/remote/store/store/store.ml`) |
| Placement decisions (aside, move, trash) | `Resolve.Publish` tables, enacted by `File.Backend_half.enact` (`lib/domain/checkout/file/file.ml`) |
| Trash expiry and purge | `Retention.expire`, `purge_trashed`, `still_trashed`, `collect_namespace` (`lib/domain/ops/retention.ml`) |
| Tree findings (twice, disowned, unanchored, orphan, trashed-live) | `Integrity.tree_report`, `repair_tree` (`lib/domain/ops/integrity.ml`) |
| Share | `Share.create`, `clear_cache` (`lib/domain/ops/share.ml`); serving in `lambda/handler.py` and the http-proxy frontend |
| Folder ids | `Journal.folder_id`, `Id`, `Folder_ids` (local) |

## Where the current code differs from the spec

- **No claim confirmation.** A claim is final as soon as `put_if_absent` answers; an empty answer (an
  http-proxy server older than claim support ignores `?if_absent=1`, overwrites, and answers `""`) reads as
  won. A non-transient failure falls back to a plain `put`.
- **Plain marker writes.** `put_folder_marker` (mkdir and move destination) and `Retention.restore` write
  the marker with a plain put after the anchor. A move's destination is checked beforehand with
  `taken_by_another` (a read), so a claim racing it can be overwritten.
- **Unconditional stale-marker delete.** `claim_name` deletes a disowned marker it found without any
  guard, then claims again; a concurrent claimant that won the slot in between loses its marker.
  `remove_old_marker` reads before deleting, which is the spec's rule for a mover.
- **Trash expiry ordering.** `Retention.expire` puts each entry's key before its subtree in one list and
  deletes it in batches whose inner order is unspecified, so the entry can go first; `purge_trashed` puts
  it last. Neither re-reads the anchor during the purge, groups entries by folder id, or skips a folder
  with a younger entry. Stale entries (folder anchored live) are skipped with an error log, never deleted.
- **Purge keeps anchors**, as the spec requires, because no tree fold yields an anchor. Integrity reports
  the resulting anchor-only namespaces as orphans rather than tombstones, and never adopts real orphans.
- **Shares** are never deleted; folder archives cached by token are frozen at first download; the share
  reader does not check anchors or domain confinement.
- **Mirror** copies listing entries in parallel, so a manifest can land on the destination before its
  chunks.
- **History** follows folder renames but not file renames, as the spec states; timestamps are
  microsecond-resolution floats (see [../02-remote-model.md](../02-remote-model.md) B.4).

## Background

- Anchors were added after lost deletes left two markers for one folder, showing it at two paths; the
  same check also stopped trash expiry from deleting restored folders.
- Claims were added after two clients creating one directory both wrote a marker with a plain put and
  the loser's subtree became unreachable.
