# Publication: the log, the cycle and the projected tree

This document owns the protocol by which a client's local changes reach the main and the main's
changes reach every client: what a client records for each local change, the upload of content, the
numbered log and its atomic append, fetching and pushing, the projection of the log onto the
per-object tree, the arrival by state, crash recovery, log retention, and what the protocol relies
on from the domain's owner.

The model it realises (keys, values, commands, batches, the merge and every proof) is owned by
[change-algebra.md](change-algebra.md) and is not restated. This document names the theory's
objects as that document does: $L$, $R$, $M$, the pending set $P$, a batch $B$, the position $h$.

Related rules owned elsewhere, referenced and not restated:

- byte formats of the log entry, the cursor, the tree head, the local records and the change feed,
  and the sync interfaces: [03](../03-journal-sync.md);
- how a merge is enacted on local state, the conflicted-copy name and the outcome of every clash:
  [conflict-resolution.md](conflict-resolution.md);
- the per-object tree a projection writes: [data-model/backend.md](../data-model/backend.md);
- durable-write primitives (P2), the durable queue, parking and re-arm:
  [durable-queue.md](durable-queue.md);
- failure kinds and their propagation: [failure-model.md](failure-model.md);
- the process model and the domain owner (P1), pause, status: [07](../07-daemon-cli.md);
- local entities and formats: [data-model/local-cache.md](../data-model/local-cache.md),
  [04](../04-checkout-cache.md);
- the reference gate a commit and a projection go through, and log retention's place in expiry:
  [gc.md](gc.md);
- the walk a state read performs (`tsync sync --full`): [05](../05-ops-config.md).

---

## 1. Goals

- **G1 — Local operations never wait on the network.** A mutation completes against the local tree
  and becomes part of the pending set.
- **G2 — Acknowledged work is never lost.** A mutation that returned success is in the main's tree,
  or was superseded by a later local change, or survives under a conflicted-copy name, across
  crashes, power loss and restarts.
- **G3 — A client's knowledge of the main changes only on observed facts** (Proposition 5): a
  created entry or a merge, never a local operation.
- **G4 — The main is safe** (Proposition 6): every committed command replaced a value its author
  knew, and every tree the log defines is well-formed.
- **G5 — Convergence under quiescence** (Theorem 10): once every client has an empty pending set and
  has arrived at the head, every local tree equals the main's, and every replica converges to it.
- **G6 — Uploads and commits are separate.** An upload may take hours and never conflicts; a commit
  is one small conditional write.
- **G7 — A local change feed.** Every owner keeps an ordered record of the changes made to its local
  tree, its own and those a merge brought. It never runs ahead of the local tree.
- **G8 — A client that cannot read the entries it missed still arrives**, by reading the tree
  instead (§4.7), with no special state and no operator action.

Non-goals: linearizability of local operations across clients; coordination between clients beyond
the append (no locks or consensus on the store, and a lease only to finish a dead client's
projection, §4.6).

---

## 2. System model and assumptions

The assumptions A1–A5 of [change-algebra.md](change-algebra.md) §1 hold. This section states how
tsync provides each.

**A1 — One main.** A domain has at most one main ([replication.md](replication.md) §3.2). A domain
without one is read-only: nothing is pushed, and its first archive stands for the main in every
read below.

**A2 — Atomic append.** The append is `put_if_absent` on the entry's key
([06](../06-backends.md) §3.3). Every store driver evaluates it atomically. A store that answers
REFUSED cannot be a main that is pushed to: a push never falls back to a plain put.

**A3 — Content is immutable.** A file's bytes are chunks named by a hash of their bytes
([01](../01-core.md)). A file's value in a command is its manifest, compared by content identity
([conflict-resolution.md](conflict-resolution.md) §2).

**A4 — Folders have identities.** Folder ids are minted locally and unique across clients
([03](../03-journal-sync.md) §2.1). No other party ever assigns or changes one.

**A5 — Clients follow the rules.** A client creates entry $n+1$ only from position $n$, with a
batch in the sense of Definition 6.

**A6 — Store consistency.** After a mutation returns, every later read of that key reflects it
([06](../06-backends.md) §3.1). A request whose answer was lost may or may not have landed.

**A7 — Clocks.** No decision compares the clocks of two machines. The settle, lease and quarantine
of §4.6 are durations on one machine, measured on a clock that counts time spent suspended. The age
of a log entry is the store-assigned modification time, compared on one store ([gc.md](gc.md) §4).

**A8 — Failures.** Processes crash at any point and machines lose power. Every local record the
protocol relies on is durable before it is relied on (P2, [durable-queue.md](durable-queue.md) §3).
The link can be down for arbitrarily long.

**A10 — Actors.** On each client and domain, exactly one **owner** (P1,
[07](../07-daemon-cli.md) §2.2). Only the owner changes the local tree, records before-values,
fetches, merges, pushes, projects and writes the change feed. Other processes act through the
owner's request interface.

---

## 3. State

### 3.1 On the main (per domain)

| State | Nature | Invariant |
|---|---|---|
| **Log**: entries numbered from 1 | each created once by `put_if_absent`, immutable | the retained entries are contiguous up to the **head**; an entry exists only after the main holds every chunk its manifests name |
| **Tree**: the per-object records of [data-model/backend.md](../data-model/backend.md) | written only by a projection (§4.6) | a projection of the log: it holds $M_t$, with some records already at the value a later entry gives them |
| **Tree head** $t$ | one object, written only by the projector of entry $t$ | every entry up to $t$ is projected; $t \le$ head |
| **Takeovers** | objects created by `put_if_absent`, one per (entry, generation) | name who may project an entry its author left unprojected (§4.6) |
| **Cursor** | one object holding a head number; last writer wins, may be stale or lost | a hint; correctness never depends on it |

An **entry** is a batch with its author: a set of commands, each a key with its value before and
after ([03](../03-journal-sync.md) §2.3–2.4). A file's value after is its whole manifest, carried in
the entry, so an entry needs no other object than the chunks to be understood.

$M_n$ is the tree after entries 1 to $n$. The log is the truth and the tree is derived from it. For
the entries expiry has deleted (§4.9), which are all below the tree head, the tree is what remains
of them.

### 3.2 Local, durable (per client and domain; owner-written)

| State | Must hold |
|---|---|
| **Local tree** $L$: the mirror overlaid with the staged edits ([data-model/local-cache.md](../data-model/local-cache.md)) | what every frontend sees |
| **Before-values**: for each key where $L$ differs from what this client last knew of the main, the main's value | recorded before $L$ changes at that key; dropped when $L$ returns to it |
| **Position** $h$: the number of the last entry merged | changes only in a merge and in a successful push |
| **In-flight record**: at most one; the entry number and the exact bytes of an entry being created | durable before the create is issued |
| **Arrival record**: at most one; the result of a merge being enacted | durable before $L$ is touched by that merge |
| **Upload records**: one per file whose staged content the main may lack | [durable-queue.md](durable-queue.md) |
| **Local intents**: one per namespace operation whose local steps are in progress | durable before the first step |
| **Change feed**: lines in the order the changes were made to $L$ | a line never claims an effect that is not durable |

$R$ and the pending set are not stored (change-algebra §6.2): $R(k)$ is the before-value of $k$ if
there is one and $L(k)$ otherwise, and the pending set is one command
$\langle k, \mathit{before}(k), L(k) \rangle$ per before-value.

### 3.3 Owner memory (per domain)

- **Cycle state**: whether a fetch is due, when the oldest pending change was made, the last cursor
  value seen, the monotonic time of the last fetch.
- **Projection watch**: for the entry after the tree head, since when this owner has seen it
  unprojected (§4.6).
- **Cursor debouncer**: pending head number, last publish time (monotonic).
- **Queue contents**: derivable from the upload records.

Every check-then-act on this memory is serialised by the owner (P1).

---

## 4. The algorithm

One **cycle worker** per domain runs fetches, merges, pushes and projections, one at a time. Local
operations and uploads run beside it.

```
CYCLE (the owner, per domain):
  loop:
    if paused: wait until resumed
    wait until one of:
      the store says the cursor may have changed        (at most SWEEP)
      SWEEP elapsed since the last fetch
      the pending set has held a pushable command for BATCH_DELAY, or its pushable commands fill an entry
      a request asks for a cycle now (sync, await, drain, and poll, which pushes only what is due)
      the last cycle pushed an entry or projected one    (at once)
    ARRIVE()                                             # §4.3, §4.4, §4.7
    if a pushable batch is due: PUSH()                   # §4.5, one entry
    PROJECT()                                            # §4.6, one entry
  on failure: log; wait RETRY_FLOOR (stop-aware)
```

### 4.1 A local operation

```
LOCAL(op), under the locks 04 §3.2 names (the metadata lock for a namespace change, the key lock
          for a change of one file's content):
  for each key k the op changes:
    if k has no before-value: record before(k) := L(k)       # before L changes at k
  change L                                                    # no store request possible
  for each key k the op changed: if L(k) = before(k): drop before(k)
  append the op to the change feed
  acknowledge
```

- **The before-value is the only thing recorded for the main's sake.** No list of operations is
  kept. A delete followed by a create of one name leaves one before-value, the content the delete
  found, and the create that follows finds it there (Proposition 2).
- **Keys.** A folder operation changes one folder key. A file operation changes one file key; a
  file rename changes two, the source and the destination. A folder rename changes one key
  whatever the folder contains.
- **Durability.** A before-value is always written before $L$ changes at its key. It is durable
  at the level the operation is acknowledged at ([durable-queue.md](durable-queue.md) §6): at once
  for a namespace operation, at the next sync or close for a write. A before-value a write left
  for its next sync is made durable by a namespace operation on its key, and before the upload
  records its edit as Uploaded: an Uploaded edit with no before-value reads as committed (§4.8).
  A staged edit found at owner start with no
  before-value takes the content identity of its base entry as its before-value, or ∅ when it has
  none ([04](../04-checkout-cache.md) §4.10): the key was clean when the edit began.
- **A local intent** precedes a namespace operation whose local steps are not one atomic step on
  local storage; owner start completes it ([04](../04-checkout-cache.md) §4.5). It serves local
  recovery only and is never published.
- **Equality.** Two file values are equal when their content identities are equal
  ([conflict-resolution.md](conflict-resolution.md) §2). A staged edit whose identity is not yet
  computed differs from every value.

### 4.2 Upload

A file command's value after is a manifest whose chunks the main holds. The upload queue provides
them ([04](../04-checkout-cache.md) §4.6):

```
UPLOAD QUEUE (keyed: at most one job per file key), not gated by the cycle:
  job k:
    upload the chunks of the staged edit at k that the main lacks
    build the manifest; record it in the staged edit (state Uploaded)
    if L(k) = before(k): drop before(k); promote the edit    # the bytes written are the main's
```

- An upload writes chunks only. It writes no manifest, no log entry and no tree record, so it
  changes no client's view and cannot conflict (A3).
- An upload is never wasted: if the file loses a merge, the same content is the conflicted copy.
- **The staged bytes stay** until the command that carries the manifest is committed. Content
  uploaded and not yet committed is named by nothing on the main and a collection may delete it;
  the commit's gate then refuses the entry with the missing chunks named, and the uploader sends
  them again from the staged bytes ([gc.md](gc.md) §5.4).
- Queue mechanics (backoff, parking, re-arm, cancellation by a newer write) are the durable
  queue's ([durable-queue.md](durable-queue.md) §4.5–4.7).

### 4.3 Fetch

```
FETCH() → entries | PRUNED:
  entries := []; n := h + 1
  loop:
    e := get_opt(log entry n)                # from the main; batched reads allowed
    if e ≠ none: entries += e; n += 1; continue
    t := tree_head()
    if t < n: return entries                 # entry n was never created: the head is n − 1
    if get_opt(log entry n) ≠ none: continue # created and projected between the two reads
    return PRUNED                            # entry n existed and is gone (§4.9)
```

- **The log is read by number, never listed.** An entry that exists is found by its number; there
  is no order of visibility to reason about.
- A failed read is never "no entry" ([failure-model.md](failure-model.md) §5.2): the fetch fails
  and nothing advances.
- An entry that does not decode, or whose version this client does not know
  ([03](../03-journal-sync.md) §2.4), cannot be merged. If the tree head has passed it, the client
  arrives by state (§4.7). Otherwise it stops fetching and pushing, and reports the entry.
- **A voided entry.** An entry that does not decode and whose void object exists
  ([03](../03-journal-sync.md) §2.6) reads, for every reader of the log (a fetch, a state read, a
  projection, a collection), as an entry with no command and no author. A client stopped at an
  undecodable entry reads the entry and its void object again at each cycle. The void object is
  created by an operator ([05](../05-ops-config.md) §4.12), never by a cycle, and has no meaning
  for an entry that decodes or whose version is unknown.
- The cursor only saves fetches: the cycle fetches when the cursor moved and every `SWEEP`
  whatever the cursor says. A fetch that finds nothing costs one read of entry $h+1$ and one of the
  tree head.

### 4.4 Arrive: fetch, then merge

```
ARRIVE():
  complete the arrival record, if any                        # §4.8 step 2; a failure fails the cycle
  recover the in-flight record, if any                       # §4.8
  r := FETCH()
  if r = PRUNED: M := STATE(); head := M's position           # §4.7
  else if r = []: return
  else: M := the last value r gives each key; head := h + |r|
  with the metadata lock:
    N := MERGE(R, L, M)                                       # change-algebra Definition 7
    write the arrival record, durably: N on the keys that change, the before-values of the keys
      fetched, and head
    change L to N, as conflict-resolution §4 specifies
    set the before-values so that R = M on every key fetched; h := head
    append the changes made to L to the change feed
    clear the arrival record
  tell this owner's frontends which paths changed
```

- **Store reads come first, the lock after.** Entries carry every value a merge installs, so the
  merge makes no store request and a slow link never delays a local operation (G1).
- **An arrival never fails for a reason of its own.** The merge is total (Theorem 8). A local
  storage failure while enacting it leaves the arrival record, which owner start completes (§4.8).
- **Atomic across crashes and failures.** The arrival record holds the merge's result, not its
  inputs. Whatever interrupted the enactment (a crash, a full disk), the record is completed
  before any other fetch or merge, at owner start or at the next cycle, so no second merge is ever
  computed over a half-changed tree. A record that cannot be completed stops the cycle and is
  reported.
- **Only the keys fetched.** The record carries the before-values of the keys the entries name
  and of the keys the merge changes in $L$, not of every key: a write to another file during the
  enactment records its own before-value under its key lock, and completing the record leaves it
  alone. The enactment holds the key lock of every file key whose before-value it settles, at the
  first enactment and at a completion alike.
- **Promotion.** An Uploaded staged edit at a key the record drops the before-value of holds the
  main's content, and is promoted before that before-value goes and before the record is cleared.
- **The feed after an interrupted arrival.** The lines are appended before the record is cleared.
  A record completed later (at owner start, or at the next cycle) cannot tell which lines the
  interrupted enactment had appended, nor what the steps it had made looked like before. It
  appends none, and stamps a new resync generation ([08](../08-frontends.md) §3.6): every anchor a
  frontend holds answers stale, and the frontend lists again.
- **An arrival with nothing pending** takes the first row of the merge on every key: $L$ becomes
  $M$ on the keys the entries name.

### 4.5 Push

```
PUSH():
  with the metadata lock:
    B := the batch to push (below); if B = ∅: return
    body := encode(author = this client, projector = the main's when it states one, B)   # 03 §2.4, §4.6
    write the in-flight record (h + 1, body), durably
  r := put_if_absent(log entry h + 1, body)                   # through the gate, gc §5.4
  case r:
    Won →
      with the metadata lock, and the key lock of each file key of B, in this order:
        promote the staged edits of B whose content is B's value at their key   # 04 §4.7
        for k in B: if L(k) = B's value at k: drop before(k)
                    else: before(k) := B's value at k
        h := n                                                  # the entry's number
        clear the in-flight record
      cursor.note(h)
    Held(_) → ARRIVE(); then PUSH() again, in this cycle a bounded number of times, else in a later one
    missing chunks(C) → upload C from the staged bytes; issue the same create again
    any other failure → the in-flight record stays; §4.8 decides at the next cycle
```

**Which batch.** A pending command is **pushable** unless it is a file command whose value after
is a staged edit not yet Uploaded. Leaving such a file out is always allowed: it keeps its value
in $R$ at its own key, and its folder is present in both trees.

**Nothing kept is dropped on the way.** The theory fixes the tree a pending set ends in, not the
trees the main passes through when the set is committed in several entries, and those are seen by
peers, by a collection, and by everyone if this client is lost. The client chooses its entries so
that this holds after each one:

> Content that the main held before the entry, and that this client's tree still holds as the
> value of a file key in $L$ or as the base of an Owed staged edit, is the value of a file key on
> the main after the entry.

Content the user removed or overwrote is not kept: only versions keep it. Two consequences:

- A file removal or replacement is committed no earlier than a pending creation of the same
  content identity (a file renamed or moved).
- A file removal or replacement is **held back** while an Owed staged edit is based on the content
  it removes (a file renamed, then edited): the staged edit's base identity is the removal's
  before-value.

$B$ is the largest batch (Definition 6) of pushable commands that keeps the rule. A command that
needs a held-back one committed first (the removal of its folder, a placement onto its name)
waits with it. Any such choice is a batch, and all of them end in the same tree (Proposition 4).

The rule is about the order of commits. Where an order is free elsewhere, its owner says what
protects content meanwhile: within the projection of one entry, the entry itself names the content
until the tree head passes it ([gc.md](gc.md) §5.3); in the local tree, a move the main made is
enacted as a move ([conflict-resolution.md](conflict-resolution.md) §4.1).

- A push is attempted only when the previous fetch found the head at $h$. It is refused whenever
  another entry $h+1$ exists; the client then arrives and pushes from the new head.
- **A refused push costs one arrival.** When the entries that got ahead touch nothing this client
  has pending, the pending set is unchanged and the same commands are pushed again with no upload.
- **Splitting.** A batch whose encoding would exceed `MAX_ENTRY_BYTES`, or that holds more than
  `MAX_ENTRY_COMMANDS` commands, is pushed as several entries, each a batch (Proposition 4). An entry of one command is never split, whatever its
  size. The split keeps the rule above: commands that must be committed together (a swap of two
  files) share an entry, which MAY then exceed the limits.
- **The `Won` step promotes, then makes three kinds of durable write, in that order.** An edit is
  promoted while its before-value is still there, so an Uploaded edit never stands without one
  unless it holds what its base entry holds: a before-value that is missing is then never read as
  a commit (§4.8). Each is idempotent, and the
  in-flight record goes last, so a crash inside the step leaves the record and recovery runs the
  whole step again (§4.8). Run again, a key that changed meanwhile gets the committed value as its
  before-value, which is what it must have.
- **Local operations during a push** are allowed. The `Won` step compares each key with what was
  committed: a key changed meanwhile keeps a before-value, now the committed value.
- **When.** A pushable command is pushed once the pending set has been non-empty for `BATCH_DELAY`,
  and at once when a request asks (a `sync`, a drain at stop, a write that awaits its publication).
  The delay exists to gather the changes of one burst into one entry, so a client MAY push before it
  has elapsed once its pushable commands fill an entry (`MAX_ENTRY_COMMANDS`), and no sooner than
  `RETRY_FLOOR` after its last push or after the pending set stopped being empty. Commands still
  waiting for their upload do not count: a burst of new files is not committed a few commands at a
  time as its uploads end. The delay is the client's choice and nothing depends on its value; being
  offline is a long delay.
- **Missing chunks with no bytes to send.** A command whose manifest names a chunk the main lacks
  and this client cannot upload again (an inherited chunk of a partial edit, whose base left the
  main and was collected, and which the local cache does not hold) is left out: the client clears the in-flight record, reports
  the file as damaged ([gc.md](gc.md) §5.4), and pushes the rest of the batch. The command stays
  pending and the file stays listed in status ([failure-model.md](failure-model.md) §9) until its
  commit succeeds.
- **What a commit means.** From `Won` on, every client that arrives sees the batch. Nothing else
  the pusher does afterwards is needed for that: the projection (§4.6) serves the readers of the
  tree, not the clients' merges.

**Cursor coalescing.** One debouncer per cursor object in the owner:

```
note(n):   pending := max(pending, n); if not armed: arm a timer for CURSOR_INTERVAL − since(last publish)
flush():   take pending; if any, put(cursor, pending); a failure is logged and dropped
```

The owner flushes the cursor after the last cycle of a drain, before exit, and SHOULD flush when the host signals
imminent suspension. A lost note costs latency only: peers fetch every `SWEEP`.

### 4.6 Projection: the tree follows the log

The tree lets a reader that does not follow the log (a state read, a lazy tree, a share server, the
collector, integrity) read the main's tree from per-object records. Entries are projected one at a
time, in number order, each by exactly one **projector**.

```
PROJECT():                                                     # one entry
  t := tree_head(); if t ≥ h: return
  e := log entry t + 1
  g := the highest takeover generation of entry t + 1 (0 when none)
  if this client is not the projector of (t + 1, g):
    if entry t + 1 has stayed unprojected at generation g for PROJECT_SETTLE (as this owner saw it):
      if put_if_absent(takeover (t + 1, g + 1), this client) = Won:
        wait PROJECT_QUARANTINE, then apply as below             # now the projector
    return
  apply(e)                                                     # data-model/backend §6
  write the tree head := t + 1
```

- **Who.** A client of a read-only domain ([05](../05-ops-config.md) §2.1) writes nothing to the
  main: it projects no entry and takes none over, and `projectCommits` has no effect there. The
  projector of an entry at generation 0 is the client its `projector` field names, and
  its author when it has none. The projector at generation $g \ge 1$ is the client whose takeover
  object $(n, g)$ exists. A voided entry (§4.3) has no author and is projected through a takeover.
- **Projection by the main's server.** A main that is an http-proxy peer MAY state a projector with
  its domain-wide settings ([05 §2.1](../05-ops-config.md#21-schema-and-validation)): the owner of
  the domain on the serving host. A client names that projector in every entry it creates through
  such a main, and then does not project its own entries: the serving owner does, as their
  generation-0 projector, woken by the listener when the create is won. The serving owner writes to
  the main without a network between them, so the entry is in the tree at once, whatever the
  author's link is and whether the author stays connected or not. A client whose main states a
  projector projects nothing and takes nothing over: it commits, and the serving owner is the one
  projector of what goes through that main, so no two machines there ever write the tree. A serving
  owner that stopped resumes its entries when it starts. Every machine reads the projector from the
  entry, so those that reach the same main directly agree on it too, and the takeover of this
  section remains theirs, the serving owner among them. A main that states no projector, and any
  main reached as a plain store, leaves each entry to its author. The serving owner projects such an
  entry before it merges it into its own tree, so a merge that fails or takes long there holds up
  nobody else, and it goes on projecting them while it is paused: a pause holds this machine's own
  changes, not those of the clients it serves. An entry of its own that it committed before the
  pause is projected with them, since theirs wait behind it. Any other paused client projects
  nothing and takes nothing over. The serving owner of a domain whose listener projects
  is the projector of every entry of that domain, whatever the entry names and whoever wrote it: the
  domain has one projector. Such a main MUST be written by no machine but through that listener, the
  serving owner apart; it is the operator who knows that, which is why `projectCommits` is an
  advanced setting.
- **When.** A client projects after it has arrived and pushed (§4), so a projection that fails or
  waits holds up neither. The owner of a domain whose listener projects is the exception stated
  above: it projects first, and a projection of its own that fails is reported once its arrival
  and its push have run, not in their place.
- **Short by construction.** Nothing tells a slow projector from a stopped one. An entry is one
  put, and its projection is at most `MAX_ENTRY_COMMANDS` commands and `MAX_ENTRY_BYTES` of
  records (or one record of any size): the caps are chosen so that a projection ends well within
  `PROJECT_SETTLE − PROJECT_QUARANTINE` on the slowest link a client is expected to run on. The
  long work, uploading chunks, is done before the commit and is under no deadline. A client MAY
  use lower caps on a slow uplink. A projector that is slower still is taken over and its entry
  is applied again from the start.
- **Apply** sets each key of the entry to its value after on the per-object records, saving
  versions as [data-model/backend.md](../data-model/backend.md) §6.1 says. It is idempotent, and a projector that
  restarts applies the whole entry again.
- **The lease.** A projector checks, before it starts an entry and at least every `PROJECT_LEASE`
  while it applies it, that the tree head is still $t$ and that no higher takeover generation
  exists. It issues a record write only while less than `PROJECT_LEASE` has elapsed since its last
  such check, and stops at once when a check fails. **Every attempt counts**: a retry of the
  ladder ([01](../01-core.md) §7) is a write issued anew and is made only under the same test, on
  the clock that counts suspended time. A write whose answer was lost is not repeated blindly:
  the projector reads the record or the tree head back first. The tree head is written only after
  reading it and finding it lower. Writes issued in parallel
  ([data-model/backend.md](../data-model/backend.md) §6.1) are each under this test: once a check
  fails none is issued any more, and those in flight are what the quarantine covers.
- **The quarantine.** A client that takes over waits `PROJECT_QUARANTINE` before its first write,
  so every write the previous projector issued under its lease has landed or failed.
- **One timing per domain.** `PROJECT_LEASE`, `PROJECT_QUARANTINE` and `PROJECT_SETTLE` are settings
  of the domain ([05 §2.1](../05-ops-config.md#21-schema-and-validation), *domain-wide settings*),
  and every client of a main uses the same three: a quarantine covers the lease the previous
  projector worked under, and a settle shorter than another client's quarantine lets two clients
  take an entry over in turn without either writing. A client neither projects nor takes an entry
  over before it knows the timing its main states, or that the main states none.
- **Order.** An author whose entry is not the one after the tree head waits for the tree head to
  reach it. Commits do not wait for projections: any number of entries may be unprojected, and the
  settle and the quarantine are waited out beside the cycle, never inside it.
- **One entry per cycle.** A cycle pushes at most one entry and projects at most one, and the next
  cycle follows at once while either had work. A client that commits many entries therefore projects
  each before it commits the next, and the entry after the tree head is never kept waiting by its
  own author's pushes: left behind a long run of pushes it would pass `PROJECT_SETTLE` and be taken
  over from an author that is running. It also bounds what a cycle holds up: a pause or a stop takes
  effect between two entries, other clients' entries are fetched between them, and a change made
  while a backlog is projected is pushed after one entry, not after the backlog.
- **Not a source for merges.** Nothing a client reads from the tree enters $R$ except through a
  state read (§4.7), which replays the log over it.

Why one projector: applying an entry is many plain writes. Two clients applying different entries
to one record, in the wrong order, would leave it at the older value, and a collection marking from
that record would delete the newer content. The author needs no coordination; a takeover happens
only when an author stopped between its commit and the end of its projection.

### 4.7 State read and arrival by state

```
STATE() → M at some head:
  t := tree_head()
  Φ := the tree as its records say: every file record and every folder's anchor (05 §4.7 owns the walk)
  replay over Φ, in order, every log entry from t + 1 to the head, read as FETCH reads from t
    (PRUNED → start again)
  return Φ, at that head
```

- Records may already hold values that entries after $t$ give them. Replaying those entries sets
  each of their keys again, so the result is the tree at the head whatever a projection in progress
  had written.
- A walk that could not read a record fails as a whole and changes nothing
  ([failure-model.md](failure-model.md) §5.2). A record listed and then gone, or unclassifiable, is
  a write in flight and not a failure: the replay gives its key its value
  ([data-model/backend.md](../data-model/backend.md) §5.2).

A client **arrives by state** when its fetch answers PRUNED, when it has no position (a new client),
and on request (`tsync sync --full`). It is an ordinary
arrival whose $M$ is read whole: the merge of §4.4 runs with the client's own $R$ and $L$, so
pending changes are kept, guarded and merged as in any arrival. There is no state in which a client
applies nothing, and no operation that discards pending work.

**The in-flight record at an arrival by state.** The entry it names can no longer be read, so the
client cannot tell whether its batch was committed. It clears the record and lets the merge decide
key by key: a key that holds the batch's value on the main is "the same change". The one case it
gets wrong is a batch that was committed and then changed again by a peer, where the client keeps
its own superseded content as a conflicted copy. This needs an entry that expiry deleted before
its author recorded it: a client that stopped mid-push for longer than the log's retention.

### 4.8 Crash recovery

Run at ownership start, in this order, before any request is served and before the first cycle:

1. **Local intents.** Complete each namespace operation whose intent remains
   ([04](../04-checkout-cache.md) §4.10).
2. **The arrival record.** Set $L$ to the recorded values on the recorded keys, write the recorded
   before-values and position, stamp a new resync generation (§4.4), clear the record. Each step
   is idempotent.
3. **Before-values.** Drop each before-value equal to $L$ at its key.
4. **Promotion.** Promote each Uploaded staged edit whose key has no before-value and whose
   content is its base entry's: its key returned to what the main holds
   ([04](../04-checkout-cache.md) §4.7). Give each staged edit that is left with no before-value,
   Owed or Uploaded, the content identity of its base entry (§4.1): a commit promotes its edits
   itself (§4.5), so an edit that is left was not committed.
5. **Upload records.** Adopt every Owed staged edit that has no upload record
   ([04](../04-checkout-cache.md) §4.10).

A sync-state record that was set aside as undecodable ([03](../03-journal-sync.md) §2.7–2.8) makes
the client arrive by state before its next push.

The in-flight record is recovered by the first cycle, since it needs the store:

```
RECOVER(in-flight (n, body)):                 # n = h + 1, or n = h after a crash inside the Won step
  e := get_opt(log entry n)
  e = body → the Won step of §4.5             # ours
  e ≠ none → clear the record                 # another client's entry: the arrival that follows merges it
  e = none and tree_head() ≥ n → clear the record; arrive by state (§4.7)   # expired: outcome unknown
  e = none otherwise → put_if_absent(log entry n, body), as in §4.5         # never created
  failure → leave the record; no fetch, merge or push runs until it is settled
```

An entry carries its author, so equal bytes mean "this client's batch is entry $n$" and nothing
else does (Proposition 7). An absent entry at or below the tree head was deleted by expiry (§4.9):
creating it again would put a second entry at a number the log has passed. An absent entry above
the tree head was never created, since expiry never deletes there. A create whose answer is lost
is settled the same way at the next cycle, and `put_if_absent` itself answers `Won` when the name
already holds exactly these bytes ([06](../06-backends.md) §3.3).

**Crash windows.**

| Crash between | Durable state left | Recovery |
|---|---|---|
| a before-value and the change of $L$ | a before-value equal to $L$ | dropped (step 3) |
| the change of $L$ and the feed line | $L$ changed, no line | the feed misses one local change; frontends re-list what they hold open |
| staging content and its upload record | a staged edit, no record | adopted (step 5) |
| the chunk uploads and the Uploaded state | chunks on the main, edit not Uploaded | uploaded again; existing chunks are skipped |
| the in-flight record and the create | in-flight, no entry | the entry is absent above the tree head: created |
| the create and the `Won` step | in-flight, entry exists | the entry holds this client's bytes: the `Won` step |
| inside the `Won` step | in-flight, some edits promoted, some before-values and perhaps the position already written | the `Won` step again, from its start: a promoted edit's key holds the committed value, and its before-value is dropped |
| a before-value lost by local storage | an Uploaded staged edit with no before-value, whose content is not its base entry's | it takes its base entry's content as before-value (step 4) and is committed again |
| the `Won` step and the end of the projection | tree head below this client's entry | the next cycle projects it again from its start |
| the arrival record and the end of the local change | arrival record, $L$ partly changed | completed (step 2) |
| the end of the local change and the clearing of the record | arrival record, $L$ changed | completed again, to the same state |

### 4.9 Log retention

- Expiry ([gc.md](gc.md) §4.2) MAY delete a log entry only if its number is at most the tree head,
  it is not the head entry, and it is older than `LOG_RETENTION` by the store's own modification
  times. It deletes in ascending number order and stops at the first entry it keeps, so the
  retained entries stay contiguous whatever their modification times.
- **The head entry is never deleted**, so the log is never empty and its head can be read from it
  alone, by an operator or an integrity check. Clients do not depend on it: they find the head
  from their position and the tree head (§4.3).
- **An entry above the tree head is never deleted**: a state read replays it, and the collector
  marks from it ([gc.md](gc.md) §5.3).
- A client whose position was pruned arrives by state (§4.7). Nothing else follows from retention:
  no client keeps a record of entries it handled, and no entry can be applied twice.

### 4.10 One owner per domain

The protocol relies on P1 ([07](../07-daemon-cli.md) §2): one process owns a domain's local tree,
before-values, position, records, change feed and cycle. Consequences the protocol depends on:

- **One position.** Only the owner advances $h$, so an in-flight record always names $h+1$.
- **One author per machine.** Every process of a machine shares its client id, and only the owner
  creates entries, so "this client's entry" is unambiguous.
- **Feed keys** are minted by the owner alone, increasing ([03](../03-journal-sync.md) §2.2).
- **Pause** holds the cycle and the upload queue; the owner persists it
  ([07](../07-daemon-cli.md) §2.6). Local operations continue and the pending set grows.

### 4.11 The lazy tree

A lazy tree ([04](../04-checkout-cache.md) §3.5) holds some folders only, and reads each when it is
opened. It runs the same protocol **per folder**:

- **One position per folder held.** A folder's view is $M$ restricted to the keys of that folder
  (the file keys under it, and the folder keys whose place is in it), at that folder's position
  $h_f$. A before-value of one of those keys is the main's value at $h_f$. Different folders may
  be at different positions.
- **A pull is an arrival for one folder.** It fetches the entries after $h_f$ (§4.3) and keeps the
  commands on the folder's keys; when the fetch answers PRUNED, or the folder was never pulled, it
  reads the folder by state instead: the tree head, the folder's namespace, then the commands on
  its keys in the entries above that tree head (§4.7). It then merges (§4.4) with the folder's
  local values and before-values, and sets $h_f$ to the head it read. A folder with nothing
  pending simply takes the main's values.
- **A folder key belongs to the folder it is placed in.** A move of a folder between two folders
  held changes a key of each, and each learns of it at its own pull.
- **A push** is attempted only when every folder that holds a key of a pending command, and every
  ancestor of such a folder up to the root, has just been pulled to the head. The ancestors are
  needed because a folder's own key is in its parent's view: only they show that the folder still
  exists and that a pending move closes no cycle, which is what makes the batch well-formed
  (Definition 6). Its entry number is that head plus one, and its `Won` step sets those
  folders' positions to the entry's number. It does the same for each folder the entry creates,
  which no pull has a view of when it holds no key of the batch: this client knows its content
  at that entry, all of it its own, so a later change in it is checked against that view rather
  than waiting for a pull. Folders with nothing pending are not touched: their
  views stay as they are, however old, until they are pulled.
- **No background fetch.** Nothing fetches on the cursor or on a timer. The cycle runs to push,
  and pulls happen when the host asks.
- **A folder never pulled** has no view, so no local operation can record a before-value in it: it
  is pulled first, and the operation waits for that.
- **What a folder holds belongs to that folder's own view.** When a pull merges the removal or the
  move of a subfolder, only the subfolder's pending keys count as its content for the repair of
  the merge (R1): entries it holds from an older pull of its own are a view, not changes of this
  client, and are dropped with it. A subfolder moved into a folder this client does not hold is
  dropped locally, and comes back when that folder is pulled.
- **A folder merged into another** ([conflict-resolution.md](conflict-resolution.md) §4.2) has no
  view under the main's id, whatever the local folder had: it is a folder never pulled.
- **The cycle still runs**, to push: it wakes on a local change and on the batch delay, never on
  the cursor or on `SWEEP`.

Recovery (§4.8) is unchanged. An in-flight record is settled before the next pull or push that
reaches the main.

### 4.12 Bulk publishers

Bulk publishers (import, rsync, revert) run in the owner and are local operations: they upload
chunks, then set $L$ at each key to the manifest they built, with its before-value. Their changes
are pushed by the cycle like any other ([05](../05-ops-config.md) §4.2).

---

## 5. Properties and why they hold

### 5.1 Safety

**S1 — $R$ changes only on observed facts** (G3). A local operation records the current value
before it changes a clean key and leaves a dirty key's before-value alone (§4.1). $R$ changes only
in the `Won` step and in a merge.

**S2 — Every entry is a batch from the head** (G4). An entry $h+1$ is created from a state that
merged entry $h$, so its author's $R$ is $M_h$ and its batch gives a well-formed $M_{h+1}$
(Proposition 6). The append admits one entry per number (A2).

**S3 — Acknowledged work stays pending until committed** (G2). A before-value is dropped only when
$L$ returned to it, when the entry carrying the key's value was created, or by a merge, which keeps
every file content the client wrote (Theorem 8, property 4).

**S4 — No entry names content the main lacks.** On a main that is collected, the append goes
through the reference gate, which checks every chunk the entry's manifests name
([gc.md](gc.md) §5.4), and the staged bytes stay until the entry exists (§4.2). On any other main
nothing removes a chunk between its upload and its commit.

**S5 — A crash invents no conflict** (Proposition 7). The in-flight record is durable before the
create and recovered by issuing the same bytes again (§4.8).

**S6 — The tree is never behind its head.** One projector per entry (§4.6): a write issued under a
lease lands before the next projector's first write, by the quarantine. A record may be ahead of
the head, which a state read's replay absorbs (§4.7).

**S7 — The feed never runs ahead of the local tree** (G7). A line is appended after the change it
names is durable.

**S8 — Local operations never wait on the store** (G1). Store requests happen in the upload queue
and in the cycle, outside the metadata lock.

**S9 — Nothing read from a copy decides anything.** Fetches, state reads, the tree head and the
append are answered by the main or fail ([replication.md](replication.md) §4.6, Proposition 12).

### 5.2 Liveness

- **L1 — Outbound progress.** With the link up, every pending command is committed, or altered by
  a merge and then committed, after finitely many cycles (Theorem 11). An upload that keeps failing
  is parked, reported and re-armed; the rest of the pending set is pushed without it.
- **L2 — Inbound latency.** A committed entry is merged by a running owner within
  `CURSOR_INTERVAL` plus one store wait when the cursor note lands, and within `SWEEP` otherwise,
  unless the link is down or the domain is paused.
- **L3 — Projection.** An entry is projected by its generation-0 projector right after its commit. An entry whose
  projector stopped is projected within `PROJECT_SETTLE + PROJECT_QUARANTINE` of some running
  client seeing it, and the entries behind it follow.
- **L4 — Arrival always possible.** A fetch answers entries or PRUNED; a state read answers the
  tree whenever the main can be read.

---

## 6. Abandonment and operator action

- Nothing is abandoned: a pending command leaves the pending set only by a commit, by the user
  undoing it, or by a merge that keeps its content.
- A link outage fails fetches and pushes and holds the upload queue at its retries. Local
  operations continue.
- `tsync sync` runs one cycle now; `tsync sync --full` arrives by state
  ([05](../05-ops-config.md) §4.7).
- A client stopped on an entry it cannot decode (§4.3) is repaired by upgrading it, or by the tree
  head passing the entry.

---

## 7. Parameters

| Parameter | Recommended | Constraint / effect |
|---|---|---|
| `BATCH_DELAY` | 10 s | the client's choice; trades commits for latency; nothing depends on it; the domain's `batchDelay` |
| `MAX_ENTRY_BYTES` | 8 MiB | a larger batch is split into several entries; the put-body limit of a store on the way to the main is tied to it in [security-model.md](security-model.md) §11 |
| `MAX_ENTRY_COMMANDS` | 256; 4096 through a main that projects | bounds the record writes of one projection (§4.6); a client MAY use less; the domain's `maxEntryCommands`, or what an http-proxy main states |
| `SWEEP` | 60 s | worst-case latency when a cursor note is lost; one entry read per client per interval when idle |
| `CURSOR_INTERVAL` | 2 s | MUST be ≥ the store's per-object write interval |
| store wait | object store 2 s; local disk watch capped at 2 s; peer long poll ≤ 30 s | cursor reads per client |
| `RETRY_FLOOR` | 2 s | back-off after a failed cycle; the least time between two pushes made before `BATCH_DELAY` |
| `PROJECT_LEASE` | 30 s | how long a projector writes after one check; the domain's `projectLease` |
| `PROJECT_WIDTH` | 8 | the writes of one pass of a projection in flight at once; a client MAY use less; the domain's `projectWidth` |
| `PROJECT_QUARANTINE` | `PROJECT_LEASE` plus the longest time a store write can still land after it was issued (its stall bound through every attempt of the retry ladder, [01](../01-core.md) §7) plus a margin; 5 min | MUST exceed the time a write issued under a lease can still land; the domain's `projectQuarantine` |
| `PROJECT_SETTLE` | 10 min | how long an entry stays unprojected before another client takes it over; MUST exceed `PROJECT_QUARANTINE` by the time the slowest expected client takes to project a largest entry; the domain's `projectSettle` |
| `LOG_RETENTION` | 30 days | how far back a returning client fetches entries instead of reading the tree |

---

## 8. Conformance

An implementation MUST exhibit the following; the method (scenarios, crash injection, power-loss
states, multi-client runs) is [09](../09-tests.md) §6–8. The cases of
[change-algebra.md](change-algebra.md) §10 are part of this list.

- **Before-values.** A delete then a create of one name, publication held, pushes one command
  guarded by the old content. A create then a delete leaves no before-value and pushes nothing. A
  temporary file renamed onto a target pushes one write of the target and nothing for the
  temporary name. A folder renamed with content inside pushes one command.
- **Local-first.** With the link down, every write, rename, delete, mkdir, rmdir and symlink
  returns with no store round trip; everything is pushed once the link returns, in as few entries
  as `MAX_ENTRY_BYTES` and `MAX_ENTRY_COMMANDS` allow.
- **Nothing kept is dropped on the way.** After every entry a client commits, each content the
  main held before it and the client's tree still holds is at some file key on the main. A file
  renamed and then edited stays at its old name on the main until the content of the new name is
  uploaded. A move split over several entries never commits the removal first. Two swapped files
  are committed in one entry, whatever its size.
- **Upload first.** Two clients upload different content for one name; both uploads complete; the
  second to commit keeps its content as a conflicted copy with no new upload.
- **Refused push.** A push refused because of a commit that touches nothing pending is repeated at
  the next number with the same commands and no upload.
- **Batch delay.** Changes made within `BATCH_DELAY` are committed in one entry; a `sync` commits
  at once.
- **Fetch.** A fetch reads entries by number and lists nothing. A transient failure injected into
  an entry read or the tree-head read fails the fetch: the position does not move and nothing is
  merged.
- **Recovery.** A kill after the entry is created and before the client records it: the next cycle
  recognises it, and a further local write to the same name makes no conflicted copy. A kill before
  the entry is created: the batch is pushed once. A kill at any step of an arrival ends in the
  state of an uninterrupted arrival.
- **Projection.** After a commit the tree holds the entry's values and the tree head its number. The
  records and the versions an entry leaves are the same whatever number of its writes were in flight
  at once. A projector killed mid-entry applies it again and ends in the same tree. An entry whose
  author never returns is projected by another client after the settle and the quarantine, and not
  before; a first projector that resumes after a takeover writes nothing more.
- **Voided entry.** With an undecodable entry above the tree head, every client stops fetching
  and pushing and reports it. Once its void object exists, every client merges it as an empty
  entry, a client takes its projection over, and the entries behind it are merged and projected.
  A void object of an entry that decodes changes nothing.
- **State read.** A state read taken while entries are being projected equals the tree at the head
  it reports. A new client, a client whose position was pruned, and `--full` arrive by state; a
  client with pending changes that arrives by state keeps them pending, and a pending change that
  clashes becomes a conflicted copy.
- **Retention.** Expiry never deletes the head entry, an entry above the tree head, nor an entry
  younger than `LOG_RETENTION`.
- **Gate.** On a collectable main, an entry naming a chunk the main lacks is refused; the client uploads the chunk again
  from its staged bytes and commits. Staged bytes are released only after their commit.
- **Cursor.** Notes within `CURSOR_INTERVAL` coalesce into one write of the highest number; a flush
  writes at once and nothing when idle; a stop writes a held note.
- **Pause.** While paused nothing of this client reaches the store and nothing of the main's is
  merged; reads are served and local operations succeed; everything flows on resume.
- **Read from a copy.** With the main unreachable, content is read from a replica; no fetch, state
  read or push is answered by it, and the position and before-values do not change.

---

## 9. Rationale

- **Derive the pending set; do not record operations.** A recorded delete and a recorded create of
  one name are two commands with two guards, and the create's guard is wrong. The difference of two
  states has one command per key and the guard of the first.
- **A numbered log with an atomic append.** A guard is only as good as the check that enforces it.
  Entries named by time and author can be created concurrently, so every check-then-write on the
  tree has a window; one conditional create per commit closes it with the primitive every store
  already offers.
- **Upload first, commit after.** A commit that carried the upload would hold the head for hours,
  or need a marker with a lease to say "in progress". Content named by its hash needs neither.
- **Manifests inside entries.** An entry that named a manifest object would need that object
  protected from collection before any tree record names it. An entry that carries the manifest
  needs only its chunks, which the gate checks.
- **The tree as a projection.** Readers that cannot follow the log need per-object records, and
  the collector marks by them. Making them the truth again would bring back one arbitration per
  record.
- **One projector per entry, a takeover with a quarantine.** Letting any client apply any entry
  needs a conditional write and a conditional delete on every record, which stores do not all
  offer. The author is the natural single writer; a lease is needed only for an author that died.
- **A cap, not a heartbeat.** A projection could prove it is alive by rewriting an object, and
  watchers could wait while it changes. Bounding what one entry asks of its projector needs no
  object and no extra write; its cost is more entries for a large batch.
- **Commits do not wait for projections.** A dead author would otherwise stop every writer for the
  settle time.
- **Arrive by state instead of a hold.** The merge needs three states, not a history, so a client
  that missed entries merges against the tree. A separate "rebuild" that refuses to run over
  pending work has no place.
- **No record of entries handled.** Numbers are dense and each is read once; nothing can be
  delivered late or twice.
- **A lock held across store requests.** Simpler, and it freezes the mount on a slow link.
