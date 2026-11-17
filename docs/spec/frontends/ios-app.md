# The iOS application

Scope: the app's screens and what the app does with the File Provider. The process model, the host
layout and the extension are [ios.md](ios.md). Files is [file-browser.md](file-browser.md), carried
out as [file-browser-differences.md §2](file-browser-differences.md#2-ios) says.

This page is a delta on [android-app.md](android-app.md). It applies:
- §6.1, the config the app writes, except where §5 says otherwise;
- §10.1, the interface principles;
- §10.7's Setup as written, with the scanner of §4.

- §10.8, the Vault screen, as §6 says.

Nothing else of android-app.md applies. Saving into the domain is §7, camera backup §8; Storage is
[ios.md §9](ios.md#9-not-yet-specified).

---

## 1. Problem

The app owns no domain: the extension owns each one. So the app does with the config, the File
Provider framework and the file system what they let it do alone: join and remove domains, register
them, tell the user which ones the Files app shows, wake the working sets, and browse and change the
domains' files through the file system, which the extension serves. Everything else, the vault
and the browser's share link and offline copies, it asks of the domain's owner through the
extension's service ([ios.md §5.4](ios.md#54-the-service)).

## 2. Structure

Until a config exists, the app shows only Setup (§4). A config that does not load shows Setup with
the core's message, as on Android. Otherwise the app has these destinations, reachable from every
screen, in this order: **Files** (the start destination), **Vault** (§6) while a domain uses an
extension, **Activity** (§2.1), and **Settings** (§5), from which Setup is reached by **Add a
domain**.

### 2.1 Activity

[activity.md](activity.md)'s screen, asked through the service
([ios.md §5.4](ios.md#54-the-service)), with these differences:

- The picker lists every configured domain, in config order. One turned off in Files says so ("Turned off
  in Files: Browse, then More, then Edit") and is asked nothing.
- The recent warnings and errors are the extension process's: one the system ended takes them with
  it, and the core log (§5, Diagnostics) keeps them.
- Camera backup's row ([activity §3](activity.md#3-below-the-domains)) is §8.6's status line with
  **Back up now**.
- Android's failed saves have no counterpart: the system holds Save to tsync's writes and hands them
  to the extension.

The app is named **tsync** on the Home Screen and in Files. Its icon is `assets/tsync-app.svg` drawn
square, one opaque 1024-pixel image whose corners the system rounds; `ios/app/make-icon.sh` renders
it and the image is committed, so a build needs no rasteriser. Files shows the same icon beside each
domain in its sidebar.

## 3. Registration and signals

**Registration** reconciles the framework's domains with the config, at every launch, on every
return to the foreground and after every change to the config. It is the pass of
[file-provider.md §9.1](file-provider.md#91-registration-app) over the domains configured with the
`android` frontend. iOS has no menu and writes no purge or reset marker, so steps 1 and 12 do not
apply and steps 3, 7 and 11 never act. Passes do not overlap.

**Removal loses what the extension has not taken.** iOS offers only the framework's remove-all mode:
edits the system has not yet handed to the extension are deleted with the domain's files. Everything
the extension accepted is in the owner's pending set, which removal does not touch. As on Android
([android-app.md §6.1](android-app.md#61-the-config-the-app-writes)), removal deletes the domain's config entry and
nothing of the core's: its local state and pending set stay until a config names it again.

**Signals.** At launch and each time the app comes to the foreground, after its registration pass,
the app signals the working set of every configured domain
([ios.md §5.1](ios.md#51-the-working-set)). Bringing the app forward is how a user refreshes what the
Files app shows at once; pushes and background runs do it otherwise
([ios.md §5.2](ios.md#52-in-the-background), [§5.3](ios.md#53-pushes)).

**Enabled state.** The framework adds a new domain turned off; the user turns it on in the Files app.
The app reads each domain's state (`userEnabled`) at launch, on returning to the foreground, and on
the framework's domain-change notification.

## 4. Setup

[android-app §10.7](android-app.md#107-setup-and-settings)'s Setup, joining over §3's registration.

- **Scan setup code** uses the system's live QR scanner (VisionKit). Where the device does not
  support it, the action is not offered and a pasted link is the only way.
- After a join, the app says which joined domains are still turned off, and how to turn them on: in
  Files, Browse, then More, then Edit.

## 5. Settings

- **Domains**: one row per domain in config order, naming it and its server, and saying "Turned off
  in Files" while it is. Each row offers **Remove**, after a confirmation naming the domain and
  saying that changes not yet uploaded from Files are lost (§3). Removing takes the domain out of
  the framework, then out of the config.
  - The app cannot end the extension's process, so there is no restart prompt: a domain removed
    while booted stays booted, unused, until the system ends that process. Joining it again before
    then serves it with the settings it booted with, as Android's *Later* does.
  - So the app keeps a SHA-256 digest of each removed domain's config entry (its keys sorted) in its
    preferences, never the entry, which holds the backend's secret. Joining a domain whose
    kept digest differs from the new entry's says that the new settings may wait for the extension to
    restart, and that restarting the iPhone applies them at once. Joining it with the same entry says
    nothing. The kept digest is dropped at that join.
  - A removal the framework refuses leaves the config as it was and shows the reason.
- **Background refresh**, under Domains, only when the system will not run it: "Background refresh
  is off for tsync: Files shows changes from other devices when you open tsync. Turn it on in
  Settings, General, Background App Refresh", or, when the device restricts it, that it is not
  available on this iPhone.
- **AutoFill**, under Domains, while it is off for tsync and a domain uses passwords:
  [passwords/ios.md §1](../extensions/passwords/ios.md#1-the-component).
- **Add a domain** opens Setup.
- **About**: the app's version and the commit it was built from.
- **Diagnostics**, a row at the end that opens a page of its own with two logs: the core log
  ([ios.md §4](ios.md#4-what-the-host-gives-the-core)) and the extension's footprint log
  ([ios.md §7](ios.md#7-memory-and-observed-behaviour)), each its last 60 lines, with **Refresh**,
  which also copies each log and its previous half (`tsync.old.log`, `footprint.old.log`) to the
  app's Documents for `devicectl`, **Share**, which offers those files to the system's share sheet
  so a tester can attach them to a report, and **Clear**. It is in every build: the log costs the extension one system call and one
  append per request (ios.md §7), and the rest runs only when asked.
- A development build, one installed from a Mac (`run-device.sh` sets `TSYNC_DEVELOPMENT`), adds to
  that page the actions that write test data or load every server:
  - **Add a local test domain**, a domain whose store is a directory in the App Group, for trying
    the extension without a server;
  - **Add the test server domain**, when the build is also given a test server from a file outside
    the repository;
  - **Run self-test**, the test that [ios.md §8](ios.md#8-conformance) runs on a device;
  - **Run browser test**, which carries out Files' operations through the browser's own code in the
    local test domain, in a folder of its own that it deletes at the end: a new folder and the same
    name again, two uploads of one file (the second numbered), a rename onto a taken name and one
    that succeeds, a move into a subfolder, a remove download and a delete. Each step's outcome
    and the verdict go to `browsertest.log` in the App Group, copied to the app's Documents like
    the footprint log. Launching a development build with `-browsertest` runs it too. It adds the
    local test domain as **Add a local test domain** does, and starts once the app's registration
    pass has registered it. It never registers the domain itself: on a fresh install, a pass that
    has not yet recorded the identity scheme removes every domain it finds;
  - launching it with `-camerabackup` turns camera backup on with "Everything" (§8.6) and runs a
    pass, for checking §8 in the simulator without its dialogs;
  - **Walk every domain**, which lists every folder of every domain through the file system, so
    that the extension pulls and then holds them all, for ios.md §8's check of a refresh pass over
    thousands of held folders. It leaves out the system's `.Trash`, which the extension does not
    serve, and runs while the app is in front. One walk runs at a time: a tap during one is ignored.
    The walk logs its start, every 100 folders, each folder it waits on and how long, each it skips,
    and its end.

  A release build offers none of them, carries no test server, and does not run the self-test at
  launch: `check-release.sh` fails one built with `TSYNC_DEVELOPMENT` or a test server (10 §5).

## 6. Vault

[android-app §10.8](android-app.md#108-vault) as written, with the Passwords tab of
[passwords/ios.md §7](../extensions/passwords/ios.md#7-in-the-app), every request through the
service ([ios.md §5.4](ios.md#54-the-service)). What differs:

- **Vault domains** are [android-app §2](android-app.md#2-components-and-process)'s set: a
  domain's server decides which extensions it uses
  ([extensions README §3](../extensions/README.md#3-opting-in)), so the app asks each configured
  domain `vault_status` at launch and each time it comes to the foreground, and a domain is in the
  set while its last answer was not refused for using no extension. The set is kept in the App
  Group's shared defaults, where the credential provider reads it
  ([passwords/ios.md §2](../extensions/passwords/ios.md#2-domains)). A domain the service does not
  reach keeps its place, and is shown *unreachable*; one turned off in Files says so, and how to
  turn it on (§4). Vault is shown while the set is not empty.
- **Unlock** derives in the app ([vault §6.4](../extensions/vault.md#64-deriving-in-the-caller)):
  `vault_slots`, then `vault_derive` off the main thread, then `vault_unlock` with `keks`, and with
  `secretKey` when the phone enrols. The secret key is the field's, or, when `vault_slots` says the
  phone is enrolled, the keychain's entry ([ios.md §4.1](ios.md#41-the-keystore)); the secret key
  field is shown only when the phone is not enrolled or that entry does not read. While it derives,
  the form shows "Unlocking…" and takes no second tap. "The keyring changed" asks for the slots
  and derives once more; a second such answer is shown. The KEKs are kept only for the one request.
  The fields are emptied once the unlock succeeds; a refused unlock keeps them, for a retry.
  `vault_unlock` is a bulk action ([07 §4.3](../07-daemon-cli.md#43-deadlines-bulk-actions-and-the-liveness-probe)):
  it waits past `service_deadline`.
- **Locked**: while no vault domain is unlocked, the screen shows no tabs, only each domain's
  form under the heading "Unlock the vault" (one domain) or "Unlock `<domain>`" (several), with
  the line "Enter the vault's passphrase to see its codes and passwords." and, below the secret
  key field, "This iPhone also needs the vault's secret key, the first time." Once one is
  unlocked the tabs return, and a locked domain's rows are its form under the same heading.
- **Fields for a secret** are secure text fields with no content type, no suggestions, no
  autocorrection and no autocapitalisation, so neither AutoFill nor the keyboard keeps them, with
  the show control of [security-model §10.6](../algorithms/security-model.md#106-vault-keys-and-passphrases).
- **Copy** writes the code, username or password to the pasteboard with `localOnly`, so Universal
  Clipboard does not carry it to another device; iOS has no sensitive marker.
- **Screens that show secrets**: iOS cannot refuse a screenshot, so the app covers its window
  while the scene is not active, which keeps them out of the app switcher.
- **Scan a QR code** uses the scanner of §4, where the device has it; otherwise the choice is not
  offered. **Import a file** uses the system's document picker.
- **Opened from elsewhere**: the app declares the `otpauth` URL scheme, so the Camera app hands a
  scanned code to tsync, which shows Android's sheet.
- **Freshness**: there are no notices; the screen asks again when the app comes to the foreground.
- **Screen lock**: while the app runs, `protectedDataWillBecomeUnavailableNotification` sends
  `vault_lock` with `reason: "screen"` to every domain that uses an extension
  ([vault §6.2](../extensions/vault.md#62-auto-lock)).

## 7. Save to tsync

A share extension, labelled "Save to tsync", that saves what another app shares into a domain. It
writes through the file system, as Files' own Save to Files does, so it links no core and keeps no
queue: the system hands each file to the domain's File Provider extension as a new item, and keeps
it until that extension has taken it.

- **What it accepts**: one to 100 items the sharing app offers as files, images or movies. Text and
  web pages alone do not offer it.
- **The sheet**: the domain (a picker when several are configured and turned on in Files), the folder,
  and for a single item its name, editable. The folder is the last one saved to in that domain,
  kept in the App Group's shared defaults by its path, else the domain's root; **Choose folder**
  lists folders from the root down, with **New folder**. A remembered folder that no longer exists
  falls back to the root. **Save** and **Cancel**.
- **Writing**: each item is copied, with a coordinated write, to the folder's user-visible URL
  (`NSFileProviderManager.getUserVisibleURL`) under its name; a name already taken there gets the
  first free one, as the app's upload picks it ([android-app §5](android-app.md#5-talking-to-the-core)):
  `report (1).pdf`. An item the sharing app offers only as data is written from that
  data. The sheet completes the request only once every write has returned: the system then holds
  the bytes, and a kill of either extension loses nothing.
- **Failure**: a write refused (the domain turned off in Files, no space) is shown with its reason
  and the item's name; the others are kept, and **Done** closes the sheet. Nothing is retried by
  the extension.
- **Afterwards**: the files appear in the folder at once, waiting to upload as any new file does;
  the share extension does not wait for the upload.
- It holds no secret and logs no file name at a level the system keeps.

## 8. Camera backup

[android-app §11](android-app.md#11-camera-backup)'s principle, on PhotoKit: every photo and video
in the photo library while backup is enabled is eventually written into the chosen domain, however
many attempts fail. Progress is a **durable record per asset**; the change token only says where the
next discovery starts. The app writes through the file system, as Save to tsync does (§7): the
system hands each file to the extension as any new file, so the app boots no core and the upload,
its retries and its staging are the extension's.

### 8.1 What is backed up

- Every asset of the user's library (`PHAsset` of source type user library), photos and videos,
  screenshots included. Assets shared with the user and hidden assets are not.
- An asset as the Photos app shows it: the full-size rendition of its edits when it has them
  (`fullSizePhoto`, `fullSizeVideo`), else its original (`photo`, `video`).
- A Live Photo as two files of one name: the still, and its video (`fullSizePairedVideo`, else
  `pairedVideo`) with the video's extension.
- An original kept only in iCloud is downloaded for the write (`isNetworkAccessAllowed`), under the
  gate (§8.6).

### 8.2 Records

One record per asset, keyed by its `localIdentifier`, in a SQLite database in the App Group
(`<group>/camera.sqlite`), which the app and the upload extension (§8.7) both open. A database
first made in the app's own container (`Library/Application Support/camera.sqlite`) is moved there
at launch, before any pass. A process holding a lock on a file of the App Group when the system
suspends it is ended, so every connection is opened for one pass or one extension run and closed
at its end, never held across a suspension:

```sql
CREATE TABLE asset (
  id TEXT PRIMARY KEY,                -- PHAsset.localIdentifier
  domain TEXT NOT NULL,               -- the target domain, frozen at first sight
  stem TEXT NOT NULL,                 -- the target path without extension, frozen (§8.5)
  ext TEXT NOT NULL,                  -- the main file's extension, frozen; '' for none
  paired_ext TEXT,                    -- a Live Photo's video extension, else NULL
  modified INTEGER NOT NULL,          -- PHAsset.modificationDate when last seen, epoch seconds
  state TEXT NOT NULL,                -- 'PENDING' | 'DONE' | 'FAILED' | 'BASELINE'
  attempts INTEGER NOT NULL DEFAULT 0,
  next_attempt INTEGER,               -- epoch seconds, set with 'FAILED'
  last_error TEXT,
  created INTEGER NOT NULL,           -- capture time, epoch seconds: the processing order
  written INTEGER NOT NULL DEFAULT 0, -- 1 once its files were written: a write again replaces them
  content_id TEXT,                    -- §8.7: the main file's content as last uploaded
  paired_content_id TEXT);            -- §8.7: the Live Photo video's
CREATE UNIQUE INDEX asset_stem ON asset(domain, stem);
CREATE TABLE job (                    -- §8.7: an upload job the system holds
  id TEXT PRIMARY KEY,                -- the job's local identifier
  asset TEXT NOT NULL,                -- asset.id
  part TEXT NOT NULL);                -- 'main' | 'paired'
CREATE TABLE meta (key TEXT PRIMARY KEY, value BLOB NOT NULL);
```

States mean what android-app §11.2 says, except `DONE`: the writes returned, so the system holds the
bytes (§7), or the listener committed every file (§8.7); and `UPLOADING`, which only §8.7 sets: the
asset's files are jobs the system holds. `meta` holds `token`, the archived `PHPersistentChangeToken` of the last discovery. The
settings are the preferences `cameraBackup` (boolean, default false), `cameraDomain` (a domain name,
default the config's first), `cameraWifiOnly` (default true), `cameraBatteryOk` (default true),
`cameraLastOutcome` (absent until a pass ran) and `cameraUploads` (§8.7), in the App Group's
defaults, moved there from the app's at launch like the database.

### 8.3 Discovery

1. With a token, `fetchPersistentChanges(since:)`; for each change's asset details, in one
   transaction with the new token:
   - an inserted asset without a record → `PENDING` (`BASELINE` during a "from now on" baseline
     pass), with its name claimed (§8.5);
   - an updated asset whose modification date differs from a `DONE` record's → `PENDING` (written
     again over the same names); a `PENDING` or `FAILED` record's → the new date;
   - a deleted asset → its record deleted. Its files stay in the domain.
2. Without a token, or when the token has expired (`persistentChangeTokenExpired`): a full discovery
   over every asset of §8.1, recording each asset without a record as step 1's insertion does, then
   the library's current token. During a full discovery that is not a baseline pass, an asset without
   a record created before the oldest record's capture time is `BASELINE`: it predates backup.

Every asset is recorded in the transaction that moves the token, so none is ever behind it without a
record.

### 8.4 Processing

`PENDING`, and `FAILED` records whose next attempt is due, in capture order:

1. Fetch the asset by id. Gone → delete the record.
2. The gate (§8.6) and the budgets: the target domain's `pendingBytes` (its owner's `status`, §2.1)
   below `staged_bytes_budget`, since the extension stages what it has not uploaded and the
   phone's storage holds it; free space at least `free_space_floor`. Over either, or the domain not
   answering → stop the pass with more work.
3. Export each resource (`PHAssetResourceManager.writeData`) into the app's temporary directory.
4. Move each into the domain with a coordinated write to its user-visible URL
   (`<stem>.<ext>`, and `<stem>.<paired_ext>`): a first write after checking no file is at either
   name, else the stem moves to its next sequence name (§8.5); a write again, for a record already
   written, over the files there, which the system sends as a change based on the version it holds, so a
   change made meanwhile on another device becomes the core's conflict copy
   ([conflict resolution §7](../algorithms/conflict-resolution.md#7-a-local-write-against-a-stale-base)).
5. Success → `DONE`, written, with the modification date. Failure (an export, iCloud unreachable, a write
   refused, the domain turned off in Files) → `FAILED`, attempts + 1, next attempt = now +
   `retry_backoff(attempts)`, last error. The temporary files are removed on every path.

`FAILED` is never terminal. The domain is never asked whether a photo is there: the record is
authoritative, so a photo deleted from the domain is not written again. A name another device took
that this phone has not yet listed is the system's collision, which it resolves by numbering the
file (`2026-08-16 14.31.04 2.jpg`).

A modification date also changes with a favourite or an album change, which writes the same bytes
again: the extension's content-addressed chunks send none of them twice.

### 8.5 Naming

android-app §11.5's names: `Camera Uploads/<yyyy>/<yyyy-MM-dd HH.mm.ss>[ (n)]<.ext>`, time =
`creationDate` in the phone's time zone at first sight, frozen with the record. The extension is the
main resource's `originalFilename`'s by §11.5's rule, frozen too: a later edit is written under the
same name, and a Live Photo video an asset gains after it was recorded is not written, having no
name. A stem is taken when a record holds it in that domain or a file is at either of its names;
`(n)` runs up to `max_name_attempts`.

### 8.6 Access, controls, schedule and gate

- **Access**: `PHPhotoLibrary` read-write authorization (persistent changes need it). *Limited*
  backs up only the selected assets and is reported as a limit; denied or restricted uploads nothing
  and says "photo access not granted".
- **Controls**, a **Camera backup** section of Settings: "Back up photos and videos"; "Back up to"
  (one configured domain; a change applies to assets seen from then on); "Only over wifi" (default
  on); "Not when the battery is low" (default on); "Back up now". Enabling asks "Everything" or
  "From now on", then for access; backup is on only once access is granted. "From now on" first
  runs a baseline full discovery (§8.3); if it cannot complete, backup stays off and says why.
  "Everything" turns every `BASELINE` record back to `PENDING`, so an earlier "From now on" leaves
  nothing out.
  Turning backup off cancels the pass. A target domain the config no longer names asks for another
  and writes nothing until one is picked.
- **Schedule**. One pass at a time, process-wide; a pass asked for during one is run after it.
  - While the app is in front: at launch, on returning to the foreground, and `trigger_delay` after
    the library's change observer last fired. Going to the background, the pass finishes the asset
    it is on (`beginBackgroundTask`) and stops.
  - In the background, two ways, since iOS wakes no app for a change to the photo library:
    - each background refresh run ([ios.md §5.2](ios.md#52-in-the-background)) also runs a pass,
      stopped between assets after `refresh_pass_budget`. Writing an asset is a local copy and the
      extension uploads it in its own process, so a short run moves several photos;
    - a `BGProcessingTask`, asked for at the end of every pass that left work and on going to the
      background while work is left, which the system runs at a time of its choosing (often
      overnight on power). Its expiration cancels the pass between assets.
  - **Back up now** runs a pass in front, ignoring the gate.
- **Gate**, before each asset: "Only over wifi" set and the path expensive or absent (`NWPath`) →
  "waiting for wifi"; "Not when the battery is low" set, not charging, and the level below
  `battery_floor` or Low Power Mode on → "battery low".
- **Status line** and outcome: android-app §11.8's, under the section's switch and as Activity's
  camera backup row (§2.1).

| Parameter | Recommended | Constraint |
|---|---|---|
| `trigger_delay` | 10 s | |
| `refresh_pass_budget` | 20 s | inside the system's ~30 s for a refresh run |
| `staged_bytes_budget` | 512 MiB | |
| `free_space_floor` | 1 GiB | |
| `retry_backoff(n)` | min(15 min × 2^(n−1), 6 h) | bounded |
| `battery_floor` | 15 % | |
| `max_name_attempts` | 1000 | |

### 8.7 Uploads by the system

On iOS 26.1 and later, when the target domain's store takes whole-file uploads, the photos go to it
through PhotoKit's background upload extension: the system sends each file itself, when and however
it chooses, with the app not running, and resumes a transfer the network cut. The listener commits
each file into the domain ([http-proxy §A4.8](http-proxy.md#a48-whole-file-uploads)), so no File
Provider extension, staging or core is involved on the phone.

**When.** `cameraUploads` is `system` when all of these hold, else `files`, which is §8.4 as before:

- the build's `upload_url_base` (below) is set and the system is iOS 26.1 or later;
- the target domain's main is an `http-proxy` store whose `url` lies under `upload_url_base`;
- its listener answers `/upload-limit` for the domain
  ([http-proxy wire §5.3](../backends/http-proxy.md#53-capabilities)).

The app decides at launch, on returning to the foreground, and when the target or the config
changes; a listener that does not answer leaves the last decision. With `system`, backup on and
access granted, the app enables the extension (`setUploadJobExtensionEnabled(true)`) and runs no
pass of its own; otherwise it disables it. Turning to `files` cancels the jobs not yet sent and turns
`UPLOADING` records back to `PENDING`.

**The build.** `upload_url_base` is the `BackgroundUploadURLBase` the extension's `Info.plist`
must declare, from the build's identifiers like the app identifier. Unset, the extension is not
built and `cameraUploads` stays `files`.

**A run** of the extension (`processJobs`), every step stopping when the system ends it
(`willTerminate`):

1. **Settle what finished.** For each job the system lists to acknowledge, with its record and part:
   - succeeded: the part's content id is the answer's `x-tsync-content-id`. The asset's last part to
     succeed makes the record `DONE`, written, with the modification date its export was taken at;
   - failed with `x-tsync-kind: exists`: the stem is taken, as a first write finding a file there
     in §8.4; the stem moves to its next sequence name (§8.5) and the record goes back to `PENDING`;
   - failed with `x-tsync-kind: denied` once: retried with a destination signed again;
   - failed with no `x-tsync-kind`, which is every transient refusal and a network failure: retried,
     with a destination signed again, by `retry(destination:)` while the system allows it, else
     the record is `FAILED` as in §8.4 step 5;
   - failed with another kind: the record is `FAILED` with the answer's reason.

   Each job is acknowledged once its record is updated, and its `job` row deleted.
2. **Discover**, as §8.3.
3. **Create jobs** for `PENDING` and due `FAILED` records, in capture order, until the system answers
   `limitExceeded`: one job per part, its resource as §8.1 picks it, the record `UPLOADING`, a `job`
   row per job. iCloud originals are the system's to download.
4. Return `processing` while jobs are in flight or records wait, else `completed`.

**A job's destination**, made when the job is created or retried:

- `POST <url>/upload?domain=<domain>&path=<stem>.<ext>&created=<creationDate, ns>`, with
  `&base=<content id>` when the part has one (a write again), signed as
  [http-proxy wire §5.7](../backends/http-proxy.md#57-whole-file-uploads) says with the domain's
  secret, from the config in the App Group, and an expiry `upload_signature_lifetime` ahead.
- "Only over wifi": `allowsExpensiveNetworkAccess` and `allowsConstrainedNetworkAccess` false.
  "Not when the battery is low" has no counterpart: the system decides when to send by its own
  power rules.

**Status.** The extension keeps `cameraLastOutcome` as a pass does, with "Uploading *n* (by iOS)"
while jobs are in flight. **Back up now** is not offered with `system`, whose schedule is the
system's.

| Parameter | Recommended | Constraint |
|---|---|---|
| `upload_signature_lifetime` | 29 days | below `upload_max_lifetime` ([security §4.4](../algorithms/security-model.md#44-upload-signatures)), with a day for a clock ahead of the listener's |

## 9. Conformance

- With no config, only Setup is shown; a config that does not load shows Setup and the core's
  message. With a config, the app opens on Files.
- Files meets [file-browser.md §6](file-browser.md#6-conformance), but for what
  [file-browser-differences.md §2](file-browser-differences.md#2-ios) leaves out; a folder listed
  in the app and in the Files app shows the same items.
- A launch with domains already registered under the current identity scheme removes and adds none.
- A domain removed from the config is removed from the framework at the next pass; a domain the
  framework refuses to remove is not deleted from the config.
- Bringing the app to the foreground signals every configured domain's working set: the extension's
  footprint log shows a change enumeration for each.
- A domain turned off in Files is shown so within a second of returning to the app, and the mark goes
  once it is turned on.
- On a device without the live scanner, Scan setup code is not offered.
- A build from TestFlight shows Domains, About and the Diagnostics row, whose page holds the two
  logs and their three actions only; Share hands over both halves of each.
- Activity, on a device: a file saved to tsync is listed under Uploads until it is uploaded; with
  the server away the state line gives the reason and the core log has the failure; Pause holds the
  uploads and Resume lets them go; a domain turned off in Files is shown so and not asked.
- With Background App Refresh turned off for tsync, Settings says so; turned on, it says nothing.
- Removing a domain and joining it again with a different server says the new settings may wait for
  a restart; joining it again from the same link says nothing.
- Vault, on a device, with a domain whose vault a computer made: the phone unlocks with the
  passphrase and the secret key, and the extension's footprint log shows its peak below the limit
  through the unlock. Locked again, it unlocks with the passphrase alone. A wrong passphrase and a
  wrong secret key are each told apart, on the field.
- After the phone restarts and is unlocked once, the vault opens unlocked, with `cached: keystore`.
- A code copied in the app pastes on the phone and does not reach a Mac through Universal Clipboard.
- An `otpauth://` QR code scanned by the Camera app opens the add sheet, and adds nothing before
  **Add**.
- Files, on a device: share link answers a URL that downloads the file; make available offline
  marks the file *pinned*, and with the server away the file still opens; remove download clears
  the mark and the file is *online only*.
- Uploads by the system, on a device on iOS 26.1 or later, with a target whose listener takes
  uploads: Settings shows uploads by iOS; with Resource Upload Test Mode on (iOS 27), a photo taken
  with the app not running is in the domain without the app opened; a 1 GB video whose upload is cut
  by airplane mode resumes from where it stopped (the listener's log shows a `PATCH`); an edited photo
  replaces the file; with "Only over wifi" nothing is sent over cellular; with the listener's
  `uploads` off, the app falls back to `files` at its next launch and the photos still arrive.
- Save to tsync, on a device: three photos shared from Photos to a remembered folder appear there
  in the app and in the Files app, and upload; a photo shared again under a taken name is saved as
  its first free name; with the domain turned off in Files the sheet says so and saves nothing.
- Camera backup, on a device: with "Everything", every library photo appears under
  `Camera Uploads` and uploads; a Live Photo gives a still and a `.mov` of one name; a photo taken
  with the app closed is written by a background run or at the next foreground; an edit made in
  Photos is written again over the same name; with "From now on", only photos taken afterwards are
  written. With the server away the records stay `FAILED` and are written once it returns; killing
  the app mid-pass writes nothing twice and loses nothing.
