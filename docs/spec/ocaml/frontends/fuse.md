# FUSE mount and the Linux desktop — OCaml implementation notes

Companion to the language-neutral spec [../../frontends/fuse.md](../../frontends/fuse.md). See [README.md](../README.md) for how these notes are organised. Each note names the spec section it implements.

Code: `lib/app/frontends/fuse/{fuse_frontend,fuse_fs,internal_ops,hidden_ops,path_ops}.ml`, `lib/app/cli/runner/daemon/engine/domain_engine.ml` (`run`, `on_loop`, `drain_for_stop`), `lib/local/desktop_mounts/`, `linux/dolphin/ml/`, `linux/tray/`.

## B-I. Runtime-independent learnings (valid under Lwt or OCaml 5 direct style)

**B-I.1 Registration and the optional build (spec §2).**
- `tsync_fuse_frontend` is an `(optional)` library depending on `fuse3`. `lib/app/frontends/dune` selects `frontend_fuse.enabled.ml` (a single line: `let () = Fuse_frontend.register ()`) when it resolves, else an empty `frontend_fuse.disabled.ml`. `tsync_frontend` is `-linkall`, so the registering module's side effect is not dropped.
- The trap: without `fuse3` the library disappears **silently** and the build stays green. What fails loudly is the launcher at run time ("configured but not compiled into this binary") and the e2e suite. Tests that link the frontend gate on `%{lib-available:tsync_fuse_frontend}`, which means they also vanish silently. A reimplementation should add a build-time assertion wherever the FUSE frontend is intended (the Linux release build).
- `tsync-fuse.opam` is a virtual package whose only job is to pull `fuse3`.

**B-I.2 The binding is a fork (spec §4, §4.7, §7).** `fuse3` is pinned to `git+file:///home/toots/src/ocaml/ocamlfuse#main` (at `c7bd205`). tsync depends on these fork-only additions:
- `Fuse.invalidate_path` (a1ce3f8) wraps high-level `fuse_invalidate_path`. The `struct fuse *` is published under a mutex once mounted and withdrawn before `fuse_destroy`. The path is copied to a C buffer **before** the runtime lock is released. A `-ENOENT` result ("not cached") is mapped to success. Any other error raises `Unix_error (EUNKNOWNERR (-err))`, including `-ENODEV` when no mount is live and `-ENAMETOOLONG` past `PATH_MAX`. The older note in `ocaml/08-frontends.md` saying it "raises when the path is not cached" is wrong.
- `Fuse.recent_errors`, `error_count` and `set_backtrace_capture` (f701c37, 41cf0f5): the exception ring (spec §7).
- The one-mount-per-process assumption is baked into the C handle (`ponytail:` note in `Fuse_util.c`). It matches `Process_per_binding`.

**B-I.3 How a callback crosses (spec §7).**
- `Fuse_lib.named_op*` wraps each op in `try Ok (f …) with Unix_error (e,_,_) -> Bad e`. **Only `Unix_error` is answered in OCaml**; the errno goes through the stub's `ml2c_unix_error_vect`.
- Any other exception propagates into the C stub, which records it in the ring **without allocating** (unless backtrace capture is on) and replies `-EIO`.
- Corollary: **handlers must not catch-and-convert.** A `with _ -> raise (Unix_error (EIO…))` in a handler hides the failure from the ring. c94929fe removed an `internal_ops` mknod catch that did exactly this. deeb5204 removed the old `on_loop` logging, which allocated on the failing thread and could raise a second exception that the old binding answered as ERANGE.
- `Fuse.set_backtrace_capture true` also turns on `Printexc.record_backtrace`. It costs an allocation per failure, which is accepted because an `Invalid_argument` from a `String.sub` otherwise names neither file nor caller.
- Registration is by physical equality: `default_operations` fields are the `undefined` closure, and `named_op f` returns `None` (op not registered with libfuse) iff `f == undefined`. Wrapping `undefined` in another closure would register the op and answer ENOSYS from OCaml instead of letting libfuse apply its default (for example `opendir` succeeding).
- `Fuse.main` reports setup failures as `Failure "fuse_mount failed"` and similar strings (status codes 1–8), raised on the main thread.

**B-I.4 Foreign threads and the runtime lock (spec §3).**
- On its first callback, each libfuse worker is registered with `caml_c_thread_register`, and a pthread key records that. Every callback then brackets itself with `caml_acquire_runtime_system` / `caml_release_runtime_system`.
- The main thread is marked OCaml-owned and releases the runtime lock for the whole `fuse_loop_mt`.
- Under OCaml 5 the "runtime lock" is domain 0's lock, so every FUSE worker contends on the domain holding the scheduler. That is fine only because a worker holds it just long enough to enqueue and later to copy the result.
- Buffers: `Fuse.buffer` is a `char` bigarray, and the checkout's `File_ops.buffer` is `Bigstringaf.t`, **the same type**. Kernel read/write buffers go straight into the file operations with no copy (`lib/local/io/fs_intf.ml`).

**B-I.5 Process exit (spec §3, §6.2).**
- `Unix._exit`, not `exit`, in two places: after a requested stop has drained (`finish_stop`, status 0), and when `Lwt_main.run` raises (`loop_died`, status 1). `at_exit` handlers would drain through the scheduler that is gone or finishing, which is the same wedge.
- `finish_stop` unlinks the socket and flushes stdout/stderr by hand first.

**B-I.6 Signals (spec §6.1).**
- OCaml installs signal handlers with `SA_ONSTACK` and no `SA_RESTART`, so once a handler exists (Lwt forces a SIGCHLD one), every blocking syscall in the process can be interrupted.
- `runtime/sys.c` reports EINTR as a `Sys_error` string, not as `Unix_error EINTR`. `tsync_stdlib` shadows `Sys`/`Stdlib` file operations to retry both spellings (37c0d67d). The FUSE process is exposed like every other.
- libfuse's `fuse_set_signal_handlers` only installs a handler where the disposition is `SIG_DFL`. tsync's SIGTERM/SIGINT handlers are installed on the scheduler thread **before** `ready`, so they are in place before `Fuse.main` runs and keep those signals. libfuse still takes SIGHUP and ignores SIGPIPE. The code comment claiming libfuse "may override these" does not match libfuse's behaviour.

**B-I.7 Shell-outs (spec §6).**
- `prepare_mount_point` uses `Sys.command "fusermount3 -uz <quoted> 2>/dev/null"` (through `/bin/sh`, result ignored) and runs before the scheduler exists.
- The stop path uses `Lwt_process.exec` with an argv array: no shell, and the exit status is inspected. `fuse3` must be a package dependency by hand, because nothing links `fusermount3`.

**B-I.8 The discovery library as a shared object (B1).** Recorded in the `ocaml-shared-object-for-plugins` note; the essentials:
- `linux/dolphin/ml/dune`: `(executable (name libtsync_mounts) (modes shared_object) (link_flags (-cclib -Wl,-soname,libtsync_mounts.so)))`.
- `(modes object)` produces one self-contained `.o`, but the runtime inside it is not PIC, and the link fails inside a `.so` on aarch64 (`R_AARCH64_ADR_PREL_PG_HI21`).
- dune sets **no SONAME** and names the file after the executable, so the executable name must equal the SONAME. A mismatch fails at load time with `cannot open shared object file`, not at link time.
- The whole OCaml side is `Callback.register "tsync_mount_points" Desktop_mounts.mount_points`. `mount_points` wraps everything in `try … with _ -> []`: an exception reaching C++ aborts Dolphin.
- C++: `caml_startup` once (static flag, one thread), then `caml_named_value` once, then `caml_callback(*f, Val_unit)`. The list is walked with `Field`/`String_val` and copied to `QString` without allocating on the OCaml heap, so no `CAMLlocal` is needed.
- Test the decode against `libtsync_mounts_fake` (same entry point, fixed answers), never against the machine's real mounts.
- Size: 2.48 MB stripped, of which about 1.79 MB is the runtime floor; `--gc-sections` does not reduce it.
- The plugin has no dune rule, so a `dune build` does not verify it. Build it in a scratch directory with cmake against `_build/default/linux/dolphin/ml/*.so`, and never `cmake --install` locally (that needs root and rewrites the RPATH).
- `tsync_desktop_mounts` is a private library `enabled_if (= %{system} linux)` with no `select`, since no other platform has an implementation.

**B-I.9 Tray (B4).**
- A single-threaded libdbus loop through tsync's own binding (`linux/tray/dbus/`, C stubs).
- It is its own opam package (`tsync-tray`) so that `conf-dbus` / libdbus never reaches the daemon's dependency closure.
- The menu model is `Tsync_menu`, shared with macOS; `tests/unit/menu` snapshots it.

## B-II. Lwt- and functor-specific learnings

**B-II.1 Bridging workers to the loop: `Domain_engine.on_loop` (spec §3).**
- `on_loop f = Lwt_preemptive.run_in_main (fun () -> Lwt.catch f …)`.
- A `Unix_error` is re-raised untouched: it is an answer, and getattr's ENOENT is the hot path. Anything else is wrapped as `With_backtrace (exn, Printexc.get_raw_backtrace ())`, because `run_in_main` re-raises on the calling thread and would otherwise replace the raise site's backtrace with its own. The failure reporter unwraps `With_backtrace` before logging.
- The same function serves Android's JNI threads (lifted out of `fuse_fs.ml` in 47040bc1).
- *Under OCaml 5 direct style:* each worker would enqueue a thunk to the scheduler domain (a mutex/condition queue, or the scheduler's cross-domain submit) and block on a one-shot result cell. The backtrace wrapper is still needed, because any cross-thread re-raise loses the original backtrace. The alternative is running file operations directly on worker threads (systhreads on one domain), which needs locks wherever the core now relies on cooperative atomicity (spec [07 §7](../../07-daemon-cli.md)).

**B-II.2 `Domain_engine.run ?main_thread ?after serve` (spec §3, §6).**
- `Lwt_main.run (serve ~ready)` runs on a `Thread.t`, and the main thread waits on a mutex/condition handshake.
- `ready` is also signalled if `serve` returns without calling it, since otherwise the main thread waits forever with nothing logged.
- `after` runs on the loop thread after a clean return; FUSE uses it for `finish_stop` when `unmount_needed`.
- The main thread then `Thread.join`s the loop thread and unlinks the socket (the external-unmount path).
- *Under OCaml 5:* the same shape with the scheduler on a domain or systhread. `Fuse.main` must keep the main thread, because libfuse's signal and daemonize handling assume it.

**B-II.3 Waking the loop from the main thread without waiting (spec §6.2).**
- When `Fuse.main` returns, the main thread must not use `on_loop`: `run_in_main` blocks until the loop takes the job, and the loop may already have finished.
- The code creates `Lwt_unix.make_notification do_stop` on the loop **before** `ready`, and the main thread calls `Lwt_unix.send_notification` (thread-safe, a no-op once the loop is gone; exceptions swallowed).
- `do_stop` checks `Lwt.state stop_t = Sleep` before `wakeup_later`, so a second stop (a signal, then the IPC call) is harmless.
- *Under OCaml 5:* an `Atomic` flag plus a wakeup fd, or a thread-safe promise resolver. Whatever is used must never block when the scheduler has exited.

**B-II.4 Concurrent unmount and drain (spec §6.2).** `let unmount_t = unmount mp in let* () = drain_for_stop [D.drain] in unmount_t`: the unmount promise starts before the drain is awaited. `drain_for_stop` races `Lwt_list.iter_p` of the drains against `Lwt_unix.sleep !Shutdown.grace` with `Lwt.choose`, and never cancels them, because a cancelled job would be recorded as a failure (`Lwt.Canceled` read as permanent by the metadata queue). *Under OCaml 5 (Eio-style):* `Fiber.both unmount drain`, where the drain is `Fiber.first (all drains) (sleep grace)` with the losing branch **detached, not cancelled**. Structured concurrency cancels by default, so the grace-race needs a daemon fiber or a switch outliving the race.

**B-II.5 Counters and flags without locks (spec §4.2).**
- `open_handles`, `files_opened`, `unmount_needed`, `stop_notification` and `Metrics` counters are plain `ref`s or ints, touched only on the loop thread (inside `on_loop`), so no lock is needed under Lwt.
- `statfs` is the exception: it runs on the worker thread with no `on_loop`, calling `Conf.capacity` → `Fs.disk_space` (a synchronous `statvfs` stub). It reads configuration only, so it touches no shared mutable state.
- *Under OCaml 5 with more than one domain:* the counters become `Atomic.t`. `unmount_needed` must be set before `do_stop` publishes the wakeup (an `Atomic.set` gives the ordering).

**B-II.6 Functor wiring (spec §4.2, §4.10).**
- `Fuse_fs.Make (C : Conf_lwt.S) (D : Domain_engine.Domain)` takes the file operations `D.F` and the request handler `D.Ih` from the domain.
- `Internal_ops.Make (F)` and `Hidden_ops.Make (C)` each build a `Path_ops.t`: a record of the eight dispatched ops (`mknod`, `fopen`, `read`, `write`, `release`, `unlink`, `rename`, `truncate`) returning `Lwt.t`. `dispatch path` picks one by basename.
- The record is the only abstraction and has exactly two implementations; it exists to keep the hidden/real split out of `fuse_fs.ml`.
- *Under direct style:* `Path_ops.t` becomes plain functions and the functors can become ordinary modules parameterised by a first-class domain value, since nothing is abstract over the monad any more.

**B-II.7 Background tasks.**
- `Lwt.async (Ipc_lwt.serve …)` and `Lwt.async (report_recorded_failures 0)`, with `Lwt.async_exception_hook` set to a logger before the loop starts.
- An exception raised **inside libev's dispatch** (seen: an SSL read) is outside any promise, so neither `Lwt.catch` nor the hook sees it. It escapes `Lwt_main.run` and is handled by `loop_died` (B-I.5).
- *Under OCaml 5:* supervised fibers in a switch. The "exception outside any fiber" case becomes an exception out of the scheduler's run function and gets the same fail-fast handling.

**B-II.8 Tray polling with nested `Lwt_main.run` (B4).** `Tray_poll.poll`, `stats` and `set_paused` each call `Lwt_main.run (Lwt_list.map_p ask ds)` from inside the synchronous libdbus loop, using `Ipc_lwt.send_lwt ~timeout` to bound each domain. The blocking `Ipc.send` has no timeout, so one wedged daemon would freeze the tray. *Under OCaml 5:* per-domain requests on a small thread pool with socket timeouts (`SO_RCVTIMEO`), or a fiber per domain under a timeout. The loop itself needs no scheduler.

## B-III. History worth knowing

| commit | what it settled |
|---|---|
| 22370770 | readdir dedup; `Revalidates` → `Notify` plus `invalidate_path` (fork ≥ a1ce3f8) |
| c099c4d7 | a stop with a held descriptor: lazy detach **and** `_exit` (either alone fails; the e2e test proves it) |
| 80a1f462 | a dead loop exits 1 instead of hanging for 47 minutes |
| deeb5204, c94929fe | never catch in handlers; the binding records and answers EIO |
| a35b9d24 | exactly one binding per FUSE process |
| 1f091af5 / 5396b942 / bac2b877 | no backend read under the mirror: getattr ENOENT went from 85 ms to 0.3 ms |
| b08c2d1f / 450efddc (PR fcbba236) | `subtype=sshfs` by default, discovery by `fsname=tsync` |
| 9d93eeee, c5d8b464, 57e9008b | Dolphin asks an in-process library, not the daemon; the library ships with `tsync`; the plugin is installed, not copied |

## B-IV. Where the current code differs from the spec

- **Process.** The FUSE process is a forked child of the launcher parent: it presents and runs its
  own upload and metadata queues, while the parent converges the domain and sends it `changed`
  notices. There is no ownership lock (see [../07-daemon-cli.md](../07-daemon-cli.md) B.4).
- **`rmdir` is recursive**: a non-empty directory is removed with its subtree; no ENOTEMPTY.
- **Rename flags are ignored**: `RENAME_NOREPLACE` overwrites, `RENAME_EXCHANGE` performs a plain
  rename. POSIX replacement rules between files and folders are not checked.
- **Hidden files lose content.** The hide rename moves `scratch(src)`, which does not exist for a
  domain file, then deletes the domain file; the holder's reads hit a missing scratch path. There
  is no retention in the file operations.
- **`fsync`, `flush`, `fsyncdir` succeed and do nothing**; nothing in the cache, staged tree or WAL
  is fsynced (finding F8). `O_SYNC` is not honoured.
- **Attributes**: a directory's mtime, ctime and atime are "now" on every getattr; a file's atime
  is "now".
- **No `default_permissions`**: with `allowOther` every local user can read, write and delete.
- **No `create` callback**: the kernel gets ENOSYS once and falls back to `mknod` + `open`. The
  `open(O_CREAT)` branch would discard staged edits if it were ever reached.
- **`link`, xattrs**: ENOSYS (the kernel reports EOPNOTSUPP for xattrs).
- **readdir** ignores the offset and returns the whole listing in one reply, with no per-handle
  snapshot; an already-open directory's listing can stay stale (only path invalidation is pushed).
- **Read-ahead** is shared by all readers of a key: `read` passes no stream id.
- **Kernel interrupts** are not handled; an offline read waits for the fetch's retry policy.
- **`auto_cache`** is passed but inert (every open replies `direct_io`); the direct-io mmap
  capability is not requested.
- **Start** runs `fusermount3 -uz <mount point>` unconditionally, whatever is mounted there.
- **`mountPoint`** is not tilde-expanded, not normalised, and unknown options are accepted (a typo
  mounts at the default). Discovery compares mount points as exact strings, so a trailing slash or
  a symlinked parent never matches.
- **Dolphin**: the share action has no deadline; restore and evict are synchronous requests.
- **Tray**: "Hold changes" pauses only the frontend's queues, in memory.
- **External unmount** ends the process and nothing restarts it.

## B-V. Conformance checks in the current test suite

| Spec §8 item | Test |
|---|---|
| subtype validation | `tests/unit/fuse_subtype` |
| store path, freshness from another client, share by ref and rel, `df -k`, stop with a held file | `tests/e2e/linux` and the shared checks in `tests/e2e/harness` |
| two mounts under load | `tests/e2e/stress` |
| no store read on a metadata path | `tests/content/absent_probe` |
| discovery library decode, longest prefix, sibling prefix | ctest against `libtsync_mounts_fake` |

Not covered today: the callback table, hidden files, invalidation, `statfs` figures other than the
unbounded case, and every POSIX item of spec §8 that the code does not implement.

## B-VI. Resource strategy

- The blocking-I/O pool of the FUSE process is sized as in [../07-daemon-cli.md](../07-daemon-cli.md)
  B.6; libfuse's worker count is its own default (`max_threads`, `max_idle_threads`), tsync sets no
  loop configuration.
