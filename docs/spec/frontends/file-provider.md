# The macOS host (File Provider frontend) — as built on `main`

Scope: the normative behaviour of the macOS integration as `main` implements it: the Swift app
(`TsyncApp`), the replicated File Provider extension (`TsyncFileProvider`), and the daemon side they
talk to (the `file_provider` frontend and the shared request handler). Build, CI and release are out
of scope.

This is an extraction, not a design: every rule below is what the code does, including where that is
wrong. Defects are left in and marked **[as built]** where they are worth calling out; the cleaned
spec is a separate pass.

---

## 1. Processes

| Process | Started by | Sandboxed | Holds a File Provider manager | Role |
|---|---|---|---|---|
| Daemon | user LaunchAgent `org.feverdreamtv.tsync.daemon` running `<app>/Contents/MacOS/tsync start` | no | no | Owns every domain configured with `file_provider`; serves one request socket for all of them; publishes events. |
| App (`TsyncApp`) | login item (`SMAppService.mainApp`); `LSUIElement` | yes (App Group, network client) | yes | Registers and removes domains at launch; one event relay per registered domain; menu bar item. |
| Extension (`TsyncFileProvider`) | the system, per domain | yes (App Group, network client, hardened runtime) | only to get its temporary directory | Implements every File Provider callback by asking the daemon. |
| CLI | user | no | no | `tsync fileprovider reimport|reset|purge`, `tsync restart`. |

- The daemon never connects to the app or the extension; both connect to its socket.
- Change notification is the app's job, not the extension's: the system stops the extension when the
  domain is idle.
- The daemon is a plain LaunchAgent, not an `SMAppService.agent`: the latter reported `.notFound` for a
  sealed, team-signed bundled agent.

## 2. Identifiers and paths

| Thing | Value |
|---|---|
| App bundle id | `org.feverdreamtv.tsync` |
| Extension bundle id | `org.feverdreamtv.tsync.fileprovider` |
| App Group | `group.org.feverdreamtv.tsync` |
| Agent label | `org.feverdreamtv.tsync.daemon` |
| Group container | `containerURL(forSecurityApplicationGroupIdentifier:)`, falling back to `~/Library/Group Containers/<group>` |
| Config | `<group>/config.json` |
| Data directory | `<group>/tsync/` |
| Cache root | `<group>/tsync/cache/` |
| Socket | `<group>/tsync/tsync.sock` (the client refuses a path ≥ `sizeof(sun_path)`) |
| Reset marker | `<data>/fileprovider-reset`, one display name per line, appended |
| Purge marker | `<data>/fileprovider-purge` |
| Identity-scheme record | `<data>/fileprovider-identity-scheme`, decimal integer, written with `atomically: true` |
| Resync generation | `<data>/resync-<domain name>` |
| Kept whole-domain walk | `<domain scratch dir>/.tsync-list-all` |
| Daemon log | `~/Library/Logs/tsync-daemon.log` (agent stdout and stderr) |
| CLI link | `/usr/local/bin/tsync` → `<app>/Contents/MacOS/tsync` |
| Extension staging | `<extension container>/tmp/staging/` (`FileManager.temporaryDirectory`) |

**Domain identifier.** `identifier(name) = lowercase(name)` with every space replaced by `-`. The
display name is the config `name`. Two names mapping to one identifier are not detected **[as built]**.

**Replica folder.** The daemon finds a domain's replica folder by listing
`~/Library/CloudStorage` and picking the entry whose lowercase-alphanumeric projection equals that of
`"TsyncApp" + name`. Used only for availability (§9.2).

The app reads only `domains[].name` from the config. The extension never reads the config.

## 3. The request socket

### 3.1 Transport

- Unix stream socket, newline-delimited JSON, one request line → one reply line.
- The daemon serves connections concurrently and requests on one connection in order. It never sets
  TCP options on the socket (setting TCP_NODELAY made macOS answer EINVAL and killed the accept loop).
- The Swift client opens **one connection per request**: connect, set `SO_NOSIGPIPE`, write the line,
  `shutdown(SHUT_WR)`, read one line, close. Replies carry no request id, so a shared connection would
  serialise requests.
- Reply lines are decoded lossily as UTF-8 (U+FFFD for invalid bytes), so one bad name costs one item,
  not the reply.
- The verdict (`ok`, `code`, `error`) is decoded first; `ok:false` becomes a remote error with
  `code` (missing → `internal`) and `error` (missing → `"unknown error"`).
- **No deadline** on any request **[as built]**. A request blocks a global-dispatch-queue thread in
  `recv` until the daemon answers or the socket is shut down.
- **Cancellation**: a per-request cancellable socket, locked throughout. Cancelling marks it cancelled
  and `shutdown(SHUT_RDWR)`s the descriptor if one is open; a request whose cancel arrived before
  connect closes its fresh descriptor and fails with cancellation; a failure on a cancelled socket is
  reported as cancellation, not transport. The descriptor is closed under the same lock.
- A synchronous variant (`sendSync`) exists with no cancellation; the extension uses it for the
  read-only probe (§5.9).

### 3.2 Routing (daemon)

Requests are `{"action":…, "domain":<display name>, …}`.

- `menu` and `menu_stats` are answered by the router across all domains (§8).
- Otherwise the request goes to the named domain's handler; with no `domain` and exactly one domain
  served, to that one.
- An unknown or ambiguous domain, invalid JSON, or a non-object is answered `{"ok":false,"error":…}`
  **with no code** **[as built]**; the client reads it as `internal`.
- A `preview` action (`body`: the staged path of an upload in flight) is answered by the frontend with a
  base64 QuickLook PNG. No Swift client sends it **[as built: dead verb]**.

### 3.3 Actions used by the macOS clients

The handler is shared with other frontends; this lists what the macOS clients send and what they rely
on.

| action | sent by | request | reply relied on |
|---|---|---|---|
| `stat` | ext | `ref` | the item row at top level |
| `list_dir` | ext | `ref`, `after?`, `limit?` | `items`, `next?` |
| `list_all` | ext | `after?`, `limit?` | `items`, `next?` |
| `changes_since` | ext | `arg` = anchor, `limit?` | `stale` or `cursor`, `more`, `ops` |
| `cursor` | ext | — | `cursor` |
| `ensure_cached` | ext | `ref`, `dest` | ok |
| `fetch_range` | ext | `ref`, `dest`, `offset`, `length` | `offset`, `length` (served) |
| `download_progress` | ext | `ref` | `active`, `bytesDownloaded`, `totalBytes` |
| `create` / `mkdir` / `symlink` | ext | `parentRef`, `name`, (`target`) | `item` |
| `write` | ext | `parentRef`, `name`, `staging` | `item` |
| `rename` | ext | `ref`, `parentRef`, `name` | `item` |
| `delete` / `rmdir` | ext | `ref` | ok |
| `share` | ext | `ref` | `url` |
| `evict` / `restore` | ext | `ref` | ok |
| `status` | ext | — | `readOnly` |
| `subscribe` | app | `domain` | ack, then events |
| `menu` / `menu_stats` | app | — | `menu` / `rows` |
| `pause` | app | `arg` = `"on"`/`"off"` | ok |
| `full_resync` | CLI | `domain` | ok |

Handler rules the clients depend on:

- **References**: `root`, `d:<folderId>`, `f:<parentFolderId>/<leaf>`; `d:.tsync-root` is the root.
  Resolution mints nothing; an unresolvable reference → `not_found`.
- **Read-only**: `create, write, delete, rename, mkdir, rmdir, symlink, revert` are refused `read_only`
  on a read-only domain.
- **Serialisation**: the same set of mutating actions runs under one per-domain mutex, reference
  resolution included (a folder rename racing a move into it filed the moved item under the old path).
- **Item row**: `ref, parentRef, name, kind, size, mtime, etag, isUploaded, [symlinkTarget],
  [trashed], [availability, pinnedUntil]`. Directory: size 0, mtime 0, etag = folder id. File etag =
  published content hash, `""` while staged edits exist.
- **write**: cancel any upload of the key in flight; adopt the staging file by rename; queue the put;
  reply with the staged or published size and mtime and the `item`. The staging path is **not
  confined** to any directory **[as built]**.
- **ensure_cached / fetch_range**: the daemon assembles the whole file, or one range at its offset
  (rest sparse), at `dest`. `dest` is **not confined** and may be overwritten **[as built]**.
  `fetch_range` refuses `offset < 0` or `length ≤ 0` as `invalid`.
- **create / mkdir / symlink / write / rename** have no exclusive mode **[as built]**: `write` and
  `rename` replace an existing destination; `mkdir` answers an existing folder as is.
- **rmdir** removes the folder and its subtree.
- **share** creates a link expiring in 7 days.
- **evict / restore**: the chunk store first (drop bodies and pin / fetch and pin, `keep` optional),
  then the frontend hook publishes an `evict`/`restore` event naming the item's reference. No
  subscriber, or a key with no reference, fails the request ("make sure TsyncApp is running").
  Applies to the key named; folder subtrees are whatever the file operations do with a folder key.
- **pause**: any `arg` other than `"off"` pauses.

### 3.4 Anchors, pages, change feed

- **Anchor** `"<generation>|<entry key>"`; generation = contents of the resync-generation file
  (epoch ms, `""` if never stamped), entry = last applied journal entry (`""` if none). The daemon
  compares both; the client carries the anchor as opaque UTF-8.
- **`changes_since(anchor, limit=512)`**: other generation → `{stale:true}`; anchor entry = applied
  head (or both absent) → no ops, same cursor; anchor entry no longer kept in the applied log →
  `{stale:true}`; else up to `limit` entries after it, `cursor` = last returned, `more`.
- **Applied log** keeps entries applied or published by this client, month-sharded, pruned by
  `keep_days = 30` (by shard mtime) and a byte budget. An anchor older than that is stale.
- **Ops**: `put`, `delete`, `mkdir`, `rmdir` (`id`), `rename` (`is_dir`, `id?`, `srcRef`,
  `srcParentRef`), each with `ref`, `parentRef`, `name`, and `item` except removals. Folder ids
  resolve through an index that outlives the marker. An op whose ends cannot be named is dropped and
  counted in `unnamed`.
- **Folder page cursor** = last name served; names strictly after it, bytewise order, files and
  folders interleaved.
- **Whole-domain page cursor** `"<walk ms>:<line>"` into the kept walk file (§2); a missing file is
  re-walked and skipped to the same line; a non-numeric walk prefix restarts.
- `full_resync` stamps a new generation, then the frontend rebuilds the folder-id index from the
  mirror and publishes `resync`.
- A daemon-side full rebuild of the mirror records its difference into the applied log as local ops,
  so the change feed covers it without a new generation.

## 4. Events

`subscribe` with a `domain` turns the connection into a stream of lines:

```json
{"event":"changed","domain":"Files","id":42}
{"event":"resync","domain":"Files","id":43}
{"event":"evict","domain":"Files","id":44,"ref":"f:<id>/movie.mkv"}
{"event":"restore","domain":"Files","id":45,"ref":"d:<id>"}
```

- `id` is a counter per domain within one daemon process.
- `changed` names nothing. The first changed key schedules one event 0.2 s later; keys arriving while
  one is pending join it. Raised when the daemon applies peer entries, on `revert`, and when an upload
  publishes.
- `resync` follows `full_resync`.
- Events are hints: not durable, not replayed, not acknowledged. Each subscriber queue holds 256; when
  full the oldest is dropped and logged.
- There is no `reset` event and no recovery notice **[as built]**.
- The subscription request does not half-close; the daemon reads end-of-input as unsubscribe.

## 5. The extension

### 5.1 Identifiers

- `root` ↔ `.rootContainer`; `d:.tsync-root` parses as root. `d:<id>` and `f:<parent>/<leaf>` are
  used verbatim as identifier strings; only the first `/` splits a file reference; empty parts fail.
- A row whose `ref` or `parentRef` does not parse is dropped silently.
- An item whose `ref` or `name` contains U+FFFD is presented read-only.
- A file's identifier can be composed client-side (`f:<parent folder id>/<name>`); a directory's
  cannot.

### 5.2 Item model

- `contentType`: directory → the declared package type of its extension if it conforms to directory,
  else `.folder`; symlink → `.symbolicLink`; file → `UTType(filenameExtension:)` or `.data`.
- `documentSize` = size; `contentModificationDate` = mtime when > 0.
- `contentPolicy` = `.downloadLazily`.
- `isUploaded` from the row; `symlinkTargetPath` from the row.
- Root: identifier and parent `.rootContainer`, filename = display name.

### 5.3 Versions

- contentVersion = etag, or `"<size>:<mtime>"` when the etag is empty (staged edits); a symlink appends
  `":<target>"`.
- metadataVersion = contentVersion + `":1"` / `":0"` for uploaded / not.
- Directory: contentVersion = its folder id (stable). Root: contentVersion `"0:0.0"`, metadataVersion `"0:0.0:1"`.

**[as built]** contentVersion changes twice around every local save: to `size:mtime` while staged,
then to the content hash when published. The system sees new content for a file it just wrote.

### 5.4 Capabilities and domain options

- Read-only domain or item: directory {reading, enumerating}; file {reading}.
- Writable: directory {reading, enumerating, adding sub-items, renaming, reparenting, deleting};
  symlink {reading, renaming, reparenting, deleting}; file {reading, writing, renaming, reparenting,
  deleting}. No trashing.
- Domain registered with `supportsSyncingTrash = false`; the trash enumerator throws
  `featureUnsupported`.
- Info.plist: `NSExtensionFileProviderSupportsEnumeration`, `…AllowsUserControlledEviction`, document
  group = the App Group, three custom actions (§5.8). No download pipeline depth (default kept so that
  range fetches do not multiply against slow storage).

### 5.5 Callbacks

Every callback runs its work in a `Task`, returns a `Progress` whose cancellation cancels the task, and
maps errors with §5.10.

| Callback | Behaviour |
|---|---|
| `item(for:)` | Root → synthesised root item. Else `stat(ref)`; an unparseable row → `not_found`. Directories are asked too. |
| `enumerator(for:)` | trash → throw; working set → working-set enumerator; anything else → directory enumerator. Both capture `readOnly` at creation. |
| directory `enumerateItems` | `list_dir(ref, after: page name, limit: suggestedPageSize ?? 100, ≥1)`; `didEnumerate`; `finishEnumerating(upTo: next page or nil)`. No change enumeration. |
| working set `enumerateItems` | `list_all` pages, same shape. |
| working set `enumerateChanges` | `changes_since(anchor, suggestedBatchSize ?? 100)`. `stale` → `syncAnchorExpired`. Else resolve ops (§6); `didDeleteItems` then `didUpdate`; `finishEnumeratingChanges(upTo: cursor ?? anchor, moreComing: more)`. Any error → `finishEnumeratingWithError`, never at the starting anchor. |
| `currentSyncAnchor` | `cursor`; error → nil. |
| `fetchContents` | dest = `temporaryDirectoryURL()/<UUID>`; `ensure_cached(ref, dest)`; then `stat` for the returned item. A poller asks `download_progress` every 0.5 s and sets total and completed when active; at the end completed = total. Failure removes dest. Cancellation → `userCancelled`. The requested `version` is ignored. |
| `fetchPartialContents` | `stat`; with `.strictVersioning` and a different contentVersion → `versionNoLongerAvailable`. Range = aligned (§5.7); empty → `versionNoLongerAvailable`. `fetch_range` into a temp dest; complete with the served range and no flags. |
| `createItem` | Read-only → `NSFileWriteVolumeReadOnlyError`. Directory iff type is `.folder`, or no URL and no `.contents` field and the type conforms to directory. With `.mayAlreadyExist` on a non-directory: `stat(f:<parent>/<name>)`; present → return it; `not_found` → continue; other error → fail. Then directory → `mkdir`; symlink → `symlink` (target required, else `invalid`); URL → stage (§5.6) and `write`; else `create`. Reply must carry an item, else `internal`. |
| `modifyItem` | Read-only → error. Contents changed with a URL: stage and `write` at the item's (new) parent and name; if moved, then `delete(old ref)`. Moved only: `rename(ref, parentRef, name)`. Neither: `stat`. The base version is ignored (comment: failing on mismatch needs macOS 26). |
| `deleteItem` | Read-only → error. Directory (identifier names a folder) without `.recursive`: `list_dir(limit 1)`, non-empty → `not_empty`. Then `rmdir` or `delete`; `not_found` → success. Base version ignored. |
| `performAction` | Copy Share URL → `share(first item)` → general pasteboard; Make Available Offline → `restore` each item in turn; Make Online Only → `evict` each item. First failure aborts the rest. |
| `invalidate` | logs only. |

**Pending fields.** Create and modify return `fields − {contents, filename, parentItemIdentifier}` as
still pending (Finder tags were otherwise reverted on disk). `shouldFetchContent` is always false.

### 5.6 Staging uploads

The system unlinks the contents URL after the callback returns. The extension hard-links it (copies if
linking fails) to `<staging>/<UUID>`, sends that path as `staging`, and removes its link when the
request finishes, whatever the outcome. The daemon renames the file into its store. The whole file is
sent on every edit.

### 5.7 Partial ranges

```
aligned(requested, alignment, documentSize):
  size = max(0, documentSize); unit = max(1, alignment)
  wantStart = max(0, requested.location); start = wantStart - wantStart % unit
  wantEnd = min(size, wantStart + max(0, requested.length))
  if start >= size or wantEnd <= start: return (min(start, size), 0)
  end = min(round_up(wantEnd, unit), size)
  return (start, end - start)
```

### 5.8 Custom actions

`org.feverdreamtv.tsync.copyShareURL`, `…makeAvailableOffline`, `…makeOnlineOnly`, each with
activation rule `TRUEPREDICATE` (offered on every item, the root included).

### 5.9 The read-only flag

A lazily evaluated property: on first use, a **synchronous, deadline-less** `status` request from
whatever thread asked (enumerator creation, a callback) **[as built]**; once answered the answer is
kept for the process lifetime; a failed probe answers "writable" and is retried on the next use. The
cell is not synchronised **[as built]**.

### 5.10 Error mapping

Only Cocoa and File Provider error domains are returned.

| daemon | framework |
|---|---|
| `not_found` | `fileProviderErrorForNonExistentItem(identifier)` when an identifier is known, else `noSuchItem` |
| `exists` | `filenameCollision` |
| `not_empty` | `directoryNotEmpty` |
| `read_only`, `denied` | Cocoa `NSFileWriteNoPermissionError` |
| `unreachable` | `serverUnreachable` |
| anything else, transport | Cocoa `NSFileWriteUnknownError` |
| cancellation | `userCancelled` |

Non-daemon errors (staging file operations) pass through unchanged.

## 6. Change batch resolution

```
lastMention[r] = index of the last op in which r appears as ref or srcRef
for (i, op) in ops:
  if op.srcRef and op.srcRef ≠ op.ref and lastMention[op.srcRef] = i: deleted += op.srcRef
  if op.ref and lastMention[op.ref] = i:
    if op is delete or rmdir: deleted += op.ref
    elif op.item parses:      updated += item
```

Nothing is filtered by what the system has materialised.

## 7. The app

### 7.1 Launch and domain registration

At launch: register as login item; then one reconciliation pass. It runs **only at launch** **[as
built]**: a config change, a daemon restart, or a reset request is picked up only when the app
restarts.

1. Read the config (`try?`); create the status menu with the configured names.
2. One 10 s deadline for every framework call of the pass; a `providerNotFound` error is retried every
   1 s until it.
3. Purge marker present: list domains, remove each (`.removeAll`); only if all went, unregister the
   login item and delete the marker. Stop.
4. Config unreadable: touch nothing, start relays, stop.
5. List domains; a failure counts as empty and marks the pass unlisted.
6. `stale` = every existing domain unless the identity record is ≥ 1.
7. `requested` = identifiers of the names in the reset marker.
8. Remove (`.removeAll`) every existing domain not configured or in `requested ∪ stale`.
9. Add every configured domain not surviving step 8, with `supportsSyncingTrash = false`. Nothing
   signals the new domain **[as built]**.
10. Record identity scheme 1 if listed and every stale domain was removed.
11. Delete the reset marker if listed and every requested domain that existed was removed.
12. Start one relay for every domain `NSFileProviderManager.domains()` returns.

### 7.2 Relay

One thread per domain, forever:

```
backoff = 1
loop:
  connected = now
  subscribe(domain)            # no tempDir
  on ack: signal working set; signalErrorResolved(serverUnreachable)
  for each event: handle
  if now - connected ≥ 30: backoff = 1
  sleep(backoff); backoff = min(2·backoff, 30)
```

- `changed`, `resync` → signal the working set and `signalErrorResolved(serverUnreachable)`.
- `evict` → `evictItem(identifier: NSFileProviderItemIdentifier(ref))`; `restore` →
  `requestDownloadForItem(identifier, range NSNotFound)`. The raw reference is used as the identifier,
  so `root` is not translated to `.rootContainer` **[as built]**.
- Unknown events are ignored. Relays are never stopped.

### 7.3 Menu bar

- The daemon renders the menu (`menu`) from the model shared with the Linux tray: `icon`, `tooltip`,
  `submenuPlaceholder`, `rows` with `label, enabled, indent, checked, submenu, separator` and an
  `action` among `openFolder`, `reveal{domain, rel}`, `setPaused`, `stats`, `quit`.
- Poll every 3 s (timer tolerance 1 s) through the first domain's client, skipping while one is
  outstanding. No deadline: a wedged daemon holds the latch forever **[as built]**. A failed poll keeps
  the last menu.
- Not rebuilt while the menu is open; rebuilt on close.
- Icons by name (`tsync-idle|sync|paused|error-symbolic`), template images; unknown → idle.
- Domain root URLs are read once at startup with `getUserVisibleURL(for: .rootContainer)` **[as
  built: never refreshed]**. `openFolder` claims the security scope and calls
  `selectFile(nil, inFileViewerRootedAtPath:)`, falling back to `activateFileViewerSelecting`;
  `reveal` selects the file.
- Pause sends `pause on|off` to each configured domain; the next poll shows the state.
- The stats submenu fetches `menu_stats` when it opens, at most once per second; failure leaves the
  placeholder.

## 8. Daemon-side File Provider frontend

- Descriptor: `file_provider`, tree replicated, one process for all domains, domain socket, CLI group
  `fileprovider`.
- **Hooks**: `evict` = chunk-store evict then publish `evict`; `restore` = `ensure_cached ?keep` then
  publish `restore`; `changed` = debounced `changed`; `full_resync` = rebuild the folder-id index, then
  publish `resync`; `status_fields` adds `subscribers`; `on_upload_done` = `changed`.
- An async exception hook logs instead of exiting.
- **Availability**: replica folder absent → `online-only`; the key's path in the replica missing or
  `SF_DATALESS` → `online-only`; otherwise `pinned` if the chunk store pins it, else `cached`.
- `menu` aggregates every domain's `status`; `menu_stats` every domain's `stats`.

## 9. CLI commands

- **`reimport`**: `full_resync` for the domain; exit 1 unless `ok`.
- **`reset`**: append the name to the reset marker; `pkill -f /Applications/TsyncApp.app`, sleep 1 s,
  `open -a` the app; if the reopen fails, remove the whole marker and exit 1. The pattern also matches
  the daemon, whose binary is inside the bundle, so reset kills the daemon too **[as built]**; launchd
  restarts it only because the kill is unclean.
- **`purge`**: write the purge marker; restart the app as above; if that fails, remove the marker and
  skip unregistration; else wait up to 60 s (0.5 s polls) for the marker to disappear, removing it and
  failing on timeout. Then `launchctl bootout` the agent, remove its plist, `rm -rf` the app bundle and
  the data directory (keeping `config.json`), and remove the CLI link (`lstat`), printing the `sudo rm`
  command when not permitted.
- **`restart`**: `pkill -f` the app bundle, `launchctl kickstart -k` the agent, `open -a` the app.

## 10. Installation

- Notarised component `.pkg` installing `TsyncApp.app` into `/Applications` (the bundle holds the app,
  the daemon/CLI binary, its dylibs, `install-agent.sh` and the `.appex`).
- `postinstall` (root): create `/usr/local/bin/tsync`; as the console user, run `install-agent.sh` and
  `open -a` the app.
- `install-agent.sh`: boot out any running agent; remove a leftover socket; write the plist
  (`RunAtLoad`, `KeepAlive {SuccessfulExit: false}`, stdout/stderr to the log); enable; bootstrap.
- The daemon exits 0 with no configured domain, so launchd leaves it stopped on a fresh install.
- macOS ≥ 13, Apple silicon.

## 11. Parameters

| Parameter | Value |
|---|---|
| progress poll | 0.5 s |
| `changed` debounce | 0.2 s |
| subscriber queue | 256 events |
| relay backoff | 1 s doubling to 30 s, reset after a connection lived 30 s |
| registration deadline / retry | 10 s / 1 s |
| purge wait | 60 s |
| menu poll / stats throttle | 3 s / 1 s |
| default page / changes limit (daemon) | 1000 / 512 |
| client page size fallback | 100 |
| applied-log retention | 30 days, plus a byte budget |
| share expiry | 7 days |
