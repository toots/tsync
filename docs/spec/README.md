# tsync — system specification

This directory specifies tsync precisely enough to rewrite it from first principles in another
language. It describes abstractions, contracts, persistent formats, algorithms and failure
semantics, not the OCaml code. The spec was extracted from the tree at commit `4c32fa96`.

- **This directory (`docs/spec/*.md`)** is the language-neutral specification. A Rust or C
  rewrite needs only these files.
- **`docs/spec/ocaml/`** holds the OCaml implementation notes: what the current code learned,
  split into lessons that survive any OCaml runtime and lessons tied to Lwt and the
  functor-over-concurrency pattern (with their OCaml 5 effects/domains translation). Each note
  points back to the spec concept it implements.
- **[findings.md](findings.md)** lists the inconsistencies and likely bugs found while
  extracting the spec, each with a verdict from a second, adversarial reading of the code.
  A rewrite should decide on each rather than copy the current behaviour.

Source references (`path:line`) point into the tree at that commit and will drift.

---

## 1. The problem

tsync mounts storage the user controls as a folder that only downloads what is opened. The storage
can be an S3 or GCS bucket, a local disk or NAS, or another tsync machine serving it over HTTP. It
is the iCloud Drive / Dropbox Smart Sync experience, pointed at the user's own storage.

The folder behaves like any folder: every application works on it, and nothing needs learning.
Only opened files use local space; evicting one frees the space and keeps it listed. Several
machines mount the same storage and see each other's changes. Some things a folder has no verb for
(versions, eviction, public links, bulk import/export, garbage collection) are CLI commands.

The hard constraints that shape everything:

1. **The storage is dumb.** A backend offers `put / get / get_range / head / delete / copy /
   list_prefix` and exactly one conditional write, `put_if_absent`. There is no server logic, no
   transactions, no rename, no notifications (except where a driver can emulate a wait).
2. **Machines never talk to each other.** The backend is the only shared medium. A change is
   announced by writing to the store, and discovered by reading it.
3. **Offline is normal.** Every local operation must succeed without the network and be published
   later, surviving crashes and restarts in between.
4. **The user's data is never lost.** When two machines disagree, both versions survive (a
   conflicted copy, or version history for the loser of a last-resort overwrite).
5. **Everything scales past memory.** Trees and keyspaces are streamed or spilled to disk; working
   sets are bounded by construction, never by a larger pool.
6. **Each OS presents files its own way** (FUSE on Linux, File Provider on macOS, DocumentsProvider
   on Android, HTTP for other tsync clients). The core must not care which.

## 2. Design principles

These cut across every subsystem. A rewrite that drops one will reintroduce the bugs it removed.

| Principle | Consequence | Spec |
|---|---|---|
| **Content addressing.** A file is cut into fixed-size chunks named by a hash of their bytes. | Dedup within a domain; an unchanged chunk is never re-sent; any reader can verify any chunk against its name. | [02](02-remote-model.md), [01](01-core.md) |
| **Folders are named by stable ids, not paths.** | Renaming a folder rewrites one object; item references survive renames; macOS never sees a subtree re-identified. | [02](02-remote-model.md), [08](08-frontends.md) |
| **The local mirror is the whole answer for names.** | `stat`/`readdir`/`lookup` never touch the network; a name the mirror lacks does not exist. | [04](04-checkout-cache.md), [08](08-frontends.md) |
| **Write locally, publish later, record intent first.** | A write-ahead log (WAL) record precedes every mutation; queues do the backend half; startup reconcile finishes whatever a crash interrupted. | [04](04-checkout-cache.md), [03](03-journal-sync.md) |
| **An append-only journal plus a cursor hint.** | Each published change is an immutable journal entry; a single cursor object tells peers to look. Peers dedupe on "every entry handled", never on "entries after the cursor". | [03](03-journal-sync.md) |
| **Best-effort conflicts.** Resolve immediately; lose nothing; conflicted copies when in doubt; winner-takes-all only as a last resort. | Two pure decision tables (a peer's change arriving; this client's change publishing to a store that moved on). | [03](03-journal-sync.md) |
| **Unpublished data lives in a store nothing else can reach.** | The cache cap, resync and eviction cannot delete staged bytes, because they are in a different store, not because a filter spares them. | [04](04-checkout-cache.md) |
| **One owner per rule.** | Naming rules, the error vocabulary, role→behaviour mapping, and per-machine roles (converger, resumer, link owner) each have exactly one owner. | all |
| **A composite of stores is itself a store.** | Callers never know whether they face one bucket or five; roles (main, replica, backfill, archive) are applied inside the composite. | [06](06-backends.md) |
| **Bounded by construction.** | Every fan-out has a width the code chooses; slots are taken before the resource; streams spill to disk. | [01](01-core.md), [05](05-ops-config.md) |
| **Correct with no graceful stop.** | Every operation's state is on disk; Android is killed without warning and must still converge at next start. | [07](07-daemon-cli.md), [android](frontends/android.md) |

## 3. Glossary

| Term | Meaning |
|---|---|
| **domain** | One mounted tree: a name, a set of backends with roles, a set of frontends, per-domain policies. |
| **backend / store** | An object store holding a domain's objects. A domain's **composite** store combines its members. |
| **role** | What a backend is for: `main` (source of truth, gets every write), `replica` (full copy filled in the background, can serve reads), `backfill` (lazily filled copy), read-only archive. |
| **logical key** | A domain-relative path, as the user sees it. |
| **stored key** | Where the store files an object: chunk keys by content hash; manifests by `<folder id>/<hash of leaf name>`. |
| **chunk** | A fixed-size slice of a file body (default 8 MiB), keyed by two XXH3-64 digests of its bytes. |
| **manifest** | The small binary object describing one file version: size, chunk size, chunk keys, digests. |
| **folder id** | A stable random id minted when a folder is created; its children are filed under it. |
| **folder marker / anchor** | The objects that place a folder id under its parent, and settle which of several markers is real. |
| **mirror** | The local projection of the domain's namespace: a manifest per file and a marker per folder, filed by real path. |
| **chunk cache** | Local, content-addressed chunk bodies, partially filled on demand, capped with LRU eviction and pins. |
| **staged** | Unpublished local writes (manifests and bodies). The sole copy of the user's data until uploaded. |
| **WAL** | The write-ahead log of owed work: one record per mutation, with states Intent → Prepared → Executed. |
| **journal entry** | An immutable object on the store listing the ops one client published, keyed by time and a uuid. |
| **cursor** | One store object naming the newest journal entry; a debounced hint that peers should look. |
| **applied log** | The local, positional log of every journal entry handled. It is also the change feed frontends read. |
| **converge** | Reconcile + journal polling + maintenance for a domain. Exactly one process per machine does it. |
| **frontend** | One way of presenting a domain on a host: `fuse`, `file_provider`, `http-proxy`, `android`. |
| **host** | A process type that instantiates the core: daemon parent, frontend child, one-shot command, embedded app. |
| **item reference** | How non-FUSE callers name items: `root`, `d:<folderId>`, `f:<parentFolderId>/<leaf>`. |
| **uplink** | The upload link governor: admits writes at a rate chosen from measured queueing delay. |

## 4. Architecture

### 4.1 Layers

Dependencies point downwards only. A layer may use any layer below it.

```
 ┌───────────────────────────────────────────────────────────────────────────────┐
 │ Hosts & native shells                                                         │
 │   Linux: daemon + FUSE, tray, Dolphin plugin   macOS: app + File Provider ext │
 │   Android: app embedding the core              http-proxy server              │  10, 11
 ├───────────────────────────────────────────────────────────────────────────────┤
 │ Frontends: frontend descriptor · shared request handler (JSON actions)        │  08
 ├───────────────────────────────────────────────────────────────────────────────┤
 │ Daemon & CLI: process model · launcher · domain engine · IPC · status · stop  │  07
 ├───────────────────────────────────────────────────────────────────────────────┤
 │ Whole-domain ops: import · export · rsync · mirror · resync · expire · gc ·   │  05
 │                   integrity · share                                           │
 ├──────────────────────────────┬────────────────────────────────────────────────┤
 │ Sync: WAL replay · queues ·  │ Checkout: mirror · chunk cache · staged ·      │  03, 04
 │ poller · conflict tables     │ WAL · file operations · folder-id index        │
 ├──────────────────────────────┴────────────────────────────────────────────────┤
 │ Remote model: manifests · chunk upload/download · inode tree · journal store  │  02
 │               · versions/trash · GC collection spaces · corruption markers    │
 ├───────────────────────────────────────────────────────────────────────────────┤
 │ Domain config: schema · validation · Domain Context · role → behaviour        │  05
 ├───────────────────────────────────────────────────────────────────────────────┤
 │ Backends: store contract · drivers (local, s3, gcs, http-proxy) · composite · │  06
 │           health · deferred replica/backfill jobs · write guard · uplink      │
 ├───────────────────────────────────────────────────────────────────────────────┤
 │ Foundation: names & keys · chunking & hashing · durable queue · retry ·       │  01
 │   health breaker · bounded pools · IPC framing · spill/listings · platform    │
 │   facts · the runtime interface                                               │
 └───────────────────────────────────────────────────────────────────────────────┘
```

The whole-domain ops sit above checkout and sync because they are *applications* of those layers:
nothing depends on them except the CLI and the request handler, which is what lets each op run
without a daemon.

### 4.2 Subsystem specs

| # | Spec | Owns |
|---|---|---|
| 01 | [Foundation](01-core.md) | Key and name formats; fixed-size chunking and XXH3 keys; durable queue; retry, health, bounded pools; IPC framing; listings and spills; platform facts; **the runtime interface** (capabilities R1–R8 and guarantees G1–G7). |
| 02 | [Remote data model](02-remote-model.md) | Backend key layout; manifest (`tsyncm03`) and folder index (`tsyncidx1`) byte formats; folder markers and anchors; upload/download pipelines; tree walks; versions, trash, retention; mark-by-move GC. |
| 03 | [Journal & sync](03-journal-sync.md) | Journal entry and cursor formats; outbound publish sequence; inbound poller; applied log; the Arrival and Publish conflict tables. |
| 04 | [Checkout & cache](04-checkout-cache.md) | Local cache layout; mirror; chunk cache (partial bodies, read-ahead, cap, pins); staged tree; WAL; **the file-operation interface** frontends call; folder-id index. |
| 05 | [Config & whole-domain ops](05-ops-config.md) | Config schema and validation; the Domain Context; role → behaviour; import, export, rsync, `tsync mirror`, `tsync sync` (resync), expire, gc, integrity, share. |
| 06 | [Backends](06-backends.md) | The store contract every backend implements; the composite and roles; health and failover; deferred jobs; write guard; server-side work as a capability; the uplink governor's implementation. |
| 07 | [Daemon & CLI](07-daemon-cli.md) | Process model; per-host composition; start order; stop and grace; IPC wire contract; every CLI command; status and diagnostics. |
| 08 | [Frontends](08-frontends.md) | The frontend contract: descriptor, shared request handler (actions, item rows, errors, anchors, paging), launcher and stop protocol. |
| 09 | [Tests as acceptance](09-tests.md) | How to read golden files (semantic vs incidental); harness seams and doubles; simulated failures; invariants by subsystem. |

Every subsystem spec has the same shape: problem, concepts and formats, interface, algorithms,
interactions, concurrency and failure semantics, design rationale, test-pinned invariants, open
questions.

### 4.3 Implementations of the two plug-in seams

The store contract (06) and the frontend contract (08) each have several implementations. Each has
its own spec, which says how it realises the contract and where it deviates.

| Backend driver | | Frontend | |
|---|---|---|---|
| [local](backends/local.md) | a directory or mounted NAS | [fuse](frontends/fuse.md) | Linux FUSE mount, plus Linux desktop integration |
| [s3](backends/s3.md) | AWS S3 and S3-compatible services | [file-provider](frontends/file-provider.md) | the macOS app, extension and daemon side |
| [gcs](backends/gcs.md) | Google Cloud Storage | [http-proxy](frontends/http-proxy.md) | serving stores to other clients, share links, status page |
| [object-store-common](backends/object-store-common.md) | the shell and bucket functions s3 and gcs share | [android](frontends/android.md) | the Android app embedding the core |
| [http-proxy](backends/http-proxy.md) | another tsync machine; owns the wire protocol | | |

### 4.4 Abstract specifications

These describe a data structure or an algorithm independently of how the current code encodes
or implements it. Each ends with one table mapping the abstraction to the current implementation.

| Spec | Subject |
|---|---|
| [data-model/backend.md](data-model/backend.md) | What a domain stores on its backend: entities, relations, invariants, ownership, and the arbitration of folder identity. |
| [data-model/local-cache.md](data-model/local-cache.md) | What one client keeps locally per domain: which entities are the only copy and which are rebuildable, and who may write each. |
| [algorithms/wal-and-journal.md](algorithms/wal-and-journal.md) | The replication protocol: WAL, publishing, discovering and applying peers' changes, crash recovery, retention, guarantees. |
| [algorithms/conflict-resolution.md](algorithms/conflict-resolution.md) | The best-effort principle, both decision tables in full, where every byte ends up, and a property-based test plan. |
| [algorithms/durable-queue.md](algorithms/durable-queue.md) | The durable queue, and crash/restart immunity across the whole application. |
| [algorithms/failure-model.md](algorithms/failure-model.md) | One classification of failures and the rules for propagating and responding to them at each layer. |
| [algorithms/replication.md](algorithms/replication.md) | Several stores with roles presented as one: write and read paths, write guard, repair, guarantees. |
| [algorithms/read-path-and-cache.md](algorithms/read-path-and-cache.md) | Materialising bytes on demand from chunks, read-ahead, and bounding the local cache. |
| [algorithms/gc.md](algorithms/gc.md) | Mark-by-move garbage collection against writers that know nothing of it, and the retention that precedes it. |
| [algorithms/uplink-governor.md](algorithms/uplink-governor.md) | Pacing uploads from measured queueing delay, and sharing a link between processes. |
| [algorithms/security-model.md](algorithms/security-model.md) | Actors, trust boundaries, assets, threat model, and each security mechanism as a protocol. |

### 4.3 The seams

These are the abstract interfaces a rewrite must reproduce. Everything else is internal to a
subsystem.

| Seam | Implemented by | Consumed by | Spec |
|---|---|---|---|
| **Runtime interface** — tasks, resolvable promises, catch/finally, join, timers with cancellable races, mutex/condition, positioned file I/O, blocking-I/O offload | the event loop binding (today Lwt) | everything with concurrency | [01 §3.1–3.2](01-core.md) |
| **Store** — `put`, `get`, `get_range`, `put_if_absent`, `head`, `delete`, `delete_multi`, `copy`, `list_prefix`, `watch`, batched reads, `discard`, `verify_all`, capabilities, health | local, s3, gcs, http-proxy drivers; **and the composite** | remote model, ops, sync, frontends | [06 §3](06-backends.md) |
| **Domain Context** — a domain's config, paths, limits, composite store, members | the config builder | every subsystem above config | [05 §2.4](05-ops-config.md) |
| **Remote** — content store, manifest store, tree reader, journal store, history, chunk space, corruption | remote model | checkout, sync, ops, share server | [02 §3](02-remote-model.md) |
| **File operations** — read, write, truncate, create, write-whole, close, delete, mkdir, rmdir, rename, symlink, evict, ensure-cached, assemble, fetch-range, revert, apply-foreign-ops, kind, stat, list-children | checkout (full mirror or lazy) | frontends, request handler, sync | [04 §3.5](04-checkout-cache.md) |
| **Request handler** — JSON actions over item references, one error vocabulary, paging and change-feed anchors, per-frontend hooks | the daemon engine | IPC sockets, macOS extension, Android bridge, CLI, tray, Dolphin | [08 §A3](08-frontends.md), [07 §3](07-daemon-cli.md) |
| **Frontend descriptor** — availability, serving mode and topology, tree kind, commands, option spec | fuse, file_provider, http-proxy, android | the launcher | [08 §A2.1](08-frontends.md) |
| **Link admission** — admit an upload of N bytes; own or lease the link rate | the uplink governor | every store's write path | [06](06-backends.md) |
| **Host bridge** — check config, boot, request, status, open/size/read/close, log sink | the embedded core | the Android app | [android §A4](frontends/android.md) |

## 5. Hosts: one core, several compositions

The same core is instantiated by several process types. They differ in which engine role they
build and which per-machine roles they hold. Three roles must have **exactly one holder per
machine** at a time:

- **converger** of a domain: reconcile, journal poller, maintenance sweeps. It writes the mirror,
  the applied-through mark and the staged tree, which nothing else arbitrates.
- **resumer** of deferred replica/backfill work left by previous runs.
- **link owner**: the uplink governor that grants rate shares to other processes.

| Host | Engine role | Resumer | Link | Checkout | Lifecycle |
|---|---|---|---|---|---|
| Daemon parent (`tsync start`) | converges every domain | yes (the only one) | owner | full mirror | runs until signalled; drains within a grace |
| FUSE child (one per domain) | presents | no | lessee | full mirror | forked by the parent |
| http-proxy child | presents; re-exports each domain's composite store to remote clients | no | lessee | full mirror | forked by the parent |
| File Provider child (macOS, all domains) | presents | no | lessee | full mirror | forked by the parent |
| One-shot command (`import`, `gc`, …) | as the command needs; never polls | its own jobs only | lessee, else local | full mirror | runs to completion, drains, exits |
| Embedded app (Android) | upload queues + maintenance; **no poller** | no | local | **lazy** (folders read on open) | lives and dies with the app process |

Frontend children never converge, and the parent never presents. The parent tells frontends
about applied peer changes with `changed` notices on their sockets; macOS then pulls the
change feed from the applied log.

Full details: [07 §3.8](07-daemon-cli.md) (composition and start order), [06 §5.1](06-backends.md)
(store building per host), [03 §5.1](03-journal-sync.md) (who converges), [file-provider](frontends/file-provider.md),
[android §A2](frontends/android.md).

## 6. End-to-end flows

**Open a file that is not cached.** Frontend `read(ref, offset, len)` → file operations resolve the
name in the mirror (no network) → the file's manifest (staged or published) → the chunk pieces
covering the range → the chunk cache fetches only those byte ranges from the composite store →
bytes are written into a sparse cache body with a partial-record → returned. Sequential reads
trigger read-ahead of the next chunk group. ([04 §4](04-checkout-cache.md), [02](02-remote-model.md))

**Write and close a file.** Writes land in a staged body (never in the cache) with a staged
manifest → on close a WAL `Put` record is written → the upload queue cuts chunks, skips chunks the
store already has, uploads the rest under link admission → commit record → the staged body is
promoted into the cache by hard link → the manifest is published under its folder id → a journal
entry is written (noted in the applied log first) → the cursor is bumped (debounced) → the WAL
record is dropped. Replicas receive the manifest only after all its chunks.
([04](04-checkout-cache.md), [03 §4](03-journal-sync.md), [06](06-backends.md))

**Create a folder offline.** WAL intent → the folder and its marker are created locally with a
freshly minted folder id → the metadata queue retries until online → the id is claimed on the store
with `put_if_absent` → the journal entry is published. ([04](04-checkout-cache.md),
[02](02-remote-model.md))

**A peer's change arrives.** The converger waits on the cursor (store-specific: a sleep for
S3/GCS, a directory watch for local disk, a long-poll for http-proxy) → lists the journal when the
cursor moved or a periodic sweep is due → skips every entry already in the applied log → for each
new entry, in key order: read what it needs from the store *first*, then under the metadata lock
decide with the Arrival table (moving its own unpublished copy aside if they clash) and write the
mirror → note the entry → notify frontends. ([03](03-journal-sync.md))

**Reclaim space.** `expire` drops references (old versions, trash, old journal entries) → `gc` opens
a run marker, moves candidate chunks into a collection space, lets concurrent writers "promote" any
chunk they reference back, and deletes what is left; every phase is resumable.
([02 §4](02-remote-model.md), [05](05-ops-config.md))

**A laptop mounts through a server.** The laptop's backend is an `http-proxy` driver. Each request
is HMAC-signed with the shared secret and confined to its domain. The server answers from its own
composite store (applying its own replicas, health and roles), coalesces cursor long-polls into one
watch per key, and can also serve public share links. ([06](06-backends.md),
[08](08-frontends.md))

## 7. Concurrency model

The spec states what the logic needs from a runtime in neutral terms
([01 §3.1–3.2](01-core.md)). Today's implementation runs one cooperative, single-threaded event
loop per process, with blocking I/O offloaded to a thread pool.

That choice silently guarantees something a rewrite loses: **nothing else runs between two
statements that do not yield.** Pools, queues, health tracking, memo tables, counters and
debouncers change shared state without locks because of it. A rewrite with real parallelism
(threads, Rust multi-threaded async, OCaml 5 domains) must lock that state. Each spec lists its
own instances in a §6.1 table: [01](01-core.md), [02](02-remote-model.md),
[03](03-journal-sync.md), [04](04-checkout-cache.md), [05](05-ops-config.md),
[06](06-backends.md), [07](07-daemon-cli.md), [08 §A6](08-frontends.md).

Separately, several processes share one domain's on-disk state. Which process may write what is a
per-machine role (§5), not a lock; see [findings.md](findings.md) for where that is not airtight.

## 8. Persistent formats

Anything written to the store, to disk, or onto a wire is a compatibility contract between
clients and releases. Where each is specified:

| Format | Where |
|---|---|
| Chunk keys, shard layout, logical/stored key escaping, item references | [01 §2](01-core.md) |
| Backend key layout, manifest (`tsyncm03`), folder index (`tsyncidx1`), folder marker, anchor, trash marker, GC run marker, corruption marker, version keys | [02 §2](02-remote-model.md) |
| Journal entry keys and bodies, cursor, applied log, last-sync mark, WAL record states, conflicted-copy names | [03 §2](03-journal-sync.md) |
| Local cache tree, staged sidecar, partial-body records, pins, WAL records, folder-id index | [04 §2](04-checkout-cache.md) |
| `config.json` schema, export resume record, share manifest, gc job keys | [05 §2](05-ops-config.md) |
| Store contract errors, deferred-job log, http-proxy wire protocol and HMAC canonical string, uplink lease JSON | [06](06-backends.md) |
| IPC line-JSON: envelope, error codes, actions, item rows, anchors and paging cursors | [07 §2–3](07-daemon-cli.md), [08 §A2](08-frontends.md) |
| macOS extension↔daemon verbs and event formats | [file-provider §A4](frontends/file-provider.md) |
| Android bridge encodings | [android §A4](frontends/android.md) |

## 9. Using this spec for a rewrite

A workable build order, each step testable against [09](09-tests.md) before the next:

1. Foundation: key and chunk formats (check against the known-answer vectors in 01), durable
   queue, bounded pools, retry, health.
2. The store contract and the local driver, then the composite with roles.
3. The remote model: manifests, upload/download, folder ids and markers, tree walks.
4. Checkout: mirror, chunk cache, staged tree, WAL, file operations.
5. Journal and sync, with both conflict tables, driven by the multi-peer scenario harness.
6. Config and the Domain Context; then the whole-domain ops.
7. The daemon: process model, request handler, IPC, stop semantics.
8. Frontends and hosts, one at a time; remote drivers (S3, GCS, http-proxy) and the uplink governor.

The golden files in `tests/` pin facts, not formatting. [09 §A1](09-tests.md) says which parts of
each snapshot a rewrite must reproduce and which it may re-baseline.
