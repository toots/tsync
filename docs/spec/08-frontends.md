# 08 — Frontends: the frontend contract

Scope: the frontend seam (`lib/app/frontends/api`), how the launcher runs frontends (`lib/app/cli/launcher.ml`), and the request handler every frontend shares (`lib/app/cli/runner/daemon/engine/{ipc_handler,item_row,ipc_error,domain_engine}.ml`, as far as frontends see it). Everything here is common to all frontends.

Each frontend has its own spec, describing how it realises this contract on its OS surface:

| Frontend | Spec | OS surface |
|---|---|---|
| `fuse` | [frontends/fuse.md](frontends/fuse.md) | Linux FUSE3 mount; also the Linux desktop integration (mount discovery, Dolphin plugin, tray, systemd, packaging). |
| `file_provider` | [frontends/file-provider.md](frontends/file-provider.md) | macOS File Provider: the app, the sandboxed extension, and the daemon side. |
| `http-proxy` | [frontends/http-proxy.md](frontends/http-proxy.md) | HTTP(S) server exposing a machine's stores to other tsync clients, plus public share links and a status page. The wire protocol is [backends/http-proxy.md](backends/http-proxy.md). |
| `android` | [frontends/android.md](frontends/android.md) | Android app embedding the core: DocumentsProvider, in-app browser, share target, camera backup. |

Paths are relative to `/home/toots/src/tsync`.

---


## A1. Problem

A *domain* is a namespace of files whose manifests and chunks live in storage the user controls. The domain core (checkout mirror, chunk cache, staged edits, upload queues, journal replay, convergence) knows nothing about how a user reaches the files. A **frontend** is one way of presenting a domain on one host:

| frontend | OS surface | process shape | tree kind |
|---|---|---|---|
| `fuse` | Linux FUSE3 mount at a directory | one process **per domain** (the mount call blocks) | replicated |
| `file_provider` | macOS File Provider, reached by a separate sandboxed extension over a JSON socket | one process for all domains, one socket | replicated |
| `http-proxy` | HTTP(S) server exposing the domain's *stores* to other tsync clients, plus public share links | one process for all domains on a listener | replicated |
| `android` | Android DocumentsProvider, core embedded in the app process | no daemon: driven only by in-process calls or CLI verbs | **pulled** (lazy) |

Frontends are a separate abstraction for three reasons:
- Every OS has its own filesystem model and threading model.
- Which frontends exist is a build-time fact: FUSE is optional, File Provider is macOS-only, Android exists only in the Android cross-build.
- The rules that must *not* differ between frontends are owned once, by the shared request handler and the file-operations interface. These rules are how items are named, what "staged" versus "published" means, the error vocabulary and the paging contract. Each frontend is a thin translation over them.

A principle applies throughout: the local manifest mirror is the full source of truth for whether something exists. No frontend path may ask the backend for metadata, and frontends never inspect the mirror directly; they call the file operations `kind`, `stat` and `list_children`. The cost it removed: a FUSE getattr for a missing name used to take ~85 ms through a backend round trip, and now takes 0.3 ms.

## A2. Concepts & data model

### A2.1 Frontend descriptor (the seam)

Each frontend registers under a name, and registration is compiled in or out per build. A descriptor holds:

- **name** — `fuse`, `file_provider`, `http-proxy` or `android`. The CLI group defaults to the name; `file_provider` uses `fileprovider`.
- **availability(locality, key) → Online_only | Cached | Pinned(until)** — where a file's bytes are, used by listings (`tsync ls`, item rows). This call is synchronous and filesystem-only.
- **serving**, one of:
  - `Daemon { topology: One_process | Process_per_binding, listens: None | DomainSocket | ProxySocket, start(served list) — blocks until shutdown }`
  - `Commands(refusal_text)` — never run by the launcher; driven by CLI verbs or by an app that embeds the core. The launcher answers `start` with the frontend's own refusal wording.
- **tree** — `Replicated`, or `Pulled(refusal_text)`. A pulled frontend reads a folder only when asked, so there is no replica for a full resync to rebuild; `tsync sync` refuses with the frontend's wording.
- **commands** — `(verb, doc, run(domain_conf, positional_args))`. They appear as `tsync <group> <verb> --domain D`. The binary resolves `--domain` and checks the frontend is configured for it, but does not parse the remaining arguments: only the frontend knows its own grammar.
- **option spec** — the fields `tsync config --edit` prompts for, with name, label, type, default and a secret flag. Secrets are masked in reports.

A **binding** is a triple (domain conf, frontend options from `config.json`, mount point). Only FUSE uses the mount point.

A **served** binding adds two things: the domain wiring built by the launcher (§A3.1), and `peers`, the sockets of the domain's *other* frontends. Only the http-proxy reads `peers`, so its status page can report on the whole domain; an empty list means no other frontend serves the domain on this host.

Registered frontends:

| name | availability | serving | tree | commands |
|---|---|---|---|---|
| fuse | chunk store | Daemon(per binding, DomainSocket) | Replicated | – |
| file_provider | replica-aware: dataless in the system replica → online-only; else pinned if the chunk store says so, else cached | Daemon(one process, DomainSocket) | Replicated | reimport, reset, purge |
| http-proxy | chunk store | Daemon(one process, ProxySocket) | Replicated | – |
| android | chunk store | Commands("…linked into the app, not served by a daemon…") | Pulled | stat, list, read, open, residency, fetch, write-whole, create, mkdir, delete, rmdir, rename, share, request, status |

**Chunk-store availability** is decided in this order:
1. The key has a staged sidecar → `cached`.
2. Otherwise, check whether every chunk is held. A chunk is *held* iff its chunk file exists **and** no partial-chunk manifest sits beside it (a partial one is on disk under the same name).
3. If every chunk is held, the file is `pinned` when its pin file's mtime is ≥ now (a lapsed pin is no pin), else `cached`. If any chunk is missing → `online-only`.

A partly cached file therefore reads as `online-only`. The wire spelling is `online-only`/`cached`/`pinned`, plus `pinnedUntil` (epoch seconds).

### A2.2 Item references

Every non-FUSE caller names items by reference:
- `root` — the domain root. `d:.tsync-root` normalises to root; the root folder id is `.tsync-root`.
- `d:<folderId>` — a directory, by the id minted when it was created. The id is **stable across rename and move**.
- `f:<parentFolderId>/<leaf>` — a file. It is split at the first `/`: neither ids nor leaves contain `/`, but leaves may contain `:`. The reference changes on rename.
- Anything else, including a bare storage key, is malformed and answered `not_found`/`invalid`. A storage key carries no kind, so accepting one would mean guessing.

Why:
- A path is the wrong name for a directory: renaming the directory renames every descendant. The macOS system treats a changed identifier as a merge instruction, so path-named folders turned each folder rename into a silent re-identification of the whole subtree.
- Files have no storage id of their own, so parent-id plus leaf limits a rename's blast radius to one item.
- References reach system logs, so they avoid storage keys and user paths.

Desktop callers that hold only a path (the Dolphin menu, CLI) may send `"rel":"<domain-relative path>"` instead; `""` is the root, and the mirror decides whether the path names a file or a directory.

A file reference can be composed from its parent's reference. A directory reference cannot, because only the core mints folder ids. That is why every mutating reply carries the resulting item.

### A2.3 Item row — one shape for stat, listings and change ops

The fields, in this order:
```
ref, parentRef, name, kind ("dir"|"file"|"symlink"), size, mtime (float seconds), etag, isUploaded
[symlinkTarget] [trashed: true, only when set] [availability [pinnedUntil]]   (availability: files only)
```
- **Directory:** size 0, mtime 0.0, etag = its folder id, isUploaded true. These stay constant for the folder's lifetime, so a watcher is not told a directory changed on every look.
- **Root:** name = domain name, parentRef = `root`, etag `.tsync-root`.
- **File:** etag = the published manifest's content hash (16 hex characters, e.g. `1294bbe85c2f380b`), so identical content gives an identical etag. The etag is `""` while unpublished edits exist, and isUploaded is false while an upload is owed.
- A row whose containing folder has no id on this client cannot be named. It is omitted and counted in an `unnamed` field, never silently dropped.

`stat` puts the row at top level; lists and mutation replies nest it (`items:[…]`, `item:{…}`). Example:
```json
{"ok":true,"ref":"f:9f3a/big.txt","parentRef":"d:9f3a","name":"big.txt","kind":"file","size":24,
 "mtime":1400000000.0,"etag":"1294bbe85c2f380b","isUploaded":true,"availability":"online-only"}
```

### A2.4 Errors

Every socket answers a failure as `{"ok":false,"code":"<code>","error":"<prose>"}`. Clients match on the code, never on the prose.

| code | raised by |
|---|---|
| `not_found` | ENOENT; share not found; "no versions for" |
| `exists` | EEXIST |
| `not_empty` | ENOTEMPTY |
| `denied` | EPERM, EACCES |
| `read_only` | EROFS; store not writable; a mutating action on a read-only domain |
| `unreachable` | backend error; timeout; share store unavailable |
| `invalid` | bad argument; bad or missing field; bad JSON; unknown action |
| `internal` | anything else |

`unreachable` is the only code that tells a client to stop trying; the macOS client latches the domain offline on it. Anything the core cannot place must therefore be `internal`, which is retried: one unexplained failure should cost one operation, not the domain.

### A2.5 Cursors and anchors

- **Change anchor:** `"<generation>|<entry key>"`, for example `"1756600000000|0001756600000-abc"`.
  - `generation` is the content of `<data_dir>/resync-<domain>`: epoch milliseconds, written atomically by `full_resync`. It is `""` if never stamped.
  - `entry` is the last applied journal entry key, or `""` for never synced.
  - The core owns and compares both halves. Clients carry the anchor verbatim, because the sandboxed macOS extension cannot read the generation file.
- **Folder page cursor:** the last *name* served. A resume returns names strictly greater, compared bytewise. It is stateless: a fresh process answers the same page, and items added or removed between pages shift nothing before the cursor.
- **Whole-domain page cursor:** `"<walk>:<line>"`.
  - `walk` is the epoch-ms stamp of a walk and must be all digits. `line` is a 0-based line index.
  - A cursor whose prefix is not all digits (the legacy `<container>/<name>` form) restarts the listing.
  - Lines are used rather than names because one folder id can sit at several mirror paths, so a name cursor could jump between copies and loop forever.
- **Kept walk file:** `<scratch dir of domain>/.tsync-list-all`.
  - Line 1 is `{"walk":"<ms>","skipped":<n>}`.
  - Each later line is one entry, sorted by path, in one of two forms:
    - `{"path":"a/b.txt","container":"<folderId>","kind":"file","size":N,"mtime":F}`
    - `{"path":"sub","container":"<id>","kind":"dir"}`
  - Entries are JSON so a name containing a newline stays on its own line.
  - It is written atomically by a first page, or whenever it is missing (a resync empties the scratch space). It is never invalidated by changes: the change feed covers anything that moves, since the anchor was taken before page 1.
  - A resume against a newer walk continues at the same line, with a warning.

### A2.6 Sockets

- Unix stream sockets carrying **newline-delimited JSON**: one request line, one reply line. A connection may carry several requests. Replies carry no request id.
- Linux has one socket per domain: `$XDG_DATA_HOME|~/.local/share` + `/tsync/tsync-<domain>.sock`.
- macOS has one socket for all domains, inside the app-group container. Requests are routed by a `domain` field.
- `proxy socket`: the http-proxy's own control socket (status and stop only).
- `sync socket`: the launcher parent's socket (uplink lease, `rescan`).
- Linux config lives at `$XDG_CONFIG_HOME|~/.config/tsync/config.json`.

### A2.7 Frontend-specific formats

FUSE mount facts, the http-proxy wire and the share manifest as the share server reads it are specified in [frontends/fuse.md](frontends/fuse.md), [backends/http-proxy.md](backends/http-proxy.md) and [frontends/http-proxy.md](frontends/http-proxy.md).
## A3. Interface

### A3.1 What a frontend is given per domain ("domain wiring")

The launcher hands every frontend process the same wiring for each served domain:

- **File operations**, the full interface owned by the checkout subsystem. Frontends use:
  - `kind`, `stat`, `readlink`, `symlink`
  - `list_children(prefix) → (files with key/size/mtime, subdir names)`, `list_tree(prefix)`
  - `create`, `read(key, buf, offset, stream?) → n`, `write(key, buf, offset) → n`, `truncate`
  - `close(key)` — queue an upload if staged edits exist
  - `delete`, `mkdir`, `rmdir`, `rename(src, dst)`, `evict`
  - `ensure_cached(key, keep?)` — fetch all chunks and pin them, 10 days by default; idempotent, and concurrent calls share the fetch
  - `assemble_to(key, dst)`
  - `fetch_range(key, dst, offset, length) → n` — writes at the same offset and leaves the rest sparse; short only at EOF; creates `dst` even past EOF
  - `write_whole(key, src)` — adopt a file by rename
  - `queue_put`, `cancel_upload`, `resolve` (staged or published), `chunk_residency`, `download_progress`, `uploads_in_flight`, plus counters.
- **The request handler** (§A3.2), built over those operations.
- **Lifecycle:**
  - `start(on_upload_done?)` — ensure the root, then start this process's upload queue and metadata queue.
  - `drain()`, in order:
    1. metadata queue;
    2. upload queue (raced to 0.8 × grace when stopping);
    3. flush the published cursor;
    4. settle pending change notices;
    5. drain backends.
  - `stats_fields()`.

Every process serving a domain runs its **own** upload and metadata queues. Their workers are in-memory, and each posts only what it was handed.

**Convergence is not a frontend's job.** Convergence covers the poller replaying foreign journals into the mirror, reconcile, and the maintenance sweeps. It runs once per host, in the launcher parent, because the mirror, applied bookmark and staged tree are shared between processes and nothing else arbitrates them. The parent tells frontends what changed by sending `{"action":"changed","domain":D,"keys":[…]}` to each frontend socket, batched to at most 512 keys and flushed every 0.2 s.

### A3.2 The shared request handler

A single handler answers requests for the FUSE socket, the File Provider extension, Android and the desktop menus. It is parameterised by per-frontend **hooks**, and these are the only frontend-specific behaviour:

```
hooks {
  evict(key)
  restore(key, keep_seconds?)
  changed(key)          # another process applied a change to key; refresh your view
  full_resync()
  status_fields() -> fields
  stats_fields()  -> fields   # must include frontend:<name>
  on_stop()
}
handler(hooks, request_line) -> (reply_line, Continue | Stop | Subscribe(topic))
key_of_ref(ref) -> key?      # for frontend commands
item_ref(key)  -> ref?
```

The hooks as each frontend fills them:

| hook | fuse | file_provider | android |
|---|---|---|---|
| evict | evict every file of the subtree, each failure logged and skipped | evict chunks, then publish an `evict` event (fails when nobody is subscribed) | evict one key |
| restore | ensure_cached every file of the subtree | ensure_cached, then publish a `restore` event | ensure_cached one key |
| changed | ask the kernel to invalidate `/<rel>` | debounced `changed` event | none (the picker re-queries) |
| full_resync | none (the resync client rebuilt the mirror before signalling) | rebuild the folder-id index, then publish a `resync` event | none |
| status_fields | `mount` | `subscribers` | – |
| on_stop | unmount and stop | none | none |

For the macOS order: the chunk store is acted on first because a pin is the core's promise, which holds whether or not anything is listening to move the system's copy.

**Actions.** The action strings are a wire contract with the native shells and must not be renamed.

| action | request fields | ok reply | mutates |
|---|---|---|---|
| stat | ref\|rel | row at top level. An `f:` ref must not answer for a folder | |
| list_dir | ref\|rel, after?, limit? (1000) | `items`, `next`?, `unnamed`? | |
| list_all | after?, limit? (1000) | `items`, `next`?, `unnamed`? | |
| changes_since | arg=anchor, limit? (512) | `{stale:true}` or `{stale:false, cursor, more, ops}` | |
| cursor | – | `cursor` | |
| ensure_cached | ref\|rel, dest (required) | `localPath`; the core writes the whole file to dest | |
| fetch_range | ref\|rel, dest, offset ≥ 0, length > 0 | `localPath, offset, length` (the served length) | |
| download_progress | ref\|rel | `{active:false}` or `{active:true, bytesDownloaded, totalBytes}` | |
| create | parentRef, name | `item`: empty, staged, etag "", isUploaded false | ✓ |
| write | parentRef, name, staging, await? | `size, mtime, item`. The staging file is adopted by rename (gone afterwards). With await, the reply waits for this key's upload | ✓ |
| mkdir | parentRef, name | `item`; idempotent | ✓ |
| symlink | parentRef, name, target | `item` | ✓ |
| rename | ref, parentRef, name | `item` at the destination. A dir stays a dir and keeps its id | ✓ |
| delete / rmdir | ref\|rel | `{}`; rmdir is recursive | ✓ |
| revert | ref\|rel, arg=version? | `{}`, then `hooks.changed` | ✓ |
| share | ref\|rel | `url` | (not counted: the manifest lives outside the domain) |
| evict / restore | ref\|rel, keep? (restore only) | `{}` | |
| full_resync | – | stamps a new generation, then the hook | |
| status | – | `domain, running, readOnly, paused, pendingUploads, pendingDownloads, uploading[{name,rel,body?,size?}], downloading, pendingBytes`, traffic, hook fields | |
| pause | arg: `"off"` resumes, anything else pauses | `{}` | |
| stats | arg: comma set of `totals, exact, reload, frontend` | full diagnostic report | |
| changed | keys: [domain-relative paths] | `{}`; unknown keys are logged | |
| stop | – | `{}`, then Stop | |
| subscribe | domain (required) | `{}`, then the connection becomes an event stream | |

The handler enforces these rules itself, rather than trusting frontends:
- **Read-only.** The actions marked ✓ are refused with `read_only` on a read-only domain, because a direct request need not honour a frontend's advertised capabilities.
- **Serialization.** Mutating actions for a domain run one at a time; reads run concurrently. A reference is resolved to a path *before* the mutation takes the mirror lock, and the File Provider sends requests concurrently. Without serialization, a folder rename racing a create inside that folder could resolve the create against the old path and drop the file into a folder that no longer exists there.
- **Destinations.** Mutations need `parentRef` and a non-empty `name`. A parent that resolves to nothing gives `not_found`. A parent named by storage key is refused.
- **write.** In order:
  1. Cancel any upload of this key in flight; a write to a file being sent stops the send.
  2. Adopt the staging file.
  3. Queue the put.
  4. Optionally wait until uploaded.
  5. Report the size and mtime of whatever now resolves (staged or published).

**changes_since algorithm:**
1. Split the anchor at the first `|`. If its generation differs from the current one → `{stale:true}`.
2. If neither the anchor's entry nor the applied head exists, or the two are equal → `{stale:false, cursor:anchor(head), more:false, ops:[]}`.
3. Otherwise read up to `limit` entries after the anchor from the *applied* entries log. Because an entry is kept only once applied, an op never names an item the mirror has yet to catch up with. If the anchor is no longer kept → stale.
4. The cursor is the last entry returned, or the anchor itself if the page is empty. Holding at the anchor stops a caller being told to start over.
5. Each op is rendered with the forms below. Ops naming a folder this client has no id for are dropped and counted, not turned into stale: re-listing the whole domain would pay for one folder with every other.
6. Ops are **not** filtered by author. The client id is per machine, so filtering hid CLI changes from the mount.

Op forms:
- `{"op":"put","ref","parentRef","name","item"}` — the item is read from the mirror via the current reference.
- `{"op":"delete","ref","parentRef","name"}`
- `{"op":"mkdir",…,"item"}` — the dir row is built from the id the op carries.
- `{"op":"rmdir","id","ref","parentRef","name"}`
- `{"op":"rename","is_dir","id"?,"srcRef","srcParentRef","ref","parentRef","name","item"}` — emitted only when both ends can be named; a half-reported move loses an item.
- Folder ids resolve through an index that keeps an id after its marker is gone: a removal destroys the marker, and a rename moves it.

**list_all algorithm:**
- *First page:* walk from the root depth-first through `list_children`. A folder with no id is counted once (its subtree cannot be named). Sort by path, stamp the walk, keep it (best effort; a failure to keep is logged), then serve lines 0..limit−1.
- *Later pages:* read the kept file from line n+1; if it is missing, re-walk and skip. The reply carries the next cursor only when one more entry exists past the page.

**list_dir algorithm:** entries are sorted by name and filtered to those strictly after `after`. The page takes `limit` of them plus one extra, which only decides whether `next` is emitted (the last served name).

### A3.3 Launcher contract

1. Group the configured bindings by frontend. **Before forking anything**, refuse any `Commands` frontend with its own wording, so no siblings are left running behind a refusal.
2. Fork one child per frontend group. The core must not start its event machinery before the forks, or a child inherits a shared wakeup descriptor.
3. In each child:
   - name the process;
   - lease uplink bandwidth from the parent over the sync socket;
   - route "replica job recorded" to the parent as a debounced (0.5 s) `{"action":"rescan"}`;
   - size the blocking-I/O thread pool to `min(256, max(32, 8 × Σ(max_uploads + max_downloads)))` over the domains it serves (the figures are per domain and the pool is per process, so they are summed);
   - build the domain wiring and call `start`.
   - For `Process_per_binding`, fork again per binding; the last binding runs in place.
4. The parent converges every domain, serves the sync socket, and on stop drains the domains.

The pool is sized by the caller because threads are never returned once grown: the ceiling becomes a memory floor. At 256 threads, one mount settled at about 114 MB.

### A3.4 Stop protocol

- **Reaper.** A process that forked sends SIGTERM to its children, waits up to grace + 2 s (polling every 50 ms), then SIGKILLs and reaps what is left. It also forwards SIGTERM to its children the moment it is itself asked to stop, so nested forks stop within one grace instead of two.
- **Drain for stop.** Run all drains in parallel, raced against the grace. On timeout, log "owed on disk and resumes at the next start" and return. The drain is not cancelled: a cancelled job would be recorded as a failure against work that was merely unfinished.
- **systemd budget.** systemd's `TimeoutStopSec=30` must exceed the grace.

## A4. Behaviour

### A4.1 Per-frontend behaviour

How each frontend maps its OS operations onto the file operations and the request handler, which hooks it installs, and its caching, lifecycle and error mapping are specified in its own file: [fuse](frontends/fuse.md), [http-proxy](frontends/http-proxy.md), [file-provider](frontends/file-provider.md), [android](frontends/android.md).
### A4.2 What macOS and Android ask of the seam

Both hosts reuse the same domain core and request handler. What differs is in the table below; the app internals are specified elsewhere.

| | macOS File Provider | Android |
|---|---|---|
| Core instantiated | Launcher child, one process for all domains, domain wiring from the launcher, convergence in the launcher parent | In the app process: domain wiring with a **lazy checkout** (§below) in place of the replicated one. The host itself runs init, queue start, reconcile and the maintenance sweeps. No poller, no convergence, no socket |
| Transport | One socket for all domains; the router picks the domain by the `domain` field (the display name). A missing field works only when one domain is served. Adds `menu`, `menu_stats` and `preview` | In-process request call: JSON bytes in, JSON bytes out, through the same handler. Plus a handle API for ranged reads: open(ref) → handle / −errno, size(handle), read(handle, off, len) → n / −errno (a stream per handle, so readers keep separate read-ahead), close |
| Actions used | stat, list_dir, list_all, cursor, changes_since, ensure_cached (dest in a system-chosen directory, written by the core), fetch_range, download_progress, create, write (staging adopted by rename), mkdir, symlink, rename, delete, rmdir, share, evict, restore, status, pause, subscribe | stat, list_dir, share, restore, evict, ensure_cached, create, mkdir, write with `await:true` (a write answers once its own key's upload has gone or started failing), delete, rmdir, rename |
| Hooks | evict/restore publish events to a subscriber (the app) because only that process can move replica content; `changed` is a debounced event; `full_resync` rebuilds the folder index and publishes `resync` | evict and restore act on one key; changed, full_resync and on_stop do nothing |
| Change feed | changes_since + events: `{"event":"changed"\|"evict"\|"restore"\|"resync","domain","id":seq,"ref"?}`. `changed` is debounced to one per 0.2 s burst and names nothing. Events are not replayed | None: the picker re-queries |
| on_upload_done | publish `changed` (upload state is part of the item's version) | none |
| Commands | `reimport` (send `full_resync`), `reset` (write a marker naming the domain, bounce the app), `purge` (marker, wait up to 60 s for the app to clear it, then remove the agent, app and data but keep config) | CLI verbs that answer each request through the same handler: start the queue iff the request mutates, always drain |

**Lazy checkout (`Pulled` tree).** It answers the checkout's listing operations as follows:
- Listing a folder reads that one folder from the store, failing rather than skipping unreadable children. Skipping is ruled out because the listing is then pruned against the answer, and a missing child is not evidence it is gone.
- The result is recorded into the mirror the same way a resync records it.
- Published entries the store no longer names are dropped. Staged entries are kept: they are this client's own.
- An absent entry means "not fetched yet", not "does not exist", and no walk is ever scheduled.

Rationale: a host that cannot hold long-lived state cannot keep a replica. A resync that wiped 36,568 manifests left document ids unresolvable for 25 minutes.

**No daemon on Android.** A long-running service is killed by the platform. Every operation is a function of key and offset whose state is already on disk, and reconcile at the next start publishes whatever is owed. There is therefore no ranged write and no close: whole staged bodies are committed through `write`.

**Swapped per host:** storage paths (HOME and config location), the checkout implementation (replicated or lazy), who runs convergence, the event transport (socket subscribe or none), and the lifecycle hooks.

## A5. Interactions

**Depends on:**
- checkout and file operations;
- upload and metadata queues, and pause;
- journal, applied-entries log and folder-id index;
- the launcher parent's convergence and change notices;
- backends (store interface, capabilities, watch, failure classification) — for the proxy and shares;
- share creation;
- platform runtime paths;
- config parsing and option specs;
- diagnostics, status report and menu rendering;
- metrics and the shutdown signal;
- the line-JSON socket transport with topic subscription.

**Depended on by:** the `tsync` binary (launcher, `tsync <group> <verb>`), `tsync sync` (tree kind), `tsync ls` (availability), `tsync status` (queries every frontend socket), and the native shells.

**Flows:**
- **Linux cold read:** open fetches nothing; read → scheduler → `read` → only the covering chunks are fetched (plus read-ahead) → bytes.
- **Linux write:** open with CREAT/TRUNC → create or truncate; writes land in staged chunk bodies; release → `close` queues the upload.
- **Foreign change on Linux:** the parent's poller applies it → change notice to the domain socket → kernel invalidation.
- **Foreign change on macOS:** notice → debounced `changed` event → the app signals the working set → `changes_since(anchor)`.
- **Remote client:** signed `GET /o/…` → admission → store → bytes.

## A6. Concurrency, durability, failure

**Execution model.** Each process has **one cooperative scheduler**. Foreign threads (FUSE workers, JNI/binder threads, the main thread of a host that owns it) submit a closure and block until it completes. Several places rely on there being **no preemption between yield points**; a rewrite with real threads, or with parallel domains, must add synchronisation at each:

- **FUSE counters** (`openHandles`, `filesOpened`, the release guard) are plain integers, touched only on the scheduler thread.
- **http-proxy state:** the per-outcome tallies and in-flight count are plain integers. The watch gate table relies on atomicity at the moment a gate is dropped: the loop removes the gate when `waiters` hits 0, and a new waiter increments `waiters` and then starts the loop with no yield in between. With preemption, a waiter could attach to a gate that is being removed and never be woken.
- **Watch gates:** each gate's `token` field is written by both the request path and the loop, with no lock.
- **File Provider:** the `changed_pending` debounce flag and the event sequence counter are unguarded.
- **Change notices:** the pending key set and the `scheduled` flag are unguarded.
- **Android:** the handle table (id → key, size) and its counter are unguarded.
- **Share server:** the manifest memo is an unguarded table with clear-when-full.
- **Metrics counters** are plain as well.
- **Handler serialization** is a scheduler mutex. Reads are not serialized against mutations, so reads rely on each mirror read being atomic between yields.
- **list_all's walk** spans many yields and may observe a mirror that changes mid-walk. This is accepted: the anchor was taken first, and the change feed covers the difference.

**Blocking I/O** goes to a separate thread pool: pool threads do blocking syscalls, while scheduler state is touched only on the scheduler thread.

**Durability.** Everything owed is on disk: staged manifests, WAL and durable queue. A stop drains within the grace; what remains resumes at the next start (reconcile).

**Offline behaviour:**
- Metadata operations never reach the backend, so getattr and readdir work offline.
- Reads of uncached chunks need the backend. They should fail fast: a FUSE read waiting on the network with no timeout blocked the cgroup freeze and hung a laptop's suspend.

**Crash leftovers:**
- A stale FUSE mount is cleared at start (`-uz`).
- The socket is removed at stop; the macOS installer also removes a stale one, since a leftover socket makes callers think the daemon is up.

**Idempotence:**
- `mkdir` answers the existing folder.
- Repeating `ensure_cached` extends the pin.
- Clients treat `not_found` on delete as success.
- `write` cancels an upload in flight rather than publishing torn content.

**Event loss** is tolerated: events are hints, and the journal carries the same news.

**Degraded paths:**
- A File Provider `evict`/`restore` with nobody subscribed fails with a message pointing at the app, rather than reporting an eviction that never happened.
- On the http-proxy, share responses themselves are not admission-bounded; only their block reads are (a known ceiling).

## A7. Design choices & rationale

Choices specific to one frontend are in its own spec.

1. **References, not paths**, on every non-FUSE wire (§A2.2).
2. **Frontends declare topology; the launcher forks.** One place decides what runs where, and it can size pools knowing what shares the process.
3. **Convergence lives outside frontends.** It is one writer of shared on-disk state; frontends learn about changes through `changed`.
4. **No backend read below the mirror** on any metadata path.
5. **The core writes materialised files** into the host-chosen directory: the sandboxed consumer may not move files in. **Staging files are adopted by rename**, with no copy.
6. **The core owns the anchor.** Stale only on reimport or a pruned anchor; ops that cannot be named are dropped individually, never turning the batch stale.
7. **Whole-domain paging** uses a kept walk with a line cursor. The consumer's 500-byte cursor cap made client-side frontiers end enumeration silently at about 26 folders.
8. **Error codes, not prose.** Only `unreachable` backs a client off.
9. **Linked-in core on Android, not a process per request.** Per-request processes lost read-ahead state and could not be ordered against the upload queue, whose locks are per process (commits cc90f688, 47040bc1).
10. **Pulled tree for hosts without long-lived state** (661d4974).
11. **Pool ceilings are asked for, not defaulted**, and an event loop that can watch file descriptors above 1024 is mandatory.

## A8. Invariants the tests pin down

Tests of a single frontend are listed in its own spec.

**Frontend tests (`tests/frontends/`):**
- **presenting_domain:** stats field list; a finished upload puts the manifest in the store and publishes the cursor; the maintenance list names each sweep and its triggers.
- **stop_publishes_cursor:** the second cursor bump is held while running and published within the grace at stop.

**Other tests:**
- **tests/scenario/ipc:**
  - Listing, paged and flat views agree.
  - A dirty file has an empty etag and a clean one does not; identical content shares an etag.
  - Files and folders share one name order.
  - A folder that cannot be named is counted, not dropped.
  - A create under a parent named by storage key is refused.
  - `changes_since` for: a foreign put; mkdir then put; delete; rename; rmdir with its id; a move into a folder renamed since; a dir rename with its id.
  - The kept walk survives being dropped between pages and a write between pages; a name containing a newline does not end the listing.
- **tests/unit/item_ref:** reference parsing and round-trip.
- **tests/unit/menu:** a golden snapshot of every menu string and action.

## A9. Open questions / inconsistencies

Questions specific to one frontend are in its own spec. Numbering is kept from the first extraction.

1. **Subtree evict/restore:** FUSE applies evict and restore to a whole subtree; Android and path-based callers apply them to a single key.
7. **Sort order ignored:** `list_dir` always pages by name, whatever sort the consumer asked for; it relies only on a stable order within one enumeration.
9. **One-key hooks on Android:** the Android evict and restore hooks take one key; a folder gesture would need the FUSE subtree walk.

---

OCaml implementation notes for this subsystem: [ocaml/08-frontends.md](ocaml/08-frontends.md).
