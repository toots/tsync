# Read path and chunk cache — OCaml implementation notes

Companion to [../../algorithms/read-path-and-cache.md](../../algorithms/read-path-and-cache.md).
Descriptive notes about the tree at `4c32fa96`; the spec is normative. Runtime lessons (the
`within_deadline` pattern, fan-out bounds, cooperative-scheduling assumptions) are in
[../04-checkout-cache.md](../04-checkout-cache.md) B.1–B.2.

## Spec → code

| Spec | Code |
|---|---|
| read through a handle, pieces, leading run | `Data.pread_key`, `Data.pread`, `serve_pieces`, `Chunks.pieces` (`lib/domain/checkout/content/data.ml`) |
| cache_read, within_deadline, touch | `Chunk_cache.read_into`, `within_deadline`, `touch` (`lib/domain/checkout/chunks/chunk_cache.ml`) |
| range fill, missing, widen | `Chunk_cache.fill`; `Partial.missing`, `take`, `publish`, `start`, `load`, `reset` (`chunks/partial.ml`) |
| ensure_whole, in-flight table | `Chunk_cache.ensure_fetched`, `fetching`, `fetch`, `complete_body`, `write_group` |
| verified fetch | `Chunk_store.fetch_verified` (used by export only) |
| read-ahead | `Data.read_ahead`, `last_read_end`, `readahead_in_flight` |
| staged combination | `Data.pread_staged`, `pread_chunked`; resolver `Manifests.current` |
| promotion hand-over | `Chunk_cache.link_in`, `put_group`, `links_supported`; `Data.promote` |
| materialisation, pins | `Data.fetch_plan`, `fetch_groups`, `ensure_local`, `assemble_to`, `fetch_range`; `Chunk_cache.pin`, `unpin`, `forget` |
| cap | `Chunk_cache.enforce_cap`, `anchor`, `counted_write`, `held_for`; triggered by the domain engine (`housekeeping_interval = 60`) |
| DOWNLOADS / RANGES pools | `Remote.pools_for` (`downloads`, `ranges`, keyed by chunk prefix), `Chunk_store.fetch`, `fetch_range` |
| SLOTS, PIECE_SLOTS, GROUP_SLOTS | `Chunk_cache.slots`, `Data.piece_slots`, `Data.group_slots` |
| FUSE read | `lib/app/frontends/fuse/internal_ops.ml` `read` (no handle binding) |
| Android per-handle stream | `android_jni.ml` `read ~stream:handle` |
| macOS aligned partial fetch | `PartialRange.aligned`, `fetchPartialContents` → IPC `fetch_range` |

## Differences from the spec

- **Partial records are persisted** (`<group key>.manifest`, strict parser, empty record written
  before the first byte, publish chained per body). The spec keeps intervals in memory and
  removes partial bodies at owner start.
- **Concurrent disjoint fills over-claim.** `Partial.take` widens the current interval with any
  fetched span, so fills of `[0,4)` and `[10,12)` of one cold member claim `[0,12)`: zeros read
  as content, persisted, copied into staged edits and republished. The spec's `widen` never
  claims a gap.
- **Eviction does not reset memory.** `enforce_cap` unlinks body and record but leaves the
  in-memory intervals, so a fill that loaded before the eviction can publish a record claiming
  evicted bytes. The spec checks a per-body generation under a body lock.
- **No read-path verification.** Whole fetches check only sizes; staging copies inherited bytes
  through `read_into`, so a wrong-bytes store answer can be republished under new keys.
- **Per-consumer dedupe and slots.** `fetching` and `slots` live inside `Data.Make`, applied once
  per consumer (file ops, diagnostics, share server, export).
- **Pin after fetch**, so a cap sweep between the two drops the body and the pin silently fails.
- **Caller-sized range buffer**: `fetch_range` allocates the requested length up front.
- **No fsync before a whole body's rename.**
- **Per-read resolution in FUSE** (no handle lineage).
- `write_group` and `complete_body` fan out over every member unbounded at this layer; the wire
  pools below `Remote` are the real bound. A test that stubs the store above those pools sees an
  apparently unbounded fan-out; test bounds against the real store layer with a fake backend
  below it.

## Resource strategy (not normative)

The spec leaves concurrency widths and memory strategy to the implementation. The current code
uses, per data-layer instance:

| Knob | Value | Why |
|---|---|---|
| `DOWNLOADS` / `RANGES` wire pools | `max_downloads` (8) each, keyed by chunk prefix | a separate range pool keeps a 128 KiB demand read from waiting 6 s behind prefetch on a phone |
| `slots` (open destinations) | `max_downloads` | taken before the destination is opened; without it a 250 MB file opened 247 descriptors in 200 ms |
| `piece_slots`, `group_slots` | `4 × max_downloads` | pieces of one read; groups of one materialisation |
| read-ahead | `window = clamp(4 MiB / group bytes, 1, 8)`, current group + `window` ahead, at most 4 loops | one group ahead at defaults |
| stat walk pools | 64 entries, 16 directories | never nest a pool in itself |
| manifest memo | FIFO, 1024 per domain | each memo entry pins an `mmap`; unbounded, an import pinned 75 MB |
| fetch buffers | one `Bigstring` per member, allocated when bytes arrive | at most `(DOWNLOADS + RANGES) ×` chunk size in flight per domain |
| `fetch_range` / `assemble_to` copies | `fetch_range` allocates the requested length; `assemble_to` reads in `cache_chunk_size` blocks | a rewrite should copy in group-sized blocks |

Whole bodies and mirror entries are never modified in place, so reading them through an `mmap`
(as `Manifest.of_file` does for manifests) is safe.
