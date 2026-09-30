# Backend driver: `local` — OCaml implementation notes

Companion to the language-neutral spec [../../backends/local.md](../../backends/local.md). See [README.md](../README.md) for how these notes are organised.

Code: `lib/backends/drivers/local/local_backend.{ml,mli}` (functor `Over`), `lib/lwt/backends/drivers/local/local_backend_lwt.ml` (application + registration), `lib/local/io/{filename,fs}.ml`, `lib/local/device/{linux_device,macos_device,watch}.ml` + `*_stubs.c`, `lib/core/bigstring.ml`, `lib/lwt/local/io/{io_lwt,watch_lwt}.ml`.

## B-0. Where the current code differs from the spec

- **Keys are not confined** (findings S3, reproduced): `resolve` joins the key onto the root without normalising `..`, and symbolic links below the root are followed. A signed http-proxy request for `tsync/<d>/../../<path>` reads, writes or deletes outside the store.
- **Directory-marker keys**: `put` of a key ending in `/` runs `mkdir -p`; `copy` of one creates an empty directory; listings emit an empty directory as its `…/` key (`last_modified = 0`); `delete` of one runs `rm -rf` on the subtree.
- **`delete`** is `head_opt` then `rm -rf` (lstat-based), swallowing `ENOENT` and every per-entry unlink/rmdir error, and still answering `true` if the key existed: `delete_multi` can "succeed" having removed nothing. A corruption marker's delete prunes its three parent directories.
- **Error kinds are inconsistent**: only `put_if_absent`, `get`, `get_opt`, `get_range` and `copy`'s link path wrap errors (`EIO ENOSPC EMFILE ENFILE EAGAIN EINTR EBUSY` → Transient, anything else → Permanent). `put`, `head_opt`, `delete`, `delete_multi`, `list_prefix` and `copy`'s body-copy fallback leak `Unix_error`, which `Retry.classify` reads as Transient, so `EACCES` on `put` retries forever while `EACCES` on `get` is Permanent. `ESTALE`/`ETIMEDOUT`/`EHOSTDOWN` are Permanent.
- **No directory fsync** after rename, link or unlink: a crash after `put` returns can lose the name. Parent directories created by `mkdir -p` are not fsynced either. A failed `put` leaves its temp file.
- **Temp names** are `.tsync-tmp-<pid>-<seq>.tmp` opened `O_CREAT` without `O_EXCL`; two hosts on one NAS can share a name. Nothing sweeps orphaned temp files in store roots.
- **Reads are mmapped** (as the spec recommends), through a reflink clone where the filesystem supports it (`FICLONE` / `clonefile` into `<root>/.tsync-tmp-scratch.tmp`, a mode-0700 directory created on first read), else the file itself. `EIO` and NFS `ESTALE` surface as SIGBUS on page touch, including inside `verify_written`'s hash. Correctness never depended on the clone (names are only replaced by rename); the scratch directory existed so a reader's clone staging would not wake a watch on the object's directory (which once looped until OOM).
- **`copy` onto an existing destination** keeps the destination (`EEXIST` → success) rather than replacing it.
- **`list_prefix`** resolves the prefix as a path (whole components only), follows symbolic links (`stat`), lists the GC lock file, sorts, and truncates to `max_keys` without stopping the walk early.
- **`watch`** ignores `last_seen`; a watcher whose directory was deleted goes silent and the store falls back to 2 s polling for the rest of the process.
- **`path`** is used verbatim: not expanded, not made absolute.
- **Health** is `always_up`; there is no bound on a blocking call, and `pwrite`, `map_file` and page faults run on the Lwt loop thread (B13).
- **Device probing** (`Device.max_concurrency`): mount-point matching is a plain string prefix (`/mnt/tsync` "covers" `/mnt/tsync2`), `\040` escapes in mountinfo are not decoded, and a relative or symlinked `path` is not canonicalised. On Linux: `/proc/self/mountinfo` → `/sys/dev/block/<maj:min>` (parent disk for a partition) → `device/queue_depth`, else `queue/nr_requests`; `d > 0` → `max(2, min(64, 4·d))`. On macOS: `df -P` → `diskutil info` (`Solid State`, `Protocol`, `Device Location`).

- **No reference gate in the driver**: promotion during a run is done by the content layer (`promote_all`), which checks the run marker once before publishing (findings F1, F2); the spec moves the gate into the driver.

## B-0.1 Resource choices (not normative, P6)

- Walk: per-store pool of 64 stat slots, 8 directory workers × 8 entry workers, a slot held only around the `stat`.
- `max_concurrency` from `Device.max_concurrency`, probed lazily once per store: Linux queue depth of the block device, `max(2, min(64, 4·depth))`; macOS by medium and bus.

## B-I. Runtime-independent OCaml learnings (valid under Lwt or OCaml 5 direct style)

**B1. The driver is a functor over six seams.** `Over (Io) (Fs) (Syscalls) (Bounded) (Clock) (Watcher)`; the `.mli` exposes only `spec` and `make ?verify_writes ~root () : (module Store)`. `Syscalls` shares `fd` with `Fs` (`with type fd = Fs.fd`). The seams are what let `tests/backends/durable_writes` substitute a recording `Syscalls` (wraps `openfile`/`fsync`/`rename`/`link`) and assert fsync-before-publish without staging a crash. Keep a syscall seam in any rewrite for exactly that test.

**B2. Registration by link-time side effect.** `Local_backend_lwt` registers `"local"` in `Backend_lwt`'s registry from a toplevel `let () =`; the library has `(library_flags (-linkall))`. Dropping `-linkall` removes the module from the binary and every config naming `"local"` fails "unknown backend type" — the suite catches it only because tests ask the registry by name (`Fixture.local_store`).

**B3. `verifyWrites` parsed by `Field_spec.bool ~default:true`** (`true/1/yes/on`, `false/0/no/off`, else default). JSON bools reach the factory as the strings `"true"`/`"false"` because the config parser stringifies scalar fields.

**B4. Bodies are `Bigstringaf.t`, mmapped.** `Bigstring.map_file ?scratch ~path ~offset ~len ()` = `Unix.map_file fd ~pos Bigarray.char c_layout false [|len|]` on a snapshot descriptor, descriptor closed immediately. `len = 0` short-circuits to `empty` without opening the file. `Unix.map_file` handles non-page-aligned `pos` itself. Mapping is synchronous by design ("mmap moves no data"); the I/O happens at page-touch time, wherever that is (hashing, socket write).

**B5. Physical identity is the claim result.** `create_exclusive` returns `data` itself on a win, so callers (and the counting wrapper used by other drivers) can test `held == data`. Any change that copies the buffer on the win path breaks that.

**B6. Errors are `Unix.Unix_error` matched by constructor**, converted by `of_errno ~op key e` into `Retry.failed ~kind ~op:("local " ^ op)`. Only five ops wrap; the rest leak `Unix_error`, which `Retry.classify` maps to Transient. In a rewrite, one wrapper at the module boundary would make the kinds uniform.

**B7. Walk memory.** `Bounded.each ~width f` with `f` popping from a `ref` list: a fixed number of live tasks, not one per entry. The earlier "promise per entry" version held ~100 MB of pending promises/closures for 500k manifests before returning a key. Same rule for fibers under effects: bound live tasks, not just tasks doing I/O. The per-store `walk_slots` (`Bounded.create ~max:64`) is taken only around `Sys.stat`, never across recursion (nested same-pool deadlock).

**B8. Lazy per-instance state inside `make`.** `scratch ()` (a `bool ref` + `Unix.mkdir` — a *blocking* `Unix` call, not via the seam), `concurrency = lazy (Device.max_concurrency root)` (reads `/proc`, `/sys`, or spawns `df`+`diskutil` on macOS; blocking, once), and `watchers : (string, Watcher.t) Hashtbl.t`. Under domains the `ref`, `lazy` (`Lazy.Undefined` on concurrent force) and `Hashtbl` need a mutex or `Atomic`.

**B9. Process-global mutable state below the driver.** `Filename.temp_seq` (`int ref`, incremented per temp name), `Bigstring.clonable` (`Hashtbl` per directory) and `warned_no_clone`. All unsynchronised: fine on one domain; with several, `temp_seq` can hand two writers the same temp name (the property that name exists to guarantee) — make it `Atomic.fetch_and_add`.

**B10. C stubs hold the runtime lock.** `tsync_ficlone` (ioctl), `tsync_watch_open_dir`, `tsync_watch_drain` do not release it (no disk data moved). The drain is bounded to 64 passes because an event that will not clear (a kqueue registration missing `EV_CLEAR`) would otherwise spin in C with the lock held, untimeoutable from OCaml. The temp-name test is duplicated in C (`tsync_watch_is_temp_name`) and must match `Filename.is_temp_name`.

**B11. `Device` is selected per platform by dune** (`device.linux.ml` / `device.macos.ml` re-exporting `Linux_device` / `Macos_device`). `macos_device.ml` shells out via `Unix.open_process_in` rather than binding IOKit.

## B-II. Lwt / functor-specific learnings (and what they become under OCaml 5 effects/domains)

**B12. Instance.** `Local_backend.Over (Io_lwt.Core) (Io_lwt.Fs) (Io_lwt.Syscalls) (Io_lwt.Bounded) (Io_lwt.Clock) (Watch_lwt)`. Under direct style the functor collapses to a module over plain functions; keep the `Syscalls` and `Clock` seams for B1's test and for fake clocks.

**B13. What blocks the Lwt loop.** `Lwt_unix.{stat,rename,link,fsync,mkdir,unlink,openfile,readdir}` run as Lwt jobs on its thread pool. But `Io_lwt.Fs.pwrite` is a synchronous stub wrapped in `Lwt.return` (`positioned`), so `put` writes the whole body on the event-loop thread; `map_file` (open + `FICLONE` + `mmap`) is synchronous too; and page faults on mapped bodies happen on whichever thread touches them — for Lwt, the loop. On a local SSD this is microseconds; on a NAS or a failing disk every chunk write and every cold page stalls every other task in the process. Under OCaml 5 the fix is to run these on a domain pool / systhread (or `io_uring`), or at least to make `pwrite` a job like `Lwt_bytes.write`.

**B14. Watch waiting.** `Watch_lwt.open_dir` wraps the raw fd once with `Lwt_unix.of_unix_file_descr ~blocking:false` (a fresh wrapper per wait would register fresh engine state each time). `wait` = `Lwt_unix.wait_read` then `Watch.drain`; loops if the drain says "only our own scratch". The store races it with `Clock.with_timeout 2.0` and recognises the timeout by `Clock.is_timeout exn` (`= Lwt_unix.Timeout`); cancellation of the losing `wait_read` is Lwt's. Under effects: an fd-readiness primitive from the scheduler (Eio `await_readable`, or a thread blocking in `poll`) plus a timeout combinator; the drain logic is unchanged.

**B15. `Io.finalize` for fd closing and temp unlinking**, `Io.catch` for errno dispatch: under direct style these become `Fun.protect ~finally` and `try … with`. Careful: `Fun.protect` re-raises `Finally_raised` if the finaliser raises; `close` and `unlink_quiet` must stay non-raising.

**B16. Cooperative atomicity used here.** `scratch ()`'s check-then-set and `watcher_for`'s find-then-add are race-free only because nothing yields between them (no bind). With preemptive domains, two first readers may both `mkdir` (harmless, `EEXIST` handled) and two first watchers may both open one (leaks one inotify fd) — guard with a mutex if it matters.

**B17. GC lock is Lwt-specific** (`Gc_lwt.Lockfile` = `Lwt_unix.lockf fd F_TLOCK 0`), plus an in-process `held` flag because POSIX record locks merge within one process. Under domains the flag must be atomic; `lockf` semantics (per process, not per domain) stay the same.
