# The iOS application

Scope: the app's screens and what the app does with the File Provider. The process model, the host
layout and the extension are [ios.md](ios.md).

This page is a delta on [android-app.md](android-app.md). It applies:
- §6.1, the config the app writes, except where §5 says otherwise;
- §10.1, the interface principles;
- §10.7's Setup as written, with the scanner of §4.

Nothing else of android-app.md applies. Files and item actions are the Files app's; Activity, Saving
into the domain, Vault, Camera backup and Storage are [ios.md §9](ios.md#9-not-yet-specified).

---

## 1. Problem

The app cannot reach a domain's owner: the extension owns it, and the service that would carry
requests to it is not yet specified. So the app does only what the config and the File Provider
framework let it do alone: join and remove domains, register them, tell the user which ones the
Files app shows, and wake the working sets.

## 2. Structure

Until a config exists, the app shows only Setup (§4). A config that does not load shows Setup with
the core's message, as on Android. Otherwise the app has one screen, Settings (§5), from which Setup
is reached by **Add a domain**.

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
the extension accepted is in the owner's pending set, which removal does not touch.

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
  - So the app keeps each removed domain's config entry in its preferences. Joining a domain whose
    kept entry differs from the new one says that the new settings may wait for the extension to
    restart, and that restarting the iPhone applies them at once. Joining it with the same entry says
    nothing. The kept entry is dropped at that join.
  - A removal the framework refuses leaves the config as it was and shows the reason.
- **Background refresh**, under Domains, only when the system will not run it: "Background refresh
  is off for tsync: Files shows changes from other devices when you open tsync. Turn it on in
  Settings, General, Background App Refresh", or, when the device restricts it, that it is not
  available on this iPhone.
- **Add a domain** opens Setup.
- **About**: the app's version and the commit it was built from.
- **Diagnostics**: the extension's footprint log ([ios.md §7](ios.md#7-memory-and-observed-behaviour))
  with Refresh and Clear; **Add a local test domain** (a domain whose store is a directory in the App
  Group, for trying the extension without a server); **Run self-test**, the test that
  [ios.md §8](ios.md#8-conformance) runs on a device; **Walk every domain**, which lists every folder
  of every domain through the file system, so that the extension pulls and then holds them all, for
  ios.md §8's check of a refresh pass over thousands of held folders. It leaves out the system's `.Trash`, which the extension does not serve, and runs while
  the app is in front. The walk logs its start, every
  100 folders, each folder it waits on and how long, each it skips, and its end. It is in every build: the log costs the
  extension one system call and one append per request (ios.md §7), and the rest runs only when
  asked.

## 6. Conformance

- With no config, only Setup is shown; a config that does not load shows Setup and the core's
  message.
- A launch with domains already registered under the current identity scheme removes and adds none.
- A domain removed from the config is removed from the framework at the next pass; a domain the
  framework refuses to remove is not deleted from the config.
- Bringing the app to the foreground signals every configured domain's working set: the extension's
  footprint log shows a change enumeration for each.
- A domain turned off in Files is shown so within a second of returning to the app, and the mark goes
  once it is turned on.
- On a device without the live scanner, Scan setup code is not offered.
- With Background App Refresh turned off for tsync, Settings says so; turned on, it says nothing.
- Removing a domain and joining it again with a different server says the new settings may wait for
  a restart; joining it again from the same link says nothing.
