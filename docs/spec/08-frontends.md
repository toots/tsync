# 08 — The frontend contract and the shared request handler

This file owns the frontend seam: what a frontend declares, what the owner gives it, and the one
request handler every frontend, tool and command uses to act on a domain. Everything here is common
to all frontends. Where frontends run and how processes are arranged is
[07 §2](07-daemon-cli.md). Each frontend's realisation is in its own spec:

| Frontend | Spec | OS surface |
|---|---|---|
| `fuse` | [frontends/fuse.md](frontends/fuse.md) | Linux FUSE mount, plus the Linux desktop integration (mount discovery, Dolphin plugin, tray, packaging) |
| `file_provider` | [frontends/file-provider.md](frontends/file-provider.md) | macOS File Provider: app, sandboxed extension, daemon side |
| `http-proxy` | [frontends/http-proxy.md](frontends/http-proxy.md) | HTTP(S) store server for other tsync clients, share links, status page; wire in [backends/http-proxy.md](backends/http-proxy.md) |
| `android` | [frontends/android.md](frontends/android.md) | Android app embedding the core |

Implementation notes: [ocaml/08-frontends.md](ocaml/08-frontends.md).

---

## 1. Problem

The domain core (mirror, chunk cache, staged edits, queues, journal replay) knows nothing about how
a user reaches the files. A **frontend** is one way of presenting a domain on one host. Every OS has
its own filesystem and threading model, and which frontends exist is a build-time fact. The rules
that must not differ between frontends are owned once, here and in the file-operation interface
([04 §3.5](04-checkout-cache.md)): how items are named, what staged and published mean, the error
vocabulary, paging, the change feed, and what evict and restore do. Each frontend is a thin
translation over them.

**The mirror is the whole answer for names.** No frontend path asks a store for metadata; frontends
call the file operations `kind`, `stat` and `list_children`, never inspect the mirror directly. A
getattr of a missing name costs a local lookup (≈0.3 ms), not a store round trip (≈85 ms).

---

## 2. Concepts

### 2.1 Frontend descriptor

Each frontend registers under a name; registration is compiled in or out per build. A descriptor
holds:

- **name**: `fuse`, `file_provider`, `http-proxy`, `android`. The CLI group defaults to the name
  (`file_provider` uses `fileprovider`).
- **kind**: `presenting` (shows the domain's files to a user: `fuse`, `file_provider`, `android`) or
  `store-serving` (serves the domain's stores to other machines: `http-proxy`). A presenting
  frontend runs inside the domain's owner ([07 §2.4](07-daemon-cli.md)); a store-serving frontend
  runs in the store server and owns no domain state.
- **topology** (presenting only): `per-domain` (the frontend's serving call holds a process per
  domain, as a FUSE mount does) or `shared` (one process presents all its domains). Declared here,
  enacted by the supervisor.
- **serving**: `Daemon` (the supervisor runs it) or `Commands(refusal text)` (never run by the
  supervisor; driven by an embedding app or by CLI verbs; `tsync start` refuses it with that text).
- **tree**: `Replicated` (the owner keeps the whole mirror and applies the journal) or
  `Pulled(refusal text)` (the owner reads a folder from the store when it is listed and keeps no
  replica; `tsync sync` refuses with that text and exit 2). A pulled tree's view of a folder is the
  last pull overlaid with this client's owed work, as
  [android.md §3.2](frontends/android.md#32-freshness-without-a-journal-poller) specifies; the
  lazy tree itself is [04 §3.5](04-checkout-cache.md#35-the-published-tree-full-and-lazy).
- **availability(key) → `online-only` | `cached` | `pinned(until)`**: where a file's bytes are, for
  item rows and `tsync ls`. Synchronous and local.
- **commands**: `(verb, doc, run(domain, positional args))`, exposed as `tsync <group> <verb>`.
  Each verb declares its access class ([07 §2.5](07-daemon-cli.md)). The binary resolves `--domain`
  and checks the frontend is configured for it; the frontend parses its own arguments.
- **option spec**: each option's name, label, type, default and secret flag. The config parser
  refuses keys not in the spec ([05 §2.1](05-ops-config.md)); the wizard prompts from it; secrets
  are masked in reports.

| name | kind | topology | serving | tree | commands |
|---|---|---|---|---|---|
| fuse | presenting | per-domain | Daemon | Replicated | — |
| file_provider | presenting | shared | Daemon | Replicated | reimport, reset, purge |
| http-proxy | store-serving | — | Daemon | — | — |
| android | presenting | per-domain | Commands | Pulled | stat, list, read, open, residency, fetch, write-whole, create, mkdir, delete, rmdir, rename, share, request, status |

Availability is computed by the core ([04 §3.6](04-checkout-cache.md#36-stat-and-availability));
a frontend's spec may refine it with its own replica (File Provider).

### 2.2 Item references

Non-FUSE callers name items by **reference**; the grammar (`root`, `d:<folderId>`, `i:<fileId>`,
`f:<parentFolderId>/<leaf>`) is [01 §2.7](01-core.md#27-item-references). The owner names every
file by `i:` in its replies; it accepts `f:` from a caller that composes a reference. A reference
is resolved to a key only by the request handler, under the owner's metadata serialisation, and resolution **mints nothing**: a read
that minted a folder id would persist a marker and resurrect a deleted folder. A reference that does
not resolve → `not_found`; a malformed one or a storage key → `invalid`. An `i:` or `f:` reference
never answers for a folder.

A caller holding only a path (desktop menus, the CLI) MAY send `"rel":"<domain-relative path>"`
instead; `""` is the root, and the mirror decides the kind.

Why references: renaming a directory renames every descendant's path, while its folder id is stable;
macOS treats a changed identifier as a merge instruction, so path-named folders turned a rename into
re-identification of a whole subtree. A file's store identity is its parent and leaf, so the owner
keeps a local file id for it ([local-cache §3.1](data-model/local-cache.md#31-namespace-mirror)):
a rename keeps every identifier, and a remote rename reaches a host as an update of the same item.
Neither id can be composed by a client, so every mutating reply carries the resulting item.

A host that maps references to its own identifiers MUST map `root` to its own root identifier, in
both directions, including in events it receives ([file-provider.md](frontends/file-provider.md)).

### 2.3 Item row

One shape for `stat`, listings, mutation replies and change ops, fields in this order:

```
ref, parentRef, name, kind ("dir"|"file"|"symlink"), size, mtime (float seconds), etag, isUploaded,
[contentId], [symlinkTarget], [trashed: true], [readOnly: true], [availability, [pinnedUntil]]
```

- **Directory**: size 0, mtime 0.0, etag = its folder id, isUploaded true. Constant for the
  folder's lifetime, so a watcher is not told a directory changed on every look.
- **Root**: `ref` and `parentRef` `root`, name = the domain name, etag `.tsync-root`.
- **File**: etag = the published manifest's content hash (16 hex digits), so identical content has
  an identical etag; `""` while staged edits exist. `isUploaded` false while an upload is owed.
  `availability` and `pinnedUntil` (epoch seconds) for files only.
- **`contentId`** (files and symlinks): the whole-file digest `h1` ([02](02-remote-model.md)) of the
  content the key resolves to, staged or published: equal to the etag when published, computed on
  adoption for a whole staged body, absent while staged partial edits exist. A symlink's is its
  symlink digest, which changes exactly when its target does. It is the identity a client sends back
  as `base` (§3.3).
- **`readOnly`**: present when the item cannot be written, which is when the domain is read-only.
  A client presents such an item read-only and decides writability no other way. A name that is not
  valid UTF-8 does not make an item read-only: `d:` and `i:` references carry no name, so a client
  that decodes names lossily still names the item exactly.
- A row whose containing folder has no id on this client cannot be named: it is omitted and counted
  in `unnamed`, never silently dropped. A non-zero count is reported in `status` with its repair
  (`tsync sync --full`).

`stat` puts the row at the top level; lists and mutation replies nest it (`items`, `item`).

```json
{"ok":true,"ref":"i:6c1e0b9a2f4d47e8a3b5c7d9e1f20384","parentRef":"d:9f3a","name":"big.txt","kind":"file","size":24,
 "mtime":1400000000.0,"etag":"1294bbe85c2f380b","isUploaded":true,"availability":"online-only"}
```

### 2.4 Error codes

Every failure is `{"ok":false,"code":"<code>","error":"<sentence>"}`, on every socket and through the
in-process bridge. The codes (including `busy` and `paused`), the kinds they stand for, and what a
client MUST do with each are
[failure-model.md §7.2](algorithms/failure-model.md#72-client-error-codes). A client treats a missing
or unknown code as `internal`.

### 2.5 Cursors and anchors

- **Change anchor** `"<generation>|<entry key>"`, e.g. `"1756600000000|0001756600000-abc"`.
  - `generation`: the content of the domain's resync-generation file ([07 §2.7](07-daemon-cli.md)),
    epoch milliseconds, replaced atomically and durably by `full_resync` only; `""` when never
    stamped.
  - `entry`: the last applied journal entry key, `""` for a client that never synced.
  - The core owns and compares both halves; clients carry the anchor verbatim.
- **Folder page cursor**: the last name served. A resume returns names strictly greater, compared
  bytewise. Stateless: a fresh process answers the same page, and changes before the cursor shift
  nothing.
- **Whole-domain page cursor** `"<walk>:<offset>"`: `walk` is the all-digit epoch-ms stamp of a kept
  walk, `offset` the decimal byte offset in the kept walk file of the first entry line not yet
  served. A cursor whose walk is not the kept walk (it is gone, or was remade), whose fields are not
  all digits, or whose offset is not the start of an entry line of that file (past the header line,
  at most the file's size, and just after a newline), is answered
  `{stale:true}`: the consumer restarts the listing. Positions, not names: one folder id can sit at
  several mirror paths, and a name cursor could loop; and never another walk's position, which would
  skip items. A byte offset, not a line index: the file is immutable, so the offset is as stateless
  as a line number, and a page seeks to it instead of scanning every earlier line (a line index would
  make a whole-domain listing quadratic in its size).
- **Kept walk file** (owner-local, in the domain's scratch directory): line 1
  `{"walk":"<ms>","skipped":<n>}`; then one JSON entry per line, sorted by path:
  `{"path":"a/b.txt","container":"<folderId>","kind":"file","size":N,"mtime":F}` or
  `{"path":"sub","container":"<id>","kind":"dir"}`. JSON keeps a name containing a newline on one
  line. Written atomically by a first page; never invalidated by changes (the change feed covers
  them, because the anchor is taken before page 1).

---

## 3. The request handler

### 3.1 What the owner gives a frontend

The frontend runs inside the domain's owner ([07 §2.2](07-daemon-cli.md)) and receives, per domain:

- the **file operations** ([04 §3.5](04-checkout-cache.md)), over the replicated or the lazy
  checkout as the descriptor's tree says;
- the **request handler** (§3.3) over them;
- the domain's **lifecycle** (`start`, `drain`, `stats_fields`), which the owner, not the frontend,
  drives ([07 §3.2, §3.4](07-daemon-cli.md)).

Every local change a frontend accepts is posted to the owner's one upload queue and one metadata
queue. Convergence is the owner's; the frontend learns of applied changes through its `changed`
hook, called in-process.

### 3.2 Hooks

The only frontend-specific behaviour of the handler:

```
hooks {
  changed(keys)           # the owner changed these keys behind the frontend: refresh your view
  reannounce()            # full_resync stamped a new generation: consumers must re-list
  on_upload_done(key)     # an upload of key published
  status_fields() -> fields
  stats_fields()  -> fields   # includes "frontend": <name>
  on_stop()               # a stop was requested through the socket
}
```

- `changed(keys)` is called by the owner after it applies peer journal entries (the keys they
  touched), after a `revert`, and after it publishes entries for records a one-shot command
  submitted. It MUST NOT block on the OS surface: a frontend that invalidates kernel or system
  state does so asynchronously and never from inside a callback on the same item.

| hook | fuse | file_provider | android |
|---|---|---|---|
| changed | invalidate the kernel's entries for each key | debounced `changed` event | none (the UI re-queries) |
| reannounce | none | debounced `changed` event | none |
| on_upload_done | none | publish `changed` | none |
| on_stop | request the owner's stop | request the owner's stop | none |

### 3.3 Actions

Action strings are a wire contract with the native shells and MUST NOT be renamed. **M** = mutates
the domain (refused with `read_only` on a read-only domain). **B** = bulk: bounded by progress and
watched with the liveness probe ([07 §4.3](07-daemon-cli.md#43-deadlines-bulk-actions-and-the-liveness-probe)).
**P** = refused with `paused` while paused.

| action | request | ok reply | |
|---|---|---|---|
| `stat` | `ref`\|`rel`\|(`parentRef`, `name`) | row at top level | |
| `list_dir` | `ref`\|`rel`, `after?`, `limit?` (1000) | `items`, `next?`, `unnamed?` | |
| `list_all` | `after?`, `limit?` (1000) | `items`, `next?`, `unnamed?`; or `{stale:true}` for a cursor on another walk | |
| `changes_since` | `arg` = anchor, `limit?` (512) | `{stale:true}` or `{stale:false, cursor, more, ops, unnamed?}` | |
| `cursor` | — | `cursor` (the current anchor) | |
| `ensure_cached` | `ref`\|`rel`, `dest` | `localPath`, `item`: the whole file written to `dest`, and the row of exactly those bytes | B |
| `fetch_range` | `ref`\|`rel`, `dest`, `offset` ≥ 0, `length` > 0 | `localPath, offset, length, item` (served length, short only at end of file; the row of the version served) | B |
| `download_progress` | `ref`\|`rel` | `{active:false}` or `{active:true, bytesDownloaded, totalBytes}` | |
| `create` | `parentRef`, `name`, `exclusive?` | `item`: empty, staged, etag `""` | M |
| `write` | (`parentRef`, `name`)\|`ref`, `staging`, `base?`, `exclusive?`, `await?` | `size, mtime, item`; the staging file is adopted by rename | M; B with `await` |
| `mkdir` | `parentRef`, `name`, `exclusive?` | `item`; without `exclusive`, an existing folder is answered as is | M |
| `symlink` | `parentRef`, `name`, `target`, `exclusive?` | `item` | M |
| `rename` | `ref`, `parentRef`, `name`, `noreplace?` (alias `exclusive`) | `item` at the destination; a folder keeps its id, a file its file id | M |
| `delete` | `ref`\|`rel` (a file or symlink) | `{}`; a folder target → `invalid` | M |
| `rmdir` | `ref`\|`rel` (a folder) | `{}`; removes the folder **and its subtree** (a platform delete gesture) | M |
| `revert` | `ref`\|`rel`, `arg` = version (`""` = latest) | `{}` | M, P |
| `share` | `ref`\|`rel`, `expires?` (seconds from now), `token?` | `url`, `expires` (epoch seconds) | P (it writes a store) |
| `share_revoke` | `arg`: a token or a link | `{revoked}`: whether a share of this domain held it | P |
| `share_clear_cache` | — | `{deleted, bytes}`: cached share artifacts removed, links unchanged | P |
| `evict` | `ref`\|`rel` | `{evicted, failed}` | B for a folder |
| `restore` | `ref`\|`rel`, `keep?` (seconds) | `{restored, failed}` | B for a folder |
| `full_resync` | — | `{}` after stamping a new generation and calling `reannounce` | |
| `sync` | `arg`: `"full"` or `""` | the resync result ([05 §4.7](05-ops-config.md)) | B, P |
| `trash_restore` | `path`: a trashed folder as its trash entry records it | `{outcome:"restored", announced}`, `{outcome:"not_in_trash"}` or `{outcome:"name_taken"}` | B, P |
| `job` | `job`: the owner job and its arguments; `narrate?` | streamed lines, then `{exit}`: the command's exit status ([07 §2.5](07-daemon-cli.md#25-one-shot-commands)) | B, P |
| `cancel` | `job`: the id a `job` streamed | `{cancelled}`: whether that job was running; it stops at its next unit boundary | |
| `prune` | `arg` = grace seconds | per task files and bytes | B |
| `retry` | — | `{readopted}`: every parked record of the domain's logs re-adopted now | |
| `set_aside` | `arg`: `""` lists; else a comma set of names, or `*` | `{items:[{name, kind, size, mtime}]}` or `{removed}` | |
| `poll` | — | `{}` at once; the owner rescans its logs for submitted records and runs a journal pass soon | |
| `notify_reset` | — | `{delivered: N}` after publishing a `reset` event to the domain's subscribers | |
| `ping` | — | `{}` from memory: the liveness probe | |
| `status` | — | `domain, running, readOnly, paused, pendingUploads, pendingDownloads, uploading[{name, rel, body?, size?}], downloading[{name, rel, bytes, size, seconds, rate}], pendingBytes`, traffic, hook fields | |
| `pause` | `arg`: `"off"` resumes, anything else pauses | `{paused}` after the state is durable | |
| `stats` | `arg`: comma set of `totals, exact, reload, frontend` | the owner's report ([07 §5.5](07-daemon-cli.md#55-tsync-status)); `frontend` = only this process's figures, no probes | |
| `stop` | — | `{}`, then the owner stops ([07 §3.4](07-daemon-cli.md#34-stop)) | |
| `subscribe` | `domain?` | `{}`, then the connection is an event stream (§3.8) | |

- `status` is cheap: no store access, no walk (menus poll it).
- `job` streams lines before its reply, each an object with a `stream` field: `{stream:"started",
  job}` first, then `{stream:"out", text}` for each line of the command's output,
  `{stream:"progress", text, fraction?}` as it moves (a few a second at most, the latest always sent
  before any other line; an empty `text` ends the job's progress) and, with `narrate`,
  `{stream:"narrate", text}`. A job that would conflict with a running one answers
  `busy` naming it. A client that closes its connection does not stop the job.
- `exclusive` (on `create`, `write`, `mkdir`, `symlink`) and `noreplace` (on `rename`): an existing
  destination answers `exists`, carrying the occupant's `item` when it can be named, and nothing
  changes; the check and the change are one step. A rename onto the item's own current place is a
  no-op answered with its item, `noreplace` notwithstanding.
- `stat` by `parentRef` and `name` names the child of that folder with that leaf, whichever kind it
  is.
- `write` by `ref` replaces that file's content in place; by `parentRef` and `name` it writes the
  file at that place. A `write` whose staged content has the key's current content identity
  changes nothing and queues no upload.
- `ensure_cached` and `fetch_range` resolve the item and serve its bytes in one step, so the
  reply's `item` describes exactly the bytes written; its `size` is the size of that content.
- `write` with `base` (a `contentId` the client read) declares the content the edit started from; the
  owner carries it to the published op, where it decides between a replacement and a conflicted copy
  ([conflict-resolution.md](algorithms/conflict-resolution.md)). Without `base` the edit's base is
  unknown.
- A socket serving several domains adds host actions (`menu`, `menu_stats` on macOS,
  [file-provider.md](frontends/file-provider.md)) and routes every other action by `domain`; its own
  refusals carry codes ([07 §4.2](07-daemon-cli.md#42-envelopes)), and a domain it does not serve is
  refused `unreachable`.
- `rename` replaces an existing destination file, as POSIX rename does; a destination that is a
  folder, or of another kind than the source, answers `exists`. The check and the rename are one
  step under the owner's metadata serialisation.

### 3.4 Evict and restore

Defined once, for every frontend and caller:

- **Target**: a file, a symlink (nothing to do), or a folder. A folder, including the root, means
  every file in its subtree, walked in the mirror under the owner's metadata serialisation.
- **Evict** a file: drop its cached chunk bodies and its pin ([04 §3.4](04-checkout-cache.md#34-operations)). Staged
  content is never dropped: a file with staged edits is left as is and counted as evicted (its bytes
  are not the cache's to drop).
- **Restore** a file: fetch every chunk and pin it until `now + keep` (default `DEFAULT_PIN_KEEP`,
  10 days); a later restore extends the pin; concurrent restores of one file share the fetch.
- Per-file failures are counted, logged, and do not stop the walk; the reply carries
  `{evicted|restored, failed}`. The request fails as a whole only when the target itself cannot be
  resolved (`not_found`) or every file failed for one reason the caller must see (for example
  `unreachable`).
- Evict and restore act on the chunk store only. A host whose OS keeps its own copy (the File
  Provider replica) moves that copy from its own client
  ([file-provider §6.7](frontends/file-provider.md#67-custom-actions)); a pin is the core's promise
  either way.

### 3.5 Rules the handler enforces

The handler enforces these itself, whatever a frontend advertises:

- **Read-only.** Actions marked M are refused with `read_only` on a read-only domain.
- **Pause.** Actions marked P are refused with `paused` while the domain is paused. Other mutations
  are accepted and held in the queues.
- **Serialisation.** Resolving a reference and acting on it are one step under the owner's per-domain
  metadata serialisation, for every mutation. Otherwise a folder rename racing a create inside that
  folder resolves the create against the old path and files it where the folder no longer is. Reads
  run concurrently, each on a consistent snapshot.
- **Destinations.** Mutations need `parentRef` and a non-empty `name` that is a valid leaf
  ([01](01-core.md)). A parent that resolves to nothing → `not_found`; a parent given as a storage
  key → `invalid`.
- **Transfer paths.** `dest` and `staging` are confined to the roots the host declares, and `dest` is
  created exclusively, never overwritten, as
  [security-model.md §7.3](algorithms/security-model.md#73-paths-passed-over-ipc-confused-deputy)
  specifies; a refused path answers `denied`.
- **write**, in order: cancel any upload of this key in flight (a write to a file being sent stops
  the send); adopt the staging file by rename, with its `base`; queue the put; with `await`, wait until this key's
  upload has published or started failing; report the size and mtime of what now resolves (staged or
  published).

### 3.6 Change feed: `changes_since`

Answers come from the **applied log** ([local-cache.md](data-model/local-cache.md)), never from the
store: an entry is there only once applied, so an op never names an item the mirror has not caught
up with. Ops are not filtered by author: a change made by a command on this machine must reach its
frontends.

1. Split the anchor at the first `|`. A generation different from the current one → `{stale:true}`.
2. An anchor with no entry ("before every entry") once the dropped-shard record is set →
   `{stale:true}`: entries it never saw may be gone.
3. If the anchor's entry equals the applied head, or both are absent → `{stale:false,
   cursor:anchor(gen, head), more:false, ops:[]}`.
4. Read up to `limit` entries after the anchor's entry. The anchor's entry no longer kept →
   `{stale:true}`.
5. `cursor` is the last entry returned, or the anchor itself on an empty page (a caller is never told
   to start over); `more` says whether entries remain.
6. Render each op; folder ids resolve through the folder-id index, which keeps an id after its marker
   is gone, and a file is named by the file id its applied-log op carries
   ([03 §2.7](03-journal-sync.md#27-applied-log-local)), so it is named the same after it moved or
   went:
   - `{"op":"put","ref","parentRef","name","item"}` — `item` read from the mirror through the
     reference's current resolution;
   - `{"op":"delete","ref","parentRef","name"}`;
   - `{"op":"mkdir","ref":"d:<id>","parentRef","name","item"}`;
   - `{"op":"rmdir","id","ref","parentRef","name"}`;
   - `{"op":"rename","is_dir","id"?,"srcRef","srcParentRef","ref","parentRef","name","item"}`,
     emitted only when both ends can be named (a half-reported move loses an item); `srcRef` equals
     `ref` for a folder and for a file named by its file id.
7. An op whose item or parent cannot be named is dropped and counted in `unnamed`, never turned into
   `stale`: re-listing the domain for one folder would cost every other.

**One consumer.** A domain has at most one change-feed consumer: the host whose frontend spec
reads the feed (the File Provider's working set, which the framework guarantees is enumerated by
one consumer at a time). The feed watermark below and the kept walk of §3.7 are single slots on that
assumption; a second consumer would move the watermark past the first one's anchor and remake the
walk under its pages. Nothing else calls `changes_since` or `list_all`.

**Feed watermark.** An anchor stays answerable for as long as its consumer may present it. The owner
records durably, as the domain's feed watermark, the entry of the oldest anchor a consumer may still
present: it is set by a `cursor` answer when no watermark exists, moves to the entry of the anchor
each `changes_since` names (the consumer will not present an older one), and is cleared when a new
generation is stamped. Applied-log retention keeps the shard holding the watermark's entry and every
later one ([wal-and-journal §4.8](algorithms/wal-and-journal.md#48-retention-horizon-bridging-and-rebuild)).
A watermark that has not moved for `FEED_WATERMARK_MAX_AGE` (recommended 180 days) lapses, is logged,
and holds nothing back: a consumer gone that long (an extension disabled, a domain unregistered) must
not grow the log without bound, and one that returns re-lists.

### 3.7 Listings and their order

- **Order.** Every listing is in bytewise order of names (`list_dir`) or paths (`list_all`), files and
  folders interleaved. This is the only order the handler serves. A host whose OS asks for another
  order sorts on its side or declares the enumeration unordered to the OS.
- **`list_dir`**: the folder's children filtered to names strictly after `after`; the page takes
  `limit` of them plus one, the extra one only deciding whether `next` (the last name served) is
  emitted.
- **`list_all`**: first page: walk from the root depth-first through `list_children`; a folder with no
  id counts once in `unnamed` and its subtree is skipped (it cannot be named); sort by path; stamp
  and keep the walk (a failure to keep is logged); serve the first `limit` entries. Later pages seek
  the kept file to the cursor's offset and serve `limit` entries from there; a cursor naming a walk
  other than the kept one, a missing kept file, or an offset that is not the start of an entry line
  is answered `{stale:true}`. `next` is the offset just past the last entry served, emitted only
  when one more entry exists. An entry whose path no longer resolves in the mirror is skipped (the
  feed covers its removal); every other entry is served as its current row. The walk spans many suspension points and may observe the mirror
  changing: the anchor was taken first, and the feed covers the difference.

### 3.8 Events

`subscribe` turns the connection into an event stream on the domain's topic
([01 §11](01-core.md#11-ipc-framing)). On a host whose socket routes several domains, a `subscribe`
without `domain` is answered by the router and subscribes to every domain it serves, including
domains it starts serving later; every event names its domain. A host with one listener for all its
domains needs no subscription per domain, and a client listening with none configured still learns
when the first one is served. Events are hints on top of the change feed: a lost event costs
promptness, never correctness. Every event is one JSON line `{"event":"<name>","domain":"<name>",
"id":<seq>, …}`, `id` increasing within one owner process. Which of `changed` and `reset` a host
publishes, and when, is in its frontend spec. Every owner publishes:

- **the recovery notice** `{"event":"recovered","domain":D,"id":N}`, when a store request for the
  domain succeeds after the owner answered `unreachable` for it
  ([failure-model.md §7.2](algorithms/failure-model.md#72-client-error-codes)), **and when the owner
  starts serving the domain** (a router that did not serve it answered `unreachable`, and a client
  latched on that must clear). A client MUST treat it as clearing every latch it holds for the
  domain; it is delivered to every subscriber of the domain, including one that subscribed after
  the owner started.

## 4. What the hosts ask of the seam

| | macOS File Provider | Android |
|---|---|---|
| Owner | the service process owns every domain ([07 §2.4](07-daemon-cli.md#24-which-process-owns-which-domain)) | the app process |
| Transport | one socket for all domains, routed by `domain`; adds `menu`, `menu_stats` | in-process call with the same JSON; plus a handle API for ranged reads (open → handle, size, read, close), one read-ahead state per handle |
| Hooks | `changed` events to the subscribed app (only a process holding a File Provider manager signals the system) | none but the defaults |
| Change feed | `changes_since` plus events | none: pulls ([android.md §3.2](frontends/android.md#32-freshness-without-a-journal-poller)) |
| Writes | `write` with a staging file adopted by rename | `write` with `await`; no ranged write and no close (the process may die at any time) |

Details: [file-provider.md](frontends/file-provider.md), [android.md](frontends/android.md).

---

## 5. Design rationale

1. **References, not paths**, on every non-FUSE wire (§2.2).
2. **Frontends declare topology and kind; the supervisor assigns owners.** One place decides what
   runs where.
3. **Presenting frontends live in the owner**: a local edit and a peer's change meet under one lock.
4. **No store read below the mirror** on any metadata path.
5. **The core writes materialised files** into a host-chosen directory (the sandboxed consumer may not
   move files in), and **adopts staging files by rename**, with no copy; both only inside the roots
   the host declares, or by path rules alone where only the host's own clients reach the socket, so
   a socket client cannot use the owner to reach files it could not reach itself.
10. **The owner announces that it serves a domain** (the recovery notice), so a client latched on a
    router's "not served" answer never stays latched after the domain comes back.
6. **The core owns the anchor.** Stale only after a new generation or a pruned anchor; unnameable
   ops are dropped individually.
7. **Whole-domain paging uses a kept walk with a byte-offset cursor**: client-side frontiers under a
   consumer's 500-byte cursor cap ended enumeration silently at about 26 folders.
8. **Evict and restore are defined by the core, on subtrees**, so every caller and every frontend
   means the same thing by "make available offline" on a folder.
9. **Error codes, not prose**; only `unreachable` backs a client off.

---

## 6. Conformance

- **Rows.** `stat` (by `ref` and by `rel`) and listings return the exact row shape of §2.3; a dirty file
  has an empty etag and a clean one does not; identical content shares an etag and a `contentId`; a
  whole adopted staged body has a `contentId` equal to the etag its publish yields; a directory's
  etag, size and mtime do not change when its children change.
- **Listings.** Paged and flat views agree; files and folders share one bytewise name order; a folder
  that cannot be named is counted, not dropped; a write between pages shifts no page; a cursor on a dropped or remade walk, or with an offset inside a line, answers `{stale:true}`; a page's cost does not grow with its position in the walk; a name containing a newline does not end the listing.
- **Mutations.** A create under a parent named by storage key is refused; `create`, `write`, `mkdir`
  and `symlink` with `exclusive`, and `rename` with `noreplace`, onto an existing name answer `exists`
  and change nothing; `delete` of a folder is `invalid`;
  every mutation on a read-only domain answers `read_only`; `revert` and `share` while paused answer
  `paused`.
- **Transfer paths.** `ensure_cached`, `fetch_range` and `write` with a path outside the host's
  declared roots (where it declares them), through a symlink, or (for `dest`) naming an existing file, answer `denied` and
  touch nothing.
- **Events.** A subscriber of a domain, and a router-level subscriber, receives `recovered` when the owner starts serving the domain
  and after the first successful store request following an `unreachable` answer; `notify_reset`
  reports how many subscribers received the `reset` event.
- **Engine seen by a frontend.** The owner's stats list pending and completed uploads, pending
  metadata, degraded copies, unapplied peer entries with their reason, and its maintenance schedule
  ([07 §6](07-daemon-cli.md#6-maintenance)); a finished upload puts the manifest on the store and
  publishes the cursor.
- **Change feed.** For a foreign put; mkdir then put; delete; rename; rmdir with its id; a move into a
  folder renamed since; a directory rename with its id: the ops of §3.6. An up-to-date anchor returns
  no ops and the same cursor; a pruned anchor and an anchor from another generation are stale.
- **Evict and restore.** On a folder (and on the root), every file of the subtree becomes
  `online-only` / `pinned` with `pinnedUntil`; a file with staged edits keeps them.
- **Codes.** Every failure reply on every socket carries a code from §2.4.
- **References.** Parsing and printing round-trip ([01](01-core.md)). A file keeps its `i:`
  reference across a local rename, a peer's rename, a new version and a rebuild; a feed op for a file
  that later moved or went still names it by that reference; `f:` and `i:` name the same file.
- **Feed retention.** An anchor handed out by `cursor`, and the last anchor named by
  `changes_since`, stay answerable after the horizon passes; a rebuild leaves them valid; an anchor
  with no entry is stale once a shard was dropped; a watermark idle for `FEED_WATERMARK_MAX_AGE`
  holds nothing back.
- **Replies that describe content.** `ensure_cached` and `fetch_range` reply with the row of the
  bytes written; `write` of the key's current content queues nothing; a row of a read-only domain
  carries `readOnly` and a row with a non-UTF-8 name does not; `exists` carries the occupant; a rename onto the item's own
  place answers the item.
