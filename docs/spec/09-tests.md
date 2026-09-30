# 09 — The test suite as the acceptance suite for a rewrite

Scope: `tests/` (about 32k lines, about 180 test directories), plus the out-of-tree suites that read its golden files (`lambda/test_*.py`) and the Android unit tests. Surveyed read-only at `4c32fa96`, 2026-09-29. No suite was run.

This file is language-neutral:
- the properties the suite protects, grouped by subsystem;
- for each property, which parts of the assertions carry it and which are presentation;
- the harness seams a rewrite needs;
- the failures the harness can simulate;
- the blind spots.

The [OCaml notes](ocaml/09-tests.md) are for someone staying in OCaml: dune mechanics, how the harness binds to Lwt, and the traps that have made suites pass while testing nothing.

---


## A1. What the suite protects, and how to read it

tsync's correctness claims are mostly about **sequences across peers and failures**. A typical one: write, rename offline, crash, have a peer publish, reconnect, collect garbage, then look at what each client and the bucket hold. The suite has three layers:

1. **Scenario layer.** Real engine components run against real on-disk stores in a scratch directory, driven step by step. The resulting state is printed:
   - each client's tree, with content read back through the read path;
   - owed work (the write-ahead log, "WAL");
   - the change log each client kept;
   - a normalised dump of every object in the bucket.
   
   The printout is compared with a committed golden file.
2. **Contract layer.** Store behaviour, composition of several stores, failover, the read path, queues, and the rate governor. Each is exercised against doubles that misbehave on purpose, and asserted in round trips, counts and orderings, never durations.
3. **Pure layer.** Hashes, key shapes, codecs, parsers, planners, renderers and bounded pools.

Three further tiers stay out of the hermetic run: real mounts (e2e and stress), real clouds (conformance), and a real configured domain (live).

**How to read a golden file.** A snapshot pins everything it prints, but only some of it is specification. The table below is the rule for all snapshots; §A5 notes exceptions per invariant.

| Snapshot element | Semantic (a rewrite must reproduce the fact) | Incidental (a rewrite may re-baseline) |
|---|---|---|
| Echoed step list | — | entirely presentation |
| Tree lines `f path size= cached=a/b uploaded= etag=` / `d path` | which paths exist and whether each is a file or a folder; logical size; how many of a file's chunks are local; published or not; etag equality between files and changes of etag | line syntax, sort order of the dump, field names |
| Content lines `path = "bytes"` | the exact bytes a reader gets through the read path; that a failed read fails | quoting and escaping |
| `pending …` lines | which operations are still owed after convergence, and their WAL state (intent, prepared, executed) | rendering |
| `kept` / change-feed ops | which ops a client recorded as applied, in order; the fields each op carries (key, src, id, size, is_dir) | JSON field order, spacing |
| Backend dump: `chunk K size=` | which chunk objects exist; that the chunk key is a pure function of the bytes (§A5.1) | shard directory in the path, line syntax |
| Backend dump: `file NAME [<folder-id>/<leaf-hash>] = manifest size chunks h1 h2` + `chunk#i` | that a manifest exists; that it is filed under its **folder id**, not its path; the recorded name; size, chunk list and digests | the exact leaf-hash spelling (it is specified in §A5.1, but a rewrite with another leaf naming only needs internal consistency) |
| Backend dump: `folder` / `anchor` / `trash` / `symlink` / `version #n` / `corrupted` / `chunk(going)` / `collecting: <phase>` lines | the object *kinds* present and their relations: which folder a marker names, where the anchor says it lives, what is in the trash, how many versions exist per path, which chunks are marked corrupt, which chunks are mid-collection, and the collection phase | line syntax; `<folder-N>` / `<entry-N>` / `#N` alias numbering; the name of the phase string |
| Journal lines `journal <entry-N> = put a.txt 11; …` | which ops were published, how they were batched into entries, and their relative order in key order | the rendering `put K SIZE` etc.; alias numbering |
| `cursor = <entry-N>` | which entry the stored cursor names | alias |
| Counts from maintenance (`gc kept K, reclaimed R`, `expire -> V version(s), J entries`, `N checked, C copied`, `repair: …`) | the numbers | the sentence around them |
| IPC JSON (`list_dir`, `stat`, `changes_since`) | field set and values, including the ref grammar, `next` cursor semantics, `stale` flag, `unnamed` count, error `code` | key order; wording of `error` text except where the text itself is a contract (noted) |
| Human-readable status, job and menu text | the facts each row states: numbers, states, which warnings appear, what is omitted when zero | column layout, padding, unit formatting, exact phrasing |
| `name: ok` check lines and the `N check(s)` tally | the number and identity of properties asserted | presentation |

Normalisations exist to make a golden file stable across runs, and a rewrite needs equivalents:
- random folder ids → `<folder-N>`, numbered by walking the tree from root, then trash, children in name order;
- journal entry names → `<entry-i>`;
- version timestamps → `#1…` oldest first;
- mtimes → `<mtime>`/`<zero>`;
- pin deadlines → `<deadline>`;
- walk ids in page cursors → `<walk>`;
- a cursor's generation prefix → `<cursor>`/`<empty>`.

Byte totals and copied keys are deliberately *not* printed where they depend on mtimes embedded in manifests. The root and trash ids are constants and are printed raw.

## A2. Harness seams a rewrite must provide

The scenario runner instantiates the engine the way a daemon does, minus the socket, the frontend and the poller's timer. What it plugs into is therefore the set of real abstraction boundaries.

### A2.1 Domain configuration (a value, not a file)

A test builds a domain configuration directly. It needs these fields:

| Field | Meaning | Test default |
|---|---|---|
| domain name, client name | identity; client name appears in conflicted-copy names | `test` / `Test Client`, `Client A`/`Client B`; the two-client driver uses domain `test-<scenario>` (see the [OCaml notes](ocaml/09-tests.md)) |
| key prefixes | `tsync/<d>/manifests/`, `tsync/<d>/chunks/`, `tsync/<d>/versions/`, `tsync/<d>/journal/`, cursor `tsync/<d>/cursor`, shares `tsync/shares/` | derived from the domain name |
| composite store | where writes and metadata go | single-client: two local stores as mains; two-client: one shared local store |
| member list | named stores with type, config and optional local path; **chunk reads and diagnostics walk members, not the composite** | as above |
| cache root, data dir, socket path | per client | under the scratch dir |
| max uploads | upload workers | 1 (see below) |
| max chunk buffers, max downloads | memory and fetch bounds | 4 / 8 |
| chunk size, cache chunk size | stored chunk size; cache group size (a multiple of it) | production default; 8 / 24 via environment in a few suites |
| max cache | cache cap | unset; 8 bytes in one suite |
| symlink policy | keep / follow / skip | keep |
| read-only, versioning | domain flags | off; versioning per suite |

Two defaults carry meaning:

- **One upload worker.** The kept log records entries in the order they finish, so with two workers in flight the log order is a race.
- **The link governor is off.** When on, every store joins a line paced by the real clock.

A second fixture builds the configuration by *parsing* a config record through the same path the daemon uses, then grafts doubles onto the composite and/or the member list.

### A2.2 The store contract

This is the one interface every backend driver and every double implements.

- `put(key, bytes)`
- `put_if_absent(key, bytes) → held bytes`. The winner gets back exactly what it passed; that is how a caller tells a win from a loss.
- `get(key) → bytes`, which fails if the key is absent.
- `get_opt(key) → bytes?`
- `get_range(key, off, len) → bytes?`, clamped at the end of the object: past-end reads are short, not errors, and an over-long answer is refused.
- `head_opt(key) → {size, mtime, etag?}?`
- `delete(key) → removed?` (a bool).
- `delete_multi(keys)`. Absent keys are fine.
- `copy(src, dst)`
- `list_prefix(prefix, max_keys?)`
- `watch(key, last_seen?)`: a long poll that returns when the key may have changed, or at a cap.
- Optional native batches `get_many` and `list_many`.
- `fast_read`: whether a whole object is as cheap as a range.
- `verify_all(chunk_prefix) → Queued n | Unsupported`
- `discard(chunk_prefix, run, name, keys) → Queued | Unsupported`
- `capabilities(prefix)`: chunk size, share URL, max concurrency, verified.
- `local_path?`
- a health cell.

### A2.3 Store doubles, one per failure shape

Every double declares no native batches, no fast read, no local path and an always-up health cell. That way nothing can answer through a side door while the double is "down".

| Double | Behaviour | Why it exists |
|---|---|---|
| Down(reason) | every call fails with `reason` | an unreachable store; two of them can be told apart in a report |
| Hung | every call pending forever | the answer that never comes: deadlines, probes, stall timeouts |
| Outage(real) | while down, each call **waits** until the link returns, then goes through; every call is counted on entry | an outage as a user sees it; measures round trips an operation made ("0 round trips while offline") |
| Flaky(real) | the next *n* calls, optionally only those of one named verb, **fail** (transient by default, or a given error) | what retries, parking and stepping aside are for |
| Refuses | reads answer empty, writes raise "not writable" | wrong credential, read-only bucket |
| Memory | an in-memory table, fresh per instance | "what reaches the store", with one verb overridden to count or gate |
| hand-written wrappers | include a real local store, override one or two verbs to count, gate on a promise, mangle bytes, or lose a delete silently | used in most backend and read-path tests |

**Outage versus Flaky.** A stalled request and a refused one exercise disjoint code. A scenario run only under Outage says nothing about retries or parking. Background cursor bumps consume refusals that are not aimed at a verb, so a Flaky refusal should name the verb it targets.

**Composite versus members.** A double passed only as the composite store is bypassed by chunk reads, which walk members, and the test then records 0 round trips. A link double must be passed as a member too.

### A2.4 The request interface (IPC)

User-level mutations and queries go through the same request handler a frontend uses. Each request is one JSON object:
- `{"action": …}` plus the arguments that action takes: `ref`, `parentRef`, `name`, `rel`, `arg`, `staging`, `target`, `limit`, `after`, `keep`, `await`.
- The answer is `{"ok": bool, "code"?, "error"?, …}`.

Actions used by the harness:
- mutations: `write` (content from a staging file the daemon adopts by rename), `mkdir`, `create`, `symlink`, `rename` (`ref` + new `parentRef`/`name`), `delete`, `rmdir`;
- cache control: `evict`, `restore`;
- versions: `revert`;
- queries: `stat`, `list_dir`, `list_all`, `cursor`, `changes_since`;
- control and reporting: `full_resync`, `stats`, `stop`.

The handler also takes a set of hooks from its host: evict, restore, changed-keys notification, full-resync, extra status and stats fields, and on-stop.

**Items are named by reference, not by path.** Reference forms:
- `root`;
- `d:<folder-id>`;
- `f:<parent-folder-id>/<leaf>`.

The client resolves path → reference from its own mirror, because the client holds the mirror. The harness creates missing parent folders through `mkdir` requests before it writes into them.

### A2.5 Direct engine surface

Some steps bypass the request interface, because what they model is not a request.

| Area | Operations | What a step models |
|---|---|---|
| POSIX-level file ops | `read(key, buf, off, stream?)`, `write(key, buf, off)`, `truncate`, `close`, `fetch_range(key → dst file, off, len)` | FUSE and File Provider calls |
| Inspection | `resolve(key) → Staged slots \| Published manifest`, `chunk_residency`, `chunk_stats`, `list_children`, `read_ahead_in_flight` | reading state without changing it |
| Queues | upload and metadata queues: `pending`, `set_paused`, `drain`; `flush_cursor` | holding or releasing work |
| Sync | one poller pass, `sync_once`, cursor gate included | the background poller's work, without its timer |
| Maintenance | retention `expire(cutoff)` / `purge_trashed(path)`; GC `run(verify?)`, `start`/`step`/`phase`/`release`/`abort`; corruption `list`/`invalidate`; `repair`; mirror `resync(scope)`; `import`; `export`; WAL `record`/`advance`/`list`/reconcile; staged-orphan sweep; cache-cap `enforce` | commands and restart-time work |

### A2.6 Clock

The abstract clock has:
- `now`, monotonic;
- `sleep`;
- `with_timeout`;
- `with_stall_timeout(alive)`, which fails after that much *silence*;
- `pick`;
- timeout and cancel classification.

A fake clock moves only on `advance(s)`, and wakes due sleepers in deadline order. That lets the rate governor, retry backoff, shutdown and the stall timeout be tested as control laws without waiting for real time.

### A2.7 Scenario drivers

A rewrite's harness needs these shapes. Each prints the step list, then the state described in A1.

| Driver | Setup | Prints after the steps |
|---|---|---|
| single client | one client, two main stores | tree, content, backend dump (plus the second store's dump when a step touched it) |
| two clients | A and B with separate cache, data and identity; one shared store | A's and B's tree, content and pending; A's and B's kept log; backend |
| listing | one client | raw `list_dir` per folder, `list_dir` paged 2 at a time, flat `list_all` paged |
| change feed | A mutates, B syncs | B's feed from a baseline anchor, from its current cursor, from a pruned anchor, and after a generation bump (reimport) |
| page stability | one client | flat listing with the server's kept walk deleted between pages, and with a file written between pages |
| stats | one client | structure of the `stats` report, and that it renders as text |

A step failure is printed as `ERROR <exn>` and the state dump still follows. A golden file can therefore pin a failure.

### A2.8 The step vocabulary (the acceptance DSL)

Steps describe what a user or the environment does, never internal transitions.

- **User**:
  - Write, Mkdir, Rmdir, Rename, Delete;
  - Symlink (a refusal is printed, not raised);
  - Evict, Restore;
  - RevertVersion, optionally to a given version;
  - Stat, StatByPath, RestoreByPath(keep), CreateUnder(parent spelled verbatim).
- **POSIX**: ReadRange(stream?), FetchRange, WriteAt, Truncate, StageWrite (edits with nothing queued), Close (queue what is owed).
- **Observe**: ShowChunks (published count or staged slots S/I/Z, plus local count), ShowChunkCache, ShowStaged, ShowNames (readdir), ShowLocal (online-only/cached/pinned), ListCorrupted, RequestVerify.
- **Queue control**:
  - Drain: wait until both queues are empty, flush the cursor, then ensure the next journal key is in a later millisecond.
  - DrainMetadata.
  - Uploads and Metadata, each Paused or Running.
  - SettleReadAhead: wait for the prefetch a read fired, bounded; fail rather than hang.
- **Sync**: Sync (one poller pass); HideNewestJournalEntry / UnhideJournalEntry (an entry whose upload lands late).
- **Maintenance**: Mark; Expire all|none|mark; PurgeTrashed; Gc, GcVerify; GcMark / GcClose / GcAbort (stop a collection at its phase boundary and act mid-collection); Repair; RescanCorrupted; ResyncRemote; ResyncScoped; Import(only, exclude, force_rehash) over a local staging tree built by LocalWrite, LocalMkdir and LocalSymlink; ExportDir.
- **Fault injection**: see A3.

## A3. Failures the harness can simulate, and why each exists

| Failure | How it is produced | What it exists to prove |
|---|---|---|
| Link offline (stall) | Outage double; `read_deadline` short or long | metadata ops cost 0 round trips offline and owe work; a cold read fails within its deadline instead of hanging (a hung read blocks system suspend); a read waiting on a long deadline is answered when the link returns |
| Link refuses (transient/permanent, per verb) | Flaky double; hand-written refusals | retries do not reorder; a permanent failure steps aside, marks degraded, can be re-armed; a refused `put_if_absent` claim is retried |
| Store down / hung / read-only | Down, Hung, Refuses | read/write policy by role; probes are bounded (`no answer within 10s`); held members are not asked; deferred targets record rather than fail |
| Backend damage | delete a chunk; overwrite with wrong size; overwrite with same size *through the store* (the store files its own marker); same size *straight to disk* (bit rot, invisible until something re-reads); delete a manifest; each optionally on the secondary store | corruption markers, repair from another copy, `gc --verify` finding bit rot, resync copying missing or wrong-size objects |
| Crash windows | bytes uploaded + WAL record "executed", no journal entry; a legacy pending record naming data never staged; an orphan staged body in each body tree; a promotion interrupted with and without its commit record; a queue log held by a real child process that is then SIGKILLed; SIGKILL of a mount or store daemon (stress) | recovery publishes exactly once, discards what cannot be completed, reclaims orphans, and never uploads bytes twice |
| Cache loss | wipe mirror, folder index, chunk store and applied log, keep the staged tree; delete one cached group behind the daemon's back; forget one folder's local id | unsynced edits survive; the mirror can be rebuilt from the store; a missing id is re-adopted |
| Journal visibility | hide the newest entry, publish later ones, unhide | an entry that becomes visible after a newer one is still applied |
| Lost delete | a store whose `delete` of one key silently does nothing | anchors make a stale folder marker harmless |
| Concurrency | racing `put_if_absent`; readers and writers during promotion; 8 foreign threads reading through the embedding bridge; several processes minting folder ids; two peers publishing conflicting ops | one winner per claim; no torn reads or mixed bodies; no duplicate ids; convergence |
| Scheduling and bounds | fetchers gated on a promise the test releases; overlap counters | pool widths are exact maxima; a read never waits behind a whole-group fetch; slots are taken before resources are opened |
| Time | fake clock | rate governor, retry backoff, stall timeout, shutdown |
| Load | stress fault `load` (busy loops); CPU hogs when reproducing flakes | convergence under contention; identifying load-sensitive tests |
| Queue hold | pause uploads and/or metadata; a frontend "hold changes" switch | a scenario can leave work owed deterministically; offline-peer conflict setups; pause never wedges shutdown |

## A4. Invariants the suite pins, by subsystem

Format of each entry: **the invariant**. Then *Carried by*, the part of the assertions that holds it. Then *Incidental*, what a rewrite may change freely. The directory names at the end are a trace only. Unless an entry says otherwise, the incidental part is the rendering conventions from A1.

### A4.1 Core: hashing, identifiers, keys, codecs

- **Chunk key = content hash.**
  - The key is `XXH3-64(body, seed 0)` and `XXH3-64(body, seed 1)`, each as 16 lowercase hex digits, joined by `-`.
  - Pinned vectors:
    - `""` → `2d06800538d394c2-4dc5b0cc826f6703`
    - `"hello world"` → `d447b1ea40e6988b-b7aeb52a10fdaf2d`
    - 14 rows in all, over XXH3's branch sizes 0, 1, 16, 17, 128, 129, 240, 241, 2600, 1 MiB, 1 MiB+1 and 8 MiB. The pattern body is byte *i* = (31*i*+7) mod 256.
  - Streaming the hash (updates split at 1, 16, 240 or 1 MiB) equals hashing in one shot. Hashing a memory-mapped buffer equals hashing a string.
  - *Carried by:* the exact key strings.
  - *Incidental:* nothing. The same golden file is re-read by the in-bucket Python verifier's test. If the two implementations ever disagree, every chunk in every store is filed as corrupt at once.
  - Trace: unit/hash, lambda/test_chunk_key.py.
- **Manifest digests.** A file's `h1`/`h2` identify its content, and a file's etag is `h1`. The etag of empty content is `06b4b04bae2346bf`. Identical content means identical etag. *Carried by:* etag equality and inequality across files. Trace: scenario/base, frontends/android.
- **Folder identity.**
  - A folder id is `<first 12 hex of the client uuid>-<hex counter>`, minted locally with no coordination.
  - The client uuid is 32 hex characters. Concurrent first-starters agree on one uuid.
  - Several processes of one client never mint a duplicate. A process started later counts above everything minted before it.
  - A forked child reseeds its random source.
  - *Carried by:* uniqueness over 8232 ids from 4 processes; the ordering claim. *Incidental:* the block size used to reserve counters.
  - Trace: unit/folder_id, unit/id.
- **Item references.**
  - `root`, `d:<id>`, `f:<parent-id>/<leaf>`. Only the first `/` separates, so a leaf may contain `/` or `:`. `d:<root_id>` normalises to `root`.
  - Malformed refs parse as Bad without raising: an empty leaf, an empty parent, a bare `d:`.
  - A storage key is never accepted as a reference, including another domain's key.
  - `to_string ∘ parse` is the identity, Bad included.
  - Trace: unit/item_ref, scenario/ipc, frontends/android.
- **Logical keys.**
  - Kinds are file, folder and root.
  - Wire spelling: a trailing `/` marks a folder. The root is the bare prefix. A leading `/` is ignored.
  - A file and a folder with the same name are distinct keys.
  - The parent of the root is the root. Descending into a file is an error.
  - A key from another domain's prefix is rejected.
  - Trace: unit/logical_key.
- **Stored (backend) keys.**
  - Anchors: `root_id = .tsync-root`, `trash_id = .tsync-trash`.
  - A child object lives at `<folder-id>/<16hex>-<16hex>`, a hash of the **name only**. Example: `img.jpg` → `066843ea47b80079-e0e3d2bb9b72c14d` under any folder.
  - A folder index lives at `<folder-id>/.tsync-index`.
  - Classifiers distinguish a child, the index, the namespace key and a temp name.
  - *Carried by:* the pinned hash values, if a rewrite wants to read existing buckets; otherwise only internal consistency.
  - Trace: unit/stored_key.
- **Chunk shard.** A chunk lives at `tsync/<d>/chunks/<first 3 hex>/<key>`. A key shorter than 3 characters goes to `_/`. Trace: unit/layout.
- **Journal entry keys.**
  - Format: `%013d-<client-uuid>`, where the 13 digits are epoch milliseconds.
  - Objects live at `journal/YYYY-MM/<key>`, with the month taken in UTC.
  - Sharded paths sort like bare keys across month and year boundaries.
  - Parsing accepts a full listing key and rejects:
    - a short timestamp;
    - a non-numeric timestamp;
    - an empty uuid;
    - a bare prefix or a bare month.
  - Trace: unit/layout.
- **Side prefixes live beside the domain, never inside it.**
  - Corruption marker: `tsync/corrupted/<d>/<shard>/<key>`.
  - Verify job: `tsync/verify-jobs/<d>/<id>`.
  - GC delete request: `tsync/gc-jobs/<d>/<run-ms>/<3hex shard>`, with the run time in integer milliseconds (1755300000.5 → `1755300000500`). Two runs 0.5 s apart get different names.
  - Domain names containing spaces work.
  - Marker membership is decided by prefix, never by shape. Nothing under `chunks.from/` or `manifests/` is a marker, and a marker's marker is None.
  - A malformed job key (missing run, bad shard, trailing `/`, empty domain) is refused.
  - *Carried by:* exact keys. The GC key is also re-read by the Python delete worker's test.
  - Trace: unit/layout, unit/gc_job, lambda/test_gc_job_key.py.
- **Temp names.**
  - tsync's own temp files are exactly `.tsync-tmp-<pid>-<n>.tmp`.
  - Recognition needs both that prefix at position 0 and that suffix. The owner pid is recoverable.
  - Everything else is a user file, including `.syncthing.X.mkv.tmp`, `x.tmp`, `.tsync-tmp-1-2.txt` and `my.tsync-tmp-1-2.tmp`.
  - Listings hide only tsync's own temp names, and mirroring never copies them.
  - Sweeps delete only temp files whose owner is dead.
  - Trace: unit/temp_names, unit/spool_reap, unit/sweep_scope, backends/writes_in_flight.
- **Recorded names.**
  - A manifest's name is its key leaf, stamped by the writer whatever name the caller supplied.
  - Names unsafe on a filesystem (`:` always) get an escaped on-disk leaf `.tsync-esc-<hash>`, and the body is the only way back to the real name. Unsafe folder names keep a `.tsync-name` marker that follows renames.
  - Trace: unit/manifest_naming.
- **Staged sidecar codec.**
  - JSON with `"v":2`. Slots are Staged{uuid, offset}, Inherit or Zero.
  - A v1 sidecar has no offsets and reads as offset 0.
  - A sidecar from a newer version is **set aside** (renamed to `.bad`) and treated as absent, never guessed at.
  - Trace: unit/staged_codec.
- **Framing robustness.**
  - The proxy batch frame is length-prefixed with no keys; order is the contract. It distinguishes an absent body from an empty one.
  - Decoding raises on truncation, on too few or too many entries, and on a half prefix.
  - Durable listing spools round-trip `\n`, `\t` and `\0`, the empty string and int64 extremes. They can be re-iterated, and refuse appends after iteration starts.
  - Trace: unit/wire_bodies, unit/listing, frontends/http_proxy.
- **Glob and field parsing.**
  - `*` and `?` do not cross `/`. `**/x` matches at any depth, the top included.
  - Booleans accept `true/1/yes/on` and `false/0/no/off`, case-insensitive; anything else gives the default.
  - Trace: unit/glob, unit/field_spec.

### A4.2 Remote model: manifests, chunks, dedup, versions, trash, GC, integrity

- **Content dedup.**
  - Identical bytes are one chunk object, whatever the file or name. A re-upload of identical content adds 0 chunk objects.
  - Zero-filled chunks from a grow share one key.
  - A 0-byte file is one empty chunk.
  - *Carried by:* the count of `chunk` lines and shared chunk keys across manifests.
  - Trace: scenario/base, scenario/upload, content/demand_paging.
- **Files are filed under folder ids, not paths.**
  - A folder rename moves one marker, and the children's keys do not change (O(1) rename).
  - The marker's *anchor* `{parent, name}` is written with the new marker **before** the old marker is deleted.
  - When a marker and its anchor disagree, the anchor wins. A stale marker left by a lost delete, or by a concurrent rename, is ignored by readers and lends its id to nobody.
  - *Carried by:* folder, anchor and file lines in the backend dump; listing shows the folder exactly once.
  - Trace: scenario/base, ops/rename, scenario/conflicts d2/d4.
- **Deletion never collects chunks.**
  - Delete and rmdir remove manifests or markers. Chunks stay until expiry and then GC.
  - rmdir moves the folder, with its subtree, to the trash: a trash marker plus an anchor in `.tsync-trash`.
  - Trace: scenario/base, scenario/expire, scenario/gc.
- **Versioning.**
  - With versioning on, each overwrite and each delete saves the prior manifest under `versions/`. A rename saves a version of the *old* path.
  - `revert` publishes a new put from a saved version, and leaves the file dataless.
  - Revert drops staged bodies.
  - *Carried by:* the version count per path and its size, and the new journal put.
  - Trace: scenario/versioning.
- **Retention.**
  - `expire(cutoff)` drops versions, trashed folders and journal entries older than the cutoff.
  - It always keeps the newest journal entry, and leaves the chunks for GC.
  - `purge_trashed(path)`:
    - drops one trashed subtree regardless of age;
    - answers "not in trash" for a path never trashed;
    - refuses a folder that lives elsewhere.
  - *Carried by:* the counts `V version(s), J entries`, and which objects remain.
  - Trace: scenario/expire.
- **GC is a mark-and-sweep with a resumable, observable phase.**
  - A chunk referenced by any live manifest, version or trashed manifest is kept.
  - A second run is a no-op.
  - Chunks the collection is taking out live in a separate "going" space. A marker names the phase.
  - During an open collection:
    - A write that dedups onto a chunk being collected keeps it alive: publishing promotes it.
    - A read finds a chunk in either space.
  - `abort` moves everything back.
  - `--verify` rehashes every live chunk. A corrupt chunk that is still referenced is kept and marked, not reclaimed.
  - Collecting a chunk removes its corruption marker.
  - *Carried by:* kept and reclaimed counts, going-space lines, and readable content after evict.
  - Trace: scenario/gc, scenario/corruption.
- **GC cost and reach on multi-store domains.**
  - Starting a collection makes 0 listings. Marking costs one listing per namespace and 0 HEADs, because promotion is a bare rename.
  - Progress is written once per namespace, so a resume redoes nothing.
  - Closing lists only the shards the main holds (12 of 4096), and **never lists a replica**.
  - A collection never copies and never fills replicas.
  - Copies are cleaned by a delete-request object under the GC-jobs prefix, not by walking them:
    - `outstanding` names the copies that still owe it;
    - a consumer deletes the keys and their derived marker keys, then the request itself.
  - A chunk only a copy holds survives. A chunk re-uploaded to the main mid-close survives on the main and is not deleted from copies.
  - Nested concurrency does not deadlock.
  - *Carried by:* listing, HEAD, copy and put counts.
  - Trace: backends/gc_cost, backends/gc_queued, backends/gc_targets, unit/gc_report.
- **Corruption markers.**
  - A store that verifies writes files a marker when a body does not hash to its key. The marker records the computed hash.
  - The upload path consults markers **before** its known-chunks memo, so a marked chunk is re-uploaded rather than deduped. The good write clears the marker and leaves no empty shard behind.
  - `list` reports a count, which may be 0, and names stores nothing checks. A store that never looked and a store that found nothing are different answers.
  - Trace: content/corruption, scenario/corruption, unit/dedup.
- **Repair.**
  - Each marked chunk is rewritten from any copy that hashes to its key. Only the damaged store is written.
  - When no copy is good the chunk is reported LOST and its markers stay.
  - A request to verify a local store answers "unsupported", and the command built on it must fail rather than report a check that never ran.
  - Trace: scenario/corruption.
- **Verified fetch.** A verified chunk fetch rehashes the body. On a mismatch it re-reads **once**; a second mismatch is an error naming the key. The unverified path accepts any bytes. Trace: content/verified_fetch.
- **Store integrity (tree shape).** An integrity pass reports these kinds of problem:
  - one folder id under two markers;
  - a trash entry naming a live folder;
  - a folder with no anchor;
  - a marker disowned by its anchor;
  - an orphan namespace.
  
  Repair removes disowned markers and trash entries that name live folders, writes missing anchors, and never touches orphans.
  - *Carried by:* the kinds and their counts.
  - *Incidental:* the report's wording.
  - Trace: ops/integrity_tree.
- **Mirror / resync between stores.**
  - The destination is **listed, not probed per object**: 0 HEADs and 1 listing per namespace; chunks are listed shard by shard.
  - Resync copies missing objects and wrong-size objects. A same-size scrambled chunk is **not** copied, because resync compares sizes only.
  - It is idempotent. A scope narrows it to one folder and the chunks that folder names.
  - A body is started only inside the copy bound. Memory per object is bounded because the listing is streamed from disk.
  - Trace: scenario/resync, unit/mirror_probe, unit/mirror_pools.
- **Upload.**
  - Chunk size is chosen in order: configured, then the backend's capability, then the default.
  - A source modified during upload aborts with nothing published.
  - Chunk bodies in memory are bounded by `max_chunk_buffers`, and there is no per-chunk task laid out up front.
  - A manifest builder keeps its body off the managed heap.
  - A queued upload whose staged manifest has vanished publishes nothing, and clears its WAL record.
  - Trace: scenario/upload, scenario/staged_fanout, unit/upload_fanout, scenario/upload_gone.

### A4.3 Journal, cursor and sync

- **Every published change is a journal entry.** The cursor names the newest entry this client published.
  - Ops and their fields:
    - `put(key, size)`
    - `delete(key)`
    - `mkdir(key, id)`
    - `rmdir(key, id)`
    - `rename(src, dst, is_dir, size?)`
  - One entry may batch several ops, in order.
  - An import publishes all its mkdirs before any put. It splits entries at a maximum op count, and also by age, so a long import publishes before it ends.
  - Trace: scenario/base, scenario/import_export, unit/import_batching.
- **Entry keys are minted when an op happens, not when it is published.** Journal order in key space is mint order. Trace: scenario/conflicts.
- **The cursor debounces.**
  - The first bump on a quiet cursor writes immediately.
  - Later bumps inside the interval coalesce into one write, carrying the newest key.
  - The cursor only moves forward.
  - `flush` writes at once. **A stop publishes held bumps even if the drain timed out.**
  - Trace: unit/cursor_debounce, frontends/stop_publishes_cursor.
- **The poller is gated by the cursor.**
  - An idle client waits on the store's `watch` and makes 0 reads.
  - When the cursor has moved: 1 cursor read and 1 journal listing.
  - When the cursor has not moved: 1 read and 0 listings.
  - A pass whose listing failed does not advance the token it offers next.
  - A periodic sweep lists the journal even when the cursor has not moved.
  - Trace: unit/cursor_watch.
- **Every foreign entry is applied exactly once, whenever it becomes visible.**
  - An entry that becomes visible after a newer one is still applied. The client never reads "since the cursor key".
  - A client's own entries are skipped.
  - *Carried by:* B's final tree and kept log.
  - Trace: scenario/sync late_visible_entry.
- **Applying foreign ops.**
  - A foreign put appears as not cached.
  - A foreign overwrite invalidates the cache.
  - A foreign rename **keeps** the cache.
  - A rename chain is applied in one pass.
  - A foreign mkdir or rmdir mirrors the folder.
  - A peer that lost a folder's local id re-adopts it from the store marker.
  - A peer rename announces both the old and the new key to the frontend.
  - Trace: scenario/sync, scenario/meta_offline.
- **Applied log (the change feed's source).**
  - Each client appends every op it published or applied to a monthly log, choosing the month by *handling* time in UTC.
  - `since(anchor, limit)`:
    - returns ops in handling order, anchor exclusive, with `more` set when the page is full;
    - crosses month shards;
    - answers "gone" for a pruned anchor.
  - A late entry with an older key follows the anchor and becomes the head.
  - A torn last line is skipped, and the head is found even when its line is wider than the tail-read window.
  - Pruning by age or size returns the count of shards and bytes removed.
  - Trace: unit/applied_entries.
- **Change feed contract.**
  - `changes_since(anchor)` reports what *this client has applied*. A client that never synced reports nothing.
  - Answer: `{stale:false, cursor, more, ops}`, where each op carries the item only if it still exists.
  - A rename carries the source reference, and the folder id for a folder.
  - A move into a folder renamed since then is named by folder id.
  - From the current cursor the ops are empty.
  - From a pruned anchor, or after a generation bump (reimport), the answer is `stale:true`.
  - Trace: scenario/ipc.
- **Metadata operations never wait on the network.**
  - Offline, every rename, delete, mkdir (id minted locally), rmdir and symlink returns with **0 round trips** and owes a WAL record.
  - After reconnect everything publishes in order:
    - a folder created then renamed publishes as `mkdir new` + `rename old→new` with the same id;
    - a folder created and removed before publishing is never filed.
  - An upload into a folder whose mkdir is owed files the marker first. A file moved into a folder that then moves is filed under the folder's id and new name.
  - Peer entries blocked on the store never block local ops.
  - Trace: scenario/meta_offline.
- **Owed-work ordering and failure.**
  - A transient failure is retried **without later ops overtaking it**.
  - A permanent failure, or a local error, steps aside: later ops publish, the op stays owed, a degraded flag is set, and re-arming retries it.
  - An unappliable peer entry steps aside and is applied once the obstacle is gone.
  - A "hold changes" switch stops both publishing and applying, but not reads.
  - Trace: scenario/meta_offline, work/queue_order, scenario/pause.
- **Crash recovery through the WAL.**
  - An op whose bytes are on the store but has no journal entry is shown as `pending executed`. After restart recovery it is published exactly once.
  - A pending record naming data that was never staged publishes nothing.
  - A never-started op is completed once. An op whose local half already ran is not redone.
  - Trace: scenario/sync crash_*, scenario/meta_offline.
- **Conflict resolution is total and converges.** After two peers race with any pair of operations, both end with identical trees, nothing pending, and **no bytes lost**. The rules the suite pins:
  - **Edit beats delete.** f1, f12: the edit survives. f5: a rename racing a delete is republished as a put.
  - **Edits follow renames.** f4, f10: an edit lands at the new name. d3, d9: an add inside a renamed folder follows the folder.
  - **Both sides of a clash are kept.**
    - edit vs edit: the first publisher keeps the name, the other becomes `<stem> (conflicted copy from <client>)<ext>`, then `… (conflicted copy 2 from …)`;
    - create vs a rename onto the same name (f7, f8, f11): the same;
    - mkdir vs mkdir (d6): the copy keeps its own folder id;
    - a file vs a folder of the same name (k1): the same, in either direction.
  - **Rename vs rename of one file keeps both names** (f6). This is duplication, not a conflict mark.
  - **Folders.**
    - rename vs rename: the last publisher's name wins and the anchor decides (d4).
    - rmdir beats adds inside (d1): the added file survives *inside the trashed folder on the store*, and is lost from both trees.
    - adds inside a folder a peer removed (d8) are **rescued to the root, flattened**, as conflicted copies.
  - **Folder rename onto a peer's folder.** The copy is named after the **renamer's** client.
  - **Concurrent create of one new name.** Last writer wins, with no copy.
  - A resolution table of 65 peer-op situations and 23 own-op situations is pinned as fact → decision (unit/resolve).
    - *Carried by:* the decision for each fact tuple.
    - *Incidental:* the wording of fact and decision strings.
  - Trace: scenario/conflicts, scenario/sync, ops/rename, unit/resolve.
  - See memory note *design-best-effort-conflicts*: resolve immediately, lose nothing, make conflicted copies when in doubt, and let winner-takes-all come last.
- **Resync, full versus incremental.**
  - With no bookmark, a full rebuild. When caught up, incremental. `--full` forces a rebuild.
  - A rebuild is reported as a **delta**: rewritten mirror entries, deletes for manifests the store lacks, and folder changes as mkdir/rename/rmdir. Chunks survive, and old anchors stay valid.
  - A partial walk (an unreadable object) leaves the bookmark where it was and sweeps nothing. A lost batch is retried.
  - An incremental run publishes owed metadata first. A full run with owed metadata is **refused**, because it would undo them.
  - Trace: ops/resync.

### A4.4 Checkout and cache: staged writes, reads, residency

- **The mirror is the whole answer for names.** Looking up an absent name makes 0 store reads, and so does repeating the lookup. A manifest on the store but not in the mirror is "not found" until the poller brings it in. Trace: content/absent_probe; see memory note *fuse-enoent-backend-roundtrip*.
- **Staged write model.** A file being edited is a slot vector: I (inherited from the published manifest), S (a staged local body) or Z (a hole from a grow, zeros, no disk).
  - An edit inside one chunk fetches that chunk only (read-modify-write).
  - An aligned whole-chunk write fetches nothing.
  - Truncation shrinks the slot vector.
  - A grow adds Z slots, fetches nothing, and reads as NULs.
  - On publish, only S chunks are uploaded, and I chunks keep their keys.
  - With cache groups larger than chunks, an edit stages every member of its group, and publishing writes the group from staged bodies with no fetch.
  - *Carried by:* slot strings, cached counts, bytes read back, and the chunk count on the store after publish.
  - Trace: scenario/staged, content/demand_paging, scenario/staged_groups.
- **Whole-file adoption.** A whole-file write *renames* the source into staging: the staging file disappears, and its mtime becomes the published mtime (photos keep their capture time). A later byte write splits it into slots. Trace: scenario/staged, frontends/android.
- **What queues an upload.** Only close queues one. WriteAt, Truncate and StageWrite queue nothing. Staged edits survive a cache wipe, and restart recovery publishes them. Trace: scenario/base.
- **Staged-body hygiene.**
  - Deleting a staged file removes its bodies.
  - Startup reclaims bodies no manifest names, and never live ones.
  - The staged tree is never counted against the cache cap or swept by it.
  - Trace: scenario/base, content/cache_cap.
- **Promotion is atomic to readers and writers.**
  - While staged bodies are promoted to content-named groups:
    - concurrent readers always get full-length, exact bytes;
    - alternating whole-file writes never publish a mixed body.
  - Replaying a promotion after a crash uploads 0 bytes. A write inside the promotion window invalidates the pending promotion.
  - Trace: content/promote_race, scenario/staged.
- **Reads fetch only what they touch.** Residency is the chunk store itself, not a separate record. A cached body deleted underneath is re-fetched. Trace: content/demand_paging.
- **Read-ahead.**
  - None until a stream looks sequential.
  - Then: the current group plus **exactly one** group ahead.
  - Each stream (descriptor) keeps its own place: a probe elsewhere in the file does not reset a sequential reader.
  - Trace: content/read_ahead, content/demand_paging.
- **Fetch bounds.**
  - A download slot is taken **before** the destination is opened, so open files stay within slots plus a small constant.
  - A single read's pieces are bounded by a per-read pool, independent of the download budget.
  - Range reads use their own pool, so a range read is served even while prefetch holds the whole download budget. A read never waits behind a whole-group fetch in flight.
  - Trace: content/fetch_fanout, content/read_fanout, unit/demand_ranges, content/chunk_cache.
- **Chunk cache contract.**
  - Concurrent fetches of one group make one request and credit their bytes once.
  - Groups are content-addressed.
  - Slow stores fill a group per member by range, recording which members are present in a sidecar. The sidecar disappears once the group is complete.
  - A partly filled group counts as **not local**: presence of a file is not enough.
  - Fast stores fetch the whole group on first touch.
  - A missing chunk surfaces the store error, names the key, and caches nothing.
  - Trace: content/chunk_cache, content/partial_local.
- **Cache cap.**
  - Eviction is by coldest last access; a read refreshes access.
  - Pinned content (restore, or an explicit fetch) is spared and does not count against the cap. A pin has a deadline, and a lapsed pin is swept.
  - An evicted body is re-fetched on the next read. A partial body goes with its sidecar, so a read never returns a hole.
  - The footprint is a running count, not a directory walk.
  - Availability of a file is online-only, cached or pinned.
  - *Carried by:* counts, availability states, and bytes read back.
  - Trace: content/cache_cap, content/chunk_cache, scenario/ipc.
- **Staged bodies enter the cache by hard link.** The link is idempotent, and is refused when the lengths differ. Trace: content/chunk_cache.
- **Partial file fetch (the File Provider range contract).**
  - The destination file holds the range **at its true offset**, with a hole before it, and stops where the range stops.
  - Only the touched chunks become local.
  - Past-end ranges are short, and a range entirely past the end still produces a file (of size 0).
  - Staged edits and grow holes are served from staged state.
  - Trace: content/fetch_range, e2e/macos.
- **Materialisation progress.**
  - Progress is continuous and monotone, with no gaps. The total covers fetch plus reassembly.
  - It is reported for cached and staged files too.
  - Overlapping materialisations of one file share one progress row.
  - Pulling rows credit bytes that crossed the wire, once, and expire when idle.
  - Trace: content/download_progress, content/pulling.
- **Cold reads have a deadline.** An uncached read with the link down fails within `read_deadline` rather than hanging. With a long deadline it is answered when the link returns, and the next read comes from cache with no store calls. Trace: scenario/read_offline.
- **Lazy browse.**
  - On a device that has never synced, listing a folder fetches that folder only, and folder ids are recovered from the store.
  - A remote delete prunes the mirror.
  - Local unpublished creations survive a browse, and local unpublished removals are not listed back.
  - Trace: frontends/android_lazy, scenario/lazy_owed.
- **Listing agrees with open.** After a rename, only the new name is listed and resolvable (the Syncthing `.tmp` → final pattern). Trace: scenario/rename_listing.
- **Folder index.**
  - A folder listing is cached as an index that is invalidated per child etag.
  - A caller that may not write never writes it.
  - A domain where a read could land on two stores does not use it.
  - A folder id resolves to a path through an index derived from markers. The index is not self-repaired at lookup: an explicit rebuild fixes it and prunes stale entries.
  - Depth has no fixed cap, and cycles answer "none".
  - Trace: unit/folder_index, unit/folder_ids.

### A4.5 Operations and configuration

- **Config validation.**
  - Unknown keys fail at every level. Backend fields are checked against what the driver declares.
  - Backend roles are `main`, `replica`, `readOnly` and `backfill`; the read order follows role and then config order.
  - A domain needs a main, or must consist only of readOnly stores, in which case it is read-only.
  - `link` names a network link: default `wan`, trimmed, not allowed on a local store, and every configured link must be used.
  - `uplink` and per-link overrides:
    - `enabled`, `headroom` in (0,1], `targetDelayMs`, `minRate` ≤ `maxRate`;
    - sizes accept integers or suffixed strings, and `parse_size` accepts whatever the size printer emits.
  - Defaults: `maxChunkBuffers` defaults to `maxUploads`; the mount defaults to `$HOME/tsync/<name>`.
  - *Carried by:* accept or reject per input, and parsed values.
  - *Incidental:* error wording.
  - Trace: unit/conf.
- **Import.**
  - An existing key is skipped **even when the content differs**. `--force-rehash` republishes, re-uploads chunks missing from the store, and picks up changed content.
  - Filters apply at any depth, and parents of excluded-only content are not created.
  - Empty folders are imported.
  - Symlink policies:
    - keep: stored as a symlink, dangling ones included;
    - follow: dereferenced, with broken links skipped and counted;
    - skip: skipped and counted.
  - Files are walked in global sorted path order, with the listing spilled to disk so memory is not proportional to file count.
  - Progress per file sums to its size.
  - Trace: scenario/import_export, unit/import_listing, unit/import_progress.
- **Export.**
  - Exported files have exact bytes and mtime.
  - A dirty file exports its **published** version and is listed as pending.
  - A rerun reads 0 chunks.
  - Resume:
    - an interrupted file keeps its full sparse length plus a record of the chunks that landed, and the next run fetches only the rest;
    - a changed upstream file restarts from scratch;
    - a corrupt chunk fails only its own file.
  - Placement: a file lands under its leaf, a folder under its own name. Two sources onto one name are refused.
  - The domain cache is untouched, and concurrency is bounded.
  - The record format is a header line of identity fields plus one decimal chunk index per line. It is believed only when the identity and the destination size match, and is read up to the last valid line.
  - Trace: ops/export, unit/export_record, scenario/import_export.
- **Copy planning (rsync-like).** For each (source, target) pair the planner picks exactly one decision:
  - skip: identical, source missing, target is a dir, target is not a dir, or not in a domain;
  - make a dir;
  - rename in domain (for `--move`);
  - copy manifest (domain → domain, **zero bytes moved**);
  - upload, fresh or replacing;
  - assemble;
  - patch local, with only the differing chunk indices.
  
  Every decision is reachable. A live run against a real domain confirms that a domain-internal copy moves 0 B. Trace: unit/rsync_plan, live/rsync.
- **Share links.**
  - A share is a manifest at `tsync/shares/<token>`:
    - `{"v":1,"domain","type":"file"|"dir","key"|"folderId","filename","expires"}`;
    - the filename is the leaf, or `<domain>.zip` for a folder.
  - It is written to a member directly, so it works on read-only domains.
  - It is refused when no member advertises a share URL.
  - Clearing the share cache removes only cache objects.
  - Trace: unit/share.

### A4.6 Backends: store contract, composition, failover, deferred targets, link governor

- **Driver contract** (every real driver, run against real S3 and GCS in CI):
  - put/get round-trip, including chunk-sized bodies.
  - `get_opt` and `head_opt` return none when the key is absent, and `head_opt` reports the exact size.
  - `copy` works.
  - `list_prefix` returns everything under the prefix, and respects `max_keys`.
  - `get_many` answers every key once, in order, pages through 300 keys, and reports absent keys as none.
  - Range reads are exact, short past the end, and none when the key is absent.
  - Racing `put_if_absent` calls produce one winner, and every caller gets the winner's body.
  - `delete` answers true then false. `delete_multi` handles more than about 1200 keys (past the per-request cap), most of them absent.
  - Awkward names round-trip: `& <> " ' + %2F # ? space unicode`.
  - `verify_all` queues one job per shard (4096). A `discard` request lands at the GC-job key and decodes to exactly the keys.
  - Trace: conformance, backends/claim, backends/get_range.
- **Local store durability.**
  - A put writes a temp file, fsyncs it, and **renames** it into place. `put_if_absent` does the same but **links** into place.
  - The losers of a claim leave no temp files.
  - A watcher on an object's directory wakes on a write or rename-in, and is not woken by *reads*: scratch space lives outside watched directories, which prevents a self-wake loop (see memory note *watch-reports-own-scratch-loop*).
  - Trace: backends/durable_writes, backends/local_watch.
- **Retry and health.**
  - Errors are classified. Transient: 5xx, network, unknown exceptions. Permanent: 403, not-writable, a backend "no".
  - Transient errors are retried up to a limit. Permanent errors and cancellation are tried once.
  - Health model:
    - Two failures in a row trip a member to *held*. A permanent "no" is not a link failure.
    - A held member is not asked.
    - When a hold expires, **exactly one** concurrent caller probes. A failed probe doubles the hold up to a cap.
    - A success clears the hold.
    - A request cancelled by its caller's deadline is not a failure, and leaves no background retry running.
  - Trace: backends/backend_failure, unit/health, backends/held_failover.
- **Composite read/write policy by role.**
  - Writes go to mains only.
  - A main miss is authoritative. Replicas serve reads only when the main is unreachable; archives are consulted after a main miss.
  - A miss while any consulted store is down is an **error, never "absent"**. With everything down, the main's error is the one reported.
  - An archive-only domain reads and lists, and writes fail with "no writable backend".
  - Trace: backends/fallback.
- **Failover while the main is held.**
  - Reads and batches go to the replica without asking the main.
  - A long poll does not probe the main.
  - With no replica, a held main is still asked.
  - Trace: backends/held_failover.
- **Main-first writes.**
  - A replica is never written while the main is offline: the write is refused as transient, naming the main.
  - A write the main did not take records no job for the replica.
  - A deferred job carries no body and re-reads it from the main.
  - Verify passes on a replica are refused while the main is offline.
  - Trace: backends/main_down, backends/write_guard.
- **Deferred (replica and backfill) targets.**
  - A job is recorded durably **before** the write returns.
  - A transient failure is retried. A permanent refusal drops the job and marks the target degraded ("needs mirror").
  - After a restart the target starts stopped with its jobs intact. Writes made meanwhile are recorded, and draining preserves op order.
  - A stop mid-copy leaves the job owed.
  - A replica receives the journal and cursor; a backfill target does not, and is never read.
  - A backfill rename is applied as copy then delete. A copy whose source the target lacks is rebuilt from the main.
  - Missing chunks are pushed with their manifest. Presence is learned by one listing per shard, so there are 0 HEADs.
  - A rate governor may drop chunk forwards; the manifest job then fetches the missing chunks.
  - Trace: backends/deferred*, backends/backfill.
- **Traffic accounting.**
  - Only bytes crossing a link count, and a local store counts nothing.
  - A lost claim counts the upload plus the winner's body coming back.
  - A put through a composite with two mains counts twice.
  - Counters are per store and summed per process.
  - Trace: unit/backend_traffic.
- **Batching and bounds.**
  - Batches degrade to per-key reads on a permanent batch failure. A transient failure propagates.
  - Batch count and byte caps hold.
  - Per-key fallback is bounded by a pool.
  - A composite never takes a second slot for the member it forwards to, since that deadlocks.
  - Bounded pools: peak width equals the max exactly; `max=0` serialises; a bounded wait queue refuses excess without consuming a slot; the first failure stops a worker set.
  - Per-domain pools are not multiplied by a second instantiation.
  - Trace: unit/batched, unit/batch_nesting, unit/bounded, unit/chunk_pools.
- **HTTP client.**
  - Connections are kept alive: 10 requests over 1 TCP connection.
  - The timeout is an **idle** timeout, not a total one: a slow trickle survives, and silence fails.
  - Trace: backends/http_reuse, backends/http_stall.
- **HTTP-proxy backend client.**
  - A permanent answer (409) is not retried; 5xx answers are.
  - A failed capability probe is not cached.
  - `watch` sends `wait=30` and `last_seen`, and enforces a floor against peers that do not long-poll.
  - An unsupported batch (404) is remembered.
  - Trace: backends/proxy_permanent, backends/proxy_watch_client.
- **Diagnostics probes are bounded and cached.**
  - A member that never answers is reported unreachable with a timeout reason.
  - Repeated status queries within the cache window make 0 store calls.
  - A held main costs 0 calls and is reported `mainOffline`.
  - Trace: backends/probe_deadline, unit/status_cost, unit/status_held.
- **Uplink rate governor.** This is a control law and is tested as one, on a fake clock.
  - **Token bucket with debt.**
    - Depth = rate × burst.
    - A body larger than the depth is admitted when the bucket is full, and the debt is paid down before anything else passes.
    - An in-flight window of rate × stall-timeout × safety. A single body always goes alone.
  - **Queue order.** FIFO waiters. Small bodies may overtake a queued chunk, but only up to that chunk's size.
  - **Control law.**
    - Start in estimating, doubling while ramping.
    - Settle to 0.6–0.85 of capacity with delay under target.
    - Yield to foreign traffic, and recover.
    - A timeout halves the rate and holds.
    - Configured min and max clamp the rate.
    - Growth requires demand.
    - Base delay is tracked per path.
  - **Lease splitting across processes.**
    - The owner keeps a floor, and wanting lessees share the rest.
    - A lessee's grant is 1.25× its use.
    - A newcomer gets total/3 at once.
    - Rows expire after 3 intervals.
  - **Modes.**
    - A lessee falls back to local after 3 silences or one refusal, and returns to leased when the daemon answers again.
    - Links are governed independently.
  - *Carried by:* numeric bounds and states.
  - *Incidental:* exact constants beyond the stated ranges.
  - Trace: unit/uplink*, unit/backend_capped.

### A4.7 Daemon, queues, lifecycle, CLI and status

- **Durable work queues.**
  - Records persist across restart, and adopt is idempotent.
  - An unparseable record is discarded, and marks the queue **degraded** (a mirror is needed).
  - An unreadable one is kept and left alone. One that vanished was completed elsewhere, and is skipped silently.
  - A queue log held by a live process is not run by another; after the holder dies it is taken over, and jobs run in order, once.
  - A queue whose jobs never finish warns that it is stalled.
  - Trace: work/*, unit/queue_claim.
- **Pause and stop.**
  - Pause holds posts, and **drain overrides pause**.
  - Stop without shutdown drains. Stop after shutdown returns within a bound, leaving records on disk for the next start.
  - `drain_for_stop` abandons a stuck drain at its grace period, without cancelling it.
  - A stop request wakes long sleeps immediately. Stop hooks run once.
  - A retry ladder stops at shutdown without counting a failure.
  - Child processes get TERM, and KILL after the grace period.
  - The IPC server removes its socket and returns within 1 s.
  - SIGTERM with a file held open in the mount stops the daemon on its own.
  - Trace: scenario/pause, unit/queue_stop, unit/drain_for_stop, unit/shutdown, unit/fork_reap, unit/ipc_serve, e2e/linux.
- **Queue accounting.** Pending is counted in files. In-flight entries are listed FIFO. Bytes owed are whole-file bytes, in-flight included. A folder rename shows as a folder with 0 bytes. Trace: scenario/queue_bytes.
- **Status report as data.**
  - Top level: host, domains, processes, jobs, warnings.
  - A domain carries its settings, cache (chunks, bytes, pinned), WAL counts by state, frontends and backends.
  - A backend carries:
    - role and config, **with secrets masked `***`**;
    - reachability, latency, error;
    - journal entries and how many are behind: our own entries are never "behind", and keys compare bare, without the month directory;
    - corruption checked or not;
    - disk space;
    - deferred queue state.
  - Processes are deduplicated by pid, and jobs likewise.
  - Warnings are folded by (level, message) with a count, first and last seen, and per-source counts.
  - Store totals are opt-in and never block a reply: a request starts counting, answers with an estimate first, then the exact figure.
  - Collecting frontend status asks exactly the named domain's frontend. When nothing is listening, it reports the frontend unreachable after a short timeout.
  - *Carried by:* the fields and their values.
  - *Incidental:* the text rendering: layout, padding, phrasing, unit formatting. The text form's content rule is that a row states its fact, and zero-valued qualifiers ("0 dropped") are omitted.
  - Trace: frontends/http_proxy, unit/status_*, scenario/ipc.
- **Jobs.**
  - A long command reports itself as a job, including when no daemon is listening.
  - Its progress has total, skipped, done, handled and remaining. The ETA comes from the run's rate and is absent before anything settles and after completion.
  - A dead pid's running job disappears, while a finished or failed one stays. A re-report replaces the pid's row.
  - Trace: unit/job, unit/job_registry, unit/progress_eta, e2e/linux.
- **IPC server semantics.**
  - Invalid JSON is answered `{"ok":false,"code":"invalid","error":"invalid JSON"}`; that exact text is a contract with the Android app.
  - An unknown action is refused, naming it.
  - `stop` is acknowledged, and requests the stop exactly once.
  - Subscriptions:
    - a connection may subscribe to a topic, after which it carries only events, in publish order;
    - publish returns its delivery count;
    - a subscriber that disconnects is dropped.
  - Trace: frontends/http_proxy, unit/subs.
- **CLI.**
  - Shell completion offers domains and in-domain paths; folders end in `/`. Every offer is accepted by the command.
  - `export` accepts the `Domain:` and `--domain` spellings and refuses mixed domains.
  - `ls` shows leaf rows: availability, name, size, and dirs with a trailing `/`.
  - Path commands find their domain's own socket.
  - Trace: unit/completion, unit/export_cli, unit/ls_listing, e2e/linux.
- **Linux desktop integration.**
  - tsync mounts are recognised from mountinfo only when both hold:
    - the type is `fuse.tsync`, or `fuse.sshfs` with source `tsync`;
    - the mount is at a configured domain mount point.
  - `\040` decodes to a space.
  - The tray menu model:
    - icon state: sync, paused, error;
    - a tooltip summary;
    - per-domain rows, and at most 5 file rows per list;
    - totals, with the rate omitted when zero;
    - a "Hold changes" toggle, disabled when the daemon is unreachable.
  - It is served as JSON rows `{label, enabled, indent, action}`.
  - Trace: unit/desktop_mounts, unit/menu, unit/fuse_subtype.
- **Memory bounds.** These are stated per item, independent of scale:
  - walking a tree: bounded peak and retained memory per entry;
  - mirroring: bounded per object;
  - upload: bounded per chunk;
  - a memory-mapped table: a small fraction of a heap table.
  
  A rewrite must keep bounds of this shape; the word counts themselves are incidental. Trace: unit/walk_fanout, unit/mirror_pools, unit/upload_fanout, unit/hashtbl_mmap, unit/import_listing.

### A4.8 Frontends (portable ones: FUSE, HTTP proxy, share server)

- **The engine seen by a frontend.**
  - A presenting host keeps the upload queue and cursor flusher running.
  - Its stats expose pending and completed uploads, pending metadata, degraded, unapplied entries with a reason, and its maintenance schedule:
    - mirror temp files, staged orphans, export records: on demand;
    - applied log: every 86400 s;
    - chunk cap: after each upload and every 60 s;
    - deferred rescan and metadata retry: every 60 s.
  - Trace: frontends/presenting_domain.
- **HTTP proxy server.**
  - **Authentication.**
    - HMAC over method, path **including the query**, body and timestamp.
    - Any tampering fails, and so does a timestamp outside the skew window.
  - **Routes.**
    - `GET /o/<key>`.
    - A range read requires both `offset` and `length`: one of them alone, a negative offset, or a zero length is a bad request, **never widened to the whole object**.
    - `GET /chunk-size?prefix=`.
    - `POST /children-multi` (capped folder count), `/get-multi`, `/delete-multi`.
    - A long poll `?wait=` (capped at 30) with `last_seen`.
  - **Domain scoping.**
    - A batch is authorised by its first key, and every key must fall within the same domain, so one secret cannot read another domain sharing the bucket.
    - A domain's side prefixes (corrupted, verify-jobs, gc-jobs) belong to it.
    - Share keys go to the route that serves shares.
  - **Read-only routes** refuse writes with 403, but still accept share writes.
  - **Data gate.**
    - Gets and puts are bounded (for example 4).
    - Metadata is unbounded.
    - A wait queue of 16× the bound; beyond that, refusals that consume no slot.
  - **Long poll.**
    - A client already behind is answered at once, with one store read against the store's *current* value.
    - An up-to-date client gets 204 at the deadline.
    - N waiters on a change cost N+1 store reads, not more.
    - A watched answer carries `x-tsync-watched`.
  - **Status endpoints** answer 401 unless signed.
  - Trace: frontends/http_proxy, frontends/proxy_bound, frontends/proxy_watch.
- **Share server.**
  - A token must be hex.
  - An unknown token, or another domain's, → 404. An expired one → 410. A path containing `../` → 400. A missing file → 404.
  - File shares:
    - `content-disposition: attachment` with an RFC 5987 filename;
    - `accept-ranges`;
    - single ranges and suffix ranges → 206; an unsatisfiable range → 416 with `bytes */size`.
  - Folder shares:
    - list returns `{dirs, files:[{name,size}]}`;
    - a file is served inline, or as an attachment with `dl=1`;
    - `download` streams a zip whose members are prefixed `<domain>/`, directories included, with no content length.
  - Reads are bounded (16 slots).
  - Serving writes nothing to the mirror, and its bytes go through the shared chunk cache.
  - Trace: frontends/share_server.
- **Streaming zip.**
  - Every entry is stored with a data descriptor, flags `0x0808` (descriptor plus UTF-8), and a ZIP64 extra field in the local header.
  - The central directory carries the real CRC, sizes and Unix modes.
  - The archive ends with ZIP64 EOCD, a locator, and a classic EOCD holding real counts.
  - `unzip -t` accepts it, and extraction is byte-exact.
  - *Carried by:* validity and the extracted bytes. The byte-exact dump pins the layout, which is specification only insofar as standard unzip tools must accept it.
  - Trace: unit/zip.
- **FUSE mount (real).**
  - Work in the mount reaches the store and is seen by a peer: create, edit, `cp`, mkdir, delete.
  - A peer's create, edit, delete, folder create and rmdir appear in the mount.
  - A folder a peer renames **keeps its reference**.
  - Sharing by reference or by path serves exact bytes.
  - The mount's listing equals the peer's listing.
  - `rm -rf` through the mount empties the store.
  - `statfs` on a proxy-backed mount reports effectively unbounded space (2^50 blocks of 4 KiB).
  - Trace: e2e/harness, e2e/linux.
- **Convergence under load and crashes (stress).** Two mounts, concurrent workers, dedup-heavy bodies, and random SIGKILL of a client or the store. After settling:
  - both trees are identical;
  - nothing is listed but unreadable;
  - every path's content is legal for the ops acknowledged on it;
  - every chunk a manifest names exists.
  
  Trace: e2e/stress.

### A4.9 macOS (File Provider) — boundary behaviour only

- A 4 KiB read at 20 MiB of a 40 MiB remote file must be served by range fetches totalling less than the file, and **no** whole-file materialisation. Trace: e2e/macos.
- The replica passes the system consistency check. Trace: e2e/macos.
- Thumbnails: a real image yields an image. A non-image body named `.png` yields none, because the name cannot make it an image. Text yields a rendered preview. A missing body yields none. Trace: frontends/preview.

### A4.10 Android — boundary behaviour only

- **One-shot verbs need no daemon state.**
  - Verbs: `create delete fetch list mkdir open read rename request residency rmdir share stat status write-whole`.
  - Every one of them is exercised by the test, which is its guard.
- **Item JSON.**
  - `ref, parentRef, name, kind, size, mtime, etag, isUploaded`, plus `availability` for files.
  - A dir has size 0, mtime 0 and its id as etag. The root is named after the domain, with etag `.tsync-root`.
  - `stat` puts the fields at top level; mutations wrap them in `item`.
  - Refusals are `{"ok":false,"code":"not_found"|"internal"|"invalid","error"}`.
- **Ranged reads.**
  - `read(ref, dest, off, len)` writes the bytes into `dest` at `off`, so separate processes can reassemble a file. A read past the end is short.
  - A long-lived `open` session answers `{"ok":true,"size"}`, then, per `"<off> <len>"` line, a JSON header with `length` followed by exactly that many raw bytes.
- **Paging.** `list(ref, after, limit)` pages by name.
- **In-process bridge** (the same requests made directly from the app's process):
  - `write` with `await` replies only after the upload drained.
  - Handles report errors as negative errno values: `-9` after close, `-2` for an absent file.
  - Concurrent reads from foreign threads return exact bytes.
- Trace: frontends/android, frontends/android_bridge. The Android app's own unit tests (CLI protocol, keys, descriptors, backup planning, photo naming, upload records) sit under `android/**/src/test` and are covered by the Android spec.

## A5. Assertion discipline a rewrite's harness should keep

These rules are why the harness is built the way it is. Each one exists because its absence once let a suite pass while testing nothing (see memory note *tsync-test-harness-blind-spots*).

1. **Count what ran.** A counted-check suite declares how many checks it makes, and fails when a different number ran. A fixture that stops producing work would otherwise print "0 failures". Live and conformance suites **exit 2** when they have no credentials or config, rather than passing.
2. **Wait for what a step expects, never for a duration.** A bounded poll on the expected state returns without failing at the bound, so the snapshot shows what was there instead. "Held" states must keep holding for a short window. Drain waits on queue emptiness and on the cursor flush, not on a timer. Read-ahead settling fails instead of hanging.
3. **Count round trips, not time.** "Offline costs 0 calls" is checkable under any load; "offline is fast" is not.
4. **Human-readable output is a snapshot, never a substring check.** A substring pins only the fragment its author thought of. A whole-block diff shows layout drift to a reviewer. Values and properties still use counted checks.
5. **The state dump runs even after a step fails,** so a golden file can pin a failure (`ERROR …`, `<unavailable: …>`).
6. **Observations that could read as "nothing wrong" must distinguish "did not look".** A corruption listing prints its count and the stores nothing checks. GC prints its verify line only when it verified something. A verify request on a store that cannot verify answers "unsupported".
7. **Doubles must not have side doors.** A double declares no batch, no fast read and no local path, so "down" means down.
8. **Scratch directories are unique per process and wiped on entry,** so concurrent runs never meet. (Four tests still hard-code a `/tmp` path; see A6.)
9. **A negative control before trusting a green run.** Plant the failure and see the suite go red. Never promote a negative-control run's output to a golden file.

## A6. Blind spots and questionable pinned behaviour

**Behaviour the suite does not reach**

- **Reads do not verify chunk hashes.** Corrupted bytes are returned by plain reads. Only verified fetch, `gc --verify` and repair rehash. The corruption snapshot pins scrambled content as what a reader gets.
- **Resync compares sizes only.** A same-size scrambled chunk is never re-copied.
- **Grouped partial edits are never published in a scenario.** Only close queues an upload, and the grouped-cache scenarios never close. Promotion with cache groups is covered only at the pure staged layer.
- **The poller's timer, the frontend dispatch of changed keys, and the running daemon's start and stop** are not exercised by scenarios. `Sync` is one direct pass, and the scenario's stop does nothing. Only e2e covers the whole daemon.
- **POSIX through a real mount** covers create, overwrite, cp, mkdir, rm and `rm -rf` only. There is no rename, chmod, symlink, truncate or partial write through the mount, and no concurrent access in e2e/linux. Stress covers renames within a flat namespace only, and does not judge renamed paths.
- **Conformance** does not cover `watch`, `list_many`, `list_prefix` page boundaries, or the local and HTTP-proxy drivers.
- **The http-proxy and share-server handlers are called directly.** No socket or router is involved, and multi-range, `If-Range` and ETag are untested.
- **Missing coverage**:
  - corruption detection on the read path;
  - which entries the known-chunks memo evicts;
  - automatic cache-cap triggering;
  - backoff timing and jitter;
  - directory fsync after rename;
  - cross-process `put_if_absent` races (they are simulated in one process).
- **Stalling links in backend tests.** Backend failover and write-guard tests use doubles that refuse or hang. None uses the stalling (outage) double except for probes.

**Pinned outcomes a rewrite should question, not copy blindly**

| Pinned outcome | Why it is questionable |
|---|---|
| An rmdir racing an add inside the folder: the added file survives only inside the trashed folder | this is loss from the user's view, and contradicts "lose nothing" |
| Rescued adds from a removed folder are flattened to the root | subfolder structure is lost |
| Rename vs rename of one file keeps both names | duplication rather than a conflicted copy; stale comments promise a conflicted copy |
| Stale folder markers remain after conflicts (d2, d4) | harmless only because of the anchor rule |
| Trash anchors survive `expire all` and `purge` | possibly a leak |
| Revert does not version the content it replaces | the replaced content can be lost |
| A symlink's tree etag equals another file's name-hash prefix | looks accidental |

**Stale comments contradicted by golden files**

- The sync race scenarios promise conflicted-copy names that do not appear.
- Import/export says export "fills the cache", and it does not.
- The resync step doc says it "prints copied keys", and it prints counts.
- A stats scenario titled "cache filled" pins `cache=0`.
- The runner comment says folder ids are "deterministic, RNG seeded per scenario, printed raw", while the code aliases them because they are random.

**Weak or vacuous assertions**

- **Suites that print checks but never call the count report**, so only the golden diff catches a failure:
  - unit: bounded, cursor_watch, folder_ids, item_ref, subs, queue_claim;
  - frontends: proxy_bound, proxy_watch.
- **Suites that report without an expected count**: completion, manifest_memo, sweep_scope (0 checks), fetch_fanout, pulling, queue_stall, known_chunks.
- **Environment-dependent zeros**: a missing `lsof` makes fetch_fanout's open-file count read 0. The `/proc/self/fd` count reads 0 off Linux (export). `fallocate` being unsupported makes reserve pass trivially.
- **Hard-coded scratch paths collide under concurrent runs**: chunk_cache, promote_race, staged, rename_listing, and several unit tests.
- **Constant checks**: job's "does not raise" checks are the constant `true`.
- **Two-client ordering depends on mint time.** Journal order in two-client snapshots reflects when entries were minted, and the cursor is "whatever the last writer stored". A rewrite with different minting could reorder lines without being wrong.

**Load-sensitive tests** (they fail under CPU contention regardless of the change under test; see memory note *tsync-load-sensitive-tests*)

- **Known and measured**:
  - content/download_progress: needs at least 3 samples *during* an operation;
  - unit/import_listing: a heap live-words threshold;
  - scenario/sync: its first scenario `foreign_put` loses B's tree and content lines, with the backend dump correct;
  - scenario/pause and scenario/queue_bytes: the queue is sampled one step early;
  - scenario/meta_offline.
  
  CI measurements put these at a few percent of runs under load on Linux, never on macOS. The first move is a rerun. An A/B against main is next, and only if the rerun fails the same way.
- **Timing-margin tests**:
  - queue_stall, fetch_fanout, read_fanout, read_ahead, read_offline;
  - progress_eta (real clock), fork_reap, drain_for_stop, cursor_debounce (real 0.5 s timer), demand_ranges, batch_nesting, ipc_serve, http_stall, local_watch;
  - chunk_cache's 5 s timeout.
- **Memory thresholds measured in managed-heap words**:
  - walk_fanout (which must be the process's first listing), mirror_pools, upload_fanout, hashtbl_mmap, bigstring, import_listing.
  
  These translate to "bounded per item" in a rewrite, not to the numbers.

**Races on count lines.** A golden line that counts requests, or orders two queues' publishes, is a race under load: read-ahead, and upload versus metadata queue. The fix is to assert a count above 0, or to sequence the queues with a metadata-only drain.

## A7. Open questions

- Is losing an add to a trashed folder (d1) intended, given the "lose nothing" principle? The golden file says yes.
- Should resync compare content (hash or etag) rather than size, given that scrambled chunks exist as a pinned case?
- Are trash anchors after expiry meant to be kept (as a tombstone that stops a stale marker from resurrecting) or collected?
- The "held" frontend switch and the pause switch are tested separately. Is their interaction (hold while paused, drain while held) specified anywhere?

---


---

OCaml implementation notes for this subsystem: [ocaml/09-tests.md](ocaml/09-tests.md).
