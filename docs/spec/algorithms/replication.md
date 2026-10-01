# Multi-store replication

One domain is backed by several stores, each with a role, and is presented to every layer above as a single store with the contract of [06-backends.md](../06-backends.md). This file owns the roles, the composite's read and write paths, the copies filled behind the write, the write guard, and repair between members.

Terms: a **member** is one configured backend of a domain. A **copy** is a replica or backfill member. The **source** is the composite of the mains alone. The **owner** is the process that owns the domain on this machine ([07 §2.2](../07-daemon-cli.md#22-the-domain-owner), principle P1 of the spec README).

---

## 1. Problem and goals

A domain is a set of objects: content-addressed **chunks** (the name is a hash of the body), and **referrers** that name chunks (file manifests) or other objects (journal entries name manifests, the cursor names the newest journal entry). The user wants more than one store to hold it: a source of truth, a full second copy that answers reads when the first is unreachable, a copy being filled for later promotion, an old archive that still answers for what it holds.

Goals:

- **G1 One store.** Callers see one store with the ordinary contract. They never learn how many members there are or which one answered.
- **G2 Roles as policy.** A member's role fixes what it promises to hold, when, and whether reads may reach it.
- **G3 Writes are not slowed by copies.** A write returns once the mains have it and every copy has durably recorded that it owes it. Copies catch up in the background, across crashes and restarts.
- **G4 Partial coverage, never partial files.** A copy may lag, but a referrer reaches it only after everything the referrer names is there.
- **G5 Honest reads.** A read fails over past an unreachable member, and never reports "not found" because a member could not be asked.
- **G6 Copies are never ahead of the truth.** No copy is written while a main is offline.
- **G7 Nothing is dropped, and divergence is visible.** A job that cannot run is kept and retried, the copy is reported degraded meanwhile, and whole-store divergence (corruption, a new empty member) is repaired by an explicit operation.
- **G8 Forwarding never competes with the user.** Best-effort chunk forwards use upload bandwidth only when the link has room.

Non-goals:

- Consensus between mains. The first main arbitrates claims. The others follow in sequence, with no rollback.
- Writes while a main is offline. Failover is for reads only. Disconnected writes are the write-ahead log's job, one layer up ([algorithms/wal-and-journal.md](wal-and-journal.md)).
- Merged listings. A listing is one member's view.
- Automatic whole-store repair. Findings are reported, and an operator runs the repair.
- Byte-level checking by the replication path. Stores check bodies against names themselves ([06 §2.3](../06-backends.md#23-capabilities)).

---

## 2. System model and assumptions

- **A1 Stores** implement the contract of [06 §3](../06-backends.md#3-the-store-contract): atomic put, honest absence, a real claim precondition, honest delete results, read-after-write and list-after-write on each key.
- **A2 Failures** carry the kinds of [algorithms/failure-model.md](failure-model.md). Each member has a [breaker cell (01 §8)](../01-core.md#8-health-breaker), fed as [failure-model §6](failure-model.md#6-link-health-evidence) says.
- **A3 Content addressing.** Chunks are immutable: two bodies under one chunk name are the same bytes unless a store damaged them. Referrers are mutable, last writer wins.
- **A4 Durable logs** as in [algorithms/durable-queue.md](durable-queue.md): records survive a crash, are run in id order, and a record that fails with a non-retryable kind is parked and retried, never dropped.
- **A5 One owner per domain per machine** (P1). Other machines write the same mains, each through its own owner, and keep their own job logs for the copies they configure.
- **A6 Clocks.** Only durations are used, on the monotonic clock. No ordering decision depends on a clock.
- **A7 Collection** runs over a main and deletes unreferenced chunks from copies through the copies' job logs ([gc §5.7](gc.md#57-deletion-on-copies)); this file specifies how those deletions are recorded and run (§4.8).

---

## 3. State

### 3.1 Roles

| Role | Promises to hold | When | Reads reach it | Written by |
|---|---|---|---|---|
| **main** | everything | synchronously: a write returns only after every main has it | first, in configuration order; the first main is the **read primary** and the arbiter of claims | the composite |
| **replica** | everything, including the journal and the cursor | eventually, behind the write, through its job log | only when no main answered | its job-log worker |
| **backfill** | content only: every key except journal entries and the cursor | eventually, from the moment it was added; earlier content arrives only through repair | never, and share links never point into it | its job-log worker |
| **read-only (archive)** | different content (an older or foreign store) | never written | after the source of truth misses, or is unreachable | nobody |

A replica and a backfill are one mechanism that differs by one bit, *reads reach it*. Promoting a fully repaired backfill is a one-word configuration change.

Every copy skips per-store caches (folder index objects, which describe the store that wrote them). A backfill also skips journal entries and the cursor.

### 3.2 Configuration rules

- Every member has a role.
- Member names MUST be unique within a domain, MUST be non-empty, and MUST NOT be `.` or `..` (uniqueness ignoring case is enforced by [05 §2.1](../05-ops-config.md#21-schema-and-validation)). A name identifies durable local state (the job log), so a duplicate would make two members share one log.
- A replica or backfill without a main MUST be refused ("nothing to fill it from").
- A domain with no main MUST have at least one archive, and is then read-only.
- Read order is main < replica < archive < backfill, stable on configuration order within a role.
- A copy is complete only with respect to writes made by owners that configure it. Every machine that writes a domain SHOULD configure the same copies. A write made by an owner that does not configure a copy reaches it only through repair.

### 3.3 Durable local state (per domain and copy)

**Job log.** One durable log per copy, at `<data dir>/deferred-pending/<domain>/<escaped member name>/`. Record ids, creation, parking and adoption are those of [durable-queue §4](durable-queue.md#4-the-durable-queue). The escape keeps `[A-Za-z0-9._-]` and writes every other byte as `%XX`. Each record is a JSON object, and none carries a body:

```json
{"op":"put","key":"tsync/d/…"}
{"op":"copy","src":"tsync/d/…","dst":"tsync/d/…"}
{"op":"delete","key":"tsync/d/…"}
{"op":"delete_multi","keys":["tsync/d/…","tsync/d/…"]}
{"op":"delete_multi","keys":["tsync/d/chunks/…"],"run":"<run name>","shard":"<sss>","generation":<n>}
```

- The last shape is a **collection delete**, appended by a collecting owner ([gc §5.5](gc.md#55-the-collector-phase-by-phase)); `generation` is the odd collection generation of that run ([02 §2.12](../02-remote-model.md#212-collection-run-record-and-generation-json)). `run`, `shard` and `generation` are present together or not at all.
- Readers MUST accept exactly these shapes. A record that does not decode, or names an invalid key, is handled as [durable-queue](durable-queue.md#46-outcomes) handles an undecodable record.

Records are named with the id grammar of [durable-queue §4.1](durable-queue.md#41-structure) and run in id order; files in a log directory that do not match the record grammar are ignored. The decoder reads fields by name and ignores any it does not know. A record without `run`, `shard` and `generation` is an ordinary job, and a record without a failure note has never failed.

**Per-log lock files.** Readers SHOULD accept a file `<log dir>.owner` beside a log directory (meaning a per-log advisory lock, which is not part of the log): while one exists, the owner SHOULD hold its lock while it runs that log, and MAY delete it when no process holds it. Writers MUST NOT create one; the domain ownership lock is the claim.

**Pending discards.** For a copy with a bucket function, the discard requests this owner wrote and has not yet seen consumed, each with its run, shard and keys: a durable log beside the job log, `<log dir>.discards/`, one record `{"run": "<run name>", "shard": "<sss>", "generation": <n>, "keys": [...]}` per request (§4.8).

**Degraded.** A copy is **degraded** while any record of its log is parked ([durable-queue §4.7](durable-queue.md#47-parking-and-retry-of-parked-records)). The parked records are the durable evidence: a restart reports the same state. Status names each parked record with its last failure.

### 3.4 Volatile state (the owner, per copy)

- `ensured`: a **presence memo** ([gc §5.6](gc.md#56-the-generation-and-presence-memos)) of chunk keys known to be on the copy, learnt from successful chunk writes and from the copy's own shard listings, each tagged with the collection generation G read when its presence was confirmed.
- `known_shards`: shards whose listing has been folded into `ensured`, with the same tag.

---

## 4. The algorithm

### 4.1 Construction

```
build(domain):
  mains    := members with role main, configuration order
  archives := members with role read-only, configuration order
  source   := composite(mains, copies = [], archives = [])        -- mains only
  copies   := [copy_target(m, source, reads_reach = (m.role = replica))
               for m in replicas ++ backfills]
  readable := mains ++ [c for c in copies if c.reads_reach]
  return composite(mains, copies, archives, readable)
```

A copy catches up by reading **the source**, never the composite. A job is consumed once it succeeds, so a body read from a copy that is itself behind would land and never be corrected.

### 4.2 Write path

```
put(k, b):
  if mains = []: fail REFUSED(read_only)
  mains[0].put(k, b)                                  -- failure: raise; no copy is told
  fill(Put(k))                                        -- the read primary holds it: copies owe it
  for m in mains[1..]: m.put(k, b)                    -- first failure: raise it (after the fill)

put_if_absent(k, b):
  r := mains[0].put_if_absent(k, b)                   -- the first main alone arbitrates
  held := (r = Won) ? b : r.holder
  fill(Put(k))
  for m in mains[1..]: m.put(k, held)                 -- followers copy the arbitrated result
  return r

delete(k):        removed := mains[0].delete(k); fill(Delete(k)); for m in mains[1..]: m.delete(k); return removed
delete_multi(ks): mains[0].delete_multi(ks); fill(DeleteMany(ks)); for m in mains[1..]: m.delete_multi(ks)
copy(s, d):       mains[0].copy(s, d); fill(Copy(s, d)); for m in mains[1..]: m.copy(s, d)

fill(job): for c in copies (configuration order):
             keys := [k in job's keys | not c.skip(k)]
             if keys ≠ []: c.accept(job restricted to keys)
```

- The first main is the authority. Its answer is the operation's answer, and its failure aborts before any other member is written or told.
- Once the first main took a write, the copies are told, even if a later main then fails. The copies read the source, whose read primary holds the write, so they converge on what readers see.
- A failure on a later main is raised after the fill. The caller treats the whole write as still owed and repeats it: every writer above the composite holds its work durably until success ([durable-queue](durable-queue.md)), and every write is idempotent.
- The followers' plain `put` of the arbitrated body is not a fallback from a claim: the arbitration already happened, on the first main.
- A write returns once every main has it and every copy has durably recorded the job, or has decided on a chunk forward.

**Accepting at a copy:**

```
accept(job) at copy C:
  if job = Put(k) and k is a chunk key: forward_chunk(C, k); return      -- not recorded
  if this process is C's owner: post job to C's log                        -- the durability point
  else: submit job to C's log and poke the owner                          -- durable-queue §4.2

forward_chunk(C, k):                         -- owner only; best effort, never blocks, never queues
  if C.relies(k): return                                -- §4.4
  if the implementation's forward bound is reached: return
  in the background:
     g := read G                                        -- before the put
     try C.store.put(k, body, mode = best_effort)       -- refused admission: CANCELLED, nothing sent
         C.note(k, g)                                   -- §4.4: recorded only if g is even
     except any: log (CANCELLED at debug, other kinds as warnings)
```

- A process that is not the owner but writes the mains (the http-proxy store server, [07 §2.2](../07-daemon-cli.md#22-the-domain-owner)) records copy jobs by **submission** and pokes the owner. Copy jobs are order-insensitive (§4.3), which is what submission requires. A non-owner never forwards chunks: the manifest's job fetches them.
- Nothing depends on a forward: the manifest's job fetches any chunk that did not arrive.

### 4.3 Running jobs: every job converges a key on the source

The owner runs each copy's log with one ordered worker ([durable-queue §4.5](durable-queue.md#45-ordered-and-keyed-queues)). Every ordinary job brings some keys of the copy to the source's state **at the time the job runs**:

```
run(Put(k))          = sync(k)
run(Delete(k))       = sync(k)
run(Copy(s, d))      = sync(d)
run(DeleteMany(ks))  = for k in ks: sync(k)

sync(k) at copy C:
  restarts := 0
  loop:
    b := source.get_opt(k)                                 -- could not look: the failure is the job's
    if b = none:
        C.ensured -= k; C.store.delete(k); return
    C.g := read G                                          -- after the source read (§4.4)
    for c in chunk_names(b), sequentially:
        case ensure_chunk(C, c) of
          Present -> continue
          Missing_at_source ->
             if restarts < JOB_RESTARTS and source.get_opt(k) ≠ b:
                 restarts += 1; continue loop                -- the referrer changed: redo with its new body
             fail CORRUPT("source names a chunk no main holds: " k, c)
    C.store.put(k, b); return                                -- only after every named chunk is confirmed

ensure_chunk(C, c):
  if C.relies(c): return Present                             -- §4.4
  if C.g is even and shard(c) not known under tag C.g:
     list C.store's shard of c; note every key and the shard under tag C.g
     if C.relies(c): return Present
  elif C.g is odd and C.store.head_opt(plain chunk key of c) ≠ none:
     return Present                                          -- confirmed afresh, nothing recorded
  body := source.get_opt(plain chunk key of c)
          else source.get_opt(collection-space chunk key of c)     -- gc §5.8
  if body = none: return Missing_at_source
  C.store.put(plain chunk key of c, body); C.note(c, C.g)    -- a copy has one chunk space
  return Present
```

- `chunk_names(b)` is the list of chunks `b` names if it parses as a manifest, and empty otherwise (markers, anchors, journal entries, the cursor, shares, versions of anything but manifests).
- A `DeleteMany` job MAY establish which of its keys the source still holds with one listing per distinct parent prefix instead of one read per key.
- Journal entries and the cursor need no dependency check. The writer puts a manifest before the entry that names it, and the entry before the cursor, and one worker runs one owner's records in order. A cursor may name an entry whose job has not run yet: the cursor is a hint, and a reader lists the journal ([algorithms/wal-and-journal.md](wal-and-journal.md)).
- Because every job reads the source when it runs, order between logs, and a parked job run after later ones, converge on the source's state. That is why jobs carry no bodies, and why a copy job is not a copy on the target: a target-side copy would carry forward whatever the target's `src` happened to hold.

**Collection deletes** (`delete_multi` with `run` and `shard`) are not converged on the source: they run as §4.8 specifies.

**Queue discipline.** Retryable kinds block the head and are retried with backoff; non-retryable kinds (REFUSED, INVALID, CORRUPT, UNEXPLAINED, …) **park** the record and it is retried at ownership start, periodically and on request ([durable-queue §4.6–4.7](durable-queue.md#46-outcomes)). Parking lets later jobs run past a parked one, which is safe because every job converges on the source when it runs. While any record is parked the copy is degraded (§3.3).

### 4.4 The chunk memo

`ensured` is a presence memo, governed by the collection generation G of the collected main ([gc §5.6](gc.md#56-the-generation-and-presence-memos), format [02 §2.12](../02-remote-model.md#212-collection-run-record-and-generation-json)):

- **Tags.** Every entry is tagged with the value of G read when the chunk's presence on the copy was confirmed (a successful put, or the copy's own shard listing).
- **Reading G.** A job reads G **after** the source read that makes its chunks relevant, once per job (or once per batch of jobs whose source reads all precede it).
- **Reliance.** `C.relies(c)` holds only if G, as last read, is even and equals `c`'s tag. When G differs from the tags held, every entry and every known shard is invalidated.
- **Odd G.** While G is odd, presence on the copy is confirmed afresh every time (a metadata read or a listing of the copy) and `C.note` records nothing. A G that cannot be read counts as odd. A run record in its closing phase that carries no generation means odd while it is present ([02 §2.12](../02-remote-model.md#212-collection-run-record-and-generation-json)).
- **Own deletions.** Keys a copy deletion names are removed from that copy's `ensured` before the deletion is issued (§4.8).
- **Gate refusals.** A writer whose publication a main's gate refuses with "missing chunks" ([gc §5.4](gc.md#54-the-collection-interlock)) drops those keys from every presence memo it holds for the domain, for every member.
- An implementation MAY invalidate the memo at any other time.

### 4.5 The single runner

The owner is the only process that runs, completes or parks a domain's job records (P1, [durable-queue §4.2](durable-queue.md#42-ownership)). Consequently:

- At start, the owner loads every copy's log in id order and runs it, whoever recorded the records.
- A process that is not the owner adds records only by submission (§4.2).
- A one-shot command that took ownership because no owner was running runs every log, its own records and those left by earlier owners alike.
- **Settling** before an owner exits is [durable-queue §4.8](durable-queue.md#48-settle-stop-and-pause): bounded, raced rather than cancelled, and records still owed stay on disk for the next owner.

### 4.6 Read path

```
ask(m, f, last_candidate, probing):
  if last_candidate: return f(m)                     -- the last candidate is asked whatever its health
  if probing:
     case breaker(m).check of held -> fail UNREACHABLE at once
                              up | probe -> until-held(m, f(m))      -- 01 §7
  else:                                              -- watches and capability queries
     if breaker(m).is-down: fail UNREACHABLE at once else until-held(m, f(m))

walk(chain, stop_on_miss):
  first_err := none
  for m in chain:
     r := try ask(m, ...) except e: first_err := first_err or e; continue
     if r = some v: return Answer v
     if stop_on_miss: return Miss                     -- the first reachable member's miss is authoritative
  return first_err ? Unreachable first_err : Miss

read(f):
  a := walk(readable, stop_on_miss = true)            -- mains, then readable replicas
  if a = Answer v: return v
  b := walk(archives, stop_on_miss = false)           -- archives hold different content: ask each
  if b = Answer v: return v
  if a = Unreachable e: raise e                       -- "could not look" never becomes "not there"
  if b = Unreachable e: raise e
  return none
```

- A main that answers "absent" means *not found*. A replica holds the same content or less, and is not asked.
- A main that is unreachable means the replica answers.
- Archives are asked both when the source of truth misses and when it is unreachable.
- When everything is unreachable, the first unreachable error is raised, never "absent" ([failure-model §5.2](failure-model.md#52-absent-versus-could-not-look)).
- `get` is `read(get_opt)`, with a clean `none` turned into ABSENT.
- `list_prefix` returns the first reachable member's listing, never merged. An empty list is an answer.
- `watch` is a non-probing read: a long poll must never be the request that finds out whether a member is back.
- The single probe per lapsed hold is the breaker's ([01 §8](../01-core.md#8-health-breaker)); concurrent reads that do not get it pass to the next member.

**Batches.** A batch read (many keys, or many folders' listings with bodies) is declared only if the first readable member declares it, and it goes to that member alone.

- If the member is passed over, or refuses the batch, the batch answers empty.
- A transient failure while the member is still considered up is raised: every key would be lost the same way.
- Every key the batch did not answer with a body goes back through `read`, one at a time, which keeps archive fallback and the unreachable-versus-absent distinction.

### 4.7 Capabilities, verification requests and discards at the composite

**`capabilities(prefix)`** asks every non-archive member that is not held, without probing:

- `share_url` and `chunk_size` come from the first main that answered. A replica never decides the chunk size of new files.
- `max_concurrency` is the minimum over the readable members that answered.
- `verified` is true only if every main, replica and backfill answered `verified = true`.
- If no main answered and the domain has a main, the call fails UNREACHABLE. An empty merge would be memoised as fact.
- Archives have no say.

**`verify_all`** asks every readable member when every main is up, and only the mains otherwise: a verification request is an object written into the store, and the write guard applies. The results are summed. `Unsupported` is returned only if every member asked answered it. Backfills are reached only by the per-member verification command ([05-ops-config.md](../05-ops-config.md)).

The composite declares no **`bucket_functions`**: collection deletes on copies are jobs (§4.8), and each copy's own declaration, with its owner's confirmation, decides how they are executed.

### 4.8 Deletions on copies outside the worker

A collection's deletions on copies are owed durably and executed by the owner ([gc §5.7](gc.md#57-deletion-on-copies)):

```
doom step for shard s of run r, generation g odd (collecting owner):     -- gc §5.5
  for each copy C told by this run:
     append CollectionDelete(doomed, r, s, g) to C's job log, durably
  -- only then does the main unlink its outgoing entries

run(CollectionDelete(ks, r, s, g)) at copy C:
  guard(C, "delete collected chunks")                       -- §4.9
  ks := ks − [k | the collected main holds k]               -- MAY: a re-check just before
  C.ensured -= ks                                            -- before the deletion is issued
  wait for C's in-flight forwards; skip new ones meanwhile   -- none lands after the deletion
  if C has a confirmed bucket function (06 §3.8):              -- MUST be used when it has one
      write the discard request for (r, s) naming ks         -- supersedes an older one of that name
      add {r, s, g, ks} to C's pending discards, durably     -- only once the request exists
  else:
      delete ks and their corruption markers                  -- absent keys count as deleted
      restore(C, s, ks)                                      -- settled

every DISCARD_POLL, for each pending discard P of copy C:
  if the request object for (P.run, P.shard) is gone:
      restore(C, P.shard, P.keys); remove P                  -- settled

restore(C, s, keys):                                         -- mandatory; the write guard applies
  list the collected main's shard s                    -- both spaces, gc §5.8
  for k in keys that the main holds: sync(k)                 -- §4.3: the chunk is put back on C

when no collection-delete record and no pending discard of generation g remains for any copy:
  with the collected main's run lock (retry while held):
     write G := g + 1 to the collected main                  -- even: settled
```

- **Recorded before the main discards.** Deletions for direct and queued copies alike are durable before the main unlinks its outgoing chunks, so a crash repeats them instead of leaking them.
- **Restore after (mandatory).** Once a deletion has taken effect (a direct delete returned, or the request object is gone), every deleted key the main still holds is put back. Only then is the deletion settled. A chunk referenced again during or after the collection is thereby restored on the copy, whenever the deletion landed.
- **Settling G.** G turns even only when every deletion of its generation is settled, so a memo is never relied on while a deletion could still invalidate it ([gc §5.6](gc.md#56-the-generation-and-presence-memos)).
- **At start** the owner resumes every unsettled collection-delete record and pending discard, settles them, and then makes G even.
- **A request never consumed** leaves G odd: copy memos go unused for the domain, which costs listings and puts, never safety. Re-delivery ([gc §5.7](gc.md#57-deletion-on-copies)) rewrites it with only the keys still absent from the main.
- A collection-delete record completes only after its direct deletion and restore, or once its discard is recorded pending; a pending discard is removed only after its restore.
- **Written before pending.** A pending discard is recorded only once its request is on the copy, so a poll that finds the request gone knows it was consumed, never not yet written. A crash in between leaves the collection-delete record owed, and its rerun writes the request again.
- Failures follow the queue discipline of §4.3.

### 4.9 Write guard

```
guard(dst, what):
  if dst.role = main: allow                          -- that is how a main is refilled from a replica
  for m in mains where (never heard from) or (down and hold lapsed):
     probe(m): m.get_opt(cursor key), bounded by PROBE_TIMEOUT including retries;
               a timeout is recorded as a lost probe
  if any main is down: fail TRANSIENT/LINK "refusing to <what>: the main <m> is not online"
  allow
```

- A main heard from and up is taken at its word, so a run of guarded writes costs one look, not one each. A domain with no main passes.
- Every operation that writes a named non-main member directly MUST call the guard first: mirror copies, integrity rewrites, verification requests, collection delete jobs and re-delivered requests, and share publication. Ordinary copy jobs are guarded too: the worker does not run while a main is down.
- The composite's own writes cannot violate the guard: copies receive only what the first main already took.
- The guard fails TRANSIENT so that callers retry once the main is back, rather than record a permanent refusal.

Why it exists: a copy written while the main is offline would hold state the source of truth never had. Reads prefer the main, so those writes would vanish when it returns, and nothing could check them against it. In the other direction, a copy that runs ahead is what a failing-over reader would trust.

Residual window: a main that goes down between the look and the write is not seen. That is harmless for repair (it copies what a main held) and for collection (it deletes what the main already doomed and re-checked).

### 4.10 Repair: mirror

Mirror is an explicit, stateless, additive whole-store copy from a source member to the others. It is the remedy for a new backfill's past content, for writes made by owners that do not configure a copy, and for parked jobs whose cause a repair of the copy clears.

```
mirror(source := a named member, or the first in read order; scope ∈ {All, ReferrersOnly, Subtree(p)}):
  refuse All and Subtree while a collection run is open on the main       -- chunks are split across two spaces
  for dst in the other members, sequentially, in configuration order:
     guard(dst, "copy to " dst)
     phase 1  chunks:   for the scope's chunks (All: every shard; Subtree: the chunks the in-scope
                        manifests name), copy each chunk the dst listing lacks or holds at a different size
     phase 2  content referrers: manifests, folder markers, anchors, trash markers, versions, shares.
                        Skip a manifest any of whose chunks phase 1 failed to place.
                        For immutable keys, copy when missing or of a different size;
                        for mutable keys, copy when missing or when the bodies differ
     phase 3  journal entries (not into a backfill)
     phase 4  the cursor (not into a backfill), last
  then retry every parked record of dst's log
```

- The phases give the dependency order of G4: a chunk before any manifest naming it, a manifest before the entry naming it, the cursor last. A mirror interrupted at any point leaves no referrer without its referents.
- Mirror never deletes. It does not detect same-size wrong chunk bytes: that is verification's job. Per-store caches are not copied.
- Mirror writes onto a main pass the main's reference gate ([gc §5.4](gc.md#54-the-collection-interlock)).

### 4.11 Verification and integrity repair

**Verification.** Each store checks "chunks are what their names say" itself ([06 §2.3](../06-backends.md#23-capabilities)). Whole-store verification queues one request per shard in each store. A composite claims `verified` only if every member does (§4.7).

**Integrity repair:**

```
for each corruption marker (store S, chunk c), sequentially:
  guard(S, "repair " c)
  if S's own body hashes to c: rewrite S's body over itself    -- S re-checks, which clears the marker
  elif some readable member R ≠ S (or a named source) has a body hashing to c:
       write it to S only                                       -- directly, never through the composite
  else: report c as unrepairable
```

- Repair never deletes a marker. Only the store's own re-check clears one, so a marker is never cleared by a party that did not check the bytes.
- A reader that cannot read a marker or a candidate body reports it as "not checked", never as "no good copy" ([failure-model](failure-model.md)).

---

## 5. Properties and why they hold

**S1 (referrer after referenced).** When a manifest is present on a copy, every chunk it names is present there. Its job ensures each named chunk before the put, and `ensure_chunk` returns only after a confirmed put, a fresh confirmation, or a memo entry whose tag equals an even G read after the manifest was read from the source. A chunk doomed in generation *g* can reappear in a manifest only after G became *g*, so such a job never relies on an entry confirmed before the doom ([gc §5.6](gc.md#56-the-generation-and-presence-memos)). A fresh confirmation made while G is odd can be overtaken by a deletion; the mandatory restore of §4.8 puts back every deleted chunk the main holds before G turns even.

**S2 (no job lost).** A job is recorded durably before the write returns. Its record is removed only on success; a non-retryable failure parks it.

**S3 (per-key convergence).** Every job sets its keys on the copy to the source's state at the time it runs. The last job for a key runs after the last main write of that key by this owner, so after quiescence (no writes, logs empty, nothing parked) every non-skipped key the owner wrote equals the source's value, whatever the order between logs, across owners and machines.

**S4 (order within a log).** One worker, head-of-line blocking for retryable failures: effects apply in id order, so an entry never reaches a copy before the manifest it named. Parking may reorder, which S3 makes harmless.

**S5 (no false absence).** `read` returns `none` only if a member in the first chain was reachable and answered `none`, and every archive answered `none`.

**S6 (copies never ahead).** Composite writes reach copies only after the first main took them. Direct writes and job runs pass the guard.

**S7 (one runner).** Only the owner runs a log (P1), and ownership is exclusive on a machine.

**S8 (visible degradation).** A copy is reported degraded exactly while a record of its log is parked, and parked records survive restarts.

**Liveness.**

- **L1.** While the source and a copy are reachable, every recorded job eventually completes or is parked; parked records are retried periodically, so one whose cause cleared completes.
- **L2.** Records left by an owner that died, and records submitted by non-owners, are run by the next owner.
- **L3.** A held member is re-probed once per hold window ([01 §8](../01-core.md#8-health-breaker)), so a returning member is noticed within that bound.

**Replica consistency at any instant.** For each key, the replica holds the source's value at some past instant, or an older value while a job for that key is owed. Across keys it is not a snapshot. A reader that follows the replica's journal sees entries whose manifests are present (possibly newer) and manifests whose chunks are present. A backfill offers the same per-key guarantee over content keys, from the moment it was added.

---

## 6. Failure, crash and resume

| Interruption point | Effect | Recovery |
|---|---|---|
| First main fails | No other member written, no copy owes it | The caller repeats the write |
| A later main fails | First main and copies' logs have it; that main does not | The caller repeats the write (idempotent); a mirror otherwise |
| Crash after the first main, before the job records | The write never returned | The caller's durable work repeats it |
| Crash after a record, before its job ran | Record on disk | Next owner runs it at start |
| Crash mid-job (chunks partly put) | Chunks are immutable; the referrer is not yet put | The job re-runs; memo misses cost a listing |
| Stop during a job | Neither done nor failed; the record stays | Next owner |
| Chunk forward lost or refused admission | Nothing owed | The manifest's job fetches the chunk |
| Copy down for hours | Records accumulate on disk; the head retries with backoff | Automatic when the link returns |
| Copy refuses a job, or a record does not decode | Record parked; copy degraded | Automatic retry once the cause clears; operator repair otherwise |
| Source names a chunk no main holds | Job parked as CORRUPT, naming the key | Integrity repair on the main; the parked retry then completes |
| Main down | Reads fail over; composite writes fail; guarded writes and job runs wait | Automatic on return |
| Collection delete re-check finds a key live | Key dropped from the delete | None needed |
| A deletion removed a chunk the main still holds | The copy lacks it until the restore | Restore after the deletion (§4.8) |
| Discard request not consumed | Chunks stay on that copy; request outstanding | Status lists it; re-delivery ([gc §5.7](gc.md#57-deletion-on-copies)) |

Every job is idempotent: ordinary jobs converge keys on the source, collection deletes re-check before deleting, and deletes treat absence as success.

---

## 7. Parameters

| Parameter | Recommended | Effect / bound |
|---|---|---|
| JOB_RESTARTS | 3 | Re-reads of a referrer that changed while its chunks were ensured |
| DISCARD_POLL | 60 s | Period of the owner's checks that a pending discard request was consumed |
| Queue backoff, rearm, settle | [durable-queue §9](durable-queue.md#9-parameters) | Retry pace, parked-record retry period, exit wait |
| PROBE_TIMEOUT | [01 §15](../01-core.md#15-parameters) | Write-guard probe bound, retries included |

---

## 8. Alternatives and rationale

- **Synchronous writes to every member.** Rejected: a slow or remote copy would slow every write.
- **Jobs carrying bodies.** Rejected: the log would grow with data, repeated puts would not converge on the latest body, and deleted keys would be resurrected.
- **Jobs replaying the operation on the target** (a copy on the target, a delete regardless of the source). Rejected: they converge only if every log runs in one global order, which two machines, submissions, parking, or a restarted owner cannot give. Reading the source when the job runs converges in any order.
- **Dropping a job that fails permanently.** Rejected: it lost work silently until a whole-store mirror; parking keeps the work and the evidence.
- **Deleting on copies directly from the collector.** Rejected: it bypassed the worker's memo; as jobs, deletes are re-checked and ordered with the copy's other work.
- **One record per chunk.** Rejected: deduplication makes most operations chunk-free, so correctness rests on the manifest job's check, and chunk forwards are pure prefetch.
- **Targets reading through the composite.** Rejected: a stale copy could feed a job whose result is never corrected.
- **Separate replica and backfill mechanisms.** Collapsed into one bit, so promotion is a configuration edit.
- **Writing a copy while the main is down.** Rejected: see the write guard.
- **A metadata read per chunk on the copy.** Replaced by shard listings folded into a memo: across many manifests shards repeat, and one listing answers about a thousand keys.
- **Several mains each arbitrating claims.** Rejected: two clients could each win somewhere.
- **Merged listings.** Rejected: one member's view is consistent with itself, and a merge would mix different points in time.

---

## 9. Conformance

An implementation MUST exhibit:

- **Read semantics.** With main and replica: a reachable main that misses answers "absent" without asking the replica; an unreachable main is passed over and the replica answers; archives answer on a source miss and when the source is unreachable; everything unreachable raises, never "absent", and with everything down the main's error is the one reported; a read-only domain reads and lists, and its writes fail REFUSED(read_only); an empty listing is an answer; an unreachable main's listing falls to an archive.
- **Held failover.** A replica is not asked while the main is up. A main found down is passed over without waiting out its retry ladder, and a request already in flight to it is cancelled. A batch whose member is passed over is answered key by key from the next member. A long poll is never the probe. A single-member domain always asks its member, held or not. At hold expiry exactly one of several concurrent reads probes.
- **Main down.** Every write verb fails; the replica is unchanged and owed nothing; verification requests to the replica are refused. A write taken earlier stays owed and lands when the main returns.
- **Multi-main.** A failure on the first main writes no other member and records no job. A failure on a later main leaves the copies owing the write, and the write raises.
- **Durability.** A job is on disk before the write returns, and survives a failure of the copy. After a restart the copy's jobs are intact and run in id order, with writes made meanwhile recorded behind them. A stop mid-job leaves it owed. A permanent failure parks the job and reports the copy degraded, across restarts; the parked job completes on retry once the cause clears. A record submitted by a non-owner is run by the owner after its poke.
- **Convergence.** A delete job whose key the source holds again restores the key on the copy. A put job whose key the source no longer holds deletes it on the copy. A rename is converged as a put of the destination and a delete of the source. Two logs replayed in either order converge on the source.
- **Referrer after referenced.** A manifest reaches a copy only after every chunk it names; a chunk missing at the source because its referrer changed restarts the job with the new body; a chunk no main holds parks the job as CORRUPT with the key named.
- **Memo.** 40 manifests × 4 chunks over 4 shards cost no per-chunk metadata reads, 4 shard listings and 160 chunk puts, and the same content under new names costs nothing more. While a run record is present the memo is not relied on. After a collection deletes a chunk from the copy and the chunk is referenced again, the manifest's job puts the chunk before the manifest.
- **Collection deletes.** Owed deletions carry their generation and are durable before the main unlinks its outgoing chunks; a crash in between repeats them. A deletion deletes chunks and their markers on a copy without a function, or writes one discard request per run and shard on a copy with one, kept pending until consumed; removes its keys from the memo first; does not run while a main is down. After a deletion takes effect, every deleted chunk the main holds is restored on the copy, and only when every deletion of a generation is settled does G turn even. At start, unsettled deletions are resumed and settled before G is made even. A never-consumed request leaves G odd, and the memo unused.
- **Generation.** While G is odd, or unreadable, or a run record in closing has no generation, no memo entry is relied on or recorded. After G changes, no entry tagged with the old value is relied on. A writer refused "missing chunks" by the gate no longer believes those chunks present anywhere.
- **Forwards.** Forwards are asked once per chunk with its exact size, and only admitted forwards are sent; a refused forward is fetched by the manifest's job.
- **Backfill.** Chunks before manifests; a deduplicated hole is filled; symlink manifests name no chunks; the journal and cursor are not carried; reads never reach it.
- **Write guard.** Probes once then trusts; a down main refuses non-main writes as TRANSIENT naming the main; an expired hold is re-probed; a main that never answers is bounded by the probe timeout; a domain with no main is allowed.
- **Mirror.** On any interruption, the destination holds no manifest without its chunks and no entry without its manifest; a mutable key of equal size but different body is recopied; mirror never deletes.

---

OCaml implementation notes: [ocaml/algorithms/replication.md](../ocaml/algorithms/replication.md).
