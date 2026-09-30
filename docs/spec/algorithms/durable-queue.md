# Durable queue and crash/restart immunity

This document describes two things. The first is the durable work queue, as an abstract data
structure and protocol. The second is how the whole application uses it and its siblings (the
WAL, staged data, job logs, run markers) to be immune to crashes and restarts.

The goal is this: **no acknowledged user action is lost, and all owed work completes after any
restart, whatever the kill point.** Sections 1–9 are implementation-independent. Section 10 is the
only place with concrete names. The WAL record state machine and reconcile are specified in
[wal-and-journal.md](wal-and-journal.md) §4.1 and §4.7. This document relies on them and does not
repeat them.

Finding IDs (F*, G*, H*) are from [findings.md](../findings.md). Gaps found during this reading
are labelled Q1–Q9. They were checked against the code but are not in findings.md, and no test
covers them.

---

## 1. Problem and goals

Every piece of work the system owes is created in one place (a user's write, a rename, a
command's publish) and finished somewhere else, later (an upload, a journal publish, a replica
copy). The finishing needs a network that may be down for days. Meanwhile the process may be
SIGKILLed, frozen by Android, OOM-killed, stopped by systemd with a 10 s budget, or lose power.

**Goals.**

- **G1 — No acknowledged action is lost.** Once the system tells a caller that a mutation
  happened, durable evidence of the owed remainder exists. "Told" means a FUSE call returned, a
  bridge call answered, or a command exited 0. The evidence must survive any later kill.
- **G2 — Owed work completes.** After any restart, every piece of owed evidence is rediscovered
  and driven to completion, or to an explicit, visible abandonment. Nothing waits on a human
  remembering.
- **G3 — At-least-once, never harmful twice.** Replay may run a job more than once, including
  concurrently across processes. The end state must equal a single run.
- **G4 — Order where it matters.** Operations whose effects do not commute (a rename's copy and
  delete, a rmdir followed by a mkdir of the same name) take effect in recorded order. Operations
  on independent keys must not block each other.
- **G5 — Bounded stop.** A stop finishes within a fixed grace. Whatever it leaves is owed on
  disk, not lost.
- **G6 — Visible failure.** Work that cannot complete is reported (degraded, parked, stepped
  aside), never silently dropped.

**Non-goals.** Exactly-once execution. Durability of work nobody acknowledged: a write in
progress when the kill came may be absent, but it must never be half-applied. Surviving loss of
the local disk (then the store is the truth, and the `mirror` or rebuild commands recover).
Cross-machine transactions.

---

## 2. System model and assumptions

- **A1 — Local filesystem.**
  - A single-file rename within one directory is atomic with respect to process crash.
  - Unlink is atomic.
  - `O_CREAT|O_EXCL` and `link` are atomic create-if-absent.
  - Appends of one small write are not torn by a process crash, but may be torn by power loss.
  - **Without fsync, nothing survives power loss in any particular order.** A rename may reach
    disk before the data of the renamed file, leaving a zero-length or garbage file under the
    new name. A directory entry may be lost entirely. With `fsync(file)` before the rename and
    `fsync(dir)` after it, the new name and its contents survive together.
- **A2 — Advisory locks** (`lockf`/`flock`-style) are held per process and dropped by the
  kernel when the holder dies. Within one process, two locks on the same file merge, and closing
  *any* descriptor to it drops them all. Locks are unreliable on network filesystems.
- **A3 — The store** (backend) is durable at the moment a put returns success. A put whose
  answer was lost may or may not have landed, so every store operation must be safe to repeat.
  Store-side conditional create (`put_if_absent`) exists.
- **A4 — Processes.** Several processes of one machine share one data directory and cache root:
  - the daemon's converging parent;
  - frontend children, forked from the parent;
  - one-shot CLI commands, including ones run while the daemon runs;
  - on Android, one app process with no stop and no drain.

  In-process mutual exclusion does not extend across processes.
- **A5 — Crashes** can happen between any two durable steps. Power loss additionally undoes
  any unsynced step (A1).
- **A6 — Clocks** are used only to name records in roughly chronological order and to time
  backoffs. Correctness never depends on them.
- **A7 — Stop.** A stop request is a process-wide flag. Waits give way to it (as an error
  distinct from cancellation). Work already running is allowed to finish, up to the grace.

---

## 3. State

### 3.1 The queue's own state

**Durable, per log (one directory per queue instance, meaning per domain, per target):**

- **Records.** Each record is one file.
  - Its name is the record **id**. Ids sort lexicographically in creation order: fixed-width
    time, then a per-process counter, then the process id. The id may instead be a
    caller-supplied key that sorts the same way (the WAL uses the journal entry key).
  - Its body is the job, in the job owner's encoding. The queue never interprets the body.
- **Claim lock**, beside the directory (not in it, so that the directory holds only records).
  Its holder is the process that holds this log's records in memory.

**Volatile, per queue instance, per process:**

- `jobs`: the in-memory run order.
- `loaded`: the set of ids this process holds, whether queued, running, or pending
  replacement.
- Keyed variant only: `slots` maps key → {cancel flag, pending replacement, failure count},
  and `active` maps key → running entry.
- Counters: `parked`, `outcomes`, `failures`.
- Flags: `degraded`, `paused`, `stopping`.
- A **recording mutex**, which makes id order equal queue order.

**Process-wide:**

- The set of logs this process has claimed.
- The list of queues that recover (the rescan list).
- The list of settle functions.

### 3.2 Everything else that carries owed work

This is the inventory of §6.1. It includes staged bodies and sidecars, WAL records by state,
deferred replica/backfill job logs, the cursor debounce, the applied log, the last-sync mark,
folder-id leases, the export record, the GC run marker and lock, GC discard jobs on the store,
the import publish spool, and Android staging files and camera-backup records.

---

## 4. The algorithm

### 4.1 Record lifecycle

```
            post / record (durable write)            adopt (already durable)
  (none) ───────────────────────────────▶ ON DISK ◀────────────────────────── caller wrote it
                                            │
                  take (in memory, under recording mutex; id ∈ loaded)
                                            ▼
                                         QUEUED ──pop──▶ RUNNING
                                                            │
     Done ────────────────────▶ unlink record (complete), id ∉ loaded
     Stopping ────────────────▶ stays ON DISK, leaves memory (owed to the next start)
     Transient ───────────────▶ backoff sleep, then requeue (ordered: HEAD; keyed: TAIL)
     Permanent, poison=Drop ──▶ unlink record, degraded := true
     Permanent, poison=Stop ──▶ stays ON DISK, removed from loaded (re-adoptable), degraded
     Superseded (keyed) ──────▶ the pending replacement takes the key; the old record is unlinked
```

**Operations:**

```
post(job):                         # the only acknowledgment path for new work
  if |jobs| ≥ MAX_QUEUED: degraded := true; log once; return    # runaway backstop: job NOT written
  with recording_mutex:
    id := mint_id()
    durable_write(dir/id, encode(job))       # atomic replace; must be fsynced, see §4.7
    take(id, job)
  return                                      # caller may now acknowledge

record(job):                       # write-only, for a log another process runs
  with recording_mutex: durable_write(dir/mint_id(), encode(job))
  notify_runner()                             # advisory poke; periodic rescan is the backstop

adopt(id, job):                    # the caller already wrote the record
  if |jobs| ≥ MAX_QUEUED: return              # record stays on disk; next recovery takes it
  with recording_mutex: if id ∉ loaded: take(id, job)

take(id, job):
  loaded += id
  ordered: push(jobs, (id, job))
  keyed:   k := key(job)
           if k has no slot: create slot; push
           else: slot.cancel := true                         # running job should stop early
                 if slot.pending: complete(slot.pending.id)  # superseded, unlinked
                 slot.pending := (id, job)                   # newest wins

cancel(k):                         # keyed only: the caller has made the work moot
  slot.cancel := true; complete(slot.pending); slot.pending := none
```

**Worker loop.** Ordered queues have exactly 1 worker. Keyed queues have W workers.

```
loop:
  if STOP requested: return                                  # leave everything on disk
  if (jobs empty or paused) and not stopping: park; wait(wake); continue
  if jobs empty: return                                      # a draining queue is done
  e := pop(jobs); keyed: active[key(e)] := e
  outcome := run(e.id, e.job, cancel_flag_of(e))             # catch everything
  keyed: remove active[key(e)]; outcomes++
  case outcome:
    Done               → reset failures; complete(e.id)               # unlink
    Stopping           → nothing (still owed on disk)
    classify = Transient → failures++; sleep(backoff(failures)) (stop-aware); requeue := true
    Permanent          → degraded := true; poison(e)
  keyed and slot.pending: slot.cancel := false; push(slot.pending); slot.pending := none
  elif requeue and not stopping: ordered → push_front(e); keyed → push_back(e)
  elif keyed: drop slot
  broadcast(settled)
```

`classify` belongs to the job's owner, because only the owner knows which of its failures will
clear with time:

- Request-level work defaults an unknown error to Transient, so that work is never abandoned.
- Ordered work defaults an unknown error to Permanent, because a local bug at the head would
  block everything behind it forever. Only errors tagged by the retry ladder around a store
  request keep their kind.
- A stop is never a failure. A cancellation ("no longer wanted") means Done-without-effect, and
  the job's own `run` completes the record.

### 4.2 Ordered vs keyed

| | **Ordered** | **Keyed** |
|---|---|---|
| Workers | exactly 1 | W (≥ 1), at most 1 per key |
| Requires | effects that do not commute across jobs (rename then create; copy then delete) | independent keys; within a key, the latest state supersedes |
| Transient retry | at the **head**: nothing recorded later may overtake a failing job (commit 5dcca235: a mkdir overtook the rmdir it followed and conflicted) | at the **tail**: one failing key must not stall the others |
| Coalescing | none; every record runs | a newer post for a busy key cancels the running job cooperatively and replaces any pending one |
| Permanent failure | Stop: park and let later jobs pass, which is a deliberate order break (see below). Drop: unlink and mark degraded. | Stop: the record stays, the slot is freed |
| Used for | metadata backend halves (Stop), deferred replica/backfill jobs (Drop) | uploads, one slot per file (Stop) |

**Why these choices:**

- **Keyed coalescing** is sound only because the job is **bodyless with respect to the key's
  state**. The upload job reads whatever is staged *now*, so the newest record fully describes
  what is owed. The superseded record may be unlinked, because the replacement is already
  durable.
- **Parking a permanent metadata failure** trades order for liveness. One `ENOTEMPTY` once
  blocked a client for 8 hours with about 1,900 entries behind it. Later ops publish past the
  parked one, and the conflict tables absorb the reorder. A periodic *rearm* re-adopts parked
  records.
- **Dropping in deferred replication** is safe because the replica can be rebuilt from the main
  (`mirror`). Waiting would block every later rename forever.

**Cross-queue dependency.** An upload may name a path that a queued rename creates, so a drain
runs the metadata queue *before* the upload queue. Peers apply entries in key order regardless
of publish order, so a crash between the two drains is harmless.

### 4.3 Ownership, claims, and rescan

Records are written *before* the work runs. A process that reads another process's log would
therefore take jobs the writer is about to run itself, which means a double run and, for ordered
logs, a reorder (c3c4f8cf: three processes each ran the same head job). The protocol:

```
role RUNNER (holds records in memory, never reads the log):
  on start(recover=false): try-lock(dir.claim) and hold it for the process's life.
      If another process holds it, run anyway without the claim: two commands against one
      target each run only what they posted.

role RESUMER (exactly one per log per machine; reads the log):
  on start(recover=true): register rescan; each worker rescans once before looping
  rescan():
    if this process already claims dir: return
    if try-lock(dir.claim) fails: return            # a live RUNNER holds records in memory
    with lock held:
      with recording_mutex:
        for (id, job) in list(dir) where id ∉ loaded, in id order:
          create slot (keyed); push                  # no coalescing on resume: each record runs
      release lock                                   # the lock is held only while reading

role RECORDER (writes jobs it will never run):
  record(job); poke the RESUMER (debounced)

list(dir, wanted):
  names := entries whose first character is a digit (anything else is a temp file, maybe live),
           filtered by wanted(id) BEFORE opening (so a rescan does not re-read what it holds), sorted
  per name: read →
     Gone        → skip silently (completed meanwhile)
     unparseable → dropped++, unlink, error log   (nothing can replay it; queue becomes degraded)
     read error  → warn, LEAVE                    (EMFILE or EIO says nothing about the record)
```

- **A dead process's claim is released by the kernel.** The next rescan (a poke, or the periodic
  one) adopts its records.
- **Rescan is triggered three ways:** at start, when a recorder pokes, and periodically as a
  backstop against a lost poke or a poke that arrived while a runner held the claim.

### 4.4 Settle, stop, and pause

- **`settle(q)`** waits on `settled` and returns when any of these holds:
  - the queue is idle;
  - the queue is not running;
  - a stop was requested;
  - **the queue has failures** (the target is down: warn, return, work stays on disk).
- **`settle_key(k)`** is the same wait, for one key's slot.
- **`settle_all(timeout)`** runs all settles concurrently, bounded by `SETTLE_TIMEOUT`. While
  stopping, the bound is min(timeout, GRACE). It warns on timeout. Commands call it before
  exiting, so that work they posted runs in-process when the link is healthy.
- **`stop(q)`** sets `stopping`, wakes the workers, and joins them.
  - A command's drain *runs what it holds* to completion.
  - When a process-wide stop is requested, workers return at once and leave the rest on disk.
  - The daemon races (not cancels) all drains against GRACE. Cancelling would surface as a
    permanent failure and mark queues degraded.
  - The queue half of each drain is raced against 0.8·GRACE, so the cursor flush and the other
    tail steps still run.
- **`pause`** parks workers without affecting records. It is volatile.

### 4.5 Execution is at-least-once

A job can run more than once:

- a crash between the effect and the unlink;
- a transient failure after a partial effect;
- a rescan racing a runner without a claim;
- reconcile and a live queue in two processes (§8);
- a resumed keyed record alongside a fresh post for the same key.

Every job must therefore be idempotent, *including under concurrent duplicate runs*.

| Job | What makes it idempotent |
|---|---|
| Upload (keyed, per file) | Chunks are content-addressed: a HEAD skips existing ones, so a re-upload sends 0 bytes. The manifest put overwrites with the same body. The staged sidecar's *committed* state is written before any local move, so a replay only promotes. Every promotion step is idempotent (hard link: EEXIST is fine; put-group: exists is a no-op). Discharge is Executed → entry put *under the record's own key* (an overwrite) → forward-only cursor note → unlink. Recovery of Executed asks the store (HEAD entry) first. |
| Metadata publish (ordered) | It re-reads the record, because a conflict may have rewritten its ops. Each op is resolved against store facts (already applied, nothing to move), so a repeat publishes nothing new. The entry goes under the same key. Empty resolved ops mean complete. |
| Metadata redo-local (recovery of Intent) | Removals go by folder id. Rename only if the source is present and the destination absent. Mkdir creates and writes an id that is final for life. |
| Intent with a put (recovery) | Ops touched by a newer peer entry are dropped. The put resumes under the same key, and only if staged data exists. |
| Deferred Put | Bodyless: it reads the *current* source body, or skips if the key is gone (a later Delete follows). It ensures every named chunk on the target, by shard listing, before putting the manifest. The put overwrites. |
| Deferred Copy | A copy is repeatable. If `src` is missing, it falls back to Put(dst). A stop mid-copy stays owed (5daf4206). |
| Deferred Delete / Delete-multi | Deleting an absent key succeeds. |
| Peer-entry apply (not a queue) | Per-op facts. The entry is noted handled only after all its ops applied. |
| GC step | The phase is saved before the step it names. The cursor is a *name*. Copies are deleted before the main. |
| GC discard job (bucket function) | Deleting an absent key is fine. Redelivery is safe. |
| Export chunk | The claim line is appended after the chunk's pwrite+fsync. A torn last line is ignored. |

Where at-least-once is **not** safe today: re-applying a pruned peer Delete (F4), cross-process
replica reordering (Q5), and a stale Intent published over a hidden peer entry (F6).

### 4.6 Acknowledgment points (where G1 attaches)

| User action | Acknowledged when | Durable evidence at that moment |
|---|---|---|
| Write/truncate of a file (FUSE, bridge) | the call returns | staged body bytes, then staged sidecar (atomic replace). No WAL record yet. |
| Close of a staged file | the call returns | WAL record `Prepared [Put]`, handed to the upload queue |
| Whole-file adoption (File Provider, Android) | the call returns (optionally after the upload starts or fails) | whole body renamed into the staged tree, then sidecar, then `Prepared` record |
| mkdir / rmdir / rename / delete | the call returns | `Intent` record written **before** the local half, rewritten `Prepared` after it |
| Write to a multi-member domain (any publisher) | the call returns | all mains hold the object, and each deferred target has **recorded** its job |
| One-shot command (import, rsync, export, sync, gc) | exit 0 | its own durable progress (published entries, export claims, GC marker). A killed command is *not acknowledged* and is resumed by re-running it. |
| Android share-sheet save | the activity closes (implicit) | staging copies only, **not yet adopted** (Q3) |
| Application fsync on the mount | the call returns | nothing extra: fsync is a no-op (Q6) |

### 4.7 Persistence requirements (abstract)

- **P1.** A record is durable **before** the operation that acknowledges it returns. Enqueueing in
  memory is only a hint.
- **P2.** Record creation and replacement are atomic: write a temp file in the same directory
  (named so readers skip it), then rename. A reader sees the old body or the new body, never a
  partial one.
- **P3.** Record update is read-modify-write. It must not resurrect a record that was completed
  concurrently. It needs one of:
  - a conditional replace (for example, rename only if the target still exists, done under a
    per-record lock);
  - a single owner per record, so that nobody else completes it.
- **P4.** Completion is an unlink, and it happens only after the effect the record names is
  durable *somewhere else*: on the store, or as a later record.
- **P5 — Power loss (F8).** Survive power loss as well as process crash:
  - `fsync(temp)` before the rename;
  - `fsync(directory)` after the rename, before acknowledging;
  - the same for staged bodies and sidecars before a close or write is acknowledged, and for
    completion unlinks where a lost unlink would cause a harmful replay. None of today's
    completions qualify: replay is idempotent.
  - Group commit (one directory fsync per batch of records) keeps the cost bounded.
  - Until this holds, the guarantee is "survives process crash" only.
- **P6.** A decoder must distinguish **unparseable** (drop, count, mark degraded) from
  **unreadable** (leave, retry). It must never decode garbage as a valid "do nothing" record.
  The WAL decoder violates this: a torn record decodes as an empty Intent, and reconcile then
  deletes it.
- **P7.** Garbage collection of data a record or sidecar references happens strictly **after**
  the reference is switched away durably (F9).

---

## 5. Properties and why they hold

**S1 — An acknowledged, recorded job is never silently lost.** A record leaves the disk in only
four ways:

- Done: the effect is durable elsewhere (P4).
- Superseded: a newer durable record covers the same key.
- Poison-Drop: visible as degraded, and the target is rebuildable.
- Unparseable: visible as degraded.

Stopping, transient failure, Poison-Stop and read errors all leave the record. A kill at any
point leaves either the record (replayed) or its completion (effect already durable). This holds
under process crash assuming P2. Under power loss it needs P5 (F8).

**S2 — A job is not run by two processes that both believe they own the log.** A resumer reads
the log only while holding the claim, and a runner holds the claim for life. This holds only if
exactly one process per log is a resumer (§8: G7, Q1, and the WAL, where the claim is taken but
never checked).

**S3 — Ordered queues preserve record order among jobs that eventually succeed.**
- One worker, retry at the head.
- The recording mutex makes id order equal enqueue order.
- Resume enqueues in id order and holds the mutex, so posts arriving during a resume queue
  behind what it found.
- Exception: Poison-Stop parks and lets later jobs pass (a deliberate liveness trade, §4.2).

**S4 — Keyed queues run at most one job per key.** Keys never block one another: failures
requeue at the tail, and backoff is per slot.

**S5 — Duplicate runs are harmless** by §4.5, except for the listed gaps.

**L1 — Every record on disk is eventually run, or visibly abandoned**, provided that:
1. some process with the resumer role for that log starts (for the WAL, a reconcile runs);
2. the target is eventually reachable;
3. the job's failure is transient.

The backoff is capped, so a recovered link is noticed within one cap interval. Rescan (poke,
periodic, start) closes the gap between a recorder's write and the resumer's memory.
Poison-Stop records are brought back by rearm (metadata) or by the next start (uploads, Q8).

**L2 — Stop is bounded.** Workers stop taking jobs on the flag. Backoff sleeps and link waits end
at once with Stopping. Drains are raced against GRACE, and the reaper SIGKILLs after GRACE+2 s.
Nothing owed is lost, by S1.

**L3 — Commands do not hang on a dead target.** `settle` returns as soon as a queue has failures,
and is capped by `SETTLE_TIMEOUT`.

**Worst interleaving, argued harmless: a runner and a resumer on one log.**
1. The runner posts record R; its claim is held.
2. The resumer's try-lock fails, so it skips.
3. The runner is SIGKILLed with R on disk.
4. The kernel drops the lock.
5. The next rescan takes the claim and adopts R in id order.

If the runner had completed R before dying, the resumer's `list` sees Gone and skips it. If the
runner died after the effect and before the unlink, the resumer re-runs R, which is idempotent
(S5).

---

## 6. Crash immunity of the system

### 6.1 Inventory: where owed work and unpublished user data live

"Consumer" is who may drive the evidence to completion. "Rediscovery" is how a restart finds it.

| # | Evidence (durable unless noted) | Protects | Consumer | Rediscovered by | Kill points and outcome |
|---|---|---|---|---|---|
| E1 | **Staged body** (group-layout sparse file, or whole-file body) | written bytes not yet uploaded | the process that owns the file's upload | named by E2; orphans reaped by age | Body written, no sidecar: an orphan, reaped after the grace. Correct, because the write was not acknowledged. |
| E2 | **Staged sidecar** (slots → bodies; *Owed* or *Committed* with the published manifest) | the file's unpublished content state | the upload job (via E3) | WAL reconcile; `adopt_unrecorded` (a sidecar with no record gets a fresh `Prepared [Put]`) | Sidecar present, no record (crash between write and close): adopted at start. *Committed*, not promoted: the replay promotes with no re-upload. Old body forgotten before the new sidecar is written: **lost edit (F9)**. Undecodable: set aside `.bad`, never decoded. The set-aside bodies are then reaped by the on-demand sweep (**F10**). |
| E3 | **WAL record, `Intent`** (metadata op, local half maybe partial) | the op, before its local half ran | reconcile, then the metadata queue | reconcile at start (parent, one-shot sync, Android) | Any point inside the local half: `redo_local` (idempotent), then `Prepared`. Local-half exception: the record is deleted and the error returned (not acknowledged). |
| E4 | **WAL record, `Prepared`** (local half done; backend half owed) | publication of a put or metadata op | upload queue (Put) or metadata queue | reconcile: `resume_put` if staged data or a symlink manifest exists, else complete; metadata goes to `resume_meta` | Between the upload's promotion (staged sidecar deleted) and `Executed`: **publication lost (Q2)**. Put with staged data gone (F9): abandoned as nothing owed. Torn by power loss: decoded as an empty Intent and deleted (**F8**). |
| E5 | **WAL record, `Executed`** (bytes and marker on the store; entry maybe not published) | the journal entry and cursor bump | reconcile | reconcile: HEAD the entry; publish if missing; complete | Either window is idempotent. The as-published (rewritten) ops are not persisted with `Executed`, so a crash here publishes the original ops (see wal-and-journal §8). |
| E6 | **Upload queue memory** (volatile) | nothing on its own; a cache of E4 | the process that holds it | rebuilt from E4 by reconcile | Lost on kill, which is harmless. A Poison-Stop upload record is not re-armed until the next start (**Q8**). |
| E7 | **Metadata queue memory + parked set** (volatile) | a cache of E4 | the process that holds it | reconcile at start; rearm every 60 s (daemon parent and Android only) | Rearm in the parent adopts `Prepared` records a frontend child is running or holding: **double run and reorder (Q1, F7)**. |
| E8 | **Deferred replica/backfill job log** (per domain, per target) | the copy of each main write onto a target | the resumer of that log (the daemon parent, or a one-shot for its own posts) | rescan: at the resumer's start, on a recorder's poke, and periodically | Recorded, then killed before running: adopted by the parent's next rescan. **Android never resumes (G7).** A one-shot that times out its settle with no daemon: never resumed (**Q4**). Queue full: the job is not written, and the target is marked degraded. Unparseable: dropped, degraded. Chunk forwards are unrecorded by design (the manifest job re-derives them). |
| E9 | **Cursor debounce** (volatile: newest noted key, timer) | the hint that tells peers to list the journal | the store wrapper, per process | none; flushed on drain | Kill inside the 2 s window (always the case on Android, which never drains): the cursor stays behind. **Latency only.** Peers find the entry by the 60 s sweep. |
| E10 | **Applied log** (positional; torn-tolerant appends) | dedupe of peer entries; the frontend change feed; own entries noted before publish | the poller / the store wrapper | loaded once per process | Noted but publish crashed: the record republishes under the same key (a duplicate line is possible). Prune by size drops in-window keys, so re-applied deletes can **remove a restored file (F4)**. |
| E11 | **Last-sync mark** (atomic rename) | "ever synced"; the rebuild decision | poller, sync | read at start | Atomic under process crash. Moved forward only. |
| E12 | **Folder-id leases** (`O_EXCL` empty files) | global uniqueness of minted folder ids | the minting process | none needed | A crash wastes the rest of a block. Safe. |
| E13 | **Client uuid** (link-to-create) | identity: the WAL lists only records carrying this uuid | all | read at start | Unsynced (F8). A lost file after power loss re-mints the uuid, and every existing WAL record becomes invisible to reconcile. They are never retried and never reported. Unlikely: this can only happen right after the first mint. |
| E14 | **Import/rsync publish spool** (journal ops batched ≤ 2000 ops / 10 s) | journal entries for manifests already on the store | the running command | none; reaped by dead pid | Kill before a batch is published: the manifests are on the store, but no entry names them. A re-run *skips existing keys without re-emitting their ops*, so peers never learn of them without a full rebuild (**Q9**). The command was not acknowledged, but a re-run does not repair this. |
| E15 | **Export record** (header written first; a claim line after each chunk's fsync) | resume of a partly exported file | a re-run of export | re-run: the header must match byte for byte, and the file must have full length | Every kill point is resumable. The record claims at most what the disk holds (fsynced). A torn last line is ignored. |
| E16 | **GC run marker (on the store) + lock file** | a collection in progress | the next `gc` | `gc` start: lock, then read the marker | The phase is saved before each step, and the cursor names the last finished unit. The kernel drops the lock on death, so the run can be resumed. Copies are deleted before the main. |
| E17 | **GC discard jobs, verify jobs** (objects on the store) | server-side deletes and verification | the bucket function | `outstanding` warns at `gc` start; `retry_outstanding` re-fires them | Idempotent under redelivery. |
| E18 | **Android staging files** (share sheet, picker, camera) | bytes copied out of another app, before adoption | the app flow that made them | **none**: swept after 24 h | Camera and picker: a kill before commit means not acknowledged, and a camera retry happens (subject to H7). Share sheet: the activity closes *before* the commits run. A kill then **silently loses the shared files (Q3)**. |
| E19 | **Camera-backup records + watermark** (SQLite) | which photos are uploaded | the backup worker | the next sweep | FAILED records and unsettled rows are never retried, because the watermark passes them (**H7**). |
| E20 | **Partial cache record** (strict parse) | which parts of a cache body are valid | readers | parsed on use | Torn means nothing is trusted. This is a cache, not owed work. |
| E21 | **Share manifest** (on the store) | a public link | nobody | not applicable | The put is the whole operation. |
| E22 | **Pause flag, change notices, stepped-aside table, handled set** (volatile) | hints and reports | the process that holds them | recomputed | Pause is lost on restart (G8). Notices are settled on drain; lost on kill they are only hints. The stepped-aside table is re-derived on the next pass. |

### 6.2 Who may consume what (the single-resumer rule)

| Evidence | Must be consumed by | Today |
|---|---|---|
| WAL records (E3–E5), staged tree (E1–E2) | **exactly one process per domain per machine** (the converger), or a per-record claim | Reconcile runs in the parent at start, in `tsync sync`, and on Android. Each presenting process runs its own queues over the shared directory. The claim on the WAL directory is taken by every runner and **checked by nobody** (reconcile and rearm ignore it). This is F7 and Q1. |
| Deferred logs (E8) | the resumer: the daemon parent, built with `resume`, started after the forks. Frontends only record and poke. One-shots run only their own posts. | As designed on the desktop. Android has no resumer (G7). A daemon-less CLI machine has none (Q4). |
| GC run (E16) | whoever holds the GC lock | Correct. Unsafe over a network filesystem (A2). |
| Export record (E15), import spool (E14) | the re-run of the command | Correct for export. The import re-run does not re-emit ops (Q9). |

### 6.3 Kill points where the guarantee fails today

| ID | Kill point | What is lost or broken | What a correct design must do |
|---|---|---|---|
| **F8** | power loss after any unsynced atomic write (WAL record, sidecar, deferred record, client uuid) | a torn or zero-length record or sidecar. The WAL decodes it as an empty Intent and deletes it. The sidecar goes to `.bad`, and then F10 reaps its bodies. Acknowledged work is lost. | P5: fsync the file, rename, fsync the directory before acknowledging. Stop decoding garbage as "nothing" (P6). |
| **F9** | a staged write that re-lays a group: the old bodies are forgotten, the new sidecar is not yet written | the sidecar names a deleted body. The upload hits ENOENT and treats it as "nothing owed", so **the whole staged edit is abandoned** | P7: write the new bodies, write the new sidecar, *then* forget the old bodies. Treat "bytes missing while a record and sidecar exist" as corruption to report, never as "nothing owed". |
| **F10** | the on-demand orphan sweep after a `.bad` set-aside | the bodies of the set-aside edit are unlinked | liveness of bodies = named by any sidecar, *including* unparseable ones (scan for body ids leniently), or never sweep while `.bad` files exist |
| **F7 / Q1** | the parent's rearm (every 60 s) or reconcile (at start), and a one-shot sync's reconcile, running over a frontend child's live `Prepared`/`Intent` records | the same metadata op published by two processes, with order across them lost (an rmdir/mkdir pair can invert). A parent's peer apply can discard a child's fresh staged edit (F7). | one converger owns every WAL record (frontends hand records to it), **or** per-record claims (a lock per record id, or a rename into an owner-scoped directory) that reconcile and rearm honour |
| **Q2** | an upload has promoted (staged sidecar deleted, mirror updated), and the record is still `Prepared`, not `Executed` | reconcile's `resume_put` finds no staged data and completes the record. **The journal entry is never published**: the manifest is on the store, but peers never hear of the new version (a new file stays invisible to them until a full rebuild) | advance the record to `Executed` (or a "published-bytes" state) **before** the last local evidence of the upload is removed, or make `resume_put` treat "no staged data but the mirror holds the manifest the record's upload produced" as Executed |
| **G7** | Android process killed with deferred records on disk | replica and backfill targets on the phone never receive those writes | whichever process is the only runner of a log must start it with recovery. The rule is "whoever can take the claim resumes", not "only the daemon". |
| **Q4** | a one-shot command's settle times out (target down) on a machine with no daemon | the deferred records are never replayed by anyone | any process that finds a log with no live claim, and is allowed to run it, resumes it. A command could offer to drain unclaimed logs. |
| **Q3** | Android share-sheet save: the activity has closed, and the commits are still running | the shared files are dropped silently, and the staging copies are swept at 24 h | adopt before closing the UI, or write a durable "pending share" record (target folder, name, staging path) that the next boot replays |
| **Q6** | the application calls fsync on the mount, then power is lost | the fsync reported success, but the staged body and sidecar may be gone | fsync must flush the file's staged body, sidecar and their directories (P5) |
| **F6** | reconcile of an `Intent` with puts, where reading a newer peer entry fails | the peer's newer entry is treated as absent, and a stale op (for example a delete) is published over the peer's file | "failed" is not "absent": fail the record's reconcile and retry later |
| **F4** | a restart after a size-capped prune of the applied log | re-applied old deletes remove a file a later peer write restored | never prune keys inside the dedupe horizon. Make delete application consult the store. |
| **Q9** | import or rsync killed between publishing manifests and publishing their batch entry | the re-run skips them, and peers never see them | spool durably and replay the spool at the next run, or emit Put ops for skipped keys whose entry is not known to exist |
| **Q8** | an upload record parked by Poison-Stop in a long-running process | never retried until a restart | rearm uploads the way metadata is rearmed |
| **Q5** | two processes running one target's deferred log concurrently (a one-shot running its posts, and the parent running a frontend's records) | a Delete(K) from one process runs after the other's Put(K) of a recreated K. The target lacks a live file, silently (not degraded). | one runner per log at a time, with recorders only recording, or a key-aware reorder check (skip a Delete whose key exists on the source now) |
| **Q7** | a record update (note failure, advance) racing a completion in another process | the completed record is resurrected. Harmless today (the replay is idempotent), but it violates P3. | a conditional update, or a single owner per record |
| **H7** | Android camera backup: a failed or unsettled photo | never retried | the watermark only moves past settled and uploaded rows |
| cursor-behind (Android) | a kill within 2 s of an upload | not lost. Peers hear of it only via the 60 s sweep. | acceptable. Flushing on `onTrimMemory` would shorten it. |
| unverified | many stops in a row, each landing inside the 0.8·GRACE queue window | nothing lost (Stopping leaves the records). Liveness only. | — |

### 6.4 Crash-testing plan for a rewrite

**The oracle.** The test driver keeps an **acknowledgment log**: each user action whose call
returned success, in order, with its expected effect. Each unacknowledged in-flight action is
recorded as "maybe".

**The invariant, checked after restart plus quiescence** (the store reachable, the resumer run,
all queues settled, one peer applying the journal):

1. **No acknowledged action lost.** For every acknowledged action there are two acceptable
   outcomes:
   - its effect is visible in the local view, on the main store, and in the peer's view;
   - it was superseded by a later acknowledged action, or displaced into a conflicted copy
     whose bytes equal it.
2. **Atomicity of the unacknowledged.** Each "maybe" action is either fully applied or absent.
   There is never a torn file, and a rename never leaves both or neither of its names.
3. **Nothing owed remains.** The WAL, the deferred logs and the staged tree are empty. There are
   no `.bad` sidecars. The export and GC markers are finished, or resumable by a re-run.
4. **Convergence.** Local view = main store = peer view = each replica (minus excluded keys).
   Every manifest on a replica has all its chunks.
5. **Idempotence.** The final state equals the final state of the same script run with no crash.
6. **Visibility.** Anything dropped (Drop, unparseable) shows as degraded in status.

**Enumerating kill points systematically:**

1. **Instrument every durable step.**
   - Wrap the filesystem capability: open-create, write, rename, link, unlink, mkdir, fsync.
   - Wrap the store capability: put, put-if-absent, copy, delete, delete-multi.
   - Give each call site a stable label (for example `wal.advance-executed` or
     `promote.delete-sidecar`). Count the steps of a reference run of each scenario.
2. **Kill each step twice.** For each step `k` and each label, re-run the scenario and abort
   immediately **before** step `k`, then again immediately **after** it.
   - Use a real process kill (SIGKILL of a child process), so that no `finally` block or
     exit hook runs.
   - Store calls get a third variant, **"landed but answer lost"**: perform the put, then fail
     the call.
3. **Restart and run the invariant.** Keep a second kill-point iteration inside recovery itself
   (kill during reconcile, then restart again). Recovery must be crash-safe too.
4. **Model power loss.** Run the local filesystem shim with a volatile overlay: every operation
   since the last `fsync` of that file (for data) or that directory (for names) is unsynced. At
   the crash, generate states:
   - (a) drop all unsynced operations;
   - (b) keep names but drop data, so renamed files are zero-length or truncated;
   - (c) random subsets that respect only fsync barriers.

   Run recovery on each state. On Linux, a block-level recorder (dm-log-writes or a
   CrashMonkey-style replay) can cross-check the model against a real filesystem.
5. **Multi-process kill points.** Run the parent, a frontend child and a one-shot command
   concurrently, and kill each one independently at each labelled step while the others keep
   running.
   - Assert that no record is executed by two processes. Count `run` invocations per record id
     through the instrumentation.
   - Assert that ordered logs are applied in id order on the store.
6. **Platform lifecycles.** For Android, kill with no drain at every step, then cold-boot. The
   invariant must include deferred logs (G7) and share-sheet saves (Q3).
7. **Guard against a vacuous pass.** Each run must assert that the kill actually fired (the step
   counter reached `k`) and that recovery found something whenever the kill fell inside a window
   that leaves evidence. A sweep that "passes" because the scenario aborted early tests nothing.
   Include one planted failure (skip an fsync, reverse F9's order) and check that the harness
   reports it.

---

## 7. Parameters

| Parameter | Value | Effect | Trade-off |
|---|---|---|---|
| `MAX_QUEUED` | 100 000 in memory per queue | runaway backstop: beyond it, posts are not written and the queue is degraded | higher means more memory in a long outage. Reaching it loses work (Drop semantics), so it must be far above any realistic backlog. `record` bypasses it, and keyed pending slots are not counted. |
| `BACKOFF(n)` | min(300 s, 0.5 s · 2^min(10, n−1)), no jitter | queue retry spacing | a longer cap means less load on a dead target and slower pickup after recovery. No jitter because one client's queue is one sequential retrier. |
| `SETTLE_TIMEOUT` | 60 s (min with GRACE while stopping) | how long a command waits for its own jobs | longer means commands finish their work in-process; shorter means leftovers wait for the resumer |
| `STALL_WARNING` | 60 s | warn when jobs are queued and no outcome happened | noise vs time to notice |
| `GRACE` | 10 s | stop budget | must fit the supervisor's kill deadline (systemd 30 s) with the reaper margin |
| queue share of the drain | 0.8 · GRACE | leaves time for the cursor flush and the notices | — |
| reaper margin | GRACE + 2 s, then SIGKILL | children's bound | — |
| upload workers `W` | `maxUploads` (≥ 1) | keyed parallelism | memory, link share |
| metadata and deferred workers | 1 | order | wider needs dependency tracking |
| periodic rescan (deferred) / rearm (metadata) | 60 s | the backstop for lost pokes and parked records | latency vs listing cost |
| rescan poke debounce / timeout | 0.5 s / 1 s | a recorder's nudge to the resumer | — |
| staged orphan grace | 3600 s (on demand) | how old an unnamed body must be before it is reaped | must exceed the longest body-before-sidecar window. Must not apply to bodies named by `.bad` files (F10). |
| Android staging orphan age | 24 h | sweep of uncommitted staging files | also the deadline for Q3's silent loss |
| cursor debounce / peer sweep | 2 s / 60 s | cursor-behind latency bound after a kill | — |
| chunk forward bound | `maxChunkBuffers` (32) | unrecorded, best-effort forwards | memory vs replica freshness |
| reconcile journal reads | 32 concurrent | `Intent` recovery reads | start time vs request burst |
| import batch | 2000 ops / 10 s | the Q9 exposure window | fewer entries vs the loss window |

---

## 8. Known gaps (summary)

Details are in §6.3. For the queue itself:

1. **No fsync** of records or their directory (F8). The queue's durability claim is "process
   crash only".
2. **The claim is advisory and only half used.** On the WAL directory every runner takes it and
   nobody checks it. Reconcile and rearm read all records regardless (F7, Q1). A correct version
   either routes every WAL record through one converger, or makes claims per record and has
   every reader honour them.
3. **No resumer on some hosts** (G7 Android, Q4 daemon-less CLI). The rule "only the daemon
   resumes" should become "a process that can take a log's claim, and is the designated runner
   on its host, resumes it".
4. **Update is not conditional** (Q7).
5. **Id minting.** The counter is per `Records` instance, not per directory per process, so two
   instances over one directory in one process could mint the same id within one microsecond
   ([01 §9.5](../01-core.md)). The WAL avoids this with a per-directory registry. The deferred
   logs rely on one instance per target (and G2: duplicate target names share one directory).
6. **`MAX_QUEUED` silently drops posts** (deferred), after logging once. That is visible as
   degraded but is data the target never gets without `mirror`.
7. **Keyed resume does not coalesce**: two records of one key both run. This is harmless (the
   upload reads the current state) but costs a run.
8. **Unparseable vs empty** (P6): the WAL job decoder never reports unparseable.

---

## 9. Alternatives and why this design

| Alternative | Why not (or not yet) |
|---|---|
| In-memory queue, persisted on shutdown | A kill loses everything acknowledged since the last save. Recording in the caller's path is the only thing that leaves evidence (01 §7: "Durable record before acknowledging a write"). |
| One append-only log file per queue (segment + offsets) | Faster, with one fsync per batch, but completion needs compaction and a torn tail needs framing. One file per record makes completion an unlink, lets `list` skip already-held ids *by name* without reading bodies, and makes "read error: leave it" local to one record. A rewrite needing throughput could use an embedded store (SQLite/LMDB) with the same states. |
| Marker file as the claim | A killed holder leaves a directory nobody may touch. A kernel lock dies with its holder (01 §7). |
| Uniform requeue position | Ordered needs head (5dcca235). Keyed needs tail (isolation). |
| A single poison policy | Drop suits rebuildable targets. Stop suits work that reconcile or rearm will bring back (01 §7). |
| Exactly-once via a committed state | Costs a write per job. `Executed` plus a store HEAD makes the publish idempotent instead (wal-and-journal §9, "record → publish → forget"). |
| Cancel in-flight jobs on stop | Surfaced as a permanent failure and degraded the metadata queue. Racing leaves the jobs owed (07 §4.2). |
| Every process resumes every log | Tried: three processes ran one head job at a third of the link each (c3c4f8cf). This led to the recorder/resumer split. |
| Frontend queues hold recorded jobs in memory | They grew for the process's life and hit the cap (67822324). `record` is now write-only. |
| Per-chunk deferred records | Dedup means copies issue no chunk puts. Correctness rests on the manifest job's chunk check, so chunk forwards stay best-effort ("partial coverage, never partial files"). |

---

## 10. Mapping to the current implementation

This section is the only one with concrete names. Paths are relative to the repository root, at
commit `4c32fa96`.

| Abstract | Concrete | Spec |
|---|---|---|
| queue, records, claim, rescan, settle | `lib/core/durable_queue.ml` (`Records`, `Make.Make`, `claim`, `with_claim`, `rescan`, `settle_all`), `durable_queue_intf.ml` | [01 §2.7, §3.6, §4.6](../01-core.md) |
| scheduler binding; Gone vs Failed read | `lib/lwt/core/durable_queue_lwt.ml` (`Files.read_file`) | 01 §3.6 |
| record id | `%020Ld-%08d-%d` (µs, seq, pid); `list` keeps names starting with a digit | 01 §2.7 |
| claim lock | `<dir>.owner`, `lockf F_TLOCK`; the process-wide `owned` table | 01 §2.7 |
| ordered / keyed | `Q.ordered` / `Q.keyed`; `put_back` (head vs tail); `take` (slot, `pending`, `cancel`) | 01 §4.6 |
| failure classes | `Retry.classify`, `Retry.classify_in_order`, `Backend.classify`; `Shutdown.Stopping`; `Retry.Cancelled` | 01 §3.5 |
| poison | `Durable_queue.Stop` / `Drop` | 01 §3.6 |
| upload queue (keyed, Stop) | `lib/domain/sync/sync_queue.ml`; ENOENT or Cancelled means abandon | [03 §4.1](../03-journal-sync.md) |
| metadata queue (ordered, Stop, parked, rearm) | `lib/domain/sync/meta_queue.ml`; `rearm` via the "metadata retry" maintenance task | 03 §3.6, §4.1 |
| WAL log and hand-offs | `lib/domain/checkout/wal/wal.ml` (`Owed`, `log_for` registry, `discharge`, `list` filtered by client uuid) | [04 §4.6](../04-checkout-cache.md) |
| reconcile, adopt-unrecorded | `lib/domain/sync/replay.ml` (`reconcile_record`, `resume_prepared`, `replay_unpublished`, `adopt_unrecorded`) | 03 §4.6 |
| resume_put / resume_meta / hand-over | `lib/domain/checkout/file/file.ml` (`hand_over`, `owing`, `resume_put`, `symlink_manifest`) | 04 §4.6 |
| deferred job log (ordered, Drop) | `lib/backends/api/deferred.ml` (`resumed_starts`, `start_resumed`, `on_recorded`, `post` vs `record`); directory `deferred-pending/<domain>/<target>` | [06 §2.6, §4.4](../06-backends.md) |
| resumer role | `Domain.start_resumed` in `lib/app/cli/launcher.ml` (parent, after forks); `resume=true` only in the daemon conf | [07 §2.1, §4.1](../07-daemon-cli.md) |
| rescan triggers | sync-socket `rescan` action → `rescan_all`; "deferred rescan" maintenance task every 60 s (`domain_engine.ml`); frontend poke debounced at 0.5 s | 07 §3.5, §3.6 |
| drain order and stop | `Domain_engine.drain` (Mq, then Sq, raced against 0.8·grace; `flush_cursor`; notices; `Backend.drain`), `drain_for_stop` | 07 §4.2 |
| one-shot drain | `Oneshot.run` → backend drain → `settle_all` | 07 §4.7 |
| Android lifecycle | `android_jni.ml` `load_domain` (no `resume`: G7); `start_queue`; `run_maintenance`; no drain | [frontends/android.md A5.1, A7](../frontends/android.md) |
| Android ingest and share | `Ingest.kt` (`commit` fsyncs staging; `sweepOrphans` 24 h), `MainActivity.kt` share save (finish before commit: Q3) | android A5.5, A5.6 |
| staged sidecar and bodies | `staged_manifest.ml`, the `data.ml` write path (`ensure_group_body`, `truncate_locked`: F9); `staged_orphans.ml` (F10) | 04 §2.3, §4.5, §4.16 |
| promotion before Executed (Q2) | `Data.sync` → `promote` deletes the staged sidecar; `Sync_queue.run` then calls `W.discharge` (advance `Executed`) | 04 §4.7 |
| atomic write without fsync | `lib/local/io/fs.ml` `atomic_write` / `with_temp_rename` (F8); fsync only in `local_backend.ml` and `export.ml` | findings F8 |
| FUSE fsync no-op (Q6) | `lib/app/frontends/fuse/fuse_fs.ml` (`flush`, `fsync` return unit) | [08](../08-frontends.md) |
| import spool (Q9) | `lib/domain/ops/import.ml` (`Skipped_exists` adds no op), `publish.ml` batch | [05 §2.5, §4.3](../05-ops-config.md) |
| export record | `lib/domain/ops/export.ml` | 05 §2.5, §4.4 |
| GC marker and lock | `Collection`, `tsync/D/gc-run`, `gc-run.lock` | 05 §4.9 |
| tests | `tests/work/queue_records` (Gone / unparseable / failed read), `queue_adopt` (idempotent adopt), `queue_order` (head retry, Stop re-adoptable), `queue_degraded`, `queue_stall`; `tests/unit/queue_claim`, `queue_stop`, `drain_for_stop`, `export_record`; `tests/scenario/sync` (`CrashBeforeCommit`, `RecoverStaged`, `OrphanStagedBody`), `tests/scenario/staged` (commit/promotion replay windows), `tests/scenario/meta_offline` (intent recovery); `tests/e2e/stress` (`crash_and_restart`: random SIGKILL against a legal-end-state oracle); `tests/backends/durable_writes` (fsync-before-rename order for the local store) | [09](../09-tests.md) |
