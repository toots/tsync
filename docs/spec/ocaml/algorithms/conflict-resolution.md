# Conflict resolution — OCaml implementation notes

Companion to the language-neutral spec [../../algorithms/conflict-resolution.md](../../algorithms/conflict-resolution.md).
Not normative. Finding numbers refer to [the 2026-10-01 review](../../review/2026-10-01-rewrite.md).

## Where each abstraction lives

| Spec | Code (`lib/sync/`) |
|---|---|
| Occupants, places, facts (§3.5, §4.2) | `Conflict.occupant`, `place`, `arrival`, `publish_fact` |
| Arrival table (§4.3), `clashed` | `Conflict.arrival`, `Conflict.clashed`; printed exhaustively by `tests/sync/formats_test` |
| Publish table (§4.5) | `Conflict.publish`, `Conflict.publish_clashed`, `Conflict.max_claim_rounds` |
| Conflicted-copy name (§4.7) | `Conflict.conflict_name`; the free name is picked by `aside_name` (`local_ops.ml`) |
| Read-ahead of store answers, ancestor adoption | `read_ahead`, `placed_answer`, `store_at`, `place_answer`, `adopt_ancestors` (`engine.ml`) |
| Arrival fact gathering, translation through our owed renames | `apply_op`, `occupant`, `removal`, `translate`, `follow_owed_renames` (`engine.ml`) |
| Arrival actions (§4.6) | `install`, `file_aside`, `file_aside_published`, `folder_aside`, `folder_aside_local`, `rescue_folder`, `rescue_ours_under`, `rescue_theirs`, `revive_ours`, `retire_stale_source` (`engine.ml`) |
| Publish gathering, the claim and move attempts | `publish_op`, `store_record`, `claim_place`, `expected_matches` (`outbound.ml`) |
| Publish actions, retarget | `enact_publish`, `retarget_rename` (`outbound.ml`) |
| Expected prior records | `Wal.prior`, `Wal.record.priors`, read by `view_prior` (`local_ops.ml`) |
| `base` of a put | `Op.Put.base`, `Staged.edit.base`, `base_hex` (`local_ops.ml`) |
| Moving a staged edit with its owed upload | `move_edit`, `repost_moved`, `materialise_inherited` (`local_ops.ml`) |
| Late name loss of a claim | the `claims` queue, `run_claim`, `set_folder_aside` (`outbound.ml`) |
| Two-client rows | `tests/sync/two_clients_test`, `moved_edit_test`, `marker_slot_test`, `missing_parent_test`, `lost_answer_test`, `restore_race_test` |

Facts, actions and endings are closed variants, so a new row fails to compile until every table handles
it. `Conflict` does no I/O: `engine.ml` and `outbound.ml` gather the facts and enact the answer.

## Where the code departs from the spec

- **The put rows are decided by the upload itself.** `run_one_upload` compares the store's record with
  the edit's base through `slot_moved_on` and moves the edit aside; it does not call `Conflict.publish`.
  The comparison is made once, before the chunks are sent: `Remote.publish` takes no expected record, so
  it is not repeated when the replaced record is read for its version save (§4.4).
- **Revive-ours owes nothing durably** (finding 39). `revive_ours` installs the aside and publishes
  from a deferred step with no WAL record: a failed publish picks a new aside name on the next pass, and
  a kill between the publish and its put leaves the store holding ours with no entry.
- **Store reads under the metadata lock** (finding 52, pitfall A-2.5). The read-ahead covers the
  answers an entry needs, except an edit reached only through an owed rename of ours, whose inherited
  bytes are fetched under the lock.
- **`create` and `mkdir` take different locks** (finding 120): the key lock and the metadata lock, so a
  file and a folder can hold one name.
- **Moves and restores are not confirmed** (finding 122): only a claim has a `claims` record; a marker
  raced during a move is not re-claimed.
- **The claim confirmation is timed on the wall clock** (finding 140): `run_claim` waits
  `claim_settle` from `landedAt` by `Unix.gettimeofday`.
- **A parked `claims` record waits for the next start.** `Engine.rearm` re-arms the upload, metadata
  and copy queues, not `claim_queue`, and `Engine.parked` does not list it.
- **Landing names are not announced** (finding 119): a path translated through an owed rename is not
  passed to the frontend's change hook, and a failed notification is not reported.

## Learnings

- "Could not tell" is its own answer. `store_record` answers `` `Unresolved `` when the parent folder
  cannot be named, and a folder marker in a file's slot is `` `Folder ``, never "no manifest"
  (pitfall A-4.1; findings 2 and 16).
- Every move of a staged edit goes through `move_edit`, which bumps the source key's generation and
  cancels its upload; `repost_moved` posts the upload at the new key. A move that skips either leaves
  the old name's upload live (findings 4, 5, 12).
- A retried round re-reads its record from the WAL (`read_record`): a retarget rewrites the record, and
  the copy in memory is stale (finding 11).
- An edit whose slots inherit from a base is materialised (`materialise_inherited`) before it is moved
  to a name that has no base.
