# The macOS application (File Provider frontend) — OCaml implementation notes

Companion to the language-neutral spec [../../frontends/file-provider.md](../../frontends/file-provider.md). See [README.md](../README.md) for how these notes are organised.


Each note names the spec concept it implements.

## B-I. Runtime-independent OCaml learnings (valid under Lwt or OCaml 5 direct style)

**B1. Frontend registration by link-time side effect (A2, A8).**
`File_provider_frontend.register` calls `Frontend.register "file_provider"
~cli_group:"fileprovider" ~commands:[reimport; reset; purge]` with a first-class module
(`availability`, `tree = `Replicated`, `serving = Daemon {topology = `One_process;
listens = Some `Domain_socket; start}`). The library is `enabled_if (= %{system}
macosx)`; `lib/app/frontends/dune` uses `(select frontend_file_provider.ml from
(tsync_file_provider_frontend -> frontend_file_provider.enabled.ml) (->
frontend_file_provider.disabled.ml))`, so the registering module is linked only where the
library exists (the disabled file is empty). Keep this shape: a Linux build must not need
any Apple framework.

**B2. One process, many domains (A4.2).** Each `served` binding is instantiated as a
per-domain record `{name; handler; drain}`; a router dispatches on `domain` (or the only
runtime). The socket path is read from the first binding's conf — on macOS
`Runtime.domain_socket_path` ignores the domain, so all are equal.

**B3. `platform_stubs.c` — dataless flag (A3, availability).** `caml_is_dataless(path)`:
`stat(2)`, return `st.st_flags & SF_DATALESS` (Darwin flag on File Provider placeholders);
false on stat failure. `File_provider_frontend.availability`: path =
`cloud_storage_dir/<logical path>`; missing or dataless → `Online_only`; else
`Checkout.availability` with `Pinned` kept and anything else collapsed to `Cached`. It reads
the replica directly and never wakes fileproviderd.

**B4. `preview_stubs.c` — QuickLook from OCaml (A10).** Compiled as Objective-C with ARC
(`(flags (-x objective-c -fobjc-arc))` on its own `foreign_stubs` stanza) so the request and
the completion block need no manual release; `c_library_flags` link
`QuickLookThumbnailing ImageIO CoreGraphics Foundation`. Traps:
- `strdup` the path **before** `caml_release_runtime_system()` (the heap may move while
  the runtime lock is released); reacquire before allocating the result string.
- The generator completes asynchronously on its own queue: wait on a
  `dispatch_semaphore` with a **10 s timeout**, because the calling thread belongs to a
  bounded worker pool and a generator that never answers would pin it forever. On timeout
  the block may still fire later and retain an image nobody releases (small leak, accepted).
- `@autoreleasepool` around the Cocoa work: worker threads have no pool.
- Return `""` for "no picture" instead of raising; the OCaml wrapper maps `""` → `None`.
- Ask for `QLThumbnailGenerationRequestRepresentationTypeThumbnail` only; `All` falls back
  to a generic icon, which the caller would rather know as "nothing".
- A uuid-named body gets a **hard link** with the item's extension
  (`<cache_root>/previews/<pid>-<counter><ext>`), removed in `Fun.protect ~finally`; a
  symlink does not work because generators resolve it back to the uuid.

**B5. Error codes are a closed variant (A4.2).** `Ipc_error.t` is a polymorphic variant
mapped once from exceptions (`of_exn`) and encoded once (`error_reply`); frontends that
answer IPC without the generic handler (http-proxy) reuse the encoder. Unknown exceptions
are `Internal`, never `Unreachable`. The `No_subscriber` exception has a registered
`Printexc` printer so the generic `Printexc.to_string` yields the user-facing hint.

**B6. Item references are a total parser over a closed variant (A4.3).**
``[`Root | `Dir of id | `File of id * leaf | `Bad of string]`` — parsing never raises;
`Bad` flows to a `not_found`/`invalid` reply. Mirrored by Swift `ItemID` and pinned by
`tests/unit/item_ref` + `ItemIDTests` against the same cases.

**B7. Build & packaging (A11).** `lwt`'s C part records `-lev` with no `-L`, so Homebrew's
lib dir must be on `LIBRARY_PATH` to link the daemon (any C-library dependency recorded
this way needs the same). `dylibbundler -cd -of -b -x tsync -d libs -p
@executable_path/../libs` rewrites install names of openssl, gmp, pcre2, libev, xxhash.
OCaml ≥ 5.5 from opam. The Swift half cannot be compiled on the Linux dev box (no swiftc):
state that in PRs and run the Xcode build + `TsyncTests` on the Mac before merging.

**B8. Process shape and signals (A2, A8, A16.3).** `Launcher.run` forks one child per
frontend group before any event-loop state exists, then converges in the parent. A child
leases uplink capacity from the parent over `tsync-sync.sock` and asks it to rescan after
recording replica jobs. `pkill -f /Applications/TsyncApp.app` matches every process whose
command line contains that path, both daemon processes included — the cause of the
"daemon stays down after reset" gotcha given `KeepAlive{SuccessfulExit=false}` and a
clean SIGTERM exit.

**B9. Test harness (A14).** `tests/scenario/ipc` checks rendered JSON through
`<exe>.expected` snapshots with normalised `<mtime>`, `<folder-1>`, `<cursor>`, `<walk>`;
never substring asserts. `tests/frontends/preview` is `enabled_if macosx`. The macOS e2e
runner taps the domain socket (`Ipc_tap`) to see which verbs the extension sent — the only
evidence of partial vs whole-file fetching.

## B-II. Lwt / functor-specific learnings, and what they become under effects/domains

**B10. The NODELAY EINVAL accept-loop death (A4.1).** `Lwt_io.establish_server*` and
`Lwt_io.open_connection` set `TCP_NODELAY` on every socket unless
`~set_tcp_nodelay:false`, tolerating only `EOPNOTSUPP`. macOS answers `EINVAL` on an
`AF_UNIX` socket whose peer has already hung up; the exception escaped Lwt's accept loop
and the server was dead while the process lived: `tsync status` hung, Finder hung, the
extension stalled, and the log's only trace was `file-provider: async exception:
Unix.Unix_error(Unix.EINVAL, "setsockopt", "")`. It presented as a File Provider deadlock.
Fix: `~set_tcp_nodelay:false` in both `connect` and `serve` (`lib/lwt/core/ipc_lwt.ml`,
d8f854af). Linux never shows it. Recovery: `launchctl kickstart -k
gui/$(id -u)/org.feverdreamtv.tsync.daemon`, then accept the TCC prompt.
*Under direct style*: the library trap disappears with Lwt_io, but the lesson stays — the
accept loop must survive any per-connection failure (setsockopt, accept `ECONNABORTED`,
`EMFILE`): catch per accepted socket, never let one client's error end the listener, and
never set TCP options on unix sockets.

**B11. `Lwt.async_exception_hook` (A7).** Lwt's default hook exits the process on any
exception escaping `Lwt.async`; the frontend (and the converger) override it to log. Without
it one failed background notice killed the daemon and launchd's restart erased the
evidence. *Under effects*: the equivalent is a supervisor for detached fibers
(`Fiber.fork` with an exception handler / a switch whose failure is logged rather than
propagated to the main fiber). Decide explicitly, per detached task, whether its failure
is fatal.

**B12. The concurrency functor (A4.1, A6).** `Ipc.Make (Io) (Lock) (Clock) (Transport)`
keeps the IPC loop and subscriber registry independent of Lwt; `Ipc_lwt` binds it to
`Lwt_io`. What it bought: one implementation for the blocking CLI and the daemon loop, and
testability. What it cost: every caller threads `Io.t`, and the concurrency primitives
leak into the signature. *Under direct style* the functor collapses to plain functions over
a socket type; the blocking CLI and the daemon share code for free.

**B13. Race-freedom that came from cooperative scheduling (A6, A7).** Several invariants
hold only because Lwt never yields between two statements without a bind:
- `Subs.write_pending`: "nothing yields between the empty check and the wait", so a
  publish cannot slip in and leave the writer asleep on a non-empty queue.
- The `changed` debounce (`ref bool` test-and-set + `Lwt.async (sleep 0.2 → publish)`),
  `Change_notice` (0.2 s, a `Hashtbl` used as a set, chunks of 512) and `ask_rescan`
  (0.5 s) all mutate shared state with no lock.
- `Subs.publish` mutates per-subscriber `Queue.t`s and the subscriber list with no lock;
  `event_seq` is a plain `ref`.
- The kept `list_all` walk is written with `atomic_write` but read by concurrent requests
  with no coordination beyond the rename.
*Under effects with a single domain* these still hold if the scheduler only switches at
effect points, but the monad no longer marks where a yield can happen, so a later edit that
adds an I/O call between the check and the wait silently breaks it — make the critical
sections explicit (a mutex/condition pair). *With multiple domains* every item above is a
data race and needs `Mutex`/`Atomic`/`Condition`.

**B14. Mutation mutex (A7).** `Lwt_mutex.with_lock mutations` around the whole action body
for `mutating_actions`, *including reference resolution* (the rename race came from
resolving outside the mirror lock). *Under effects/domains*: a per-domain `Mutex` (or an
Eio mutex/semaphore of 1) held across the resolve **and** the mutation; with real
parallelism, also audit read paths that assumed a mutation could not be half-applied
between two binds.

**B15. Per-connection task, sequential per connection (A4.1).** `serve` spawns one Lwt
thread per accepted connection and serves its lines one by one; `Subscribe` hands the same
channels to the event writer, `Stop` wakes a promise the listener awaits (guarded against a
second wake, which raises in Lwt). *Under effects*: one fiber per connection; the "wake
twice raises" guard becomes an idempotent `Promise.resolve`/`Atomic` flag.

**B16. Blocking work off the loop (A10).** QuickLook runs under `Lwt_preemptive.detach`,
whose pool is capped by `Frontend.cap_blocking_pool` (sized per frontend's bindings), and
the C stub releases the runtime lock. *Under domains*: run it on a dedicated domain or a
bounded thread pool; the 10 s C-side timeout remains necessary because a hung generator
still occupies a pool slot.

**B17. Timeouts (A4.1).** The daemon-side client `Ipc.Make.send` wraps a request in
`Clock.with_timeout 2.` (used by the converger's change notices, 1 s for rescans). The Swift
client has none (A16.7). *Under effects*: a cancellation-aware timeout (switch/cancel
context) around the whole connect-write-read, not just the read.
