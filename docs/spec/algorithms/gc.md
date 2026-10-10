# Retention and garbage collection

This file owns retention (expiry and purge: removing the references that make storage garbage) and
garbage collection of unreferenced chunks, including the **collection interlock** that every writer
publishing a chunk reference goes through. Entities and invariants are in
[data-model/backend.md](../data-model/backend.md); byte formats and key spellings in
[02-remote-model.md](../02-remote-model.md); the operator-facing operations (`expire`, `purge`, `gc`,
their options and output) in [05-ops-config.md](../05-ops-config.md). Implementation notes:
[ocaml/algorithms/gc.md](../ocaml/algorithms/gc.md).

---

## 1. Problem and goals

File content is stored as immutable, content-addressed chunks, deduplicated across every file of a
domain. Files are manifests that list chunk keys. Overwriting, deleting or expiring a manifest never
deletes chunks, because another manifest may name the same chunk. Garbage accumulates; something must
find and delete the chunks nothing references, while writers that know nothing about it keep writing.

Goals:

- **Goal 1, no loss.** A chunk named by any manifest or version that is visible on a main, at any time, is
  never deleted from that main. A chunk a collection deletes from a copy while a manifest there names it
  is put back on that copy before the collection's generation settles (§5.7).
- **Goal 2, reclaim.** A chunk that no manifest or version names when a collection opens, and that nobody
  references again before it is examined, is deleted from the collected main and from every copy the
  collecting client lists.
- **Goal 3, oblivious writers.** Clients do not have to know a collection is running. Their one duty is to
  publish references through the interlock (§5.4), which the store driver of the collected main
  performs on their behalf. Every chunk access on that main is scoped by the same driver (§5.8).
- **Goal 4, resumable and abandonable.** A collection can take hours and be interrupted at any point by a
  crash, a time budget or an operator. It resumes where it got to, and can be called off with everything
  put back.
- **Goal 5, cost proportional to data.** Work is proportional to the live manifests plus live chunks on the
  collected main, and to the garbage on every other store. Copies are never walked or listed.

Non-goals:

- Reclaiming garbage created during a run: it lands in the surviving space and waits for the next run.
- Collecting a store that is not a filesystem local to the collecting host. Object stores only receive
  deletes; a domain whose mains are all object stores is expired but not collected.
- Cross-domain deduplication (a domain is dropped with one prefix delete).
- Deciding what to keep. That is retention (§4); a collection only follows references.

---

## 2. System model and assumptions

- **A1, collectable main.** A main is **collectable** iff it is a filesystem store whose root is on a
  filesystem local to the collecting host (not a network filesystem). It offers atomic rename of a file
  or directory within the filesystem (renaming a missing source fails with *not-found*), atomic object
  put (temporary file renamed into place, missing parent directories created first), and host-level
  advisory locks released by the kernel when their holder dies. A collection MUST refuse a main that is
  not collectable.
- **A2, content addressing.** Two chunks with the same key hold the same bytes; a re-upload is harmless
  to the bytes and refreshes the object's modification time.
- **A3, no transactions.** Store operations are atomic for one object at most. The only cross-process
  exclusion is the host-level locking of §5.4, which exists only on the collected main's host.
- **A4, writers.** Any number of writers, on this host or elsewhere (directly, or through an http-proxy
  served from this host), upload chunks and publish references concurrently with a collection. A
  writer may skip uploading a chunk it believes present (a memo, a presence check, a chunk inherited
  from the manifest it rewrites), may hold chunk keys for an unbounded time before publishing, and may
  publish references without touching chunks (rename, copy, revert, version snapshot).
- **A5, reach.** Every write onto a collectable main passes through that store's driver on the main's
  host: by a process on that host, or by an http-proxy server on that host acting for a remote client.
  A filesystem main MUST NOT be written by several hosts through a shared network mount.
- **A6, copies.** Replicas and backfills are filled from the mains by ordered, durable job logs, one per
  client per copy, owned by that client's domain owner ([algorithms/replication.md](replication.md)).
  Archives are never written. Other mains are written synchronously.
- **A7, cloud deleters.** Some object-store copies have a bucket function triggered by object-created
  notifications. Delivery is at-least-once and unordered; nothing redelivers a missed event.
- **A8, failures.** Crash-stop. The collector's durable state is what lies on the collected main plus the
  owner's durable records of deletions owed to copies, so a crash loses only in-memory progress.
- **A9, clocks.** Safety never compares clocks of two machines. Durations are measured with a clock
  that counts time spent suspended. The only time comparisons are between two store-assigned
  modification times on one store (trash and share ages, §4) and between the run's recorded start and the collecting host's
  own clock (§5.5).
- **A10, reads.** Reading a chunk does not keep it alive; a reader must find a chunk wherever it is.

---

## 3. State

Durable, on the collected main only (never replicated):

| State | Content | Notes |
|---|---|---|
| Surviving space **S** | the live chunk directory | where every writer writes |
| Outgoing space **F** | exists only while a run is open | the chunk space as it was at open, minus what has been promoted since; after marking, F is the garbage |
| Run record **R** | phase ∈ {Opening, Marking, Closing, Abandoning}, start time, cursor, and from Closing on the run's **generation** | present iff a run is open. The cursor is the last finished unit **by name** (a namespace or a shard), never a position |
| Collection generation **G** | a counter; even = settled, odd = deletions on copies in flight | persists across runs; absent reads as 0. Written only by the collecting owner (§5.6) |
| Lock file | beside R | carries the two host-level locks of §5.4; its content is irrelevant |

Durable, elsewhere:

| State | Where | Content |
|---|---|---|
| Owed copy deletions | the collecting owner's local state ([algorithms/replication.md §4.8](replication.md#48-deletions-on-copies-outside-the-worker)) | chunk keys to delete on that copy, with the run and shard they came from, and pending discards until consumed |
| Discard requests | on a copy with queued deletion | chunk keys for the bucket function, named by run and shard |

Volatile, in every process that holds them (what the collection must be robust against):

- Cached "is a run open" bits (readers use them only to order lookups).
- **Presence memos**: beliefs that a chunk is present on a member (a writer's dedup memo, a deferred
  worker's memo of chunks it confirmed on a copy). Each entry is tagged with the generation it was
  confirmed under (§5.6).

---

## 4. Retention

Retention removes references. It runs through the domain's composite (reaching every main and queueing
deletes to copies), deletes no chunks, and proceeds in this order, so that nothing it is about to purge
still counts as a reference to what follows: trash, versions, journal, shares. Each step is idempotent;
an interrupted expiry is simply run again.

Expiry and purge have a **dry run** that performs every read and decision below and reports each
deletion it would make, by kind, deleting and writing nothing. Operator entry points default to it.

### 4.1 Trash

Expiry takes a cutoff time. For each folder id named by at least one trash entry:

1. Read the folder's anchor.
2. **Stale entries.** If the anchor says the folder is live (not in trash), every entry naming it is
   stale: delete those older than the cutoff, alone, never the subtree. Log each.
3. **Not yet expired.** If any entry naming the folder is younger than the cutoff, skip the folder: it was
   trashed again recently.
4. **Purge.** Otherwise (anchor "in trash", or no anchor), purge the folder (§4.2), then delete every
   entry naming it.

An entry's age is its store-assigned modification time. Purging one named trashed folder on demand
(any age) is the same procedure from step 1, with step 3 skipped.

### 4.2 Purge

A purge deletes a trashed folder's subtree so that a crash at any point leaves the remainder reachable
from the trash entry:

1. Walk the subtree from the folder, following **filed** markers only (a subfolder moved out of the
   trashed tree is not part of it).
2. Visit namespaces **deepest first**. Immediately before deleting a namespace, re-read the trashed
   folder's anchor; if it no longer says "in trash" (a concurrent restore), stop and report. Then delete
   the namespace's manifests, folder markers and folder index. **Never delete the anchor**: it stays as a
   tombstone ([data-model/backend.md](../data-model/backend.md) §2.7).
3. Delete the trash entries naming the folder, last.

Restore and purge of the same folder are not atomic with respect to each other: a restore landing
between the re-read of step 2 and that namespace's deletes loses that namespace. Operators SHOULD NOT
restore a folder while its expiry runs; the window is one namespace's deletes.

A deleted file with versioning on is still referenced by its versions until they expire. With
versioning off, nothing references it once its manifest is deleted.

### 4.3 Versions

Delete every version whose timestamp is older than the cutoff, then any group directories left empty
on filesystem stores.

### 4.4 Journal

Journal entries hold no chunk references. Expiry MUST NOT delete an entry younger than the retention
horizon H, nor the entry the cursor names, whatever cutoff it was given
([algorithms/wal-and-journal.md §4.8](wal-and-journal.md#48-retention-horizon-bridging-and-rebuild)).

### 4.5 Shares

On each member holding shares for the domain (behind the write guard):

- delete every share whose body names this domain and whose expiry has passed, then the token-keyed
  artifacts of each deleted share;
- delete share artifacts (either assembled kind) whose modification time is older than the cutoff:
  they are rebuildable, whichever domain built them. A preview image goes only with its share:
  with it, or as soon as its share's manifest is not in the listing.

A share body that does not parse is left in place and reported.

### 4.6 Orphan namespaces

An **orphan namespace** is one holding at least one child object that no walk from the root or from a
trash entry reaches through filed markers. Orphans arise from a move or restore cut short and never
resumed. They are GC roots (§5.3), so they keep their chunks alive until adopted.

Integrity repair ([05-ops-config.md](../05-ops-config.md)), which enumerates every namespace and walks
the tree, MUST adopt each **top-level** orphan (one whose anchor's parent is not itself an orphan) once
its anchor and every object in it are older than `orphan_grace`: write a trash entry for it (name from
its anchor, or its id; path equal to that name, at the root), then anchor it "in trash". It is then an
ordinary trashed folder: restorable, and purged by expiry. A client that later completes the interrupted
placement re-anchors the folder live; the adoption's entry then becomes stale and expiry deletes it.

A walk that could not read a folder (its listing or its marker failed, failure-model §5.2) is
**incomplete**: below that folder it cannot tell an orphan from a folder it never reached. The report
names every folder it could not read, and repair adopts no orphan from an incomplete walk.

A namespace holding only its anchor is a tombstone, not an orphan. Repair MAY delete a tombstone once
its full enumeration found no marker naming that id.

---

## 5. Collection

### 5.1 Idea

Opening renames S to F in one atomic step. From then on S starts empty and grows two ways: writers write
into S as always, and marking **moves** every chunk a reference names from F back to S. When marking
ends, whatever is still in F is named by no reference and was not rewritten: it is the garbage, listed by
name. Deleting it is a walk of F plus a lookup per candidate.

A move rather than a link or copy: it needs only rename, promotion is idempotent and exclusive (exactly
one rename of a source succeeds), the garbage is the residue, and S itself is the record of what was
marked, so a resumed run needs no mark table. One rename of the whole space puts every existing chunk
at risk atomically, with no per-chunk bookkeeping.

### 5.2 Which mains are collected, and who is told

- **Every collectable main is collected by its own run**, on the host that owns its filesystem, by the
  owner of the domain on that host ([07-daemon-cli.md](../07-daemon-cli.md)). Runs on two collectable
  mains are independent.
- The run on the **first collectable main in role order** also deletes on copies: every replica and
  backfill in the collecting client's configuration. Copies other clients configure are theirs to
  collect.
- A main that is not collectable is never told deletes: it takes writes synchronously, and a delete
  decided elsewhere cannot be ordered with them. Its garbage is not reclaimed.
- Archives are never written.

### 5.3 What is referenced

A chunk is **referenced** for a run iff it is named by a manifest body that is present in a
**namespace** of the collected main when marking lists that namespace, or that is published through the
interlock (§5.4) while the run is open. Namespaces are every directory of the manifest area (live,
trashed, orphaned or tombstone folders alike) and every version group of the version area.

Marking is by **presence**, not reachability from the root. Reachability is not stable while folders
move (a folder mid-move is unreachable), the store offers no snapshot to compute it on, and removing
references is retention's job, not the collector's. Orphans are handled by adoption (§4.6).

Folder markers, anchors, trash entries and folder indexes name no chunks; journal entries and shares
name paths or locations, never chunks.

### 5.4 The collection interlock

Every write that makes a chunk reference visible on a collectable main MUST go through the **reference
gate** of that main's store driver. A reference-publishing write is any put (plain, claimed or conditional) or server-side copy whose
destination lies in the manifest area or the version area. This covers, among others: publishing an
upload, a file rename (copy then delete), an in-domain copy or move, re-publishing a cached manifest,
reverting to a version, restoring a deleted file, a version snapshot, import, mirror or repair writing
onto the main, a copy refilling a main, and every such write an http-proxy listener performs for a remote
client. A chunk put received by a listener is a writer path too: it goes through the same driver and
lands in S like any other writer's. Because the gate sits in the driver of the store that has the spaces, no caller can bypass it.

The main carries two independent host-level locks, each on its own lock file:

- the **run lock**, exclusive, held by the collector for the whole of its session: at most one collector
  per collectable main. It is a POSIX record lock on `gc-run.lock`. No other lock lives on that file,
  since closing any descriptor of it drops the process's record lock.
- the **publish lock**, a reader/writer lock on `gc-publish.lock`: shared by the
  gate, exclusive by the collector during opening (§5.5) and during each shard's doom step. A gate MUST
  bound its wait for the shared side ([algorithms/failure-model.md](failure-model.md)); a timeout is a
  transient failure of the write.

Within one process, collector exclusion MUST be a check-and-set with no suspension between the check and
the set, taken before the run lock (a process's own record locks merge and would not exclude a second
session in the same process).

**The gate.** For a write naming chunks *C* (read from the body being put, or from the source body of a
copy):

```
gate(write, C):
  take the publish lock, shared
  if R is present on this main (presence, whatever its body):
     for c in C: promote(c)
  for c in C: require c present in S           -- a stat, not a belief
  if any c is missing:
     release; fail the write permanently with "missing chunks" naming them
  perform the write
  release

promote(c):
  rename F/shard(c)/c -> S/shard(c)/c
  on not-found: ensure S/shard(c) exists; retry once; a second not-found is not an error
```

A body in the manifest or version area that is not a manifest (a folder marker, an anchor, a trash entry,
an index) names nothing and passes. A body there that does not parse as any of these is refused.

On a "missing chunks" refusal, the writer MUST re-upload the named chunks from bytes it holds (its staged
body, its source file, its local cache) and retry. A writer that holds no bytes for a missing chunk MUST
NOT publish the reference: it reports the file as damaged and keeps its local content
([algorithms/failure-model.md](failure-model.md)). A version snapshot refused this way is logged and
skipped, like any failed snapshot.

Why this is exact: a gate either completes before the collector takes the publish lock exclusively to
open (so its manifest is present when marking lists its namespace, which happens after the open), or it
observes R and promotes. A promotion either happens before a shard's doom step (so the chunk is in S and
not doomed) or after it (so the chunk is gone from F and the gate reports it missing). The presence check
makes the result independent of what the writer believed, so presence memos never reach the main.

### 5.5 The collector, phase by phase

The phase is recorded in R **before** the step it names; resuming from any phase redoes, idempotently,
whatever that step had started.

```
start(keep, verify):
  require a collectable main (A1) on this host, else Unsupported
  in-process exclusion (check-and-set), then the run lock (non-blocking), else Busy
  R0 := read R
  report outstanding discard requests on each copy
  if R0 is present but unparseable: treat it as Abandoning         -- the safe direction
  match:
    R0.phase = Abandoning          -> work := Keep(shards of F after R0.cursor)
    keep                           -> write R{Abandoning, cursor=""}; work := Keep(all shards of F)
    R0.phase = Closing             -> work := Close(shards of S ∪ F after R0.cursor)
    R0 absent | Opening | Marking  ->
        with the publish lock exclusive:
            write R{Opening, started = R0.started or now, cursor = R0.cursor or ""}
            if F does not exist: rename S -> F      (S missing: nothing to rename; S is not recreated)
        if the manifest area is absent or cannot be enumerated while F holds chunks:
            stop, leaving the run open                -- a missing mount must not read as "no references"
        N := sorted(manifest namespaces tagged m/…  ++  version groups tagged v/…), keep n > R0.cursor
        write R{Marking, cursor = R0.cursor}
        work := Mark(N)
```

**Marking**, one namespace at a time, so "last finished" equals "furthest reached":

```
mark(ns):
  keys := list ns as a directory prefix (with its trailing separator: without it the listing is empty,
          nothing is promoted, and closing would delete every chunk)
  for each child object k (a listed key whose leaf is not internal):
     body := read k from the collected main
       not found (deleted or renamed since the listing): references nothing
       any other read failure, or a body that is not a manifest or folder marker: stop the run,
         leaving it open, nothing discarded
     for each chunk c named by body:
        moved := promote(c)
        if verify and moved: verify_promoted(c)
  write R{Marking, cursor = ns}
```

A not-found on a listed child is safe to read as "references nothing": if it was renamed, the rename's
copy went through the gate.

`verify_promoted(c)` runs only when this call moved c (once per chunk per run). It reads c from the
collected main alone, never through the composite. If c hashes to its key, it deletes any corruption
marker for c on that main; otherwise, or if unreadable, it files one. It never discards c.

**Transition to closing.** When Mark is empty:

```
wait until this owner holds no unsettled copy deletion (§5.7)
if G is odd: g := G                           -- left odd by a crash, or by a run whose records are gone
else: g := G + 1; write G := g                -- odd: from here on no presence memo about a copy is relied on
shards := sorted(shard directories of S ∪ shard directories of F)
write R{Closing, cursor = "", generation = g}
work := Close(shards)
```

A resumed run in Closing whose R carries a generation continues with it (G is already that odd value).
A collector resuming an R in Closing that carries no generation MUST set G to the next odd value and
record it in R before its next doom step, then continue under these rules.

**Closing**, one shard at a time; the **doom step** of each shard runs under the publish lock,
exclusive:

```
close(shard):
  with the publish lock exclusive:
     cand   := [names in F/shard that are chunk keys]      -- temporary files are never named in a delete
     doomed := [c in cand | c not present in S/shard]      -- a point lookup each
     for each copy m told by this run (§5.2):
        record delete(doomed, run, shard) for m durably             -- before the next line (§5.7)
     delete corruption markers of doomed keys on this main
     unlink every entry of F/shard; remove F/shard
  write R{Closing, cursor = shard}
```

The doom step touches only the main's disk and the owner's local records, so the exclusive hold is
short. The surviving shard is never listed: it is hundreds of times larger than the outgoing one.

**Finish.** When Close is empty: remove F recursively, then delete R. The run's generation stays odd
until its copy deletions settle (§5.7), which may outlive the collector's session: the domain owner
settles them. A collector MAY end its session before that and let a later session finish: R stays
present meanwhile, which is safe.

**Abandoning** (the operator's abort, or `keep`): the same machine with "every chunk is live". Per shard
of F, sorted, after the cursor:

```
keep_one(shard):
  if S/shard is absent or empty: rename F/shard -> S/shard                (one rename)
  else k := |S/shard|, m := |F/shard|
       if k + 1 < m - k: move S's few entries into F/shard, then retry the directory rename
                         (if a writer landed something meanwhile, fall back to moving across)
       else: rename each c in F/shard not in S/shard into S/shard
       -- names in both are identical bytes (A2): either copy may be dropped
  unlink leftovers of F/shard; remove it
  write R{Abandoning, cursor = shard}
when Keep is empty: re-list F; shards left -> another round; none -> remove F, delete R
```

Once abandoning, a run stays abandoning on resume. `keep` overrides any phase and ignores the cursor
(a cursor means something different in each phase). Shards already closed cannot be restored; they
were garbage by construction.

### 5.6 The generation, and presence memos

A collection deletes chunks some process may believe present: a writer's dedup memo, or a copy
worker's memo of chunks it confirmed on a copy. No such belief survives a collection (P8):

- **On the collected main**, beliefs are harmless: the gate checks presence at every publication
  (§5.4). A writer receiving a "missing chunks" refusal MUST drop those keys from every presence memo it
  holds for the domain, for every member.
- **On copies**, beliefs are governed by the **generation G**, an object on the first collectable main
  ([02-remote-model.md §2.12](../02-remote-model.md#212-collection-run-record-and-generation-json)):
  - The collecting owner sets G to the next **odd** value durably before the first doom step of a run
    (§5.5), and to the next **even** value only when every deletion that run owed a copy has taken
    effect and been followed by its restore check (§5.7).
  - A presence memo entry about a copy is tagged with the value of G read when the presence was
    confirmed. It MAY be relied on only if G, read **after** the source body that makes the entry
    relevant was read, is even and equal to the tag. While G is odd, presence on a copy is confirmed
    afresh (a probe or a listing of the copy) and no memo entry is recorded.
  - A G that cannot be read (absent reads as 0; an unparseable body does not) is treated as odd.
  - A client cannot tell which of its mains is collectable on another host, so it reads G from
    **every** main and takes the maximum; a main that cannot answer makes G unknown, which is odd.
    Only the collected main holds G, so every other main reads as 0.

Why this is exact, with no timing assumption. A chunk doomed in generation *g* is absent from the main
from its doom step on, so any manifest naming it that a copy later receives was published on the main
after the chunk was uploaded again, which is after G became *g*. A worker reads that manifest from the
main before it reads G, so it sees G ≥ *g* and never relies on an entry confirmed before the doom.
Presence confirmed afresh while deletions are in flight can be wrong by the time the manifest lands on
the copy; the restore check runs after every deletion has taken effect and puts back every deleted
chunk the main holds, which includes every chunk such a manifest names. Only after the restore checks
does G turn even, and fresh confirmations are then true until the next run turns it odd.

### 5.7 Deletion on copies

The deletions a doom step owes each copy are recorded **durably** in the collecting owner before the
main's outgoing entries are unlinked (§5.5), so a crash repeats deletions instead of leaking them. The
owner executes them as specified in
[algorithms/replication.md §4.8](replication.md#48-deletions-on-copies-outside-the-worker):

- **Re-check before** (an optimisation): immediately before issuing a deletion, the owner MAY drop every
  key the collected main holds (§5.8).
- **Direct delete** (a copy without queued deletion: a filesystem copy, or a remote store whose driver
  has no confirmed deleter): delete the keys and their corruption markers. Absent keys count as
  deleted. This costs one request per chunk on an object store, which is impractical for a large
  domain: every remote driver SHOULD provide queued deletion ([06 §3.8](../06-backends.md#38-optional-operations)).
- A copy whose store confirms queued deletion MUST be told through it, never by direct deletes.
- **Queued deletion** (a copy with a bucket function): write the discard request, named by run and shard,
  and keep it among the copy's pending discards (locally, durably) until the request object is gone. A
  request already present under that name is superseded by the new one covering the same or later
  shards.
- **Restore after.** Once a deletion has taken effect (the direct delete returned, or the request object
  is gone), list the collected main's shard for those keys (§5.8), and put back onto the copy,
  from the main, every deleted key the main still holds. Only then is the deletion settled.
- **Settle.** When every deletion owed for generation *g* is settled, write G := *g* + 1 (even),
  holding the run lock: a collector reading G at its transition to closing would otherwise reuse *g*
  for new deletions just as G turns even. A settle that finds the lock held retries once the lock is
  free; the collector's own session also settles at its finish when nothing of *g* is owed.
- **No stale forward.** A best-effort forward of a chunk to a copy that is still in flight when a
  deletion is issued could land after it and put a doomed chunk back; the deletion waits for the
  copy's in-flight forwards, and forwards started meanwhile are skipped.
- The write guard applies: no deletion or restore runs while a main is unreachable.

The **bucket function** deletes only chunk keys of the request's own domain, deletes each chunk's
corruption marker with it, and deletes the request last, only if it refused nothing.

**Re-delivery.** Outstanding requests are reported at every start of a collection. Re-delivering one
rewrites it with only the keys still absent from the collected main (§5.8), which raises a fresh
notification; a request with no key left is deleted instead. Nothing re-delivers automatically. A
request never consumed keeps G odd: copy memos stay unused for that domain (a cost, not a risk) until it
is re-delivered and consumed.

**Records without a generation.** Readers SHOULD accept a run record in Closing without a generation
(meaning G is odd for as long as it is present); collectors MUST NOT write one, and MUST maintain G for
every run they close.

### 5.8 Chunk access is scoped by the driver

The two spaces, R and the publish lock are private to the collectable main's store driver and to the
collector. Every access to a chunk of a collectable main goes through that driver, which scopes it with
the collection, so no caller names F, reads R, or orders lookups:

| Operation on a chunk key | The driver does |
|---|---|
| get, range, head | S, then F. A miss in S re-reads R's presence before it is believed, so a cached "no run" bit can reorder lookups but never turn "in F" into "absent". F is read holding the publish lock shared, then S once more: a reader never observes a shard its doom step is emptying (a copy's restore check would otherwise find a doomed chunk and put it back), and a chunk promoted between the reads is found. Reads never promote |
| put | writes into S |
| delete | deletes from both spaces, and the chunk's corruption marker is the caller's as usual |
| listing of the chunk area | the union of both spaces under plain keys, each name once; keys of F are never listed as such |
| put or copy into the manifest or version area | the gate (§5.4) |

The collector's promotion and the gate's are one implementation. Consequences, with no collection
code at the caller: readers and writers of the main, an http-proxy server exporting it (remote clients
read, and deduplicate against, chunks still in F), a copy's fill job reading a chunk from it (and writing
it to the copy under its plain key, a copy having one space) and an integrity check all see one space.

Presence memos about copies are scoped the same way: the component holding a copy's memo reads G
itself and answers "unknown" whenever §5.6 forbids relying on an entry, and records nothing while G is
odd. Its callers ask whether a copy holds a chunk; they never read G.

### 5.9 Dry run

A **dry run** reports what a collection would reclaim and changes nothing: it writes no store object,
no local record and no generation, opens no run, renames nothing and never takes the publish lock. It
takes the run lock (a dry run beside a live collection would read spaces mid-rename) and answers `Busy`
like a collection.

```
dry_run():
  require a collectable main, the run lock, as start()
  report R's phase and cursor if a run is open, and outstanding discard requests on each copy
  referenced := {}
  for ns in every namespace (§5.3), sorted:
     for each child object k of ns:  body := read k      -- the same read rules as mark()
        referenced += chunks named by body
  for each chunk c listed in the chunk area (both spaces, §5.8), with its size:
     if c not in referenced: count c and its bytes as reclaimable
  report referenced, reclaimable count and bytes, the referenced chunks absent from the chunk area
  (damage), and per-copy the number of reclaimable keys the run would tell that copy to delete
```

A body that stops marking stops the dry run with the same report, having deleted nothing. The
reclaimable set is exact for a main nobody writes between the survey and the collection; writers
move it either way (a publication references a counted chunk, a delete or expiry frees one), and
nothing depends on it: the collection decides by its own marking. Its memory is proportional to
the live set, which §9 rejects for a collection but not for a report: an interrupted dry run is simply
run again. With `verify`, it also hashes each referenced chunk and reports mismatches without filing
markers.

Operator entry points default to the dry run; a collection that deletes needs an explicit request.

---

## 6. Properties and why they hold

**P1, the main keeps what marking saw.** A chunk named by a manifest present when its namespace was
listed is in S at the end of marking: marking promoted it or found it already there. Closing deletes
only names in F absent from S. Listing, reads and promotion are idempotent, and a crash re-marks the
current namespace in full.

**P2, the interlock covers what marking did not see.** A reference published after its namespace was
listed, or into a namespace created after enumeration, went through the gate while R was present (the
open took the publish lock exclusively, so no gate straddles it), and was either promoted before its
shard's doom step or refused as missing. A reference whose chunks the writer held only as a belief is
checked by presence. Nothing the gate lets through names a chunk absent from S.

**P3, copies end with every referenced chunk.** A key is sent to copies only if it was in F and absent
from S under the exclusive doom step. A chunk referenced again after its doom is on the main by the time
of the restore check that follows each deletion, and is put back. Memos cannot hide a deletion (§5.6).

**P4, no non-chunk object is deleted.** Only names that parse as chunk keys are doomed. Anything else in
F is removed with F as a leftover temporary file. The bucket function re-validates each key's shape and
domain.

**P5, abandoning loses nothing still in F.** Every surviving entry of F is moved or carried into S, or
dropped when a same-named copy is already in S. F is removed only once it holds no shard.

**P6, one collector per main.** The run lock excludes other processes on the host, the in-process
check-and-set excludes a second session in one process, and A1/A5 exclude other hosts.

**Liveness.** Marking terminates (the enumerated list is finite; later namespaces are not added).
Closing terminates (finite shards). Abandoning converges (each round removes directories). A failing
step (an unparseable body, an unreachable copy's queue) leaves R and the cursor where they were: the
run stays open and resumable, and readers and writers keep working because lookups consult both
spaces and the gate promotes. Reclaim on a queued-deletion copy depends on its notification firing; a
missed one stays outstanding until re-delivered.

**Cost.** One rename to open. One listing plus one read per manifest and one rename per live chunk to
mark. Two directory listings plus one lookup per garbage candidate to close. On copies, deletes only.
Per publication on the collected main: one lock, one read of R, one stat per named chunk.

---

## 7. Failure, crash and resume

| Interrupted at | State on the main | Resume does |
|---|---|---|
| after writing Opening, before the rename | R = Opening, S intact | renames (skipped if F exists; S absent is fine); the rename happens only in Opening, never once Marking is recorded |
| after the rename, before Marking | R = Opening, F exists | enumerates again, marks from the start |
| mid-namespace | R = Marking(previous namespace) | re-lists and re-marks that namespace |
| mid-namespace, and no F (the open found no chunk space to move) | R = Marking, no F | never renames: every chunk in S was written since the open and is live; marks on from the cursor |
| after Closing was recorded, before the first shard | R = Closing("") | lists shards again |
| mid doom step, jobs appended, F/shard not yet unlinked | R = Closing(previous shard) | re-dooms the same keys and appends them again (duplicate deletes are harmless) |
| after the unlink, before the cursor | shard gone from F | nothing left to doom there |
| after F removed, before R deleted | R = Closing, no F | waits out §5.5's finish condition, deletes R |
| mid-abandon | R = Abandoning(shard) | continues abandoning; never collects |
| budget exhausted or operator stop | any phase, at a unit boundary | as a crash, without redoing the unit |
| collector crashed while holding the publish lock | kernel released it | gates proceed |
| after G was made odd, before R records Closing | G odd, R = Marking | the transition finds G odd and no unsettled deletion, reuses G, records Closing |
| copy deletions recorded, owner stopped before settling | G odd, R possibly gone | the owner resumes its durable records at start, settles them, then makes G even |

Every step is a rename that tolerates not-found, a delete that treats absent as success, a durable job
append that tolerates duplicates, or a record overwrite. G only ever increases. The kernel releases both locks on process death,
so a run left open with no process is simply resumable; R's presence alone keeps readers looking in both
spaces and gates promoting.

---

## 8. Parameters

| Parameter | Recommended | Effect / constraint |
|---|---|---|
| `delete_batch` | 1000 keys, ≥ 1 | keys per copy delete request; the executor may merge consecutive jobs of one copy up to it |
| `budget` | none | elapsed time after which the run is left open; a session always finishes at least one unit, so a zero budget steps |
| `pause` | none | wait between steps |
| `verify` | off | re-hash each chunk promoted by this run |
| `keep` / abort | off | abandon instead of collect |
| `apply` | off at operator entry points | off: a dry run (§5.9, §4); on: collect or expire |
| shard fan-out | 3 hex digits (4096) | frozen by the key layout ([02-remote-model.md](../02-remote-model.md)) |
| publish lock wait | the request deadline | a gate that cannot take the shared lock fails transiently |
| `orphan_grace` | the journal retention horizon plus 7 days | MUST be at least the journal retention horizon, so a client allowed to resume a placement has had the chance |
| expiry cutoff | operator-chosen | longer keeps more history and chunks |
| expiry delete batch | 1000 | — |

---

## 9. Alternatives considered

| Alternative | Why not |
|---|---|
| Mark by hard link, close by link count | Filesystems without links (exFAT, Android shared storage, some network mounts) fell back to rewriting every live chunk while reporting success. |
| In-memory live set, diffed against a listing | Memory proportional to the live set; not resumable without persisting the set. |
| Reconcile copies by listing all shards on each | Cost proportional to layout on every copy; copies are told keys instead. |
| Redirect writers to another space during a run | Every writer would have to know about runs, including peers and proxies. |
| Promote on read or on presence check | A read says nothing about references; one duty at the publication seam is easier to be sure of. |
| A writer-side duty (each writer promotes before its put) | Missed every publication that is not an upload (renames, reverts, snapshots), could not be performed by remote writers, and checked the run once before a put that could straddle the open. The gate in the driver of the main is the one seam every writer crosses. |
| Timing rules for memos (keep the run record present for a poll interval) | Correct only if every owner polls on schedule; the generation is exact. |
| A per-chunk modification-time rule in the bucket function | Needed only without the restore check, which covers every kind of copy the same way. |
| Doom a shard by renaming it to a separate "doomed" area | The exclusive doom step already makes dooming atomic with respect to publications. |
| Reachability-based marking | Unstable while folders move; conflates retention with collection (§5.3). |
| Put R through the composite | Copies would carry a record of a run that is not theirs. |
| Delete on the main first, then tell copies | A crash between the two would leak those keys on copies forever. Deletes owed to copies are made durable first. |
| A lease or grace period between writing R and renaming | A publication has no bounded latency, so a writer cannot know it met the deadline; the publish lock is exact. |
| Skip unparseable manifests during marking | Would discard the chunks of a file that exists. |
| A key-based lock instead of a kernel lock | A crashed holder would leave a run nobody may touch. |

---

## 10. Conformance

An implementation MUST exhibit these observable properties:

- **No loss on the main.** For every interleaving of a collection with writers publishing through each
  reference-publishing path of §5.4 (upload with memo hits, upload in flight across the open, file
  rename across namespaces already and not yet marked, in-domain copy, re-publish, revert, version
  snapshot, import, a remote client through an http-proxy), every chunk named by a manifest or version
  visible on the main after the run is present on the main.
- **Gate outcomes.** A publication naming a chunk absent from the main is refused as "missing chunks"
  whether or not a run is open, including after a completed run deleted a chunk the writer remembers;
  the writer re-uploads and succeeds.
- **Crash at every step** of opening, marking, closing and abandoning, then resume, reaches the same end
  state as an uninterrupted run; abandoning after any interruption restores every chunk still in F.
- **Copies.** For every interleaving of a run's copy deletions with other owners forwarding manifests
  that name re-uploaded chunks, including forwards whose presence check ran just before a deletion
  landed and forwards relying on memos confirmed before the run, every manifest on the copy has its
  chunks once the generation is even again. A worker never relies on a memo entry while G is odd or
  after G changed. A run record in Closing without a generation is
  continued with a fresh odd generation.
- **Readers.** During a run, chunks in either space are readable, directly and through an http-proxy;
  an idle-cache miss re-checks the run before answering "absent".
- **Scoped access.** No component other than the collectable main's driver and the collector names the
  outgoing space, reads the run record or takes the publish lock; no component other than a copy's
  presence memo reads the generation to decide whether a memo entry holds. A listing of the chunk area
  during a run names each chunk once, under its plain key.
- **Dry run.** A dry run changes no byte on any store and no local record, whatever the phase it finds;
  on a main nobody writes, its reclaimable count and bytes equal what the following collection reclaims,
  and after a completed collection it reports zero.
- **Retention.** Expiry never deletes a folder whose anchor is live; purges deepest namespace first and
  trash entries last; keeps anchors; deletes stale entries alone; skips a folder with any entry younger
  than the cutoff; deletes expired shares of its domain and their cached artifacts; never deletes a
  journal entry younger than the horizon or the one the cursor names; leaves chunks to the collection.
- **Exclusion.** A second collection of the same main, from another process or the same process, is
  refused as busy.
- **GC behaviour.** A chunk referenced by any live manifest, version or trashed manifest is kept; a
  second run right after a completed one deletes nothing; `abort` restores every chunk still in F;
  with `verify`, a referenced chunk that does not hash to its key is kept and marked, never deleted;
  deleting a chunk deletes its corruption marker; a chunk only a copy holds survives on that copy; a
  collection never copies chunks to, or fills, a copy.
- **Purge.** Purging a named path never trashed answers "not in trash"; purging a trashed folder that
  is anchored elsewhere is refused.
- **Cost.** Starting a run lists nothing; marking lists each namespace once and needs no presence
  check per chunk; resuming does not redo finished units; closing lists only the shards the main holds,
  never lists a copy, and asks copies nothing but deletions.
