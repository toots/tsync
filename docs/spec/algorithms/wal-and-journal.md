# WAL and journal: one replication protocol over a dumb store

This document owns the replication protocol of one domain: the WAL state machine, publishing,
discovery, application of peers' entries, crash recovery, the dedupe horizon, the detection of a
client that can no longer bridge the journal, and what such a client must do. The WAL on each client
and the journal on the store are two halves of one protocol and are specified together.

Related rules owned elsewhere, referenced and not restated:

- byte formats of the journal entry, the cursor, the applied log and the last-sync mark, and the
  sync interfaces: [03](../03-journal-sync.md);
- the conflict principle and both decision tables: [conflict-resolution.md](conflict-resolution.md);
- durable-write primitives (P2), the durable queue, parking and re-arm, and the crash-immunity
  inventory: [durable-queue.md](durable-queue.md);
- failure kinds and their propagation (P3, P7): [failure-model.md](failure-model.md);
- the process model and the domain owner (P1), pause, status: [07](../07-daemon-cli.md);
- local entities and the WAL's byte format: [data-model/local-cache.md](../data-model/local-cache.md),
  [04](../04-checkout-cache.md);
- journal expiry on the store and the GC interlock (P8): [gc.md](gc.md);
- the rebuild walk (`tsync sync`): [05](../05-ops-config.md).

---

## 1. Goals

- **G1 — Local operations never wait on the network.** A mutation completes against the local
  replica and becomes a debt to the store, paid later.
- **G2 — Acknowledged work is never lost.** A mutation that returned success reaches the store, or
  is found to be owed nothing (superseded, or its data is gone), across crashes, power loss and
  restarts.
- **G3 — Every client learns of every change.** Each published entry is applied by every other
  client, including entries that become visible late or out of key order.
- **G4 — Convergence under quiescence.** Once mutations stop and every debt is paid, all replicas
  hold the same tree.
- **G5 — One bad unit never blocks the rest.** A unit that fails for a reason local to one client
  does not stall that client's other traffic. A link failure does stall traffic, on purpose.
- **G6 — A local change feed.** Every client keeps an ordered record of what it handled, its own
  work and its peers'. It never runs ahead of the replica.
- **G7 — A client that cannot bridge the journal knows it.** A client that may have missed entries
  (pruned, or hidden by the horizon) stops applying incrementally and repairs itself by a rebuild,
  never silently diverging.

Non-goals: linearizability or causal order across clients; coordination between clients (no
locks, leases or consensus on the store).

---

## 2. System model and assumptions

**A1 — The store is dumb.** It offers `put` (overwrite allowed), `get`, `head`, `list(prefix)`
(every key, any order, answered completely or failed) and `delete`. Only the conflict decisions use
a conditional create, to claim folder names. The journal needs no conditional write, append or
notification.

**A2 — Store consistency.** An object whose `put` returned is visible to `get`, `head` and `list`
from every client within `LIST_SLACK`. A store may serve a slightly stale version of an object but
never a torn one.

**A3 — Write rate per object name is limited** (about one write per second on object stores).

**A4 — Clocks.** Wall clocks name units of work. Clients' clocks agree within `LIST_SLACK`; the
bridging argument (§4.8) depends on it, nothing else does. Durations and timers use monotonic time
(P5).

**A5 — Failures.** Processes crash at any point, and machines lose power. Every local record the
protocol relies on is made durable before it is relied on (P2,
[durable-queue.md](durable-queue.md) §3). The link can be down for arbitrarily long.

**A6 — Actors.**
- *Clients*, each with a stable random identity shared by all processes of one machine.
- On each client and domain, exactly one **owner** (P1, [07](../07-daemon-cli.md) §2.2). Only the
  owner mints entry keys, writes the WAL's states, publishes entries, bumps the cursor, applies
  peers' entries, recovers, writes the applied log and the mark, and prunes the applied log. Other
  processes act through the owner's request interface or submit records to its logs
  ([durable-queue.md](durable-queue.md) §4.2).
- *Maintenance* on any client may delete old journal entries ([gc.md](gc.md)), within §4.8.

---

## 3. State

### 3.1 Shared (on the store, per domain)

| State | Nature | Invariant |
|---|---|---|
| **Journal**: entries `key → [op]` | immutable once written | an entry exists only after the store holds everything its ops name |
| **Cursor**: one object holding one entry key | last-writer-wins, rate-limited, may be stale, lost, or move backwards | a hint; correctness never depends on it |

The **entry key** (milliseconds at mint time, client id) is totally ordered and printed so that
lexicographic order equals that order ([03](../03-journal-sync.md) §2.2). It names the unit of work
from its WAL record to its journal entry, cursor value, applied-log line and change-feed anchor.
A record may be **re-keyed** before its entry is published (§4.2); once published, the key never
changes.

The **op vocabulary** is file put (path, size), delete (path), make folder (path, folder id), remove
folder (path, folder id) and rename (src, dst, is-folder, size, folder id). Ops name paths as the
writer saw them when publishing; folder ops carry the folder's stable id.

**A put carries no content and no base version.** It tells a reader to install the store's
*current* record for the path. Every other op likewise tells the reader which names and ids to
reconcile with the store's current state ([conflict-resolution.md](conflict-resolution.md) §5.2).
Applying entries in any order, or twice, therefore converges on the store.

### 3.2 Local, durable (per client and domain; owner-written)

| State | Must hold |
|---|---|
| **WAL**: one record per unit of owed work (§4.1) | durable before the work is acknowledged |
| **Applied log**: `(key, ops)` lines in *handling* order, own entries and peers' | at most one line per key; every key of the horizon (§4.8); a line never claims an effect that is not durable |
| **Last-sync mark**: one entry key, forward only | a time before which this client has seen every entry it will ever apply incrementally (§4.8) |
| **Replica**: mirror, staged edits, folder-id index | [data-model/local-cache.md](../data-model/local-cache.md) |

### 3.3 Owner memory (per domain)

- **Handled set**: the keys of the applied log. The owner loads it at ownership start and adds to it
  on every append; being the only writer (P1), it never re-reads it.
- **Stepped-aside set**: peer entries that failed on this client's own account, with their reasons.
- **Bridge state**: `incremental` or `hold(reason)` (§4.8).
- **Catch-up gate**: whether an apply pass completed cleanly since the last start or link outage
  (§4.2).
- **Cursor debouncer**: pending newest key, last publish time (monotonic), whether a timer is armed.
- **Poller memory**: last cursor value seen, monotonic time of the last listing.
- **Queue contents**: always derivable from the WAL.

Every check-then-act on this memory is serialised by the owner (P1).

---

## 4. The algorithm

### 4.1 Records and their states

```
          local half fails, or owes nothing
     ┌──────────────────────────────────────────────────────────────┐
     │                                                              ▼
 INTENT ──local half done──► PREPARED ──store half done──► EXECUTED ──entry published──► (released)
 (metadata only)             (puts are born here)             │
                                 │                             │
                                 └── nothing owed / superseded ┴─────────────────────────► (released)
```

- **INTENT**: the op is recorded; the local replica may be partly changed.
- **PREPARED**: the local half is done; the store half is owed.
- **EXECUTED**: the store holds what the entry will name. The record holds **the ops that will be
  published**, as rewritten by the publish decision ([conflict-resolution.md](conflict-resolution.md)
  §4.4), written together with the state in one durable replace. The entry may not exist yet.
- **Released**: the record is gone. There is no committed state: releasing *is* the commit, and
  recovery asks the store whether the entry exists.

A record carries: its ops; its state; attempt count and last failure; for each `delete` and file
`rename` op, the **expected prior record** ([conflict-resolution.md](conflict-resolution.md) §3.3);
and, while INTENT after a retarget, the **local location** the file occupies until its move is
redone. These last two are local only and never published.

**Record kinds.** A record is exactly one of: a *metadata record* (one or more non-put ops), a
*single put* (one put, from a staged edit or a symlink), or a *batch put* (several puts from a
whole-domain operation, with no staged edit). A record mixing puts and metadata: readers SHOULD
accept it, and recovery splits it (§4.7); writers MUST NOT create one. An INTENT record holding
only puts: readers SHOULD accept it as PREPARED; writers MUST create put records in PREPARED.

- An unreadable or unknown state reads as INTENT, the least advanced state, so recovery re-derives
  the rest and never skips work ([04](../04-checkout-cache.md) §2.8).
- A record whose key names another client is never run or released, and is reported.
- When an EXECUTED record is published, each folder op in it names the folder's current local
  place, found by id (a no-op when the record already holds it). An op with no expected prior
  has an *unknown* prior: readers SHOULD accept it; writers MUST record the prior of every
  `delete` and file `rename`.
- Orthogonal updates keep the state: noting a failure, and rewriting ops when a conflict retargets
  the record.
- **Re-keying** renames a record to a fresh key minted by the owner, atomically (one durable rename:
  at every instant exactly one record describes the work).

### 4.2 Outbound: a local mutation's life

```
WRITER, metadata op m, under the metadata lock:
  k := mint()
  wal.create(k, INTENT, [m], expected prior of m)   # durable before anything changes
  r := local_half(m)                                # no store request possible
    on failure: wal.release(k); fail
  if r = NOTHING_OWED: wal.release(k)               # e.g. renaming a never-published staged file
  else: wal.replace(k, PREPARED); metadata_queue.post(k)
  acknowledge

WRITER, content (close of a staged file, symlink):
  k := mint(); wal.create(k, PREPARED, [put(path, size)]); upload_queue.post(k); acknowledge

METADATA QUEUE (ordered, one worker, key order):
  job k:
    wait for the catch-up gate
    rec := wal.read(k)                              # re-read: a conflict may have retargeted it
    ops' := PUBLISH_DECISION(rec.ops)               # conflict-resolution §4.4; may act on the store
    if ops' = []: wal.release(k); return
    MARK_EXECUTED(k, ops'); PUBLISH(k, ops'); wal.release(k)

UPLOAD QUEUE (keyed: at most one job per file):
  job k:
    wait for the catch-up gate
    wait while an unpublished, unparked record with a smaller key renames a file from or to this path,
      or creates or moves a folder on its ancestor chain
    run the put rows of PUBLISH_DECISION            # conflict-resolution §4.5 P1, P2
    the upload job of 04 §4.6: chunks and manifest (GC interlock), commit the staged edit,
      MARK_EXECUTED(k, rec.ops) before promotion removes the staged manifest, promote
    PUBLISH(k, rec.ops); wal.release(k)

MARK_EXECUTED(k, ops):
  if now − k.ms > REKEY_AGE: k := rekey(k)          # §4.1; peers must see a fresh key
  wal.replace(k, EXECUTED, ops)                     # state and ops in one durable write

PUBLISH(k, ops):                                    # the one publishing operation
  applied_log.note(k, ops)                          # durable; a no-op if k is already there
  store.put(journal/k, encode(ops))                 # 03 §2.4
  announce(ops) to this owner's frontends
  cursor.note(k)
```

Queue mechanics (backoff, head-of-line retry, parking, re-arm, cancellation) are the durable
queue's ([durable-queue.md](durable-queue.md) §4.5–4.7); failure kinds map per
[failure-model.md](failure-model.md) §7.1. A SUPERSEDED ending is CANCELLED: its replacement record
is durable before the original is released.

**Ordering rules and their reasons.**

1. **Record before the local half.** A crash mid-change leaves an intent saying what the partial
   change was meant to be.
2. **Store half before the entry.** An entry tells peers to fetch or act on something; it must never
   name data the store does not hold.
3. **EXECUTED, with the published ops, before anything destroys the evidence of the store half**
   (the local promotion of an upload) and before publishing. Recovery then only asks "is the entry
   there?", publishes exactly what the publish decision chose, and never redoes the store half.
4. **Note before publishing.** "Noted but not published" describes something true (the change is
   in this replica) and the record still publishes it; "published but never noted" could never be
   reported. Noting, publishing and announcing are one operation so no publisher can forget a part.
5. **Publish, then the cursor, then release.** A peer that sees the cursor move finds the entry; a
   lost cursor note is repaired by the sweep; releasing last means every earlier crash leaves
   something for recovery.
6. **Metadata publishes strictly in key order** (one worker, head-of-line retry on retryable
   failures). A rename follows the mkdir it moves; a create follows the rename that freed its name.
7. **An upload waits for earlier unpublished records it depends on**: a folder mkdir or folder
   rename that places one of its ancestors (so the folder's marker is filed before any content under
   it), and a file rename from or to its path. Publishing a rename copies
   the source's record over the destination on the store; an upload of the destination landing first
   would be overwritten by the older content. A parked rename does not hold the upload (G5); when it
   is re-armed, its destination check finds the upload and retargets it
   ([conflict-resolution.md](conflict-resolution.md) P22).
8. **Content is keyed, not ordered.** Uploads run in parallel, one per file; the newest write of a
   file cancels and replaces the older job. A local move of staged files re-posts their uploads
   under fresh keys minted after the move's record, so peers apply the move before the puts, and a
   put always names the file's path at the time it is published.
9. **Catch up before publishing.** After owner start, and after any store request failed with
   TRANSIENT/link or UNREACHABLE, neither queue publishes until an apply pass that began after that
   event completed cleanly (§4.4). A peer's change made while this client was away then reaches it
   as an *arrival*, while its own work is still unpublished, which is where the conflict tables give
   rung 3 rather than rung 4. The gate does not apply while the domain is in `hold` (§4.8), nor in a
   host with no apply pass (a pulled tree, [08](../08-frontends.md)); an owner that does not poll
   continuously runs one apply pass before its queues publish.
10. **Stale keys are re-keyed before publishing.** A key older than `REKEY_AGE` at publish time is
    replaced by a fresh one, so every entry is visible to peers for at least
    `H − REKEY_AGE − LIST_SLACK` after it lands (§4.8).
11. **The metadata lock is never held across a store request** (G1).

**Submitted records** are adopted and re-keyed in the order their holds are released (§4.9), so
their key order, and with rule 7 their publication order, is the submitter's release order.

**Batching.** One record is one entry. Interactive ops produce one op per record. Whole-domain
operations publish batch puts ([durable-queue.md](durable-queue.md) §7.3). A rebuild reports its
diff in the applied log only (§4.8).

**Cursor coalescing** (A3), one debouncer per cursor object in the owner:

```
note(k):   pending := max(pending, k); if not armed: arm a timer for CURSOR_INTERVAL − since(last publish)
bump(k):   if since(last publish) ≥ CURSOR_INTERVAL: publish k now; else note(k)
flush():   take pending; if any, publish it (serialised with the timer's publish);
           a failure is logged and dropped: the cursor is a hint
publish(k): put(cursor, k); last publish := monotonic now, after the write lands
```

The owner flushes the cursor when its queues drain, before exit, and SHOULD flush when the host
signals imminent suspension. A lost bump costs latency only (the sweep finds the entry).

**Drain order** (stop, or a command that settles): metadata queue, then uploads, then cursor flush.

### 4.3 Inbound: discovering entries

```
POLLER (the owner, per domain; not in a pulled-tree host):
  loop:
    if paused: wait until resumed
    wait until the store says the cursor may have changed, at most SWEEP
    c := get(cursor)                         # a failure → back off RETRY_FLOOR, loop
    moved := c ≠ last_seen
    due   := monotonic now − last_listing ≥ SWEEP
    if moved ∨ due ∨ a poll was requested:
      last_listing := monotonic now
      APPLY_PASS(c)                          # a failure leaves last_seen unchanged
      last_seen := c
  on failure: log; wait RETRY_FLOOR (stop-aware)
```

- **The cursor is a hint.** It saves a listing per wake-up when nothing changed; correctness comes
  from the listing.
- **The sweep is timed from the last listing**, not from a wait timeout: every store answers a
  wait well inside `SWEEP`, so a sweep tied to a timeout would never run. The sweep finds bumps that
  never landed, a cursor overwritten backwards, and entries visible after their bump.
- **Store waits** (object store: a fixed sleep; local disk: a directory watch capped at the same
  interval; a peer tsync: a long poll) are specified by each driver ([06](../06-backends.md)). A
  wait's expiry is not a failure.
- A `poll` request ([07](../07-daemon-cli.md) §4.6) ends the current wait.

### 4.4 Inbound: applying entries

```
APPLY_PASS(c):
  if bridge = hold: return                                  # §4.8
  t0 := wall now
  listing := list(journal)                                  # complete, or the pass aborts
  if CANNOT_BRIDGE(mark, listing, c): bridge := hold; report; return
  due := sort_by_key { e ∈ listing | e.ms ≥ t0 − H ∧ e ∉ handled }
  oldest_open := none
  for e in due, sequentially:
    r := get(the listed object of e)
    case r:
      ABSENT               → bridge := hold (a due entry vanished: §4.8); report; return
      TRANSIENT, UNREACHABLE, DEADLINE → abort the pass; nothing advances
      STOPPING             → end the pass; nothing advances
      body undecodable or an op invalid (03 §2.3) → step aside (CORRUPT / INVALID)
      entry(ops) →
        apply_entry(ops)                                    # conflict-resolution §4.1
          failure: abort or step aside by kind (failure-model §7.1)
        on success: applied_log.note(e, ops); handled += e; stepped_aside −= e
                    tell this owner's frontends which paths changed
    if e ∉ handled: oldest_open := min(oldest_open, e)
  mark := max(mark, oldest_open = none ? key(t0 − LIST_SLACK) : key(oldest_open.ms − 1))
  catch-up gate := open
```

A pass is **clean** when it ran to its end (entries stepped aside do not make it unclean). The mark
is written durably, forward only, only at the end of a clean pass.

**Dedupe against the handled set within the horizon, never "keys after a cut".** Keys are minted
when work is published or started; entries become visible in another order (slow uploads, retries,
parallel workers, listing lag, a client back from days offline). Any rule of the form "list keys
after the last one seen" loses every entry that lands behind the cut, silently, and reports
nothing to apply. Membership in the handled set has no such hole: an entry is due whenever it is
visible, within the horizon and unhandled. **Author does not matter**: an entry of this client's own
id that is not in the handled set was not applied to this replica (another process published it)
and is applied like any other; the owner's own entries are always in the set, because they are
noted before they are published.

**Apply in key order.** For one client's metadata this equals its publication order (§5.2), which
its ops depend on. Across clients key order is arbitrary; the decisions are written against the
store's current state and local facts, not against an expected sequence.

**Step aside, do not block.** An entry that fails for a reason other than a retryable one is left
unhandled, recorded in the stepped-aside set with its reason, reported by status, and retried on
every pass; later entries proceed. A retryable failure aborts the whole pass: skipping would lose
order, and waiting costs nothing when nothing can be read. A stepped-aside entry holds the mark
below its key, so an entry that never applies eventually makes the client unable to bridge (§4.8)
and is repaired by the rebuild rather than forgotten.

**Apply atomicity.** One entry's ops are enacted within one hold of the metadata lock; no local
mutation interleaves inside an entry. Store reads happen before the lock, in a read-ahead
([conflict-resolution.md](conflict-resolution.md) §3.4). Each op's effects are durable before the
entry is noted.

**The applied log is the change feed.** Readers page through it by position (the line holding an
anchor), never by key comparison; the log is sharded by handling time, so an entry handled late with
an old key appears after anchors taken earlier. A missing anchor means "re-list from scratch"
([03](../03-journal-sync.md) §2.7, [08](../08-frontends.md)).

### 4.5 Failure handling

Every failure on either path is classified once, by [failure-model.md](failure-model.md); its
§7.1 table gives the response for the ordered queue (metadata), the keyed queue (uploads) and
inbound entries. The protocol adds:

- A listing or entry read that fails is never "no entries" or "no entry" (§4.4).
- A listed due entry that reads ABSENT puts the domain in `hold` (§4.8).
- A record is never released on a kind that can clear by itself.

### 4.6 The two conflict decision points

The policy is [conflict-resolution.md](conflict-resolution.md). The protocol places the decisions
and relies on these properties of them:

- **Arrival** runs inside `APPLY_PASS`, per op of an unhandled entry, with store answers read ahead
  and local facts read under the lock. A skip still lets the entry be noted handled.
- **Publish** runs in the queue job before `MARK_EXECUTED`, outside the lock. Its output is the ops
  as they are here now (what `MARK_EXECUTED` records and `PUBLISH` publishes), plus one ending.
- **Convergence**: for every combination of facts both clients end with the same tree once both
  have published and applied.
- **Idempotence and order-insensitivity**: re-applying an entry, or applying entries out of key
  order within the horizon, ends in the same state.
- **Skips are backed by owed work**: "ours publishes later" is safe because the record persists
  until published (G2).
- **Progress**: a superseding decision writes its replacement record before the original is
  released; `again` is bounded.
- **No store request under the metadata lock.**

### 4.7 Crash recovery (reconcile)

Run once at ownership start, before the queues accept posts and before the first apply pass.
Records are processed sequentially in key order; records of other client ids are left and reported.

```
for (k, rec) in wal.records() in key order:
  try:
    case rec:
      EXECUTED:
        (a committed upload was already promoted by 04 §4.10)
        case head(journal/k):
          present → release
          ABSENT  → PUBLISH(k, rec.ops) (re-keying first if k is older than REKEY_AGE); release
          failure → leave owed
      PREPARED single put:  the upload queue; its job (04 §4.6) handles an owed edit, a committed
                            edit, a symlink, and no staged edit (durable-queue §7.3)
      PREPARED batch put:   the no-staged-edit rule of durable-queue §7.3, per op
      PREPARED metadata:    the metadata queue (the publish decision re-gathers facts)
      INTENT metadata:      redo_local(each op); wal.replace(k, PREPARED); the metadata queue
      INTENT with only puts: wal.replace(k, PREPARED); as PREPARED
      mixed puts and metadata:
        write each put as its own PREPARED single-put record under a fresh key;
        keep the metadata ops in k (state unchanged) and handle k as above
  except failure: note it on the record and leave it for the next start (reported)
```

Promotion of committed edits runs before reconcile, and adoption of staged edits no record names
runs after it ([04](../04-checkout-cache.md) §4.10). Parked records of both queues are re-armed
([durable-queue.md](durable-queue.md) §4.7).

**Local redo** (INTENT metadata; idempotent):

- `delete(p)`: remove the local file at `p` if present.
- `mkdir(p, id)`: create a folder with `id` at `p` unless `id` is held anywhere.
- `rmdir(p, id)`: remove the folder holding `id`; with no id, the folder at `p`; nothing if absent.
- file `rename(s → d)`: if the record names a local location `X`, move `X → d` when `X` is present
  and `d` absent; otherwise move `s → d` when `s` is present and `d` absent; otherwise nothing (the
  op stays owed: its store half is decided by the publish decision).
- folder `rename(s → d, id)`: move the folder holding `id` to `d` when `d` is absent.

**Crash windows.**

| Crash between | Durable state left | Recovery |
|---|---|---|
| staging content and writing its record | staged edit, no record | adopted with a fresh put record |
| intent and the end of the local half | INTENT, replica partly changed | local redo, then publish |
| local half and PREPARED | INTENT, local half complete | local redo is a no-op, then publish |
| PREPARED and the store half | PREPARED | the queue re-runs the decision and the store half (idempotent: content-addressed chunks, overwrite with the same manifest, publish decisions re-gather facts and find "already there") |
| the store half and EXECUTED | PREPARED, store already changed | as above: the decision finds `landed`, `filed_here_already`, `already_trashed`, `store_gone`; a committed upload only promotes |
| EXECUTED and the local promotion | EXECUTED, committed staged edit | promotion finished, then publish if the entry is absent |
| EXECUTED and the note | EXECUTED | head → publish |
| note and publish | EXECUTED, the applied log holds the key | head → publish; the note is not repeated |
| publish and cursor note | EXECUTED, entry visible | head → release; peers' sweep covers the missed bump |
| cursor note and release | EXECUTED | head → release |
| a peer entry partly applied | entry unhandled | the next pass re-applies it idempotently |
| a peer entry applied, not noted | entry unhandled | the next pass re-applies; decisions find "already applied" |
| re-keying | exactly one record, under the old or the new key | as its state says |

### 4.8 Retention, horizon, bridging and rebuild

**The horizon.** An entry is due only if its key is at most `H` old (`e.ms ≥ now − H`). The handled
set covers every key of that window because the applied log keeps it:

- **Applied-log retention.** A shard MAY be deleted only when it is not the newest shard, every
  key in it is older than `now − H − LIST_SLACK`, and it was handled entirely before the entry the
  feed watermark names (the shard holding that entry is kept, and every later one;
  [08 §3.6](../08-frontends.md#36-change-feed-changes_since)). Deleting a shard sets the
  dropped-shard record durably first. Nothing else deletes applied-log lines; there is no
  size-based pruning. (Keys older than the horizon are never due, so their lines are no longer
  needed for dedupe; the margin covers a clock step between prune and pass.)
- **Journal retention** ([gc.md](gc.md)). Expiry MUST NOT delete an entry whose key is younger than
  `H`, and MUST keep the entry the cursor names. Age is the only safe criterion: nothing on the
  store records what every client applied.

**The mark.** The mark `M` is an entry key up to which this client has examined the journal: an
entry with a key at or below `M` was listed by a pass of this client, and it is handled or it is
treated like any late entry (applied while it is due). Any key of a handled entry is a valid mark,
and so is any key below one. After a clean pass that started at wall time `t0`, the mark moves
forward to `key(t0 − LIST_SLACK)` if no due entry stayed unhandled, else to just below the oldest
one; it never moves back. The bridge checks (B2, B3) look for entries that could be missed above
the mark rather than at the mark's age, so an old mark on a quiet domain causes no rebuild. The
mark is written durably ([03](../03-journal-sync.md) §2.6).

**Stale keys are re-keyed** (§4.2 rule 10): every entry's key is at most `REKEY_AGE` old when it is
published, so it stays due for every client for at least `H − REKEY_AGE − LIST_SLACK` after it is
listed.

**Cannot bridge.** The owner evaluates at the start of every pass, with `M` the mark and `c` the
cursor just read:

| # | Condition | Why |
|---|---|---|
| B1 | no mark | nothing was ever handled incrementally; the replica has no base to apply to |
| B2 | a listed entry that is newer than `M`, older than `now − H`, and not handled | the entry is hidden by the horizon and would never be applied |
| B3 | the smallest listed key other than `c` is newer than `M`; or no key other than `c` is listed and `c` is listed and newer than `M` (a cursor naming an entry the listing lacks, such as one a replica has not copied yet, is ignored) | entries after `M` may have been pruned (by expiry, possibly with a shorter cutoff than §4.8 requires) |
| B4 | a due entry read ABSENT during a pass | an entry this client had not handled was removed |

An empty journal with no cursor is a fresh domain: it satisfies none of B2–B4 by itself.

**What a client that cannot bridge does.** It enters `hold`:

1. It applies nothing incrementally, and reports `hold` with its reason, the mark's age and the
   count of owed metadata records in status ([07](../07-daemon-cli.md)).
2. Its queues keep publishing (the catch-up gate does not apply), so owed metadata drains.
3. As soon as no metadata record is owed (none unpublished, none parked) and the domain is not
   paused, the owner runs a **rebuild** by itself.
4. While a metadata record stays parked, it remains in `hold` and reports the parked record as the
   repair to make. A rebuild would discard the local halves of owed metadata, so it never runs
   over them.

**Rebuild obligations.** Any rebuild (automatic, or `tsync sync --full`; the walk is
[05](../05-ops-config.md)):

1. MUST refuse while any metadata record is owed (UNPREPARED).
2. Takes `t0 := wall now` and a complete journal listing **before** walking the tree.
3. Walks the store's tree and rewrites the replica in place; staged edits are untouched. Each
   difference is appended to the applied log under a freshly minted key with the ops it amounts to,
   so feed readers learn it. A rebuild stamps no new resync generation: outstanding change-feed
   anchors stay valid and read the difference as ordinary ops. At its end the owner rebuilds the
   reverse folder index from the mirror.
4. Only if the walk had no failures: notes every listed key not yet handled with empty ops (their
   effect is in the tree just read), sets the mark to `key(t0 − LIST_SLACK)`, clears the
   stepped-aside set, and returns the domain to `incremental`.
5. Otherwise leaves the mark and `hold` as they were, and reports the failures.

Entries published during the walk that the listing missed stay unhandled and are applied
incrementally afterwards; re-applying an effect the walk already read is idempotent.

### 4.9 One owner per domain

The protocol relies on P1 ([07](../07-daemon-cli.md) §2): one process owns a domain's WAL, applied
log, mark, handled set, stepped-aside set, debouncer and poller. Consequences the protocol depends
on:

- **Key uniqueness.** Only the owner mints entry keys for journal entries: `max(now_ms, last + 1)`,
  where `last` starts at ownership from the largest key it finds in the WAL, the applied log's own
  lines and the mark, so a clock step backwards never re-mints a used key. A record submitted by
  another process ([durable-queue.md](durable-queue.md) §4.2) carries a provisional id; the owner
  re-keys it with a fresh key when it adopts it. Adoption follows release: a record is adopted only
  once its submitter released its hold, records adopted in one rescan are re-keyed in provisional-id
  order, and later rescans mint later keys. A submitter that creates and releases its folder records
  before its file records therefore gets smaller keys for the folders, and §4.2 rule 7 then files
  every folder before any put under it ([05](../05-ops-config.md) §4.2).
- **One dedupe set**, never stale, because the owner is the only writer of the applied log.
- **One debouncer per cursor**, so a flush publishes every pending bump of the domain.
- **Pause** holds the poller and both queues; the owner persists it ([07](../07-daemon-cli.md) §2.6).

---

## 5. Properties and why they hold

### 5.1 Safety

**S1 — Acknowledged work stays owed until discharged** (G2). A mutation is acknowledged only after
its record is durable. A record is released only after its entry is published; when its local half
failed (the mutation failed too); or when nothing is owed: superseded by a replacing record already
durable, cancelled by a newer job for the same file, its publish decision found the store already
agreeing, or its staged data and the store's manifest are both gone. Every crash window leaves a
state recovery maps to the remaining work (§4.7).

**S2 — No entry names data the store lacks.** An entry is published only after EXECUTED, which is
set only after the store half returned; recovery publishes a put without a staged edit only for a
manifest the store holds.

**S3 — What is published is what was decided.** EXECUTED records the rewritten ops; recovery
publishes those, never the originally recorded ops.

**S4 — No entry is skipped because of arrival order** (G3). A pass admits every visible entry
within the horizon that is not handled; the set grows only by entries fully applied or marked by a
clean rebuild. An entry visible after later ones were applied is still due at the next pass.

**S5 — No entry is silently lost to the horizon or to pruning** (G7). Applied-log retention keeps
every key of the horizon; journal expiry keeps every entry younger than `H`; re-keying keeps
published keys fresh; the mark never passes an unhandled entry; B1–B4 detect every case in which an
entry this client did not handle can no longer be listed or is no longer due. The bounds hold under
A2 and A4.

**S6 — The feed never runs ahead of the replica** (G6). Peers' entries are noted after their
effects are durable; own entries after the local half.

**S7 — Local operations never wait on the store** (G1). Store requests happen in queues, in the
unlocked read-ahead, or in the poller.

**S8 — Re-application is harmless.** Every arrival action installs the store's current state for
the names it touches ([conflict-resolution.md](conflict-resolution.md) §5.2), so a repeated, late or
out-of-order entry cannot undo a later write.

### 5.2 Ordering

- **Metadata entries of one client become visible in key order**: the single worker publishes each
  record completely before the next, and keys are minted monotonically by the owner (re-keying
  preserves the order, since records are re-keyed in publication order). Under A2 a lagging listing
  may show a later entry first; the arrival decisions tolerate this (§5.1 S8).
- **Content entries have no order** among themselves or with metadata, except that an upload
  follows the earlier records it depends on (§4.2 rule 7). A put before the mkdir of its
  folder materialises the folder without an id, and the mkdir gives it its id.
- **No causal order across clients.**

### 5.3 Liveness

- **L1 — Outbound progress.** With the link up and the catch-up gate open, every PREPARED record
  reaches EXECUTED and is released, or is parked, reported and re-armed.
- **L2 — Inbound latency.** A published entry is applied by a running owner within
  `CURSOR_INTERVAL` plus one store wait when the bump lands, and within `SWEEP` otherwise, unless
  the link is down, the domain is paused or in `hold`, or the entry is stepped aside.
- **L3 — Isolation** (G5). A stepped-aside entry or parked record costs one retry per pass or
  re-arm.
- **L4 — Repair.** A client in `hold` rebuilds as soon as its metadata is discharged; a
  permanently failing peer entry leads to `hold` once its key leaves the horizon (B2) and is then
  settled by the rebuild.
- **L5 — Convergence under quiescence** (G4). With no mutations, working links, every client
  running, and every parked record eventually succeeding: every record is discharged (L1), every
  entry is applied everywhere or covered by a rebuild (S4, S5, L2, L4), and the tables make both
  sides agree ([conflict-resolution.md](conflict-resolution.md) §5.2).

---

## 6. Abandonment and operator action

- A record is released without an entry only when nothing is owed (S1). A record that keeps
  failing stays, counted and shown with its last failure, and is re-armed
  ([durable-queue.md](durable-queue.md) §4.7).
- A failed recovery of one record notes the failure and moves on; the next start retries it.
- A link outage aborts passes and holds the queues at the head; the catch-up gate closes, and
  reopens after the first clean pass.
- `tsync sync --full` forces a rebuild (refused while metadata is owed); `tsync sync` runs one pass,
  or a rebuild when the domain cannot bridge ([05](../05-ops-config.md)).

---

## 7. Parameters

| Parameter | Recommended | Constraint / effect |
|---|---|---|
| `H` (dedupe horizon) | 30 days | MUST be ≤ the journal's minimum retention ([gc.md](gc.md)); bounds the handled set |
| `LIST_SLACK` | 1 day | the bound of A2 (listing lag) and A4 (clock agreement) |
| `REKEY_AGE` | 1 day | a record older than this at publish time is re-keyed; MUST be less than `H − LIST_SLACK` |
| `CURSOR_INTERVAL` | 2 s | MUST be ≥ the store's per-object write interval (A3) |
| `SWEEP` | 60 s | worst-case latency when a bump is lost; one listing per client per interval when idle |
| store wait | object store 2 s; local disk watch capped at 2 s; peer long poll ≤ 30 s | cursor reads per client |
| `RETRY_FLOOR` | 2 s | back-off after a failed pass |
| applied-log prune interval | 1 day | |

---

## 8. Conformance

An implementation MUST exhibit the following; the method (scenarios, crash injection, power-loss
states, multi-process runs) is [09](../09-tests.md) §6–7.

- **Batching.** One entry may carry several ops, applied in order. A bulk publisher files every
  folder it creates before any put under it, and splits its entries by op count and by age, so a
  long run publishes before it ends.
- **Local-first ordering.** Offline, every rename, delete, mkdir (id minted locally), rmdir and
  symlink returns with no store round trip and stays owed; after reconnect everything publishes in
  key order. A folder created then renamed publishes as `mkdir` at its current name followed by the
  rename with the same id; a folder created and removed before publishing is never filed; an upload
  into a folder whose mkdir is owed files the marker first.
- **Owed-work failures.** A retryable failure is retried without later records overtaking it; a
  permanent or local failure parks the record, later records publish, status reports it, and
  re-arming retries it.
- **Recovery.** A record whose store half is done and whose entry is missing is reported as
  executed and published exactly once after restart; a record naming data that was never staged
  publishes nothing; a never-started op completes once; an op whose local half ran is not redone.
- **Peer application.** A peer's put appears uncached; a peer's overwrite invalidates the cached
  bytes of the old version; a peer's rename keeps them; a chain of renames applies in one pass; a
  peer's mkdir and rmdir mirror the folder; a client that lost a folder's id re-adopts it from the
  store's marker; a peer's rename announces both the old and the new path to frontends.
- **Rebuild.** With no mark, a rebuild; when able to bridge, an incremental pass; `--full` forces a
  rebuild. A rebuild is reported as a delta in the applied log (rewritten entries, deletes for
  records the store lacks, folder changes as mkdir, rename and rmdir by id); cached chunks survive
  and earlier feed anchors stay valid. A walk with a failure leaves the mark and `hold` as they were
  and removes nothing. A rebuild with owed metadata is refused; an incremental run publishes owed
  metadata first.

- **Late visibility.** An entry hidden from listings while later entries are applied, then shown,
  is applied, and appears in the applied log after them.
- **Out-of-order and repeated delivery.** Applying a set of entries in any order within the
  horizon, or any entry twice, ends in the same replica as applying them once in key order.
- **No read as absent.** A transient failure injected into the listing, an entry read, a manifest
  read or the mark read aborts the pass: no entry is noted, the mark does not move, nothing is
  stepped aside.
- **Step aside.** A peer entry that cannot be applied here is reported as unapplied with its reason;
  later entries apply; it applies on a later pass once possible; the mark never passes it.
- **Bridging.** A client that lists an unhandled entry newer than its mark and older than the
  horizon, or whose journal was pruned past its mark, or which finds a due entry absent, applies nothing incrementally, reports `hold`, publishes
  its owed metadata, then rebuilds by itself and returns to incremental application; with a parked
  metadata record it stays in `hold` and reports it.
- **Retention.** Applied-log pruning never removes a key younger than `H + LIST_SLACK` nor the
  newest shard, whatever the log's size.
- **What is published is what was decided.** A kill after EXECUTED of a record whose publish
  decision rewrote or dropped ops publishes the rewritten ops only.
- **Promotion window.** A kill between an upload's store half and its promotion, and between its
  promotion and publishing, ends with the entry published and the file promoted.
- **Re-keying.** A record published more than `REKEY_AGE` after it was minted is published under a
  fresh key, exactly once.
- **Catch-up.** After a start or a link outage, a peer's edit of a file this client edited offline
  becomes a conflicted copy (rung 3), not an overwrite.
- **Own ordering.** An upload of a path renamed by an earlier unpublished rename lands after the
  rename on the store and in the journal.
- **Cursor.** A bump on a quiet cursor writes before returning; bumps within `CURSOR_INTERVAL`
  coalesce into one write of the newest key after the timer; an older key never replaces a newer
  pending one; a flush writes the pending key at once and nothing when idle; a stop writes a held
  bump even when its queue drain ran out of time.
- **Poller.** An idle owner waits before reading the cursor; a moved cursor costs one cursor read
  and one listing; an unmoved cursor costs one cursor read; a failed pass keeps offering the
  previous token; a due sweep lists with a still cursor.
- **Pause.** While paused nothing of this client reaches the store and nothing of the peer's is
  applied; reads are served; everything flows on resume.
- **Local-first.** Local operations complete with zero store round trips while the link is down,
  and publish once it returns.

---

## 9. Rationale

- **"List entries after the last-seen key."** The obvious incremental read. It lost entries under
  concurrent uploads because keys are minted before entries become visible. The positional applied
  log, the handled set and the horizon replace it.
- **Bridge checks on evidence, not on the mark's age.** A quiet domain leaves any mark old; an age
  test would rebuild healthy clients. B2 and B3 look for the entries that could actually be missed.
  The mark never passes an unhandled entry, so such an entry cannot age out of the horizon
  unnoticed.
- **Re-keying stale records.** A client back from a long absence publishes work minted long ago;
  under its original key that work would already be outside every peer's horizon.
- **Hold and rebuild automatically.** A client that silently applies what survives of a pruned
  journal diverges for good; a client that only reports it waits for a user who may never look.
- **Catch up before publishing.** Publishing first turns every offline edit that met a peer's edit
  into a silent overwrite; applying first lets the tables keep both.
- **A store-assigned sequence** (conditional append, a log head, a server) would give a total order
  and cheap "since" reads, but not every backend offers it (A1).
- **Relying on the cursor alone.** Bumps get lost and can move backwards; a sweep timed from the
  last listing covers both.
- **Listing on every wake-up.** Correct, and one list request per client every two seconds for
  "nothing changed".
- **A committed WAL state.** One more local write per unit; EXECUTED plus a head of the entry gives
  the same idempotence.
- **Recording in each publisher.** The next publisher forgets; one publishing operation notes,
  publishes and announces.
- **Blocking on a failing entry or record.** One bad unit wedged a client for hours; parking and
  stepping aside keep the rest moving, with link failures still blocking.
- **State transfer instead of ops.** Convergence would be trivial, at the cost of a walk per change
  and no change feed. The design uses it only as the rebuild; ops are hints that tell a reader
  which names to reconcile with the store's current state.
- **A lock held across store requests.** Simpler, and it freezes the mount on a slow link.
