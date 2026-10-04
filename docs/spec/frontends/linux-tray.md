# Linux tray

`tsync-tray` is a standalone process that shows the state of every configured domain as one icon
in the desktop's notification area, with a menu. It draws nothing itself: it exports two objects
on the D-Bus session bus, a **StatusNotifierItem** and a **dbusmenu**, and the desktop's panel
(the *host*) draws them. What the menu says is [menu-model.md](menu-model.md); shared rules
(roles, mount points, the request transport, packaging, autostart, icons) are in
[linux-desktop.md](linux-desktop.md).

Hosts differ, and the protocols leave defaults open. The rules below that look redundant (two
interface names, properties sent though they hold a default, both opening notices handled) each
exist because some host needs them. The panels of KDE Plasma, XFCE, Cinnamon and LXQt draw
StatusNotifier items; GNOME Shell needs an extension to.

---

## 1. Command line and exit

`tsync-tray [-v|--verbose]`, with `--help` and `--version`. It logs warnings by default and debug
lines with `--verbose` ([07 §5.7](../07-daemon-cli.md#57-logging)). A command-line error exits 1.

| end | message | exit |
|---|---|---|
| the menu's Quit | — | 0 |
| the session bus closes | — | 0 |
| another tray is running | stdout `tsync-tray is already running` | 0 |
| no session bus | stderr `tsync-tray: no session bus: the tray needs a running desktop session` | 1 |
| the bus connection fails | stderr `tsync-tray: no session bus: <reason>` | 1 |
| the item's name cannot be claimed | stderr `tsync-tray: cannot claim <name>` | 1 |

Quitting the tray stops no owner.

## 2. Startup

In order:

1. **Bus address.** If `DBUS_SESSION_BUS_ADDRESS` is unset or empty: use
   `unix:path=$XDG_RUNTIME_DIR/bus` when `XDG_RUNTIME_DIR` is set and that socket exists; else
   fail (no session bus). The tray MUST NOT let a bus be started for it: a bus library left to
   guess launches a private one, which under a remote shell is a bus no panel is on, and the tray
   then runs forever drawn nowhere.
2. **Connect.** A dropped connection ends the tray through the table of §1, never through the bus
   library ending the process by itself.
3. **Single instance.** Request the bus name `org.tsync.Tray` **without queueing**. Not the owner
   → print `tsync-tray is already running`, exit 0. Two trays would draw two icons and act on one
   hold switch; a second tray that queued would take over silently when the first exits.
4. **Export** the item at `/StatusNotifierItem` (§3) and the menu at `/MenuBar` (§4). Calls are
   answered from here on (§5.1). Until the first refresh installs a layout, the menu is the root
   alone.
5. **Item name.** Request `org.kde.StatusNotifierItem-<pid>-1` without queueing. Failure is fatal.
   The objects MUST be exported before the name is requested: a name on the bus whose objects do
   not answer yet refuses the first call of whoever saw the name appear.
6. **Register** with the watcher (§3.1), and ask whether a host is registered. If none is, warn
   once: `tray: no StatusNotifier host is running, so nothing will draw the icon; on GNOME this
   needs the AppIndicator extension`. The tray keeps running.
7. Refresh (§5.2), then serve.

The bus names `org.tsync.Tray` and `org.kde.StatusNotifierItem-<pid>-1` and the two object paths
are compatibility surface.

## 3. StatusNotifierItem

### 3.1 Registration

- Watcher: bus name `org.kde.StatusNotifierWatcher`, path `/StatusNotifierWatcher`, interface
  `org.kde.StatusNotifierWatcher`.
- Register by calling `RegisterStatusNotifierItem(s)` with the item's bus name. A failure is not
  an error: at login the tray may start before the watcher.
- A host is present when the watcher's property `IsStatusNotifierHostRegistered` reads true; any
  error or other shape is "no".
- The tray watches the watcher's name. **Each time the name gets a new owner**, the tray MUST
  register again and then emit `NewIcon` and `NewToolTip`. A panel that restarts forgets its
  items; without this the icon disappears until the tray restarts, or returns showing what it
  said at login.
- Calls to the watcher are bounded by `WATCHER_TIMEOUT` and are subject to §5.1.

### 3.2 Calls answered at the item path

The item answers identically on **`org.kde.StatusNotifierItem`** and
**`org.freedesktop.StatusNotifierItem`**: hosts disagree on the name.

| call | answer |
|---|---|
| `Properties.Get(iface, name)`, iface one of the two | the property; unknown name → error `UnknownProperty` |
| `Properties.GetAll(iface)`, iface one of the two | every property |
| `Properties.Get` or `GetAll` on another interface | error `UnknownInterface` |
| `Properties.Set` | error `PropertyReadOnly` |
| `Introspectable.Introspect` | a document declaring what this table answers |
| `org.freedesktop.DBus.Peer` calls | as the D-Bus specification defines them |
| `Activate(ii)`, `SecondaryActivate(ii)`, `ContextMenu(ii)`, `Scroll(is)` | an empty reply; nothing is done |
| another member of an item interface | error `UnknownMethod` |
| another interface | error `UnknownInterface` |

- **Every method call that expects a reply MUST get a reply or an error**, on these paths and on
  any other path of the tray's connection (`UnknownMethod` there). An unanswered call holds its
  caller for the caller's full timeout, tens of seconds of a panel that looks wedged; and the
  calls that go unanswered are the ones nobody thought of.
- A call with no interface in its header is legal; it is dispatched by its member name among the
  interfaces of the object.
- The activation methods do nothing because the item is a menu, and are answered for the reason
  above.

### 3.3 Properties

| name | type | value |
|---|---|---|
| `Category` | `s` | `ApplicationStatus` |
| `Id` | `s` | `tsync` |
| `Title` | `s` | `tsync` |
| `Status` | `s` | `Active`, always |
| `WindowId` | `i` | 0 |
| `IconName` | `s` | the model's icon name |
| `IconPixmap` | `a(iiay)` | empty |
| `OverlayIconName` | `s` | empty |
| `AttentionIconName` | `s` | empty |
| `AttentionMovieName` | `s` | empty |
| `ToolTip` | `(sa(iiay)ss)` | `("", [], <the model's tooltip>, "")` |
| `ItemIsMenu` | `b` | true |
| `Menu` | `o` | `/MenuBar` |

- `Status` is never `NeedsAttention`: the icon already says what is wrong, and some hosts animate
  attention.
- `IconPixmap` is present and empty rather than absent: some hosts read it unconditionally.
- `ItemIsMenu` makes a primary click open the menu: there is no window to raise.
- Before the first refresh: icon `tsync-idle-symbolic`, tooltip `tsync`.

### 3.4 Signals

`NewIcon` when the icon name changes and `NewToolTip` when the tooltip changes, neither with
arguments, each emitted on both item interfaces. Nothing is emitted while the value is unchanged:
a host re-reads every property on each signal, and the values are recomputed at every poll.

## 4. dbusmenu

Interface `com.canonical.dbusmenu` at `/MenuBar`. The tray describes the menu as a tree of
numbered rows with a revision, and tells the host to fetch it again; the host draws it.

Three things make this hard, and the rules of this section answer them:

- the content is recomputed every few seconds, while a host that is told the whole layout changed
  may drop the menu it is drawing;
- a click names a row by a number the host fetched earlier;
- the Stats submenu is written by another source than the rest of the tree.

### 4.1 State

- **rows**: the installed tree. A row is an entry of the model, an id, and child rows.
- **revision**: an unsigned integer that MUST increase before every `LayoutUpdated`. Some hosts
  ignore a signal whose revision is not greater than the last they saw.
- **ids**: id 0 is the root. A row's id is a positive integer, and an id MUST NOT ever be given to
  a second row during the life of the process.
- **open**: whether the root menu is on screen, as far as the tray knows (§4.4).
- **held**: a layout kept back while the menu is open, or none.

### 4.2 Row properties

A separator has `type` = `separator`. An item has:

| property | type | value |
|---|---|---|
| `label` | `s` | 4 spaces per indent level, then the label; then every `_` doubled |
| `enabled` | `b` | the model's |
| `visible` | `b` | true, always sent |
| `icon-name` | `s` | only when the model gives an icon |
| `toggle-type` | `s` | `checkmark`, only for a checkmark row |
| `toggle-state` | `i` | 1 or 0, only for a checkmark row |
| `children-display` | `s` | `submenu`, only for a submenu row |

- A single `_` marks a mnemonic and is removed by the host; undoubled, a file name loses its
  underscores.
- The protocol has no property for nesting; leading spaces are the only indentation every host
  draws.
- `visible` is sent though true: hosts disagree on what its absence means.
- `children-display` comes from the model's marker, not from whether children have arrived: a row
  that changed kind when its content loaded would move under the pointer.
- The root has the single property `children-display` = `submenu`.

### 4.3 Installing a layout

**Row identity.** When a new list of entries replaces the rows at one level, position by position:

- where the old row at that position has an equal entry, the row is kept whole: same id, same
  children;
- otherwise the row gets a fresh id. If it is a submenu row, it takes the children of the old row
  at that level, wherever it stood, that was a submenu row with the same action; with no such
  row, it takes the placeholder ([menu-model.md §6](menu-model.md#6-stats-submenu)), so that a
  submenu row has content before anyone opens it.

So an unchanged row keeps its id; a row that changed can no longer be clicked through its old id;
and the Stats submenu keeps its content across a redraw, even when a new row above shifts it.

**Setting the whole menu**, at every refresh, given the model's entries:

1. Equal to the installed entries → drop any held layout and do nothing else. Announcing an
   unchanged layout would be noise, and retiring ids at every poll would lose every click.
2. Else, if the menu is open → hold it, replacing any layout already held.
3. Else install it by the identity rule and emit `LayoutUpdated(revision, 0)`.

While the menu is open the tray MUST NOT announce a change of the root. It announces the held
layout when the menu closes, when a new opening begins, or at the first refresh after the menu
has been open for `MENU_OPEN_BOUND`, whichever comes first (§4.4).

**Setting the Stats row's children**, given entries:

1. Find the top-level row whose action is `ShowStats`; none → nothing.
2. Equal to its current children → nothing.
3. Else replace them by the identity rule and emit `LayoutUpdated(revision, <that row's id>)`.

This is done whether or not the menu is open: it is the content the user opened the menu for, and
announcing it against the row asks the host to fetch one subtree. It MUST be announced against the
row, not the root: some hosts refresh only the direct children of the id they are told.

The icon and the tooltip of §3 follow every refresh at once, open menu or not.

### 4.4 Open and closed

Hosts announce an opening by `AboutToShow`, by an `opened` event, or by both, and each may name
the root or a submenu row. Some never report a close of the root.

- **An opening notice** is `AboutToShow`, `AboutToShowGroup`, or an `opened` event, for any id.
- An opening notice naming **the root** (id 0) that arrives more than `OPEN_DEBOUNCE` after the
  previous opening notice begins a **new opening**: the tray installs any held layout first, then
  marks the menu open from now. Within `OPEN_DEBOUNCE` it is the same opening, announced twice.
- A `closed` event naming **the root** marks the menu closed and installs any held layout. A
  `closed` event naming any other row changes nothing: a submenu closing is not the menu closing.
- The menu stops counting as open `MENU_OPEN_BOUND` after it was marked open. A menu that only
  swapped its content on close would otherwise keep its first content forever on a host that
  reports no close.
- Every opening notice, for any id, runs the stats fetch of §6.1.

### 4.5 Methods

| method | behaviour |
|---|---|
| `GetLayout(parentId i, recursionDepth i, propertyNames as)` → `(u, (ia{sv}av))` | the revision and the node for `parentId`. Depth 0 gives the node without children, −1 the whole subtree, and each level down decrements it. Children are variants of nodes. A `parentId` that names no row is answered with a node of that id, with no properties and no children. |
| `GetGroupProperties(ids ai, propertyNames as)` → `a(ia{sv})` | the listed rows, wherever they are in the tree; an empty list of ids means every row. Ids that name no row are left out. The root is never included. |
| `GetProperty(id i, name s)` → `v` | the property; the empty string for an id or a name that has none. |
| `AboutToShow(id i)` → `b` | an opening notice (§4.4). Answers `true` iff handling it changed the layout under `id`. |
| `AboutToShowGroup(ids ai)` → `(ai, ai)` | an opening notice for each id. Answers the ids whose layout changed, and the ids that name no row. |
| `Event(id i, eventId s, data v, timestamp u)` | `opened` and `closed` as §4.4, `clicked` as §4.6; any other event is accepted and ignored. `data` and `timestamp` are not read. |
| `EventGroup(events a(isvu))` → `ai` | each event handled as `Event` would, in order. Answers the ids that name no row. |
| another member | error `UnknownMethod` |

- An empty `propertyNames` means every property; otherwise only the named ones.
- A stale id is routine here, since rows change under a host that fetched them earlier. That is
  why a query about a row that no longer exists is answered empty and not with an error.
- **`EventGroup` and `AboutToShowGroup` MUST act**, not merely answer. A host that sees `Version`
  3 or above sends every click through `EventGroup` and never falls back to `Event`: a tray that
  answered it without acting would have a menu on which nothing can be clicked.
- The reply to a call is sent before the work the call triggers (a stats fetch, showing a
  folder), and never waits on it (§5.1).

Properties of the interface: `Version` `u` 3, `Status` `s` `normal`, `TextDirection` `s` `ltr`,
`IconThemePath` `as` empty. `Properties`, `Introspectable` and `Peer` calls are answered by the
rules of §3.2, with `com.canonical.dbusmenu` as the object's one interface.

### 4.6 Click

Find the row with the event's id anywhere in the tree. If it exists, is an item and is enabled,
run its action (§6). Otherwise drop the click.

A dropped click is the intended outcome for a row that changed after the host fetched it: it
never fires whatever took that row's place.

### 4.7 Signals

`LayoutUpdated(revision u, parent i)` is the only signal emitted. Every change, a checkmark
flipping included, is a layout update that gives the changed rows fresh ids.

## 5. Polling

### 5.1 The bus is always served

The tray MUST answer every bus call within `BUS_ANSWER_BOUND`, whatever any owner, the file
manager or the watcher is doing. No request the tray makes (to an owner, to the watcher, to the
file manager) may delay a reply to its host, and the menu opens on the content last installed.

How the tray achieves this is its own business. What a host observes is the bound.

### 5.2 Refresh

Every `TRAY_POLL_INTERVAL`, and at once after a hold switch (§6.2):

1. **Domains.** The configured domains, in config order, each with its owner socket and its
   configured mount point ([linux-desktop.md §2](linux-desktop.md#2-where-a-domain-is-mounted)).
   - A change to the config MUST be reflected within two poll intervals, with no restart: a
     domain added by the config editor appears by itself.
   - A config that is missing, unreadable, not JSON or refused by validation is **no domains**,
     for whatever reason it fails. The tray warns once per distinct reason, keeps running, and
     shows the domains once the config is repaired.
2. **Poll.** Send `status` to every domain's owner **at the same time**, each under
   `TRAY_STATUS_DEADLINE`. No answer or a refusal makes that domain unreachable. A refresh costs
   at most one deadline, however many domains there are and however many are silent.
3. **Render** with the menu model, quit label `Quit tsync tray`.
4. Set the item's icon and tooltip (§3.4) and the menu (§4.3).

A refresh that is still waiting when the next is due is not started twice.

## 6. Actions

### 6.1 Stats

On an opening notice (§4.4), unless a fetch started less than `STATS_DEBOUNCE` ago:

1. Send `stats` to every domain's owner at the same time, each under `TRAY_STATS_DEADLINE`. It is
   longer than the status deadline because the owner consults its stores to answer. A domain that
   does not answer is left out.
2. Build the stats rows ([menu-model.md §6](menu-model.md#6-stats-submenu)) and set them as the
   Stats row's children (§4.3).

Stats are fetched on opening and not at every poll: reaching every store every few seconds when
nobody is looking is a cost nobody asked for. The debounce exists because one opening may be
announced twice.

A click on the Stats row itself does nothing.

### 6.2 Hold changes

`SetPaused(p)`:

1. Send `pause` with `arg` `on` or `off` to every domain's owner at the same time, each under
   `TRAY_PAUSE_DEADLINE`. A refusal or no answer is logged as a warning naming the domain and the
   reason; the others still go.
2. When every request has ended, refresh.

The tray changes nothing locally: the checkmark shows what the owners report at the next poll,
never what was asked. A domain that was not answering at the click is not held; when it answers
again it reports its own state, and the switch then reads unchecked
([menu-model.md §2](menu-model.md#2-input-one-status-per-domain)).

### 6.3 Open folder, reveal file

- `OpenFolder(domain)`: show the domain's mount point, the one the owner reported at the last
  poll, else the configured one. A domain with neither, or an unknown domain → nothing.
- `Reveal(domain, rel)`: show `<mount point>/<rel>` selected in its folder. **A file is never
  opened**: launching the application for its type could read a body that is still being written,
  or fetch one that is not local.

### 6.4 Quit

Leave. The owners keep running.

## 7. Showing a path in the file manager

1. Build the URI: `file://` followed by the path, where every byte outside
   `A–Z a–z 0–9 - _ . ~ /` is written `%XX` in upper-case hexadecimal.
2. Call `org.freedesktop.FileManager1` at `/org/freedesktop/FileManager1`: `ShowFolders(as, s)`
   for a folder, `ShowItems(as, s)` for a file, with `[uri]` and an empty startup id, under
   `FILE_MANAGER_TIMEOUT`.
3. On any error (no such service, a timeout): run `xdg-open <folder>`, where `<folder>` is the
   folder itself or the file's parent directory, since that helper cannot select a file. The child
   is not waited for and MUST NOT be left as a zombie.

## 8. Failure behaviour, summarised

| situation | outcome |
|---|---|
| an owner socket is absent, refuses or is silent | that domain's row reads `not answering`; the others are unaffected |
| every owner is silent | the error icon, `Daemon not running`, the hold switch disabled |
| the config is missing or bad | no domains, the error icon, `No domains configured`, one warning; repaired without a restart |
| the panel is not running at start | registration fails quietly; done when the watcher appears |
| the panel restarts | registered again, with the current icon and tooltip |
| no host draws items | one warning; the tray keeps running |
| a click on a row that changed since the host fetched it | dropped |
| an owner refuses a pause | a warning; the checkmark shows what the owners report |
| the session bus closes | exit 0 |
| a second tray is started | it says so and exits 0 |

## 9. Conformance

The tray is tested as a process on a private session bus, with a scripted host. It MUST NOT need a
desktop.

Where a rule is about order (a reply is not delayed by an owner, every owner is asked before any
is given up on), the suite asserts the order of events as its doubles record them: when a request
reached an owner, when the tray hung up on it, when a reply reached the host. It does not time
them: a duration measured on a machine that runs other work fails without the tray being wrong.
Durations are asserted only where the rule is itself a duration (a held layout, a debounce), with
the margin the suite names.

**Doubles:** a private session bus; a scripted host that plays the watcher and sends any call;
owners that answer scripted replies, and the three owners of
[linux-desktop.md §6.5](linux-desktop.md#65-the-wedged-owner); a file-manager service that
records calls, and none; a config as a file.

- **Every call is answered.** Every method of both objects, an unknown member, a known member on
  an unknown interface, a call with no interface header and a call to an unknown path each get a
  reply or an error. **Binding:** that each is answered, and the error name where §3.2 gives one.
- **The bus is served while owners are silent.** With one owner that accepts and never answers,
  during a poll, a stats fetch and a hold switch, `GetLayout` and `Properties.GetAll` are answered
  while the tray's request to that owner is still outstanding: the reply reaches the host before
  the owner sees the tray hang up. The same holds with a file manager that does not answer: the
  reply comes before the fallback helper runs. **Binding:** that order. The figure of
  `BUS_ANSWER_BOUND` is checked by hand on a panel.
- **One silent owner costs one deadline.** With N domains of which one is silent, the others' rows
  are current after one `TRAY_STATUS_DEADLINE`, for N = 2 and N = 20, and with every owner silent.
  **Binding:** every owner has received its request before the tray hangs up on any; the silent
  domain reads `not answering`.
- **Ids.** Fetch the layout, change one row, send a click with that row's old id: no action runs.
  Send a click with the old id of an unchanged row: its action runs. Refresh with unchanged
  content: no id changes and no `LayoutUpdated` is emitted. Over a long run with churning rows, no
  id is ever seen on two different rows.
- **Grouped events.** A click sent through `EventGroup` runs the row's action exactly as one sent
  through `Event`; `AboutToShowGroup` marks the menu open and starts the stats fetch; each
  answers the ids that name no row.
- **An open menu is not replaced.** After an opening notice for the root, with the content
  changing at every poll, no `LayoutUpdated` naming the root is emitted; a row fetched at the
  opening is still clickable. After `closed` for the root, the next layout is announced. After
  `closed` for the Stats row's id, it is not.
- **A host that reports no close.** With no `closed` ever sent, the content becomes current
  by the first refresh after `MENU_OPEN_BOUND`, and at once at the next opening of the root.
- **The revision increases** at every `LayoutUpdated`.
- **Stats.** Before any answer the Stats row has one child, the placeholder; with no owner
  answering, one child; after the answers, the rows of the model, announced against the row's id
  with the menu open. They are still there after two polls and after a domain is added above. One
  opening announced by both `AboutToShow` and `opened` causes one fetch.
- **Hold switch.** With one owner refusing `pause`, the checkmark after the click is what the
  owners report; with one owner silent, the others are held and the click costs one deadline: every
  owner has received the request before the tray hangs up on the silent one.
- **Mount point.** With an owner reporting a mount point the config does not name, `OpenFolder`
  and `Reveal` name the reported one. With that owner silent, the configured one.
- **Reveal.** `Reveal` calls `ShowItems` with the percent-encoded URI of the file; with no
  file-manager service, the helper is run on the parent folder. No call opens the file.
  **Binding:** the method, the URI, the helper's argument.
- **Labels.** A label with underscores reaches the host with each doubled; an indented row
  starts with 4 spaces per level.
- **Panel lifecycle.** Started before the watcher, the tray registers when the watcher appears.
  When the watcher's name changes owner, the tray registers again and emits `NewIcon` and
  `NewToolTip`. With no host, it runs and warns once.
- **Signals only on change.** Two refreshes with the same status emit no `NewIcon`, no
  `NewToolTip` and no `LayoutUpdated`.
- **Session.** With no bus address and no session socket, the tray exits 1 with the message of
  §1 and no bus process was started. With the socket present, it uses it. When the bus closes, it
  exits 0. A second tray prints its line and exits 0, and one item remains on the bus.
- **Config.** Started with no config, with a file that is not JSON, and with JSON that fails
  validation, the tray runs and shows `No domains configured`; after each is repaired, the domains
  appear within two poll intervals. A config rewritten twice in quick succession ends with the
  second content shown.
- **Quit.** After Quit the process has exited 0 and every owner still answers.

**Incidental throughout:** log wording, the introspection document's text, the order of
properties in a reply.

Not automated: what each named panel draws. That each draws the icon, keeps an open menu open,
shows underscores and indentation, and delivers a click is checked by hand per panel, and the
result is recorded with the panel's name and version.

## 10. Parameters

| name | recommended | protects |
|---|---|---|
| `TRAY_POLL_INTERVAL` | 3 s | the owners from a client that asks without rest; the menu from being stale |
| `TRAY_STATUS_DEADLINE` | 1.5 s, < the poll interval | the display from one silent owner: its row must say so within a poll |
| `TRAY_STATS_DEADLINE` | 4 s | an open submenu from a placeholder that never resolves |
| `TRAY_PAUSE_DEADLINE` | 5 s | the switch from a click that never settles; long enough for the owner to make the state durable |
| `STATS_DEBOUNCE` | 1 s | the owners from two fetches per opening |
| `OPEN_DEBOUNCE` | 1 s | one opening announced twice from being taken for two |
| `MENU_OPEN_BOUND` | 60 s | the menu from a layout held forever when the host reports no close |
| `BUS_ANSWER_BOUND` | 100 ms | the panel from a tray that looks wedged |
| `FILE_MANAGER_TIMEOUT` | 5 s | a click from a file manager that does not answer, before the fallback runs |
| `WATCHER_TIMEOUT` | 5 s | registration from a watcher that does not answer |
