# Linux desktop clients — OCaml and build notes

How this tree builds what [../../frontends/linux-desktop.md](../../frontends/linux-desktop.md),
[dolphin.md](../../frontends/dolphin.md), [linux-tray.md](../../frontends/linux-tray.md) and
[menu-model.md](../../frontends/menu-model.md) specify. Descriptive, not normative: where this and
the spec differ, the spec is what to build.

## 1. Where things are

| piece | location | language |
|---|---|---|
| menu model | `lib/menu` (`Tsync_menu.Menu_model`) | OCaml; depends on `tsync_core` for the byte formatter and on nothing else |
| mount discovery | `lib/config/mounts.ml` (`Tsync_config.Mounts`) | OCaml |
| discovery as shared objects | `linux/mounts` (`libtsync_mounts.so`, `libtsync_mounts_fake.so`) | OCaml, `(modes shared_object)` |
| host side of the discovery library | `linux/mounts/tsync_mounts.h`, `tsync_mounts_host.c` | C, compiled into each host |
| D-Bus binding | `linux/tray/dbus` (`Tsync_dbus.Dbus`) | OCaml over libdbus-1 C stubs |
| tray | `linux/tray` (`Bus`, `Layout`, `Tray`, the `tsync_tray` executable) | OCaml |
| plugin | `linux/dolphin` | C++20, Qt 6, KF6, built by CMake |
| owner doubles | `tests/desktop/owner_double.ml` | OCaml, plain threads |

The tray is its own opam package (`tsync-tray`, Linux only) so that libdbus (`conf-dbus`, a package
of this repository: opam's has none) stays off the main one. Everything under `linux/` is outside
the default alias: a plain `dune build` does not need libdbus, `dune build @runtest` does.

## 2. The menu model

- One module, two functions (`render`, `stats`), the formatters, and the JSON form.
- **Inputs are abstract types read from the wire.** `status` and `stats` are records derived with
  `ppx_deriving_yojson` over the reply's own shape, and the interface exposes only
  `status_of_json` and `stats_of_json`. A caller holding a typed reply (the shared owner of the
  macOS service) encodes it with the owner's codec and reads it back through the model's, so that
  there is one reader and the field names are checked against a real reply by `shared_test`.
- **Leniency per field.** menu-model §2 wants a field of the wrong type to read as absent, where a
  derived record reader fails the whole record. Each leaf is a type alias with a reader that never
  fails (`count`, `number`, `text`, `flag`), each nested record is read through `lenient` and each
  list through `items`, which drops what does not parse. Every field carries `[@default]`, so the
  empty object reads.
- The JSON form goes out through a derived record (`wire_item`), whose `[@default]` fields are left
  out when unset; the action is the one hand-written encoder, since a derived variant would not
  give the one-key object of §7.
- `Narrate.size` is the byte formatter of §3, and the only one.

## 3. Mount discovery

- `Mounts.mount_points` is the whole of linux-desktop §3.2 and is total by one `try … with _`.
- The config is read by the core's parser, so the library links the whole catalog: a config
  naming a driver no linked library registered would be refused, and discovery would answer
  nothing for a valid config. The cost is the size of `libtsync_mounts.so` (22 MB, 14 MB
  stripped) and its needing libssl, libfuse3 and libgmp, which the `tsync` package that ships it
  depends on already.
- Measured under a C host: 3.4 ms for the first call, runtime start and the initialisers of every
  linked module included; 90 µs after. Starting it changes no signal disposition, signal stack,
  locale, directory or environment variable, and starts no thread (`linux/mounts/test`).
- `Mounts.canonical` resolves a parent one component at a time and stops at a tsync mount point
  before `lstat`ing it; `Fs.resolve_parent`, which the owner uses for its own mount point, calls
  `realpath` and may look anywhere. The two agree on every path that crosses no tsync mount.
- The FUSE frontend takes its configured mount point and its mount-table decoding from this
  module.

## 4. OCaml inside a C++ host (the discovery library)

- A dune `executable` with `(modes shared_object)`. `(modes object)` links the runtime without
  `-fPIC`, which a shared library cannot hold (on aarch64 the link fails on
  `R_AARCH64_ADR_PREL_PG_HI21`).
- dune names the output after the executable and records no SONAME. The SONAME is set by a link
  flag and the executable is named to match; a mismatch fails at load time with "cannot open
  shared object file", not at link time. `linux/mounts/test` links by name and runs, which is the
  check.
- The entry point is `Callback.register "tsync_mount_points"`. The host side is one C file,
  `tsync_mounts_host.c`, compiled into the plugin and into the test host: it calls `caml_startup`
  once, calls the closure with `caml_callback_exn`, copies every string out and only then hands the
  pairs to the host's callback. Nothing in it allocates on the OCaml heap, so the list is not
  registered as a root.
- The plugin records the installed library directory as its only search path
  (`BUILD_WITH_INSTALL_RPATH`, `INSTALL_RPATH_USE_LINK_PATH OFF`). `KDECMakeSettings` turns the
  latter on, which adds the directory the library was linked from: a path into the build tree.

## 5. The D-Bus binding

- Only what the two protocols need: a private connection to an address, the handshake, messages,
  `send`, a non-blocking `read_write`, `pop_message`, the socket's descriptor.
- **No library dispatch.** libdbus's dispatch answers any call no registered handler claimed with
  an automatic `UnknownMethod`. The incoming queue is taken raw and routed in OCaml, which then
  owes a reply to every call (`Tray.dispatch`).
- **Values cross in one call each way.** `Dbus.value` is a variant; `tsync_dbus_message_body`
  builds the whole list and `tsync_dbus_message_append` writes it. The recursion is in C and its
  iterators live on the C stack, so nothing libdbus writes through is in a block the collector
  moves. The append side allocates nothing on the OCaml heap.
- An array carries its element signature because an empty one must still be typed. The stub
  checks each element against it, and validates the array's signature as a whole: `{sv}` alone is
  not a complete type.
- libdbus refuses or aborts on names and strings it finds invalid, so the stubs validate paths,
  interface and member names, signatures and UTF-8 first and raise `Dbus.Error`; `Dbus.method_return`
  and friends replace the invalid bytes of a string, since a file name need not be UTF-8.
- The handshake (`dbus_connection_open_private`, `dbus_bus_register`) releases the runtime lock.
  Nothing else blocks.
- The stubs keep the standard C flags; the include path comes from `pkg-config --cflags dbus-1`,
  since `dbus-arch-deps.h` sits in a per-distribution, per-architecture directory.

## 6. The tray on the runtime

- `Bus.serve` is one fiber: it waits for the connection's descriptor with `Rt.wait_readable`,
  reads and writes without blocking under a mutex, and routes what it popped. A reply resolves the
  fiber that made the call (`Rt.suspend`, keyed by serial); a call or a signal goes to the handler,
  which must not wait.
- `Bus.call` never blocks the connection: it queues the message and parks its own fiber, with
  `Rt.with_timeout`. This is what makes linux-tray §5.1 hold: a silent watcher, file manager or
  owner parks a fiber and nothing else.
- A handler answers `(reply, work)`: `Tray.dispatch` sends the reply, then starts the work in a
  fiber (a stats fetch, an action).
- Owner requests go through `Ipc.ask`, one deadline over the whole exchange, with
  `Rt.map_concurrently`: twenty silent owners cost one deadline.
- One `Mutex` guards the tray's state and the layout; announcements are sent while holding it, so
  they leave in the order of the changes. It is never held across a wait.
- The config is read at every refresh rather than watched: it is small, and that is the whole of
  "reflected within two poll intervals".
- `Layout` holds the dbusmenu tree and is not concurrent by itself. It decides "this row did not
  change" by structural equality on the model's entries, which is what lets ids survive a poll; an
  entry type that gained a closure would break it at run time.

## 7. Tests

- `tests/menu`: the conformance suite of menu-model §8, one snapshot.
- `tests/desktop`: discovery from fixture files, and the three wedged owners against `Ipc.ask`.
- `linux/mounts/test`: a C host against the stand-in and against the real library on inputs that
  must each answer nothing.
- `tests/tray`: the tray as a process on a private `dbus-daemon`, the test being the host, the
  watcher and the file manager. Scenarios run side by side, each on its own bus, in about a minute:
  the time a host that reports no close is given. The bus is started from a configuration with no
  service directory: under the system's session configuration, a call to
  `org.freedesktop.FileManager1` starts the real file manager.
- `linux/dolphin/tests`: `ctest`, run by `linux/build.sh`. One snapshot of resolution, the menu
  table, `stat` against the wedged owners, every click against owners that succeed, refuse, hang up
  or go silent, and the built plugin's metadata; and the plugin's recorded search path.
