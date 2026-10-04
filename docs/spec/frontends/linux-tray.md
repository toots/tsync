# Linux tray — as built

> **Status: as-built snapshot (pass 1)** of `main` at `4c32fa96`. Descriptive, not normative. Shared
> rules (paths, the request wire, packaging, autostart, icons) are in
> [linux-desktop.md](linux-desktop.md); the menu's content is [menu-model.md](menu-model.md);
> findings in [linux-desktop-findings.md](linux-desktop-findings.md).

`tsync-tray` is a standalone process that shows the state of every configured domain as one icon
in the desktop's notification area, with a menu. It draws nothing itself: it exports two objects
on the D-Bus session bus, a **StatusNotifierItem** and a **dbusmenu**, and the desktop's panel
draws them. It is single-threaded: one loop serves the bus and polls the owners.

Hosts named in its documentation as drawing the item: KDE Plasma, XFCE, Cinnamon, LXQt. GNOME Shell
needs the *AppIndicator and KStatusNotifierItem Support* extension.

## 1. Command line and exit

`tsync-tray [-v|--verbose]`, plus the usual `--help` and `--version`.

- Log level `warn` by default, `debug` with `--verbose`.
- A command-line error exits 1.

| end | message | exit |
|---|---|---|
| menu Quit | log `tray: quit` (info) | 0 |
| session bus closed | log `tray: session bus closed` (info) | 0 |
| another tray is running | stdout `tsync-tray is already running` | 0 |
| no session bus | stderr `tsync-tray: no session bus: the tray needs a running desktop session` | 1 |
| bus connection fails | stderr `tsync-tray: no session bus: <bus error text>` | 1 |
| item name cannot be claimed | stderr `tsync-tray: cannot claim org.kde.StatusNotifierItem-<pid>-1` | 1 |

No signal handler is installed; a terminating signal ends the process by default action.

## 2. Startup

In order:

1. **Bus address.** If `DBUS_SESSION_BUS_ADDRESS` is unset or empty: if `XDG_RUNTIME_DIR` is set and
   `$XDG_RUNTIME_DIR/bus` exists, set the address to `unix:path=$XDG_RUNTIME_DIR/bus`; else fail
   (no session bus). The D-Bus library is never left to guess: with no address it auto-launches a
   private bus, which under ssh is a bus no panel is on.
2. **Children.** Ignore `SIGCHLD`, so that children are reaped automatically. The only child ever
   forked is `xdg-open` (§7).
3. **Connect** to the session bus with a private connection that does not exit the process when it
   drops.
4. **Single instance.** Request the name `org.tsync.Tray` without queueing. Not primary owner →
   print `tsync-tray is already running`, exit 0. Two trays would draw two icons and fight over
   the pause switch; not queueing means the second learns now rather than inheriting the name later.
5. **Item name.** Request `org.kde.StatusNotifierItem-<pid>-1` without queueing; failure is fatal.
6. **Item** (§3): subscribe to the watcher's owner changes, register with the watcher, ask whether
   a host is registered.
7. **Menu** (§4): created empty.
8. If no host is registered, warn once:
   `tray: no StatusNotifier host is running, so nothing will draw the icon; on GNOME this needs the AppIndicator extension`.
9. First refresh (§5.2), then set the Stats row's submenu to the placeholder (so the row has a
   submenu to open before anyone opened it).
10. Enter the loop (§5.1).

Object paths: the item at `/StatusNotifierItem`, the menu at `/MenuBar`.

## 3. StatusNotifierItem

### 3.1 Registration

- Watcher: bus name `org.kde.StatusNotifierWatcher`, path `/StatusNotifierWatcher`, interface
  `org.kde.StatusNotifierWatcher`.
- Register: call `RegisterStatusNotifierItem(s)` with the item's bus name (§2 step 5). An error
  (typically the watcher not running yet at login) is logged at debug and ignored.
- Host present: `org.freedesktop.DBus.Properties.Get(watcher interface,
  "IsStatusNotifierHostRegistered")`; a boolean variant; any error or other shape is "no".
- Both calls block, 5 s timeout each.
- Match rule added at creation:

  ```
  type='signal',sender='org.freedesktop.DBus',path='/org/freedesktop/DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='org.kde.StatusNotifierWatcher'
  ```

- On `NameOwnerChanged` for the watcher with a non-empty new owner: log
  `tray: org.kde.StatusNotifierWatcher is back, registering again` (info), register again, then
  emit `NewIcon` and `NewToolTip`. A panel that restarts forgets its items; without this the icon
  disappears until the tray restarts.

### 3.2 Interfaces answered at the item path

The item answers identically on **`org.kde.StatusNotifierItem`** and
**`org.freedesktop.StatusNotifierItem`**: hosts disagree on the name.

| request | answer |
|---|---|
| `Properties.Get(iface, name)`, iface one of the two | the property as a variant; unknown name → error `UnknownProperty` |
| `Properties.GetAll(iface)`, iface one of the two | all properties, `a{sv}` |
| `Properties.GetAll(other iface)` | empty `a{sv}` |
| `Properties.Set` | error `PropertyReadOnly`, text `these properties are read-only` |
| other `Properties` call | error `UnknownMethod` |
| `Introspectable.Introspect` | the XML document (§3.4) |
| any `org.freedesktop.DBus.Peer` call | empty reply |
| `Activate(ii)`, `SecondaryActivate(ii)`, `ContextMenu(ii)`, `Scroll(is)` on either item interface | empty reply, nothing done |
| other member on either item interface | error `UnknownMethod` |
| any other interface | error `UnknownInterface` |

The activation methods do nothing because the item is a menu, but each is answered: an unanswered
call costs the host its full timeout.

### 3.3 Properties

| name | type | value |
|---|---|---|
| `Category` | `s` | `ApplicationStatus` |
| `Id` | `s` | `tsync` |
| `Title` | `s` | `tsync` |
| `Status` | `s` | `Active`, always |
| `WindowId` | `i` | 0 |
| `IconName` | `s` | the current icon name |
| `IconPixmap` | `a(iiay)` | empty |
| `OverlayIconName` | `s` | empty |
| `AttentionIconName` | `s` | empty |
| `AttentionMovieName` | `s` | empty |
| `ToolTip` | `(sa(iiay)ss)` | `("", [], <tooltip>, "")` |
| `ItemIsMenu` | `b` | true |
| `Menu` | `o` | `/MenuBar` |

- `Status` is never `NeedsAttention`: the icon already says what is wrong, and KDE animates
  attention.
- `IconPixmap` is present and empty rather than absent, so a host that reads it unconditionally
  gets an answer.
- `ItemIsMenu` makes a left click open the menu: there is no window to raise.
- Initial values before the first refresh: icon `tsync-idle-symbolic`, tooltip `tsync`.

### 3.4 Signals

- `NewIcon` (no arguments) when the icon name changes; `NewToolTip` (no arguments) when the tooltip
  changes. Each is emitted on both item interfaces. Nothing is emitted when the value is unchanged:
  a host re-reads every property on each signal, and the values are recomputed every poll.
- `NewStatus` is declared in the introspection document and never emitted.

The introspection document declares the properties of §3.3, the four methods of §3.2 and the three
signals, under the interface name `org.kde.StatusNotifierItem`, inside the standard node that also
declares `Introspectable`, `Peer` and `Properties`. No host needs it; `busctl`, `gdbus` and
`d-feet` do.

## 4. dbusmenu

Interface `com.canonical.dbusmenu` at `/MenuBar`. The panel draws the menu; the tray describes it
as a tree of numbered rows with a revision, and tells the host to refetch.

### 4.1 State

- `rows`: the installed tree. A row is `(entry, id, children)`; `entry` comes from the menu model.
- `revision`: starts at 1; incremented before every `LayoutUpdated`.
- `next id`: starts at 1; ids are never reused. Id 0 is the root.
- `opened at`: when the menu was last reported open, or none.
- `pending`: a layout held back while the menu is open, or none.

The menu **is open** while `opened at` is set and less than **60 s** old. The bound exists because
some hosts never report the close, and a menu that only swapped on close would then keep its first
content forever.

### 4.2 Row properties

For a separator: `type` = `separator`.

For an item:

| property | type | value |
|---|---|---|
| `label` | `s` | 4 spaces per indent level, then the label; then every `_` doubled (a lone `_` is the mnemonic marker and would be eaten) |
| `enabled` | `b` | the model's |
| `visible` | `b` | true, always sent (hosts disagree on the default) |
| `icon-name` | `s` | only when the model gives an icon |
| `toggle-type` | `s` | `checkmark`, only for a checkmark row |
| `toggle-state` | `i` | 1 or 0, only for a checkmark row |
| `children-display` | `s` | `submenu`, only for a submenu row |

`children-display` comes from the model's marker, not from whether children have arrived: a row
that changed kind when its content loaded would move under the pointer.

The root (id 0) has the single property `children-display` = `submenu`.

### 4.3 Installing a layout

**Set the whole menu** (every refresh), given the model's entries:

1. Equal to the installed entries → clear `pending`, do nothing else. (Reinstalling would retire
   ids every poll, and a click arriving later than that would name a row that is gone.)
2. Else, the menu is open → store as `pending`. (Replacing the layout under an open menu makes the
   host dismiss it.)
3. Else install: build the rows (below), then emit `LayoutUpdated(revision, 0)`.

**Build**, position by position against the previous rows at that level:

- the previous row at the same position has an equal entry → keep it whole: same id, same children;
- else → a fresh id; its children are those of the previous row, anywhere at that level, that is a
  submenu row with the same action, or none.

So a row that did not change keeps its id, a click on a row that changed is dropped rather than
firing whatever replaced it, and the Stats submenu keeps its content across a redraw even when a
new row above shifts it.

**Set one row's children** (the Stats submenu), given an action and entries:

1. Find the top-level row carrying that action; none → nothing.
2. Entries equal to its current children → nothing.
3. Else build the children against the old ones, replace the row, emit
   `LayoutUpdated(revision, <that row's id>)`.

This is done whether or not the menu is open: announcing against the row makes the host refetch
one subtree instead of dropping the menu.

**Close**: clear `opened at`; if a layout is pending, install it.

### 4.4 Methods

| method | behaviour |
|---|---|
| `GetLayout(parentId i, recursionDepth i, propertyNames as)` → `(u, (ia{sv}av))` | the revision and the node for `parentId`. Depth 0 returns the node without children; −1 returns everything; each level down decrements it. Children are variants of nodes. Parent 0 is the root. An unknown id is answered with a node of that id, no properties and no children. |
| `GetGroupProperties(ids ai, propertyNames as)` → `a(ia{sv})` | the listed rows anywhere in the tree; an empty id list means every row. Unknown ids are skipped. The root is never included. |
| `GetProperty(id i, name s)` → `v` | the property; an unknown row or name is answered with the empty string. |
| `AboutToShow(id i)` → `b` | mark the menu open; reply `false`; flush; then run the open hook (§6.1). |
| `AboutToShowGroup(ids ai)` → `(ai, ai)` | mark the menu open; reply two empty arrays; flush; then run the open hook. |
| `Event(id i, eventId s, data v, timestamp u)` | reply empty; flush; then act: `opened` → mark open and run the open hook; `closed` → close (§4.3); `clicked` → §4.5; anything else → nothing. |
| `EventGroup(events a(isvu))` → `ai` | reply an empty array. The events are not acted on. |
| anything else | error `UnknownMethod` |

- An empty `propertyNames` means every property; otherwise only the named ones.
- `AboutToShow` answers `false` (no update needed): the layout is already current.
- Every reply is sent and flushed **before** the work it triggers: filling the submenu asks every
  owner, and opening a file manager blocks.
- The id passed to `AboutToShow`, `opened` and `closed` is not looked at.

Properties of the interface (`Properties.Get` with any interface name, `GetAll`): `Version` `u` 3,
`Status` `s` `normal`, `TextDirection` `s` `ltr`, `IconThemePath` `as` empty. `Set` →
`PropertyReadOnly`. `Introspect` and `Peer` as for the item.

### 4.5 Click

Find the row with the event's id anywhere in the tree. If it exists, is an item and is enabled, run
its action (§6). Otherwise drop the click and log `tray: click on a stale item <id>` (debug).

### 4.6 Signals

- `LayoutUpdated(revision u, parent i)`, as above.
- `ItemsPropertiesUpdated` is declared in the introspection document and never emitted: every
  change, including a checkmark flipping, is a layout update with fresh ids for the changed rows.

## 5. Loop

### 5.1 Tick

Repeat until quit:

1. Do bus I/O, blocking at most **250 ms**. If the connection is gone, stop (the session is
   ending).
2. Take every queued message, one by one, and route it: the item first, then the menu.
   - The item claims any `NameOwnerChanged` signal and anything addressed to its path; the menu
     claims anything addressed to its path.
   - A message nobody claimed: if it is a method call that expects a reply, answer
     `org.freedesktop.DBus.Error.UnknownMethod` with text `tsync-tray does not implement that`, and
     log it at debug. Signals are dropped. The library's own dispatch is not used, so every call is
     answered by this routing or not at all.
3. If not quitting and at least **3 s** have passed since the end of the last refresh, refresh.

After the loop: close the connection.

### 5.2 Refresh

1. **Domains.** Read the config file's mtime (0 when it cannot be read). If it equals the one seen
   at the last load, reuse the list. Else load the config and, per domain in config order, record
   its name, its owner socket and its mount point
   ([linux-desktop.md §2](linux-desktop.md#2-path-rules-consumed)). A load that fails with a message
   yields no domains and a warning `tray: <config path>: <message>`; the mtime is recorded either
   way, so the load is not retried until the file changes.
2. **Poll.** Send `{"action":"status"}` to every domain's owner **at the same time**, each under a
   **1.5 s** deadline covering connect, write and reading one reply line. Any failure, a deadline or
   an unparseable reply makes that domain unreachable. The refresh waits for all of them, so it
   takes at most the deadline, however many domains there are.
3. **Render** the statuses with the menu model ([menu-model.md](menu-model.md)), default quit
   label.
4. Set the item's icon and tooltip (§3.4), set the menu (§4.3).
5. Record the time.

The loop serves no bus message while a refresh runs.

## 6. Actions

### 6.1 Opening the menu: the Stats submenu

On each open hook, if at least **1 s** has passed since the last fetch started:

1. Send `{"action":"stats","domain":"<name>"}` to every domain's owner at the same time, each under
   a **4 s** deadline (longer than the poll's: the owner reaches every backend first). A domain that
   fails or does not answer is left out and logged at debug.
2. Build the submenu rows ([menu-model.md §6](menu-model.md#6-stats-submenu)) and set them as the
   Stats row's children (§4.3).

The 1 s debounce exists because a host may send both `AboutToShow` and `Event "opened"` for one
opening. Stats are fetched on open and not on the poll: reaching every backend every 3 s when
nobody is looking is a cost nobody asked for.

### 6.2 Hold changes

Action `SetPaused(p)`:

1. Send `{"action":"pause","arg":"on"}` (or `"off"`) to every domain's owner at the same time, each
   under **1.5 s**. The reply is not read. A transport failure or deadline is logged as a warning
   `tray: pause "<name>": <error>`; the others still go.
2. Refresh at once. Nothing is changed locally: the checkmark shows what the owners report, not
   what was asked.

### 6.3 Open folder, reveal file

- `OpenFolder(domain)`: the domain's mount point from the loaded config; unknown domain → nothing.
  Show the folder.
- `Reveal(domain, rel)`: `<mount point>/<rel>`. Show the item selected in its folder. A file is
  never opened: launching the application that owns its type could pull down a body that is still
  being written.

Showing, §7.

### 6.4 Others

- `Quit` → leave the loop. The owners keep running.
- `ShowStats` (a click on the Stats row itself) and `Nothing` → nothing.

## 7. Showing a path in the file manager

1. Build the URI: `file://` followed by the path, where every byte outside `A–Z a–z 0–9 - _ . ~ /`
   is written `%XX` (upper-case hex).
2. Call `org.freedesktop.FileManager1` at `/org/freedesktop/FileManager1`:
   `ShowFolders(as, s)` for a folder, `ShowItems(as, s)` for a file, with `[uri]` and an empty
   startup id. Blocking, **5 s** timeout.
3. On any D-Bus error (no such service, timeout, …): log at debug and run `xdg-open <folder>`,
   where `<folder>` is the folder itself, or the file's parent directory (`xdg-open` cannot select
   a file). The child is not waited for; a failed exec exits it with 127; a failed fork is logged
   as a warning.

## 8. Failure behaviour, summarised

| situation | outcome |
|---|---|
| owner socket absent, refused, or silent for 1.5 s | that domain's row reads `not answering`; others unaffected |
| every owner silent | error icon, `Daemon not running`, Hold changes disabled |
| config missing or unreadable with a message | no domains, error icon, `No domains configured`, a warning |
| panel not running at start | registration fails quietly; picked up when the watcher appears |
| panel restarts | re-registration on the watcher's new owner |
| no host draws items | a warning at startup, the tray keeps running |
| click on a row that changed since the host fetched it | dropped |
| session bus closes | exit 0 |

## 9. Parameters

| name | value | protects |
|---|---|---|
| tick | 250 ms | an idle loop from spinning; a click from feeling dropped |
| poll interval | 3 s | same value as the macOS menu |
| status / pause deadline | 1.5 s | the single thread from a wedged owner |
| stats deadline | 4 s | same, for a request that reaches backends |
| stats debounce | 1 s | a double fetch per opening |
| menu open bound | 60 s | a layout held forever when the host reports no close |
| file-manager call timeout | 5 s | the loop from a file manager that does not answer |
| watcher call timeout | 5 s | same, for the watcher |
| file rows per list | 5 | (menu model) the menu from being pushed off screen |

## 10. Tests

There is no test of the tray process: the bus binding, the item, the dbusmenu state machine (ids,
pending layouts, the open bound), the poll and the actions are not exercised by any suite. The
only automated coverage is the menu model's snapshot suite
([menu-model.md §8](menu-model.md#8-tests)) and the package checks of
[linux-desktop.md §5.4](linux-desktop.md#54-checks-made-on-the-built-packages-ci), which run the
binary without a session.
