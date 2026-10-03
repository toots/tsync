# 02 — The remote data model — OCaml implementation notes

Companion to [../02-remote-model.md](../02-remote-model.md). Not normative: where each concept lives
in the code, where the code departs from the spec, and what holds for this code. The folder protocol
is mapped in [data-model/backend.md](data-model/backend.md); body handling in [memory.md](memory.md).

## Code map

| Spec concept | Code |
|---|---|
| Dual digest (§2.1) | `Xxh` (`dual`, `dual_bigstring`, `dual_create` / `dual_update_*` / `dual_digest`), stubs in `lib/core/xxh_stubs.c` |
| Chunk key, shard | `Chunk_key` (`of_string`, `v`, `of_bigstring`, `shard`, `empty`), `Names.is_chunk_key`, `Names.shard` |
| Chunking facts (§2.2) | `Chunking` (`count`, `manifest_count`, `length`, `pieces`, `chunk_size_min` / `_max` / `_read_max`) |
| Key layout (§2.3) | `Key`: the namers (`chunk`, `chunk_from`, `namespace`, `child`, `anchor`, `index`, `trash_entry`, `version`, `journal_entry`, `marker`, `verify_job`, `discard_job`, `share`, `gc_run`, `gc_generation`) and the readers (`chunk_of`, `chunk_parts`, `outgoing_chunk`, `parse_verify_job`, `parse_discard_job`, `is_child_of`, `is_internal_leaf`, `run_name`, `probe_run`) |
| Key and name grammar | `Names` (`valid_key`, `valid_leaf`, `valid_path`, `valid_folder_id`), `Domain_name` |
| Folder ids (§2.5) | `Folder_id` (`root`, `trash`, `mint`); leases in `Identity` (`lib/checkout`) |
| File manifest (§2.6) | `Manifest` (`decode`, `of_body`, `make`, `symlink`, `rename`, `key`, `chunk_names`, `digest_of`, `check_readable`, `equal_content`) |
| Folder marker, anchor, trash entry (§2.7–2.9) | `Folder` (`marker_body`, `anchor_body`, `trash_body`, `classify_marker`, `decode_anchor`, `in_trash`) |
| Folder index (§2.10) | `Folder_index` (`encode`, `decode`, `max_bytes`, `max_children`); read and written by `Tree.children` |
| Versions (§2.11) | `Remote.Make`: `save_version`, `list_versions`, `all_versions`, `get_version`, `revert` |
| Run record, generation (§2.12) | `Gc_record` (`lib/gc`), `Gc_generation` (`lib/store`) |
| Corruption marker, discard job (§2.13) | `Corruption_marker.body`, `Discards` (`request_key`, `body`, `keys_of_body`) |
| Share manifest (§2.14) | `Share` (`lib/gc`), served by `lib/frontends/http_proxy/share_server.ml` |
| ContentStore (§3.1) | `Remote.Make`: `upload_chunks`, `put_chunk`, `get_chunk`, `get_verified_chunk`, `get_chunk_range`, `chunk_size` |
| ManifestStore, store side | `Remote.Make`: `get_slot`, `head_slot`, `put_manifest`, `publish`, `delete_slot`, `rename_file` |
| ManifestStore, folders | `Tree.Make`: `claim`, `confirm`, `place`, `move`, `trash`, `restore`, `remove_marker_if`, `anchor`, `placed`, `holder_at` |
| `ensure_folder_id`, pending confirmations | `Outbound.Make` (`lib/sync`): `ensure_folder_id`, `claim_place`, `record_claim`, `run_claim` |
| TreeReader | `Tree.Make`: `children`, `find`, `fold_tree`; `Tree.unusable`, `Tree.on_unusable` |
| ChunkSpace, the gate | `Chunk_spaces` (`read`, `gate`, `promote`, `run_open`, `list`, `twins`), called by the local driver (`lib/store/local.ml`) |
| Corruption memo (§4.7) | `Remote.Make.is_marked`, cleared per chunk by `put_chunk` |
| Dedup memo | `Remote.Make`: a `Chunk_set` behind a mutex, `drop_memo` |
| Domain context | `Context.S` (`lib/remote`), built by `Tsync_domain.Domain.context` |

## Departures from the spec

- **No whole-file `upload`, no `fetch_manifest`.** `upload_chunks` puts chunks and returns the
  manifest; it publishes nothing. `publish` is a separate call, made by `Outbound.run_one_upload`
  under the key lock after its generation check. A cancel set while the put is in flight is not
  followed by a delete of the manifest.
- **Chunk sources** are `Stored`, `Bytes` and `Lazy`, not `Stored`, `Mapped` and `Filled`.
- **Slots, not logical keys.** Every `Remote` and `Tree` verb takes `(Folder_id.t, leaf)` or a
  `Key.t`. There is no KeyLayout seam and no `Unresolved` answer: resolving a path to an id is the
  caller's (`Mirror.folder_id`, `Outbound.ensure_folder_id`), and share serving walks from the root
  with `Tree.find`.
- **State is per functor application, not per domain.** The semaphores, both memos, the resolved
  chunk size and the version-timestamp table are values of the `Remote.Make` body. `Local_ops`,
  `Export` and one-shot commands each apply it, so two applications in one process share none of
  them (review finding 87).
- **`fold_tree` never uses `list_many`.** A folder costs one listing, one `Store.read_many` for the
  bodies its index does not serve, and one anchor read per folder marker (review finding 97).
- **A claim made by `ensure_folder_id` queues no confirmation.** Only `claim_place` (a published
  mkdir) calls `record_claim`. Placements by a move or a restore are not confirmed either (review
  finding 122).
- **`revert` re-puts the body**, decoded and renamed to the slot's leaf, through `put_manifest`; it
  is not a server-side copy. `rename_file` snapshots the destination as well as the source.
- **Share tokens** are accepted from 1 to 128 lowercase hex characters (`Key.share`, following
  security-model §6.1), where §2.14 says at most 64.

## Learnings

- **Types guard the key space.** `Key.t`, `Key.prefix`, `Chunk_key.t`, `Folder_id.t` and
  `Domain_name.t` are private strings. A key comes from a namer or from `Key.of_string`, the one
  validating boundary for names from a listing, a peer or a job record. `Chunk_key.v` fails CORRUPT,
  `Folder_id.v` and `Key.v` fail INVALID: the kind says where the string came from.
- **A manifest is a heap string.** `Manifest.t` keeps the exact body and its decoded header; keys
  are cut out by `Manifest.key` when used, so a malformed key fails only the read that needs it.
  `Manifest.of_body` tests the magic on the bigstring before copying ([memory.md](memory.md) M.1).
- **Markers, anchors and manifests cross the store as strings**, converted in `Tree.Make.get` and
  `put`; chunk bodies stay bigstrings.
- **Three lanes, three semaphores**: `buffers` (chunk bodies in memory across all uploads),
  `downloads` (whole chunks), `ranges` (demand range reads). A range read behind whole-group
  prefetches misses its deadline (C-10.1). One upload sends two chunks at a time
  (`Rt.map_bounded ~width:2`).
- **The buffer slot is taken before the bytes exist.** `upload_chunks` evaluates a `Lazy` source
  inside the slot (C-2.1). `progress` and `sent` are called under one mutex, because the workers
  run on several domains and a caller counting into a `ref` would lose updates.
- **`chunk_size` never waits for the store.** The main's recommendation is asked once in a spawned
  fiber, guarded by a compare-and-set; until it answers the default is used, so a local write
  stays offline work. A failure clears the guard and the next caller asks again.
- **The corruption memo refreshes outside its lock.** Callers arriving past the TTL each list the
  markers; the result is swapped in under the mutex. Duplicate listings, never a torn table.
- **Version timestamps** come from `next_version_ts`: one mutex, the last stamp per group, pruned
  past 1024 groups to stamps not yet in the past. It orders snapshots of one process only.
- **`save_version` is bounded by `Rt.with_timeout ~detach:true`** and re-raises `Stop.Stopping` and
  `Rt.Cancelled`; every other failure is logged and the write proceeds.
- **A claim answer that is not a marker is read back**, in `Tree.claim` and `Tree.place` alike; an
  empty slot claims again, at most 8 rounds, then fails LOAD.
- **`fold_tree` bounds its look-ahead by position** (C-1.2): an explicit stack, each folder carrying
  a promise cell, and only the next `width` folders in visit order fetched with `Rt.async`. The
  visit order does not depend on which fetch finishes first. Under `Skip`, a folder failing with a
  retryable kind is walked once more after the walk, its subtree with it.
- **The index is read only when the listing shows it.** `children` finds the index key in the same
  listing that yields the children, so a folder without one costs no extra request.
