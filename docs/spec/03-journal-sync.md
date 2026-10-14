# 03 — Log and sync: formats and interfaces

This file owns the persistent formats of multi-machine synchronisation and the interfaces between
its parts:

- the client identity and folder-id leases;
- the command encoding and the log entry on the store;
- the cursor, the tree head and the takeover object on the store;
- the position, the before-values, the in-flight record and the arrival record on the local disk;
- the feed key, the feed ops and the applied log on the local disk;
- the interfaces of the log store, the applied log, the cycle and the merge.

The behaviour is owned elsewhere and not restated here:

| Topic | Owner |
|---|---|
| The model: keys, values, commands, batches, the merge | [algorithms/change-algebra.md](algorithms/change-algebra.md) |
| Before-values, upload, fetch, push, projection, state read, recovery, retention | [algorithms/publication.md](algorithms/publication.md) |
| Enacting a merge, the conflicted-copy name, outcomes of every clash | [algorithms/conflict-resolution.md](algorithms/conflict-resolution.md) |
| Upload records and local intents | [04](04-checkout-cache.md) §2.8 |
| Folder-id grammar, logical paths, key validation (P4) | [01](01-core.md) §2 |
| Store key layout around the log; the manifest body | [02](02-remote-model.md) |
| Durable writes (P2) | [algorithms/durable-queue.md](algorithms/durable-queue.md) §3 |
| Failure kinds (P3) | [algorithms/failure-model.md](algorithms/failure-model.md) |
| Which process owns a domain (P1), status, `poll` | [07](07-daemon-cli.md) |
| The change-feed request (`changes_since`) | [08](08-frontends.md) §3.6 |
| Log expiry on the store | [algorithms/gc.md](algorithms/gc.md) |
| Store waits on the cursor, per driver | [06](06-backends.md), [backends/](backends/) |

The [OCaml notes](ocaml/03-journal-sync.md) describe the OCaml implementation.

---

## 1. Purpose

One person mounts the same domain from several machines. Machines never talk to each other; the
main is the only shared medium. Each client changes its local tree first and publishes later. A
published batch of changes is an immutable, numbered **log entry** on the main; a single
**cursor** object tells peers to look; each client keeps the main's value at every key it has
changed and not yet published (its **before-values**), and an **applied log** of the changes made
to its local tree, which is its local change feed. The formats below are what clients exchange and
what survives restarts.

---

## 2. Formats

All text is UTF-8. "Durable replace" and "durable create-if-absent" are the primitives of
[durable-queue.md](algorithms/durable-queue.md) §3.2.

### 2.1 Client identity and folder-id leases (local)

| Item | Location | Format |
|---|---|---|
| Client uuid | `<data_dir>/client-uuid` | 32 lowercase hex characters (16 random bytes), on the first line. Shared by every domain and process of the client. |
| Folder-id lease | `<data_dir>/id-leases/<block in lowercase hex>` | an empty file; its creation grants the block of 1024 counter values `block × 1024 … block × 1024 + 1023` |

- **Uuid creation** is race-free across processes: write the token to a temporary file, make it
  durable, then link it to `client-uuid` (a durable create-if-absent). If the link finds the file
  present, another process won: read its uuid. Readers take the first line, trimmed.
- **Folder ids** have the grammar of [01](01-core.md) §2.5: `<first 12 hex of the uuid>-<counter in
  lowercase hex>`. A process mints from a block it leased: it creates the next free block file
  (one past the highest existing block, retrying upward when the create finds it present), durably,
  before using its first id. A forked child leases its own block. Leases are never removed. Minting
  never contacts the store and never waits on another process.
- A minted id is final: it is the folder's identity on every client, and nothing on the store
  arbitrates or replaces it (assumption A4 of
  [change-algebra.md](algorithms/change-algebra.md)).

### 2.2 Feed key

A **feed key** names one line of the applied log and is what a change-feed anchor carries (§2.9,
[08](08-frontends.md) §2.5).

```
feed-key  = 13DIGIT "-" client-id        ; milliseconds since the epoch, zero-padded
client-id = 32hexlower                    ; written; readers accept 1*(any character but "/")
```

- **Writers** mint feed keys only in the domain owner: `max(now_ms, last + 1)`, where `last` starts
  at ownership from the largest key the applied log holds, so a clock step backwards never mints a
  used key.
- **Order**: by milliseconds, then by client id bytewise. Lexicographic order of the written form
  equals this order.
- **Month shard** of a key: the UTC year and month of its milliseconds, `YYYY-MM`.
- A feed key is local. It names nothing on the store.

### 2.3 Commands

A command is a key, the value before and the value after
([change-algebra.md](algorithms/change-algebra.md) Definition 4), one JSON object:

```json
{"file":["3f9a0c1b2d4e-40a","one.jpg"],"before":null,"after":"<base64 of a manifest body>"}
{"file":["3f9a0c1b2d4e-40a","two.jpg"],"before":"8f3a0c1b2d4e5f60-1b2d4e5f608f3a0c","after":null}
{"folder":"3f9a0c1b2d4e-40b","before":null,"after":[".tsync-root","Photos"]}
{"folder":"3f9a0c1b2d4e-40b","before":[".tsync-root","Photos"],"after":[".tsync-root","Pics"]}
{"folder":"3f9a0c1b2d4e-40b","before":[".tsync-root","Pics"],"after":null}
```

| Field | Meaning |
|---|---|
| `file` | a file key: `[folder id, leaf name]`. The leaf is one path segment ([01](01-core.md) §2.3) |
| `folder` | a folder key: a folder id other than the root's |
| `before` | the guard. For a file: the content identity `"<h1>-<h2>"` of the value replaced (33 characters, [02](02-remote-model.md) §2.1), or `null` for ∅. For a folder: `[parent folder id, leaf name]`, or `null` |
| `after` | the new value. For a file: standard padded base64 of the manifest body ([02](02-remote-model.md) §2.6), whose recorded name is the key's leaf, or `null`. For a folder: `[parent folder id, leaf name]`, or `null` |

- Exactly one of `file` and `folder` is present. `before` and `after` are always written, `null`
  included.
- A file rename is two commands: a removal at one key and a creation at the other, with the same
  manifest.
- **Reading a command** (entries come from a store and are untrusted, P4):
  - unknown fields are ignored;
  - a missing or ill-typed field, both or neither of `file` and `folder`, a folder id or a leaf
    that fails its grammar, a `before` that is not a content identity, or an `after` that does not
    decode to a manifest body, makes the whole entry CORRUPT
    ([failure-model.md](algorithms/failure-model.md)). An entry is never applied with a command
    dropped.
- A reader does not check `before` against its own state: the main checks nothing, and a client at
  the head knows the main exactly ([change-algebra.md](algorithms/change-algebra.md) Proposition
  6). A projection uses `before` to recognise the record a command replaces
  ([data-model/backend.md](data-model/backend.md) §6).

### 2.4 Log entry (store)

- **Number**: an integer ≥ 1, written as 16 decimal digits, zero-padded.
- **Key**: `tsync/<domain>/log/<group>/<number>`, where `<group>` is the number divided by 10 000,
  written as 12 decimal digits. Example: entry 1 234 567 is
  `tsync/photos/log/000000000123/0000000001234567`.
- **Body**: one JSON object:

  ```json
  {"v":1,"author":"3f9a0c1b2d4e5f60718293a4b5c6d7e8","commands":[ … ]}
  ```

  `v` is the format version, `1`. `author` is the client uuid of the creator. An optional
  `projector` is the client uuid of the entry's generation-0 projector, when that is not its
  author ([publication.md](algorithms/publication.md) §4.6); a reader that finds none takes the
  author, and one that finds anything but 32 lowercase hexadecimal digits finds the entry CORRUPT. `commands` is the
  batch, a non-empty array of commands (§2.3) on distinct keys, in any order: a batch is a set
  ([change-algebra.md](algorithms/change-algebra.md) Definition 6).
- **Writers** create an entry on the main only with `put_if_absent`, with the body bounded by
  `MAX_ENTRY_BYTES` unless it holds one command, and at most `MAX_ENTRY_COMMANDS` commands
  ([publication.md](algorithms/publication.md) §4.5). A writer MUST decode the body it is about
  to create and refuse to send one that does not read back as the batch. An entry is immutable: its
  key is only ever put again with the same bytes (recovery,
  [publication.md](algorithms/publication.md) §4.8).
- **Readers**:
  - read an entry by its number, never by listing;
  - a body that is not a JSON object, lacks a field, or holds two commands on one key is CORRUPT;
  - a `v` greater than 1 is an entry this reader cannot follow
    ([publication.md](algorithms/publication.md) §4.3); it is not CORRUPT;
  - never turn a failed read into "no entry"
    ([failure-model.md](algorithms/failure-model.md) §5.2).
- Replica members carry the log as copies of the main's entries, written by their job logs and by mirror; backfill members do not
  ([algorithms/replication.md](algorithms/replication.md)).

### 2.5 Cursor (store)

- **Key**: `tsync/<domain>/cursor`.
- **Body**: one entry number in its written form (§2.4), with no trailing newline: the head, as far
  as the writer knew.
- **Readers** trim surrounding whitespace. A body that does not parse is treated as a cursor that
  moved (a fetch follows).
- The cursor is a hint: last writer wins, it may be stale, lost, or move backwards.
- A store wait on the cursor compares the object's bytes: a caller's token is the body it last read.

### 2.6 Tree head and takeover (store)

- **Tree head**, at `tsync/<domain>/tree-head`: `{"n":<entry number as an integer>}`. Every entry up
  to `n` is projected. Absent reads as 0. A body that does not parse is CORRUPT. Written by a plain
  put, only by the projector of entry `n` ([publication.md](algorithms/publication.md) §4.6), and
  only to raise it.
- **Takeover**, at `tsync/<domain>/log-takeover/<number>-<generation>`: the body is the client uuid
  of the client that may project entry `<number>` at that generation, a decimal integer ≥ 1.
  Created only with `put_if_absent`. The highest generation of an entry is found by reading
  generations upward from 1 until one is absent. A takeover object MAY be deleted once the tree
  head has passed its entry.
- **Void**, at `tsync/<domain>/log-takeover/<number>-void`: the body is the client uuid of the
  client that created it. Created only with `put_if_absent`. It makes an entry that does not
  decode read as empty ([publication.md](algorithms/publication.md) §4.3). It lies under the
  takeovers' prefix, and every rule about where takeovers are copied, kept and deleted covers it.

### 2.7 Position, in-flight record and arrival record (local)

Under `<data_dir>/sync/<domain>/`, each written by durable replace, in the order
[publication.md](algorithms/publication.md) §4.5 gives when several change together:

| File | Content |
|---|---|
| `position` | (full tree; a lazy tree keeps one position per folder, [04](04-checkout-cache.md) §2.3) the number of the last entry merged, in its written form (§2.4). Absent: no position; the client arrives by state ([publication.md](algorithms/publication.md) §4.7). Unparseable: reported and treated as absent |
| `in-flight` | `{"n":<number>,"body":"<base64 of the exact bytes of the entry>"}`. Absent: no push is in flight |
| `arrival` | the result of a merge being enacted (below). Absent: no arrival is in progress |

**Arrival record**: one JSON object.

```json
{"head":1234567,
 "steps":[{"reidentify":"5c2e81d07a3b-3","as":"3f9a0c1b2d4e-40a"},
          {"move":["3f9a0c1b2d4e-40a","a.txt"],"to":["3f9a0c1b2d4e-40a","a (conflicted copy from laptop).txt"]},
          {"file":["3f9a0c1b2d4e-40a","a.txt"],"value":"<base64 of a manifest body>"},
          {"folder":"3f9a0c1b2d4e-40b","value":[".tsync-root","Pics"]}],
 "before":[{"file":["3f9a0c1b2d4e-40a","a (conflicted copy from laptop).txt"],"before":null}]}
```

- `head`: the position the arrival ends at.
- `view` (lazy tree only): the id of the folder whose position the arrival sets
  ([publication.md](algorithms/publication.md) §4.11). Absent on a full tree.
- `steps`, in an order in which each can be applied to the local tree
  ([change-algebra.md](algorithms/change-algebra.md) Theorem 3): `reidentify` gives the local
  folder held under one id the other id where it stands, with what it holds, when the first id is
  held ([conflict-resolution.md](algorithms/conflict-resolution.md) §4.2); `move` takes the local file at
  one key to another key when the source is present and the destination absent;
  `file` and `folder` set a key to `value` (`null` for ∅). A folder parked at a temporary place is
  a `folder` step whose value names the root and the leaf `.tsync-park-<folder id>`, followed
  later by the step that gives it its place. That leaf is not a temporary name of
  [01](01-core.md) §2.9: the sweep of temporary files at owner start runs before the record is
  completed and MUST NOT take a parked folder. Every step is idempotent.
- `before`: the before-value, after the arrival, of each key the arrival fetched or created, in
  the encoding of §2.8 (`"drop":true` in place of `before` for a key that ends with none). Keys
  the arrival did not touch are not listed and are left as they are.
An unparseable in-flight or arrival record is set aside
([durable-queue.md](algorithms/durable-queue.md) R6); the client then arrives by state before it
pushes again.

### 2.8 Before-values (local)

`<data_dir>/sync/<domain>/before/<record name>`, one file per dirty key, written by replace,
made durable as [publication.md](algorithms/publication.md) §4.1 says, and removed by release:

| Key | Record name | Body |
|---|---|---|
| file key `(d, a)` | `f-<d>-<leaf hash of a>` ([02](02-remote-model.md) §2.1) | `{"file":["<d>","<a>"],"before":<null or "<h1>-<h2>">}` |
| folder key `i` | `d-<i>` | `{"folder":"<i>","before":<null or ["<parent id>","<leaf>"]>}` |

- The presence of a record is what makes a key pending. `before` is the main's value at the key as
  this client last knew it ([publication.md](algorithms/publication.md) §3.2).
- Local only: a before-value reaches the store only as the `before` of a command.
- An unparseable record is set aside, and the client arrives by state before it pushes again. A
  record whose `before` alone does not parse keeps its key pending with an **unknown** before-value,
  which differs from every value. A client writes one, as `"before":"unknown"`, for a file key
  whose value it cannot read from its own tree (a mirror entry that does not decode). A key with an
  unknown before-value is left out of every push, and the client arrives by state before it pushes
  again: the arrival reads the main's value at the key, and what the client holds there that
  differs is kept as a conflicted copy ([conflict-resolution.md](algorithms/conflict-resolution.md)). A record whose key cannot be read is no before-value: a file
  key's record name holds a hash of its leaf, so the key cannot be recovered from the name. Its
  key then reads as clean, and the arrival by state installs the main's value there unless a
  staged edit holds it ([publication.md](algorithms/publication.md) §4.8 step 3).

### 2.9 Feed ops and the applied log (local)

**Feed ops** describe a change of the local tree to frontends, by path. One op is one JSON object;
optional fields are omitted, never written as `null`.

```json
{"op":"put","key":"photos/one.jpg","size":1024}
{"op":"delete","key":"photos/two.jpg"}
{"op":"mkdir","key":"photos","id":"3f9a0c1b2d4e-40a"}
{"op":"rmdir","key":"photos","id":"3f9a0c1b2d4e-40a"}
{"op":"rename","key":"photos/two.jpg","src":"photos/one.jpg","is_dir":false,"size":1024}
{"op":"rename","key":"pics","src":"photos","is_dir":true,"id":"3f9a0c1b2d4e-40a"}
```

| Op | Required | Optional |
|---|---|---|
| `put` | `key` (path), `size` (integer ≥ 0) | `fid` |
| `delete` | `key` | `fid` |
| `mkdir` | `key`, `id` (folder id) | — |
| `rmdir` | `key`, `id` | — |
| `rename` | `key` (destination), `src` | `is_dir` (boolean, absent = `false`), `size`, `id` (folder id, for a folder), `fid` |

- Paths are domain-relative logical paths ([01](01-core.md) §2.3) as they were when the change was
  made.
- `fid` is the file's local id ([01 §2.7](01-core.md#27-item-references)) when the change was made,
  so the feed names the file even after it moved again or went. Writers MUST record it for every op
  naming a file. Readers SHOULD accept an op without it: the feed then names the file by the id now
  at the op's path, or counts it unnamed.
- A reader ignores an op whose `op` it does not know, and unknown fields.
- The **paths an op concerns** are `[key]`, or `[key, src]` for a rename.
- Feed ops are also the body of a local intent ([04](04-checkout-cache.md) §2.8).

**Applied log.**

- **Directory**: `<cache_root>/<domain>/applied/`.
- **Shards**: files `YYYY-MM.log`, the month shard of the line's feed key. Shard names sort
  chronologically.
- **Record**, newline-*led*:

  ```
  \n<feed key>\t<JSON array of feed ops>
  ```

- **Appending**: one write per record to the newest shard (opened append-only, created with mode
  0600), made durable. A line is appended only after the change it names is durable in the local
  tree. The newline leads, so a record torn by a crash is closed by the next append and only that
  record is lost.
- **Contents**: one line per local operation, and one line per arrival holding the changes the
  merge made to the local tree, a move aside included. An arrival by state is reported the same
  way, split into lines of at most `FEED_LINE_OPS` ops.
- **Reading**: split on `\n`; a line that has no tab, whose key does not parse, or whose second
  field is not a JSON array is dropped (a torn record). An op the reader cannot decode is dropped
  from its line rather than failing it.
- **Position**: the log's order is shard order, then line order, which is feed-key order.
- **Retention**: a shard MAY be deleted only when it is not the newest shard, every key in it is
  older than `FEED_RETENTION`, and it precedes the shard holding the line the feed watermark names
  ([08 §3.6](08-frontends.md#36-change-feed-changes_since)). Deleting a shard sets the
  dropped-shard record durably first. There is no size-based pruning.

### 2.10 Upload records and local intents

[04](04-checkout-cache.md) §2.8.

### 2.11 Conflicted-copy name

[conflict-resolution.md](algorithms/conflict-resolution.md) §5.

---

## 3. Interfaces

The interfaces are language-neutral. Every operation that touches the store may fail with a kind of
[failure-model.md](algorithms/failure-model.md); ABSENT is returned only where stated. Every store
operation here is answered by the main, never by a copy
([replication.md](algorithms/replication.md) §4.6).

### 3.1 Log store (the log's store seam)

```
read_entry(n)             → entry | ABSENT                    | failure (CORRUPT for §2.3/§2.4 violations)
read_entries(from)        → [entry], contiguous from `from`   | failure     (MAY batch; stops at the first absent)
create_entry(n, bytes)    → Won | Held                        | failure (missing chunks: gc §5.4)
tree_head()               → n                                 | failure
tree_head_write(n)        → ()                                | failure
takeover_generation(n)    → g ≥ 0                             | failure
takeover_create(n, g)     → Won | Held(client)                | failure
void_exists(n)            → bool                              | failure
void_create(n)            → Won | Held(client)                | failure
cursor_read()             → number | none                     | failure
cursor_wait(token)        → () when the cursor may have changed, bounded      (driver-paced; expiry is not a failure)
cursor_note(n)            → ()   never writes inline; arms the debouncer
cursor_flush()            → ()   writes the pending number now; a failure is logged and dropped
```

### 3.2 Sync state (local)

```
position()                         → n | none
before(key)                        → value | none | unknown
record_before(key, value)          → ()   a no-op if the key has one; durability per publication §4.1
drop_before(key)                   → ()
pending()                          → [command]            one per before-value
in_flight()                        → (n, bytes) | none
committed(n, batch)                → ()   the Won step: before-values, then the position, then the in-flight record
arrival_begin(record), arrival_end()
```

### 3.3 Applied log

```
note([op])                         → feed key   durable
since(anchor?, limit)              → page | stale
    page = { entries: [(key, [op])] in log order, at most limit; more: bool }
    anchor given: the entries after the anchor's position; stale if the anchor is not kept
    no anchor: from the start of the kept log
head()                             → the key of the last line | none
prune(now)                         → shards removed          (§2.9)
```

### 3.4 Cycle (one per domain, in the owner)

```
recover()                          → ()        at ownership start (publication §4.8)
arrive()                           → changes made to the local tree (publication §4.4)
arrive_by_state()                  → changes made to the local tree (publication §4.7)
push()                             → committed n | refused | nothing to push (publication §4.5)
project()                          → the tree head reached (publication §4.6)
poll()                             ends the current wait; a cycle runs now and pushes what is due,
                                     not what the batch delay still holds
status()                           → position, pending count, in-flight?, the tree head as last read,
                                     an entry that cannot be followed, if any: its number, and whether it does not
                                     decode or is of an unknown version; why the last background
                                     cycle failed, until one runs again
```

The cycle is parameterised by the log store, the sync state, the applied log, the staged-edit
store, the domain configuration and the domain's file operations; the file operations provide the
enactment of a merge it calls back.

### 3.5 Upload queue

Keyed, one job per file key: pending, in flight, pending bytes, completed count, parked, pause,
settle, re-arm, wait until a given key's content is uploaded, and until it is committed. It is a
durable queue over the upload records ([durable-queue.md](algorithms/durable-queue.md) §4).

### 3.6 Merge (the policy seam)

```
MERGE(R, L, M)  → N                                       total, pure (change-algebra Definition 7)
clashed(R, L, M, N) → [key]                               the keys a merge did more than install M at
describe(…) → text                                        for logs and the exhaustive listing
```

Enactment lives with the file operations, which own the metadata lock and cannot reach the store
while holding it ([conflict-resolution.md](algorithms/conflict-resolution.md) §4).

---

## 4. Conformance

An implementation MUST exhibit:

- **Commands and entries.** Every command round-trips, with `null` written for ∅; a reader ignores
  unknown fields; a command missing a field, naming an invalid folder id or leaf, or carrying an
  `after` that is not a manifest makes its entry CORRUPT; an entry with two commands on one key is
  CORRUPT; an entry of a later version is reported as one the client cannot follow, and is not
  CORRUPT.
- **Entry keys.** Entry 1 234 567 has the key of §2.4; a failed read is never "no entry".
- **Cursor.** A body with a trailing newline reads as its number; an unparsable body triggers a
  fetch.
- **Tree head.** Absent reads as 0; it is never written lower than it was read.
- **Local records.** The position, in-flight record, arrival record and before-values are written
  by durable replace; an absent position reads as none; an unparseable record is set aside and
  leads to an arrival by state before the next push; a before-value record's name follows from its
  key.
- **Applied log.** `since` returns oldest first, is exclusive of the anchor, sets `more` only when
  entries remain, crosses shard boundaries, and answers stale for an anchor not kept; a torn line
  does not stop the reader; the head is found past a line longer than any read-ahead window.
- **Identity.** Concurrent processes agree on one client uuid; folder ids minted by forked and
  concurrent processes are distinct.

---

## 5. Parameters

| Parameter | Value | Notes |
|---|---|---|
| Folder-id lease block | 1024 ids | |
| Log group | 10 000 entries per directory | |
| Applied-log shard | one per UTC month | |
| `FEED_LINE_OPS` | 64 | ops per line of an arrival by state |
| `FEED_RETENTION` | 30 days | how long a change-feed anchor without a watermark stays answerable |
| Timing and retention parameters of the protocol | — | [publication.md](algorithms/publication.md) §7 |
