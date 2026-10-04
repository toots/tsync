# The macOS host (File Provider frontend)

Scope: how tsync presents domains on macOS through Apple's File Provider framework: the processes
involved and which of them owns what, the macOS realisation of the request interface, the mapping
between tsync items and File Provider items, change signalling, domain registration, and the
installation.

Rules shared by every frontend are owned elsewhere and only referenced here:
- the frontend contract, item references, the item row, error codes, anchors, paging and the shared
  request handler: [the frontend contract](../08-frontends.md);
- the process model, domain ownership, the owner's lifecycle and stop protocol, and the CLI:
  [daemon and CLI](../07-daemon-cli.md);
- what the owner's local state is: [local state](../data-model/local-cache.md);
- failure kinds and deadlines: [failure model](../algorithms/failure-model.md);
- trust boundaries: [security model](../algorithms/security-model.md);
- conflicts: [conflict resolution](../algorithms/conflict-resolution.md).

---

## 1. Problem

On macOS a folder lazily backed by remote storage is provided through the File Provider framework
as a *replicated* extension, not a kernel filesystem. The framework imposes this shape:

- The system keeps a **replica** of each domain on disk under `~/Library/CloudStorage/`. Files are
  dataless until materialised. The provider never writes the replica; it answers callbacks.
- Callbacks are served by an **extension** the system starts, suspends and kills at will, one
  process per domain. It is sandboxed: it may not create files in the App Group container, may not
  read files other processes wrote there, and may not move files into its provider temporary
  directory.
- Only a process holding a File Provider manager (the app or the extension) may register domains,
  signal changes, evict items or request downloads.
- The system persists item identifiers and treats them as the item's identity for its whole life.
  It learns of remote changes only from the **working set** enumerator, which must cover the whole
  domain, through opaque **sync anchors**. A folder is enumerated once, when first materialised;
  after that nothing but the working set tells the system about it.

tsync's engine lives in a long-running, unsandboxed process. This subsystem is the adapter: it
divides the File Provider duties between processes, realises the request interface for sandboxed
clients, and maps tsync's items and change feed onto the framework's identifiers, versions,
enumerations and anchors.

**Design goal.** The replica must converge on the owner's mirror and stay converged across process
restarts, sleep and arbitrarily long downtime, without user action. The framework offers no repair
that is both cheap and complete: an expired working-set anchor costs a scan of every item the system
knows and does not reliably remove items it already holds. So every rule below is chosen to make
anchor expiry practically never happen, and to make every change reachable through the working set.

## 2. Processes and ownership

```
                    launchd (per user session)
         ┌───────────────────┴─────────────────────────┐
   Agent: tsync service                           Login item: TsyncApp (sandboxed)
         │                                          - registers and reconciles domains
         └─ owner of every File Provider domain     - one event relay        
            (converges each domain it owns;         - menu bar status item
             serves the request socket)  ◄──────────┘ subscribe, menu, pause
                  ▲
                  │ one request per connection
     TsyncFileProvider extension (sandboxed; one process per domain; started by the system)

     tsync CLI: requests to the owner's socket; takes ownership itself only when no owner runs
```

| Process | Lifetime | Sandboxed | Holds a File Provider manager | Role |
|---|---|---|---|---|
| Owner | per-user agent, restarted on any unclean exit | no | no | Owns and converges every domain configured with `file_provider` (P1, [07](../07-daemon-cli.md)). Serves the request socket. Publishes events. |
| App | login item, always running | yes (App Group) | yes | Domain registration, reset and purge; relays owner events to the framework; menu bar. |
| Extension | started and stopped by the system | yes (App Group) | yes, for its temporary directory and for eviction and download requests it makes itself | Implements every File Provider callback by asking the owner. Holds no state across callbacks. |
| CLI | one-shot | no | no | Sends requests to the owner. `fileprovider reimport|reset|purge` (§9). |

**Ownership (P1).** One process owns all File Provider domains of the user. It holds each domain's
ownership lock for its lifetime and is the only process that mutates their local state. It also
converges them: reconcile, journal polling and application, maintenance, and resumption of deferred
work. The app, the extension and the CLI act on a domain only through the owner's request
interface. A one-shot command that finds no owner running MAY take ownership for its own duration,
as [07](../07-daemon-cli.md) specifies.

**Every rule has its owner on the owner's side.** The extension and the app translate; they do not
decide. Whether an item is writable, what its identity and version are, which changes happened and
where an enumeration resumes are all answered by the owner. A rule restated on the Swift side
drifted every time it was tried.

**Direction rule.** The owner never connects to the sandboxed processes. They connect to the owner's
socket; the system owns their lifetime. The app therefore subscribes and receives events on its own
connection, and the extension makes only request/reply calls.

**Why the app relays events, not the extension.** The system stops the extension exactly when the
domain is idle, which is when remote changes need reporting. The app is a login item and stays up.
The app MUST NOT offer to quit: without it no remote change reaches the replica until the next
login.

## 3. Host layout and identifiers

### 3.1 Fixed identifiers

These identifiers are part of the installed base. Changing the App Group orphans every existing
installation's configuration and local state.

| Thing | Value |
|---|---|
| App bundle id | `org.feverdreamtv.tsync` |
| Extension bundle id | `org.feverdreamtv.tsync.fileprovider` |
| App Group | `group.org.feverdreamtv.tsync` |
| Service label | `org.feverdreamtv.tsync.daemon` |

A `group.`-style App Group is accepted by macOS without a prompt only when every binary claiming it
carries a provisioning profile authorising it; the app and the extension MUST both embed one.

### 3.2 Paths

| Thing | Path |
|---|---|
| Group container | `~/Library/Group Containers/<App Group>/` |
| Config | `<group>/config.json` (survives purge) |
| Data directory | `<group>/tsync/` |
| Cache root | `<group>/tsync/cache/` |
| Request socket (all domains) | `<group>/tsync/tsync.sock` |
| Reset marker | `<data dir>/fileprovider-reset` (one display name per line) |
| Purge marker | `<data dir>/fileprovider-purge` |
| Identity-scheme record | `<data dir>/fileprovider-identity-scheme` (decimal integer) |
| Service log | `~/Library/Logs/tsync-daemon.log` |
| CLI link | `/usr/local/bin/tsync` → the binary inside the app bundle |
| Extension staging directory | the extension's own temporary directory, `staging/` |

Unix socket paths are limited to 104 bytes; the request socket path MUST fit. Every marker and record
above is written by the rule of [durable-queue.md](../algorithms/durable-queue.md) (temporary file,
fsync, rename, directory fsync).

### 3.3 Domain identifier

The config's domain `name` is the File Provider **display name**. The File Provider **domain
identifier** is derived from it:

```
identifier(name) = replace every U+0020 SPACE with "-" in lowercase(name)
```

where `lowercase` is the Unicode default lowercase mapping. The derivation is part of the installed
base: registered domains are found again by it.

- Every client names the domain to the owner by its display name, byte for byte equal to the config
  name. The identifier is used only between the app and the framework.
- On a macOS host, config validation MUST refuse two domains configured with `file_provider` whose
  identifiers are equal, naming both domains.
- The app MUST NOT register a domain whose identifier equals one it registers for another name in
  the same pass; it registers neither and reports the collision in the menu.

The owner never reads or writes the replica folder.

## 4. The request interface on macOS

### 4.1 Framing

- A Unix stream socket at the request socket path, carrying newline-delimited JSON as
  [08](../08-frontends.md) specifies. The App Group container is the trust boundary: only members of
  the App Group, and processes of the same user outside any sandbox, can reach the socket.
- The owner serves each connection sequentially and every connection concurrently. A failure on one
  connection (including a socket-option or accept error) MUST NOT stop the listener. The owner MUST
  NOT set TCP options on Unix sockets.
- `subscribe` turns the connection into an event stream (§8.1).

### 4.2 Routing and refusals

Requests are `{"action": <verb>, "domain": <display name>, …}`, routed as
[07 §4.2](../07-daemon-cli.md#42-envelopes) specifies.

- An absent `domain` is accepted only when the owner serves exactly one File Provider domain.
- **Every refusal carries a code**, the router's own included
  ([failure-model.md §7.2](../algorithms/failure-model.md#72-client-error-codes)). A request naming a
  domain the running owner does not serve is answered `unreachable`; the owner's `recovered` notice
  clears it when it starts serving the domain.

`menu` and `menu_stats` span domains and are answered by the router itself (§10).

### 4.3 Client obligations

- **One connection per request**: connect, write the line, half-close the write side, read one line,
  close. SIGPIPE is suppressed on the socket. A subscription does not half-close. Replies carry no
  request id, so a shared connection would serialise requests.
- **Lossy decoding**: a reply line is decoded as UTF-8 with replacement characters, so one name that
  is not UTF-8 costs that item, not the reply.
- **Deadlines.** Every request obeys the client deadlines of
  [failure-model.md §8.2](../algorithms/failure-model.md#82-requests-between-processes). The
  extension treats `ensure_cached`, `fetch_range`, `write` and a first `list_all` page as bulk and
  bounds them with the liveness probe (`ping`). An expired deadline closes the socket and is reported like a transport
  failure.
- **Cancellation**: cancelling a request shuts the socket down in both directions under a lock and
  returns at once with a cancellation error. A request cancelled before its connection opened never
  opens one. The descriptor is closed under the same lock, so a cancel never shuts a reused
  descriptor number. Cancelling a task does not interrupt a thread blocked in a socket call; only the
  shutdown does.
- **No blocking call on a framework callback thread**, and blocking socket I/O never occupies a
  shared thread pool other requests need.
- **Thread-safe state.** Every piece of client state touched by more than one task (the cancellable
  socket, the menu's poll latch) is synchronised. A latch marking a request outstanding is released
  when the request's deadline expires.

### 4.4 Transfer paths

`write` names a `staging` file the owner adopts, and `ensure_cached`/`fetch_range` name a `dest` the
owner creates. On macOS the App Group container is the trust boundary (§4.1), and the provider
temporary directory has no location the owner could derive, so the host realises
[security-model.md §7.3](../algorithms/security-model.md#73-paths-passed-over-ipc-confused-deputy)
by its path rules alone, without declared roots:

- `dest` MUST NOT exist; the owner creates it exclusively, without following a link at any
  component, mode 0600. It never overwrites.
- `staging` MUST be a regular file owned by the owner's uid, not a link; it is adopted by rename.

## 5. Anchors and pages

The anchor and page cursors are the core's ([08 §2.5](../08-frontends.md#25-cursors-and-anchors)).
On macOS:

- The extension carries an anchor as the UTF-8 bytes of the owner's string, verbatim. Bytes that do
  not decode as UTF-8 are no anchor.
- A page is the UTF-8 bytes of the owner's resume cursor, verbatim. The two framework initial-page
  sentinels are themselves valid UTF-8, so the extension MUST recognise them and treat them as "from
  the start".
- Every anchor and cursor the owner issues fits in 500 bytes by construction. The extension MUST
  refuse, not truncate, a longer one: an oversized page ends the enumeration with an error, an
  oversized anchor is reported as no anchor.
- Page and batch sizes are the framework's suggested size, or 100 when it suggests none, and at least
  1.
- A cursor means the same thing to a freshly started extension: no cursor encodes an in-memory
  offset.

**Ordering.** The system asks for the anchor before the first page of a full enumeration, and asks
for changes from it afterwards. The anchor MUST therefore describe a state at or before the one the
pages show. The owner's anchor names the last applied entry and the kept walk is taken at page 1,
after it, so a change landing in between is delivered twice, which is harmless.

**Anchors do not expire on a running installation.** The core keeps an anchor valid for as long as
its consumer may present it ([08 §3.6](../08-frontends.md#36-change-feed-changes_since)): the applied
log keeps every entry from the feed watermark on, the watermark being the oldest anchor the extension
was handed or asked from; a rebuild appends its difference to the applied log and stamps no new
generation. An anchor is stale only after `reimport` stamps a new generation, or after the watermark
lapsed because the domain was not enumerated for `FEED_WATERMARK_MAX_AGE`. So a machine off for months
resumes with a change enumeration, not a rescan.

**Page expiry.** A whole-domain page cursor naming a kept walk that is gone, or a walk other than the
current one, is answered `{stale:true}` ([08 §3.7](../08-frontends.md#37-listings-and-their-order));
the extension finishes the enumeration with the framework's page-expired error and the system
restarts it. Continuing at the same position in another walk would skip items, and an unchanged item
skipped there is never enumerated again.

## 6. File Provider mapping (extension)

### 6.1 Identifiers

- An item's identifier is its item reference, verbatim. `root` maps to the framework's root container
  identifier and back, in requests, replies and events; the root item's parent is itself.
- **Identifiers are stable for the item's life on this machine and independent of its name and
  parent**, as the framework requires: returning another identifier from a modification is a merge
  instruction, and the system removes the other item from disk. A folder is named by its folder id;
  a file by its **file id**, a local id the owner assigns to each file of the domain, keeps across
  renames, moves and content changes of that file, and never reuses. Every reference the owner
  issues to this host is one of `root`, `d:<folder id>`, `i:<file id>`.
- A remote rename or move is an update of the same identifier with a new name or parent; nothing is
  deleted and the materialised content stays.
- Rows whose `ref` or `parentRef` do not parse are dropped.

### 6.2 Item model

- `filename` = `name`; `parentItemIdentifier` = `parentRef`.
- `contentType`: a directory whose extension is a declared package type conforming to directory (for
  example `.rtfd`, `.logicx`, `.band`) takes that type, any other directory is a folder; a symlink is
  a symbolic link; a file takes the declared type of its filename extension, else generic data.
- `documentSize` = size, exactly the bytes a fetch delivers (a mismatch makes the system upload the
  file again after every download); `contentModificationDate` = mtime, absent when mtime ≤ 0.
- `isUploaded` = the row's `isUploaded`; `symlinkTargetPath` = its target.
- `contentPolicy` = download lazily, set on the root and inherited.
- **Writability is the owner's.** A row carries `readOnly: true` when the item cannot be written
  (the domain is read-only). The extension presents such an item read-only (§6.4) and never decides
  it otherwise. A name that is not valid UTF-8 reaches the system lossily decoded; the item stays
  writable, because its identifier, not its name, is what the extension sends back. The
  root is answered by `stat("root")` like any item.

### 6.3 Versions

Both versions MUST be non-empty and at most 128 bytes.

- **contentVersion** changes if and only if the bytes of the item change.
  - File: the row's `contentId` (the whole-file digest of the content the key resolves to, staged or
    published, [08 §2.3](../08-frontends.md#23-item-row)). It does not change when this client's own
    upload of content the system already holds completes: a changed contentVersion makes the system
    fetch a materialised file again and replace the file the user just saved.
  - Symlink: `"l:"` followed by the row's `contentId`, the symlink digest, so a retarget changes it
    and a long target still fits. The extension computes no digest of its own.
  - Directory: its folder id, constant for its life. Children changes arrive through the working
    set, never through the parent's version.
- **metadataVersion** = contentVersion. The system stores it and otherwise ignores it; metadata
  changes (name, parent, upload state) are applied whether or not it moves.
- The owner MUST report a `contentId` for every file it describes on this host: a whole adopted body
  is digested while adopting it, with the chunk size the upload will use, so the later publish yields
  the same digest. Staged partial edits are never produced on macOS.

### 6.4 Capabilities and domain

- Read-only item (§6.2): directory {reading, enumerating}; file {reading}.
- Writable: directory {reading, enumerating, adding sub-items, renaming, reparenting, deleting};
  symlink {reading, renaming, reparenting, deleting}; file {reading, writing, renaming, reparenting,
  deleting}. No trashing.
- Capabilities only gate the user interface: edits made outside it (a terminal) still arrive and are
  refused by the owner (§6.10).
- The domain is registered with `supportsSyncingTrash = false`, since trash is not implemented, and
  the trash container's enumerator fails with feature-unsupported.
- The extension declares enumeration support, user-controlled eviction and the custom actions of
  §6.7. The download pipeline depth is left at the system default: each fetch costs the owner a store
  read, and a deeper pipeline buries a slow store rather than keeping it busy.

### 6.5 Callbacks

Every callback runs its work asynchronously, returns a progress object whose cancellation cancels the
request and completes the callback promptly with user-cancelled, and completes exactly once with an
item or an error. A creation or modification never completes with neither.

| Callback | Behaviour |
|---|---|
| item for identifier | `stat(ref)`, the root included. It is the system's authority on existence: `noSuchItem` deletes the item from disk, so it is returned for the owner's `not_found` and for nothing else. The trash container is answered feature-unsupported without asking the owner, as its enumerator is. |
| enumerator for container | Working set → the working-set enumerator; trash → feature-unsupported; any other container → a directory enumerator. Creating one does no I/O. |
| directory: enumerate items | `list_dir(ref, after: page, limit)`. No change enumeration and no anchor: a folder enumerator is used once, at materialisation. |
| working set: enumerate items | `list_all` pages over the whole domain; items carry their real parent. |
| working set: enumerate changes from anchor | `changes_since(anchor, limit)`. `stale` → finish with sync-anchor-expired. Else resolve the ops (§7), report deletions and updates, and finish up to the returned cursor with `more` as more-coming. **On any error, finish with the error, never at the starting anchor**: finishing there claims "up to date" and the system stops asking. |
| working set: current sync anchor | `cursor`; on failure, no anchor (an invented anchor costs a rescan). |
| fetch contents | `dest` = a new UUID name in the provider temporary directory; `ensure_cached(ref, dest)`: the owner writes the file there, because the extension may not move files into that directory. Complete with `dest` and **the reply's `item`**, which describes exactly the bytes written. Progress: `download_progress` every `progress_poll_interval`; total set when known, completed at the end. On failure `dest` is removed. |
| fetch partial contents | `stat`; with strict versioning and a contentVersion other than the requested one → version-no-longer-available. Range = `aligned` (§6.8) against the stat's size; empty → version-no-longer-available (a length of 0 is invalid to the owner, and an unknown error is retried forever). `fetch_range(ref, dest, offset, length)`. A reply item whose contentVersion differs from the stat's (the content changed in between, so the range may be misaligned) → version-no-longer-available, and the system asks again. Complete with the served range and the reply's `item`. |
| create item | Read-only item or domain → cannot-synchronize. Directory iff the type is folder, or the type conforms to directory and no contents are offered (a flat file named like a package is offered contents). Directory → `mkdir`; symlink → `symlink` (target required); contents → stage (§6.6) and `write(parentRef, name)`; else `create`. Every creation is `exclusive:true` except a may-already-exist replay (below). |
| create item, may already exist | A reimport replays every on-disk item. Directory → `mkdir` without `exclusive` (it answers an existing folder as is). Otherwise `stat(parentRef, name)`: `not_found` → create as above; present and no contents offered → return it; present with contents → stage and `write(ref, base: its contentId)`, which the owner answers without uploading when the content is identical. Only `not_found` means absent; any other error propagates. |
| modify item | Read-only → cannot-synchronize. Moved (filename or parent changed): `rename(ref, parentRef, name, noreplace:true)`; a rename onto the item's own current place is a no-op answered with the item, so a modification retried after its write failed converges. Then contents changed: stage and `write(ref, base)`, where `base` is the contentVersion of the base version the system gave. Return the last reply's `item`. Neither: return a fresh `stat`. |
| delete item | Read-only → cannot-synchronize. A directory without the recursive flag: `list_dir(limit: 1)`; non-empty → directory-not-empty. Then `rmdir` or `delete`; `not_found` → success. |
| custom actions | §6.7. |

**Pending fields.** Create and modify return as still pending exactly the fields they could not
store, i.e. every given field other than contents, filename and parent. When that is the whole set
the system offered, it marks those fields unsupported for the item until the next modification; a
field neither stored nor returned pending would be overwritten on disk by the reply's value (Finder
tags were silently reverted).

**Concurrent edit on write.** A `write` whose `base` differs from the key's current content identity
is a local edit of a version this client no longer has. The owner keeps both sides as
[conflict resolution](../algorithms/conflict-resolution.md) specifies for a stale `base`: the item
keeps the newer content and the local edit becomes a conflicted copy. The reply's `item` is the item
as it now resolves; its contentVersion differs from the bytes the system sent, so the system fetches
the winning content, and it learns of the copy through the working set. This is the resolution the
framework expects from a modification on a stale base.

### 6.6 Staging uploads

The system unlinks the contents URL it handed over once the callback completes. The extension clones
the URL (copying when cloning is impossible) to a new UUID name in its staging directory, sends that
path as `staging`, and removes its name afterwards whatever the outcome. It does not hard-link: a
second link on the system's file makes the item unevictable. The owner validates the path (§4.4) and
adopts the file by rename before replying, so the callback completes once the content is the owner's
and the upload continues behind it, reported through `isUploaded`. The whole file is sent on every
edit; chunk deduplication keeps unchanged chunks off the wire.

Completing before the upload publishes is allowed by the framework on macOS and is what lets a local
edit never wait on the network; the system then counts no upload against its pipeline depth.

### 6.7 Custom actions

Three actions, offered on every item, whose effect on tsync's cache is the core's
([08 §3.4](../08-frontends.md#34-evict-and-restore)):

- **Copy Share URL** → `share(item)` → the general pasteboard. With several items selected it acts on
  the first.
- **Make Available Offline** → `restore` each item: the owner fetches and pins it. A pinned file is
  readable offline because `fetch contents` is served from the pinned cache; the replica copy is the
  system's to keep or evict. For a file, the extension then requests its download through its own
  manager so it is materialised now.
- **Make Online Only** → `evict` each item, then evict it from the replica through the extension's
  own manager. Eviction refused by the system (open file, unsynced edits) is reported, not retried.

Every selected item is attempted; failures are reported together. No event crosses to the app for
these, and nothing depends on the app running. Finder's own Download Now and Remove Download act on
the replica only and leave pins alone. CLI `evict` and `restore` act on tsync's cache only.

### 6.8 Partial ranges

```
aligned(requested, alignment, documentSize):
  size = max(0, documentSize); unit = max(1, alignment)
  wantStart = max(0, requested.location); start = wantStart - wantStart % unit
  wantEnd = min(size, wantStart + max(0, requested.length))
  if start >= size or wantEnd <= start: return (min(start, size), 0)
  end = min(round_up(wantEnd, unit), size)
  return (start, end - start)
```

The range only grows outwards (a missing byte is read as content). Its length is a multiple of the
alignment except at end of file. The alignment is a power of two chosen per boot and MUST NOT be
assumed constant. The bytes sit at their real offset in `dest`; the rest is left sparse.

### 6.9 Mutation replies carry the item

Every mutation reply names the resulting item, and `ensure_cached` and `fetch_range` replies name
the item whose bytes they wrote, resolved in the same step as the work. A separate `stat` afterwards
could describe a newer version than the bytes delivered, and the system would then never fetch that
version. A reply without an item fails the callback as `internal`.

### 6.10 Mapping codes to the framework

The meaning of each code and what a client must do with it are
[failure-model.md §7.2](../algorithms/failure-model.md#72-client-error-codes). The extension returns
only errors in the Cocoa or File Provider domains; anything else surfaces as an unexplained I/O
error.

| code | Mutation (create, modify, delete) | Read (item, enumerate, fetch) |
|---|---|---|
| `not_found` | `noSuchItem` for the target; for a creation, for the parent (the system re-creates it) | `noSuchItem` for the identifier |
| `exists` | `filenameCollision`, carrying the occupying item when the reply names it | Cocoa read-unknown |
| `not_empty` | `directoryNotEmpty` | Cocoa read-unknown |
| `read_only`, `denied`, `invalid` | `cannotSynchronize`, carrying the owner's sentence | Cocoa read-no-permission for `denied`; read-unknown otherwise |
| `unreachable`; no owner listening (nothing accepts the connection) | `serverUnreachable` | `serverUnreachable` |
| `paused`, `busy`, `internal`, unknown or missing, another transport failure, client deadline | Cocoa write-unknown | Cocoa read-unknown |
| cancellation | Cocoa user-cancelled | Cocoa user-cancelled |

- `cannotSynchronize` stops the system retrying that item until it is modified on disk again or the
  error is signalled resolved; it is exactly "do not resend unchanged". The relay signals it resolved
  when the owner restarts (§8.2), which is when a configuration may have changed.
- `serverUnreachable` makes the system back off until signalled; the relay signals it resolved on
  every event and every acknowledgement, so it lasts until the owner answers again. It is produced
  by the owner's `unreachable`, and by an owner that is not listening (restarting, or not started
  yet): the relay's next acknowledgement is that owner coming back. Any other error is retried with
  the system's own backoff, which grows to tens of minutes and is not shortened by a signal; an
  owner restart reported that way left the working set unlisted for twenty minutes.
- Everything else is retried by the system with its own backoff.

## 7. Change batch resolution

A pure function turns an ordered page of ops into an unordered set of updated items and deleted
identifiers. Identifiers are stable (§6.1), so an identifier's fate is its last op:

```
last[r] = index of the last op naming r
for (i, op) in ops where last[op.ref] = i:
  if op is delete or rmdir: deleted += op.ref
  elif op.item parses:      updated += op.item
  # otherwise nothing: no field is invented and nothing asks the owner again
```

Every change is reported wherever it sits. The extension MUST NOT filter by what the system has
materialised: a folder holding a child the system was never told about is never removed.

An op or listing entry the owner could not name (a folder with no id on this client) is counted in
`unnamed`, never turned into `stale`. The item is missing from the replica until it can be named, so
the owner surfaces a non-zero count in status with its repair (`tsync sync --full`), as
[08 §2.3](../08-frontends.md#23-item-row) specifies.

## 8. Change signalling

### 8.1 Events

The app subscribes once, without a domain ([08 §3.8](../08-frontends.md#38-events)): the router
answers and streams the events of every domain it serves, now or later. One JSON line per event:

```json
{"event":"changed","domain":"Files","id":42}
{"event":"recovered","domain":"Files","id":43}
{"event":"reset","domain":"Files","id":44}
```

- `id` increases within one owner process; a client uses it only for ordering.
- `changed` names nothing: the answer is always "enumerate the working set's changes". The owner emits
  it debounced: the first changed key after a quiet period schedules one event `changed_debounce`
  later, and later keys join it. It is raised when the owner applies a peer change, on `revert`, when
  an upload publishes, and after `full_resync` stamps a new generation.
- `recovered` is the domain's recovery notice
  ([08 §3.8](../08-frontends.md#38-events)), including when the owner starts serving the domain.
- `reset` follows `notify_reset` (§9.3).
- Events are hints on top of the change feed: not durable, not replayed, not acknowledged. A lost
  event costs promptness, not correctness. Each subscriber's queue is bounded; when full the oldest is
  dropped and logged. `status.subscribers` reports the count.

### 8.2 The app's relay

One relay for the app, on its own thread:

```
loop:
  connect; subscribe()
  on acknowledgement:
    reconcile domain registrations (§9.1)
    for every registered domain:
      signal the working set
      signal resolved: serverUnreachable, cannotSynchronize
  for each event, on the registered domain it names (none → ignored):
    reset → reconcile domain registrations (§9.1)
    otherwise → signal the working set; signal resolved: serverUnreachable
  back off, then retry
```

- Signalling on every acknowledgement catches up on whatever was missed, since events are not
  replayed; reconciling then is how a changed configuration takes effect once the owner restarts.
  The relay exists with no domain registered, so the first domain added to a fresh install is
  registered by the same path as any other.
- Backoff starts at `relay_backoff_min`, doubles to `relay_backoff_max`, and resets only when a
  connection lived at least `relay_backoff_reset`: an acknowledgement costs the owner nothing, and a
  crash-looping owner would otherwise cause a working-set enumeration per second. The relay never
  gives up.
- Unknown events are ignored. Only the working set is signalled: the framework ignores any other
  container for a replicated extension.

## 9. Domain lifecycle

### 9.1 Registration (app)

The app registers itself as a login item (§11) at launch, then reconciles
domains. Reconciliation also runs on every relay acknowledgement and on a `reset` event; passes do
not overlap (a pass requested during one runs once after it).

1. Load the config's domain names. Create the menu first, so a failure still shows UI.
2. Take one deadline, `registration_deadline`, for every framework call of this pass. A call failing
   with provider-not-found (the installer is swapping the extension) is retried every
   `registration_retry` until that deadline.
3. If the purge marker exists: remove every domain; only if all were removed, unregister the login
   item and delete the marker. Register nothing and stop. (The owner's agent is the purge command's to
   remove, §9.4: the sandboxed app cannot.)
4. If the config cannot be read, leave every domain untouched (reconciling against no names would
   remove every domain), keep the relay, and stop.
5. List existing domains. A failure to list counts as an empty list and marks the pass *unlisted*.
6. `stale` = every existing domain unless the identity-scheme record says 2, this spec's scheme
   (identifiers as §6.1 defines them). Writers MUST NOT record another scheme. Readers SHOULD accept
   an absent record or another value, meaning the registered domains use identifiers that cannot be
   translated: they are rebuilt once.
7. `requested` = the identifiers of the names in the reset marker.
8. Remove every existing domain that is not configured, or is in `requested ∪ stale`.
9. Add every configured domain that did not survive step 8, subject to §3.3's collision rule, and
   signal the working set of each added domain so its enumeration starts without waiting for a user.
10. Record the current identity scheme only if the pass was listed and every stale domain was removed
    (a domain the system refuses to release must not force a rebuild of all domains at every launch).
11. Clear the reset marker only if the pass was listed and every requested domain that existed was
    removed; a failed removal keeps the marker for the next pass.
12. Refresh each domain's user-visible root for the
    menu.

**Removal keeps dirty data.** Every removal uses the framework's preserve-dirty-user-data mode, so
local edits the system had not yet handed to the extension survive. When the framework returns a
location for preserved data, the app logs it and shows it in the menu until the next pass that
finds it gone.

### 9.2 Reimport

`tsync fileprovider reimport` sends `full_resync`. The owner stamps a new generation and raises
`changed`. Every outstanding anchor becomes stale, the
system re-enumerates the working set and may replay on-disk items with may-already-exist, which §6.5
turns into no-ops. The command fails (exit 1) unless the owner answered `ok`.

A reimport is the framework's full scan; it is expensive and does not reliably remove items the
system already holds. It repairs missing items, not extra ones. The complete repair is a reset.

### 9.3 Reset

Only the app may remove a domain. `tsync fileprovider reset`:

1. appends the display name to the reset marker (durably);
2. sends `notify_reset` for the domain; the owner publishes a `reset` event and replies
   `{delivered}`; the app reconciles at once;
3. if `delivered` is 0 or the owner cannot be reached, launches the app (never terminating any
   process), which reconciles at launch or at its next relay acknowledgement.

The command reports success when the marker is written and the app was reached or launched; if
neither worked it removes its line from the marker and fails. The owner keeps running, so the domain
is served again as soon as the app re-adds it.

### 9.4 Purge (uninstall)

`tsync fileprovider purge`:

1. writes the purge marker, then reaches the app as in §9.3;
2. waits up to `purge_wait` for the marker to disappear. On timeout it deletes the marker (else the
   app would purge at every later launch) and fails. When the app is not installed or cannot be
   launched, unregistration is skipped;
3. stops the owner through the service manager and removes the agent definition (§11), so no login
   starts a service whose bundle is gone;
4. removes the app bundle and the data directory, keeping `config.json`;
5. removes the CLI link when it may; when the link is owned by root it prints the command that
   removes it. The link is tested without following it, since it dangles by then.

`tsync restart` restarts the owner through the service manager's own restart (never a signal matched
by process name: the owner's binary lives inside the app bundle) and launches the app if it is not
running.

## 10. Menu bar

There is no settings window; configuration is `config.json`. The app's only UI is a status item whose
content the owner renders (`menu`) from the model shared with the Linux tray
([menu-model.md](menu-model.md)), so the platforms cannot drift. Every label of a rendered menu is the
model's.

`menu` answers `{"ok":true,"menu":<menu JSON>}`, the model's JSON form
([menu-model.md §7](menu-model.md#7-json-form)), rendered with no quit label:

```json
{"ok":true,"menu":{"icon":"tsync-sync-symbolic","tooltip":"tsync — Downloading 1",
  "entries":[{"label":"Files — Downloading 1","enabled":true,"indent":0,"action":{"openFolder":"Files"}},
             {"label":"movie.mkv","enabled":true,"indent":1,"action":{"reveal":{"domain":"Files","rel":"a/movie.mkv"}}},
             {"label":"1.5 GB of 3.7 GB","enabled":true,"indent":2,"action":{}},
             {"separator":true},
             {"label":"Stats","enabled":true,"indent":0,"submenu":true,"action":{"stats":true}},
             {"label":"Hold changes","enabled":true,"indent":0,"checked":false,"action":{"setPaused":true}}]}}
```

`menu_stats` answers `{"ok":true,"entries":[…]}`: the stats rows of
[menu-model.md §6](menu-model.md#6-stats-submenu), in the same JSON form. Until it arrives the
submenu shows the model's placeholder row.

- Poll every `menu_poll_interval`, skipping a poll while one is outstanding; a poll that exceeds its
  deadline counts as a failure and releases the latch. The menu is not rebuilt while open and is
  rebuilt on close.
- An owner that cannot be reached, or a poll that timed out, shows the error icon and an
  "unreachable" tooltip rather than the last known state.
- Icons are named as on the Linux panel (`tsync-idle|sync|paused|error-symbolic`); unknown → idle.
- `openFolder` opens the domain's user-visible root (asked of the framework, never derived from the
  display name) in Finder; `reveal` selects the file and never opens it.
- "Hold changes" toggles all domains through the owner (`pause`), with the semantics of
  [07 §2.6](../07-daemon-cli.md#26-pause). The state shown is read back by the next poll.
- The stats submenu is fetched with `menu_stats` when it opens, at most once per
  `menu_stats_interval`; a failure leaves the placeholder.
- The owner renders no quit row for this host (§2).

## 11. Installation

- Distributed as a notarised installer package installing the app bundle into `/Applications`. A disk
  image cannot install the CLI link and exposes the app to translocation.
- The package's post-install step creates the CLI link, writes the owner's agent definition and loads
  it, and launches the app, all as the console user. The app registers itself as a login item through
  the service-management API.
- The owner's agent is a per-user agent definition in the user's launch agents directory, naming the
  program inside the app bundle by its absolute path. It MUST name the app's bundle identifier as its
  associated bundle, so the system attributes it to the app in Login Items. It runs `tsync start` at
  login, sends its output to the service log, and is restarted on any unclean exit. With no config, or no domain
  configured (every fresh install), the service still serves the request socket, answering `menu`
  with "No domains configured" and holding the app's subscription: the app then needs no other path
  to learn of the first domain, which takes effect at `tsync restart` like any configuration change. A
  leftover request socket is removed before the owner binds: a stale socket makes callers believe the
  owner is running.
- The agent cannot be bundled and registered by the app: the system lets a sandboxed app register
  only sandboxed executables through the service-management API ("SMAppService target executable must
  be sandboxed because the app is sandboxed"), and the owner must not be sandboxed.
- The user approves the extension once in System Settings. The owner reads and writes inside the
  extension's container (staging and temporary files), so its first start may prompt once for access
  to data from other apps.
- Apple silicon only; minimum macOS 13.

## 12. The framework's contract (what any reimplementation must honour)

1. Identifiers are persisted and must be stable for the item's life, independent of name and parent;
   an identifier returned from a modification that differs from the one given is a merge, and the
   other item is removed from disk.
2. Replicated extensions may signal only the working set; any other container is ignored. The working
   set must cover every item (the whole domain), with items carrying their real parent. Folder
   enumerators are used at materialisation only and never asked for changes.
3. The anchor is asked before a full enumeration and must be at or before the state the pages show.
   Finishing a change enumeration at its starting anchor means "up to date". Anchor expiry costs a scan
   of every known item and does not reliably remove items already held.
4. Pages and anchors are at most 500 bytes (an oversized anchor is an expired one, an oversized page
   ends the enumeration); the initial-page sentinels are valid UTF-8; both must mean the same to a
   fresh process.
5. Only Cocoa and File Provider error domains are accepted. `serverUnreachable` and
   `notAuthenticated` back off until signalled; `cannotSynchronize` stops retries of that item until
   it is modified or signalled; everything else is retried.
6. Version data must be non-empty and at most 128 bytes per component. A changed contentVersion means
   new bytes, except in the reply to the creation or modification that sent them. Directory versions
   must be stable.
7. The root's parent is itself.
8. "Item for identifier" is the authority on existence: `noSuchItem` deletes the item from disk.
9. A partial fetch's served range covers the request and is aligned in start and length (short only at
   end of file, checked against the document size); the alignment varies per boot.
10. The extension may not move files into the provider temporary directory, create files in the group
    container, or read files other processes wrote there. The system clones and unlinks a fetched file
    and unlinks a contents URL once the callback completes.
11. Domain calls may fail with provider-not-found while an installer swaps the extension.
12. Only a process holding a manager can register, signal, evict or request downloads. A sandboxed app
    can register only sandboxed executables as agents.
13. Trash syncing defaults to on and must be turned off unless trash is implemented.
14. A field returned neither stored nor pending is written to disk from the reply; returning exactly
    the offered set as pending marks those fields unsupported.
15. Every callback completes promptly after cancellation, exactly once, with an item or an error.
16. `documentSize` must equal the bytes delivered.
17. Calls arrive concurrently; there is one working-set enumeration at a time, one extension process
    per domain, and the process is killed when no callback is outstanding.

## 13. Parameters

| Parameter | Recommended | Constraint |
|---|---|---|
| `progress_poll_interval` | 0.5 s | |
| `changed_debounce` | 0.2 s | ≤ 1 s |
| `relay_backoff_min` / `relay_backoff_max` / `relay_backoff_reset` | 1 s / 30 s / 30 s | reset ≥ max |
| `registration_deadline` / `registration_retry` | 10 s / 1 s | |
| `purge_wait` | 60 s | |
| `menu_poll_interval` / `menu_stats_interval` | 3 s / 1 s | |

## 14. Conformance

An implementation MUST exhibit these properties; [09-tests.md](../09-tests.md) says how they are
checked.

**Identifiers and items**
- `root` and `d:.tsync-root` are one identity, mapped to the root container; malformed references are
  rejected without an exception.
- A renamed or moved file or folder keeps its identifier; a remote rename reaches the system as an
  update, not a deletion; a materialised file stays materialised across a remote rename.
- A directory's version is stable across looks and renames.
- Two configured names with the same identifier are refused.
- Every item of a read-only domain carries `readOnly`; an item with a non-UTF-8 name does not, and
  can be renamed, rewritten and deleted through the replica; a declared package
  directory takes its package type; a folder named like a flat file stays a folder.

**Versions and content**
- A file's contentVersion is identical before and after its own upload completes; a peer's edit
  changes it.
- `ensure_cached` and `fetch_range` reply with the item whose bytes they wrote, and its size equals
  the bytes delivered.
- A concurrent-edit write (stale `base`) keeps both contents; a may-already-exist replay of identical
  content uploads nothing.
- Partial ranges cover the request, start aligned, have aligned length except at end of file, grow
  only outwards, clamp at end of file, are empty past it, and handle an empty file and alignments of 0
  and 1.
- Reading 4 KiB in the middle of a large dataless file is served by range fetches totalling less than
  the file.

**Request interface**
- Every refusal, the router's included, carries a code; `read_only`, `denied` and `invalid` on a
  mutation map to cannot-synchronize; only `unreachable` maps to server-unreachable.
- A request to a wedged owner fails within its deadline; cancelling returns without waiting for the
  owner; concurrent tasks share no unsynchronised client state.
- An existing `dest`, or a link at any component, is refused `denied` and touches nothing.
- `create`, `mkdir`, `symlink` and `write` with `exclusive`, and `rename` with `noreplace`, onto a
  taken name answer `exists` and change nothing; a rename onto the item's own place answers the item.

**Enumeration and feed**
- Folder pages and whole-domain pages lie end to end with no gap or repeat; a resume against a remade
  walk answers `{stale:true}`, never another walk's position; the last page of a whole-domain listing
  costs no more than the first.
- A change enumeration that fails finishes with an error, never at its starting anchor.
- Change batches: create then delete → only deleted; rename then delete → deleted; a→b→c → one update
  at c; a removal needs no item; an update without an item is not invented.
- The anchor of the last full enumeration, and the last anchor asked from, survive applied-log
  retention past the horizon; an empty-entry anchor is stale once a shard was dropped; a rebuild
  leaves outstanding anchors valid.
- Oversized pages or anchors are refused; sentinels are not names; non-UTF-8 anchor bytes are no
  anchor.

**Lifecycle**
- A domain added to the config is registered after the owner restarts, without restarting the app,
  including the first domain of a fresh install; the new domain is enumerated without user action.
- `reset` leaves the owner running and the domain re-registered and enumerated; no process is
  terminated; `purge` removes domains before stopping the owner; an unreadable config removes nothing;
  a removal preserves dirty data.
- Make Available Offline on a file makes it readable with the store unreachable; Make Online Only
  leaves it dataless on disk and absent from the cache.
- After the owner and the app are stopped for longer than the journal horizon and restarted, the
  replica converges through a change enumeration, without a scan.
- The replica passes the system's consistency check after the platform-neutral end-to-end scenario.

## 15. Rationale (do not undo)

- **The owner holds the anchor and compares it.** The sandbox denies the extension every file the
  owner writes; an extension-side token was always empty and reimport expired nothing.
- **The working set is one owner-paged listing over a kept walk, resumed by byte offset.** Walking in the extension carried a
  frontier in the page, which overflowed 500 bytes at about 26 folders and ended enumeration silently;
  re-walking per page cost a minute a page at 220k items; a name cursor looped on a folder id at two
  paths.
- **Anchors survive downtime and rebuilds.** At 220k items the scan after an expiry never finished and
  the replica held 40k items for weeks.
- **Two enumerators.** A single one reported the whole journal into every folder's changes.
- **Report every change.** A materialised-set filter left folders on disk forever.
- **Stable file ids.** Name-derived file identifiers made every file rename a merge and every remote
  rename a re-download; they also needed a read-only rule for lossy names and source-retiring logic in
  change batches.
- **Only `unreachable` and an absent owner latch, and both are unlatched by the relay.** Latching on
  other codes took domains offline for weeks after a one-second owner restart, when nothing
  signalled them resolved.
- **The owner writes fetched files into the system's temporary directory.** The extension cannot move
  files there.
- **Content identity survives the upload.** A version that moved on publish re-fetched every saved
  file.
- **The fetch reply carries the item.** A separate stat could describe a newer version than the bytes
  written.
- **Reset never kills processes.** Matching processes by path killed the owner, whose binary is in the
  app bundle.
- **No app round trip for offline actions, no destination root declared by the app.** Both made the
  extension's work depend on the app running.
- **Relay backoff resets on uptime, not on acknowledgement.**
- **Connection per request.** Replies carry no request id; pooling would serialise requests.
- Rejected: a helper registered through the app for the owner's sockets; a disk image; in-memory page
  offsets; path or parent-and-name identifiers; a materialised-set filter; mapping pins onto the
  item's content policy (pin state is not in the change feed, and the pinned cache already makes
  reads offline-safe); reading the replica folder from the owner.

---

Implementation notes for this subsystem: [../ocaml/frontends/file-provider.md](../ocaml/frontends/file-provider.md).
