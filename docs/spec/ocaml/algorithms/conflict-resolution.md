# Conflict resolution — OCaml implementation notes

Companion to the language-neutral spec [../../algorithms/conflict-resolution.md](../../algorithms/conflict-resolution.md).
Not normative.

## Where each abstraction lives

| Spec | Code |
|---|---|
| The merge (§1, change-algebra Definition 7) | `Algebra.merge` (`lib/core`), pure |
| Keys and values (§2) | `Algebra.key`, `place`; `Log_entry.value`, whose `equal` compares content identities and makes `Unknown` differ from everything |
| Local state a merge reads (§3) | `Cycle.l_base` (`lib/sync`): the mirror overlaid with the staged edits, read under the metadata lock; `Cycle.pending` for the before-values |
| Enacting a merge (§4) | `Cycle.merge_and_enact`: the decision is taken again with the key locks held; `steps_of` orders the changes; `run_arrival` and `apply_step` make them |
| A move the main made (§4.1) | `Cycle.steps_of`: a removal of an unedited file paired with an earlier creation of the same content becomes one `Move` |
| Conflicted-copy name (§5) | `Conflict.name`; the free name is picked by `Cycle.aside` (a merge) and `Local_ops.aside_name` (a stale base) |
| A local write against a stale base (§7) | `Local_ops.write_whole` |
| Every row of §8.3 | `tests/sync/rows_test`: two clients and a third that arrives by state, trees compared with contents |

## Where the code departs from the spec

- **The file-rename refinement of §6 is not implemented**: a renamed file a peer edited is two
  files, as the theory gives.
- **A name the local tree cannot hold (§4.1)** is not handled: an escape handle already used by
  another name of the folder makes the arrival fail, and it is retried.
- **The identity of a staged edit is not computed at the merge (§2)**: two clients writing the
  same bytes get a conflicted copy when the arrival comes before the upload.
