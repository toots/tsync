# Durable queue, persistence rules and crash immunity

This document owns three things:

1. **The persistence rules** (principle P2, "durability before acknowledgement"): the durable
   write primitives and the ordering rules every authoritative local object obeys (§3).
2. **The durable queue**: an on-disk log of owed jobs and the runner that drives it (§4).
3. **The crash-immunity inventory**: every place owed work or unpublished user data lives, every
   acknowledgement point, and the outcome of a kill at every step (§6–§7).

Related rules owned elsewhere, referenced and not restated:

- WAL record states, publishing and startup reconcile:
  [wal-and-journal.md](wal-and-journal.md) §4.1, §4.2, §4.7.
- What the domain owner owns, and which local entities are authoritative:
  [data-model/local-cache.md](../data-model/local-cache.md).
- The process model and the ownership lock's lifecycle (P1): [07-daemon-cli.md](../07-daemon-cli.md).
- Failure kinds and their propagation (P3): [failure-model.md](failure-model.md).
- Byte formats of local files: [04-checkout-cache.md](../04-checkout-cache.md) §2.

---

## 1. Goals

- **G1. No acknowledged action is lost.** Once the system tells a caller that a mutation
  happened, durable evidence of every owed remainder exists and survives any later kill,
  including power loss (at the durability level the acknowledgement promised, §3.1).
- **G2. Owed work completes.** After any restart, all owed evidence is rediscovered and driven
  to completion, or to a parked state that is visible and retried. Nothing waits on a human
  remembering, and nothing is abandoned silently.
- **G3. At-least-once, harmless twice.** A job may run more than once. The end state equals a
  single run.
- **G4. Order where it matters.** Jobs whose effects do not commute take effect in recorded
  order among the jobs that succeed. Jobs on independent keys do not block each other.
- **G5. Bounded stop.** A stop completes within a fixed grace. Whatever it leaves is owed on
  disk.
- **G6. Visible failure.** Work that cannot complete is reported (parked, set aside, degraded),
  never dropped.

**Non-goals.** Exactly-once execution. Durability of an action nobody acknowledged: it may be
absent after a crash, but never half applied. Surviving loss of the local disk (the store is
then the truth and a rebuild recovers). Cross-machine transactions.

## 2. Model and assumptions

- **A1. Local filesystem.** The data directory and the cache root MUST be on a local filesystem
  that provides: atomic rename within a directory; `fsync` on files and on directories, after
  which the synced data and directory entries survive power loss; hard links (required in the
  data directory, where create-if-absent uses them; optional in the cache root, see
  [04](../04-checkout-cache.md) §4.8); sparse files; and advisory whole-file locks released by
  the kernel when the holder dies and not released by closing an unrelated descriptor (BSD
  `flock` or open-file-description locks, not POSIX record locks). A network filesystem does not
  qualify, and an implementation MUST refuse to take ownership of a domain whose data directory
  it detects on one.
- **A2. Without fsync nothing survives power loss in any order.** A rename can reach the disk
  before the renamed file's data, leaving a zero-length or torn object under the new name; a
  directory entry can vanish.
- **A3. The store** is durable when a put returns success. A put whose answer was lost may or
  may not have landed, so every store step is safe to repeat.
- **A4. One owner per domain** (P1). All of a domain's local state, including every queue log in
  this document, is written by exactly one process at a time, the domain owner. In-process
  concurrency inside the owner is serialised as [04](../04-checkout-cache.md) §3.2 specifies.
- **A5. Crashes** happen between any two steps: process kill (SIGKILL, OOM, Android freeze and
  kill) or power loss.
- **A6. Clocks.** Record ids use wall time only to sort roughly chronologically; correctness
  never depends on it. Backoff and deadlines use a monotonic clock (P5).

---

## 3. Persistence rules (P2)

### 3.1 Two durability levels

| Level | Survives | Promised by |
|---|---|---|
| **Visible** | process crash | the object is in the filesystem (written, or renamed into place) |
| **Durable** | power loss | the object's data and its directory entry have been fsynced |

Every acknowledgement names its level (§6). A **write** to a file promises *visible*, which is
what a local filesystem's `write` promises. A **sync** (`fsync` on the mount), a **close** of a
modified file, a namespace operation, a pin and every command's success promise *durable*.

### 3.2 Primitives

Every write of an authoritative local object (the classes in
[data-model/local-cache.md](../data-model/local-cache.md) §6) uses one of these primitives.

| Primitive | Steps | Leaves after power loss |
|---|---|---|
| **Durable replace** `(path, bytes)` | write a temp file in the same directory (temp naming: [01](../01-core.md)); fsync the temp; rename it over `path`; fsync the directory | the old object or the new one, whole |
| **Replace** `(path, bytes)` | as durable replace without the final directory fsync | the old object or the new one, whole (never torn, because the temp's data was synced before the rename) |
| **Durable create-if-absent** `(path, bytes)` | write and fsync a temp; hard-link it to `path` (EEXIST means another creator won: read the winner); unlink the temp; fsync the directory | the winner's object, whole, or nothing if the link itself was not synced and nobody depended on it |
| **Durable directory** `(path)` | create each missing component; fsync the parent of every component created | the directory chain |
| **Durable append** `(file, line)` | one `write` of a complete, newline-terminated line; fsync the file (and its directory when the file was just created) | every fully appended line; a torn last line, which readers skip |
| **In-place data** `(file, offset, bytes)` | positional write; made durable later by fsync of the file (and of its directory if the file was created since the last durability point) | data up to the last fsync; after it, any mix of old and new blocks |
| **Release** `(path)` | unlink | the object may reappear after power loss unless the directory was fsynced |

- An implementation MAY group several durable steps under one set of fsyncs (**group
  commit**): fsync all the temps, rename them all, fsync each directory once. Every
  acknowledgement waits for the group's fsyncs. A filesystem-wide flush (for example `syncfs`)
  MAY replace the per-object fsyncs of a group.
- An authoritative object MUST NOT be written by any other means (no truncate-and-rewrite in
  place, no rename of an unsynced temp over it).
- Directories that hold authoritative state MUST be created with owner-only permissions (0700);
  files in them MUST be created 0600 and never widened.

### 3.3 Ordering rules

- **R1. Durable before acknowledged.** Every object an acknowledgement relies on reaches the
  level the acknowledgement promises before the acknowledgement is given. Enqueueing in memory
  is only a hint.
- **R2. Referent before referrer.** An object that names another (a staged manifest naming a
  body, a WAL record naming a staged edit, a mirror entry naming the manifest promotion
  produced, a record state claiming an effect) reaches a durability level only after every
  object it names has reached that level.
- **R3. Switch before release.** A referent is released only after every referrer that named it
  has durably switched away. In-memory referrers count: an open read handle, a running job. When
  a later step relies on a release having happened (a referent's name being reused, a sweep
  concluding something is gone), the release's directory is fsynced before that step.
- **R4. Intent before effect.** A record that announces an effect not yet performed is durable
  before the effect begins.
- **R5. Effect before claim.** A record state that claims an effect (a WAL record reaching
  Prepared or Executed, an applied-log line, a completed job) is written only after the effect
  is durable: local effects fsynced, store effects acknowledged by the store.
- **R6. Unparseable is not absent.** A reader of an authoritative object distinguishes three
  outcomes:
  - **absent**: the name does not exist;
  - **unreadable**: an I/O error (EMFILE, EIO): the object is left in place and the step fails
    with TRANSIENT/LOCAL ([failure-model](failure-model.md) §3.1);
  - **unparseable**: the bytes do not decode, or decode to something this reader does not
    fully understand (a newer version, an unknown op). The object is **set aside**: renamed to
    its set-aside name (spelled in [04](../04-checkout-cache.md) §2), which no reader decodes, never decoded into
    something it does not mean, never deleted automatically, and reported by status as a
    degraded condition. A set-aside object still counts as a referrer under R3, so everything
    it names is kept. Only an explicit user request removes set-aside objects.

---

## 4. The durable queue

### 4.1 Structure

- A **log** is one directory. It holds one file per **record** and nothing else except temps
  and set-aside records.
- A record's file name is its **id**: a string over `[0-9A-Za-z-]` that begins with a digit.
  Ids sort lexicographically in creation order. Readers list only names that match this
  grammar exactly, so temps (which begin with `.`) and set-aside records (which contain a `.`)
  are skipped.
- A record's body is the job, in the encoding its **job kind** defines. The queue never
  interprets the body; the job kind's decoder answers job, or unparseable (R6).
- **Record-id format** (owned here). A **submission id** is
  `<20-digit microseconds since the epoch>-<8-digit sequence>-<decimal pid>`, the sequence
  breaking ties within one microsecond, per process and log. The WAL's own records are named by
  entry keys ([03](../03-journal-sync.md) §2.2), which only the owner mints; a record a non-owner
  submits to the WAL carries a submission id, and the owner **re-keys** it to a fresh entry key
  when it adopts it, by one atomic rename ([04](../04-checkout-cache.md) §2.8). Every other log
  names all its records by submission ids. The owner's own posts get strictly increasing ids
  within a log.
- **Lock files** (owned here). A log has no claim file: the domain ownership lock is the claim
  ([07](../07-daemon-cli.md) §2.3). A submitter's hold (§4.2) is an exclusive advisory lock on
  the record file itself, of the kind required by §2 A1. Files beside a log directory, and files
  inside it that are not records, are not part of the log and are ignored.
- Every new record, the owner's or a submitter's, is created by durable create-if-absent
  (§3.2), minting a new id on EEXIST, so no writer ever replaces a record it did not create.
  Updates use durable replace. Records are completed by release.

### 4.2 Ownership

- **A log belongs to its domain's owner.** Only the owner lists, reads, updates, runs,
  completes or sets aside a record. There is no per-log claim: the domain ownership lock (P1,
  [07](../07-daemon-cli.md) §2.3) is the claim, for every log of the domain.
- The owner is every log's only **resumer**: it starts every log of its domain at ownership
  start, with recovery, and loads the records on disk in id order before accepting new posts on
  that log. The logs of a domain are its WAL, its deferred job logs (one per replica or backfill
  target) and its pending folder-claim confirmations ([04](../04-checkout-cache.md) §2.9).
  Owners settle their logs on exit, bounded by the grace. When a one-shot command
  becomes the owner, it runs every log of the domain, not only its own posts.
- **Submission** (the only write a non-owner makes to a log, [07](../07-daemon-cli.md) §2.2).
  A process that is not the owner MAY add a new record to a log:
  - it mints a submission id (§4.1) and creates the record with durable create-if-absent
    (§3.2), minting a new id on EEXIST; it never replaces, updates or removes
    a record;
  - it MAY hold an exclusive advisory lock on its record file for as long as the record must
    not run yet (a bulk publisher holds it until the manifests its record announces are on the
    store, §7.3); the lock dies with the submitter;
  - it then pokes the owner ([07](../07-daemon-cli.md) §4.6).

  Submitters are the non-owner writers of [07](../07-daemon-cli.md) §2: the store server
  records deferred replica and backfill jobs caused by writes it accepted, and store- or
  publish-class commands record deferred jobs and WAL batch records (§7.3).

  The owner adopts submitted records by rescanning the log at ownership start, on a poke, and
  every `REARM_INTERVAL`. It runs a submitted record only after taking that record's lock
  without waiting; a record whose lock is held is skipped until a later rescan.
- **Release order.** Submitted records are adopted, and WAL records re-keyed, in the order the
  submitter released them: a submitter MUST create its records in the order it wants them
  published and release their locks in that same order (hence in id order), and the owner adopts
  a submitter's records in id order, never adopting one while a lower id of the same submitter
  (same pid in the id) is still held. A bulk publisher that releases its folder records before
  its file records therefore has the folder ops published first. Across submitters, and against
  the owner's own posts, a submitted record may run after records with later ids, so only
  order-insensitive job kinds (§4.7) accept submissions.
- Several queues MAY run over one log when each takes a disjoint subset of records by a
  predicate over the decoded job (the WAL's metadata and upload queues:
  [wal-and-journal.md](wal-and-journal.md) §4.2).
- A record whose job belongs to another client (a WAL record under another client uuid) is
  never run, never deleted, and reported by status.

### 4.3 Operations

```
post(job):                     # the only acknowledgement path for new work
  with recording_mutex(log):
    id := mint()                          # again on EEXIST
    durable_create_if_absent(log/id, encode(job))
    if backlog_on_disk(log): return       # the runner will load it in id order (§4.4)
    take(id, job)
  return                                  # the caller may acknowledge now (R1)

adopt(id, job):                # the record already exists (recovery, rearm)
  with recording_mutex(log): if id ∉ loaded: take(id, job)

update(id, f):                 # read-modify-write of one record
  with record_mutex(id):
    body := read(log/id); if absent: return      # completed meanwhile: never resurrect
    durable_replace(log/id, encode(f(decode(body))))

complete(id):  release(log/id)
set_aside(id): rename log/id → set-aside name; report
```

`take` puts the record in memory: into the run order (ordered queue), or into the key's slot
(keyed queue, §4.5).

### 4.4 Never bounded loss

- How many records a runner holds in memory is the implementation's choice (P6). Whatever it
  holds, records run in id order (ordered queues), and records it has not loaded stay on disk
  until it loads them.
- A queue MUST NOT refuse, drop or skip writing a record because of its length. The length of
  a log is bounded only by the owed work itself (a long outage grows it, by design). A job kind
  MAY declare a threshold past which its target is reported degraded
  ([replication.md](replication.md)); crossing it changes the report, not the records.

### 4.5 Ordered and keyed queues

| | **Ordered** | **Keyed** |
|---|---|---|
| Workers | exactly 1 | any number, at most one running job per key |
| For | effects that do not commute across jobs | independent keys, where the newest state of a key supersedes older jobs for it |
| Transient retry | at the **head**: nothing recorded later overtakes a failing job | at the **tail**: one failing key never stalls others |
| Coalescing | none: every record runs | a new post for a key with a running job sets that job's cancel flag and replaces any pending job for the key; the replaced pending record is completed |
| Used by | metadata publishing; deferred replica and backfill jobs | uploads, one key per file |

Keyed coalescing is sound only for **bodyless** jobs: the job reads the key's current state
when it runs, so the newest record fully describes what is owed, and completing a superseded
record loses nothing. Resumed records of one key are coalesced the same way as posts.

### 4.6 Outcomes

A job run ends in exactly one outcome. The job kind maps its failures to kinds with the rules
of [failure-model.md](failure-model.md) §5; the queue acts on the kind only.

| Outcome | Queue action |
|---|---|
| **Done** | complete the record; reset the failure count |
| **CANCELLED** (no longer wanted) | complete the record; not a failure |
| **STOPPING** | leave the record on disk and in no memory; not a failure |
| Retryable kind (TRANSIENT/*, UNREACHABLE, DEADLINE) | note the failure in the record (`update`); wait `BACKOFF(n)` (stop-aware); requeue (ordered: head; keyed: tail) |
| Non-retryable kind (ABSENT, EXISTS, REFUSED, INVALID, CORRUPT, UNPREPARED, UNEXPLAINED) | note the failure; **park** (§4.7) |

For an ordered queue, UNEXPLAINED is non-retryable: a local bug at the head would otherwise
block every later record forever.

### 4.7 Parking and retry of parked records

- A **parked** record stays on disk with its failure noted (attempt count, last kind, detail)
  and leaves the run order. In an ordered queue, later records then run past it: parking trades
  order for liveness, so one refused record cannot block a client for hours.
- Parked records are **retried**, each re-adopted once per trigger, by every queue (ordered and
  keyed alike):
  - at ownership start;
  - every `REARM_INTERVAL` while the owner runs;
  - when the user asks (the retry command of [07](../07-daemon-cli.md));
  - when the failure's cause is known to have cleared (for a REFUSED on a target, a
    configuration change of that target).
- Status reports every parked record with its last failure, and the owner's report is degraded
  while any is parked. A job kind MAY also keep a durable marker of that condition; the deferred
  job logs do (the copy is marked degraded while any of its jobs is parked,
  [replication](replication.md)).
- Because a parked record may run after records posted later, **every job kind that can be
  parked MUST be safe to run after any later job of its log**: it re-derives its effect from the
  current state of its source and target rather than replaying a stale effect. Each job kind's
  owner states how (§4.9).

### 4.8 Settle, stop and pause

- `settle(q)` returns when the queue is idle, is not running, a stop was requested, or has a
  failure noted since the settle began (the target is down: the work stays on disk).
  `settle_all(timeout)` settles every queue of the owner concurrently, bounded by
  `SETTLE_TIMEOUT` (by the remaining grace while stopping).
- `stop`: workers take no new job; a running job is allowed to finish up to the grace, and a
  process-wide stop makes every wait inside a job end with STOPPING. Stop never cancels a job
  (cancellation would be CANCELLED and complete a record whose work is still owed).
- `pause` keeps workers from taking jobs and changes no record. The pause state is persisted by
  the owner and read at owner start before any queue starts ([07](../07-daemon-cli.md) §2.6); a
  queue started while paused loads its records and runs none. A command's drain runs its queues
  only when the domain is not paused.
- A one-shot command that owns a domain settles its queues before exiting. Records still owed
  stay on disk; the command reports their count, and the next owner of the domain runs them
  (§6, E16).

### 4.9 At-least-once: what makes each job kind idempotent

A job may run twice: a kill between its effect and its completion, a retry after a partial
effect, a parked record re-adopted. Each job kind MUST reach the single-run end state when
repeated and when run after later jobs of its log. The owner of the mechanism is named.

| Job kind | Requirement | Mechanism owned by |
|---|---|---|
| Upload of a file (keyed) | content-addressed chunks skip what exists; the manifest put overwrites with the same body; the commit record is written before any local move, so a replay only promotes; every promotion step is idempotent; discharge publishes under the record's own key | [04](../04-checkout-cache.md) §4.6, [wal-and-journal.md](wal-and-journal.md) §4.2 |
| Put with no local staged edit (bulk publish, revert, recovery) | publishes an entry only for paths whose manifest the store holds; installs that manifest locally if absent | [04](../04-checkout-cache.md) §4.6 |
| Metadata publish (ordered) | re-reads its record (a conflict may have retargeted it); decides from store facts, so a repeat publishes nothing new | [conflict-resolution.md](conflict-resolution.md) §4.4 |
| Metadata local redo (Intent recovery) | removals by folder id; a rename only when the source is present and the destination absent; a mkdir writes an id final for life | [wal-and-journal.md](wal-and-journal.md) §4.7 |
| Deferred replica/backfill job (ordered) | bodyless: it brings the target's key to the source's *current* state (copy when present, delete when absent), so any order converges | [replication.md](replication.md) |
| Peer-entry application (not a queue) | per-op facts; noted handled only after every op's effects are durable | [wal-and-journal.md](wal-and-journal.md) §4.4 |
| GC step, GC discard job | phase saved before the step; deletes of absent keys succeed | [gc.md](gc.md) |
| Export chunk | a progress line is appended only after the chunk's bytes are fsynced | [05](../05-ops-config.md) |

---

## 5. Properties

- **S1. A record leaves the disk only when its work is done elsewhere** (Done, with the effect
  durable per R5), superseded by a newer durable record of the same key, or no longer wanted
  (CANCELLED). Stop, retryable failures, parking, unreadable records and unparseable records
  (set aside) all leave evidence. With §3, this holds under power loss.
- **S2. A record is run by at most one process**: only the owner runs a log (§4.2).
- **S3. Ordered queues preserve id order among records that succeed**, except that a parked
  record's later retry runs after records posted after it (§4.7).
- **S4. Keyed queues run at most one job per key**; failures requeue at the tail and back off
  per key.
- **S5. Duplicate runs are harmless** (§4.9).
- **L1. Every record on disk is eventually run to Done, or is parked, reported and retried**, as
  long as some process owns the domain and the target is eventually reachable. The backoff is
  capped, so a recovered link is noticed within one cap interval.
- **L2. Stop is bounded** by the grace; nothing owed is lost (S1).
- **L3. Commands do not hang on a dead target**: settle returns on the first failure and is
  bounded by `SETTLE_TIMEOUT`.

---

## 6. Acknowledgement points

"Evidence" is what is durable (or visible, for a write) when the acknowledgement is given. The
steps are specified by the file operations of [04](../04-checkout-cache.md) §3–§4.

| Action | Acknowledged when | Level | Evidence at that moment |
|---|---|---|---|
| Write, truncate, create of a file | the call returns | visible | staged bodies written; staged manifest replaced (§3.2 *replace*) |
| Sync (`fsync` on the mount) | the call returns | durable | the file's staged bodies fsynced, its staged manifest durable, their directories fsynced |
| Close of a modified file | the call returns | durable | as sync, then the WAL record `Prepared [Put]` durable |
| Whole-file handover (File Provider, Android) | the call returns | durable | the handed-over file adopted as a staged whole body and fsynced, staged manifest durable, WAL record durable |
| mkdir, rmdir, rename, delete, symlink | the call returns | durable | WAL record `Intent` durable before the local half; the local half's effects durable; the record `Prepared` durable |
| Pin ("make available offline") | the call returns | durable | every group whole and each pin durable ([read-path-and-cache.md](read-path-and-cache.md) §4.8) |
| Android share-sheet save, picker close | the app reports success to the platform | durable | every file handed over and closed as above, or its staging copy fsynced with a durable *ready* ingest intent that the next app start commits ([android](../frontends/android.md) §9.2) |
| Write to a domain with replica or backfill targets | the publishing step returns | durable | the mains hold the object and each target's deferred job record is durable ([replication.md](replication.md)) |
| Bulk publish (import, rsync), revert | the command returns 0 / the call returns | durable | every manifest put, every Put op recorded (§7.3) and discharged or durably owed |
| Any one-shot command | exit status 0 | durable | its effects, plus any owed remainder durable in the domain's logs (reported on exit) |

An action killed before its acknowledgement is not acknowledged: it may be absent after
restart, and it is never half applied (§8, property 2).

---

## 7. Crash-immunity inventory

### 7.1 Where owed work and unpublished data live

Every entry is consumed by the **domain owner** (P1) unless stated. "Rediscovery" is how a new
owner finds it at start.

| # | Evidence | Primitive | Rediscovery | Kill point → outcome |
|---|---|---|---|---|
| E1 | Staged body (group layout or whole file) | in-place data; fsynced at sync, close, handover | named by E2; the start-of-ownership orphan sweep releases bodies nothing names | Written, no manifest names it: the write was not acknowledged; released at start. Named by a manifest: kept. |
| E2 | Staged manifest, *Owed* or *Committed* | replace per write; durable at sync, close and state changes | owner start: Committed ones are promoted; Owed ones with no WAL record are adopted with a fresh `Prepared [Put]` | Replaced mid-write: old or new, whole. Committed, not promoted: promotion replays with no upload. |
| E3 | Set-aside staged manifest | rename (R6) | reported at start | Kept forever with every body it may name ([04](../04-checkout-cache.md) §4.10); never adopted automatically. |
| E4 | WAL record `Intent` | durable replace, before the local half | reconcile at owner start | Mid local half: local redo (idempotent), then Prepared. The local half failed: record completed, error returned (not acknowledged). |
| E5 | WAL record `Prepared` | durable replace, after the local effects are durable | reconcile; the queues' recovery | Put with an Owed edit: uploads. Put with a Committed edit: promotes and discharges. Put with no staged edit: §7.3. Metadata: republished by the ordered queue. |
| E6 | WAL record `Executed` | durable replace, after the store half and before promotion | reconcile | Publishes the entry if the store lacks it, then completes ([wal-and-journal.md](wal-and-journal.md) §4.7). |
| E7 | Parked records (any log) | the record itself, with its failure noted | loaded at owner start and retried (§4.7) | Survive any kill; retried at start and every `REARM_INTERVAL`. |
| E8 | Deferred replica/backfill job log | durable replace per job, before the main write is acknowledged | loaded at owner start (every owner, including a one-shot command and the Android app) | Killed before running: run by the next owner. |
| E9 | Queue memory, upload slots, cancel flags | volatile | rebuilt from E4–E8 | Lost on kill; harmless. |
| E10 | Cursor debounce | volatile | none | Kill inside the debounce window: peers learn of the entry by their periodic listing. Latency only. The owner flushes it on stop and SHOULD flush when the host signals imminent suspension. |
| E11 | Applied log ([03](../03-journal-sync.md)) | durable append: own entries before the journal put; peer entries after their effects are durable | read at owner start | A line never claims an effect that is not durable. A lost own line after a kill is written again by the record's discharge. |
| E12 | Last-sync mark, resync generation | durable replace | read at start | Old or new value, whole. |
| E13 | Client uuid | durable create-if-absent | read at start | Never lost once any record carries it. |
| E14 | Folder-id lease | durable create-if-absent before the first id of the block is used | none needed | A kill wastes the rest of the block; ids stay unique. |
| E15 | Export progress record | owned by [05](../05-ops-config.md): header first, a line per chunk after the chunk is fsynced | a re-run of the export | Every kill point resumes. |
| E16 | Owed work left by a one-shot command | E4–E8 | the next owner of the domain (daemon or next command) | Nothing is lost; the command reported it on exit. |
| E17 | GC run marker and lock, GC discard and verify jobs | owned by [gc.md](gc.md) | the next collection | Resumable; see gc.md. |
| E18 | Android staging copies and ingest intents (share sheet, picker, camera) | owned by [android](../frontends/android.md) §9: copy fsynced, intent durable before success is reported | the next app start commits every *ready* intent | Before the intent is ready: not acknowledged; copy and intent discarded. Ready, not committed: committed at start. Committed: E1–E5. |
| E19 | Android camera-backup records | owned by [android](../frontends/android.md) | the backup worker | A photo is marked done only after its close was acknowledged; failed and unsettled photos are retried. |
| E20 | Cache bodies and pins | whole bodies: data fsynced before the rename that installs them; pins: durable create | the cache walk at owner start | A partial body is discarded at start; a whole body is whole; a pin survives ([read-path-and-cache.md](read-path-and-cache.md) §6). |
| E21 | Locally written configuration | owned by [05](../05-ops-config.md): durable replace | read at start | Old or new config, whole. |

### 7.2 Kill-point walkthrough: a file edit from write to published entry

Steps of [04](../04-checkout-cache.md) §4.3–§4.6, in order. Every kill point leaves one of the
listed states, and each state recovers without losing an acknowledged action.

| # | Step | Kill just after → state at restart → recovery |
|---|---|---|
| W1 | stage group body bytes (in-place data) | unacknowledged bytes in a body nothing new names; the previous manifest still names what it named → the orphan sweep releases unnamed bodies |
| W2 | replace the staged manifest (acknowledges the write) | new manifest, visible → adopted at start with a fresh `Prepared [Put]` |
| W3 | release bodies the new manifest no longer names, after the manifest is durable (R3) | orphans at worst → swept |
| C1 | sync: fsync bodies, durable staged manifest | as W2, durable |
| C2 | WAL `Prepared [Put]` durable (acknowledges the close) | reconcile resumes the upload |
| U1 | upload chunks and the manifest (GC interlock, [gc.md](gc.md) §4.4) | Prepared + Owed edit → upload again (existing chunks are skipped) |
| U2 | durable replace of the staged manifest as *Committed* | Prepared + Committed → promote, then discharge; no upload |
| U3 | WAL record → `Executed` (durable) | Executed + Committed → promote at start; reconcile publishes |
| U4 | promotion: cache groups, durable mirror entry, release of the staged manifest (directory fsynced), release of bodies | any sub-step: the Committed manifest replays the promotion idempotently; after the manifest's release, only orphan bodies remain → swept |
| U5 | discharge: applied line, journal put, cursor note, record release | per [wal-and-journal.md](wal-and-journal.md) §4.2 |

### 7.3 Kill-point walkthrough: publishing without a local staged edit

Bulk publishers (import, rsync), revert and the recovery of a Put whose staged edit is gone use
one rule, so that a manifest on the store is never left unannounced:

1. Durably record a WAL record `Prepared` listing the batch's Put ops **before** the first
   manifest put. A publisher that is not the owner submits this record (§4.2) and holds its lock
   until step 2 is over.
2. Put the chunks, then the manifests (GC interlock).
3. Install each manifest in the mirror if the mirror lacks that path, durably (the owner does
   this; a submitter leaves it to the owner).
4. Discharge (the owner; a submitter's acknowledgement is the durable record plus the manifests
   on the store, and the owner publishes the entry).

Recovery of a `Prepared` Put op with no staged edit asks the store whether a manifest exists at
the op's path: if yes, it ensures the mirror holds a manifest for the path (fetching the store's
if the mirror has none) and publishes the op; if no, the op is dropped from the record; if the
store cannot answer, the record stays owed (TRANSIENT). A Put entry for a manifest that exists
is always harmless, because a Put tells peers to fetch the current manifest
([wal-and-journal.md](wal-and-journal.md) §3.1). The mechanism of that recovery is owned by
[wal-and-journal.md](wal-and-journal.md) §4.7; this section owns the requirement.

### 7.4 Kill-point walkthrough: a namespace operation

| # | Step | Kill just after → recovery |
|---|---|---|
| M1 | WAL `Intent` durable | local redo of the op (idempotent), then Prepared |
| M2 | local half (mirror, staged moves, folder index), each effect made durable | as M1: the redo finds each effect already there |
| M3 | WAL `Prepared` durable (acknowledges the call) | the metadata queue publishes |
| M4 | publish decision, store effects, `Executed`, discharge | per [wal-and-journal.md](wal-and-journal.md) §4.2 |

---

## 8. Conformance

An implementation MUST exhibit these properties. [09](../09-tests.md) specifies how they are
checked (kill-point enumeration over every labelled durable step, a store variant that lands a
put and loses its answer, power-loss states generated from the fsync barriers, kills inside
recovery, and multi-process runs).

After any sequence of acknowledged actions interrupted by kills or power losses at any step,
followed by restarts and quiescence (store reachable, owner started, queues settled, one peer
applying the journal):

1. **No acknowledged action is lost.** Each acknowledged action's effect is visible in the local
   view, on the store and in the peer's view, or it was superseded by a later acknowledged
   action, or its bytes survive in a conflicted copy
   ([conflict-resolution.md](conflict-resolution.md) §5.1). For a write acknowledged only at the
   *visible* level, this holds for kills of the process and not for power loss.
2. **Unacknowledged actions are atomic.** Each is fully applied or absent: no torn file, no
   rename that leaves both names or neither.
3. **Nothing owed remains**, except parked records, which are reported: the logs are empty, the
   staged tree is empty, no Committed staged manifest remains.
4. **Convergence.** The local view, the main store, the peer's view and every replica (minus
   excluded keys) agree; every manifest on a replica has all its chunks.
5. **Idempotence.** The final state equals that of the same actions run without a crash.
6. **Visibility.** Every set-aside object and every parked record shows in status.
7. **Single runner.** No record is run by two processes, and an ordered log's records that
   succeed take effect in id order, except for re-adopted parked records. A log is run only by
   the domain owner; after the owner dies, the next owner runs it, in order, once per record.

At the level of one queue:

- Records persist across a restart; adopting a record already held is a no-op.
- An unparseable record is set aside and makes the queue report degraded; an unreadable one is
  left in place and retried; one that vanished (completed meanwhile) is skipped silently.
- A submitted record whose submitter still holds its lock is not run; once the lock is free it
  is run.
- A queue with queued jobs and no outcome for `STALL_WARNING` warns that it is stalled.
- A paused queue runs nothing; its records stay on disk and are loaded.
- A stop wakes every backoff sleep and link wait at once; they end with STOPPING, which is never
  counted as a failure and leaves the record on disk. A stop that finds a stuck job gives up at
  the grace without cancelling it.
- A parked record is retried at the next rearm, and a job that then succeeds is completed.

---

## 9. Parameters

| Name | Recommended | Constraint / effect |
|---|---|---|
| `BACKOFF(n)` | min(300 s, 0.5 s · 2^min(10, n−1)) | the cap bounds how late a recovered target is noticed |
| `REARM_INTERVAL` | 60 s | MUST be finite: parked records are always retried |
| `SETTLE_TIMEOUT` | 60 s (the remaining grace while stopping) | how long a command waits for its own jobs |
| `STALL_WARNING` | 60 s | warn when jobs are queued and no outcome happened |
| `GRACE` | 10 s | the stop budget; MUST fit the host supervisor's kill deadline with margin |
| Ordered workers | 1 | MUST be 1 |

---

## 10. Rationale

| Choice | Reason |
|---|---|
| One file per record | Completion is a release; listing can skip loaded ids by name without reading bodies; an I/O error is local to one record. An embedded database with the same states and durability is an acceptable encoding. |
| The domain ownership lock is the only claim | Per-log claims taken by some processes and checked by others let two processes run one log, which ran a job three times and reordered an rmdir/mkdir pair. One owner makes every record's writer unique, so a record update cannot resurrect a completed record. |
| Park, never drop | A dropped record is owed work gone silently; a parked one is visible and retried. Parking must not block the log, so parked jobs are made order-insensitive instead. |
| Head retry for ordered, tail retry for keyed | A later mkdir once overtook the rmdir it followed; a failing upload must not stall other files. |
| Stop races the grace rather than cancelling | Cancellation completes records whose work is still owed. |
| fsync the temp before every replace | Without it a power loss can leave a zero-length object under the final name, and an unparseable authoritative object costs the user a manual recovery. |
