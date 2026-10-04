# Linux desktop clients

Two components put tsync on a Linux desktop: a context-menu plugin for the Dolphin file manager
and a tray icon with a menu. This file owns what they share: their place among the processes, how
each learns where a domain is mounted, mount discovery, the owner requests they send, and how they
are delivered.

| file | owns |
|---|---|
| this file | roles, mount points, mount discovery, the client side of the requests, packages, autostart, icons |
| [dolphin.md](dolphin.md) | the Dolphin context-menu plugin |
| [linux-tray.md](linux-tray.md) | the tray process: StatusNotifierItem, dbusmenu, polling, actions |
| [menu-model.md](menu-model.md) | the function from owner replies to an icon, a tooltip and menu rows |
| [linux-desktop-known-complexity.md](linux-desktop-known-complexity.md) | the difficulties this problem is known to hold, each with the rule that answers it |

The mount itself is [fuse.md](fuse.md). The request handler is [08 §3](../08-frontends.md); the
process model, the sockets and the paths are [07](../07-daemon-cli.md); deadlines and error codes
are [failure-model.md](../algorithms/failure-model.md).

Implementation notes: [../ocaml/frontends/linux-desktop.md](../ocaml/frontends/linux-desktop.md).

---

## 1. Roles

Both components are **client tools** ([07 §2.1](../07-daemon-cli.md#21-roles)): they own no domain
state, hold no lock, write no file of tsync's, and act only by sending requests to a domain's
owner over its socket.

| component | runs | talks to |
|---|---|---|
| Dolphin plugin | inside the file manager's process, on the thread that draws its menus | the owner of the domain whose mount holds the selected item; the session bus (notifications); the clipboard |
| Tray | its own process, one per desktop session | every configured domain's owner; the session bus (item, menu, file manager) |
| Mount discovery | a shared library the plugin loads | the config and the kernel mount table; **no process** |

The owner pushes nothing to either: the tray polls, the plugin asks once per menu.

On Linux each domain has its own owner process and socket
([07 §2.4](../07-daemon-cli.md#24-which-process-owns-which-domain)), so a request to an owner
socket carries no `domain` field ([07 §4.2](../07-daemon-cli.md#42-envelopes)).

## 2. Where a domain is mounted

Three parties know something about it. The config says where a mount was asked for. The owner
knows where it mounted. The kernel mount table knows what is mounted now. They agree on an
ordinary machine, and each client is told here which one to believe.

- **The configured mount point** of a domain is the rule of
  [fuse.md §2.1](fuse.md#21-options): the `mountPoint` of its `fuse` frontend, else
  `$HOME/tsync/<domain>`. A domain with no `fuse` frontend has none. The config, the data
  directory and the owner socket path are [07 §2.7](../07-daemon-cli.md#27-runtime-paths),
  including the config given in the environment.
- **Discovery** (§3) answers from the config and the mount table: the config for *where*, the
  table for *whether*.
- **The tray** uses the mount point the owner reports in its `status` reply (`mount`,
  [fuse.md §5](fuse.md#5-hooks)) when the owner answers and reports one, and the configured mount
  point otherwise.
- A path is compared with a mount point only after both are made canonical: §3.2 for the
  configured side, [dolphin.md §2](dolphin.md#2-building-the-menu) for a selected path.

**Stated limit.** A mount started at a mount point the config does not name (the command-line
override of [fuse.md §2.1](fuse.md#21-options)) is not found by discovery, so the plugin offers
nothing inside it. The tray opens it correctly, since it asks the owner.

## 3. Mount discovery

### 3.1 The answer

`mount_points() → [(mount point, socket path)]`: one pair for every configured domain whose
filesystem is mounted now, with the canonical mount point (§3.2) and the domain's owner socket. A
domain that is configured and not mounted is absent. The order of the pairs is not significant.

Discovery MUST NOT connect to any socket or wait on any process, and MUST NOT perform a filesystem
operation at or below a tsync mount point: it runs on a thread that is not its own, while a user
waits for a menu, and an owner can stop answering.

Discovery MUST be **total**: whatever fails (no home directory, a config that is missing,
unreadable or invalid, a mount table that cannot be opened or holds lines it cannot parse), the
answer is a list, empty if need be, and nothing is raised to the caller. A line of the mount table
that cannot be parsed is skipped; it does not empty the answer.

The inputs are read on every call. A mount or unmount is reflected by the next call.

### 3.2 Algorithm

1. Load the config. For each domain with a `fuse` frontend, take its configured mount point (§2)
   and make it canonical: resolve the symbolic links of its **parent** directory, and append the
   last component unchanged. The last component is not resolved: it is the mount itself, and
   looking through it would ask the owner. A parent that cannot be resolved leaves the configured
   string as it is.
2. Read `/proc/self/mountinfo`. A line is fields separated by single spaces.
   - Field 5 (1-based) is the mount point.
   - After it comes a variable number of optional fields, ended by a field equal to `-`. The two
     fields after `-` are the filesystem type and the source.
   - Keep the line iff the **source is `tsync`** and the **type starts with `fuse.`**.
   - Decode the mount point: a `\` followed by three octal digits whose value is at most 255
     becomes the byte of that value; any other `\` is kept as it is.
   - A line with fewer than five fields, or with no `-` followed by two more fields, is skipped.
3. Emit `(canonical mount point, owner socket)` for each domain of step 1 whose canonical mount
   point is byte-equal to a kept, decoded mount point.

### 3.3 Why this rule

- **The mount table decides liveness, not the socket.** Asking each owner from the menu thread
  costs a wait per owner that accepts and does not answer, and freezes the file manager on one
  that sends bytes with no end of line.
- **Both columns are needed.** The type is not tsync's own: it defaults to `fuse.sshfs`, so that
  the file manager does not fetch every file of a folder to draw thumbnails
  ([fuse.md §B2](fuse.md#b2-why-the-mount-reports-fusesshfs)), and matching it alone would take a
  real sshfs mount for a domain. The source is free text any mount may carry, so matching it alone
  would take a tmpfs named `tsync` for a live domain.
- **The kernel escapes** space, tab, newline and backslash in the mount point, as `\040`, `\011`,
  `\012` and `\134`, and nothing else. A domain whose name holds a space is missed by a reader
  that does not decode.
- **The rule is shipped, not restated.** An extension that computed mount points and socket paths
  itself would drift from the core. It links the core's answer instead.

### 3.4 Shared-library contract

These names are compatibility surface and MUST NOT change:

- file name and SONAME `libtsync_mounts.so`, the two equal, installed in `<libdir>/tsync/`;
- one entry point, found by the name **`tsync_mount_points`**, taking no argument and returning
  the list of §3.1 as pairs of byte strings.

Rules:

- The library is position-independent and self-contained: it brings whatever runtime it needs.
- The host initialises it once, from the thread that will call it, and calls it from that thread
  only. Asking again MUST NOT initialise again.
- The host copies the strings out before it does anything else with the library.
- A failure inside the library MUST NOT end, abort or unwind into the host process.
- Initialising it MUST NOT change process-wide state the host depends on: signal dispositions,
  the locale, the working directory, the environment.

A test stand-in exporting the same entry point with fixed pairs MAY exist for the tests of an
extension. It MUST NOT be installed.

## 4. Owner requests

### 4.1 Transport and bounds

- A Unix stream socket at the domain's owner socket path. One request is one line of JSON ending
  in a newline; the reply is one line ([01 §11](../01-core.md#11-ipc-framing),
  [07 §4.2](../07-daemon-cli.md#42-envelopes)). Each request of these clients uses its own
  connection, which the client closes.
- **Every exchange has a deadline that covers the whole of it**: connecting, writing, and reading
  until the newline. A timer restarted by each byte received is not a deadline: a peer that keeps
  sending without ending its line defeats it. Each client's file states its deadlines; where it
  states none, the client rules of
  [failure-model.md §8.2](../algorithms/failure-model.md#82-requests-between-processes) apply.
- A request that is abandoned is closed. The owner's work continues
  ([07 §4.3](../07-daemon-cli.md#43-deadlines-bulk-actions-and-the-liveness-probe)).
- No answer, a transport failure, an expired deadline and a reply that is not one JSON object are
  one outcome, **no answer**. It is never read as `not_found` and never as success
  ([failure-model.md §7.2](../algorithms/failure-model.md#72-client-error-codes)).
- A reply with `ok` other than `true` is a **refusal**. The client reads its `code` and shows its
  `error` sentence.

### 4.2 Requests used

Field names, replies and refusals are those of [08 §3.3](../08-frontends.md#33-actions).

| action | sent by | request | reply fields read |
|---|---|---|---|
| `stat` | plugin | `rel` | `kind`, `availability` |
| `share` | plugin | `rel` | `url`, `expires` |
| `restore` | plugin | `rel` | `restored`, `failed` |
| `evict` | plugin | `rel` | `evicted`, `failed` |
| `ping` | plugin | — | `ok` |
| `status` | tray | — | [menu-model.md §2](menu-model.md#2-input-one-status-per-domain), and `mount` |
| `stats` | tray | — | [menu-model.md §6](menu-model.md#6-stats-submenu) |
| `pause` | tray | `arg`: `on` or `off` | `ok`, `error` |

`rel` is the item's path relative to the mount point, with no leading `/`; the empty string names
the domain's root.

## 5. Delivery

### 5.1 Packages

Package names and installed paths are compatibility surface.

| package | installs | depends on |
|---|---|---|
| `tsync` | among the rest ([fuse.md §B6](fuse.md#b6-packaging)): `<libdir>/tsync/libtsync_mounts.so`, the application icon `hicolor/scalable/apps/tsync.svg` | no desktop library |
| `tsync-tray` | `/usr/bin/tsync-tray`, `/etc/xdg/autostart/tsync-tray.desktop`, the four status icons (§5.3) | the session-bus library it links; `tsync` at exactly the same version |
| `tsync-dolphin` | `<Qt 6 plugin directory>/kf6/kfileitemaction/tsyncdolphin.so` | Qt 6 and KDE Frameworks 6; `tsync` at exactly the same version |

- **The split** keeps bus and toolkit libraries off a headless machine, and the file manager's
  toolkit off a desktop that only wants the tray.
- **The discovery library ships with `tsync`**: it is tsync's answer, and a second extension links
  the same object.
- **The exact version pin** exists because both clients speak the owner's request interface.
- Every file is installed by exactly one package, and every package of a build is a distinct
  artifact.
- The installed plugin MUST find `libtsync_mounts.so` in `<libdir>/tsync` through the search path
  recorded in it, and that recorded path MUST name no directory of the build machine.
- `tsync-tray` and `tsync-dolphin` run nothing at install or removal.
- A package build MUST fail when the plugin cannot be built. It never produces a package set
  without it.

### 5.2 Autostart

`/etc/xdg/autostart/tsync-tray.desktop`:

```ini
[Desktop Entry]
Type=Application
Name=tsync tray
Comment=Sync status in the system tray
Exec=/usr/bin/tsync-tray
Icon=tsync
Terminal=false
Categories=Utility;
X-GNOME-Autostart-enabled=true
```

- The tray is started by XDG autostart, not by a unit tied to a session target of the service
  manager: such a unit is never started on a desktop whose session does not populate that target.
- The entry MUST stay visible in the desktop's list of startup applications (no `NoDisplay`,
  no `Hidden`): that list is where a user turns it off.

### 5.3 Icons

Four status icons, installed as
`/usr/share/icons/hicolor/symbolic/apps/tsync-<state>-symbolic.svg` for `<state>` in `idle`,
`sync`, `paused` and `error`. The names are compatibility surface: the menu model emits them
([menu-model.md §4](menu-model.md#4-icon-and-tooltip)) and the macOS menu maps them.

- They are installed in `hicolor` because every icon theme inherits it.
- Each is one colour, drawn with **fills only**. A panel of the GTK family recolours a file whose
  name ends in `-symbolic.svg` by forcing the fill of every shape to its foreground colour, so a
  stroked mark is filled and a second colour is flattened.
- Each carries a style element with the id `current-color-scheme`, defining the class
  `ColorScheme-Text`, and paints with `currentColor` under that class. A panel of the KDE family
  replaces that style element with its own colours, when the user's icon theme follows the colour
  scheme.
- Each declares a default `color`, so that `currentColor` resolves where no panel supplies one.

## 6. Conformance

### 6.1 Mount discovery

Driven by fixture files, never by the machine's real mounts.

**Invariants.**

- A domain is reported iff the mount table holds a line at its canonical mount point whose source
  is `tsync` and whose type starts with `fuse.`. It is reported with its own owner socket.
- A mount point holding a space survives decoding.
- A domain with no configured mount point is found at the default.
- A real sshfs mount at a configured path is not reported (the source decides).
- A non-FUSE mount whose source is `tsync` is not reported (the type decides).
- A configured mount point reached through a symbolic link in a parent directory is reported, with
  the canonical path the table lists.
- A domain with no `fuse` frontend is not reported.
- A table holding an unparseable line, and one holding a malformed escape, still yields every
  other mount.
- With no home directory, no config, an invalid config, and no mount table, the public entry
  point returns the empty list each time, and its caller survives.
- No socket is connected to: with every owner socket replaced by one that accepts and never
  answers, the answer is the same and takes no longer.

**Binding:** which pairs are present, both strings of each, the count. **Incidental:** the order
of the pairs.

**Doubles:** a mount table as a file; a config as a file; an overridable home directory; a
directory tree with a symbolic link in it; an owner that accepts connections and never answers.

### 6.2 Shared library

- A host built against the stand-in receives every pair, with both halves intact and a space
  preserved.
- Asking twice initialises once and answers the same.
- The library loads and answers on every architecture it is packaged for.

### 6.3 Packages

Each check is made on the package as built, not on the build tree, and each MUST have been seen to
fail against a deliberately bad artifact before its pass counts.

- `tsync` declares no dependency on a bus or toolkit library. `tsync-tray` declares the bus
  library and not the file manager's toolkit. `tsync-dolphin` declares the toolkit.
- `tsync-tray` and `tsync-dolphin` each depend on `tsync` at exactly their own version.
- The installed plugin resolves every library it needs, `libtsync_mounts.so` among them, on a
  machine that never held the build tree; its recorded search path names no build directory.
- The plugin is installed in the directory the file manager scans, and its metadata reads back as
  [dolphin.md §7](dolphin.md#7-conformance) requires.
- `libtsync_mounts.so` is listed by `tsync` and by no other package; no file is listed by two
  packages.
- A package build with the plugin's toolkit absent fails.
- After install, `tsync-tray` runs: started with no session bus, it exits as
  [linux-tray.md §1](linux-tray.md#1-command-line-and-exit) says.
- A client machine installs `tsync` and `tsync-tray` from the repository as it is served.

### 6.4 Icons

On a dark and on a light panel of each family, the four states are visible and distinct. This is
checked by eye; no automated check is required.

### 6.5 The wedged owner

For every request of §4.2 and each of three owners, one that accepts and never answers, one that
sends a byte at an interval shorter than any timer and never ends its line, and one that is not
listening, the client ends the exchange by its stated deadline and reports no answer.

**Doubles:** those three owners.
