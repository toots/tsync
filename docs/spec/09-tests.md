# 09 — Conformance

Scope: what an implementation must demonstrate before it may claim to implement this specification,
and how the demonstration is built: the tiers of checks, how golden files are read, the seams a
harness needs, the doubles it plugs in, fault and crash injection, property-based testing of
the merge, and the discipline that makes a passing suite mean something.

The properties themselves are not listed here. Each is stated once, in the **Conformance** section of
the file that owns the rule (§3). This file owns the method.

---

## 1. What conformance means

An implementation conforms when, for every Conformance property of every file in §3, it provides a
check that:

1. exercises the property through the seams of §5, not through the implementation's internals;
2. would fail if the property were violated (§10);
3. runs in the tier the property needs (§2).

tsync's claims are mostly about **sequences across peers and failures**: write, rename offline, crash,
let a peer publish, reconnect, collect garbage, then look at what each client and each store hold. A
conforming suite is therefore dominated by scenario checks that drive real components through such
sequences and compare the resulting state, rather than by unit checks of single functions.

Checks MUST NOT depend on elapsed time for their verdict (§10.3). A property phrased with a duration
("within the deadline") is checked on a controllable clock (§5.6), or as a round-trip count.

## 2. Tiers

| Tier | What runs | Hermetic | Required for conformance |
|---|---|---|---|
| Pure | codecs, key derivations, parsers, planners, renderers, the merge | yes | yes |
| Contract | one component against doubles of its neighbours: store drivers, the composite, failover, the read path, queues, the uplink governor | yes | yes |
| Scenario | the engine of one or two clients against real local stores in a scratch directory, driven step by step (§6), state compared with a golden file (§4) | yes | yes |
| Crash and fault | scenarios under injected failures, process kills and simulated power loss (§7) | yes | yes |
| Property | the merge enumerated over small trees; generated operation pairs and interleavings with shrinking (§8) | yes | yes |
| Multi-process | several real processes sharing one machine's domain state (§7.5) | yes | yes |
| Platform | each frontend on its operating-system surface: a real FUSE mount, the macOS extension against a real owner, the Android bridge called from foreign threads | per platform | yes, on that platform |
| Live store | every driver against the real service it targets | no (credentials) | yes, per driver, before a driver is declared supported |
| Whole system | two mounted clients converging under load and random kills (stress); a real configured domain (live) | no | SHOULD, before a release |

A hermetic check uses only the scratch directory, local stores, spawned processes and fakes. A
non-hermetic check that lacks its credentials or configuration MUST report "not run", never pass (§10.1).

## 3. Where the properties are

| Subject | Conformance section in |
|---|---|
| Names and keys, chunking and chunk keys, references, retry ladder, health breaker, IPC framing, time | [01-core.md](01-core.md) |
| Backend entities, invariants, projection of the log onto the tree | [data-model/backend.md](data-model/backend.md) |
| Byte formats, the remote interface, dedup, versions, integrity | [02-remote-model.md](02-remote-model.md) |
| Retention and garbage collection | [algorithms/gc.md](algorithms/gc.md) |
| Commands, log entry, cursor, tree head, local sync records, applied log, change feed formats | [03-journal-sync.md](03-journal-sync.md) |
| Before-values, upload, fetch, push, projection, state read, recovery, log retention | [algorithms/publication.md](algorithms/publication.md) |
| The cases every suite covers, each tied to a result of the theory (§12 there) | [algorithms/change-algebra.md](algorithms/change-algebra.md) |
| Enacting a merge, outcomes by operation pair, the invariants after quiescence (§10 there) | [algorithms/conflict-resolution.md](algorithms/conflict-resolution.md) |
| Local formats, file operations, staged writes | [04-checkout-cache.md](04-checkout-cache.md) |
| Local entities and the owner's state | [data-model/local-cache.md](data-model/local-cache.md) |
| Materialisation, read-ahead, cache bounds | [algorithms/read-path-and-cache.md](algorithms/read-path-and-cache.md) |
| Durable queue and persistence | [algorithms/durable-queue.md](algorithms/durable-queue.md) |
| Failure kinds, propagation, deadlines | [algorithms/failure-model.md](algorithms/failure-model.md) |
| Config and whole-domain operations | [05-ops-config.md](05-ops-config.md) |
| Store contract, composite, admission | [06-backends.md](06-backends.md) |
| Roles, deferred jobs, write guard, repair | [algorithms/replication.md](algorithms/replication.md) |
| Uplink governor | [algorithms/uplink-governor.md](algorithms/uplink-governor.md) |
| Each driver | [backends/](backends/) |
| Security mechanisms | [algorithms/security-model.md](algorithms/security-model.md) |
| Process model, ownership, lifecycle, IPC, CLI | [07-daemon-cli.md](07-daemon-cli.md) |
| Frontend contract, shared request handler | [08-frontends.md](08-frontends.md) |
| Each frontend | [frontends/](frontends/) |

## 4. Golden files

### 4.1 What a golden file is

A scenario prints the state it reached in a canonical text form, and the print is compared with a
committed golden file. The print covers, per client: the tree with content read back through the read
path, the sync state (the position, the before-values and the pending set they give, the in-flight
record), the upload records with their state, the applied log; and, per store, a normalised dump of
every object: the log entries by number, the tree head, the takeovers, the cursor, and the tree's
records.

A golden file pins everything it prints, but only part of it is specification. A golden comparison is
one assertion among others: the check MUST also verify that the process exited successfully and that
its declared count of checks ran (§10.1).

### 4.2 Semantic and incidental content

A conforming implementation MUST reproduce the **semantic** facts of every golden file. It MAY print
them differently and re-baseline the **incidental** parts. A reviewer MUST treat a change to a semantic
fact in a golden file as a change of behaviour, to be justified by the specification.

| Printed element | Semantic (must be reproduced) | Incidental (may be re-baselined) |
|---|---|---|
| Echoed step list | — | all |
| Tree lines | which paths exist; file or folder; logical size; how many of a file's chunks are local; pending or not; etag equality and change | line syntax, order, field names |
| Content lines | the exact bytes a reader gets; that a read fails | quoting, escaping |
| Sync state and owed work | the position; which keys are pending, each with its before-value; whether an in-flight record remains; which upload records remain, and the state of each | rendering |
| Applied log / change feed | which ops a client recorded, in order, and the fields each op carries | field order, spacing |
| Chunk objects | which chunk objects exist; that a chunk key is a function of its bytes | shard path, syntax |
| Manifests | that a manifest exists, filed under its folder id; its recorded name, size, chunk list and digests | leaf-hash spelling where the frozen format does not require it |
| Folder, anchor, symlink, version, corruption and collection objects | the object kinds present and their relations: which folder a marker names, where the anchor places it, how many versions per path, which chunks are marked or mid-collection, the collection phase | syntax, alias numbering, phase wording |
| Log, tree head, takeovers and cursor | which entries exist, by number; the author and the commands of each (key, value before, value after); the tree head; which takeovers exist and whom each names; which entry the cursor names | rendering; the order of the commands within an entry |
| Counts from maintenance | the numbers | the sentence around them |
| Request replies | field set and values, reference grammar, cursor semantics, `stale`, `unnamed`, error `code` | key order; prose, except where the owning file makes the text a contract |
| Human-readable status and menus | the facts each row states: numbers, states, which warnings appear, what is omitted when zero | layout, padding, units, phrasing |
| Check lines and their tally | the number and identity of properties checked | presentation |

Frozen backend formats ([02](02-remote-model.md)) are an exception: wherever a golden file shows bytes
or keys that the frozen format defines, they are semantic in full.

### 4.3 Normalisation

Values that vary between runs MUST be replaced by stable aliases before comparison, and an
implementation's harness MUST provide equivalents:

- random folder ids → `<folder-N>`, numbered by walking from the root, children in name order, then
  the ids only a log entry or a before-value names, in order of first appearance; the root id is a
  constant and printed raw;
- file ids → `<file-N>`, numbered in order of first appearance in the output;
- client uuids → the client's configured name; feed keys → `<feed-N>`, numbered per client in
  applied-log order; version timestamps → `#N`, oldest first;
- mtimes → `<mtime>` / `<zero>`; pin deadlines → `<deadline>`;
- walk ids in page cursors → `<walk>`; a cursor's generation → `<cursor>` / `<empty>`.

Entry numbers are deterministic and are printed raw.

Values that depend on normalised inputs (byte totals of manifests embedding mtimes, for example) MUST
NOT be printed. Wall-clock values MUST NOT appear in golden files.

### 4.4 Cross-implementation vectors

Golden vectors for frozen algorithms (chunk keys, stored-key hashes, log-entry and GC-job key
spellings) are shared with every other program that reads a store, such as a bucket-side verifier or
delete worker. They are semantic in full, and their line format is itself a contract with those
programs. The vectors are owned by the file that owns the algorithm ([01](01-core.md),
[02](02-remote-model.md)).

## 5. Harness seams

A harness instantiates the engine the way an owner does, without its socket, its frontends and its
timers. What it plugs into are the real abstraction boundaries; a conforming implementation MUST
expose each of them.

### 5.1 Domain configuration as a value

A test builds a domain configuration directly, and also by parsing a config document through the same
path the owner uses, then replacing the composite store and/or the member list with doubles. The fields
a test sets: domain and client names; the composite and its members (each with type and role; **chunk
reads and diagnostics walk members, not the composite**); cache root, data directory and socket path per
client under the scratch directory; upload workers; chunk-buffer and download bounds; chunk size and cache
group size; cache cap; symlink policy; read-only and versioning flags.

Two defaults carry meaning:
- **One upload worker**, so that the order in which uploads finish, and therefore which files a
  push carries, is deterministic. Tests of parallel uploads set more explicitly.
- **The uplink governor off**, since when on it paces every store on the real clock. Tests of the
  governor run it on the controllable clock.

### 5.2 The store contract

Every driver and every double implements the store contract of [06-backends.md](06-backends.md). A
contract-tier suite MUST run the same checks against every driver (live tier for cloud drivers) and
against the local driver.

### 5.3 Store doubles

Every double declares no native batches, no fast whole-object read, no local path and an always-up
health cell, so nothing can answer through a side door while the double is "down".

| Double | Behaviour | What it proves |
|---|---|---|
| Down(reason) | every call fails with `reason` | unreachable stores; two can be told apart in a report |
| Hung | every call pends forever | deadlines, bounded probes, stall timeouts |
| Outage(real) | while down, each call **waits** until the link returns, then goes through; calls counted on entry | outages as users see them; "0 round trips while offline" |
| Flaky(real, n, verb?, error?) | the next n calls (of one named verb) fail, transient by default | retries, parking, a failed cycle that changes nothing |
| Refuses | reads answer empty, writes raise not-writable | wrong credential, read-only store |
| Memory | a fresh in-memory table | what reaches the store; one verb overridden to count or gate |
| Landed-then-failed(real, verb) | performs the call, then reports failure | "the write landed but the answer was lost" |
| Wrappers | a real local store with one or two verbs overridden: count, gate on a latch the test releases, mangle bytes, lose a delete | read path and backend details |

- A stalled request and a refused one exercise disjoint code. A scenario run only under Outage says
  nothing about retries.
- A Flaky refusal SHOULD name its verb: background work (cursor bumps, probes) otherwise consumes it.
- A link double MUST be installed as a member as well as in the composite; installed only in the
  composite, it is bypassed by chunk reads and the test records 0 round trips.

### 5.4 The request interface

User-level mutations and queries go through the shared request handler
([08-frontends.md](08-frontends.md)), in process, one JSON request per step. Items are named by
reference; the harness resolves a path to a reference from the client's own mirror, and creates missing
parent folders with `mkdir` requests before writing into them.

### 5.5 Direct engine surface

Steps that model something other than a request bypass the handler:

| Area | Operations | Models |
|---|---|---|
| Positional file operations | read with a stream id, write at an offset, truncate, close, fetch a range into a file | FUSE and File Provider calls |
| Inspection | resolve (staged edit or mirror entry), chunk residency and counts, children, read-ahead in flight | reading state without changing it |
| Upload queue | pending, pause, drain; flush the cursor | holding or releasing work |
| Sync | one cycle; each of its steps alone (arrive, push, project); an arrival by state ([03 §3.4](03-journal-sync.md#34-cycle-one-per-domain-in-the-owner)) | the cycle worker without its timer |
| Maintenance | expire, GC (run, and step by phase: start, step, release, abort), corruption list and invalidate, repair, import, export, owner-start recovery, staged-orphan sweep, cache-cap enforcement | commands and restart-time work |

### 5.6 Clock

The engine takes its clock from outside: monotonic `now`, `sleep`, `with_timeout`,
`with_stall_timeout(alive)` (fails after that much silence), `pick`, and classification of timeouts and
cancellations; wall time is a separate source (P5). A fake clock moves only on `advance(d)` and wakes
due sleepers in deadline order. The governor, retry backoff, health holds, stall timeouts, debouncers
and shutdown are checked as control laws on it.

### 5.7 Filesystem

Every durable local step goes through a filesystem capability the harness can wrap: create, write,
fsync (file and directory), rename, link, unlink, mkdir. The wrapper labels each call site, counts steps,
kills at a chosen step, and keeps the volatile overlay of §7.3.

### 5.8 Processes

A harness can spawn real processes of the implementation (owners, one-shot commands, frontend hosts)
over one scratch machine state, send them requests, and kill them with an uncatchable signal at a chosen
labelled step.

### 5.9 Platforms

- **FUSE**: a real mount over a local store, driven by ordinary file-system calls.
- **macOS**: the extension-side client, item mapping and change-batch logic against a real owner
  process started from the build, with the home directory redirected and a short scratch root (the
  104-byte socket limit); end to end, the installed app with a second client.
- **Android**: the bridge called from foreign threads in-process, and the desktop command group
  spawned once per call, so that a frontend that works only as a long-lived process cannot pass.

## 6. Scenarios

### 6.1 Drivers

Each driver prints its step list, then the state of §4.1.

| Driver | Setup | Prints |
|---|---|---|
| single client | one client, a main and a replica | tree, content, store dump (and the second store's when a step touched it) |
| two clients | A and B with separate caches, data and identities over one shared store | both trees, contents and sync states; both applied logs; the store |
| listing | one client | each folder listed whole and paged, and the whole-domain listing paged |
| change feed | A mutates, B syncs | B's feed from a baseline anchor, from its cursor, from a pruned anchor, after a generation bump, after an arrival by state (still valid), and past `FEED_RETENTION` with a watermark (still valid); a file renamed by A keeps its `i:` reference in B's feed |
| page stability | one client | the whole-domain listing with a write between pages (no gap or repeat), and with the kept walk deleted between pages (`{stale:true}`) |
| report | one client | the structure of the status report, and its text rendering |

A step failure is printed as `ERROR <failure>` and the state dump still follows, so a golden file can
pin a failure.

### 6.2 Step vocabulary

Steps describe what a user or the environment does, never internal transitions.

- **User**: write, mkdir, rmdir, rename, delete, symlink (a refusal is printed), evict, restore, revert
  (optionally to a version), stat by reference or path, restore by path with a keep, create under a
  parent spelled verbatim.
- **Positional**: read a range (with a stream id), fetch a range, write at an offset, truncate, stage a
  write without queueing, close.
- **Observe**: chunks (the mirror entry's count, or staged slots and local count), chunk cache, staged tree,
  names, availability, corruption list, verify request.
- **Queues**: drain (the upload queue empty, the pending set empty, the tree head at the head, the
  cursor flushed, and the next feed key in a later millisecond), pause and resume the upload queue,
  settle read-ahead (bounded; fails rather than hangs).
- **Sync**: one cycle; arrive, push or project alone; arrive by state. A scenario holds publication by
  running no push.
- **Maintenance**: expire (versions, log entries, shares), GC and GC with verify, GC stepped to a
  phase boundary and then continued or aborted, repair, rescan corruption, import from a
  local staging tree with filters, export.
- **Faults**: §7.

## 7. Fault injection

### 7.1 Failure shapes

| Failure | Produced by | Exists to prove |
|---|---|---|
| Link stalled | Outage double; short and long read deadlines | local operations cost 0 round trips offline and stay pending; a cold read fails within its deadline; a read on a long deadline is answered when the link returns |
| Link refuses | Flaky double, per verb, transient or permanent | a failed fetch or push changes nothing and the next cycle repeats it; an upload that keeps failing is parked, reported, can be re-armed, and the rest of the pending set is pushed without it |
| Store down, hung, read-only | Down, Hung, Refuses | read and write policy by role; bounded probes; held members are not asked; deferred targets record rather than fail |
| Landed, answer lost | Landed-then-failed | every retried store write is idempotent or detected; a `put_if_absent` of a log entry that landed is recognised as this client's by the recovery of the in-flight record, and makes no conflicted copy ([publication.md §4.8](algorithms/publication.md#48-crash-recovery)) |
| Backend damage | delete a chunk; overwrite with another size; overwrite with the same size through the store and straight to disk; delete a manifest; each also on a secondary store | corruption markers, repair, verification finding bit rot, tree integrity |
| Cache loss | wipe the chunk cache and the reverse folder index; delete one cached group behind the owner | pending edits survive; bytes are fetched again on demand; the folder-id index is rebuilt |
| Racing append | two clients at one position create the same entry number | one `Won`; the other is answered `Held`, arrives, and commits at the next number |
| Projector killed | kill the projector between any two record writes of an entry, and between the last and the tree-head write | the entry is applied again from its start and ends in the same records; every replaced or deleted manifest has a version, and one killed between its version and the write of its slot has it twice, with one body |
| Version not saved | the write of a version fails while a projection removes one file and replaces another: with a link failure, then with the chunks of the manifest missing from the main | link failure: the projection fails, neither slot is changed and the tree head stays; applied again once the link answers, both versions are saved and both slots written. Missing chunks: the failure is logged and the slots are written |
| A run of pushes | one client with more pending than three entries hold, a second client watching the tree head | the tree head is never more than one entry behind the first client's position when it pushes; no takeover is created; a change made while entries wait to be projected is committed after one projection; a pause set during the run takes effect before the next entry |
| Domain-wide settings | a domain with `chunkSize`, `symlinks` and the three timings configured, unset, and with timings breaking lease < quarantine < settle; a client of an http-proxy main with each setting unset, equal to the main's, and different; a main older than `/domain-settings` | the validator refuses the broken triple; unset uses the default (`keep`, 8 MiB, 30, 300, 600); the client with none uses the main's, and status says which come from the main; the client that differs stops serving the domain with an error naming both values, except one configuring fewer `maxEntryCommands` than the main, which is served; no client projects or takes over before it has asked; against the older main the chunk size is still learned and the rest are the client's |
| Advanced config | the editor in its default mode on a file holding advanced keys, and in advanced mode answering a value, blank and `-` | default mode asks about none and keeps them; advanced mode sets, keeps, and removes the key |
| Projection in parallel | one entry holding creations, removals, replacements, a folder move and two folders that swap names, applied with one write in flight and with `PROJECT_WIDTH`, its slots read one by one and together | the same records and the same versions each way; a file created at an empty place is put with no read of its slot; a removed or replaced file's slot is read once and leaves one version |
| Projector stalled | a projector whose writes are gated on a latch past `PROJECT_SETTLE`, released after another client took the entry over | no takeover before the settle, no write of the new projector before the quarantine; the stalled projector writes nothing once released |
| Undecodable entry | replace the body of an entry above the tree head with bytes that do not decode; then void it | every client stops and reports the entry, and none passes it; after the void every client merges it as empty, one takes its projection over, and later entries are merged and projected |
| Collection before commit | run a collection between an upload and the push that names its chunks | the create is refused with the missing chunks named; the client uploads them again from its staged bytes and commits |
| Log expiry | expire the log past a stopped client's position, the client holding pending changes | the client arrives by state; its pending changes stay pending, and one that clashes becomes a conflicted copy |
| Main unreachable | Down or Outage on the main, a replica up | chunks are read from the replica; every fetch, state read, tree-head read and push fails UNREACHABLE; the position and the before-values do not change |
| Lost delete | a store whose delete of one key silently does nothing | a marker that a projection failed to delete is disowned by its folder's anchor and invisible to every reader |
| Concurrency | racing conditional creates of a log entry and of a takeover; readers and writers during promotion; foreign threads through a bridge; several processes minting ids; peers committing clashing changes | one winner per entry number and per takeover; no torn reads; unique ids; convergence |
| Scheduling | fetchers gated on latches the test releases; overlap counters | observable limits the owning files specify hold (request caps, admission); a read never waits behind unrelated work |
| Time | fake clock; a wall-clock step | control laws; wall-clock steps change no duration |
| Load | CPU contention | convergence under contention; no verdict depends on speed |
| Queue hold | pause the upload queue; run no push | work left pending deterministically |

### 7.2 Crash at every durable step

Every durable step (§5.7 and every store write) MUST be a kill point.

1. **Reference run.** Run a scenario once with instrumentation and record the labelled steps.
2. **Kill twice per step.** For each step `k`, re-run and kill immediately **before** `k`, then
   immediately **after** it, with an uncatchable process kill so that no cleanup runs. Store writes get a
   third variant: landed, answer lost.
3. **Restart and check.** Restart, recover, reach quiescence (store reachable, recovery run, the upload
   queue settled, the pending set empty, the tree head at the head, a peer arrived at the head) and check the invariant below.
4. **Crash recovery too.** Repeat with a second kill point inside recovery; recovery must be crash-safe.
5. **Prove the kill fired.** Each run asserts that the step counter reached `k`, and that recovery found
   evidence whenever `k` lies in a window that leaves some.

**The oracle.** The driver logs each user action whose call returned success, with its expected effect
and the durability level of its acknowledgement; an action in flight at the kill is logged as "maybe".
After recovery and quiescence, the check asserts the crash-immunity properties of
[durable-queue.md §8](algorithms/durable-queue.md#8-conformance) against that log.

### 7.3 Power loss

The filesystem wrapper keeps a volatile overlay: an operation is unsynced until the file (for data) or
its directory (for names) is fsynced. At the crash the harness generates the states a power loss may
leave:

- (a) every unsynced operation dropped;
- (b) names kept, data dropped (renamed files empty or truncated);
- (c) random subsets that respect only the fsync barriers.

Recovery runs on each and the oracle of §7.2 applies to actions acknowledged as durable. This is the check of P2
([durable-queue.md](algorithms/durable-queue.md)): an acknowledgement given before a durable step fails
here. A block-level recorder on a real filesystem MAY cross-check the model.

### 7.4 Platform lifecycles

- **Android**: kill the app process with no drain at every durable step of a picker write, a share save,
  a camera upload and a deferred replica job, then cold-boot; the oracle includes ingest intents and
  deferred logs.
- **macOS**: kill the owner during a `write` adoption, a fetch into the provider directory and a reset;
  the extension's retried calls and the app's relay must bring the replica back without a user action.

### 7.5 Multi-process ownership

With the process seam (§5.8), over one machine's state:

- A second would-be owner of a domain cannot take the ownership lock while the first lives; it forwards
  to the owner or refuses, per [07](07-daemon-cli.md).
- A one-shot command with no owner running takes ownership for its duration, and a daemon started
  meanwhile waits or forwards rather than sharing the state.
- An owner killed at any labelled step releases ownership; the next owner resumes its work, and no
  record, job or queue entry is executed by two processes (count executions per record id through the
  instrumentation). Ordered logs reach the store in order.
- Every mutation of a domain's local state is attributed to the owner's process; a mutation by any other
  process fails the check.
- A wedged owner (accepting connections, never answering) makes every client request fail within that
  client's deadline.
- Owners, one-shots and frontend hosts run concurrently and are killed independently while the others
  keep running.

## 8. Property-based merge testing

The merge is checked against the theory, and the engines against the invariants the merge exists for.
[change-algebra.md](algorithms/change-algebra.md) owns the definitions and the theorems;
[conflict-resolution.md](algorithms/conflict-resolution.md) §10 owns the invariants to assert after
quiescence; this section owns how cases are generated and how the run proves its reach.

### 8.1 The merge, enumerated

Pure tier: no engine, no store.

- **Trees.** Every well-formed tree within `merge_tree_bound`: a fixed set of folder ids besides the
  root, of leaf names and of content tokens.
- **Merge.** For every well-formed $R$ within the bound, and every well-formed $L$ and $M$ within it
  that each differ from $R$ on at most `merge_diff_keys` keys, the implemented `MERGE(R, L, M)`
  ([03 §3.6](03-journal-sync.md#36-merge-the-policy-seam)) equals a reference written directly from
  Definition 7, and its result satisfies the five properties of Theorem 8. Where the repair rules can
  be applied in more than one order, the reference applies them in the implementation's order.
- **Application.** For every pair of well-formed trees within the bound, the order in which the
  implementation applies their difference to a local tree keeps every intermediate state well-formed,
  ends at the target, and uses at most one temporary place per folder the difference moves
  (Theorem 3).
- **Reach.** The run counts the cases that took each row of step 1 and each of R1, R2 and R3, and the
  applications that needed a temporary place; a zero anywhere fails. It asserts the number of
  triples enumerated.

### 8.2 Two clients, generated

- **Model.** A small tree (at most 3 names at the root and one folder level, 2–3 distinct contents as
  tokens so that bytes can be accounted exactly), two clients, and one main, with versioning on and
  off. The real engines are driven through their request interface and the steps of the cycle (§5.5);
  running or withholding a step produces the interleavings.
- **Generators.**
  1. A starting tree, committed by one client and arrived at by both.
  2. One operation per side (or a short chain), from put, delete, mkdir, rmdir, rename of a file,
     rename of a folder, symlink, and a write inside a folder, with arguments biased towards collisions:
     the same name, a rename destination equal to the other side's name or source, a parent of the other
     side's name, the same leaf with the other kind.
  3. An interleaving class: B's change pending when A's entry arrives, with B's content staged and
     with it uploaded; B's push refused because A's entry took the number; both clients creating one
     entry number at once; B arriving by state instead of fetching.
  4. Faults: a kill before and after each step of an arrival's enactment, and between the in-flight
     record and the end of the `Won` step, then recovery; a create that landed with its answer lost; a
     transient store failure.
  5. Role swap: every case is also run with A and B exchanged.
- **Shrinking.** A failure is shrunk to a minimal operation pair and starting tree and emitted as a
  two-client scenario (§6.1) to be committed with its golden file.
- **Reach.** The run counts every row of
  [conflict-resolution.md §8.3](algorithms/conflict-resolution.md#83-coverage-by-operation-pair) and
  each of the four clashes of [change-algebra.md §7.2](algorithms/change-algebra.md#72-where-the-two-sides-can-clash)
  it actually reached, and fails unless each was reached at least once, listing the unreached. It also
  counts cases per interleaving class and per fault point; a zero anywhere fails.
- **Budget.** At least `property_cases` cases per run, with the seed printed, and any failing seed
  replayable.

## 9. Coverage the suite MUST include

Beyond the properties of §3, a conforming suite MUST reach these, each of which a suite built only from
convenient seams tends to miss:

- the read path detecting a chunk whose bytes do not hash to its key, where the owning file requires
  verification;
- an arrival by state comparing content identity, not only size;
- grouped partial edits committed end to end, not only staged;
- the owner's own timers, the dispatch of changes to frontends, and a real owner start and stop;
- positional operations through a real mount: rename (including over an existing name), truncate,
  partial writes, symlinks, concurrent access, and a file held open while replaced or deleted;
- every driver's `watch`, batch listing and listing page boundaries, including the local and http-proxy
  drivers;
- the http-proxy and share server through a real socket and router, including range forms the owning
  file supports and cache validators;
- directory fsync after rename, via §7.3;
- conditional-create races across processes, not only within one;
- that no memo of chunk presence survives a collection
  ([gc.md](algorithms/gc.md));
- automatic cache-cap triggering, and retry backoff with jitter on the fake clock;
- stalling (Outage) links in failover and write-guard checks, not only refusing ones.
- scheduling under a stalled disk: with every slot for may-block work held, timeouts, stop, the
  liveness answer and non-blocking socket exchanges still proceed, and a may-block task does not
  ([01 §6.5](01-core.md#65-scheduling));
- ownership: one owner per domain on a machine, delegation of one-shot commands to a running owner,
  refusal with `busy` when the holder cannot take the request, takeover after the owner dies (§7.5,
  [07 §2](07-daemon-cli.md#2-process-model));
- pause persisted across an owner restart, and the actions refused with `paused`
  ([07 §2.6](07-daemon-cli.md#26-pause));
- a wedged owner (connections accepted, never answered): every client, the CLI, the tray, the macOS
  extension and app included, fails within its deadline
  ([failure-model.md §8.2](algorithms/failure-model.md#82-requests-between-processes));
- through a real FUSE mount: rename over an existing file and folder, rmdir of a non-empty folder,
  truncate, partial writes, fsync, and a file held open while it is unlinked or replaced
  ([fuse.md](frontends/fuse.md));
- transfer-path refusal: a `staging` or `dest` outside the host's declared roots, through a symbolic
  link, or naming an existing `dest`, is refused `denied` and touches nothing
  ([security-model.md §7.3](algorithms/security-model.md#73-paths-passed-over-ipc-confused-deputy));
- the bucket-function probe: `verified` and `Queued` answers only after the probe succeeded, and a
  store without the function answers "unsupported" ([gc.md](algorithms/gc.md));
- starting on existing state: start an implementation on a machine state another run left (staged
  edits including set-aside ones, before-values, a position, an in-flight record, an arrival record,
  upload records, local intents, a deferred-job backlog, the mirror and folder-id index, the applied
  log, the client identity and host state such as camera-backup records), and check that it continues
  the owed work to the same end state as the run that left it would, rewriting no existing record at
  start beyond what recovery specifies ([publication.md §4.8](algorithms/publication.md#48-crash-recovery));
  compare the files before and after start-up.

## 10. Assertion discipline

These rules exist because each one's absence once let a suite pass while testing nothing.

### 10.1 A suite proves it ran

- Every check suite declares how many checks it makes and fails when a different number ran; "0
  failures" from a fixture that produced no work is a failure.
- A pass requires all of: the declared count reached, a successful exit, and a matching golden file. A
  failure written only to an error stream MUST still fail the check.
- A suite that could not run (missing credentials, configuration, platform or tool) reports "not run"
  with a distinct status, and a conformance claim lists every "not run".
- A measurement that depends on an optional tool or platform facility (open-descriptor counts, space
  reservation) MUST fail or report "not run" when the facility is missing, never read as 0.
- Parameterised sweeps (kill points, property cases) assert the number of cases executed and that each
  injected fault fired.

### 10.2 Negative controls

Before a new check is trusted, plant the failure it guards against (skip an fsync, reverse two durable
steps, return "absent" for "could not look") and see it fail. A negative control's output is never
promoted to a golden file.

### 10.3 No verdict from elapsed time

- Wait for the state a step expects, never for a duration. A bounded wait that expires does not fail by
  itself; the state it found is printed and the comparison decides. A "held" state is checked to keep
  holding for a short window.
- Count round trips, not time: "offline costs 0 calls" holds under any load, "offline is fast" does
  not.
- A check that fails under CPU contention without a change under test is a defect of the check.

### 10.4 Observations distinguish "did not look"

An observation that could read as "nothing wrong" also states whether it looked: a corruption listing
prints its count and names the stores nothing checks; a verification that verified nothing says so; a
verify request to a store that cannot verify answers "unsupported", and a command built on it fails.

### 10.5 Human-readable output is compared whole

Status, menus and reports are compared as whole blocks, never by substring: a substring pins only the
fragment its author thought of. Values and properties inside them are also checked by counted checks.

### 10.6 Isolation

Scratch directories are unique per process and wiped on entry, so concurrent runs never meet; no check
uses a fixed shared path. State that outlives one case in a process (debouncers, health, memo tables,
pools) is either per instance or reset between cases, and a check SHOULD run correctly with its cases
reordered. Before a check removes its scratch directory it requests a stop (01 §9) and waits, within
`GRACE`, for the detached work it started to end; work still running then fails the check and is
named.

### 10.7 Doubles without side doors

A double declares no capability through which a real store could answer (§5.3), so "down" means down.

## 11. Parameters

| Parameter | Recommended | Constraint |
|---|---|---|
| `property_cases` | 10 000 per run | every reach counter > 0 |
| `merge_tree_bound` | 2 folder ids besides the root, 2 leaf names, 2 contents | every row of Definition 7 and each of R1, R2, R3 reached |
| `merge_diff_keys` | 2 per side | ≥ 2: a removal of a folder and of what it held is two keys |
| kill variants per durable step | before, after (and landed-then-failed for store writes) | all |
| power-loss subsets per crash point | 16 | ≥ 1 of each of (a), (b), (c) |
| scenario upload workers | 1 | > 1 only where the scenario tests parallelism |

---

Implementation notes for this subsystem: [ocaml/09-tests.md](ocaml/09-tests.md).
