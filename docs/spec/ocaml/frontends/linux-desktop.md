# Linux desktop clients — OCaml and build notes

Notes on how the implementation on `main` built what
[../../frontends/linux-desktop.md](../../frontends/linux-desktop.md),
[dolphin.md](../../frontends/dolphin.md), [linux-tray.md](../../frontends/linux-tray.md) and
[menu-model.md](../../frontends/menu-model.md) specify. Descriptive, not normative: it predates
that text, and where the two differ the spec is what to build. Its largest departures: one loop
served the bus and polled the owners, so the bus waited during a poll; the plugin's click actions
had no deadline; `EventGroup` was answered without acting.

## 1. Where things are

| piece | location on `main` | language |
|---|---|---|
| mount discovery | `lib/local/desktop_mounts` | OCaml, Linux only |
| discovery as shared objects | `linux/dolphin/ml` (real and fake) | OCaml |
| plugin | `linux/dolphin` | C++17, Qt 6, KF6, built by CMake |
| menu model | `lib/app/ui/menu` | OCaml, no dependency on D-Bus or a toolkit |
| tray | `linux/tray` (`sni`, `dbusmenu`, `tray_poll`, `tray`, `main`) | OCaml |
| D-Bus binding | `linux/tray/dbus` | OCaml over libdbus-1 C stubs |

The tray is its own opam package (`tsync-tray`, Linux only) so that the libdbus dependency
(`conf-dbus`) stays off the main package.

## 2. OCaml inside a C++ host (the discovery library)

- Built as a dune `executable` with `(modes shared_object)`. `(modes object)` links the runtime
  without `-fPIC`, which a shared library cannot hold (on aarch64 the link fails on
  `R_AARCH64_ADR_PREL_PG_HI21`).
- dune sets no SONAME and names the output after the executable. The SONAME is set by a link flag
  and the executable is named to match; a mismatch fails at load time with "cannot open shared
  object file", not at link time.
- The entry point is `Callback.register "tsync_mount_points"`. The host calls `caml_startup` once
  with a made-up `argv`, looks the closure up with `caml_named_value`, calls it with
  `caml_callback`, and walks the list copying each string out. Nothing on the host side allocates
  on the OCaml heap during the walk, so the list is not registered as a root.
- The registered closure is total: it wraps everything and answers the empty list. An exception
  crossing the boundary aborts the host process.
- The runtime is started from the thread that draws the menu and only ever called from it.
- Measured in a real file manager: 1.4 ms for the first call including runtime start, 141 µs after.
  Stripped size 2.48 MB, of which 1.79 MB is the runtime.
- The CMake build takes the path of the real and fake objects as variables, asks `ocamlc -where`
  for the headers, links the plugin against the real object and the test against the fake one, and
  installs in two components (`plugin`, `rules`) because the halves ship in different packages.

## 3. The D-Bus binding

- Only what the two protocols need: a private session connection, name requests, match rules,
  message construction, send, blocking call, `read_write` + `pop_message`.
- **No library dispatch.** libdbus's dispatch answers any call no registered handler claimed with
  an automatic `UnknownMethod`; using it means either C vtables calling back into OCaml or racing
  the library's replies. The queue is taken raw and routed in OCaml, which then owes a reply to
  every call.
- **The value recursion lives in OCaml.** A variant type covers the D-Bus types
  (`Array of signature * value list`, `Struct`, `Variant`, `Dict`); the C side offers iterator
  handles only. An array carries its element signature because an empty array must still be typed.
  Only a variant passes an explicit signature when its container is opened.
- **Iterators are malloc'd**, not embedded in the custom block: OCaml 5 moves custom blocks, and
  libdbus writes through the iterator's address at close time, long after it was opened. Each
  iterator holds a reference on its message.
- Blocking calls (`send_with_reply_and_block`, `read_write`) release the runtime lock.
- A signature string is copied out before allocating, since allocation can move it.
- Header accessors answer `""` where libdbus answers NULL.
- The stubs keep the standard C flags (they carry `-fPIC`); the include path comes from
  `pkg-config --cflags dbus-1`, since `dbus-arch-deps.h` sits in a per-distro, per-architecture
  directory.

## 4. Lwt inside the tray's loop

The loop is a plain blocking loop over the bus. Each poll, stats fetch and pause runs
`Lwt_main.run` over the parallel requests and returns: Lwt is used only for the timed, concurrent
socket round trips (`Ipc_lwt.send_lwt ~timeout`), not as the process's scheduler. The blocking
client (`Ipc.send`) has no timeout, which is why it is not used.

Consequence for a move to effects or domains: the tray needs "N requests at once, each with a
deadline, wait for all", and nothing else of a scheduler. A bus read that is itself an event source
would remove the 250 ms tick and the blocking of the bus during a poll.

## 5. State kept by structural equality

The dbusmenu module decides "this row did not change" and "this menu did not change" by structural
equality on the model's entries. That is what lets ids survive a poll. A model type that gained a
closure or a cyclic value would break it at run time.

## 6. Development launcher

`linux/tray/tsync-tray` runs the tray through `dune exec` from the repository root. It is not
installed.
