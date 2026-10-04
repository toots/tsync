# Linux desktop clients — as built

> **Status: as-built snapshot (pass 1).** This file and its siblings
> ([dolphin.md](dolphin.md), [linux-tray.md](linux-tray.md), [menu-model.md](menu-model.md))
> describe what `main` at `4c32fa96` does, read from the code. They are descriptive, not normative:
> no MUST/SHOULD, no judgement. Defects and open questions are in
> [linux-desktop-findings.md](linux-desktop-findings.md). OCaml and build specifics are in
> [../ocaml/frontends/linux-desktop.md](../ocaml/frontends/linux-desktop.md). Until the normative
> pass, [fuse.md](fuse.md) Part II and [07 §5.8](../07-daemon-cli.md) remain the normative text for
> these components.

This file is the index of the extraction and owns what the two clients share: their place among
the processes, the path rules they consume, mount discovery, the owner requests they send, and how
they are delivered.

| file | owns |
|---|---|
| this file | roles, path rules, mount discovery, the request wire as these clients use it, packaging |
| [dolphin.md](dolphin.md) | the Dolphin context-menu plugin |
| [linux-tray.md](linux-tray.md) | the tray process: StatusNotifierItem, dbusmenu, poll loop, actions |
| [menu-model.md](menu-model.md) | the function from owner replies to an icon, a tooltip and menu rows |
| [linux-desktop-findings.md](linux-desktop-findings.md) | defects, asymmetries, gaps, claims to verify |

Candidates that did not earn a document: the libdbus binding (a language note: any D-Bus library
does), the icons (four SVG files, §5.3), the autostart entry (§5.2).

---

## 1. Roles

Both components are **client tools** in the sense of [07 §1](../07-daemon-cli.md): they own no
domain state, hold no lock, write no file, and act only by sending requests to a domain's owner
over its local socket.

| component | process | lifetime | talks to |
|---|---|---|---|
| Dolphin plugin | loaded into the file manager's process | the file manager's | the owner of the domain whose mount holds the clicked item; the session bus (notifications); the clipboard |
| Tray | its own process, one per desktop session | from session start until quit or the session bus closes | every configured domain's owner; the session bus (item, menu, file manager) |
| Mount discovery | a shared library the plugin loads | the host process's | the config file and the kernel mount table; no socket |

Neither component is told anything by the owner: the owner publishes no events to them. The tray
polls; the plugin asks once per menu.

On Linux each domain has its own owner process and its own socket, so a request carries no domain
selector unless stated (§4).

## 2. Path rules consumed

These rules belong to the core. They are restated here as the clients evaluate them, because a
rebuild of either client needs them exactly.

| name | value |
|---|---|
| config path | `$XDG_CONFIG_HOME/tsync/config.json`, with `$HOME/.config` when `XDG_CONFIG_HOME` is unset |
| data dir | `$XDG_DATA_HOME/tsync`, with `$HOME/.local/share` when `XDG_DATA_HOME` is unset |
| owner socket of domain `D` | `<data dir>/tsync-D.sock` (the name verbatim, spaces included) |
| mount point of domain `D` | the `mountPoint` option of the first `fuse` frontend of `D` that has one, when non-empty; else `$HOME/tsync/D` |

- `HOME` is read unconditionally; when it is unset the evaluation fails.
- The mount point is the configured string, used verbatim: no `~` expansion, no symlink
  resolution, no trailing-slash trimming.
- The mount point is computed for every configured domain, whether or not it has a `fuse` frontend.
- The config is the JSON in the environment variable `TSYNC_CONFIG_JSON` when that is set, else the
  file's content.

## 3. Mount discovery

`mount_points() → [(mount point, socket path)]`: every configured domain whose filesystem is
mounted now. A domain configured but not mounted is absent.

### 3.1 Algorithm

1. Compute the paths of §2 and load the config.
2. Read `/proc/self/mountinfo` line by line. Split a line on single spaces.
   - Field 5 (1-based) is the mount point.
   - Scan the fields after it for the first field equal to `-`. The next two fields are the
     filesystem type and the source.
   - Keep the line iff **source = `tsync`** and **type starts with `fuse.`**.
   - Decode the mount point: each `\` followed by three characters that parse as an octal number is
     replaced by the byte with that value; any other `\` is kept.
   - A line with fewer than five fields, or with no `-` field followed by two more, is skipped.
   - A mount table that cannot be opened yields no mounted paths.
3. For each configured domain, in config order: compute its mount point (§2); emit
   `(mount point, owner socket)` iff the mount point is **byte-equal** to one of the kept, decoded
   mount points.
4. Any failure anywhere in 1–3 yields the empty list. Nothing is raised to the caller.

The inputs are re-read on every call. Nothing is cached.

### 3.2 Why this rule (from the code and its history)

- The mount table decides liveness, not the socket: asking each socket from the menu thread cost
  0.3 s per right-click with two owners that accepted and did not answer, and froze the file
  manager when one sent bytes without a newline.
- The source column identifies tsync, not the type, because the type is `fuse.sshfs` by default
  ([fuse.md §B2](fuse.md)) and `fuse.tsync` only when configured so. The type test only tells a
  FUSE mount from a non-FUSE one.
- The rule lives in the core and is shipped as a library so that an extension does not restate
  where a domain mounts or where its owner listens.

### 3.3 Shared-library contract

- File `libtsync_mounts.so`, SONAME `libtsync_mounts.so`, installed at `<libdir>/tsync/`.
- Position-independent; carries the language runtime.
- One entry point, registered under the name **`tsync_mount_points`**, taking no argument and
  returning a list of string pairs.
- The host starts the runtime once, from the one thread that will call it, then looks the entry
  point up by name and calls it. It copies the strings out before doing anything else.
- A second object, `libtsync_mounts_fake.so`, registers the same name with three fixed pairs. It
  exists for the plugin's test and is never installed:

  ```
  ("/mnt/files",        "/run/tsync-Files.sock")
  ("/mnt/files/media",  "/run/tsync-Media.sock")
  ("/mnt/spaced name",  "/run/tsync-Spaced Name.sock")
  ```

## 4. Owner requests used

Transport: a Unix stream socket at the owner socket path. One request is one line of compact JSON
ending in `\n`; the reply is one line of JSON ending in `\n`. Each request here uses its own
connection, closed by the client after the reply.

Reply envelope:

- success: `{"ok":true, …fields}`
- failure: `{"ok":false,"code":"<code>","error":"<text>"}`

Neither client reads `code`.

| action | sent by | request, as written | reply fields read |
|---|---|---|---|
| `stat` | plugin | `{"action":"stat","rel":"<rel>"}` | `ok`, `availability` |
| `share` | plugin | `{"action":"share","rel":"<rel>"}` | `ok`, `url`, `error` |
| `restore` | plugin | `{"action":"restore","rel":"<rel>"}` | `ok`, `error` |
| `evict` | plugin | `{"action":"evict","rel":"<rel>"}` | `ok`, `error` |
| `status` | tray | `{"action":"status"}` | see [menu-model.md §2](menu-model.md#2-input-one-status-reply-per-domain) |
| `stats` | tray | `{"action":"stats","domain":"<name>"}` | see [menu-model.md §6](menu-model.md#6-stats-submenu) |
| `pause` | tray | `{"action":"pause","arg":"on"}` or `"off"` | none; the reply is discarded |

`<rel>` is the item's path relative to the mount point, with no leading `/`; the empty string names
the domain's root. `<name>` is JSON-escaped. The plugin's object keys are written in alphabetical
order (`action` before `rel`).

What the owner does with them, as far as these clients depend on it:

- **Target by `rel`.** With no `ref` field, an empty `rel` is the root; a non-empty `rel` is looked
  up in the local mirror and is a file or a directory by what the mirror holds. A `rel` the mirror
  does not hold is answered `ok:false` with the text `not found: <rel>`.
- **`stat`** answers the item's row. A file's row has `availability`: `online-only`, `cached` or
  `pinned` (with `pinnedUntil`). A directory's row has no `availability`.
- **`share`** creates a share of the path, expiring 7 days after the request, and answers `url`.
  The client cannot choose the expiry.
- **`restore`** makes the item's content local and pins it; on a directory, every file under it,
  one after the other, where one file's failure is logged by the owner and does not stop the rest.
  With no `keep` field the owner applies its default pin duration. The reply is sent when the work
  is finished.
- **`evict`** drops the item's content from the cache; on a directory, the same subtree walk.
- **`status`** is cheap by design: no store access. **`stats`** reaches every backend before
  answering.
- **`pause`** holds every change when `arg` is anything but `off`, releases on `off`, and answers
  `{"ok":true}`.
- `share`, `restore`, `evict` and `pause` are not among the actions a read-only domain refuses.
- The owner handles one mutation at a time; these actions queue behind it.

## 5. Delivery

### 5.1 Packages

| package | contents | dependencies |
|---|---|---|
| `tsync` | the binary, the system unit template, the app icon `hicolor/scalable/apps/tsync.svg`, `<libdir>/tsync/libtsync_mounts.so` | its shared libraries, `fuse3` |
| `tsync-tray` | `/usr/bin/tsync-tray`, `/etc/xdg/autostart/tsync-tray.desktop`, the four status icons | its shared libraries (libdbus), `tsync` at exactly the same version |
| `tsync-dolphin` | `<qt6 plugin dir>/kf6/kfileitemaction/tsyncdolphin.so` | its shared libraries (Qt 6, KF6), `tsync` at exactly the same version |

- The split keeps libdbus, Qt and KF6 off a headless install, and Qt/KF6 off a desktop that only
  wants the tray.
- The discovery library ships with `tsync`, not with the plugin: it is tsync's answer and a second
  extension would link the same object.
- The version pin exists because both clients speak the owner's request wire.
- `tsync-tray` and `tsync-dolphin` carry no maintainer scripts.
- The plugin is installed with a library search path of `<libdir>/tsync` and no build-tree path.
  The build produces it by an install step, never by copying from the build directory (a copied
  plugin keeps the build machine's search path).
- Binaries are stripped.
- A source install (`make install`) installs neither client. Its uninstall removes
  `~/.local/bin/tsync-tray` and `~/.config/autostart/tsync-tray.desktop` if present.
- The package build fails when Qt or KF6 is absent; it never produces a package set without the
  plugin.

### 5.2 Autostart entry

`/etc/xdg/autostart/tsync-tray.desktop`, mode 644:

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

- XDG autostart rather than a systemd user unit: it is honoured by sessions that are not
  systemd-managed, and becomes a session-bound unit where they are.
- No `NoDisplay`: the entry stays visible in the desktop's startup list, where a user turns it off.

### 5.3 Icons

Four SVGs, 24×24 view box, installed as
`/usr/share/icons/hicolor/symbolic/apps/tsync-<state>-symbolic.svg` for `<state>` in `idle`,
`sync`, `paused`, `error`.

- The `-symbolic` suffix together with the `symbolic/` directory is what makes GTK panels recolour
  the icon to the panel foreground. Qt panels ignore both and recolour through the
  `current-color-scheme` stylesheet block the SVGs carry.
- Each SVG declares a `color` so that `currentColor` resolves when no toolkit supplies one.

### 5.4 Checks made on the built packages (CI)

- Each of `tsync` and `tsync-tray` runs after install.
- `tsync-tray` depends on libdbus and not on KF6; `tsync-dolphin` depends on KF6; `tsync-tray` has
  no post-install script.
- The installed plugin resolves `libtsync_mounts.so` with every dependency found, and its recorded
  search path names no build directory.
- `libtsync_mounts.so` is listed by `tsync` and not by `tsync-dolphin`.
- The repository install test installs `tsync` and `tsync-tray` from the published repository.

## 6. Tests — mount discovery

One suite, driven by fixture files, never by the machine's real mounts.

**Fixture.** A config with five domains and a mount table with six lines:

| domain | configured mount point | mount table line | expected |
|---|---|---|---|
| `Explicit` | `<home>/elsewhere` | type `fuse.tsync`, source `tsync` | reported |
| `Jellyfin Media` | none (default `<home>/tsync/Jellyfin Media`) | `…/tsync/Jellyfin\040Media`, type `fuse.sshfs`, source `tsync` | reported |
| `Unmounted` | `<home>/gone` | type `fuse.sshfs`, source `user@host:` | absent |
| `Impostor` | `<home>/impostor` | type `tmpfs`, source `tsync` | absent |
| `Absent` | `<home>/absent` | no line | absent |
| — | — | `/proc` (type `proc`), `<home>/other` (type `ext4`) | absent |

**Invariants.**

- A mounted domain is reported with the socket path of §2 for its name.
- An octal escape in the table is decoded before comparison.
- A domain with no configured mount point is found at the default.
- A real sshfs mount at a configured path is not tsync's (source decides).
- A non-FUSE mount whose source is `tsync` is not tsync's (type decides).
- Exactly two pairs come back.
- With `HOME` pointing at a directory that does not exist, the public entry point returns without
  raising.

**Binding:** which pairs are present, the socket path of each, the count. **Incidental:** the
order of the pairs, the scratch location, the output wording.

**Doubles a new harness needs:** a mount table as a file, a config as a file, an overridable
`HOME`.

The suite counts its checks and fails when none ran.
