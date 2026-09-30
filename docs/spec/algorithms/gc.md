# Garbage collection of unreferenced chunks

A resumable copying collector that marks by *moving*, run against a domain's main store while
unaware writers keep writing. It is preceded by retention (expiry), which removes the references
that make chunks garbage. This file describes the algorithm independently of the current code;
section 10 maps it onto the implementation. Source references are at commit `4c32fa96`.

---

## 1. Problem and goals

File content is stored as immutable, content-addressed chunks. A chunk's name is a digest of
its bytes, and chunks are deduplicated across every file of a domain. Files are *manifests*,
small objects that list chunk names. Overwriting, deleting or expiring a manifest never deletes
chunks, because another manifest may name the same chunk. Garbage accumulates, and something has
to find and delete the chunks no manifest names.

Goals:

- **G1, no loss.** A chunk named by any manifest that exists when the collection ends, or is
  published later from knowledge acquired before it, must not be deleted.
- **G2, reclaim.** A chunk that no manifest names when the collection opens, and that nobody
  writes again, is deleted from the main and from every store that mirrors it.
- **G3, oblivious writers.** Clients that write the domain must not have to know that a
  collection is running, and must not coordinate with it beyond one cheap duty at publish time.
  Some clients are other machines, some are old binaries, and some reach the store through a
  proxy.
- **G4, resumable and abandonable.** A collection can take hours and be interrupted at any point
  by a crash, a time budget or an operator. It must resume from where it got to without redoing
  finished work, and it can be called off with everything put back.
- **G5, cost proportional to data, not layout.** Work is proportional to the number of live
  manifests plus live chunks on the main, and to the garbage (not the layout) on every other
  store. Copies are never walked or listed.

Non-goals:

- Reclaiming garbage created *during* a run. It lands in the surviving space and waits for the
  next run.
- Collecting a store that is not a local filesystem. Object stores only receive deletes. A domain
  whose main is an object store can be expired but not collected.
- Cross-domain deduplication. Chunk spaces are per domain, so a domain can be dropped with one
  prefix delete.
- Deciding what to keep. That is retention's job (section 4.7), and GC only follows references.

## 2. System model and assumptions

- **A1, main.** The collected store (the *main*) is a directory tree on one filesystem. It offers
  atomic rename of a file or directory within that filesystem. Renaming a missing source fails
  with *not-found*, and renaming a directory onto a non-empty directory fails. Its object `put` is
  atomic: a temp file is renamed into place, and the writer creates missing parent directories
  first.
- **A2, content addressing.** Two chunks with the same name hold the same bytes. A re-upload of a
  name is always harmless to the bytes. It does refresh the object's modification time.
- **A3, no transactions.** Every store operation is atomic for one object at most. There is no
  multi-object transaction and no lock shared between writers and the collector, except the
  optional one proposed in section 8.
- **A4, writers.** Any number of writers, on this machine, other machines, or behind an HTTP
  proxy, upload chunks and publish manifests concurrently with the collection. A writer may:
  - skip uploading a chunk it believes is present (a session memo, a presence check, or a chunk
    inherited from the manifest it is rewriting);
  - hold chunk names for an unbounded time between uploading and publishing (large uploads,
    retries);
  - be a peer that renames or copies manifests without touching chunks.
- **A5, copies.** Other members of the domain hold copies. *Replica* and *backfill* members are
  filled asynchronously from the main by an ordered, durable job queue. That queue is owned by
  the daemon, not by the collector's process. *Archive* (read-only) members hold different
  content and are never written. Additional mains, if any, are written synchronously alongside
  the first.
- **A6, cloud deleters.** Some object-store copies have a server-side function triggered by that
  bucket's object-created notification. Delivery is at-least-once and unordered, and nothing
  redelivers a missed event.
- **A7, failures.** Crash-stop. The collector's durable state is only what lies on the main, so a
  crash loses no more than in-memory progress. A crashed collector's lock is released by the
  kernel.
- **A8, one collector per main.** Exclusion is an advisory kernel lock on a file in the main's
  own tree. This holds only for processes on the host that owns the filesystem (see gap N7).
- **A9, clocks.** Safety of the current design uses no clock. Clocks pace checkpoints and
  progress output and name the run. The proposed fixes in section 8 use store-assigned
  modification times, compared only against another store-assigned time on the same store.
- **A10, reads.** Reading a chunk does not keep it alive. A reader must find a chunk wherever it
  currently is.

## 3. State

Durable, on the main only (never replicated, because a copy cannot act on it):

| State | Content | Notes |
|---|---|---|
| Surviving space **S** | the live chunk directory, by name | Where every writer writes, whatever it knows. |
| Outgoing space **F** | exists only while a run is open | The whole chunk space as it was at open, minus what has been promoted since. At the end of marking, F *is* the garbage. |
| Run record **R** | `phase ∈ {Opening, Marking, Closing, Abandoning}`, `started` (open time), `cursor` | Present iff a run is open. The cursor is the last finished item **by name** (a namespace or a shard), never a position, because resuming re-lists and a changed store shifts positions. |
| Lock file | beside R | Kernel advisory lock. Its content is irrelevant. |

Durable, on copies:

| State | Content |
|---|---|
| Delete request Q(run, name) | A list of chunk names for a cloud deleter. Keyed by run *and* batch, so a later run cannot overwrite an unconsumed one. Deleted by the function only after every key went. |

Volatile, in the collector:

- The work list of the current phase: namespaces, or shards.
- Two concurrency pools, separated by nesting depth: an outer one for roots and an inner one for
  chunks. Sharing one pool deadlocks.
- A pending batch of doomed keys and their shards, plus the time of the last flush.
- Counters.

Volatile, in writers and readers (these are what the collector must be robust against):

- A cached "is a run open" bit with a TTL. Readers use it only to order lookups.
- Session memos of chunk names believed present. This includes the writer's dedup memo and each
  copy's memo of chunks it has confirmed.

## 4. The algorithm

### 4.1 Idea

Opening renames S to F in one atomic step. From then on, S starts empty and grows two ways:

- writers, who know nothing, write into S;
- marking *moves* every chunk a manifest names from F back to S.

When marking ends, whatever is still in F is named by no manifest that marking saw and was not
rewritten by any writer. It is the garbage, listed by name rather than inferred from a set
difference. Deleting it is a directory walk of F plus a per-name check.

Why a move and not a link or copy: a move needs nothing beyond rename. An earlier link-based mark
fell back to rewriting every live chunk on filesystems without hard links. A move also leaves the
garbage behind as the residue, and it makes promotion idempotent and exclusive: exactly one
rename of a given source succeeds.

Why the whole space at once: one rename puts every pre-existing chunk "at risk" atomically, with
no per-chunk bookkeeping and no in-memory live set. S becomes the record of what has been marked,
so a resumed run needs no mark table.

### 4.2 Referenced

A chunk is *referenced* for this run iff it is named by a manifest object that is present in some
**namespace** of the main when marking lists that namespace. Namespaces are:

- every folder namespace in the manifest area. This is by directory enumeration, not tree
  reachability, so trashed subtrees, disowned or orphaned folders and unanchored namespaces all
  keep their chunks;
- every version group in the version area.

Folder markers, anchors and indexes name no chunks. Journal entries and share records name paths
or manifest keys, never chunks. A manifest body that will not parse aborts the run, because
skipping it would delete a file.

References the collector *cannot* see, which must be covered by the writer duty (section 4.4):

1. A manifest published after its namespace was listed, or into a namespace created after
   enumeration.
2. Chunks uploaded, or believed present, by a writer that has not published yet. This covers
   in-flight uploads and staged edits that inherit chunk names from an older manifest, on this
   or any other client.
3. Manifests moved or copied between namespaces during marking: a rename is copy-then-delete,
   from a namespace not yet listed to one already listed.

Copies are never consulted for references. The main's manifest set is authoritative for the
domain.

### 4.3 Collector, phase by phase

The phase is always recorded in R **before** the step it names. Resuming from any recorded phase
redoes, idempotently, whatever that step had started.

```
start(keep, verify):
  require main has a filesystem root, else Unsupported
  take kernel lock (fail Busy if held); set in-process held flag      -- see G3
  R0 := read R
  report outstanding delete requests on each copy (listing only)
  match:
    R0.phase = Abandoning         -> work := Keep(shards of F after R0.cursor)
    keep                          -> write R{Abandoning, cursor=""}; work := Keep(all shards of F)
    R0.phase = Closing            -> work := Close(shards of S ∪ F after R0.cursor)
    R0 absent | Opening | Marking ->
        write R{Opening, started = R0.started or now, cursor = R0.cursor or ""}
        if F does not exist: rename S -> F   (S missing = nothing to do; S is not recreated,
                                              writers create it on demand)
        N := sorted(manifest namespaces tagged m/…  ++  version groups tagged v/…)
        N := [n in N | n > R0.cursor]
        write R{Marking, cursor = R0.cursor}
        work := Mark(N)
```

**Marking.** Namespaces are handled one at a time. Only one at a time makes "last finished" the
same as "furthest reached", so the cursor is exact.

```
mark(ns):
  keys := list(ns as a *directory prefix*)        -- the trailing separator is load-bearing:
                                                     without it the listing is empty, nothing is
                                                     promoted, and closing deletes every chunk
  roots := [k in keys | k is a child object (not internal, not a temp file, not a dir entry)]
  parallel over roots (outer pool):
     body := read(k)            -- a read failure or unparseable body fails the run, nothing discarded
     if body is a folder marker: continue
     for each chunk c named by body (inner pool):
        moved := promote(c)
        if verify and moved: verify_promoted(c)
  write R{Marking, cursor = ns}

promote(c):                         -- also what writers call
  try rename F/shard(c)/c -> S/shard(c)/c ; return true
  on not-found: ensure S/shard(c) exists; retry once
     second not-found: return false   -- already in S, or in neither (see N2)
```

`verify_promoted` runs only when this call moved the chunk, which is once per chunk per run. It
reads the chunk from the main alone, never through the composite: a composite read could be
answered by a replica, and a write would fan out. If the chunk hashes to its name, it deletes any
stale corruption marker. If it does not, or is unreadable, it files a marker. It never discards
the chunk, because a manifest names it.

**Transition.** When Mark is empty:

```
begin_closing:
  shards := sorted(shard dirs in S ∪ shard dirs in F)
  write R{Closing, cursor = ""}
```

**Closing.** Shards are handled one at a time, and doomed keys are pooled across shards.

```
for shard in shards (sequential):
  cand := [names in F/shard that are chunk names]     -- temp files etc. are never named in a delete
  doomed_here := [c in cand | c not present in S/shard (point lookup, inner pool)]
                                                     -- checked after listing F: a promotion that
                                                        landed before the lookup is seen
  pending += shard; doomed += doomed_here
  if no copies  or  |doomed| >= delete_batch  or  now - last_flush >= checkpoint_interval:
     flush()

flush():
  for each copy m (replica, backfill), sequentially:
     ensure main is online (write guard)
     r := m.discard(run, name = max(pending shards), doomed)
     if r = Queued:      nothing more     -- a durable request now exists on m
     if r = Unsupported: m.delete_many(doomed)  (absent = success; per-key failures raise)
  delete corruption markers of doomed keys on the main and on copies that deleted directly
  for shard in pending: unlink every entry of F/shard; rmdir F/shard
  write R{Closing, cursor = max(pending shards)}
```

**Finish.** When Close is empty: remove F recursively, delete R.

**Order inside a flush.** Copies are handled first, then corruption markers, then the main's F
entries, then the cursor. If a crash comes after the copies were told and before the main
discarded, a resume re-lists F, re-dooms the same keys, and re-sends idempotent deletes. The
reverse order would leak those keys on the copies forever, because nothing ever walks a copy.

**Abandoning** (the operator's abort, or `keep`). This is the same machine with "every chunk is
live". Per shard of F, sorted, after the cursor:

```
keep_one(shard):
  if S/shard absent or empty: rename F/shard -> S/shard          (one rename for the whole shard)
  else k := |S/shard|, m := |F/shard|
       if k + 1 < m - k: push_down (move/unlink S's few into F), then try the directory rename again
                         (if a writer landed something meanwhile, fall back to move_across)
       else move_across: rename each c in F/shard not in S/shard into S/shard
       -- names in both are identical bytes (A2), so either copy may be dropped
  unlink leftovers of F/shard; rmdir
  write R{Abandoning, cursor = shard}
when Keep is empty: re-list F; any shards left -> another Keep round; none -> rm F, delete R
```

Once a run is abandoning it stays abandoning on resume. `keep` overrides any phase and ignores
the old cursor, because a cursor means something different in each phase. Shards already closed
cannot be restored, so abort after closing started keeps only what is left.

### 4.4 Writers (the one duty)

Every writer, before making a manifest visible on the main:

```
publish(M):
  (upload or dedup every chunk of M into S, as usual)
  if R is present on the main: for each chunk c of M: promote(c)
  put M
```

Tying survival to publish rather than to how a chunk was found covers the three cases a presence
check alone cannot:

- a chunk skipped by the writer's own memo;
- a chunk uploaded before the open and moved to F by the rename;
- an upload in flight across the open.

Promotion is idempotent and costs nothing when no run is open, apart from one read of R.

Presence checks during a run look in S, then in F. A *miss* re-reads R for real before it is
believed, so a stale "no run" cache can reorder lookups but cannot turn "in F" into "absent".
Readers do the same, S first. Reads never promote.

### 4.5 Deletion on other members

- **Replica, backfill.** These members are told keys, never walked. How a key is removed depends
  on what the member can do:
  - a store with a server-side deleter gets one request object per flush. Its object-created
    notification runs a function that accepts only chunk keys of that domain, deletes them and
    their corruption markers, and deletes the request last, and only if nothing was refused;
  - any other store gets a direct bulk delete.

  Outstanding requests are reported at every start. They can be re-fired by re-writing each
  request onto itself, which raises a fresh notification. Nothing retries automatically.
- **Archives.** Never written. They hold different content, so their garbage is theirs.
- **Additional mains.** Never collected and never told (gap N8).
- **Write guard.** No copy is written while the main is unreachable.

### 4.6 Readers and copies' fill during a run

A copy's fill job (ordered, durable, in the daemon) fetches a chunk from the main when the copy
lacks it. During a run the chunk may still be in F, so the fetch falls back to F. It is written
to the copy under its plain name, because a copy has one space.

### 4.7 Retention (what makes chunks garbage)

Expiry runs through the composite, so it reaches every main and queues deletes to copies. It
removes references and no chunks, in this order:

1. **Trash.** A trashed folder whose trash entry is older than the cutoff, and whose anchor still
   says it is trashed (or is gone), is deleted with its whole subtree: every manifest, marker and
   index under it. The trash entry goes last. An entry whose folder is anchored elsewhere (it was
   restored) is skipped loudly. This goes first so that nothing in the purged subtree counts as a
   reference any more.
2. **Versions.** Version snapshots older than the cutoff are deleted, then version groups that
   have no survivor.
3. **Journal.** Entries older than the cutoff are deleted, except the one the cursor names. The
   journal holds no chunk references, so this step does not matter to GC.

Until expiry removes them, trashed subtrees and versions are namespaces, and they keep every chunk
they name alive (section 4.2). A deleted file with versioning on is still referenced by its
versions. With versioning off, nothing references it once its manifest is deleted.

## 5. Properties and why they hold

**P1, the main keeps what marking saw.** A chunk named by a manifest that was present when its
namespace was listed is in S at the end of marking. Marking promotes it, or finds it already in S.
Closing only deletes names that are in F and absent from S. The listing, reads and promotion are
all idempotent, and a crash re-marks the current namespace in full.

**P2, the writer duty covers what marking did not see**, provided four conditions hold. Suppose
manifest M, naming c, lands after its namespace was listed, or in a namespace enumeration missed.
The four conditions:

- (a) the writer's read of R happened after R was written (so it promoted);
- (b) the promotion happened before closing reached c's shard;
- (c) c existed in F or S at promotion time;
- (d) the writer took the promoting path at all.

Under these, c is in S when closing checks it, and it survives. Each condition fails somewhere
(section 8): (a) is F1, (b) and (c) are N1 and N2, (d) is F2 and N3.

**P3, copies only lose unreferenced keys**, modulo N4. A key is sent to copies only if it was in
F after marking and absent from S at the lookup made after F was listed. A chunk re-uploaded during
the run lands in S, so it is not doomed. A promotion that lands before the lookup is seen.

**P4, no non-chunk object is deleted.** Only names that parse as chunk names are doomed. Anything
else in F is removed with F, as a temp file of an interrupted write. The cloud deleter
re-validates every key's shape and domain before deleting.

**P5, abandoning loses nothing still in F.** Every surviving F entry is moved or carried into S,
or dropped when a same-named copy is already in S (A2). F is deleted only once it is empty of
shards.

**P6, no double collector on one host.** The kernel lock excludes other processes. The
in-process flag excludes a second session in the same process, where record locks merge; this
part is racy, see G3.

**Liveness.**

- Marking terminates: the enumerated namespace list is finite, and namespaces created later are
  not added.
- Closing terminates: the shard list is finite.
- Abandoning converges, because each round removes directories.
- A step that fails, for example on an unreadable manifest or an unreachable copy, leaves R and
  the cursor where they were. The run stays open and resumable, and readers and writers keep
  working, because lookups consult both spaces.
- Reclaim on copies with a deleter depends on their notification firing. A missed event stays
  outstanding until someone re-fires it.

**Cost.**

- One rename to open.
- One listing plus one read per manifest and one rename per live chunk to mark.
- Two directory listings plus one point lookup per *garbage candidate* to close. The surviving
  shard is never listed, because it is hundreds of times larger.
- On copies, deletes only.
- Delete batches are sized by keys, not shards.

## 6. Failure, crash and resume

| Interrupted at | State on the main | Resume does |
|---|---|---|
| after writing Opening, before the rename | R=Opening, S intact | renames (skipped if F exists; S absent is fine) |
| after the rename, before Marking was recorded | R=Opening, F exists | enumerates again, marks from the start |
| mid-namespace | R=Marking(cursor=previous ns) | re-lists and re-marks that namespace (promotion idempotent) |
| between begin_closing and first flush | R=Closing("") | lists shards again, recomputes doomed keys |
| mid-flush: copies told, main not discarded | R=Closing(previous batch) | re-dooms the same keys and re-sends them all (batches may split differently; a request re-put under the same run+name is superseded by one covering the same or later shards); deletes are absent-tolerant |
| after main discard, before cursor saved | shards already gone | those shards are empty, so nothing is doomed there |
| after rm F, before R deleted | R=Closing, no F | no shards to close; deletes R |
| mid-abandon | R=Abandoning(shard) | continues abandoning; never resumes collecting |
| budget exhausted or operator stop | any phase, cursor at a unit boundary | same as a crash, without redoing the current unit |

Other properties:

- **Idempotence.** Every step is either a rename that tolerates not-found, a delete that treats
  absent as success, or a record overwrite.
- **Abandonment.** Possible at any point. It restores everything still in F. What closing has
  already deleted stays deleted, but it was garbage by construction.
- **Lock loss.** The kernel releases the lock on process death. A run left open with no process
  is simply resumable. R's presence alone keeps readers looking in both spaces.
- **Unreadable R.** Lookups treat R's presence as "open", which is safe. Promotion treats an
  unreadable R as "idle", which is unsafe (N5).

## 7. Parameters

| Parameter | Current value | Effect | Trade-off |
|---|---|---|---|
| `concurrency` | store's advertised max concurrency (default 8), clamped ≥ 1, overridable | width of the outer (roots) and inner (chunks) pools, each | Throughput against device load. 1 is least obtrusive. Both pools share the value, so the peak is width² in-flight chunk operations. |
| `delete_batch` | 1000 keys, clamped ≥ 1 | keys per copy delete or request | Fewer round trips against the store's body or request limits. It also bounds how much a crash repeats. |
| `checkpoint_interval` | 5 s | the longest closing goes without flushing and saving the cursor | Shorter means more deletes and record writes. Longer means more rescanning after a crash. It also moves the cursor on stores with little garbage. |
| `units` per step | 256 | namespaces or shards per step call | Granularity of pause and budget checks. The budget is also checked between units. |
| `budget` | none | wall time after which the run is left open | Enables nightly incremental collection. |
| `pause` | none | sleep between steps | Background friendliness. |
| `verify` | off | re-hash each chunk promoted by this run | Turns marking into a full integrity scan of the live set, at one read per live chunk. |
| `keep` / abort | off | abandon instead of collect | — |
| shard fan-out | 3 hex digits (4096 shards) | granularity of closing, abandoning and delete batches | More shards make smaller directories and finer cursors, at the cost of more empty-directory overhead. |
| run-open cache TTL (readers) | 5 s | how long a lookup trusts "no run" | Performance only. A miss always re-checks. |
| writer memo size | 100 000 names, cleared at cap | dedup without store round trips | Bigger saves more lookups but widens N2. |
| copy "ensured" memo | 100 000 names, cleared at cap | copy fill avoids listings | Same exposure as N4b. |
| expiry cutoff | operator-chosen date | what retention dereferences | Longer keeps more history and more chunks. A client offline longer than the cutoff must fully resync. |
| expiry delete batch | 1000 | — | — |
| progress report interval | 1 s | — | Output only. |

## 8. Known gaps

Findings F1, F2 and G3 are adversarially confirmed in [findings.md](../findings.md). The N items
were identified while writing this description from the code. They are **not** adversarially
verified, but each cites the code path it rests on (section 10).

**F1, the writer checks R once, before publishing.** Interleaving:

1. The writer dedups c.
2. The writer reads R, which is absent.
3. The collector writes R and renames S to F, so c is now in F.
4. The collector enumerates namespaces, or marks M's namespace.
5. The writer puts M.
6. Closing finds c in F and not in S, and deletes it.

The window is from the writer's read to the manifest landing, which is milliseconds unless the
put retries.

**F2, proxy writers promote nothing.** Promotion is a rename on the main's filesystem, so a writer
reaching the main over the HTTP proxy cannot perform it, and the proxy server does not perform it
either. Presence checks through the proxy are safe: a chunk only in F reads as absent and is
re-uploaded into S. The unsafe path is the session memo:

1. The writer uploaded c before the run.
2. The run opens and moves c to F.
3. The writer publishes another manifest naming c from its memo.
4. Its promotion is a no-op.
5. The manifest lands in an already-marked or new namespace.
6. Closing deletes c.

The window is the whole marking phase, hours.

**N1, promotion races closing.** Closing decides "doomed" by looking c up in S, then deletes it
from copies and unlinks it from F. A writer promotion that lands *after* that lookup can hit two
cases:

- (i) before the unlink: the promotion succeeds, the main keeps c, but every copy is told to
  delete it (violates P3);
- (ii) after the unlink: the promotion finds c in neither space and returns "false", which the
  writer ignores, and M is published naming a chunk that no longer exists (violates G1).

The code comment claims a promotion landing between the two listings is seen. It is seen only
before the lookup.

**N2, beliefs outlive a completed run.** The writer's memo is process-lifetime, and inherited
chunk names (a partial rewrite reusing the old manifest's chunks) are taken on trust. Nothing
ties either to a collection. Example:

1. A file is deleted with versioning off, or deleted and expired.
2. A full run deletes c.
3. The same process later publishes a file with c's content, from its memo.
4. No run is open, so no promotion happens.
5. The manifest names a chunk that exists nowhere.

This needs no concurrency with the run, only a long-lived daemon. Inside a run, promotion's "false" result
(c in neither space) is the signal that is currently discarded; outside one, nothing is checked at all.

**N3, manifest writes that bypass the duty.** Only the upload path promotes. Several other
operations make a manifest visible without promoting its chunks:

- a file rename, which is a server-side copy to the destination then a delete of the source;
- the in-domain rename in the copy/move operation;
- re-publishing a cached manifest when a rename's source vanished;
- reverting to a version.

Cross-folder file rename during marking, with versioning off, loses data:

1. The destination namespace was already listed.
2. The source namespace is not yet listed.
3. The rename moves the only reference into a listed namespace and removes it from an unlisted
   one.
4. Closing deletes the chunks.

With versioning on, the pre-rename version snapshot keeps the chunks referenced (version groups
sort after all manifest namespaces). Taking that snapshot is best-effort, though, and it can be
expired. A revert is safe only while the version it copied survives until its group is marked.
The code comment that says a namespace created after enumeration "needs no catching, whatever
writes it promoting its own chunks" is true only of the upload path.

**N4, copy-side races.**

- (a) A queued delete request is applied whenever the bucket function runs. That can be hours
  later, or days later after a re-fire. It is applied without re-checking. A chunk re-uploaded
  after the run (it lands in the main's S and is forwarded to the copy) is then deleted from the
  copy by the stale request.
- (b) The copy's fill queue keeps an "ensured" memo in the daemon. Direct deletes by the collector
  process do not invalidate it. A later manifest job naming c skips sending c, and the copy holds
  a manifest without its chunk. Mirror repair heals this. Nothing else does.

**N5, an unreadable R reads as "idle" for promotion** but as "open" for lookups. A writer then
skips promotion during a run. Promotion must be keyed on R's presence, as lookups already are.

**N6, a concurrent delete aborts marking.** A manifest listed and then deleted or renamed before
its read makes the read fail, and the run stops, leaving it open. The resume re-lists, so this is
liveness, not safety. A namespace under steady churn could fail repeatedly. A not-found on a
listed root can safely be treated as "references nothing", because the object is gone.

**N7, exclusion is per host.** Two hosts sharing a main over a network filesystem could both step
one run. Both would resume from the same cursor and partition the work, and one would close while
the other still marks. This is acknowledged in the code.

**N8, only the first main is collected.** Other mains are never told deletes, so they leak
garbage. A domain whose first main is remote is refused even if a later main is local.

**G3, the in-process guard** checks its flag, suspends to open and lock the file, and only then
sets the flag. Two sessions in one process could both pass, and record locks merge within a
process. Nothing drives two sessions today. Set the flag before the first suspension, or use a
mutex.

**Also:**

- Expiry's trash purge checks "still trashed", then deletes the subtree. A restore landing in
  between is deleted with it. This is a check-then-act with no fence; the same fix shape applies,
  re-checking the anchor after deleting the marker.
- Nothing re-fires stuck delete requests automatically.

### What a correct version requires

A minimal protocol that closes F1, F2, N1–N5 and N8 without making writers aware of runs beyond
what they already do:

1. **Promotion is owned by the store that has the spaces, at the manifest-write seam.** Every
   write or copy of a manifest onto the main performs the duty. That means the local driver's
   manifest put and copy, and the proxy server when it receives one. Doing it in one upload path
   is what left F2 and N3 open. It is the single place every writer, including peers, proxies,
   renames and reverts, crosses. A copy of a manifest must read the source body to know its
   chunks. On the main that is a local read.
2. **Publish and doom are mutually exclusive.** On the main's host, take a shared/exclusive
   advisory lock on the main's filesystem:
   - a publisher holds it *shared* across "read R → promote → put manifest";
   - the collector holds it *exclusive* across "write R → rename S→F" and across each shard's
     doom step (below).

   This closes F1 exactly: a publisher either completes before the open, so its manifest is
   enumerated, or observes R. It is cheap: one lock per publish, uncontended except for
   milliseconds. It is sound only where every publisher runs on the main's host, which (1)
   guarantees. Remote writers publish through the proxy or the host's own daemon.

   *Lock-free alternative:* check R *after* the put. If R is present, promote and verify. If R is
   absent, any later open enumerates after the manifest landed, so marking lists it. This needs
   (3) and (4) as well, because the post-check can meet a closing that already doomed c.
3. **Doom atomically, and let promotion observe it.** Closing first renames `F/shard` to a doomed
   area, all at once, under the exclusive lock. It then looks up survivors in S and tells copies.
   Promotion reports one of three outcomes: *moved*, *already in S* (verified, not assumed), or
   *missing*. On *missing*, the publisher must restore c before the manifest becomes visible, or
   refuse to publish. It can restore by renaming c back from the doomed area if it is still
   there, re-uploading it from bytes in hand, or re-reading it from the source file. The doomed
   area is deleted after copies are told. This closes N1(ii) and N2 for writers inside a run.
4. **Beliefs carry a collection generation.** The main keeps a monotonically increasing
   generation, bumped durably at begin-closing. It can live in a permanent record rather than in
   R, so one read yields both. Writers tag memo entries and inherited chunk names with the
   generation at which each was last verified. At publish, a chunk verified in an older
   generation is re-verified by presence in S and handled as *missing* if absent. Copy fill
   queues scope their "ensured" memo the same way. This closes N2 across completed runs and
   N4(b).
5. **Copy deletes are conditional.** Each copy deletes c only if its copy of c is older than the
   run's doom time. Both times are the copy store's own clock: the request carries a doom time
   read from the copy, for example the request object's own creation time. A re-upload or forward
   after doom refreshes c's modification time and survives. Where the store offers a
   generation/precondition on delete, use it to close the head-then-delete window. Where it does
   not, a residual window of one round trip remains, and the generation-scoped copy memo (4)
   repairs it on the next manifest that names c. Alternatively, route direct deletes through the
   copy's own ordered fill queue, where each delete job re-checks "c absent from the main's S" at
   execution time. FIFO order with the manifest jobs makes this exact. This closes N1(i) and
   N4(a), including re-fired stale requests.
6. **Smaller fixes.**
   - Key promotion on R's presence (N5).
   - Treat a vanished root as referencing nothing (N6).
   - Set the in-process flag before suspending (G3).
   - Either collect every local main and tell every other main its deletes, or refuse
     multi-main domains explicitly (N8).
   - Keep the lock on the host that owns the disk, and refuse to collect over a network mount
     (N7).

Items 1–3 together subsume the current pre-publish check. Item 4 is needed even with a perfect
lock, because N2 involves no concurrency.

## 9. Alternatives considered

| Alternative | Why not |
|---|---|
| Mark by hard link, then close by link count (earlier design) | Filesystems without links (exFAT, Android shared storage, some network mounts) fell back to rewriting every live chunk while reporting success. Move needs only rename, and it leaves the garbage as the named residue. (commit `18e77119`) |
| In-memory live set: walk manifests, then diff against a listing | Memory proportional to the live set. Not resumable without persisting the set. The code rejects it with the note "the surviving root is the record of what has been marked". |
| Reconcile copies by listing all 4096 shards on each | Cost proportional to layout. A 12-chunk domain paid 4096 round trips per copy. Copies are now told keys (`18e77119`), and filling a lagging copy is the mirror's job. |
| Redirect writers into a different space during a run | Every writer would have to know about runs, including old binaries, peers and proxies (violates G3). Writing to S unchanged is what makes an unaware writer safe for new chunks. |
| Promote on read or on presence check | Two mechanisms to be sure of instead of one. A read says nothing about references. The code deliberately keeps a single duty at publish. |
| Put R through the composite | Copies would carry a record of a run that is not theirs. R goes to the main only. |
| Delete on the main first, then copies | A crash between the two leaks those keys on copies forever, because nothing walks them. |
| Run request naming by cursor alone | A later run could overwrite an unconsumed request (`27685a67`). Requests are keyed by run and batch. |
| Collect object-store mains with conditional deletes | Needs a server-side rename or a listing of the whole live set per run. Out of scope; expiry still works there. |
| Skip unparseable manifests | A first attempt at "skip what you don't recognise" discarded a whole store. Unparseable input stops the run with nothing discarded. |
| A key-based lock instead of a kernel lock | A crashed holder would leave a run nobody may touch. The kernel lock is dropped on death, so a crash leaves a resumable run. |
| Proposed: a lease or grace period between writing R and renaming | Bounds F1 by time, but a manifest put has no bounded latency (retries), so a writer cannot know it met the deadline. Section 8 (2) or its lock-free post-check variant is exact. |

## 10. Mapping to the current implementation

Spec sections:

- [02 §2.3](../02-remote-model.md#23-backend-key-layout-everything-a-domain-puts-on-a-store)
- [02 §4.9](../02-remote-model.md#49-garbage-collection-mark-by-move)
- [02 §4.8](../02-remote-model.md#48-versions--retention-retentionexpire-cutoff)
- [05 §4.8](../05-ops-config.md#48-retention-expire-trash-deleted-files)
- [05 §4.9](../05-ops-config.md#49-gc-copying-collector-over-a-local-main)
- [06 §4.4](../06-backends.md#44-deferred-targets-replica-and-backfill)
- [06 §4.6](../06-backends.md#46-server-side-work-through-the-bucket-verify-and-discard)
- [OCaml notes](../ocaml/05-ops-config.md)

| Abstract | Concrete |
|---|---|
| Surviving space S | `tsync/<D>/chunks/<sss>/<key>` on the first `Main` member with `local_path` (`Chunk_layout` `key`) |
| Outgoing space F | `tsync/<D>/chunks.from/<sss>/<key>` (`L.from_prefix`, `L.from_key`) |
| Run record R | `tsync/<D>/gc-run` JSON `{phase, started, cursor}`, legacy `reconciling`→`Closing`; `Collection.read_run`/`write_run`/`clear_run`, written to the main directly (`marker_store`) — `lib/domain/remote/store/gc/collection.ml:222-245` |
| Lock | `lockf F_TLOCK` on `tsync/<D>/gc-run.lock` plus in-process `held` — `lib/domain/ops/gc.ml:156-201` |
| Namespace tags | `m/<folder-id>`, `v/<folder-id>` from `readdir` of `manifests/` and `versions/` — `gc.ml:223-261` |
| Directory prefix with trailing separator | `prefix_of_namespace` — `gc.ml:252-261` |
| Root → chunks, abort on parse failure | `referenced_chunks` (reads via composite `B.get`) — `gc.ml:266-283` |
| promote | `Collection.promote` (rename, `ensure_parent`, retry once; result ignored by writers) — `collection.ml:264-285` |
| Writer duty | `Collection.promote_all` (reads R via `read_run`, parse-based) — `collection.ml:294-305`; called in `Remote.publish` before `St.put_manifest` — `lib/domain/remote/remote.ml:202-203`, and via `upload_chunks` |
| Two-space lookups | `Collection.head/get/get_range`, `candidates`, `missed`, `order_ttl = 5.` — `collection.ml:99-220` |
| Writer memo | `Chunk_store.Dedup` (process-lifetime, `max_known` 100 000, reset at cap) — `lib/domain/remote/chunks/chunk_store.ml:3-26,50-68` |
| Collector start / phase dispatch | `Gc.start` — `gc.ml:527-653` |
| Marking step, cursor per namespace | `mark_one`, `mark_root`, `step` (`Mark`) — `gc.ml:752-798,1196-1214` |
| verify_promoted | `gc.ml:691-750` (main only; `Corruption_marker`) |
| begin_closing | `gc.ml:1103-1124` |
| Doomed lookup | `orphans_in_shard` (list F shard, `head_opt` in S per candidate, `Chunks.is_chunk_key` filter) — `gc.ml:330-358` |
| Batch, checkpoint | `close_batch` (`delete_batch` default `Batch.per_delete` = 1000, `checkpoint_interval` = 5 s) — `gc.ml:905-956` |
| flush order | `flush_close` (`Guard.ensure`, `discard` → `Queued`/`Unsupported`→`delete_multi`, markers, `discard_shard`, `save Closing`) — `gc.ml:835-890` |
| Finish | `discard_from_space` (`rm_rf`), `finish` (`clear_run`) — `gc.ml:1129-1139,1184-1187` |
| Abandoning | `carry_over`, `push_down`, `move_across`, `keep_one`, `Keep []` re-list — `gc.ml:966-1099,1169-1183`; `abort` — `gc.ml:1273-1281` |
| Parameters | `run ?budget ?(units=256) ?pause ?concurrency ?delete_batch ?keep ?verify` — `gc.ml:1225-1267`; concurrency from `caps.max_concurrency` default 8 — `gc.ml:542-550`; `report_interval = 1.` |
| Delete requests | `Backend.discard` → `tsync/gc-jobs/<D>/<run13ms>/<last shard>`, body `\n`-joined keys; `outstanding`, `retry_outstanding` — `gc.ml:459-522`; function `run_gc_job` / `may_delete` — `lambda/verify.py:204-240` |
| Copies | `Backend.deferred` = `Replica` ∪ `Backfill` (`lib/backends/api/backend.ml:165-166`); archives = `ReadOnly`; `Backend.main` = first `Main` only (`backend.ml:145`) |
| Copy fill from F | `Deferred` `source_body` with `chunk_from_prefix` — `lib/backends/api/deferred.ml:180-192`; `ensured` memo (100 000) — `deferred.ml:122,154-172,208-245` |
| Write guard | `Write_guard.ensure` ([06 §4.5](../06-backends.md#45-write-guard-never-write-a-copy-while-the-main-is-offline)) |
| Retention | `Retention.expire ~cutoff` (trash → versions → version dirs → journal, cursor entry kept; `still_trashed`, `collect_namespace`) — `lib/domain/ops/retention.ml:248-331` |
| N3 bypasses | `Store.copy_manifest` (copy then delete) — `lib/domain/remote/store/store/store.ml:260-268`, used by file rename `gather_rename_file` — `lib/domain/checkout/file/file.ml:1382-1389`; `publish_manifest` (`Republish_here`) — `file.ml:1168-1175,1455-1461`; `revert` — `file.ml:1191-1216`; rsync `Rename_in_domain` — `lib/domain/ops/rsync.ml:395-410`; `save_version` gated on `C.versioning` — `file.ml:1153-1154` |
| F1 / F2 / G3 | [findings.md](../findings.md) F1 (`remote.ml:202-203`, `collection.ml:294-305`, `gc.ml:636-653`), F2 (`http_proxy_backend.ml:396`, `http_proxy_frontend.ml:645-650`), G3 (`gc.ml:181-196`) |
| Tests | `tests/scenario/gc`, `tests/scenario/expire`, `tests/backends/gc_cost`, `gc_targets`, `gc_queued`, `tests/unit/gc_job`, `tests/unit/chunk_space`, `tests/content/promote_race`. None covers F1, F2 or N1–N6. |
