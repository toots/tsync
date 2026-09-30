# 06 — Backends: the store contract

Scope: the contract every store implements, the composite interface, the process-wide store services, the admission seam through which uploads are paced, and the uplink configuration. The composite's policy (roles, read and write paths, copies, write guard, repair) is [algorithms/replication.md](algorithms/replication.md). The rate law and the lease protocol are [algorithms/uplink-governor.md](algorithms/uplink-governor.md). Failure kinds are [algorithms/failure-model.md](algorithms/failure-model.md). What a domain stores, and the byte formats of every object, are [data-model/backend.md](data-model/backend.md) and [02-remote-model.md](02-remote-model.md).

Each driver realises this contract in its own file:

| Driver | Spec | What it is |
|---|---|---|
| `local` | [backends/local.md](backends/local.md) | A directory on this machine, or a mounted network filesystem. |
| `s3` | [backends/s3.md](backends/s3.md) | AWS S3 and S3-compatible services. |
| `gcs` | [backends/gcs.md](backends/gcs.md) | Google Cloud Storage. |
| shared by `s3` and `gcs` | [backends/object-store-common.md](backends/object-store-common.md) | The object-store shell, the HTTP transport, and the bucket-side function. |
| `http-proxy` | [backends/http-proxy.md](backends/http-proxy.md) | Another tsync machine serving its stores. |

---

## 1. Purpose

Everything above this layer thinks in keys and bodies. This layer turns them into requests against a concrete service, and hides which service it is, how many stores a domain has, the health of each link, and upload pacing.

The contract is minimal and honest so that the domain logic (sync, GC, mirror, checkout) is written once against it, and so that the composite of several stores can itself be a store with the same contract.

Layering rule: a store knows how bytes are stored and found, never what the domain does with them. Domain knowledge enters only as injected functions (the chunk names a manifest body refers to, the keys a copy must skip) or through the shared key layout of [02-remote-model.md](02-remote-model.md).

---

## 2. Concepts

### 2.1 Keys and prefixes

- A **key** and a **prefix** follow the grammar of [01 §2.1](01-core.md#21-store-keys-and-prefixes): a key has no trailing `/`; a prefix is empty or a key followed by `/`, so it names whole segments (`tsync/d/chunks/ab/` is a prefix, `tsync/d/chunks/ab` is not).
- Every store operation MUST refuse an argument that is not a valid key or prefix, with kind INVALID, before it issues any request or touches any file.
- A listing MUST omit every stored name that is not a valid key. Readers SHOULD accept directory-marker objects (names ending in `/`, meaning nothing: they hold no tsync object) by omitting them; writers MUST NOT produce them, and their presence changes no answer.
- A store never interprets keys, with one exception every driver shares: the corruption-marker key derived from a chunk key ([02-remote-model.md](02-remote-model.md)), which decides whether a written object is a chunk to verify.

### 2.2 Entries

```
entry = { key: key; size: bytes; last_modified: wall-clock epoch seconds; etag: string? }
```

- `etag` is the store's own version name for the object. When a store has one it MUST report it, in listings and in `head_opt` alike, and it MUST change whenever the object's body changes.
- When a store has no etag, `(size, last_modified)` is the validator, and the store MUST report `last_modified` at the finest resolution it keeps.
- A caller that caches a body against an entry MUST use the etag when present: a body rewritten within the same second at the same length is invisible to `(size, last_modified)` on a store with whole-second times.

### 2.3 Capabilities

```
caps = { share_url: string?;       -- base URL of the share endpoint serving this store
         chunk_size: bytes?;       -- recommended chunk size for new files
         max_concurrency: int?;    -- object operations this store usefully serves at once
         verified: bool }          -- every chunk this store takes is checked against its name
```

`verified` is a claim that someone is looking, not that nothing was found. A store MUST NOT claim it unless the check is known to run. A store that checks files a corruption marker ([02 §2.13](02-remote-model.md#213-corruption-marker-verify-job-discard-job); lifecycle in [data-model/backend §2.15](data-model/backend.md#215-corruption-marker)) for each chunk whose bytes do not match its name or cannot be read. How each driver checks is in its own file.

### 2.4 Watch token

The value of a watched key, as a watch compares it: the object's body with leading and trailing whitespace removed. Tokens are compared only for equality.

---

## 3. The store contract

### 3.1 General rules

- **Outcomes.** Every operation either returns its result or fails with exactly one kind from [algorithms/failure-model.md](algorithms/failure-model.md), detected per its [§4](algorithms/failure-model.md#4-detection). The kind is decided by the driver, which has the evidence, and travels as data.
- **Kinds every operation may fail with.** INVALID (a malformed argument, detected before any request), REFUSED (denied, read-only, or a request the store will never accept), TRANSIENT/LINK, TRANSIENT/LOAD, TRANSIENT/LOCAL, STOPPING, CANCELLED and UNEXPLAINED. The composite may also fail with UNREACHABLE. An answer that contradicts what the store must return is CORRUPT. The table in §3.2 lists only what each operation adds.
- **"Could not look" is never "absent".** ABSENT, `none` and `false` are returned only on the store's considered answer.
- **Atomic visibility.** A reader sees an object whole or not at all, never a partial body.
- **Consistency.** After a mutation returns, every later read of that key, and every later listing of a prefix covering it, on the same store reflects it. A driver for a service without that guarantee MUST NOT be offered.
- **Bounded.** No operation waits forever: a remote request is bounded by its stall detector, and a filesystem call by the local stall bound (per driver). Retries follow the [retry ladder (01 §7)](01-core.md#7-retry-ladder); what each outcome tells the member's [health breaker (01 §8)](01-core.md#8-health-breaker) is [failure-model §6](algorithms/failure-model.md#6-link-health-evidence).
- **Bodies.** A body handed to a store MUST stay valid and unmodified until the operation returns, retries included. A body returned by a store is the caller's to read; it MAY be an immutable mapping of on-disk data (P6).
- **Idempotence.** Every operation is safe to repeat. A repeated `put` converges on the last body, a repeated delete of an absent key succeeds.

### 3.2 Operations

| Operation | Result | Absent key | Kinds added |
|---|---|---|---|
| `put(k, body)` | unit; `k` holds `body` (last writer wins) | created | — |
| `put_if_absent(k, body)` | `Won` or `Held(holder_body)` (§3.3) | created, `Won` | REFUSED when the store cannot evaluate the precondition |
| `get(k)` | body | fails ABSENT | — |
| `get_opt(k)` | body or `none` | `none` | — |
| `get_range(k, offset, length)` | bytes (§3.5) or `none` | `none` | INVALID if `length ≤ 0` or `offset < 0`; CORRUPT if the answer is longer than asked or not the asked range |
| `head_opt(k)` | entry or `none` | `none` | — |
| `delete(k)` | `true` if an object was removed, `false` if none was there (§3.4) | `false` | — |
| `delete_multi(keys)` | unit (§3.4) | success | the most doubtful kind among per-key refusals |
| `copy(src, dst)` | unit; `dst` holds `src`'s body as it was at some instant during the call, replacing any previous `dst` | fails ABSENT (the source) | — |
| `list_prefix(p, max_keys?)` | entries (§3.6) | empty list | CORRUPT for a listing that contradicts itself |
| `watch(k, last_seen)` | unit (§3.7) | returns like any other | — |
| `get_many`, `list_many` | optional (§3.8) | | |
| `verify_all(chunk_prefix)` | `Queued(n)` or `Unsupported` (§3.8) | | |
| `discard(chunk_prefix, run, name, keys)` | `Queued` or `Unsupported` (§3.8) | | |
| `capabilities(prefix)` | caps (§2.3) for the domain the prefix identifies | | |
| `fast_read` | whether reading a whole chunk costs about what a range does | | |
| `local_path` | a directory granting in-process code filesystem access to the store's tree, or none | | |
| `health` | the member's health cell ([01-core.md](01-core.md)) | | |

### 3.3 `put_if_absent`

- It is an atomic claim, used only for claim keys (folder identity, [data-model/backend.md](data-model/backend.md)). Content is either content-addressed or single-owner and uses `put`.
- The store MUST evaluate "only if no object has this name" itself, atomically with the write. A check followed by a write is not conforming.
- `Won` means the name now holds exactly `body`. `Held(b)` means another writer's body `b` holds the name, and this call changed nothing.
- If the holder's body is byte-identical to `body`, the store MUST answer `Won`. This covers an attempt whose success answer was lost, so that a later attempt found its own write: the name holds exactly what the caller asked, whoever wrote it.
- A conditional write the service reports as conflicting with another in-flight write, and as retryable, is TRANSIENT/LOAD and is retried with the precondition intact.
- If the holder vanishes between a refused write and the read of its body, the store MUST retry the claim, at most CLAIM_RETRIES times (recommended 3), before failing TRANSIENT/LOAD.
- A store that cannot evaluate the precondition MUST fail REFUSED, and MUST NOT write.
- A caller MUST NOT emulate a claim with `put`, and MUST NOT fall back to `put` when a claim fails, whatever the kind. A plain write over a claim key silently undoes the arbitration it exists for.

### 3.4 `delete` and `delete_multi`

`delete(k)`:

- `true` means an object was present when this call removed it. `false` means the store found no object under `k`.
- A store whose delete request does not say whether the object existed MUST learn it with a metadata read immediately before, and MUST NOT issue the delete when that read found nothing.
- `delete` is not an arbitration primitive. Two concurrent deletes of one key may both answer `true` on such a store. A caller that needs exclusive ownership of a removal uses a claim.

`delete_multi(keys)`:

- Accepts any number of keys. An empty list issues no request and succeeds.
- The driver splits the list into pages at the service's limit, sends them in order, and stops at the first page that fails. Pages already sent stay deleted. The caller repeats the whole call, which is idempotent.
- A key reported absent is a success.
- Any other per-key refusal inside an otherwise successful answer MUST fail the call. The failure names how many keys were refused and the first key and reason.
- Its kind is the most doubtful of the per-key reasons: TRANSIENT/LOAD for a service-side "try again" or internal error, REFUSED for a permission or invalid-key refusal. Per-key refusals inside an answered request are not link evidence.
- A caller MUST NOT treat any failure of `delete_multi` as done: until a later call succeeds, every key in the list may still be present.

### 3.5 `get_range`

- For an object of size `s`, it returns the bytes `[offset, min(offset + length, s))`.
- When `offset ≥ s` it returns an empty body, not `none` and not a failure.
- An answer longer than `length`, or one the service reports as starting elsewhere than `offset`, is CORRUPT: a store that ignored the range must be distinguishable from one that honoured it.
- A driver MUST check the answer against the range and total size the service reports, where the protocol reports them.
- `get_range` is mandatory, and not derived from `get`: the derived form would satisfy callers while fetching exactly what the range exists to avoid.

### 3.6 `list_prefix`

- It returns every valid key that starts with `p`, recursively and flat, with its entry, in ascending byte order of key.
- With `max_keys = n` it returns the first `n` such entries in that order. A driver SHOULD stop paging once it holds them, so that a bounded existence check costs one request.
- An empty list is a real answer: the store was asked and holds nothing under `p`.
- A failure on any page fails the whole listing. No partial listing is ever returned as a whole one.

### 3.7 `watch`

- It returns when `k` may have changed, or after at most WATCH_INTERVAL (recommended 2 s; a store caps writes to one name at about one per second, so polling faster only spends requests). A store that delivers change notifications MAY wait longer, up to its own documented bound.
- Returning early is allowed; returning late is not.
- If the value at call time already differs from `last_seen`, the store SHOULD return promptly.
- The caller always re-reads the key and compares tokens.
- A watch MAY fail with any kind a read may. The caller then waits at least WATCH_INTERVAL before watching again, so a watch that cannot fire slows a caller down without stopping it.

### 3.8 Optional operations

**`get_many(entries)`** (a native multi-read, declared or absent):

- Every requested key is answered exactly once, in request order, with its body or `none` for an absent key.
- The driver pages over its own limits.
- A per-key failure fails the call. A caller told "absent" would write a mirror missing the file.

**`list_many(prefixes)`** returns, for each folder asked, its full listing plus a body for each child object, in request order. The store MAY stop early or skip folders, and the caller asks those one by one.

**`verify_all(chunk_prefix)`** queues a server-side check of every chunk under the prefix. It answers `Queued(n)`, the number of units queued (not findings), or `Unsupported`.

**`discard(chunk_prefix, run, name, keys)`** hands unreferenced chunks to the store's server-side deleter:

- `Queued` means the request is durably stored before the call returns, and a consumer is known to be deployed on this store. It is never a detached promise.
- `Unsupported` means the caller deletes the chunks itself with `delete_multi`.
- A store MUST NOT answer `Queued` unless both conditions hold.
- A `Queued` request is consumed later, at-least-once, by a party this client does not see. Until it is consumed, the named chunks are still on the store.
- A collection never calls `discard` or `delete_multi` on a copy directly: its deletions on copies are jobs in the copies' durable job logs ([gc §5.7](algorithms/gc.md#57-deletion-on-copies), [replication §4.8](algorithms/replication.md#48-deletions-on-copies-outside-the-worker)).

### 3.9 Capabilities, `fast_read`, `local_path`, `health`

- `capabilities` of a single store never fails for want of an opinion: an unknown field is `none`, and `verified` is `false`.
- A caller MUST NOT memoise a failed or partial answer. A caller that needs a value to proceed uses its own default, and asks again later.
- `fast_read` is `true` only where reading more than asked costs about what the range does (a filesystem).
- `local_path` is granted only by a store whose objects are files under one directory on this machine. The grant is to in-process code (collection by rename, disk-space reports), and anything done through it MUST keep §3.1's visibility and consistency rules.
- `health` is the member's [breaker cell (01 §8)](01-core.md#8-health-breaker). Every store has one, including a filesystem store, whose cell hears only link-kind failures (a network filesystem that stopped answering).

### 3.10 Caller obligations

- Pass only valid keys and prefixes (§2.1).
- Keep request bodies valid until the operation returns (§3.1).
- Never emulate `put_if_absent`, and never fall back from it (§3.3).
- Never read "absent" into a failure, and never read "done" into a failed `delete_multi`.
- Re-read after a watch returns. Never assume a change happened.
- Treat `Queued` from `discard` as "not yet deleted" until consumption is observed.

---

## 4. The composite interface

A domain's composite is a store with exactly the contract of §3. Callers never learn how many members there are or which answered. Its policy is [algorithms/replication.md](algorithms/replication.md).

Beside the composite, a domain exposes its **member list**, one record per configured backend in read order:

```
member = { name; role: main | replica | backfill | read-only;
           readable: bool;                 -- false for a backfill: reads never reach it, and share links never point into it
           backend_type: local | s3 | gcs | http-proxy;
           config: fields, secrets masked;
           store;                          -- the leaf store, for operations that name a member
           copy_stats?: { owed; parked; degraded };               -- replicas and backfills
           traffic?: { uploaded; downloaded };                    -- stores with a link
           local_path?; link? }
```

Looking a member up by name fails when the name is unknown, listing the configured names. Each copy's durable job log is [replication §3.3](algorithms/replication.md#33-durable-local-state-per-domain-and-copy).

---

## 5. Process-wide services

- **Batched reads.** There is one way to read many keys: if the store declares `get_many`, the entries are sent in requests of at most MAX_BATCH_KEYS keys (recommended 256) and MAX_BATCH_BYTES of listed sizes (recommended 8 MiB); an entry larger than the byte budget goes alone. Otherwise each key is read with `get_opt`. A batch that fails permanently is answered key by key; a transient batch failure is raised.
- **Batch sizes on the peer wire.** MAX_BATCH_FOLDERS (recommended 64) and MAX_BATCH_BYTES bound a `list_many` answer; both ends of the http-proxy wire use the same values ([backends/http-proxy](backends/http-proxy.md)).
- **Drain hooks.** Background work registers a settle hook, and a process that is about to exit runs the hooks in parallel under a bound ([algorithms/replication.md](algorithms/replication.md) settling).
- **Driver registry.** Drivers register a type name, a field specification (name, label, type, default, whether secret) and a constructor. The registry lists the available types, and a build without a driver simply lacks that type. Constructing an unknown type fails, naming the type. Building a store reaches no network and touches no file.

The registry and the drain hooks are one per process.

---

## 6. The admission seam

Uploads over a network link are paced by the uplink governor. The seam between a store and the governor is an **admission**, a value handed to each store at construction:

```
admission = { acquire(bytes)      -- suspends until the bytes may be sent, or fails STOPPING
              try_acquire(bytes)  -- takes admission now if the budget allows, else refuses; never waits
              completed(bytes, elapsed)
              abandoned(bytes)
              waiting() }
```

Rules:

- Every store with a link gets its link's admission. A store without a link (a filesystem store) gets none, and is neither gated nor counted.
- **Per attempt.** Every request attempt that carries a body upstream MUST be admitted before it is sent, for its body size plus the governor's per-request overhead ([algorithms/uplink-governor.md](algorithms/uplink-governor.md)). This includes retries, the upload half of an emulated copy, job objects, markers and claims. It then reports exactly once: `completed` with the time from admission to answer, or `abandoned`.
- **Modes.** A write is issued in one of two modes. `wait` acquires. `best_effort` uses `try_acquire` for every attempt, and when admission is refused the operation fails CANCELLED ("not admitted") without sending. Best-effort writes are for work that another mechanism redoes, such as chunk forwards to copies.
- **Atomicity.** `try_acquire` takes the admission in the same step as it checks it. There is no separate check that a later acquire has to honour.
- **Reads are never gated.** A user is waiting on them.
- **Stall timeouts.** A remote driver's stall timeout MUST be at least the governor's STALL_TIMEOUT: the in-flight window is sized so that a body queued behind a full window still crosses within it.
- **Traffic counters.** Each store with a link counts body bytes of every attempt in each direction, per store and per process. A claim that returns `Held` counts the holder's body read back as download. Counting happens at the store, not in the content layer, because GC, mirror and repair talk to stores directly.

---

## 7. Uplink configuration

Configuration of the governor, read once per process before the first store is built:

- A top-level `uplink` object, and a `links` object mapping a link name to overrides. Overrides apply field by field over `uplink`.
- Fields: `enabled` (bool, default true), `headroom` (in (0, 1], default 0.8), `targetDelayMs` (≥ 5, default 50), `minRate` (a size per second, > 0, default 64 KiB/s), `maxRate` (a size per second, default none).
- `maxRate < minRate` MUST be refused. A `links` name that no backend uses MUST be refused.
- Each backend with a network path has a `link` field naming its link, default `"wan"`. The field MUST be refused on a `local` backend.
- A per-store ceiling is expressed by giving the store a link of its own and capping that link.

The meaning of each setting is in [algorithms/uplink-governor.md](algorithms/uplink-governor.md).

---

## 8. Concurrency requirements

An implementation MUST make each of these one atomic step with respect to every other task that touches the same state, by construction or by a lock:

1. Admission check-then-take (§6) and every mutation of a link's budget, line, law and lessee table.
2. The health cell's check that hands the single probe to one caller, and its failure-counter updates.
3. A copy's presence memo and its known-shard set ([algorithms/replication.md](algorithms/replication.md)).
4. The process-wide registry and drain hooks.

---

## 9. Design choices (do not undo)

1. **Minimal verbs, declared optional capabilities.** A store without a native batch says so, and the generic fan-out is written once, so no driver picks a concurrency width without seeing the process.
2. **`get_range` is mandatory and checked.** Over-long answers are errors, not trimmed.
3. **Per-key bulk-delete refusals fail the call.** Discarding them made GC report success while keys stayed on a copy that nothing walks again.
4. **Claims are real preconditions, never emulated and never abandoned for a plain write.**
5. **"Could not look" is never "not there".**
6. **Admission per attempt, at the store.** Retries, copies and job objects cross the same link as first attempts. Counting in the content layer missed GC, mirror and repair.
7. **Capabilities are evidence.** A store claims `verified` or `Queued` only when it knows the checker or the consumer is there.
8. **Listings are one store's view and are never merged** ([algorithms/replication.md](algorithms/replication.md)).

---

## 10. Conformance

A conforming store, run against a real service where it has one:

- Round-trips put, get, `get_opt`, `head_opt` (exact size), copy and listing. Absent keys read `none`, and `get` of one fails ABSENT.
- Returns chunk-sized bodies byte-identical.
- Answers `get_range` with exact slices at the start, middle and end of an object; the tail only for a range reaching past the end; an empty body for an offset at or past the end; and `none` for an absent key. An over-long answer from the service is refused as CORRUPT.
- Five concurrent claims of one name leave one stored body, and every claimant is told that body; exactly one is told `Won`. A later claim answers `Held` with the holder, unchanged. A free name answers `Won` and stores the body.
- `delete` answers `true`, then `false`.
- `delete_multi` over more keys than one page, mostly absent, with survivors at the front, on the page boundary and past it, removes every survivor. An injected per-key refusal fails the call.
- Keys holding `& < > " ' + % # ? space` and non-ASCII characters round-trip through put, get, listing and `delete_multi`. Invalid keys (`..`, `.`, empty segments, a leading or trailing `/`) are refused INVALID before any request, and never reach a file or the network.
- `list_prefix` answers in ascending key order, honours `max_keys` exactly, answers a listing longer than one page whole, and omits names that are not valid keys.
- `get_many`, where declared, answers every key once in request order, across pages.
- `capabilities.verified`, `verify_all` and `discard` answer as the store's checker actually runs: `verify_all` queues one unit per shard; a `discard` request carries exactly its keys; a deployed consumer deletes the named chunk.
- Classification: a TRANSIENT failure is retried to the ladder's limit; a REFUSED one is attempted once; a health cell trips after link failures, recovers after one answer, and is kept up by a considered "no".
- Every upload attempt, retries included, passes admission once and reports once; a best-effort write refused admission sends nothing.
- Traffic: only bytes crossing a link count, and a filesystem store counts nothing; a lost claim counts the upload plus the holder's body read back; a put through a composite with two mains counts on both; counters are per store and summed per process.
- Batches: request key and byte caps hold; a permanently failed batch is answered key by key; a transient batch failure is raised.
- HTTP: sequential requests reuse one kept-alive connection; a slow but flowing answer survives, silence past the stall timeout fails TRANSIENT/LINK.

Driver-specific conformance is in each driver's file.

---

OCaml implementation notes: [ocaml/06-backends.md](ocaml/06-backends.md).
