# Lazy read path and cache replacement

How the bytes of a file are materialised on demand from content-addressed chunks, and how the
local copy of those chunks is kept within a bound. Implementation-independent: concrete names
appear only in §10.

Sources: [04 §2.1, §4.3–4.5, §4.10–4.12, §6](../04-checkout-cache.md),
[02 §4.2, §6](../02-remote-model.md), [08 availability](../08-frontends.md),
[file-provider A5.3](../frontends/file-provider.md), [android](../frontends/android.md),
[09 §A6](../09-tests.md), [findings](../findings.md).

---

## 1. Problem and goals

A file is a *version*: an immutable ordered list of **stored chunks**, each named by a hash of
its bytes, plus a size. The store holds the chunks; nothing local is required to exist. A reader
asks for `[offset, offset+len)` of a named file and must get those bytes, fetching only what it
touches.

Goals:

- **G1 Correct bytes.** A read returns exactly the bytes of one version of the file, the one it
  resolved; never zeros standing for missing data, never bytes of another version, never a mix
  within one read.
- **G2 Pay for what is touched.** A small read of a cold file costs roughly one small request,
  not a whole chunk, and never a whole file.
- **G3 Streaming speed.** A sequential reader finds the next bytes already local.
- **G4 Latency isolation.** A reader waiting for its own bytes never queues behind prefetch or
  another reader's larger fetch.
- **G5 Bounded resources.** Local disk is held under a cap (except for explicitly pinned data);
  open descriptors, concurrent requests and memory are bounded by constants, not by file size,
  read size or reader count.
- **G6 No unpublished loss.** Nothing the cache does (eviction, crash recovery, refetch) can
  destroy the only copy of user data.
- **G7 Bounded waiting.** A read never blocks longer than a fixed deadline, even when the
  network is gone; abandoning a wait does not abandon the fetch.

Non-goals: integrity verification on the read path (§5.4, §8); caching directory metadata (the
mirror is a separate algorithm); refcounting shared bodies; persistence of access statistics;
exact LRU; cross-process coordination beyond what the filesystem gives.

## 2. System model and assumptions

- **A1 Content addressing.** A chunk name determines its bytes. Any copy of a chunk, anywhere,
  at any time, is interchangeable with any other. Two writers of the same chunk region write the
  same bytes. (Everything that lets the cache be lock-light follows from this.)
- **A2 Store operations.** `get(chunk) → bytes` and `get_range(chunk, off, len) → bytes`
  (exactly `len` bytes, short only at the chunk's end). Both may be slow, fail transiently, or
  hang indefinitely. The store is *not* assumed honest about bytes: it may return bytes that do
  not hash to the name (bit rot, a mangling link). A "fast" store (local disk) makes a whole
  chunk cost about as much as a range.
- **A3 Local filesystem.** Supports sparse files (an unwritten region reads as zeros), positional
  write, atomic rename, hard links (optional; some mobile storage refuses them), and mtime set
  by the caller. Durability is to a *process* crash (no fsync assumed, see §6).
- **A4 Other actors.** Several processes may share one cache directory (frontends, the converge
  process, CLI commands). Within a process, reads, fills, prefetch, eviction and promotion run
  concurrently. The implementation relies on a cooperative single-threaded scheduler for
  atomicity of in-memory updates between suspension points (§5.5).
- **A5 Version resolution is external.** A resolver answers, for a file, either a *published
  version* (chunk list) or a *staged edit* (a slot per chunk: inherited from a base version,
  a local staged body, or a hole) with its base version. Staged bodies live in a separate store
  the cache never touches.
- **A6 Clocks.** Wall clock for mtimes and pin deadlines; a monotonic timer for the read deadline.
  Clock steps can make pins lapse early or late; nothing correctness-critical depends on them.

## 3. State

Durable, on local disk (shared by every process on the machine):

| State | Meaning | Must live |
|---|---|---|
| **Group body** `B(g)` | one local file per *group* `g` (run of `per` consecutive stored chunks of a version), member `i` at `offset(i) = Σ size(j<i)`; sparse while partial | in the cache store, named by the group key |
| **Group key** | hash of the ordered member chunk names (not first/last: runs sharing ends differ inside) | name of `B(g)`; two files with the same run share one body |
| **Partial record** `R(g)` | beside `B(g)`; one interval `[a,b)` per member that holds anything | presence ⇔ body incomplete; absence ⇔ body whole |
| **Pin** `P(g)` | beside `B(g)`; its mtime is a deadline | follows the content, not the file |
| **Body mtime** | last read/publish time, coarsened to 60 s | the LRU order |
| Staged bodies | sole copy of unpublished bytes | a *different store*, unreachable by the cap |

Volatile, per process (must be one instance per process per cache root, §8 G-dup):

| State | Meaning |
|---|---|
| **In-flight table** | group key → the one running whole-group fetch, for joiners |
| **Held intervals (memory)** | group key → member intervals; the authority while the process runs, the record being its persisted shadow |
| **Publish chain** | group key → the last pending record write, serialising record writes per body |
| **Stream positions** | stream id → end of its last read (sequential detection) |
| **Held counts** | per cache root: files, bytes, pinned bytes, earliest pin deadline, anchored flag |
| **Link capability** | unknown / yes / no, probed once |
| Pools | see §7 |

Per-body state machine (the body, its record, its pin are the observable state):

```
ABSENT ──fill(range)──▶ PARTIAL{intervals} ──fill…──▶ PARTIAL ──last member whole──▶ WHOLE
ABSENT ──whole fetch (temp+rename)───────────────────────────────────────────────▶ WHOLE
PARTIAL ──complete (fetch missing members in place, then drop record)───────────▶ WHOLE
WHOLE ──forced refetch (temp+rename, replaces inode)─────────────────────────────▶ WHOLE
WHOLE ──promote(link of a staged body)───────────────────────────────────────────▶ WHOLE
PARTIAL ──promote: unlink body+record, then link────────────────────────────────▶ WHOLE
any ──evict/forget: unlink body, then record────────────────────────────────────▶ ABSENT
record without body ≡ ABSENT (reset on next fill)
```

There is no "verified" state: nothing on the read path rehashes (§5.4). "Whole" means *every
byte the manifest describes is on disk and sized right*, not *checked against its name*.

## 4. The algorithm

### 4.1 Units and why

- **Stored chunk** (default 8 MiB): the network and dedup unit; the unit of a whole fetch.
- **Group** (`per = round(cache_chunk / chunk)`, default 2 → 16 MiB): the **disk** unit, one
  file. Coarser than a chunk to keep file counts, directory fan-out and cap walks small; `per` is
  derived from the *version's own* chunk size so old versions group by their body.
- **Range** (a sub-interval of one member): the unit a *demand* read fetches, so a 4 KiB read
  costs a 4 KiB request (G2).
- **Piece**: the intersection of a read with one stored chunk; a read is served piece by piece.

Fetch granularity is thus split by intent: **demand reads fetch ranges; prefetch and explicit
materialisation fetch whole groups** (fewer, larger, cacheable requests; one round trip per
group since members are fetched concurrently).

### 4.2 Resolving a read

```
read(file, stream, buf, off):
  loop at most twice:                               // second pass only after "body vanished"
    v = resolve(file)                               // once per attempt: one version per read (G1)
    if v = none: return 0
    if v is staged: return read_staged(v, buf, off)
    return read_published(v.version, stream, buf, off)
  on ENOENT in attempt 1: retry (a promotion may have moved the bytes, §4.8)

read_published(ver, stream, buf, off):
  total = clamp(len(buf), 0, ver.size - off);  if total = 0: return 0
  pieces = split [off, off+total) at stored-chunk boundaries → (index, chunk_off, len, dest)
  concurrently, bounded by PIECE_SLOTS:
     for each piece p: served[p] = cache_read(group_of(p.index), p.index, buf[p.dest..], p.chunk_off)
  got = length of the leading run of complete pieces        // a short middle piece ends the count
  if position[stream] = off: start_prefetch(ver, last chunk read)
  position[stream] = off + got
  return got
```

Missing group for an index (a malformed chunk list) is an error, never zeros.

### 4.3 Serving one piece from the cache

```
cache_read(g, i, dst, coff):
  want = len(dst); at = offset_g(i) + coff
  if WHOLE(g):                         fetched = 0
  elif store.fast:                     within_deadline(ensure_whole(g))       // take the group
  else:                                fetched = within_deadline(fill(g, i, [coff, min(coff+want, size(i)))))
  n = pread(B(g), at, dst); touch(B(g))
  if n ≠ want or ENOENT:               // evicted under us, or the body was replaced
     within_deadline(ensure_whole(g, force=true)); n = pread(...)   // once; a second failure is real
  return n

within_deadline(work):
  start work detached; wait for its outcome at most READ_DEADLINE
  timeout ⇒ fail this reader (EIO); the work continues and still lands for the next read
```

**Rule R1 (never wait for another's whole fetch on a range read).** A demand read on a slow
store asks for its own range even when a whole-group fetch of the same group is in flight
(typically the prefetch). Duplicated bytes are bounded by the read and identical (A1).

### 4.4 Range fill (the partial body protocol)

```
fill(g, i, want=[c,d)):   under SLOTS (one open destination)
  here = exists(B(g))
  held = here ? load(g)               // memory first, else parse R(g); unparsable ⇒ nothing
              : (reset memory(g); nothing)   // a record whose body is gone is about nothing
  gap = missing(held[i], want); if none: return 0
  if not here: write R(g) := empty    // BEFORE the first byte (crash ⇒ claims less than disk)
  data = store.get_range(chunk(g,i), gap)             // ranges pool
  if data empty: return 0
  pwrite(B(g), offset_g(i) + gap.lo, data)            // creates/extends a sparse file
  memory(g)[i] := widen(memory(g)[i], [gap.lo, gap.lo+|data|))   // no suspension between read & write of memory
  publish(g): chained after the previous publish of g; when its turn comes, read memory(g):
     all members whole ⇒ delete R(g) (and drop memory)      // this is what makes the body WHOLE
     else ⇒ atomic-write R(g) := render(memory(g))
  return |data|

missing(have=[a,b), want=[c,d)):          // one interval per member, never a set
  none held → [c,d);  want ⊆ have → none
  d ≤ a → [c,a)   (fetch the hole between too);   c ≥ b → [b,d)
  c<a ∧ d>b → [c,d) (refetch the middle rather than split)
  c<a → [c,a);  else → [b,d)
widen(have, got) = [min, max]            // valid only if got touches or overlaps have (see §8 N1)
```

Worst case one read costs one gap inside one chunk; no interval algebra.

### 4.5 Whole-group fetch with in-flight dedupe

```
ensure_whole(g, force=false):
  if inflight[g.key] exists: await it; return {waited = entry.went_to_network, pulled = 0}
  entry = new; inflight[g.key] = entry          // inserted before any work can run
  try:
    if not force and WHOLE(g): return
    entry.went_to_network = true                // slot wait counts as network cost
    under SLOTS:
      if R(g) exists: for every member not held whole, concurrently: get, check size, pwrite at offset
                      then drop R(g)            // publishes as WHOLE; members a reader paid for are kept
      else:           temp := sized to group bytes (disk-full fails before paying for bytes)
                      concurrently: get each member, check size = manifest size, pwrite at offset
                      rename temp → B(g); drop any stale R(g)
  finally: remove inflight[g.key]
```

A size mismatch fails the whole write: nothing lands. Joiners get the owner's outcome; only the
owner is credited with bytes pulled (so progress is not counted N times).

### 4.6 Sequential detection and read-ahead

- A *stream* is a reader's identity (a descriptor/handle if the frontend has one, else the file).
  A read is sequential iff it starts exactly where that stream's previous read ended. The first
  read of a stream never prefetches.
- On a sequential read: from the group containing the last chunk read, walk `window + 1` groups
  in order (`window = clamp(READAHEAD_BYTES / group_bytes, 1, MAX_GROUPS)`; 1 at defaults, i.e.
  current group + next), calling `ensure_whole` on each, detached, errors swallowed. Skip if
  `MAX_LOOPS` prefetch loops are already running (spawn rate is the reader's; the count is ours).
- Prefetch is *sequential within a loop* and whole-group, using the whole-chunk pool, so it can
  never occupy the range pool a demand reader needs (G4).

Staged reads do not prefetch; their inherited pieces still go through §4.3.

### 4.7 Staged edits combined with published chunks

```
read_staged(edit, base, buf, off):
  whole-file staged body ⇒ read it directly (short = EOF)
  else per piece i:
    Staged(body, boff) ⇒ read body at boff+chunk_off; past its end ⇒ zeros (a body is only as
                          long as the writes that reached it; the edit's size is authoritative)
    Zero               ⇒ zeros
    Inherit            ⇒ cache_read(group of i in base, …)   // no base ⇒ error, never zeros
```

A write that must stage a group with inherited members copies them *through* `cache_read`, so
the cache's bytes become the staged edit's bytes and then a newly published chunk (§8 N1 impact).

### 4.8 Cooperation required from other actors

- **Promotion (writer side).** Publishing a staged group into the cache is a *hard link* of the
  staged body under the group key (fallback: write the group whole). If a partial body occupies
  the name it is unlinked with its record first; the link is dated now (else the cap sees it as
  old as the write). Order: groups into the cache → published version visible → staged edit
  removed → staged bodies forgotten. A reader that resolved either representation finds its
  bytes, and one ENOENT retry of the whole read covers the flip.
- **Resync / namespace changes** never touch the cache (content-addressed, still valid).
- **Evict(file)** forgets every group of its published version, reference-blind: a body shared
  with another file goes too and is re-fetched on demand.
- **Explicit materialisation** (pin, assemble to a path): plan the groups still owed (published:
  all; staged: groups with an inherited member), `ensure_whole` each under GROUP_SLOTS, then for
  pinning set `P(g)` deadline = now + keep on each (a pin needs a body to stand beside).
  Assembly then reads through §4.2.
- **Partial-range frontends** (macOS dataless files) round the requested range outward to the
  system's alignment (start down, end up, clamp at EOF), then call a range read into the
  destination at the same offset; bytes outside stay sparse. An empty range is answered as
  "version gone", not sent.

### 4.9 Replacement

```
held counts: maintained on every write into a body name (size before/after delta; new file +1),
             link, forget, pin/unpin; anchored by one full walk per process (or reset if the root is gone)

enforce_cap():            // triggers: after each upload, and every HOUSEKEEPING_INTERVAL
  anchor()
  if now < earliest_pin_deadline and not (cap set and bytes − pinned_bytes > cap): return
  walk all bodies (skip records; pins give deadlines)
  unlink lapsed pins; recount exactly from the walk
  if over cap:
     candidates = unpinned bodies, sorted by mtime ascending
     while bytes − pinned_bytes > cap: unlink body, THEN its record
```

- Counts: bodies (whole or partial, by file size), not records, not pins, not staged bodies.
- Pinned bytes neither count nor are evicted; a pin lapses at its deadline and is removed by the
  next sweep, after which the body is an ordinary candidate.
- LRU approximation: mtime, refreshed by a read only when older than TOUCH_INTERVAL.
- **Staged bytes cannot be evicted because they are in a different store** — not because a filter
  spares them. After promotion a published body may share an inode with a staged body; unlinking
  the cache name leaves the staged name intact, and after the staged name is gone the bytes are
  published and re-fetchable.

### 4.10 Availability (derived)

`held(g)` ⇔ WHOLE(g). A file is *pinned* if every group is held with a live pin, *cached* if
every group is held, else *online-only* (a partly cached file reads online-only). Staged files
are cached.

## 5. Properties and why they hold

### 5.1 Safety: bytes match the version resolved (G1)

Claim: a published read returns bytes whose hash-named source is the resolved version's chunk
list, given an honest store.

- *Naming.* A body is named by the hash of its members' names, so a body can only ever be filled
  with bytes of those chunks (A1). Two versions never alias a body unless they share the exact
  run, in which case the bytes are equal.
- *Placement.* Every write lands member `i`'s bytes at `offset(i)+x` for chunk-local `x`; whole
  fetches check each member's size; ranges are read at chunk-local offsets.
- *No zeros for missing data.* The invariant **I1: every interval a record (or the memory table)
  claims is on disk** plus **I2: a body without a record is whole** make every served byte real:
  a reader reads only after `missing` returned none (claimed) or after its own fill wrote the
  range, or after a whole fetch/rename. I1 is kept by: empty record before first byte; widen
  after bytes land; eviction removes body before record (a record without body reads as empty);
  promotion removes a partial body before linking. **I1 is violated by two interleavings (§8 N1,
  N2).**
- *One version per read.* Resolution happens once per attempt; the retry re-resolves and re-reads
  the whole buffer. Across reads of one open descriptor, versions may change (§8 N3).
- *Short reads.* A missing/short piece ends the count at the leading run of complete pieces, so
  a hole is never reported as read.

### 5.2 Safety: eviction never loses unpublished data (G6)

Staged bytes live in a separate store the cap, evict and forced refetch cannot address. Cache
bodies are projections of published chunks (A1: re-fetchable). Promotion links rather than
renames, so at no instant is the only name of unpublished bytes in the cache. Holds structurally.
(Staged-store losses exist but belong to the write path: findings F7, F9, F10.)

### 5.3 Liveness and bounded waiting (G7, G3)

- Every foreground wait is `within_deadline`: after READ_DEADLINE the reader gets EIO; the fetch
  continues detached and completes the body for the next read (offline read fails fast, then
  succeeds once online).
- A body stuck PARTIAL completes on the next `ensure_whole` (prefetch, materialisation).
- In-flight entries are removed in a `finally`, so a failed or cancelled owner does not wedge
  joiners forever; joiners observe the failure.
- A cold sequential stream: the second read prefetches current + next group; afterwards each
  crossing into a new group fetches one further ahead (G3). Bounded concurrency means a slow store
  degrades throughput, not correctness.

### 5.4 Integrity (what is *not* guaranteed)

Plain reads never rehash. Whole fetches check only size; range fills cannot check anything (a
chunk name covers the whole chunk). A store returning wrong bytes of the right length is served
to readers, cached, and — via §4.7 staging copies — republished under new honest names. Only
verified fetch (export), `gc --verify` and repair rehash (09 §A6). A correct version must either
accept this explicitly or verify: whole fetches can rehash for free (bytes are in memory);
ranges would need a per-chunk sub-hash tree in the manifest.

### 5.5 Concurrency argument

Relies on the cooperative scheduler: (a) the in-flight lookup-then-insert, (b) `widen` of the
memory table, (c) publish-chain append, (d) held-count deltas have no suspension point inside.
Under preemptive threads each becomes a critical section; `widen` + `publish` for one body must
be one. Concurrent *writers* of the same region are harmless by A1; concurrent fills of different
regions are correct only if widen is (§8 N1).

### 5.6 Bounds (G5)

Disk: `bytes − pinned ≤ cap` after each sweep; overshoot between sweeps ≤ what is read in one
HOUSEKEEPING_INTERVAL plus drift from other processes; pinned bytes unbounded by design (user
asked). Descriptors: ≤ SLOTS open destinations for fills and group fetches. Wire: ≤ DOWNLOADS
whole-chunk requests + ≤ RANGES range requests per domain per process (the pools are per
domain prefix, shared by every consumer). Memory: a whole fetch holds up to one group of chunk
buffers per slot (SLOTS × group bytes = 128 MiB at defaults); a read holds its caller's buffer.
Exception: the caller-sized range copy (§8 N4).

## 6. Failure, crash and resume

| Interrupted at | Left on disk | Next behaviour |
|---|---|---|
| fill: before empty record | nothing | fill starts over |
| fill: after empty record, before/after pwrite | record `{}` (claims nothing) + maybe bytes | bytes re-fetched on demand; harmless waste |
| fill: after pwrite, before record update | record claims less than disk | refetch of that range; I1 holds |
| record write torn | unparsable record | strict parser ⇒ "holds nothing"; I1 holds |
| whole fetch before rename | temp file | temp sweep (dead pid) |
| complete-in-place before record drop | partial body, record claims less | next ensure completes it |
| eviction between body unlink and record unlink | record without body | read as ABSENT, reset on next fill |
| promotion mid-way | see write path (04 §4.7); cache side is idempotent (EEXIST ⇒ done) | |
| pin after fetch, cap in between | body gone, pin skipped | file reads online-only, re-pin needed (not detected) |
| read deadline expires | fetch still running | next read finds the bytes |
| power loss | renames may persist before data (no fsync): zero-length record ⇒ "holds nothing" (safe); a whole body renamed before its data ⇒ **zeros read as whole** (F8) | |

Every cache step is idempotent: re-running a fill re-asks `missing`; a whole fetch of a whole body
is a no-op; linking an existing name succeeds; forget of an absent body is a no-op.

## 7. Parameters

| Name | Value | Effect / trade-off |
|---|---|---|
| CHUNK_SIZE | 8 MiB (per version) | network/dedup unit; larger = fewer requests, costlier whole fetches, worse dedup |
| CACHE_CHUNK (group) | 16 MiB → `per = 2` | files on disk vs prefetch granularity and eviction granularity |
| DOWNLOADS | `max_downloads` = 8 | concurrent whole-chunk requests per domain |
| RANGES | `max_downloads` = 8 | concurrent demand ranges; separate so prefetch cannot starve readers |
| SLOTS | `max_downloads` = 8 | open destinations (fills + group fetches) per consumer; without it 247 fds in 200 ms |
| PIECE_SLOTS | 4 × max_downloads | pieces of one read in flight; bounds caller-sized fan-out |
| GROUP_SLOTS | 4 × max_downloads | groups of a materialisation queued at once |
| READ_DEADLINE | 15 s | EIO latency when offline vs spurious failures on a slow link |
| READAHEAD_BYTES / MAX_GROUPS / MAX_LOOPS | 4 MiB / 8 / 4 | lookahead depth (1 group at defaults) vs wasted bandwidth on seeks |
| TOUCH_INTERVAL | 60 s | LRU resolution vs one inode write per read |
| CAP | unset (unlimited) by config; wizard proposes 1 GiB | disk vs refetch cost |
| HOUSEKEEPING_INTERVAL | 60 s | cap overshoot window vs walk cost (walk only when over or a pin lapsed) |
| PIN_KEEP | 10 days | offline guarantee duration |
| stat pools (walk) | 64 entries / 16 directories | cap walk speed vs fd use; two pools because nesting one deadlocks |

## 8. Known gaps

- **N1 (new, from code reading; not reproduced) — concurrent disjoint fills over-claim.** A fill
  computes its gap against the `held` it loaded, then suspends on the network; `widen` applies
  its fetched span to the *current* memory interval. Two fills of one member with disjoint wants
  (`[0,4)` and `[10,12)` on a cold member) end with a claimed `[0,12)` whose middle was never
  written: sparse zeros served as content, persisted in the record, copied into staged edits and
  republished. Fix: widen only when the new span touches or overlaps the current interval,
  otherwise keep the current interval (claim less); or hold one fill per (body, member).
- **N2 (new, from code reading) — eviction during a fill resurrects stale claims.** The cap
  unlinks the body and record but not the in-memory intervals; a fill that loaded before the
  eviction pwrites into a freshly created sparse body, widens the stale memory, and publishes a
  record claiming the evicted intervals. Fix: eviction must reset memory for that group, and a
  fill must re-check that the body it loaded against is the one it writes (e.g. inode or a
  generation counter) before widening.
- **N3 — "the version it opened" is per read call, not per open.** FUSE resolves the file on
  every read with no stream id; a peer update applied between two reads of one descriptor mixes
  versions in what the application sees, and `assemble_to` loops over reads the same way (a
  materialised copy can be torn across versions). The share server holds one manifest per
  response and is consistent. Fix: resolve at open and read that version for the handle's life
  (bodies are content-addressed, so the old version stays readable while re-fetchable).
- **N4 — caller-sized buffer.** A range copy allocates the requested length up front; the IPC
  verb bounds it only by `length > 0`. Fix: copy in group-sized blocks.
- **N5 — no read-path verification** (09 §A6): corruption flows to readers and into republished
  chunks (§5.4).
- **N6 — per-consumer dedupe and slots** (04 §9.5): each data-layer instance in a process has its
  own in-flight table and SLOTS, so two consumers can fetch one group twice and hold 2×SLOTS
  descriptors; wire pools are shared, so the wire bound holds.
- **N7 — cross-process counts drift** (by design, `ponytail` note): another process's writes and
  evictions are not seen until a walk; overshoot costs disk only.
- **N8 — fan-out below SLOTS.** A group fetch fans out over all its members unbounded at the
  cache layer; the wire pools are the bound. A test stubbing the store above those pools sees an
  apparently unbounded fan-out (memory note *read-path pools*): test bounds against the real
  store layer with a fake backend below it.
- **N9 — pin after fetch is not atomic with the cap**; a pin can silently not happen. Pin before
  fetch with a marker the cap honours even for an absent body, or re-check after pinning.
- **N10 — power loss** (F8): no fsync; a renamed-before-data whole body reads as whole zeros.
- **N11 — availability is binary** (04 §9.6): a partly cached file is online-only.
- Publish-chain entries for bodies that stay partial are never freed (04 §9.7): bounded by distinct
  partial bodies seen per process.

## 9. Alternatives and why this design

| Choice | Alternative | Reason |
|---|---|---|
| Ranges for demand, whole groups for prefetch | all-or-nothing bodies | a few-byte read cost 16 MiB (b0ea0213, 00585588) |
| One interval per member | interval sets | worst case one gap per read; no algebra (b0ea0213) — at the price of N1 |
| Record absent ⇔ whole | flag inside the body | keeps "name exists ⇒ whole" for every existing caller (9f41023b) |
| Never join a whole fetch on a range read | join in-flight | 100 KB turned into seconds; phones lost FUSE descriptors (6bd091b6) |
| Separate range pool | one download pool | 128 KiB read behind 8 × 1 MiB prefetches = 6 s on a phone (ff9b1855) |
| Detached fetch + deadline | retry ladder / cancel on timeout | suspend froze 44 s with the link down; cancellation would fail joiners (0f9a529e) |
| Descriptor slots at the cache | rely on wire pools | destinations opened before the wire slot: 247 fds in 200 ms (eb40957d) |
| Prefetch ahead of, not alongside, the reader | prefetch from current chunk | (96e990ea) |
| Fast stores take the whole group | ranges everywhere | same cost, better cache (f18f85db) |
| LRU by coarse mtime | atime, access log | no inode write per read (6c654bc9) |
| In-process counts + one walk | walk every time; persisted counts | status polls walked 4096 shards (82e0adea) |
| Pin = marker whose mtime is the deadline | per-file pin list | follows content, shared across files (9b794f0c) |
| Staged in a separate store | spare staged in the cap | eviction *cannot* reach sole copies (2d0f0fc9, 75c90fdd) |
| Promote by hard link | rename / copy | both names readable across the flip; half the local writes (99ec3cb6) |
| Reference-blind evict | refcounts | re-fetch is cheap; refcounts are state to corrupt |
| Plausible: verify on whole fetch | — | costs one hash of bytes already in memory; would close N5 for prefetched data |

## 10. Mapping to the current implementation

| Abstract | Concrete | Spec |
|---|---|---|
| group, group key, `per`, offsets | `Manifest.Group`, `Conf.chunks_per_group` | [04 §2.1](../04-checkout-cache.md) |
| body / record / pin paths | `chunks/<xxx>/<group key>`, `.manifest`, `.pin` via `Cache_layout` | 04 §2.2–2.3 |
| read (§4.2), retry on ENOENT | `Data.pread_key`, `Data.pread`, `serve_pieces`, `Chunks.pieces` (`lib/domain/checkout/content/data.ml`) | 04 §4.11 |
| cache_read (§4.3), within_deadline, touch | `Chunk_cache.read_into`, `within_deadline`, `touch` (`lib/domain/checkout/chunks/chunk_cache.ml`) | 04 §4.3 |
| fill, missing, widen, publish chain | `Chunk_cache.fill`; `Partial.missing/widen/take/publish/start/load/reset` (`chunks/partial.ml`) | 04 §4.4 |
| ensure_whole, in-flight table | `Chunk_cache.ensure_fetched`, `fetching`, `fetch`, `complete_body`, `write_group` | 04 §4.4 |
| read-ahead | `Data.read_ahead`, `last_read_end`, `readahead_in_flight` | 04 §4.11 |
| staged combination | `Data.pread_staged`/`pread_chunked`; resolver `Manifests.current` | 04 §4.5 |
| promotion hand-over | `Chunk_cache.link_in`, `put_group`, `links_supported`; `Data.promote` | 04 §4.7 |
| materialisation, pin | `Data.fetch_plan`, `fetch_groups`, `ensure_local`, `assemble_to`, `fetch_range`; `Chunk_cache.pin/unpin/forget` | 04 §4.10 |
| cap | `Chunk_cache.enforce_cap`, `anchor`, `counted_write`, `held_for`; triggers in the domain engine (`housekeeping_interval = 60`) | 04 §4.12 |
| availability | `Checkout.availability` | [08](../08-frontends.md) |
| DOWNLOADS / RANGES pools, verified fetch | `Remote.pools_for` (`downloads`, `ranges`, keyed by chunk prefix); `Chunk_store.fetch/fetch_range/fetch_verified` | [02 §4.2, §6](../02-remote-model.md) |
| SLOTS, PIECE_SLOTS, GROUP_SLOTS | `Chunk_cache.slots`, `Data.piece_slots`, `Data.group_slots` | 04 §2.5, §6 |
| FUSE read (no stream) | `lib/app/frontends/fuse/internal_ops.ml` `read` | 08 |
| Android per-handle stream | `android_jni.ml` `read ~stream:handle` | [android](../frontends/android.md) |
| macOS aligned partial fetch | `PartialRange.aligned`, `fetchPartialContents` → IPC `fetch_range` | [file-provider A5.3](../frontends/file-provider.md) |
| share server consistent reads | `share_server.ml` `D.pread ~manifest` (one manifest per response) | 08 |
| tests | `tests/content/{chunk_cache,demand_paging,fetch_range,read_ahead,read_fanout,fetch_fanout,cache_cap,partial_local,promote_race,read_offline,verified_fetch,corruption}`, `tests/unit/{partial_intervals,demand_ranges,chunk_pools}` | 04 §8, [09](../09-tests.md) |
