# Multi-store replication

One domain is backed by several stores, each with a role, and is presented to every layer above as a single store with the contract of [06-backends.md](../06-backends.md). This file owns the roles, the composite's read and write paths, the copies filled behind the write, the write guard, and repair between members.

Terms: a **member** is one configured backend of a domain. A **copy** is a replica or backfill member. The **source** is the main, read alone. The **owner** is the process that owns the domain on this machine ([07 §2.2](../07-daemon-cli.md#22-the-domain-owner), principle P1 of the spec README).

---

## 1. Problem and goals

A domain is a set of objects: content-addressed **chunks** (the name is a hash of the body), and **referrers** that name chunks (file manifests, versions, and the log entries that carry manifests) or other objects (the tree head and the cursor name a log entry). The user wants more than one store to hold it: a source of truth, a full second copy that still serves file content when the first is unreachable, a copy being filled for later promotion, an old archive that still answers for what it holds.

Goals:

- **G1 One store.** Callers see one store with the ordinary contract. They never learn how many members there are or which one answered.
- **G2 Roles as policy.** A member's role fixes what it promises to hold, when, and whether reads may reach it.
- **G3 Writes are not slowed by copies.** A write returns once the main has it and every copy has durably recorded that it owes it. Copies catch up in the background, across crashes and restarts.
- **G4 Partial coverage, never partial files.** A copy may lag, but a referrer reaches it only after everything the referrer names is there.
- **G5 Honest reads.** A read of content fails over past an unreachable member, and never reports "not found" because a member could not be asked. A read that decides what the tree is (the log, the tree head, a tree record) is answered by the main or fails ([publication.md](publication.md) S9).
- **G6 Copies are never ahead of the truth.** No copy is written while the main is offline.
- **G7 Nothing is dropped, and divergence is visible.** A job that cannot run is kept and retried, the copy is reported degraded meanwhile, and whole-store divergence (corruption, a new empty member) is repaired by an explicit operation.
- **G8 Forwarding never competes with the user.** Best-effort chunk forwards use upload bandwidth only when the link has room.

Non-goals:

- More than one main. A domain has at most one: the log's atomic append is what orders every change, and it is evaluated in one place ([publication.md](publication.md) §2).
- Writes while the main is offline. Failover is for reads of content only. Disconnected writes stay pending on the client, one layer up ([publication.md](publication.md)).
- Following a copy. A copy's log and tree lag the main's key by key and are not a snapshot of it; no client fetches, merges or pushes against one.
- Merged listings. A listing is one member's view.
- Automatic whole-store repair. Findings are reported, and an operator runs the repair.
- Byte-level checking by the replication path. Stores check bodies against names themselves ([06 §2.3](../06-backends.md#23-capabilities)).

---

## 2. System model and assumptions

- **A1 Stores** implement the contract of [06 §3](../06-backends.md#3-the-store-contract): atomic put, honest absence, a real claim precondition, honest delete results, read-after-write and list-after-write on each key.
- **A2 Failures** carry the kinds of [algorithms/failure-model.md](failure-model.md). Each member has a [breaker cell (01 §8)](../01-core.md#8-health-breaker), fed as [failure-model §6](failure-model.md#6-link-health-evidence) says.
- **A3 Content addressing.** Chunks are immutable: two bodies under one chunk name are the same bytes unless a store damaged them. Referrers are mutable, last writer wins.
- **A4 Durable logs** as in [algorithms/durable-queue.md](durable-queue.md): records survive a crash, are run in id order, and a record that fails with a non-retryable kind is parked and retried, never dropped.
- **A5 One owner per domain per machine** (P1). Other machines write the same main, each through its own owner, and keep their own job logs for the copies they configure.
- **A6 Clocks.** Only durations are used, on the monotonic clock. No ordering decision depends on a clock.
- **A7 Collection** runs over a main and deletes unreferenced chunks from copies through the copies' job logs ([gc §5.7](gc.md#57-deletion-on-copies)); this file specifies how those deletions are recorded and run (§4.8).

---

## 3. State

### 3.1 Roles

| Role | Promises to hold | When | Reads reach it | Written by |
|---|---|---|---|---|
| **main** (at most one) | everything | synchronously: a write returns only after it has it | every read; its answer is the domain's, and it alone evaluates conditional writes | the composite |
| **replica** | everything, including the log, the tree head, takeovers and the cursor | eventually, behind the write, through its job log | **chunks only**, and only when the main did not answer | its job-log worker |
| **backfill** | the tree and its content: every key except log entries, the tree head, takeovers and the cursor | eventually, from the moment it was added; earlier content arrives only through repair | never, and share links never point into it | its job-log worker |
| **read-only (archive)** | different content (an older or foreign store) | never written | chunks, after the main misses or is unreachable; everything, in a domain with no main | nobody |

A replica and a backfill are one mechanism that differs in whether chunk reads reach it and whether it carries the log.

Every copy skips per-store caches (folder index objects, which describe the store that wrote them).

**A copy is a last resort.** It converges on the main eventually and is not a substitute that can take over at once. Putting a copy in service as a main is outside this specification.

### 3.2 Configuration rules

- Every member has a role.
- A domain MUST NOT have more than one main.
- Member names MUST be unique within a domain, MUST be non-empty, and MUST NOT be `.` or `..` (uniqueness ignoring case is enforced by [05 §2.1](../05-ops-config.md#21-schema-and-validation)). A name identifies durable local state (the job log), so a duplicate would make two members share one log.
- A replica or backfill without a main MUST be refused ("nothing to fill it from").
- A domain with no main MUST have at least one archive, and is then read-only: nothing is pushed, and its first archive, in configuration order, stands for the main in every read (§4.6).
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
- Readers MUST accept exactly these shapes. A record that does not decode, or names an invalid key, is set aside ([durable-queue §3.3](durable-queue.md#33-ordering-rules), R6).

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
  main     := the member with role main, if any
  archives := members with role read-only, configuration order
  source   := composite(main, copies = [], archives = [])         -- the main only
  copies   := [copy_target(m, source, chunk_reads = (m.role = replica))
               for m in replicas ++ backfills]
  return composite(main, copies, archives)
```

A copy catches up by reading **the source**, never the composite. A job is consumed once it succeeds, so a body read from a copy that is itself behind would land and never be corrected.

### 4.2 Write path

```
put(k, b):
  if main = none: fail REFUSED(read_only)
  main.put(k, b)                                      -- failure: raise; no copy is told
  fill(Put(k))                                        -- the main holds it: copies owe it

put_if_absent(k, b):
  r := main.put_if_absent(k, b)                       -- the main alone arbitrates
  if r = Won: fill(Put(k))                            -- a Held answer wrote nothing
  return r

put_if_unchanged(k, b, expected):
  r := main.put_if_unchanged(k, b, expected)          -- the main alone evaluates it
  if r = Changed: return Changed                      -- nothing written, no copy told
  fill(Put(k)); return Written

delete(k):        removed := main.delete(k); fill(Delete(k)); return removed
delete_multi(ks): main.delete_multi(ks); fill(DeleteMany(ks))
copy(s, d):       main.copy(s, d); fill(Copy(s, d))

fill(job): for c in copies (configuration order):
             keys := [k in job's keys | not c.skip(k)]
             if keys ≠ []: c.accept(job restricted to keys)
```

- The main is the authority. Its answer is the operation's answer, and its failure aborts before any copy is told.
- `expected` was read from the main: a conditional replace is never evaluated against an entry a copy reported.
- A write returns once the main has it and every copy has durably recorded the job, or has decided on a chunk forward.

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

- A process that is not the owner but writes the main (the http-proxy store server, [07 §2.2](../07-daemon-cli.md#22-the-domain-owner)) records copy jobs by **submission** and pokes the owner. Copy jobs are order-insensitive (§4.3), which is what submission requires. A non-owner never forwards chunks: the referrer's job fetches them.
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

- `chunk_names(b)` is the list of chunks `b` names if it parses as a manifest, and empty otherwise (log entries, markers, anchors, the tree head, takeovers, the cursor, shares).
- A log entry is copied without its chunks being checked. An entry at or below the tree head may name content that was replaced since and collected ([gc §5.3](gc.md#53-what-is-referenced)), and nothing follows a copy's log (§4.6): what a copy must hold whole is what its tree records name.
- A `DeleteMany` job MAY establish which of its keys the source still holds with one listing per distinct parent prefix instead of one read per key.
- The tree head and the cursor need no dependency check: nothing reads them from a copy to decide anything (§4.6).
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

read(k, f):
  if main ≠ none and k is not a chunk key:
     return ask(main, f, last_candidate = true)       -- the main's answer, or its failure
  a := main = none ? Miss : walk([main], stop_on_miss = true)
  if a = Answer v: return v
  if a = Unreachable e:                               -- only then is a replica asked
     for r in replicas: if (try ask(r, f)) = some v: return v
                                                      -- a replica's "absent" is no answer: it may lag
  b := walk(archives, stop_on_miss = false)           -- archives hold different content: ask each
  if b = Answer v: return v
  if a = Unreachable e: raise e                       -- "could not look" never becomes "not there"
  if b = Unreachable e: raise e
  return none
```

- **Only chunks fail over.** A chunk is named by its bytes, so a copy that lags can lack it but cannot hold another body under its name. Every other key (a log entry, the tree head, a takeover, the cursor, a manifest, a marker, an anchor, a version) says what the tree is or was: a copy's answer would be an older truth, which a client would take for a peer's change ([publication.md](publication.md) S9). Those reads are the main's or fail.
- A main that answers "absent" means *not found*. A replica holds the same chunks or fewer, and is not asked.
- A main that is unreachable means the replica answers for chunks.
- Archives are asked for chunks both when the main misses and when it is unreachable. In a domain with no main, the first archive answers as the main would (every key that is not a chunk, and listings), and the others answer chunks only.
- When everything is unreachable, the first unreachable error is raised, never "absent" ([failure-model §5.2](failure-model.md#52-absent-versus-could-not-look)).
- `get` is `read(get_opt)`, with a clean `none` turned into ABSENT.
- `list_prefix` is the main's listing, never merged and never a copy's. An empty list is an answer. Its etags and checksums are the main's. In a domain with no main it is the first archive's.
- `compute_checksum` is answered as `list_prefix` is: a checksum describes the view the composite's listings and entries describe. `locality` is that member's.
- `watch` is a non-probing read of the main: a long poll must never be the request that finds out whether a member is back.
- The single probe per lapsed hold is the breaker's ([01 §8](../01-core.md#8-health-breaker)); concurrent chunk reads that do not get it pass to the next member.

**Batches.** A batch read (many keys, or many folders' listings with bodies) is declared only if the member that answers single reads of those keys declares it, and it goes to that member alone.

- If the member refuses the batch, the batch answers empty.
- A transient failure while the member is still considered up is raised: every key would be lost the same way.
- Every key the batch did not answer with a body goes back through `read`, one at a time, which keeps chunk failover and the unreachable-versus-absent distinction.

### 4.7 Capabilities, verification requests and discards at the composite

**`capabilities(prefix)`** asks every non-archive member that is not held, without probing:

- `share_url` and `chunk_size` come from the main. A replica never decides the chunk size of new files.
- `max_concurrency` is the minimum over the main and the replicas that answered.
- `verified` is true only if the main and every replica and backfill answered `verified = true`.
- If the main did not answer and the domain has one, the call fails UNREACHABLE. An empty merge would be memoised as fact.
- Archives have no say.

**Whole-store verification** is the owner's, per member: it writes verify requests to each member whose bucket function it confirmed, behind the write guard, since a request is an object written into the store ([05-ops-config.md §4.10](../05-ops-config.md#410-integrity)).

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

- **Recorded before the main discards**, for direct and queued copies alike ([gc §5.7](gc.md#57-deletion-on-copies)).
- **Restore after (mandatory).** Once a deletion has taken effect (a direct delete returned, or the request object is gone), every deleted key the main still holds is put back. Only then is the deletion settled. A chunk referenced again during or after the collection is thereby restored on the copy, whenever the deletion landed.
- **Settling G.** G turns even only when every deletion of its generation is settled, so a memo is never relied on while a deletion could still invalidate it ([gc §5.6](gc.md#56-the-generation-and-presence-memos)).
- **At start** the owner resumes every unsettled collection-delete record and pending discard, settles them, and then makes G even.
- **A request never consumed** leaves G odd until it is re-delivered and consumed ([gc §5.7](gc.md#57-deletion-on-copies)).
- A collection-delete record completes only after its direct deletion and restore, or once its discard is recorded pending; a pending discard is removed only after its restore.
- **Written before pending.** A pending discard is recorded only once its request is on the copy, so a poll that finds the request gone knows it was consumed, never not yet written. A crash in between leaves the collection-delete record owed, and its rerun writes the request again.
- Failures follow the queue discipline of §4.3.

### 4.9 Write guard

```
guard(dst, what):
  if dst.role = main: allow                          -- integrity repair of a chunk on the main
  if the main was never heard from, or is down and its hold lapsed:
     probe: main.get_opt(cursor key), bounded by PROBE_TIMEOUT including retries;
            a timeout is recorded as a lost probe
  if the main is down: fail TRANSIENT/LINK "refusing to <what>: the main <m> is not online"
  allow
```

- A main heard from and up is taken at its word, so a run of guarded writes costs one look, not one each. A domain with no main passes.
- Every operation that writes a copy directly MUST call the guard first: mirror copies, integrity rewrites, verification requests, collection delete jobs and re-delivered requests, and share publication. Ordinary copy jobs are guarded too: the worker does not run while the main is down.
- The composite's own writes cannot violate the guard: copies receive only what the main already took.
- The guard fails TRANSIENT so that callers retry once the main is back, rather than record a permanent refusal.

Why it exists: a copy written while the main is offline would hold state the source of truth never had, and nothing could check it against the main.

Residual window: a main that goes down between the look and the write is not seen. That is harmless for repair (it copies what the main held) and for collection (it deletes what the main already doomed and re-checked).

### 4.10 Repair: mirror

Mirror is an explicit, stateless, additive copy of the main onto its copies. It is the remedy for a new copy's past content, for writes made by owners that do not configure a copy, and for parked jobs whose cause a repair of the copy clears. It never writes the main.

```
mirror(scope ∈ {All, Skip_chunks, Path(p)}):
  refuse All and Path while a collection run is open on the main          -- chunks are split across two spaces
  for dst in the copies, sequentially, in configuration order:
     guard(dst, "copy to " dst)
     phase 1  chunks (not Skip_chunks): for the scope's chunks (All: every shard; Path: the chunks
                        the in-scope manifests name), copy each chunk the dst listing lacks or holds
                        at a different size
     if phase 1 failed to place any chunk: stop for this dst, and report it
     phase 2  log entries, in ascending number, then takeovers (not into a backfill; not Path)
     phase 3  tree records: manifests, folder markers, anchors; and versions (not Path).
                        For immutable keys, copy when missing or of a different size;
                        for mutable keys, copy when missing or when the bodies differ
     phase 4  the tree head, then the cursor (not into a backfill; not Path), last
  then retry every parked record of dst's log
```

- The phases give the dependency order of G4 and of [data-model/backend.md §4.3](../data-model/backend.md#43-ordering-rules-crash-consistency): a chunk before anything naming it, a log entry before the tree records it gives a value to, both before the tree head, the cursor last. A copy's log entries, tree head and tree records are plain objects that nothing follows (§4.6), so mirror writes them as it writes any object; the arbitration rules of the log bind the main alone. A mirror interrupted at any point leaves no referrer without its referents.
- Mirror never deletes. It does not detect same-size wrong chunk bytes: that is verification's job. Per-store caches are not copied.

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

**S1 (referrer after referenced).** When a manifest is present on a copy, every chunk it names is present there. Its job ensures each named chunk before the put, and `ensure_chunk` returns only after a confirmed put, a fresh confirmation, or a memo entry whose tag equals an even G read after the referrer was read from the source. A chunk doomed in generation *g* can reappear in a referrer only after G became *g*, so such a job never relies on an entry confirmed before the doom ([gc §5.6](gc.md#56-the-generation-and-presence-memos)). A fresh confirmation made while G is odd can be overtaken by a deletion; the mandatory restore of §4.8 puts back every deleted chunk the main holds before G turns even.

**S2 (no job lost).** A job is recorded durably before the write returns. Its record is removed only on success; a non-retryable failure parks it.

**S3 (per-key convergence).** Every job sets its keys on the copy to the source's state at the time it runs. The last job for a key runs after the last main write of that key by this owner, so after quiescence (no writes, logs empty, nothing parked) every non-skipped key the owner wrote equals the source's value, whatever the order between logs, across owners and machines.

**S4 (order within a log).** One worker, head-of-line blocking for retryable failures: effects apply in id order. Parking may reorder, which S3 makes harmless.

**S5 (no false absence).** In a domain with a main, `read` returns `none` only if the main answered `none` and, for a chunk, every archive answered `none` too. A replica's `none` never becomes the domain's.

**S6 (copies never ahead).** Composite writes reach copies only after the main took them. Direct writes and job runs pass the guard.

**S7 (one runner).** Only the owner runs a log (P1), and ownership is exclusive on a machine.

**S8 (visible degradation).** A copy is reported degraded exactly while a record of its log is parked, and parked records survive restarts.

**S9 (a copy decides nothing).** Every read that can set what a client knows of the main, check a guard or order a commit is answered by the main (§4.6), and every conditional write is evaluated by it (§4.2).

**Liveness.**

- **L1.** While the source and a copy are reachable, every recorded job eventually completes or is parked; parked records are retried periodically, so one whose cause cleared completes.
- **L2.** Records left by an owner that died, and records submitted by non-owners, are run by the next owner.
- **L3.** A held member is re-probed once per hold window ([01 §8](../01-core.md#8-health-breaker)), so a returning member is noticed within that bound.

**Replica consistency at any instant.** For each key, the replica holds the source's value at some past instant, or an older value while a job for that key is owed. Across keys it is not a snapshot: its log may have a hole, and its tree may be ahead of its tree head or behind it. Every referrer it holds has its chunks. That is enough for what a replica is read for (chunks) and for mirror; it is not enough to follow, which is why nothing does. A backfill offers the same per-key guarantee over the keys it carries, from the moment it was added.

---

## 6. Failure, crash and resume

| Interruption point | Effect | Recovery |
|---|---|---|
| The main fails | No copy owes it | The caller repeats the write |
| Crash after the main, before the job records | The write never returned | The caller's durable work repeats it |
| Crash after a record, before its job ran | Record on disk | Next owner runs it at start |
| Crash mid-job (chunks partly put) | Chunks are immutable; the referrer is not yet put | The job re-runs; memo misses cost a listing |
| Stop during a job | Neither done nor failed; the record stays | Next owner |
| Chunk forward lost or refused admission | Nothing owed | The manifest's job fetches the chunk |
| Copy down for hours | Records accumulate on disk; the head retries with backoff | Automatic when the link returns |
| Copy refuses a job | Record parked; copy degraded | Automatic retry once the cause clears; operator repair otherwise |
| A record does not decode | Record set aside ([durable-queue §3.3](durable-queue.md#33-ordering-rules), R6); copy degraded | Operator |
| Source names a chunk no main holds | Job parked as CORRUPT, naming the key | Integrity repair on the main; the parked retry then completes |
| Main down | Chunk reads fail over; every other read and every composite write fails; guarded writes and job runs wait | Automatic on return |
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
- **Several mains.** Rejected: two clients could each create the same entry number on a different one.
- **Following a replica during an outage.** Rejected: a lagging log or tree shows an older value than the client last saw, which it would merge as a peer's change and publish when the main returns.
- **Merged listings.** Rejected: one member's view is consistent with itself, and a merge would mix different points in time.

---

## 9. Conformance

An implementation MUST exhibit:

- **Read semantics.** With main and replica: a reachable main that misses answers "absent" without asking the replica; with the main unreachable, a chunk read is answered by the replica and every other read fails UNREACHABLE; archives answer chunk reads on a miss of the main and when it is unreachable; everything unreachable raises, never "absent", and the main's error is the one reported; a read-only domain reads and lists from its archives, and its writes fail REFUSED(read_only); an empty listing is an answer.
- **Held failover.** A replica is not asked while the main is up. A main found down is passed over for chunk reads without waiting out its retry ladder, and a request already in flight to it is cancelled. A long poll is never the probe. A single-member domain always asks its member, held or not. At hold expiry exactly one of several concurrent reads probes.
- **Main down.** Every write verb fails; no log entry, tree head or tree record is read from a copy; the replica is unchanged and owed nothing; verification requests to the replica are refused. A write taken earlier stays owed and lands when the main returns.
- **One main.** A configuration with two mains is refused. A conditional write is evaluated by the main alone; a `Held` or `Changed` answer records no job.
- **Durability.** A job is on disk before the write returns, and survives a failure of the copy. After a restart the copy's jobs are intact and run in id order, with writes made meanwhile recorded behind them. A stop mid-job leaves it owed. A permanent failure parks the job and reports the copy degraded, across restarts; the parked job completes on retry once the cause clears. A record submitted by a non-owner is run by the owner after its poke.
- **Convergence.** A delete job whose key the source holds again restores the key on the copy. A put job whose key the source no longer holds deletes it on the copy. A rename is converged as a put of the destination and a delete of the source. Two logs replayed in either order converge on the source.
- **Referrer after referenced.** A manifest reaches a copy only after every chunk it names; a log entry is copied whatever chunks the copy holds; a chunk missing at the source because its referrer changed restarts the job with the new body; a chunk no main holds parks the job as CORRUPT with the key named.
- **Memo.** 40 manifests × 4 chunks over 4 shards cost no per-chunk metadata reads, 4 shard listings and 160 chunk puts, and the same content under new names costs nothing more. While a run record is present the memo is not relied on. After a collection deletes a chunk from the copy and the chunk is referenced again, the manifest's job puts the chunk before the manifest.
- **Collection deletes.** Owed deletions carry their generation and are durable before the main unlinks its outgoing chunks; a crash in between repeats them. A deletion deletes chunks and their markers on a copy without a function, or writes one discard request per run and shard on a copy with one, kept pending until consumed; removes its keys from the memo first; does not run while a main is down. After a deletion takes effect, every deleted chunk the main holds is restored on the copy, and only when every deletion of a generation is settled does G turn even. At start, unsettled deletions are resumed and settled before G is made even. A never-consumed request leaves G odd, and the memo unused.
- **Generation.** While G is odd, or unreadable, or a run record in closing has no generation, no memo entry is relied on or recorded. After G changes, no entry tagged with the old value is relied on. A writer refused "missing chunks" by the gate no longer believes those chunks present anywhere.
- **Forwards.** Forwards are asked once per chunk with its exact size, and only admitted forwards are sent; a refused forward is fetched by the manifest's job.
- **Backfill.** Chunks before manifests; a deduplicated hole is filled; symlink manifests name no chunks; the log, the tree head, takeovers and the cursor are not carried; reads never reach it.
- **Write guard.** Probes once then trusts; a down main refuses non-main writes as TRANSIENT naming the main; an expired hold is re-probed; a main that never answers is bounded by the probe timeout; a domain with no main is allowed.
- **Mirror.** On any interruption, the destination holds no manifest without its chunks, and no tree head above its log; a mutable key of equal size but different body is recopied; mirror never deletes.

---

OCaml implementation notes: [ocaml/algorithms/replication.md](../ocaml/algorithms/replication.md).
