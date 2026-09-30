# The macOS application (File Provider frontend)

Scope: everything under `macos/` (TsyncApp, TsyncFileProvider extension, Shared,
TsyncTests, build/sign/notarize/install scripts, RELEASING.md) and its daemon-side
counterpart `lib/app/frontends/file_provider/` (plus the parts of the generic IPC
handler `lib/app/cli/runner/daemon/engine/ipc_handler.ml` that exist for this client).

The generic frontend seam (`Frontend.S`, topology, `served`, how a launcher forks
frontends) is specified in **[the frontend contract](../08-frontends.md)** and is only referenced here. Journal,
applied-entries, folder ids, chunk store, uploads and conflicts have their own files;
this one specifies how the macOS host uses them.

---


## A1. Problem

On macOS a user folder that is lazily backed by remote storage must be provided through
Apple's **File Provider** framework (`NSFileProviderReplicatedExtension`), not FUSE.
The framework imposes a very specific shape:

- The OS (`fileproviderd`) owns a **replica** on disk under
  `~/Library/CloudStorage/<App>-<Domain>/`; files are "dataless" placeholders until
  materialized. The provider never writes the replica directly: it answers callbacks.
- Callbacks are served by an **app extension** (`.appex`) that the OS launches, suspends
  and kills at will, which is **sandboxed**, and which may not read files other
  processes wrote into the shared App Group container.
- Only a process holding an `NSFileProviderManager` may register domains, signal
  changes, evict or request downloads. The daemon (a plain unsandboxed binary) is not
  such a process.
- Items are identified by opaque identifiers the system persists; changes are pulled by
  the system from a **working set** enumerator using opaque **sync anchors**; pages and
  anchors are opaque blobs ≤ 500 bytes.

tsync's engine (mirror, journal, chunk store, upload queue) lives in a long-running
daemon. This subsystem is the adapter: it splits the File Provider duties across three
processes, defines a JSON-lines IPC contract between them and the daemon, and maps
tsync's naming (logical keys, folder ids) and change feed (applied journal entries)
onto the framework's identifiers, enumerations, versions and anchors.

It is a separate abstraction because none of this is shared with FUSE/Android: the
daemon core stays frontend-agnostic and the frontend contributes only (a) hooks (evict,
restore, changed, full_resync, status/stats fields), (b) an event channel, (c) one extra
verb (`preview`), (d) three CLI commands (`fileprovider reimport|reset|purge`), and (e)
an `availability` answer that reads the replica's dataless flag.

## A2. Process model

```
                   launchd (per user, gui/<uid>)
        ┌──────────────────────┴───────────────────────┐
  LaunchAgent org.feverdreamtv.tsync.daemon      Login item (SMAppService.mainApp)
  $APP/Contents/MacOS/tsync start                $APP/Contents/MacOS/TsyncApp  (sandboxed, LSUIElement)
        │                                          │  - registers/reconciles domains
        ├─ parent: "converging" process            │  - one SignalRelay thread per domain
        │   (sync, uplink owner, journal apply)    │    (subscribes to events)
        │   listens tsync-sync.sock                │  - menu bar status item (polls "menu")
        │   posts {"action":"changed",keys}  ──┐   │
        └─ child: file_provider frontend       │   │
            ONE process for ALL domains  ◄─────┘   │
            listens tsync.sock  ◄───────────────────┘ subscribe (long-lived), menu, pause
                  ▲
                  │ request/reply (one connection per request)
     TsyncFileProvider.appex (sandboxed; one instance per domain; launched by fileproviderd)

     tsync CLI (same binary via /usr/local/bin/tsync symlink): one-shot requests to
     tsync.sock; fileprovider commands write marker files and bounce TsyncApp.
```

| Process | Lifetime | Sandbox | Holds FP manager? | Role |
|---|---|---|---|---|
| daemon parent (`tsync start`) | launchd `KeepAlive{SuccessfulExit=false}`, `RunAtLoad` | no | no | Converges every domain with the store (poller, journal apply, uplink). Sends change notices to the frontend socket. See 08. |
| daemon child (file_provider frontend) | forked by the parent | no | no | Serves **all** domains on one socket `tsync.sock`; answers extension/app/CLI requests; publishes events. Topology `One_process`, `listens = Domain_socket`, `tree = Replicated`. |
| TsyncApp | login item, always up | yes (App Group) | yes | Domain registration/reset/purge; event relay (daemon → `signalEnumerator`/`evictItem`/`requestDownload`); menu bar. |
| TsyncFileProvider.appex | started/stopped by the OS | yes (App Group, network.client, hardened runtime) | via `NSFileProviderManager(for:)` only for temp dir | Implements every File Provider callback by asking the daemon. Holds **no state** across calls except a cached "readOnly" flag. |
| CLI | one-shot | no | no | Generic daemon verbs + `fileprovider reimport/reset/purge`. |

Direction rule (load-bearing): **the daemon never connects out.** Sandboxed processes
can always connect to the daemon's unix socket, but the daemon cannot reach into them
and the OS owns their lifetime. So the app subscribes and receives events on its own
connection; the extension only makes request/reply calls.

Why the app, not the extension, relays events: the extension is stopped exactly when the
domain is idle — which is when remote changes need reporting. The app is a login item
and stays up (`SignalRelay.swift` header comment).

## A3. Filesystem layout and identifiers

| Thing | Value |
|---|---|
| App bundle id | `org.feverdreamtv.tsync` |
| Extension bundle id | `org.feverdreamtv.tsync.fileprovider` |
| App Group | `group.org.feverdreamtv.tsync` |
| Daemon launchd label | `org.feverdreamtv.tsync.daemon` |
| Team ID | `PSE2VP6582` |
| Group container | `~/Library/Group Containers/group.org.feverdreamtv.tsync/` |
| Config | `<group>/config.json` (survives purge) |
| data_dir | `<group>/tsync/` |
| cache_root | `<group>/tsync/cache/` |
| Frontend socket (all domains) | `<group>/tsync/tsync.sock` |
| Converger socket | `<group>/tsync/tsync-sync.sock` |
| http-proxy socket | `<group>/tsync/tsync-http-proxy.sock` |
| Generation stamp | `<data_dir>/resync-<domain>` (decimal ms since epoch) |
| Kept list_all walk | `<scratch_dir(domain)>/.tsync-list-all` |
| Preview scratch | `<cache_root>/previews/` |
| Markers (app ↔ CLI) | `<data_dir>/fileprovider-reset`, `<data_dir>/fileprovider-purge`, `<data_dir>/fileprovider-identity-scheme` |
| Daemon log | `~/Library/Logs/tsync-daemon.log` (stdout+stderr of the agent; syslog opened with LOG_PERROR so it has every line) |
| LaunchAgent plist | `~/Library/LaunchAgents/org.feverdreamtv.tsync.daemon.plist` |
| CLI symlink | `/usr/local/bin/tsync → /Applications/TsyncApp.app/Contents/MacOS/tsync` |
| Replica folder | `~/Library/CloudStorage/TsyncApp-<displayName with disallowed chars removed>` |
| Extension staging | `<extension container>/tmp/staging/<UUID>` (the extension's own sandbox tmp) |
| Fetch destinations | `NSFileProviderManager.temporaryDirectoryURL()/<UUID>` |

All five identifiers must agree across the Xcode project, both entitlements, the Swift
`Config`, `install-agent.sh` and the daemon runtime paths. Changing the App Group
orphans cache and config. Unix socket paths are capped at 104 bytes.

**Domain identity.** Config domain `name` is the *display name*; the
`NSFileProviderDomainIdentifier` is `name.lowercased()` with spaces → `-`. Every client
(`DaemonClient(domain: domain.displayName)`) sends the display name as `"domain"`, and the
daemon routes on it, so display name must equal the config name byte-for-byte.

**Locating the replica folder** (`Conf_parsing.cloud_storage_dir`): the OS names it
`<AppName>-<displayName>` after dropping characters it will not put in a path, by an
undocumented rule. It is found by listing `~/Library/CloudStorage` and comparing
lowercase-alphanumeric-only projections: `alnum(dir) == alnum("TsyncApp" ^ domain)`.
`None` until the domain is registered and fileproviderd has created it.

## A4. Wire protocol (extension/app/CLI ↔ frontend daemon)

### A4.1 Framing

- `AF_UNIX`, `SOCK_STREAM`, path `tsync.sock`. One JSON object per line, `\n`
  terminated, UTF-8 (names passed through as bytes; the Swift reader decodes lossily so
  one bad name costs one item).
- The server serves a connection **sequentially**: read line → handle → write reply
  line → loop, until EOF. Replies carry **no request id**; concurrency comes from
  multiple connections (one server task per connection).
- The Swift client uses **one connection per request**: connect, write line,
  `shutdown(SHUT_WR)` (tells the server no more requests), read one line, close.
  `SO_NOSIGPIPE` set. No client-side timeout; cancellation `shutdown(SHUT_RDWR)`s the
  socket under a lock (see A7).
- A reply of `"subscribe"` turns the connection into an event stream (A4.5); the
  client must **not** half-close it (EOF on the read side ends the subscription).
- `"stop"` replies then stops the server.

### A4.2 Envelope

Request: `{"action": <verb>, "domain": <display name>, ...fields}`. Absent `domain` is
accepted only when the daemon serves exactly one domain; otherwise
`{"ok":false,"error":"cannot tell which domain '<action>' is for: name it with \"domain\""}`.
Routing to the domain happens in the frontend router, except `menu` and `menu_stats`,
which span domains and are answered by the router itself.

Success: `{"ok":true, ...}`. Failure:
`{"ok":false,"code":<code>,"error":<prose>}` where code ∈

| code | from | Extension maps to | Semantics for FP |
|---|---|---|---|
| `not_found` | ENOENT, share not found, "no versions for" | `NSFileProviderError.noSuchItem` (or `fileProviderErrorForNonExistentItem(id)` when the item is known) | item gone; delete treats as success |
| `exists` | EEXIST | `.filenameCollision` | |
| `not_empty` | ENOTEMPTY | `.directoryNotEmpty` | |
| `read_only` | EROFS, backend not writable, domain read-only | Cocoa `NSFileWriteNoPermissionError` | |
| `denied` | EPERM/EACCES | Cocoa `NSFileWriteNoPermissionError` | |
| `unreachable` | backend error, timeout, share unavailable | `.serverUnreachable` | **latches** the domain until `signalErrorResolved` |
| `invalid` | bad request, `Invalid_argument` | Cocoa `NSFileWriteUnknownError` | retried |
| `internal` | anything else | Cocoa `NSFileWriteUnknownError` | retried |
| (transport) | socket connect/read/write failure | Cocoa `NSFileWriteUnknownError` | retried |

Rules: only errors in `NSCocoaErrorDomain` or `NSFileProviderErrorDomain` may be
returned to the framework (any other domain surfaces as an unexplained I/O error).
Only `unreachable` may map to `serverUnreachable`: a daemon restarting (transport error)
must cost one retried operation, never latch the domain off. Unplaceable daemon
exceptions are `internal`, never `unreachable`.

### A4.3 Item references

The wire name of an item (and, verbatim, the `NSFileProviderItemIdentifier` raw value):

| Form | Meaning |
|---|---|
| `root` | domain root (daemon side). The extension maps it to/from `.rootContainer`. |
| `d:<folderId>` | a directory, by its daemon-minted stable folder id. `d:.tsync-root` parses as root. |
| `f:<parentFolderId>/<leaf>` | a file (or symlink): parent folder id + leaf name. Split at the **first** `/` (neither ids nor leaves contain `/`); both halves non-empty. |
| anything else | `Bad` → request answered `not_found` or `invalid`; a storage key is deliberately not accepted as a reference. |

`.tsync-root` is the reserved folder id of the root, i.e. the parent id of every
top-level file (`f:.tsync-root/a.txt`). A top-level item's `parentRef` is `root`.

Why: the framework reads an identifier returned from `modifyItem` that differs from the
one passed in as an instruction to **merge**. Path identifiers would make every folder
rename a silent re-identification of its whole subtree. Folder ids survive renames; a
file's identifier still changes on rename, but that "merge" covers exactly one item,
which the system reconciles. A stable per-file id would require a storage-layout change.
Identifiers reach system logs, so they never spell storage keys (and user paths only
where a leaf is a name).

Only the daemon mints folder ids; a file reference is **composable** by the client from
a container identifier + name (`ItemID.file(in:named:)`), a directory's is not — which
is why every mutation replies with the item it produced.

Resolution on the daemon: `root`→root key; `d:id`→path via folder-id index (mints
nothing; `None` → `not_found`); `f:id/name`→ that folder's path + leaf. A reference's
kind is enforced on `stat` (`f:` must not answer for a folder).

Alternative addressing for path-only callers (desktop menus, CLI): `"rel": "<path>"` in
place of `"ref"`; `rel:""` is root; kind is read from the mirror; absent → `not_found`.

### A4.4 Item row (the one shape for stat, listings, change ops, mutation replies)

```json
{"ref":"f:.tsync-root/a.txt","parentRef":"root","name":"a.txt","kind":"file",
 "size":5,"mtime":1727630000.25,"etag":"650e58ac64da6e0a","isUploaded":true,
 "availability":"pinned","pinnedUntil":1727633600.0}
```

| Field | Meaning |
|---|---|
| `ref`, `parentRef`, `name` | A4.3; the root's `name` is the domain name; root's `parentRef` is `root`. |
| `kind` | `dir` \| `file` \| `symlink` |
| `size` | logical bytes (dir: 0) |
| `mtime` | float seconds (dir: **0**, meaning "no date", constant) |
| `etag` | published manifest's content hash `h1` (16 hex); **`""`** for a file with unsynced edits (staged); for a dir its **own folder id** (constant for its lifetime) |
| `isUploaded` | false while a staged version is unpublished |
| `symlinkTarget` | present only for symlinks |
| `trashed` | present only when true (unused by the extension today) |
| `availability` | files only: `online-only` \| `cached` \| `pinned` (chunk store state, see checkout spec) |
| `pinnedUntil` | with `pinned`: deadline, float seconds |

Staged files: size/mtime come from the staged manifest (authoritative until publish),
`etag:""`, `isUploaded:false`. Listed files with no readable manifest fall back to the
listing's size/mtime, `etag:""`, `isUploaded:true`.

### A4.5 Verbs

Mutating verbs (`create write delete rename mkdir rmdir symlink revert`) are refused
with `read_only` on a read-only domain **by the daemon** (not trusting the client's
capabilities) and are **serialized** under one per-domain mutex (A7).

| Verb | Request fields | Reply (besides `ok`) | Used by |
|---|---|---|---|
| `stat` | `ref` \| `rel` | item row fields at **top level** | ext `item(for:)`, `existingFile` |
| `list_dir` | `ref`, `after?`, `limit?` (default 1000) | `items:[row]`, `next?`, `unnamed?` | ext directory enumerator; non-recursive delete check (`limit:1`) |
| `list_all` | `after?`, `limit?` | `items`, `next?` (`"<walk>:<line>"`), `unnamed?` | ext working-set `enumerateItems` |
| `changes_since` | `arg`=anchor, `limit?` (default 512) | `stale:true` **or** `stale:false,cursor,more,ops:[op],unnamed?` | ext working-set `enumerateChanges` |
| `cursor` | – | `cursor` | ext `currentSyncAnchor` |
| `ensure_cached` | `ref`, `dest` (absolute path) | `localPath` | ext `fetchContents` |
| `fetch_range` | `ref`, `dest`, `offset≥0`, `length>0` | `localPath`, `offset`, `length` (served; short at EOF) | ext `fetchPartialContents` |
| `download_progress` | `ref` | `active:false` \| `active:true,bytesDownloaded,totalBytes` | ext progress poller |
| `create` | `parentRef`, `name` | `item` | ext createItem (file w/o contents) |
| `write` | `parentRef`, `name`, `staging` (abs path), `await?` | `size`, `mtime`, `item` | ext create/modify with contents |
| `mkdir` | `parentRef`, `name` | `item` (existing folder if already there) | ext createItem dir |
| `symlink` | `parentRef`, `name`, `target` | `item` | ext createItem symlink |
| `rename` | `ref`, `parentRef`, `name` | `item` (destination) | ext modifyItem move |
| `delete` / `rmdir` | `ref` | – | ext deleteItem; rmdir detaches the whole subtree |
| `revert` | `ref`\|`rel`, `arg`=version | – | CLI |
| `share` | `ref`\|`rel` | `url` (expires in 7 days) | ext custom action Copy Share URL |
| `restore` | `ref`\|`rel`, `keep?` (s) | – | ext "Make Available Offline", CLI pin |
| `evict` | `ref`\|`rel` | – | ext "Make Online Only", CLI |
| `full_resync` | – | – | CLI `fileprovider reimport` |
| `status` | – | `domain,running,readOnly,paused,pendingUploads,pendingDownloads,uploading[],downloading[],pendingBytes,<traffic>,subscribers` | ext readOnly probe, CLI, menu (internally) |
| `pause` | `arg`=`"on"`\|`"off"` | – | app menu (all domains), CLI |
| `stats` | `arg`= comma set of `totals,exact,reload,frontend` | diagnostics | CLI/menu_stats |
| `menu` | – (spans domains) | `menu:{icon,tooltip,submenuPlaceholder?,rows}` | app status item poll |
| `menu_stats` | – | `rows:[row]` | app stats submenu on open |
| `changed` | `keys:[logical key]` | – | converger → frontend (not a client verb) |
| `preview` | `body` (abs path) | `data` (base64 PNG) or nothing | none today (A10) |
| `subscribe` | `domain` (required) | ack, then event lines | app SignalRelay |
| `stop` | – | – | CLI |

`uploading[]` = `{name, rel, body?, size?}` (body = staged body path); `downloading[]` =
`{name, rel, bytes, size, seconds, rate}`.

**Mutation replies carry the resulting item** (`item`); the extension fails the
operation (`internal`, "reply names no item") if absent, because completing without an
item tells the system nothing about what changed.

**Change op** (entry in `changes_since.ops`), each naming its item like a listing:

```json
{"op":"put","ref":"f:.tsync-root/a.txt","parentRef":"root","name":"a.txt","item":{...row...}}
{"op":"delete","ref":"f:.tsync-root/a.txt","parentRef":"root","name":"a.txt"}
{"op":"mkdir","ref":"d:<id>","parentRef":"root","name":"sub","item":{...}}
{"op":"rmdir","id":"<id>","ref":"d:<id>","parentRef":"root","name":"gone"}
{"op":"rename","is_dir":false,"srcRef":"f:.tsync-root/a.txt","srcParentRef":"root",
 "ref":"f:.tsync-root/b.txt","parentRef":"root","name":"b.txt","item":{...}}
{"op":"rename","is_dir":true,"id":"<id>","srcRef":"d:<id>","srcParentRef":"root",
 "ref":"d:<id>","parentRef":"root","name":"sub2","item":{...}}
```

- Non-removal ops carry `item` = the item **as it is now**, found by resolving the
  reference (the path the op spelled may have moved with its folder). If it no longer
  exists (e.g. put then deleted later in the feed), `item` is omitted.
- Directory ops name the folder by the id stored **in the journal op** (a removed or
  renamed folder's marker is gone); the dir row is synthesized from the id
  (`dir_with_id`), no mirror read.
- End-point naming uses a folder-id lookup that survives removal (`removed_folder_id`).
- An op whose ends cannot be named (folder unknown to this client) is **dropped and
  counted** in `unnamed`, never made stale; a rename is reported only if *both* ends are
  nameable.
- **Nothing is filtered by author**: this client's own ops appear (the CLI's changes must
  reach the mount; client uuid is per machine).

**Events** (subscriber stream lines):

```json
{"event":"changed","domain":"Files","id":42}
{"event":"resync","domain":"Files","id":43}
{"event":"evict","domain":"Files","id":44,"ref":"f:<id>/movie.mkv"}
{"event":"restore","domain":"Files","id":45,"ref":"f:<id>/movie.mkv"}
```

`id` is a process-wide monotonically increasing sequence (reserved for future acks). The
Swift decoder also accepts an optional `key` that the daemon no longer sends.

### A4.6 Anchors and pages

**Sync anchor** = daemon string `"<generation>|<entryKey>"`, carried by the extension
**verbatim** as UTF-8 bytes (`NSFileProviderSyncAnchor(Data(s.utf8))`).

- `generation` = contents of `<data_dir>/resync-<domain>` (decimal ms timestamp), `""`
  when never stamped. Stamped only by `full_resync`.
- `entryKey` = the last applied journal entry, `%013d-<client uuid>` (ms, zero-padded
  13 digits), `""` if none. Example: `1727630000123|1727629999000-0a1b2c3d4e5f`.
- Undecodable bytes → `""` → treated as never synced.

`changes_since(anchor)`:
1. Split at first `|` (no `|` → generation `""`). If generation ≠ current → `stale:true`.
2. If anchor entry == applied head (or both absent) → `stale:false, cursor=anchor, more:false, ops:[]`.
3. Else page `Applied_entries.since(anchor, limit)`; `None` (anchor pruned) → `stale:true`.
4. `cursor` = last entry of the page, or the input anchor if the page is empty ("holding
   at the anchor"); `more` from the page.

Answered from **applied** entries (entries kept only once this client applied them), so
an op never names an item the mirror has yet to catch up with.

**Pages** (`NSFileProviderPage`): the daemon's resume cursor as UTF-8 bytes.
- `list_dir`: cursor = last **name** served; resumes with `name > after` over a
  name-sorted list (files and folders interleaved in one byte-order). A deleted cursor
  name still resumes after it.
- `list_all`: the first page walks the whole mirror (depth-first via folder ids,
  collecting `(path, container id, entry)`), sorts by path, writes the kept walk file
  (header `{"walk":"<ms>","skipped":n}` then one JSON line per entry
  `{"path","container","kind","size"?,"mtime"?}`), and uses cursor `"<walk>:<line>"`.
  Later pages read lines `n+1…` of the kept file. If the file is missing (a resync
  empties scratch), it re-walks and resumes at the same line number; a walk-id mismatch
  only logs. Cursors not matching `digits:digits` restart from the beginning.
- The two framework sentinels `initialPageSortedByName`/`ByDate` are **valid UTF-8**
  (`"FPPageSortedByName "`…) so they are matched explicitly and mean "from start".
- Any page or anchor > 500 bytes is **refused rather than truncated**: an oversized page
  becomes `nil` (finishes the enumeration there). Names ≤ 255, ids and entry keys short.
- `next` is present iff more entries follow (the page fetches `limit+1`).
- Page size = `observer.suggestedPageSize ?? 100` (≥1); batch size likewise for changes.

Why no in-memory offsets: the extension is killed and restarted at will and pages/anchors
outlive the object that issued them; a cursor must mean the same to a fresh process.
Why line numbers for list_all rather than `<container>/<name>`: a folder id can sit at
several mirror paths, so a name cursor could jump between copies and loop.

## A5. File Provider mapping (extension)

### A5.1 Item model (`TsyncItem`)

- `itemIdentifier` = ref (root ↔ `.rootContainer`); `parentItemIdentifier` = parentRef.
  The root item's parent is itself.
- `contentType`: dir → `UTType(ext, conformingTo: .directory)` **if it is a declared
  type** (packages: `.rtfd`, `.logicx`, `.band`), else `.folder`; symlink →
  `.symbolicLink`; file → `UTType(filenameExtension:) ?? .data`.
- `documentSize`, `contentModificationDate` (nil when mtime ≤ 0).
- `contentPolicy = .downloadLazily` (download on read, pull updates eagerly once
  materialized, evictable under pressure — so a changed `contentVersion` re-fetches on
  its own).
- **Versions** (both must be non-empty; the framework drops empty version data):
  - `content = etag` if non-empty else `"<size>:<mtime as Double>"`; symlinks append
    `":<target>"` (all symlink manifests hash an empty chunk list).
  - `contentVersion = content`, `metadataVersion = content + ":" + (isUploaded ? "1" : "0")`
    (so an upload finishing refreshes metadata).
  - Directory: content = folder id (constant) → children changes arrive via the feed,
    never through the parent's version.
- **Capabilities**: read-only domain or mangled name → dir `{reading, contentEnumerating}`,
  file `{reading}`. Writable: dir `{reading, contentEnumerating, addingSubItems,
  renaming, reparenting, deleting}`; symlink `{reading, renaming, reparenting, deleting}`;
  file `{reading, writing, renaming, reparenting, deleting}`. No trashing capability.
- A name or ref containing U+FFFD (non-UTF-8 bytes decoded lossily) is made read-only:
  its reference no longer names what the daemon has, and writing it would create a
  second file and fail to delete the first.
- Rows whose `ref`/`parentRef` do not parse are dropped.

### A5.2 Domain

`NSFileProviderDomain(identifier: lowercase-dashed name, displayName: name)`,
`supportsSyncingTrash = false` (else Finder offers Move to Trash for something nothing
implements). `enumerator(for: .trashContainer)` throws `featureUnsupported`.

Info.plist: `NSExtensionFileProviderDocumentGroup = group.org.feverdreamtv.tsync`,
`SupportsEnumeration = true`, `AllowsUserControlledEviction = true`, **no**
`DownloadPipelineDepth` (deliberately default; raising it multiplies concurrent range
fetches, each costing the daemon a group read + read-ahead, which buries slow backends),
three custom actions with `TRUEPREDICATE` activation.

### A5.3 Callbacks

| Callback | Behaviour |
|---|---|
| `item(for:)` | root → synthesized root item; else `stat(ref)`. Must really ask the daemon for directories too: answering from the identifier keeps a deleted folder on disk forever. Error mapped with the identifier (so the system reconciles that exact item away). |
| `enumerator(for:)` | `.workingSet` → WorkingSetEnumerator; any other container → DirectoryEnumerator. |
| Directory `enumerateItems` | `list_dir(ref, after: page, limit)`. **No** `enumerateChanges`/`currentSyncAnchor`: a replicated extension can signal only the working set, so a directory's change enumeration is never triggered. |
| Working set `enumerateItems` | `list_all` pages (whole domain; items carry their real parent). A fresh anchor is paired with a full enumeration. |
| Working set `enumerateChanges(from:)` | `changes_since(anchor, limit)`. `stale` → finish with `.syncAnchorExpired` (system re-enumerates). Else resolve ops (A5.4), `didDeleteItems`, `didUpdate`, `finishEnumeratingChanges(upTo: cursor ?? anchor, moreComing: more)`. On error: finish **with the error**, never at the starting anchor (that would claim "up to date" and the system stops asking for the life of the domain). |
| `currentSyncAnchor` | `cursor`; on failure `nil` (an invented anchor would come back unparseable and cost a rescan). |
| `fetchContents` | `dest = temporaryDirectoryURL/UUID`; `ensure_cached(ref, dest)` — the **daemon writes the file** there (the extension gets EPERM moving files into that dir). Then re-`stat` for the item returned. A 0.5 s poller on `download_progress` drives the `Progress` (total set when known; set to 100 % at the end; not reset on inactive). On failure the destination is deleted. Cancellation → `CocoaError(.userCancelled)`. |
| `fetchPartialContents` | `stat` first; with `.strictVersioning` and a different contentVersion → `versionNoLongerAvailable`. Range = `PartialRange.aligned` (below). Empty range → `versionNoLongerAvailable` (daemon would reject length 0 as `invalid`, which the system retries forever). `fetch_range(ref, dest, offset, length)`; complete with the **served** range and no flags. |
| `createItem` | Read-only → `NSFileWriteVolumeReadOnlyError`. isDirectory = `contentType == .folder` OR (`url == nil` AND `.contents` not in fields AND type conforms to `.directory`) — a flat file named like a package is offered contents. `mayAlreadyExist` (reimport replay) on a non-directory: compose `f:<parentId>/<name>`, `stat`; if present return it without writing (else the reimport re-uploads the domain). Only `not_found` means absent; any other error propagates. Then: dir → `mkdir`; symlink → `symlink` (target required); with contents → stage + `write`; else `create`. Complete with `described(reply)` and pending fields. |
| `modifyItem` | Read-only → error. `baseVersion` is **ignored** (conflict detection by base version needs macOS 26; conflicts are settled in the daemon, which publishes the losing side as a conflicted copy — see conflicts spec). If `.contents` changed with a URL: stage + `write(parentRef: new parent, name: new name)`; if also moved (`.filename` or `.parentItemIdentifier`), then `delete(old ref)` because the file reference changed. Else if moved: `rename(ref, parentRef, name)`. Else (only unsupported fields) → answer with a fresh `stat`. |
| `deleteItem` | Read-only → error. Directory (ref parses to a folder) without `.recursive`: `list_dir(limit:1)`; non-empty → `not_empty` (daemon's rmdir always detaches the subtree). `delete`/`rmdir`; `not_found` → success (already gone). |
| Pending fields | `unsupported(fields) = fields − {contents, filename, parentItemIdentifier}` returned as still-pending on create/modify, so the system neither propagates its own idea of them to disk (that silently reverted Finder tags) nor re-offers them. |
| Custom actions | `copyShareURL` → `share(first item)` → `NSPasteboard`; `makeAvailableOffline` → `restore` each selected item; `makeOnlineOnly` → `evict` each. |

**Staging (uploads).** The system unlinks the URL it handed over once the call returns,
and the daemon's upload outlives that. The extension hard-links (fallback copy) the URL
into `<own sandbox tmp>/staging/<UUID>` (it may read but not write the group container),
sends that path as `staging`; the daemon (unsandboxed) **adopts the file where it is**
(rename into its store on the same volume, no copy/chunking pass), cancels any upload in
flight for that key, stages it, queues the put and replies with staged size/mtime and the
item. The extension removes its staging link afterwards (`defer`). The whole file is
re-uploaded on edit (the framework hands whole files), chunk dedup keeps unchanged
chunks off the wire.

**PartialRange.aligned(requested, alignment, documentSize)**:
```
size = max(0, documentSize); unit = max(1, alignment)
wantStart = max(0, req.location); start = wantStart - wantStart % unit
wantEnd = min(size, wantStart + max(0, req.length))
if start >= size or wantEnd <= start: return (min(start,size), 0)
end = wantEnd rounded UP to a multiple of unit, then min(end, size)
return (start, end - start)
```
Rounds outwards only (a missing byte is read as a hole of content); length is a multiple
of the alignment except at EOF; alignment is a runtime value, never baked in.

**readOnly flag**: asked once via a *blocking* `status` on first use and cached for the
extension's lifetime; unanswered (daemon down) → treated writable, and the daemon refuses
writes itself. The config file cannot be read from the sandbox.

### A5.4 Change batch resolution (`ChangeBatch.resolve`, pure)

Input: ordered ops. Output: unordered `updated` items and `deleted` identifiers.

```
lastMention[r] = index of the last op where r appears as ref or srcRef
for (i, op):
  if op.srcRef ≠ nil and op.srcRef ≠ op.ref and lastMention[srcRef] == i:
      deleted += srcRef                # a file rename retires its old reference
  if op.ref ≠ nil and lastMention[ref] == i:
      if op is delete/rmdir: deleted += ref
      elif op.item parses:  updated += item
      # else: dropped (no invented fields; nothing here re-asks the daemon)
```

Pinned cases: create+delete in one batch → only deleted; file rename → old ref deleted,
new updated; folder rename (same ref) → nothing deleted; rename then delete → both names
deleted; rename chain a→b→c → only c updated, a and b deleted; removal needs no item.

Every change is reported **wherever it sits** — the extension does not filter by what the
system has materialized (the system tracks that itself and asks for the rest). An earlier
"materialized set" filter dropped removals under unbrowsed folders and left folders on
disk (f779eb51, d1bea01b).

## A6. Event relay (app) and change signalling

End-to-end flow of a remote change:

1. Converger applies foreign journal ops to the mirror, then `Change_notice` batches keys
   (0.2 s flush, ≤ 512 keys/line, set semantics) and sends
   `{"action":"changed","domain":D,"keys":[...]}` to the domain's frontend sockets
   (warn once on failure).
2. Frontend `changed` handler calls hook `changed(key)` per key; the hook **debounces**:
   first key schedules one `{"event":"changed"}` publish 0.2 s later, carrying no key
   (the answer is always "re-read the working set"). Also fired by `revert` and by upload
   completion (`on_upload_done`), since upload state is part of the item version.
3. App `SignalRelay` receives it → `signalEnumerator(for: .workingSet)` **and**
   `signalErrorResolved(.serverUnreachable)` (clears a latched outage on any news).
   Signalling a specific item is ignored for replicated extensions, so only the working set.
4. fileproviderd calls working-set `enumerateChanges(anchor)` → `changes_since`.

Events are **hints on top of the journal**: nobody subscribed is not a failure for
`changed`/`resync`, and a dropped event costs promptness, not correctness.

`SignalRelay` per domain (dedicated thread): loop { subscribe; on ack → signal working set
("subscribed", catches up on anything missed, since events are not replayed); read events
until EOF }. Backoff 1 s doubling to 30 s; reset to 1 s only if the connection lived ≥ 30 s
(an ack is free and proves nothing — a crash-looping daemon would otherwise cause a
working-set enumeration every second). Never gives up (survives `make install`).

Event handling in the app: `changed`, `resync` → signal working set; `evict` →
`manager.evictItem(identifier: ref)`; `restore` → `manager.requestDownloadForItem(ref,
range: NSNotFound)`; others ignored.

Subscriber registry (daemon): topic = domain name (`""` hears all); per-subscriber queue
bounded at 256, **dropping the oldest** with an error log; `publish` returns the number
of subscribers reached. `status.subscribers` exposes the count.

**Evict / restore** (hooks, used by custom actions and CLI):
- `evict(key)`: drop the chunk store's copy (and pin) first, then publish `evict` naming
  the item's reference; zero subscribers → fails `No_subscriber` ("nothing is listening
  for '<domain>': make sure TsyncApp is running, then retry").
- `restore(key, keep?)`: `ensure_cached` into the chunk store with pin deadline (a repeat
  moves the deadline), then publish `restore`. Same `No_subscriber` failure.
- Chunk store first because a pin is the daemon's promise and holds whether or not
  anything listens. Finder's own "Download Now"/"Remove Download" act on the replica only
  and leave the pin alone.

**Reimport** (`full_resync` action, CLI `tsync fileprovider reimport`): stamp a new
generation (atomic write), rebuild the folder-id index from the mirror (it may have been
replaced wholesale by another process), publish `resync`. Every outstanding anchor is now
stale → system gets `syncAnchorExpired` → full working-set enumeration → `createItem`
calls with `.mayAlreadyExist` for everything on disk, deduplicated by the stat guard.

## A7. Concurrency, durability, failure semantics

- **Mutation serialization**: all mutating verbs of one domain run under one mutex,
  covering reference **resolution** as well as the mutation. fileproviderd sends
  modifyItem calls concurrently; resolving `parentRef` before the mirror lock let
  `mv f4 sub/` racing `mv sub sub2` put f4 into a re-created `sub` beside `sub2`, which
  was then journaled and replicated everywhere (b7fd7943). Reads are not serialized.
- **One task per connection** on the server; a slow request (large restore) never blocks
  another client. Per connection, requests are sequential.
- **Cancellation (Swift)**: each request runs on a GCD global thread doing blocking
  `recv`; `Task.cancel()` does not reach it, and that pool is small, so cancelled fetches
  waiting on a daemon with no deadline starved every later request. A `CancellableSocket`
  (NSLock-guarded) records the fd; cancel = `shutdown(SHUT_RDWR)`; `adopt` fails after
  cancel (never opens a connection nobody will shut down); closing under the lock avoids
  shutting a reused fd number. A cancelled request reports `CancellationError`, mapped to
  `CocoaError(.userCancelled)`.
- **Progress objects**: every callback returns a `Progress` whose cancellation handler
  cancels the task; the system cancels a slow fetch and expects the completion handler
  promptly.
- **Daemon down**: extension calls fail with transport errors → retried by the system;
  relay reconnects with backoff; menu shows last known state; `readOnly` treated false.
- **Store unreachable**: `unreachable` → `serverUnreachable` latches; cleared by the
  relay's `signalErrorResolved` on the next event or reconnection.
- **Durability**: the daemon's state (mirror, staged tree, applied entries, generation
  stamp) is covered by other specs. Things specific here: the generation file is written
  atomically; the kept list_all walk is best-effort (failure logs, page still served);
  staged upload bodies are adopted before `write` returns, so the system may delete its
  URL. No state lives in the extension.
- **Events** are not durable and not replayed; correctness rests on anchors + journal.
- **Async exceptions** in the frontend process are logged, not fatal (a background error
  must not end the daemon).

## A8. Domain registration, reset, purge (app)

`applicationDidFinishLaunching`: `SMAppService.mainApp.register()` (login item), then
`registerDomains()`:

1. Load `config.json` (display names). Create the status menu first (so a failure still
   shows UI).
2. `deadline = now + 10 s` shared by **every** framework call of this launch.
   `retryingWhileInvalidating` retries a call failing with `providerNotFound` ("in the
   process of being invalidated", raced by the installer opening the app during a fresh
   install) every 1 s until the deadline.
3. If `<data_dir>/fileprovider-purge` exists: list domains, remove all
   (`.removeAll`); only if **all** were removed: unregister the login item and delete the
   marker. Register nothing. Return.
4. Config unreadable → **leave domains untouched** (reconciling against no names would
   remove every domain and its local copies), start relays, return.
5. `existing = NSFileProviderManager.domains()` (failure → treat as empty, `listed=false`).
6. `stale` = all existing domains if the recorded identity scheme
   (`fileprovider-identity-scheme`, int, default 0) < current scheme **1** (identifiers
   recorded before opaque references spelled paths and cannot be translated → rebuild once;
   content goes dataless, store untouched).
7. `requested` = identifiers from `fileprovider-reset` (one display name per line,
   converted to identifiers).
8. Remove every existing domain that is not configured or is in `requested ∪ stale`.
9. Add every configured domain not surviving (with `supportsSyncingTrash=false`).
10. Record the identity scheme only if `listed` and `stale ⊆ removed` (a domain dropped
    from config that the system refuses to release must not pin every launch to a rebuild
    of all domains).
11. Clear the reset marker only if `listed` and every requested domain that existed was
    removed (a failed removal keeps the marker for the next launch).
12. Start one relay per domain returned by `domains()`.

New domains in config take effect on app restart (`Runtime.restart_service`: pkill app,
`launchctl kickstart -k` the daemon agent, `open -a` app).

**CLI side** (`tsync fileprovider …`):
- `reimport`: send `full_resync` for the domain; exit 1 if no `ok`.
- `reset`: append domain name to the reset marker, restart the app (`pkill -f
  /Applications/TsyncApp.app` + `open -a`); if the app cannot be restarted remove the
  marker and fail. (Only the app owning the extension may remove a domain.)
- `purge`: write purge marker, restart app, wait up to 60 s (120 × 0.5 s) for the marker
  to disappear. App not running → skip unregistration. Timeout → remove marker (else the
  app would purge at every future launch) and fail. Then `launchctl bootout` the daemon
  agent, delete its plist, `rm -rf` the app bundle and `data_dir`; keep `config.json`;
  remove `/usr/local/bin/tsync` if possible (root-owned: print the `sudo rm` hint; checked
  with `lstat` since the link dangles).

## A9. Menu bar (settings UI)

There is **no settings window**; configuration is `config.json` (edited by hand/CLI).
The app's only UI is an `NSStatusItem` whose content the **daemon renders** (`menu`
verb) from the same model the Linux tray uses, so platforms cannot drift:

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

- Poll every 3 s (timer tolerance 1 s), skipped while a poll is outstanding; menu not
  rebuilt while open (would dismiss it); rebuilt on close.
- Icons are asset-catalog image sets named exactly as the Linux panel names them
  (`tsync-idle|sync|paused|error-symbolic`), template images 18×18; unknown → idle.
- `openFolder` → root URL from `manager.getUserVisibleURL(for: .rootContainer)` (resolved
  once at launch); open via `startAccessingSecurityScopedResource` +
  `NSWorkspace.selectFile(nil, inFileViewerRootedAtPath:)`, fallback
  `activateFileViewerSelecting`. `reveal` → select the file in Finder (never open it);
  icon from `NSWorkspace.icon(forFile:)` using the rel's last component.
- Pause toggles **all** domains (`pause on|off`), state read back by the next poll
  (uploads only; not persisted across daemon restarts).
- Stats submenu: rows fetched with `menu_stats` on `menuNeedsUpdate`, at most once per
  1 s; failure leaves the placeholder.
- Items: `autoenablesItems=false`; indented rows drawn in secondary colour.

## A10. QuickLook previews

Daemon-side `preview` verb: `{"action":"preview","body":<abs path>}`. Accepted only if
`body` equals the staged body of an upload currently in flight (so callers cannot name
arbitrary paths). The body is named by uuid (no extension), so the daemon hard-links it
into `<cache_root>/previews/<pid>-<n><ext of the item's name>` (same filesystem; a
symlink would be resolved back to the uuid by generators), asks QuickLook Thumbnailing for
a **thumbnail representation** (not the generic icon) at 64×64 points, scale 1, with a
10 s timeout, encodes PNG, unlinks the link, replies `data: base64(png)`; no picture →
`{"ok":true}` with no `data`; not in flight → `not_found`. Runs off the event loop.

Rationale for placing it in the daemon: the menu bar app is sandboxed and a file in the
shared container is "data from other apps" to it.

**Current status**: no client sends `preview` since the tray rework (269bd342 moved the
menu rendering into the daemon and the Swift menu now uses `NSWorkspace` file-type icons).
The verb and its test remain.

## A11. Install, packaging, uninstall

Bundle:
```
TsyncApp.app/Contents
├── MacOS/TsyncApp                  app (LSUIElement: no Dock icon)
├── MacOS/tsync                     daemon + CLI (same binary)
├── libs/*.dylib                    non-system libs, install names @executable_path/../libs
├── Resources/install-agent.sh
└── PlugIns/TsyncFileProvider.appex
```

- Distributed as a notarized, stapled **component pkg** (not a dmg: a sandboxed app cannot
  install the CLI symlink; pkg also avoids Gatekeeper app translocation). Install location
  `/Applications`.
- `postinstall` (root): `ln -sf …/MacOS/tsync /usr/local/bin/tsync` (creating the dir);
  then as the console user: run `install-agent.sh` and `open -a` the app.
- `install-agent.sh` (user, never root): bootout old agent, delete a stale socket (a
  leftover makes callers think the daemon is up), write the plist
  (`ProgramArguments=[…/tsync, start]`, `RunAtLoad`, `KeepAlive={SuccessfulExit:false}`
  — the daemon exits 0 with no config, which happens on every fresh install —,
  stdout/stderr → `~/Library/Logs/tsync-daemon.log`), `enable`, `bootstrap gui/<uid>`.
- The daemon is a **plain LaunchAgent**, not `SMAppService.agent`: a correctly placed,
  sealed, Team-ID-signed bundled agent reports `.notFound` / "Operation not permitted".
  `SMAppService.mainApp` works, so the app itself is the login item.
- Signing inside-out after all injection: dylibs → daemon → appex (its effective
  entitlements) → app. Re-sign preserving the entitlements Xcode derived from the profile
  (`com.apple.application-identifier`), else the App Group breaks. Sandbox + App Group
  under Developer ID requires embedded provisioning profiles for both bundle ids.
  Hardened runtime and secure timestamp only with a real identity (ad-hoc signatures have
  no Team ID and library validation rejects the bundled dylibs).
- User must approve the extension once in System Settings → Login Items & Extensions →
  File Provider Extensions. After a deploy, the daemon's first start blocks on a TCC
  prompt "TsyncApp would like to access data from other apps" (the daemon runs from inside
  the app bundle).
- Apple silicon only; deployment target macOS 13.0.
- Uninstall = `tsync fileprovider purge` (A8).

## A12. What a reimplementation must honour from Apple's contract

1. Identifiers are persisted by the system; a returned identifier differing from the one
   given means **merge**. Keep directory identity stable across renames.
2. Replicated extensions may only signal `.workingSet`; changes for any container must be
   reported through the working set, with items carrying their real parent.
3. A new anchor pairs with a full enumeration; `syncAnchorExpired` makes the system
   re-enumerate; finishing a change enumeration at the starting anchor on error means "up
   to date forever". Never do it.
4. Pages and anchors ≤ 500 bytes; initial-page sentinels are valid UTF-8 and must be
   recognized explicitly; both must be meaningful to a freshly started process.
5. Only `NSCocoaErrorDomain`/`NSFileProviderErrorDomain` errors are accepted.
   `serverUnreachable`/`notAuthenticated` latch until `signalErrorResolved`; everything
   else is retried.
6. `itemVersion` data must be non-empty; directory versions must be stable or the system
   sees modifications on every look.
7. The root's parent is itself; any other parent makes the system invent a container.
8. `item(for:)` is the system's authority on existence: `noSuchItem` (preferably with the
   identifier) is how items leave disk.
9. Partial fetch: served range must cover the request, be aligned in start and length
   (length may be short only at EOF, checked against `documentSize`); alignment varies
   per boot.
10. The extension may not move files into the provider temp dir nor write into the group
    container, and may not read files other processes wrote there; the fetched file must
    be created at a path the system gave and handed back; the system unlinks a contents URL
    after the callback returns.
11. Domain calls can fail with `providerNotFound` while the extension registration is
    being swapped (install) — retry with a bounded deadline.
12. Only a process holding an `NSFileProviderManager` (app or extension) can register,
    signal, evict or request downloads.
13. `supportsSyncingTrash` defaults to true; set false unless trash is implemented.
14. Fields the provider cannot store must be returned as still-pending, or the system
    writes its own values to disk (Finder tags reverted) and re-offers them.
15. Every callback must complete promptly after cancellation.

## A13. Interactions

| Depends on | Through |
|---|---|
| Frontend seam (08) | `Frontend.S`: `availability`, `tree=Replicated`, `serving=Daemon{One_process, Domain_socket, start}`; CLI group `fileprovider` with verbs `reimport/reset/purge`; `served` list with per-domain engine. |
| Domain engine / IPC handler (generic) | `handler(hooks)`, `item_ref`, `key_of_ref`; `start ~on_upload_done`, `drain`, `stats_fields`. |
| File ops / checkout | `evict`, `ensure_cached ?keep`, `uploads_in_flight`, `kind`, `resolve`, `published`, `list_children`, `assemble_to`, `fetch_range`, `write_whole`, `create/mkdir/rename/delete/rmdir/symlink/revert`, download progress, `Checkout.availability`. |
| Folder ids | `lookup_id`, `lookup_id_removed`, `key_of_id`, `rebuild` (on reimport). |
| Applied entries / journal | `head`, `since(anchor, limit)`, `Entry_key` string form. |
| Upload queue | `queue_put`, `wait_uploaded`, `pending`, `pending_bytes`, `on_upload_done`. |
| Converger (launcher parent) | `changed` notices on `tsync.sock`; the frontend child asks it to rescan after recording jobs and leases uplink from it (`tsync-sync.sock`). |
| Menu model (shared with Linux tray) | `Menu.of_status_json`, `render`, `to_json`, `of_stats_json`, `stats_entries`. |
| Share | `Share.create ~expires:+7d ~rel`. |
| Runtime paths | `default_paths`, `domain_socket_path` (same path for all domains), `restart_service`. |

Main flows: **open a dataless file** (fetchPartialContents → stat → fetch_range → daemon
reads chunks → writes range into dest), **save** (modifyItem → stage → write → staged,
queued → upload → on_upload_done → changed event → working set → put op with
isUploaded=true), **remote edit** (converger applies → changed notice → debounced event
→ app signals → changes_since → didUpdate → system re-fetches if materialized),
**Make Available Offline** (custom action → restore → chunk store pin → restore event →
app requestDownload).

## A14. Invariants the tests pin down

Swift `TsyncTests` (pure + against a real daemon started from `_build`, `HOME`
redirected, local store, short `/tmp/ts-xxxx` root because of the 104-byte socket cap):
- ItemID: dir named by id; file by parent+leaf; one root identity (`root`, `d:.tsync-root`
  ↔ `.rootContainer`); only first slash splits; malformed refs rejected (not thrown);
  round trip; composing a child ref.
- Item: non-UTF-8 name → read-only; declared package type is its document type; plain
  folder is `.folder`; folder named like a flat file stays a folder.
- Protocol (real daemon): `status.readOnly`; empty domain lists nothing; created file is
  fully described; `fetch_range` served at its offset and short past EOF; composed file ref
  equals daemon's; child `parentRef` equals container ref; folder and whole-domain pages
  lie end to end; resuming after a deleted name; renamed folder keeps identity; directory
  version stable; deleted file/folder report `not_found`; failures carry a code; many
  requests in sequence on one connection.
- Cancellation: cancelling a request returns without waiting on the daemon.
- ChangeBatch: the six cases in A5.4 plus "update without item is not invented".
- DaemonError: not_found/exists/not_empty distinct; only `unreachable` latches; unexplained
  failures retried; refusals surface to the user; every mapping in an accepted domain;
  not_found carries the item.
- PartialRange: covers request; start aligned; length aligned except at EOF; rounds out;
  clamps at EOF; past-EOF empty; empty file; degenerate alignments 0/1.
- Cursor: name round trip incl. awkward names; sentinels are not names; oversized name
  refused; anchor verbatim; non-text bytes → no cursor.

OCaml snapshot `tests/scenario/ipc` (`ipc.expected`): exact JSON of stat by path, restore
with keep → `pinned`+`pinnedUntil`, evict → `online-only`; list_dir whole/paged
(`next` = name), list_all paged (`next` = `<walk>:<n>`); files and folders share one name
order; nested keys; an unnameable folder is counted (`unnamed`), not dropped; identical
content shares an etag; changes_since working/up-to-date/pruned-stale/after-reimport-stale
for put, mkdir+put, delete, rename, rmdir (carries `id`), move into a folder renamed since
(named by kept id), dir rename (same ref, `id`); create under a parent spelled as a storage
key is refused; a name containing `\n` does not end the kept walk. `tests/unit/item_ref`
mirrors the Swift ItemID cases. `tests/unit/ipc_serve`, `tests/unit/subs` cover the server
loop and subscriber registry. `tests/frontends/preview` (macOS only): image named .png →
png; text named .png → none; text named .txt → png; missing body → none.

End-to-end `tests/e2e/macos` (needs installed app; `make -C macos e2e`): stages a store
daemon over http-proxy, a domain in the real config (restored afterwards), a second client;
runs the platform-neutral E2e checks (user create reaches store, edit → new version, copy,
folder+file, delete leaves no manifest, remote create/edit/delete/folder appear, remote
folder rename keeps identity, share URLs serve, mount and store agree, cleanup) plus:
reading 4 KiB at 20 MiB of a 40 MiB dataless file issues ≥1 `fetch_range`, **zero**
`ensure_cached`, and fetched bytes < file size (observed with an IPC tap); and
`fileproviderctl check -a <mount>` reports no broken invariants.

## A15. Design choices & rationale (do not undo)

- **Daemon owns the anchor and compares it** (807e1454): the extension once read the
  resync token from a daemon-written file, which the sandbox denies; every anchor carried
  an empty token and reimport expired nothing.
- **Working set = one daemon-paged listing** (3c1c513a): the extension used to walk the
  domain itself, carrying the frontier in the page; ~26 folders overflowed 500 bytes and
  the enumeration silently ended early. Names containing `|` also broke that encoding.
- **Two enumerators** (a06abe2f): the single one reported the whole journal into every
  folder's changes.
- **Report every change** (f779eb51, d1bea01b): see A5.4.
- **An unnameable op is dropped and counted, not stale** (807e1454): stale re-lists the
  whole domain to repair one folder.
- **Mutation replies carry the item** (9cb2f9c4): no post-create listing; directories'
  refs cannot be composed.
- **Move-with-contents deletes the old ref** (2939226c): a guard comparing a value to
  itself left the old file behind and the system took it as a merge.
- **Only not_found means absent in the reimport guard** (274cc0ab).
- **Only unreachable latches** (DaemonError header): a one-second daemon restart used to
  latch the domain off.
- **Daemon assembles fetched files into the system's temp dir** (eff2c3ac): EPERM moving
  there from the extension, on local and notarized builds alike.
- **Relay backoff reset by uptime, not ack** (ee2dfe5b).
- **Launch-wide invalidation deadline; rebuild marker recorded only by stale domains**
  (9b4c3156). **Unreadable config touches nothing; purge marker deleted only on full
  success; relay signals on (re)subscribe** (f81bb083). **Reset marker survives a failed
  removal** (2cc2fd00).
- **Empty partial range → versionNoLongerAvailable** (51c9b0f6).
- **Cancelled request releases its thread** (d0e0c1d4).
- **Restore/evict act on the chunk store first** (8fe543be).
- **readOnly asked of the daemon** (061b7ab7).
- **Mutation mutex** (b7fd7943) — see A7.
- **No DownloadPipelineDepth** — Info.plist comment.
- **Connection-per-request client**: replies have no id; pooling would mean serialising;
  revisit only if connect shows in a profile.
- Rejected: `SMAppService.agent` for the daemon (doesn't work); a dmg (cannot install the
  CLI); in-memory page offsets; path identifiers; a materialized-set filter.

## A16. Open questions / inconsistencies

1. **`preview` verb has no client** since 269bd342; the Swift `DaemonClient` no longer
   calls it. Dead surface on the daemon (with a test) or planned reuse?
2. **contentVersion changes on publish**: a freshly written file reports
   `contentVersion = "size:mtime"` (etag `""`), and after upload `= h1`. The system may
   treat the materialized file as having new content and re-fetch it (from the local chunk
   cache) even though the comment says only metadataVersion should move. Unverified.
3. **`reset` leaves the daemon down**: `restart_app` does `pkill -f
   /Applications/TsyncApp.app`, which also matches the daemon binary inside the bundle;
   the daemon exits cleanly (0) and `KeepAlive{SuccessfulExit:false}` does not restart it.
   `restart_service` kickstarts the agent; `reset` does not (memory note
   fileprovider-reset-gotchas). Also a CLI invoked by its in-bundle path would kill itself.
4. After reset the domain stays empty until a GUI-session client touches it (ssh `ls` reads
   the replica without waking fileproviderd).
5. **Relay does not translate `root`** into `.rootContainer` for `evict`/`restore` events
   (the extension's `ItemID.wire` does translate the other way). Evicting/restoring the
   root by event would name an identifier the system does not know.
6. **Relays and menu clients are created only at app launch**: a domain added to config
   needs an app restart (the CLI's `restart_service` does this).
7. **No client-side timeout** on extension requests: a wedged daemon holds a callback until
   the system cancels it (cancellation is handled; see A7).
8. `DaemonRequest` still declares `path`, `src` fields and `DaemonEvent` a `key` the daemon
   never uses/sends; the OCaml comment points to `macos/TsyncFileProvider/IPC.swift`, which
   no longer exists (it is `Shared/DaemonClient.swift`).
9. `modifyItem` ignores `baseVersion`; concurrent local/remote edits rely entirely on the
   daemon's conflicted-copy logic (see conflicts spec / conflict-gaps memory note).
10. The `readOnly` probe in the extension is a **blocking** socket call on whatever thread
    first asks (possibly inside a framework callback), and a failed first probe is retried
    on every subsequent call until the daemon answers.
11. Events have an `id` "so an acknowledgement can be threaded back"; no ack exists.
12. `status` in the file_provider frontend reports `running:true` always (it answers only
    when running) — fine, but the menu's "unreachable" state must come from transport
    failure.

---


---

OCaml implementation notes for this subsystem: [../ocaml/frontends/file-provider.md](../ocaml/frontends/file-provider.md).
