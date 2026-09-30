# WAL and journal: one replication protocol over a dumb store

This is an implementation-independent description of how tsync clients replicate one domain's
tree to each other. The only thing they share is an object store with no server-side logic. The
write-ahead log (WAL) on each client and the shared journal on the store are two halves of one
protocol. The WAL makes the sending side survive crashes and the journal carries the work to
peers. They are described together because their ordering rules only make sense as a pair.

The concrete specification is [03 — journal & sync](../03-journal-sync.md). The local side
(staged data, mirror, WAL API) is in [04 — checkout & cache](../04-checkout-cache.md).
Verified defects are in [findings](../findings.md). What to do when two clients' operations clash
(the principle, both decision tables and their rationale) is in
[conflict resolution](conflict-resolution.md). This document says only where those decisions sit
in the protocol, what they receive, and what the protocol needs from them. Concrete names appear
only in §10.

---

## 1. Problem and goals

One person mounts the same storage ("domain") from several machines ("clients"). Each client
keeps a full local replica of the tree's metadata (the *mirror*) plus locally written content
that has not been uploaded yet (the *staged* data). It serves every read and write from that
replica. The replicas must be brought into agreement through the store alone.

Goals:

- **G1 — Local operations never wait on the network.** A mutation completes against the local
  replica and becomes a debt to the store, paid later.
- **G2 — Acknowledged work is never lost.** A mutation that returned success eventually reaches
  the store, or is explicitly found to be owed nothing (it was superseded or its data is gone).
  This holds across process crashes and restarts.
- **G3 — Every client learns of every change.** Each published unit of work is applied by every
  other client that runs for long enough, including units that become visible late or out of
  order.
- **G4 — Convergence under quiescence.** Once mutations stop and every debt is paid, all
  replicas hold the same tree.
- **G5 — One bad unit never blocks the rest.** A unit that fails for a reason local to one client
  does not stall that client's other traffic in either direction. A link failure does stall
  traffic, on purpose (§4.3, §4.5).
- **G6 — A local change feed.** Every client keeps an ordered record of what it has handled, its
  own and its peers'. Frontends read it to learn what changed, and it never runs ahead of the
  replica.

Non-goals:

- General concurrent correctness: no linearizability, no causal order across clients, no
  preservation of the intent of truly concurrent edits beyond the best-effort policy in
  [conflict resolution](conflict-resolution.md). The single user mostly avoids concurrency.
- Coordination between clients. No locks, leases, leader, or consensus on the store.
- Durability against power loss on the client (§8, F8).
- Catching up a client that was away longer than the retention window. That client must rebuild
  from the store's tree (§4.8).

---

## 2. System model and assumptions

**A1 — The store is dumb.** It offers only: `put(key, bytes)` (overwrite allowed), `get`,
`head`, `list(prefix)` returning every key under a prefix (order irrelevant, since the client
sorts), and `delete`. Only the conflict decision points need a create-if-absent write, and only
to claim a folder name (see [conflict resolution](conflict-resolution.md)). The journal protocol
itself needs no conditional write, compare-and-swap, append, or notification.

**A2 — Store consistency.** An object whose `put` returned is eventually visible to `get`,
`head` and `list` from every client. Nothing requires listing to be immediate or ordered. A
false "absent" from `head` is tolerated (§6: republishing an entry under the same key is
harmless). A store may serve an object's latest version or a slightly stale one, but never a
torn one.

**A3 — Write rate per object name is limited** (about one write per second on object stores).
Hot single objects must be written rarely.

**A4 — Clocks are loosely synchronised wall clocks.** They name units of work and order them
into a total order that is only roughly chronological. No correctness property depends on
cross-client clock agreement, except that a clock skewed by more than the retention horizon
makes its entries invisible to peers (§8).

**A5 — Failures.** Processes crash at any point and restart. A local file replaced by
write-temp-then-rename is either old or new, never torn, but this holds only for process
crashes: nothing is flushed to stable storage (F8). The link to the store can be down for
arbitrarily long. Store requests fail transiently (network) or permanently (refused). Clients
are not malicious.

**A6 — Actors.**
- *Clients*, each with a stable random identity. Different machines never share an identity.
  All processes of one machine share it, which gives the multi-process hazards of §4.9.
- On each client, *writers* (frontends, command-line tools) mutate the local replica.
- *Exactly one converger* per client and domain applies peer entries and recovers crashed work
  (§4.9, where this is violated today).
- *Maintenance* on any client may delete old journal entries by age (§4.8).
- A *rebuild* may replace a client's replica with the store's tree (§4.8).

**A7 — Within one process, the steps that update shared in-memory state do not interleave.**
The implementation relies on cooperative scheduling. A preemptive reimplementation must lock
each check-then-act on key minting, the cursor debouncer, the dedupe set and the queues'
hand-off (listed in [03 §6.1](../03-journal-sync.md)).

---

## 3. State

### 3.1 Shared (on the store, per domain)

| State | Nature | Invariant |
|---|---|---|
| **Journal**: set of *entries*, each `key → [op]` | durable, immutable once written, never updated | key = (mint time ms, client id), unique per unit of work; an entry exists only after the store holds everything its ops name (bytes, manifests, folder markers) |
| **Cursor**: one small object holding one entry key | durable, last-writer-wins, rate-limited | a *hint*: some recent entry key; may be stale, lost, or move backwards; correctness never depends on it |

The **entry key** is a pair (milliseconds at the *start* of the work, client id). It is totally
ordered by (ms, client id) and printed so that lexicographic order equals that order. It names
the unit of work for its whole life: WAL record, journal entry, cursor value, applied-log line
and change-feed anchor. Using one spelling in all five places is a requirement: two readers once
compared different spellings and fell permanently behind.

The **op vocabulary** is file content put (path, size), delete (path), make folder (path, folder
id), remove folder (path, folder id) and rename (src, dst, is-folder, size, folder id). Ops name
paths as the *writer* sees them. Folder ops carry the folder's stable, client-minted id, because
applying a removal destroys the local record the id could otherwise be read from. Decoding is
total: an unknown op is skipped, for forward compatibility.

A content put carries **no content and no base version**. It tells the reader to fetch the
file's *current* manifest from the store. Content therefore converges to the store's latest
write whatever order puts are applied in, and a re-applied put is idempotent. The cost is that
two concurrent edits of a published file cannot be told from sequential ones (§5.3).

### 3.2 Local, durable (per client, per domain)

| State | Written by | Must live |
|---|---|---|
| **WAL**: one record per unit of work, `key → {state, ops, attempts, last error}` | writers (create), queues (advance, delete), converger (recover) | on local disk, one directory per domain, shared by every process of the client |
| **Applied log**: append-only sequence of `(key, ops)` lines in *handling* order, own entries and peers' | the publishing wrapper (own), the converger (peers, rebuild findings) | local disk, sharded by *handling* time, never by key time; readers address it by position (the line holding an anchor key), never by key comparison |
| **Last-sync mark**: one entry key, forward-only | converger | local disk, atomic replace. Its only meanings are "has ever synced" and the rebuild check; it is never a listing cut (§4.4) |
| **Replica**: mirror, staged data, folder-id index | writers, converger | local disk; owned by the checkout, see [04](../04-checkout-cache.md) |

### 3.3 Local, volatile (per process)

- **Handled set**: the keys in the applied log. It is a cache of durable state and must be
  reloaded whenever another process may have appended (F5).
- **Stepped-aside set**: peer entries that failed on this client's account, with the reason. It
  is reported by status and rebuilt naturally, since those entries stay unhandled.
- **Parked set**: own metadata records that failed permanently. It is reported by status.
- **Cursor debouncer**: pending newest key, last publish time, and whether a timer is armed. It
  is shared by everything in the process that writes the cursor.
- **Poller memory**: last cursor value seen and time of last full listing.
- **Queue contents**: always derivable from the WAL.

---

## 4. The algorithm

### 4.1 Record states (the WAL state machine)

```
                 local half fails / local half owes nothing
      ┌────────────────────────────────────────────────────────────┐
      │                                                            ▼
  INTENT ──local half done──► PREPARED ──backend half done──► EXECUTED ──entry published,
  (metadata op only)          (content puts are born here)        │       cursor noted──► (deleted)
                                  │                               │
                                  └─ nothing owed / superseded ───┴──────────────────────► (deleted)
```

- `INTENT` means the op is recorded and the local replica may be partly changed.
- `PREPARED` means the local half is done and the store half is owed.
- `EXECUTED` means the store holds the bytes, manifests or markers, and the journal entry may
  not exist yet.
- There is no "committed" state. Deleting the record *is* the commit, because a crash between
  commit and delete would need a HEAD check anyway, and the extra write costs one disk write per
  unit.
- Orthogonal updates that keep the state: record a failure (increment attempts, store the
  error), and rewrite ops when a conflict settled later retargets the record.
- An unreadable or unknown state reads as `INTENT`. That is the least advanced state, so recovery
  re-derives the rest from disk and store and never skips work.
- The record id is the entry key it will be published under.

### 4.2 Outbound: a local mutation's life

```
WRITER, metadata op m (delete, mkdir, rmdir, rename), under the local metadata lock:
  k := mint_key()                      # max(now_ms, last_minted+1), per process
  wal.write(k, INTENT, [m])            # 1. intent durable BEFORE anything changes
  try r := local_half(m)               # 2. replica change, no store request possible
  except: wal.delete(k); raise
  if r = NOTHING_OWED: wal.delete(k)   #    e.g. renaming a never-published staged file
  else: wal.write(k, PREPARED, [m]); metadata_queue.signal(k)

WRITER, content (close of a staged file, symlink):
  k := mint_key()
  wal.write(k, PREPARED, [Put(path, size)])
  upload_queue.signal(k)               # returns once taken, so a following delete can cancel it

METADATA QUEUE: one worker, strict record order, head-of-line retry
  job k:
    rec := wal.read(k)                 # re-read: a conflict settled since may have rewritten it
    ops' := PUBLISH_DECISION(rec.ops)  # §4.6: probes the store, may act on it, rewrites ops
    if ops' = []: wal.delete(k); return             # store owed nothing
    DISCHARGE(k, ops')
  on SUPERSEDED: wal.delete(k)         # replaced by a new record the decision created
  on link failure: note failure; retry at the head (nothing overtakes)
  on any other failure: note failure; PARK (leave record, leave queue, mark degraded)
  periodic rearm: re-adopt every PREPARED metadata record not queued

UPLOAD QUEUE: pool of width W, at most one job per file (a newer job cancels the running one)
  job k:
    if cancelled: wal.delete(k); return
    upload staged bytes and manifest for the file
    if cancelled: wal.delete(k); return
    DISCHARGE(k, rec.ops)
  on cancelled / staged bytes gone: wal.delete(k)       # nothing owed any more
  on shutdown: leave record
  on other failure: note failure; transient → requeue at back; permanent → stop, record kept

DISCHARGE(k, ops):
  wal.advance(k, EXECUTED)             # 3. store half is done
  applied_log.append(k, ops)           # 4. noted locally BEFORE publishing
  store.put(journal/k, encode(ops))    # 5. published (idempotent: immutable key)
  local_announce(ops)                  #    wake this client's frontends
  cursor.note(k)                       # 6. hint, coalesced
  wal.delete(k)                        # 7. forgotten
```

**Ordering rules and their reasons.**

1. **Record before the local half** (step 1 before 2). A crash mid-change leaves an intent that
   says what the partial change was meant to be.
2. **Store half before the entry** (step 3 before 5). An entry tells peers to fetch or act on
   something, and it must never name data the store does not hold. That is why a put whose
   staged bytes vanished publishes no entry.
3. **Advance to `EXECUTED` before publishing.** On restart, recovery then only needs to ask
   "is the entry there?" and never redoes the backend half.
4. **Note locally before publishing** (step 4 before 5). The change is already in this replica,
   so "noted but not published" describes something true: the change feed may report it and the
   record will still publish it. The reverse order would allow "published but never noted",
   which no one could ever report. The note lives in the one publishing wrapper, not in each
   publisher, because five publishers exist and a sixth would forget. Noting and announcing are
   one operation for the same reason.
5. **Publish before the cursor, cursor before delete** (5 → 6 → 7). A peer that sees the cursor
   move finds the entry. A lost cursor note is repaired by the sweep. Deleting the record last
   means every earlier crash leaves something for recovery.
6. **Metadata publishes strictly in record order** (single worker, head-of-line retry on link
   failure). A rename must follow the mkdir it moves, and a create must follow the rename that
   freed its name.
7. **Metadata drains before uploads** at shutdown or sync. A rename being published may name the
   file an upload behind it is for.
8. **Content is keyed, not ordered.** Uploads run in parallel, one per file, and the newest write
   of a file cancels and replaces the older job, so successive saves coalesce into one entry. A
   rename that moves staged files re-queues their uploads under a *fresh* key minted after the
   rename's key, so peers apply the move before the puts.
9. **The local lock is never held across a store request.** Writers hold it only in a component
   that cannot reach the store (G1).

**Batching.** One record is one entry. Interactive ops produce one op per entry. Bulk producers
put many ops in one entry: import flushes at N ops or T seconds, and a rebuild reports its diff
in chunks. Content coalesces per file through cancel-and-replace. Cursor writes coalesce as
follows.

**Cursor coalescing** (A3):

```
note(k):  pending := max(pending, k); if not armed: arm timer for (interval − since last publish)
bump(k):  if since last publish ≥ interval: publish k now, else note(k)
timer / flush: take pending; if any, publish it under a lock; ignore errors (it is a hint)
```

Every process that published must flush before exit, otherwise its last bump is lost. That loss
is only a latency cost, because the sweep repairs it. The debouncer is one per cursor object per
process, however many components use it.

### 4.3 Inbound: discovering entries

```
POLLER LOOP (converger only), per domain:
  loop:
    if paused: sleep(tick); continue
    wait until the store says the cursor may have changed, at most SWEEP seconds
         (object store: fixed sleep; local disk: directory watch; proxy peer: long-poll)
    c := get(cursor)
    moved := c ≠ none ∧ c ≠ last_seen
    due   := now − last_listing ≥ SWEEP
    if moved ∨ due:
      last_listing := now
      APPLY_PASS()                    # may raise, in which case last_seen is unchanged
      last_seen := c
  on error: log; sleep(RETRY_FLOOR)
```

- **The cursor is a hint.** It saves a listing per client per wake-up when nothing changed.
  Correctness comes from the listing.
- **The sweep is timed from the last listing, not from a wait timeout.** Every store answers a
  wait well inside the sweep interval, so a sweep tied to a timeout would never run. The sweep
  catches bumps that never landed, a cursor overwritten backwards by an older key from another
  process, and entries that became visible after their bump.

### 4.4 Inbound: applying entries

```
APPLY_PASS():
  handled := load-once(applied_log.keys)
  horizon := (mark = none) ? −∞ : now_ms − HORIZON
  due := sort_by_key( { e ∈ list(journal) | e.ms ≥ horizon ∧ e ∉ handled } )
  for e in due, sequentially:
    try:
      if e.client = me: pass                        # own work is already in the replica
      else:
        ops := get(journal/e)
        if ops = unreadable: continue               # (today: indistinguishable from absent, F6)
        ARRIVAL_DECISION + enact(ops)               # §4.6; read-ahead unlocked, apply locked
        stepped_aside.remove(e)
        applied_log.append(e, ops)                  # AFTER applying
        handled.add(e)
        notify frontends of every path in ops
      mark := max(mark, e)                          # forward only; not a cursor
    except link failure:  abort the whole pass      # retried from scratch
    except any other:     stepped_aside[e] := reason; continue   # stays unhandled
```

**Why dedupe against the handled set within a horizon, never "keys after a cursor".** Keys are
minted when work *starts*. Entries become visible in a different order: slow uploads, retries,
a record published after a crash under its original key, parallel upload workers, and listing
lag. Any rule of the form "list keys > last seen" loses every entry that lands behind the cut,
silently, and reports "0 to apply". This happened with four concurrent uploads per side: each
peer got the first batch and lost the second. Membership in the set of handled keys has no such
hole. An entry is due whenever it is visible and unhandled, whenever it arrives.

The horizon bounds the set: entries older than `HORIZON` are indistinguishable from ones handled
and since forgotten, and are ignored. This makes late visibility by more than `HORIZON` a loss
by design. With no mark at all nothing was ever handled, so the whole journal is due.

The same rule governs the change feed. A reader's anchor is a *position* in the applied log (the
line holding its key). The log is sharded by handling time, so a late-visible entry handled
today appears after anchors taken yesterday. A missing anchor means "relist from scratch", never
"start from the nearest key".

**Apply in key order.** Within one pass, entries are applied in key order. For one client's
metadata this equals its record order (§5.2), which the ops depend on (mkdir before the rename
of that folder). Across clients, key order is an arbitrary total order. Nothing assumes it is
causal, and the arrival decision is written against facts rather than against an expected
sequence.

**Step aside, do not block.** An entry that fails for a reason other than the link is left
unhandled and reported. Later entries proceed, and the failed one is retried on every pass.
Before this rule, one entry (a folder rename onto a non-empty directory) blocked a client for
eight hours and about 1,900 entries. A *link* failure aborts the pass instead: skipping would
break per-client order, and waiting costs nothing when nothing can be read anyway.

**Apply atomicity and locking.** One entry's ops are applied sequentially within one hold of
the local metadata lock, so no local mutation interleaves inside an entry. Store reads happen
before the lock is taken, in a read-ahead that collects every answer the decision will need. If
the local state changed between read-ahead and apply so that an answer is missing, the apply
fails as a *transient* failure and the entry is re-read on the next pass. It is never stepped
aside for this.

**Note after applying, so the feed never runs ahead of the replica.** Peers' entries are noted
only after every op is applied. Own entries are noted after the local half, which is already in
the replica. A crash mid-entry therefore leaves it unhandled, and it is re-applied.
Re-application must be safe, which the arrival decision guarantees through facts such as
"already applied" or "nothing to move", and puts are safe because they re-read the current
manifest. The exceptions are in §8 (F4).

**The applied log is the change feed.** Frontends page through it by position. It contains own
entries, which a mount must see when a command-line tool made the change, peers' entries, and
rebuild findings. An op a frontend cannot name (no folder id) is dropped from the description,
not from the log.

### 4.5 Failure classes

Every failure on either path is classified once.

- **Link**: the retry loop around a store request gave up. Traffic waits: the metadata queue
  holds at the head and the apply pass aborts. Order is preserved and nothing is skipped.
- **Own account**: any other exception, including local filesystem errors and unexpected states.
  The failed unit is set aside, visible in status, and retried periodically, while everything
  behind it proceeds. Outbound, a parked metadata op is retried by rearm. Inbound, a stepped-aside
  entry is retried every pass.
- **Superseded**: the unit is replaced by other recorded work or found to be owed nothing. The
  record is deleted.
- **Shutdown**: re-raised untouched. The record stays for the next start.

A catch-all handler anywhere on these paths silently changes the policy. F6 is one.

### 4.6 The two conflict decision points

The protocol has exactly two places where two clients' histories meet. Their policy is specified
in [conflict resolution](conflict-resolution.md). This section states only their position, their
inputs, and what the protocol requires of them.

**D-Arrival: a peer's op arrives** (inside `APPLY_PASS`, per op of an unhandled peer entry).
- Inputs:
  - the peer's op, with paths as the peer named them and folder ids;
  - this client's *owed* metadata records (unpublished work, from the WAL);
  - local state: replica, staged data, folder-id index, including where this client has moved a
    folder since;
  - store answers gathered in the unlocked read-ahead (folder markers, the peer's current
    manifests).
- Paths are first translated. A folder or file this client moved but has not published is
  followed to where it is now, and ancestor folder ids are adopted from the store, never minted.
- Output: *skip*, or an ordered list of local actions. Actions may move this client's own
  unpublished items aside, which creates new owed records (renames or uploads) through the normal
  outbound path.
- A skip still marks the entry handled.

**D-Publish: our op meets a store that moved on** (inside the metadata queue job, before
`DISCHARGE`).
- Inputs:
  - our op as currently recorded (re-read from the WAL);
  - local state now;
  - the store's state, learned by *attempting* where the store is the arbiter: claiming a folder
    name with create-if-absent, or moving a file's manifest.
- Output:
  - store actions;
  - one ending: publish the op *rewritten to where the item is here now*, owed nothing, superseded
    by newly recorded work, decide again, or retry.

**Invariants the protocol relies on them for:**

- **Convergence (G4)**: for every combination of facts, both clients end with the same tree once
  both have published and applied. The loser of a clash is whichever client still holds its op
  *unpublished* when the other's arrives, or whichever publishes second. That client renames its
  own item and **publishes that rename**. Both machines thereby compute the same winner without
  coordination: the first to publish is never asked to yield, and the second learns of the clash
  at D-Arrival, D-Publish, or both. Moving the loser aside on each side independently would swap
  names and diverge.
- **No data loss (G2)**: no decision discards unpublished local content. Content is moved aside,
  never overwritten. The only loss admitted is the last-resort one: an already-published file
  overwritten by a later write, whose old content survives in the store's version history.
- **Skips are backed by owed work.** "Skip, ours publishes later" is safe only because the owed
  record persists until published (G2, §5.1).
- **Idempotence.** Re-applying an entry after a crash, or twice across processes, must decide
  "already applied" or "nothing to do" and not act again (§4.4).
- **Progress.** "Superseded" must record its replacement *before* the original record is deleted.
  "Again" must terminate: it re-gathers after a store claim, and each round claims a fresh
  conflict name. "Retry" is only for a failure the queue classifies (§4.5).
- **No store request under the local lock.** D-Arrival gets store answers as data. D-Publish runs
  outside the lock, and the local enactments it triggers take the lock themselves.
- **As-published rewriting.** What goes into the entry is where the item lives here *now*, under
  the original key, because a local move may have happened since the op was recorded.

### 4.7 Crash recovery (reconcile)

Run once at converger start, **after** both outbound queues have started (recovery goes through
them) and **before** new writes are staged. Records are processed sequentially, in key order.

```
for (k, rec) in wal.own_records() sorted by key:          # own client id only
  try:
    case rec.state:
      EXECUTED:
        if not head(journal/k): put(journal/k, rec.ops) (noting and announcing it); cursor.bump(k)
        wal.delete(k)
      PREPARED, single put:
        if staged data (or symlink manifest) still exists: upload_queue.resume(k)
        else wal.delete(k)
      PREPARED, metadata only:
        metadata_queue.resume(k)          # no re-check against peers: publishing what this
                                          # replica holds is what brings the two back together
      INTENT, metadata only:
        redo_local(each op)               # idempotent: removal by id; rename only if src present
                                          # and dst absent
        metadata_queue.resume(k as PREPARED)
      INTENT with a put, or a mixed record:
        newer := paths touched by OTHER clients' entries with key > k
        drop ops touching `newer`         # a peer's later change wins over our unfinished one
        apply the remaining metadata ops locally
        single put with staged data → upload_queue.resume(k)
        else metadata left → publish entry k, bump cursor, delete record
        else → delete record (nothing staged: never announce data that was not uploaded)
  except e: wal.note_failure(k, e)        # left for the next start; visible in status

for each staged file no record names: upload_queue.new_record(file)    # crash between staging
                                                                        # and recording
```

What each crash window owes, and how recovery finds it:

| Crash between | Durable state left | Owed | Rediscovered by |
|---|---|---|---|
| staging content and writing its record | staged data, no record | upload + entry | scan of staged data against records |
| intent and end of local half | `INTENT`, replica partly changed | rest of local half + publish | `INTENT` metadata: `redo_local` |
| local half and hand-off | `INTENT`, local half complete | publish | `redo_local` is a no-op, then resume |
| hand-off and store half | `PREPARED` | store half + entry | resume in the right queue |
| store half and `EXECUTED` | `PREPARED`, store already changed | entry | queue re-runs the store half, which is idempotent (content-addressed upload; the publish decision re-gathers facts and finds "already there") |
| `EXECUTED` and local note | `EXECUTED` | entry | HEAD → publish |
| note and publish | `EXECUTED`, applied log already lists it | entry | HEAD → publish (applied log gets a second line, §8) |
| publish and cursor note | `EXECUTED`, entry visible | nothing but a hint | HEAD → delete record; bump; peers' sweep covers it meanwhile |
| cursor note and record delete | `EXECUTED` | nothing | HEAD → delete |
| peer entry applied partly | entry unhandled | the rest | next pass re-applies the whole entry idempotently |
| peer entry applied, before note | entry unhandled | nothing | next pass re-applies; decisions find "already applied" |

Idempotence of each step:
- Local halves are redone by id or with presence checks.
- Content upload is content-addressed and the manifest put is an overwrite.
- Store-side metadata acts are re-derived from facts.
- Journal put is under an immutable key, so re-putting the same bytes is a no-op to readers,
  who dedupe by key.
- The cursor is a hint.
- Record delete is idempotent.

The one non-idempotent write is a second applied-log line for the same own key (§8).

### 4.8 Retention, horizon, and the rebuild

**Journal pruning.** Maintenance, run on demand on any client, deletes journal entries whose
key time is older than a chosen cutoff, **except the entry the cursor names**. That exception
keeps a quiet domain's cursor pointing at something. Age is the only safe criterion, because
nothing on the store records what every client has applied. A cursor says what was published,
not what was consumed.

**Applied-log pruning.** Local shards older than `HORIZON`, or beyond a byte cap, are dropped.
The dedupe horizon *is* the applied-log retention. The handled set only covers what the log
still holds, so anything older must be excluded by the horizon rule or it would be re-applied.
The byte cap currently violates this coupling (F4).

**The obligation of a client that fell behind.** A client may have missed entries it can no
longer see. This happens in either of two cases:

- its mark is older than the oldest surviving journal entry, meaning entries were pruned after
  it last synced;
- its mark is older than `now − HORIZON`, meaning the entries exist but the horizon hides them.

Incremental apply cannot repair this, and the client must **rebuild**:

```
REBUILD():
  require no owed metadata records (a rebuild would undo them)       # refuse otherwise
  drain own queues first
  keys := list(journal)                                  # read BEFORE walking the tree
  walk the store's tree; rewrite the replica in place; for each difference, append a
    locally-minted entry of the ops it amounts to to the applied log (feed readers learn it)
  if the walk had no failures:
    mark := fresh key
    handled += keys (ops [])                             # their effect is in the tree just read
```

An empty journal is treated as "cannot bridge" on purpose: a needless rebuild is cheaper than
silently skipping pruned ops.

Today only the one-shot sync command runs the check, and only the first condition (F3, and the
second condition is a gap noted in §8). A correct converger runs both checks at startup and after
each pass that advances the mark. When either is true, it stops applying incrementally, reports
itself as needing a rebuild, and either rebuilds automatically once no metadata is owed or holds
until the user does.

### 4.9 Several processes on one machine

**Rule: exactly one converger per (client, domain).** The converger is the process that runs
recovery, the poller and apply, and maintenance. Those steps write the replica, the mark, the
applied log and the staged tree, which every process serving the domain shares. Other processes
may:

- perform local mutations, each under its own lock, writing records into the shared WAL
  directory;
- run their own outbound queues over *the records they created*, or over records no live process
  claims;
- read the replica and the applied log (the change feed), and receive "changed" notices from the
  converger;
- publish through the same wrapper (so every entry is noted and announced), and flush the cursor
  before exiting.

They must not: apply peer entries, run recovery over records another live process owns, or prune.

**Where the current implementation violates this:**
- **F7.** Frontend processes stage writes while the converger applies a peer's delete. Locks are
  per process, and the write path does not even take the metadata lock in-process. A peer delete
  can therefore discard a staged edit made between the converger's fact check and its enactment,
  although the designed decision for that case is "skip, ours publishes later".
- **F7.** A one-shot sync run alongside the daemon runs recovery over every record, including
  another process's in-flight `INTENT`/`PREPARED` records, and adopts staged files whose record is
  not yet written.
- **F5.** That same one-shot run also applies entries. Each process loads its handled set once,
  so the daemon may re-apply what the command-line run applied, relying on idempotence, which F4
  shows is not total.
- **G8.** Pause is delivered to one frontend process. The converger's poller keeps applying peer
  entries while the user believes sync is held.
- Two processes sharing a client id can mint the same key in the same millisecond, because
  monotonicity is only per process. One journal object and one record then overwrite each other.
- Cursor debouncers are per process. One process can overwrite the cursor with an older key than
  another's. This is harmless: the sweep covers it.

A correct version needs:
- a cross-process exclusion per domain that covers *both* peer apply and every local write of the
  same paths (the data write path included);
- one-shot tools that go through the running converger rather than becoming a second one;
- a handled set that is re-read (or appended to under the same exclusion);
- a record-ownership claim so recovery skips records a live process owns;
- key minting that is unique per client, not per process: a per-process nonce in the key, or a
  shared counter.

---

## 5. Properties and why they hold

### 5.1 Safety

**S1 — Acknowledged work stays owed until discharged** (G2). A mutation returns only after its
record is durable (§4.2 rules 1–2). A record is deleted in only three cases:

- after its entry is published;
- when its local half failed, in which case the mutation also failed;
- when a queue established that nothing is owed: superseded by a replacing record that is already
  written, cancelled by a newer job for the same file, staged bytes gone, or the publish decision
  found the store already agrees.

Every crash window leaves a state that recovery maps to the remaining work (§4.7 table). The
argument breaks where the local data behind a record can vanish silently: F9, where a crash in
the staged write loses the bytes and the upload then reads "nothing owed", and F8 on power loss.

**S2 — No entry names data the store lacks.** An entry is published only from `DISCHARGE`, after
`EXECUTED`, which the queues set only after the store half returned. Recovery publishes an
`INTENT` put only if staged data survived and was uploaded through the queue.

**S3 — No handled entry is skipped because of arrival order** (G3). The pass admits any visible
entry within the horizon that is not in the handled set. The set only grows by entries fully
applied (or deliberately marked by a rebuild). So an entry is either applied or still due. The
worst case is a late-visible entry: key `a` becomes visible after `b > a` was applied. The next
pass still lists `a`, `a ∉ handled`, and applies it. The scenario test hides the newest entry,
syncs, unhides it, and expects the applied order b, a, c.

**S4 — The feed never runs ahead of the replica** (G6). Peers' entries are noted after apply and
own entries after the local half.

**S5 — Local operations never wait on the store** (G1). Every store request happens in a queue,
in the unlocked read-ahead, or in the poller. The component holding the lock has no path to the
store.

**S6 — Content converges to the store's latest write.** Puts re-read the current manifest, so
applying any subset of a file's put entries, in any order, at least once after its last write,
yields the store's latest.

### 5.2 Per-client ordering

- **Metadata entries of one process become visible in record order.** The single worker publishes
  `k_i` completely before starting `k_{i+1}`, and keys are monotonic per process. A peer applying
  in key order therefore applies them in that order, provided the listing shows `k_i` no later
  than `k_{i+1}` (A2 gives only eventual visibility, so a lagging listing could show `k_{i+1}`
  alone. The arrival decision tolerates this through "source gone → nothing to move" and id-based
  facts, at the price of a wrong outcome in rare shapes).
- **Content entries have no order** with each other or with metadata. The arrival decision
  tolerates a put before the mkdir of its folder: the put materialises id-less ancestors, and the
  later mkdir or id adoption fills in the id.
- **No order across processes of one client, and no causal order across clients.**

### 5.3 Liveness

**L1 — Outbound progress.** With the link up, every `PREPARED` record reaches `DISCHARGE`, unless
it is parked. Parked records are retried every rearm period. A link outage delays records but
drops none.

**L2 — Inbound latency.** A published entry is applied by a running converger within
`cursor debounce + wait interval` when the bump lands, and within `SWEEP` otherwise, unless the
link is down or the entry is stepped aside.

**L3 — Isolation** (G5). A stepped-aside entry or parked record costs one retry per pass or
rearm, and delays nothing behind it except by link failure.

**L4 — Convergence under quiescence** (G4). Assume that from some time on:
- no client mutates;
- links work;
- every stepped-aside entry and parked record eventually succeeds;
- every client runs longer than `L2`;
- no gap from §8 fires.

Then every record is discharged (L1) and every entry is applied everywhere (S3, L2). Content
agrees by S6. Metadata agrees because each clash is resolved at D-Arrival or D-Publish into an
outcome identical on both sides (§4.6). Non-clashing ops commute because they touch different
names and ids. New records created by conflict actions are themselves discharged and applied,
and they only rename items to fresh conflict names, so this adds finitely many rounds.

**What is explicitly not guaranteed:**
- Truly concurrent edits of an already-published file: the last write to the store wins and the
  loser survives only in version history.
- A kind clash (file vs folder) where both sides already published: undecided.
- Writes into a folder being moved aside may land at its old path.
- Entries late by more than `HORIZON`: lost.
- Anything under a clock skewed by more than `HORIZON`.
- Order or atomicity across entries.
- Crash atomicity within an entry: the apply lock gives isolation, not atomicity.

---

## 6. Failure, crash and resume

The per-window table is §4.7. Additionally:

- **Abandonment.** A record is abandoned (deleted without an entry) only when nothing is owed
  (S1). A record that keeps failing is never abandoned. It stays, counted and shown with its last
  error, and recovery and rearm keep trying it. Operator action is a rebuild (refused while
  metadata is owed) or fixing the local cause.
- **A failed recovery of one record** notes the failure and moves on. The next start retries it.
- **A link down during apply** aborts the pass. The poller retries after the retry floor, or
  waits on the store's watch. Nothing is marked handled.
- **Unreadable entry.** The entry must be retried and must not advance anything that implies it
  was seen. Today it is read as "absent", which is F6.
- **Shutdown.** Queue drains race against a fraction of the grace period so that the cursor flush
  still happens. Anything unfinished stays as records.
- **Pause** holds both outbound queues and the poller (no journal reads). Reads are still served,
  and resuming releases everything. It is not persisted, and G8 applies.

---

## 7. Parameters

| Parameter | Current value | Effect | Trade-off |
|---|---|---|---|
| `HORIZON` (dedupe window = applied-log age retention) | 30 days | how far back a late-visible entry is still applied; bounds the handled set | longer = more local log and memory, tolerates longer lateness and clock skew; must be ≤ retention of the applied log it reads |
| `APPLIED_BYTES_CAP` | 64 MiB | local disk bound on the applied log | today it can cut inside `HORIZON` (F4); a correct cap must never drop keys ≥ horizon, or must lower the horizon with it |
| applied-log prune period | 1 day | — | — |
| journal retention cutoff | chosen per `expire` run | store space; sets which clients must rebuild | shorter than `HORIZON` makes pruning, not the horizon, the binding limit |
| `CURSOR_INTERVAL` (debounce) | 2 s | ≥ store per-object write limit (A3) | shorter risks rate-limit errors; longer adds latency |
| store wait | object store 2 s sleep; local disk watch capped 2 s; proxy long-poll ≤ 30 s | cursor reads per client | one GET per client every 2 s on object stores |
| `SWEEP` | 60 s | worst-case latency when a bump is lost; one listing per client per minute when idle | longer or jittered if idle fleets cost too much |
| `RETRY_FLOOR` | 2 s | poller back-off after a failed pass | — |
| pause tick | 0.2 s | resume latency | wake-ups while paused |
| upload width `W` | `maxUploads`, default 4 | parallel content publishes | more parallelism means more out-of-key-order visibility (harmless by S3) and more memory |
| metadata width | 1 (by design) | preserves record order | a wider queue needs dependency tracking |
| rearm period | 60 s | retry of parked metadata | — |
| recovery read concurrency | 32 | reading newer entries in `INTENT` recovery | request burst vs start time |
| bulk entry size | import: 2000 ops or 10 s; rebuild findings: 64 ops | entry count vs entry size | larger entries mean fewer objects and larger re-reads |
| shutdown drain share | 0.8 × grace | leaves time to flush the cursor | — |

---

## 8. Known gaps

| Gap | What breaks | A correct version |
|---|---|---|
| **F3**: the converger never checks whether the journal was pruned past its mark | a long-offline daemon applies what survives and permanently misses pruned deletes, renames and puts; a later local edit of a stale file may overwrite a newer peer version | run the §4.8 check at start and after each pass; stop incremental apply and rebuild |
| **Horizon hides unpruned entries** (found in this reading; not in findings) | a client stopped for longer than `HORIZON` with an unpruned journal: every entry with `mark < key < now − HORIZON` is filtered out by the horizon, and the rebuild check sees nothing wrong because the oldest key is older than the mark. Both the daemon and the one-shot sync miss them silently | treat `mark < now − HORIZON` as "cannot bridge" (§4.8), or anchor the horizon to the mark rather than to now when the mark is older |
| **F4**: the byte cap drops the newest shard or shards inside the horizon | after a restart those keys are re-applied; a re-applied delete is not idempotent against a later put that is still marked handled, and removes a restored file | cap must preserve every key ≥ horizon (or shrink the horizon consistently); make delete application consult the store (manifest absent) so re-application is idempotent |
| **F5**: handled set loaded once per process | entries applied by another process are re-applied | re-read on each pass or on a change of the applied log, and have one converger (§4.9) |
| **F6**: reading an entry maps every error to "absent" | the pass skips a transiently unreadable entry, advances the mark, and never reports it; in `INTENT` recovery a hidden newer peer entry lets a stale op (e.g. a delete) publish over the peer's file | distinguish "absent" from "failed"; a failure aborts the pass (link) or steps aside (other); recovery fails the record rather than proceed |
| **F7**: several writers per cache root with per-process locks | data loss (a peer delete discards a fresh staged edit); a second recovery over another process's records | §4.9 requirements |
| **F8**: no fsync of WAL records or staged sidecars | power loss can leave a torn record, which reads as an empty `INTENT` and is deleted: acknowledged work lost | fsync record (and directory) before acknowledging; same for staged data |
| **F9**: staged-edit crash window deletes the old body before writing the new sidecar | the upload then reads "staged bytes gone", and the record is abandoned as nothing owed | write new data and sidecar before forgetting old data; treat "bytes gone for a record that exists" as an error, not as nothing owed |
| **G8**: pause does not reach the converger | peers' ops keep applying while paused | deliver pause to the converger; persist it |
| **`EXECUTED` does not persist the as-published ops** (found in this reading; not in findings) | the metadata queue marks `EXECUTED` and publishes the *rewritten* ops, but the record keeps the originals. A crash between the two makes recovery publish the original ops. A folder moved aside to a conflict name is then announced at its old name, where the store files another folder, and an op the decision dropped as owed nothing is announced anyway | write the rewritten ops together with `EXECUTED` in one atomic record update |
| duplicate own lines in the applied log ([03 §9.2](../03-journal-sync.md)) | a record noted and then failed to publish is noted again on retry; a feed anchor on the first copy can replay entries | note once per key (check the tail, or note at `EXECUTED` in the same write) |
| key collision across processes ([03 §9.8](../03-journal-sync.md)) | two units share one key: one journal object and one record overwrite the other | per-client uniqueness (§4.9) |
| clock skew ([03 §9.7](../03-journal-sync.md)) | a peer's clock more than `HORIZON` behind makes all its entries invisible to clients that have ever synced | refuse to mint when the local clock is behind the newest key seen; or have peers apply entries by visibility age |
| mixed records ([03 §9.11](../03-journal-sync.md)) | a `PREPARED` record with puts and metadata goes through the `INTENT` path and re-applies local halves already done | split mixed records at creation, or give them their own recovery case |

---

## 9. Alternatives and why this design

- **"List entries after the last-seen key."** This is the obvious incremental read, and it was
  the implementation until it lost entries under concurrent uploads (commits `2102b6bc`,
  `aebaeff5`). It is rejected because keys are minted at start and become visible in a different
  order. The positional applied log, the handled set and the horizon replace it.
- **A store-assigned sequence** (conditional append, compare-and-swap on a log head, or a
  server). It would give a true total order and cheap "since" reads. It is ruled out by A1:
  object stores, local disks and a proxy peer are all backends, and the protocol must run on the
  least capable.
- **Relying on the cursor alone** (wait for it to move, then list). Bumps get lost (debounce,
  crash), and another process's older bump overwrites a newer one. A sweep was added (`9ba6f9d5`,
  `be0f7fe1`), then timed from the last listing because every store's wait returns sooner than
  the sweep (`2569ed4f`).
- **Listing on every wake-up.** It is correct and simpler, but costs one list request per client
  every two seconds for "nothing changed". The cursor exists only to avoid that.
- **A committed WAL state.** It costs one more local write per unit. `EXECUTED` plus a HEAD of
  the entry gives the same idempotence.
- **Recording in the applied log from each publisher.** There were five publishers and the next
  one would forget. Recording and announcing were moved into the one wrapper (`d48dc303`,
  `492b878c`).
- **Recording after publishing.** That allows "published, never noted", which cannot be reported.
- **Blocking on a failing peer entry, or on a failing metadata op.** This wedged a client for
  hours. The design now sets such a unit aside and retries it, with link failures still blocking
  (`0872ce2f`, `7e99a17a`).
- **Deferring a peer's entry until local work publishes.** Rejected by the best-effort principle:
  resolve at arrival, never defer the poller (see
  [conflict resolution](conflict-resolution.md)).
- **State transfer instead of ops** (ship the tree or per-folder snapshots). It would make
  convergence trivial, but costs a walk per change and loses the change feed. This design uses it
  only as the rebuild escape hatch. It already takes the hybrid route for content: puts are "go
  re-read the current manifest".
- **Carrying a base version in content puts** (the manifest hash the edit started from). This
  would let a peer tell a concurrent edit from a later one and keep the published loser as a
  conflicted copy instead of only in version history. It is not done. The best-effort bar accepts
  the overwrite.
- **A lock held across store requests.** It is simpler to write, but it freezes the mount on a
  slow link. The read-ahead with answers-as-data replaces it.
- **Minting folder ids and claiming names centrally.** Ids are minted locally and never change,
  so frontend references stay valid. Names are claimed on the store at publish time
  (`addadddc`), and a taken name becomes a conflicted copy.

---

## 10. Mapping to the current implementation

| Abstract | Concrete | Spec |
|---|---|---|
| entry key | `Journal.Entry_key.t` `{ms; client_uuid}`, printed `%013Ld-<uuid>`; only constructor `of_string` | [03 §2.2](../03-journal-sync.md) |
| client id | `<data_dir>/client-uuid`, created by `link()` race | [03 §2.1](../03-journal-sync.md) |
| op vocabulary | `Journal.op` (`` `Put | `Delete | `Mkdir | `Rmdir | `Rename ``), NDJSON body | [03 §2.3–2.4](../03-journal-sync.md) |
| journal entry | `tsync/<domain>/journal/<YYYY-MM>/<key>`, key → backend key only via `File_store.journal_key` | [03 §2.4](../03-journal-sync.md) |
| cursor | `tsync/<domain>/cursor`; debouncer in `file_store.ml` (`note_cursor`, `bump_cursor`, `flush_cursor`), `cursor_flush_interval = 2 s` | [03 §2.5, §4.2](../03-journal-sync.md) |
| last-sync mark | `<data_dir>/last-sync-<domain>` (`read/write_last_sync_key`) | [03 §2.6](../03-journal-sync.md) |
| applied log / change feed | `Applied_entries` (`note`, `since`, `head`, `keys`, `prune`), `<cache_root>/<domain>/applied/YYYY-MM.log`, `keep_days = 30`, `keep_bytes = 64 MiB`; feed = `ipc changes_since` | [03 §2.7, §3.2, §4.7](../03-journal-sync.md) |
| WAL record, states | `Wal` (`record`, `advance`, `note_failure`, `update_ops`, `complete`, `list`, `owed_metadata`), `<data_dir>/journal-pending/<domain>/<key>`, states `intent/prepared/executed` | [03 §2.8](../03-journal-sync.md), [04 §4.6](../04-checkout-cache.md) |
| hand-off to queues | `Wal.Owed` (`owed` for puts, `meta_owed` for metadata), `signal` / `consume` | [04 §4.6](../04-checkout-cache.md) |
| `DISCHARGE` | `Wal.discharge ~publish ~cursor` with `write_journal_entry` + `note_cursor` | [03 §4.1](../03-journal-sync.md) |
| note-before-publish wrapper | `file_store_lwt.ml` `write_journal_entry` (`Applied_entries.note`, put, `Change_notice.send`), `note_local` | [03 §3.3, §7.10](../03-journal-sync.md) |
| metadata queue | `Meta_queue` (ordered durable queue, `classify_in_order`, poison `Stop`, `parked`, `rearm` every 60 s by maintenance "metadata retry") | [03 §4.1, §3.6](../03-journal-sync.md) |
| upload queue | `Sync_queue` (keyed pool, `maxUploads`, cancel-and-replace per file) | [03 §4.1](../03-journal-sync.md) |
| local halves / writers | `File` `owing`, `rename_local`, `queue_put`, under `with_meta` in `File.Local` | [04 §4.6](../04-checkout-cache.md) |
| poller | `Sync_poller` (`sync_once`, `start`, `sweep_interval = 60 s`, `retry_floor = 2 s`, `held_tick = 0.2 s`); `wait_cursor_change` per store | [03 §4.3](../03-journal-sync.md) |
| `APPLY_PASS`, handled set, step aside | `Replay.apply_foreign`, `handled_set`, `stepped_aside` (per domain), `unapplied` | [03 §4.3](../03-journal-sync.md) |
| failure classes | `Retry.classify_in_order`, `Retry.Failed{kind}`, `Retry.Cancelled`, `Shutdown.Stopping`, upload `ENOENT` | [03 §7.7](../03-journal-sync.md), [ocaml/03 B-I.4](../ocaml/03-journal-sync.md) |
| D-Arrival | `File.apply_foreign_ops` (read-ahead `Foreign`, apply `Local.Peer_entry`), `Resolve.Arrival.decide` | [03 §4.4](../03-journal-sync.md), [04 §4.8](../04-checkout-cache.md) |
| D-Publish | `File.backend_ops` (`Backend_half`, `as_published`), `Resolve.Publish.decide` | [03 §4.5](../03-journal-sync.md), [04 §4.9](../04-checkout-cache.md) |
| reconcile | `Replay.reconcile` (`finish_executed`, `resume_prepared`, `replay_unpublished`, `overridden_since` with `Bounded ~max:32`, `adopt_unrecorded`) | [03 §4.6](../03-journal-sync.md) |
| rebuild and bridge check | `Resync.run` (`tsync sync [--full]`), `Entry_key.cannot_bridge`, `refuse_if_metadata_owed`, `Replay.mark_handled` | [03 §4.3](../03-journal-sync.md), [05](../05-ops-config.md) |
| journal pruning | `Retention.expire ~cutoff` (`tsync expire`), keeps the cursor's entry | [05 §4.8](../05-ops-config.md) |
| bulk batching | import `Publish` spool: `entry_ops = 2000`, `entry_age = 10 s`; rebuild `note_local` every 64 ops | [05](../05-ops-config.md) |
| converger | launcher parent `Domain_engine.converge` (reconcile, poller, maintenance); frontends run `Domain.start` (queues only) | [03 §5.1](../03-journal-sync.md), [07](../07-daemon-cli.md) |
| pause | `Pause` switch over both queues and poller `paused` | [03 §3.6](../03-journal-sync.md), findings G8 |
| tests | `tests/unit/resolve`, `tests/scenario/{conflicts,sync,meta_offline}`, `tests/unit/{applied_entries,cursor_debounce,cursor_watch}`, `tests/ops/resync` | [03 §8](../03-journal-sync.md) |
