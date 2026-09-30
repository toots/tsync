# Failure model

One classification of what can go wrong, used by every layer from a store driver up to a
client. It covers how each layer recognises a failure, what a failure may turn into when it
crosses a boundary, and what each layer does about it. Today these rules are spread over
[01-core §3.5, §4.4–4.7](../01-core.md), [06-backends §3.1, §4.1, §4.3–4.5, §4.8](../06-backends.md),
[03-journal-sync §4.1, §4.3, §7.7](../03-journal-sync.md), [08-frontends §A2.4, §A3.4](../08-frontends.md),
[frontends/file-provider.md §A4.2](../frontends/file-provider.md),
[frontends/http-proxy.md §A6](../frontends/http-proxy.md) and [07-daemon-cli §2.3, §3.7](../07-daemon-cli.md).
Sections 1–9 do not depend on the implementation. Concrete names appear only in §10.

---

## 1. Problem and goals

tsync keeps a user's files in object stores that can be slow, down, throttled, wrong or
damaged. It does this on devices that crash, lose power, run out of descriptors and get
stopped at any moment. Several independent layers ask for work and report failures: drivers, a
composite over members, the content model, checkout, sync, request handlers, and native clients
behind a wire protocol. Each layer decides whether to retry, wait, skip or report. Those
decisions are correct only if every layer agrees on what a failure *means*.

Goals:

- **G1. No silent data loss.** Work that was acknowledged is either completed or left in a
  durable, visible, automatically retried state. The one exception is work dropped with a named
  repair.
- **G2. No false "not found".** "Absent" is claimed only when an authority that could hold the
  thing was asked and said so. "Could not look" is never reported as "not there".
- **G3. One unexplained failure costs one operation**, not a queue, a domain, a link or a
  process.
- **G4. Link trouble costs time, not work.** Offline, local operations keep working and every
  remote obligation stays owed until the link returns.
- **G5. Stopping is not failing.** A requested stop leaves work owed, counts nothing as a
  failure and is bounded in time.
- **G6. Every wait a human sits behind is bounded**, and the answer when the bound fires says
  which kind of failure it was.
- **G7. The breaker hears only evidence about the link**, measured on a clock that cannot jump.

Non-goals:

- Byzantine stores. A store that returns a different, well-formed object under a key is
  caught only for content-addressed chunks, whose hash is checked.
- Durability against power loss. It is a stated gap ([findings F8](../findings.md)), and is
  out of scope here except where it changes a failure's kind.
- Detecting truly concurrent edits. That is conflict policy ([03 §7.1](../03-journal-sync.md)),
  not failure handling.
- Automatic repair of damaged stores. Damage is surfaced with a named repair and never fixed
  silently.

---

## 2. System model and assumptions

- **A1. Stores** answer each request with one of: a value, "absent", a refusal, or nothing
  (an error, a hang, a dropped connection). A store's "absent" is an authoritative statement
  about that store only. A conditional create is atomic on the store's side. A store may
  throttle (429/503) while it is healthy.
- **A2. Links** can be down, flapping, slow-but-flowing or dead-without-FIN. A connection that
  dies without FIN is silent forever unless a timer ends it.
- **A3. Several members** can hold the same content (main, replica), or different content
  (archive). One member is the source of truth for existence: the first main.
- **A4. Local resources** fail independently of stores: descriptor exhaustion, disk full, EIO,
  EINTR, permission.
- **A5. Processes** can be killed at any instruction. Atomic rename-into-place survives a
  process crash. Without fsync it does not survive power loss.
- **A6. Clocks.** A monotonic clock exists and never steps. The wall clock can step either way
  by any amount: NTP corrections, or a fake hardware clock at boot on boards with no RTC. Peers'
  wall clocks disagree.
- **A7. Clients** (the file manager, the OS file-provider framework, Android document
  consumers, the CLI) retry or give up on their own policy. Some can *latch* a domain offline
  until told otherwise. The daemon cannot see a client's retries.
- **A8. Code has bugs.** Some exceptions will be raised that nobody classified.

---

## 3. The classification

### 3.1 Failure kinds

Each failure has exactly one **kind**. The kind is decided by the layer that has the evidence,
normally the lowest one. It is carried upward as data, never re-derived from prose.

| Kind | Definition | Link evidence? | Will repeating help? |
|---|---|---|---|
| **ABSENT** | An authority for the name was reachable and answered that the named object does not exist. At domain level, *every* member that could be authoritative was asked, and the first reachable source of truth said no. | yes (link up) | no |
| **EXISTS** | The name is held by something else: a lost claim, `EEXIST`, `ENOTEMPTY`. It is a considered answer about a name, and conflict policy resolves it. | yes (up) | no |
| **REFUSED** | The authority answered and will give the same answer: permission or credentials (`denied`), a read-only store or domain (`read_only`), a 4xx other than those listed as transient. | yes (up) | no, until configuration changes |
| **INVALID** | The request is malformed on this side: a bad argument, an unknown action, bad JSON. | no | no |
| **CORRUPT** | An answer was obtained and contradicts what it must be. Examples: bytes that do not hash to their name, a length that disagrees with the manifest, a manifest with a hole, an over-long range answer, a record that cannot be decoded. It is *not* ABSENT: the thing exists and is wrong. A dependency that no store holds after all were asked (a manifest naming a missing chunk) is CORRUPT, not ABSENT. | yes (up) | no, only repair helps |
| **UNPREPARED** | Local state cannot express the operation. For example, the parent folder has no id here, or a full rebuild is refused while metadata is owed. A user action (a sync) clears it. | no | not by itself |
| **TRANSIENT/LINK** | No considered answer: a connection error, a 5xx, a stall (silence past the stall timeout), a probe that did not answer, TLS or DNS failure, a truncated framed answer. | **yes (against)** | yes, later |
| **TRANSIENT/LOAD** | The authority answered "later": 429, 503 busy, a throttling code. | yes (up, but busy) | yes, later |
| **TRANSIENT/LOCAL** | A resource on this host: `EMFILE`, `ENFILE`, `ENOSPC`, `EIO`, `EAGAIN`, `EBUSY`. | no | yes, later |
| **UNREACHABLE** | *Derived, not raised by a driver.* Every candidate that could answer is held by the breaker, or TRANSIENT/LINK persisted past the layer's patience budget or deadline. It means "the store is the problem; stop asking until told." | aggregate | yes, after the link returns |
| **STOPPING** | A process stop was requested. The work is untouched and **owed on disk**. | no | yes, at next start |
| **CANCELLED** | The work is no longer wanted: a newer write superseded it, a publish was superseded by work under its own record, or the caller withdrew. Its record may be completed. | no | not applicable |
| **DEADLINE** | *The waiter's* bound expired. The work may continue and land for the next caller. To the waiter it is reported as UNREACHABLE. It is not link evidence unless it was a probe. | only if a probe | yes |
| **UNEXPLAINED** | Anything nobody classified (A8). | no | unknown |

Three orthogonal properties follow from the table and drive every policy:

1. **Retryable**: TRANSIENT/*, UNREACHABLE, STOPPING (at next start), DEADLINE.
2. **Health evidence**: only TRANSIENT/LINK and a lost probe count *against* a member. Any
   considered answer counts *for* it: ABSENT, EXISTS, REFUSED, CORRUPT, TRANSIENT/LOAD.
   Nothing else moves the breaker.
3. **Failure accounting**: STOPPING, CANCELLED and DEADLINE are never counted as failures. They
   never mark anything degraded and never park or drop a record.

UNEXPLAINED has a context-dependent default (§5.3). It is never ABSENT, never UNREACHABLE and
never health evidence.

### 3.2 Durable and volatile failure state

| State | Where | Durable? | Meaning |
|---|---|---|---|
| Owed record (upload, metadata op, replica job) | per-domain log directories | yes (process-crash) | work acknowledged, not yet done |
| Per-record failure note (kind, reason) | in the owed record | yes | last failure, shown by status |
| Parked set (ordered own-ops that failed non-transiently) | memory + record left on disk | record yes, set no | skipped by the queue, re-offered by a periodic sweep |
| Stepped-aside set (peer entries that failed non-transiently) | memory | no (the entry stays unhandled, so it is recomputed) | retried every pass, shown as "unapplied" |
| Degraded flag | memory, re-derived at start from dropped/unreadable records | partly | a copy needs a named repair |
| Set-aside file (undecodable local sidecar) | renamed beside the original | yes | never deleted automatically |
| Corruption marker per chunk | on the store | yes | the finding itself |
| Breaker cell per member | memory | no | trip run, hold, probe |
| Last-sync mark, applied log | local files | yes | what peer work was done |

---

## 4. Detection: from raw inputs to a kind

Every layer that turns a raw signal into a kind is listed here. A layer not in this table must
pass the kind through (§5).

| Layer | Input | Kind |
|---|---|---|
| Local-filesystem store driver | `ENOENT` on read or stat | ABSENT (as "no value", not an error) |
| | `EEXIST` on claim-by-link | EXISTS (answer: the holder's body) |
| | `EIO ENOSPC EMFILE ENFILE EAGAIN EINTR EBUSY` | TRANSIENT/LOCAL (EINTR is retried inline and never surfaces) |
| | any other errno (`EACCES`, `EROFS`, `ENOTDIR`, …) | REFUSED |
| | written bytes read back do not hash to their name | CORRUPT, filed as a marker; the write still succeeds |
| HTTP object-store drivers | 2xx | value |
| | 404, or a per-key `NoSuchKey`/`NotFound` in a bulk answer | ABSENT (a delete of an absent key is success) |
| | 412 on a conditional create | EXISTS, then read the holder |
| | 429, 503/throttled | TRANSIENT/LOAD |
| | other 5xx; connection or TLS error; redial failure | TRANSIENT/LINK |
| | stall timer fired (no byte for the stall window) | TRANSIENT/LINK |
| | per-key non-absent error inside a 2xx bulk answer | TRANSIENT/LINK. It must be raised, never dropped. |
| | 401, 403 | REFUSED (`denied`) |
| | other 4xx, redirect | REFUSED |
| | range answer longer than asked | CORRUPT (the store ignored the range) |
| Peer tsync store (proxy client) | 404 on object | ABSENT |
| | 404 on an optional capability | "no opinion", which is not a failure |
| | 409 + reason | the server's permanent kind. Today the subkind is flattened to REFUSED (§8 N4). |
| | 500 | TRANSIENT/LINK (the server's transient) |
| | 503 `busy`, 429 | TRANSIENT/LOAD |
| | 401 | REFUSED. Clock skew beyond the signature window is reported this way (§6). |
| | truncated framed answer | TRANSIENT/LINK |
| Peer tsync store (proxy server) | store kind → status | ABSENT → 404; any permanent kind → 409 + reason; TRANSIENT/* and UNEXPLAINED → 500; admission queue full → 503; read-only → 403 |
| Breaker | ≥ 2 consecutive LINK failures spanning ≥ trip span | the member goes *held*; asks to it fail fast as UNREACHABLE |
| | a probe gets no answer within the probe timeout | lost probe, so the hold extends |
| Composite over members | every readable candidate held or failing, and no archive answers | UNREACHABLE (raise the first candidate's error) |
| | first reachable source-of-truth answers absent | ABSENT (a replica miss is never consulted) |
| | nothing answered anywhere but something was passed over | UNREACHABLE, never ABSENT and never an empty merge |
| | no writable member | REFUSED (`read_only`) |
| | write to a non-main while a main is down | TRANSIENT (UNREACHABLE of the main) |
| Content model | chunk bytes do not hash to the key after one re-fetch | CORRUPT |
| | manifest hole, or inherit slot with no base | CORRUPT |
| | chunk length ≠ manifest's size | CORRUPT |
| | chunk no store holds, all asked | CORRUPT (a dangling reference) |
| Checkout | read of uncached bytes not done within the read deadline | DEADLINE (the fetch continues) |
| | parent folder has no local id | UNPREPARED |
| | local source of an upload is gone | CANCELLED (nothing is owed any more) |
| | undecodable staged sidecar | CORRUPT (set aside, never deleted) |
| Durable queue | record body unreadable because gone | nothing (already completed) |
| | record unparseable | CORRUPT (dropped, degraded) |
| | record read fails otherwise (`EMFILE`, `EIO`) | TRANSIENT/LOCAL (left for the next rescan) |
| Process | stop requested | STOPPING, raised out of every backoff, ladder, queue wait and link wait |
| Request handler | errno from the core | the errno's kind (ENOENT → ABSENT, EEXIST → EXISTS, ENOTEMPTY → EXISTS, EPERM/EACCES → REFUSED/denied, EROFS → REFUSED/read_only) |
| Clients | transport failure to the daemon (connect or read) | TRANSIENT/LOCAL from the client's view. It is never UNREACHABLE: a daemon restart must cost one retry. |
| | no reply within the client's request deadline | DEADLINE (today there is none; see §8) |

---

## 5. Propagation

### 5.1 General rules

- **P1. The kind is data.** It crosses every boundary in a typed field: an exception variant, a
  status code, a wire `code`. It is never re-derived from message text.
- **P2. Upward, a kind may only be refined by a layer with more evidence, or aggregated.** It
  is never weakened into a more confident kind.
- **P3. Aggregation is monotone in doubt.** When several answers combine, the result is the
  most doubtful one that could change the answer. For existence:
  `value > ABSENT(authoritative) > UNREACHABLE`. For a domain, "some member unreachable and the
  rest absent" is UNREACHABLE unless the absent answer came from the source of truth.
- **P4. A batch failure is not a per-item answer.** If a batched request fails, every item is
  unanswered, not absent. The layer re-asks each item singly or raises.
- **P5. STOPPING and CANCELLED pass through every layer unchanged**, and every catch-all
  handler must re-raise them first.

### 5.2 Permitted transformations by boundary

| Boundary | Permitted | Notes |
|---|---|---|
| raw signal → driver | per §4 | the only place a raw errno or status is interpreted |
| driver → retry ladder | TRANSIENT/* retried; after the last attempt it leaves as TRANSIENT carrying the member and op | an unclassified error inside a request is TRANSIENT in the current code; see §5.3 |
| ladder → breaker | LINK counts against; considered answers count for | LOAD should count for (up); it counts against today (§8 N3) |
| member → composite | held member → UNREACHABLE fast-fail; ABSENT from source of truth → ABSENT; all failed → UNREACHABLE; batch failure → re-ask singly | an archive miss never overrides an unreachable main |
| composite → content model | ABSENT of a *dependency* (a manifest names a chunk) → CORRUPT | ABSENT of the *requested* item stays ABSENT |
| content → checkout | CORRUPT stays CORRUPT; a waiter's DEADLINE → UNREACHABLE for that waiter only | the fetch itself continues and is not a failure |
| checkout/sync → ordered queue | TRANSIENT/LINK and TRANSIENT/LOAD block the head; everything else (UNEXPLAINED included) parks | this is the "link failure blocks, anything else steps aside" rule |
| sync inbound, per peer entry | TRANSIENT/* aborts the pass; everything else steps the entry aside | "could not read the entry" is TRANSIENT, never "entry gone" |
| core → request handler | ABSENT → `not_found`; EXISTS → `exists`/`not_empty`; REFUSED → `denied`/`read_only`; INVALID → `invalid`; UNREACHABLE and DEADLINE → `unreachable`; CORRUPT, UNPREPARED, UNEXPLAINED → `internal`, with a reason naming the repair; STOPPING → `internal` ("left for the next start") | see §8 N1 for today's table |
| handler → kernel (FUSE) | ABSENT → ENOENT; EXISTS → EEXIST/ENOTEMPTY; REFUSED → EACCES/EROFS; everything else → EIO | an errno raised by the core passes through untouched |
| handler → HTTP peer | ABSENT → 404; permanent kinds → 409 + reason; TRANSIENT/*, UNEXPLAINED → 500; overload → 503 | the permanent subkind should travel too (§8 N4) |
| wire → native client | map `code` one to one; an **absent `code` is `internal`**; a transport failure is a retried local error | only `unreachable` may map to a latching client state |
| anything → CLI exit status | 0 success; 1 for every classified failure (the reason is printed); 2 for refusals about the invocation's environment; 125 only for UNEXPLAINED | see §8 N6 |

### 5.3 Forbidden transformations

| # | Forbidden | Why | Current breaches |
|---|---|---|---|
| X1 | TRANSIENT, UNREACHABLE, UNEXPLAINED, STOPPING or DEADLINE → ABSENT (or "empty", "nothing", "hole") | G2, and it becomes G1 when the caller acts on "absent" by writing | F6, H10, N2, N5 |
| X2 | Any kind → UNREACHABLE except link aggregation or a deadline | UNREACHABLE latches clients off; a local fault must not take a domain down (G3) | N1 (CORRUPT and UNPREPARED map to `unreachable`) |
| X3 | UNREACHABLE → a kind a client retries hot | G6: the client never learns to back off | N1 (a held or exhausted member maps to `internal`) |
| X4 | STOPPING or CANCELLED → counted failure, degraded, parked or dropped | G5; cancelling a drain once made the metadata queue degrade itself | F6 (swallows STOPPING); fixed for drains ("raced, not cancelled") |
| X5 | A replica's ABSENT → the domain's ABSENT while the main is unreachable | a stale copy is not an authority | none known (the composite guards it) |
| X6 | A batch failure → per-key ABSENT | a caller told "absent" writes a mirror or a copy missing the file | none known (the batch path re-asks) |
| X7 | TRANSIENT/LOAD or UNEXPLAINED → evidence against a member | G7: a busy or buggy peer is not a dead link | N3 |
| X8 | A kind → a missing kind on the wire | the receiver cannot tell `not_found` from `unreachable` | H2 (router), H10 (Kotlin) |
| X9 | TRANSIENT/LOCAL on reading local source data → "source is empty or hole" | uploads zeros as content | N2 |

**UNEXPLAINED defaults.** In a single request with a retry ladder, the current code treats it as
TRANSIENT. That keeps work from being abandoned over an unknown blip. In ordered work it is
treated as permanent, so it parks: a local bug must not block everything behind it. At a client
boundary it is `internal`, which is retried. The model keeps these defaults but requires that
UNEXPLAINED never feeds the breaker (X7) and never becomes ABSENT or UNREACHABLE.

---

## 6. Response policy per kind and layer

| Kind | Driver / ladder | Composite | Ordered queue (own metadata ops, replica jobs) | Keyed queue (uploads) | Sync inbound | Request handler / client | What stays owed |
|---|---|---|---|---|---|---|---|
| ABSENT | return "no value" | answer if from source of truth; otherwise go on to the next | the op's fact tables decide (for example "nothing owed") | local source gone → complete | fact tables | `not_found`; delete treats it as success | nothing |
| EXISTS | return holder | first main arbitrates | conflict table: set ours aside, re-gather | n/a | conflict table | `exists` | the conflicted copy's upload |
| REFUSED | stop, 1 attempt, member marked up | pass on (`read_only` if no writer) | park (own ops) / drop and mark degraded (replica jobs) | stop; the record stays until next start | step aside | `denied`/`read_only`; CLI exit 1 | parked or dropped record |
| INVALID | n/a | n/a | park | stop | step aside | `invalid`, not retried by a correct client | nothing |
| CORRUPT | 1 attempt; chunk read re-fetched once | ask the next member for a good copy where one exists | park / drop and mark degraded | stop | step aside | `internal` + reason; marker filed; CLI exit 1 naming the repair | marker, set-aside file |
| UNPREPARED | n/a | n/a | refused before anything changes | n/a | step aside | `internal` + "run sync"; CLI exit 1 | nothing |
| TRANSIENT/LINK | retry with jittered exponential backoff up to the attempt limit; report to the breaker | fail fast on a held member when there is an alternative; the last candidate is always asked | block at head, back off up to the queue cap, no jitter | requeue at tail with backoff | abort the pass; retry after the floor, or at the sweep | after patience: `unreachable` (the client latches); FUSE: EIO | everything |
| TRANSIENT/LOAD | same ladder, but should not count against the member | same | block at head | tail | abort the pass | backpressure; a client backs off | everything |
| TRANSIENT/LOCAL | same ladder (always-up cell) | n/a | block at head | tail | abort the pass | `internal` | everything |
| UNREACHABLE | not retried inside the ladder; the hold ends it | failover to readable replica, then archives; writes never redirected | block at head | tail | abort the pass | `unreachable`; the client latches until told; the status shows the hold | everything |
| STOPPING | end the ladder at once | pass through | leave the record, not counted | leave the record | end the pass (the mark stays) | reply if possible, otherwise close | everything |
| CANCELLED | pass through | pass through | complete the record | complete the record | n/a | `internal`/`userCancelled` on the client side | the replacement's record |
| DEADLINE | n/a | n/a | n/a | n/a | n/a | `unreachable` / EIO for that waiter; the work continues | the fetch still lands |
| UNEXPLAINED | treated as TRANSIENT in a ladder (must not feed the breaker) | pass on | park | tail with backoff (indefinitely) | step aside | `internal` (costs one op); CLI exit 125 | the record |

**Time bounds.**

- **Ladder.** The delay before attempt n+1 is `min(20, 0.5·2^(n−1)) × U[0.5, 1.5)` s. With 8
  attempts the nominal backoff totals 51.5 s (≤ 77 s), plus up to one stall window per attempt.
  With a 60 s stall that is ≤ 8 min for an unresponsive object store. With the 300 s peer stall
  window it is up to 40 min. The breaker cuts this to about 1–2 s whenever there is an
  alternative. It does not cut it for the last candidate, so the client-facing deadline must
  (G6).
- **Breaker.** It trips after 2 LINK failures ≥ 1 s apart, where failures more than the initial
  hold apart restart the count. It holds 30 s, doubling per lost probe up to 300 s. Exactly one
  probe is offered per expired hold. A probe is bounded at 10 s including retries.
- **Queues.** Backoff is `min(300, 0.5·2^min(10, n−1))` s. An ordered queue blocks at its head,
  so one flapping member costs every job behind it up to 5 min per round. Parked ops are
  re-offered every 60 s. A peer-entry pass that aborts is retried after 2 s; a full sweep runs
  at least every 60 s.
- **Read deadline.** 15 s for uncached reads.
- **Settle and stop.** Settle waits are capped at 60 s, and end early once a target is failing.
  A stop is bounded by the grace (10 s): the queue drain gets 0.8 × grace so the cursor still
  flushes, the reaper waits grace + 2 s before SIGKILL, and the supervisor's stop budget must
  exceed that.
- **In-daemon IPC.** 2 s.

**What is surfaced to a human.**

- A tripped breaker (with its reason and the hold's end time).
- Parked and unapplied counts with the reason.
- Degraded copies, with the repair command ("mirror from the main").
- Corruption markers (integrity check).
- Set-aside files.
- Queue stalls: a warning when there has been no progress for 60 s with work queued.
- The CLI exits with the reason.

A failure surfaced only in a log line at info level is not surfaced.

---

## 7. Clocks

A timer that measures a **duration inside this process** must use the monotonic clock. A time
that is **persisted, or compared with another host's time**, must use the wall clock, and must
tolerate steps.

| Timer | Must be | Current |
|---|---|---|
| Retry backoff, queue backoff, interruptible sleeps | monotonic | monotonic (event-loop timers) |
| Stall timeout (silence since the last byte) | monotonic | **wall**: a backward step delays detection by the step; a forward step fires it spuriously (G12) |
| Breaker trip span, hold, probe re-offer | monotonic | **wall**: a forward step at boot satisfies the trip span at once, and a backward step lengthens a hold and suppresses its probe (G12) |
| Request, probe, read, settle, grace and IPC deadlines | monotonic | monotonic (sleep-based) |
| Rate windows (metrics, job ETA) | monotonic | **wall** (G12) |
| Uplink governor | monotonic | monotonic |
| Queue stall watchdog, reaper polling | monotonic | monotonic |
| Journal entry timestamps, 30-day dedupe horizon, retention cutoffs | wall (cross-host) | wall. A peer skewed > 30 days behind is ignored ([03 §9.7](../03-journal-sync.md)). |
| Peer request signature window (±300 s) | wall (cross-host) | wall. Skew is reported as REFUSED (401), which is permanent until the clock is fixed. It should be reported as a distinct reason. |
| Pin expiry, orphan-sweep grace, temp-file age | wall (persisted as file times) | wall |
| Credential token expiry | wall for the token's claims, monotonic for the cache's "refresh by" | wall |

---

## 8. Properties, and where the code breaks them

### 8.1 Why they hold, when they hold

- **No silent loss (G1).** Each piece of work is written durably *before* it is acknowledged:
  the owed record, the staged body, the replica job. A record is completed only on success,
  ABSENT-of-source or CANCELLED. The failure kinds map onto three terminal states:
  1. TRANSIENT, UNREACHABLE and STOPPING keep the record and retry it.
  2. The non-transient kinds keep it and make it visible: parked, stepped aside, set aside, or
     marked.
  3. For a rebuildable copy only, the job is dropped with the copy marked degraded and a named
     repair.

  Nothing in the table in §6 unlinks a record on a kind that could clear by itself.
- **No false not-found (G2).** ABSENT has one source: an authority's answer (§4). X1, X5 and X6
  forbid every other route. The composite only answers ABSENT when the first reachable
  source-of-truth member was asked. The inbound sync pass treats "could not read an entry" as
  TRANSIENT and aborts rather than advancing.
- **One unexplained failure costs one operation (G3).** UNEXPLAINED is never health evidence
  (X7) and never UNREACHABLE (X2). In ordered work it parks rather than blocks, and at a client
  it is `internal`, which is retried. The worst case is one parked op, re-offered every 60 s.
- **Link trouble costs time (G4).** Local operations never await a store: metadata halves are
  queued, and the lock never spans a request. TRANSIENT kinds only ever delay work. The breaker
  limits the cost per request to the probe cadence.
- **Stop (G5).** STOPPING passes every catch (P5), and drains are raced against the grace, not
  cancelled.

### 8.2 Known gaps

Findings already listed in [findings.md](../findings.md):

| ID | Rule broken | Effect |
|---|---|---|
| **F6** | X1, X4 | Reading a peer journal entry turns every error, STOPPING included, into "no entry". The pass does not abort and the mark advances past it. In startup recovery, a hidden newer peer entry lets a stale unpublished delete be published over the peer's file. |
| **H2** | X8 | The multi-domain router's own refusals carry no `code`. Clients read them as `internal`, correctly retried, but a missing domain becomes an endless, uninformative retry. |
| **H10** | X1, X8 | The Android bridge drops `code`. A failed listing reads as "no children", and name allocation then overwrites an existing file. "Deleted folder" and "server unreachable" look alike. |
| **G9**, **H6** | G6 | The CLI's and the macOS client's blocking IPC calls have no deadline. A wedged daemon hangs `stop`, `pause`, `cache`, `versions` and the extension's read-only probe. A hang is not a transport failure, so a latching client never shows "unreachable". |
| **G12** | §7 | Stall timeout, breaker and rate windows use the wall clock. |
| **G10** | G5 | One frontend's stop is not grace-bounded and drains sequentially, so it can hang with a store down. |
| **G5** | G2 (dual) | A conditional create against an older peer reads as "won" when it lost. |
| **H7**, **H9** | G1 | Android paths where a failure or a truncated read is taken as "done" or "free". |
| **F8** | G1 | Durability is process-crash only. |

Found while writing this model; these are not in findings.md:

| # | Rule broken | Evidence | Effect |
|---|---|---|---|
| **N1** | X2, X3 | The client error mapping sends the store's "considered answer" error (used for CORRUPT data and for UNPREPARED "run sync") to `unreachable`, and sends the retry ladder's own failures (a member held, exhausted TRANSIENT, REFUSED 403) to `internal`. Only a bare deadline maps correctly to `unreachable`. | The mapping is inverted relative to its own stated rule. A corrupt chunk, or an op under a folder without an id, latches a macOS domain offline. A store that is actually down, or a revoked credential, is retried hot as "unknown error" and never latches. |
| **N2** | X1, X9 | When the upload path fills a staged chunk, it treats *any* failure to open the staged body as "missing body, zero-fill". | Under descriptor exhaustion (`EMFILE`) or `EIO`, zeros are uploaded and published as the file's content. That is silent data loss, recoverable only through version history. Only ENOENT should mean "hole". |
| **N3** | X7 | 429 and 503 are TRANSIENT, and every TRANSIENT counts against the member. So do unclassified exceptions inside a request (decoder bugs). | A throttling store or a busy peer (`503 busy` is deliberate backpressure) trips the breaker. Reads then fail over to a replica or get held for 30–300 s while the link is up. |
| **N4** | P1 | The peer server maps every permanent kind to 409 + prose. The client sees generic REFUSED. | CORRUPT, UNPREPARED and ABSENT-of-source become indistinguishable across a peer. Local and remote corruption surface differently (N1 then maps them to different client codes). |
| **N5** | X1 (mild) | Reading the last-sync mark treats every read error as "never synced". | A transient local read error makes the next pass consider the whole journal. For a manual sync it triggers a full rebuild. The only cost is work, because apply is idempotent. |
| **N6** | §5.2 exit rule | The CLI prints only generic failures and ladder failures as user sentences. The store's considered-answer error (CORRUPT or UNPREPARED, including "run 'tsync sync' first") exits 125 as "internal error, uncaught exception" with a stack trace. | A user-actionable message looks like a crash. |
| **N7** | G1 visibility | A permanently failed upload is left on disk but taken out of the queue, and is re-offered only at the next process start. Parked metadata ops, by contrast, are re-armed every 60 s. | A fixed credential does not resume uploads until restart. The status shows them as owed but not as failing. |
| **N8** | G6 | A single-member domain asks its only member unconditionally, through the full ladder. Only uncached reads are deadline-wrapped (15 s). Whole-file `ensure_cached` and listings through the store are not. | A request handler can sit for many minutes (40 min on a stalled peer) behind a client that itself has no deadline (G9/H6). |
| **N9** | G1 | Integrity and corruption readers turn read errors into "no good copy" / "no marker". | Reports can understate what was checked. They are reports only, so nothing is deleted on their say-so. |

**What a correct version requires:**

- A single typed failure value carrying `kind` and `reason`. Every catch-all must match on
  kind, re-raise STOPPING and CANCELLED first, and never produce ABSENT.
- The client code mapping as in §5.2.
- A `code` on every wire refusal, and native clients that keep it.
- A permanent subkind on the peer wire (for example a header beside 409).
- LOAD split from LINK in the breaker.
- Monotonic timers for every duration.
- A deadline on every client-facing wait. When one fires, the answer is `unreachable` and the
  work continues.
- The same periodic re-arm for every durable queue that parks.

---

## 9. Alternatives and rationale

- **Unknown = transient for requests, permanent for ordered work.** A request retried a few
  times costs seconds. An ordered queue blocked by a local bug cost 8 hours behind one
  `ENOTEMPTY` (memory note *foreign-rename-enotempty-loop*; [03 §7.7](../03-journal-sync.md)).
  A uniform default fails one of the two cases.
- **Breaker with a single probe** rather than per-request ladders. Eight retries against a dead
  host cost about a minute per read, and failover takes 1–2 s instead
  ([06 §7.10](../06-backends.md)). The alternative, adaptive timeouts, still pays one timeout
  per request.
- **Stall timeout, not a total deadline**, for requests. Large bodies on slow links are
  legitimate. Deadlines belong to *waiters*, which is why DEADLINE is a separate kind that does
  not cancel the work.
- **409 for permanent at the peer**, rather than 4xx by cause. 5xx made clients climb the ladder
  8 times for a name that would never exist (commit 48e797b4). The model keeps 409 but asks for
  the subkind to travel with it.
- **Only `unreachable` latches.** A daemon restart once latched a domain off
  ([file-provider §A15](../frontends/file-provider.md)). A conservative mapping costs retries; a
  liberal one costs the domain.
- **Drop vs stop for permanent queue failures.** Dropping is right only where a named repair
  rebuilds the whole target (a replica is rebuilt from its main). Own work is reconciled by
  others and must stay.
- **Drains raced, not cancelled.** Cancellation reached the queue as a failure and degraded it
  ([07 §4.2](../07-daemon-cli.md)).
- **Plausible alternative: a result type per call instead of exceptions.** It would make X1 a
  type error (an `Unreachable` constructor cannot be matched as `None`). Most of the breaches in
  §8.2 are catch-alls that such a type would have refused.

---

## 10. Mapping to the current implementation

| Abstract | Concrete | Spec |
|---|---|---|
| kind TRANSIENT / "permanent" | `Retry.Failed {kind = Transient \| Permanent; op; detail}` (`lib/core/retry.ml`); LINK, LOAD and LOCAL are not distinguished | [01 §3.5](../01-core.md) |
| CANCELLED | `Retry.Cancelled`; runtime cancellation `Clock.is_cancelled` | [01 §3.5](../01-core.md) |
| STOPPING | `Shutdown.Stopping`, `Shutdown.request`, `grace = 10` | [01 §4.7](../01-core.md), [07 §3.4](../07-daemon-cli.md) |
| UNEXPLAINED default in requests / ordered work | `Retry.classify` (→ Transient) / `Retry.classify_in_order` (→ Permanent) | [01 §3.5](../01-core.md) |
| CORRUPT, UNPREPARED (conflated) | `Backend.Backend_error msg` (raised in `chunk_store.ml`, `chunk_cache.ml`, `data.ml`, `file.ml`, `gc/collection.ml`, `Backend.checked_range`) | [06 §3.1](../06-backends.md), [04 §3.3](../04-checkout-cache.md) |
| REFUSED/read_only | `Backend.Not_writable`; `EROFS` | [06 §3.1](../06-backends.md) |
| store classifier | `Backend.classify` | [06 §3.1](../06-backends.md) |
| HTTP detection | `Http_client.failed` (Transient iff ≥ 500 or 429), `call_retry`, `with_stall_timeout` | [01 §3.7, §4.8](../01-core.md) |
| local errno detection | local driver's errno table | [06 §4.2](../06-backends.md) |
| S3 / GCS detection | `Throttled`, `Failed exn` → Transient; `Forbidden`, `Not_found`, `Unknown`, `Redirect` → Permanent; `Backend.absent_code` | [06 §4.2](../06-backends.md) |
| ladder | `Retry.Make.with_retry`, `default_attempts = 8` | [01 §4.4](../01-core.md) |
| breaker | `Health` (`lost`, `answered`, `check`, `probe_lost`, `trip_after`, `trip_span`, `hold_initial`, `hold_max`, `probe_timeout`); `Health_wait.until_held`; `Retry.held` | [01 §4.5](../01-core.md), [06 §4.1](../06-backends.md) |
| composite aggregation | `Domain_store.make`: `read`, `walk`, `ask_member`, `stop_on_miss`, batch re-ask | [06 §4.3](../06-backends.md) |
| write to copy while main down | `Write_guard.ensure` | [06 §4.5](../06-backends.md) |
| durable queue policy | `Durable_queue.ordered` / `keyed`, `Poison.Stop` / `Drop`, backoff cap 300, `settle_all` 60 s, stall warning 60 s | [01 §3.6, §4.6](../01-core.md) |
| own metadata ops | `Meta_queue` (ordered, `classify_in_order`, `Stop`, `parked`, `rearm` every 60 s in `Domain_engine` maintenance) | [03 §4.1](../03-journal-sync.md) |
| uploads | `Sync_queue` (keyed, `Backend.classify`, `Stop`; `Retry.Cancelled \| ENOENT` → complete) | [03 §4.1](../03-journal-sync.md) |
| replica/backfill jobs | `Deferred` (ordered, `Drop` → degraded) | [06 §4.4](../06-backends.md) |
| peer entries: step aside vs abort | `Replay.apply_foreign` / `stepping_aside`, `stepped_aside`; poller `retry_floor = 2 s`, sweep 60 s | [03 §4.3](../03-journal-sync.md) |
| F6 site | `File_store.get_journal_entry` (catch-all → `None`); callers `apply_foreign`, `overridden_since` | [findings F6](../findings.md) |
| N2 site | `Data.fill_from_staged` (catch-all on open → zero-fill), used by `staged_source` for uploads | `lib/domain/checkout/content/data.ml` |
| N5 site | `File_store.read_last_sync_key` (`with _ -> None`) | `lib/domain/remote/store/file_store/file_store.ml` |
| read DEADLINE | `Chunk_cache.read_deadline = 15`, `within_deadline` | [04 §3.3](../04-checkout-cache.md) |
| client code mapping | `Ipc_error.of_exn`, `Ipc_handler` `error_code_json` | [07 §2.3](../07-daemon-cli.md), [08 §A2.4](../08-frontends.md) |
| FUSE mapping | errno passes through `on_loop`; other → EIO + failure ring | [08 §A4.1](../08-frontends.md) |
| peer server mapping | 404 / 409 / 500 / 503 / 403 / 401 / 400 | [http-proxy §A5–A6](../frontends/http-proxy.md), [06 §4.8](../06-backends.md) |
| macOS client | `DaemonError` / `FileProviderError.from`: only `unreachable` → `serverUnreachable` (latched until `signalErrorResolved`); missing code → `internal` | [file-provider §A4.2, §A7](../frontends/file-provider.md) |
| Android client | `Cli.reply` / `Cli.Error` (code dropped, H10) | [android §A3.3](../frontends/android.md) |
| CLI exit | `main.ml`: `Failure` / `Retry.Failed` → 1; anything else → 125; per-command 1/2 | [07 §3.7](../07-daemon-cli.md) |
| blocking IPC without deadline | `Ipc.send` (G9); Swift `sendSync` (H6); in-daemon `send_async` 2 s | [07 §3.3](../07-daemon-cli.md) |
| stop | `drain_for_stop` (raced against grace), queue drain 0.8 × grace, reaper grace + 2 s, `TimeoutStopSec=30` | [07 §4.2](../07-daemon-cli.md), [08 §A3.4](../08-frontends.md) |
| clocks | `Io_lwt.Clock.now` (monotonic); `with_stall_timeout`, `Health.now`, `Metrics.now_sec` (wall, G12) | [01 §9.2](../01-core.md), [findings G12](../findings.md) |
| durable failure state | WAL record `note_failure`; `.bad` sidecars; `tsync/corrupted/<domain>/` markers; `degraded` in queue stats | [04 §6](../04-checkout-cache.md), [06 §4.7](../06-backends.md) |
