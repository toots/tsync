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
- trust boundaries and path confinement: [security model](../algorithms/security-model.md);
- conflicts: [conflict resolution](../algorithms/conflict-resolution.md).

---

## 1. Problem

On macOS a folder lazily backed by remote storage is provided through the File Provider framework
(a *replicated* extension), not a kernel filesystem. The framework imposes this shape:

- The operating system keeps a **replica** of each domain on disk under
  `~/Library/CloudStorage/`. Files are dataless placeholders until materialised. The provider never
  writes the replica; it answers callbacks.
- Callbacks are served by an **extension** the system launches, suspends and kills at will. It is
  sandboxed and may not read files other processes wrote into the shared App Group container.
- Only a process holding a File Provider manager (the app or the extension) may register domains,
  signal changes, evict items or request downloads.
- Items are named by opaque identifiers the system persists. Changes are pulled by the system from
  a **working set** enumerator, using opaque **sync anchors**. Pages and anchors are at most 500 bytes.

tsync's engine lives in a long-running, unsandboxed process. This subsystem is the adapter: it
divides the File Provider duties between processes, realises the request interface for sandboxed
clients, and maps tsync's names and change feed onto the framework's identifiers, versions,
enumerations and anchors.

## 2. Processes and ownership

```
                    launchd (per user session)
         ┌───────────────────┴─────────────────────────┐
   LaunchAgent: tsync service                     Login item: TsyncApp (sandboxed)
         │                                          - registers and reconciles domains
         └─ owner of every File Provider domain     - one event relay per domain
            (converges each domain it owns;         - menu bar status item
             serves the request socket)  ◄──────────┘ subscribe, menu, pause, reset notices
                  ▲
                  │ one request per connection
     TsyncFileProvider extension (sandboxed; one instance per domain; started by the system)

     tsync CLI: requests to the owner's socket; takes ownership itself only when no owner runs
```

| Process | Lifetime | Sandboxed | Holds a File Provider manager | Role |
|---|---|---|---|---|
| Owner | started by the service manager, restarted on any unclean exit | no | no | Owns and converges every domain configured with the `file_provider` frontend (P1, [07](../07-daemon-cli.md)). Serves the request socket. Publishes events. |
| App | login item, always running | yes (App Group) | yes | Domain registration, reset and purge; relays owner events to the framework; menu bar. |
| Extension | started and stopped by the system | yes (App Group, network client) | only to obtain its temporary directory | Implements every File Provider callback by asking the owner. Holds no state across callbacks except the cached read-only flag (§6.9). |
| CLI | one-shot | no | no | Sends requests to the owner. `fileprovider reimport|reset|purge` (§9). |

**Ownership (P1).** One process owns all File Provider domains of the user. It holds each domain's
ownership lock for its lifetime and is the only process that mutates their local state. It also
converges them: reconcile, journal polling and application, maintenance, and resumption of deferred
work. Any other frontend configured for one of these domains runs inside the same owner. The app,
the extension and the CLI act on a domain only through the owner's request interface. A one-shot
command that finds no owner running MAY take ownership for its own duration, as
[07](../07-daemon-cli.md) specifies. Because the owner applies peer changes itself, it learns which
keys changed in-process; no notice crosses a process boundary for that.

**Direction rule.** The owner never connects to the sandboxed processes. Sandboxed processes can
always connect to the owner's socket, but the owner cannot reach into them and the system owns their
lifetime. The app therefore subscribes and receives events on its own connection, and the extension
makes only request/reply calls.

**Why the app relays events, not the extension.** The system stops the extension exactly when the
domain is idle, which is when remote changes need reporting. The app is a login item and stays up.

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
| Extension staging directory | `~/Library/Containers/<extension bundle id>/Data/tmp/staging/` |

The generation stamp and the kept whole-domain walk are the owner's local state and live where
[local state](../data-model/local-cache.md) puts them. Unix socket paths are limited to 104 bytes;
the request socket path MUST fit.

Every marker and record above is written by the rule of
[durable-queue.md](../algorithms/durable-queue.md) (temporary file, fsync, rename, directory fsync).

### 3.3 Domain identifier

The config's domain `name` is the File Provider **display name**. The File Provider **domain
identifier** is derived from it:

```
identifier(name) = replace every U+0020 SPACE with "-" in lowercase(name)
```

where `lowercase` is the Unicode default lowercase mapping. The derivation is part of the installed
base: registered domains are found again by it.

- Every client names the domain to the owner by its display name, byte for byte equal to the
  config name. The identifier is used only between the app and the framework.
- On a macOS host, config validation MUST refuse two domains configured with `file_provider` whose
  identifiers are equal, or whose replica-folder projections (§3.4) are equal, naming both domains.
  The domain name grammar itself is [01-core.md](../01-core.md)'s.
- The app MUST NOT register a domain whose identifier equals one it registers for another name in
  the same pass. If it meets such a collision (a configuration that bypassed validation), it
  registers neither and reports the collision in the menu.

### 3.4 Locating the replica folder

The system names a domain's replica folder `<app name>-<display name>` after dropping characters it
does not put in a path, by an undocumented rule. The owner finds it by listing `~/Library/CloudStorage`
and comparing projections that keep only lowercase ASCII letters and digits:

```
projection(s) = the lowercase ASCII letters and digits of lowercase(s), in order
replica(domain) = the entry e with projection(e) = projection("TsyncApp" + name)
```

It is absent until the domain is registered and the system has created the folder. The owner uses it
only to answer availability (a dataless file is `online-only`); it never writes there.

## 4. The request interface on macOS

### 4.1 Framing

- A Unix stream socket at the request socket path, carrying newline-delimited JSON as
  [08](../08-frontends.md) specifies.
- The owner serves each connection sequentially and every connection concurrently. A failure on one
  connection (including a socket-option or accept error) MUST NOT stop the listener. The owner MUST
  NOT set TCP options on Unix sockets.
- `subscribe` turns the connection into an event stream (§8.1).

### 4.2 Routing and refusals

Requests are `{"action": <verb>, "domain": <display name>, …}`, routed as
[07 §4.2](../07-daemon-cli.md#42-envelopes) specifies.

- An absent `domain` is accepted only when the owner serves exactly one File Provider domain.
- **Every refusal carries a code**, the router's own included; the kind-to-code mapping is
  [failure-model.md §7.2](../algorithms/failure-model.md#72-client-error-codes). A request naming a
  domain the running owner does not serve (the config changed and the owner was not restarted) is
  answered `unreachable`, with prose naming the domain; the latch this sets in the framework is
  cleared by the relay when the owner restarts with the domain (§8.2).

`menu` and `menu_stats` span domains and are answered by the router itself (§10).

### 4.3 Mapping codes to the framework

The meaning of each code, and what every client must do with it, is
[failure-model.md §7.2](../algorithms/failure-model.md#72-client-error-codes). The extension realises
it with this table, and MUST return to the framework only errors in the Cocoa or File Provider error
domains (any other domain surfaces as an unexplained I/O error).

| code | Framework error |
|---|---|
| `not_found` | `noSuchItem`, built for the item's identifier when the call names one |
| `exists` | `filenameCollision` |
| `not_empty` | `directoryNotEmpty` |
| `read_only`, `denied` | Cocoa write-no-permission, carrying the owner's sentence |
| `unreachable` | `serverUnreachable` (latches until `signalErrorResolved`) |
| `paused`, `busy` | Cocoa write-unknown, carrying the owner's sentence |
| `invalid`, `internal`, an unknown code, a transport failure, a client deadline | Cocoa write-unknown |
| cancellation | Cocoa user-cancelled |

Only `unreachable` maps to `serverUnreachable`: the framework retries everything else, so an owner
restarting costs one retried operation, never a latched domain. `paused` reaches the File Provider
only from the Copy Share URL action (writes are accepted and held while paused,
[07 §2.6](../07-daemon-cli.md#26-pause)), and is shown to the user there.

### 4.4 Client obligations (Swift client)

- **One connection per request**: connect, write the line, half-close the write side, read one line,
  close. SIGPIPE is suppressed on the socket. A subscription does not half-close.
- **Deadlines.** Every request, including the read-only probe (§6.9) and the menu poll (§10), obeys
  the client deadlines of [failure-model.md §8.2](../algorithms/failure-model.md#82-requests-between-processes).
  The extension treats `ensure_cached`, `fetch_range` and `write` as bulk requests (their duration
  grows with a file's size) and bounds them with the liveness probe (`ping`) that section specifies. A
  deadline expiry closes the socket and is reported like a transport failure.
- **Cancellation**: cancelling a request shuts the socket down in both directions under a lock and
  returns at once with a cancellation error. A request cancelled before its connection opened never
  opens one. The descriptor is closed under the same lock, so a cancel never shuts a reused
  descriptor number.
- **No blocking call on a framework callback thread** waits without a deadline, and blocking socket
  I/O never occupies a shared thread pool that other requests need.
- **Thread-safe state.** Every piece of client state read or written by more than one task (the
  cancellable socket, the read-only cell of §6.9, the menu's poll latch of §10) MUST be synchronised.
  A latch that marks a request outstanding MUST be released when the request's deadline expires.

### 4.5 Transfer paths (confused-deputy protection)

`write` names a `staging` file the owner adopts, and `ensure_cached`/`fetch_range` name a `dest` the
owner creates. The rule is [security-model.md §7.3](../algorithms/security-model.md#73-paths-passed-over-ipc-confused-deputy),
enforced by the handler ([08 §3.5](../08-frontends.md#35-rules-the-handler-enforces)). On macOS the
File Provider host declares these transfer roots:

- **staging root**: the extension staging directory (§3.2), derived by the owner from the extension's
  bundle id, never taken from a request;
- **destination root**, per domain: the provider temporary directory the app declared for that domain
  in its subscription (§8.2). The app holds a File Provider manager and obtains the directory from the
  framework; the extension, the less trusted party, never declares it.

Until the app has declared a domain's destination root, requests naming a `dest` for it are refused
with `unreachable`; the declaration arrives with the app's subscription, whose acknowledgement also
makes the relay clear the latch.

## 5. Anchors and pages

The anchor and page cursors are the core's ([08](../08-frontends.md)). On macOS:

- The extension carries an anchor as the UTF-8 bytes of the owner's string, verbatim. Bytes that do
  not decode as UTF-8 are treated as no anchor (never synced).
- A page is the UTF-8 bytes of the owner's resume cursor, verbatim. The two framework initial-page
  sentinels are themselves valid UTF-8, so the extension MUST recognise them explicitly and treat them
  as "from the start" rather than as a name.
- Every anchor and cursor the owner issues fits in 500 bytes by construction (names are at most 255
  bytes; walk cursors and anchors are short). The extension MUST refuse, not truncate, any anchor or
  page longer than 500 bytes: an oversized page ends the enumeration there, and an oversized anchor is
  reported as no anchor.
- Page and batch sizes are the framework's suggested size, or 100 when it suggests none, and at least 1.

A cursor must mean the same thing to a freshly started extension: the extension is killed and
restarted at will, and pages and anchors outlive the object that issued them. No cursor may encode an
in-memory offset.

## 6. File Provider mapping (extension)

### 6.1 Identifiers

- An item's identifier is its item reference ([08](../08-frontends.md)), verbatim. `root` maps to the
  framework's root container identifier and back; the root item's parent is itself.
- Rows whose `ref` or `parentRef` do not parse are dropped.
- A name or reference containing U+FFFD (bytes that were not UTF-8, decoded lossily) is presented
  read-only: its reference no longer names what the owner holds, and writing it would create a second
  item and fail to delete the first.

### 6.2 Item model

- `contentType`: a directory whose extension is a declared package type conforming to directory
  (for example `.rtfd`, `.logicx`, `.band`) takes that type, any other directory is a folder; a
  symlink is a symbolic link; a file takes the type of its filename extension, else generic data.
- `documentSize` = size; `contentModificationDate` = mtime, absent when mtime ≤ 0.
- `contentPolicy` = download lazily: download on read, keep materialised items up to date, evictable
  under pressure.

### 6.3 Versions

Both versions MUST be non-empty (the framework drops empty version data).

- **contentVersion** changes if and only if the bytes of the item change. In particular it MUST NOT
  change when this client's own upload of content the system already holds completes: a changed
  contentVersion makes the system fetch a materialised file again and replace the file the user just
  saved.
  - File: the row's content identity (`contentId`, see below) when present, else
    `"<size>:<mtime>"`. A symlink appends `":<target>"`.
  - Directory: its folder id, constant for its lifetime. Children changes arrive through the working
    set, never through the parent's version.
- **metadataVersion** = contentVersion + `":1"` when uploaded, `":0"` when not, so an upload finishing
  refreshes the item's metadata without touching its content.

**Content identity.** The item row carries, for a file, `contentId`: the whole-file digest `h1` of the
content the key resolves to ([02](../02-remote-model.md)). For a published file it equals the etag. For
a file whose staged content is a whole adopted body, the owner computes the digest while adopting the
body, with the chunk size the upload will use, and reports it immediately; the later publish yields
the same `h1`. A file with staged partial edits (not produced on macOS) has no `contentId` until
published. The `etag` keeps its meaning ([08](../08-frontends.md)).

### 6.4 Capabilities and domain

- Read-only domain or read-only item (§6.1): directory {reading, enumerating}; file {reading}.
- Writable: directory {reading, enumerating, adding sub-items, renaming, reparenting, deleting};
  symlink {reading, renaming, reparenting, deleting}; file {reading, writing, renaming, reparenting,
  deleting}. No trashing capability.
- The domain is registered with `supportsSyncingTrash = false`, since trash is not implemented, and
  the trash container's enumerator fails as unsupported.
- The extension declares user-controlled eviction, enumeration support, the three custom actions
  (§6.7). How many fetches the system may issue concurrently is left at its default (see the
  implementation notes).

### 6.5 Callbacks

| Callback | Behaviour |
|---|---|
| item for identifier | Root → the synthesised root item. Otherwise `stat`. Directories are asked too: answering from the identifier would keep a deleted folder on disk forever. Errors map with the identifier, so the system reconciles that exact item away. |
| enumerator for container | Working set → the working-set enumerator; any other container → a directory enumerator. |
| directory: enumerate items | `list_dir(ref, after: page, limit)`. A directory enumerator has no change enumeration: a replicated extension can signal only the working set, so it would never be asked. |
| working set: enumerate items | `list_all` pages over the whole domain; items carry their real parent. A fresh anchor is paired with a full enumeration. |
| working set: enumerate changes from anchor | `changes_since(anchor, limit)`. `stale` → finish with sync-anchor-expired (the system re-enumerates). Else resolve the ops (§7), report deletions and updates, and finish up to the returned cursor with `more` as more-coming. **On any error, finish with the error, never at the starting anchor**: finishing there claims "up to date" and the system stops asking for the life of the domain. |
| current sync anchor | `cursor`; on failure, no anchor (an invented anchor would come back unparseable and cost a rescan). |
| fetch contents | `dest` = a new UUID name in the provider temporary directory; `ensure_cached(ref, dest)`: the owner writes the file there, because the extension may not move files into that directory. Then `stat` for the returned item. Progress is driven by polling `download_progress` every `progress_poll_interval`; the total is set when known and completed at the end. On failure the destination is deleted. |
| fetch partial contents | `stat` first. With strict versioning and a different contentVersion → version-no-longer-available. Range = `aligned` (§6.8). An empty range → version-no-longer-available (the owner rejects length 0 as `invalid`, which the system would retry forever). `fetch_range(ref, dest, offset, length)`; complete with the **served** range. |
| create item | Read-only → volume-read-only. It is a directory iff the type is folder, or the type conforms to directory and no contents are offered (a flat file named like a package is offered contents). With may-already-exist (a reimport replay) on a non-directory: compose `f:<parent id>/<name>` and `stat` it; if present return it without writing (else a reimport re-uploads the domain). **Only `not_found` means absent**; any other error propagates. Then: directory → `mkdir`; symlink → `symlink` (target required); contents → stage and `write`; else `create`. Every creation that is not a may-already-exist replay is sent with `exclusive:true`: an existing name is refused with `exists`, which the system presents as a name collision. |
| modify item | Read-only → error. Contents changed: stage and `write` at the new parent and name, carrying `base` = the content identity in the base version the system gave (omitted when that version is a `size:mtime` fallback); if the item also moved, the write is `exclusive:true` at the new name and is followed by `delete(old ref)`, because a file's reference changes with its name. Moved only: `rename(ref, parentRef, name)` with `noreplace:true`. Otherwise (only unsupported fields): answer with a fresh `stat`. |
| delete item | Read-only → error. A directory without the recursive flag: `list_dir(limit: 1)`; non-empty → `not_empty`. Then `delete`/`rmdir`; `not_found` → success. |
| custom actions | Copy Share URL → `share(first item)` → pasteboard; Make Available Offline → `restore` each item; Make Online Only → `evict` each item. |

**Pending fields.** Create and modify MUST return every changed field other than contents, filename
and parent as still pending. Otherwise the system writes its own idea of them to disk (Finder tags were
silently reverted) and offers them again.

**Mutation replies carry the item.** The extension fails the operation as `internal` when a mutation
reply names no item: completing without one tells the system nothing about what changed.

**Concurrent edit on write.** A `write` carrying `base` whose base differs from the key's current
content identity is a local edit of a version this client no longer has. The owner keeps both sides
as [conflict resolution](../algorithms/conflict-resolution.md) specifies for a stale `base`; the
reply's `item` is the key as it now resolves, so the system fetches the winning content and learns of
the copy through the change feed. The base travels with the published `put`
([03 §2.3](../03-journal-sync.md#23-journal-ops)), so a peer's concurrent edit is settled the same way
at publish time.

**Progress and cancellation.** Every callback returns a progress object whose cancellation cancels the
request; the system cancels slow fetches and expects the completion handler promptly.

### 6.6 Staging uploads

The system unlinks the contents URL it handed over once the callback returns, and the upload outlives
that. The extension hard-links the URL (or copies it, when linking fails) to a new UUID name in its
staging directory, sends that path as `staging`, and removes its link afterwards whatever the outcome.
The owner validates the path (§4.5) and adopts the file where it is, as [08](../08-frontends.md)
specifies for `write`. The whole file is re-sent on edit; chunk deduplication keeps unchanged chunks
off the wire.

### 6.7 Evict and restore

The custom actions and the CLI send `evict` and `restore`, whose chunk-store semantics (subtree of a
folder, root included; per-file counts; staged content never dropped) are
[08 §3.4](../08-frontends.md#34-evict-and-restore). The File Provider host's hooks then move the
replica: `surface_evicted` and `surface_restored` publish an `evict` or `restore` event naming the
request's reference, and the app evicts the item from the replica or requests its download (§8.2).

- With no subscriber, the hook fails and the request is refused with a sentence telling the user to
  start TsyncApp and retry; it never reports success for a replica nobody changed.
- Finder's own Download Now and Remove Download act on the replica only and leave pins alone.

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
alignment except at end of file. The alignment is a runtime value and MUST NOT be assumed constant.

### 6.9 The read-only flag

The sandboxed extension cannot read the config, so it asks the owner (`status.readOnly`).

- The probe runs asynchronously when the extension starts, under the client deadline (§4.4), never
  inside a framework callback.
- The answer is kept in a synchronised cell for the extension's lifetime. A `read_only` refusal also
  sets it. A failed probe is retried at most once per `readonly_probe_retry`.
- Until an answer arrives the domain is presented writable; the owner refuses writes to a read-only
  domain itself.

## 7. Change batch resolution

A pure function turns an ordered page of ops into an unordered set of updated items and deleted
identifiers:

```
lastMention[r] = index of the last op in which r appears as ref or srcRef
for (i, op) in ops:
  if op.srcRef ≠ none and op.srcRef ≠ op.ref and lastMention[op.srcRef] = i:
    deleted += op.srcRef                     # a file rename retires its old reference
  if op.ref ≠ none and lastMention[op.ref] = i:
    if op is delete or rmdir: deleted += op.ref
    elif op.item parses:      updated += op.item
    # otherwise nothing: no field is invented and nothing asks the owner again
```

Every change is reported wherever it sits. The extension MUST NOT filter by what the system has
materialised: the system tracks that itself, and a filter drops removals under unbrowsed folders and
leaves folders on disk.

## 8. Change signalling

### 8.1 Events

A subscription (`subscribe` with the domain) receives one JSON line per event:

```json
{"event":"changed","domain":"Files","id":42}
{"event":"resync","domain":"Files","id":43}
{"event":"evict","domain":"Files","id":44,"ref":"f:<id>/movie.mkv"}
{"event":"restore","domain":"Files","id":45,"ref":"root"}
{"event":"reset","domain":"Files","id":46}
{"event":"recovered","domain":"Files","id":47}
```

- `id` increases monotonically within one owner process. No acknowledgement exists; a client uses
  `id` only for ordering.
- `changed` names nothing: the answer is always "enumerate the working set's changes". The owner emits
  it debounced: the first changed key after a quiet period schedules one event `changed_debounce`
  later, and further keys in that window join it. It is raised when the owner applies a peer change,
  on `revert`, and when an upload completes (upload state is part of the item's version).
- Events are hints on top of the change feed. They are not durable and not replayed; a lost event
  costs promptness, not correctness. Nobody subscribed is not a failure for `changed` or `resync`.
- Each subscriber's queue is bounded. When full, the oldest event is dropped and the drop is logged;
  the next event still makes the app enumerate. `status.subscribers` reports the count.
- `recovered` is the domain's recovery notice
  ([failure-model.md §7.2](../algorithms/failure-model.md#72-client-error-codes),
  [08 §3.8](../08-frontends.md#38-events)): a store request succeeded after the owner had answered
  `unreachable`.

### 8.2 The app's relay

One relay per registered domain, on its own thread:

```
loop:
  connect; subscribe(domain, tempDir = the provider temporary directory for the domain)
  on acknowledgement:
    signal the working set; signal error resolved (serverUnreachable)
    if this is a reconnection: reconcile domain registrations (§9.1)
  read events until the connection ends
  back off, then retry
```

- The subscription declares the domain's provider temporary directory (§4.5). The app obtains it from
  the framework; the owner keeps the latest declaration per domain in memory.
- Signalling on every (re)subscription catches up on whatever was missed, since events are not
  replayed.
- Backoff starts at `relay_backoff_min`, doubles to `relay_backoff_max`, and resets only when a
  connection lived at least `relay_backoff_reset` (an acknowledgement is free, and a crash-looping
  owner would otherwise cause a working-set enumeration per second). The relay never gives up.
- Handling:
  - `changed`, `resync`, `recovered` → signal the working set, and signal error resolved;
  - `evict` → evict the item from the replica; `restore` → request its download (whole range);
    the event's `ref` is translated to the framework identifier exactly like an item identifier
    (§6.1), so `root` names the root container;
  - `reset` → run the registration pass of §9.1 now, which reads the purge and reset markers;
  - unknown events are ignored.
- Signalling a specific item is ignored by the framework for replicated extensions, so only the
  working set is signalled.

## 9. Domain lifecycle

### 9.1 Registration (app)

At launch the app registers itself as a login item, then reconciles domains. The same reconciliation
runs whenever a relay reconnects after the owner restarted, which is how a changed configuration takes
effect without restarting the app.

1. Load the config's domain names. Create the menu first, so a failure still shows UI.
2. Take one deadline, `registration_deadline`, for every framework call of this pass. A call failing
   with provider-not-found (the extension registration is being swapped by an installer) is retried
   every `registration_retry` until that deadline.
3. If the purge marker exists: remove every domain; only if all were removed, unregister the login
   item and delete the marker. Register nothing and stop.
4. If the config cannot be read, leave every domain untouched (reconciling against no names would
   remove every domain and its local copies), start relays for the domains that exist, and stop.
5. List existing domains. A failure to list counts as an empty list, and marks the pass *unlisted*.
6. `stale` = every existing domain unless the identity-scheme record says 1, this spec's scheme (item
   identifiers as §6.1 defines them). Writers MUST NOT record another scheme. Readers SHOULD accept an
   absent record or another value, meaning the registered domains use identifiers that cannot be
   translated: they are rebuilt once. Their content goes dataless; the stores are untouched.
7. `requested` = the identifiers of the names in the reset marker.
8. Remove every existing domain that is not configured, or is in `requested ∪ stale`.
9. Add every configured domain that did not survive step 8, subject to §3.3's collision rule, and
   signal the working set of each added domain so its enumeration starts without waiting for a user.
10. Record the current identity scheme only if the pass was listed and every stale domain was removed
    (a domain the system refuses to release must not force a rebuild of all domains at every launch).
11. Clear the reset marker only if the pass was listed and every requested domain that existed was
    removed; a failed removal keeps the marker for the next pass.
12. Start one relay per registered domain that has none, and stop relays of removed domains.

### 9.2 Reimport

`tsync fileprovider reimport` sends `full_resync` to the owner. The owner stamps a new generation
([08 §2.5](../08-frontends.md#25-cursors-and-anchors)), and the host's `reannounce` hook rebuilds the
folder-id index from the mirror and publishes `resync`. Every
outstanding anchor becomes stale, the system re-enumerates the working set and replays creations with
may-already-exist, which the stat guard of §6.5 turns into no-ops. The command fails (exit 1) unless
the owner answered `ok`.

### 9.3 Reset

Only the app may remove a domain. `tsync fileprovider reset`:

1. appends the display name to the reset marker (durably);
2. sends `notify_reset` for the domain; the owner publishes a `reset` event and replies
   `{delivered}`, the number of subscribers reached; the app runs the registration pass of §9.1 at
   once;
3. if `delivered` is 0 or the owner cannot be reached, launches the app (never terminating it), which processes the marker
   at launch.

The command MUST NOT terminate any process: in particular the owner keeps running, so the domain is
served again as soon as the app re-adds it. It reports success when the marker is written and the app
was reached or launched; if neither worked it removes its line from the marker and fails.

### 9.4 Purge (uninstall)

`tsync fileprovider purge`:

1. writes the purge marker, then reaches the app as in §9.3 (`notify_reset`, else launch);
2. waits up to `purge_wait` for the marker to disappear. On timeout it deletes the marker (else the app
   would purge at every later launch) and fails. When the app is not installed or cannot be launched,
   unregistration is skipped;
3. stops the owner through the service manager and removes the service definition;
4. removes the app bundle and the data directory, keeping `config.json`;
5. removes the CLI link when it may; when the link is owned by root it prints the command that removes
   it. The link is tested without following it, since it dangles by then.

The owner is stopped deliberately and only at step 3, after the app released the domains.

`tsync restart` restarts the owner through the service manager (the service manager's own restart,
not a signal matched by process name) and relaunches the app.

## 10. Menu bar

There is no settings window; configuration is `config.json`. The app's only UI is a status item whose
content the owner renders (`menu`) from the same model as the Linux tray
([fuse.md](fuse.md)), so the platforms cannot drift.

```json
{"ok":true,"menu":{"icon":"tsync-sync-symbolic","tooltip":"…",
  "submenuPlaceholder":[{"label":"Reading…","enabled":false}],
  "rows":[{"label":"Files","action":{"openFolder":"Files"}},
          {"label":"movie.mkv — 40%","indent":1,"action":{"reveal":{"domain":"Files","rel":"a/movie.mkv"}}},
          {"separator":true},
          {"label":"Pause","checked":false,"action":{"setPaused":true}},
          {"label":"Stats","submenu":true,"action":{"stats":true}},
          {"label":"Quit tsync menu bar","action":{"quit":true}}]}}
```

- Poll every `menu_poll_interval`, skipping a poll while one is outstanding; a poll that exceeds its
  deadline counts as a failure and releases the latch. The menu is not rebuilt while open (that would
  dismiss it) and is rebuilt on close.
- An owner that cannot be reached, or a poll that timed out, shows the error icon and an "unreachable"
  tooltip rather than the last known state.
- Icons are named as on the Linux panel (`tsync-idle|sync|paused|error-symbolic`); unknown → idle.
- `openFolder` opens the domain's root in Finder; `reveal` selects the file in Finder and never opens
  it.
- Pause toggles all domains through the owner (`pause`), with the semantics of
  [07 §2.6](../07-daemon-cli.md#26-pause). The state shown is read back by the next poll.
- The stats submenu is fetched with `menu_stats` when it opens, at most once per
  `menu_stats_interval`; a failure leaves the placeholder.

## 11. Installation

- Distributed as a notarised installer package installing the app bundle into `/Applications`. A disk
  image cannot install the CLI link and exposes the app to translocation.
- The package's post-install step creates the CLI link, installs the owner's service definition for the
  console user, and launches the app.
- The service definition runs `tsync start` at login and restarts it on any unclean exit. The service
  exits cleanly when no domain is configured, which is every fresh install, and is not restarted then.
  Installing removes a leftover request socket first: a stale socket makes callers believe the owner is
  running.
- The owner is a plain per-user service, not a helper registered through the app: the latter is
  refused by the system for a sealed, team-signed bundled executable. The app itself is the login item.
- The user approves the extension once in System Settings. The owner's first start after an install
  prompts once for access to data from other apps, since it runs from inside the app bundle.
- Apple silicon only; minimum macOS 13.

## 12. The framework's contract (what any reimplementation must honour)

1. Identifiers are persisted by the system; an identifier returned from a modification that differs
   from the one given is a **merge** instruction. Directory identity must survive renames.
2. Replicated extensions may signal only the working set; changes for any container are reported
   through it, with items carrying their real parent.
3. A new anchor pairs with a full enumeration; anchor-expired makes the system re-enumerate; finishing
   a change enumeration at its starting anchor on error means "up to date" forever.
4. Pages and anchors are at most 500 bytes; the initial-page sentinels are valid UTF-8; both must mean
   the same to a fresh process.
5. Only Cocoa and File Provider error domains are accepted. `serverUnreachable` and
   `notAuthenticated` latch until error-resolved is signalled; everything else is retried.
6. Version data must be non-empty; directory versions must be stable, or the system sees a
   modification on every look.
7. The root's parent is itself.
8. "Item for identifier" is the system's authority on existence: `noSuchItem` is how items leave disk.
9. A partial fetch's served range covers the request and is aligned in start and length (short only at
   end of file, checked against the document size); the alignment varies per boot.
10. The extension may not move files into the provider temporary directory, write into the group
    container, or read files other processes wrote there; a fetched file is created at a path the system
    gave; the system unlinks a contents URL once the callback returns.
11. Domain calls may fail with provider-not-found while an installer swaps the extension.
12. Only a process holding a manager can register, signal, evict or request downloads.
13. Trash syncing defaults to on and must be turned off unless trash is implemented.
14. Fields the provider cannot store must be returned as pending.
15. Every callback completes promptly after cancellation.

## 13. Parameters

| Parameter | Recommended | Constraint |
|---|---|---|
| `progress_poll_interval` | 0.5 s | |
| `readonly_probe_retry` | 10 s | |
| `changed_debounce` | 0.2 s | ≤ 1 s |
| `relay_backoff_min` / `relay_backoff_max` / `relay_backoff_reset` | 1 s / 30 s / 30 s | reset ≥ max |
| `registration_deadline` / `registration_retry` | 10 s / 1 s | |
| `purge_wait` | 60 s | |
| `menu_poll_interval` / `menu_stats_interval` | 3 s / 1 s | |

## 14. Conformance

An implementation MUST exhibit these properties; [09-tests.md](../09-tests.md) says how they are
checked.

**Identifiers and references**
- A directory is named by its id and a file by its parent's id and leaf; `root` and `d:.tsync-root`
  are one identity, mapped to the root container; only the first `/` splits; malformed references are
  rejected without an exception; a reference composed by the client equals the owner's.
- A renamed folder keeps its identifier; a directory's version is stable across looks and renames.
- Two configured names with the same identifier or replica projection are refused.

**Items and versions**
- A non-UTF-8 name is read-only; a declared package directory takes its package type; a plain folder
  is a folder; a folder named like a flat file stays a folder.
- A file's contentVersion is identical before and after its own upload completes; its metadataVersion
  changes. A peer's edit changes the contentVersion.
- A created file is fully described by the mutation reply; every mutation reply carries an item.

**Request interface**
- Every refusal, including the router's, carries a code; only `unreachable` latches; an unknown or
  missing code is retried; `not_found` carries the item's identifier.
- A request to a wedged owner fails within its deadline; cancelling a request returns without waiting
  for the owner; concurrent tasks share no unsynchronised client state.
- A `staging` or `dest` outside its permitted directory, or a symbolic link at the leaf, is refused
  with `denied` and touches nothing.
- Many requests in sequence on one connection are answered in order.

**Enumeration**
- Folder pages and whole-domain pages lie end to end with no gap or repeat, including when the named
  cursor entry was deleted between pages; child `parentRef` equals the container's reference.
- A change enumeration that fails finishes with an error, never at its starting anchor; a stale
  answer finishes with anchor-expired.
- Change batches: create then delete → only deleted; file rename → old deleted, new updated; folder
  rename → nothing deleted; rename then delete → both deleted; a→b→c → only c updated, a and b deleted;
  a removal needs no item; an update without an item is not invented.
- Oversized pages or anchors are refused; sentinels are not names; an anchor is carried verbatim;
  non-UTF-8 anchor bytes are no anchor.

**Content**
- Partial ranges cover the request, start aligned, have aligned length except at end of file, grow
  only outwards, clamp at end of file, are empty past it, and handle an empty file and alignments of
  0 and 1.
- Reading 4 KiB at the middle of a large dataless file is served by range fetches totalling less than
  the file, with no whole-file materialisation.
- A concurrent-edit write (stale `base`) keeps both contents.

**Lifecycle**
- Evicting or restoring the root, a folder or a file changes the replica and the chunk store for the
  whole subtree; with no subscriber it fails and says so.
- `reset` leaves the owner running and the domain re-registered and enumerated; `purge` removes
  domains before stopping the owner; an unreadable config removes nothing.
- A domain added to the config is registered after the owner restarts, without restarting the app.
- The replica passes the system's consistency check after the platform-neutral end-to-end scenario.

## 15. Rationale (do not undo)

- **The owner holds the anchor and compares it.** The sandbox denies the extension the generation
  file; an extension-side token was always empty and reimport expired nothing.
- **The working set is one owner-paged listing.** Walking the domain in the extension carried a
  frontier in the page, which overflowed 500 bytes at about 26 folders and silently ended enumeration.
- **Two enumerators.** A single one reported the whole journal into every folder's changes.
- **Report every change; an unnameable op is dropped and counted, not stale.** Stale re-lists the whole
  domain to repair one folder.
- **Only `not_found` means absent in the reimport guard.**
- **Only `unreachable` latches.** Latching on any other code would take a domain offline for a one-second owner restart.
- **The owner writes fetched files into the system's temporary directory.** The extension cannot move
  files there.
- **Relay backoff resets on uptime, not on acknowledgement.**
- **Content identity survives the upload.** A version that moved on publish re-fetched every saved file.
- **Reset never kills processes.** Matching processes by path killed the owner, which then stayed down.
- **Connection per request.** Replies carry no request id; pooling would serialise requests.
- Rejected: a helper registered through the app for the owner (refused by the system); a disk image;
  in-memory page offsets; path identifiers; a materialised-set filter.

---

Implementation notes for this subsystem: [../ocaml/frontends/file-provider.md](../ocaml/frontends/file-provider.md).
