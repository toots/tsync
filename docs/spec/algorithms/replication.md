# Multi-store replication

One domain is backed by several stores, each with a role, and is presented to every layer above as a single store with the ordinary object contract. This document specifies the policy and the algorithm independently of the current code; §10 maps it onto the implementation.

---

## 1. Problem and goals

A user's domain is a set of objects: content-addressed **chunks** (the name is a hash of the body), and **referrers** that name chunks (file manifests) or name other objects (journal entries name manifests, the cursor names the newest journal entry). The user wants more than one store to hold it: a source of truth, a full second copy that can answer reads when the first is unreachable, a copy being filled for later promotion, an old archive that still answers for what it holds.

Goals:

- **G1 One store.** Callers see one store with the ordinary contract (put, get, conditional put, delete, copy, list, watch). They never learn how many members there are or which answered.
- **G2 Roles as policy.** Each member's role fixes what it promises to hold, when, and whether reads may reach it.
- **G3 Writes are not slowed by copies.** A write returns once the sources of truth have it and every copy has *durably recorded* that it owes it. Copies catch up in the background, across crashes and restarts.
- **G4 Partial coverage, never partial files.** A copy may lag, but a referrer reaches it only after everything the referrer names is there. A reader of a copy may see an old tree; it never sees a file whose chunks are missing.
- **G5 Honest reads.** A read fails over past an unreachable member, and never reports "not found" because a member could not be asked.
- **G6 Copies are never ahead of the truth.** No copy is written while a source of truth is offline.
- **G7 Repairable.** Divergence (dropped work, corruption, a new empty member) is detectable and repairable by an explicit whole-store operation.
- **G8 Bounded resources.** Background forwarding holds a bounded number of bodies in memory, and a bounded amount of upload bandwidth.

Non-goals:

- Consensus between sources of truth. With several mains, the first one arbitrates conditional writes; the others are written in sequence with no rollback.
- Writes while the main is offline. Failover is for reads only (disconnected writes are the local write-ahead log's job, one layer up).
- Merged listings. A listing is one member's view.
- Automatic repair. Integrity findings and dropped jobs are reported; an operator runs the repair.
- Byte-level verification by the replication path. Stores verify bodies against names on their own (§4.7).

---

## 2. System model and assumptions

- **A1 Store operations.** Each member offers: atomic whole-object put (no partial object is ever visible); get / get-optional (absent is distinguished from failure); head; delete (reports whether something was there); bulk delete (absent keys are success; per-key failures are raised); copy; recursive prefix listing; a true server-side put-if-absent; a bounded watch on one key. Consistency: read-after-write on one key. Listings may be eventually consistent, but a missing key only costs extra work (§5).
- **A2 Failure classification.** Every failure is *transient* (retry may help: network, 5xx, throttling, timeouts) or *permanent* (the store's considered answer: absent, forbidden, malformed). Unknown failures are transient.
- **A3 Health per member.** Each remote member has a health cell fed by every request: consecutive transient failures spanning a minimum time *trip* it; a tripped member is *held* for a window that doubles on each failed probe; a considered answer, permanent failures included, proves the link and resets it. Exactly one caller per expired hold is granted the *probe*.
- **A4 Content addressing.** A chunk's name is a hash of its body. Chunks are immutable: two bodies under one name are the same bytes unless a store corrupted them. Referrers are mutable, last-writer-wins.
- **A5 Durable local disk.** Each process has a local directory whose atomic record writes survive a crash. Records are listable in creation order.
- **A6 Processes.** Several processes may build the same domain on one machine at once: one long-lived daemon, its forked frontends (which inherit its stores), and short one-shot commands. A per-directory advisory lock is available, and the kernel drops it when its holder dies. Other machines may write the same mains, but never the local job records.
- **A7 Cooperative scheduling** inside a process. Check-then-act on in-memory tables is atomic between suspension points (§8 notes what a preemptive runtime needs).
- **A8 Clocks.** Only durations are used (backoff, health windows, timeouts). No ordering decision depends on a clock.
- **A9 Garbage collection** runs over the main and deletes unreferenced chunks from every other member *directly*, not through the replication path (§4.8).

---

## 3. State

### 3.1 Roles (configuration, durable, per domain)

| Role | Promises to hold | When | Reads reach it | Written by |
|---|---|---|---|---|
| **main** | everything | synchronously: a write returns only after every main has it | first, in config order (the first main is the *read primary*) | the composite, directly |
| **replica** | everything, including journal and cursor | eventually: behind the write, through a durable per-member job log | only when no main answered (unreachable) | its deferred target |
| **backfill** | content only (manifests, chunks, folder markers). No journal or cursor | eventually, from the moment it was added. It starts empty and past content arrives only through repair | never. It is also never a share location | its deferred target |
| **read-only (archive)** | different content (an older or foreign store) | never written | after the sources of truth miss, or are unreachable | nobody |

A replica and a backfill are one mechanism that differs by one bit, *reads reach it*. Promoting a fully repaired backfill is a one-word configuration change.

Configuration rules: roles are required. Replica or backfill without a main is refused ("nothing to fill it from"). A domain with no main needs at least one archive and is then forced read-only. Member names must be unique (not enforced today, see G2 in §8). Read order is main < replica < archive < backfill, stable on config order.

### 3.2 Durable state

- **Job log**, one per (domain, deferred member), in local storage keyed by an escaped member name: an ordered sequence of *bodyless* jobs:
  - `Put(key)`
  - `Copy(src, dst)`
  - `Delete(key)`
  - `DeleteMany(keys)`

  A record exists from before the write returns until the job completes or is dropped. An unparseable record is dropped and counted.
- **Claim lock** beside each log: held by a process that keeps jobs of this log in memory (§4.6).
- **Corruption markers** in each store, under a separate prefix: "the object named N here is not what N says" (computed hash and size, or an unreadability reason).
- **Verify requests** and **server-side delete requests** as objects in the store they concern (the bucket is the queue).
- The **GC run marker** in the main (read by repair to refuse a whole-store copy mid-collection).

### 3.3 Volatile state (per process, per deferred member)

- `ensured`: a set of chunk keys known to be on the member, filled by forwards, by chunk puts inside jobs and by shard listings. Capped, and reset whole when full.
- `known_shards`: the shards whose listing has been folded into `ensured`. Reset together with `ensured`, because a key forgotten while its shard stayed "known" would never be relearned.
- `forwards_in_flight`: the count of best-effort chunk forwards.
- `running`: whether this process runs this log, or only records into it.
- `degraded`: a job was dropped. Only a repair restores the promise.
- The in-memory queue of jobs this process will run, in record order.

---

## 4. The algorithm

### 4.1 Composite construction

```
build(domain):
  mains    := members with role main, config order
  archives := members with role read-only
  source   := composite(mains, targets = [], archives = [])        -- mains only
  targets  := [deferred_target(m, source, reads_reach = (m.role = replica))
               for m in replica ∪ backfill]
  readable := mains ++ [t.store for t in targets if t.reads_reach]
  return composite(mains, targets, archives, readable)
```

A target catches up by reading **the mains only**, never the composite: a job is consumed once it succeeds, so a body read from a copy that is itself behind would land on the target and never be corrected.

### 4.2 Write path

```
put(key, body):
  if mains = []: fail NotWritable
  for m in mains (sequentially): m.put(key, body)        -- any failure fails the write; nothing is filled
  fill(Put(key, body))

put_if_absent(key, body):
  held := mains[0].put_if_absent(key, body)                -- the first main alone arbitrates
  for m in mains[1..]: m.put(key, held)
  fill(Put(key, held)); return held

delete(key):     removed := any(m.delete(key) for m in mains); fill(Delete(key)); return removed
delete_many(ks): for m in mains: m.delete_many(ks); for t in targets: t.accept(DeleteMany([k in ks | not t.skip(k)]))
copy(src, dst):  for m in mains: m.copy(src, dst); fill(Copy(src, dst))       -- skip decided on dst

fill(op): for t in targets (config order): if not t.skip(op.key): t.accept(op)
```

`skip(key)` is true for per-store caches (folder index objects, which describe the store that wrote them), and, for a target that reads never reach, for the journal and the cursor.

```
accept(op) at target T:
  case op of
    Put(key, body) with key a chunk:  forward_chunk(key, body); return       -- not recorded
    Put(key, _)       -> post(Put(key))
    Copy(s, d)        -> post(Copy(s, d))
    Delete(k)         -> post(Delete(k))
    DeleteMany(ks)    -> post(DeleteMany(ks))

post(job):
  if T.running_here:
     if in_memory_queue_length ≥ MAX_QUEUED: T.degraded := true; return   -- dropped, see §8
     under record_lock: write record durably; enqueue in memory
  else:
     write record durably; notify(the runner)                               -- §4.6

forward_chunk(key, body):                                  -- best effort, never blocks, never queues
  if not running_here or key ∈ ensured or forwards_in_flight ≥ MAX_FORWARDS
     or not uplink.try_admit(len body): return
  forwards_in_flight += 1
  spawn: try T.store.put(key, body); ensured += key   except: warn
         finally forwards_in_flight -= 1; wake settlers
```

The write returns when every main has the object and every target has either durably recorded the job or (for a chunk) decided on the forward. That is the *durability point* for copies. A crash after it loses no copy work. The only exception is a chunk forward, which nothing needs (see below).

The **referrer-after-referenced rule** is enforced by the consumer, not by the order of arrival:

```
run(job) at target T (one worker, record order):
  Put(key):
     body := source.get_optional(key)
     if body = none: return                         -- deleted since; a later Delete job says so
     for c in chunk_names(body) (sequentially): ensure_chunk(c)
     T.store.put(key, body)                         -- only after every chunk is confirmed
  Copy(s, d):
     try T.store.copy(s, d)
     except Stopping: re-raise                       -- still owed
     except _: run(Put(d))                           -- T lacks s; rebuild d, chunk check included
  Delete(k):       ensured -= k; T.store.delete(k)
  DeleteMany(ks):  ensured -= ks; T.store.delete_many(ks)

ensure_chunk(c):
  if c ∈ ensured: return
  learn_shard(shard(c))                               -- list T's shard once; add every key to ensured
  if c ∈ ensured: return
  body := source.get_optional(c)
          or, if a collection is open, source.get(from_space(c))    -- else fail: not found
  T.store.put(plain_name(c), body); ensured += c      -- a target has one space
```

`chunk_names(body)` is the chunks the body names if it parses as a manifest, and nothing otherwise (markers, journal entries, shares). Journal entries and the cursor need no dependency check: one ordered worker runs the jobs of one process's log, and the writer puts the manifest before the entry that names it, and the entry before the cursor that names that. So a replica never publishes a cursor ahead of the entries and manifests it describes (within one writer process, see gap R2).

Why bodyless jobs: repeated puts of one key converge on the latest body, a put whose key was since deleted reads nothing, and the log stays small. Why one record per user-visible operation rather than per chunk: deduplication means a copy or an incremental re-upload issues no chunk puts at all, so correctness must rest on the manifest job's chunk check, and chunk puts are pure prefetch.

**Queue discipline.** One worker per target, in record order. A job that fails transiently stays at the head and is retried with exponential backoff (cap 5 min). Nothing overtakes it, so a rename's copy never lands after its delete. A permanent failure drops the job (its record is deleted) and marks the target degraded: the same request would be refused again, and every later job would wait behind it forever. "Stopping" during shutdown is neither: the job stays owed.

### 4.3 Read path

```
ask(member, f, others_remaining, probing):
  if not others_remaining: return f(member)            -- the last candidate is asked whatever its health
  if probing:
     case health.check(member): Held -> fail fast "held"
                                Up | Probe -> f(member), cancelled as soon as the member is found down elsewhere
  else:                                                -- long polls, capability queries
     if health.is_down(member): fail fast else f(member) with the same cancellation

walk(chain, stop_on_miss):
  last_err := none
  for m in chain:
     r := try ask(m, ...) except e: last_err := e; continue
     if r = some v: return Answer v
     if stop_on_miss: return Miss                       -- the first reachable member's miss is authoritative
  return last_err ? Unreachable last_err : Miss

read(f):
  a := walk(readable, stop_on_miss = true)             -- mains, then readable replicas
  if a = Answer v: return v
  b := walk(archives, stop_on_miss = false)            -- archives hold different content; ask each
  if b = Answer v: return v
  if a = Unreachable e: raise e                        -- "could not look" never becomes "not there"
  if b = Unreachable e: raise e
  return none
```

Consequences:

- Main reachable and missing means *not found*: a replica holds the same content (or less) and is not asked.
- Main unreachable means the replica answers.
- Archives are asked both when the source of truth misses and when it is unreachable.
- Everything unreachable raises the first unreachable error, never "absent".

`get` = `read(get_optional)`, with a clean `none` turned into a permanent "not found" in the drivers' own vocabulary. `list_prefix` returns the first reachable member's listing, never merged, and an empty list is an answer. `watch` is a non-probing read: a 30 s long poll must never be the request spent discovering whether a member is back.

**One probe per hold.** A held member is skipped without a request until its hold expires. Then exactly one caller gets `Probe` and asks it. Taking the probe pushes the hold out, so a probe that never reports back is retried at the next expiry rather than never. Concurrent reads in that instant are all passed over to the next member. A request already in flight to a member that another request finds down is cancelled with a transient "held" failure, so it stops climbing its retry ladder.

**Batches.** A batch read (many keys, or many folders' listings plus bodies) belongs to the first readable member alone and is sent to it directly, without taking a second slot from the caller's pool. If that member is passed over or refuses the batch, the batch answers empty. A transient failure while the member is still considered up is re-raised, since every key would be lost the same way. Every key the batch did not return a body for goes back through `read` one at a time, which keeps archive fallback and the unreachable-versus-absent distinction.

**Capabilities** are merged over the readable members that are not held. Archives have no say. If every candidate was passed over, the merge raises rather than returning an empty merge that callers would memoise as fact.

### 4.4 Write guard

```
guard(dst, what):
  if dst.role = main: allow                       -- that is how a main is refilled from a replica
  for m in mains where (never heard from) or (down and hold expired):
     probe(m): get_optional(cursor), bounded by PROBE_TIMEOUT including retries;
               a timeout is recorded as a failed probe (a cancelled request tells the cell nothing)
  if any main is down: fail TRANSIENT "refusing to <what>: the main <m> is not online"
  allow
```

A main heard from and up is taken at its word, so a run of guarded writes costs one look, not one each. A domain with no main passes.

Every operation that writes a **named non-main member directly** must call the guard first: repair copies, integrity rewrites, verify requests (they are objects written into the store), GC deletions from copies, re-sent delete requests, and share publication. The composite's own writes cannot violate it: targets only ever receive what a main already took, and a main write failure aborts before `fill`.

Why the guard exists: a copy written while the main is offline would hold state the source of truth never had. Reads prefer the main, so those writes would disappear when it returns, and nothing could check them against it. In the other direction, a copy that runs ahead is what a reader failing over would trust. The guard fails *transient*, so callers retry once the main is back rather than record a permanent refusal.

### 4.5 Repair and verification between members

**Mirror (repair by copy).** An explicit, stateless, additive whole-store operation:

```
mirror(source := named member or the first in read order, scope ∈ {All, ReferrersOnly, Subtree(p)}):
  refuse All/Subtree while a collection is open on the main (chunks are split across two names)
  L := listing of source for the scope, spooled to disk (chunks one batch of shards at a time;
       Subtree walks the tree and adds only the chunks its manifests name, and excludes history)
  for dst in other members (sequentially, config order):
     guard(dst, "copy to dst")
     V := listing of dst for the scope (disk-backed map key → size); Subtree uses HEAD per key
     for e in L, by a fixed pool of workers:
        if e ∉ V or size differs: copy source→dst (body in memory under a bounded copy pool)
```

It never deletes. It does not detect same-size wrong bytes: that is verification's job. Per-store caches are not copied. It is the only remedy for a degraded target, a new backfill's past content, and dropped or never-replayed records.

**Verification.** Each store checks "chunks are what their names say" itself: a local store re-reads every chunk after writing it, and a cloud store checks each new chunk on its object-created event. A mismatch or an unreadable chunk becomes a **corruption marker**. Whole-store verification queues one request per shard in each store. The composite asks every readable member when the mains are up, and only the mains otherwise (a request is a write). Backfills are reached only by a per-member verify command. A store's capability `verified` says whether anyone is checking. A composite claims it only if every member does.

**Integrity repair.**

```
for marker (store S, chunk c):                                 -- sequential
  guard(S, ...)
  if S's own body hashes to c: rewrite S's body over itself    -- S re-verifies, which clears the marker
  elif some readable member R ≠ S (optionally a named source) has a body hashing to c:
       write it to S only                                       -- directly, never through the composite
  else: report unrepairable
```

Repair never deletes a marker. Only the store's own re-verification clears one, so a marker can never be cleared by a party that did not check the bytes. The cloud checker deletes the marker *before* hashing: events are at-least-once and unordered, and a stale "clean" state on bad bytes is unrecoverable, while a spurious marker only costs a rewrite.

### 4.6 Resumption: the single-runner rule

A log must be run by at most one process at a time. Otherwise two workers would reorder a rename's copy and delete.

- **Resumer (daemon).** Builds every target *stopped* in resume mode. After forking its frontends, it starts them: each reads its log (records not already loaded, in record order) and runs them. It re-reads every log on a periodic housekeeping sweep and whenever notified, but only a log that no live process has claimed.
- **Forked frontends.** They inherit targets that are not running. `accept` only records the job and notifies the resumer, which rescans.
- **One-shot commands.** They claim the log with the advisory lock, run the jobs they record themselves, and on exit settle (wait for their queue and their in-flight forwards) up to a timeout. Records still owed stay on disk. The kernel drops the claim when the command exits, killed or not, and the resumer's next sweep takes them.
- **Rescan dedup.** The resumer never enqueues an id it already holds. A rescan runs under the same lock as recording, so a write arriving meanwhile queues behind what the rescan found.

### 4.7 Deletion and GC propagation

Ordinary deletes and bulk deletes are replicated like any write (a `Delete` job for every target that does not skip the key). A target takes a delete whether or not it holds the object.

Garbage collection (§A9) deletes unreferenced chunks from copies **before** the main, and **directly**:

```
per flush of doomed chunks (keys not present by name in the main's surviving space, re-checked after listing):
  for each deferred member M:
     guard(M)
     M.discard(keys) → Queued (a durable server-side delete request) | Unsupported → M.delete_many(keys)
  delete the doomed chunks' corruption markers on the main and on direct-deleting copies
  discard the shards on the main; advance the durable cursor
```

- Copies before main: a crash in between leaves keys that a resumed run deletes again (idempotent). The other order would leak them forever, since nothing walks a copy's shards.
- The recheck of each doomed key in the main's surviving space protects a chunk that was orphaned and then re-uploaded during the run: deleting it off a copy would take out a live chunk.
- Server-side delete requests are left in place when any per-key delete was refused, and can be re-sent by hand. Nothing retries them automatically.

### 4.8 Settling

A process about to exit calls the drain hook once. It waits, bounded by the settle timeout (shortened to the shutdown grace when stopping), for every queue to empty and every chunk forward to finish. A queue that has started failing ends the wait at once: its work is on disk and outlives the process.

---

## 5. Properties and why they hold

**S1 (referrer after referenced).** When a manifest is present on a target, every chunk it names is present on that target. Its job runs `ensure_chunk` for each name, sequentially, before the put. `ensure_chunk` returns only after a confirmed put or a positive memo entry. The memo is filled only by successful puts or by the target's own listing, and a listing that misses a key only costs a redundant put, which is harmless for immutable content. *Holds unless the memo is stale (R1) or the chunk is deleted from the target later by an actor other than the job worker (R1, R6).*

**S2 (no job lost at the durability point).** A job is on local disk before the write returns. Its record is deleted only on success, or on a permanent failure, which sets `degraded`. A crash between the main write and the record loses the fill, but then the write never returned success, and the caller's retry repeats it.

**S3 (per-key convergence).** Jobs are bodyless: a `Put(k)` run at time t writes the main's value of `k` at t. The last job for `k` therefore writes a value at least as new as the write that recorded it, or deletes, matching the main's state at the time it ran. After quiescence (no writes, all logs empty, no drops, one runner) every non-skipped key on the target equals the main's.

**S4 (order within a log).** One worker, head-of-line blocking on transient failures: effects apply in record order, so copy-then-delete (rename) and entry-then-cursor are preserved on the target.

**S5 (no false absence).** `read` returns `none` only if some member in the first chain answered `none` and was reachable (stop on miss), and every archive answered `none`. An unreachable member always surfaces as an error when nothing answered.

**S6 (copies never ahead).** Composite writes to targets happen only after all mains succeeded. Direct writes to non-mains pass the guard. A main that failed the probe blocks them. Residual window: the guard trusts a main heard from and up, so a main that goes down between the look and the write is not seen. The write then fails on its own ladder or, for a copy-only write, lands. That is harmless for repair (it copies what a main held) and for GC (it deletes what the main already doomed).

**S7 (one runner).** A resumer reads a log only under a lock that any process holding its records in memory also holds. Forked frontends never run. **But** a one-shot command and the resumer each run their *own* records concurrently against the same member (R2).

**Liveness.**

- **L1.** While the main and a target are reachable, every recorded job eventually completes or is dropped. The worker retries transient failures forever with capped backoff, and a stall watchdog logs a queue that has not moved in a minute.
- **L2.** Owed records left by a dead process are taken by the resumer within one housekeeping interval, if a resumer exists (R3, G7).
- **L3.** A held member is re-probed at most once per hold window, which doubles to 5 min, so a returning member is noticed within that bound.

**Worst-case interleavings, and why they are harmless:**

- A put and a delete of `k` recorded in one log, the put run after the source deleted `k`: the put reads none and does nothing, and the delete then runs.
- A copy whose source key is gone from the target (its put was dropped, or the target was added later): it falls back to rebuilding the destination from the main, chunk check included.
- A manifest overwritten while its job runs: the job may put the newer body, which is fine by S3. Its chunks are ensured from the body actually put, because the same fetch supplies both.
- A chunk read from the from-space during a collection: it is written to the target under its plain name, since a target has one space.

**Replica consistency at any instant.** For each key, the replica holds the main's value at some past instant, or an older value while a job for that key is owed. Across keys it is not a snapshot: a manifest may be newer than the cursor the replica publishes, never older than the entries that cursor reaches (S4). A reader of a replica that follows its cursor sees a tree where every entry it reaches has its manifest (possibly newer) and every manifest has its chunks (S1). A backfill offers the same per-key guarantee over content keys only, from the moment it was added.

**After quiescence** (no writes, logs drained, no drops since the last full mirror, single runner, no out-of-band deletes): replica ≡ main over non-skipped keys, and backfill ≡ main over content written since it was added. A completed `mirror` from the main makes a backfill ≡ main over content as well. Mirror is additive, so it never removes a key the main no longer has.

---

## 6. Failure, crash and resume

| Interruption point | Effect | Recovery |
|---|---|---|
| Main k fails after mains 1..k−1 took the write | Write fails; earlier mains hold it; no target owes it | Caller retries (idempotent). If it never does, R4. |
| Crash after mains, before a record | Write never returned; targets owe nothing | Caller's write-ahead replay repeats the write |
| Crash after the record, before the job ran | Record on disk | Resumer rescans at start or on its sweep |
| Crash mid-job (chunks partly put) | Chunks are immutable; the manifest is not yet put | Job re-run: memo misses cost a listing, puts are idempotent |
| Crash mid-copy | Target copy is an atomic put | Re-run, or fall back to rebuild |
| Stop during a job | Job neither done nor failed; record kept | Next runner |
| Chunk forward lost (crash, drop, refusal) | Nothing owed | The manifest job fetches it from the main |
| Target down for hours | Records accumulate on disk; head retries with backoff ≤ 5 min | Automatic when the link returns |
| Target refuses permanently | Job dropped, target degraded | Operator: mirror from the main |
| In-memory queue over its cap | New jobs not recorded; degraded | Mirror |
| Unparseable record | Dropped, counted, degraded | Mirror |
| Main down | Reads fail over; composite writes fail transient; guarded writes refused; jobs whose source read fails wait at the head | Automatic on return |
| GC crash between copies and main | Doomed keys still on the main, maybe gone from copies | Resumed run redoes both (idempotent) |
| Server-side delete request not consumed | Chunk stays on that copy; request stays | Status lists it; re-send by hand |

Every job is idempotent: bodyless put, copy onto an atomic put, deletes that treat absent as success. Re-running any prefix of a log is safe.

Abandonment: nothing is abandoned automatically except by drop (permanent failure, overflow, unreadable record). Every drop sets `degraded`, the only signal that a repair is needed.

---

## 7. Parameters

| Parameter | Value | Effect | Trade-off |
|---|---|---|---|
| MAX_FORWARDS | = chunk buffer budget (default = upload concurrency, 4). 32 when no budget is given | Chunk bodies kept alive by best-effort forwards | Higher prefills targets faster but holds more memory. Lower costs the manifest job a fetch per dropped chunk |
| forward admission | the target's uplink `try_admit` | Forward only when the link has room now | Forwards never delay user writes on a shared uplink |
| MEMO_CAP | 100 000 keys | `ensured` size before a full reset | Larger saves repeat listings, smaller saves memory. A reset costs one shard listing per shard met |
| MAX_QUEUED | 100 000 jobs in memory per log | Runaway backstop: past it, new jobs are dropped and the target is degraded | Too low degrades a merely slow target; too high only delays noticing |
| queue backoff | base 0.5 s, doubling, cap 300 s | Retry pace of a failing head | Faster retries waste requests against a dead target |
| settle timeout | 60 s (capped by shutdown grace) | How long a command waits for its own queue before exiting | Longer keeps commands open; shorter leaves more to the resumer |
| housekeeping interval | 60 s | Resumer rescan period for orphaned records | Latency before a dead command's work resumes |
| health trip | ≥ 2 consecutive transient failures over ≥ 1 s | When a member is declared down | Lower fails over faster but flaps more |
| hold | 30 s, doubling to 300 s per failed probe | How long a down member is skipped | Longer spends fewer probes but notices a return later |
| PROBE_TIMEOUT | 10 s (including retries) | Write-guard probe bound | Shorter refuses sooner on a slow-but-alive main |
| driver retry ladder | 8 attempts, 0.5 s·2ⁿ capped at 20 s, jittered | Per-request persistence | Cut short by health "held" |
| mirror pools | copy = chunk buffer budget; probe = max(8, 4×copy); in flight = 4×probe | Bodies in memory, round trips in flight, listing records in flight | Memory against throughput |

---

## 8. Known gaps

Cited from `findings.md`:

- **G2 — duplicate member names.** Two deferred members with the same name share one job log and one set of per-name tables. The resumer runs one member's records against the other's store, and stats and admission come from the wrong member. Correct version: reject duplicate names at configuration time (names are the identity of durable state).
- **G7 — Android never resumes.** The app builds its domain in non-resume mode, which claims the log and never rescans. Records left by a killed app process are never replayed on the device, and the member stays behind until a mirror (which the phone cannot run). Correct version: the app is its own resumer (resume mode, start after construction, periodic rescan), or it hands its logs to a resumer.

Observed while writing this specification, not in `findings.md`:

- **R1 — stale `ensured` memo after out-of-band deletes.** GC deletes chunks from copies directly (or through a server-side request), bypassing the job worker, so a long-lived process's memo still lists them. If the same content is uploaded again later, both the forward and the manifest job's `ensure_chunk` see the memo and skip, and the manifest reaches the target without its chunk, which breaks S1. Correct version: any deletion on a target must invalidate that target's memo in every process that runs it. The simplest sound rule is to drop the memo whenever a collection closes: the resumer can observe the run marker, or tag the memo with the collection epoch and discard it on change.
- **R2 — two runners per log across processes.** A one-shot command runs its own records while the resumer runs its own, against the same member. Order across the two is not preserved. Example: a command's `Delete(k)` runs after the daemon's later `Put(k)` has landed, so the target lacks a key the main holds until the next write to `k` or a mirror. The claim lock only prevents one process from running another's records. Correct version: a single runner per member (commands record and hand off, as forked frontends do), or per-key ordering across logs.
- **R3 — `degraded` is volatile.** A dropped job deletes its record, and the flag lives in memory. After a restart the member reports healthy although it owes a mirror. Correct version: persist a degraded marker beside the log, cleared only by a completed mirror to that member.
- **R4 — partial main fan-out.** With several mains, a failure on main k leaves mains 1..k−1 holding a write that nothing owes the others or the targets unless the caller retries. Correct version: record owed writes for later mains as for targets, or guarantee caller retry.
- **R5 — spurious drops under collection.** A `Put(manifest)` job that read a body naming a chunk the collection then discarded (the manifest was overwritten after marking) gets a permanent "not found" and is dropped, which degrades the target although a later job carries the newer manifest. The harm is a false degraded signal. Correct version: treat "chunk missing at source" as "the referrer changed". Re-read the referrer and retry, and drop only if it still names the missing chunk.
- **R6 — re-upload between GC's recheck and a copy's delete.** A chunk re-uploaded to the main after the doomed-key recheck but before the delete on a copy is removed from the copy while the main keeps it. The window is small. Correct version: recheck after the copies' deletes too, and re-forward survivors, or order the copy deletes behind a barrier on writers.
- The composite's capability merge with the main held answers from the replica alone (acknowledged), and health windows use the wall clock (G12).

Preemptive runtimes: `ensured`/`known_shards`, the forward counter's check-and-increment, and `try_admit`-then-take each need to become one atomic step.

---

## 9. Alternatives and why this design

- **Synchronous writes to every member.** Rejected: a slow or remote copy would slow every write ("Fill replicas behind the write, not in it", 9b0f6af2).
- **Jobs carrying bodies.** Rejected: the log would grow with data, repeated puts would not converge on the latest body, and deleted keys would be resurrected. Bodyless jobs read the main at run time.
- **One record per chunk.** Rejected: deduplication makes most operations chunk-free, so correctness rests on the manifest job's check and chunk forwards are pure prefetch.
- **Targets reading through the composite.** Rejected: a stale copy could feed a job whose result is never corrected (targets read mains only).
- **Separate replica and backfill mechanisms.** Collapsed into one with one bit (b92f69b2, fcf7b854), so promotion is a configuration edit.
- **Writing a replica while the main is down.** Rejected (the write guard): it creates state nobody can check and that disappears on the main's return.
- **HEAD per chunk on the target.** Replaced by shard listings folded into a memo: across tens of thousands of manifests, shards repeat, and a listing answers about 1000 keys per request (deferred_shards: 40 manifests × 4 chunks → 0 HEADs, 4 listings).
- **Several mains each arbitrating conditional writes.** Rejected: two clients could each win somewhere.
- **Merged listings.** Rejected: one member's view is consistent with itself, and a merge would mix different points in time.
- **A queue service for verify and delete requests.** Rejected: the bucket's own notification delivers request objects to the function that already checks every chunk. No second credential, one code path.
- **Automatic repair.** Not done: drops are rare and signalled, and mirror is additive, idempotent, and cheap to rerun.

---

## 10. Mapping to the current implementation

| Abstract | Concrete | Spec |
|---|---|---|
| Roles, read order, config validation | `role = Main\|Replica\|Backfill\|ReadOnly`, `order_backends`, `validate_roles` (`conf_parsing.ml`) | [05 §2.2](../05-ops-config.md), [06 §2.5](../06-backends.md) |
| Composite construction | `Domain.of_config` → `build_backends` → `Domain_store.make ~mains ~targets ~archives` (`lib/domain/config/domain/domain.ml`, `lib/backends/api/domain_store.ml`) | 05 §4.1, 06 §4.3 |
| Source = mains only | `make ~mains ~targets:[] ~archives:[]` inside `Domain_store.make` | 06 §4.3 |
| Write fan-out, `fill`, `skip` | `write`, `fill`, `D.skip` (`excluded = Stored_key.is_index_key`; journal prefix / cursor key when `reads_reach = false`) | 06 §4.3–4.4 |
| Deferred target, reads-reach bit | `Deferred.make ~reads_reach:(role=Replica)` (`lib/backends/api/deferred.ml`) | 06 §4.4 |
| Job log, bodyless jobs | `Durable_queue.ordered` with `Records` at `<data_dir>/deferred-pending/<domain>/<escape name>/`, JSON `{"op":"put"\|"copy"\|"delete"\|"delete_multi",…}` | 06 §2.6 |
| Claim lock | `lockf` on `<dir>.owner`, `claim`/`with_claim`/`release` (`lib/core/durable_queue.ml`) | 06 §4.4 |
| MAX_QUEUED, backoff, settle timeout | `max_queued = 100_000`, `Retry.backoff ~base:0.5 ~cap:300.`, `default_settle_timeout = 60.` | — |
| chunk forward, MAX_FORWARDS, admission | `forward_chunk`, `max_chunk_forwards` = `maxChunkBuffers` (default 32 in `Deferred`), `room_for` = link admission `try_admit` | 06 §4.4, §4.9 |
| `ensured`, `known_shards`, MEMO_CAP | same names, `max_ensured = 100_000`, `learn_shard` over `Chunk_layout.shard_prefix` | 06 §4.4 |
| from-space fallback | `chunk_from_prefix` = `tsync/<d>/chunks.from/` | 05 §4.9 |
| chunk_names | `chunk_keys` (manifest parse, `[]` otherwise) | 05 §4.1 |
| drop → degraded | `poison = Drop`, `Q.stats.degraded` | 06 §4.4 |
| read / walk / ask | `read`, `walk`, `ask_member ?probing ~others`, `Health_wait.until_held` | 06 §4.3 |
| health, hold, probe | `Health` (`trip_after 2`, `trip_span 1.`, `hold_initial 30.`, `hold_max 300.`, `probe_timeout 10.`), `check → Up\|Held\|Probe` | 06 §4.1 |
| batches | `get_many`/`list_many` on the first readable member, `passed_over`, per-key `read` fallback | 06 §4.3 |
| write guard | `Write_guard.ensure`/`look`/`probe` on the cursor key (`lib/backends/api/write_guard.ml`) | 06 §4.5 |
| mirror | `tsync mirror`, `lib/domain/ops/mirror.ml` (`resync ?source ?scope`) | 05 §4.6 |
| verification, markers | local `verifyWrites`, `lambda/verify.py`, `verify_all` → `tsync/verify-jobs/<d>/<shard>`, markers at `tsync/corrupted/<d>/<shard>/<key>` | 06 §4.6–4.7 |
| integrity repair | `Integrity.repair` / `verify` / `follow` (`lib/domain/ops/integrity.ml`), `tsync data-integrity` | 05 §4.10 |
| GC propagation | `Gc.flush_close` (`discard` → `tsync/gc-jobs/<d>/<run>/<shard>` or `delete_multi`), `orphans_in_shard` recheck (`lib/domain/ops/gc.ml`) | 05 §4.9, 06 §4.6 |
| resumer | daemon `resume = true`, `Domain.start_resumed` after fork (`launcher.ml`), `rescan_all` on the 60 s housekeeping sweep (`domain_engine.ml`) and IPC `rescan` from `set_on_recorded` | 06 §5.1, 05 §4.1 |
| settle / drain | `Queues.register_settle chunks_quiet`, `Domain_store` drain hook → `settle_all` | 06 §4.4 |
| Android host | `android_jni.ml` `load_domain` without `~resume` (G7) | findings G7 |
| Tests | `tests/backends/{fallback,held_failover,main_down,deferred,deferred_shards,deferred_governed,backfill,write_guard,gc_targets,gc_queued}`, `tests/unit/queue_claim` | 06 §8 |
