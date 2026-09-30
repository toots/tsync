# The Android host

Scope: how tsync runs on an Android phone: the app process as the owner of its domain, the embedding
of the core, the DocumentsProvider, the in-app browser and settings, the share target, and camera
backup.

Rules shared by every frontend are owned elsewhere and only referenced here:
- the frontend contract, item references, the item row, error codes, paging and the shared request
  handler: [the frontend contract](../08-frontends.md);
- the process model and domain ownership: [daemon and CLI](../07-daemon-cli.md);
- what the owner's local state is: [local state](../data-model/local-cache.md);
- durability of local writes: [durable queue](../algorithms/durable-queue.md);
- failure kinds and deadlines: [failure model](../algorithms/failure-model.md);
- trust boundaries, TLS and secrets: [security model](../algorithms/security-model.md);
- conflicts: [conflict resolution](../algorithms/conflict-resolution.md).

---

## 1. Problem

tsync on a phone has to do three things differently from the desktop:

1. **Expose a domain to other apps** as documents they can browse, open and write, without a kernel
   filesystem and without a system extension. Android offers a DocumentsProvider (the Storage Access
   Framework): the system picker calls a content provider in the app's process, which answers
   listings and metadata and serves bytes through descriptors it controls.
2. **Survive the platform's process model.** Android kills and freezes processes at will, caps
   foreground-service time, and reaps executed children. A long-lived daemon is the wrong shape. The
   core is a library the app's process hosts, and every operation is resumable from durable state.
3. **Feed content in** from the phone: camera backup, a "Save to tsync" share target, and edits other
   apps make through the picker.

## 2. Ownership and process model

- **The app process owns its domain (P1).** At boot it takes the domain's exclusive ownership lock
  ([07](../07-daemon-cli.md)) and holds it for the life of the process; process death releases it.
  Only this process mutates the domain's local state, and it alone reconciles, runs maintenance and
  resumes deferred work (§3).
- Every component that touches the domain (the provider, activities, workers, services) runs in the
  app's default process. None may be declared in a separate process: a second process would have to
  go through the owner's request interface, and the app offers none.
- There is no daemon, no socket and no stop. Process death is a crash-stop; recovery is the next
  boot's reconcile.
- The app serves exactly one domain: the one its configuration names.
- A desktop build also offers a `tsync android …` command group (§12) for shells and tests. Each
  invocation follows the one-shot rule of [07](../07-daemon-cli.md): it sends its request to the
  domain's owner when one runs, and otherwise takes ownership for its own duration.

## 3. What the owner runs

### 3.1 Boot

Boot is triggered by the first use from any entry point (provider call, activity, worker, share
target), under a process-wide lock, and is idempotent within a process.

1. Install the log sink, set the host environment (§4), refresh the trust store (§4.2).
2. Load and validate the config; take the ownership lock ([07 §2.3](../07-daemon-cli.md#23-the-ownership-lock)); build the domain over the **lazy tree**
   ([04 §3.5](../04-checkout-cache.md#35-the-published-tree-full-and-lazy)).
3. Load the local manifest tree, then report ready. Callers wait for this step only.
4. In the background: reconcile ([wal-and-journal.md](../algorithms/wal-and-journal.md)), start the
   upload and metadata queues, **resume deferred replica and backfill work** left by earlier processes
   ([replication.md](../algorithms/replication.md)), resume ready ingest intents (§9.2), and start the
   maintenance schedule (the same sweeps as any owner, including the deferred rescan).

Saving a changed config while booted offers "Restart now", which finishes every activity and exits the
process, or "Later", which keeps serving the old config until the process dies.

### 3.2 Freshness without a journal poller

The owner runs no journal poller and applies no peer entry. Its only view of what peers did comes from
**pulls**: a pull reads one folder's children from the store and replaces the mirror's view of that
folder, as the lazy tree specifies ([04 §3.5](../04-checkout-cache.md#35-the-published-tree-full-and-lazy)). The rules below bound how stale an
answer can be.

**When the owner pulls.**
1. Every child listing asked for by any client (provider, browser, ingest) pulls that folder first.
2. A mutation that names a child by name (create, mkdir, write, symlink, the destination of a rename)
   pulls the destination folder first unless it was pulled within `pull_freshness`, so that an
   existence check sees peers' entries.
3. Opening a file (for reading or for an edit) reads the file's current manifest from the store and
   updates the mirror's entry, or removes it and answers `not_found` if the store no longer has it.
4. While a child listing handed to the platform stays open, the owner re-pulls that folder every
   `observed_refresh` and, when its children differ from what was handed out, notifies the platform
   that the folder's children changed. The refresh stops when the listing is closed or the process
   leaves the foreground.
5. After every mutation it performs, the owner notifies the platform for each folder whose children
   changed.

**Owed local changes.** A pull MUST NOT undo a local change that is not yet published, and MUST NOT be
skipped because such a change exists. The pulled children are overlaid with the owed work touching that
folder: names an owed operation removes or renames away are hidden, names an owed operation creates or
renames in are shown, and staged entries are kept. A record that cannot be discharged therefore never
freezes a folder.

**Store unreachable.** A listing of a folder pulled before answers the last pulled view, flagged to the
platform as possibly out of date. A folder never pulled answers an error. An open serves the mirror's
version when its bytes can be read.

**Bound.** While the store is reachable, a listing or an open is as fresh as the request, and a listing
on screen is at most `observed_refresh` old. While it is not, staleness is unbounded but always flagged.

Conflicts between this client's unpublished work and peers' changes are settled when the owner
publishes, as the publish side of [conflict resolution](../algorithms/conflict-resolution.md) specifies.

### 3.3 What is left out

- The journal poller and entry application (§3.2), and therefore full resync: `tsync sync` refuses on
  this frontend, as a pulled tree has no replica to rebuild.
- Change events and subscriptions: the platform is notified directly (§3.2).
- Symlinks: the config forces `symlinks: "skip"`; the picker has no symlink.
- Ranged writes and `close`: the only write is whole-body adoption of a staged file (§9).

## 4. Host environment

### 4.1 Contract

Before the core initialises, the host provides:

1. **Home**: the app's private files directory. The config and cache locations derive from it, as on
   Linux with no XDG overrides.
2. **Trust store**: the path of a PEM bundle of the device's trusted certificate authorities (§4.2).
   The core's TLS client uses it for every connection.
3. **A log sink** `(level ∈ {debug, info, warn, error}, message)`, routed to the platform log, installed
   before anything that can fail.
4. The name of the domain to serve (empty = the only one the config names).

The host calls the core from threads it owns (binder threads, descriptor callback threads, worker
threads). The core MUST accept calls from threads it did not create, MUST block only the calling
thread, and MUST apply the per-domain and per-key serialisation of P1 whatever thread a call arrives
on. Boot MUST NOT run on the UI thread.

### 4.2 Trust store

- It holds the system certificate authorities (from the updatable system directory where the platform
  has one, else the system one), taking only complete certificate blocks. User-installed authorities
  are not trusted; a backend that needs a private authority names it explicitly in its config
  ([security-model.md §9](../algorithms/security-model.md#9-tls)).
- Rebuilt at every process start, before boot, written atomically (temporary file, fsync, rename), and
  replaced only when its content differs. A system trust-store update therefore takes effect at the
  next process start.
- A failed rebuild keeps the previous bundle; with no bundle at all, boot fails with a message naming
  the trust store.

## 5. The bridge

All text crosses as **UTF-8 byte arrays**, never platform strings: names may hold characters outside
the Basic Multilingual Plane, which the JVM's native string encoding cannot carry.

| Operation | In | Out | Semantics |
|---|---|---|---|
| `check_config(domain)` | domain | `""` or error text | Loads and validates the config and selects the domain without starting it. Callable before or after boot. |
| `boot(domain)` | domain | `""` or error text | §3.1. Returns once the manifest tree is loaded. |
| `request(json)` | request | reply | One request, one reply, through the shared handler ([08](../08-frontends.md)). |
| `status()` | — | text | The same report as desktop `tsync status` for this domain, with `frontend: android`. |
| `open(ref)` | reference | handle > 0, or −errno | Resolves the file's current version (§3.2 rule 3) and pins it to a new handle. |
| `size(handle)` | handle | size, or −1 | The size of the handle's version. |
| `read(handle, offset, length, dest)` | | bytes served, or −errno | Bytes `[offset, offset+n)` of the handle's version. Short only at end of content; 0 past it. Each handle is its own read stream for read-ahead. |
| `close(handle)` | handle | 0 | Forgets the handle. Idempotent. |

- **A handle serves one version.** Size and bytes both come from the version resolved at open, never
  from a later one. If that version's bytes become unavailable (a staged body replaced meanwhile), reads
  fail with EIO rather than mixing versions.
- Errno values: ENOENT for a reference naming nothing, EBADF for an unknown or closed handle, EACCES,
  ENOSPC, and EIO for anything else. A read's failure kind follows
  [failure-model.md](../algorithms/failure-model.md); an unreachable store is EIO after the read deadline.
- **Every entry is total.** Any failure becomes a reply, an error string or a −errno. Nothing propagates
  into the host: an escaping failure kills the app, which has no supervisor. A request that is not JSON
  is answered `{"ok":false,"code":"invalid","error":"invalid JSON"}`.
- There are no calls from the core to the host other than the log sink and the platform notifications
  of §3.2, which the host performs when a reply or a refresh reports changed folders.

## 6. Requests the app uses

The app speaks the shared handler's actions ([08](../08-frontends.md)): `stat`, `list_dir`, `mkdir`,
`create`, `write` (always with `await`), `delete`, `rmdir`, `rename`, `ensure_cached`, `share`,
`restore`, `evict`.

- **Error codes reach the caller.** The bridge and the app's error type keep the reply's `code`
  through to every caller, which follows
  [failure-model.md §7.2](../algorithms/failure-model.md#72-client-error-codes): it branches on the
  code, never on the prose; an unknown code is `internal`; nothing but `not_found` means "absent", so
  a listing that failed is never an empty folder. `paused` (a share while the domain is paused) is shown
  to the user with the owner's sentence; `busy` cannot occur in the app, which owns its domain.
- **Use the item a mutation returns.** `mkdir`, `create`, `write` and `rename` reply with the resulting
  item; the app takes the reference from there and never re-lists to find it.
- **Looking up one child by name** composes its reference (`f:<parent id>/<leaf>`) and `stat`s it, or,
  for a folder, uses `mkdir` (which answers an existing folder). When a listing is needed it MUST
  follow `next` until the end.
- **Exclusive creation.** Every creation that must not replace an existing item (§8, §11.1, §13.4)
  is requested with `exclusive:true` (`noreplace:true` for a rename); an existing name answers `exists`, and the caller picks the next name
  (`<stem> (<n>)<ext>`, n = 1, 2, …, up to `max_name_attempts`). The name check and the creation are
  one step in the owner, so two concurrent saves never overwrite each other.
- `write` with `await` answers once this key's owed upload has been sent or has started failing; the
  queue keeps retrying in the second case. `isUploaded` in the returned item says which.

## 7. Configuration and secrets

### 7.1 The config the app writes

```json
{ "name": "<device model, else 'android'>",
  "domains": [ { "name": "Family Photos", "versioning": true, "symlinks": "skip",
    "maxCache": "2G", "frontends": ["android"],
    "backends": [ { "type": "http-proxy", "name": "server", "role": "main",
                    "url": "https://tsync.example.org", "secret": "…" } ] } ] }
```

- The setup form offers one http-proxy backend: domain, URL, secret, cache limit (default `2G`).
- Validation, first failure wins and is attached to its field: the domain name follows the grammar of
  [01-core.md](../01-core.md); the URL MUST use `https://` unless its host is a loopback address
  (§7.2); the secret meets the strength rule of
  [security-model.md §10.1](../algorithms/security-model.md#101-generation-and-strength). Then the
  core is asked (`check_config`) whether it accepts the config, and its message is shown verbatim.
- The config is written atomically with owner-only permissions, never readable by other apps.

### 7.2 Cleartext refused

The rule is [security-model.md §9](../algorithms/security-model.md#9-tls): TLS to every host that is
not a loopback address. The core's network traffic does not go through the platform's network stack,
so the platform's cleartext switch does not reach it, and the rule is enforced at configuration:

- The app MUST refuse a cleartext URL to a non-loopback host in the setup form and in `check_config`.
- The core, when running on this host, MUST refuse to connect to such a URL even if a config names
  one.
- The app declares cleartext traffic disallowed to the platform as well, for anything that does go
  through the platform stack (the setup form's own request, §11.2).

### 7.3 Backup and device transfer

The rule is [security-model.md §10.2](../algorithms/security-model.md#102-at-rest): backup and
device transfer exclude the config, the client identity and the domain's local state. On Android the
exclusion also covers the host's own state: the staging directory, ingest intents and camera-backup
records, which describe media and staged work that do not exist on another device. The app SHOULD
disable backup entirely.

## 8. DocumentsProvider

- Authority `org.feverdreamtv.tsync.documents`, guarded by the system-only document-management
  permission.
- **Roots.** Always one root, even when the core cannot boot (a vanished root leaves no way to
  diagnose): root id = the domain name, document id `root`, title `tsync`, summary = domain name,
  supporting create and is-child. The platform is told roots changed after first setup and after
  settings are saved.
- **Document.** `root` is synthesised (a fresh install has no mirror). Otherwise `stat`. Folders: the
  directory MIME type, supporting create, delete and rename. Files: MIME type from the extension
  (default octet-stream), supporting write, delete and rename; size; last-modified = mtime, absent when
  0.
- **Children.** Pull (§3.2), then walk every page of `list_dir` into one result. The result is
  registered for refresh while open (§3.2 rule 4). Failures:
  - `unreachable` with a previously pulled view: that view, with an info message that it may be out of
    date;
  - `unreachable` otherwise: what was gathered, with an error message that the server could not be
    reached;
  - `not_found`: the folder no longer exists (the platform is told the parent changed);
  - any other code: an error message naming the failure.
- **Is child.** `isChildDocument(parent, doc)` is true iff walking `doc`'s `parentRef` chain upward
  through `stat` reaches `parent`. The walk stops false at the root, on any failure, and after
  `max_tree_depth` steps. Tree grants therefore reach every descendant.
- **Create.** Leaf = the sanitised display name (§13.5); `mkdir` or `create`, exclusive, numbering on
  `exists` (§6). Answers the created item's reference.
- **Delete.** `rmdir` for folder references, `delete` for files.
- **Rename.** Parent = `stat(doc).parentRef`; `rename(doc, parent, sanitised name)` with `noreplace:true`; an
  existing name is refused to the caller. Answers the reference from the reply's item (a folder's is
  unchanged; a file's is new).
- **Open for reading** (a mode without `w`): `open(ref)`, retain keep-alive (§10), and return a
  seekable proxy descriptor whose callbacks run on a small fixed set of callback threads, one
  assigned per open: get-size → `size`, read → `read` (a negative answer raises the errno),
  release → `close` and release keep-alive. If the descriptor cannot be made, close and release at once.
  Each open file's reads are serialised on its thread.
- **Open for writing** (`w`, `wt`, `rw`, `wa`, …):
  1. Create a staging file and a durable ingest intent for it (§9.2) naming the item's parent and name.
  2. If the mode contains `r` or `a`, assemble the current body into the staging file
     (`ensure_cached`). On failure, delete staging and intent and refuse the open: starting empty
     would publish a truncated file on close.
  3. Return a read-write descriptor on the staging file with a close listener.
  4. On a close reporting an error: delete staging and intent (a truncated write is worse than a dropped
     edit).
  5. On a clean close: mark the intent ready (durably), then commit on a thread that does not serve
     descriptor reads (§9.1). A failure is logged and notified to the user.

## 9. Ingest

Bytes enter the domain from the app only through ingest.

### 9.1 Commit

`commit(parent, name, staging, modified?, exclusive?, base?)`:
1. fsync the staging file: adoption is a rename, and unsynced bytes would publish a truncated body after
   a power loss.
2. If `modified` is given, set the staging file's mtime to it; the adopted file's mtime becomes the
   item's mtime, which is how a photo keeps its capture time.
3. `write` with `await`, the given exclusivity and base. On success the core owns the file; on failure
   the caller decides whether the staging file is kept (a ready intent) or deleted.

### 9.2 Ingest intents

A write the platform considers finished (a picker's clean close, a share the user confirmed) is
acknowledged before the owner can commit it. To keep P2, each staging file has a durable intent record:
`{staging name, parent reference, name, exclusive, modified?, state: open | ready}`.

- The intent is written before the staging file is handed to anyone; it becomes `ready` before the
  platform is told the operation succeeded, or, for a picker close, as the first step of the close
  listener.
- Boot resumes every `ready` intent by committing it, then deletes it. An `open` intent at boot is an
  interrupted write and is discarded with its staging file.
- A parent that no longer exists at resume time commits to the domain root under the same name,
  exclusive, and notifies the user.
- The staging sweep deletes only staging files that no intent names and whose name-embedded creation
  time is older than `staging_orphan_age`. The creation time is in the name because adoption rewrites
  the file's mtime.

### 9.3 Folders by path

`folderFor(path)` resolves each directory segment with `mkdir` (which answers an existing folder, after
the pull of rule 2 in §3.2) and takes the reference from the reply. A cache of path → folder reference
MAY avoid repeated requests; a cached reference that answers `not_found` is dropped and the path
resolved again.

## 10. Keep-alive

Proxy-descriptor reads are answered in the app process, and the platform freezes cached processes: a
player then drains its buffer and waits forever.

- A process-wide counter of open work: `retain` returns true exactly on 0→1, `release` exactly on 1→0;
  a release at 0 is ignored, so the counter is never negative.
- On 0→1 start a foreground service (data-sync type, low-importance notification "Serving N open
  files"); on 1→0 stop it.
- A platform refusal to start it (background restrictions, an exhausted daily budget) is logged and
  ignored: reads keep working while the process lives.
- On the platform's foreground timeout the service stops itself rather than letting the process be
  killed.
- Retained by each read-only open (released at descriptor release or failed open) and by each share
  save until its last commit.

## 11. User interface

### 11.1 Share target ("Save to tsync")

- The launcher activity accepts single and multiple sends of any type carrying streams. No streams →
  "only files can be saved"; no config → "Set up tsync before saving to it".
- The browser opens in save mode: taps only navigate folders; the header reads "Save N files to
  /path"; "Save here" and "Cancel".
- One file: an editable "Save as" name pre-filled with the stream's display name (else the last URI
  segment, else "shared file"). Several: each keeps its own name.
- **Save**: retain keep-alive; on a worker thread, while the activity still holds the read grant, copy
  each stream into its own staging file with an intent, and commit it (exclusive, numbering on
  `exists`). The activity reports success and closes only once **every** file is committed or has a
  ready intent (§9.2); until then it shows progress. Per-file failures are reported; the rest continue.
  Release keep-alive when the last commit ends.

### 11.2 Browser and settings

- The browser keeps a trail of `(reference, name)` and lists `list_dir` pages,
  loading the next page near the end. Folder tap descends; back pops. It pulls again when resumed and
  on a pull-to-refresh gesture.
- Item actions:
  - files: Open (view intent on the provider URI with a read grant);
  - files and folders: Share link (`share`, then copy or send); Make available offline / Keep offline
    longer (`restore`); Make online only (`evict`).
  - `restore` and `evict` on a folder act on its whole subtree, as
    [08 §3.4](../08-frontends.md#34-evict-and-restore) specifies; on the lazy tree, `restore` first
    pulls each folder of the subtree so that the subtree is the one the store holds. The confirmation
    states the reply's counts of files done and failed; a failure is never reported as success.
- Status screen: the camera-backup line and the `status()` text verbatim.
- Setup form (§7.1), then camera-backup controls.
- **Check server** is the one request the app makes itself, before any config exists: `GET
  <url>/domains` over HTTPS through the platform stack, signed as the http-proxy wire specifies
  ([backends/http-proxy.md](../backends/http-proxy.md)), with a `check_server_timeout`. 200 → offer the
  listed domains; 401 → "secret refused (or clock off)"; 404 → "server too old to list domains".

## 12. The `tsync android` command group (desktop)

For shells and tests on a desktop build. Arguments are positional; bad usage exits 2. Each invocation
follows §2's one-shot rule, answers through the same handler and bridge semantics, drains, and exits.

`stat REF`, `list REF [AFTER [LIMIT]]`, `read REF DEST OFFSET LENGTH` (writes the range into DEST at
the same offset, sparse elsewhere), `open REF` (session below), `residency REF` →
`{"ok":true,"cached":n,"total":m}`, `fetch REF DEST`, `write-whole PARENT NAME STAGING` (with await),
`create`, `mkdir`, `delete`, `rmdir`, `rename SRC PARENT NAME`, `share REF`, `request JSON`, `status`.

Only mutating verbs start the queues and reconcile; read-only verbs only load the manifest tree.

`open REF` session: first line `{"ok":true,"size":N}` or a refusal; then for each input line
`"OFFSET LENGTH"` (offset ≥ 0, length > 0) a line `{"ok":true,"length":n}` followed by exactly `n` raw
bytes; a malformed line is answered with an `invalid` refusal and the session continues; end of input
ends it. Framing is by count, never by delimiter.

## 13. Camera backup

### 13.1 Principle

Every photo or video captured into DCIM while backup is enabled is eventually uploaded, however long it
takes to settle and however many attempts fail. Progress is carried by a **durable record per media
item**; the discovery mark only decides where the next discovery query starts, and never whether an
item is uploaded.

### 13.2 Records

One record per media item, keyed by its media id, with a unique target path:

| Field | Meaning |
|---|---|
| volume, media id | the item's identity in the media store |
| target | the domain path it is (or will be) uploaded to; frozen at first sight |
| size, modified | the item's values when last seen, and when uploaded for `DONE` |
| etag | the content identity the upload produced; writers MUST record it with `DONE`. Readers SHOULD accept a record without it (meaning unknown: a re-upload then carries no `base`) |
| state | `PENDING` (seen, not yet uploaded), `DONE` (adopted by the core), `FAILED` (last attempt failed), `BASELINE` (existed when backup was enabled "from now on"; never uploaded). Writers MUST NOT produce another value; readers SHOULD accept one, meaning `FAILED` |
| attempts, next attempt, last error | retry bookkeeping for `FAILED`; writers MUST record the next attempt with `FAILED`. Readers SHOULD accept a record without it, meaning due now |

Per volume, a **discovery mark**: the highest modification generation discovered where the platform
has one, else the highest date-added (0 when there is no mark); the media store's version string for
the volume; and the time of the last full discovery. Writers MUST record the version string and the
full-discovery time with every mark they write (steps 1 and 4 of §13.3). Readers SHOULD accept a mark
without the version string (meaning unknown, never a mismatch) and without the full-discovery time
(meaning a full discovery is due).

**A row below the mark without a record.** Writers MUST NOT produce this state: discovery records
every row it passes (§13.3). Readers SHOULD accept it, meaning a row passed without being recorded; a
full discovery that finds one records it:
- `PENDING` if its date-added is later than `date_added_lookback` before the oldest record's update
  time, or if there is no record at all and the mark is 0 (a backfill that never completed): it was
  captured while backup was running;
- `BASELINE` otherwise: it existed before backup started.

Opening the record store never rewrites a record; a record is rewritten only when its item's state
changes.

A folder cache (target folder path → folder reference) MAY be kept; it is disposable.

### 13.3 Discovery

A discovery pass, per volume:

1. If the mark's version string is known and differs from the volume's, or the volume's current
   generation is lower than the mark's, reset the mark (the media store was rebuilt). Record the
   volume's version string.
2. Query DCIM at any depth (OEM cameras use their own subfolders) for rows newer than the mark:
   modification generation greater than the mark's where available; else date-added greater than the
   mark minus `date_added_lookback`, since date-added is not monotonic.
3. For each row, in one transaction with the mark's advance to the highest value seen:
   - no record and no `DONE` record with the same target and size (a renumbered id) → insert `PENDING`
     (or `BASELINE` during a "from now on" baseline pass);
   - a renumbered `DONE` record → re-key it to the new id;
   - an existing `DONE` record whose size or modification changed → `PENDING` (re-upload to the same
     target);
   - an existing `PENDING` or `FAILED` record → update size and modification.
4. When the last full discovery is unknown or older than `full_discovery_interval`, run the query
   without the mark, to catch anything else, and record its time.

Because every row is recorded in the transaction that moves the mark, no row is ever behind the mark
without a record.

### 13.4 Processing

Records in `PENDING`, and in `FAILED` whose next attempt is due, are processed in capture order:

1. Re-read the row by id. Gone → delete the record. Still pending in the media store, or modified less
   than `settle_time` ago → leave it and report more work.
2. Check the budgets (§13.6) and the gate (§13.7); if either says stop, stop the pass with more work.
3. `folderFor(dir of target)`; copy the **original** stream (with location metadata) into a staging
   file with an intent; a copied length different from the row's size is a failure.
4. Commit with `modified` = capture time:
   - a first upload is exclusive: on `exists` (another device's photo holds the name) the target moves
     to the next sequence name (§13.5) and is frozen there;
   - a re-upload of a `DONE` record carries `base` = the recorded etag, so a file someone else put at
     the target meanwhile is kept, as [conflict resolution](../algorithms/conflict-resolution.md)
     specifies.
5. Success → `DONE` with size, modification and etag. Failure → `FAILED`, attempts + 1, next attempt =
   now + `retry_backoff(attempts)`, last error.

`FAILED` is never terminal: the item is retried until it succeeds or leaves the device.

The domain is never asked whether a photo exists: the device's record is authoritative, so a photo the
owner deleted from the domain is not uploaded again.

### 13.5 Naming

`Camera Uploads/<yyyy>/<yyyy-MM-dd HH.mm.ss>[ (n)]<.ext>` under the domain root.

- Time = capture time (date-taken, else date-added), formatted in the phone's time zone **at first
  sight** and frozen in the record: re-computing after travel would duplicate.
- `(n)` distinguishes captures sharing a second and names already taken (by a record, by an earlier
  claim in the same pass, or by `exists` at upload); 0 omits it; up to `max_name_attempts`.
- The extension is taken from the display name (not the MIME type): the part after the last dot, when
  the dot is neither first nor last and the part is letters and digits only; lower-cased. Otherwise none.
- **Leaf sanitising** (also used for every name the app creates): `/`, `\` and control characters → `_`;
  leading whitespace and trailing spaces and dots are trimmed; empty → `unnamed`.
- Example: `IMG_1234.JPG` captured 2026-08-16 12:31:04 UTC in Paris →
  `Camera Uploads/2026/2026-08-16 14.31.04.jpg`.

### 13.6 Budgets

Per pass: the staged bytes the core still owes for this domain SHOULD stay under a bound the
implementation chooses, since staged bodies are not covered by the cache limit and fill the phone's
storage while the store is unreachable; running time at most `pass_time_budget` (the platform stops jobs after
about ten minutes); free space in the staging directory at least twice the item's size.

### 13.7 Access, gate and schedule

- **Access level**: full when both image and video read access are granted (or, on older platforms,
  external-storage read); selected-only when only a user selection is readable; denied otherwise.
  Media-location access and notification permission are requested too. Selected-only is reported as a
  limit, not a stall.
- **Enabling**: "Everything" (backfill) or "From now on". For "From now on", once read access is
  granted and off the UI thread, a discovery pass records every existing row as `BASELINE`; if that pass
  cannot complete, backup is not enabled and the user is told why. Turning backup off cancels all work.
- **Gate**, re-checked before each upload: when unmetered-only is set and the active network is metered
  or absent → "waiting for wifi"; when battery-ok is set, not charging, and the level is below
  `battery_floor` → "battery low". A user-initiated run ignores the gate.
- **Schedule** (three unique jobs, which may run concurrently but share one pass lock):
  - on media changes: a one-shot job triggered by changes under the image and video collections
    (update delay `trigger_delay`, maximum delay `trigger_max_delay`), re-enqueued at the end of every
    run since a trigger fires once;
  - periodic, every `periodic_interval`;
  - run now (user-initiated), without constraints.
  Constraints for the first two: network unmetered if unmetered-only else connected; battery not low if
  battery-ok; storage not low always. Changing a setting re-enqueues with the new constraints.

### 13.8 A pass

1. Try the process-wide pass lock; if another pass holds it, return success (two passes would plan from
   the same records).
2. Disabled → success. No read access → outcome "photo access not granted", success.
3. Not user-initiated and the gate blocks → outcome = the reason, retry later.
4. Try to become a foreground job ("Backing up camera photos"); a refusal is ignored.
5. Sweep orphan staging files (§9.2). Discovery (§13.3), then processing (§13.4), stopping when the job
   is stopped.
6. Outcome `"<u> uploaded[, <f> failed][, more to do]"`. Settled = no `PENDING` or `FAILED` record. More
   work or due retries → retry later; else success. An unexpected failure → outcome "last sweep failed:
   …", retry later. Always re-enqueue the media-change job.

Status line: `off` | `<n> failed — <last error>` | `not started yet` | `<n> waiting to upload` |
`up to date`, plus the hold reason, "(only the photos you selected)", and the last outcome.

## 14. Parameters

| Parameter | Recommended | Constraint |
|---|---|---|
| `pull_freshness` | 5 s | |
| `observed_refresh` | 30 s | ≥ 5 s |
| `max_tree_depth` | 4096 | |
| `max_name_attempts` | 1000 | |
| `staging_orphan_age` | 24 h | |
| `check_server_timeout` | 10 s | |
| `settle_time` | 10 s | |
| `date_added_lookback` | 24 h | |
| `full_discovery_interval` | 7 days | |
| `retry_backoff(n)` | min(15 min × 2^(n−1), 6 h) | bounded |
| `pass_time_budget` | 8 min | time budget below the platform's job limit |
| `battery_floor` | 15 % | |
| `trigger_delay` / `trigger_max_delay` | 10 s / 300 s | |
| `periodic_interval` | 6 h | |

## 15. Conformance

An implementation MUST exhibit these properties; [09-tests.md](../09-tests.md) says how they are
checked. Properties of the shared handler are [08](../08-frontends.md)'s.

**Ownership and boot**
- A second process cannot own the domain while the app does; the desktop command group forwards to a
  running owner and otherwise owns the domain for its duration.
- Deferred replica or backfill work and ready ingest intents left by a killed process are completed
  after the next boot.
- Every bridge entry is total; a non-JSON request is answered with the exact `invalid JSON` reply.
- Concurrent reads from foreign threads return exact bytes; a read after close is −EBADF; an open of an
  absent reference is −ENOENT; a handle keeps serving the version it opened.

**Freshness**
- With the mirror wiped, listing root works without any sync and reads only root; descending reads only
  that folder.
- A file a peer deleted disappears from the next listing and from the mirror; a peer's new file appears.
- A locally created, unpublished file survives a pull; a locally removed, unpublished file is not listed
  back; a folder with a metadata record that cannot be published is still refreshed from the store.
- Offline, a previously listed folder is served with the out-of-date flag; a never-listed folder errors.

**Names and writes**
- A share-sheet save, a document creation and a first camera upload never replace an existing item,
  including in a folder with more entries than one listing page and under concurrent saves of one name.
- `write` adopts the staging file (it is gone afterwards), keeps its mtime, and with await answers
  uploaded.
- Every surfaced failure carries its code; a failed listing is never taken as an empty folder.
- `isChildDocument` is true for every descendant of a tree root and false for anything else.
- Folder evict and restore act on every file of the subtree and report counts.

**Secrets and transport**
- The config, client identity and core state are excluded from backup and device transfer.
- A cleartext backend URL to a non-loopback host is refused by the form, by `check_config` and by the
  core.
- A trust-store change on the device is picked up at the next process start.

**Camera backup**
- A photo captured, unsettled at the first pass and unchanged afterwards is uploaded by a later pass.
- A photo whose upload failed is retried until it succeeds, across passes and process restarts.
- A media store rebuild (new version string or lower generation) loses no photo and re-uploads none.
- Renumbered ids with the same target and size are recognised; renumbered different content gets a new
  sequence name; a name clash with another device's photo takes the next sequence name.
- "From now on" uploads nothing that existed when it was enabled; "Everything" uploads it all.
- Records with only some optional fields, and a mark without its optional parts, are used as they
  are; a row below the mark without a record, captured while backup was running, is uploaded.
- The planner is deterministic: the same records and rows give the same plan.
- The share target reports success only after every file is committed or has a ready intent.

## 16. Rationale (do not undo)

- **Linked core, not a daemon or a process per call.** Android reaped the daemon; per-call processes
  had no read-ahead state and could not be ordered against the upload queue.
- **Pulled tree.** A host without long-lived state cannot keep a replica: rebuilding one leaves
  document ids unresolvable until the rebuild ends.
- **Read-ahead keyed by handle, not by file.** A probe elsewhere in the file must not reset a sequential
  reader.
- **Edit opens that cannot fetch the current body are refused.** Starting empty published truncations.
- **Commit off the descriptor thread.** A commit waits for the upload; the callback thread serves other
  files' reads.
- **The service stops itself on the platform timeout.** Letting the timeout fire crashed the app in a
  loop.
- **Per-item records, not a watermark.** A watermark stored at the end of a pass skipped every photo
  that was unsettled or failed during it, silently and forever.
- **Exclusive creation in the owner, not check-then-write in the app.** A lookup that read one page, or
  took an error for "absent", overwrote existing files.

---

Implementation notes for this subsystem: [../ocaml/frontends/android.md](../ocaml/frontends/android.md).
