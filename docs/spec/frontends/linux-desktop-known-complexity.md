# Linux desktop clients: known complexity

The difficulties the Linux desktop clients are known to hold: the tray, the file-manager
context-menu plugin, mount discovery, the shared menu model, and their packaging. Each entry
states a situation, what an observer saw go wrong, why the problem is easy to get wrong again in
any language, and a check a new implementation can be run against. It names actors, orderings and
failures in the vocabulary of the spec, never how anything was coded. Each entry ends with the
rule that answers it, and each is a conformance check an implementation MUST pass.

An entry marked *incident* was observed going wrong. An entry marked *design note* was written
down as the reason for a rule, with no recorded failure before it; most of the tray's panel
behaviour is of this kind, checked by hand on one panel.

## Mount discovery and the plugin

### K1. Asking owners while the menu is drawn froze the file manager

*Incident, 1 redesign.*

- **Situation** — The plugin runs on the file manager's menu-drawing thread. To learn which mounts
  exist it asked every owner over its socket, on that thread, before the menu appeared.
- **What went wrong** — Two owners that accepted a connection and did not answer cost a third of a
  second per right-click. One owner that sent bytes with no end of line never let the menu appear:
  the file manager was frozen until it was killed.
- **Why it is hard** — It was measured only against healthy owners, where it cost a quarter of a
  millisecond. Anything with a process at the other end can stop answering, and the thread that
  waits is not the plugin's to block.
- **How to tell** — With every owner replaced by one that accepts and stays silent, and by one
  that trickles bytes with no terminator, a right-click inside and outside a mount returns its
  menu within a fixed bound. Binding: discovery itself talks to no process; the bound holds
  whatever the owners do.

Answered by: [linux-desktop.md §3.1](linux-desktop.md#31-the-answer) (discovery talks to no process), [dolphin.md §3.1](dolphin.md#31-while-the-menu-is-built-stat) and its conformance (the menu thread is bounded).

### K2. A timeout per wait is not a deadline

*Incident, same event as K1.*

- **Situation** — A client reads a reply line from an owner with a timeout applied to each wait
  for more bytes.
- **What went wrong** — Every chunk received restarted the timeout, so a reply that never ended
  was waited for without end.
- **Why it is hard** — A per-wait timeout reads as a bound and passes every test where the peer
  is either prompt or silent. Only a peer that keeps sending defeats it.
- **How to tell** — Against an owner that sends one byte at an interval shorter than the timeout
  and never ends the line, every request of every client ends by its stated deadline. Binding:
  the deadline covers the whole exchange.

Answered by: [linux-desktop.md §4.1](linux-desktop.md#41-transport-and-bounds) (a deadline covers the whole exchange) and [§6.5](linux-desktop.md#65-the-wedged-owner).

### K3. Where a domain is mounted has three possible sources, and one was lost

*Incident, 3 changes.*

- **Situation** — A client must turn "this domain" into a folder, or "this path" into a domain.
  The config says where a mount was asked for. The owner knows where it mounted. The kernel mount
  table knows what is mounted now.
- **What went wrong** — The plugin first asked owners (K1). The tray first preferred the mount
  point the owner reported and kept the config's answer only for an owner that did not answer.
  When menu actions were changed to name a domain and a path under it, the tray kept only the
  config's answer, and a note still said the owner's report was used. Nobody saw the change:
  where config and owner agree, nothing differs.
- **Why it is hard** — The three sources agree on every ordinary machine. They differ only when a
  mount point is overridden at start, is not mounted, or is written differently from what the
  kernel lists. A rule that restates the answer in a second place drifts when the first changes.
- **How to tell** — Start an owner at a mount point the config does not name. The tray's open and
  reveal actions land in the real mount, and the plugin offers its actions there. Binding: the
  folder opened is the one mounted. Second check: a domain configured and not mounted is offered
  nothing by the plugin.

Answered by: [linux-desktop.md §2](linux-desktop.md#2-where-a-domain-is-mounted): the tray believes the owner's report, discovery the config and the mount table, and the override is a stated limit of the plugin.

### K4. Telling a tsync mount from another mount in the kernel table

*Incident, 2 fixes.*

- **Situation** — Discovery reads `/proc/self/mountinfo`. The filesystem type the owner reports
  was changed to that of a network filesystem (K5), so the type no longer said "tsync".
- **What went wrong** — Matching the type alone would have taken every sshfs mount for a domain.
  Matching the source column alone took any mount whose source was named the same, a tmpfs for
  instance, for a live domain whose socket nobody listens on.
- **Why it is hard** — Each column is under someone else's control: the type is chosen for the
  benefit of file managers, the source is free text any mount may carry. A line also has a
  variable number of optional fields before its separator, and a mount point with a space is
  written with an octal escape, so a domain whose name has a space is missed by a naive split.
- **How to tell** — A fixture table with: a mount of each reported type at a configured path, a
  real sshfs mount at a configured path, a non-FUSE mount whose source is tsync's, a configured
  path with no line, and a mount point with a space. Binding: exactly the first kind and the
  spaced one are reported, each with its owner's socket.

Answered by: [linux-desktop.md §3.2](linux-desktop.md#32-algorithm), [§3.3](linux-desktop.md#33-why-this-rule), [§6.1](linux-desktop.md#61-mount-discovery).

### K5. Browsing a mounted folder downloaded it

*Incident, 1 fix.*

- **Situation** — The file manager generates thumbnails for every file in view. It decides
  whether a mount is slow from its filesystem type alone, against a fixed list it does not let
  anyone extend.
- **What went wrong** — Opening a media library fetched every file in it: several thumbnail
  workers, each seek pulling a whole chunk, every download slot busy and reads queued behind them.
- **Why it is hard** — The cost is caused by a third party reading the mount as a local disk, and
  the only signal it accepts is a type name. Claiming a known network type is untrue about the
  transport and breaks any rule that recognised the mount by its type (K4).
- **How to tell** — With the default configuration, opening a folder of large files in the file
  manager starts no content fetch. Binding: no fetch from browsing alone; discovery still finds
  the mount.

Answered by: [fuse.md §B2](fuse.md#b2-why-the-mount-reports-fusesshfs), with [linux-desktop.md §3.3](linux-desktop.md#33-why-this-rule) for what it costs discovery.

### K6. A fault in the embedded discovery library takes the file manager with it

*Design note, settled with a test.*

- **Situation** — Discovery is a library loaded into the file manager's process, carrying its own
  language runtime. Its inputs are a config file and a mount table that may be missing or
  malformed.
- **What went wrong** — Nothing was shipped broken. The rule was fixed at the start: an error
  that escapes the library is a crash of the host, so the entry point must answer for every input.
- **Why it is hard** — Inside its own process the same error is a message and an exit code.
  Totality is a property of the outermost entry point, and a test of the inner logic does not
  show it.
- **How to tell** — Call the public entry point with no home directory, no config, an unreadable
  mount table and a malformed one. Binding: it returns an empty answer each time and the host
  survives. The runtime is started once, from one thread, however often it is asked.

Answered by: [linux-desktop.md §3.1](linux-desktop.md#31-the-answer) (total), [§3.4](linux-desktop.md#34-shared-library-contract), [§6.1](linux-desktop.md#61-mount-discovery), [§6.2](linux-desktop.md#62-shared-library).

### K7. A shared object that links on one architecture and not on another, or is not found at run time

*Incident, 2 fixes and 1 trap met while building.*

- **Situation** — The discovery library is a shared object; the tray's bus binding is compiled
  native code linked into one. Packages are built for two architectures.
- **What went wrong** — Code compiled without position independence linked on one architecture
  and was refused on the other, once for each component and on opposite architectures. A library
  whose recorded name differed from its file name linked and then failed to load.
- **Why it is hard** — Each failure is silent on the machine most at hand. A load failure appears
  only at run time, inside the host, as an absent menu.
- **How to tell** — Build and load both components on every packaged architecture. Binding: the
  installed plugin resolves the discovery library by its recorded name from the installed
  location.

Answered by: [linux-desktop.md §3.4](linux-desktop.md#34-shared-library-contract) and [§6.2](linux-desktop.md#62-shared-library) (every packaged architecture).

### K8. A plugin taken from the build directory looks for its library on the build machine

*Incident, 1 fix.*

- **Situation** — The plugin finds the discovery library along a search path recorded in it. The
  build records a path into the build tree; only an install step rewrites it.
- **What went wrong** — A package shipped a plugin whose search path named a directory of the
  build machine. The check that its libraries resolved passed, because it ran where that
  directory still existed. Another distribution's package build refused the same artifact.
- **Why it is hard** — The check consulted the build machine, not the artifact. It could not fail
  where it ran.
- **How to tell** — Inspect the packaged plugin's recorded search path. Binding: no build
  directory in it. The check must be shown to fail against a deliberately bad artifact.

Answered by: [linux-desktop.md §5.1](linux-desktop.md#51-packages) and [§6.3](linux-desktop.md#63-packages) (checked on the package, and seen to fail).

### K9. A plugin that loads, matches nothing and reports no error

*Incident, 3 occurrences.*

- **Situation** — The file manager finds plugins by scanning a directory, reads their metadata,
  and calls those whose declared types match the selection.
- **What went wrong** — A metadata key at the wrong nesting level read back empty: the plugin
  would have loaded and never been called. The install directory was computed before the toolkit
  was located and named a place nothing scans. An early discovery listed a directory with a
  filter that leaves out sockets and found no owner at all.
- **Why it is hard** — Each failure produces a normal desktop with no menu entry. There is no
  error to read.
- **How to tell** — Read the built plugin's metadata the way the host does. Binding: it is valid
  and covers every file and every folder. Check the installed path against the directory the host
  scans.

Answered by: [dolphin.md §1](dolphin.md#1-registration), [dolphin.md §7](dolphin.md#7-conformance) (metadata), [linux-desktop.md §6.3](linux-desktop.md#63-packages) (installed where the host scans).

### K10. Which domain a path belongs to

*Incident, 2 fixes outside the clients, 1 test in the plugin.*

- **Situation** — A file manager holds a path and nothing else. Several domains are mounted, and
  one may be mounted inside another.
- **What went wrong** — A share of an absolute path was resolved against the default domain, so a
  path under another domain failed as not found. The owner's share request took only an internal
  reference, which a file manager does not hold.
- **Why it is hard** — With one domain every rule gives the right answer. A prefix test without a
  path separator also takes a sibling directory whose name starts with the mount's name.
- **How to tell** — With a mount, a mount inside it, and a sibling sharing its prefix. Binding:
  the innermost mount wins, the sibling matches nothing, the mount itself yields the empty
  relative path, and the request names the item by that relative path.

Answered by: [dolphin.md §2](dolphin.md#2-building-the-menu) step 3 and [dolphin.md §7](dolphin.md#7-conformance) (resolution).

### K11. What the menu offers when the owner does not say

*Design note.*

- **Situation** — Which offline action fits an item depends on where its content is, which only
  the owner knows, and a menu is drawn once.
- **What went wrong** — Nothing recorded. The rule chosen: an owner that does not answer in time
  costs a beat and the menu then offers only what needs no knowledge of the item.
- **Why it is hard** — An action offered on unknown state is a guess, and a menu cannot be
  corrected after it is shown.
- **How to tell** — With a silent owner, the menu appears within the stated bound and holds no
  offline action. Binding: the bound, and the absence of state-dependent actions.

Answered by: [dolphin.md §2](dolphin.md#2-building-the-menu) step 4.

## Tray and panel

### K12. Replacing the layout under an open menu closes it

*Design note, observed by hand on one panel.*

- **Situation** — The tray recomputes its menu on every poll. The host is told to refetch, not
  handed an update.
- **What went wrong** — A host told that the whole layout changed drops the menu it is drawing: a
  menu that closes under the pointer, and cannot be clicked while anything is transferring.
- **Why it is hard** — Holding the new layout until the menu closes depends on the host reporting
  the close, and some hosts never do. A menu that only swaps on close would then keep its first
  content forever.
- **How to tell** — With the menu open and the content changing every poll, the menu stays open
  and a row can be clicked. With a host that reports no close, the content still becomes current
  within a stated bound. Binding: no root-level layout change while open; an upper bound on
  staleness.

Answered by: [linux-tray.md §4.3](linux-tray.md#43-installing-a-layout) and [§4.4](linux-tray.md#44-open-and-closed).

### K13. A click names a row by a number the host remembered

*Design note, verified by hand.*

- **Situation** — Rows appear and disappear every few seconds. The host sends a click with the id
  it fetched earlier.
- **What went wrong** — If ids are positions, a late click fires whatever took the row's place:
  the wrong file is revealed. If every refresh retires all ids, a click on a row that never
  changed is lost.
- **Why it is hard** — The two failures pull in opposite directions, and both depend on the delay
  between the host's fetch and the user's click.
- **How to tell** — Fetch the layout, change one row, click the old id of that row: nothing
  happens. Click the old id of an unchanged row: its action runs. Refresh with unchanged content:
  no id changes and no layout change is announced. Binding: an id is never reused for another row.

Answered by: [linux-tray.md §4.1](linux-tray.md#41-state), [§4.3](linux-tray.md#43-installing-a-layout), [§4.6](linux-tray.md#46-click).

### K14. A submenu filled on demand must survive the next redraw, and must never be empty

*Incident, 2 fixes, plus a design note.*

- **Situation** — The statistics submenu is fetched when the menu opens, because answering it
  makes each owner reach every store. The main menu is redrawn on every poll.
- **What went wrong** — On one client the submenu was never filled and opened onto nothing. Two
  clients each spelled their own placeholder and failure text. Without care the poll after the
  answer puts the placeholder back, and a new row above the submenu row empties it. Some panels do
  not open an empty submenu at all.
- **Why it is hard** — The submenu's content belongs to whoever fetched it, not to the periodic
  model, so two sources write one tree. A row that becomes a submenu only when its content arrives
  moves under the pointer.
- **How to tell** — Open the menu, wait for the figures, wait two polls, add a domain: the
  figures are still there. Before any answer, and with no owner answering, the submenu holds one
  row. Binding: never empty; content kept across redraws; the row is a submenu from the start;
  placeholder and failure text come from the model.

Answered by: [linux-tray.md §2](linux-tray.md#2-startup) step 5, [§4.3](linux-tray.md#43-installing-a-layout), [menu-model.md §6](menu-model.md#6-stats-submenu), [menu-model.md §7](menu-model.md#7-json-form).

### K15. Every call left unanswered costs the host its full timeout

*Design note.*

- **Situation** — The tray answers bus calls itself. Hosts send calls the tray has no use for:
  activation, scroll, introspection, properties of interfaces it does not have.
- **What went wrong** — An unanswered call holds the caller for its timeout, about 25 seconds of
  a menu that looks wedged. Work done before replying (asking every owner, starting a file
  manager) delays the menu the same way.
- **Why it is hard** — Nothing fails. The cost is paid in the host, and only on the calls nobody
  thought of.
- **How to tell** — Send every method of both objects, an unknown method, and a call on an
  unknown interface. Binding: each gets a reply or an error at once. For calls that trigger work,
  the reply is on the wire before the work starts.

Answered by: [linux-tray.md §3.2](linux-tray.md#32-calls-answered-at-the-item-path), [§4.5](linux-tray.md#45-methods), [§5.1](linux-tray.md#51-the-bus-is-always-served).

### K16. Hosts disagree

*Design note, 6 points.*

- **Situation** — StatusNotifierItem and dbusmenu are implemented by several panels.
- **What went wrong** — As recorded by the author: hosts differ on the item's interface name; on
  what an absent visibility property means; on whether they announce an opening by one call, the
  other, or both; some read the pixmap property unconditionally; one animates the attention state;
  a single underscore in a label is taken as a mnemonic marker and removed, so a file name loses
  its underscores. There is no property for indentation.
- **Why it is hard** — Each point works on the panel at hand. The protocols leave defaults open.
- **How to tell** — Per host: the icon is drawn, a label with underscores reads intact, one
  opening causes one fetch, nested rows read as nested. Binding: the observable result on each
  named host.

Answered by: [linux-tray.md §3.2](linux-tray.md#32-calls-answered-at-the-item-path), [§3.3](linux-tray.md#33-properties), [§4.2](linux-tray.md#42-row-properties), [§4.4](linux-tray.md#44-open-and-closed), [§4.5](linux-tray.md#45-methods) (grouped events).

### K17. The panel restarts, starts late, or does not exist

*Design note.*

- **Situation** — The item is drawn by a host found through a watcher. At login the tray may
  start first. A panel may restart. A GNOME session without its extension has no host.
- **What went wrong** — The known failure of this protocol: the icon disappears after a panel
  restart and stays gone, or returns showing what it said at login.
- **Why it is hard** — Registration is a one-time act against a party with its own lifetime.
- **How to tell** — Start the tray before the watcher; restart the watcher; run with no host.
  Binding: the icon appears when the watcher does, reappears with the current icon and tooltip
  after a restart, and with no host the tray keeps running and says so once.

Answered by: [linux-tray.md §2](linux-tray.md#2-startup) step 6 and [§3.1](linux-tray.md#31-registration).

### K18. No session bus, or the wrong one

*Design note.*

- **Situation** — The tray is started outside a desktop session, for instance over ssh, with no
  bus address in its environment.
- **What went wrong** — The bus library, left to itself, starts a private bus that no panel is
  on: a tray that runs forever and is drawn nowhere. The library may also end the process itself
  when the connection drops, with no message.
- **Why it is hard** — Both defaults are silent.
- **How to tell** — With no address and no standard session socket, the tray exits with a
  message and a failing status. With the socket present it uses it. When the bus closes, it exits
  cleanly. Binding: no private bus is ever started.

Answered by: [linux-tray.md §1](linux-tray.md#1-command-line-and-exit) and [§2](linux-tray.md#2-startup) steps 1 and 2.

### K19. Two trays

*Design note.*

- **Situation** — The autostart entry and a user both start a tray.
- **What went wrong** — Two icons, and two processes acting on the same hold switch. A second
  tray that queues for the name takes over silently whenever the first exits.
- **Why it is hard** — Queueing is the default of name ownership.
- **How to tell** — Start a second tray: it says one is running and exits successfully, at once.
  Binding: one item on the bus.

Answered by: [linux-tray.md §2](linux-tray.md#2-startup) step 3.

### K20. One silent owner must not freeze the tray

*Design note.*

- **Situation** — The tray has one loop and one owner per domain.
- **What went wrong** — A request with no deadline to a wedged owner stops the icon, the menu and
  every bus reply.
- **Why it is hard** — Asking owners in turn makes the cost grow with the number of domains.
- **How to tell** — With one owner that accepts and never answers, the other domains' rows stay
  current and a poll costs at most one deadline, whatever the number of domains. Binding: the
  bound is independent of the domain count.

Answered by: [linux-tray.md §5.1](linux-tray.md#51-the-bus-is-always-served) and [§5.2](linux-tray.md#52-refresh) step 2.

### K21. The hold switch shows what the owners did, and holds everything

*Incident, 1 fix, plus a design note.*

- **Situation** — The switch acts on every owner. An owner may be unreachable or refuse.
- **What went wrong** — The switch first held uploads only: a rename or a delete was still
  published, and a peer's change still applied, while the user had asked for quiet. The row was
  renamed with the fix.
- **Why it is hard** — A checkmark set from the click shows the request, not the result. The rule
  from the start is to change nothing locally and read the state back on the next poll.
- **How to tell** — Refuse the request at one owner: the checkmark after the click reflects what
  owners report. Binding: the state shown is read back, never assumed.

Answered by: [linux-tray.md §6.2](linux-tray.md#62-hold-changes), [menu-model.md §2](menu-model.md#2-input-one-status-per-domain) (all paused, over reachable domains), [07 §2.6](../07-daemon-cli.md#26-pause) (what a pause holds).

### K22. A config that is missing or half written is not a reason to die

*Design note.*

- **Situation** — The tray reads the config at start and when its modification time moves. A
  user may be editing it.
- **What went wrong** — The stated intent: a missing or unparseable config is an empty list of
  domains, the tray says so and keeps running. The reload on modification time exists so a domain
  added by the config editor appears without a restart.
- **Why it is hard** — "Unparseable" has several causes that fail in different ways, and only
  some were handled.
- **How to tell** — Start with no config, with invalid JSON, with valid JSON that fails
  validation; then repair it. Binding: the tray runs throughout, shows that no domain is
  configured, and shows the domains after the repair.

Answered by: [linux-tray.md §5.2](linux-tray.md#52-refresh) step 1.

### K23. Reveal a file, never open it

*Design note.*

- **Situation** — A menu row names a file that is being transferred.
- **What went wrong** — Opening it launches the application for its type, which may pull down or
  read a body still being written.
- **Why it is hard** — Opening is the default action of every desktop helper; the fallback helper
  cannot select a file.
- **How to tell** — Click a file row. Binding: the folder is shown, with the file selected where
  the file manager supports it; no application is started on the file.

Answered by: [linux-tray.md §6.3](linux-tray.md#63-open-folder-reveal-file) and [§7](linux-tray.md#7-showing-a-path-in-the-file-manager).

### K24. Icons that are missing from the theme, or invisible on the panel

*Incident, 2 fixes.*

- **Situation** — The panel looks icons up by name in the user's theme and recolours symbolic
  icons to its foreground.
- **What went wrong** — Icons borrowed from the theme were chosen for being present, and one name
  from the specification was in neither common theme. Own icons then drew black on a dark panel:
  each toolkit reads a different half of the recolouring contract, and a stroked glyph is filled
  in the wrong colour by one of them.
- **Why it is hard** — Without a toolkit there is no way to ask a theme what it has. An icon that
  is right on one panel is invisible on another.
- **How to tell** — On a dark and a light panel of each toolkit family, the four states are
  visible and distinct. Binding: own icons installed where every theme inherits them; file rows
  use only generic names.

Answered by: [linux-desktop.md §5.3](linux-desktop.md#53-icons), [§6.4](linux-desktop.md#64-icons), [menu-model.md §3](menu-model.md#3-formatters) (generic file icons only).

## Menu model

### K25. Two copies of the menu's wording

*Incident, 3 fixes.*

- **Situation** — Two clients on two platforms show the same menu. One cannot link the model.
- **What went wrong** — The second menu was a hand copy. A size read differently in the tray and
  in the status command, because two formatters used different bases. Nothing on the building
  side could compile the other client, so a renamed field would have shown as an empty menu there.
- **Why it is hard** — The copies agree on the day they are written, and no machine builds both.
- **How to tell** — One snapshot of every string and of the serialised menu. Binding: every
  label, the field names and nesting of the serialised form; a size prints the same in the menu
  and on the command line.

Answered by: [menu-model.md](menu-model.md) as the one source of every string, [menu-model.md §3](menu-model.md#3-formatters) (one byte formatter), [menu-model.md §8](menu-model.md#8-conformance).

### K26. A count and the rows under it disagreed

*Incident, 2 fixes.*

- **Situation** — The owner reports a number of fetches in flight and, separately, the files
  worth a row.
- **What went wrong** — A domain read "Downloading 9" above two rows. The icon read idle above a
  row that said a file was downloading, because the instantaneous count is zero between one fetch
  and the next.
- **Why it is hard** — Two figures with one name count different things, and one is sampled at
  an instant.
- **How to tell** — Status with a fetch count of nine and two rows, then of zero and one row.
  Binding: the number equals the rows where there are rows, and the icon shows activity whenever a
  row does.

Answered by: [menu-model.md §2](menu-model.md#2-input-one-status-per-domain) (download count, transferring).

### K27. Rows that state nothing, or something untrue

*Incident, 4 fixes.*

- **Situation** — Owners do not report every figure: a frontend may keep no counters, an upload
  has no per-file progress.
- **What went wrong** — A row of zeros claimed nothing was read. "0 B sent" stood under an idle
  menu. A header repeated the domain row below it. A file row said only "downloading", which
  answers neither how much nor when. A time estimate must not run out while bytes still move.
- **Why it is hard** — Absent and zero look alike once parsed, and a default of zero is the easy
  choice.
- **How to tell** — A status with figures absent, and one with them zero. Binding: an unreported
  figure produces no row; the traffic line appears only when something was sent or is owed; under
  a minute is said in words.

Answered by: [menu-model.md §2](menu-model.md#2-input-one-status-per-domain) (absent is not zero), [§3](menu-model.md#3-formatters) (time left), [§5](menu-model.md#5-rows), [§6](menu-model.md#6-stats-submenu).

### K28. A property derived from a label that was shortened for display

*Incident, 1 fix.*

- **Situation** — A long file name reaches its row with an ellipsis. A client picks the file's
  icon.
- **What went wrong** — The icon was asked for a type ending in an ellipsis and came back
  generic.
- **Why it is hard** — The label is the nearest string to hand. It works for every short name.
- **How to tell** — A name longer than the limit with a known extension. Binding: the icon is
  that of the real type; the serialised form carries the full relative path in the row's action
  and no icon name of another platform.

Answered by: [menu-model.md §3](menu-model.md#3-formatters) (the icon comes from the full name) and [§7](menu-model.md#7-json-form) (a reader derives it from the action's path).

### K29. Quitting the icon is not quitting tsync, and a row names no absolute path

*Incident, 2 changes.*

- **Situation** — The model serves clients whose icons have different names and whose domain
  folders are in places only the client knows.
- **What went wrong** — A quit label in one platform's vocabulary read wrong on the other, and
  suggested that syncing would stop. A row carrying an absolute path was wrong for a client that
  must ask its platform where the folder is.
- **Why it is hard** — Both are true on the platform they were written on.
- **How to tell** — Binding: the quit label is the caller's; every action names a domain and a
  relative path; after Quit the owners are still running.

Answered by: [menu-model.md §1](menu-model.md#1-output), [§5](menu-model.md#5-rows) row 7, [linux-tray.md §6.4](linux-tray.md#64-quit).

## Packaging

### K30. Checks that passed while testing nothing

*Incident, 6 occurrences.*

- **Situation** — Packages are checked in the container that built them. Parts of the tree build
  only on one platform.
- **What went wrong** — Running a binary proved nothing about its declared dependencies, because
  the build container has the development packages. Installing proved nothing about maintainer
  scripts, which do nothing where no service manager runs. A moved component left the package
  jobs asking for a path that no longer existed, unseen by an ordinary build. A package made
  entirely of platform-gated parts broke the other platform's build, and a gated library went
  uncompiled without notice. A plugin skipped when its toolkit is absent would leave a package
  around a missing file. A repository uploads well and still fails at a client's first update.
- **Why it is hard** — The absence of a failure was read as success. Each check could not fail in
  the place it ran.
- **How to tell** — For each package: the declared dependencies include what the split is for
  and exclude what it is against; the scripts are in the package; the build fails when the
  plugin's toolkit is absent; a client installs from the repository as served. Each check is
  shown failing once against a bad input.

Answered by: [linux-desktop.md §6.3](linux-desktop.md#63-packages); the general rule is [09 §10](../09-tests.md#10-assertion-discipline).

### K31. One file, one owning package; one name, one artifact

*Incident, 2 fixes.*

- **Situation** — The tray and the plugin ship apart from the base package, so that a headless
  machine carries no bus or toolkit library, and each is pinned to the exact build beside it
  because they speak to the owner.
- **What went wrong** — An output name keyed on distribution and architecture alone let the
  second package overwrite the first. The application icon was wanted by two packages and a file
  has one owner.
- **Why it is hard** — Both appear only when the second package is added.
- **How to tell** — Binding: every package of a build has a distinct artifact; no file is listed
  by two packages; the base package pulls no desktop library.

Answered by: [linux-desktop.md §5.1](linux-desktop.md#51-packages) and [§6.3](linux-desktop.md#63-packages).

### K32. An autostart tied to a systemd session target never starts on half the desktops

*Design note.*

- **Situation** — The tray must start with the graphical session on desktops that are and are
  not systemd-managed.
- **What went wrong** — A user unit wanted by the graphical session target is silently never
  started where the session does not populate that target.
- **Why it is hard** — It works on the two largest desktops.
- **How to tell** — Log in on a desktop of each kind. Binding: the tray runs after login, and the
  entry is visible in the desktop's own startup list.

Answered by: [linux-desktop.md §5.2](linux-desktop.md#52-autostart).
