# The in-app file browser: where the platforms differ

Scope: how each app carries out [file-browser.md](file-browser.md)'s operations, and what each adds
to it or leaves out. Everything file-browser.md says holds unless this page says otherwise.

---

## 1. Android

The app calls the domain's owner through the bridge ([android-app §5](android-app.md#5-talking-to-the-core)),
off the UI thread; a failure shows the reply's `error` and the app decides what to offer from its
`code`.

| Operation | Carried out by |
|---|---|
| list | `list_dir`, a page at a time with `after`; a row's state from `online-only`, `cached`, `pinned` and `isUploaded` |
| refresh | `list_dir` with `"pull":"now"`; the folder on screen is observed ([android-app §7.1](android-app.md#71-observed-folders)) and re-listed on a `changed` notice naming it and on `recovered` |
| new folder | `mkdir`, exclusive; `exists` is the taken name |
| upload | [android-app §10.6](android-app.md#106-saving-into-the-domain), into the current folder |
| open | a view intent on the documents provider's address of the file, with its MIME type and a read grant, through the system chooser |
| share link | `share` |
| make available offline | `restore`; a folder's counts are the reply's |
| remove download | `evict`; a folder's counts are the reply's |
| rename | `rename` in place with `noreplace: true` |
| move | `rename` into the destination under the same name with `noreplace: true` |
| delete | `delete`, or `rmdir` for a folder |

- **Domains.** A domain row's tap boots the domain; one the core refuses at boot shows the core's
  sentence on its row, and Settings offers its **Remove**.
- **Offline.** A listing answered `outdated` shows the banner, with the folder's `pulledAt` as its
  time; `unreachable` is the server that cannot be reached.
- **Read-only.** From the rows' `readOnly`.
- **Trail.** Kept as `(reference, name)` pairs, restored after process death and configuration
  changes.
- **Pick mode** also saves into the domain: the share target and Upload files (android-app §10.6),
  titled "Save N files to <path>" with "Save here".

## 2. iOS

The app has no owner of its own: the File Provider extension owns every domain
([ios.md §2](ios.md#2-processes-and-ownership)), and the app reaches a domain's files through the file
system, as any app would, from the root the framework gives it for the domain. Every read and write
goes through file coordination, which the system hands to the extension; it is never made on the
main thread.

| Operation | Carried out by |
|---|---|
| list | the folder's contents with their resource values: kind, size, modification date, whether the bytes are downloaded, whether the item is uploaded |
| refresh | the domain's working set signalled ([ios.md §5.1](ios.md#51-the-working-set)), which starts a refresh pass, and the folder read again once the system reports it changed, or after `refresh_patience` |
| new folder | a coordinated create of the directory; a name already taken fails it |
| upload | the system's document picker, copying; each file a coordinated write into the current folder, a taken name numbered as [android-app §5](android-app.md#5-talking-to-the-core) numbers one |
| open | the system's preview of the file, read through coordination; its share control hands the file to another app |
| remove download | the system's eviction of the item; one the system refuses (an open file, an edit not yet taken) is reported with its reason |
| rename, move | a coordinated move to the new place; a taken name fails it and changes nothing |
| delete | a coordinated delete |

- **Not offered** until the app can reach the extension's owner
  ([ios.md §9](ios.md#9-not-yet-specified) item 1): share link, make available offline, keep offline
  longer, the *pinned* mark, and pinned until in Details.
- **Listing.** The system answers a folder whole, so there are no pages. A folder the system has
  not enumerated yet fails to read until the extension has answered: the app shows progress and
  reads again each second, up to `first_listing_patience`, then shows the failure with Retry.
- **Kept current.** A file presenter on the folder on screen; the folder is read again when it
  reports a change below it.
- **Offline.** The system's listing carries no age, so no offline banner is shown; a read that fails
  with the framework's server-unreachable error is the server that cannot be reached.
- **Read-only.** A domain whose root is not writable.
- **Domains.** A domain turned off in Files is not opened: its row says "Turned off in Files" and
  how to turn it on ([ios-app §4](ios-app.md#4-setup)).
- **Counts.** Remove download of a folder is one eviction, so its confirmation has no counts.
- **Trail.** Kept as paths from the domain's root, restored when the app is started again.
- **No save into the domain** from other apps: the share extension is ios.md §9 item 2.

| Parameter | Default | Note |
|---|---|---|
| `first_listing_patience` | 30 s | how long a folder the system has not enumerated yet is read again; a first pull of a large folder takes several seconds on a device |
