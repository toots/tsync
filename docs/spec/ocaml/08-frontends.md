# 08 — Frontends — OCaml implementation notes

Companion to the language-neutral spec [../08-frontends.md](../08-frontends.md). See [README.md](README.md) for how these notes are organised.
Notes specific to one frontend are in [fuse](frontends/fuse.md), [http-proxy](frontends/http-proxy.md), [file-provider](frontends/file-provider.md), [android](frontends/android.md). Some of them are also summarised below from the first extraction.



## B1. Runtime-independent learnings

**Frontend registry by link-time selection (spec §2.1).**
- Each frontend has `frontend_<x>.enabled.ml` (`let () = X.register ()`) and an empty `.disabled.ml`.
- dune `(select … from (lib -> enabled) (-> disabled))` picks one, and the umbrella library uses `(library_flags (-linkall))` so the side effects are kept.
- The FUSE library is `(optional)`, so it silently disappears when `fuse3` is not installed. Per the user's verification rule, something must fail when an intended frontend is missing: the e2e suite, or `Launcher.resolve`'s "configured but not compiled into this binary".
- File Provider uses `(enabled_if (= %{system} macosx))`.
- Android is built only in the `default.android` cross context.

**Dolphin → OCaml through a shared object (spec fuse.md B1).**
- `linux/dolphin/ml/libtsync_mounts.ml` does `Callback.register "tsync_mount_points" Desktop_mounts.mount_points`, of type `unit -> (string * string) list`.
- C++ calls `caml_startup({"tsyncdolphin",NULL})` once, from one thread; then `caml_named_value` + `caml_callback(Val_unit)`; then walks the list (`Field(list,0)` is the pair, `Field(pair,0/1)` the strings) and converts with `QString::fromUtf8(String_val)`.
- Measured: 1.4 ms for the first call including runtime start, 141 µs after that. Stripped size is 2.48 MB, of which 1.79 MB is the runtime floor.
- Three traps, each of which looks like something else:
  1. `(modes object)` links the runtime without `-fPIC`, and the linker rejects it inside a `.so` on aarch64 (`R_AARCH64_ADR_PREL_PG_HI21`). It must be `(modes shared_object)`, which produces two files.
  2. dune sets no SONAME. Add `(link_flags (-cclib -Wl,-soname,libtsync_mounts.so))` **and** name the executable to match. A mismatch fails at run time ("cannot open shared object file"), not at link time.
  3. An exception crossing into C aborts the host process (Dolphin). The registered closure must be total; `mount_points` catches everything and returns `[]`.
- Test the C++ decoding against a second `shared_object` (`libtsync_mounts_fake`) that registers the same name with fixed answers, not against whatever is mounted.
- Install with cmake components, so the plugin's RPATH is rewritten to `${libdir}/tsync`. CI asserts that no `_build` RPATH remains and that `ldd` resolves the library.
- KDEInstallDirs must be included after `find_package(Qt6)`.

**Android embedding (the app side is specified in android.md).**
- `libtsyncjni.so` is `(executable (modes shared_object))` with soname `libtsyncjni.so`, 16 KB page alignment (Android 15), `-llog`, and `-L<stdlib>/..` for libev.
- On the first call: `setenv HOME`, `setenv SSL_CERT_FILE` (conduit builds its authenticator at module init, so this must be set before `caml_startup`), then `caml_startup`.
- Foreign threads: on first entry, `caml_c_thread_register` (abort if it returns 0), recorded in a pthread key; then `caml_acquire_runtime_system` / `caml_release_runtime_system` around each call. The key's destructor unregisters foreign threads only. This is modelled on the fuse3 binding's `Fuse_util.c`.
- Text crosses as `byte[]` of UTF-8. JNI's modified UTF-8 cannot carry non-BMP characters, and `NewStringUTF` aborts on them.
- `read` fills an OCaml Bigarray and copies it out with `SetByteArrayRegion` while still holding the runtime lock. `GetPrimitiveArrayCritical` is avoided.
- Every callback is total: a `Unix_error` becomes −errno (ENOENT 2, EIO 5, EBADF 9, EACCES 13, ENOSPC 28, anything else 5); any other exception becomes −5 or an `internal` reply.
- A domain cannot be reopened in-process after a config change: the app restarts its process.

**File Provider C stubs.**
- `caml_is_dataless` (platform_stubs.c) checks the dataless flag of a replica path.
- `caml_preview_thumbnail` (preview_stubs.c) is Objective-C compiled with `-x objective-c -fobjc-arc`, linking QuickLookThumbnailing, ImageIO, CoreGraphics and Foundation. It returns `""` for "no picture".
- QuickLook types a file by its extension, and a staged body is named by uuid. So the body is **hard-linked** to `<cache_root>/previews/<pid>-<n><ext>`: a symlink is resolved back to the uuid name by the generators. The previews directory sits under the cache root so the link lands on the same filesystem.

**FUSE binding (ocaml-fuse3, a binding of its own).**
- Handlers run on libfuse worker threads (`Multi_threaded`).
- The binding records any exception that is not a `Unix_error` into a ring (`Fuse.recent_errors`, `error_count`, entries with a `ticket`) and answers EIO. `Fuse.set_backtrace_capture true` is worth its allocation: an `Invalid_argument` from a `String.sub` otherwise names neither the file nor the caller.
- `Fuse.invalidate_path` wraps the high-level invalidation; "not cached" maps to success and any other failure raises `Unix_error` ([frontends/fuse.md](frontends/fuse.md) B-I.2).
- `Fuse.main` holds the main thread until the connection drops.
- Other details: `fi_update_direct_io = true` on open; `rename_flags` are ignored; `statfs` returns a record from `Unix_util`.

**Process shutdown.**
- `Unix._exit` (not `exit`) is used after a completed FUSE stop and when the event loop dies: `at_exit` handlers would drain through a loop that no longer exists.
- Frontends set `Lwt.async_exception_hook` to log instead of the default, which exits the process on a background error.

**Wire helpers.** `Http_proxy.Auth` uses Digestif SHA256, HMAC and `Eqaf.equal` for the constant-time compare. It hashes the body from the Bigstring directly, so a chunk-sized body is never copied onto the heap. Keys use `Base64.uri_safe_alphabet ~pad:false`. Share assets (`mime.json`, `browse.html`, `player.js`) and `stats.html` are embedded with `[%blob …]` from the Lambda's own files, giving one definition across both deployments.

## B2. Lwt- and functor-specific learnings

**Shape of the seam.** In the implementation, the domain wiring is a first-class module:

```ocaml
module type Domain = sig
  module F : File_ops.S with type 'a io := 'a Lwt.t
  module Ih : Ipc_handler.S
  val start : ?on_upload_done:(key:Logical_key.t -> unit Lwt.t) -> unit -> unit Lwt.t
  val drain : unit -> unit Lwt.t
  val stats_fields : unit -> (string * Yojson.Safe.t) list
end
```

- A binding carries `(module Conf_lwt.S)`.
- `Domain_engine.Make_over (Checkout) (C)` picks the tree, and Android passes `Lazy_checkout_lwt`. `Fuse_fs.Make (C) (D)` and `File_provider.Make (C) (D)` are functors over it.
- Under direct style, the same seam is a record or object of functions; the functor bought nothing except the `'a io` abstraction.

**Scheduler bridging (spec 07 §3.7).**
- `Domain_engine.on_loop f = Lwt_preemptive.run_in_main (fun () -> Lwt.catch f wrap)`. Exceptions other than `Unix_error` are wrapped in `With_backtrace (exn, raw_bt)`, because `run_in_main` re-raises on the calling thread and would otherwise replace the backtrace with its own line. `Unix_error` is matched first: it is an answer, and ENOENT on getattr is the hot path.
- `Domain_engine.run ?main_thread ?after serve` runs `Lwt_main.run` on a `Thread`. A mutex/condition handshake makes the main thread wait for `ready` before entering `Fuse.main`. If `serve` returns without calling `ready`, `ready` is signalled anyway, or the main thread would hang with nothing logged.
- `start_detached` does the same with no join. On Android the serve body ends in `fst (Lwt.wait ())` to keep the loop alive.
- **Stopping from the main thread** uses `Lwt_unix.make_notification` / `send_notification`, which is safe from any thread and a no-op once the loop is gone. It cannot use `on_loop`, which blocks until the loop picks up the job; a finished loop never does.
- **Under effects/domains:** foreign threads would submit to a scheduler domain through a channel and wait on a promise. The places listed in spec 07 §7 as relying on cooperative atomicity (FUSE counters, proxy gate removal, debounce flags, handle table, memo) need `Atomic` or a mutex once any of them can be touched from more than one domain. The monad no longer marks yield points, so the invariant "no await between these two lines" (the watch gate's removal, the `waiters` increment followed by `start_watching`) must be enforced by a lock rather than by reading the code.

**Event loop engine and fork.**
- `use_libev ()` fails when `Lwt_sys.have \`libev` is false. The default `select` engine cannot watch fds ≥ FD_SETSIZE (1024 on macOS), and once `Descriptors` raises the fd limit, one high descriptor raises EINVAL and kills the loop. `conf-libev` being installed does not prove Lwt was built with it, so this is checked at run time.
- `cap_blocking_pool` must be called **after all forking**, inside the leaf: the first `Lwt_unix` touch creates the notification eventfd.
- Forks use `Lwt_unix.fork` (which reinitialises notifications in the child), never `Unix.fork`.
- `fork_each` iterates explicitly in order: `List.map`'s evaluation order is unspecified, and these are forks. `Diagnostics.restart ()` runs once in each child so uptime is its own.
- **Under effects/domains:** the fork-before-runtime rule stays; forking after domains are spawned is unsafe. The fixed ceiling on the blocking pool becomes a bound on system threads used for blocking syscalls.

**Lwt-flavoured concurrency bounds.**
- `Io_lwt.Bounded` pools: proxy objects (`max`, `max_waiting = 16×max`, `use_or ~busy` → 503); proxy batch reads (shared); share read slots (16, no `max_waiting`, taken **before** the buffer is allocated).
- Handler mutation serialization is an `Lwt_mutex`.
- The watch uses `Lwt_condition` plus `Lwt.pick [wait; sleep left]` in a loop that re-checks `differs`.
- **Under effects/domains:** these become semaphores with an optional queue bound; the "slot before buffer" rule carries over unchanged.

**Drain racing.** `drain_for_stop` uses `Lwt.choose [drained; sleep grace]` and deliberately does **not** cancel: cancelling an Lwt promise fails the job, and the queue would record a failure. Under effects this means leaving the fibers running rather than cancelling them, and exiting.

**Async exceptions.** In the FUSE and http-proxy processes, `Lwt.async` background loops (the failure reporter, watch loops, change debouncers) set `Lwt.async_exception_hook` to a logger. Separately, an exception escaping `Lwt_main.run` itself (an SSL read raising inside libev dispatch) is fatal by design: the process logs it and calls `_exit 1`.

## B3. Mapping to the current code

| Spec concept | Current code |
|---|---|
| descriptor, registry | `lib/app/frontends/api/frontend.ml` |
| request handler | `lib/app/cli/runner/daemon/engine/ipc_handler.ml` (`Ipc_handler.Make (C) (F) (Sq) (Pause)`) |
| item rows, codes | `item_row.ml`, `ipc_error.ml` |
| references | `lib/core/item_ref.ml` |
| domain wiring | `Domain_engine.Domain` (first-class module; `Make_over (Checkout) (C)`) |

## B4. Where the current code differs from the spec

- **Hooks.** The hook record is `evict`, `restore ?keep`, `changed`, `full_resync`, `status_fields`,
  `stats_fields`, `on_stop`, and the hooks do the chunk-store work themselves: FUSE walks the subtree
  (`on_subtree`), Android acts on one key, so "make available offline" on an Android folder does
  nothing and reports success (finding H11). File Provider's `on_stop` is a no-op.
- **Codes.** `busy` and `paused` do not exist; the File Provider router's own errors omit `code`.
- **Transfer paths.** `dest` and `staging` are accepted anywhere the daemon can write (security
  finding S6).
- **rename** has no `noreplace`; **delete** of a folder is not refused.
- **Actions.** `changed` is an action sent by the launcher parent; there is no `sync`, `prune`,
  `poll`, `job` or `detach`; `rescan` goes to the sync socket. `evict` and `restore` reply `{}`.
- **Pause** is accepted without persistence and does not refuse `revert` or `share`.
- **Order.** The File Provider enumerator is not told that only name order is served.

## B5. Conformance checks in the current test suite

`tests/scenario/ipc` (rows, listings, paging, `unnamed`, storage-key parents, change feed ops, restore
and evict availability), `tests/unit/item_ref`, `tests/unit/menu`, `tests/frontends/presenting_domain`,
`tests/frontends/stop_publishes_cursor`. Not covered: transfer-path refusal, `noreplace`, subtree
evict/restore on every frontend, codes on router errors.
