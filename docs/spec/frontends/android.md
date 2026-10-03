# The Android host — as built on `main`

Scope: the behaviour of the Android integration as `main` (`4c32fa96`) implements it: the Kotlin app
(`android/app`, `android/core`), the JNI bridge and the `android` frontend
(`lib/app/frontends/android`), and the parts of the shared core the app relies on. Build, signing,
CI and release are out of scope.

This is an extraction, not a design: every rule below is what the code does, including where that is
wrong. Defects are left in and marked **[as built]** where they are worth calling out; the cleaned
spec is a separate pass. The request handler described here is `main`'s (`f:` file references, no
exclusive creation), not the one [08](../08-frontends.md) now specifies.

---

## 1. Processes and components

One process: the app's. There is no daemon, no socket and no stop; the core is a shared library
(`libtsyncjni.so`) loaded into the app, and it runs for as long as the process does.

| Component | Kind | Role |
|---|---|---|
| `MainActivity` | launcher activity; also the target of `SEND` / `SEND_MULTIPLE` of `*/*`, labelled "Save to tsync" | Setup form, file browser, status screen, share target, camera-backup controls. |
| `TsyncProvider` | DocumentsProvider, authority `org.feverdreamtv.tsync.documents`, exported, guarded by `MANAGE_DOCUMENTS`, `grantUriPermissions` | The domain in the system picker. |
| `OpenDocumentsService` | foreground service, type `dataSync`, not exported | Keeps the process running while it serves open files (§9). |
| `BackupWorker` | WorkManager `CoroutineWorker` | One camera-backup pass (§12). |
| Core | OCaml runtime, one event loop on its own thread | The domain: mirror, cache, queues, the shared request handler. |

- Every component runs in the app's default process and calls the core directly through the bridge
  (§4).
- The app serves one domain: `domains[0]` of its config (§6).
- Nothing takes an ownership lock **[as built]**. A second process on the same state (the desktop
  `tsync android` verbs, §11) is not excluded.
- Process death is a crash-stop. The next boot's reconcile finishes owed work (§3.1).

Platform floor: `minSdk` 26, `targetSdk` 35, `arm64-v8a` only.

Permissions declared: `INTERNET`, `ACCESS_NETWORK_STATE`, `FOREGROUND_SERVICE`,
`FOREGROUND_SERVICE_DATA_SYNC`, `POST_NOTIFICATIONS`, `READ_MEDIA_IMAGES`, `READ_MEDIA_VIDEO`,
`READ_MEDIA_VISUAL_USER_SELECTED`, `READ_EXTERNAL_STORAGE` (max SDK 32), `ACCESS_MEDIA_LOCATION`.
WorkManager's `SystemForegroundService` is merged with `foregroundServiceType="dataSync"`: without it
the worker's foreground request throws on the service's own thread.

`usesCleartextTraffic="true"`. No backup rules are declared, so the platform's Auto Backup and device
transfer copy the app's files, the config and its secret included **[as built]**.

## 2. Identifiers, paths and local state

| Thing | Value |
|---|---|
| Application id | `org.feverdreamtv.tsync` |
| Provider authority | `org.feverdreamtv.tsync.documents` |
| Home | `<filesDir>`; the core derives every path from `HOME` as on Linux with no XDG overrides |
| Config | `<filesDir>/.config/tsync/config.json` |
| Trust bundle | `<filesDir>/ca-bundle.pem` |
| Staging | `<filesDir>/staging/<epochMillis>-<uuid>` |
| Camera-backup settings | SharedPreferences `camera-backup`: `enabled` (false), `unmeteredOnly` (true), `whenBatteryOk` (true), `lastOutcome`, `settled` |
| Camera-backup records | SQLite `camera-backup.db`, version 2 (§12.2) |
| Notification channels | `tsync-backup` "Camera backup" (low), `tsync-open-documents` "Open files" (low), `tsync-problems` "Problems" (default) |
| Notification ids | backup 2, open documents 3, problem 4 |
| Log tags | `tsync` (core and app), `tsyncsaf` (provider), `tsync-open` (service), `tsync-backup` |

- A staging name carries its creation time because commit rewrites the file's mtime (§8).
- All problem notifications share one id, so a later one replaces an earlier one **[as built]**.
- `POST_NOTIFICATIONS` is requested only in the camera-backup permission flow (§12.6); without it
  the problem and keep-alive notifications are not shown **[as built]**.

**Trust bundle.** Built by concatenating every `-----BEGIN CERTIFICATE-----` …
`-----END CERTIFICATE-----` block of every file in `/apex/com.android.conscrypt/cacerts`, else
`/system/etc/security/cacerts` (system authorities only). The core requires the file even for plain
HTTP. Built once: an existing non-empty bundle is never rebuilt, so a trust-store update on the
device is never picked up **[as built]**. The write is not atomic. With neither directory present a
warning is logged and the path of a file that does not exist is handed to the core.

## 3. The core's lifecycle

### 3.1 Boot

Boot is `Native.ensure`, called before every `request`, `status` and read-only open. It is
synchronised and idempotent: the first caller waits, later callers return at once. A failed boot
leaves it unbooted and throws "tsync could not open the domain: …"; the next call tries again.

1. Start the OCaml runtime if it is not running, after setting `HOME` = `<filesDir>` and
   `SSL_CERT_FILE` = the trust bundle. The runtime is started by the first `check_config` or boot,
   whichever comes first.
2. Install the log sink (platform log, tag `tsync`; levels debug, info, warn, error).
3. Load and validate the config; apply its TLS settings; select the domain the app names, or the
   config's only domain when the name is empty.
4. Build the domain over the **lazy tree** (§3.2).
5. Start the event loop on a thread of its own. On it, in order:
   1. ensure the mirror's root exists, then report ready: the booting caller returns here;
   2. start the upload and metadata queues and reconcile the WAL;
   3. start the maintenance schedule, the same task list every owner runs: the cache maintenance
      tasks, the chunk cap (after each upload and every 60 s), the deferred rescan (60 s) and the
      metadata retry (60 s);
   4. wait for ever.

- A failure in steps 2–4 is returned as text. A failure on the loop, at any time, ends the process
  (`_exit(1)`) after logging **[as built]**.
- Deferred replica and backfill work left by an earlier process is not resumed **[as built]**.
- An unhandled failure in detached work is logged, not fatal.
- The core's blocking-call pool is capped at 16 threads.
- Boot must not run on the UI thread; every caller is a binder, worker or ad-hoc thread.

Saving a changed config while booted offers "Restart now" (finish every activity, exit the process)
or "Later" (keep serving the old config until the process dies).

### 3.2 Freshness without a journal poller

The core runs no journal poller and applies no peer entry. Its view of what peers did comes only
from **pulls**.

**Pull.** Listing a folder's children (`list_dir`) first reads that folder's children from the store,
records each in the mirror, and removes from the mirror every published entry the store did not list.
Staged entries are kept. Then the listing is answered from the mirror.

- Every `list_dir` request pulls, each page of a paged listing included **[as built]**.
- A folder with no id in the local mirror is not pulled; the listing answers what the mirror holds.
- A folder is **not pulled at all** while any owed metadata WAL record names one of its direct
  children **[as built]**: a record that keeps failing hides peers' changes in that folder for as
  long as it is owed.
- A pull that fails fails the listing; there is no fallback to the last pulled view **[as built]**.
  A child the store listed but that could not be read fails the whole pull rather than being pruned.

**Everything else answers from the mirror alone.**

- `stat`, opening a file, and the destination of a mutation are resolved in the mirror with no store
  read. An item in a folder never listed in this install is `not_found`.
- An open does not re-read the file's manifest: it serves the version the last pull of its folder
  recorded **[as built]**.
- `mkdir` under a parent that was never pulled does not see a folder of that name a peer made, and
  mints a second id for it **[as built]**.
- A listing handed to the platform is never refreshed while displayed, and the platform is never
  told that a folder's children changed, after a pull or after a mutation **[as built]**.

Changes this client makes are published to the journal and cursor as on any owner, so peers see
them.

### 3.3 What is left out

- Journal polling and entry application; full resync (`tsync sync` refuses on a pulled tree; the
  frontend's `full_resync` and `changed` hooks do nothing).
- Change events and subscriptions.
- Symlinks: the config sets `symlinks: "skip"`.
- Ranged writes and `close`: the only write is whole-body adoption of a staged file.
- Subtree evict and restore: both act on one key (§10.2).

## 4. The bridge

Text crosses as **UTF-8 byte arrays**, never platform strings (the JVM's native string encoding
cannot carry characters outside the Basic Multilingual Plane). The two paths given at startup cross
as platform strings.

| Entry | In | Out | Semantics |
|---|---|---|---|
| `check_config(home, bundle, domain)` | paths, domain name | nothing, or error text | Starts the runtime if needed; loads and validates the config, applies its TLS settings, selects the domain; starts nothing. |
| `boot(home, bundle, domain)` | same | nothing, or error text | §3.1. |
| `request(json)` | request | reply | One request, one reply, through the shared handler (§5). The handler's continuation is ignored. |
| `status()` | — | text | The desktop `tsync status` report for this domain, with `frontend: android`; on failure `tsync could not report: …`. |
| `open(ref)` | reference | handle > 0, or −errno | Resolves the reference in the mirror (staged or published) and records `{key, size now}` under a new handle. |
| `size(handle)` | handle | size, or −1 | The size recorded at open. |
| `read(handle, offset, length, dest)` | | bytes served, or −errno | Reads the handle's **key** at `offset`. Short only at end of content; 0 past it. Each handle is its own read-ahead stream. |
| `close(handle)` | handle | 0 | Forgets the handle. Idempotent. |

- Entries other than `check_config` and `boot` assume the runtime is running; the app guarantees it
  by booting first.
- **Threads.** Every entry may be called from any thread. The caller's work runs on the core's one
  event loop; only the calling thread blocks, and other callers proceed meanwhile.
- **A handle is a key, not a version [as built].** A file rewritten while open is read at its new
  content with the size recorded at open.
- `size` and `close` touch the handle table on the calling thread, outside the loop **[as built]**.
- **Errno**: ENOENT (2) for a reference that parses to nothing or resolves to nothing; EBADF (9) for
  an unknown or closed handle; EACCES (13) and ENOSPC (28) when the core raises them; EIO (5) for
  every other failure.
- **Every entry is total.** A failure becomes a reply, an error text or a −errno; nothing propagates
  into the host. A failed `request` is answered
  `{"ok":false,"code":"internal","error":…}`; a request that is not JSON is answered
  `{"ok":false,"code":"invalid","error":"invalid JSON"}`.
- The core never calls the host, other than the log sink.
- A read allocates a buffer of `length` bytes and copies the served bytes out; the platform array is
  never pinned across the read.

## 5. Requests the app sends

Requests are `{"action":…, …}`. The app sends no `domain`.

| action | request | reply relied on |
|---|---|---|
| `stat` | `ref` | the row at top level: `name`, `parentRef`, `size`, `mtime` |
| `list_dir` | `ref`, `after` (`""` first), `limit?` | `items[]` (`ref`, `name`, `kind`, `size`, `mtime`, `availability`), `next?` |
| `mkdir` / `create` | `parentRef`, `name` | ok only |
| `write` | `parentRef`, `name`, `staging`, `await: true` | ok only |
| `rename` | `ref`, `parentRef`, `name` | ok only |
| `delete` / `rmdir` | `ref` | ok |
| `ensure_cached` | `ref`, `dest` | ok |
| `share` | `ref` | `url` |
| `restore` / `evict` | `ref` | ok |

Handler rules the app depends on:

- **References**: `root`, `d:<folderId>`, `f:<parentFolderId>/<leaf>`. The app treats `root` and
  every `d:` reference as a folder and anything else as a file, from the spelling alone.
- **`list_dir`** orders by name, resumes after the name `after`, defaults to 1000 rows, and answers
  `next` (the last name served) only when more follow.
- **Item row**: `ref, parentRef, name, kind, size, mtime, etag, isUploaded, [availability,
  pinnedUntil]`. A directory has size 0 and mtime 0.
- **`mkdir`** of an existing folder answers that folder. **`create`** of an existing file replaces it
  with an empty staged file. **`write`** and **`rename`** replace an existing destination. There is
  no exclusive mode **[as built]**.
- **`write`** cancels any upload of the key in flight, adopts the staging file by rename (it is gone
  afterwards), keeps its mtime as the item's mtime, and queues the upload. With `await` it answers
  once the key's upload has left the queue or has started failing (the queue keeps retrying).
- **`share`** publishes a link valid 7 days. A domain whose backends cannot hold a share answers
  `internal` with a sentence.
- **`restore`** fetches every chunk of one file and pins it for 10 days; **`evict`** drops one
  file's chunks and its pin.
- Mutating actions (`create, write, delete, rename, mkdir, rmdir, symlink, revert`) run one at a
  time per domain, and are refused `read_only` on a read-only domain.
- `ensure_cached` writes the whole body to `dest`; `dest` and `staging` are not confined to any
  directory **[as built]**.

How the app reads replies:

- `ok:false` raises an error carrying the reply's `error` sentence (`"request failed"` when absent).
  **The `code` is dropped [as built]**: no caller can tell `not_found` from `unreachable`.
- An empty reply raises "the domain answered nothing"; an unparseable one, "unparseable reply: …".
- The `item` in a mutation reply is ignored; the app finds what it made by listing the parent again
  and matching on name (§7, §8) **[as built]**.

## 6. Configuration and setup

### 6.1 The config the app writes

```json
{ "name": "<Build.MODEL, else 'android'>",
  "domains": [ { "name": "<domain>", "versioning": true, "symlinks": "skip",
    "maxCache": "<cache limit>", "frontends": ["android"],
    "backends": [ { "type": "http-proxy", "name": "server", "role": "main",
                    "url": "<url>", "secret": "<secret>" } ] } ] }
```

The app reads back `domains[0].name`, `domains[0].maxCache` (default `2G`) and
`domains[0].backends[0].{url, secret}`; an unreadable config is "no config". The app shows setup when
no config file exists and the browser when one does.

### 6.2 Setup form

Fields: domain name (free text with a dropdown filled by Check server), server URL, shared secret
(masked), cache limit (blank → `2G`). All are trimmed.

**Save and start**:
1. Validate; the first failure is attached to its field, which takes focus:
   - domain: required; at most 32 characters; no `/` and no control character. The 32-character
     limit is justified by a socket path that no longer exists **[as built]**;
   - URL: required; starts with `http://` or `https://` (cleartext to any host is accepted
     **[as built]**);
   - secret: required (no strength rule **[as built]**).
2. Write the config (pretty-printed, not atomic).
3. Off the UI thread, `check_config`. A refusal is shown as "tsync rejected the config:\n<text>";
   **the rejected config stays on disk [as built]**, so the next launch opens the browser on it.
4. On acceptance, tell the platform the provider's roots changed. If the core is already booted,
   offer the restart of §3.1; else open the browser.

Back from the form returns to the browser when a config existed on entry.

### 6.3 Check server

The one request the app makes itself, before any config exists.

- `GET <url without trailing slashes>/domains`, connect and read timeouts 10 s, through the
  platform's HTTP stack.
- Headers: `x-tsync-timestamp` = epoch seconds; `x-tsync-signature` = lowercase hex of
  HMAC-SHA256(secret, `"GET\n/domains\n<timestamp>\n<hex SHA-256 of the empty body>"`). The signed
  path is `/domains` whatever path the URL carries.
- 200 → the `name` of each element of `domains`. One name fills the domain field ("Server reached,
  serving "<name>""); several open the dropdown ("Server reached — pick a domain"); none: "Server
  reached, but it serves this secret no domain".
- 401 → "the secret was refused (or this device's clock is off)"; 404 → "this server cannot list its
  domains — update tsync on it"; other → "the server answered HTTP <code>". Each is shown after
  "Cannot use this server: ".

## 7. DocumentsProvider

A document id **is** the handler's reference.

- **Roots.** Always one, even when the core cannot boot: root id = the configured domain name
  (`media` with no config), document id `root`, title `tsync`, summary = the domain name, flags
  create and is-child, the launcher icon. The platform is told roots changed when the activity
  starts with a config and when settings are saved.
- **Document.** `root` is synthesised as a directory named `tsync`, never `stat`ed. Otherwise
  `stat`; a failure propagates as an exception. The row's kind is taken from the reference's
  spelling.
  - Folder: directory MIME type; flags create, delete, rename.
  - File: MIME type from the name's extension (default `application/octet-stream`); flags write,
    delete, rename; size.
  - Last-modified = `mtime` in milliseconds, absent when 0.
  - The flags are the same on a read-only domain **[as built]**.
- **Children.** Walk every page of `list_dir` (500 rows per page) into one cursor. On **any**
  failure the cursor holds what was gathered and carries the error "tsync could not reach the server
  for this folder", whatever the cause **[as built]**. The cursor has no notification URI.
- **Is child.** True iff `doc` is `f:<parent's folder id>/…` or `d:<parent's folder id>`: only a
  file directly inside the parent, or the parent itself. A subfolder and everything below it is
  rejected, so a tree grant reaches only the top level **[as built]**.
- **Create.** Leaf = the sanitised display name (§12.5); `mkdir` for the directory MIME type, else
  `create`; then list the parent's first page (1000 rows) and answer the reference of the row with
  that name, failing when it is not on that page **[as built]**. An existing file of that name is
  emptied and an existing folder is answered (§5).
- **Delete.** `rmdir` for a folder reference, `delete` for a file.
- **Rename.** Parent = `stat(doc).parentRef`; `rename(doc, parent, sanitised name)`, replacing any
  item of that name. Answers the unchanged id for a folder; for a file, the reference found by
  listing the parent's first page.
- **Open for reading** (a mode without `w`): boot, `open(ref)` (a negative answer raises its errno),
  retain keep-alive (§9), and return a seekable proxy descriptor. Its callbacks run on one of 4
  fixed callback threads, assigned round-robin per open: get-size → `size`; read → `read` (a negative
  answer raises its errno; a read of 1 s or more is logged); release → `close` and release
  keep-alive. If the descriptor cannot be made, close and release at once. The cancellation signal
  is ignored.
- **Open for writing** (a mode containing `w`):
  1. Take a staging name.
  2. If the mode contains `r` or `a`, assemble the current body into it (`ensure_cached`). On failure
     delete the staging file and refuse the open as file-not-found: starting empty would publish a
     truncated file on close.
  3. Create the staging file if absent and return a read-write descriptor on it with a close
     listener. The descriptor is positioned at 0 and not truncated whatever the mode, so an append
     mode overwrites from the start **[as built]**.
  4. On a close reporting an error: delete the staging file.
  5. On a clean close, on a new thread (the callback threads serve other files' reads):
     `stat(doc)` for its parent and name, then commit (§8). A failure is logged and posted as the
     problem notification "Could not save <document id>: …".
  - Keep-alive is not retained for a write open or its commit **[as built]**.
  - A document renamed, moved or deleted while open fails the `stat` (a file's reference spells its
    parent and leaf), and the edit is dropped **[as built]**.
  - A process death between the close and the commit loses the edit: the staging file is an orphan
    the sweep deletes later (§8) **[as built]**.
- Not implemented: move, copy, remove-from-parent, thumbnails, search, recents, root capacity.
- The platform is never notified of a change by any of the mutations above **[as built]**.

## 8. Ingest

Bytes enter the domain from the app only through commit.

**Commit** `(parent, name, staging, modified?)`:
1. fsync the staging file: adoption is a rename, and unsynced bytes would publish a truncated body
   after a power loss.
2. If `modified` is given, set the staging file's mtime to it; the adopted file's mtime becomes the
   item's.
3. `write` with `await` (§5). On success the core owns the file. On failure the staging file is
   deleted and the failure raised.

An existing item of that name is replaced. `isUploaded` in the reply is not read: a commit succeeds
once the core has adopted the body, whether or not it is uploaded yet.

**Folders by path** `folderFor(path, known)`: for each directory segment of `path` (its last segment
is the file), use `known[path so far]` when present; else find the child of that name in the parent's
first listing page, `mkdir` it when absent and look it up again (failing "could not create …" when it
is still not found), and remember the reference in `known`. A listing that fails is taken as "no
children" **[as built]**. A remembered reference is never checked or dropped **[as built]**.

**Free name** `freeName(parent, name)`: `name` when the parent's first listing page does not hold it,
else the first `<stem> (<n>)<ext>`, n = 1, 2, …, not on that page. `<ext>` starts at the last dot. A
listing that fails is taken as an empty folder, and the check and the write are separate requests, so
an existing file can be replaced **[as built]**.

**Orphan sweep** (run at the start of each camera-backup pass): delete every staging file whose
name-embedded creation time is more than 24 h old. It does not know whether a picker still holds the
file open or a commit is pending **[as built]**. There is no durable record of a staged write: a
write the platform considers finished is lost if the process dies before its commit **[as built]**.

## 9. Keep-alive

Proxy-descriptor reads are answered in the app process, and the platform freezes cached processes:
a player then drains its buffer and waits for ever.

- A process-wide counter: `retain` reports true exactly on 0→1, `release` exactly on 1→0; a release
  at 0 is ignored, so the counter is never negative.
- On 0→1 start the foreground service (data-sync type; low-importance notification "Serving an open
  file" / "Serving N open files", N read once at start); on 1→0 stop it. The service is not sticky.
- A platform refusal to start it is logged and ignored: reads keep working while the process lives.
- On the platform's foreground timeout the service stops itself rather than letting the process be
  killed.
- Retained by each read-only open (released at descriptor release or on a failed open) and by a
  share save from its start until its last commit ends (§10.1).

## 10. User interface

Views are built in code; one activity shows one screen at a time and handles back itself.

### 10.1 Share target ("Save to tsync")

- Streams = `EXTRA_STREAM` of a `SEND`, or the list of a `SEND_MULTIPLE`. None → toast "Nothing to
  save: only files can be saved to tsync" and finish. No config → toast "Set up tsync before saving
  to it" and finish.
- The browser opens in save mode: taps only navigate folders; item actions are off; the heading reads
  "Save N file(s) to /<path>"; the buttons are "Save here" and "Cancel" (finish).
- One file: a "Save as" dialog with the name pre-filled from the stream's display name (else the
  URI's last segment, else "shared file"). Several: each keeps its own name.
- **Save**: retain keep-alive, toast "Saving N file(s)…", then on a worker thread:
  1. copy each stream into its own staging file while the activity holds the read grant; a failed
     copy deletes its staging file and posts "Could not read <name>: …";
  2. **finish the activity**;
  3. for each staged file: leaf = `freeName(folder, sanitised name)`, then commit; a failure posts
     "Could not save <name>: …" and the rest continue;
  4. release keep-alive.
- The activity closes before any file is committed and nothing reports success **[as built]**.

### 10.2 Browser

- A trail of `(reference, name)` from the root. The screen lists the current folder with `list_dir`
  pages of 200, loading the next page when the list scrolls within 10 rows of its end.
- A failed page shows "Cannot read this folder: <error>" and stops paging; an empty folder shows
  "Empty folder".
- Rows: an icon by kind (folder, or image / video / audio / file from the MIME type), the name, and
  "Folder" or the size.
- Folder tap descends; back pops the trail, and leaves the app at the root.
- The listing is read when a folder is shown and never again: not on resume, and there is no refresh
  gesture **[as built]**.
- Buttons: Settings (§6.2), Status (§10.3). Heading: the trail's names joined by `/`, or `tsync`.
- **Item actions** (tap a file, long-press anything):
  - Open (files): a view intent on the provider's document URI with the name's MIME type and a read
    grant, through a chooser; "No app on this phone opens <name>" when nothing takes it.
  - Share link: `share`, then a dialog with the URL and Copy / Send (a text send intent) / Close.
    A failure toasts "Cannot share <name>: …".
  - "Make available offline", or "Keep offline longer" when the row's `availability` is `pinned`:
    `restore`. "Make online only", offered unless `availability` is `online-only`: `evict`. Both
    toast "<name> is available offline" / "<name> is online only" on an ok reply, "Failed: …"
    otherwise.
  - A folder row has no `availability`, so both are offered; they act on one key, which for a folder
    does nothing, and the toast still reports success **[as built]**.

### 10.3 Status and settings

- **Status**: Files and Refresh buttons; monospace text = the camera-backup line (§12.8) followed by
  `status()` verbatim, or "tsync could not start: …" when boot fails.
- **Settings**: the setup form (§6.2) followed by the camera-backup controls (§12.6).

## 11. The `tsync android` command group (desktop)

For shells and tests, on a desktop build that includes the frontend. Arguments are positional; bad
usage prints `tsync android <verb>: <usage>` and exits 2. Each invocation is its own process: it
starts the core, answers, drains the queues and exits. It takes no lock and never forwards to a
running owner **[as built]**.

A verb that sends a mutating action starts the queues and reconciles first; every other verb only
ensures the mirror's root.

| Verb | Request or behaviour |
|---|---|
| `stat REF` | `stat` |
| `list REF [AFTER [LIMIT]]` | `list_dir` |
| `read REF DEST OFFSET LENGTH` | `fetch_range`: the range is written into DEST at the same offset, sparse elsewhere; replies `localPath`, `offset`, `length` served |
| `open REF` | the session below |
| `residency REF` | `{"ok":true,"cached":n,"total":m}`: chunks of REF on this device |
| `fetch REF DEST` | `ensure_cached` |
| `write-whole PARENT NAME STAGING` | `write` with `await` |
| `create PARENT NAME`, `mkdir PARENT NAME` | `create`, `mkdir` |
| `delete REF`, `rmdir REF` | `delete`, `rmdir` |
| `rename SRC PARENT NAME` | `rename` |
| `share REF` | `share` |
| `request JSON` | the request, verbatim: the wire the app speaks |
| `status` | the status text |

`open REF` session: a reference that does not parse prints to stderr and exits 1. First line
`{"ok":true,"size":N}`, or a `not_found` refusal. Then for each input line `"OFFSET LENGTH"` (offset
≥ 0, length > 0): a line `{"ok":true,"length":n}` followed by exactly `n` raw bytes. A malformed line
is answered with an `invalid` refusal and the session continues. End of input ends it. Framing is by
count, never by delimiter.

The frontend's descriptor: serving `Commands` (`tsync start` refuses it), tree `Pulled` (`tsync sync`
refuses it), availability as the core computes it.

## 12. Camera backup

### 12.1 Principle

Photos and videos under DCIM are copied into `Camera Uploads/` in the domain. Progress is a
**per-volume watermark** plus a **record per media item**. The domain is never asked whether a photo
exists: the device's records are authoritative, so a photo deleted from the domain is not uploaded
again.

### 12.2 Records

```sql
CREATE TABLE media (media_id INTEGER PRIMARY KEY, volume TEXT NOT NULL,
  relative_path TEXT NOT NULL, size_bytes INTEGER NOT NULL,
  modified_seconds INTEGER NOT NULL, state TEXT NOT NULL,   -- 'DONE' | 'FAILED'
  attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT, updated_at INTEGER NOT NULL);
CREATE UNIQUE INDEX media_path ON media(relative_path);
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
  -- 'watermark.<volume>.generation', 'watermark.<volume>.dateAdded'
CREATE TABLE dirs (path TEXT PRIMARY KEY, ref TEXT NOT NULL);
```

- `relative_path` is the item's target in the domain, frozen at first sight.
- Every write is insert-or-replace: a new media id claiming a recorded target replaces the old row.
- A state other than `DONE` reads as `FAILED`. `attempts` is never written.
- `dirs` is the persisted `known` map of `folderFor` (§8). An upgrade drops and recreates only
  `dirs`.
- A missing watermark reads as `(0, 0)`.

### 12.3 A sweep

For each volume (every external volume name; the single external volume below API 29):

1. Read the volume's watermark, and its current media-store generation (0 below API 30).
2. For the image collection, then the video collection:
   1. Query rows under DCIM at any depth (`RELATIVE_PATH LIKE 'DCIM/%'`; below API 29
      `DATA LIKE '%/DCIM/%'`) that are newer than the watermark: `GENERATION_MODIFIED` greater than
      its generation on API 30 and up; else `DATE_ADDED` greater than its date-added minus 24 h.
      Ordered by id.
   2. Plan the rows against all records (§12.4).
   3. For each planned action, in order, first check the stop conditions: the job was stopped; the
      run is not user-initiated and the gate blocks (§12.7); 512 MiB or more were staged by this
      sweep; 8 min or more have passed. Any of them ends the **whole sweep** with "more to do",
      saving `known` and **not** moving the watermark.
   4. Skip *already done*: advance the date-added mark to the row's. Skip *still pending* or
      *unsettled*: mark "more to do". Skip *empty*: nothing.
   5. Upload (§12.5). Success: count it, add its size to the staged total, advance the date-added
      mark. Failure: count it.
3. Store the watermark `(generation read in step 1, highest date-added reached)`.

Then save `known`.

On API 30 and up the generation stored in step 3 is the one read before the queries, and it is stored
whatever happened to the rows: a row that was pending, unsettled or failed is not returned by the
next query unless it is modified again, and nothing re-reads `FAILED` records. Such a photo is never
uploaded **[as built]**. Below API 30 the 24 h overlap brings recent rows back.

### 12.4 Planning

Pure and deterministic: the same rows and records give the same plan. Rows are taken in id order.

1. Pending in the media store → skip *still pending*.
2. Size ≤ 0 → skip *empty*.
3. Modified less than 10 s ago → skip *unsettled*.
4. A record exists for the id: `DONE` with the same size and modification time → skip *already
   done*; otherwise upload to the record's target.
5. No record: for sequence 0, 1, … 999, form the candidate name (§12.5):
   - a `DONE` record holds that target with this row's size → skip *already done* (a renumbered id;
     the record keeps its old id);
   - the target is held by no record and no earlier claim in this plan → claim it and upload there.
   With no free name after 1000 tries the sweep fails.

A row's capture time is its date-taken when positive, else its date-added.

### 12.5 Uploading and naming

Upload of one row to a target:

1. Free space in the staging directory less than twice the row's size → fail.
2. `folderFor(target)` (§8).
3. Copy the **original** stream (location metadata kept, where the platform has the notion and
   allows it; else the plain stream) into a staging file. A copied length different from the row's
   size → fail.
4. Commit with `modified` = capture time (§8). Whatever already holds the target name is replaced,
   another device's photo included **[as built]**.
5. Success → record `DONE` with the row's size and modification time. Any failure → delete the
   staging file and record `FAILED` with the error text.

**Target**: `Camera Uploads/<yyyy>/<yyyy-MM-dd HH.mm.ss>[ (n)]<.ext>`.

- Time = capture time in the phone's time zone when the target is first computed.
- `(n)` is the sequence; 0 omits it.
- The extension comes from the display name: the part after the last dot, when the dot is neither
  first nor last and the part is letters and digits only; lower-cased. Otherwise none.
- **Leaf sanitising** (also applied to every name the provider and the share target create): `/`, `\`
  and control characters → `_`; leading whitespace and trailing spaces and dots trimmed; empty →
  `unnamed`.
- Example: `IMG_1234.JPG` captured 2026-08-16 12:31:04 UTC in Paris →
  `Camera Uploads/2026/2026-08-16 14.31.04.jpg`.

### 12.6 Access, enabling and schedule

- **Access level.** API 33 and up: full when both image and video read access are granted;
  selected-only when either one, or the user-selection access (API 34 and up), is; denied otherwise.
  Below: full when external-storage read is granted, else denied.
- **Requested together**: the read permissions for the API level, media-location access (API 29 and
  up), notifications (API 33 and up).
- **Controls**: "Back up camera photos and videos", "Only over wifi" (default on), "Not when the
  battery is low" (default on), "Back up now".
- **Enabling.** Ticking the box sets `enabled` at once and asks "Everything" or "From now on" (not
  dismissable). "From now on" first moves every volume's watermark to (current generation, newest
  date-added) — on the UI thread, before any permission is granted, with a query whose `LIMIT` in
  the sort order recent platforms reject **[as built]**. Then the permissions are requested; denied →
  toast "tsync cannot back up photos without access to them"; selected-only → toast "Only the photos
  you selected will be backed up"; and the schedule is enabled when anything is readable. `enabled`
  stays set when access is denied **[as built]**.
- **Disabling** cancels the three jobs.
- **Schedule**, three unique jobs sharing one pass lock:
  - *watch*: one-shot, triggered by changes under the external image and video collections
    (descendants included), update delay 10 s, maximum delay 300 s; replaces any previous one;
    exponential backoff from 5 min; re-enqueued at the end of every pass, since a trigger fires once;
  - *periodic*: every 6 h; updated in place; exponential backoff from 15 min;
  - *now*: one-shot, no constraints, user-initiated; kept if one is already enqueued. "Back up now"
    refuses with a toast while backup is off.
  - Constraints of the first two: network unmetered when "Only over wifi" is set, else connected;
    battery not low when "Not when the battery is low" is set; storage not low always. Changing
    either setting while enabled re-enqueues both.

### 12.7 Gate

Checked at the start of a scheduled pass and before every planned action of one. A user-initiated
pass ignores it.

- "Only over wifi" set, and the active network is absent or metered → "waiting for wifi".
- "Not when the battery is low" set, the battery neither charging nor full, and its level below
  15 % → "battery low".

### 12.8 A pass

1. Try the process-wide pass lock; held → success, nothing done.
2. Backup disabled → success. No read access → outcome "photo access not granted", success.
3. Not user-initiated and the gate blocks → outcome = the reason, retry later.
4. Try to become a foreground job (notification "Backing up camera photos"); a refusal is ignored.
5. Orphan sweep (§8), then the sweep (§12.3). With no config the sweep does nothing.
6. Outcome `"<u> uploaded[, <f> failed][, more to do]"`; `settled` = no "more to do" and no failure
   in this pass. "More to do" → retry later; else success. Failures alone do not ask for a retry
   **[as built]**.
7. An exception → outcome "last sweep failed: …", retry later.
8. Always re-enqueue the watch job.

**Status line**: `camera backup: off`, or `camera backup: <state>[ — <last error, 80 chars>][ —
<hold>][ (only the photos you selected)]` and, on the next line, `last sweep: <outcome>`.

- `<state>`: `<n> failed` when any `FAILED` record exists (with the most recent recorded error);
  else `not started yet` (no pass has set `settled`), `more to upload`, or `up to date`.
- `<hold>`: the gate's reason, else `no access to photos` when access is denied.

## 13. Parameters

| Parameter | Value |
|---|---|
| Blocking-call pool | 16 threads |
| Maintenance period | 60 s |
| Proxy-descriptor callback threads | 4 |
| Slow-read log threshold | 1 s |
| Provider listing page | 500 |
| Browser listing page / load-ahead | 200 / 10 rows |
| Default `list_dir` page (child lookups) | 1000 |
| Domain name length | ≤ 32 |
| Default cache limit | `2G` |
| Check-server timeouts | 10 s connect, 10 s read |
| Share link lifetime | 7 days |
| Pin lifetime (`restore`) | 10 days |
| Staging orphan age | 24 h |
| Settle time | 10 s |
| Date-added overlap | 24 h |
| Name sequence bound | 1000 |
| Staged-bytes budget per sweep | 512 MiB |
| Sweep time budget | 8 min |
| Free-space factor | 2 × the item's size |
| Battery floor | 15 % |
| Watch trigger delay / maximum | 10 s / 300 s |
| Periodic interval | 6 h |
| Job backoff (watch / periodic) | exponential from 5 min / 15 min |

## 14. What `main` checks

- **Spawned command group** (`tests/frontends/android`): every verb, one process per call, full
  replies snapshotted; fails when a registered verb is not driven.
- **Lazy tree** (`tests/frontends/android_lazy`): root lists with the mirror wiped and reads only
  root; descending reads only that folder; a file a peer deleted is pruned; a staged file survives a
  pull.
- **Bridge** (`tests/frontends/android_bridge`): the entry points linked in-process; 8 foreign
  threads × 64 reads return exact bytes; a non-JSON request gets the `invalid JSON` reply; a write
  with `await` is sent before it answers; read after close is −9; open of an absent name is −2.
- **JVM** (`:core`): the wire against a real binary through `tsync android request`; leaf
  sanitising; the keep-alive counter; photo naming; the planner.
- **Robolectric** (`:app`): the record store.
- **Device, opt-in**: the media-store queries on an emulator.
- Every Gradle test task fails when it ran zero tests.

Not checked: the provider, the activity, the share target, the worker, the sweep, and everything
marked **[as built]**.

---

Implementation notes for this subsystem: [../ocaml/frontends/android.md](../ocaml/frontends/android.md).
