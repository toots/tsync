# The macOS application (File Provider frontend) — OCaml implementation notes

Companion to the language-neutral spec [../../frontends/file-provider.md](../../frontends/file-provider.md). See [README.md](../README.md) for how these notes are organised.


Each note names the spec concept it implements. Section numbers in parentheses refer to the spec.

## B-0. Where the current code departs from the spec

The code at `4c32fa96` (Swift under `macos/`, OCaml under `lib/app/frontends/file_provider/` and the
parts of `lib/app/cli/runner/daemon/engine/ipc_handler.ml` that serve this client) differs from the
normative spec in these places. Each is a change to make, not a behaviour to preserve.

- **Ownership (§2).** The launchd agent runs the launcher parent, which converges every domain and
  forks a `file_provider` child serving `tsync.sock` (topology `One_process`). The parent sends
  `{"action":"changed","keys":[…]}` to the child after applying peer entries (`Change_notice`, 0.2 s
  flush, ≤ 512 keys per line). Under the spec the presenting process is the owner and converges its
  domains itself; the notice becomes an in-process call to the `changed` hook.
- **Router errors lack `code` (§4.2).** `error_json` in `file_provider.ml` emits only `ok`/`error` for
  "invalid JSON", "expected JSON object" and "cannot tell which domain". Swift maps a missing code to
  `internal` (`DaemonClient.swift`), so an unserved domain is retried forever with no explanation.
- **No client deadlines, unsynchronised state (§4.4).** `DaemonClient.swift` has no timeout of any
  kind; `sendSync` hands in a `CancellableSocket` nobody can cancel and is what the read-only probe
  uses from inside callbacks. `readOnlyAnswered` in `Extension.swift` is an unsynchronised `var`
  shared by concurrent tasks. The menu poll's `polling` latch (`StatusMenu.swift`) is never released
  by a hung request, so the menu freezes on its last state.
- **No path validation (§4.5).** `write`'s `staging` and `ensure_cached`/`fetch_range`'s `dest` are
  used as given (`ipc_handler.ml` around the write and fetch actions, `data.ml` adoption and assembly).
  `subscribe` carries no temporary directory.
- **`contentVersion` moves on publish (§6.3).** `Item.swift` uses `etag.isEmpty ? "size:mtime" :
  etag`; a write replies before upload with `etag:""`. There is no `contentId` in the row
  (`item_row.ml`), and adoption does not hash the body.
- **Creations are not exclusive; no `base` (§6.5).** `mkdir` answers an existing folder, `write`
  replaces, `rename` replaces. `modifyItem` ignores `baseVersion`.
- **Relay passes `root` raw (§8.2).** `SignalRelay.swift` builds `NSFileProviderItemIdentifier(ref)`
  directly, so evicting or restoring the root is a logged no-op on the replica while the owner answered
  `ok`. Evict/restore act on one key, not the subtree.
- **Relays exist only from app launch; one relay per domain found at launch (§8.2, §9.1).** A new
  domain needs an app restart (`Runtime.restart_service`).
- **Identifier collisions (§3.3).** `AppDelegate.swift` does not add a newly registered identifier to
  `surviving` inside its add loop; two names folding to one identifier reuse it. `Conf_parsing` does
  not refuse such configs.
- **Reset kills the daemon (§9.3).** `restart_app` runs `pkill -f /Applications/TsyncApp.app`, which
  also matches the agent's `…/MacOS/tsync start`. The daemon exits 0 on SIGTERM and
  `KeepAlive{SuccessfulExit=false}` does not restart it; `reset` never kickstarts. Invoked by its
  in-bundle path, the CLI kills itself. There is no `reset` event; the app only reads the marker at
  launch.
- **Stop (07).** `file_provider.ml`'s stop has `on_stop = ()`, runs `Lwt_list.iter_s drain` after the
  server returns, installs no signal handler and never requests `Shutdown`, so a stop with a store
  down can hang and SIGTERM kills without draining.
- **`preview` (dead).** The daemon still answers a `preview` verb (QuickLook thumbnail of an in-flight
  staged body, `preview_stubs.c`, `tests/frontends/preview`) that no client has sent since the menu
  moved into the daemon. The spec has no such verb; B4 and B16 describe code to delete.
- **Leftovers.** `DaemonRequest` declares `path` and `src`, `DaemonEvent` a `key`, that nothing uses.
  An OCaml comment points at `macos/TsyncFileProvider/IPC.swift`, now `Shared/DaemonClient.swift`.

## B-I. Runtime-independent OCaml learnings (valid under Lwt or OCaml 5 direct style)

**B1. Frontend registration by link-time side effect (§2, §9).**
`File_provider_frontend.register` calls `Frontend.register "file_provider"
~cli_group:"fileprovider" ~commands:[reimport; reset; purge]` with a first-class module
(`availability`, `tree = `Replicated`, `serving = Daemon {topology = `One_process;
listens = Some `Domain_socket; start}`). The library is `enabled_if (= %{system}
macosx)`; `lib/app/frontends/dune` uses `(select frontend_file_provider.ml from
(tsync_file_provider_frontend -> frontend_file_provider.enabled.ml) (->
frontend_file_provider.disabled.ml))`, so the registering module is linked only where the
library exists (the disabled file is empty). Keep this shape: a Linux build must not need
any Apple framework.

**B2. One process, many domains (§4.2).** Each `served` binding is instantiated as a
per-domain record `{name; handler; drain}`; a router dispatches on `domain` (or the only
runtime). The socket path is read from the first binding's conf — on macOS
`Runtime.domain_socket_path` ignores the domain, so all are equal.

**B3. `platform_stubs.c` — dataless flag (§3.4, availability).** `caml_is_dataless(path)`:
`stat(2)`, return `st.st_flags & SF_DATALESS` (Darwin flag on File Provider placeholders);
false on stat failure. `File_provider_frontend.availability`: path =
`cloud_storage_dir/<logical path>`; missing or dataless → `Online_only`; else
`Checkout.availability` with `Pinned` kept and anything else collapsed to `Cached`. It reads
the replica directly and never wakes fileproviderd.

**B4. `preview_stubs.c` — QuickLook from OCaml (dead code, see B-0).** Compiled as Objective-C with ARC
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

**B5. Error codes are a closed variant (§4.2, §4.3).** `Ipc_error.t` is a polymorphic variant
mapped once from exceptions (`of_exn`) and encoded once (`error_reply`); frontends that
answer IPC without the generic handler (http-proxy) reuse the encoder. Unknown exceptions
are `Internal`, never `Unreachable`. The `No_subscriber` exception has a registered
`Printexc` printer so the generic `Printexc.to_string` yields the user-facing hint.

**B6. Item references are a total parser over a closed variant (08 item references).**
``[`Root | `Dir of id | `File of id * leaf | `Bad of string]`` — parsing never raises;
`Bad` flows to a `not_found`/`invalid` reply. Mirrored by Swift `ItemID` and pinned by
`tests/unit/item_ref` + `ItemIDTests` against the same cases.

**B7. Build & packaging (§11).** `lwt`'s C part records `-lev` with no `-L`, so Homebrew's
lib dir must be on `LIBRARY_PATH` to link the daemon (any C-library dependency recorded
this way needs the same). `dylibbundler -cd -of -b -x tsync -d libs -p
@executable_path/../libs` rewrites install names of openssl, gmp, pcre2, libev, xxhash.
OCaml ≥ 5.5 from opam. The Swift half cannot be compiled on the Linux dev box (no swiftc):
state that in PRs and run the Xcode build + `TsyncTests` on the Mac before merging.

Bundle layout and signing, as `macos/build.sh`, `package.sh` and `RELEASING.md` do it:
```
TsyncApp.app/Contents
├── MacOS/TsyncApp                  app (LSUIElement: no Dock icon)
├── MacOS/tsync                     daemon + CLI (same binary)
├── libs/*.dylib                    install names @executable_path/../libs
├── Resources/install-agent.sh
└── PlugIns/TsyncFileProvider.appex
```
- Team ID `PSE2VP6582`. Sign inside-out after all injection: dylibs → daemon → appex (its effective
  entitlements) → app. Re-sign preserving the entitlements Xcode derived from the profile
  (`com.apple.application-identifier`), else the App Group breaks. Sandbox + App Group under Developer
  ID needs embedded provisioning profiles for both bundle ids. Hardened runtime and secure timestamp
  only with a real identity: ad-hoc signatures have no Team ID and library validation then rejects the
  bundled dylibs.
- `postinstall` (root) links `/usr/local/bin/tsync`, then as the console user runs `install-agent.sh`
  and `open -a` the app. `install-agent.sh` (never root) boots out the old agent, deletes a stale
  socket, writes the plist (`ProgramArguments=[…/tsync, start]`, `RunAtLoad`,
  `KeepAlive={SuccessfulExit:false}`, stdout/stderr → `~/Library/Logs/tsync-daemon.log`), enables and
  bootstraps it in `gui/<uid>`. `SMAppService.agent` for the daemon reports `.notFound` / "Operation
  not permitted" for a correctly placed, sealed, Team-ID-signed agent; `SMAppService.mainApp` works.
- Info.plist: `NSExtensionFileProviderDocumentGroup`, `SupportsEnumeration`,
  `AllowsUserControlledEviction`, no `DownloadPipelineDepth`, three custom actions with
  `TRUEPREDICATE` activation.
  `DownloadPipelineDepth` stays at the default because each extra concurrent range fetch costs the
  daemon a group read plus read-ahead, which buries slow stores.
- The subscriber queue holds 256 events per subscriber. The Swift client has no deadlines today (B-0);
  the spec now takes them from failure-model §8.2 with `ensure_cached`, `fetch_range` and `write` as
  bulk requests guarded by the liveness probe.
- Swift tests (`TsyncTests`) run against a real daemon started from `_build` with `HOME` redirected,
  a local store, and a short `/tmp/ts-xxxx` root because of the 104-byte socket path limit.

**B8. Process shape and signals (§2, §9.3).** `Launcher.run` forks one child per
frontend group before any event-loop state exists, then converges in the parent. A child
leases uplink capacity from the parent over `tsync-sync.sock` and asks it to rescan after
recording replica jobs. `pkill -f /Applications/TsyncApp.app` matches every process whose
command line contains that path, both daemon processes included — the cause of the
"daemon stays down after reset" gotcha given `KeepAlive{SuccessfulExit=false}` and a
clean SIGTERM exit.

**B9. Test harness (§14).** `tests/scenario/ipc` checks rendered JSON through
`<exe>.expected` snapshots with normalised `<mtime>`, `<folder-1>`, `<cursor>`, `<walk>`;
never substring asserts. `tests/frontends/preview` is `enabled_if macosx`. The macOS e2e
runner taps the domain socket (`Ipc_tap`) to see which verbs the extension sent — the only
evidence of partial vs whole-file fetching.

Where the §14 properties are checked today: Swift `TsyncTests` (`ItemIDTests`, `ItemTests`,
`DaemonProtocolTests` against a real daemon, `DaemonCancellationTests`, `ChangeBatchTests`,
`DaemonErrorTests`, `PartialRangeTests`, `CursorTests`); `tests/scenario/ipc` (`ipc.expected`: stat by
path, restore with keep → `pinned`+`pinnedUntil`, evict → `online-only`, paged `list_dir`/`list_all`,
`unnamed` counting, `changes_since` for put, mkdir+put, delete, rename, rmdir, a move into a folder
renamed since, dir rename, pruned and reimported anchors, a create under a storage-key parent refused,
a name containing `\n` in the kept walk); `tests/unit/item_ref` (mirrors `ItemIDTests`);
`tests/unit/ipc_serve`, `tests/unit/subs`; `tests/e2e/macos` (`make -C macos e2e`: the platform-neutral
E2e checks, the 4 KiB-at-20 MiB range read with zero `ensure_cached`, and `fileproviderctl check -a`).
Not covered today: content-version stability across upload, client deadlines, path validation,
router error codes, root evict/restore, reset keeping the daemon up, identifier collisions.

## B-II. Lwt / functor-specific learnings, and what they become under effects/domains

**B10. The NODELAY EINVAL accept-loop death (§4.1).** `Lwt_io.establish_server*` and
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

**B11. `Lwt.async_exception_hook` (§4.1).** Lwt's default hook exits the process on any
exception escaping `Lwt.async`; the frontend (and the converger) override it to log. Without
it one failed background notice killed the daemon and launchd's restart erased the
evidence. *Under effects*: the equivalent is a supervisor for detached fibers
(`Fiber.fork` with an exception handler / a switch whose failure is logged rather than
propagated to the main fiber). Decide explicitly, per detached task, whether its failure
is fatal.

**B12. The concurrency functor (§4.1, §8).** `Ipc.Make (Io) (Lock) (Clock) (Transport)`
keeps the IPC loop and subscriber registry independent of Lwt; `Ipc_lwt` binds it to
`Lwt_io`. What it bought: one implementation for the blocking CLI and the daemon loop, and
testability. What it cost: every caller threads `Io.t`, and the concurrency primitives
leak into the signature. *Under direct style* the functor collapses to plain functions over
a socket type; the blocking CLI and the daemon share code for free.

**B13. Race-freedom that came from cooperative scheduling (§8).** Several invariants
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

**B14. Mutation mutex (08 serialisation).** `Lwt_mutex.with_lock mutations` around the whole action body
for `mutating_actions`, *including reference resolution* (the rename race came from
resolving outside the mirror lock). *Under effects/domains*: a per-domain `Mutex` (or an
Eio mutex/semaphore of 1) held across the resolve **and** the mutation; with real
parallelism, also audit read paths that assumed a mutation could not be half-applied
between two binds.

**B15. Per-connection task, sequential per connection (§4.1).** `serve` spawns one Lwt
thread per accepted connection and serves its lines one by one; `Subscribe` hands the same
channels to the event writer, `Stop` wakes a promise the listener awaits (guarded against a
second wake, which raises in Lwt). *Under effects*: one fiber per connection; the "wake
twice raises" guard becomes an idempotent `Promise.resolve`/`Atomic` flag.

**B16. Blocking work off the loop (dead code, see B-0).** QuickLook runs under `Lwt_preemptive.detach`,
whose pool is capped by `Frontend.cap_blocking_pool` (sized per frontend's bindings), and
the C stub releases the runtime lock. *Under domains*: run it on a dedicated domain or a
bounded thread pool; the 10 s C-side timeout remains necessary because a hung generator
still occupies a pool slot.

**B17. Timeouts (§4.4).** The daemon-side client `Ipc.Make.send` wraps a request in
`Clock.with_timeout 2.` (used by the converger's change notices, 1 s for rescans). The Swift
client has none (B-0). *Under effects*: a cancellation-aware timeout (switch/cancel
context) around the whole connect-write-read, not just the read.

## Pitfalls met in the rewrite

- **A throwing Swift initializer still runs `deinit`** once every stored property is set. A
  descriptor closed before the `throw` is closed again by `deinit`, and that second close can hit a
  number another thread just reused (a request socket, a manager's descriptor). The relay retries a
  subscription every few seconds while the service is down, so this fires often. Close in one place:
  `deinit`, or mark the descriptor invalid before throwing.
