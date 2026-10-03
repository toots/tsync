# Failure model

This file is normative. It owns principle **P3** (one failure model) and principle **P7**
(bounded waits and deadlines): the failure kinds, how each layer recognises them, what a
failure may become when it crosses a boundary, how each layer responds, what every client
error code means and obliges a client to do, and the bound on every wait.

Other files state their own mechanisms and link here for the kinds: the retry ladder and the
breaker ([01 §7–8](../01-core.md)), the durable queue
([durable-queue](durable-queue.md)), the composite over members ([replication](replication.md)),
the IPC contract and the CLI ([07](../07-daemon-cli.md)), the frontend contract
([08](../08-frontends.md)) and the peer wire ([backends/http-proxy](../backends/http-proxy.md)).
Time rules are owned by [01 §4](../01-core.md#4-time-p5). Notes on the OCaml implementation are
in [ocaml/algorithms/failure-model.md](../ocaml/algorithms/failure-model.md).

---

## 1. Goals

- **G1. No silent data loss.** Acknowledged work is completed, or left in a durable, visible,
  automatically retried state. No record is dropped on a failure.
- **G2. No false "not found".** ABSENT is claimed only when an authority that could hold the
  thing was asked and said so. "Could not look" is never reported as "not there".
- **G3. One unexplained failure costs one operation**, not a queue, a domain, a link or a
  process.
- **G4. Link trouble costs time, not work.** Offline, local operations keep working and every
  remote obligation stays owed until the link returns.
- **G5. Stopping is not failing.** A requested stop leaves work owed, counts nothing as a
  failure, and is bounded in time.
- **G6. Every wait is bounded**, and the answer when the bound fires says which kind of failure
  it was.
- **G7. The breaker hears only evidence about the link**, measured on a clock that cannot step.

Out of scope: stores that return a different well-formed object under a key (caught only for
content-addressed chunks, whose key is checked); detecting truly concurrent edits (that is
[conflict-resolution](conflict-resolution.md)); repairing damaged stores automatically (damage is
surfaced with a named repair and never fixed silently).

---

## 2. Assumptions

- **A1. Stores** answer each request with a value, "absent", a refusal, or nothing (an error, a
  hang, a dropped connection). A store's "absent" is authoritative about that store only. A
  conditional create is atomic on the store's side. A store may throttle while healthy.
- **A2. Links** can be down, flapping, slow-but-flowing, or dead without a FIN. A connection
  dead without a FIN is silent forever unless a timer ends it.
- **A3. Members.** Several members can hold the same content (main, replica) or different
  content (archive). The first main is the source of truth for existence.
- **A4. Local resources** fail independently of stores: descriptor exhaustion, disk full, EIO,
  permission.
- **A5. Processes** can be killed at any instruction.
- **A6. Clocks** behave as in [01 §4](../01-core.md#4-time-p5).
- **A7. Clients** (file managers, the OS file-provider framework, Android document consumers,
  the CLI, the tray) retry or give up on their own policy, and some can *latch* a domain
  offline until told otherwise. The owner cannot see a client's retries.
- **A8. Code has bugs.** Some failures will be raised that nobody classified.

---

## 3. The classification

### 3.1 Kinds

Every failure has exactly one **kind**. The layer with the evidence — normally the lowest —
decides it, and it travels upward as data.

| Kind | Subkinds | Definition | Repeating helps? |
|---|---|---|---|
| **ABSENT** | | An authority for the name was reachable and answered that the object does not exist. At domain level, the rules of §5.2 held. | no |
| **EXISTS** | `exists`, `not_empty` | The name is held by something else: a lost conditional create, `EEXIST`, `ENOTEMPTY`. A considered answer about a name; conflict policy resolves it. | no |
| **REFUSED** | `denied`, `read_only`, `other` | The authority answered and will answer the same: permissions or credentials (`denied`); a read-only store or domain (`read_only`); any other permanent refusal whose cause this side cannot name (`other`). | not until configuration changes |
| **INVALID** | | The request is malformed on this side: a bad argument, a malformed key or reference, an unknown action, bad JSON. | no |
| **CORRUPT** | `missing_chunks`, `other` | An answer was obtained and contradicts what it must be: bytes that do not hash to their key, a length that disagrees with the manifest, a manifest with a hole, a range answer longer than asked, an undecodable object or local record, a dependency no member holds after all were asked. `missing_chunks` is a store refusing to take a manifest or version whose chunks it does not hold; it carries the missing chunk keys. The thing exists and is wrong. | no; only repair (for `missing_chunks`, the writer re-sends the named chunks) |
| **UNPREPARED** | `paused`, `other` | Local state cannot express the operation yet: the user paused the domain's remote work and the operation needs it (`paused`); the parent folder has no id here, or a rebuild is refused while metadata is owed (`other`). A user action (resume, sync) or convergence clears it. | not by itself |
| **TRANSIENT** | `link`, `load`, `local` | No considered answer yet. `link`: connection error, TLS or DNS failure, a 5xx that is not throttling, a stall, a transfer truncated below its announced length. `load`: the authority answered "later" (429, a throttling 503, a peer's `busy`, a conflict-in-progress answer to a conditional write). `local`: a resource on this host (`EMFILE`, `ENFILE`, `ENOMEM`, `ENOSPC`, `EDQUOT`, `EIO`, `EAGAIN`, `EBUSY`). | yes, later |
| **UNREACHABLE** | | Derived, never raised by a driver: every candidate that could answer is held by the breaker; TRANSIENT/link persisted past the caller's patience or deadline; a deadline expired while the store was silent; or the owner does not serve the domain named. "The store (or its server) is the problem; stop asking until told." | yes, after the link returns |
| **STOPPING** | | A process stop was requested. The work is untouched and owed on disk. | yes, at next start |
| **CANCELLED** | | The work is no longer wanted: superseded by newer work that has its own record, or the caller withdrew. Its record may be completed. | not applicable |
| **DEADLINE** | | A *waiter's* bound expired (§8). The work may continue and land for the next caller. §7.2 says what the waiter is told. | yes |
| **UNEXPLAINED** | | Anything nobody classified (A8). | unknown |

### 3.2 The failure value

A failure is a typed value carrying:

- `kind` and `subkind`;
- `operation`: what was attempted (a verb and its subject: a member, a key, an item);
- `reason`: one human sentence, safe to show a user;
- `repair` (optional): the command or action that clears it, for CORRUPT, UNPREPARED, REFUSED;
- `retry_after` (optional): a hint from the authority, for TRANSIENT/load.

The kind is never re-derived from `reason` text. A catch-all handler MUST first re-raise
STOPPING and CANCELLED unchanged, then act on the kind, and MUST NOT produce ABSENT.

### 3.3 Properties that drive every policy

1. **Retryable:** TRANSIENT, UNREACHABLE, DEADLINE, and STOPPING (at next start).
2. **Link evidence** (§6): only TRANSIENT/link and a lost probe count *against* a member; a
   considered answer counts *for* it.
3. **Not failures:** STOPPING, CANCELLED and DEADLINE are never counted as failures, never mark
   anything degraded, and never park or drop a record.
4. **UNEXPLAINED** is never ABSENT, never UNREACHABLE, never link evidence. Its handling per
   context is in §7.1.

---

## 4. Detection

A raw signal (errno, status, exception, timer) is interpreted only at the layers listed here.
Every other layer passes the kind through (§5).

**Application logic is driven by signals the application owns, never by third-party error
codes.** An errno, an HTTP status or a library's exception means what its platform, its version
and its configuration make it mean: macOS refuses a connection to a full backlog with the same
`ECONNREFUSED` as a socket nobody listens on, where Linux tells the two apart. So:

- Each external interface has a boundary that translates its conditions into the failure kinds of
  §3, and nothing past that boundary reads the raw code.
- A decision about the application's own state (is an owner running, does an object exist, is a
  peer alive, did a write land) is made from a signal the application owns and defines: the
  ownership lock, a holder record, a protocol reply, a conditional write's outcome, a marker. An
  external code may hint at it, but never decides it.
- Where one external code covers conditions the application must tell apart, the boundary reports
  the ambiguity (the kind that covers both), and the caller resolves it with its own signal.

### 4.1 Local filesystem errors

One table for every local filesystem access: a local-filesystem store driver, local state
files, staged data, the cache, durable records.

| errno | Kind |
|---|---|
| `ENOENT`, `ENOTDIR` on read, stat, open or list | ABSENT |
| `EEXIST` on an exclusive create or claim-by-link | EXISTS/exists |
| `ENOTEMPTY`, `EEXIST` on rmdir or rename over a directory | EXISTS/not_empty |
| `EINTR` | retried inline; never surfaces |
| `ESTALE`, `ETIMEDOUT`, `EHOSTDOWN`, `EHOSTUNREACH`, `ENETDOWN`, `ENETUNREACH`, `ECONNRESET`, `ECONNREFUSED`, `ECONNABORTED`, `ENOTCONN`, `ENOLINK`, `EREMOTEIO` (a network or removable filesystem) | TRANSIENT/link |
| `EMFILE`, `ENFILE`, `ENOMEM`, `ENOBUFS`, `ENOSPC`, `EDQUOT`, `EIO`, `EAGAIN`, `EBUSY`, `ETXTBSY` | TRANSIENT/local |
| `EACCES`, `EPERM` | REFUSED/denied |
| `EROFS` | REFUSED/read_only |
| any other errno (`ENAMETOOLONG`, `ELOOP`, `EINVAL`, `EISDIR`, `EXDEV`, `EFBIG`, …) | REFUSED/other |

- The same errno has the same kind on every verb.
- A local-filesystem store has its own breaker cell; TRANSIENT/link from it counts against it
  (§6).
- A local store writes a chunk, reads it back, and a mismatch between the bytes and the key is
  CORRUPT (filed as a corruption marker per [02](../02-remote-model.md)).

### 4.2 HTTP object stores

| Signal | Kind |
|---|---|
| 2xx | value |
| 404, or a per-key "no such key" inside a bulk answer | ABSENT (a delete of an absent key is success) |
| 412 on a conditional create | EXISTS/exists; the holder is then read |
| 409 "conditional request conflict" (a concurrent conditional write in progress) | TRANSIENT/load |
| 429; 503 carrying a throttling indication (a throttling error code such as `SlowDown`, or a `Retry-After` header) | TRANSIENT/load, with `retry_after` when given |
| any other 5xx | TRANSIENT/link |
| connection, DNS or TLS failure; a failed redial; a stall; a body shorter than its framing announced | TRANSIENT/link |
| `EMFILE`, `ENFILE`, `ENOBUFS`, `ENOMEM` while opening a socket | TRANSIENT/local |
| a per-key error other than "absent" inside a 2xx bulk answer (for example a bulk delete) | TRANSIENT/load for that key when the code is service-internal (internal error, slow down, service unavailable), REFUSED/other otherwise. It MUST be raised, never dropped, and is never evidence against the link: the request itself was answered |
| 401, 403; a credential that cannot be minted because the grant is invalid or revoked | REFUSED/denied |
| a network failure while minting a credential | TRANSIENT/link |
| any other 4xx; a redirect | REFUSED/other |
| a range answer longer than asked | CORRUPT (the store ignored the range) |
| a response body that cannot be decoded | CORRUPT |

**Outcome-unknown conditional writes.** A conditional create whose outcome is unknown (a
timeout, a conflict-in-progress answer, a lost connection after the request left) MUST be
resolved by retrying the same conditional create or by reading the key. It MUST NOT be replaced
by an unconditional write.

### 4.3 A peer tsync store (http-proxy client)

The peer wire's statuses are owned by [backends/http-proxy](../backends/http-proxy.md). Read as
kinds:

| Peer answer | Kind |
|---|---|
| 404 on an object, empty body | ABSENT |
| 404 with a non-empty body (the body names a domain the server does not serve) | REFUSED/denied: the domain is not served there; never ABSENT. Clients SHOULD accept this form; servers MUST NOT produce it (they answer 401) |
| 404 on an optional capability | "no opinion"; not a failure |
| 409 with `x-tsync-kind` | the kind or subkind it names (a value from §3.1, such as `corrupt`, `exists`, `not_empty`, `unprepared`, `invalid`), carrying the server's reason; an unknown value → REFUSED/other |
| 409 with `x-tsync-kind: missing_chunks` | CORRUPT/missing_chunks, carrying the chunk keys listed in the answer. The writer re-sends exactly those chunks and retries the write once; a second refusal parks the record |
| 409 without `x-tsync-kind` | REFUSED/other, carrying the server's reason. Clients SHOULD accept this form; servers MUST NOT produce it |
| 403 | REFUSED/read_only |
| 401 (a bad signature, or a domain the server does not serve) | REFUSED/denied. If the answer's `Date` differs from the local wall clock by more than the signature window, the reason says "clock skew". |
| 500 | TRANSIENT/link |
| 503 `busy`, 429 | TRANSIENT/load |
| a framed answer truncated | TRANSIENT/link |

A peer server maps its own kinds onto the wire so the client can recover these kinds: ABSENT
distinct from every refusal, TRANSIENT/load distinct from TRANSIENT/link, `read_only` and
`denied` distinct from other refusals, and every permanent kind distinct from every transient
one. UNEXPLAINED travels as a transient server failure.

### 4.4 Breaker and composite

| Layer | Signal | Kind |
|---|---|---|
| Breaker ([01 §8](../01-core.md#8-health-breaker)) | a member held | asks to it fail fast as UNREACHABLE (for that member) |
| | a probe unanswered within `PROBE_TIMEOUT` | a lost probe |
| Composite ([replication](replication.md)) | every readable candidate held or failing transiently, and no archive answers | UNREACHABLE, carrying the first candidate's failure as its reason |
| | the first reachable source of truth answers absent | ABSENT |
| | a replica or archive answers absent while a main is unreachable | UNREACHABLE (§5.2) |
| | no writable member | REFUSED/read_only |
| | a write to a non-main copy while a main is down | TRANSIENT (UNREACHABLE of the main, as the reason) |

### 4.5 Content

| Signal | Kind |
|---|---|
| chunk bytes do not hash to their key after one re-fetch | CORRUPT |
| a manifest hole; a slot inheriting from a base that does not exist | CORRUPT |
| a chunk's length differs from the manifest's | CORRUPT |
| a chunk a manifest names that no member holds, all asked | CORRUPT (a dangling reference), not ABSENT |

### 4.6 Local unpublished data

Staged bodies and staged manifests are the only copy of the user's unpublished bytes. Reading
them to upload, or to answer a local read, follows these rules:

- A slot the staged manifest marks as a hole is zeros, explicitly.
- Bytes past the end of a staged body, within the file's size, are zeros: a staged body is
  sparse, and its length is not the file's size.
- Opening or reading a staged body that fails with ENOENT: re-read the file's staged state
  under its per-key content lock. If it no longer names that body (superseded by a newer write,
  or the file was deleted), the upload is CANCELLED. If it still names it, the staged state is
  CORRUPT: nothing is published, the record stays, and the item is surfaced.
- Any other failure is classified by §4.1 (TRANSIENT/local is retried later; REFUSED parks).
- A failure to read unpublished data MUST NOT be replaced by zeros or by any other substitute,
  and MUST NOT publish anything. A local read that fails returns an error to the application,
  never substituted bytes.
- An undecodable staged sidecar is CORRUPT: it is set aside under a new name, never deleted.

Rebuildable local data (the chunk cache) differs: a read that fails, for any reason, MAY be
treated as "not held" provided the caller then fetches from an authority; nothing is ever
substituted.

### 4.7 Local state files and durable records

For local files the system relies on (last-sync mark, applied log, cursor copies, WAL records,
folder-id index, durable-queue records):

- ENOENT → ABSENT, and the owner's rule for "none recorded" applies.
- Undecodable → CORRUPT: set aside, surfaced, never deleted; the owning file states how to
  proceed.
- Any other failure → classified by §4.1. The consumer MUST NOT proceed as if the file were
  absent. (A transient read error taken as "never synced" triggers a full rebuild.)

Durable-queue record reads follow the same rule: a record gone is already completed; an
unparseable one is CORRUPT; any other failure leaves it for the next rescan
([durable-queue](durable-queue.md)).

### 4.8 Process, request handler, clients

| Layer | Signal | Kind |
|---|---|---|
| Process | stop requested | STOPPING, raised out of every backoff, ladder, queue wait, link wait and settle |
| Request handler | malformed request, malformed item reference, unknown action | INVALID |
| | a domain this owner does not serve | UNREACHABLE (the domain's server is not here) |
| | a configured domain not yet serving (starting) | TRANSIENT/local |
| | an operation needing remote work on a paused domain | UNPREPARED/paused |
| | a well-formed reference that resolves to nothing | ABSENT |
| | a mutating action on a read-only domain | REFUSED/read_only |
| | an errno from the core | §4.1 |
| Client | cannot connect to, or lost the connection to, the owner | TRANSIENT/local, from the client's view; never UNREACHABLE, never ABSENT |
| | no reply within the client's deadline (§8.2) | DEADLINE, reported like a transport failure |
| | a reply with no `code`, or a `code` it does not know | treated as `internal` |

---

## 5. Propagation

### 5.1 Rules

- **R1. The kind is data.** It crosses every boundary in a typed field: an exception variant, a
  status code, a wire `code`. It is never re-derived from text.
- **R2. Refine or aggregate, never weaken.** Upward, a kind may only be refined by a layer with
  more evidence, or aggregated. It is never turned into a more confident kind.
- **R3. Aggregation is monotone in doubt.** When answers combine, the result is the most
  doubtful one that could change the answer: `value > ABSENT (authoritative) > UNREACHABLE`.
- **R4. A batch failure is not a per-item answer.** If a batched request fails, every item is
  unanswered: the layer re-asks each item singly or raises.
- **R5. STOPPING and CANCELLED pass through every layer unchanged.**

### 5.2 Absent versus could-not-look

ABSENT has exactly three sources:

1. a store's explicit absence answer for that exact key (§4.1–4.3);
2. a composite whose first reachable source-of-truth member answered absent, per §4.4; a
   replica's or archive's absence never stands for the domain while a main is unreachable;
3. a local ENOENT/ENOTDIR on local state (§4.1, §4.7).

Consequences:

- A listing that fails, or fails partway through its pages, is a failure, never an empty or
  shorter listing.
- A read of a journal entry, a manifest, a marker or a mark that fails is a failure, never "no
  entry".
- Any action that is justified only by absence — deleting, overwriting, allocating a name,
  zero-filling, advancing a mark past an entry, dropping a reference, reporting "no children" —
  MUST have ABSENT, and MUST NOT proceed on any other kind.
- ABSENT of a *dependency* (a manifest names a chunk nobody holds) is CORRUPT; ABSENT of the
  *requested* item stays ABSENT.

### 5.3 Permitted transformations

| Boundary | Permitted |
|---|---|
| raw signal → driver | §4, the only place a raw errno or status is read |
| driver → retry ladder | TRANSIENT retried; after the last attempt it leaves with its kind, member and operation |
| ladder → breaker | §6 |
| member → composite | a held member → UNREACHABLE fast; source-of-truth ABSENT → ABSENT; all failed → UNREACHABLE; a batch failure → re-ask singly |
| composite → content | a dependency's ABSENT → CORRUPT |
| content → checkout | CORRUPT stays CORRUPT; a waiter's DEADLINE is that waiter's only (§7.2) |
| any layer → queue | per §7.1 |
| core → request handler | per §7.2 |
| handler → kernel, peer, CLI | per §7.3–7.5 |

### 5.4 Forbidden transformations

| # | Forbidden | Why |
|---|---|---|
| X1 | TRANSIENT, UNREACHABLE, UNEXPLAINED, STOPPING, CANCELLED, DEADLINE or CORRUPT → ABSENT, "empty", "no entries", "hole" or "never" | G2; it becomes data loss when the caller writes on "absent" |
| X2 | any kind → UNREACHABLE, except held members, TRANSIENT/link that exhausted the caller's patience, a deadline on a silent store, and an unserved domain (§3.1) | UNREACHABLE latches clients; a local fault must not take a domain down (G3) |
| X3 | UNREACHABLE → a code a client retries hot | the client never learns to back off (G6) |
| X4 | STOPPING, CANCELLED or DEADLINE → a counted failure, degraded, parked or dropped | G5 |
| X5 | a replica's or archive's ABSENT → the domain's ABSENT while a main is unreachable | a stale copy is not an authority |
| X6 | a batch failure → per-key ABSENT | a caller told "absent" writes a copy missing the file |
| X7 | TRANSIENT/load, TRANSIENT/local, UNEXPLAINED or a waiter's DEADLINE → evidence against a member | a busy peer or a local bug is not a dead link (G7) |
| X8 | a kind → no code on the wire, or a native client dropping the code | the receiver cannot tell `not_found` from `unreachable` |
| X9 | a failure reading local unpublished data → zeros or any substitute | uploads zeros as the file's content |

---

## 6. Link health evidence

What the breaker ([01 §8](../01-core.md#8-health-breaker)) hears:

| Outcome of a request to a member | Breaker input |
|---|---|
| success | answered |
| ABSENT, EXISTS, REFUSED, CORRUPT (a considered answer) | answered |
| TRANSIENT/load (429, throttling 503, peer `busy`) | answered: the link is up and the member is merely busy |
| TRANSIENT/link, including a stall and a network-filesystem errno from a local store | lost; a stall also increments the member's timeout tally |
| a per-key refusal inside an answered bulk request | answered |
| a deliberate probe that fails or exceeds `PROBE_TIMEOUT` | probe lost |
| TRANSIENT/local | nothing |
| UNEXPLAINED | nothing |
| STOPPING, CANCELLED, a waiter's DEADLINE that cancelled the request | nothing |

- A long poll (a wait on a cursor) is never a probe, and its expiry is not a failure.
- A member that only ever throttles never trips; it is slowed by its own `retry_after` and by
  the ladder's backoff.

---

## 7. Response policy

### 7.1 Per kind and layer

"Owed" means the durable record stays; queue mechanics (backoff, park, re-arm, degraded
marking) are owned by [durable-queue](durable-queue.md).

| Kind | Ladder | Composite | Ordered queue (own metadata ops) | Ordered queue (replica/backfill jobs) | Keyed queue (uploads) | Inbound peer entry |
|---|---|---|---|---|---|---|
| ABSENT | return "no value" | answer if from the source of truth, else ask the next | the op's own rules decide | job's own rules decide | local source gone → §4.6 | per [wal-and-journal](wal-and-journal.md) |
| EXISTS | return the holder | the first main arbitrates | conflict table ([conflict-resolution](conflict-resolution.md)) | job's own rules | n/a | conflict table |
| REFUSED | one attempt | pass on | park | park; copy marked degraded | park | step aside |
| INVALID | n/a | n/a | park | park; degraded | park | step aside |
| CORRUPT | one attempt; a chunk is re-fetched once | ask the next member for a good copy | park | park; degraded | park | step aside |
| UNPREPARED | n/a | n/a | refused before anything changes | n/a | park | step aside |
| TRANSIENT (any) | retry with backoff up to the attempt limit or the caller's deadline | fail fast on a held member when another candidate exists; the last candidate is always asked | block at the head with backoff | block at the head with backoff | requeue at the tail with backoff | abort the pass without advancing |
| UNREACHABLE | not retried by the ladder; the hold ends it | fail over to a readable copy, then archives; writes are never redirected | block at the head | block at the head | tail with backoff | abort the pass |
| STOPPING | end at once | pass through | leave the record, uncounted | leave the record | leave the record | end the pass; nothing advances |
| CANCELLED | pass through | pass through | complete the record | complete the record | complete the record | n/a |
| DEADLINE | n/a | n/a | n/a | n/a | n/a | abort the pass |
| UNEXPLAINED | retried as TRANSIENT, never link evidence | pass on | park | park | tail with backoff | step aside |

- **Park** keeps the record on disk, takes it out of the running order, surfaces it with its
  reason, and re-offers it on the re-arm cadence of [durable-queue](durable-queue.md). Every
  queue that parks re-arms, so a repaired credential resumes work without a restart.
- **Step aside** records the entry as unapplied with its reason, retries it on every pass, and
  surfaces it; the pass continues with later entries only where
  [wal-and-journal](wal-and-journal.md) allows.
- Nothing in this table removes a record because it failed. A copy with a parked replica or
  backfill job is marked degraded by a durable marker, with its repair, for as long as any of
  its jobs is parked ([durable-queue](durable-queue.md), [replication](replication.md)).
- UNEXPLAINED parks ordered work because a local bug must not block everything behind it; it
  is retried in a ladder because a request retried a few times costs seconds.

### 7.2 Client error codes

The owner answers every failed request with a `code` from the IPC contract
([07](../07-daemon-cli.md)). This table is the only mapping from kinds to codes; every socket,
the in-process bridge and the router use it, and every failure carries a code.

| `code` | Kinds | Tells the client | The client MUST |
|---|---|---|---|
| `not_found` | ABSENT | the item does not exist, authoritatively | drop the item from its view; treat a delete of it as success |
| `exists` | EXISTS/exists | the name is taken | not resend unchanged; re-read, pick another name, or apply its conflict rule |
| `not_empty` | EXISTS/not_empty | the folder has children | not resend unchanged |
| `read_only` | REFUSED/read_only | the domain or store refuses writes | stop offering writes until the configuration changes |
| `denied` | REFUSED/denied | permission or credentials refused | not retry automatically; show the reason |
| `invalid` | INVALID | the request is malformed, or names something this owner does not serve | not resend unchanged |
| `unreachable` | UNREACHABLE; DEADLINE while the store was silent for the whole wait; TRANSIENT/link that exhausted the request's patience | the store, or the domain's server, cannot be reached; nothing local is wrong | back off requests that need the store for this domain; it MAY latch the domain offline, and then MUST unlatch at the domain's recovery notice or at any later successful reply |
| `busy` | TRANSIENT/load that exhausted the request's patience; the owner refusing admission under load | the store or owner is up but will not serve this now | retry later with backoff, no sooner than a `retryAfter` hint when the reply carries one; MUST NOT latch |
| `paused` | UNPREPARED/paused | the user paused this domain's remote work, and the operation needs it | not retry until the domain is resumed (status or a notice says so); MUST NOT latch; may show the pause |
| `internal` | CORRUPT, UNPREPARED/other, REFUSED/other, TRANSIENT/local, STOPPING, CANCELLED, DEADLINE while the work was progressing or waiting on local work, UNEXPLAINED | this operation failed; the domain is not known to be unavailable | MAY retry with its own backoff; MUST NOT latch; show the `error` prose, which names the repair where one exists |

- `not_found` is sent for ABSENT and nothing else. `unreachable` is sent for store or server
  unavailability and nothing else: it is the only code that may latch a client.
- A client MUST treat a missing or unknown `code` as `internal`, and a transport failure or its
  own deadline expiry like `internal` (never `unreachable`, never `not_found`): a restarting
  owner must cost one retry, not the domain. One exception: a host whose spec unlatches the domain
  when its owner comes back MAY report a connection nothing accepted (no owner listening) as
  `unreachable` ([file-provider §6.10](../frontends/file-provider.md#610-mapping-codes-to-the-framework)).
- **Recovery notice.** After an owner has answered `unreachable` for a domain, it MUST publish
  a recovery notice to that domain's subscribers when a store request for the domain next
  succeeds. Its form is owned by [08](../08-frontends.md).
- **DEADLINE split.** When a request's deadline fires, the owner answers `unreachable` if the
  request was waiting for a store and heard nothing from any store for the whole wait, and
  `internal` ("still in progress; retry") otherwise. The work continues either way.
- Native clients (macOS, Android, tray, file-manager plugins) MUST keep the code through their
  own error types.

### 7.3 Kernel (FUSE)

ABSENT → `ENOENT`; EXISTS → `EEXIST` / `ENOTEMPTY`; REFUSED/denied → `EACCES`;
REFUSED/read_only → `EROFS`; INVALID → `EINVAL`; an errno raised by local I/O passes through
unchanged; everything else → `EIO`, recorded for status.

### 7.4 Peer server

A tsync server answering peers maps kinds so that §4.3 recovers them, naming every permanent
kind in `x-tsync-kind` beside its 409 and sending `Date` on every 401; the statuses are owned
by [backends/http-proxy](../backends/http-proxy.md). Admission refusal under load is
TRANSIENT/load (`busy`).

### 7.5 CLI exit status

`0` success; `1` every classified failure, printing its reason and repair as a sentence (CORRUPT
and UNPREPARED included); `2` a refusal about the invocation's environment, as defined per
command in [07](../07-daemon-cli.md); `125` only for UNEXPLAINED. A classified failure never
prints a stack trace.

---

## 8. Deadlines and bounded waits (P7)

Nothing waits forever on a peer, a store, a lock or another process. Every wait has one of:

- a **stall bound**: it fails once there has been no progress for a window;
- a **deadline**: it fails once a total time has passed;
- a **liveness bound**: it continues only while a separate cheap check keeps answering in time.

Every bound uses the monotonic clock. When a bound fires, the waiter gets the kind stated below;
the work behind it is cancelled only where the table says so.

### 8.1 Inside a process

| Wait | Bound | Parameter | On expiry |
|---|---|---|---|
| one HTTP request | stall | the driver's stall window ([06](../06-backends.md)) | TRANSIENT/link; request cancelled |
| a retry ladder | attempts and the caller's remaining deadline ([01 §7](../01-core.md#7-retry-ladder)) | `LADDER_ATTEMPTS` | the last failure |
| a breaker probe | deadline, retries included | `PROBE_TIMEOUT` | probe lost |
| a long poll on a cursor | the poll's duration plus the stall window | [backends/http-proxy](../backends/http-proxy.md), [06](../06-backends.md) | not a failure; poll again |
| a frontend read waiting for uncached bytes | deadline | `READ_DEADLINE` | DEADLINE for that read; the fetch continues |
| a lock guarding local state | transitively: a lock is never held across a store, peer or IPC wait ([01 §6.2](../01-core.md#62-guarantees-the-logic-requires)) | — | — |
| a pool slot | transitively: every holder is bounded | — | — |
| an upload waiting for link admission | stop, cancellation, and the governor's rules ([uplink-governor](uplink-governor.md)) | — | STOPPING or CANCELLED |
| settling queues before exit | deadline | [durable-queue](durable-queue.md) | work left owed |
| a stop | `STOP_GRACE` ([07](../07-daemon-cli.md)) | — | work left owed |
| an advisory IPC send | deadline | owned by [07](../07-daemon-cli.md) | dropped, logged once |
| a partial IPC request line | deadline | `IPC_LINE_DEADLINE` | connection closed |

**Background loops** (journal polling, maintenance sweeps, queue workers, deferred-job workers,
lease renewal, status collection): every wait inside a pass has one of the bounds above, so a
pass either makes progress or fails within a bound. A loop whose pass fails backs off and runs
again; it never exits silently. A loop that has work pending and has made no progress for
`LOOP_STALL_WARNING` is surfaced (§9) and keeps reporting its work as pending.

### 8.2 Requests between processes

- **Owner side.** The owner MUST answer every request within `REQUEST_DEADLINE`, except
  requests the IPC contract ([07](../07-daemon-cli.md)) designates as **bulk** (those that move a
  whole file's bytes or walk a subtree). A bulk request is bounded by `PROGRESS_DEADLINE`: it
  fails when no byte or entry has progressed for that long. On expiry the owner answers per the
  DEADLINE split of §7.2, and the work continues.
- **Client side, ordinary requests.** A client MUST abandon a request after
  `REQUEST_DEADLINE + CLIENT_DEADLINE_MARGIN`, so the owner's coded answer normally arrives
  first and the client's own bound fires only when the owner is wedged.
- **Client side, bulk requests.** While waiting, the client sends the contract's **liveness
  probe** on a separate connection every `LIVENESS_INTERVAL` with deadline `LIVENESS_DEADLINE`,
  and abandons the bulk request when a probe misses. The owner MUST answer the liveness probe
  from memory: without awaiting a store, a lock held across I/O, or a pool.
- An abandoned request is reported per §4.8. The client closes that connection; a late reply is
  never read as the answer to a later request.
- Blocking and asynchronous client calls alike obey these bounds, including one-shot CLI
  commands and extension probes.

### 8.3 Parameters

| Parameter | Recommended | Constraint |
|---|---|---|
| `READ_DEADLINE` | 15 s | |
| `REQUEST_DEADLINE` | 30 s | > `READ_DEADLINE` |
| `PROGRESS_DEADLINE` | 60 s | ≥ the longest stall window of the domain's stores |
| `CLIENT_DEADLINE_MARGIN` | 5 s | > 0 |
| `LIVENESS_INTERVAL` / `LIVENESS_DEADLINE` | 10 s / 5 s | |
| `LOOP_STALL_WARNING` | 60 s | |
| `PROBE_TIMEOUT` | 10 s | [01 §15](../01-core.md#15-parameters) |

---

## 9. Surfacing

A failure a person must act on is shown in status and by the CLI, not only in a log line.
Status MUST show:

- each tripped breaker, with its reason and the hold's end;
- parked records and unapplied peer entries, with counts and reasons;
- degraded copies, with their repair;
- corruption markers and set-aside local files;
- stalled loops and queues (§8.1);
- the reason of the last failure of each owed record.

A failure surfaced only in a log line below warning level is not surfaced.

---

## 10. Conformance

An implementation MUST exhibit:

- **Absent is authoritative.** A store or local read failing with anything but an absence
  answer never yields "absent", "empty", "no entries", a hole, or an advanced mark; injecting a
  transient failure into a listing, a journal-entry read, a marker read or a mark read aborts
  the operation without side effects.
- **Batch.** A failed bulk read re-asks singly or fails; it never marks items absent.
- **Replica absence.** With the main unreachable and a replica answering absent, the domain
  answers `unreachable`, not `not_found`.
- **Peer refusals.** A peer's 409 is read by its `x-tsync-kind`; an unknown value is
  REFUSED/other; `missing_chunks` makes the writer re-send exactly the listed chunks; a 404
  with a body is never taken as absent.
- **Unpublished data.** An upload whose staged body cannot be opened for a reason other than
  ENOENT publishes nothing and stays owed; with ENOENT it is cancelled if superseded and CORRUPT
  otherwise; no zeros are ever published in place of unreadable staged bytes.
- **Breaker evidence.** 429, a throttling 503 and per-key refusals in a bulk delete never trip a
  member; stalls, connection failures and a local store's `ESTALE`/`ETIMEDOUT` do; a local
  descriptor exhaustion does not; an UNEXPLAINED failure does not. An S3
  `ConditionalRequestConflict` is retried as the same conditional write.
- **Codes.** Each row of §7.2 produces its code: a corrupt chunk and an operation under a
  folder without an id answer `internal` with a repair; an unreachable main answers
  `unreachable`; a store that keeps throttling answers `busy`; a paused domain answers `paused`
  to an operation that needs remote work; a revoked credential answers `denied`; a malformed
  reference answers `invalid`; an unserved domain answers `unreachable`; every failure carries a
  code.
- **Clients.** A missing or unknown code is `internal`; a transport failure never latches, except
  no owner listening on a host that unlatches when the owner returns; only `unreachable` latches,
  and a recovery notice unlatches.
- **Deadlines.** A wedged owner makes a client call fail within
  `REQUEST_DEADLINE + CLIENT_DEADLINE_MARGIN`; an owner waiting on a silent store answers
  `unreachable` within `REQUEST_DEADLINE`, and the fetch continues and serves the next caller; a
  bulk request over a slow but flowing link completes.
- **Stop.** A stop during any wait ends it with STOPPING within the grace, counts no failure,
  degrades nothing, and leaves every record on disk.
- **Re-arm.** A parked record of any queue runs again after its cause is fixed, without a
  restart.
- **CLI.** A CORRUPT or UNPREPARED failure exits 1 with a sentence naming the repair; only an
  UNEXPLAINED failure exits 125.

---

## 11. Rationale

- **Only `unreachable` latches.** A daemon restart once latched a domain offline. A
  conservative mapping costs retries; a liberal one costs the domain. Corruption and missing
  local preparation are faults of one operation, not of the store, so they map to `internal`.
- **A malformed request is `invalid`, not `not_found`.** A client told "absent" acts on it.
- **Throttling is not link failure.** A throttling store or a peer applying deliberate
  backpressure is up; tripping it fails reads over to replicas or holds them for minutes while
  the link works.
- **Unknown is transient in requests, parked in ordered work.** A request retried a few times
  costs seconds; an ordered queue blocked by a local bug once stalled hours of work behind one
  failing op.
- **Stall timeouts for requests, deadlines for waiters.** Large bodies on slow links are
  legitimate; a person waiting is not. DEADLINE is its own kind because the work behind it
  continues.
- **The DEADLINE split.** A deadline is evidence about the store only if the store was silent;
  a fetch that is progressing is not an outage.
- **Liveness probes for bulk requests.** A fixed deadline would cut a slow but healthy transfer;
  no deadline lets a wedged owner hang a client forever.
- **Park and re-arm everywhere.** Work left parked until a restart looks owed but never runs.
- **Park, never drop.** A dropped replica job leaves the copy silently short until someone runs
  a repair; a parked one keeps retrying and keeps the copy visibly degraded.
- **`busy` apart from `unreachable`.** A throttling store is up; latching it offline would need
  a recovery notice that no breaker transition ever produces.
- **No unconditional fallback for conditional writes.** It turns a race into an overwrite of the
  winner.
