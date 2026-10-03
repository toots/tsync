# The Android application

Scope: the Android app built on the [Android frontend](android.md): how it hosts the core, its
configuration, the DocumentsProvider, ingest, keep-alive, the user interface, the share target,
camera backup, and how it is built. The core side (ownership, the lazy tree, working without the
store, the bridge) is [android.md](android.md); how the app is tested and released in CI is
[10](../10-delivery.md).

Rules owned elsewhere and only referenced here:
- the actions, item rows and references the app sends and reads: [08](../08-frontends.md);
- what each error code tells a client: [failure-model.md §7.2](../algorithms/failure-model.md#72-client-error-codes);
- durability of handed-over writes: [durable queue](../algorithms/durable-queue.md);
- TLS, secrets and backup exclusion: [security model](../algorithms/security-model.md).

---

## 1. Problem

The app has to do four things with one process the platform may kill at any moment:

1. **Expose the domain to other apps** as documents they can browse, open and write, through the
   Storage Access Framework: the system picker calls a content provider in the app's process.
2. **Be a usable file browser of its own**, including when the phone is offline.
3. **Feed content in**: a "Save to tsync" share target, uploads picked in the app, edits other apps
   make through the picker, and camera backup.
4. **Never lose a write the platform considers finished**, and never overwrite a file it was not
   asked to replace.

## 2. Components and process

| Component | Role |
|---|---|
| Main activity | Launcher; also the target of single and multiple sends of any type carrying streams, labelled "Save to tsync". Hosts every screen of §10. |
| Documents provider | Authority `org.feverdreamtv.tsync.documents`, guarded by the system-only document-management permission (§7). |
| Keep-alive service | A foreground service of the data-sync type (§9). |
| Backup worker | A scheduled job running one camera-backup pass (§11). |

- Every component runs in the app's default process and calls the core through the bridge
  ([android.md §5](android.md#5-the-bridge)). None may be declared in a separate process: a second
  process could not reach the owner, which serves no socket.
- The app serves exactly one domain: the one its config names.
- **Boot** is triggered by the first use from any entry point, never on the UI thread, and is the
  bridge's `boot` ([android.md §3.1](android.md#31-boot)). After it reports ready the app resumes
  ready ingest intents (§8.2).
- **Notices** ([android.md §4.2](android.md#42-notices)): on `changed`, tell the platform that each
  named folder's children changed (§7) and refresh the browser when it shows one of them (§10.3); on
  `recovered`, clear the offline state and refresh.

## 3. Local state

| Thing | Value |
|---|---|
| Home | the app's private files directory |
| Trust bundle | `<home>/ca-bundle.pem` (§4) |
| Staging and transfer root | `<home>/staging/`, files `<epochMillis>-<uuid>` |
| Ingest intents | `<home>/intents/`, one record per staging file (§8.2) |
| Camera-backup settings and records | app-private preferences and database (§11.2) |
| Notification channels | "Camera backup" (low), "Open files" (low), "Problems" (default) |

- A staging name carries its creation time, because commit rewrites the file's mtime.
- Every notification about a problem has its own identity (the item it concerns), so one never
  replaces another; tapping it opens the Activity screen (§10.5).
- Notification permission is requested the first time the app would post a notification the user
  needs to see (a problem, or enabling camera backup), not only in the camera-backup flow.

## 4. Trust store

The bundle the core is given ([android.md §4.1](android.md#41-what-the-host-provides)):

- It holds the system certificate authorities (from the updatable system directory where the
  platform has one, else the system one), taking only complete certificate blocks. User-installed
  authorities are not trusted; a backend that needs a private authority names it in its config
  ([security-model.md §9](../algorithms/security-model.md#9-tls)).
- Rebuilt at every process start, before boot, written atomically (temporary file, fsync, rename),
  and replaced only when its content differs. A system trust-store update therefore takes effect at
  the next process start.
- A failed rebuild keeps the previous bundle; with no bundle at all, boot fails naming the trust
  store.

## 5. Talking to the core

- **Error codes reach the caller.** The app's error type keeps the reply's `code` through to every
  caller, which branches on the code, never on the prose; an unknown code is `internal`; nothing but
  `not_found` means "absent", so a listing that failed is never an empty folder.
- **Use the item a mutation returns.** `mkdir`, `create`, `write` and `rename` reply with the
  resulting item; the app takes the reference from there and never re-lists to find it.
- **Looking up one child by name** is `stat` by `parentRef` and `name`. When a listing is needed it
  MUST follow `next` until the end.
- **Kind, writability and state come from the row** (`kind`, `readOnly`, `availability`,
  `isUploaded`), never from how a reference is spelled.
- **Exclusive creation.** Every creation that must not replace an existing item (§7, §10.4, §10.6,
  §11.4) is requested with `exclusive: true` (`noreplace: true` for a rename). On `exists` the
  caller picks the next name, `<stem> (<n>)<ext>`, n = 1, 2, …, up to `max_name_attempts`; `<ext>`
  starts at the last dot when that dot is not the first character. The name check and the creation
  are one step in the owner, so two concurrent saves never overwrite each other.
- **Offline.** A listing reply's `outdated` and `pulledAt`
  ([android.md §3.2](android.md#32-freshness-without-a-journal-poller)) are shown, never hidden
  (§7, §10.3). An `unreachable` answer puts the app in the offline state until a later successful
  reply or the `recovered` notice.

## 6. Configuration and secrets

### 6.1 The config the app writes

```json
{ "name": "<device model, else 'android'>",
  "domains": [ { "name": "Family Photos", "versioning": true, "symlinks": "skip",
    "maxCache": "2G", "frontends": ["android"],
    "backends": [ { "type": "http-proxy", "name": "server", "role": "main",
                    "url": "https://tsync.example.org", "secret": "…" } ] } ] }
```

- The app configures one domain backed by one http-proxy server: URL, secret, domain, cache limit
  (default `2G`).
- **Validation**, first failure wins and is attached to its field:
  1. the URL MUST use `https://` unless its host is a loopback address
     ([android.md §4.1](android.md#41-what-the-host-provides));
  2. the secret meets the strength rule of
     [security-model.md §10.1](../algorithms/security-model.md#101-generation-and-strength);
  3. the domain name follows the grammar of [01-core.md](../01-core.md);
  4. the core accepts the candidate (`check_config`); its message is shown verbatim.
- **A config the core refused is never the app's config.** The candidate is written beside the
  config, checked, and renamed over it only when accepted; a refused candidate is deleted.
- The config is written atomically with owner-only permissions.
- Saving a changed config while the core is booted offers "Restart now", which finishes every
  activity and exits the process, or "Later", which keeps serving the old config until the process
  dies. The platform is told the provider's roots changed either way.

### 6.2 Check server

The one request the app makes itself, before any config exists: `GET <url>/domains` through the
platform's network stack, signed as the http-proxy wire specifies
([backends/http-proxy.md](../backends/http-proxy.md)), with `check_server_timeout`. 200 → offer the
listed domains; 401 → "secret refused (or this device's clock is off)"; 404 → "this server is too
old to list its domains", and the domain name is typed instead. The app declares cleartext traffic
disallowed to the platform, which covers this request.

### 6.3 Backup and device transfer

The rule is [security-model.md §10.2](../algorithms/security-model.md#102-at-rest). The app disables
platform backup and device transfer entirely: the config, the client identity, the domain's local
state, the staging directory, ingest intents and camera-backup records all describe this device.

## 7. Documents provider

A document id is the item's reference. File references are `i:` references
([08 §2.2](../08-frontends.md#22-item-references)), so a document id survives a rename and a move.

- **Roots.** Always one root, even when the core cannot boot (a vanished root leaves no way to
  diagnose): root id = the domain name, document id `root`, title `tsync`, summary = the domain
  name, supporting is-child, and create unless the domain is read-only.
- **Document.** `root` is synthesised (a fresh install has no mirror). Otherwise `stat`.
  - Folder: the directory MIME type; supports create, delete, rename and move.
  - File: MIME type from the name's extension (default octet-stream); supports write, delete,
    rename and move; size; last-modified = `mtime`, absent when 0.
  - A row carrying `readOnly` supports none of create, write, delete, rename or move.
- **Children.** Walk every page of `list_dir` into one result, registered on the folder's
  notification address so a `changed` notice refreshes it. While the result is open the folder is
  **observed** (§7.1).
  - `outdated`: the rows, with the info message "Offline: showing this folder as of <time>".
  - `unreachable`: no rows, with the error "Cannot reach the server".
  - `not_found`: the folder no longer exists; the platform is told its parent changed.
  - any other code: the error message naming the failure.
- **Is child.** True iff walking the document's `parentRef` chain upward through `stat` reaches the
  parent. The walk stops false at the root, on any failure, and after `max_tree_depth` steps. Tree
  grants therefore reach every descendant.
- **Create.** Leaf = the sanitised display name (§11.5); `mkdir` or `create`, exclusive, numbering
  on `exists` (§5). Answers the created item's reference.
- **Delete.** `rmdir` for a folder, `delete` for a file.
- **Rename.** `rename(doc, stat(doc).parentRef, sanitised name)` with `noreplace: true`; an existing
  name is refused to the caller. Answers the reference from the reply's item.
- **Move.** `rename(doc, target parent, the document's current name)` with `noreplace: true`; a
  name taken in the target is refused to the caller, as is a folder moved into itself or its own
  subtree. Answers the reference from the reply's item, which is the document's own: a move changes
  no document id.
- **Open for reading** (a mode without `w`): `open(ref)`, retain keep-alive (§9), and return a
  seekable proxy descriptor whose callbacks run on a small fixed set of callback threads, one
  assigned per open: get-size → `size`; read → `read` (a negative answer raises its errno);
  release → `close` and release keep-alive. If the descriptor cannot be made, close and release at
  once.
- **Open for writing** (a mode containing `w`):
  1. Retain keep-alive. Create a staging file and a durable ingest intent for it (§8.2) naming the
     document's reference.
  2. If the mode contains `r` or `a` and does not truncate, assemble the current body into the
     staging file (`ensure_cached`) and record the reply item's `contentId` as the intent's `base`.
     On failure, delete staging and intent and refuse the open: starting empty would publish a
     truncated file on close. A truncating open records as `base` the `contentId` of `stat`.
  3. Return a read-write descriptor on the staging file with a close listener, positioned as the mode
     says (at the end for an append mode).
  4. On a close reporting an error: delete staging and intent (a truncated write is worse than a
     dropped edit).
  5. On a clean close: mark the intent ready, durably, as the first step of the listener; then
     commit (§8.1) on a thread that does not serve descriptor reads. A failure is posted as a
     problem notification and the intent stays ready.
  6. Release keep-alive when the commit ends or the staging file is deleted.
- **Not provided**: copy, thumbnails, search, recents.

### 7.1 Observed folders

A folder is observed while a children result handed to the platform is open, or while the browser
shows it in the foreground. Every `observed_refresh` the app lists each observed folder again; the
owner pulls it and sends a `changed` notice when its children differ. The refresh stops when nothing
is observed. A listing on screen is therefore at most `observed_refresh` old while the store answers.

## 8. Ingest

Bytes enter the domain from the app only through ingest.

### 8.1 Commit

`commit(target, staging, modified?, exclusive?, base?)`, where the target is a parent reference and a
name, or the reference of an existing file:

1. fsync the staging file: adoption is a rename, and unsynced bytes would publish a truncated body
   after a power loss.
2. If `modified` is given, set the staging file's mtime to it; the adopted file's mtime becomes the
   item's mtime, which is how a photo keeps its capture time.
3. `write` with `await`, the given exclusivity and base. On success the core owns the file and the
   intent is deleted. On failure the staging file is kept while its intent is ready, else deleted.

A commit succeeds once the core has adopted the body, whether or not it is uploaded yet;
`isUploaded` in the reply says which, and the queues keep retrying.

### 8.2 Ingest intents

A write the platform considers finished (a picker's clean close, a share the user confirmed, a file
picked for upload) is acknowledged before the owner can commit it. Each staging file therefore has a
durable intent record:
`{staging name, target (parent reference and name, or file reference), exclusive, base?, modified?, state: open | ready}`.

- The intent is written before the staging file is handed to anyone. It becomes `ready`, with the
  staging file fsynced, before the platform or the user is told the operation succeeded.
- After boot the app commits every `ready` intent, then deletes it. An `open` intent found at
  process start is an interrupted write and is discarded with its staging file.
- A target that no longer exists at commit time (`not_found`) commits to the domain root under the
  same name, exclusive, and notifies the user where the file went.
- The staging sweep deletes only staging files that no intent names and whose name-embedded creation
  time is older than `staging_orphan_age`.

### 8.3 Folders by path

`folderFor(path)` resolves each directory segment with `mkdir` (which answers an existing folder,
after the destination pull) and takes the reference from the reply's item. A cache of path → folder
reference MAY avoid repeated requests; a cached reference that answers `not_found` is dropped and
the path resolved again.

## 9. Keep-alive

Proxy-descriptor reads and commits run in the app process, and the platform freezes cached
processes: a player then drains its buffer and waits for ever.

- A process-wide counter of open work: `retain` reports true exactly on 0→1, `release` exactly on
  1→0; a release at 0 is ignored, so the counter is never negative.
- On 0→1 start a foreground service (data-sync type, low-importance notification saying what is
  held: "Serving N open files", "Saving N files"); on 1→0 stop it. The service is not restarted by
  the platform after a kill: nothing it held survives the process.
- A platform refusal to start it (background restrictions, an exhausted daily budget) is logged and
  ignored: the work continues while the process lives, and ready intents cover the rest.
- On the platform's foreground timeout the service stops itself rather than letting the process be
  killed.
- Retained by each read-only open (until descriptor release or a failed open), each write open
  (until its commit ends), each share save and in-app upload (until its last commit ends), and the
  resume of ready intents after boot.

## 10. User interface

This section is the limit of what the spec says about the interface: the screens, what each must
show and offer, and the states it must distinguish. Layout, typography and motion are the
implementation's.

### 10.1 Principles

- **Platform-native.** The app follows the platform's current design system, its light and dark
  themes and system colours where the platform offers them, draws edge to edge with the system bars'
  insets applied, and uses the system's back gesture.
- **Nothing blocks the UI thread.** Every request to the core is made off it. An action that takes
  time shows that it is running and then says how it ended; a failure is never reported as success.
- **Every state is told apart**: loading, empty, failed (with the reason and a retry), offline, and
  read-only each have their own presentation. An empty list is shown only for a folder known to be
  empty.
- **The owner's sentence is shown.** A failure shows the reply's `error` text; the app decides what
  to offer from the `code`.
- **Accessible.** Every control has a text label or content description, touch targets meet the
  platform minimum, text scales with the system font size, and state is never carried by colour
  alone.
- **Localisable.** Every user-visible string is a resource; sizes, dates and counts are formatted by
  the platform for the user's locale.

### 10.2 Structure

Until a config exists the app shows only Setup (§10.7). After that, three top-level destinations
reachable from every screen: **Files** (the start destination), **Activity** and **Settings**.
Process death and configuration changes restore the destination and, in Files, the folder trail.

### 10.3 Files

- **Trail.** A stack of `(reference, name)` from the root. The title is the current folder's name
  (the domain name at the root); the path is shown and each ancestor is reachable from it. Back pops
  the trail and leaves the app at the root.
- **Listing.** `list_dir` pages, the next page loaded as the list nears its end, in the handler's
  order. Shown while the first page loads: a progress indication, not an empty list.
- **Row.** An icon for the kind (folder, or the file's type family from its MIME type), the name, a
  second line (a file's size and modification date), and a **state mark**:
  - `online-only`: bytes are on the server only;
  - `cached`: no mark;
  - `pinned`: available offline;
  - `isUploaded` false: waiting to upload, which takes precedence over the others.
- **Refresh.** A pull-to-refresh gesture lists with `"pull":"now"`. The folder is observed while
  shown (§7.1), and re-listed when the screen is resumed, on a `changed` notice naming it and on
  `recovered`. A refresh keeps the scroll position and does not clear the list while it runs.
- **Offline.** When the listing is `outdated`, a banner above the list says "Offline: showing this
  folder as of <time>" and stays until a fresh listing arrives. A folder that answers `unreachable`
  shows "Cannot reach the server" with Retry instead of a list.
- **Read-only.** On a read-only domain the screen says so once, and nothing that writes is offered.
- **Add.** One prominent control offering "New folder" (a name prompt; `mkdir`, exclusive; `exists`
  is shown on the name field) and "Upload files" (the system file picker, multiple; then §10.6 into
  the current folder).
- **Tap**: a folder descends; a file opens (below). **Long-press or the row's menu**: the item's
  actions (§10.4).

### 10.4 Item actions

Offered in a sheet titled with the item's name; each ends with a short confirmation or the failure.

| Action | For | What it does |
|---|---|---|
| Open | files | A view intent on the provider's document address with the file's MIME type and a read grant, through the system chooser; "No app on this phone opens <name>" when nothing takes it. |
| Share link | all | `share`; then the URL with its expiry, and Copy and Send. `paused` and `unreachable` are shown with the owner's sentence. |
| Make available offline | all not pinned | `restore`. For a folder the confirmation states the reply's counts: "<r> files available offline", and "<f> failed" when any did. |
| Keep offline longer | pinned files | `restore` again, which extends the pin. |
| Remove download | all not `online-only` | `evict`, with counts for a folder. A file waiting to upload keeps its bytes. |
| Rename | all, when writable | A name prompt pre-filled with the current name; `rename` in place with `noreplace: true`; `exists` is shown on the field. |
| Move | all, when writable | Files in pick mode (§10.6) to choose the destination folder, the item itself and its subtree not offered; then `rename` into it under the same name with `noreplace: true`. `exists` is shown with the owner's sentence. |
| Delete | all, when writable | A confirmation naming the item, and for a folder saying that everything in it is deleted; then `delete` or `rmdir`. |
| Details | all | Name, kind, size, modified, where its bytes are, pinned until, whether it is uploaded. |

A folder action that walks a subtree shows that it is running for as long as it does, and can be
left running: its outcome is then a notification.

### 10.5 Activity

What the app is doing and what went wrong, read from the `status` action every `status_poll` while
the screen is visible, and not at all otherwise.

- **State line**: connected, offline (last answer `unreachable`), paused, or read-only.
- **Uploads**: the files uploading now, how many more are waiting and how many bytes are owed.
- **Downloads**: each transfer running now with its progress and rate.
- **Problems**: failed saves, with Retry (commit the intent again) where a ready intent remains; and
  the owner's parked records, with "Retry now" (`retry`).
- **Pause / Resume** (`pause`).
- **Camera backup**: the status line of §11.8 and "Back up now".
- **Details**: the `status()` text verbatim, selectable, for diagnosis.

### 10.6 Saving into the domain

One flow for the share target and for "Upload files". Its pick mode also chooses the destination
of a Move (§10.4), titled "Move <name> to <path>" and offering "Move here".

- **Share target.** No streams → "Only files can be saved to tsync"; no config → "Set up tsync
  before saving to it"; in both cases the activity finishes. Otherwise Files opens in **pick mode**:
  taps only navigate folders, item actions are off, "New folder" stays, the title reads "Save N
  files to <path>", and the screen offers "Save here" and "Cancel".
- **Names.** One file: an editable name pre-filled with the stream's display name (else the last
  address segment, else "shared file"). Several: each keeps its own name. Every name is sanitised
  (§11.5).
- **Save.** Retain keep-alive. Off the UI thread, while the activity still holds the read grants,
  copy each stream into its own staging file with an intent (exclusive, in the chosen folder), fsync
  it and mark the intent ready. The screen shows progress, per file when there are several.
- **Done.** The flow reports success and closes only once **every** file has a ready intent or is
  committed. Commits then run with numbering on `exists` (§5), and continue after the screen closed.
  A file that could not be copied is reported by name; the rest continue.
- Release keep-alive when the last commit ends.

### 10.7 Setup and Settings

- **Setup**, when no config exists, in this order: server URL and secret (the secret masked, with a
  control to reveal it, and paste accepted); **Check server** (§6.2), whose answer fills a choice of
  domains, or one domain directly; cache limit, pre-filled; **Connect** (§6.1). Each validation
  failure is shown on its field, which takes focus and is scrolled into view. A server that cannot be
  checked does not block setup: the domain name can be typed.
- **Settings**:
  - *Server*: the same fields, with the restart prompt of §6.1 on a change.
  - *Storage*: the cache limit; how much the cache and the staged bodies hold now (from `status`);
    "Free up space" (`evict` on the root, after a confirmation saying that files made available
    offline are removed from the phone too).
  - *Camera backup*: the controls of §11.6.
  - *About*: the app version and the commit it was built from.

## 11. Camera backup

### 11.1 Principle

Every photo or video captured into DCIM while backup is enabled is eventually uploaded, however long
it takes to settle and however many attempts fail. Progress is carried by a **durable record per
media item**; the discovery mark only decides where the next discovery query starts, and never
whether an item is uploaded.

### 11.2 Records

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
full-discovery time with every mark they write (steps 1 and 4 of §11.3). Readers SHOULD accept a mark
without the version string (meaning unknown, never a mismatch) and without the full-discovery time
(meaning a full discovery is due).

**A row below the mark without a record.** Writers MUST NOT produce this state: discovery records
every row it passes (§11.3). Readers SHOULD accept it, meaning a row passed without being recorded; a
full discovery that finds one records it:
- `PENDING` if its date-added is later than `date_added_lookback` before the oldest record's update
  time, or if there is no record at all and the mark is 0 (a backfill that never completed): it was
  captured while backup was running;
- `BASELINE` otherwise: it existed before backup started.

Opening the record store never rewrites a record; a record is rewritten only when its item's state
changes. The folder cache of §8.3 MAY be kept beside the records; it is disposable.

### 11.3 Discovery

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

### 11.4 Processing

Records in `PENDING`, and in `FAILED` whose next attempt is due, are processed in capture order:

1. Re-read the row by id. Gone → delete the record. Still pending in the media store, empty, or
   modified less than `settle_time` ago → leave it and report more work.
2. Check the budgets (§11.6) and the gate (§11.7); if either says stop, stop the pass with more work.
3. `folderFor(dir of target)`; copy the **original** stream (with location metadata) into a staging
   file with an intent; a copied length different from the row's size is a failure.
4. Commit with `modified` = capture time:
   - a first upload is exclusive: on `exists` (another device's photo holds the name) the target moves
     to the next sequence name (§11.5) and is frozen there;
   - a re-upload of a `DONE` record carries `base` = the recorded etag, so a file someone else put at
     the target meanwhile is kept, as [conflict resolution](../algorithms/conflict-resolution.md)
     specifies.
5. Success → `DONE` with size, modification and etag. Failure → `FAILED`, attempts + 1, next attempt =
   now + `retry_backoff(attempts)`, last error.

`FAILED` is never terminal: the item is retried until it succeeds or leaves the device.

The domain is never asked whether a photo exists: the device's record is authoritative, so a photo the
owner deleted from the domain is not uploaded again.

Camera backup works through §8 like every other write, so it needs no store to make progress: with
the store away, photos are staged up to the budget and published when it returns.

### 11.5 Naming

`Camera Uploads/<yyyy>/<yyyy-MM-dd HH.mm.ss>[ (n)]<.ext>` under the domain root.

- Time = capture time (date-taken, else date-added), formatted in the phone's time zone **at first
  sight** and frozen in the record: re-computing after travel would duplicate.
- `(n)` distinguishes captures sharing a second and names already taken (by a record, by an earlier
  claim in the same pass, or by `exists` at upload); 0 omits it; up to `max_name_attempts`.
- The extension is taken from the display name (not the MIME type): the part after the last dot, when
  the dot is neither first nor last and the part is letters and digits only; lower-cased. Otherwise
  none.
- **Leaf sanitising** (also used for every name the app creates): `/`, `\` and control characters →
  `_`; leading whitespace and trailing spaces and dots are trimmed; empty → `unnamed`.
- Example: `IMG_1234.JPG` captured 2026-08-16 12:31:04 UTC in Paris →
  `Camera Uploads/2026/2026-08-16 14.31.04.jpg`.

### 11.6 Access, controls, budgets and schedule

- **Access level**: full when both image and video read access are granted (or, on older platforms,
  external-storage read); selected-only when only a user selection is readable; denied otherwise.
  Media-location access is requested too. Selected-only is reported as a limit, not a stall.
- **Controls**: "Back up camera photos and videos"; "Only over wifi" (default on); "Not when the
  battery is low" (default on); "Back up now".
- **Enabling** asks "Everything" (backfill) or "From now on", then requests access. Backup is enabled
  only once read access is granted. For "From now on", off the UI thread, a discovery pass first
  records every existing row as `BASELINE`; if that pass cannot complete, backup is not enabled and
  the user is told why. Turning backup off cancels all work.
- **Budgets**, per pass: the staged bytes the core still owes for this domain stay under
  `staged_bytes_budget`, since staged bodies are not covered by the cache limit and fill the phone's
  storage while the store is away; running time at most `pass_time_budget` (the platform stops jobs
  after about ten minutes); free space in the staging directory at least twice the item's size.
- **Schedule** (three unique jobs, which may run concurrently but share one pass lock):
  - on media changes: a one-shot job triggered by changes under the image and video collections
    (update delay `trigger_delay`, maximum delay `trigger_max_delay`), re-enqueued at the end of every
    run since a trigger fires once;
  - periodic, every `periodic_interval`;
  - run now (user-initiated), without constraints.
  Constraints for the first two: network unmetered if "Only over wifi" else connected; battery not low
  if "Not when the battery is low"; storage not low always. Changing a setting re-enqueues with the
  new constraints.

### 11.7 Gate

Re-checked before each upload; a user-initiated run ignores it. "Only over wifi" set and the active
network metered or absent → "waiting for wifi". "Not when the battery is low" set, not charging, and
the level below `battery_floor` → "battery low".

### 11.8 A pass

1. Try the process-wide pass lock; if another pass holds it, return success (two passes would plan
   from the same records).
2. Disabled → success. No read access → outcome "photo access not granted", success.
3. Not user-initiated and the gate blocks → outcome = the reason, retry later.
4. Try to become a foreground job ("Backing up camera photos"); a refusal is ignored.
5. Sweep orphan staging files (§8.2). Discovery (§11.3), then processing (§11.4), stopping when the
   job is stopped.
6. Outcome `"<u> uploaded[, <f> failed][, more to do]"`. Settled = no `PENDING` or `FAILED` record.
   More work or due retries → retry later; else success. An unexpected failure → outcome "last pass
   failed: …", retry later. Always re-enqueue the media-change job.

**Status line**: `off` | `<n> failed — <last error>` | `not started yet` | `<n> waiting to upload` |
`up to date`, plus the hold reason, "(only the photos you selected)", and the last outcome.

## 12. Build

What the app's build MUST guarantee; where it runs and what it gates is [10](../10-delivery.md).

- **One core, the commit's own.** The package carries the core library cross-built from the same
  commit; a package build fails when that library is missing, and no built library is kept in the
  repository.
- **Floors agree.** The app's minimum platform version equals the platform API level the core is
  cross-built against. One ABI is shipped: 64-bit ARM. The library is linked for 16 KB pages, which
  current platforms require.
- **Installs over its predecessor.** The version code increases with every published build, and
  every published build is signed with the one tsync key (10 §5.4).
- **Logic is testable off a device.** The decisions (request and reply shapes, naming, the backup
  planner, the keep-alive counter, intents) are separable from the platform and tested on a plain
  JVM; the request and reply shapes are tested against a real `tsync` binary through
  `tsync android request`, so the two sides cannot drift.
- **A suite that ran nothing fails**, on the JVM and on a device alike.

## 13. Parameters

| Parameter | Recommended | Constraint |
|---|---|---|
| `observed_refresh` | 30 s | ≥ `pull_freshness` |
| `status_poll` | 2 s | only while the Activity screen is visible |
| `max_tree_depth` | 4096 | |
| `max_name_attempts` | 1000 | |
| `staging_orphan_age` | 24 h | |
| `check_server_timeout` | 10 s | |
| `settle_time` | 10 s | |
| `date_added_lookback` | 24 h | |
| `full_discovery_interval` | 7 days | |
| `retry_backoff(n)` | min(15 min × 2^(n−1), 6 h) | bounded |
| `staged_bytes_budget` | 512 MiB | |
| `pass_time_budget` | 8 min | below the platform's job limit |
| `battery_floor` | 15 % | |
| `trigger_delay` / `trigger_max_delay` | 10 s / 300 s | |
| `periodic_interval` | 6 h | |

## 14. Conformance

An implementation MUST exhibit these properties; [09-tests.md](../09-tests.md) says how they are
checked.

**Names and writes**
- A share-sheet save, an in-app upload, a document creation and a first camera upload never replace
  an existing item, including in a folder with more entries than one listing page and under
  concurrent saves of one name.
- A commit adopts the staging file (it is gone afterwards) and keeps its mtime.
- Every surfaced failure carries its code; a failed listing is never taken as an empty folder.
- A config the core refuses is never left as the app's config.

**Provider**
- `isChildDocument` is true for every descendant of a tree root and false for anything else.
- A document id is unchanged by a rename or a move of the document or of any ancestor.
- A move onto a taken name, and a move of a folder into its own subtree, change nothing.
- An edit of a document renamed while it was open is saved to the renamed document.
- A read-only domain's documents offer no write, create, delete, rename or move.
- A children result of a folder listed before is served, flagged, while the store is silent; a
  folder never listed reports the failure and no rows.
- An observed folder shows a peer's change within `observed_refresh` plus one pull.

**Crash safety**
- The process killed at every durable step of a picker write, a share save, an in-app upload and a
  camera upload, then started again, loses no write that was reported successful and publishes no
  truncated body.
- The share target reports success only after every file is committed or has a ready intent.
- The staging sweep never deletes a file an intent names.

**Secrets and transport**
- The app's data is excluded from backup and device transfer.
- A cleartext URL to a non-loopback host is refused by the form.
- A trust-store change on the device is picked up at the next process start.

**User interface**
- Loading, empty, failed, offline and read-only are each presented distinctly; an offline listing
  shows its age.
- A folder evict or restore reports the counts the owner answered; a failure is never reported as
  success.
- No request to the core is made on the UI thread.

**Camera backup**
- A photo captured, unsettled at the first pass and unchanged afterwards is uploaded by a later pass.
- A photo whose upload failed is retried until it succeeds, across passes and process restarts.
- A media store rebuild (new version string or lower generation) loses no photo and re-uploads none.
- Renumbered ids with the same target and size are recognised; renumbered different content gets a
  new sequence name; a name clash with another device's photo takes the next sequence name.
- "From now on" uploads nothing that existed when it was enabled; "Everything" uploads it all.
- Records with only some optional fields, and a mark without its optional parts, are used as they
  are; a row below the mark without a record, captured while backup was running, is uploaded.
- The planner is deterministic: the same records and rows give the same plan.

## 15. Rationale (do not undo)

- **Edit opens that cannot fetch the current body are refused.** Starting empty published
  truncations.
- **Commit off the descriptor thread.** A commit waits for the upload; the callback thread serves
  other files' reads.
- **The service stops itself on the platform timeout.** Letting the timeout fire crashed the app in a
  loop.
- **Per-item records, not a watermark.** A watermark stored at the end of a pass skipped every photo
  that was unsettled or failed during it, silently and for ever.
- **Exclusive creation in the owner, not check-then-write in the app.** A lookup that read one page,
  or took an error for "absent", overwrote existing files.
- **Intents, not best effort.** A share that closed its screen before committing, and a picker edit
  committed after the close, were lost to a process death with nothing to show for it.
- **The candidate config is checked before it replaces the config.** A refused config left on disk
  opened the app on a domain that could not boot.
- **Kind from the row, ids that survive renames.** A document id that spelled its parent and leaf
  made a rename drop the edit of an open document, and made tree grants stop at the first level.

---

Implementation notes for this subsystem: [../ocaml/frontends/android.md](../ocaml/frontends/android.md).
