# FUSE mount and the Linux desktop

This file specifies the `fuse` frontend, which presents a domain as a Linux FUSE mount, and what
the mount owes the Linux desktop around it: its identity in the mount table, service units and the
base package. The desktop clients themselves are [linux-desktop.md](linux-desktop.md). The generic seam (descriptor, request handler, hooks, error codes, item references)
is [the frontend contract](../08-frontends.md); where the mount runs and how it starts and stops is
[07](../07-daemon-cli.md). This file says how the mount maps kernel operations onto the file
operations ([04 §3.5](../04-checkout-cache.md)) and which POSIX semantics it guarantees.

Part I is the mount. Part II is its side of the desktop integration, which is not a frontend: it
is a set of clients of the owner's socket plus one in-process library.

Implementation notes: [../ocaml/frontends/fuse.md](../ocaml/frontends/fuse.md).

---

# Part I — the FUSE frontend

## 1. Problem

On Linux a domain is an ordinary directory tree any program can open, read, write and rename. The
kernel sends every operation to a userspace server through `/dev/fuse`. The server is path-based:
every callback names its target by a path relative to the mount root.

Three properties of this surface shape the design:

- **The kernel caches names, attributes, listings and pages**, assuming the filesystem changes only
  through its own calls. A domain shared with other machines changes behind its back.
- **The FUSE loop owns the calling thread** until the mount goes away, and runs handlers on its own
  worker threads.
- **A mount outlives the server's wishes**: a clean unmount is refused while any process holds a
  descriptor inside it, and the kernel session survives a lazy detach for as long as one does.

## 2. Descriptor and configuration

Registered as `fuse`: presenting, per-domain topology, `Daemon`, `Replicated`, no commands
([08 §2.1](../08-frontends.md)). Compiled in only when the FUSE library is available at build time;
the Linux release build MUST fail if it is absent.

The mount runs inside the domain's owner process, one process per domain
([07 §2.4](../07-daemon-cli.md)). A process serves exactly one mount.

### 2.1 Options

A domain's frontend list holds `"fuse"` or `{"type":"fuse", …}`. Options, validated by the config
parser against this spec ([05 §2.1](../05-ops-config.md)):

| JSON name | type | default | meaning |
|---|---|---|---|
| `mountPoint` | absolute path | `$HOME/tsync/<domain>` | where to mount. Normalised at validation (no trailing `/`, no `.` or `..` segments); a relative path or one starting with `~` is refused. |
| `allowOther` | bool | `false` | other local users may reach the mount, with the access `uid`, `gid`, `fileMode` and `dirMode` grant them (§4.4). Requires `user_allow_other` in `/etc/fuse.conf`, else the mount fails with that sentence. |
| `uid` | string: a user name or a decimal uid below 2³²−1 | the owner process's uid | the owner every entry reports (§4.3). A name is resolved through the system's user database; one it does not know is refused. |
| `gid` | string: a group name or a decimal gid below 2³²−1 | the owner process's gid | the group every entry reports (§4.3), resolved as `uid` is. |
| `fileMode` | string: octal permission bits, `[0-7]{3}` with an optional leading `0` | `"0644"` | the mode files report (§4.3). |
| `dirMode` | string, as `fileMode` | `"0755"` | the mode directories report (§4.3). |
| `mountSubtype` | string matching `[A-Za-z0-9._-]*` | `"sshfs"` | the mount reports fstype `fuse.<mountSubtype>`; blank means `sshfs` (§B2). |

The mount point is resolved by one rule shared with the tray, the CLI and discovery: the domain's
`fuse` entry's `mountPoint`, else `$HOME/tsync/<domain>`. `tsync start --mount P` overrides it only
when one domain is configured.

Domain settings the mount reads: `readOnly` (§4.4), `symlinks` (§4.6), members' local paths
(`statfs`, §4.5).

### 2.2 Paths

- Owner socket: `<data dir>/tsync-<domain>.sock` ([07 §2.7](../07-daemon-cli.md)).
- Scratch for writes to unlinked open files (§4.10): `<cache root>/<domain>/scratch/`.

## 3. Threads

```
owner process (one domain)
  main thread      : the FUSE loop, multi-threaded, until the session ends
  scheduler        : the owner's single scheduler (file operations, queues, poller, socket)
  FUSE workers     : the FUSE library's threads, one per in-flight kernel request
```

- **Scheduler first.** The main thread enters the FUSE loop only after the owner has finished its
  start sequence up to serving its socket ([07 §3.2](../07-daemon-cli.md)), so no kernel request
  arrives before the domain's queues exist and reconcile has run.
- **Bridging.** A callback that touches the domain submits a closure to the scheduler and blocks its
  worker until the result is back ([07 §3.7](../07-daemon-cli.md)). A slow read blocks only its own
  request. Callbacks that touch no domain state (`statfs`, `chmod`, `chown`, `utimens`, `flush`)
  answer on the worker.
- **Interrupts.** When the kernel interrupts a pending request (the calling process got a signal, or
  is being frozen), the mount MUST answer it with EINTR promptly; the work the request started (a
  chunk fetch) MAY continue for the cache.
- FUSE counters (`openHandles`, `filesOpened`, bytes read and written) are touched only on the
  scheduler.

## 4. Operation mapping

### 4.1 Path to key

`/` is the domain root. `/<rel>` is the file key of `<rel>` for file operations and the directory key
for directory operations. Paths are forwarded verbatim: no normalisation, no case folding. A path
whose basename starts with `.fuse_hidden` is a **hidden name** (§4.10) and never a domain key.

### 4.2 Callbacks

| callback | behaviour | answers |
|---|---|---|
| `getattr` | `stat(key)` from the mirror (§4.3); a hidden name answers its retained attributes, else ENOENT | ENOENT when absent |
| `readlink` | the symlink's target | EINVAL for a non-symlink |
| `symlink` | `symlink(key, target)` | EPERM unless `symlinks = keep` (§4.6) |
| `opendir` / `readdir` / `releasedir` | a listing snapshot per open directory handle, taken at the first `readdir`: `.` and `..`, then file leaves and subdirectory names from `list_children`, each name once; served by offset; released at `releasedir` | |
| `create` | `create(key, exclusive)` then open it (content operation, visible level): an empty staged file, mtime now; mode ignored. The existence check and the creation are one step. When the key already exists as a file (a race with another creator): with `O_EXCL` EEXIST, otherwise open the existing file as `open` does | EEXIST with `O_EXCL`, or when a folder has the name |
| `mknod` | as `create` without the open | EEXIST when the key exists |
| `open` | open a read handle for the descriptor; `O_TRUNC` → `truncate(key, 0)`; nothing else is created or discarded; `O_SYNC`/`O_DSYNC` mark the handle synchronous (§4.9). Nothing is fetched | replies with direct I/O (§4.7) |
| `read` | through the descriptor's read handle ([04 §3.3](../04-checkout-cache.md#33-read-handles)); a hidden name reads its retention | short only at end of file |
| `write` | `write(key, buf, offset)`; cancels an in-flight upload of the key; lands in staged content before replying; synchronous handles make it durable first | |
| `truncate` | `truncate(key, size)` (content operation, visible level); cancels an in-flight upload | |
| `flush` | nothing: the durability point is `release` (or `fsync`) | |
| `release` | the last release after a modification: `close(key)`, which syncs the staged content and makes its WAL record durable before the reply ([04 §4.4](../04-checkout-cache.md#44-sync-and-close)) | |
| `fsync` | `sync(key)` (§4.9) | |
| `fsyncdir` | nothing: directory changes are durable when their call returns | |
| `unlink` | `delete(key)` | |
| `mkdir` | `mkdir(dir key)`; mode ignored | EEXIST when the name exists |
| `rmdir` | remove the folder **only if it is empty** (no file, folder or staged entry beneath it), as one step under the owner's metadata serialisation | ENOTEMPTY otherwise |
| `rename(src, dst, flags)` | §4.2.1 | |
| `statfs` | §4.5 | |
| `utimens`, `chmod`, `chown` | succeed and change nothing (failing them broke `rsync`, whose temp-file `fchmod` reported "mkstemp failed") | |
| `link` | unsupported | EPERM |
| xattr calls | unsupported | EOPNOTSUPP |
| `fallocate` | unsupported | EOPNOTSUPP |
| `access` | not implemented: the kernel checks permissions (§4.4) | |

File locks (`flock`, POSIX locks) are handled by the kernel and are local to this machine.

#### 4.2.1 rename

- `flags` may hold `RENAME_NOREPLACE`: an existing destination answers EEXIST and nothing changes.
  `RENAME_EXCHANGE`, `RENAME_WHITEOUT` or any other flag answers EINVAL: an atomic exchange cannot
  be published as one change.
- A destination whose basename is a hidden name is the hide of an open victim (§4.10).
- Otherwise `rename(src key, dst key)` with POSIX replacement, decided and applied as one step under
  the owner's metadata serialisation:
  - file onto file: the destination is replaced;
  - folder onto an empty folder: the destination is removed and replaced; onto a non-empty folder:
    ENOTEMPTY;
  - file onto a folder: EISDIR; folder onto a file: ENOTDIR.
- A folder keeps its folder id across the rename.

### 4.3 Attributes

`getattr` answers from the mirror only, never from a store.

| kind | mode | nlink | size | mtime | ctime, atime |
|---|---|---|---|---|---|
| directory | `S_IFDIR` `dirMode` | 2 | 0 | the time its set of children last changed on this client ([04](../04-checkout-cache.md)) | = mtime |
| staged file | `S_IFREG` `fileMode` | 1 | staged size | staged mtime | = mtime |
| published file | `S_IFREG` `fileMode` | 1 | manifest size | manifest mtime | = mtime |
| published symlink | `S_IFLNK 0777` | 1 | length of the target | manifest mtime | = mtime |
| retained (hidden) file | `S_IFREG` `fileMode` | 0 | retained size | retained mtime | = mtime |

- Every time is stable between changes: a directory's mtime moves when a child is added, removed or
  renamed on this client (locally or by an applied peer change), never on a mere look.
- uid and gid are the configured `uid` and `gid`, the owner process's by default. Modes and
  ownership are presentation only: the store keeps neither, `chmod` and `chown` change nothing, and
  every client may present the same domain with its own.
- A read-only domain clears the write bits.
- `utimens` is a no-op, so a file's mtime is its last staged write or its manifest's.

### 4.4 Read-only and multi-user access

- **Read-only domain**: the mount carries `ro`; the kernel refuses every mutation with EROFS before it
  reaches the owner. The owner's request handler refuses mutating actions itself
  ([08 §3.5](../08-frontends.md#35-rules-the-handler-enforces)).
- **Other users**: by default only the mounting user reaches the mount. `allowOther` opens it to other
  local users, always together with `default_permissions`: the kernel grants each caller what the
  ownership and modes of §4.3 grant it, supplementary groups included. With the default `uid`,
  `fileMode` and `dirMode` that is read-only, and the owner also refuses (EACCES) every mutating call
  from another uid; a configuration that grants anyone else write access leaves that decision to the
  kernel alone, as [security-model.md §8](../algorithms/security-model.md#8-fuse-multi-user-access)
  specifies. A typical shared library: `"gid": "media", "fileMode": "0664", "dirMode": "0775"`.

### 4.5 statfs

- `bsize = frsize = 4096`.
- Capacity = the least-available of the domain's writable members that have a local path, one
  `statvfs` each; read-only members and object stores do not count. `blocks = total/4096`,
  `bfree = free/4096`, `bavail = avail/4096` (`bfree` counts the root reserve, `bavail` is what this
  writer gets).
- No bounded member: total = free = avail = 2^50 bytes, so nothing that sizes a write against free
  space refuses (`df -k` reports 1099511627776 blocks).
- `files = ffree = favail =` the largest value, `fsid = 0`, `flag = 0`, `namemax = 255`.
- No cache walk, no store call: df-like tools poll it.

### 4.6 Symlinks

The domain setting `symlinks` is `keep`, `follow` or `skip`.

- Only `keep` lets the mount create symlinks; `follow` and `skip` refuse `symlink()` with EPERM,
  since neither may put a symlink object in the domain and "follow" is undefined at creation time.
- Published symlinks (from a `keep` peer) are presented as symlinks whatever the local policy.
- A symlink has no bytes to stage; its upload publishes the manifest the mirror already holds.

### 4.7 Kernel caches and invalidation

After a change to a key is applied by the owner, the next lookup of its name, the next `getattr`, the
next read and the next listing of its parent MUST reflect it. The mount achieves this with:

- mount options `entry_timeout=0`, `attr_timeout=0`, `negative_timeout=0`: every access looks up;
- **direct I/O** on every open: no page cache for file data, so a read always reaches the owner.
  The mount requests the kernel's capability to `mmap` direct-I/O files, so shared mappings work on
  kernels that offer it; on older kernels a shared writable mapping fails;
- no kernel caching of directory contents (the mount never asks for it);
- **pushed invalidation**: for each key passed to the `changed` hook, invalidate the path of the key
  and the path of its parent directory (dropping dentries, including negative ones, and cached
  attributes). Zero timeouts do not stop the kernel resolving through a dentry it already holds; an
  unpushed rename left the old name resolvable inside an open directory and made two mounts
  disagree.

Invalidation runs on the scheduler, never from inside a FUSE callback on the same path (the kernel
would wait on the request while the invalidation waits on the kernel). "Not cached" is success;
any other failure is logged at debug level and dropped.

A listing is a snapshot per open directory handle (§4.2); a new `opendir` sees the mirror as it is
then.

### 4.8 Reads

- A kernel read request is at most the kernel's maximum read size, so a sequential stream reaches
  the owner as many small reads; read-ahead is the core's
  ([read-path-and-cache.md](../algorithms/read-path-and-cache.md)), with **one read-ahead state per
  open handle**, so readers of different regions of one file do not disturb each other.
- An uncached chunk is fetched inside the read. The read is bounded by `READ_DEADLINE`
  ([failure-model.md §8.1](../algorithms/failure-model.md#81-inside-a-process)); past it, or when the store is
  unreachable, the read answers EIO. A read waiting on the network without a bound blocks cgroup
  freezing and hangs suspend.

### 4.9 Durability

The mount's durability points follow POSIX; the levels are [04 §3.4](../04-checkout-cache.md#34-operations)'s
and each durable point is a P2 acknowledgement ([durable-queue.md](../algorithms/durable-queue.md)):

- `write`, `truncate`, `create` and `mknod` are content operations at the **visible** level: their
  effect is seen by every later call, and is durable only at the next `fsync`, synchronous write or
  close.
- `fsync` / `fdatasync` on a file: `sync(key)`: every staged byte of the key and its staged manifest
  are durable before the reply. Publishing is not implied.
- A handle opened with `O_SYNC` or `O_DSYNC`: every `write` through it is followed by `sync(key)` before its reply.
- `release` after a modification: `close(key)`, whose WAL record is durable before the reply.
- `mkdir`, `rmdir`, `unlink`, `rename` and `symlink` are durable before their reply.
- A crash of the owner loses nothing already made durable; a power loss may lose writes that were
  never flushed, as on any local filesystem.

### 4.10 Open files that are unlinked or replaced

When a file held open by a process is unlinked or replaced through the mount (unlink, or a rename
onto it), every descriptor open on it MUST keep reading the content the file had at that moment,
until its last close. POSIX gives this for inodes; the mount gives it for keys:

- The FUSE library hides such a victim by renaming it to a free hidden name `.fuse_hidden<hex>` (it
  probes candidate names with `getattr` until one answers ENOENT), and unlinks the hidden name at the
  last close.
- On that rename the mount asks the file operations to **retain** the victim's current content,
  published or staged, as it is at that instant ([04 §3.3](../04-checkout-cache.md#33-read-handles)), binds the retention
  to the hidden name, and then deletes the victim key in the domain (published as an ordinary
  delete).
- `getattr`, `read` and `truncate` on the hidden name act on the retention. The first `write` to it
  copies the retained content into a scratch file private to the process and writes there. Nothing
  under a hidden name is ever published.
- Unlinking the hidden name releases the retention and removes any scratch copy.
- Retentions and scratch copies are process-local and are discarded when the owner restarts (no
  descriptor survives it). Scratch copies count against no cache cap and are removed at start.
- Every open descriptor is a read handle of the file operations, one version per descriptor
  (close-to-open consistency, [04 §3.3](../04-checkout-cache.md#33-read-handles)): a peer's version
  applied while a file is open is seen by opens after it; the open descriptor keeps reading the
  version it had. A local write through any descriptor is seen by every descriptor of the file. A
  local edit meeting a peer's change is resolved by the conflict rules
  ([conflict-resolution.md](../algorithms/conflict-resolution.md)).

## 5. Hooks

| hook ([08 §3.2](../08-frontends.md)) | behaviour |
|---|---|
| `changed(keys)` | kernel invalidation (§4.7), asynchronous |
| `reannounce`, `on_upload_done` | nothing |
| `status_fields()` | `mount: <mount point>` |
| `stats_fields()` | `type:"fuse"`, `mount`, `openHandles`, `bytesRead`, `bytesWritten` |
| `on_stop()` | request the owner's stop |

`openHandles` counts successful opens minus releases, never below 0 (a release without a matching
open arrives across a remount). Byte counters exist because a read served from the cache never
reaches a store, so store metrics stay at zero while a mount streams gigabytes. The socket publishes
no events; the tray polls.

## 6. Lifecycle

### 6.1 Start

After the owner's start sequence up to serving its socket ([07 §3.2](../07-daemon-cli.md)):

1. Validate options; a bad option fails here, before anything is mounted.
2. If the mount table shows a mount at the mount point whose source is `tsync`, it is stale (this
   process holds the ownership lock): detach it lazily. If another filesystem is mounted there,
   fail with a sentence naming it. Create the mount point with its parents.
3. Enter the FUSE loop on the main thread with the options
   `fsname=tsync,subtype=<subtype>,default_permissions[,ro][,allow_other],entry_timeout=0,attr_timeout=0,negative_timeout=0`,
   multi-threaded, in the foreground. SIGTERM and SIGINT stay with the owner's stop handling (the
   FUSE library installs handlers only for signals still at their default disposition, so the owner
   installs its own before entering the loop).

The mount table then shows fstype `fuse.<subtype>` and source `tsync`.

### 6.2 Stop

**Requested stop** (the owner's stop, [07 §3.4](../07-daemon-cli.md)): concurrently with the drain,

- **unmount**: after `UNMOUNT_DELAY` (so an IPC `stop` reply reaches its caller), unmount normally; if
  that fails because the mount is busy (one media server holding a file is enough), log at info and
  detach lazily; if that fails too, log an error that the mount point is left behind (the next
  start's step 2 clears it);
- **drain** under the grace.

The unmount runs concurrently because it is what releases the main thread from the FUSE loop. When
both are done, the owner removes its socket, flushes its output and **exits with status 0
immediately**, without waiting for the FUSE loop: a lazily detached session lives as long as a
descriptor inside it does, and waiting for the loop turned every stop with a held file into a
service-manager timeout ending in SIGABRT. After the exit the holder's descriptor fails (the kernel
answers ENOTCONN). Nothing owed is lost: the drain has run, and what it did not finish is on disk.

**External unmount** (someone ran `fusermount3 -u`, or the connection was aborted): the FUSE loop
returns on the main thread, which wakes the scheduler's stop **without waiting on it** (the scheduler
may already be gone). The owner skips the unmount, drains and exits 0; the supervisor starts it again
([07 §3.3](../07-daemon-cli.md)).

### 6.3 Timing

- The drain is bounded by `GRACE`; `UNMOUNT_DELAY` = 0.1 s.
- With a file held open inside the mount, SIGTERM ends the owner by itself (not by a signal) within
  `GRACE`.

## 7. Error mapping

The mapping from failure kinds to errno is
[failure-model.md §7.3](../algorithms/failure-model.md#73-kernel-fuse). The mount's own answers:

| situation | errno |
|---|---|
| `getattr` of an absent key or unused hidden name | ENOENT |
| `readlink` of a non-symlink; an unsupported rename flag | EINVAL |
| `symlink` with `symlinks ≠ keep`; `link` | EPERM |
| `create` with `O_EXCL`, `mknod`, `mkdir` of an existing name; `RENAME_NOREPLACE` onto one | EEXIST |
| `rmdir` of a non-empty folder; rename onto a non-empty folder | ENOTEMPTY |
| file renamed onto a folder / folder onto a file | EISDIR / ENOTDIR |
| a mutating call from another user under `allowOther`, when the configuration grants only the owner process's user write access | EACCES |
| xattr, `fallocate` | EOPNOTSUPP |
| an interrupted request | EINTR |

Everything the failure model maps to EIO (store failures, a folder this client holds no id for, a read
past its deadline, unexplained failures) is also recorded:

Recording happens on the failing worker and MUST NOT do anything that can fail (a log call that raised there once surfaced to callers as ERANGE with nothing logged):

- a process-wide counter is incremented first (exported as `handlerFailures`);
- the entry `{ticket, time, op, path, failure, trace?}` is written to a fixed ring of
  `FAILURE_RING` entries, the trace being the original failure's;
- a scheduler task wakes every `FAILURE_REPORT_INTERVAL` and logs each entry newer than the last seen,
  then `fuse: N handler failures went unreported` when the ring wrapped.

## 8. Conformance

- **POSIX semantics.** `rmdir` of a non-empty folder answers ENOTEMPTY and removes nothing; `mv -n`
  style `RENAME_NOREPLACE` onto an existing file answers EEXIST; `RENAME_EXCHANGE` answers EINVAL;
  `create` with `O_EXCL` of an existing file answers EEXIST; a process holding a file open keeps
  reading its old content after another process deletes it or renames a new file over it, and the
  domain shows the deletion or the new file; a directory's mtime is identical on two `stat`s with no
  change between them, and moves after a child is created.
- **Durability.** After `fsync` returns, killing the owner with SIGKILL and restarting it keeps the
  bytes; the upload then publishes them.
- **Freshness.** Another client's create, edit, delete, folder create and removal appear in the mount
  (lookup, attributes and a fresh listing), and a remote folder rename keeps the folder's identity.
- **Multi-user.** With `allowOther` and the default ownership and modes, another user can read but not
  write, rename or delete. With `gid` set to a group another user belongs to (as a supplementary
  group) and `fileMode` `0664`, `dirMode` `0775`, that user can create, write, rename and delete, a
  user outside the group still only reads, and `stat` reports the configured gid and modes.
- **Store path.** A create reaches the store; an edit becomes a new version; `cp` within the domain; a
  folder plus a file; a delete leaves no manifest; `rm -rf` of the mount's content empties the store
  of the domain's live manifests. The mount and the store agree, and the mount's listing equals a
  peer's.
- **No store read on a metadata path** (getattr of a missing name costs no store request).
- **Stop.** With a file held open, SIGTERM ends the owner by itself within the grace. `df -k` on a
  mount with no bounded store reports 1099511627776 blocks.
- **Options.** An absent or blank subtype is `sshfs`; `tsync` is kept; `,`, `=` and space are refused.
- **Convergence under load and crashes.** Two mounts with concurrent workers and deduplication-heavy
  content, with random SIGKILL of a client or of the store's server, after settling: both trees are
  identical; nothing is listed that cannot be read; every path's content is one that the operations
  acknowledged on it allow; every chunk a manifest names exists.
- **Share.** Sharing by reference or by path serves the exact bytes.

---

# Part II — Linux desktop integration

## B1. Mount discovery

Desktop extensions need to know whether a path is inside a tsync mount and which socket serves it.
The rule, its algorithm and the shared library that ships it are
[linux-desktop.md §3](linux-desktop.md#3-mount-discovery). What this mount owes that rule: it
reports the source `tsync` and a type starting with `fuse.` (§B2), at the mount point of §2.1.

## B2. Why the mount reports `fuse.sshfs`

KIO (and so Dolphin) generates thumbnails for every file on a mount whose type is not on its list of
network filesystems; on a tsync mount, browsing a folder downloaded every file in it. `fuse.sshfs` is
on that list, so the subtype defaults to `sshfs`. `fsname=tsync` keeps tsync's identity in the source
column, which discovery matches. `mountSubtype: "tsync"` restores `fuse.tsync` for anyone who wants
thumbnails or an honest type. Tools that special-case sshfs treat the mount as sshfs too.

## B3. Dolphin plugin

[dolphin.md](dolphin.md).

## B4. Tray

[linux-tray.md](linux-tray.md), with the menu's content in [menu-model.md](menu-model.md).

## B5. Service units

The units are specified in [07 §2.8](../07-daemon-cli.md). The user unit is installed by a source
install, which enables lingering; the system template `tsync@.service` is installed by the packages
and enabled by hand per user (`systemctl enable --now tsync@alice`). `make uninstall` removes the user
unit and the binary link and leaves lingering enabled.

## B6. Packaging

| package | contents | dependencies |
|---|---|---|
| `tsync` | the binary, `tsync@.service`, the app icon, `<libdir>/tsync/libtsync_mounts.so` | its shared libraries, plus `fuse3` (the unmount helper is executed, not linked) |

- The desktop packages `tsync-tray` and `tsync-dolphin`, why they are apart, and the checks made on
  them are [linux-desktop.md §5](linux-desktop.md#5-delivery) and
  [§6.3](linux-desktop.md#63-packages).
- Versions: `0.0.0-<YYYYMMDD>.<run>~<distro suffix>` (deb) and release `<YYYYMMDD>.<run><dist>` (rpm).
- Maintainer scripts: after install, reload systemd and, on upgrade, restart only the `tsync@*`
  instances that were active; before removal, stop active instances while the binary still exists
  (so `tsync stop` can unmount); after removal, delete the template's `.wants` links and reload.
- CI checks that the maintainer scripts name `tsync@*.service`.
- The repository is rebuilt signed from scratch; a missing signing key aborts the publish.

## B7. Conformance (desktop)

[linux-desktop.md §6](linux-desktop.md#6-conformance), [dolphin.md §7](dolphin.md#7-conformance),
[linux-tray.md §9](linux-tray.md#9-conformance), [menu-model.md §8](menu-model.md#8-conformance).

---

## Parameters

| name | value |
|---|---|
| `UNMOUNT_DELAY` | 0.1 s |
| `FAILURE_RING` | 1024 entries |
| `FAILURE_REPORT_INTERVAL` | 30 s |
| capacity with no bounded member | 2^50 bytes |
| `namemax` | 255 |
