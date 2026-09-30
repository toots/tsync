# FUSE mount and the Linux desktop

Scope: the `fuse` frontend (`lib/app/frontends/fuse/`), and the Linux desktop integration around it: the mount-discovery rule (`lib/local/desktop_mounts/`), the Dolphin context-menu plugin (`linux/dolphin/`), the tray (`linux/tray/`), systemd units and deb/rpm packaging (`linux/*.service`, `linux/deb/`, `linux/rpm/`, `linux/repo/`).

The generic seam (descriptor, domain wiring, request handler, hooks, launcher, stop protocol, error codes, item references) is **[the frontend contract](../08-frontends.md)** and is only referenced here. This file says how the FUSE frontend maps each kernel operation onto the file operations and the request handler, which hooks it installs, and where it deviates.

Part I is the mount. Part II is the desktop integration, which is not a frontend: it consists of clients of the mount's socket plus one in-process library.

OCaml notes: [../ocaml/frontends/fuse.md](../ocaml/frontends/fuse.md).

---

# Part I — the FUSE frontend

## A1. Problem

On Linux a domain is presented as an ordinary directory tree that any program can open, read, write and rename. The kernel sends every path operation to a userspace server through `/dev/fuse`. The server here is a libfuse3 **high-level** (path-based) filesystem: every callback names its target by a path relative to the mount root, never by inode.

Three properties of the OS surface shape the design:

- **The kernel caches names, attributes and listings**, assuming the filesystem changes only through its own calls. A domain shared with other clients changes behind the kernel's back.
- **The libfuse loop owns the calling thread** until the mount goes away, and runs handlers on its own worker threads.
- **The mount outlives the server's wishes**: a clean unmount is refused while any process holds a descriptor inside it, and the kernel session survives a lazy detach for as long as such a descriptor exists.

## A2. Descriptor and configuration

Registered under the name `fuse` (CLI group `fuse`, no commands). Compiled in only when the FUSE binding is available at build time; an absent build answers "configured but not compiled into this binary" from the launcher.

| descriptor field | value |
|---|---|
| availability | chunk-store availability (contract §A2.1), no replica of its own |
| serving | `Daemon { topology: Process_per_binding, listens: DomainSocket, start }` |
| tree | `Replicated` |
| commands | none |

`start` accepts **exactly one** served binding and fails with `fuse: expected one domain per process, got N` otherwise. Serving two in one process would mount the second only after the first unmounted, under the first's log prefix.

### A2.1 Options (`frontends[]` entry in `config.json`)

A domain's frontend list may hold the bare string `"fuse"` or an object `{"type":"fuse", …}`. Option values are carried as strings (JSON bools and ints are stringified).

| JSON name | type | default | meaning |
|---|---|---|---|
| `mountPoint` | string | `""` | Directory to mount at. Blank or absent means `$HOME/tsync/<domain>`. Not tilde-expanded. |
| `allowOther` | bool | `false` | Adds `allow_other`, so other users (a media server) can reach the mount. Also requires `user_allow_other` in `/etc/fuse.conf`, or the mount fails. Accepted spellings: `true/1/yes/on`, `false/0/no/off` (case-insensitive); anything else is the default. |
| `mountSubtype` | string | `"sshfs"` | Filesystem type suffix: the mount reports `fuse.<mountSubtype>`. Blank means `sshfs`. Must match `[A-Za-z0-9._-]*`, else startup fails with `fuse: invalid mountSubtype "<v>"` (the value is spliced into libfuse's comma-separated option list). |

The mount point is resolved once, by one rule shared with the tray, the CLI and the Dolphin library (`mount_point_of`): the **first** `fuse` entry's `mountPoint` if non-empty, else `$HOME/tsync/<domain>`. `tsync start --mount P` overrides it only when exactly one domain is configured.

Domain-level settings the mount reads: `readOnly` (§A4.4), `symlinks` (§A4.6), the members' local paths (for `statfs`).

### A2.2 Socket and paths

- Domain socket: `<data dir>/tsync-<domain>.sock`, where data dir is `$XDG_DATA_HOME|~/.local/share` + `/tsync`. One per domain, because each FUSE domain is its own process.
- Scratch tree for `.fuse_hidden*` files: `<cache root>/<domain>/scratch/<domain-relative path>` (cache root `$XDG_CACHE_HOME|~/.cache` + `/tsync`).

## A3. Process shape and threading

```
tsync start (launcher parent: convergence, sync socket, change notices)
 └─ fork: fuse group
     ├─ fork: domain A   ──┐  one process per binding;
     └─ (in place) domain B┘  the last binding runs in the group process itself
         ├─ main thread     : libfuse loop (fuse_loop_mt), blocks until unmount
         ├─ scheduler thread: the single cooperative core scheduler
         │                    (file ops, upload/metadata queues, IPC server, failure reporter)
         ├─ libfuse workers : one per in-flight kernel request (libfuse-managed pool)
         └─ blocking-I/O pool: sized by the launcher (contract §A3.3)
```

- **Scheduler before loop.** The scheduler thread starts first. It starts the domain, starts the IPC server and the failure reporter, installs SIGTERM/SIGINT handlers, then signals *ready*. The main thread waits for *ready* (mutex + condition), then enters the libfuse loop. So no kernel request can arrive before the domain's queues exist.
- **Handler bridging.** Every callback that touches the domain submits a closure to the scheduler and **blocks its worker thread** until the result is back. A slow read blocks only its own kernel request; other workers keep being served. Callbacks that do not touch the domain (`statfs`, `utimens`, `chmod`, `chown`, `flush`, `fsync`) answer directly on the worker thread with no scheduler hop.
- **Serialisation.** All file-operation work runs on the one scheduler thread, so the FUSE counters (`openHandles`, `filesOpened`) are plain integers mutated only there. Concurrency between kernel requests is interleaving at the scheduler's yield points, never parallel execution.
- **Parallelism ceiling.** The number of concurrently blocked workers is libfuse's (its multi-threaded loop spawns workers on demand, capped by its `max_threads`/`max_idle_threads` defaults); tsync sets no loop configuration. `clone_fd` is taken from command-line options (not set).
- **Dead scheduler.** If the scheduler's run loop dies with an exception, the process logs `event loop stopped: <exn>` with a backtrace and exits with status 1 immediately, without running exit handlers. Otherwise every later FUSE callback would block forever on a scheduler that no longer exists (observed: 47 minutes of silence until a stop timed out).
- **Asynchronous exceptions** from background tasks on the scheduler are logged (`async exception: …`) and never end the process.

## A4. Operation mapping

**Path to key.** `/` is the domain root. Any other path `/<rel>` maps to the **file key** of `<rel>` for file operations and to the **directory key** of `<rel>` for `mkdir`, `rmdir`, `readdir`. Paths are forwarded verbatim (no normalisation, no case folding).

**Dispatch.** A path whose **basename** starts with `.fuse_hidden` goes to the *hidden* table (§A5); every other path goes to the *real* table below. `getattr`, `readlink`, `symlink`, `readdir`, `mkdir`, `rmdir` are never dispatched: they always take the real path.

### A4.1 Callback table

| callback | real behaviour | notes |
|---|---|---|
| `init` | nothing | registered so libfuse calls it; any failure is recorded |
| `getattr(path)` | `stat(key)`; absent → **ENOENT** | see §A4.3 for the synthesized fields; read-only domain clears write bits |
| `readlink(path)` | published manifest's symlink target; not a symlink or absent → **EINVAL** | |
| `symlink(target, path)` | `symlink(key, target)` | refused with **EPERM** unless `symlinks = keep` (§A4.6) |
| `readdir(path, offset)` | `list_children(dir key)` → file leaves, then subdir names, deduplicated, prefixed with `.` and `..` | offset ignored: the whole listing in one reply; no per-entry attributes (no readdirplus) |
| `mknod(path, mode)` | `create(key)`: an empty staged file, size 0, mtime now | mode ignored. Reached on file creation, since there is no `create` callback (§A4.2) |
| `open(path, flags)` | `O_TRUNC` → `truncate(key, 0)`; else `O_CREAT` and nothing **published** → `create(key)`; else nothing | always replies `direct_io`. Nothing is fetched: the first read fetches the chunks it covers |
| `read(path, buf, off)` | `read(key, buf, off)` with **no stream id** → bytes read | short only at EOF; a key the mirror no longer holds reads 0 bytes (EOF), not ENOENT |
| `write(path, buf, off)` | `write(key, buf, off)` → bytes written | cancels any in-flight upload of the key; lands in staged chunk bodies before returning |
| `release(path)` | `close(key)`: queue an upload iff staged edits exist | |
| `unlink(path)` | `delete(key)` | |
| `mkdir(path, mode)` | `mkdir(dir key)` | mode ignored |
| `rmdir(path)` | `rmdir(dir key)` | **recursive**: a non-empty directory is removed with its subtree (no ENOTEMPTY) |
| `rename(src, dst, flags)` | dst basename `.fuse_hidden*`: hidden rename (§A5), then `delete(src key)`. Otherwise `rename(src key, dst key)` | **flags ignored**, including `RENAME_NOREPLACE` and `RENAME_EXCHANGE` (§A9) |
| `truncate(path, size)` | `truncate(key, size)` | cancels any in-flight upload of the key |
| `statfs` | §A4.5 | answered on the worker thread |
| `utimens`, `chmod`, `chown` | succeed, change nothing | ENOSYS broke rsync: its `mkstemp` `fchmod`s the temp file and reported "mkstemp failed" |
| `flush`, `fsync` | succeed | nothing is buffered per descriptor; ENOSYS would surface as an error to apps that fsync |

**Counters** (all on the scheduler thread): a successful `open` increments `openHandles` and `filesOpened`; `release` decrements `openHandles` but never below 0 (a release without a matching open arrives across a remount). `read`/`write` add the returned byte count to rolling counters (`bytesRead`, `bytesWritten`, and per-second rates). These exist because a read served from the chunk cache never reaches a backend, so backend metrics stay at zero while a mount streams gigabytes.

**readdir collision.** Files and directories are two listings of one namespace. When a name is both, it is returned once and logged at warning level (`readdir <path>: "<name>" is both a file and a directory`). Returning it twice made `ls` print it twice and made map-building readers drop an entry silently; the collision itself is upstream and readdir cannot repair it.

### A4.2 Callbacks not implemented

Unregistered callbacks get libfuse's default. Consequences a reimplementation must reproduce or consciously change:

| callback | effect |
|---|---|
| `create` | kernel receives ENOSYS once, then falls back to `mknod` + `open` for every later creation. The `O_CREAT` branch of `open` is therefore defensive: the kernel strips `O_CREAT`/`O_EXCL` from open requests |
| `link` | ENOSYS: hard links are unsupported |
| `setxattr`/`getxattr`/`listxattr`/`removexattr` | ENOSYS, which the kernel reports to callers as EOPNOTSUPP and stops asking |
| `opendir`, `releasedir`, `fsyncdir` | libfuse default: succeed |
| `access`, `lock`, `flock`, `fallocate`, `lseek`, `copy_file_range`, `poll`, `ioctl`, `bmap` | not implemented (ENOSYS / kernel-local behaviour) |

No `default_permissions` option is passed, so the kernel does not check mode bits; access is gated only by the mount's owner rule (only the mounting user, unless `allow_other`).

### A4.3 Attributes

`getattr` answers from the mirror only, never from a backend (contract §A1 principle; measured at ~0.3 ms for a missing name).

| kind | mode | nlink | size | mtime | ctime | atime |
|---|---|---|---|---|---|---|
| directory (mirror entry is a directory) | `S_IFDIR 0755` | 2 | 0 | **now** | now | now |
| staged file | `S_IFREG 0644` | 1 | staged size | staged mtime | = mtime | now |
| published file | `S_IFREG 0644` | 1 | manifest size | manifest mtime | = mtime | now |
| published symlink | `S_IFLNK 0777` | 1 | byte length of target | manifest mtime | = mtime | now |

- uid/gid are the serving process's; `st_ino` and `st_dev` are 0 (libfuse assigns node ids).
- **Read-only domain:** the write bits are cleared (`mode & ~0o222`), and the mount carries `ro`, so the kernel refuses every mutation with **EROFS** before it reaches the server.
- Because `utimens` is a no-op, a file's mtime is the time of its last staged write, and `touch` or `rsync -t` do not set times.

### A4.4 Read-only

Read-only is enforced by the kernel through the `ro` mount option; the file operations called by the mount do not check it. The same domain's socket still refuses mutating IPC actions with `read_only` (contract §A3.2).

### A4.5 statfs

- `bsize = frsize = 4096`.
- Capacity = the **tightest** (least available) of the domain's writable members that have a local path, measured by one `statvfs` per such member. Read-only members and object stores do not count. `blocks = total/4096`, `bfree = free/4096`, `bavail = avail/4096`.
- No bounded member: total = free = avail = 2^50 bytes (1 PiB), so nothing that sizes a write against free space refuses. (`df -k` reports 1099511627776 1K-blocks; the e2e suite pins it.)
- `bfree` is not `bavail`: df derives its *used* column from `bfree`, which counts the root reserve; only `bavail` is what this writer gets.
- `files = ffree = favail = max int`, `fsid = 0`, `flag = 0`, `namemax = 255`.
- It walks no cache and makes no backend call, because df-like tools poll it.

### A4.6 Symlinks

Domain setting `symlinks` (required field): `keep`, `follow`, `skip`.

- Only `keep` lets the mount **create** symlinks; `follow` and `skip` refuse `symlink()` with EPERM, since neither may put a symlink object in the domain and "follow" is undefined at creation time (relative, dangling or out-of-mount targets).
- Symlinks already published (by a `keep` peer) are presented as symlinks whatever the local policy: `getattr` says `S_IFLNK` and `readlink` answers the target.
- A symlink has no bytes to stage. Its upload publishes the manifest the mirror already holds.
- The policies also drive import and rsync, which are specified elsewhere.

### A4.7 Kernel caches and invalidation

Mount options turn the kernel's caches off: `entry_timeout=0`, `attr_timeout=0`, `negative_timeout=0`. Freshness is bought with one LOOKUP per path component per access. `auto_cache` is also passed but is inert, since every open replies `direct_io` (no page cache for file data).

Timeouts of zero do not stop the kernel from resolving a path through a dentry it already holds. That left a name another client renamed away still resolvable inside an already-open directory, and made two mounts disagree with no fault injected. So the mount also **pushes** invalidations:

- **Trigger:** the `changed` hook, called by the request handler for each key of a `{"action":"changed","keys":[…]}` notice, and after a `revert`.
- **Senders:** the launcher parent after replaying foreign journal entries (batched ≤512 keys, flushed every 0.2 s), and any process that records a journal entry for the domain (a CLI import or revert, and this process's own uploads), which notifies the domain socket the same way.
- **Action:** invalidate the path `/<domain-relative path of key>` through libfuse's path invalidation (drops dentry and cached attributes). Keys are sent as file keys; path invalidation does not care about kind.
- **Thread:** always from the scheduler thread, never from inside a FUSE callback on the same path: the kernel waits on that request while the invalidation waits on the kernel.
- **Errors:** "not cached" (ENOENT) is success. Any other error (including "no live mount") is logged at debug level and dropped.
- **Gap:** a directory's cached *listing* is covered neither by the timeouts nor by path invalidation. A stale readdir survives until the directory is opened afresh. Closing it needs entry-level invalidation (`notify_inval_entry` on the parent) from the low-level API.

### A4.8 Reads

- One read request is at most the kernel's max read size (128 KiB by default). A sequential stream therefore reaches the core as thousands of small reads, and read-ahead is the core's (contract: checkout spec).
- The stream id is absent, so **all readers of one key share one read-ahead state**. Two processes reading different regions of the same file interleave on it. Android differs: it keys read-ahead per handle.
- An uncached chunk is fetched from the backend inside the read. Offline, such a read fails as soon as the fetch fails (EIO, recorded). A read that waits on the network without a timeout blocks cgroup freezing and hangs system suspend: one did so on 2026-09-17 when Wi-Fi dropped mid-read. Reads must fail fast when offline.

## A5. `.fuse_hidden*` files

libfuse's high-level layer, not tsync, hides a file that is unlinked or renamed over while a descriptor on it is open. It picks a free name `.fuse_hidden<16 hex>` by calling `getattr` until one answers ENOENT, then renames the victim to it. On the last `release` it unlinks the hidden name.

tsync treats these names as process-local scratch that is never published:

| callback on a hidden path | behaviour |
|---|---|
| `getattr` | not dispatched: `stat` of the key → always ENOENT (which is what libfuse's name search needs) |
| `mknod` | create an empty file at the scratch path, creating parent directories |
| `open` | nothing; reply `direct_io` |
| `read` / `write` | `pread`/`pwrite` on the scratch file (`write` creates it) |
| `release` | nothing |
| `unlink` | unlink the scratch file, ignoring absence |
| `rename(src, hidden dst)` | rename scratch(src) → scratch(dst), ignoring ENOENT; then `delete(src key)` on the real side |
| `truncate` | `ftruncate` the scratch file |

The real file's bytes are **not** moved into scratch: scratch(src) of a domain file does not exist, so the rename is a no-op, and the domain file is deleted. A process holding a descriptor on a file another process deleted or replaced therefore does not keep reading the old content (its reads hit a scratch path that does not exist). See §A9.

## A6. Request handler hooks

The mount serves the domain socket with the shared request handler and these hooks:

| hook | behaviour |
|---|---|
| `evict(key)` | If the key is a directory (by key kind, else by the mirror), `evict` every file of `list_tree(dir)`, sequentially, logging and skipping each failure (`evict <key>: <exn>`). Else `evict(key)`. |
| `restore(key, keep?)` | The same subtree walk with `ensure_cached(key, keep)` (default pin 10 days). |
| `changed(key)` | Kernel invalidation, §A4.7. Synchronous and non-blocking. |
| `full_resync()` | Nothing. The `sync --full` client rebuilt the mirror before signalling, and every lookup rereads it. |
| `status_fields()` | `mount: <mount point>` |
| `stats_fields()` | `frontend:"fuse"`, `mountPoint`, `openHandles`, `filesOpened`, `bytesRead`, `bytesWritten`, `bytesReadPerSec`, `bytesWrittenPerSec`, `handlerFailures`, then the domain's own fields |
| `on_stop()` | Request an internal stop (§A7.2) |

`on_upload_done` passed to the domain's `start` does nothing: on a mount, a finished upload changes nothing a reader can observe.

The socket serves no event stream (`subscribe` is answered but nothing is ever published), which is why the tray polls.

## A7. Lifecycle

### A7.1 Start

1. Resolve options (`allowOther`, `mountSubtype`); a bad subtype fails here, before anything is mounted.
2. Run `fusermount3 -uz <mount point>` (output discarded, failure ignored) to clear a stale mount left by a crash. Then create the mount point with parents.
3. Prefix every log line with `[<domain>] `.
4. Enable backtrace capture for recorded handler failures (§A8).
5. Start the scheduler thread, which in order:
   1. starts the domain (ensure the root, start this process's upload and metadata queues);
   2. serves the domain socket in the background;
   3. starts the failure reporter;
   4. installs SIGTERM and SIGINT handlers → internal stop;
   5. publishes the "loop stopped" notification handle for the main thread;
   6. signals *ready*;
   7. waits for a stop.
6. The main thread waits for *ready*, logs `mounting FUSE at <mp>`, and runs the libfuse loop with argv:

```
["tsync", <mount point>, "-o", "fsname=tsync,subtype=<subtype>[,ro][,allow_other],entry_timeout=0,attr_timeout=0,negative_timeout=0,auto_cache"]
```

The loop runs multi-threaded and in the foreground. libfuse installs its own signal handlers only for signals still at their default disposition; SIGTERM/SIGINT are already taken by step 5.4, so they reach tsync's handler.

The resulting `/proc/self/mountinfo` line has fstype `fuse.<subtype>` (by default `fuse.sshfs`) and mount source `tsync`.

### A7.2 Stop

There are two ways to stop.

**Internal stop** (IPC `stop`, the launcher's SIGTERM, SIGINT): mark *unmount needed*, request the process-wide shutdown (backoffs and queues give way), and wake the scheduler's wait. The scheduler then runs **concurrently**:

- **Unmount:** sleep 0.1 s so the IPC `stop` reply reaches its caller, then `fusermount3 -u <mp>`. If it exits non-zero (something still holds the mount; one media server with a file open is enough), log at info and run `fusermount3 -uz <mp>`. If that also fails, log an error that the mount point is left behind; the next start's step 2 clears it.
- **Drain for stop** (contract §A3.4): all drains raced against the grace.

The two run concurrently because the unmount is what releases the main thread from the libfuse loop, so it must not wait behind the drain. When both have finished, the scheduler's run returns and its *after* step runs on the scheduler thread: unlink the socket, flush stdout/stderr, and **exit the process with status 0 immediately**.

Exiting is what ends the kernel session. A lazy detach removes the mount from the tree, but the connection lives as long as any process holds a descriptor inside it, and the libfuse loop does not return until then. Waiting for the loop turned every stop with a held file into a 90 s systemd timeout ending in SIGABRT. After exit the holder's descriptor fails (ENOTCONN was observed). Nothing owed is lost: the drain has already run, and what it did not finish is on disk for the next start.

**External unmount** (someone ran `fusermount3 -u`, or the connection was aborted): the libfuse loop returns on the main thread, which posts an asynchronous "stop" notification to the scheduler. It must not submit-and-wait, because the scheduler may already be gone and that would block forever. *Unmount needed* is false, so the scheduler skips the unmount, drains, and returns. The main thread then joins the scheduler thread, unlinks the socket, and returns normally from `start`.

### A7.3 Timing budget

- The drain grace is the process-wide shutdown grace (10 s by default).
- systemd's `TimeoutStopSec=30` must exceed grace + unmount; the launcher's reaper waits grace + 2 s before SIGKILL.
- Test-pinned: with a file held open inside the mount, SIGTERM ends the mount process by itself (not by a signal) within 10 s.

## A8. Error mapping

| origin | errno returned to the kernel |
|---|---|
| a file operation fails with an OS error (ENOENT, ENOSPC, EACCES, EEXIST, …) | that errno, unchanged |
| `getattr` on an absent key | ENOENT |
| `readlink` on a non-symlink | EINVAL |
| `symlink` with `symlinks ≠ keep` | EPERM |
| any mutation on a read-only domain | EROFS (from the kernel, because of `ro`) |
| an unregistered callback | ENOSYS (xattrs are surfaced as EOPNOTSUPP by the kernel) |
| **anything else**: backend failures, "this client holds no id for the folder it is in; run 'tsync sync' first" on mkdir/rmdir/rename under an unidentified folder, offline fetch failures, programming errors | **EIO**, and the failure is recorded |

**Recording a non-errno failure** happens in the binding, on the failing worker thread, and must not do anything that can fail (a previous version formatted a log line there; an exception raised while formatting escaped and reached callers as ERANGE, "numerical result out of range", with nothing logged):

- A process-wide counter is incremented first. It counts every failure, including ones that could not be stored. It is exported as `handlerFailures`.
- The entry `{ticket (monotonic from 0), time, op name, path, exception, backtrace?}` is written to a fixed ring of 1024 entries. The backtrace is captured only when capture is enabled (it is) and is the backtrace of the original raise, carried across the scheduler hop.
- **Reporter:** a scheduler task wakes every 30 s. It logs each entry whose ticket is ≥ the last seen (`fuse <op> <path>: <exn>`, then the backtrace), advances past the newest, and if the counter exceeds the next ticket, logs `fuse: N handler failures went unreported` (the ring wrapped).
- Error-level logs are polled rather than pushed, because waking a reader from the failing thread is itself something that can fail.

A failure is never surfaced to IPC clients this way; IPC errors use the contract's codes.

## A9. Open questions / inconsistencies

1. **`.fuse_hidden` loses the content of open-but-deleted files.** The hide rename moves a scratch path that does not exist and then deletes the domain file, so a reader holding the descriptor gets errors instead of the old bytes. POSIX semantics would keep the bytes readable until the last close (for example by materialising or pinning the file into scratch at hide time).
2. **Rename flags are ignored.** `RENAME_NOREPLACE` overwrites an existing destination, and `RENAME_EXCHANGE` performs a plain rename. Either implement them or refuse with EINVAL.
3. **Stale readdir** until the directory is reopened (§A4.7); needs entry-level invalidation of the parent.
4. **`rmdir` is recursive**, unlike POSIX (ENOTEMPTY). Tools relying on `rmdir` failing on a non-empty directory will delete a subtree.
5. **Directory mtime is "now"** on every getattr, so `find -newer` and backup tools see directories as always modified. Files are stable.
6. **Offline reads may block** for as long as the fetch's retry policy allows; no FUSE-level timeout exists. See §A4.8 and the suspend hang.
7. **`direct_io` everywhere** disables the page cache. On kernels without direct-io mmap support, shared-writable `mmap` of files in the mount fails, and it costs repeated reads of hot files. Unmeasured.
8. **Exit error on held descriptors:** code comments say ESTALE, while the commit that introduced exiting observed ENOTCONN.
9. **Two spellings of "is this key a directory":** the evict/restore hooks decide by key kind then the mirror, while getattr decides by the mirror entry alone.
10. **The `open(O_CREAT)` branch is unreachable** from the kernel (§A4.2). If it were reached for a staged-but-unpublished file, `create` would discard the staged edits.

## A10. Invariants the tests pin down

- **tests/unit/fuse_subtype:** an absent or blank subtype is `sshfs`; `tsync` is kept; `,`, `=` and space are refused.
- **tests/e2e/linux** (a real mount, a real second client, a local store served over http-proxy), plus the checks shared with macOS in `tests/e2e/harness`:
  - A create reaches the store; an edit becomes a new version; a copy within the domain; a folder plus a file; a delete leaves no manifest.
  - Another client's create, edit, delete and folder create/remove appear in the mount; a remote folder rename keeps its identity.
  - A share by ref and by rel serves the file; mount and store agree.
  - A path-based CLI command (`tsync cache --evict <path in mount>`) finds its domain's socket and answers `Evicted:`.
  - `df -k` on a mount with no bounded store reports 1099511627776 blocks.
  - SIGTERM with a file held open inside the mount: the process exits on its own within 10 s.
- **tests/e2e/stress:** two mounts under concurrent load see the same tree, and nothing is listed that cannot be read.
- **tests/content/absent_probe** (checkout level): no backend read on a metadata path. This is what keeps getattr ENOENT at ~0.3 ms.
- **Not tested in isolation:** the callback table, the hidden-file path, invalidation and statfs figures other than the unbounded case. They are covered only through e2e.

---

# Part II — Linux desktop integration

## B1. Mount discovery (one rule, in-process)

Desktop extensions must know whether a path is inside a tsync mount and which socket serves it. The rule lives once, in the core, and is shipped as a shared library with a single C-callable entry point. The Dolphin plugin loads it in-process rather than asking a daemon: the menu is drawn while the user waits, and an earlier version that asked each socket froze Dolphin when a daemon wedged.

**`mount_points() → [(mount point, socket path)]`**, in config order:

1. Load `config.json` (`$XDG_CONFIG_HOME|~/.config` + `/tsync/config.json`).
2. Read `/proc/self/mountinfo`. For each line, split on single spaces; field 5 is the mount point. After the ` - ` separator come fstype and source. Keep the mount point iff **source = `tsync`** and **fstype starts with `fuse.`**. Decode octal escapes `\NNN` in the mount point (`Jellyfin\040Media` → `Jellyfin Media`).
3. For each configured domain, compute its mount point (§A2.1 rule) and include `(mount point, <data dir>/tsync-<domain>.sock)` iff that exact string is among the kept mount points.
4. **Total:** any failure (missing HOME, unreadable config or mount table) returns `[]`. The caller is C++, where an escaping exception kills the host process.

Why this matching rule:

- **Liveness is the mount table, not the socket.** A mounted-but-wedged daemon still counts as live, and the plugin's IPC deadlines cover that case.
- **Source, not fstype, identifies tsync.** The fstype defaults to `fuse.sshfs` (§B2), so a real sshfs mount (source `user@host:…`) must be excluded by the source column. The `fuse.` prefix check rejects a non-FUSE filesystem that happens to be named `tsync`.

Cost measured inside Dolphin: 1.4 ms for the first call including runtime start, 141 µs afterwards.

**Shared-library contract** (`libtsync_mounts.so`, installed at `<libdir>/tsync/`):

- SONAME `libtsync_mounts.so`; the file name matches the SONAME, because the loader searches by SONAME.
- The embedded runtime is started once by the host (`caml_startup` with argv `["tsyncdolphin"]`), from **one thread only**: the thread drawing the menu.
- The entry point is looked up by name (`tsync_mount_points`), called with unit, and returns a list of string pairs that the host copies out immediately.
- Built position-independent. A self-contained object without PIC cannot be linked into a shared library on aarch64.

## B2. Why the mount reports `fuse.sshfs` (commit fcbba236)

KIO, and so Dolphin, generates thumbnails for every file on any mount whose filesystem type is not on its hard-coded list of network filesystems. On a tsync mount, browsing a folder therefore downloaded every file in it. `fuse.sshfs` is on that list, so the mount defaults to `subtype=sshfs`, and KIO treats it as remote and does not thumbnail.

- `fsname=tsync` keeps tsync's identity in the mountinfo **source** column, which is what discovery matches.
- `mountSubtype: "tsync"` restores `fuse.tsync` for anyone who wants thumbnails or an honest type in `mount`/`df -T`. Discovery still finds it.
- Side effect: tools that special-case sshfs (for example KIO's other network heuristics, or backup tools that skip network filesystems) now treat the mount as sshfs too.

## B3. Dolphin plugin (`tsync-dolphin`)

A KF6 `KAbstractFileItemActionPlugin`: context-menu actions only. It has no KIO worker and no overlay icons.

- **Metadata:** name `tsync`, MIME types `application/octet-stream` (every file) and `inode/directory`. Installed as `<qt plugin dir>/kf6/kfileitemaction/tsyncdolphin.so` (no `lib` prefix). Its RPATH is `<libdir>/tsync`, rewritten at install time. A plugin copied out of the build tree would keep the build machine's RPATH.
- **Algorithm, per menu:**
  1. Offer nothing unless exactly one item is selected and it is a local file URL.
  2. Resolve `(mount, rel)` against `mount_points()` by the **longest** mount with `path == mount` or `path` starting with `mount + "/"`. A sibling that only shares a prefix does not match; a nested mount wins. `rel` is `""` for the mount itself. No match → no actions.
  3. Always offer **Copy Share Link** (icon `tsync`, falling back to `edit-link`). On click it sends `{"action":"share","rel":rel}` asynchronously; on `ok` it copies `url` to the clipboard and shows the notification "Share link copied to the clipboard."
  4. Synchronously send `{"action":"stat","rel":rel}`: 200 ms to connect, 300 ms overall for a full line. No answer or `ok:false` → stop with only the share action, since acting on an item whose state is unknown is a guess.
  5. Offer **Make Available Offline**, or **Keep Offline Longer** when `availability = pinned`, which sends `restore` and on success notifies "<name> is available offline."
  6. Unless `availability = online-only`, offer **Make Online Only**, which sends `evict` and notifies "<name> is online only." A directory row carries no availability, so it gets both actions. On a mount, evict and restore apply to the whole subtree (§A6).
- **Transport:** each request is a fresh connection to the domain socket, one compact JSON line terminated by `\n`, and one reply line read until `\n`. No `domain` field: the Linux socket is per domain.
- **Errors:** `ok:false` → a desktop notification carrying the reply's `error` text (or "The daemon refused."). A socket error → a notification carrying the socket's error string. Notifications go through `org.freedesktop.Notifications.Notify` (app `tsync`, icon `edit-link`, 5 s timeout).
- **Tests (ctest):** against a fake library registering the same entry point with fixed answers. Three mounts cross the boundary; a space in a path survives; the runtime starts once; longest-prefix resolution; a sibling prefix does not match; the plugin metadata lists both MIME types. No test exercises a real menu.

## B4. Tray (`tsync-tray`)

A standalone process showing status for every configured domain as a StatusNotifierItem with a dbusmenu, over the session bus. It speaks raw libdbus (its own small binding) on a single thread.

**Startup:**

1. If `DBUS_SESSION_BUS_ADDRESS` is unset or empty, set it to `unix:path=$XDG_RUNTIME_DIR/bus` when that socket exists. Otherwise fail with "no session bus: the tray needs a running desktop session". This stops libdbus from auto-launching a private bus under ssh that nothing displays.
2. Ignore SIGCHLD, so `xdg-open` children are reaped automatically.
3. Claim `org.tsync.Tray` with DO_NOT_QUEUE. If it is already owned, print "tsync-tray is already running" and exit 0.
4. Claim `org.kde.StatusNotifierItem-<pid>-1`.
5. Export the item at `/StatusNotifierItem` and the menu at `/MenuBar`, and register with `org.kde.StatusNotifierWatcher` (`RegisterStatusNotifierItem`). ServiceUnknown at login is normal.
6. If `IsStatusNotifierHostRegistered` is false, warn that nothing will draw the icon (GNOME needs the AppIndicator extension).

**Item:** answers on both `org.kde.StatusNotifierItem` and `org.freedesktop.StatusNotifierItem`. Properties: Category `ApplicationStatus`, Id/Title `tsync`, Status `Active`, IconName, ToolTip, ItemIsMenu `true`, Menu `/MenuBar`, and empty pixmaps and overlays. `Activate`, `SecondaryActivate`, `ContextMenu` and `Scroll` are answered with an empty reply, since the click belongs to the menu. `NewIcon`/`NewToolTip` are emitted only when the value changes. The item watches `NameOwnerChanged` for the watcher and re-registers and re-announces when it gets a new owner (a Plasma restart). Every unclaimed method call gets an `UnknownMethod` error, never silence, because an unanswered call costs the host a 25 s timeout.

**Menu:** dbusmenu version 3 (`GetLayout`, `GetGroupProperties`, `GetProperty`, `Event`, `EventGroup`, `AboutToShow(Group)`; `LayoutUpdated` with an incrementing revision). The rows, the icon choice and the tooltip come from the menu model shared with macOS. Icon: `tsync-error-symbolic` if there are no domains or every domain is unreachable; `tsync-paused-symbolic` if all are paused; `tsync-sync-symbolic` if any is transferring; else `tsync-idle-symbolic`.

**Loop:** libdbus read/write with a 250 ms tick. Dispatch every queued message. Every 3 s, refresh:

- **Domains:** re-read `config.json` when its mtime changes. A missing or bad config is an empty list plus a warning. For each domain: name, socket, mount point (§A2.1 rule).
- **Status poll:** `{"action":"status"}` to every domain in parallel, each bounded at 1.5 s. A failure shows that domain as unreachable.
- **Stats:** `{"action":"stats","domain":D}` at 4 s each, sent only when the menu opens (`AboutToShow` or an `opened` event), debounced to once per second, and filled into the stats submenu.
- **Hold changes:** `{"action":"pause","arg":"on"|"off"}` to every domain at 1.5 s each, best effort, then an immediate re-poll so the checkmark shows what the daemons did.
- **Open folder / reveal file:** `org.freedesktop.FileManager1.ShowFolders` / `ShowItems` with a percent-encoded `file://` URI (unreserved characters and `/` kept). On any D-Bus error, fall back to `xdg-open` on the folder (xdg-open cannot select a file). A file is never opened, only revealed.
- **Quit** stops the tray only. A closed session bus ends the loop.

Polling is used because the FUSE socket publishes no events (§A6). Queue depth is not an event anywhere.

**Autostart:** the XDG entry `/etc/xdg/autostart/tsync-tray.desktop` (`Exec=/usr/bin/tsync-tray`, `Icon=tsync`, `X-GNOME-Autostart-enabled=true`, visible so users can disable it). XDG autostart is used rather than a systemd user unit because `graphical-session.target` exists only on systemd-managed sessions; systemd's autostart generator turns the entry into a session unit where one exists.

## B5. systemd units

| unit | installed by | ExecStart / ExecStop | notes |
|---|---|---|---|
| `tsync.service` (user) | `make install-system` (source install) | `%h/.local/bin/tsync start` / `… stop` | `WantedBy=default.target`; install enables lingering (`loginctl enable-linger`) so it runs without a session |
| `tsync@.service` (system template) | deb/rpm | `/usr/bin/tsync start` / `… stop` | `%i` is a **username** (`User=%i`); `WantedBy=multi-user.target`; enabled by hand: `systemctl enable --now tsync@alice` |

Both units have `After=`/`Wants=network-online.target`, `Restart=on-failure`, `RestartSec=5`, `TimeoutStopSec=30` (which must exceed the drain grace), and `LimitNOFILE=65536`.

**The system unit must not** set `ProtectHome=`, `PrivateTmp=` or `PrivateMounts=`. Each gives the service a private mount namespace, and the FUSE mount would then exist for nobody else.

A stale user unit pointing at a missing binary restart-loops every 5 s; it was seen on a development host. `make uninstall` removes the user unit, the binary link and leftovers from older source installs, and leaves lingering enabled.

## B6. Packaging

Three packages from one build, split so that a headless server gets neither libdbus nor Qt/KF6:

| package (deb / rpm) | contents | dependencies |
|---|---|---|
| `tsync` / `tsync` | `/usr/bin/tsync`, `tsync@.service`, the app icon (hicolor scalable), `<libdir>/tsync/libtsync_mounts.so` | shared libraries computed from the binary, plus **`fuse3` by hand** (`fusermount3` is executed, not linked) |
| `tsync-tray` / `tsync-tray` | `/usr/bin/tsync-tray`, the autostart entry, `tsync-{idle,sync,paused,error}-symbolic.svg` (hicolor `symbolic/apps`) | its shared libraries (libdbus), `tsync (= same version)` |
| `tsync-dolphin` / `tsync-dolphin` | `tsyncdolphin.so` | its shared libraries (Qt6, KF6), `tsync (= same version)` |

- The discovery library ships with `tsync`, not with the plugin, because it is tsync's answer and any other extension should link the same object. The app icon ships with `tsync` because a file has one owner and both desktop packages want it.
- The tray and plugin pin the exact tsync version because they speak the IPC protocol.
- The symbolic suffix plus the `symbolic/` directory is what makes GTK recolour the icons to the panel foreground; Qt recolours through the SVGs' embedded stylesheet.
- **Versions:** `0.0.0-<YYYYMMDD>.<run>~<distro suffix>` (deb; suffix `deb<VERSION_ID>` on Debian, `<ID><VERSION_ID>` otherwise) and release `<YYYYMMDD>.<run><dist>` (rpm). Asset names carry no version: `<pkg>_<distro>_<arch>.<ext>`.
- **deb maintainer scripts** (the rpm uses `%systemd_*` macros plus equivalent loops):
  - `postinst configure`: `daemon-reload`, and on an upgrade (`$2` non-empty) restart only the `tsync@*.service` instances already **active**. It never starts new ones, since which users to run for is not the package's choice.
  - `prerm remove`: stop active instances while the binary still exists, so `tsync stop` can unmount.
  - `postrm remove|purge`: delete `/etc/systemd/system/*.wants/tsync@*.service` links (a template's instances are unknown to dpkg), then `daemon-reload`.
  - rpm `%post` on upgrade uses `try-restart` on the active instances; `%preun` on erase stops them.
- **Build:** one opam switch builds the daemon, the tray and both discovery objects (the real one and the test fake); cmake builds the plugin against the real object and runs ctest. A missing Qt/KF6 fails the build rather than silently producing packages without the plugin.
- **Repository:** `linux/repo/build.sh` rebuilds signed apt and dnf repositories from scratch, grouping packages by the distro field in the file name. A missing gpg key aborts the publish, since apt refuses unsigned repositories.
- **CI checks:** the dependency split (dbus only in the tray, KF6 only in the plugin); the plugin resolves the discovery library with no build-tree RPATH; the maintainer scripts reference `tsync@*.service`.

## B7. Open questions (desktop)

1. A mounted-but-wedged daemon counts as live for discovery. The plugin's 200/300 ms deadlines limit the damage, but the share action has no deadline at all (it is asynchronous and waits indefinitely).
2. The tray's D-Bus layer has no tests.
3. The menu's actions (share, restore, evict) are only checked by hand in a real Dolphin.
4. `mount_point_of` takes the first `fuse` entry's `mountPoint`; a domain listing `fuse` twice is not rejected.
5. Discovery compares mount points as exact strings, so a configured `mountPoint` with a trailing slash or a symlinked component never matches mountinfo's canonical path.
