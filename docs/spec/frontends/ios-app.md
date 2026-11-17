# The iOS application

Scope: the app's screens and what the app does with the File Provider. The process model, the host
layout and the extension are [ios.md](ios.md). Files is [file-browser.md](file-browser.md), carried
out as [file-browser-differences.md §2](file-browser-differences.md#2-ios) says.

This page is a delta on [android-app.md](android-app.md). It applies:
- §6.1, the config the app writes, except where §5 says otherwise;
- §10.1, the interface principles;
- §10.7's Setup as written, with the scanner of §4.

- §10.8, the Vault screen, as §6 says.

Nothing else of android-app.md applies. Saving into the domain is §7; Activity, Camera backup and
Storage are [ios.md §9](ios.md#9-not-yet-specified).

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
screen: **Files** (the start destination), **Vault** (§6) while a domain uses an extension, and
**Settings** (§5), from which Setup is reached by **Add a domain**.

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
- **Diagnostics**, a row at the end that opens a page of its own: the extension's footprint log
  ([ios.md §7](ios.md#7-memory-and-observed-behaviour)), its last 60 lines, with **Refresh**, which
  also copies it and its previous half (`footprint.old.log`) to the app's Documents for `devicectl`,
  **Share**, which offers both files to the system's share sheet so a tester can attach them to a
  report, and **Clear**. It is in every build: the log costs the extension one system call and one
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

## 8. Conformance

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
- A build from TestFlight shows Domains, About and the Diagnostics row, whose page holds the log and
  its three actions only; Share hands over both halves of the log.
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
- Save to tsync, on a device: three photos shared from Photos to a remembered folder appear there
  in the app and in the Files app, and upload; a photo shared again under a taken name is saved as
  its first free name; with the domain turned off in Files the sheet says so and saves nothing.
