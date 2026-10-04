# tsync — system specification

This directory is the specification of tsync: the single source of truth for how it behaves. It
defines abstractions, contracts, persistent formats, algorithms and failure semantics precisely
enough to implement tsync from first principles in any language.

- **The spec** is every file in this directory and its subdirectories, except `ocaml/`. It is
  normative and language-neutral.
- **[`ocaml/`](ocaml/README.md)** holds notes about the OCaml implementation: how it maps onto the
  spec, where it departs from it, and what it learned. They are descriptive, not normative.

## Conventions

- The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are used as in RFC 2119.
- Each rule is stated once, in the file that owns it; other files link to it.
- Constants are named parameters with a recommended value; a range is given where safety depends on
  it. Every file ends its normative part with a **Conformance** section: the observable properties
  an implementation MUST exhibit. [09](09-tests.md) says how conformance is checked.
- Internal concurrency, pool sizes and memory strategies are left to implementations. Only limits
  another party can observe are specified.

---

## 1. The problem

tsync mounts storage the user controls as a folder that only downloads what is opened. The storage
can be an S3 or GCS bucket, a local disk or NAS, or another tsync machine serving it over HTTP. It
is the iCloud Drive / Dropbox Smart Sync experience, pointed at the user's own storage.

The folder behaves like any folder: every application works on it, and nothing needs learning.
Only opened files use local space; evicting one frees the space and keeps it listed. Several
machines mount the same storage and see each other's changes. Some things a folder has no verb for
(versions, eviction, public links, bulk import/export, garbage collection) are CLI commands.

The constraints that shape everything:

1. **The storage is dumb.** A store offers `put`, `get`, `get_range`, `head`, `delete`, `copy`,
   `list_prefix` and exactly one conditional write, `put_if_absent`. There is no server logic, no
   transaction, no rename and no notification (except where a driver can emulate a wait).
2. **Machines never talk to each other.** The store is the only shared medium. A change is
   announced by writing to the store and discovered by reading it.
3. **Offline is normal.** Every local operation succeeds without the network and is published
   later, across crashes and restarts.
4. **The user's data is never lost.** When two machines disagree, both versions survive: a
   conflicted copy, or version history for the loser of a last-resort overwrite.
5. **Stored data outlives implementations.** Data written to a store, and the state a machine keeps
   locally, MUST be usable as-is by any conforming implementation: no migration, no conversion
   step. Formats are defined generally enough that data already written is valid under them.
6. **Each OS presents files its own way** (FUSE on Linux, File Provider on macOS, DocumentsProvider
   on Android, HTTP for other tsync clients). The core does not depend on which.

## 2. Design principles

| Principle | Consequence | Owner |
|---|---|---|
| **Content addressing.** A file is cut into fixed-size chunks named by a hash of their bytes. | Dedup within a domain; an unchanged chunk is never re-sent; any reader can check a chunk against its name. | [01](01-core.md) |
| **Folders are named by stable ids, not paths.** | Renaming a folder rewrites one object; item references survive renames. | [data-model/backend](data-model/backend.md) |
| **The local mirror is the whole answer for names.** | `stat`, `readdir` and `lookup` never touch the network; a name the mirror lacks does not exist. | [04](04-checkout-cache.md) |
| **Record intent, act locally, publish later.** | A WAL record precedes every mutation; queues do the store half; recovery finishes whatever a crash interrupted. | [wal-and-journal](algorithms/wal-and-journal.md) |
| **An append-only journal plus a cursor hint.** | Each published change is an immutable journal entry; one cursor object tells peers to look. Peers deduplicate on "every entry handled", never on "entries after the cursor". | [wal-and-journal](algorithms/wal-and-journal.md) |
| **Best-effort conflicts.** Resolve immediately; lose nothing; conflicted copies when in doubt; winner-takes-all only as a last resort. | Two pure decision tables: a peer's change arriving, and this client's change publishing to a store that moved on. | [conflict-resolution](algorithms/conflict-resolution.md) |
| **One local owner per domain.** | On a machine, one process at a time owns a domain's local state; every other process acts through it. | [07](07-daemon-cli.md) |
| **Durability before acknowledgement.** | Nothing is acknowledged, or relied on for recovery, before it is durable; a referent is durable before its referrer. | [durable-queue](algorithms/durable-queue.md) |
| **Unpublished data lives in a store nothing else can reach.** | The cache bound, eviction and a rebuild cannot delete staged bytes. | [04](04-checkout-cache.md) |
| **One failure model.** | Every layer classifies failures the same way; "could not look" is never reported as "absent". Decisions rest on signals the application owns (locks, records, protocol replies), never on a third party's error code, which is platform-dependent. | [failure-model](algorithms/failure-model.md) |
| **A composite of stores is itself a store.** | Callers never know whether they face one bucket or five; roles are applied inside the composite. | [replication](algorithms/replication.md) |
| **Garbage collection is safe against every writer.** | Any operation that publishes a chunk reference goes through one interlock with the collector. | [gc](algorithms/gc.md) |
| **Names are validated at every trust boundary.** | Keys, domain names and paths passed between processes are checked where they enter. | [01](01-core.md), [security-model](algorithms/security-model.md) |
| **Immutable data may be shared.** | Data never modified in place MAY be passed around as an immutable memory mapping, and SHOULD be. | [01](01-core.md) |
| **Correct with no graceful stop.** | Every operation's state is on disk; a process killed at any point converges at its next start. | [durable-queue](algorithms/durable-queue.md) |

## 3. Glossary

| Term | Meaning |
|---|---|
| **domain** | One mounted tree: a name, a set of backends with roles, a set of frontends, per-domain policies. |
| **store / backend** | An object store holding a domain's objects. A domain's **composite** store combines its members. |
| **role** | What a member store is for: `main` (source of truth, takes every write), `replica` (full copy filled behind the write, may serve reads), `backfill` (copy filled lazily), `readOnly` archive. |
| **core data / ephemeral data** | Core data (chunks, manifests, folder markers, anchors, trash entries, versions, journal entries, the cursor) is the domain's content and history. Ephemeral data (collection state, job objects, corruption markers, shares, the folder index) serves operations and can be recreated. |
| **logical key** | A domain-relative path, as the user sees it. |
| **stored key** | Where the store files an object: chunks by content hash, manifests by folder id and a hash of the leaf name. |
| **chunk** | A fixed-size slice of a file body, keyed by two XXH3-64 digests of its bytes. |
| **manifest** | The object describing one file version: size, chunk size, chunk keys, digests. |
| **content identity** | The whole-file digest `h1` of a manifest; equal content has equal identity. Frontends see it as `contentId`. |
| **folder id** | A stable id minted without coordination when a folder is created; its children are filed under it. |
| **folder marker / anchor** | The objects that place a folder id under its parent, and settle which of several markers is real. |
| **owner** | The one process on a machine that owns a domain's local state, converges it and serves its request interface. |
| **ownership lock** | The per-domain lock an owner holds for its lifetime. |
| **supervisor** | An optional per-machine process that starts owners and holds machine-wide resources (the uplink governor). It owns no domain state. |
| **store server** | The process that serves a machine's stores to other tsync machines over HTTP; it owns no domain state. |
| **mirror** | The owner's local projection of the domain's namespace, filed by real path. |
| **chunk cache** | Local chunk bodies, filled on demand, bounded, with pins. |
| **staged** | Unpublished local writes. The only copy of the user's data until uploaded. |
| **WAL** | The write-ahead log of owed work: one record per mutation, with states intent → prepared → executed. |
| **journal entry** | An immutable store object listing the ops one client published. |
| **cursor** | One store object naming a recent journal entry: a hint that peers should look. |
| **applied log** | The owner's log of every journal entry handled; also the change feed frontends read. |
| **converge** | Recover owed work, apply peers' journal entries, run maintenance. Done by the domain's owner. |
| **frontend** | One way of presenting a domain on a host: `fuse`, `file_provider`, `http-proxy`, `android`. |
| **item reference** | How non-FUSE callers name items: `root`, `d:<folderId>`, `i:<fileId>` (a local id kept across renames), or `f:<parentFolderId>/<leaf>`. |
| **uplink governor** | Admits uploads on a network link at a rate chosen from measured queueing delay. |

## 4. Architecture

### 4.1 Layers

Dependencies point downwards only.

```
 ┌───────────────────────────────────────────────────────────────────────────────┐
 │ Frontends and hosts: fuse · file_provider · http-proxy · android              │  frontends/
 ├───────────────────────────────────────────────────────────────────────────────┤
 │ Frontend contract: descriptor · shared request handler                        │  08
 ├───────────────────────────────────────────────────────────────────────────────┤
 │ Process model and CLI: owner · supervisor · IPC · lifecycle · status          │  07
 ├───────────────────────────────────────────────────────────────────────────────┤
 │ Whole-domain operations: import · export · rsync · mirror · resync · expire · │  05
 │                          gc · integrity · share                               │
 ├──────────────────────────────┬────────────────────────────────────────────────┤
 │ Sync: WAL · publishing ·     │ Checkout: mirror · chunk cache · staged ·      │  03, 04
 │ journal polling · conflicts  │ file operations · folder-id index              │
 ├──────────────────────────────┴────────────────────────────────────────────────┤
 │ Remote model: manifests · chunks · folder tree · versions · trash ·           │  02
 │               collection state · corruption markers                           │
 ├───────────────────────────────────────────────────────────────────────────────┤
 │ Domain config and the Domain Context                                          │  05
 ├───────────────────────────────────────────────────────────────────────────────┤
 │ Stores: store contract · drivers · composite and roles · deferred copies ·    │  06, backends/
 │         write guard · uplink governor                                         │
 ├───────────────────────────────────────────────────────────────────────────────┤
 │ Foundation: names and keys · chunking and hashing · time · runtime ·          │  01
 │             retry · health breaker · IPC framing                              │
 └───────────────────────────────────────────────────────────────────────────────┘
```

Whole-domain operations sit above checkout and sync because they are applications of those layers:
nothing depends on them except the CLI and the request handler.

### 4.2 Subsystem specs

| # | Spec | Owns |
|---|---|---|
| 01 | [Foundation](01-core.md) | Name, key and folder-id grammars; hashing, chunking and chunk keys; time rules; resources and immutable data; runtime requirements; retry ladder; health breaker; IPC framing; ZIP64 streaming; glob patterns. |
| 02 | [Remote data model](02-remote-model.md) | Byte-level backend formats and key spellings (core and ephemeral); the remote interface. |
| 03 | [Journal & sync](03-journal-sync.md) | Client identity and leases; journal entry, cursor, applied log and last-sync mark formats; sync interfaces. |
| 04 | [Checkout & cache](04-checkout-cache.md) | Local on-disk formats; the file-operation interface; local behaviour and recovery. |
| 05 | [Config & whole-domain operations](05-ops-config.md) | Config schema and validation; the Domain Context; import, export, rsync, mirror, resync, expire, gc, integrity, share. |
| 06 | [Backends](06-backends.md) | The store contract; the composite interface; the admission seam; uplink configuration. |
| 07 | [Process model & CLI](07-daemon-cli.md) | Roles and ownership; lifecycle; the IPC contract; every CLI command; maintenance. |
| 08 | [Frontends](08-frontends.md) | The frontend contract: descriptor, item references and rows, the request handler, change feed, events. |
| 09 | [Conformance](09-tests.md) | How conformance is checked: tiers, golden files, harness seams, fault and crash injection, property-based conflict testing, required coverage. |
| 10 | [Delivery](10-delivery.md) | Where each tier runs, the gate, builds, releases, secrets. |
| 11 | [Store infrastructure](11-infrastructure.md) | What is deployed around a bucket: client identity, the two functions, their triggers and permissions, lifecycle, outputs, operator state and tooling. Per provider: [aws](infrastructure/aws.md), [gcs](infrastructure/gcs.md). |

### 4.3 Implementations of the two plug-in seams

| Backend driver | | Frontend | |
|---|---|---|---|
| [local](backends/local.md) | a directory or mounted NAS | [fuse](frontends/fuse.md) | Linux FUSE mount, and the Linux desktop integration |
| [s3](backends/s3.md) | AWS S3 and S3-compatible services | [file-provider](frontends/file-provider.md) | macOS File Provider: app, extension and owner |
| [gcs](backends/gcs.md) | Google Cloud Storage | [http-proxy](frontends/http-proxy.md) | the store server, share links and status page |
| [object-store-common](backends/object-store-common.md) | what s3 and gcs share, and the bucket-side functions | [android](frontends/android.md), [android-app](frontends/android-app.md) | the owner embedded in the Android app; the app itself |
| [http-proxy](backends/http-proxy.md) | another tsync machine; owns the wire protocol | | |

### 4.4 Data models and algorithms

| Spec | Subject |
|---|---|
| [data-model/backend](data-model/backend.md) | What a domain stores: entities, relations, invariants, ownership, and folder-identity arbitration. |
| [data-model/local-cache](data-model/local-cache.md) | What an owner keeps locally: what is authoritative and what is rebuildable. |
| [algorithms/wal-and-journal](algorithms/wal-and-journal.md) | The replication protocol: WAL, publishing, discovering and applying peers' changes, recovery, retention, guarantees. |
| [algorithms/conflict-resolution](algorithms/conflict-resolution.md) | The best-effort principle and both decision tables. |
| [algorithms/durable-queue](algorithms/durable-queue.md) | Durable queues, persistence rules, and crash immunity across the application. |
| [algorithms/failure-model](algorithms/failure-model.md) | Failure kinds, propagation, response policy, error codes and deadlines. |
| [algorithms/replication](algorithms/replication.md) | Several stores with roles presented as one: write and read paths, deferred copies, write guard, repair. |
| [algorithms/read-path-and-cache](algorithms/read-path-and-cache.md) | Materialising bytes on demand, read-ahead, and the cache bound. |
| [algorithms/gc](algorithms/gc.md) | Retention, and garbage collection against writers that know nothing of it. |
| [algorithms/uplink-governor](algorithms/uplink-governor.md) | Pacing uploads from measured queueing delay, and sharing a link between processes. |
| [algorithms/security-model](algorithms/security-model.md) | Actors, trust boundaries, threat model, and every security mechanism. |

### 4.5 The seams

| Seam | Implemented by | Consumed by | Spec |
|---|---|---|---|
| **Runtime** — tasks, promises, cancellation, timers, locks, blocking-I/O offload | the event loop or scheduler | everything with concurrency | [01 §6](01-core.md) |
| **Store** — the operations of the store contract, capabilities, health | each driver, **and the composite** | remote model, operations, sync, frontends | [06 §3](06-backends.md) |
| **Domain Context** — a domain's config, paths, composite store and members | the config builder | every subsystem above config | [05 §3](05-ops-config.md) |
| **Remote** — content store, manifest store, tree reader, history, chunk space | remote model | checkout, sync, operations, share servers | [02 §3](02-remote-model.md) |
| **File operations** — the per-item operations frontends need | checkout (full or lazy tree) | the request handler, sync | [04 §3](04-checkout-cache.md) |
| **Request handler** — JSON actions over item references, one error vocabulary, paging, change feed, events | the owner | IPC clients, extensions, the Android bridge, CLI, desktop tools | [08 §3](08-frontends.md), [07 §4](07-daemon-cli.md) |
| **Frontend descriptor** — availability, serving mode and topology, tree kind, commands, options | each frontend | the supervisor and owners | [08 §2.1](08-frontends.md) |
| **Link admission** — admit an upload of N bytes | the uplink governor | every remote store's write path | [06 §6](06-backends.md) |

## 5. Hosts: one core, several compositions

Every host runs the same core; they differ in which roles their processes hold.
[07 §2](07-daemon-cli.md) is authoritative.

| Host | Processes |
|---|---|
| Linux | A supervisor holding the uplink governor; one owner process per domain, which hosts the domain's FUSE mount (or runs headless for a domain with no presenting frontend); at most one store server. |
| macOS | One service process owns every domain, hosts the File Provider side and holds the uplink governor; a sandboxed extension and app are clients of it. |
| Android | The app process owns its domain, with a lazy tree (folders read from the store when opened) and no journal polling; the UI and the DocumentsProvider call it directly. |
| One-shot command | Asks the running owner, or takes ownership for its own duration when none runs. |

The owner of a domain does everything that changes its local state: it converges the domain,
resumes its deferred work, runs its queues and maintenance, and serves its request interface. Every
other process either asks the owner or submits a durable record to one of its logs.

## 6. End-to-end flows

**Open a file that is not cached.** A frontend reads a range → the owner resolves the name in the
mirror (no network) → the file's manifest → the chunk pieces covering the range → the cache fetches
only those bytes from the composite store → the reader gets bytes of the one version it opened.
([read-path-and-cache](algorithms/read-path-and-cache.md))

**Write and close a file.** Writes land in a staged body with a staged manifest → the WAL record is
made durable → the upload queue uploads the chunks the store does not have, under link admission →
the manifest is published under its folder id → the journal entry is published and noted → the
cursor is updated → the WAL record completes. Copies receive the manifest only after its chunks.
([04](04-checkout-cache.md), [wal-and-journal](algorithms/wal-and-journal.md),
[replication](algorithms/replication.md))

**Create a folder offline.** WAL intent → the folder is created locally under a freshly minted
folder id → when online, its placement is claimed on the store with `put_if_absent` and confirmed →
the journal entry is published. ([data-model/backend](data-model/backend.md))

**A peer's change arrives.** The owner waits on the cursor, lists the journal, skips every entry
already handled, and applies each new entry in key order: store facts are read first, then the
Arrival table decides under the local lock, moving an unpublished local copy aside if they clash.
([wal-and-journal](algorithms/wal-and-journal.md),
[conflict-resolution](algorithms/conflict-resolution.md))

**Reclaim space.** Retention drops references (old versions, trash, old journal entries, expired
shares) → a collection moves the chunk space aside, lets every writer promote the chunks it
references back through the publish gate, deletes what is left from the main and then from each
copy, and restores anything a copy still needs. Every phase is resumable.
([gc](algorithms/gc.md))

**A machine mounts through another.** Its store is an `http-proxy` driver. Each request is signed
with the domain's secret and confined to that domain. The store server answers from its own
composite store and coalesces cursor waits.
([backends/http-proxy](backends/http-proxy.md), [frontends/http-proxy](frontends/http-proxy.md))

## 7. Persistent formats

Anything written to a store, to local disk or onto a wire is a compatibility contract.

| Format | Where |
|---|---|
| Key, folder-id and item-reference grammars; chunk keys and shard layout; name escaping; temporary names | [01 §2–3](01-core.md) |
| Backend key layout; manifest; folder index; folder marker, anchor, trash entry; versions; collection run record and generation; corruption markers; job objects; share manifests | [02 §2](02-remote-model.md) |
| Client identity and leases; journal entries; cursor; applied log; last-sync mark | [03 §2](03-journal-sync.md) |
| Local cache tree; staged manifests and bodies; WAL records; pins; folder-id index; pending claims | [04 §2](04-checkout-cache.md) |
| Durable-queue record ids and locks | [durable-queue](algorithms/durable-queue.md) |
| Deferred-job logs | [replication](algorithms/replication.md) |
| `config.json`; export records | [05](05-ops-config.md) |
| IPC envelope, error codes, actions, item rows, anchors, events | [07 §4](07-daemon-cli.md), [08](08-frontends.md), [failure-model](algorithms/failure-model.md) |
| http-proxy wire protocol | [backends/http-proxy](backends/http-proxy.md) |
| Uplink lease messages | [uplink-governor](algorithms/uplink-governor.md) |
| Host-specific state (macOS, Android) | [file-provider](frontends/file-provider.md), [android-app](frontends/android-app.md) |

## 8. Building an implementation

A workable order, each step checked against [09](09-tests.md) before the next:

1. Foundation: grammars, hashing and chunk keys (check the known-answer vectors in 01), time,
   retry, health.
2. The store contract and the local driver; then the composite with roles and deferred copies.
3. The remote model: manifests, upload and download, folder ids and arbitration, tree walks.
4. Durable queues; checkout: mirror, cache, staged tree, WAL, file operations.
5. Journal and sync with both conflict tables, driven by the multi-peer scenario harness.
6. Config and the Domain Context; the whole-domain operations; garbage collection.
7. The process model: owners, supervisor, request handler, IPC, lifecycle.
8. Frontends and hosts; remote drivers; the uplink governor; the store server.

An implementation is ready to replace another on an existing machine when it passes the
conformance item that starts it on existing state with owed work and checks that nothing is
converted and nothing is lost ([09](09-tests.md)).
