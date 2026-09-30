# 01 — Foundation: names, content keys, time, resources, runtime, shared mechanisms

This file is normative. It owns:

- the grammar of every name and key, and their validation (principle P4, grammar half);
- content hashing, fixed-size chunking and chunk keys;
- the mapping from logical keys to stored keys, and item references;
- the time rules (P5) and the resource rule (P6);
- the requirements on the runtime every concurrent part is written against;
- the retry ladder, the health breaker, the HTTP request discipline and IPC framing.

It does not own, and only links to: the failure kinds and their propagation
([failure-model](algorithms/failure-model.md)), the durable queue and every persistence rule
([durable-queue](algorithms/durable-queue.md)), the backend key layout and object bodies
([02](02-remote-model.md)), the IPC contract — envelope, error codes, actions
([07](07-daemon-cli.md)), socket locations, change notices and advisory sends
([07](07-daemon-cli.md)), and where each trust boundary enforces validation
([security-model](algorithms/security-model.md)). Notes on the OCaml implementation are in
[ocaml/01-core.md](ocaml/01-core.md).

Terms follow the [glossary](README.md#3-glossary). Parameters are written `NAME` and collected
in §15 with recommended values; where safety depends on a range, the range is a MUST.

---

## 1. Why a foundation layer

Several independent programs — daemons, frontends, one-shot commands, an embedded app, a
bucket verifier in another language — read and write the same stores. They agree only if they
compute every name identically, across languages and releases. Names are therefore persistent
formats, and each is defined once, here. The same programs share a small set of mechanisms
(retry, breaker, framing) whose semantics must not drift between callers; those
are defined here too, against an abstract runtime (§6) so no rule depends on a scheduler.

---

## 2. Names and keys (P4)

All names are byte strings. Comparison is byte-wise and case-sensitive unless a rule says
otherwise.

### 2.1 Store keys and prefixes

A **key** names one object in a store. A **prefix** names a set of keys (a listing argument).

```
key      = segment *( "/" segment )
prefix   = key "/"
segment  = 1*byte  except  "/" and NUL,  and not exactly "." or ".."
```

- A key MUST NOT be empty, MUST NOT start with `/`, MUST NOT end with `/`, MUST NOT contain an
  empty segment (`//`), a `.` or `..` segment, or a NUL byte.
- A prefix is a key followed by exactly one `/`. No object key ends with `/`, and no store
  writes or lists a directory-marker key.
- Every component that accepts a key or prefix from outside the process (a peer request, a
  listing returned by a store, a job object read from a store, a config value, an IPC request)
  MUST validate it against this grammar before using it, and refuse it as INVALID
  ([failure-model §3](algorithms/failure-model.md#3-the-classification)) otherwise. A listing entry
  is validated as a key, or as a prefix where a listing by delimiter returns one; an entry that
  fails validation is skipped with a warning and never mapped to a path.
- A store that maps keys to a filesystem MUST follow no symbolic link at or below its root: every
  component of a key's path is opened without following links, and a link found there is
  refused (enforcement: [security-model](algorithms/security-model.md)).
- Every key existing writers have produced satisfies this grammar, so validation rejects no
  existing object.

### 2.2 Domain names

```
domain-name = 1*255 byte  except  "/", NUL, bytes 0x01–0x1F and 0x7F
              and not "." or "..", not beginning with ".tsync-"
              and not a reserved root name
reserved    = "shares" | "corrupted" | "verify-jobs" | "gc-jobs"
```

- A domain name is a key segment: it appears as `tsync/<domain>/…` and as a sibling of the
  reserved roots `tsync/shares/`, `tsync/corrupted/`, `tsync/verify-jobs/`, `tsync/gc-jobs/`
  ([02](02-remote-model.md)). A domain carrying a reserved name would read and write another
  subsystem's objects; one containing `/` or `..` would escape its prefix.
- A reserved name is refused byte for byte everywhere. If any of the domain's stores is a
  local-filesystem store, a name equal to a reserved name ignoring ASCII case is refused too,
  because such a store may sit on a case-insensitive filesystem that files `Shares` and
  `shares` in one directory. (Object stores are case-sensitive, so a domain named `Shares` on
  one remains valid.)
- The config validator ([05](05-ops-config.md)) MUST refuse a domain whose name violates this
  grammar. Uniqueness of domain names (ignoring case) is a configuration rule owned by
  [05](05-ops-config.md). Every component that receives a domain name from outside (a peer
  request, an IPC request, a job object, a GC job key) MUST validate it against the grammar.
- Inner spaces and any other byte are allowed (`Family Photos` is a valid name). A domain
  literally named `chunks` or `tsync` is valid.

### 2.3 Leaf names and logical paths

```
leaf  = 1*byte  except  "/" and NUL,  and not exactly "." or ".."
path  = "" | leaf *( "/" leaf )          ; "" is the domain root
```

- A leaf is the user's name for one file or folder. Any byte string satisfying `leaf` is valid,
  including names beginning with `.tsync-`, names longer than a local filesystem allows, and
  names with characters some filesystems refuse: the store files children by a hash of the
  leaf (§2.6), and a local mirror escapes what it cannot hold (§2.8).
- Readers MUST accept any leaf that existing writers stored; all of them satisfy this grammar.
- A path accepted from a user (CLI argument, import source walk) MAY carry one leading and one
  trailing `/`, which are removed; after that it MUST satisfy `path` or be refused as INVALID.

### 2.4 Logical keys

A **logical key** is `(domain, path, kind)` with `kind ∈ {file, folder}`.

- Its string spelling is `<domain prefix><path>` where the domain prefix is
  `tsync/<domain>/manifests/`. The root is `(domain, "", folder)`, spelled
  `tsync/<domain>/manifests/`. The spelling carries no kind.
- Equality includes the kind: a file and a folder with the same path are different keys.
- `leaf(k)` is the last segment of the path, `""` for the root. `parent(k)` is the key of the
  path minus its last segment, always of kind folder; the parent of the root is the root.
- Descending from a file key is an error.
- Parsing a string back into a logical key succeeds only if it starts with this domain's
  prefix and the remainder satisfies `path` (readers SHOULD accept one trailing `/` after it,
  meaning the same key; writers MUST NOT produce it); the
  kind MUST come from the caller or from local state, never be guessed from the string.

Example: file `photos/trip/img.jpg` in domain `home` is spelled
`tsync/home/manifests/photos/trip/img.jpg`, leaf `img.jpg`, parent folder `photos/trip`.

### 2.5 Folder ids

A **folder id** names one folder for its whole life, across renames and moves.

```
folder-id  = root-id | trash-id | hex-id
root-id    = ".tsync-root"
trash-id   = ".tsync-trash"
hex-id     = 1*hexlower [ "-" 1*hexlower ]
hexlower   = "0"–"9" | "a"–"f"
```

- Writers MUST mint ids of the form `<12 hex> "-" <counter>`: the first 12 hex characters of
  this client's uuid, `-`, and a counter in lowercase hex that is unique for that client. Client identity, counter
  leases and minting are owned by [03 §2.1](03-journal-sync.md#21-client-identity-and-folder-id-leases-local); arbitration between clients
  that claim ids is owned by [data-model/backend.md §6](data-model/backend.md#6-folder-identity-arbitration).
- Readers SHOULD accept any other `hex-id` (for example 16 or 32 hex digits with no counter)
  as a folder id with the same meaning; writers MUST NOT mint one.
- Anything else read where a folder id is expected is INVALID (from a request) or CORRUPT (from
  a store object).

### 2.6 Stored keys: the logical-to-stored mapping

A **stored key** is where the store files an item. Stored keys are built only by the mapping
functions below, or taken from a store's own listing after validation (§2.1). There is no other
way to obtain one: a free string is never a stored key.

The **inode model**: a folder's children are filed under the folder's id, each at a hash of its
leaf, so renaming or moving a folder rewrites one object and nothing under it.

```
name-hash(leaf)                 = hex16(XXH3(leaf, 0)) "-" hex16(XXH3(leaf, 1))     (§3.1)
namespace(prefix, id)           = prefix id "/"
child-key(prefix, id, leaf)     = prefix id "/" name-hash(leaf)
reserved-key(prefix, id, name)  = prefix id "/" name     for name ∈ reserved leaves
```

- `manifest-key(k) = child-key(domain prefix, folder-id(parent(k)), leaf(k))`. A folder's
  marker lives at the same key as a file of the same name would; the two cannot coexist in one
  parent.
- **Reserved leaves.** Every name a store keeps for itself begins with the sentinel `.tsync-`.
  No user leaf reaches a store key unhashed, so no user name can collide with one. The reserved
  leaves under a folder namespace (`.tsync-parent`, `.tsync-index`), the trash namespace
  (`.tsync-trash/`), the full key layout and the bodies filed at each key are specified in
  [02](02-remote-model.md).
- A stored key's parent folder id is its second-to-last segment; a namespace's folder id is its
  last non-empty segment.

Example: `img.jpg` in a folder with id `3f2a9c1b7d4e-1a` is filed at
`<prefix>3f2a9c1b7d4e-1a/066843ea47b80079-e0e3d2bb9b72c14d`.

### 2.7 Item references

An **item reference** is how a non-kernel client names an item to the domain owner. It is
never a path for a folder, so it survives renames of any ancestor.

```
item-ref = "root"
         | "d:" folder-id                       ; a folder
         | "f:" folder-id "/" leaf              ; a file: its parent's id and its leaf
```

- Parsing is total: every string yields either a reference or "malformed".
- `d:.tsync-root` denotes the root and MUST be normalised to `root`.
- For `f:`, the first `/` separates the id from the leaf. The id MUST satisfy `folder-id`, and
  the leaf MUST satisfy `leaf` (so it contains no `/`); a leaf MAY contain `:`.
- Anything else — an empty id or leaf, a bare `d:` or `f:`, an id or leaf violating its
  grammar, a store key — is **malformed**. A malformed reference is INVALID; it is never
  answered as ABSENT. A well-formed reference that resolves to nothing is ABSENT.
- A reference names a kind: an `f:` reference MUST NOT resolve to a folder, and a `d:`
  reference MUST NOT resolve to a file.
- Formatting a parsed reference MUST reproduce the canonical string (`root`, `d:<id>`,
  `f:<id>/<leaf>`).
- Resolving a reference MUST NOT mint a folder id or write anything: a resolution that minted
  would publish a marker and could resurrect a deleted folder.

Rationale: a directory rename changes every descendant's path, and references reach system
logs, so no user path appears in one unless the caller named it.

### 2.8 Mirror escaping (local names for real paths)

A local mirror files each item by its real path. A component is **storable** as itself iff it
is at most `NAME_MAX_LOCAL` bytes, does not begin with `.tsync-`, and contains none of
`" * : < > ? \ |` and no byte below 0x20. Otherwise it is filed as
`.tsync-esc-` followed by `hex16(XXH3(leaf, 0))`.

- Characters illegal on FAT, exFAT or NTFS are escaped even where the local filesystem would
  accept them, so a mirror can be copied to such a volume.
- The real name is recovered from the file's manifest (files) or from a `.tsync-name` record
  beside the escaped directory (folders); the layout of those records is owned by
  [04](04-checkout-cache.md).
- The escape handle is a 64-bit hash, so two distinct unstorable leaves in one folder can map
  to one handle. A writer that finds the handle already taken by a different real name MUST
  refuse the second item locally as EXISTS rather than overwrite the first; the conflict policy
  ([conflict-resolution](algorithms/conflict-resolution.md)) then files it under a conflicted
  name.

### 2.9 Temporary and reserved local names

- A **temporary file** lives in the directory of its target. A name is a temporary iff it has
  **both** the prefix `.tsync-tmp-` and the suffix `.tmp`; whatever lies between is the
  writer's choice. A suffix test alone MUST NOT be used: it once deleted a user's
  `.syncthing.*.tmp` files, forever.
- Writers MUST name temporaries `.tsync-tmp-<pid>-<seq>.tmp` (`pid` in decimal, `seq` unique
  within the process), except a local-filesystem store, which MUST use
  `.tsync-tmp-<random>.tmp` with lowercase random hex from §2.10
  ([backends/local](backends/local.md)). Readers, listings, sweepers and watchers SHOULD
  recognise any other middle (such as `scratch`) as a temporary too; writers MUST NOT produce
  one.
- A sweeper MAY remove a temporary whose middle is `<pid>-<seq>` only if `pid` names no live
  process, and any other temporary only once it is older than its owner's age rule. Readers and
  listings MUST hide temporary files, and a directory watcher MUST ignore them (§14).

### 2.10 Random identifiers

- Tokens that grant access or identify a client (share tokens, the client uuid) MUST be drawn
  from the operating system's cryptographically secure generator. If it is unavailable the
  operation MUST fail; there is no fallback.
- Short random ids (staged-body names, trash entries) MUST be drawn from a generator seeded
  from the operating system's secure generator, and MUST NOT repeat across processes: a
  process created by `fork` MUST reseed before drawing (forked frontends once drew identical
  ids).
- The client uuid is 16 random bytes in lowercase hex (32 characters).

---

## 3. Content: hashing, chunking and chunk keys

### 3.1 The hash

- Algorithm: **XXH3-64** (xxHash 0.8, `XXH3_64bits_withSeed`) with seeds **0** and **1**.
- `hex16(h)` is the 64-bit result in lowercase hexadecimal, zero-padded to 16 characters.
- Streaming and one-shot hashing MUST give the same result for every input length.

Known answers, which every implementation MUST reproduce:

| input | seed 0 | seed 1 |
|---|---|---|
| `""` | `2d06800538d394c2` | `4dc5b0cc826f6703` |
| `"hello world"` | `d447b1ea40e6988b` | `b7aeb52a10fdaf2d` |
| 8 388 608 bytes, byte i = (31·i + 7) mod 256 | `29a6314906cb27cd` | `314dbe6e90136337` |

Conformance vectors additionally cover lengths 0, 1, 16, 17, 128, 129, 240, 241, 2600,
1 MiB, 1 MiB + 1 and 8 MiB, which straddle the algorithm's internal branch boundaries.

### 3.2 Chunk keys

```
chunk-key(body) = hex16(XXH3(body, 0)) "-" hex16(XXH3(body, 1))      ; 33 characters
```

- A string is a chunk key iff it is exactly 33 bytes, byte 16 is `-`, and the other 32 bytes are
  lowercase hex. Uppercase is not a chunk key. This test decides whether a listed object is a
  chunk, so it tests what a key *is*, not what it resembles. A manifest's stored key has the
  same shape; membership in the chunk space is therefore decided by prefix
  ([02](02-remote-model.md)), never by leaf shape.
- Example: the chunk key of `"hello world"` is `d447b1ea40e6988b-b7aeb52a10fdaf2d`.
- **Threat model.** The chunk key is 128 bits of a non-cryptographic hash. It detects accidental
  damage (bit rot, truncation, a store answering for the wrong key) and gives deduplication
  among cooperating clients. It does not resist an adversary who can write to the store: such
  an adversary can craft colliding bodies. Stores are assumed to be written only by the user's
  own clients ([security-model](algorithms/security-model.md)). The algorithm is frozen: every
  existing chunk is filed under it.
- A reader that verifies a chunk (every reader that obtained the bytes from a store or a peer,
  per [read-path-and-cache](algorithms/read-path-and-cache.md)) recomputes the key and treats a
  mismatch as CORRUPT.

### 3.3 Other digests with the same construction

Each is `hex16(XXH3(x, 0)) "-" hex16(XXH3(x, 1))` over the stated input:

| digest | input |
|---|---|
| leaf name hash (§2.6) | the leaf |
| whole-file digest in a manifest | concatenation over chunks of `"<chunk-key>-<length>;"` |
| symlink digest | the target string |

The mirror escape handle (§2.8) uses seed 0 only. Local cache names derived from digests are
owned by [04](04-checkout-cache.md).

### 3.4 Fixed-size chunking

A file of `size` bytes with chunk size `cs > 0` is cut at multiples of `cs`. Every chunk is `cs`
bytes except the last:

```
count(size, cs)       = 0                     if size ≤ 0
                      = ⌈size / cs⌉            otherwise
offset(cs, i)         = i · cs
length(size, cs, i)   = max(0, min(cs, size − i·cs))
index(cs, pos)        = ⌊pos / cs⌋
```

- An empty file has no chunks.
- Deduplication is by chunk key equality only. Two clients cutting the same bytes at the same
  chunk size produce the same keys; different chunk sizes do not deduplicate.
- **Range to pieces.** A byte range `[offset, offset + len)` of a file with `count` chunks maps
  to the ordered list of `(index, offset inside chunk, length, offset inside the caller's
  buffer)` that covers the range exactly once, clipped at the end of chunk `count − 1`. The list
  is empty if `cs ≤ 0`, `len ≤ 0` or `offset < 0`. A range past the end is short, not an error.
  Examples with `cs = 8`: `[6,10)`, count 3 → `#0[6,8)@0, #1[0,2)@2`; `[12,28)`, count 2 →
  `#1[4,8)@0`; `[16,24)`, count 2 → empty.

### 3.5 Chunk size

- The chunk size is recorded per file in its manifest and never changes for that file version.
- A writer choosing the chunk size of a new file MUST use, in order: the domain's configured
  chunk size ([05](05-ops-config.md)); else the main store's recommended chunk size (an
  http-proxy peer answers with the serving domain's); else `DEFAULT_CHUNK_SIZE`. The chosen
  value MUST lie in `[CHUNK_SIZE_MIN, CHUNK_SIZE_MAX]`; a store recommendation outside it is
  ignored with a warning, and a configured value outside it is refused by the validator. Every
  other client must be able to read what a writer chooses, so the range is part of the format.
- A reader MUST accept any chunk size in `[1, CHUNK_SIZE_READ_MAX]` found in an existing
  manifest, and treat a larger or non-positive one as CORRUPT.
- A symlink manifest records `DEFAULT_CHUNK_SIZE` and no chunks.

### 3.6 Chunk shards

- A chunk is filed under the shard named by the first 3 characters of its key
  (`SHARD_FANOUT` = 3 hex characters, 4096 shards, named `000`–`fff`); a key shorter than 3
  characters is filed under shard `_`. The relative path of a chunk is `<shard>/<key>`.
- The same function names chunks in the local chunk cache.
- The full set of keys built on it (chunk space, collection space, corruption markers, job
  requests) is owned by [02](02-remote-model.md).

---

## 4. Time (P5)

Two clocks exist. The **monotonic clock** never steps and has an arbitrary origin. The **wall
clock** can step by any amount in either direction (NTP corrections; a fake hardware clock on
boards without a real-time clock sets it far off at boot), and peers' wall clocks disagree.

- Every **duration measured inside a process** MUST use the monotonic clock: timeouts, stall
  detection, deadlines, retry and queue backoff, breaker trip spans and holds, probe cadence,
  lease expiry on the holder's side, watchdogs, rate windows, throughput and ETA estimates, and
  debounce intervals.
- The **wall clock** is used only for a time that is **persisted** or **compared with another
  host**: journal entry timestamps and retention horizons, request-signature windows, GC run
  names, version and trash timestamps, pin expiry, temp-file and orphan ages derived from file
  times, credential expiry claims, and human-readable timestamps in logs and status.
- Every wall-clock comparison MUST tolerate a step: the result of a step is at most an early or
  late expiry, never a loss of data. Rules that compare wall times across hosts state their
  tolerance where they are owned.
- A monotonic reading MUST NOT be persisted and MUST NOT be sent to another host. It MAY be
  exchanged between processes on one host only if the clock is system-wide.
- A timer MUST fire at its deadline without polling; a watchdog re-arms to the exact next
  deadline.
- A clock that includes time spent suspended MAY be used as the monotonic clock, provided it
  never steps.

Rationale: a wall-clock breaker trips at boot when fake-hwclock jumps forward, and a backward
NTP step extends a hold and delays stall detection by the size of the step.

---

## 5. Resources and immutable data (P6)

- **Resource strategy is not specified.** Internal concurrency widths, pool sizes, fan-out
  bounds, and memory strategies (streaming or materialising, spilling to disk, off-heap
  structures) are implementation choices. This specification states only limits another party
  can observe: wire limits, request size and time limits at trust boundaries, retention
  horizons and deadlines. Each is a named parameter in the file that owns it.
- **Immutable data may be shared.** Data that is never modified in place — objects only ever
  replaced by rename (store objects on a filesystem store, whole cache bodies, mirror entries)
  and content-addressed data — MAY be passed around as an immutable memory mapping, and SHOULD
  be; no rule in this specification forbids it. A local-filesystem store SHOULD read objects by
  mapping them; positioned reads are equally allowed.
- **Data written in place** (staged bodies, partial cache bodies) MAY be mapped only under the
  rules of [04](04-checkout-cache.md) and
  [read-path-and-cache](algorithms/read-path-and-cache.md). Files outside tsync's control that
  others change in place (a user's source files during an import) follow §12.

---

## 6. Runtime requirements

Every concurrent part of tsync is written against the capabilities below and relies only on
the guarantees in §6.2. Any runtime — a multi-threaded async runtime, an event loop with a
blocking-I/O thread pool, effects-based fibers — satisfies the spec if it provides them.

### 6.1 Capabilities

| Group | Capability | Contract |
|---|---|---|
| R1 tasks | spawn detached | MUST NOT fail; a detached body catches everything, and an escaping failure is a fatal bug |
| | join all / map concurrently | results keep input order |
| | catch, finally | `finally` runs on success, failure and cancellation, then re-raises |
| | one-shot promise and resolver | resolving never runs the waiter re-entrantly inside the resolver; resolving twice is a bug and callers guard against it |
| R2 time | monotonic now | §4 |
| | sleep | cancellable |
| | with timeout | fails with a recognisable timeout and cancels the work |
| | with stall timeout | fails like a timeout once the window passes with no progress signal; fires at the exact deadline |
| | race | the first to finish wins; the others are cancelled |
| | is cancelled | distinguishes "the caller withdrew" from a failure of the work |
| R3 coordination | mutex | FIFO; released however the holder ends |
| | condition | carries no value; a woken waiter re-reads its state; a signal with no waiter is lost, so waiters re-check before waiting |
| R4 bounded concurrency | counting semaphore | FIFO hand-off; a slot is released however its holder ends |
| R5 file I/O | POSIX calls; positioned read/write into off-heap buffers; block reservation | EINTR retried inside (§6.3); positioned calls carry their offset so many ranges of one file move through one descriptor; "reservation unsupported" is distinct, and the caller falls back to setting the size |
| R6 sockets | Unix stream sockets (§11); pooled HTTP/1.1 connections (§10) | |
| R7 readiness | wait until an OS descriptor is readable | used by directory watch (§14) |
| R8 stop | process-wide stop flag, hooks, stop-aware sleep (§9) | every runtime binding wires stop into in-flight waits |

### 6.2 Guarantees the logic requires

- **Atomic check-then-act.** Every check-then-act on shared in-memory state (pool counters,
  waiter queues, queue slot tables, breaker cells, memo tables, counters, subscriber queues,
  "replace only if still the one that failed" swaps) MUST be atomic with respect to every
  other task. An implementation achieves this either by **confinement** — the state is touched
  by one executor that cannot switch tasks between the check and the act — or by a lock or an
  atomic operation. A runtime that can switch tasks at any call, or run tasks in parallel,
  MUST use locks or atomics for every such section.
- **Suspension points.** Code relying on confinement MUST keep its critical sections free of any
  call that can suspend.
- **Ordering.** Mutexes and pool hand-offs are FIFO. Concurrent maps keep input order.
  Broadcast wakes every waiter.
- **Cancellation.** A cancelled task receives a distinguishable cancellation at its current
  wait; `finally` handlers run (slots released, descriptors closed, watchers removed). Retry
  loops never retry a cancellation.
- **Stop is not cancellation.** A stop is an explicit STOPPING failure raised by stop-aware
  waits and checks; running work may finish or give way at its next stop-aware wait (§9).
- **Blocking I/O.** A call that can block on disk or on another process MUST NOT stall
  unrelated tasks longer than the call itself; if the runtime has one executor, such calls are
  offloaded. Code around an offloaded call keeps the atomicity it relied on.
- **Locks across external waits.** A lock guarding local state MUST NOT be held across a store
  request, a peer request or an IPC wait. Work that needs remote data reads it first, then
  takes the lock to decide and write locally.
- **Process-wide registries** (named pools, queue registries, driver registries, stop hooks)
  exist once per process.

### 6.3 Interrupted system calls

Signal handlers may be installed without automatic restart, so any blocking system call can
fail with EINTR. Every file and directory call, in every helper, MUST retry on EINTR, and an
EINTR MUST never be interpreted as an answer. In particular, "does this path exist" is: the
stat succeeds → yes; it fails with ENOENT or ENOTDIR → no; EINTR → retry; any other error →
a failure classified per [failure-model §4.1](algorithms/failure-model.md#41-local-filesystem-errors),
never "no". (An existence check that answered "no" on EINTR once re-minted a client uuid over
the live one.)

### 6.4 Local filesystem helpers

- **Absent versus failed.** A helper that reads, stats, lists or opens a local path MUST report
  ABSENT only for ENOENT or ENOTDIR, and MUST surface every other error as a classified failure
  ([failure-model §4.1](algorithms/failure-model.md#41-local-filesystem-errors)). A helper that
  answers "absent", "empty", "no entries" or "missing" on an arbitrary error MUST NOT exist,
  except for best-effort cleanup (unlinking a temporary, pruning an empty directory) whose
  result no caller uses as an answer.
- **Atomic replacement.** Replacing a file writes a temporary in the same directory (§2.9),
  then renames it over the target; on failure the temporary is removed and the failure
  re-raised. Readers never see a partial body. When the file is state the system relies on for
  recovery, the persistence rules of [durable-queue](algorithms/durable-queue.md) apply.
- **Positioned writes of a known size.** The temporary is first sized to the final length (a
  full disk fails before any byte is written); ranges are then written in any order, each byte
  exactly once, and the rename follows the last write.
- **Short writes.** A write that makes no progress is a failure, never a silent truncation.
- **Tree removal** never follows symbolic links.
- **Reservation**: size 0 is a no-op; otherwise reserve blocks (Linux `fallocate`, macOS
  preallocation) and fall back to setting the size when the filesystem cannot reserve.
- **Disk space** reports available, free and total bytes; a failure to query is reported as
  unknown, never as zero or full.

---

## 7. Retry ladder

The ladder retries one request against one member. Which failures are retryable is decided by
the failure's kind ([failure-model §3](algorithms/failure-model.md#3-the-classification)); the
ladder never inspects message text.

```
attempt n = 1, 2, …, LADDER_ATTEMPTS:
  run the request
  success                          → report "answered" to the breaker; return the value
  STOPPING, CANCELLED, cancellation→ re-raise at once; nothing is reported or counted
  a considered answer              → report "answered"; return the failure (1 attempt)
     (ABSENT, EXISTS, REFUSED, CORRUPT are returned as failures or values per the driver)
  TRANSIENT/LINK                   → report "lost" to the breaker; retry
  TRANSIENT/LOAD                   → report "answered" (the link is up); retry
  TRANSIENT/LOCAL, UNEXPLAINED     → report nothing; retry
  retry:
    delay = min(LADDER_CAP, LADDER_BASE · 2^min(10, n−1)) · U[0.5, 1.5)
    if the answer carried a retry-after hint: delay = max(delay, min(hint, LADDER_CAP))
    if n = LADDER_ATTEMPTS, or delay exceeds the caller's remaining deadline → give up
    sleep(delay) stop-aware; a stop during the sleep raises STOPPING
give up → raise the last failure, keeping its kind, with the member and the operation attached
```

- The delay before attempt `n + 1` uses the jitter factor so a fleet failing together does not
  return together.
- A timeout of a single attempt (stall) is TRANSIENT/LINK and is also tallied as a timeout on
  the member (the uplink governor reads the tally).
- The ladder never refuses to ask because the member is held: whoever has an alternative
  consults the breaker before asking (§8), and a request to a member that goes out while it
  climbs is ended by `until-held`.
- **`until-held(member, ask)`** races `ask` against the member's breaker tripping, cancelling
  `ask` and raising UNREACHABLE for that member when it trips.
- Attempts and failures are counted in metrics where they happen.

---

## 8. Health breaker

One breaker cell per member, local-filesystem stores included: a store on a network
filesystem or a removable disk fails the way a link does (its network-filesystem errnos are
TRANSIENT/link). A store that is not a member (a scratch store inside one process) uses a
shared cell that is always up. Every duration below uses the monotonic clock (§4). Which
outcomes count for or against a member is owned by
[failure-model §6](algorithms/failure-model.md#6-link-health-evidence); the cell only receives
"lost", "answered" and "probe lost".

State: `consecutive` failures, `failing_since`, `last_lost`, `held_until` (none when not out),
`hold`, `probing`, `timeouts` tally, one-shot watchers.

- **lost** (a failure counting against the member):
  - If `consecutive = 0`, or the cell is not out and `now − last_lost > HOLD_INITIAL`, start a
    new run: `consecutive = 0`, `failing_since = now`. Then `consecutive += 1`,
    `last_lost = now`.
  - If the cell is out: if a probe was handed out or the hold has lapsed, the failure is the
    probe's (or a lapsed hold's) evidence → `hold = min(HOLD_MAX, 2·hold)`,
    `held_until = now + hold`, notify watchers, answer *tripped*. Otherwise the request was
    already in flight when the member went out: answer *held*, no extension.
  - If not out: if `consecutive ≥ TRIP_AFTER` and `now − failing_since ≥ TRIP_SPAN` →
    `hold = HOLD_INITIAL`, `held_until = now + hold`, notify watchers, answer *tripped*. Else
    answer *up*: a burst within one instant is one bad moment.
- **check**: not out → *up*. `now < held_until` → *held*. Otherwise hand out the probe:
  `held_until = now + hold`, `probing = true`, answer *probe*. Exactly one caller per lapsed
  hold gets the probe; a probe that never reports back is re-offered at the next lapse.
- **is-held**: out and `now < held_until`. **is-down**: out, even if the hold lapsed (a lapsed
  hold is not an answer).
- **answered**: reset: `consecutive = 0`, not out, `hold = HOLD_INITIAL`, `probing = false`,
  sampled.
- **probe lost** (a deliberate probe failed or exceeded `PROBE_TIMEOUT`, retries included):
  the member goes out on that evidence alone: `hold = 2·hold` if already out (capped at
  `HOLD_MAX`), else `HOLD_INITIAL`.
- Watchers are one-shot: called once and cleared at each trip.
- A cell describes itself for status as "held down for Ns after K failures (reason)" and
  reports hold end, failure count and reason while out.

Rationale: without a breaker, eight retries against a dead host cost about a minute per read;
with it, failover to another member takes one to two seconds and only one request per hold
pays for finding out.

---

## 9. Stop

- A process has one stop flag. Requesting a stop is idempotent: it sets the flag and runs the
  registered hooks once, in registration order. A hook registered after the request runs at
  once.
- A **stop-aware sleep** ends early with STOPPING when a stop is requested. Every backoff and
  every wait for a link, a queue or a settle MUST be stop-aware.
- On stop: ladders end with STOPPING; queues stop taking work; waits for settle are capped at
  `STOP_GRACE`. STOPPING is never retried, never counted as a failure, and leaves the work owed
  on disk (the propagation rules are in
  [failure-model §5](algorithms/failure-model.md#5-propagation)).
- The lifecycle that requests a stop, and how processes drain within the grace, is owned by
  [07](07-daemon-cli.md).

---

## 10. HTTP request discipline

- **Pooled connections.** Each endpoint has a keep-alive connection cache.
- **Redial.** If a pooled connection proves dead before the request left, the cache that failed
  is replaced (only if it is still the current one) and the request is tried once more. A
  request that may have left is never silently resent by this layer; it is a TRANSIENT/LINK
  failure for the ladder.
- **Stall timeout, not a latency budget.** Each request runs under a stall timeout: it fails
  as TRANSIENT/LINK once `stall window` passes with no progress. Progress is any of: a request
  body chunk accepted by the transport, response headers, a response body chunk. (Large
  bodies over slow links are legitimate; a connection that died without FIN is silent forever
  unless a timer ends it.) The window is the driver's parameter
  ([06](06-backends.md)). The stall timer uses the monotonic clock.
- **Headers** may be computed per attempt (credentials that need minting); computing them
  counts as the request's first step and is inside the stall timeout.
- **Statuses** are classified by the driver per
  [failure-model §4.2](algorithms/failure-model.md#42-http-object-stores); only statuses the
  ladder retries raise; every other status is returned to the verb to interpret.
- **Bodies** move as off-heap buffers end to end; a body is never copied to be hashed or sent.
- Failure text quotes at most `HTTP_EXCERPT` characters of a response body, with whitespace
  runs collapsed.

---

## 11. IPC framing

The framing of every local socket between tsync processes and their clients. The envelope and
actions are owned by [07](07-daemon-cli.md), the error codes by
[failure-model §7.2](algorithms/failure-model.md#72-client-error-codes); where sockets live, their
modes and who may connect, by [07](07-daemon-cli.md) and
[security-model](algorithms/security-model.md).

- **Transport**: Unix-domain stream socket.
- **Framing**: one request is one JSON object on one line terminated by `\n`; one reply is one
  line. Requests and replies strictly alternate on a connection, which carries any number of
  requests until the client closes it.
- **Line bound**: a line longer than `IPC_MAX_LINE` is refused: the server answers `invalid`
  if it can and closes the connection. A line that is not a JSON object is answered `invalid`
  and the connection continues.
- **Partial lines**: once the first byte of a request line has arrived, the rest MUST arrive
  within `IPC_LINE_DEADLINE`, or the server closes the connection. An idle connection between
  requests MAY stay open.
- **Connection bound**: a listener serves at most `IPC_MAX_CONNECTIONS` connections at once.
  At the bound it closes the connection idle the longest; if none is idle it refuses the new
  one. Subscribed connections count toward the bound.
- **Subscription**: a request the contract defines as a subscription is answered with one
  reply line, after which the connection carries only event lines, one JSON object each, until
  either side closes it. Each subscriber has a backlog of at most `IPC_SUBSCRIBER_BACKLOG`
  events; on overflow the oldest events are dropped and the drop is logged. Events are hints
  for promptness, never needed for correctness. A subscription ends when the client closes or
  a write fails. Publishing reports how many subscribers received the event; zero is not an
  error.
- **Direction**: servers never connect to clients. A sandboxed client can always reach a
  server; a server pushing to clients cannot.
- **Socket options**: implementations MUST NOT set TCP-only options (such as `TCP_NODELAY`) on
  Unix sockets; some platforms answer `EINVAL` once the peer has left, and an accept loop that
  treats that as fatal stops serving everyone.
- **Server robustness**: a failure while serving one connection closes that connection only;
  it never ends the listener.
- **Advisory sends** (one process notifying another's socket: change notices, job reports,
  lease renewals) never fail their caller and log a failure once; their messages and send
  deadlines are owned by [07](07-daemon-cli.md).
- **Deadlines**: every request a client sends has a deadline, and the server answers every
  request within its own; both are specified in
  [failure-model §8](algorithms/failure-model.md#8-deadlines-and-bounded-waits-p7).

---

## 12. Reading data that may change under the reader

- A reader of a file outside tsync's control that another writer may truncate or rewrite in
  place (a user's file being imported) MUST obtain a failure, never a process crash,
  when that happens. It either reads a snapshot (a copy-on-write clone, unlinked after opening)
  or uses positioned reads; it MUST NOT map the live file, because a truncate under a mapping
  kills the process.
- A mapping is private and read-only, so a file shorter than the mapping is an error, never
  extended.
- Data that is never modified in place needs no snapshot; data tsync writes in place is read
  under the rules §5 points to.

---

## 13. Streaming ZIP64 archives

Folder downloads (share server, export) stream an archive whose total size is not known in
advance. The format is exact:

- Method STORED only. Every archive is ZIP64. Version needed 45. General-purpose flags `0x0808`
  (bit 3: data descriptor follows; bit 11: UTF-8 names).
- **Local header**: signature `0x04034b50`, CRC and sizes 0, extra field of 20 bytes: tag
  `0x0001`, length 16, two zero 64-bit sizes.
- **Data descriptor** after each member: signature `0x08074b50`, CRC-32, 64-bit compressed size,
  64-bit uncompressed size.
- **Central directory entry**: version made by `(3 << 8) | 45`. If the size or the local header
  offset is ≥ `0xFFFFFFFF`, all three (uncompressed size, compressed size, offset) move to a
  28-byte ZIP64 extra field and their 32-bit fields are `0xFFFFFFFF`. External attributes are
  `(S_IFREG | mode) << 16` for files and `((S_IFDIR | mode) << 16) | 0x10` for directories;
  default modes 0644 and 0755; directory names end in `/`.
- **End**: ZIP64 end of central directory (signature `0x06064b50`, record size 44), ZIP64
  locator (`0x07064b50`), end of central directory (`0x06054b50`) with counts capped at
  `0xFFFF` and sentinel values where a field overflows 32 bits.
- Times are DOS times in local time; a time before 1980 is written as date `0x21`, time 0.
- CRC-32 polynomial `0xEDB88320`.

---

## 14. Directory watch

- A watch reports that a directory's entries changed (created, moved in, closed after writing,
  and on macOS written, linked, deleted or renamed). It is not recursive. Where no watch is
  available, the consumer polls.
- A watcher MUST NOT wake its consumer for the consumer's own temporary files (§2.9): a read
  that makes a snapshot beside the watched file would otherwise wake itself forever. Where the
  platform reports names (inotify), events for temporary names are discarded. Where it does not
  (kqueue), the consumer MUST place its temporaries and snapshots outside the watched directory.
- Draining events after a wake is bounded, so a registration that never clears cannot spin
  forever.

---

## 15. Parameters

| Parameter | Recommended | MUST range / note |
|---|---|---|
| `DEFAULT_CHUNK_SIZE` | 8 MiB | |
| `CHUNK_SIZE_MIN` / `CHUNK_SIZE_MAX` (writers) | 256 KiB / 256 MiB | every client must read what a writer chooses |
| `CHUNK_SIZE_READ_MAX` (readers) | 2³¹ − 1 bytes | MUST accept every size existing manifests carry |
| `SHARD_FANOUT` | 3 hex characters | frozen |
| `NAME_MAX_LOCAL` | 250 bytes | ≤ 255 − the longest suffix appended to a stored leaf |
| `LADDER_ATTEMPTS` | 8 | ≥ 1 |
| `LADDER_BASE` / `LADDER_CAP` | 0.5 s / 20 s | jitter factor U[0.5, 1.5) |
| `TRIP_AFTER` / `TRIP_SPAN` | 2 failures / 1 s | |
| `HOLD_INITIAL` / `HOLD_MAX` | 30 s / 300 s | |
| `PROBE_TIMEOUT` | 10 s | includes retries |
| `STOP_GRACE` | 10 s | owned by [07](07-daemon-cli.md) |
| `HTTP_EXCERPT` | 200 characters | |
| `IPC_MAX_LINE` | 1 MiB | |
| `IPC_LINE_DEADLINE` | 10 s | |
| `IPC_MAX_CONNECTIONS` | 256 per listener | |
| `IPC_SUBSCRIBER_BACKLOG` | 256 events | drop oldest |


---

## 16. Conformance

An implementation MUST exhibit these observable properties.

- **Hashing.** The known answers of §3.1 for both seeds at every listed length (the empty body's
  chunk key is `2d06800538d394c2-4dc5b0cc826f6703`, that of `"hello world"`
  `d447b1ea40e6988b-b7aeb52a10fdaf2d`). Streaming with updates split at 1, 16, 240 or 1 MiB
  bytes equals one-shot hashing, and hashing a mapped buffer equals hashing the same bytes held
  any other way. The chunk-key test accepts exactly 33-byte lowercase dual-hex strings. The
  same vectors are checked by every other implementation of the chunk key (the bucket
  verifier): if two implementations disagree, every chunk in every store reads as corrupt.
- **Chunking.** Range-to-pieces lists equal the examples in §3.4, always cover the range exactly
  once, and are empty for length 0 or chunk size 0.
- **Keys.** The leaf `img.jpg` hashes to `066843ea47b80079-e0e3d2bb9b72c14d` under any folder;
  the root and trash ids are `.tsync-root` and `.tsync-trash`; a folder index lives at
  `<folder-id>/.tsync-index`; classification tells a child key, the index key, a namespace
  prefix and a temporary name apart. A file and a folder of one path are different logical
  keys; the root is the bare domain prefix and its parent is itself; parsing a string of
  another domain's prefix fails; a trailing `/` is accepted when parsing; descending from a
  file fails; a leading `/` in a user path is ignored. A chunk with a key shorter than 3
  characters is filed under shard `_`.
- **Validation.** Keys with an empty, `.` or `..` segment, a leading `/` or a NUL are refused;
  domain names `shares`, `gc-jobs`, `a/b`, `..`, `.tsync-x` are refused, `SHARES` is refused
  for a domain with a local-filesystem store and accepted otherwise, and `Family Photos` and
  `chunks` are accepted; folder ids of 12, 16 and 32 hex digits, with or without a `-<counter>`, are accepted.
- **Item references.** `d:.tsync-root` is the root; a leaf may contain `:`
  (`f:3f2a9c1b7d4e-1a/a:b`); `f:3f2a9c1b7d4e-1a/a/b`, `d:`, `f:3f2a9c1b7d4e-1a/`, `f:/x`,
  `d:..`, `d:Photos` and a storage key are malformed and answered INVALID; formatting
  round-trips.
- **Temporary names.** `.tsync-tmp-1-2.tmp` (owner pid 1 recoverable),
  `.tsync-tmp-9f3a0c.tmp` and `.tsync-tmp-scratch.tmp` are ours; `.syncthing.X.mkv.tmp`, `x.tmp`, `.tsync-tmp-1-2.txt` and
  `my.tsync-tmp-1-2.tmp` are the user's. Listings and mirroring hide only ours; a sweep removes
  a pid-form temporary only when its owner is dead.
- **Escaped names.** A leaf containing `:` is always escaped to `.tsync-esc-<hex16>` locally; a
  file's real name is recovered from its manifest; an escaped folder's `.tsync-name` record
  follows the folder through renames.
- **Random ids.** A forked child draws ids distinct from its parent's.
- **EINTR.** Both spellings of an interrupted call are retried; other errors propagate; an
  existence check agrees with the platform on missing files, files, directories and dangling
  links.
- **Local absent vs failed.** A read, stat or listing that fails with an error other than
  ENOENT/ENOTDIR raises a classified failure, never "absent" or "empty".
- **Breaker.** A blip does not trip; the second failure spanning ≥ `TRIP_SPAN` trips; an answer
  resets; one probe among concurrent checkers; a lost probe doubles the hold up to the cap; a
  failure in flight when the member went out does not extend the hold; a same-instant burst
  does not trip; watchers fire once; a lapsed hold is still down; an isolated old failure does
  not start a run with a new one; the always-up cell never goes out; the timeout tally
  persists across trips. None of this changes when the wall clock steps. A local-filesystem
  member whose network filesystem answers `ESTALE` or `ETIMEDOUT` trips like a remote one.
- **Stop.** A stop-aware sleep ends with STOPPING without the clock moving; an unregistered hook
  never runs; a late hook runs at once; a ladder under stop gives up after one try and counts no
  failure.
- **Glob.** Every row of the table in §17.
- **ZIP.** A fixed member set (a directory, a text file, a 300-byte binary, an empty file, a
  UTF-8 name) produces a fixed 1144-byte archive that a standard unzipper extracts.
- **Mappings and snapshots.** A mapping survives unlink and republish of its source; a short
  file errors instead of growing; writes to the mapping do not reach the file; a truncate of a
  file being imported fails the read rather than the process; no clone is left behind.
- **Reservation.** The file is sized; blocks are owned where the filesystem supports it; size
  0 is a no-op.
- **IPC.** Many requests per connection; a subscription acknowledges, then delivers only its
  topic's events in order; a departed subscriber is removed; publishing to nobody returns 0; an
  over-long line is refused; a stalled partial line is closed after `IPC_LINE_DEADLINE`; the
  listener survives any single connection's failure and stops cleanly.

---

## 17. Glob patterns

Glob patterns select paths (import `--only` and `--exclude`,
[05](05-ops-config.md)). A pattern is matched against a path (§2.3) as a whole: both ends are
anchored. Matching is byte-wise and case-sensitive.

- A **globstar** is `**` forming a whole segment of the pattern: at the start of the pattern or
  after `/`, and at the end of the pattern or before `/`.
  - `**/` matches zero or more whole leading segments of the remaining path: the rest of the
    pattern is tried at the current position and at every position immediately after a `/`.
  - `**` at the end of the pattern matches the rest of the path, whatever it is, including
    nothing.
- `*` matches any run of bytes, possibly empty, not containing `/`. Two or more consecutive `*`
  that do not form a globstar behave as one `*`.
- `?` matches exactly one byte other than `/`.
- Every other byte matches itself. There is no escaping, no character class and no brace
  expansion.

| pattern | path | matches |
|---|---|---|
| `**/.git` | `.git`, `a/.git`, `a/b/.git` | yes |
| `**/.git` | `foo.git`, `a/repo.git`, `a/b/c` | no |
| `**/node_modules` | `a/my_node_modules` | no |
| `src/**/*.ml` | `src/foo.ml`, `src/a/b/foo.ml` | yes |
| `src/**/*.ml` | `src/a/b/foo.c`, `srcx/foo.ml` | no |
| `a/**` | `a/b`, `a/b/c` | yes |
| `a/**` | `a` | no |
| `*.ml` | `foo.ml` | yes |
| `*.ml` | `dir/foo.ml` | no |
| `fo?` | `foo` | yes |
| `fo?` | `fo`, `fo/` | no |
| `a**b` | `axyb` | yes |
| `a**b` | `ax/yb` | no |
| `lost+found` | `lost+found` | yes |
| `foo.bar` | `fooXbar` | no |
| `""` | `""` | yes |
| `""` | `x` | no |
| `*` | `""`, `abc` | yes |
| `**` | `""`, `a/b/c` | yes |

---

## 18. Rationale

| Rule | Why | Rejected |
|---|---|---|
| Fixed-size chunks, size recorded per file | clients agree without talking; ranges map arithmetically; the size can change for new files only | content-defined chunking |
| XXH3-64 with two seeds, hex, joined by `-` | fast; fixed width; filesystem-safe; 128 bits of name; reimplemented by a bucket verifier | a cryptographic hash (the stores are the user's own; §3.2 states the limit) |
| Children filed by leaf hash under a stable folder id | a folder rename rewrites one object, not its subtree | path-keyed manifests |
| Kind not encoded in the key string | a second spelling can disagree with the first | trailing `/` for folders |
| Item references by folder id | paths change under renames and leak into logs | paths on the wire |
| No free-string constructor for stored keys | a key exists because a namer built it or a validated listing returned it | strings everywhere |
| Malformed reference is INVALID, not ABSENT | a client told "absent" may act on it (delete, allocate the name) | answering `not_found` |
| Reserved domain names refused, ignoring case where a filesystem store may fold case | a domain named `gc-jobs` could queue deletes of another domain's chunks; case-insensitive filesystems merge names; object stores do not, and existing domains there stay valid | trusting config |
| Globstar only as a whole segment | `**/.git` must not exclude `project.git` | character-level `**` |
| Temp names tested by prefix and suffix | a suffix test deleted a user's files | `*.tmp` |
| Jittered ladder backoff | a fleet failing together must not return together | fixed delays |
| Breaker with a single probe | failover in seconds; one request per hold pays for the probe | per-request ladders only |
| Stall timeout, not a total deadline, per HTTP request | slow-but-flowing links are legitimate; dead connections without FIN hang forever | a total request deadline |
| Monotonic clock for durations | wall steps at boot and under NTP trip breakers and fire stall timers | wall clock |
| Servers never connect to clients | sandboxed clients can always reach the server | pushing to clients |
| No TCP options on Unix sockets | an `EINVAL` on a departed peer killed an accept loop | runtime defaults |
| Subscriber backlog drops oldest | events are hints on top of the journal | unbounded buffers |
| Snapshot or positioned reads for files others change in place | a truncate under a mapping kills the process | mapping the live file |
| Resource strategy left to implementations; immutable data may be mapped | only observable limits constrain interoperability; objects replaced only by rename and content-addressed data never change in place | specified pool widths and memory strategies |
| One composition root binds the runtime | registries stay singletons; swapping the runtime touches one place | runtime calls everywhere |
