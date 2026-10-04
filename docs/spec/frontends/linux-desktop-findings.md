# Linux desktop clients — findings of the as-built pass

Found while writing [linux-desktop.md](linux-desktop.md), [dolphin.md](dolphin.md),
[linux-tray.md](linux-tray.md) and [menu-model.md](menu-model.md) from `main` at `4c32fa96`.

**Every finding here is "read only"**: it comes from reading the code. Nothing was run. Neither
client was built, no tray was started on a session bus, no plugin was loaded into a file manager,
and no request was sent to an owner. Each finding is a suspect until a second read or a run tries
to refute it. The agenda for the normative pass.

Ranked within each group: user-visible wrong behaviour first.

## Defects

**D1. A missing or malformed config ends the tray instead of yielding no domains.** The tray
documents "a missing or unparseable config is an empty list" and catches only a failure that
carries a message. Opening a missing file and parsing invalid JSON raise other kinds of error,
which nothing catches: at startup the process dies with an uncaught error; during a refresh the
same. Only a config that parses as JSON and is then rejected by validation takes the documented
path.

**D2. `EventGroup` discards its events.** The menu advertises dbusmenu `Version` 3 and answers
`EventGroup` with an empty array without acting on any event. A host that delivers clicks through
`EventGroup` gets a menu where nothing can be clicked, and `opened`/`closed` are lost too. See V1.

**D3. Closing a submenu is taken for closing the menu.** `Event "closed"` is acted on whatever id
it names. If a host reports the Stats submenu closing while the main menu is still on screen, a
held layout is installed at once, which is the dismissal the hold exists to prevent, and the menu
stops counting as open. See V2.

**D4. The upload total and rate are read from the first domain only.** The model reads
`bytesUploaded` and `uploadBytesPerSec` once, on the stated ground that they are per process. On
Linux each domain is its own owner process, so with several domains the traffic line shows one
domain's bytes sent, and the time estimate divides every domain's pending bytes by one domain's
rate. The model's test pins "read once, not summed".

**D5. A refused pause is not reported.** The tray documents "one that refuses is logged". The reply
to `pause` is discarded, so `ok:false` is indistinguishable from success; only a transport failure
is logged.

**D6. A plugin action can wait forever, silently.** `share`, `restore` and `evict` have no
deadline. An owner that accepts the connection and never answers, or sends bytes without a newline,
leaves the socket open for the life of the file manager and shows the user nothing: no success, no
failure.

**D7. The tray's menu does not appear while a stats fetch is in progress.** `AboutToShow` is
answered before the fetch so that the menu can draw, but the fetch then holds the single thread for
up to 4 s, during which the host's `GetLayout` is not answered. With one wedged owner, opening the
menu costs 4 s. The same holds for the 1.5 s poll, the 1.5 s pause and the 5 s file-manager call.

**D8. A comment contradicts the code on where a domain's folder is.** The tray states "the daemon
reports where it actually mounted; a domain that is not answering keeps the config's answer". The
code only ever uses the config's answer.

**D9. One malformed mount-table escape empties discovery.** An escape whose three characters parse
as an octal number above 255 fails the decode; the failure propagates, and the whole answer becomes
the empty list (and the table's file handle is left open). The kernel only writes `\040`, `\011`,
`\012` and `\134`, so this needs a hostile or exotic table. The decoder also accepts three
characters that parse as octal with an underscore in them.

**D10. The build's error message names a file that does not exist.** When the discovery library is
not given, the plugin's build says to point at `tsync_mounts_ml.so`; the file is
`libtsync_mounts.so`. The fake library's path is not checked at all.

## Asymmetries

**A1. The plugin sets deadlines on `stat` and none on the three actions** (D6). The tray bounds
every request.

**A2. `status` is sent without a domain, `stats` with one.** Both go to a socket that serves one
domain.

**A3. Item `Properties.Get` on a foreign interface answers `UnknownMethod`; `GetAll` on one answers
an empty dictionary; the menu's `Get` ignores the interface name.** Three behaviours for one
question.

**A4. `GetProperty` on an unknown row answers the empty string, `GetLayout` on one an empty node,
`Properties.Get` on an unknown name an error.**

**A5. As built against the normative text.** Where [fuse.md](fuse.md) Part II and
[07 §5.8](../07-daemon-cli.md) already say something else, to be reconciled deliberately:

| point | normative text | as built |
|---|---|---|
| mount point match | symlinks in parent directories resolved; trailing slash tolerated | byte-equal to the configured string (G1) |
| plugin actions | under the client deadline; `restore`/`evict` watched with the liveness probe | no deadline, no probe (D6) |
| traffic line | every domain's sent bytes and rate | the first domain's (D4) |
| status fields | `traffic.upBytes`, `traffic.upRate` | flat `bytesUploaded`, `uploadBytesPerSec` |
| menu rows | upload rows "not actionable"; download rows `name — P%` | both reveal the file; progress is a separate row with bytes, rate and time left |
| menu JSON | `entries`, optional `icon` | `rows`, `icon` always, plus `submenuPlaceholder` |
| summary | ` · paused` when **any** domain is paused | `paused` only when **all** are |
| domain rows | not described | `<name> — <detail>`, file icons, 64-byte ellipsis, `… and N more` per list |

## Gaps

**G1. A mount point that is not written canonically is never discovered.** A configured
`mountPoint` with a trailing slash, a `..`, or a symlinked parent differs from what the kernel
lists, so the domain is absent from discovery and the plugin is silent on it. The tray opens the
configured string, which the file manager may or may not resolve.

**G2. A mount point overridden on the command line is unknown to both clients.** Starting a single
domain with an explicit mount point mounts it somewhere the config does not say. Discovery misses
it and the tray opens the wrong folder.

**G3. The plugin's path is not canonicalised either.** An item reached through a symlink into a
mount is under no mount as far as resolution is concerned.

**G4. No test covers the tray process or the plugin's menu and requests** (see
[linux-tray.md §10](linux-tray.md#10-tests), [dolphin.md §6.3](dolphin.md#63-not-covered)). The
dbusmenu id and pending-layout rules, the deadlines, the request lines and the notifications have
no automated check. The package checks run the tray with no session bus, which exercises the exit
path only.

**G5. Share is offered for a path the owner does not know.** When `stat` fails with "not found",
the share action is still offered, and clicking it produces the same "not found" as a notification.
The reason given in the code, "an action on an item whose state is unknown is a guess", is applied
to the offline actions and not to sharing.

**G6. Nothing tells the user a long `restore` is under way.** The reply comes when the whole
subtree is local. Until then the plugin shows nothing, and a per-file failure inside a directory is
logged by the owner and reported to the plugin as success.

**G7. The share expiry is fixed by the owner at 7 days** and is not shown to the user: the
notification says only that a link was copied.

**G8. Hold changes with some domains unreachable.** The row is enabled unless all are unreachable;
its checkmark needs all domains paused, and an unreachable domain is never "paused". With one
domain down the user can check the row and it reads unchecked on the next poll, though the
reachable domains are held.

**G9. A config rewritten within the mtime resolution, or whose content comes from the environment
override, is not reloaded.** The tray keys its cache on the file's mtime alone. A load that failed
is not retried until the mtime moves.

**G10. Nothing stops a second language runtime in the host.** The plugin starts the discovery
library's runtime inside the file manager and never stops it. Two extensions each embedding their
own copy is not considered.

**G11. Method calls with no interface header** are legal on the bus; the item and the menu answer
them `UnknownInterface`.

**G12. The tray lists every configured domain**, including ones with no `fuse` frontend, and gives
each a default mount point and a per-domain socket path whether or not such an owner exists.

**G13. Every notification of the plugin carries the link icon**, including the offline and online
messages and the failures.

## To verify

**V1. Which hosts send `EventGroup` and `AboutToShowGroup`.** From memory: clients built on
libdbusmenu group events when the server reports version 3 or above, which is what the tray
reports. If so, D2 makes the menu unclickable on those panels. Check the dbusmenu client
implementations of the panels named in [linux-tray.md](linux-tray.md), or run the tray under each.

**V2. Whether hosts send `Event "closed"` (and `"opened"`) with a submenu's id** while the parent
menu stays open (D3).

**V3. Whether a host keeps a menu open across `LayoutUpdated` for a subtree** but not for the
root. The whole pending-layout design rests on this; it is stated in the code and was observed by
its author, not re-checked here.

**V4. Whether the owner abandons a `restore` when its requester disconnects**, i.e. what happens to
a long restore when the file manager exits.

**V5. That `application/octet-stream` in the plugin's metadata matches every file** through type
inheritance in KF6, as the metadata test's comment implies.

**V6. The recolouring contract of the icons** (suffix plus directory for GTK, stylesheet for Qt) is
stated in the packaging and the SVGs; not checked on a panel here.

**V7. That the kernel's mount table escapes only space, tab, newline and backslash**, which bounds
D9.
