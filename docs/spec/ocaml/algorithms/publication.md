# Publication — OCaml implementation notes

Companion to the language-neutral spec [../../algorithms/publication.md](../../algorithms/publication.md)
and to the theory it realises, [../../algorithms/change-algebra.md](../../algorithms/change-algebra.md).
Not normative.

## Where each abstraction lives

| Spec | Code |
|---|---|
| Keys, values, commands, states (change-algebra §3) | `Algebra` (`lib/core`): `place`, `key`, `command`, `base`, `t`; a state is a `base` read on demand plus the keys changed over it |
| Well-formedness, batches (Definitions 3, 6) | `Algebra.well_formed`, `is_batch` |
| Order of application, temporary places (Theorem 3) | `Algebra.take` (a batch under a limit), `order` (a whole difference), `run` |
| The merge and its repair (Definition 7) | `Algebra.merge`: step 1 over the keys of `before` and `theirs`, then R1, R2, R3 until no violation |
| A file's value and its equality | `Log_entry.value` (`Known`, `Identity`, `Unknown`), `equal` |
| Command and entry formats (03 §2.3–2.4) | `Log_entry`: `encode` (checks that the body reads back as the batch), `decode`, `chunk_names` (for the gate) |
| Log, tree head, takeover, void, cursor on the store (03 §3.1) | `Log_store` (`lib/remote`) |
| Position, before-values, in-flight and arrival records (03 §2.7–2.8, §3.2) | `Sync_state` (`lib/sync`): before-values are held in memory, the files are their durable form |
| A local operation (§4.1) | `Local_ops`: `begin_change` and `settle` around content changes; `namespace_op` (intent, local half, feed line); `delete_held`, `rmdir_held`, `move_file_held`, `remove_tree` |
| Upload (§4.2) | `Uploads.run_upload`: chunks, then the edit marked `Uploaded` under the key lock if its generation did not move |
| Fetch (§4.3) | `Cycle.fetch`, over `Log_store.read_entries` |
| Arrive (§4.4) | `Cycle.arrive`, `merge_and_enact`, `steps_of`, `run_arrival`, `apply_step` |
| Push and the choice of a batch (§4.5) | `Cycle.choose_batch`, `push`, `commit`, `won`, `chunks_refused` |
| Projection (§4.6) | `Projection.apply` (`lib/remote`, the four passes, each reading its slots through `Store.read_keys` and writing `project_width` at a time); `Cycle.project` (who, the lease test, the settle and the quarantine) |
| State read and arrival by state (§4.7) | `Projection.fold` (the walk of 05 §4.7), `Cycle.state_read`, `arrive_by_state` |
| Crash recovery (§4.8) | `Cycle.recover_local` (steps 1 to 5), `complete_arrival`, `recover_in_flight`; called from `Engine.recover` |
| Log retention (§4.9) | `Gc_plan.log`, `takeovers`; `Retention.expire` |
| The lazy tree (§4.11) | `Cycle.pull_folder`, `push_position`, `views_of`, `commit_position`; positions beside the pull marker (`folder_position`) |
| Bulk publishers (§4.12) | `Bulk` (`install`, `folder`, `await`), `Import`, `Rsync` |
| The cycle (§4) | `Cycle.step` (one cycle: arrive, push one entry, project one), `cycle_loop` (a step, and the next at once while one pushed or projected), `run_cycle` (steps until one does neither, for a caller that waits); `Engine.resync`, `drain`, `poll` |
| Parameters (§7) | `Tuning.default` for the six a domain may set, read through `Engine_ctx.S.settings`; `sweep` and `retry_floor` at the top of `cycle.ml`; `Log_entry.max_bytes`; `Log_store.retention`, `cursor_interval` |

`Engine.Make (C)` is one functor chain, each layer including the one below: `Local_ops`, `Uploads`,
`Cycle`, `Bulk`, `Import`, `Rsync`, then `Engine` (the change feed, start and drain, status).

## Where the code departs from the spec

- **The retry ladder of a store write is not under the lease test.** `Cycle.project` tests the
  lease before each record write and at least every `PROJECT_LEASE / 2`; a driver's own retries of
  that write are not re-tested. The quarantine (5 min) is what covers a write that lands late.
  The fibers writing one pass make the test one at a time, under a fiber mutex, and
  `Projection.apply` issues no write once it failed for one of them.
- **A write whose answer was lost is repeated**, not read back first (§4.6). Applying is
  idempotent, so the repeat writes the same record.
- **A parked folder can be listed.** `.tsync-park-<id>` is a real name of the root, escaped in the
  mirror, for the time of one enactment under the metadata lock; a listing that takes no lock can
  show it.
- **A refused commit for missing chunks is not answered from the local cache.** An edit whose
  bytes are staged is uploaded again; a file with no staged bytes is reported as damaged, and a
  later import or rsync of it uploads it again.
- **An arrival by state holds its difference in memory**, and writes it whole in the arrival
  record. On a client whose mirror is current that is small; a first sync of a very large domain
  holds every manifest of it.
- **Takeover is tested once.** A client takes over an entry its projector left, after the settle
  and the quarantine of a short `Tuning` (`cycle_test`, the paused client). A stalled projector that
  resumes and two clients racing for one takeover are not tested.
- **`Rt.boottime`** is `CLOCK_BOOTTIME` on Linux and `CLOCK_MONOTONIC` elsewhere; whether the
  latter counts suspended time depends on the system.

## What the code learned

- **The exhaustive check is the real proof.** `tests/sync/algebra_test` runs every triple of
  small trees through `Algebra.merge` and every pair through `order` and `take`; `ALGEBRA_FULL=1`
  adds universes of a few million triples. It is what found that the repair's order changes fresh
  names, and that R3 must never pick a folder R1 restored.
- **A state as a base plus changes** keeps a merge proportional to the keys that changed: the
  local tree is read through `Cycle.l_base`, and a violation is looked for only around changed
  keys, which is sound because the base is well-formed.
- **Arguments are evaluated right to left.** A test that prints `(sync b) (tree b)` reads the tree
  before the sync; two scenarios of `cycle_test` looked wrong for that reason alone.
- **A list literal too.** `[waiter "a"; waiter "b"]` starts `b` first.
- **`dune build ./tests` runs every test.** Compile with `@check`, run one directory's `runtest`.
