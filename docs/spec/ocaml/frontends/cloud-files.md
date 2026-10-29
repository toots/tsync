# The Windows host (Cloud Files frontend) — implementation notes

Companion to the language-neutral spec [../../frontends/cloud-files.md](../../frontends/cloud-files.md).
See [README.md](../README.md) for how these notes are organised. Section numbers in parentheses
refer to the spec.

Nothing of the Windows host is built yet. These notes say where each part goes in the existing
code and what is known to stand in the way.

## Where each part goes

| Spec | OCaml | C |
|---|---|---|
| Windows refusals (§2, 05 §2.1) | `lib/config`: the validator's per-host rules; `bin/` command dispatch for the refused commands | — |
| Files (§5.1) | `lib/core/fs.ml` keeps its interface | `lib/core/sys_stubs.c`: a `_WIN32` block beside the Linux and macOS ones (positioned reads and writes, locks, flush, POSIX rename and delete, reserve, free space, pid liveness, boot time); `malloc_trim`, `drop_mapped_pages` and `syncfs` no-ops |
| Exact names (§5.1, 01 §2.8) | `lib/checkout/mirror.ml`: the storable test and every lookup | a stub returning the on-disk name of a path |
| Processes (§5.2) | `lib/supervisor`: start children with `Unix.create_process`, stop them through their socket | job object, process groups, console and session-end handlers, the hidden window |
| Sockets (§5.3) | `lib/ipc` | access-list check of the data directory; peer SID from the peer pid |
| Keystore (§5.4) | `bin/platform.windows.ml`, selected in `bin/dune` like `platform.linux.ml` | Credential Manager stubs |
| The frontend (§6–§13) | `lib/frontends/cloud_files/`, an `(optional)` library selected into `lib/catalog` like `tsync_fuse` | the Cloud Filter API: register, connect, the callback table, transfers, placeholder calls, the recursive watch |
| Tray (§15) | `windows/tray/`, the Linux tray's refresh and actions over `lib/menu` | notification icon, popup menu, dialogs, clipboard |
| Installer (§14) | — | `windows/`: installer script, identity package manifest |

## What stands in the way

- **The scheduler's poller.** `vendor/duppy/pollset_stubs.c` has epoll and kqueue backends only. A
  Windows backend is needed that has no ceiling on sockets (07 §3.7): `select` is capped at
  `FD_SETSIZE` (64 by default). A port of wepoll (epoll over the AFD driver) fits the existing
  interface; `WSAPoll` works but is linear in the number of sockets.
- **AF_UNIX through `Unix`.** Windows has the sockets, but OCaml's `Unix` documentation does not
  promise `ADDR_UNIX` on native Windows. Confirm on the target OCaml and Windows before relying on
  it; otherwise a small stub binds and connects.
- **`Unix.rename` is not POSIX on Windows.** It replaces through `MoveFileEx`, which fails while
  the target is open. Every rename in owner state goes through the `_WIN32` stub of §5.1, never
  through `Unix.rename` directly.
- **Opening with delete sharing.** Without it a reader blocks a delete. `Unix.openfile` takes
  `O_SHARE_DELETE` on Windows; `Fs` passes it on every open.
- **Callbacks on system threads.** Cloud Filter callbacks arrive on a system pool. Each registers
  the thread with the OCaml runtime, submits to the scheduler and waits only on itself, as the FUSE
  workers do (07 §3.7). A stub that waits on the platform releases the runtime lock (README
  lesson 4).
- **Identity in tests.** The Platform tier registers a sync root, so the test binary needs package
  identity: the gate registers a test identity package whose external location is the build's
  output directory (10 §3.1).
- **Build.** The natural route is the Windows cross switch of opam-cross-windows, built on Linux;
  `tsyncd.exe` is the same `main` linked with `-subsystem windows`: `bin/` is the `tsync_cli`
  library with two entry points, and `tsyncd` passes the option to flexlink, which refuses
  `-mwindows`. A windowed process has no standard handles, so `Entry.main` puts the null device in
  each one Windows did not give (`Fs.std_handle_missing`): without it a print raises and
  `Unix.create_process` fails on the missing handle. The supervisor runs its owners as the
  `tsyncd.exe` beside it, which also keeps a console interrupt to the supervisor. The WinRT registration
  (`StorageProviderSyncRootManager`) is called from C through its COM interfaces, so no C++/WinRT
  toolchain is needed.
- **TLS.** Both implementations must read the Windows root stores (spec §5.4); check that the
  certificate loading of each does before shipping.
