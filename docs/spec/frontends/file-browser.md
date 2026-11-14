# The in-app file browser

Scope: the **Files** destination of the tsync apps, Android and iOS: the folders shown, the rows,
the actions on an item and pick mode. What each platform does differently, and how it carries out
each operation, is [file-browser-differences.md](file-browser-differences.md). The interface
principles are [android-app §10.1](android-app.md#101-principles), on both platforms.

---

## 1. Problem

A domain's files are browsed in the system's file manager too, but that manager offers only what
the platform's provider interface carries. The app's browser is where every tsync operation on a
file or folder is reached, the same way on each platform.

## 2. Operations

The browser is written against these operations; each platform names how it performs them
(differences §1, §2). An operation a platform cannot perform is not offered there, and the
differences page says so.

| Operation | Effect |
|---|---|
| list | A folder's children, a page at a time, each with its kind, name, size, modification date and state (§3). |
| refresh | The folder listed again after a pull from the store. |
| new folder | A folder created under a name not already taken. |
| upload | Files from elsewhere on the device copied into a folder, under names not already taken. |
| open | A file handed to the platform's viewer or to another app. |
| share link | A URL that downloads the item, with its expiry. |
| make available offline | The item fetched and pinned: readable with the store away. |
| remove download | The item's local bytes released; a file waiting to upload keeps them. |
| rename | The item's name changed in its folder, refused onto a taken name. |
| move | The item placed in another folder of the same domain under the same name, refused onto a taken name or into the item's own subtree. |
| delete | The item, and for a folder everything under it, removed. |

## 3. Files

- **Domains.** With one domain, Files opens at its root. With several, it opens on the list of
  domains, in config order, each row a folder that descends into the domain's root; a domain that
  cannot be opened shows why on its row.
- **Trail.** A stack of folders from the root, within one domain. The title is the current folder's
  name (the domain name at the root); the path is shown and each ancestor is reachable from it, as
  is the list of domains when there are several. Back pops the trail and leaves the app at the list
  of domains, or at the root when there is one domain. The trail survives the app's process ending.
- **Listing.** Pages loaded as the list nears its end, in the order listed. While the first page
  loads: a progress indication, not an empty list. A failed listing is never shown as an empty
  folder.
- **Row.** An icon for the kind (folder, or the file's type family), the name, a second line (a
  file's size and modification date), and a **state mark**:
  - *online only*: the bytes are on the server only;
  - *downloaded*: no mark;
  - *pinned*: available offline;
  - *waiting to upload*, which takes precedence over the others.
- **Refresh.** A pull-to-refresh gesture refreshes the folder. The folder shown is kept current
  while it is on screen, and re-listed when the screen returns. A refresh keeps the scroll position
  and does not clear the list while it runs.
- **Offline.** When the platform can tell that a listing is older than the store's state, a banner
  above the list says "Offline: showing this folder as of <time>" until a fresh listing arrives. A
  folder that cannot be listed because the server cannot be reached shows "Cannot reach the server"
  with Retry instead of a list.
- **Read-only.** On a read-only domain the screen says so once per domain, and nothing that writes
  is offered.
- **Add.** One prominent control offering **New folder** (a name prompt; a taken name is shown on
  the name field) and **Upload files** (the system's file picker, several at once, into the current
  folder).
- **Tap**: a folder descends; a file opens. **Long-press or the row's menu**: the item's actions
  (§4).

## 4. Item actions

Offered in a sheet or menu titled with the item's name; each ends with a short confirmation or the
failure, never a failure reported as success.

| Action | For | What it does |
|---|---|---|
| Open | files | open; "No app on this device opens <name>" when nothing takes it. |
| Share link | all | share link; then the URL with its expiry, and Copy and Send. A paused or unreachable domain is shown with the reason. |
| Make available offline | all not pinned | make available offline. For a folder the confirmation states how many files are available offline, and how many failed when any did. |
| Keep offline longer | pinned files | make available offline again, which extends the pin. |
| Remove download | all not *online only* | remove download, with counts for a folder. |
| Rename | all, when writable | A name prompt pre-filled with the current name; rename; a taken name is shown on the field. |
| Move | all, when writable | Pick mode (§5) to choose the destination folder; then move. A taken name is shown with the reason. |
| Delete | all, when writable | A confirmation naming the item, and for a folder saying that everything in it is deleted; then delete. |
| Details | all | Name, kind, size, modified, where its bytes are, pinned until when pinned, whether it is uploaded. |

An action that walks a folder's subtree shows that it is running for as long as it does, and can be
left running: its outcome is then a notification.

## 5. Pick mode

Files, choosing a destination folder: for **Move**, and for saving into the domain where a platform
offers it (differences §1).

- Taps only navigate folders; item actions are off; **New folder** stays.
- The title says what is being placed and where: "Move <name> to <path>", the path starting at the
  domain name. The screen offers the confirmation ("Move here") and **Cancel**.
- For a Move, the item itself and everything under it are not offered as destinations, nor is any
  other domain: with several domains, pick mode stays within the item's.
- Confirming places the item, then leaves pick mode at the destination, with a confirmation naming
  the item and where it went.

## 6. Conformance

Each holds on both platforms, except where the differences page says an operation is not offered.

- With several domains, Files opens on their list; with one, at its root.
- The trail is restored after the app's process is ended.
- A first page loading shows progress; an empty list is shown only for a folder known to be empty,
  and a failed listing shows its failure and no rows.
- Each state mark is shown for an item in that state, and *waiting to upload* over the others.
- A peer's change to the folder on screen is shown without leaving it.
- A read-only domain offers no new folder, upload, rename, move or delete.
- New folder, rename and move onto a taken name change nothing and say so on the field or with the
  reason.
- Move: the item, its subtree and every other domain are not offered as destinations; a move into
  another folder keeps the item's name and contents, and the source folder no longer lists it.
- Delete of a folder removes everything under it, after a confirmation that says so.
- A folder action's outcome is reported once, as a confirmation or a notification.
