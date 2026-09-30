# Backend driver: `local` — OCaml implementation notes

Companion to the language-neutral spec [../../backends/local.md](../../backends/local.md). See [README.md](../README.md) for how these notes are organised.

Code: `lib/backends/drivers/local/local_backend.{ml,mli}` (functor `Over`), `lib/lwt/backends/drivers/local/local_backend_lwt.ml` (application + registration), `lib/local/io/{filename,fs}.ml`, `lib/local/device/{linux_device,macos_device,watch}.ml` + `*_stubs.c`, `lib/core/bigstring.ml`, `lib/lwt/local/io/{io_lwt,watch_lwt}.ml`.

## B-I. Runtime-independent OCaml learnings (valid under Lwt or OCaml 5 direct style)

**B1. The driver is a functor over six seams (spec §1).** `Over (Io) (Fs) (Syscalls) (Bounded) (Clock) (Watcher)`; the `.mli` exposes only `spec` and `make ?verify_writes ~root () : (module Store)`. `Syscalls` shares `fd` with `Fs` (`with type fd = Fs.fd`). The seams are what let `tests/backends/durable_writes` substitute a recording `Syscalls` (wraps `openfile`/`fsync`/`rename`/`link`) and assert fsync-before-publish without staging a crash. Keep a syscall seam in any rewrite for exactly that test.

**B2. Registration by link-time side effect (spec §2).** `Local_backend_lwt` registers `"local"` in `Backend_lwt`'s registry from a toplevel `let () =`; the library has `(library_flags (-linkall))`. Dropping `-linkall` removes the module from the binary and every config naming `"local"` fails "unknown backend type" — the suite catches it only because tests ask the registry by name (`Fixture.local_store`).

**B3. `verifyWrites` parsed by `Field_spec.bool ~default:true`** (`true/1/yes/on`, `false/0/no/off`, else default). JSON bools reach the factory as the strings `"true"`/`"false"` because the config parser stringifies scalar fields.

**B4. Bodies are `Bigstringaf.t`, mmapped (spec §4).** `Bigstring.map_file ?scratch ~path ~offset ~len ()` = `Unix.map_file fd ~pos Bigarray.char c_layout false [|len|]` on a snapshot descriptor, descriptor closed immediately. `len = 0` short-circuits to `empty` without opening the file. `Unix.map_file` handles non-page-aligned `pos` itself. Mapping is synchronous by design ("mmap moves no data"); the I/O happens at page-touch time, wherever that is (hashing, socket write).

**B5. Physical identity is the claim result (spec §5).** `create_exclusive` returns `data` itself on a win, so callers (and the counting wrapper used by other drivers) can test `held == data`. Any change that copies the buffer on the win path breaks that.

**B6. Errors are `Unix.Unix_error` matched by constructor**, converted by `of_errno ~op key e` into `Retry.failed ~kind ~op:("local " ^ op)`. Only five ops wrap; the rest leak `Unix_error`, which `Retry.classify` maps to Transient (spec §10, open question 2). In a rewrite, one wrapper at the module boundary would make the kinds uniform.

**B7. Walk memory (spec §8).** `Bounded.each ~width f` with `f` popping from a `ref` list: a fixed number of live tasks, not one per entry. The earlier "promise per entry" version held ~100 MB of pending promises/closures for 500k manifests before returning a key. Same rule for fibers under effects: bound live tasks, not just tasks doing I/O. The per-store `walk_slots` (`Bounded.create ~max:64`) is taken only around `Sys.stat`, never across recursion (nested same-pool deadlock).

**B8. Lazy per-instance state inside `make`.** `scratch ()` (a `bool ref` + `Unix.mkdir` — a *blocking* `Unix` call, not via the seam), `concurrency = lazy (Device.max_concurrency root)` (reads `/proc`, `/sys`, or spawns `df`+`diskutil` on macOS; blocking, once), and `watchers : (string, Watcher.t) Hashtbl.t`. Under domains the `ref`, `lazy` (`Lazy.Undefined` on concurrent force) and `Hashtbl` need a mutex or `Atomic`.

**B9. Process-global mutable state below the driver.** `Filename.temp_seq` (`int ref`, incremented per temp name), `Bigstring.clonable` (`Hashtbl` per directory) and `warned_no_clone`. All unsynchronised: fine on one domain; with several, `temp_seq` can hand two writers the same temp name (the property that name exists to guarantee) — make it `Atomic.fetch_and_add`.

**B10. C stubs hold the runtime lock.** `tsync_ficlone` (ioctl), `tsync_watch_open_dir`, `tsync_watch_drain` do not release it (no disk data moved). The drain is bounded to 64 passes because an event that will not clear (a kqueue registration missing `EV_CLEAR`) would otherwise spin in C with the lock held, untimeoutable from OCaml. The temp-name test is duplicated in C (`tsync_watch_is_temp_name`) and must match `Filename.is_temp_name`.

**B11. `Device` is selected per platform by dune** (`device.linux.ml` / `device.macos.ml` re-exporting `Linux_device` / `Macos_device`). `macos_device.ml` shells out via `Unix.open_process_in` rather than binding IOKit.

## B-II. Lwt / functor-specific learnings (and what they become under OCaml 5 effects/domains)

**B12. Instance.** `Local_backend.Over (Io_lwt.Core) (Io_lwt.Fs) (Io_lwt.Syscalls) (Io_lwt.Bounded) (Io_lwt.Clock) (Watch_lwt)`. Under direct style the functor collapses to a module over plain functions; keep the `Syscalls` and `Clock` seams for B1's test and for fake clocks.

**B13. What blocks the Lwt loop.** `Lwt_unix.{stat,rename,link,fsync,mkdir,unlink,openfile,readdir}` run as Lwt jobs on its thread pool. But `Io_lwt.Fs.pwrite` is a synchronous stub wrapped in `Lwt.return` (`positioned`), so `put` writes the whole body on the event-loop thread; `map_file` (open + `FICLONE` + `mmap`) is synchronous too; and page faults on mapped bodies happen on whichever thread touches them — for Lwt, the loop. On a local SSD this is microseconds; on a NAS or a failing disk every chunk write and every cold page stalls every other task in the process. Under OCaml 5 the fix is to run these on a domain pool / systhread (or `io_uring`), or at least to make `pwrite` a job like `Lwt_bytes.write`.

**B14. Watch waiting (spec §6).** `Watch_lwt.open_dir` wraps the raw fd once with `Lwt_unix.of_unix_file_descr ~blocking:false` (a fresh wrapper per wait would register fresh engine state each time). `wait` = `Lwt_unix.wait_read` then `Watch.drain`; loops if the drain says "only our own scratch". The store races it with `Clock.with_timeout 2.0` and recognises the timeout by `Clock.is_timeout exn` (`= Lwt_unix.Timeout`); cancellation of the losing `wait_read` is Lwt's. Under effects: an fd-readiness primitive from the scheduler (Eio `await_readable`, or a thread blocking in `poll`) plus a timeout combinator; the drain logic is unchanged.

**B15. `Io.finalize` for fd closing and temp unlinking**, `Io.catch` for errno dispatch: under direct style these become `Fun.protect ~finally` and `try … with`. Careful: `Fun.protect` re-raises `Finally_raised` if the finaliser raises; `close` and `unlink_quiet` must stay non-raising.

**B16. Cooperative atomicity used here.** `scratch ()`'s check-then-set and `watcher_for`'s find-then-add are race-free only because nothing yields between them (no bind). With preemptive domains, two first readers may both `mkdir` (harmless, `EEXIST` handled) and two first watchers may both open one (leaks one inotify fd) — guard with a mutex if it matters.

**B17. GC lock is Lwt-specific** (`Gc_lwt.Lockfile` = `Lwt_unix.lockf fd F_TLOCK 0`), plus an in-process `held` flag because POSIX record locks merge within one process. Under domains the flag must be atomic; `lockf` semantics (per process, not per domain) stay the same.
