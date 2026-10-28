# The Windows host (Cloud Files frontend)

Scope: how tsync presents domains on Windows through the Cloud Files API: what a Windows host may
hold, its processes, how the platform realises the core's file, process and IPC rules, the mapping
between tsync items and placeholders, how local changes are taken and the domain applied to the
sync root, the tray, and the installation.

Rules shared by every frontend are owned elsewhere and only referenced here:
- the frontend contract, item references, the item row, error codes, anchors and the request
  handler: [the frontend contract](../08-frontends.md);
- the process model, ownership, lifecycle, stop protocol and CLI: [daemon and CLI](../07-daemon-cli.md);
- the owner's local state: [local state](../data-model/local-cache.md);
- failure kinds and deadlines: [failure model](../algorithms/failure-model.md);
- trust boundaries: [security model](../algorithms/security-model.md);
- conflicts: [conflict resolution](../algorithms/conflict-resolution.md);
- the menu's content: [menu-model.md](menu-model.md).

Implementation notes: [../ocaml/frontends/cloud-files.md](../ocaml/frontends/cloud-files.md).

---

## 1. Problem

On Windows a folder lazily backed by remote storage is a **sync root** of the Cloud Files API. A
kernel filter on an NTFS volume presents **placeholders**: files and folders whose metadata is on
disk and whose content the system asks the provider for when a program reads it. The shape the
platform imposes:

- **The provider owns the folder.** The provider creates, updates, moves and deletes placeholders;
  the system stores them and hydrates them through callbacks. A file the user creates in the sync
  root is an ordinary file until the provider converts it.
- **The system tells the provider about some changes and not others.** Reads, folder enumeration,
  deletes, renames and file closes arrive as callbacks; deletes and renames are asked before they
  happen and can be refused. Creations, content edits and pin changes do not arrive: the provider
  watches the folder for them.
- **Each placeholder carries an in-sync bit** that the system clears when the file's content
  changes, and a **file identity** of the provider's choosing, at most 4 KiB, kept with the file
  for its life.
- **Callbacks run on a system thread pool**, concurrently, each with a fixed 60 s timeout that any
  progress on a pending request resets.
- **Registration needs package identity.** A sync root is registered through the storage-provider
  API, which is meant for processes with package identity.

Unlike macOS, nothing is sandboxed: callbacks reach the process that connected the sync root, so
the domain's owner is the provider and needs no other process to reach the system. And unlike
macOS, the replica is the provider's to keep converged in both directions: this file's core is the
**take** (§9), which brings a change made in the sync root into the domain, and the **apply**
(§10), which brings the domain into the sync root.

**Design goal.** The sync root converges on the owner's local tree and stays converged across
restarts, crashes, sleep and downtime, without user action. Every repair is a local walk of the
sync root against the mirror; nothing on the platform's side needs to be rebuilt.

## 2. What a Windows host holds

A Windows host presents and edits domains whose data lives elsewhere. It holds no store locally
and serves no store; its only local data is its owner's local state (mirror, chunk cache, staged
edits, logs), which is there to work offline.

- **Backends.** Every backend but `local` is accepted, in every role: object stores (`s3`, `gcs`)
  and other tsync machines (`http-proxy` backend), as main, replica, backfill or archive. The host
  fills the remote copies it configures with its own writes, as any client does
  ([replication.md](../algorithms/replication.md)). Config validation refuses `local` and the
  `http-proxy` frontend ([05 §2.1](../05-ops-config.md#21-schema-and-validation)) in a config the
  user writes: the config file, `$TSYNC_CONFIG_JSON` and the wizard's. A configuration built in
  code, as tests build theirs ([09 §5.1](../09-tests.md#51-domain-configuration-as-a-value)), is not
  refused, so the suites keep their local store doubles.
- **Store maintenance runs elsewhere.** The commands that maintain a store's data rather than the
  user's files, which [07 §5.3](../07-daemon-cli.md#53-commands) marks *not on Windows*, exit 2
  with `<command> is not run on Windows` before reading anything. Publication of the host's own
  changes, their uploads and shares are not maintenance and run as anywhere.

Consequences this file relies on: no local-filesystem store, so no memory-mapped store file and no
collection interlock exist on the host; no store server, so the only listening sockets are the
owner and supervisor sockets.

## 3. Processes and ownership

```
              Task Scheduler (logon of the user)
                         │
              tsyncd start  (the supervisor)
                 │                         ▲ status, pause, codes
                 ├─ owner, domain A ◄──────┤
                 │    hosts sync root A    │
                 └─ owner, domain B ◄──────┴── tsync-tray   (Run key at logon)
                      hosts sync root B
        callbacks ▲
     (cldflt.sys) │
          programs reading and writing the sync roots

     tsync CLI: requests to owner sockets; takes ownership itself only when no owner runs
```

| Process | Lifetime | Package identity | Role |
|---|---|---|---|
| Supervisor (`tsyncd start`) | the logon session, restarted by Task Scheduler on failure | yes | Starts one owner per domain ([07 §2.4](../07-daemon-cli.md#24-which-process-owns-which-domain)), holds the uplink governor, unregisters sync roots of domains no longer configured (§13.1). |
| Owner (`tsyncd`, one per domain) | started and restarted by the supervisor | yes | Owns the domain; registers and connects its sync root; answers every callback; takes and applies (§9, §10). |
| Tray (`tsync-tray`) | the logon session | no | Status menu (§15). A client of the owner sockets. |
| CLI (`tsync`) | one-shot | no | Requests to owners. `cloudfiles reimport\|reset\|purge` (§13.3). |

- The topology is **per-domain**, as on Linux: each owner connects exactly one sync root, and a
  callback reaches only the process that connected its root.
- Every process that registers, unregisters or connects a sync root runs the identity-bearing
  executable `tsyncd.exe` (§14.1). `tsync.exe`, the console CLI, is the same program linked for the
  console subsystem; a command that must register or unregister runs in an owner, or re-executes
  itself as `tsyncd.exe` (purge, §13.3).
- **Every rule has its owner on the owner's side.** The provider is in-process and calls the
  request handler and the file operations directly, with the same actions and codes as any client
  ([08 §3](../08-frontends.md#3-the-request-handler)); it decides nothing the handler decides.

## 4. Host layout and identifiers

### 4.1 Fixed identifiers

Part of the installed base: changing one orphans existing registrations or state.

| Thing | Value |
|---|---|
| Identity package name | `org.feverdreamtv.tsync` |
| Provider id (sync root ids) | `tsync` |
| Scheduled task | `\tsync\service` |
| Tray autostart value | `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`, value `tsync-tray` |
| Tray instance mutex | `Local\org.feverdreamtv.tsync.tray` |

### 4.2 Paths

`<local>` is the user's Local AppData known folder (`%LOCALAPPDATA%`). The config, data directory,
cache root, sockets and every other runtime path the core names are in
[07 §2.7](../07-daemon-cli.md#27-runtime-paths); these are the host's own.

| Thing | Path |
|---|---|
| Programs | `<local>\Programs\tsync\` (`tsync.exe`, `tsyncd.exe`, `tsync-tray.exe`) |
| Apply state | `<data dir>\cloudfiles-<domain>.json` (§10.1) |
| Take staging | `<cache root>\<domain>\staging\` |
| Service log | `<local>\tsync\logs\tsync.log` |
| Sync root (default) | `%USERPROFILE%\tsync\<domain>` |

- Nothing tsync keeps lives in the roaming profile: a roaming copy of the client identity or the
  sync state on a second machine would push as the first ([security-model §10.2](../algorithms/security-model.md#102-at-rest)).
- AF_UNIX socket paths are limited to 108 bytes; the rule of
  [07 §2.7](../07-daemon-cli.md#27-runtime-paths) applies.
- Records above are written by the durable replace of
  [durable-queue.md](../algorithms/durable-queue.md), as realised in §5.1.

### 4.3 Sync root identifier

```
sync_root_id(domain) = "tsync!" + <user SID, string form> + "!" + hex16(XXH3(name bytes, 0))
```

The domain's config `name` is the display name; the hash keeps every byte a domain name may hold
out of the `!`-separated id. Domain names are unique ignoring case
([05 §2.1](../05-ops-config.md#21-schema-and-validation)), so ids collide only by a 64-bit hash
collision, which config validation on a Windows host refuses, naming both domains.

## 5. Platform realisation

What the core requires of a host, as Windows provides it. Each line realises a rule owned
elsewhere; none changes it.

### 5.1 Files

- **Sharing.** Every file tsync opens, its own state and the sync root alike, is opened sharing
  read, write and delete, unless a rule below asks otherwise. A reader holding a file open MUST NOT
  block the owner's replace or removal of it.
- **Rename and delete** use POSIX semantics (the name is gone at once, open handles keep the old
  file): a replace is a rename with POSIX semantics and replace-if-exists; a delete is a
  disposition with POSIX semantics. A volume that refuses POSIX semantics is refused for the data
  directory and the cache root at owner start, with a sentence naming it.
- **Durability.** "fsync a file" is a flush of its buffers. "fsync the directory" after a rename is
  realised by renaming with write-through; NTFS journals metadata, and no directory handle is
  flushed. A durable create-if-absent links with a hard link as on POSIX.
- **No mapping of what may be removed.** A mapped file cannot be deleted on Windows. A file the
  owner may replace or delete MUST NOT be held mapped across that operation; data never modified
  in place ([01](../01-core.md)) MAY be mapped only while nothing removes it.
- **Exact names.** The data directory and cache root are case-insensitive. The mirror's rule for
  such filesystems is [01 §2.8](../01-core.md#28-mirror-escaping-local-names-for-real-paths); every
  lookup in owner state compares the name the filesystem holds.
- **Long paths.** Every path tsync passes to the system is in its extended-length form (`\\?\`),
  so no path is limited to 260 characters.
- **Free space** for the core's checks is the volume's free space available to the user.

### 5.2 Processes

- A child is a fresh execution of `tsyncd.exe` ([07 §3.1](../07-daemon-cli.md#31-tsync-start-the-supervisor)
  step 8). The supervisor places its children in a job object that ends them when the supervisor's
  last handle closes, so a supervisor that dies takes its owners with it and the next one starts
  them afresh.
- **Stop without signals.** Where [07 §3.4](../07-daemon-cli.md#34-stop) tells a child to stop, the
  supervisor sends `stop` to the child's socket; where it kills, it terminates the process. Children
  start in a process group of their own, so a console interrupt reaches only the supervisor.
- A console interrupt (Ctrl+C, Ctrl+Break, the console closing) requests the stop of the process it
  reaches.
- **Session end.** Every process without a console listens for the session ending on a hidden
  top-level window and requests its stop when told the session ends. It never delays the session:
  Windows ends it seconds later, and what was unfinished is owed on disk.
- **Screen lock** ([vault §6.2](../extensions/vault.md#62-auto-lock)) is the session's lock
  notification, received on the same window.
- The descriptor limit of [07 §3.1](../07-daemon-cli.md#31-tsync-start-the-supervisor) step 6 does not apply.
- The process-wide readiness wait has no ceiling on the number of sockets
  ([07 §3.7](../07-daemon-cli.md#37-event-loop-hosting)).

### 5.3 Local IPC

- Sockets are AF_UNIX stream sockets, framed as [01 §11](../01-core.md#11-ipc-framing).
- Directory access lists and the peer check are
  [security-model §7.1–§7.2](../algorithms/security-model.md#7-local-ipc-access-control), which
  states their Windows form.
- **Transfer paths** ([security-model §7.3](../algorithms/security-model.md#73-paths-passed-over-ipc-confused-deputy)):
  no client is less privileged than the owner. The host declares the user's profile folder as both
  roots for socket clients; the provider's own staging is in-process (§9.3).

### 5.4 Secrets and trust

The vault keystore and the TLS trust store are
[security-model §10.6](../algorithms/security-model.md#106-vault-keys-and-passphrases) and
[§9](../algorithms/security-model.md#9-tls), which state their Windows form.

## 6. Descriptor and options

Registered as `cloud_files` (CLI group `cloudfiles`): presenting, **per-domain** topology,
`Daemon`, `Replicated`; wizard on `windows`, question "show it in Explorer on this machine", asks
nothing; commands `reimport`, `reset`, `purge` ([08 §2.1](../08-frontends.md#21-frontend-descriptor)).
Compiled in only on Windows; the Windows release build MUST fail without it.

| JSON name | type | default | meaning |
|---|---|---|---|
| `syncRoot` | absolute path | `%USERPROFILE%\tsync\<domain>` | the folder presented. Validated at owner start: on a fixed NTFS volume, not inside or containing the data directory, the cache root or another domain's sync root, and not inside a sync root another provider registered. Changing it moves the registration at the next start (§13.1). |

Domain settings it reads: `readOnly` (§7.3).

**Availability** ([08 §2.1](../08-frontends.md#21-frontend-descriptor)) is the core's: what the
chunk cache holds. Bytes hydrated in the sync root are the system's copy, as the replica is on
macOS, and are not reported by `tsync ls`.

| Hook ([08 §3.2](../08-frontends.md#32-hooks)) | Behaviour |
|---|---|
| `changed(keys)` | wake the apply loop (§10.3) |
| `reannounce()` | the apply's anchor is stale at its next read |
| `on_upload_done(key)` | nothing: in sync is set by the take (§9.3) |
| `status_fields()` | `syncRoot`; `unpresented`, `untaken` and `pendingFolders` when non-zero |
| `stats_fields()` | `type:"cloud_files"`, `syncRoot`, `bytesTransferred`, `takes`, `handlerFailures` |
| `on_stop()` | request the owner's stop |

## 7. Presentation

### 7.1 Names a sync root can hold

A domain leaf ([01 §2.3](../01-core.md#23-leaf-names-and-logical-paths)) is **presentable** on
Windows iff, after decoding it as UTF-8 with replacement characters:

- it is at most 255 UTF-16 code units;
- it contains no `< > : " / \ | ? *` and no character below U+0020;
- it does not end with a space or a dot;
- its part before the first dot is not, ignoring case, one of `CON`, `PRN`, `AUX`, `NUL`,
  `COM0`–`COM9`, `LPT0`–`LPT9`, or `COM` or `LPT` followed by `¹`, `²` or `³`.

A leaf that is not valid UTF-8 is presented under its decoded name, as on macOS: its placeholder's
identity (§8.1), not its name, is what the provider sends back.

### 7.2 Names that differ only in case

Siblings whose presented names are equal under the volume's case mapping (ordinal comparison
ignoring case, as NTFS compares names) form a **case group**. One member of a group is presented:
the one the sync root already holds, else the least by bytewise order of its leaf. The others are
**unpresented**. The choice is stable: a peer adding a name that differs only in case never
replaces what the user has on disk.

### 7.3 What is not presented

- Unpresentable leaves (§7.1), the unpresented members of case groups (§7.2), and everything below
  an unpresented folder.
- **Symlinks.** A placeholder cannot be a link. A domain symlink is not presented; a link the user
  makes in the sync root is never taken (§9.1).

Every item not presented is counted in `status.unpresented`, and each is logged once per owner run
with its domain path and the reason. Its repair is a rename on another machine, or `tsync rsync`
from this one. A folder holding an unpresented item cannot be deleted or moved out of the sync
root (§9.2): the user never saw what that would remove.

**Read-only domain.** Placeholders carry the read-only attribute; deletes, renames and moves are
refused (§9.2); a file created locally is not taken and is counted in `status.untaken`.

## 8. Mapping

### 8.1 File identity

Every placeholder the provider creates carries a file identity, UTF-8, three lines:

```
t1
<ref>
<contentId>
```

- `ref` is the item's reference: `d:<folder id>` for a folder, `i:<file id>` for a file
  ([08 §2.2](../08-frontends.md#22-item-references)). Stable across renames, moves and content
  changes, so a placeholder keeps its identity whatever happens to its name.
- `contentId` is the row's `contentId` of the content the placeholder describes, empty for a folder.
  It is the `base` of the next local edit (§9.3) and the version a fetch must serve (§8.3).
- The sync root folder itself stands for `root`; it carries no identity.
- A placeholder whose identity is not of this form is **foreign**: it is never taken, never
  applied, and is counted in `status.untaken`.

### 8.2 Placeholder metadata

| Placeholder field | From the row ([08 §2.3](../08-frontends.md#23-item-row)) |
|---|---|
| name | the presented name (§7.1) |
| file size | `size`, exactly the bytes a fetch delivers |
| last write and creation time | `mtime`; the time the placeholder is made when `mtime` ≤ 0 |
| attributes | directory for a folder; read-only when `readOnly` |
| identity | §8.1 |

### 8.3 Sync root registration

| Setting | Value |
|---|---|
| id | §4.3 |
| display name | the domain name |
| path | `syncRoot` |
| hydration | progressive: the requested range first, the rest behind it. Automatic dehydration allowed: the content is the domain's |
| population | full, on demand: a folder's children are asked once, on first enumeration |
| in-sync tracking | a file's content (its last write time), and nothing else; changes the provider makes do not clear in-sync |
| hard links | none |
| pinning | allowed |
| protection | personal |
| version | the build's version |

## 9. Callbacks and the take

### 9.1 Callbacks

Callbacks run on the system's threads. Each submits its work to the owner's scheduler and blocks
only itself ([07 §3.7](../07-daemon-cli.md#37-event-loop-hosting)), completes exactly once, and
completes with the cancellation status promptly after the system cancels it.

**Own changes.** A notification callback (delete, rename, close) whose requesting process is the
owner itself is acknowledged at once without acting: the provider changed the sync root to follow
the domain, and the domain already holds that state.

| Callback | Behaviour |
|---|---|
| fetch placeholders (folder F) | `list_dir(ref of F)`, every page; transfer the presented children (§7) as placeholders, marking F populated. Then apply F once (§10.2), which takes any change that raced the listing. A failure completes with its status (§12); the system asks again at the next enumeration. |
| fetch data (file, required range, optional range) | Resolve the placeholder's `ref` and open a read handle on it ([04 §3.3](../04-checkout-cache.md#33-read-handles)). A handle whose content identity differs from the placeholder's `contentId` completes with not-in-sync and applies the parent folder: the content changed, and the placeholder is updated before anything is served. Otherwise read the required range through the handle and transfer it. Every transfer starts at a multiple of 4096 and is a multiple of 4096 long, except one that ends at end of file. The optional range MAY be transferred when it is cached. Reads are bounded by `READ_DEADLINE` ([failure-model §8.1](../algorithms/failure-model.md#81-inside-a-process)). Progress is reported to the system as bytes arrive. |
| cancel fetch data / placeholders | Cancel the request; a chunk fetch it started MAY complete for the cache. |
| file close completion | Schedule a take of the file (§9.3) after `TAKE_SETTLE`. |
| delete (before) | §9.2 |
| rename (before) | §9.2 |
| dehydrate (before) | Allowed. Dehydrating drops only the system's copy. |
| open, delete, rename and dehydrate completions; validate data | Not registered. |

### 9.2 Delete and rename

Asked before the system acts, so the domain changes first and the sync root follows; a refusal
leaves both as they were.

- **Delete a file**: `delete(ref, base: its contentId)`. `not_found` is success. `kept` (a peer
  edited the file since its placeholder was made) is success too, and the parent folder is applied,
  which brings the peer's version back.
- **Delete a folder**: the file operation `rmdir`, which removes the folder only if the domain holds
  nothing beneath it ([04 §3.4](../04-checkout-cache.md#34-operations)), unpresented items
  included; otherwise refused as not empty. `not_found` is success.
- **Rename or move within the sync root**: the target folder's identity gives `parentRef`;
  `rename(ref, parentRef, name)` with replacement as the system asked (a rename that may replace
  replaces, with `dstBase` the replaced placeholder's `contentId`; one that may not answers
  `exists` as a collision). A reply carrying `aside` is success, and both folders are applied once
  the system has renamed, which moves the file to its aside name and brings the destination back.
- **Move out of the sync root**, the volume's recycle bin included: the content of the item, and of
  every file beneath a folder, is made whole on disk first (populated and hydrated), then the item
  is deleted in the domain (`delete`, or `remove_tree` for a folder). A folder holding an
  unpresented item, or content that cannot be made whole, refuses the move. The user keeps a whole
  copy of what left the sync root; the domain's versions keep the rest.
- Read-only domain, or an `invalid` answer (a name the domain refuses, such as `.tsync-ext` at the
  root): refused.
- Mutations are accepted while paused, as for any client
  ([08 §3.5](../08-frontends.md#35-rules-the-handler-enforces)).

### 9.3 The take

A take brings one item of the sync root into the domain. It is idempotent: a take of an item the
domain already holds changes nothing, so every trigger may be repeated.

**The in-sync bit is the owed marker.** A placeholder out of sync, or a file or folder that is not a
placeholder, is a local change the domain does not hold yet. The bit is durable on the volume, so a
crash leaves nothing owed unrecorded, and no provider-side queue exists.

```
take(item):
  temporary name (01 §2.9), symlink, foreign or other reparse point → nothing (symlinks and
    foreign items counted untaken)
  parent not a placeholder → take(parent), which takes its children
  in-sync placeholder → nothing
  read-only domain → nothing; counted untaken
  folder, not a placeholder:
    mkdir(parentRef, name, aside: true); landed = the reply's aside when present, else its item
    convert to a placeholder with landed's identity, in sync and populated; renamed to landed's
      presented name when landed is the aside (a file held the name)
    take every child; then apply the folder (§10.2), which brings the domain's children of a
      folder that already existed
  file (placeholder or not):
    wait until it is settled: unchanged for TAKE_SETTLE and openable without sharing write
    u = its update sequence number; copy it into the take staging directory
    not a placeholder → write(parentRef, name, staging, aside: true)
    placeholder       → write(ref, staging, base: its contentId)
    landed = the reply's aside when present, else its item  # the item the file's bytes now are
    under a handle that denies write, if the sequence number is still u:
      store landed's identity and metadata, marked in sync
    else: store landed's identity, not in sync (the item stays owed and is taken again)
    landed is the reply's aside:
      rename the file to landed's presented name; apply the parent folder, which creates the
      placeholder of what the domain holds at the original name
```

- `aside` ([08 §3.3](../08-frontends.md#33-actions)) puts a new local item whose place the domain
  already holds at the conflicted-copy name, as a merge would, and a stale `base` does the same for
  an edit ([conflict resolution §7](../algorithms/conflict-resolution.md#7-a-local-write-against-a-stale-base)).
  Either way the local file keeps the user's bytes and becomes the copy, as a file moved aside by a
  merge does. Nothing local overwrites a peer's item, and the provider never makes a
  conflicted-copy name itself.
- A local folder created where the domain holds a folder merges into it, as two folders of one name
  do in a merge.
- The whole file is copied on every edit; chunk deduplication keeps unchanged chunks off the wire.
- **In sync means the owner holds it**, not that it is published: the content is staged durably
  when the bit is set. A file the user saves can be dehydrated at once, offline included, because
  staged content is never dropped ([08 §3.4](../08-frontends.md#34-evict-and-restore)). Publication
  is shown by the tray.
- A take that fails on a local error is retried at the next trigger; a refusal (`read_only`, a name
  the domain refuses) is counted untaken and not retried until the item changes again.

### 9.4 Triggers

- File close completion (§9.1).
- **The watch.** One recursive change watch over the sync root reports creations, writes,
  attribute changes and renames. It wakes takes (after `TAKE_SETTLE`, coalesced per item) and pin
  handling (§11). Events for temporary names are discarded ([01 §14](../01-core.md#14-directory-watch)).
  The watch is a hint: what is done is decided by reading the item, so the provider's own changes,
  which leave items in sync, wake nothing that acts.
- **The sweep.** A walk of every populated folder of the sync root takes every owed item. It runs
  at start, when the watch reports that it lost events, and every `REPLICA_SWEEP`.

## 10. The apply

### 10.1 State

The apply state file (§4.2), written by durable replace:

```json
{"anchor":"<change anchor>","pending":["d:9f3a","root"]}
```

- `anchor` is the last change anchor whose ops are applied ([08 §2.5](../08-frontends.md#25-cursors-and-anchors)),
  `""` before the first.
- `pending` lists the folders whose apply could not finish (a file in use, a take still owed). They
  are applied again every `APPLY_RETRY` and at start.
- An absent or unreadable file means `anchor` `""` and the whole sync root pending.

### 10.2 Applying a folder

```
apply(F):                              # F a folder the sync root holds, populated
  rows = list_dir(F), every page;  presented = §7 over rows and F's children on disk
  for each child c of F on disk:
    temporary name → skip
    owed (§9.3) → take(c); F stays pending
    r = c's ref
    r presented in F under name n:
      name differs → rename c to n
      contentId differs → update c's metadata and identity and dehydrate it,
                          guarded by c's sequence number; pinned → hydrate it again (§11)
      else metadata differs → update c's metadata
    else, stat(r):
      in another folder G the sync root holds, populated → move c into G under its presented name
      in a folder not populated or not held, or not_found → delete c (G's first enumeration
        brings it back)
  for each presented row with no child of F under that name → create its placeholder
  any step failing (in use, sequence number moved) → F pending; a moved sequence number
    also schedules a take
```

- Nothing that is owed is overwritten, moved or deleted: it is taken first, and the merge decides
  ([conflict resolution §4](../algorithms/conflict-resolution.md#4-enacting-a-merge)).
- Moving, deleting and dehydrating an in-sync placeholder loses nothing: its content is the domain's.
  A folder is deleted only when every item beneath it is an in-sync placeholder.
- The provider's own moves and deletes reach its callbacks and are acknowledged without acting
  (§9.1). Every change to the sync root is made off the scheduler and holding no domain lock, so a
  callback is always answerable while one is in progress.
- A folder's place in the sync root is the chain of presented names from `root`; a chain with an
  unpresented link is a folder the sync root does not hold.
- A folder the system has not populated holds no children to apply; it is populated by its first
  enumeration (§9.1).

### 10.3 Following the domain

```
loop, woken by the changed hook (debounced by APPLY_DEBOUNCE) or every APPLY_RETRY:
  page = changes_since(anchor)
  stale → pending = every populated folder; anchor = cursor
  else  → pending += the parentRef and srcParentRef of each op
  apply each pending folder; drop it from pending when its apply finishes
  store {cursor, pending}; more → again
```

- The feed is read from the stored anchor, so a restart resumes where the last run stopped;
  `pending` is stored with it, so a folder is never forgotten between two runs.
- `stale` (a new generation, `reimport`) costs a local walk of the populated folders, not a
  download: the walk compares, and changes only what differs.
- The anchor this consumer holds keeps the applied log from being pruned under it, as for any
  consumer of the feed ([08 §3.6](../08-frontends.md#36-change-feed-changes_since)).

## 11. Pins and space

The sync root's pin state is the user's control ("Always keep on this device", "Free up space").
The watch reports pin changes as attribute changes.

- **Pinned** (the item's own state, or inherited from a folder): hydrate it whole in the
  background. A placeholder the apply creates or updates under a pinned folder is hydrated too. A
  pinned file stays readable offline from the sync root itself; no core pin is taken, so its bytes
  are not kept twice.
- **Unpinned**: dehydrate every in-sync file of the item's subtree, and `evict` the item from the
  chunk cache ([08 §3.4](../08-frontends.md#34-evict-and-restore)), so "Free up space" frees tsync's
  copy too. Files out of sync are left as they are.
- A hydration that fails is retried at the next `REPLICA_SWEEP` and reported in the log.
- CLI `tsync cache --fetch` and `--evict` act on the chunk cache only, as on macOS.
- Hydrating fills the chunk cache as any read does; the cache stays bounded by `maxCache`.

## 12. Errors

What a callback completes with. The meaning of each code is
[failure-model §7.2](../algorithms/failure-model.md#72-client-error-codes).

| Code or situation | Fetch (data, placeholders) | Delete, rename |
|---|---|---|
| success; `not_found` on delete or rename | success | success |
| `not_found` on fetch | not in sync; the parent folder is applied | — |
| content identity differs from the placeholder's | not in sync; the parent folder is applied | — |
| `exists` | — | name collision |
| `not_empty`; a folder holding unpresented items | — | directory not empty |
| `read_only`, `denied` | access denied | access denied |
| `invalid` | invalid request | invalid request |
| `unreachable` | network unavailable | — |
| `paused`, `busy`, `internal`, deadline, unknown | unsuccessful | unsuccessful |
| cancelled by the system | request cancelled | request cancelled |

Every failure is also recorded as the FUSE mount records its EIO answers: a counter, a ring of
entries and a periodic report ([fuse §7](fuse.md#7-error-mapping)).

## 13. Lifecycle

### 13.1 Registration and start

After the owner's start sequence up to serving its socket ([07 §3.2](../07-daemon-cli.md#32-owner-start)),
step 9 is, in order:

1. Validate `syncRoot` (§6); a bad value fails here. Create the folder when absent.
2. Register the sync root with the settings of §8.3, or update the registration when they differ
   (another path, another version). Registration persists: an owner that stops does not unregister.
3. Connect the sync root with the callbacks of §9.1.
4. Start the watch, then the sweep, then the apply loop. The watch starts first so nothing done
   during the sweep is missed.

**A changed `syncRoot`.** The owner first connects the old folder under its registration and
sweeps it, taking every owed item; then releases it (§13.4) and registers the new folder. While an
item there cannot be taken, the old registration stays and is served, and status and the log say
the move waits on it.

The supervisor, at its start, lists the sync roots registered for this user whose id starts with
`tsync!<SID>!` and releases (§13.4) each whose domain is not configured with `cloud_files`. Owed
items there cannot be taken, since the domain is gone: they stay as plain files and are logged.

### 13.2 Stop

Un-presenting ([07 §3.4](../07-daemon-cli.md#34-stop) step 2) disconnects the sync root after the
callbacks in progress complete or are cancelled. Takes in progress finish within the grace or are
left owed: their in-sync bits say so. The apply state is stored with whatever finished. Programs
reading placeholders afterwards are told the provider is not running.

### 13.3 Commands

- **`tsync cloudfiles reimport`** sends `full_resync`: the owner stamps a new generation, the apply
  finds its anchor stale and applies every populated folder, and a sweep runs. Exit 1 unless the
  owner answered `ok`.
- **`tsync cloudfiles reset`** runs in the owner. It disconnects the sync root first, so nothing
  changes under it, then looks for owed items: any found, it reconnects and refuses, listing them
  (exit 1), since a reset must not cost a local edit. Otherwise it deletes every in-sync placeholder,
  leaves anything else, unregisters, clears the apply state, and starts again as §13.1. The sync
  root is then rebuilt from the domain as the user browses it.
- **`tsync cloudfiles purge`** (the uninstaller's step) runs as a one-shot of `tsyncd.exe`; `tsync`
  re-executes itself so when asked. It stops the service (`tsync stop`), releases (§13.4) every
  sync root of the user whose id starts with `tsync!<SID>!`, deletes the scheduled task, and removes the
  data directory and the cache root, keeping `config.json` and every sync root folder. It refuses
  first (exit 1, naming each domain) while any domain holds a change it has not committed: its
  staged content is the only copy once the user freed space on the file. Owed items do not block
  it: their bytes are in the sync root and stay there as plain files.

### 13.4 Releasing a sync root

A sync root no longer served is released, so its folder holds only files that open without a
provider: purge, a domain removed from the config, a moved `syncRoot`.

1. Disconnect it, if connected.
2. Every placeholder whose content is whole on disk (hydrated, or owed) becomes a plain file.
3. Every other placeholder is deleted: its content is the domain's, and without a provider it
   could never be opened.
4. Unregister it. The folder and the plain files stay: they are the user's.

## 14. Installation

### 14.1 Package

- One per-user installer, needing no administrator, signed with the tsync code-signing certificate.
  It installs the programs (§4.2), adds the programs folder to the user's `PATH`, and registers the
  **identity package**: a sparse package whose external location is the programs folder, declaring
  `tsyncd.exe` as its application, signed with the same certificate. Only `tsyncd.exe` runs with
  package identity; nothing is virtualised, so the CLI and the owners share one data directory.
- It creates the scheduled task (§14.2), sets the tray's autostart value, then starts the task and
  the tray.
- With no config, or no domain configured, the supervisor exits 0
  ([07 §3.1](../07-daemon-cli.md#31-tsync-start-the-supervisor)); a configuration takes effect when
  the service is next started.
- Uninstall runs `tsyncd.exe cloudfiles purge`, removes the identity package, the autostart value,
  the `PATH` entry and the programs.
- x86-64; minimum Windows 10 version 2004, the first with identity for unpackaged programs.

### 14.2 Service

The scheduled task `\tsync\service`: triggered at the user's logon, running `tsyncd.exe start` as
the user while they are logged on, no execution time limit, not stopped on battery, a new instance
not started while one runs, and restarted every `SERVICE_RESTART` on failure, up to 999 times.

- `tsyncd.exe` is linked for the windowed subsystem, so the service shows no console.
- The task's own End terminates without a drain, which the core survives
  ([durable-queue](../algorithms/durable-queue.md)). Restarting is therefore the command of
  [07 §2.7](../07-daemon-cli.md#27-runtime-paths), which stops through `tsync stop` first.
- A config error (exit 78) is restarted like any failure: Task Scheduler cannot exclude a status.
  Each start reports the error to the log and exits at once.

## 15. Tray

`tsync-tray` shows every configured domain as one notification-area icon with a menu, rendered by
the menu model ([menu-model.md](menu-model.md)), which it evaluates itself.

- **One instance**: it holds the tray mutex (§4.1); a second tray finds it held and exits 0.
- **Icon**: added at start, and added again when the taskbar is recreated (the shell broadcasts it
  when Explorer restarts). Icons are the four `tsync-*-symbolic` images, drawn for light and dark
  taskbars. The tooltip is the model's, cut to what the platform shows.
- **Refresh, stats and hold** are those of the Linux tray: refresh
  ([linux-tray §5.2](linux-tray.md#52-refresh)), stats ([§6.1](linux-tray.md#61-stats)), hold
  changes ([§6.2](linux-tray.md#62-hold-changes)), quit ([§6.4](linux-tray.md#64-quit)), with the
  same parameters. The config is read from §4.2.
- **The interface thread never waits on an owner.** Requests run on other threads; the menu opens on
  the content last installed, within `TRAY_UI_BOUND`.
- **Submenus** (stats, codes) are filled when the menu opens: they show the model's placeholder
  until the rows arrive, and the rows replace it, shown the next time that submenu is opened if it
  is already on screen. Codes rows from an earlier opening are never shown again.
- **Open folder** opens the domain's sync root in Explorer: the `syncRoot` the owner reported at the
  last poll, else the configured one. **Reveal** opens the parent folder with the item selected,
  and never opens the file.
- **Copy code** asks `totp_code` and puts the code on the clipboard as text, with the clipboard
  formats that keep it out of clipboard monitors, clipboard history and cloud clipboard. It is never
  logged and never kept. A refusal is a notification carrying the owner's sentence; nothing is
  copied.
- **Unlock** opens a dialog naming the domain with a password field, and a second for the secret
  key when status says this machine is not enrolled; each has a Show box
  ([security-model §10.6](../algorithms/security-model.md#106-vault-keys-and-passphrases)). It then
  behaves as the macOS dialog does ([file-provider §10.1](file-provider.md#101-one-time-codes)).
  No code is added from the tray: that is `tsync totp add`.
- Notifications are the notification-area balloon of the tray's icon.
- Quitting the tray stops no owner.

## 16. Parameters

| Parameter | Recommended | Constraint |
|---|---|---|
| `TAKE_SETTLE` | 2 s | long enough that a save through a temporary file and a rename reaches the domain once |
| `REPLICA_SWEEP` | 1 h | |
| `APPLY_DEBOUNCE` | 0.2 s | ≤ 1 s |
| `APPLY_RETRY` | 30 s | |
| `SERVICE_RESTART` | 1 min | the least Task Scheduler offers |
| `TRAY_UI_BOUND` | 100 ms | |
| transfer alignment | 4096 bytes | the platform's |
| callback timeout | 60 s | the platform's, reset by progress |

## 17. Conformance

An implementation MUST exhibit these properties; [09](../09-tests.md) says how they are checked.

**What the host holds**
- The Windows config checks of [05 §7](../05-ops-config.md#7-conformance) pass.
- Every command 07 §5.3 marks *not on Windows* exits 2 before reading anything;
  `data-integrity --verify`, `share` and `sync` run.

**Platform**
- A reader holding an owner state file open does not stop the owner replacing or deleting it.
- After a crash during a durable replace, the old file or the new one is there, whole.
- A socket connection from another user's process is refused; the socket directory's access list
  grants only the user.
- Two domain files `A.txt` and `a.txt` are both held in the mirror on NTFS, each with its content.

**Presentation and identity**
- A name with a reserved device name, a trailing dot, or a character NTFS refuses is not presented
  and is counted in `unpresented`; so is the second member of a case group; the member already on
  disk stays presented when a peer adds the other.
- A file or folder renamed or moved in the sync root keeps its identity; a peer's folder rename moves
  the placeholder and keeps hydrated files under it hydrated.
- A folder holding an unpresented item refuses deletion and moves out of the sync root.

**Reads**
- Opening a dehydrated file serves its bytes; reading 4 KiB in the middle of a large one fetches
  less than the file; every transfer is aligned except the last.
- A placeholder whose domain content changed is never served the new bytes under the old identity:
  the fetch fails not-in-sync and the placeholder is updated.

**Takes**
- A file created, a file edited, a folder created, a file deleted, renamed and moved in the sync root
  each reach a peer.
- An edit made while offline reaches the domain after a restart with no event delivered: the sweep
  finds it from its in-sync bit.
- A save through a temporary file renamed over the original reaches the domain as one content at
  the original name.
- A local file created where a peer's file of that name arrived lands as a conflicted copy, and both
  are in the sync root afterwards. An edit made on a stale base keeps both contents.
- Killing the owner during a take, then restarting, loses no local edit and duplicates none.
- A file deleted in the sync root after a peer edited it, before the apply updated its placeholder,
  comes back with the peer's version; a rename over such a file lands the source at its aside name.

**Apply**
- A peer's create, edit, delete, folder create, rename and removal appear in the sync root.
- An owed local edit is never overwritten, moved or deleted by an apply.
- After the owner is stopped for longer than `LOG_RETENTION` and restarted, the sync root converges
  from its stored anchor and pending set, without a full walk.
- `reimport` converges a sync root whose placeholders were damaged, touching nothing that matches.

**Pins**
- "Always keep on this device" on a folder hydrates its files, and files a peer adds there later.
- "Free up space" dehydrates the in-sync files and empties the chunk cache of them; an owed file
  keeps its content.

**Lifecycle**
- A domain added to the config is registered and browsable after the service restarts; a domain
  removed is unregistered and its folder left in place.
- `reset` refuses while anything is owed; otherwise the sync root is rebuilt and loses no file.
- After `purge`, a domain removed from the config, or a moved `syncRoot`, every file left in the
  old folder opens with no provider running.
- `reset` refuses an edit made while it runs, as well as one made before.
- `purge` refuses while a change is uncommitted; otherwise it leaves no registration, task or data
  directory, and keeps the config and every folder.

**Tray**
- With one owner silent, the menu opens within `TRAY_UI_BOUND` and the other domains are current
  after one status deadline.
- A copied code is on the clipboard with the exclusion formats and in no log.
- Reveal selects the file and never opens it.
- After Explorer restarts, the icon is back.

## 18. Rationale (do not undo)

- **The owner is the provider.** Nothing is sandboxed, and callbacks reach the process that
  connected the root; a second process would be a relay with nothing to relay.
- **Per-domain processes.** One sync root per process keeps the Linux supervision unchanged and a
  wedged domain from taking the others with it.
- **The in-sync bit is the owed marker.** It is durable on the volume and cleared by the system on
  any content change, so a crash between an edit and its take loses nothing and needs no queue.
- **In sync at staging, not at commit.** The owner's staged content is never dropped, so the user
  can free space right after saving, offline included; the tray shows what is unpublished.
- **The apply walks folders, the feed only names them.** A folder walk is idempotent and repairs
  whatever it finds, so a lost op, a crash or a stale anchor costs a local walk, never a re-download.
- **Identity in the placeholder, not a provider index.** It moves with the file, survives every
  rename, and a restart needs no table to rebuild.
- **`aside` from the owner.** The conflicted-copy name is the merge's; a provider-made name would be
  a second copy of that rule.
- **Own changes recognised by process, not by echo.** Intermediate states of the provider's own
  moves would otherwise reach the domain as renames.
- **A move out of the sync root makes the content whole first.** A dehydrated file moved out would
  leave the user an empty file while its content left the domain.
- **The case-group member on disk stays.** Choosing by name alone would swap the user's file for a
  peer's when the peer adds a name that differs only in case.
- **No local store.** It relies on what Windows does not give it: a collection renames the whole
  chunk space aside, which Windows refuses while any file in it is open, so one reader could
  hold collection off; the collection interlock relies on advisory locks the kernel drops with
  their holder, where Windows locks are mandatory byte ranges; a mapped store file cannot be
  deleted; a directory cannot be flushed; and the cursor wait has no directory watch. A store
  that is never collected only grows.
- **No core pin for pinned files.** The sync root holds a pinned file's bytes; a core pin would keep
  them a second time.
- Rejected: a kernel filesystem (a third-party driver, and no Explorer integration); a full MSIX
  package (its file-system virtualisation splits the CLI's data directory from the owners');
  a Windows service (session 0 has no user sync roots); placeholders for symlinks; renaming
  unpresentable names locally (the name would differ on every Windows machine and leak back as a
  rename).

---

Implementation notes for this subsystem: [../ocaml/frontends/cloud-files.md](../ocaml/frontends/cloud-files.md).
