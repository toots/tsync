# Android application

Scope: everything under `android/` (Kotlin app module `:app`, pure-JVM module `:core`,
manifest, gradle build), its core-side counterpart `lib/app/frontends/android`
(frontend verbs + `jni/` bridge), and `tests/frontends/android{,_lazy,_bridge}`.
The generic frontend seam (`Frontend.S`, `availability`/`serving`/`tree`, registration,
the request handler vocabulary) is specified in **[the frontend contract](../08-frontends.md)** and only referenced
here.

---


## A1. Problem

tsync on a phone has to do three things the desktop daemon does differently:

1. **Expose a domain to other apps** as browsable, openable, writable documents, without
   a kernel filesystem (no FUSE) and without a system extension (no File Provider). Android
   offers a *DocumentsProvider* (Storage Access Framework, SAF): the system picker calls a
   content provider in the app's process, and the app answers directory listings,
   metadata, and serves file bytes through descriptors it controls.
2. **Survive the platform's process model.** Android kills and freezes processes at will,
   caps foreground-service time (Android 15: `dataSync` services get a few hours a day),
   and reaps exec'd children. A long-lived daemon is therefore the wrong shape
   (`android_frontend.ml:41-48`). The core must be a *library the app's process hosts*,
   whose every operation is resumable from on-disk state.
3. **Feed content in** from the phone: a camera-roll backup, a "Save to tsync" share
   target, and edits made by other apps through the picker.

The Android app is therefore a separate *host* for the same core that the Linux daemon
and the macOS extension host. It is a separate abstraction because it replaces the
frontend, storage locations, lifecycle hooks and background scheduling, and deliberately
leaves out several subsystems (A3).

## A2. Role compared with other hosts

| Aspect | Linux daemon (FUSE) | macOS (File Provider) | Android app |
|---|---|---|---|
| Process | long-lived daemon, per-user | daemon + system extension | the app's own process; lives and dies with it |
| Core reached by | kernel VFS → FUSE callbacks | extension → IPC socket → daemon | host UI/provider → in-process call (bridge) |
| Tree of folders | replicated mirror (`Replicated`) | replicated mirror | **pulled**: a folder is read from the store only when asked (`tree = Pulled`) |
| Remote change poller | yes (converge) | yes | **no** — freshness comes from re-reading a folder when it is opened |
| `tsync sync`/resync | available | available | refused: "nothing for a resync to rebuild" |
| Upload queue | yes | yes | yes, in-process, started at boot |
| Replay/reconcile of WAL at start | yes | yes | yes |
| Periodic maintenance sweeps | yes | yes | yes — the same list, same driver |
| IPC socket served | yes | yes | **no** (`serving = Commands`): no socket; the CLI group `tsync android …` answers one request per process for shells/tests |
| Config editor | `tsync config --edit` | app | app's own one-backend form |
| Sharing links | yes | yes | yes (same `share` action) |
| Symlinks | per config | per config | config forces `symlinks: "skip"` (SAF has no symlink) |

### Subsystems the Android host instantiates (per boot, one domain)

- **Config loading + TLS config** from `<HOME>/.config/tsync/config.json` (see A4.1).
- **Domain engine over the *lazy checkout*** (`Make_over(Lazy_checkout)`): file
  operations (resolve, read with read-ahead, write-whole, create, mkdir, rename, delete,
  rmdir, evict, ensure-cached/assemble, fetch-range, chunk residency), the manifest
  mirror, staged manifests, the write-ahead log.
- **Request handler** — the same JSON action handler the daemon's IPC socket uses
  (see [the frontend contract](../08-frontends.md) and the IPC handler spec), with Android-specific hooks (A5.3).
- **Upload queue (data + metadata)** started at boot, followed by **replay/reconcile**
  of what a previous process left owed.
- **Maintenance driver** (`run_maintenance`): every periodic sweep declared for a domain
  (cache sweeps, chunk cap every 60 s and after each upload, deferred rescan every 60 s,
  metadata retry every 60 s).
- **Diagnostics** fold for a status report (no daemon to ask; the domain is reported
  directly with `frontend: "android"`).
- **Share** (link publishing, 7-day expiry, same as daemon).

### Left out

- The sync **poller / converge** loop (no background pull of remote changes).
- Full resync / mirror rebuild (`full_resync` hook is a no-op).
- The IPC socket server, subscriptions and change notifications to a frontend
  (`changed` hook is a no-op: the client re-queries).
- Symlinks, directory-subtree evict/restore (single key only; FUSE walks a subtree).
- Ranged writes and `close`: the only write is **whole-body adoption** of a staged file.
- Every backend type except `http-proxy` in the app's config form (the core would accept
  others if the JSON named them; the form cannot write them).
- Multiple domains: the app serves exactly one (the first/only domain in the config, or
  the one named).

### Journal, WAL and convergence with peers (verified in code)

| Question | Answer on Android |
|---|---|
| Polls the shared journal? | **No.** Boot runs `init`, `start_queue` (upload + metadata queues, then replay/reconcile) and `run_maintenance`; it never starts the poller (`converge`). The only callers of "apply foreign entries" are the poller and full resync, and resync is refused on this frontend (`tree = Pulled`). |
| Applies foreign journal entries? | **No.** Nothing on Android reads a peer's journal entry. `last_sync_key` is never written by the app. |
| Keeps a WAL? | **Yes**, the same per-client write-ahead log as every host: each mutation (write, create, mkdir, rename, delete, rmdir) is recorded before execution, and replay/reconcile at the next boot finishes `Intent`/`Prepared`/`Executed` records and adopts staged bodies no record names. |
| Publishes journal entries for its own writes? | **Yes.** The upload queue, after uploading, discharges each record: marks it Executed, **publishes the journal entry** (ops of that record, under the record's entry key), notes the cursor, then deletes the record. Share-sheet saves, camera backups and picker edits all go through `write` → queue → journal entry, exactly like a desktop write. Metadata ops (mkdir/rename/delete…) are published by the metadata queue the same way. |
| Cursor bump? | Coalesced by the store layer: published at most every 2 s via a timer (no explicit flush, since the linked runtime never drains). A kill inside that window leaves the entry published but the cursor behind; a peer still finds the entry by listing journal keys. |
| Keeps an applied log? | Only of **its own** entries: publishing an entry also notes it in the local applied-entries log (and emits a change notice to the domain's socket path, which nobody listens on here). No foreign entry is ever noted. |
| How does it converge with peers? | **Pull-on-read.** Listing a folder reads that folder's children straight from the store's inode tree (by folder id), records them in the local mirror, and prunes published entries the store no longer names (staged, never-uploaded entries are kept). A folder with metadata still owed in the WAL under it is **not** pulled (a listing would undo the local, unpublished change). A folder never opened is simply not known. File content is always read by manifest from the store/cache, so a re-listed file shows the peer's latest version. There is no push of peer changes to the UI; freshness = "re-open the folder". |
| Conflict handling | Whatever the shared write/rename path does (whole-body write replaces; see the checkout/conflict specs). The app adds none, except `freeName` numbering for share-sheet saves. |

### What is replaced

| Concern | Replacement on Android |
|---|---|
| Frontend | a DocumentsProvider (SAF) + an in-app file browser + a share-target activity |
| Storage locations | `HOME` = the app's private files dir; config/cache derive from it (A4.1) |
| Trust store | a PEM bundle concatenated from the device's CA directory, passed as `SSL_CERT_FILE` |
| Logging | a log sink routed to the platform log (logcat, tag `tsync`) |
| Lifecycle | boot on first use from any entry point; no stop; process death = crash-stop, recovered by replay at next boot |
| Keep-alive | a foreground service held while ≥1 served descriptor is open, or while a share-save is uploading |
| Background scheduling | the platform job scheduler (WorkManager) for camera backup, not the engine |
| Upload pacing | a write may ask to be answered only once its own upload has been sent or started failing (`await`) |

## A3. Concepts & data model

### A3.1 Item references (the bridge's names)

Items are never named by path. Every item has a **reference** string:

| Form | Meaning |
|---|---|
| `root` | the domain's root folder |
| `d:<folder id>` | a folder; id minted by the core at mkdir, stable across rename/move |
| `f:<folder id>/<leaf>` | a file: the id of the folder holding it + its leaf name |

- Root folder id is reserved: `.tsync-root` (`Keys.ROOT_FOLDER_ID`); `d:.tsync-root`
  parses as `root`.
- Neither a folder id nor a leaf may contain `/`, so the first `/` after `f:` separates
  them. Anything else parses as `Bad` and is answered `not_found` (not a crash).
- Kind is decidable from the prefix alone (`isDir(ref) = ref == "root" || ref starts "d:"`).
- Consequence: a file's reference changes when it is renamed or moved; a folder's does
  not. The SAF documentId **is** the reference, so folder grants survive a folder move.
- Clients learn folder refs only from replies (listing, or the `item` in a mkdir reply);
  they can compose a file ref (`f:<parent id>/<leaf>`) but the app does not.

### A3.2 Item row (JSON)

Every listing entry / stat reply / `item` field:

```json
{"ref":"f:<id1>/big.txt","parentRef":"d:<id1>","name":"big.txt","kind":"file",
 "size":24,"mtime":1400000000.0,"etag":"1294bbe85c2f380b","isUploaded":true,
 "availability":"online-only"}
```

- `kind` ∈ `dir|file|symlink`. `mtime` = float seconds since epoch (0.0 for folders).
- `etag`: content identity (empty for a staged, never-uploaded body; a folder's etag is its
  id; root's is `.tsync-root`).
- `isUploaded`: false while a staged body is owed to the store.
- `availability` (files only) ∈ `online-only|cached|pinned`; when pinned, `pinnedUntil`
  (float seconds) is added. Optional `symlinkTarget`, `trashed:true`.
- Root's `name` is the domain name.

### A3.3 Replies and errors

- Success: `{"ok":true, …fields}`. Failure: `{"ok":false,"code":<code>,"error":<prose>}`,
  `code` ∈ `not_found|exists|not_empty|read_only|unreachable|denied|invalid|internal`.
- A request that is not JSON: `{"ok":false,"code":"invalid","error":"invalid JSON"}`.
- The bridge guarantees **a reply for every request**: any unexpected failure becomes
  `code: "internal"` with the exception text; it never propagates to the host.

### A3.4 Configuration file written by the app

At `<filesDir>/.config/tsync/config.json` (`Config.kt`):

```json
{ "name": "<Build.MODEL or 'android'>",
  "domains": [ { "name": "Jellyfin Media", "versioning": true, "symlinks": "skip",
    "maxCache": "2G", "frontends": ["android"],
    "backends": [ { "type": "http-proxy", "name": "server", "role": "main",
                    "url": "https://tsync.example.org", "secret": "…" } ] } ] }
```

The app reads back `domains[0].name`, `backends[0].url/secret`, `domains[0].maxCache`
(default `2G`). Validation before save (first failure wins, attached to its field):
domain non-blank, ≤32 chars, no `/` or control chars (spaces allowed); URL non-blank and
starting `http://` or `https://`; secret non-blank. Then the **core** is asked whether it
can load that config (A5.1 `check_config`); its message is shown verbatim.

### A3.5 Local state owned by the app (not by the core)

| Store | Format | Content |
|---|---|---|
| `<filesDir>/staging/<epochMillis>-<uuid>` | plain files | bodies being handed to the core; the name prefix is the staging time (used by orphan sweep, because commit rewrites the file's mtime) |
| `<filesDir>/ca-bundle.pem` | PEM concatenation | built once from `/apex/com.android.conscrypt/cacerts` (Android 14+) else `/system/etc/security/cacerts`; only `-----BEGIN CERTIFICATE-----…END…` blocks taken |
| SharedPreferences `camera-backup` | key/value | `enabled` (false), `unmeteredOnly` (true), `whenBatteryOk` (true), `lastOutcome` (string?), `settled` (bool?, absent until a sweep ran) |
| SQLite `camera-backup.db` v2 | see A3.6 | per-media upload records, per-volume watermarks, folder-ref cache |

### A3.6 Camera-backup records (SQLite, schema v2)

```sql
CREATE TABLE media (media_id INTEGER PRIMARY KEY, volume TEXT NOT NULL,
  relative_path TEXT NOT NULL, size_bytes INTEGER NOT NULL,
  modified_seconds INTEGER NOT NULL, state TEXT NOT NULL,   -- 'DONE' | 'FAILED'
  attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT, updated_at INTEGER NOT NULL);
CREATE UNIQUE INDEX media_path ON media(relative_path);
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
  -- 'watermark.<volume>.generation', 'watermark.<volume>.dateAdded'
CREATE TABLE dirs (path TEXT PRIMARY KEY, ref TEXT NOT NULL);
  -- 'Camera Uploads/2026' -> 'd:<id>'
```

- All writes are `INSERT OR REPLACE`. The unique `relative_path` index means a new
  `media_id` claiming an existing name replaces the old row (MediaProvider rebuilds
  renumber ids).
- Upgrade (any old version) drops and recreates only `dirs`; upload records are real
  state and are never dropped.
- Unknown `state` strings read as `FAILED`. `attempts` is never incremented (unused).
- **Watermark** = `(generation, dateAddedSeconds)`, default `(0,0)`.

### A3.7 Photo naming

`Camera Uploads/<yyyy>/<yyyy-MM-dd HH.mm.ss>[ (n)]<.ext>` under the domain root.

- Time = capture time (`DATE_TAKEN` ms, else `DATE_ADDED`·1000) formatted in the phone's
  zone **at first sight**; the name is then frozen in the record (re-computing after
  travel would duplicate).
- `(n)` sequence for captures sharing a second; 0 omits it; up to 1000 tries.
- Extension from the display name (not MIME): the part after the last dot, if the dot is
  not first/last and the extension is all letters/digits; lower-cased. Else none.
- Leaf passes through `sanitizeLeaf`: `/`, `\`, ISO control chars → `_`; trim leading
  whitespace; trim trailing spaces and dots; empty → `unnamed`.
- Example: `IMG_1234.JPG` captured 2026-08-16 12:31:04 UTC in Paris →
  `Camera Uploads/2026/2026-08-16 14.31.04.jpg`.

## A4. Interface

### A4.1 Host environment contract (what the host must provide before the core starts)

1. `HOME` = the app's private files directory. Config path =
   `$HOME/.config/tsync/config.json`; cache root = `$HOME/.cache/tsync` (the Linux XDG
   derivation; `XDG_*` unset). Must be set before any core initialisation, which derives
   paths eagerly.
2. `SSL_CERT_FILE` = path of the CA bundle. Mandatory even for plain-HTTP backends: the
   HTTP client builds a TLS authenticator unconditionally, and without a bundle the core
   dies at startup.
3. A **log sink**: `(level ∈ {debug=0, info=1, warn=2, error=3}, message)`; installed
   before anything that can fail.
4. The domain name to serve (`""` = the only one the config names).
5. Threads: the host calls from arbitrary threads it owns (binder threads, worker
   threads, descriptor-callback threads). The core must accept calls from threads it did
   not create, serialise them onto its own single event loop, and block only the calling
   thread.
6. Never call `boot` from the UI thread (it reads the manifest tree).

### A4.2 Bridge operations (core ⇄ host), abstract

All text crosses as **UTF-8 byte arrays**, not platform strings (names may contain
characters outside the BMP; the JVM's modified-UTF-8 cannot carry those).

| Op | In | Out | Semantics |
|---|---|---|---|
| `check_config(domain)` | domain bytes | `""` or error text | Loads config + selects the domain without starting it. Callable before/after boot. |
| `boot(domain)` | domain bytes | `""` or error text | Idempotent at host level (host guards with a lock + `started` flag). Loads config, applies TLS config, builds the engine, starts the event loop on a core-owned thread, **returns once the manifest tree is ready** (not after replay), then in the background: start upload queue + replay/reconcile, start maintenance, keep the loop alive forever. No stop operation exists. |
| `request(json)` | request bytes | reply bytes (always a JSON reply) | One request, one reply; see A4.3. Changes are serialised by the handler's mutation lock. |
| `status()` | — | human-readable text | Same text as desktop `tsync status` for one domain, with `frontend: android`. Errors → `"tsync could not report: …"`. |
| `open(ref)` | ref bytes | handle > 0, or `-errno` | Resolves the ref; records `{key, size-at-open}` under a new monotonically increasing integer handle. ENOENT (2) when the ref names nothing. |
| `size(handle)` | handle | size, or -1 for unknown handle | Size captured at open (not re-resolved). |
| `read(handle, offset, length, dest)` | | bytes served, or `-errno` | Fills `dest[0..n)` with content bytes `[offset, offset+n)`. Short **only** at end of content; 0 past end. Unknown/closed handle → `-EBADF` (−9). Each handle is its own *read stream* for read-ahead (A6.2). May block for as long as the network takes. |
| `close(handle)` | handle | 0 | Forgets the handle. Idempotent. |

Errno mapping for open/read: ENOENT→2, EIO→5, EBADF→9, EACCES→13, ENOSPC→28, any other
Unix error→5, any non-Unix failure→5 (logged).

There are **no events/callbacks from core to host** besides the log sink. The host learns
of changes only by re-querying (the `changed` hook is a no-op).

### A4.3 Request actions the app uses (JSON)

Request = `{"action": <name>, …}`. Shared vocabulary with the macOS extension (full
handler spec: [the frontend contract](../08-frontends.md) / IPC handler). Used by the app:

| Action | Request fields | Reply (success) | Used by |
|---|---|---|---|
| `stat` | `ref` | the item row at top level | provider queryDocument, write commit, rename |
| `list_dir` | `ref`, `after` (""), `limit`? (default 1000) | `items:[row…]`, `next`? | provider (limit 500, walks all pages), browser (200, infinite scroll), ingest (default, **no paging**) |
| `mkdir` | `parentRef`, `name` | `item` | provider createDocument(dir), ingest folderFor |
| `create` | `parentRef`, `name` | `item` (empty staged file, `isUploaded:false`, `availability:cached`) | provider createDocument(file) |
| `write` | `parentRef`, `name`, `staging` (abs path), `await:true` | `size`, `mtime`, `item` | Ingest.commit (all writes) |
| `delete` / `rmdir` | `ref` | `{}` | provider deleteDocument |
| `rename` | `ref`, `parentRef`, `name` | `item` (at destination) | provider renameDocument (same parent) |
| `ensure_cached` | `ref`, `dest` | `localPath` | provider open for edit/append |
| `share` | `ref` | `url` | browser "Share link" |
| `restore` | `ref`, `keep`? | `{}` | browser "Make available offline / Keep offline longer" |
| `evict` | `ref` | `{}` | browser "Make online only" |

Paging contract (`list_dir`): entries sorted by name (byte order); page = entries with
name > `after`, at most `limit`; `next` = name of the last row served, present only if
more follow. Stateless: a fresh process resuming from `next` answers identically.

`write` contract: the staged file at `staging` is **adopted by rename** into the chunk
store — it no longer exists on success (caller must not delete it); the staged file's
mtime becomes the item's mtime (this is the only channel by which a photo keeps its
capture time). Any in-flight upload of the same key is cancelled first. The whole body
**replaces** any existing file at `parentRef/name`. With `await:true` the reply comes only
after this key's owed upload has been sent **or has started failing** (left to the queue's
retries); `isUploaded` in the returned `item` says which. A `parentRef` naming a folder
nobody made is refused and journals nothing.

### A4.4 CLI group `tsync android` (for shells and JVM tests)

Positional arguments; each invocation boots a runtime, answers, drains, exits.
`stat REF`, `list REF [AFTER [LIMIT]]`, `read REF DEST OFFSET LENGTH` (fetch_range into
DEST at the same offset, sparse elsewhere), `open REF` (session, below), `residency REF`
→ `{"ok":true,"cached":n,"total":m}`, `fetch REF DEST`, `write-whole PARENT NAME STAGING`
(await), `create`, `mkdir`, `delete`, `rmdir`, `rename SRC PARENT NAME`, `share REF`,
`request JSON` (exactly what the linked runtime answers), `status`. Bad usage → exit 2.

Only mutating verbs start the upload queue + replay; read-only verbs only load the
manifest tree. Every verb ends with a drain (queues, cursor flush, notices, backends).

`open REF` session protocol: first line `{"ok":true,"size":N}` (or a `not_found`
refusal); then for each stdin line `"OFFSET LENGTH"` (offset ≥ 0, length > 0) the answer is
a JSON line `{"ok":true,"length":n}` followed by exactly `n` raw bytes; a malformed line is
answered `{"ok":false,"code":"invalid",…}` and the session continues; EOF on stdin ends it.
Framing is by count, never by delimiter. (The app no longer uses it; kept for shells.)

## A5. Behaviour / algorithms

### A5.1 Boot and lifecycle

```
any entry point (provider call, browser, worker, share save)
  → Native.ensure(context)   [process-wide lock; returns at once if started]
      home  = filesDir; certs = caBundle(); domain = config.domains[0].name or ""
      first call in process: set HOME, SSL_CERT_FILE; start the core runtime
      boot(domain) → error text ⇒ throw "tsync could not open the domain: …"
      started = true
```

- Boot answers ready after the manifest tree is loaded; queue start + replay continue on
  the loop, so the first query does not wait for replay.
- The engine and handler are built **once per process**. Saving a new config while
  `started` offers "Restart now", which finishes all activities and exits the process;
  "Later" keeps serving the old config until the process dies.
- There is no stop/drain on the Android host. Process death is a crash-stop; everything
  owed is in the WAL / durable queue and is replayed at next boot (see sync-queue and WAL
  specs). This is the reason there is no ranged write or close: every operation is a
  function of key and offset whose state is already on disk.

### A5.2 DocumentsProvider (SAF) mapping

- Authority `org.feverdreamtv.tsync.documents`; guarded by `MANAGE_DOCUMENTS` (system-only).
- **queryRoots**: one row always (even if the core is down: a vanished root leaves no way
  to diagnose): `rootId = domain` (config, default `"media"`), `documentId = "root"`,
  title `tsync`, summary = domain, flags `SUPPORTS_CREATE | SUPPORTS_IS_CHILD`.
  Roots change notification is fired after first launch with a config and after saving
  settings (DocumentsUI caches roots).
- **queryDocument(id)**: `root` is synthesised (a fresh install has no mirror; stat would
  answer not_found). Others: `stat`; folders → MIME `vnd.android.document/directory`,
  flags `DIR_SUPPORTS_CREATE|SUPPORTS_DELETE|SUPPORTS_RENAME`; files → MIME from extension
  (`MimeTypeMap`, default `application/octet-stream`), flags
  `SUPPORTS_WRITE|SUPPORTS_DELETE|SUPPORTS_RENAME`, size, last-modified = mtime·1000 (null
  if 0).
- **queryChildDocuments**: walk every page (`list_dir`, limit 500) into one cursor. On any
  failure: return what was gathered plus `EXTRA_ERROR = "tsync could not reach the server
  for this folder"` (a banner beats an empty folder that looks like truth).
- **isChildDocument(parent, doc)**: parent folder id = `.tsync-root` for `root`, id for
  `d:`; files are children iff `doc` starts `f:<id>/`; a `d:` doc only iff it equals
  `d:<id>` (see open questions).
- **createDocument(parent, mime, displayName)**: leaf = `sanitizeLeaf(displayName)`;
  `mkdir` or `create`; returns the new child's ref found by listing `parent` and matching
  the name.
- **deleteDocument**: `rmdir` for folder refs, `delete` for files.
- **renameDocument**: parent = `stat(doc).parentRef`; `rename(doc, parent, sanitized)`;
  returns the same id for folders (id survives), the listed child ref for files.
- **openDocument, read-only mode** (mode without `w`):
  1. ensure booted; `h = open(ref)` (negative → errno exception); retain keep-alive (A5.4).
  2. Return a **proxy descriptor** (seekable, as container probing needs) whose callbacks
     run on one of 4 fixed callback threads, assigned round-robin per open:
     `onGetSize → size(h)`, `onRead(off, n, buf) → read(h, off, n, buf)` (negative →
     errno exception; ≥1000 ms reads logged), `onRelease → close(h) + release keep-alive`.
  3. If the descriptor cannot be made, close + release immediately, rethrow.
  So at most 4 reads are in flight app-wide; each open file's reads are serialised on its
  thread; interleaving between files happens on the core's loop.
- **openDocument, write modes** (`w`, `wt`, `rw`, `wa`…):
  1. staging = new staging file.
  2. If mode contains `r` or `a`: `ensure_cached(ref, staging)` (assemble the whole
     current body into staging). On failure delete staging and refuse the open
     (`FileNotFoundException`) — never start empty, or the close would publish a
     truncated file.
  3. Create staging if absent; return a real read-write descriptor on it with a close
     listener on a callback thread.
  4. On close with error: delete staging (a truncated write is worse than a dropped
     edit). On clean close: on a **new thread** (commit waits for the upload; the callback
     thread serves other files' reads): `stat(ref)` → `parentRef`,`name`;
     `Ingest.commit(parent, name, staging)`. Failure → log + "Problems" notification.

### A5.3 Request-handler hooks on this host

| Hook | Android behaviour |
|---|---|
| evict | single key evict |
| restore | single key ensure-cached (pin with optional keep) |
| changed | no-op |
| full_resync | no-op |
| status_fields | none |
| stats_fields | engine stats + `frontend: "android"` |
| on_stop | no-op |

The handler's continuation (`Continue`/`Stop`/`Subscribe`) is ignored: every call is
answered the same way.

### A5.4 Keep-alive (process must not be frozen while serving)

Proxy-descriptor reads are answered in the app process, and Android freezes cached
processes — a player then drains its buffer and waits forever (observed on a Pixel 9a,
commit 76905162). Rule:

- A counter `open` (process-global, synchronised). `retain()` increments and returns true
  exactly on 0→1; `release()` decrements and returns true exactly on 1→0; release at 0 is
  ignored (never negative).
- On 0→1 start a foreground service (type `dataSync`, low-importance notification
  "Serving N open files", `START_NOT_STICKY`); on 1→0 stop it.
- Platform refusal (background-start restrictions, exhausted daily dataSync budget) is
  logged and ignored: reads keep working as long as the process lives.
- On the platform's foreground timeout the service stops itself instead of letting the
  process be killed.
- Retained by: each read-only open (released at descriptor release or failed open), and
  each share-target save (released after the last commit).

### A5.5 Ingest (the only way bytes enter a domain from the app)

`commit(parent, name, staging, modified?)`:
1. fsync the staging file (adoption is a rename; unsynced bytes would publish as the
   whole file after a power loss).
2. If `modified` given, set the staging file's mtime to it.
3. `write` with `await:true`. On failure delete staging and rethrow; on success the core
   owns it.

`folderFor(relativePath, known)`: for each directory segment of `relativePath`, reuse the
ref cached in `known` (keyed by the path prefix), else list the parent and find the child
by name, else `mkdir` then list again; record in `known`. Returns the innermost folder ref.

`freeName(parent, name)`: if `name` is not among the parent's children, it; else
`stem (n).ext` for the first free n ≥ 1 (stem = before last dot, or whole name if that is
empty). Used only for share-target saves (a whole write replaces what it lands on).

`sweepOrphans(age)`: delete staging files whose name-prefix timestamp is older than `age`
(24 h, run at each backup worker start).

### A5.6 Share target ("Save to tsync", commit 4c32fa96)

- The launcher activity also accepts `SEND` / `SEND_MULTIPLE` of `*/*` with
  `EXTRA_STREAM`. No streams → toast "only files can be saved" and finish; no config →
  "Set up tsync before saving to it".
- The browser opens in *save mode*: item taps only navigate folders; the header reads
  "Save N files to /path"; buttons "Save here" / "Cancel".
- One file: an editable "Save as" dialog pre-filled with the stream's display name
  (`OpenableColumns.DISPLAY_NAME`, else last URI segment, else "shared file"). Several:
  each keeps its own name.
- Save: retain keep-alive; on a worker thread copy every stream into its own staging file
  **while the activity still holds the read grant**, then finish the activity, then for
  each staged file: `leaf = freeName(folder, sanitizeLeaf(name))`, `commit`. Per-file
  failures → "Problems" notification; the rest continue. Release keep-alive at the end.

### A5.7 In-app browser and settings

- Browser: trail of `(ref, name)`; lists `list_dir` pages of 200, loading the next page
  when within 10 rows of the end; "Empty folder"/error notice. Folder tap → descend; back
  → pop. File tap/long-press → actions: `Open` (ACTION_VIEW on the provider URI with a read
  grant, chooser), `Share link` (`share` → dialog with Copy / Send), `Make available
  offline` or `Keep offline longer` (if pinned) → `restore`, `Make online only` (unless
  already online-only) → `evict`.
- Status screen: backup line + `status()` text verbatim, monospace, refresh button.
- Setup form: domain (free text, autocompleted after "Check server"), URL, secret (hidden),
  cache limit (default `2G`), "Save and start", then camera-backup controls.
- "Check server" is the one network request the host makes itself (before any config
  exists): `GET <url>/domains` with headers `x-tsync-timestamp: <unix seconds>` and
  `x-tsync-signature: hex(HMAC-SHA256(secret, "GET\n/domains\n<ts>\n<hex(sha256(""))>"))`
  (same HMAC as the http-proxy backend; ±5 min skew). 200 → `{"domains":[{"name":…}]}`;
  401 → "secret refused (or clock off)"; 404 → "server too old to list domains"; timeouts
  10 s.

### A5.8 Camera backup

Components: schedule (platform jobs), worker (one bounded pass), sweep, planner (pure),
scan (MediaStore adapter), records (A3.6), gate (network/battery), access level.

**Access level**: API ≥ 33: `FULL` iff both READ_MEDIA_IMAGES and READ_MEDIA_VIDEO;
`SELECTED_ONLY` if either, or (API ≥ 34) READ_MEDIA_VISUAL_USER_SELECTED; else `DENIED`.
Below 33: READ_EXTERNAL_STORAGE → FULL else DENIED. Requested set also includes
ACCESS_MEDIA_LOCATION (API ≥ 29) and POST_NOTIFICATIONS (API ≥ 33). Selected-only is
reported as a limit ("only the photos you selected"), not a stall.

**Enabling**: checkbox on → dialog "Everything" (backfill) / "From now on". "From now on"
sets each volume's watermark to `(current generation, newest DATE_ADDED)` — taken from
MediaStore, not the clock. Then permissions are requested; if any read access results,
schedule is enabled. Off → cancel all three unique works.

**Schedule** (three unique work names, so they may run concurrently):
- `camera-backup-watch`: one-shot with content-URI triggers on Images and Video external
  URIs (descendants), update delay 10 s, max delay 300 s; policy REPLACE; backoff
  exponential 5 min; **re-enqueued at the end of every run** (a trigger fires once).
- `camera-backup-periodic`: every 6 h, policy UPDATE, backoff exponential 15 min.
- `camera-backup-now` (button): one-shot, KEEP, no constraints, input `userInitiated=true`.
- Constraints for the first two: network UNMETERED if `unmeteredOnly` else CONNECTED;
  battery-not-low if `whenBatteryOk`; storage-not-low always.
- Changing either checkbox re-enqueues with new constraints.

**Worker** (one pass):
1. Process-wide try-lock; if another sweep holds it, return success immediately
   (concurrent sweeps would plan from the same records and upload twice).
2. Disabled → success. No read access → `lastOutcome="photo access not granted"`, success.
3. Not user-initiated and gate blocked → `lastOutcome = reason`, **retry**.
4. Try to promote to foreground (dataSync, "Backing up camera photos"); refusal ignored.
5. Sweep orphans (24 h). Run the sweep with `cancelled = worker is stopped`.
6. `lastOutcome = "<u> uploaded[, <f> failed][, more to do]"`;
   `settled = !more && failed == 0`; `more` → retry, else success. Exception → `lastOutcome
   = "last sweep failed: …"`, retry. Always re-enqueue the watch.

**Gate** (re-checked per file, not only at start): `unmeteredOnly` and active network
lacks NOT_METERED (or no network) → "waiting for wifi"; `whenBatteryOk`, not charging/full,
and level < 15 % → "battery low".

**Sweep** (bounded): budgets — staged bytes 512 MiB per pass (staged bodies are not
covered by `maxCache`), time 8 min (jobs are stopped ≈10 min), free space ≥ 2× file size
in the staging directory. For each volume (API ≥ 29: all external volume names, else
`external`): read watermark and the current generation; for each collection (images,
video): query rows, plan, act:

- Before each action: if cancelled, gate blocked (unless user-initiated), budget or time
  exceeded → persist folder cache, return `more=true` **without advancing the watermark**.
- `Skip ALREADY_DONE` → advance `highestDateAdded`. `STILL_PENDING`/`UNSETTLED` → `more`.
  `EMPTY` → nothing (never improves).
- `Upload` → check space; `folderFor(dir of relativePath)`; copy the *original* stream
  (with location metadata: API ≥ 29 `setRequireOriginal`) into staging, 64 KiB buffer;
  copied ≠ row size → fail; `commit(folder, leaf, staging, modified = captureMillis)`;
  record DONE; advance watermark by DATE_ADDED. On any failure delete staging, record
  FAILED with the message.
- After both collections: `setWatermark(volume, (generation read at start, highestDateAdded))`.
- End: persist folder cache.

**Query** (MediaScan): selection `RELATIVE_PATH LIKE 'DCIM/%'` (API ≥ 29) or
`DATA LIKE '%/DCIM/%'` (older) — any depth under DCIM, since OEM cameras use their own
subfolders; AND `GENERATION_MODIFIED > wm.generation` (API ≥ 30) or
`DATE_ADDED > max(0, wm.dateAdded − 86400)` (older; 24 h lookback because DATE_ADDED is
not monotonic, records dedupe). Order `_ID ASC`. Row: id, volume, display name,
captureMillis (DATE_TAKEN or DATE_ADDED·1000 — video often lacks DATE_TAKEN), size,
DATE_ADDED, DATE_MODIFIED, GENERATION_MODIFIED, isVideo, IS_PENDING.

**Planner** (pure; `plan(rows, records, now, zone, settle=10 s)`), rows sorted by id:
1. pending → Skip STILL_PENDING; size ≤ 0 → Skip EMPTY; `now − modified·1000 < settle`
   → Skip UNSETTLED.
2. Record for this id exists: DONE and same size and modified → Skip ALREADY_DONE; else
   Upload under the **recorded** name (changed or FAILED content re-uploads to the same
   place, replacing it).
3. No record: for seq = 0..999 compute the name; if `(name, size)` is a DONE record's →
   Skip ALREADY_DONE (recognises renumbered ids); else if the name is not taken by any
   record nor claimed earlier in this plan → claim it, Upload. 1000 collisions → error.
- `advanceWatermark(prev, row) = max(prev, row.DATE_ADDED)` — never DATE_MODIFIED.
- The domain is never asked whether a photo exists: the device record is authoritative, so
  a photo the owner deleted from the domain is not re-uploaded forever.

**Status line**: `camera backup: off` | `<n> failed — <last error (80 chars)>` |
`not started yet` (settled null) | `more to upload` | `up to date`, plus hold reason
(gate or "no access to photos"), "(only the photos you selected)", and `last sweep: …`.

## A6. Interactions

- **08-frontends**: registration (`implementation = "android"`, CLI group `android`,
  `serving = Commands`, `tree = Pulled`, `availability = Checkout.availability`).
- **IPC request handler**: the entire app wire is that handler's JSON; the same action
  strings are a contract with the macOS extension.
- **Domain engine**: `init` (manifest root), `start_queue` (upload + metadata queues, then
  replay/reconcile), `run_maintenance`, `drain` (CLI only), stats.
- **Lazy checkout**: listing a folder pulls it from the store through the inode tree,
  records entries in the mirror, prunes published entries the store no longer names
  (staged entries are kept). Proven by the lazy test (A8).
- **File ops / content**: `read` with a per-reader stream id → read-ahead in the chunk
  data layer; `write_whole` adoption by rename; `assemble_to`; `fetch_range`;
  `chunk_residency`; evict/ensure_cached; `enforce_chunk_cap` as maintenance.
- **Sync queue**: `settle_key` behind `await` (answered once the key's owed work is gone
  or has started failing); durable queue + WAL make a kill safe.
- **Share**, **Diagnostics/Status report**, **Config parsing/TLS**, **http-proxy auth**
  (the setup form reuses its HMAC).

Data flow, picker playback: SAF read → callback thread → `read(h, off, n)` → core loop →
file-ops read (cache hit or backend fetch; read-ahead continues past this range) → bytes
copied into the platform buffer.

Data flow, camera photo: content trigger → worker → planner → `folderFor` (list/mkdir) →
copy to staging → fsync → `write await` → core adopts, queues upload, waits for it →
record DONE.

## A7. Concurrency, durability & failure semantics

- One core event loop per process; host threads block only themselves. Mutating actions
  are serialised by the handler's mutation lock (refs are resolved before the mirror lock,
  so parallel mutations could otherwise race a folder rename).
- Blocking-job thread pool capped at 16 (a phone's floor, not a server's range).
- Reads: ≤ 4 concurrent at the provider (callback threads).
- Durability: writes are fsynced by the host before adoption; adoption is a rename; the
  upload is durable in the queue/WAL; a kill at any point is recovered by replay at next
  boot. Staged bodies orphaned before commit are swept after 24 h.
- `await` never holds a caller for a store that is down: "started failing" ends the wait,
  retries continue in the queue.
- A write open that cannot fetch the current body is refused; a close with error drops the
  edit rather than publishing a truncated body.
- Camera backup idempotence: records keyed by media id and unique by path; the watermark
  only moves on complete passes and only by DATE_ADDED of settled/uploaded rows; a
  truncated pass returns `more` and is retried.
- Offline: listing a never-opened folder fails (provider shows a banner); cached/pinned
  bytes still read; writes stage and are queued (with `await`, answered when the upload
  starts failing).
- Every bridge entry is total: a failure becomes a reply, an error string, or `-errno`.

## A8. Invariants the tests pin down

`tests/frontends/android` (spawned, one process per call; snapshot of full replies):
- mkdir then list/stat show the folder with `d:<id>`; `stat root` answers name = domain,
  etag `.tsync-root`.
- `write-whole` adopts the staging file (gone afterwards); mtime comes from the staged
  file's mtime; reply has `isUploaded:true` after await.
- `read` ranges written at their offset reassemble the file; a read past the end is short
  (`length` 8 for 16+64 of 24 bytes) or 0, never padded.
- Missing refs are coded refusals (`not_found`), including a raw storage key.
- `create` → size 0, etag "", `isUploaded:false`, availability `cached`.
- `fetch` assembles the whole body; `residency` = `cached:3,total:3` for 3 chunks.
- `list` pages by name with `next`.
- `share` without a share-capable backend → `internal` "Sharing is not available for …".
- `open` session: size line, then counted byte frames; past-end → 0.
- rename returns the new item; delete/rmdir; list root empty.
- status report works with no daemon.
- Every registered verb is exercised (registry vs. tested list; `untested: (none)`).

`tests/frontends/android_lazy`: with the mirror wiped, listing root works without a sync
and fetches only root; descending fetches only that folder; a file deleted by another
device disappears from the listing and is pruned from the mirror; a staged (created) file
survives a pull that does not know it.

`tests/frontends/android_bridge` (linked in, foreign threads): boot ok; request lists,
mkdirs, lists again; a write after a change is answered uploaded and consumes staging;
non-JSON → `{"ok":false,"code":"invalid","error":"invalid JSON"}`; status non-empty;
size matches; 8 foreign threads × 64 reads over a 4096-byte multi-chunk file → 0 wrong
bytes; close → 0; read after close → −9; open of an absent ref → −2.

`CliProtocolTest` (JVM, drives `tsync android request` with the Kotlin request builders):
fresh domain lists nothing; write into an unminted folder is refused and journals
nothing; mkdir+write gives correct size/name/parentRef; paging (3 items, limit 2 → 2
pages, no duplicates); staging consumed; mtime preserved (±2 s); published by return;
missing stat fails promptly; create alone → size 0; root addressable with name = domain;
second write replaces; fetch; evict→`online-only`, restore→`pinned` with
`pinnedUntil > now`, evict again.

JVM unit tests: `KeysTest` (root id, sanitize), `OpenDescriptorsTest` (first starts, last
stops, middles silent, failed open gives back exactly, no negative), `PhotoNamingTest`,
`BackupPlannerTest` (fresh, done, changed keeps name, failed retried same name, same-second
sequence, pending, unsettled, empty, renumbered ids by name+size, renumbered different
content gets `(1)`, watermark by DATE_ADDED and monotone, plan stable), `UploadRecordsTest`
(Robolectric: round trip, same id one row, new id claiming a name replaces, count by state,
per-volume watermarks default/persist, dirs round trip and overwrite). Device-only
`MediaScanTest` (emulator, opt-in): finds a DCIM capture, ignores non-DCIM, finds OEM
DCIM subfolders, reports pending, watermark ahead finds nothing, lists volumes.
Every gradle test task fails if it executed zero tests; the device workflow fails if the
reports count zero tests.

## A9. Open questions / inconsistencies

1. **Watermark generation vs. retry (API ≥ 30)**: a complete pass stores the generation
   read at its start even when rows were UNSETTLED or FAILED. Next query is
   `GENERATION_MODIFIED > generation`, so an unsettled row (not modified again) or a
   failed upload is never returned again; `more=true` retries a pass that cannot see it.
   Only older APIs' 24 h lookback re-covers such rows. Likely bug.
2. **`isChildDocument` for folders**: a `d:` ref does not encode its parent, so only files
   directly in the folder (and the folder itself, via `== d:<id>`) are recognised; nested
   folders and deeper files return false. SAF's contract is "descendant", so tree grants
   under a subfolder may be refused.
3. **Unpaged child lookups**: `Ingest.children`/`childRef`/`freeName` and the provider's
   `childRef` call `list_dir` with the default limit (1000) and never follow `next`: in a
   folder with > 1000 entries a child may not be found (mkdir would then be attempted
   again; `freeName` may pick a taken name and **overwrite** it).
4. The app ignores the `item` returned by `mkdir`/`create`/`rename` and re-lists to find
   the ref (an extra round trip the handler's comment says it exists to avoid).
5. `freeName` + `commit` is check-then-act outside the mutation lock: concurrent saves of
   the same name can overwrite each other.
6. `newestAdded` passes `"… DESC LIMIT 1"` as sortOrder; recent MediaProvider versions are
   reported to reject `LIMIT` in sortOrder (unverified here). `skipExistingRoll` runs on
   the UI thread and before the permission request, so below API 30 it may see no rows and
   leave dateAdded 0 (full backfill despite "From now on").
7. `Cli.reply` throws with the prose `error` only; the `code` is dropped, so the app cannot
   distinguish `not_found` from `unreachable` (e.g. `Ingest.children` treats every error as
   "no children").
8. Stale wording: `Config.MAX_DOMAIN_LENGTH` justified by a socket path (no socket
   exists now); `test-android-device.yml` mentions "Ipc's LocalSocket"; memory note
   mentions `stageDaemon` (task is `stageLibrary`); a local `jniLibs/.../libtsync.so`
   (old exec'd binary) may linger, gitignored.
9. The CA bundle is built once and never refreshed after OS trust-store updates.
10. `size(handle)` is the size at open; a file rewritten while open keeps serving by the
    old size.
11. `BackupSweep` loads the domain name only to bail out if there is no config.
12. The `attempts` column is never written.

---



---

OCaml implementation notes for this subsystem: [../ocaml/frontends/android.md](../ocaml/frontends/android.md).
