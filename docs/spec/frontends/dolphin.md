# Dolphin plugin — as built

> **Status: as-built snapshot (pass 1)** of `main` at `4c32fa96`. Descriptive, not normative. Shared
> rules (paths, mount discovery, the request wire, packaging) are in
> [linux-desktop.md](linux-desktop.md); findings in
> [linux-desktop-findings.md](linux-desktop-findings.md).

A KDE Frameworks 6 **file-item action plugin**: it adds entries to the file manager's context
menu for an item inside a tsync mount. It is not a KIO worker, draws no overlay and adds no
column. It runs inside the file manager's process, on the thread that draws the menu.

## 1. Registration

- Plugin file `tsyncdolphin.so` (no `lib` prefix), in `<qt6 plugin dir>/kf6/kfileitemaction/`.
- Embedded metadata:

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

- `application/octet-stream` is the type every file inherits from, so the two types cover every
  file and every folder. The host calls the plugin for any selection matching them, tsync or not;
  §2 is what makes it answer nothing elsewhere.

## 2. Building the menu

Called by the host with the selection, once per context menu. It returns a list of actions, in
this order.

1. **Selection.** If the selection is not exactly one URL, or that URL is not a local file, return
   no actions.
2. **Mounts.** Call mount discovery ([linux-desktop.md §3](linux-desktop.md#3-mount-discovery)).
3. **Resolve.** Take the URL's local path as given (no canonicalisation). Among the mounts, the
   candidates are those whose mount point equals the path, or is a prefix of it followed by `/`.
   Pick the candidate with the **longest** mount point. None → return no actions.
   - `rel` is empty when the path is the mount point, else the path after `<mount point>/`.
   - The item's display name is the last component of `rel`, or `The folder` when `rel` is empty.
4. **Share action**, always: label `Copy Share Link`; icon `tsync` from the icon theme, falling
   back to `edit-link`.
5. **State.** Send `stat` for `rel` synchronously (§3.1). If there is no reply, or the reply's `ok`
   is not `true`, return the share action alone.
6. **Offline action**: label `Keep Offline Longer` when `availability` is `pinned`, else
   `Make Available Offline`; icon `cloud-download`.
7. **Online action**, unless `availability` is `online-only`: label `Make Online Only`; icon
   `cloud-upload`.

A directory's `stat` reply has no `availability`, so a directory gets both the offline action
(labelled `Make Available Offline`) and the online action.

| item state | actions offered |
|---|---|
| owner silent, or `stat` refused | Copy Share Link |
| file, `online-only` | Copy Share Link, Make Available Offline |
| file, `cached` | Copy Share Link, Make Available Offline, Make Online Only |
| file, `pinned` | Copy Share Link, Keep Offline Longer, Make Online Only |
| directory, mount root | Copy Share Link, Make Available Offline, Make Online Only |

## 3. Requests

All requests go to the socket of the resolved mount, one connection each, per
[linux-desktop.md §4](linux-desktop.md#4-owner-requests-used).

### 3.1 Synchronous (`stat`, while the menu is being built)

1. Connect; wait at most **200 ms**. Not connected → no answer.
2. Write the request line.
3. Read until the bytes received end with `\n`, under one deadline of **300 ms** from the write.
   Deadline passed, or the connection fails → no answer.
4. Parse the bytes as one JSON object.

"No answer" and an unparseable reply are the same outcome: an empty object, whose `ok` is not
`true`. The worst case blocks the menu thread for 500 ms.

### 3.2 Asynchronous (`share`, `restore`, `evict`, on click)

The click handler returns at once; the exchange runs on the host's event loop.

1. Connect. On connection, write the request line.
2. Accumulate received bytes. While they do not end with `\n`, wait for more.
3. When they do: close the socket, parse the bytes as one JSON object.
   - `ok` is not `true` → notify (§4) with the reply's `error` text, or `The daemon refused.` when
     that text is empty or absent. Stop.
   - else run the action's success step.
4. On any socket error (cannot connect, peer closed, …): notify with the socket library's error
   text and close.

There is no deadline on this exchange.

### 3.3 Success steps

| action | request | on success |
|---|---|---|
| Copy Share Link | `share` | put the reply's `url` on the clipboard as text; notify `Share link copied to the clipboard.` |
| Make Available Offline / Keep Offline Longer | `restore` (no `keep` field in either case) | notify `<name> is available offline.` |
| Make Online Only | `evict` | notify `<name> is online only.` |

`<name>` is the display name of §2 step 3.

## 4. Notifications

One call to `org.freedesktop.Notifications.Notify` at `/org/freedesktop/Notifications` on the
session bus, sent without waiting for the reply:

| argument | value |
|---|---|
| app name | `tsync` |
| replaces id | `0` |
| app icon | `edit-link` |
| summary | `tsync` |
| body | the message |
| actions | empty |
| hints | empty |
| expire timeout | `5000` (ms) |

Every message of this plugin, success or failure, uses these same values.

## 5. Failure behaviour, summarised

| situation | outcome |
|---|---|
| discovery fails (no `HOME`, unreadable config or mount table) | no actions |
| path is under no tsync mount | no actions |
| owner does not answer `stat` within 200 ms + 300 ms | share action only |
| owner answers `stat` with a failure (e.g. `not found`) | share action only |
| click, socket cannot connect or drops | notification with the socket error text |
| click, owner replies `ok:false` | notification with the owner's `error` text |
| click, owner accepts and never answers | nothing: no notification, the socket stays open |
| notification service absent | the message is lost silently |

## 6. Tests

Two suites, both built with the plugin and neither loading it into a file manager.

### 6.1 Decode and resolve

Linked against the fake discovery object
([linux-desktop.md §3.3](linux-desktop.md#33-shared-library-contract)).

- **Every pair crosses the boundary**: three pairs, the first with both halves intact, the third
  with its space intact.
- **Asking twice** starts the runtime once and answers the same.
- **Resolution**:

  | path | result |
  |---|---|
  | `/mnt/files/a/b.txt` | socket `/run/tsync-Files.sock`, rel `a/b.txt` |
  | `/mnt/files` | rel empty |
  | `/mnt/files/media/x.mkv` | socket `/run/tsync-Media.sock`, rel `x.mkv` (inner mount wins) |
  | `/mnt/files-elsewhere/x` | no match (sibling sharing a prefix) |
  | `/home/someone/x` | no match |
  | any path, empty mount list | no match |

**Binding:** the count, the strings, which mount is chosen, the `rel`. **Incidental:** output
wording.

### 6.2 Metadata

The built plugin's metadata is read back the way the host reads it: it is valid, has a non-empty
name, and lists both `application/octet-stream` and `inode/directory`. A key in the wrong place
leaves a plugin that loads, matches nothing and reports no error; this is what the test exists for.

### 6.3 Not covered

Nothing exercises §2 steps 4–7, §3 or §4: the menu contents, the deadlines, the request lines, the
clipboard and the notifications are checked only by hand in a real file manager.

Both suites count their checks and fail when none ran.
