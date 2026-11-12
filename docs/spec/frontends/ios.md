# The iOS client

Scope: tsync on iOS: which process owns a domain, where its files live, what the host gives the
core, and how the File Provider framework is served from Android's lazy tree. The app's screens are
[ios-app.md](ios-app.md)'s; the rest of the app (Save to tsync, camera backup, vault, credentials) is
[§9](#9-not-yet-specified). There is no in-app browser: the Files app is the browser.

This page is a delta. What it does not restate is owned by:
- the embedded owner, the lazy tree, the bridge and notices: [android.md](android.md), which applies
  wherever this page does not say otherwise;
- the File Provider item model, versions, callbacks and error mapping:
  [file-provider.md](file-provider.md) §5–§7, which apply as written unless §5 says otherwise;
- memory bounds and their measurements: [ocaml/memory.md §M.5](../ocaml/memory.md#m5-a-memory-capped-host).

---

## 1. Problem

iOS has no daemon and no app that stays running. The process the system starts whenever a domain
is in use is the **File Provider extension**; it runs while a system call is pending and is
suspended or killed when idle. It is killed past about 20 MB of dirty memory. A process that holds
a file lock while suspended is killed too, wherever the file is: the extension's own container is
no exception (pitfall B-8.21).

So:

1. **The File Provider extension owns** every domain it serves (§2).
2. **No file lock while idle, and no domain state in the App Group**: each process keeps its core's
   home in its own container; the group holds only what two processes read (§3).
3. **The tree is lazy**, as on Android: no background cycle, freshness from pulls
   ([android.md §3.2](android.md#32-freshness-without-a-background-cycle)).
4. **The core runs bounded** (§4), and every callback arrives on a thread of its own.

## 2. Processes and ownership

| Process | Started by | Boots domains | Uses the core for |
|---|---|---|---|
| File Provider extension | the system, on any use of a domain | yes, each domain at the first callback naming it | every callback, by direct calls ([android.md §5](android.md#5-the-bridge)) |
| App | the user | never | `check_config` with a candidate and `setup_link`, which take no lock and write nothing |

- Ownership follows [android.md §2](android.md#2-ownership-and-process-model): held for the life of
  the process; no stop and no drain; process death is a crash-stop and the next boot recovers.
- The system runs one extension process per domain: on a device, each process it killed held one
  domain, and two idle domains' processes ended in the same second. Any number of booted domains per
  process is still supported.
- **The ownership record is the lock.** The owner takes no kernel lock: it writes
  [07 §2.3](../07-daemon-cli.md#23-the-ownership-lock)'s holder record into the domain's lock file,
  in the extension's own container (§3). A boot that finds a record naming another process that is
  alive (`kill(pid, 0)` succeeds or is refused) is refused as another holder's; a record naming a
  dead process, or none, is replaced. Two processes booting one domain at the same instant are not
  told apart: the system's one process per domain is what excludes them.
- Every other file lock the core takes is held only while a callback runs: a write awaits its upload
  ([android.md §5](android.md#5-the-bridge)), and the chunk store's locks are a local store's
  collection's.
- The app never calls `boot`, `request` or `status`.

## 3. Host layout

### 3.1 Identifiers

| Item | Build setting |
|---|---|
| Signing team | `TSYNC_TEAM_ID` |
| App | `TSYNC_APP_ID` |
| File Provider extension | `$(TSYNC_APP_ID).fileprovider` |
| App Group | `TSYNC_APP_GROUP` |
| Push environment | `TSYNC_APS_ENVIRONMENT`: `development` for a build installed from a Mac, `production` for a TestFlight or App Store build ([10 §5.6](../10-delivery.md#56-ios-signing-and-testflight)) |
| Domain | [file-provider.md §3.3](file-provider.md#33-domain-identifier)'s identifier of its display name |

The source holds no value for them: a build is given them by its environment (the CI's secrets, or
the shell of a local build), and fails at its start, naming each one missing. Each process reads the
App Group from its bundle's Info.plist. They are persistent for an installation: changing one orphans
its domains.

### 3.2 Paths

| Thing | Location | Written by |
|---|---|---|
| Config | `<group>/config.json` | the app only, atomically, mode 0600, after every new domain passes `check_config` |
| Home of a process's core | `<the process's own container>/Library/Application Support/tsync/` | that process's core |
| Ownership records, data, cache | under the home, in the core's Apple layout | the owner |
| Transfer root | the process's temporary directory, which in the extension is the File Provider's temporary directory | the framework and the owner |
| Footprint log | `<group>/footprint.log` | the extension (§7) |

- The host names the config file with `$TSYNC_CONFIG_FILE` ([07 §2.7](../07-daemon-cli.md)): the
  core's home is the process's, the config is the group's.
- Every staging and destination path the callbacks pass lies in the transfer root
  ([android.md §4.1](android.md#41-what-the-host-provides) item 5).

## 4. What the host gives the core

The host environment of [android.md §4.1](android.md#41-what-the-host-provides), given once per
process before the first call:

- **home** and **config file**: §3.2, both in the environment before the runtime starts;
- **trust store**: none; Network.framework verifies against the system's store, and an iOS build
  carries no other TLS implementation ([security-model.md §9.2](../algorithms/security-model.md#92-implementation-per-host));
- **transfer root**: §3.2;
- **resource bounds** (item 7), in the extension only: the capped host's of
  [memory.md §M.5](../ocaml/memory.md#m5-a-memory-capped-host), the minor heap included; the app
  keeps the defaults;
- **log sink**: the unified log;
- **keystore**: none yet, so a domain using the vault does not boot here (§9).

The cleartext rule of android §4.1 applies. Each callback runs on a new thread, which ends when the
callback completes ([android.md §4.3](android.md#43-threads)).

## 5. File Provider on a lazy tree

The extension is the macOS one ([file-provider.md](file-provider.md) §5–§7), its sources shared,
with an in-process owner in place of the socket. What differs:

- **No ranged reads**: `NSFileProviderPartialContentFetching` is macOS only; a fetch is
  `ensure_cached` into the provider's temporary directory.
- **Content policy**: the root's is `downloadLazilyAndEvictOnRemoteUpdate`, iOS having no plain lazy
  policy; everything below inherits it.
- **Writes await their upload**: `write` carries `await`, so the reply describes an uploaded item.
  The system learns that an item is uploaded only from the reply of the callback that wrote it, and
  evicts nothing before.
- **The working set is the feed over held folders** (§5.1).
- **Custom actions** are not offered: on iOS they need an actions UI extension.
- A request cannot be interrupted once in the core: a cancelled callback completes at once and the
  call's reply is dropped.

### 5.1 The working set

The system enumerates a folder once and never again: it learns of every later change from the
working set alone, and asks the working set only when signalled (§7.1). So the working set is the
whole change feed of [file-provider.md](file-provider.md) §6.5, over the feed a pulled tree keeps
([android.md §6](android.md#6-the-handler-on-a-pulled-tree)):

- **Items**: `list_all`, what the mirror holds.
- **Changes**: `refresh`, then `changes_since`. The refresh waits for its pass up to
  `refresh_patience` ([android.md §3.2](android.md#32-freshness-without-a-background-cycle)), so
  the changes answered include what the pass brought; a pass longer than that announces the rest
  by its notices, and the system asks again.
- **Signals**: the extension signals the working set of a domain after each `changed` and
  `recovered` notice naming it, read from the bridge's notices
  ([android.md §4.2](android.md#42-notices)), and once at each domain boot. The app signals every
  configured domain's working set at launch and each time it comes to the foreground
  ([ios-app.md §3](ios-app.md#3-registration-and-signals)).

A refresh pass runs only while the system lets the extension run, which is while one of its
callbacks is pending: one cut short by suspension is taken up by the next signal. While neither the Files app nor the tsync app is in use, a push from
the domain's server signals (§5.3), else the app's background runs do (§5.2).

### 5.2 In the background

The app asks the system for a background app refresh run (`BGAppRefreshTask`) no earlier than
`background_refresh_interval` from now: at launch, each time it comes to the foreground, and at the
end of each run. A run signals the working set of every configured domain and ends at once. The
refresh pass is the extension's, started by the change enumeration the signal brings, so a run needs
neither the core nor a service, and is far inside the time the system gives it.

- When the system grants a run is its own: it weighs how the app is used, the battery, and the user's
  Background App Refresh switch. A run it skips costs freshness, never correctness.
- A run selects no folders. One pass brings every held folder to the head for one read of the log
  ([android.md §3.2](android.md#32-freshness-without-a-background-cycle)), so there is no subset to
  choose and no stamp a run could renew.
- Runs are asked for whether or not a domain's server pushes: a push lost or a server without push
  leaves the runs to catch up.
- Each run appends `app: background refresh` to the footprint log (§7).

| Parameter | Recommended | Constraint |
|---|---|---|
| `background_refresh_interval` | 15 min | the earliest next run asked for; the system may run later, never earlier |

### 5.3 Pushes

A server holding a push key tells phones when a domain changed. The system turns a file provider push
naming a domain into a signal of that domain's working set (§5.1): the extension's refresh pass
follows, with neither app running.

**Who can push.** Apple delivers a push to the app only when it is signed with a key of the team that
signs the app. A server pushes only when its operator gives it such a key: the publisher's own server
for the published app, or any operator for an app they build and sign under their own identifiers
(§3.1). A server without a key does not push, and its phones rely on the background runs of §5.2.
The key signs pushes to every app of its team, so it is given to no other server.

**The phone.**
- At each domain boot, and whenever the system hands it a new token, the extension registers for
  file provider pushes and sends the core a `push_register` request
  ([08 §4](../08-frontends.md)): the token, its
  environment (`development` for builds signed for development, else `production`), and the domain's
  File Provider identifier.
- A server without a key answers `{pushes:false}`; the extension does not ask that server again in
  this process. A failed registration is logged and retried at the next boot.
- The extension obtains the token itself: on a device (iOS 18.1), the app and the extension each
  registering got the same token and neither saw it invalidated. The app does not register.

**The server** pushes as [http-proxy §A4.7](http-proxy.md#a47-pushes) specifies: its operator sets
the listener's `push_*` options, and a build without libcurl cannot.

## 6. The app

[ios-app.md](ios-app.md).

## 7. Memory and observed behaviour

The extension appends one line per core request to the footprint log: the domain, the action, the
`ref` it names, how long it took in milliseconds, its failure code and message if it failed, the rows
of a listing (`items`) or of a change read (`ops`) with `more` when more follow, the process's
`phys_footprint` after it, and the kernel's record of its peak since the process started
(`ledger_phys_footprint_peak`). Nothing samples in between, so the log costs one system call and one
append per request. It also appends a line for each push, each notice it signals a working set for,
and the signal's error when the system refuses it. At 1 MiB the log is renamed to `footprint.old.log`, replacing the previous one,
and a new log begins. The app shows the log.

Measured in the iOS 26.5 simulator, one self-test per build, the test domain's local store:

| Peak | Debug | Release |
|---|---|---|
| first callbacks after boot | 16.2 MiB | 17.8 MiB |
| 1,000 creations and their listing | 19.0 MiB | 20.0 MiB |
| 256 MiB write, evict, read back | 20.5 MiB | 20.3 MiB |

A process that does nothing costs 8.6 MiB in the simulator. On an iPhone 14 (iOS 18.1.1), Release,
the self-test passes with the extension at 8.4 MiB at most.

### 7.1 Enumeration, observed

On the iPhone 14, with every enumerator callback logged:

- reopening a folder, also after leaving the Files app for minutes, makes no listing call;
- the working set is asked nothing unprompted, not even after a local `mkdir`;
- a signal of the working set from the app is followed by its change enumeration within a second.

## 8. Conformance

[android.md §9](android.md#9-conformance) applies, except the command group and the handle API. In
addition:

- No file lock is held by an idle extension: after an hour of use on a device, the system log shows
  no termination of the extension for locked files (`0xdead10cc`).
- A boot of a domain whose ownership record names a live process is refused; one naming a dead
  process boots.
- A build missing any identifier of §3.1 fails before compiling, naming each one missing.
- A thousand callbacks, each on a new thread, leave the extension's footprint where one thread's
  would.
- The self-test passes with the extension below its memory limit on a device.
- On a desktop, through `tsync android request`: after a peer commits into a held folder, a
  `refresh` followed by `changes_since` names the change; `list_all` makes no store request and
  lists files this client wrote in a folder it created; `refresh` while a pass runs starts none.
- With 5,000 held folders and a peer's commits into a few of them, a refresh pass makes as many log
  reads as the new entries fill pages, not one per folder, and merges only the folders concerned.
- A pull of a folder 10,000 entries behind holds no more than one page of entries at a time.
- In the extension, a refresh pass over 5,000 held folders and the working-set listing that follows
  stay below the memory limit.
- On a device: a peer's change to a folder the Files app already shows appears there after the
  tsync app is brought to the foreground, without the folder being opened again.
- A server with the `push_*` options set sends one push to each other registered client of a domain within
  `push_coalesce` of a change, and none to the change's author; through one without, the
  extension's `push_register` answers `{pushes:false}`.
- On a device, with neither app in use, a peer's change to a folder the Files app already shows
  appears there within seconds through a server that pushes.
- On a device with Background App Refresh on, a background run shows in the footprint log as
  `app: background refresh` followed by change enumerations, with the tsync app not in use; a peer's
  change made before it shows in the Files app without either app being opened.

## 9. Not yet specified

Each becomes a section above before its code.

1. A service the extension vends (`NSFileProviderServiceSource`) for the app and other extensions,
   one connection per domain, with deadlines, and the transfer root for its callers.
2. The keystore (the keychain, after first unlock, this device only), the vault, passwords, passkeys
   and one-time codes (iOS 18), the credential provider and share extensions.
3. Camera backup with PhotoKit's change tracking.
4. Registering an `ios` frontend: domains are configured with the `android` frontend, whose rules
   this page extends.
5. Open on a device: the extension's limit on the oldest supported device.
