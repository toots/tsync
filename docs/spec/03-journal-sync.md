# 03 — Journal and sync: formats and interfaces

This file owns the persistent formats of multi-machine synchronisation and the interfaces between
its parts:

- the client identity and the entry key;
- the journal op vocabulary and its encoding;
- the journal entry and the cursor on the store (frozen formats);
- the last-sync mark and the applied log on the local disk;
- the interfaces of the journal store, the applied log, the replication engine, the poller, the
  outbound queues and the conflict decisions.

The behaviour is owned elsewhere and not restated here:

| Topic | Owner |
|---|---|
| WAL states, publishing, discovery, application, recovery, horizon, bridging, rebuild | [algorithms/wal-and-journal.md](algorithms/wal-and-journal.md) |
| Conflict principle, decision tables, conflicted-copy name | [algorithms/conflict-resolution.md](algorithms/conflict-resolution.md) |
| WAL record byte format | [04](04-checkout-cache.md) §2.8 |
| Folder-id grammar, logical paths, key validation (P4) | [01](01-core.md) §2 |
| Store key layout around the journal | [02](02-remote-model.md) |
| Durable writes (P2) | [algorithms/durable-queue.md](algorithms/durable-queue.md) §3 |
| Failure kinds (P3) | [algorithms/failure-model.md](algorithms/failure-model.md) |
| Which process owns a domain (P1), status, `poll` | [07](07-daemon-cli.md) |
| The change-feed request (`changes_since`) | [08](08-frontends.md) §3.6 |
| Journal expiry on the store | [algorithms/gc.md](algorithms/gc.md) |
| Store waits on the cursor, per driver | [06](06-backends.md), [backends/](backends/) |

The [OCaml notes](ocaml/03-journal-sync.md) describe the OCaml implementation.

---

## 1. Purpose

One person mounts the same domain from several machines. Machines never talk to each other; the
store is the only shared medium. Each client writes locally first and publishes later. A published
unit of work is an immutable **journal entry** on the store; a single **cursor** object tells peers
to look; each client keeps an **applied log** of what it handled, which is also its local change
feed. The formats below are what clients exchange and what survives restarts.

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

### 2.2 Entry key

An **entry key** names one unit of work: the WAL record, the journal entry, the cursor value, the
applied-log line and the change-feed anchor ([wal-and-journal.md](algorithms/wal-and-journal.md)
§3.1).

```
entry-key = 13DIGIT "-" client-id        ; milliseconds since the epoch, zero-padded
client-id = 32hexlower                    ; written; readers accept 1*(any character but "/")
```

Example: `1788134400000-3f9a0c1b2d4e5f60718293a4b5c6d7e8`.

- **Writers** mint keys only in the domain owner, as specified in
  [wal-and-journal.md](algorithms/wal-and-journal.md) §4.9.
- **Parser**: take the last `/`-separated segment (so a listing path or a stored line is accepted);
  require exactly 13 decimal digits, then `-`, then a non-empty client id. Anything else is not an
  entry key; in particular a month directory such as `2026-08` never parses.
- **Order**: by milliseconds, then by client id bytewise. The order is total, not causal.
  Lexicographic order of the written form equals this order.
- **Month shard** of a key: the UTC year and month of its milliseconds, `YYYY-MM`.
- **Mark keys**: the last-sync mark (§2.6) is an entry key with this client's id and a
  millisecond value that names a time, not a unit of work.

### 2.3 Journal ops

One op is one JSON object. Writers emit exactly these fields; optional fields are **omitted**,
never written as `null`, so older readers see what they always saw.

```json
{"op":"put","key":"photos/one.jpg","size":1024}
{"op":"put","key":"photos/one.jpg","size":2048,"base":"8f3a0c1b2d4e5f60"}
{"op":"delete","key":"photos/two.jpg"}
{"op":"mkdir","key":"photos","id":"3f9a0c1b2d4e-40a"}
{"op":"rmdir","key":"photos","id":"3f9a0c1b2d4e-40a"}
{"op":"rename","key":"photos/two.jpg","src":"photos/one.jpg","is_dir":false,"size":1024}
{"op":"rename","key":"pics","src":"photos","is_dir":true,"id":"3f9a0c1b2d4e-40a"}
```

| Op | Required | Optional |
|---|---|---|
| `put` | `key` (path), `size` (integer ≥ 0) | `base` (16 lowercase hex: the content identity `h1` of the manifest the edit started from, [02](02-remote-model.md) §2.1) |
| `delete` | `key` | — |
| `mkdir` | `key` | `id` (folder id) |
| `rmdir` | `key` | `id` |
| `rename` | `key` (destination), `src` | `is_dir` (boolean, absent = `false`), `size` (integer ≥ 0), `id` (folder id, for a folder) |

- Paths are domain-relative logical paths ([01](01-core.md) §2.3): `/`-separated, no leading `/`,
  non-empty. Folder ids follow [01](01-core.md) §2.5. Sizes are 64-bit integers written in full.
- `base` is written only when the writer knows it, and omitted otherwise (never `null`). Readers
  that predate it ignore it. Its use: [conflict-resolution.md](algorithms/conflict-resolution.md)
  A2a.
- Directory ops carry the folder's id because applying a removal destroys the local evidence it
  could otherwise be read from. An op without `id` names the folder by path alone. Readers SHOULD accept it; writers MUST always
  include `id`.
- **Reading an op** (entries come from a store and are untrusted, P4):
  - an object whose `op` is a string this reader does not know is **ignored** (forward
    compatibility);
  - unknown fields are ignored;
  - a known op with a missing or ill-typed required field, a path that fails the grammar, an
    `id` that fails the folder-id grammar, or a `base` that is not 16 lowercase hex makes the whole
    entry CORRUPT
    ([failure-model.md](algorithms/failure-model.md)); it is never applied with the op dropped.
- The **paths an op concerns** are `[key]`, or `[key, src]` for a rename; a reader deciding whether
  an op touches a path tests all of them.

### 2.4 Journal entry (store; frozen)

- **Key**: `tsync/<domain>/journal/<YYYY-MM>/<entry key>`, where `YYYY-MM` is the month shard of
  the entry key (§2.2). Example: `tsync/photos/journal/2026-09/1788134400000-3f9a…e8`.
- **Body**: the entry's ops, each encoded as §2.3 on its own line, joined by `\n`, with a trailing
  `\n`. An entry with no ops has an empty body.
- **Writers** write a new entry once, with a plain put, under the canonical key. An entry is
  immutable: the same key is only ever re-put with the same bytes (recovery,
  [wal-and-journal.md](algorithms/wal-and-journal.md) §4.7).
- **Readers**:
  - list the whole prefix `tsync/<domain>/journal/` recursively, and take as entries the objects
    whose last path segment parses as an entry key (§2.2). An entry directly under the prefix, or in
    a directory other than its month shard, is still an entry: readers SHOULD accept it; writers
    MUST write the canonical key. A key listed at several places is one entry, and any of its
    objects may be read;
  - read an entry at the location the listing returned;
  - split the body on `\n`, trim each line of surrounding whitespace, ignore empty lines, decode
    each remaining line as §2.3; a line that is not a JSON object makes the entry CORRUPT;
  - never turn a failed read or listing into "no entry" or "no entries"
    ([failure-model.md](algorithms/failure-model.md) §5.2).
- Replica members carry the journal; backfill members carry neither journal nor cursor
  ([algorithms/replication.md](algorithms/replication.md)).

### 2.5 Cursor (store; frozen)

- **Key**: `tsync/<domain>/cursor`.
- **Body**: one entry key in its written form (§2.2), with no trailing newline: the newest entry the
  writer published, as far as it knew.
- **Readers** trim surrounding whitespace, take the last `/` segment, and parse it as an entry key.
  A body that does not parse is treated as a cursor that moved (a listing follows) and as no cursor
  for the bridge check ([wal-and-journal.md](algorithms/wal-and-journal.md) §4.8).
- The cursor is a hint: last writer wins, it may be stale, lost, or move backwards.
- A store wait on the cursor compares the object's bytes: a caller's token is the body it last read.

### 2.6 Last-sync mark (local)

- **Path**: `<data_dir>/last-sync-<domain>`.
- **Content**: one line holding an entry key (§2.2), of any client; a trailing newline is allowed.
  A line holding a longer path whose last `/` segment is an entry key (such as the entry's store
  key) denotes that key: readers SHOULD accept it; writers MUST write the bare key. Its meaning is specified in
  [wal-and-journal.md](algorithms/wal-and-journal.md) §4.8.
- **Written** by durable replace, forward only.
- **Read**: absent (ENOENT) means no mark. Content that does not parse is reported and treated as no
  mark (the consequence is a rebuild, which is safe). Any other read failure is a failure, never "no
  mark".

### 2.7 Applied log (local)

- **Directory**: `<cache_root>/<domain>/applied/`.
- **Shards**: files `YYYY-MM.log`, where the month is the UTC month in which the entry was
  **handled** (appended), not the month of its key. Shard names sort chronologically.
- **Record**, newline-*led*:

  ```
  \n<entry key>\t<JSON array of ops, §2.3>
  ```

  e.g. `\n1788134400001-3f9a…e8\t[{"op":"put","key":"photos/one.jpg","size":1024}]`.
- **Appending**: one write per record to the newest shard (opened append-only, created with mode
  0600), made durable before anything relies on it: an own entry's record is durable before the
  entry is put on the store; a peer entry's record before the mark can pass it. The newline leads,
  so a record torn by a crash is closed by the next append and only that record is lost.
- **At most one record per key.** The owner appends a key only if it is not already in the log (its
  handled set). A key on several lines: readers SHOULD accept it, and its position is its
  earliest line; writers MUST NOT append a key twice.
- **Contents**: this client's published entries; peers' applied entries; rebuild findings (under
  freshly minted keys, with the ops a rebuild's diff amounts to); keys a rebuild marked handled
  (with `[]`).
- **Reading**: split on `\n`; a line that has no tab, whose key does not parse, or whose second
  field is not a JSON array is dropped (a torn record). Ops inside a kept line are decoded by §2.3,
  except that an op the reader cannot decode is dropped from the line rather than failing it.
- **Position**: the log's order is shard order, then line order. The position of a key is its
  **earliest** line. Order of lines is order of handling; it is the feed order and is unrelated to
  key order.
- **Retention**: shards are deleted only as [wal-and-journal.md](algorithms/wal-and-journal.md)
  §4.8 allows. Nothing else removes lines.

### 2.8 WAL record

The byte format is [04](04-checkout-cache.md) §2.8; the states, record kinds and the information a
record carries are [wal-and-journal.md](algorithms/wal-and-journal.md) §4.1.

### 2.9 Conflicted-copy name

[conflict-resolution.md](algorithms/conflict-resolution.md) §4.7.

---

## 3. Interfaces

The interfaces are language-neutral. Every operation that touches the store may fail with a kind of
[failure-model.md](algorithms/failure-model.md); ABSENT is returned only where stated.

### 3.1 Journal store (the journal's store seam)

```
list_entries()            → [(entry key, object)] sorted by key, complete    | failure
read_entry(object)        → [op] | ABSENT                                    | failure (CORRUPT for §2.3/§2.4 violations)
entry_exists(key)         → present | ABSENT (at the canonical key)          | failure
write_entry(key, [op])    → ()                                               | failure
cursor_read()             → entry key | none                                 | failure
cursor_wait(token)        → () when the cursor may have changed, bounded      (driver-paced; expiry is not a failure)
cursor_note(key)          → ()   never writes inline; arms the debouncer
cursor_bump(key)          → ()   writes now if the debounce interval has passed, else as note
cursor_flush()            → ()   writes the pending key now; a failure is logged and dropped
mark_read()               → entry key | none                                 | failure
mark_write(key)           → ()                                               | failure
```

The seam never mints keys: every write names its key. The cursor debouncer
([wal-and-journal.md](algorithms/wal-and-journal.md) §4.2) is one per cursor object in the owner.

### 3.2 Applied log

```
note(key, [op])                    → ()   durable; a no-op if key is present
contains(key)                      → bool
keys()                             → every kept key          (loaded once by the owner)
since(anchor?, limit)              → page | stale
    page = { entries: [(key, [op])] in log order, at most limit; more: bool }
    anchor given: the entries after the anchor's position; stale if the anchor is not kept
    no anchor: from the start of the kept log
head()                             → the key of the last line | none
prune(now)                         → shards removed          (per wal-and-journal §4.8)
```


### 3.3 Publishing

`PUBLISH(key, ops)` is the one operation that publishes an entry: note in the applied log, write
the entry, announce the paths to the owner's frontends, note the cursor
([wal-and-journal.md](algorithms/wal-and-journal.md) §4.2). No other code writes journal entries.

### 3.4 Replication engine (one per domain, in the owner)

```
reconcile()                        → ()        at ownership start (wal-and-journal §4.7)
apply_pass(cursor)                 → entries applied (wal-and-journal §4.4)
rebuild_done(listed keys, t0)      → ()        notes the keys handled and moves the mark (§4.8)
unapplied()                        → [(entry key, reason)]   the stepped-aside entries
bridge()                           → incremental | hold(reason), with the mark and its age
```

The engine is parameterised by the journal store, the applied log, the WAL, the staged-edit store,
the domain configuration and the domain's file operations; the file operations provide the arrival
enactment, the publish decision and the local redo it calls back.

### 3.5 Poller

```
start(paused?, on_changed)         one loop per domain in the owner (wal-and-journal §4.3)
poll()                             ends the current wait; a pass runs soon
```

### 3.6 Outbound queues

- **Upload queue** (keyed, one job per file): pending, in flight, pending bytes, completed count,
  pause, settle, wait until a given path's upload settles.
- **Metadata queue** (ordered, one worker): pending (queued and in flight), parked, pause, settle,
  re-arm.
- Both are durable queues over the WAL ([durable-queue.md](algorithms/durable-queue.md) §4), each
  taking its record kinds ([wal-and-journal.md](algorithms/wal-and-journal.md) §4.1).

### 3.7 Conflict decisions (the policy seam)

```
ARRIVAL.decide(facts)  → skip(reason) | apply([action])      total, pure
PUBLISH.decide(facts)  → { actions: [action]; ending }       total, pure
clashed(decision)      → bool
describe(facts), describe(decision) → text                    for logs and the exhaustive listing
```

Facts, actions and endings are those of
[conflict-resolution.md](algorithms/conflict-resolution.md) §4.2–4.6. Fact gathering and enactment
live with the file operations, which own the metadata lock and cannot reach the store while holding
it.

---

## 4. Conformance

An implementation MUST exhibit:

- **Entry keys.** Written keys round-trip through the parser; a month directory, a temporary name
  and a key with fewer than 13 digits do not parse; a listing path yields the key of its last
  segment; order equals the lexicographic order of written keys.
- **Ops.** Every op round-trips, `put` with and without `base`; optional fields are omitted when
  absent; a reader ignores an
  unknown `op` and unknown fields; `is_dir` absent reads `false`; a known op missing a required
  field, or naming an invalid path or folder id, makes its entry CORRUPT.
- **Entries.** An entry placed under its month directory and one placed directly under the journal
  prefix are both listed and read; blank lines and `\r\n` line ends are tolerated; a failed listing
  or read is never "no entries" or "no entry".
- **Cursor.** A body with a trailing newline or a path prefix reads as its key; an unparsable body
  triggers a listing.
- **Mark.** Written by durable replace; absent reads as no mark; an unparsable mark is reported and
  read as no mark; a read failure is a failure.
- **Applied log.** A record is kept under its key; `since` returns oldest first, is exclusive of the
  anchor, sets `more` only when entries remain, crosses shard boundaries, and answers stale for an
  anchor not kept; an entry handled late with an older key follows the anchor and becomes the head;
  a torn line does not stop the reader; the head is found past a line longer than any read-ahead
  window; noting a key twice leaves one line; with a log holding a key twice, the earliest
  line is the anchor's position.
- **Identity.** Concurrent processes agree on one client uuid; folder ids minted by forked and
  concurrent processes are distinct.

---

## 5. Parameters

| Parameter | Value | Notes |
|---|---|---|
| Folder-id lease block | 1024 ids | MUST stay 1024: existing lease files grant blocks of this size |
| Applied-log shard | one per UTC month of handling | |
| Timing, horizon and retention parameters | — | [wal-and-journal.md](algorithms/wal-and-journal.md) §7 |
