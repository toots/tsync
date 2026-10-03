# FUSE mount and the Linux desktop — OCaml implementation notes

Companion to the spec [../../frontends/fuse.md](../../frontends/fuse.md). Not normative. Section
numbers in parentheses are the spec's.

Code: `lib/frontends/fuse/fuse_options.ml` (the descriptor and its option checks) and
`fuse_mount.ml` (everything else). The libfuse binding is the external opam package `fuse3`
(`tsync-fuse.opam`); no C of the mount lives in this tree.

## Where each part lives

| Spec | Code |
|---|---|
| Descriptor, options (§2) | `Fuse_options`: `fields` with a `~check` per option, `user_id`, `group_id`, `mode`; registered `` `Per_domain ``. |
| Mount point (§2.1) | `Fuse_mount` `mount_point`: `--mount`, else `mountPoint`, else `Paths.mount_point`, through `Fs.resolve_parent`. |
| Threads (§3) | `Fuse_mount` `host`, registered with `Owner.register_host "fuse"`; `call` is `Rt.run_sync`. |
| Callbacks (§4.2) | `operations`: `getattr`, `readlink`, `opendir`, `readdir`, `releasedir`, `mknod`, `fopen`, `read`, `write`, `truncate`, `release`, `fsync`, `unlink`, `mkdir`, `rmdir`, `rename`, `symlink`, `statfs`, each over the engine's file operations. |
| Attributes (§4.3) | `stats`; a directory's mtime is the engine's `stat`, from `Mirror.dir_mtime`. |
| Multi-user access (§4.4) | `presentation`, `grants_others_write`, `check_mutation` (`Fuse.get_context`). |
| statfs (§4.5) | `statfs` over `Domain.capacity`; 2^50 bytes when no member is bounded. |
| Invalidation (§4.7) | `invalidator`, the `changed` hook. |
| Durability (§4.9) | the engine's `sync` in `fsync` and after a write through a handle opened `O_SYNC` or `O_DSYNC`; `close` in `release` once the handle modified the file. |
| Hidden names (§4.10) | `hide`, `retained`, `ensure_scratch`, `drop_hidden`; the engine's `retain` and `release`. |
| Status fields (§5) | `hooks.frontend`: `mount`, `open_handles`, `bytes_read`, `bytes_written`. |
| Start (§6.1) | `prepare`, `mounted_at`, `unescape_mount`; the option string is built in `host`. |
| Stop (§6.2) | `unmount`, `run_command`; the owner thread in `host`. |
| Failure ring (§7) | the binding's `Fuse.recent_errors`; `report_failures`. |

## Where the code departs from the spec

- **No `create` and no `fallocate`.** The binding's `operations` record has neither, so a create
  reaches the mount as `mknod` then `open`.
- **Interrupts are not answered.** A worker waits in `Rt.run_sync` until its call returns.
- **The direct-I/O `mmap` capability is not requested**: `operations` sets no `init`.
- **Invalidation runs on a system thread of its own**, not on the scheduler, fed by a queue under
  a mutex.
- **Counters are atomics updated on the workers**, and the handle, listing and hidden tables sit
  under one mutex, also taken on the workers. `filesOpened` is counted and not reported;
  `handlerFailures` and the per-second rates are not reported.
- **Ring entries carry no trace.** `Fuse.set_backtrace_capture` is never called, so
  `report_failures` logs the operation, the path and the exception.
- **`readdir` filters the whole snapshot at every offset call** (finding 146).
- **The exit waits for the unmount at most 5 s** after the drain, then happens whether or not it
  finished.
- **No test mounts.** `tests/config/config_test` checks the options through the catalog, and says
  so instead of running where `tsync_fuse` is not built; nothing under `tests/` drives a callback.

## Learnings

- **Only an OS error is an answer.** The binding answers a `Unix_error` with its errno, records
  any other exception in its ring and answers EIO. `call` turns a classified failure into its errno
  (`Fail.errno`) and lets the rest through: a handler that caught and converted would hide the
  failure from the ring.
- **An operation left at `default_operations` is not registered with libfuse**, by physical
  equality with the binding's `undefined`. Wrapping it in a closure registers it and answers ENOSYS
  where libfuse would have applied its default.
- **The owner runs on a thread, FUSE on the main one.** `host` starts a `Thread` that runs the
  owner, and the main thread waits on a mutex and condition for `` `Ready `` (the presentation's `go`
  ran, so the socket serves) or `` `Done code `` (the owner ended first, for example `owner_held`).
  The second case is what keeps the main thread from waiting for ever.
- **A stop unmounts from a hook.** `go` registers `Stop.on_request`, which spawns the unmount
  fiber: `fusermount3 -u`, then `-uz` when busy, run with `Unix.create_process` and reaped by
  polling, so no shell and no blocked worker. It runs beside the drain because it is what releases
  the main thread.
- **The owner thread ends the process.** Once the owner returned (drained, socket closed) it
  awaits the unmount, flushes and calls `Unix._exit`: a lazily detached session keeps `Fuse.main`
  alive as long as a descriptor is held inside it.
- **An external unmount** returns from `Fuse.main`; the main thread sets `loop_ended`, calls
  `Stop.request`, which never blocks, and joins the owner thread. The unmount fiber sees
  `loop_ended` and runs nothing.
- **Invalidation needs a thread that no callback waits on**: `Fuse.invalidate_path` blocks on the
  kernel, which may be waiting on a callback for the same path. Each key invalidates its path and
  its parent's; the root is skipped, as it has no entry to drop.
- **Buffers are not copied on the way in.** `Fuse.buffer` is the `Bigstring.t` of the file
  operations: a write passes a view of the kernel's buffer, which outlives the call because the
  worker waits; a read blits into it ([memory.md](../memory.md) M.1).
- **The mount table escapes and resolves.** `/proc/self/mounts` writes a space, tab, newline or
  backslash as `\ooo`, and names the resolved path, so `unescape_mount` and `Fs.resolve_parent`
  come before any comparison. A stale mount is recognised by its source `tsync`.
- **Options are checked twice.** `Fuse_options` refuses a bad value when the config is parsed;
  `presentation` resolves `uid` and `gid` again at start, since a user may have been removed since.
- **`open` with `O_TRUNC`** truncates, then opens its read handle; when that open fails the file
  is closed at once, so the truncation's upload record is owed (pitfall C-7.10).
- **Signals stay with the owner** because `Owner.stop_on_signals` blocks them in every thread
  before `host` runs ([07](../07-daemon-cli.md)).
- **`fusermount3` is executed, not linked**, so the package names `fuse3` by hand
  (`linux/deb/build.sh`), and `linux/build.sh` requires `tsync build-info` to list `fuse`: the
  library is `(optional)` and its absence fails no build.

## Linux desktop (Part II)

The tray, the Dolphin plugin and the mount-discovery shared library are not built in this tree.
What they will rest on is here: the mount reports `fsname=tsync` and `subtype=<mountSubtype>`
(§B1, §B2), `Menu.render` is the menu model (§B4, `tests/owner/menu_test`), and the units and
packages are under `linux/` (§B5, §B6).

Rules for when the discovery library is rebuilt as an OCaml shared object called from C++; none
depends on how the old one was written:

- Build it as `(executable (modes shared_object))`. `(modes object)` links a runtime that is not
  position-independent, which the linker refuses inside a `.so` on aarch64.
- dune sets no soname and names the file after the executable. Pass `-Wl,-soname,<name>` and give
  the executable that name; a mismatch fails when the plugin loads, not when it links. The JNI
  library of [android.md](android.md) is built this way.
- Every closure registered for C is total: an exception crossing into the host aborts it.
- `caml_startup` runs once, from one thread; other threads register before they call in.
- Test the C++ decoding against a second shared object that registers the same entry with fixed
  answers, never against the machine's mounts.
