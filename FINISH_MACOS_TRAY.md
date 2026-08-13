# Finishing the macOS menu

The Linux tray and the macOS menu used to be two implementations of one menu,
kept in step by hand and watched by a snapshot test that ran on the macOS
runner so a human might notice a divergence. They are now one implementation.
`lib/ui/menu/menu.ml` decides the icon, the tooltip and every row; the Linux
tray links it, and the macOS app asks the daemon for `menu` and draws what
comes back.

**None of the Swift in this branch has been compiled.** It was written on a
Linux machine with no `swift`, `swiftc` or `xcodebuild`, and the `menu` IPC
action it depends on only runs under a File Provider, so that path has never
been exercised end to end by anything. Compiling is the first thing to do, not
the last.

## What to do first

```bash
cd macos
make generate
xcodebuild -project tsync.xcodeproj -scheme TsyncApp \
  -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

Then run the daemon and ask it for a menu by hand, which is the fastest way to
see whether the contract holds:

```bash
printf '{"action":"menu"}\n' | socat - UNIX-CONNECT:"$HOME/Library/Application Support/tsync/tsync.sock"
```

## The contract

`tests/unit/menu/menu_test.expected` ends with a section titled
`== menu as JSON` holding a full worked example. That snapshot is the contract:
it is pinned on the OCaml side precisely because nothing here can compile the
client that reads it, so a field renamed in `Menu.to_json` shows up as a diff
in that file rather than as an empty menu on your machine.

Shape:

```json
{ "icon": "state-sync",
  "tooltip": "tsync — Downloading 1",
  "rows": [ { "label": "...", "enabled": true, "indent": 0,
              "action": { ... }, "icon": "...", "checked": true,
              "submenu": true },
            { "separator": true } ] }
```

`icon`, `checked` and `submenu` are present only when they apply. An action is
one of `{"openFolder": "<domain>"}`, `{"reveal": {"domain": …, "rel": …}}`,
`{"setPaused": <bool>}`, `{"stats": true}`, `{"quit": true}`, or `{}` for a row
that only states something.

Two things about it are deliberate and easy to undo by accident:

**Actions name a domain and a path under it, never a place on disk.** The
daemon cannot know where the File Provider surfaced a folder — only the app can
ask `NSFileProviderManager.getUserVisibleURL`. `StatusMenu.domainURLs` holds
that mapping and `folderURL`/`fileURL` do the resolving. A row whose domain is
not in that map gets no action rather than a broken one.

**Icons are freedesktop names**, because that is what a Linux panel looks up.
`StatusMenu.symbol(for:)` maps the four the model emits — `dialog-warning`,
`media-playback-pause`, `state-sync`, `view-refresh` — onto SF Symbols. File
rows carry names like `image-x-generic`, which the Swift ignores in favour of
`NSWorkspace.icon(forFile:)` on the label.

## Where the code is

| | |
|---|---|
| The model | `lib/ui/menu/menu.ml`, `menu.mli` — pure, no D-Bus, no toolkit, no mount paths |
| Rendered to JSON | `Menu.to_json` |
| The `menu` action | `lib/frontends/file_provider/file_provider.ml`, in the router rather than a domain handler: it spans domains, and on macOS one process holds them all |
| Swift wire types | `macos/Shared/DaemonClient.swift` — `DaemonMenu`, `DaemonMenuRow`, `DaemonMenuAction`, and `DaemonClient.menu()` |
| Swift renderer | `macos/TsyncApp/StatusMenu.swift` — 241 lines, down from 446 |

`StatusMenu` no longer decides anything. Gone from it: `summary`, `detail`,
`human`, `eta`, `trafficLine`, `rateLine`, `symbolName` and the whole
`DomainStatus` aggregation. What is left is `NSMenuItem` construction and
resolving a domain to a folder.

## Known gaps

**The stats submenu is empty.** The `Stats` row arrives with
`"submenu": true` and no children — the model marks that a submenu exists but
its contents are fetched separately, and on Linux the tray does that on
menu-open via `Tray_poll.stats`. There is no macOS equivalent. `StatusMenu`
gives such a row an empty `NSMenu` so it still opens as one rather than moving
under the pointer once contents arrive. Filling it means calling the `stats`
action per domain and rendering `Menu.stats_entries`, which is OCaml — so it
probably wants a `menu` variant that includes the submenu, at the cost of that
call reaching every backend.

**Thumbnails are gone.** They keyed off `body`, the staged-body path an upload
holds, which the menu carries no room for; putting it there would push a
macOS-only concern into a shared model. File rows show
`NSWorkspace.icon(forFile:)` on the name instead. Restoring them means either
carrying `body` on a transfer or having the app ask `preview` by domain+rel.

**The `preview` verb is now dead.** Nothing calls it: `DaemonClient.preview`
is deleted, and `handle_preview` in `file_provider.ml` plus
`File_ops.in_flight.body` exist only to feed it. Left in place deliberately —
worth removing once you are happy the menu works without thumbnails.

**Per-file upload progress does not exist.** An upload row can say how big the
file is, because the staged manifest carries `s_size`, but not how far along it
is: `lib/content/remote.ml:160` counts uploaded bytes process-wide with no key
attached. Downloads have both, because `lib/content/data.ml` attributes each
chunk fetch to the file being read. Fixing uploads is the same shape of change
— thread the key down to the chunk put — and would make upload rows read like
download ones with no menu change at all.

## What is verified, and what is not

Verified on Linux: the read-path attribution (`tests/content/pulling`, with a
deliberate break confirming it can fail), the chunk-cache signal
(`tests/content/chunk_cache`, including two concurrent readers of one group
both reporting a backend against a single GET), every menu string
(`tests/unit/menu`), and the full Linux end-to-end suite. The tray has been run
against a live daemon and its menu read back over D-Bus.

Not verified, at all: every line of Swift, and the `menu` IPC action. Both
compile-and-run for the first time on your machine.
