# Read path and chunk cache — OCaml implementation notes

Companion to [../../algorithms/read-path-and-cache.md](../../algorithms/read-path-and-cache.md). Not
normative. Finding numbers refer to [the 2026-10-01 review](../../../review/2026-10-01-rewrite.md).
What bodies are made of, and what is mapped, is in [../memory.md](../memory.md).

## Spec → code

| Spec | Code |
|---|---|
| Units (§4.1): chunk, group, piece | `Cache.member`, `Cache.group`, `Cache.per`, `group_key`, `group_of`, `groups`, `group_index` (`lib/checkout/cache.ml`); `Chunking.pieces` (`lib/core/chunking.ml`) |
| On-disk state (§3.1) | `whole_path`, `partial_path` (`.partial`), `pin_path` (`.pin`) under `<cache_root>/<domain>/chunks/<shard>/` |
| Body lock, generation, held intervals (§3.2) | one `gstate` per group key (`lock`, `generation`, `held`), reached only through `using`; `fresh_generation`, `forget` |
| In-flight table | `Cache.t.in_flight`, joined in `ensure_whole` |
| Reading through a handle (§4.2) | `open_read`, `read`, `read_content`, `read_published`, `read_staged`, `close_read` (`lib/sync/local_ops.ml`) |
| Serving one piece (§4.3), the read deadline | `Cache.read_piece`, `within_deadline`, `read_deadline` |
| Range fill (§4.4) | `fill`, `missing`, `widen`, `install_from_partial` |
| Whole-group fetch, verification, install (§4.5, §4.6) | `ensure_whole`, `fetch_group`, `fetch_verified`; `Cache.verified_member` is the only source of inherited bytes in a new publication |
| Sequential detection, read-ahead (§4.7) | the handle's `pos`, and `prefetch` (`local_ops.ml`): the current group and the next |
| Materialisation, pinning (§4.8) | `Cache.pin`, `unpin`, `availability`, `resident`; `pin`, `assemble_to`, `fetch_range`, `downloads` (`local_ops.ml`) |
| Promotion hand-over | `promote` (`local_ops.ml`), `Cache.adopt_body`: a hard link, else a copy |
| Replacement (§4.9) | `Cache.enforce_cap`, `last_counts`, `touch`; run by `Engine.trim_cache` from the owner's housekeeping and after each upload |
| Owner start | `Cache.sweep_at_start`, from `recover_local` (`lib/sync/engine.ml`) |
| Store reads and their bounds | `get_whole` and `get_range` given to `Cache.create`; the `downloads`, `ranges` and `buffers` semaphores (`lib/remote/remote.ml`) |
| Fast or slow store | `Store.fast_read` of the composite, asked through `fast` |
| Tests | `tests/unit/cache_states_test`, `shared_outcome_test`, `tests/sync/offline_test` |

One `Cache.t` exists per domain per owner (`local_ops.ml`), so every consumer shares its in-flight
table and its group states.

## Departures from the spec

- **The cap is enforced between passes, not on the fetch path** (finding 34). Bytes a fetch adds are
  counted at the next `enforce_cap`: a host that mostly reads can pass its cap between two housekeeping
  passes.
- **Prefetches are not bounded per handle** (finding 35). Demand range reads have their own lane (the
  `ranges` semaphore), but each sequential read spawns up to two detached whole-group fetches, and a
  prefetch the reader has passed is not dropped.
- **A prefetch reserves before it has a slot, and every read rebuilds the group list** (finding 80).
  `prefetch` calls `Cache.groups` over the whole manifest on each read.
- **`fast_read` is the first readable member's** (finding 98): with a local main held down, every
  small read from the remote copy still fetches a whole group.
- **A local store is `fast_read` on a network filesystem too** (finding 148).
- **An eviction can report success while the body stays** (finding 134): a fetch in flight installs
  the body after the eviction answered.
- **The cap pass counts a fetch's temporary as a body** (finding 135) and under-evicts by its size.
- **A reader of a whole staged edit can meet `ENOENT`** when the first write splits that edit into
  slots and releases the body (finding 109).
- **Startup walks the cache root before the owner serves** (finding 88).

## Learnings

- A fetch several readers wait on shares its failure as well as its success: `ensure_whole` resolves
  the promise with the result, and a waiter that gets another reader's cancellation checks its own and
  asks again (finding 50).
- Group state is kept only for a group that has a partial body or a user (`using`, `Cache.tracked`):
  one entry per group ever touched cost hundreds of megabytes after a pass over a large domain
  (finding 69).
- Generations come from one process-wide counter, never repeated, so a state dropped and made again is
  not taken for the one a fetch planned against.
- The read deadline bounds the wait, not the work: `within_deadline` runs the fetch detached, and it
  lands for the next reader.
- A whole body exists only verified, fsynced and renamed into place; a partial body means nothing
  without the owner's memory, so `sweep_at_start` removes every file that is neither a whole body nor
  a pin.
- Inherited bytes of a new publication come from `verified_member`, never from a range read: a range
  cannot be checked against a chunk key.
