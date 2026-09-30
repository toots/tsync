# Read path and chunk cache

How a file's bytes are served on demand from content-addressed chunks, how fetched bytes are
verified, how sequential readers are kept ahead of, and how the local copy of chunks is bounded.

The cache files' spellings are in [04](../04-checkout-cache.md) §2.7; version resolution, read
handles and staged content are in [04](../04-checkout-cache.md) §3.3, §4.2 and §4.3; the durable
write primitives are in [durable-queue](durable-queue.md) §3.2.

---

## 1. Goals

- **G1. Correct bytes.** A read returns exactly bytes of the content its handle is bound to:
  never zeros standing for missing data, never another version's bytes, never a mix of versions
  within one handle's lineage ([04](../04-checkout-cache.md) §3.3).
- **G2. Pay for what is touched.** A small read of a cold file costs about one small request,
  never a whole chunk or file.
- **G3. Streaming speed.** A sequential reader finds its next bytes already local.
- **G4. Latency isolation.** A reader waiting for its own bytes never queues behind prefetch or
  behind another reader's larger fetch.
- **G5. Bounded disk.** Cache disk is held under a cap, except for pinned data.
- **G6. No unpublished loss.** Nothing the cache does can destroy the only copy of user data.
- **G7. Bounded waiting.** A read never waits longer than `READ_DEADLINE`, even offline;
  abandoning a wait does not abandon the fetch.
- **G8. Nothing unverified is republished.** Bytes that leave this machine inside a new
  publication come only from verified or locally written sources.

**Non-goals.** Caching directory metadata (the mirror is separate); reference counting of
shared bodies; exact LRU; persisting access statistics.

## 2. Model and assumptions

- **A1. Content addressing.** A chunk key determines its bytes. Any correct copy of a chunk is
  interchangeable with any other, and two writers of the same region of a body write the same
  bytes.
- **A2. Store operations.** `get(chunk)` and `get_range(chunk, offset, length)`, the latter
  answering exactly `length` bytes or fewer only at the chunk's end
  ([06](../06-backends.md)). Both may be slow, fail, or hang. The store is **not** trusted to
  return correct bytes: it may return bytes that do not hash to the key (bit rot, a mangling
  path). A *fast* store (local disk) makes a whole chunk cost about as much as a range.
- **A3. One writer.** Only the domain's owner reads into or writes the cache (P1). Inside the
  owner, reads, fills, prefetch, eviction and promotion run concurrently; the per-body lock of
  §3.2 serialises what must be.
- **A4. Clocks.** Pin deadlines and body mtimes are wall time (they are stored); the read
  deadline and every duration are monotonic (P5). A wall-clock step can make a pin lapse early
  or late; nothing correctness-critical depends on it.

## 3. State

### 3.1 On disk

| State | Meaning |
|---|---|
| **Whole body** `B(g)` | the group's bytes in group layout ([04](../04-checkout-cache.md) §2.2). Exists ⇒ whole and verified |
| **Partial body** `P(g)` | a sparse file in group layout, filled by range fetches; meaningful only with the owner's memory of what it holds |
| **Pin** `N(g)` | its mtime is a deadline; may exist without a body |
| **Body mtime** | the last read or install time, refreshed at most every `TOUCH_INTERVAL`: the LRU order |

Staged bodies live in a different tree that nothing here addresses.

### 3.2 In the owner's memory (one instance per domain per owner)

Every consumer inside the owner (the file operations, the request handler, materialisation)
shares these; none of them is per consumer, so one group is never fetched twice at once.

| State | Meaning |
|---|---|
| **Body lock** per group key | serialises every change of what a group's files are: creating or removing `P(g)`, recording held intervals, installing or removing `B(g)`, eviction |
| **Generation** per group key | incremented under the body lock whenever `P(g)` or `B(g)` is removed or replaced |
| **Held intervals** per group key | for each member of `P(g)`, one interval `[a, b)` of chunk-local bytes known to be on disk in `P(g)`'s current inode |
| **In-flight table** | group key → the one running whole-group fetch, for joiners |
| **Stream positions** | read handle → end of its last read |
| **Counts** | bytes held, pinned bytes, earliest pin deadline |
| **Link capability** | unknown, yes or no, for the cache root ([04](../04-checkout-cache.md) §4.8) |

### 3.3 Per group

```
ABSENT ──range fill──▶ PARTIAL ──fills…──▶ PARTIAL ──every member held, verified──▶ WHOLE
ABSENT ──whole fetch, verified (temp, fsync, rename)──────────────────────────────▶ WHOLE
PARTIAL ──whole fetch of the missing members, verified, install───────────────────▶ WHOLE
WHOLE ──forced refetch (new inode)────────────────────────────────────────────────▶ WHOLE
ABSENT or PARTIAL ──promotion hard link of a staged body──────────────────────────▶ WHOLE
PARTIAL or WHOLE ──evict, forget, cap──────────────────────────────────────────────▶ ABSENT
owner start: every PARTIAL ──────────────────────────────────────────────────────▶ ABSENT
```

At owner start every cache file that is not a whole body or a pin is removed
([04](../04-checkout-cache.md) §2.7, §4.10). The owner MAY re-verify any whole body and removes
one that fails.

---

## 4. The algorithm

### 4.1 Units

- **Chunk** (default 8 MiB): the network and dedup unit, and the unit of verification.
- **Group** (`per` chunks, default 2): the disk unit, one file. Coarser than a chunk to keep file
  counts and cap walks small.
- **Range**: a sub-interval of one member, the unit a demand read fetches (G2).
- **Piece**: the intersection of a read with one chunk; a read is served piece by piece.

Demand reads fetch ranges; prefetch, materialisation and staging copies fetch whole groups,
which are verifiable and cacheable.

### 4.2 Reading through a handle

```
read(handle, off, buf):
  c := handle's current content                        # 04 §3.3
  if c is a staged edit: return read_staged(c, off, buf)   # 04 §4.3
  total := clamp(len(buf), 0, c.size − off); if total = 0: return 0
  pieces := split [off, off+total) at chunk boundaries
  serve every piece (concurrently or not): cache_read(group of piece, piece)
  got := length of the leading run of complete pieces      # a short middle piece ends the count
  if position[handle] = off: start_prefetch(c, last chunk read)
  position[handle] := off + got
  return got
```

A read is short only at the end of the content. A missing group for a chunk index is CORRUPT.

### 4.3 Serving one piece

```
cache_read(g, i, dst, coff):
  within_deadline:
    if B(g) exists:            fd := open B(g)
    elif store is fast:        ensure_whole(g); fd := open B(g)
    else:                      fd := fill(g, i, [coff, min(coff + len(dst), size(i))))
  n := pread(fd, offset_g(i) + coff, dst); touch(g)
  if n ≠ len(dst):             # the body was replaced or damaged under us
    within_deadline: ensure_whole(g, force = true); fd := open B(g); n := pread(...)
    if n ≠ len(dst): CORRUPT
  return n

within_deadline(work):
  run work detached; wait for its outcome at most READ_DEADLINE (monotonic)
  on expiry: this reader fails with DEADLINE; the work continues and lands for later readers
```

- **R1. A range read never waits for another's whole fetch.** A demand read on a slow store
  fetches its own range even while a whole-group fetch of the same group is in flight
  (typically prefetch). The duplicated bytes are bounded by the read and identical (A1).
- A reader reads through a descriptor opened at a moment its range was held, so an eviction or
  replacement after that moment cannot take its bytes away: an unlinked inode stays readable.
- `touch(g)` sets the body's mtime to now if it is older than `TOUCH_INTERVAL`.

### 4.4 Range fill

```
fill(g, i, want):
  loop:
    with body_lock(g):
      if B(g) exists: return open B(g)
      gen := generation(g)
      gap := missing(held(g, i), want)
      if gap = none: return open P(g)
      if P(g) absent: create P(g) empty and sparse; held(g, ·) := none
    data := store.get_range(chunk(g, i), gap)        # no lock held
    with body_lock(g):
      if generation(g) ≠ gen or P(g) absent: continue loop     # evicted or replaced meanwhile
      pwrite(P(g), offset_g(i) + gap.lo, data)
      held(g, i) := widen(held(g, i), [gap.lo, gap.lo + |data|))
      if every member of g is held whole: install_from_partial(g)     # §4.5
      return open (B(g) if it exists, else P(g))
```

`missing(have, want)` answers one interval per member, never a set:

```
have = none                       → want
want ⊆ have                       → none
want = [c,d), have = [a,b):
  d ≤ a                           → [c, a)       (fetch the hole between too)
  c ≥ b                           → [b, d)
  c < a and d > b                 → [c, d)       (refetch the middle rather than split)
  c < a                           → [c, a)
  otherwise                       → [b, d)
```

`widen(have, got)` is the union when the two intervals touch or overlap; when they are disjoint
it keeps whichever is longer (the current one on a tie). It never claims the gap between them.

**Invariant I1.** Every interval held in memory for `P(g)` is on disk in `P(g)`'s current
inode. It holds because an interval is widened only after its bytes were written, under the
body lock, after checking that the generation (hence the inode) is the one the fill started
against, and because nothing about a partial body survives the owner: partial bodies are
removed at owner start ([04](../04-checkout-cache.md) §4.10).

### 4.5 Whole-group fetch, verification and install

```
ensure_whole(g, force = false):
  if in_flight[g] exists: await it; return (the joiner is credited with nothing)
  in_flight[g] := this fetch            # inserted before any work can start
  try:
    if not force and B(g) exists: return
    do:
      if not force and P(g) exists:     # complete in place
        for each member not held whole: fetch_verified(member);
          with body_lock(g): if generation changed: restart ensure_whole; pwrite; held := whole
        install_from_partial(g)
      else:                             # fresh body
        temp := a temporary file for the group
        for each member: pwrite(temp, offset, fetch_verified(member))
        fsync(temp)
        with body_lock(g): rename temp → B(g); remove P(g) if any; forget held(g); generation(g)++
  finally: remove in_flight[g]

fetch_verified(member):
  bytes := store.get(chunk)
  require |bytes| = member size and hash(bytes) = chunk key, else CORRUPT
  return bytes

install_from_partial(g):                # under body_lock(g)
  for each member whose bytes came, in whole or in part, from range fills:
    read it back from P(g); require hash = chunk key
  on a mismatch: remove P(g); forget held(g); generation(g)++; answer "mismatch"
  else: fsync(P(g)); rename P(g) → B(g); forget held(g); generation(g)++

A caller told "mismatch" releases the body lock and runs ensure_whole(g, force = true) once;
that fetch verifies every member itself, so its failure (CORRUPT if the store's bytes are
wrong) is the answer.
```

A size or hash mismatch lands nothing. CORRUPT is propagated per
[failure-model](failure-model.md) (the chunk's corruption marker and repair are
[02](../02-remote-model.md) and [replication](replication.md)); it is never retried as
TRANSIENT and never served. Promotion installs a group by hard link instead
([04](../04-checkout-cache.md) §4.8); its bytes are the bytes the upload hashed.

### 4.6 Verification

- **V1.** Every whole chunk fetched from a store is hashed and compared with its key before any
  of its bytes is written (§4.5).
- **V2.** A member assembled from range fills is verified when its body becomes whole, before
  the body is installed (§4.5). A whole body is therefore always verified.
- **V3.** Bytes served from a partial body are **unverified**: a range cannot be checked against
  a key that covers the whole chunk. They reach only readers on this machine.
- **V4.** Any operation that turns cached bytes into bytes of a new publication (staging an
  inherited member, [04](../04-checkout-cache.md) §4.3; export verification in
  [05](../05-ops-config.md)) reads them only from a whole body, fetching it whole if needed.
  Hence G8.
- **V5.** Whole bodies are not re-hashed on every read: verification happened at install, and
  the install's fsync before rename keeps a power loss from leaving an unwritten body under the
  final name.
- The chunk key is a non-cryptographic hash. Verification detects accidental corruption, not a
  store that deliberately crafts colliding bytes; the threat model is
  [security-model](security-model.md).

### 4.7 Sequential detection and read-ahead

- A read is sequential iff it starts exactly where its handle's previous read ended; a
  handle's first read never prefetches.
- On a sequential read the owner SHOULD fetch whole, detached, the group holding the last chunk
  read and at least the next one. How far ahead, and how many prefetches run at once, is the
  implementation's choice. Prefetch errors are logged, never raised to a reader.
- Prefetch MUST NOT delay a demand read (G4): a range read is served while prefetches of the
  same file are in flight, whatever capacity they hold.
- Reads of staged content do not prefetch; their inherited pieces still go through §4.3.

### 4.8 Materialisation and pinning

- **Plan**: a published version needs all its groups; a staged edit needs the base groups that
  hold an Inherit member; a staged edit without base needs none. On a lazy tree, a file absent
  from the mirror has its manifest fetched and recorded first.
- **`pin(key, keep)`**:
  1. For every planned group, durably create or update `N(g)` with deadline `now + keep`
     **before** fetching, so the cap cannot evict a group between its fetch and its pin. A pin
     is attached to content: it follows the content across renames and is shared by every file
     using that body.
  2. `ensure_whole` every planned group.
  3. Acknowledge once every group is whole. A failure leaves the pins in place (a later retry
     or the cap's lapse removes them).
- **`unpin(key)`** removes the pins of the key's groups (reference-blind, like `evict`).
- **`assemble_to`** fetches the plan whole, then reads the content through one read handle into
  the destination. Its progress covers both the fetch and the
  assembly; concurrent materialisations of one key report as one.
- **`fetch_range`** reads only the covering pieces through one handle into the destination.
- A whole body is never modified in place (it is only created by rename or link and removed), so
  a reader SHOULD read it through a read-only mapping. A partial body is written in place while
  it fills; a reader MAY map it, and reads only intervals that I1 guarantees.

### 4.9 Replacement (the cap)

```
counts: maintained by every create, write, install, link, removal, pin and unpin of cache files;
        anchored by one walk of the cache tree per owner (lazily after owner start)

enforce_cap():            # after every upload, and every HOUSEKEEPING_INTERVAL
  if now < earliest_pin_deadline and not (CAP set and bytes − pinned > CAP): return
  walk: bodies (whole and partial), pins
  remove lapsed pins (deadline < now); recount exactly from the walk
  if CAP set and bytes − pinned > CAP:
    candidates := bodies without a live pin, by mtime ascending (coldest first)
    for each, while bytes − pinned > CAP:
      if body_lock(g) is free: take it; remove the body; forget held(g); generation(g)++
```

- Bytes are counted by allocated size where the filesystem reports it, else by apparent size.
  Pins and staged bodies count nothing.
- Pinned bodies are neither evicted nor counted against the cap; pinned bytes are unbounded by
  design (the user asked).
- A body under a running fill or install is skipped, not waited for.
- The cap cannot reach staged bytes: they are in another tree. A cache body that shares an inode
  with a staged body loses only its cache name.
- With no cap configured nothing is evicted; lapsed pins are still removed.

---

## 5. Properties

- **Safety of bytes (G1).** A body is named by the digest of its member keys, so it can only
  ever hold bytes of those chunks; whole fetches check each member's size and hash; every range
  lands at the member's chunk-local offset. A reader reads either a whole body (verified, V1–V2),
  or a partial body's range that I1 guarantees is on disk, or bytes its own fill wrote. A short
  piece ends the count, so a hole is never reported as read. One handle reads one lineage
  ([04](../04-checkout-cache.md) §3.3).
- **No unpublished loss (G6).** Staged bytes are in a tree the cap, evict and forced refetch
  cannot address; promotion links rather than renames, so at no instant are unpublished bytes
  only in the cache.
- **Liveness (G3, G7).** Every foreground wait is bounded by `READ_DEADLINE`; the detached fetch
  completes the body for the next read. In-flight entries are removed in a `finally`, so a
  failed fetch never wedges its joiners. A fill that finds its body replaced starts over, within
  the reader's deadline.
- **Concurrency.** The in-flight insertion, the held-interval widen, the generation check and
  every cache file change are each one critical section (the body lock, or the in-flight table's
  own atomic insert). Concurrent fills of disjoint ranges of one member are correct because
  `widen` never claims a gap.

## 6. Crash and power loss

| Interrupted at | Left on disk | Next behaviour |
|---|---|---|
| any point of a range fill | a partial body | removed at owner start |
| a fresh whole fetch before its rename | a temporary file | removed at owner start ([04](../04-checkout-cache.md) §4.10) |
| an install from a partial body | the partial body, or the whole body (after the rename) | removed, or whole and verified |
| an eviction | the body gone or still there; a pin, if any, untouched | consistent either way |
| a pin before its fetch | a pin without a body | the next pin or the cap's lapse handles it |
| a promotion | [04](../04-checkout-cache.md) §4.7 replays it; linking an existing name succeeds | |
| power loss | whole bodies were fsynced before their rename; partial bodies are discarded anyway | no body under a whole name holds unwritten bytes |

Every cache step is idempotent: a fill re-asks `missing`, a whole fetch of a whole body does
nothing, linking an existing name succeeds, forgetting an absent body succeeds.

## 7. Bounds and parameters

**Disk**: `bytes − pinned ≤ CAP` after each sweep; overshoot between sweeps ≤ what is read in one
`HOUSEKEEPING_INTERVAL`. How many requests, descriptors and buffers a fill or fetch uses at once
is the implementation's choice ([01](../01-core.md), P6).

| Name | Recommended | Constraint / effect |
|---|---|---|
| `READ_DEADLINE` | 15 s | EIO latency offline vs spurious failures on a slow link |
| `TOUCH_INTERVAL` | 60 s | LRU resolution vs one inode write per read |
| `CAP` | unset (unlimited); the config wizard proposes 1 GiB | disk vs refetch cost |
| `HOUSEKEEPING_INTERVAL` | 60 s | cap overshoot window |
| `PIN_KEEP` | 10 days | default offline duration of a pin |

## 8. Conformance

An implementation MUST exhibit the following.

- Two concurrent whole fetches of a cold group issue one request per member; the first caller is
  credited with the bytes, the joiner with none.
- Reading 4 bytes of member 0 of a group of members sized 4, 4 and 2 asks the store for exactly
  `[0,4)` of member 0; the body is 10 bytes with members at 0, 4 and 8; reading all three makes it
  whole.
- On a fast store, a member read fetches the whole group and no range.
- A range read proceeds while a whole fetch of its group is held in flight, and the group still
  arrives.
- Two fills of disjoint ranges of one cold member, completing in either order, never make a
  later read return bytes that were not fetched; the cap evicting a body during a fill never
  makes a later read return bytes that are not on disk.
- A fetched chunk whose bytes do not hash to its key is never written, served or installed, and
  the failure is CORRUPT; a store answering a missing chunk yields ABSENT or CORRUPT per
  [failure-model](failure-model.md), names the chunk, caches nothing, and the in-flight table is
  empty afterwards.
- A body assembled from ranges whose bytes are wrong is not installed as whole.
- Reads fetch only the groups they touch; `fetch_range` serves a range without materialising
  the file, and the destination's size is the end of the range.
- Two handles on one file keep separate read-ahead positions; one read does not prefetch; a
  second sequential read fetches the current and the next group; a probe elsewhere in the file
  through another handle does not reset a sequential reader.
- A range read is served while prefetches hold every whole-fetch request in flight.
- A handle opened before a peer's version is applied keeps reading the version it opened; a
  local write is visible to every handle.
- A read offline fails within `READ_DEADLINE`; the fetch lands; the next read is local with no
  store call. A body removed underneath a reader is refetched on the next read.
- Read touches mtime; with no cap nothing is evicted; a cap of 20 bytes drops the coldest
  bodies; a cap of 0 drops every unpinned body, whole or partial.
- A pin spares a body at cap 0; re-pinning moves the deadline; a lapsed pin is removed, then its
  body is an ordinary candidate; a pin made before its fetch survives a cap sweep that runs
  during the fetch.
- Promotion by link: one body, two names; publishing twice succeeds; a length mismatch is
  refused; the body stays readable after the staged name goes, with no refetch; a cap of 0
  never touches staged bodies.
- A file with every group present but one partly filled is `online-only`; once filled it is
  `cached`.
- Progress of a materialisation is monotone, covers fetch and assembly, and overlapping
  materialisations of one key share one report.

## 9. Rationale

| Choice | Reason |
|---|---|
| Ranges for demand reads, whole groups for prefetch | A few-byte read once cost a whole group. |
| One held interval per member | The worst case per read is one gap in one chunk; no interval algebra. |
| Held intervals only in memory | A persisted record needs crash-ordering rules that power loss breaks; a lost partial body costs a refetch. |
| A name that exists is a whole body | Every caller can answer "cached?" from a name. |
| Never join a whole fetch on a range read | Joining turned 100 KB into seconds and lost file descriptors on phones. |
| Prefetch never delays a demand read | A 128 KiB read waited 6 s behind prefetches on a phone. |
| Detached fetch plus deadline | A suspend froze 44 s on a reader with the link down; cancelling would fail joiners. |
| Verify whole chunks, read-back verify range-built bodies | Corruption must not be cached as whole or republished under new, honest keys. |
| Pin before fetch | A pin placed after its fetch could silently not happen. |
| LRU by coarse mtime | No inode write per read. |
| Pin as a marker whose mtime is the deadline | Follows content across renames and is shared by every file using the body. |
| Reference-blind evict | Refetching is cheap; reference counts are state to corrupt. |
