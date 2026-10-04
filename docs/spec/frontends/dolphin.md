# Dolphin plugin

A KDE Frameworks 6 **file-item action plugin**: it adds entries to the file manager's context menu
for an item inside a tsync mount. It is not a KIO worker, draws no overlay and adds no column. It
runs inside the file manager's process, and its menu is built on the thread that draws the menu.

Shared rules (roles, mount points, mount discovery, the request transport, packaging) are in
[linux-desktop.md](linux-desktop.md).

The one constraint that shapes everything here: **the thread that builds the menu is not the
plugin's to block.** A user is waiting for a menu, and anything with a process at the other end
can stop answering.

---

## 1. Registration

Compatibility surface: the plugin file is `tsyncdolphin.so` (no `lib` prefix), installed in
`<Qt 6 plugin directory>/kf6/kfileitemaction/`.

Embedded metadata:

```json
{
    "KPlugin": {
        "Description": "Share links and offline availability for files and folders in a tsync mount",
        "MimeTypes": [
            "application/octet-stream",
            "inode/directory"
        ],
        "Name": "tsync"
    }
}
```

- The host offers a plugin for a selection whose type inherits one of the listed types. Every
  regular file's type inherits `application/octet-stream`, so the two types cover every regular
  file and every folder.
- The host therefore calls the plugin for any such selection, tsync or not. §2 is what makes it
  answer nothing outside a mount, at the cost of discovery alone.
- A metadata key at the wrong nesting level leaves a plugin that loads, matches nothing and
  reports no error. §7 checks for it.

## 2. Building the menu

Called by the host with the selection, once per context menu. It returns a list of actions.

1. **Selection.** Unless the selection is exactly one URL and that URL is a local file, return no
   actions.
2. **Mounts.** Call mount discovery
   ([linux-desktop.md §3](linux-desktop.md#3-mount-discovery)). An empty answer → no actions.
3. **Resolve.** Find the mount holding the path:
   - Normalise the path lexically (no `.` or `..` segment, no repeated or trailing `/`).
   - A mount **holds** a path when its mount point equals the path, or is a prefix of it followed
     by `/`. Among the mounts that hold the path, pick the one with the **longest** mount point.
   - If none holds it, resolve the path's symbolic links one component at a time from the root,
     and test again after each component; stop at the first resolved prefix that is a mount
     point, and take the rest of the path as it was written. The plugin MUST NOT perform a
     filesystem operation at or below a tsync mount point: that would ask an owner, on the menu
     thread.
   - Still none → no actions.
   - `rel` is empty when the path is the mount point, else the path after `<mount point>/`.
   - The item's display name is the last component of `rel`, or `The folder` when `rel` is empty.
4. **State.** Send `stat` for `rel` (§3.1).
   - Refused with `not_found` → no actions: the owner does not know the item.
   - No answer, or any other refusal → the share action alone. Which offline action fits depends
     on where the item's content is, which only the owner knows; an action offered on unknown
     state is a guess, and a menu cannot be corrected once shown. Sharing needs no such knowledge.
5. **Actions**, from the row's `kind` and `availability`:

| item | actions, in order |
|---|---|
| file, `online-only` | Copy Share Link, Make Available Offline |
| file, `cached` | Copy Share Link, Make Available Offline, Make Online Only |
| file, `pinned` | Copy Share Link, Keep Offline Longer, Make Online Only |
| directory (the mount's root included) | Copy Share Link, Make Available Offline, Make Online Only |
| symlink | Copy Share Link |

| action | label | icon |
|---|---|---|
| share | `Copy Share Link` | `tsync` from the icon theme, else `edit-link` |
| restore | `Make Available Offline`, or `Keep Offline Longer` for a pinned file | `cloud-download` |
| evict | `Make Online Only` | `cloud-upload` |

A directory row carries no availability, and its files may be in any state, so a directory gets
both offline actions. Both apply to its whole subtree
([08 §3.4](../08-frontends.md#34-evict-and-restore)).

## 3. Requests

All requests go to the socket of the resolved mount, under the transport rules of
[linux-desktop.md §4.1](linux-desktop.md#41-transport-and-bounds).

### 3.1 While the menu is built: `stat`

Synchronous, under one deadline of `PLUGIN_STAT_DEADLINE` for the whole exchange. This is the only
wait the plugin imposes on the menu thread, and it is the bound on how long a wedged owner can
delay a menu.

### 3.2 On a click: `share`, `restore`, `evict`

The click handler returns at once; the exchange runs on the host's event loop and MUST NOT block
it.

- **`share`, and `evict` of a file,** are ordinary requests: the plugin abandons one after the
  client deadline of
  [failure-model.md §8.2](../algorithms/failure-model.md#82-requests-between-processes).
- **`restore`, and `evict` of a directory,** are bulk requests
  ([07 §4.3](../07-daemon-cli.md#43-deadlines-bulk-actions-and-the-liveness-probe)): they have no
  total deadline, since a folder may take hours. While one is outstanding the plugin sends the
  liveness probe on a separate connection, at the interval and under the deadline of
  [failure-model.md §8.3](../algorithms/failure-model.md#83-parameters), and abandons the request
  when a probe misses.
- A file manager that exits, or a plugin that abandons, stops nothing: the owner finishes the
  work, and its progress is what the tray's download rows show
  ([menu-model.md §5](menu-model.md#5-rows)).
- Several actions MAY be outstanding at once. Each has its own connection and its own notices.

## 4. Outcomes

Every click ends in exactly one final notice (§5), and a bulk action on a directory begins with
one.

| action | start notice | on success |
|---|---|---|
| share | none | put `url` on the clipboard as text; `Share link copied to the clipboard. It expires on <date>.` with `expires` as a date in the user's locale |
| restore, file | none | `<name> is available offline.` |
| restore, directory | `Making <name> available offline…` | `<name>: <restored> files available offline.` and, when `failed` > 0, ` <failed> could not be fetched.` |
| evict, file | none | `<name> is online only.` |
| evict, directory | `Making <name> online only…` | `<name>: <evicted> files are online only.` and, when `failed` > 0, ` <failed> could not be released.` |

`<name>` is the display name of §2. `restore` is sent with no `keep`: the owner's default pin
duration applies, and "Keep Offline Longer" is the same request, which extends the pin.

| failure | final notice |
|---|---|
| refusal | the reply's `error` sentence; `The daemon refused.` when it is empty or absent |
| no answer to an ordinary request | `The tsync daemon did not answer.` |
| a missed probe, or the connection lost, during a bulk request | `The tsync daemon stopped answering. The change to <name> may still complete.` |

A refusal is shown as the owner worded it: its sentence names the repair where one exists
(`paused`, for a share asked while changes are held).

## 5. Notifications

One call to `org.freedesktop.Notifications.Notify` at `/org/freedesktop/Notifications` on the
session bus:

| argument | value |
|---|---|
| app name | `tsync` |
| replaces id | the id of this action's start notice when it has one, else `0` |
| app icon | `tsync` |
| summary | `tsync` |
| body | the message |
| actions | empty |
| hints | empty |
| expire timeout | `NOTICE_TIMEOUT`; a start notice asks for no expiry, and is replaced by the final one |

- The plugin MUST NOT wait for the notification service on the menu thread.
- With no notification service, the message is lost; the action itself is unaffected.

## 6. Failure behaviour, summarised

| situation | outcome |
|---|---|
| discovery answers nothing | no actions |
| the path is under no tsync mount | no actions |
| the owner does not know the item | no actions |
| the owner does not answer `stat` within `PLUGIN_STAT_DEADLINE` | the share action only |
| click, the socket cannot connect or drops | one final notice |
| click, the owner refuses | one final notice with the owner's sentence |
| click, the owner accepts and never answers | one final notice, by the deadline or the first missed probe |
| the file manager exits during a restore | the owner completes it |
| a mount at a place the config does not name | no actions ([linux-desktop.md §2](linux-desktop.md#2-where-a-domain-is-mounted)) |

## 7. Conformance

Nothing here needs a file manager: the menu logic and the exchanges are testable as functions and
against socket doubles, and they MUST be built so.

**Resolution.** With the mounts `/mnt/files`, `/mnt/files/media` and `/mnt/spaced name`:

| path | result |
|---|---|
| `/mnt/files/a/b.txt` | the first mount, rel `a/b.txt` |
| `/mnt/files` and `/mnt/files/` | the first mount, rel empty |
| `/mnt/files/media/x.mkv` | the inner mount, rel `x.mkv` |
| `/mnt/files-elsewhere/x` | no mount (a sibling sharing a prefix) |
| `/home/someone/x`, and any path with no mounts | no mount |
| a path through a symbolic link that points into `/mnt/files/a` | the first mount, rel under `a` |

**Binding:** which mount is chosen and the `rel`.

**Menu.** For each row of the two tables of §2, a `stat` reply of that shape yields exactly those
actions, labels and order. A `not_found` refusal yields none; a silent owner yields the share
action alone.

**The menu thread is bounded.** With the owner replaced by each of the three owners of
[linux-desktop.md §6.5](linux-desktop.md#65-the-wedged-owner), and with a mount whose every
filesystem operation hangs, building the menu for a path inside and outside the mount returns
within `PLUGIN_STAT_DEADLINE` plus a margin fixed by the test. **Binding:** the bound, and that it
does not grow with the number of mounts.

**Requests.** Each click sends the request line of
[linux-desktop.md §4.2](linux-desktop.md#42-requests-used) for its action, with the `rel` of the
resolution. **Binding:** the action and `rel`. **Incidental:** key order and whitespace.

**Every click ends in one final notice.** For each action, against an owner that succeeds, one
that refuses, one that is not listening, one that accepts and never answers, and one that stops
answering the probe mid-way: exactly one final notice, with the text of §4. For a directory, the
start notice comes first and is replaced. **Binding:** the count of final notices (one), the
message, the clipboard content after a share. **Incidental:** the time a notice stays up.

**The work outlives the client.** A `restore` of a directory whose client disconnects after
sending it leaves every file of the subtree pinned once the owner is done.

**Metadata.** The built plugin's metadata, read back the way the host reads it, is valid, has a
non-empty name, and lists both types.

**Doubles:** the discovery stand-in
([linux-desktop.md §3.4](linux-desktop.md#34-shared-library-contract)); the owners above; a
notification service that records calls; a clipboard that records what it is given; a filesystem
whose operations hang.

## 8. Parameters

| name | recommended | protects |
|---|---|---|
| `PLUGIN_STAT_DEADLINE` | 500 ms | the file manager's menu thread from a wedged owner |
| `NOTICE_TIMEOUT` | 5 s | the screen from a notice that stays |
