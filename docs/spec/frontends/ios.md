# The iOS client

Scope: tsync on iOS: which process owns a domain, where its files live, what the host gives the
core, and how the File Provider framework is served from Android's lazy tree. The app's own screens
are only those §6 names; the full app (browser, Save to tsync, camera backup, vault, credentials) is
[§9](#9-not-yet-specified).

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
a file lock in a shared App Group container while suspended is killed too.

So:

1. **The File Provider extension owns** every domain it serves (§2).
2. **No lock and no domain state in the App Group**: each process keeps its core's home in its own
   container; the group holds only what two processes read (§3).
3. **The tree is lazy**, as on Android: no background cycle, freshness from pulls
   ([android.md §3.2](android.md#32-freshness-without-a-background-cycle)).
4. **The core runs bounded** (§4), and every callback arrives on a thread of its own.

## 2. Processes and ownership

| Process | Started by | Boots domains | Uses the core for |
|---|---|---|---|
| File Provider extension | the system, on any use of a domain | yes, each domain at the first callback naming it | every callback, by direct calls ([android.md §5](android.md#5-the-bridge)) |
| App | the user | never | `check_config` with a candidate and `setup_link`, which take no lock and write nothing |

- Ownership follows [android.md §2](android.md#2-ownership-and-process-model): the ownership lock,
  held for the life of the process; no stop and no drain; process death is a crash-stop and the
  next boot recovers. The lock is in the extension's own container (§3).
- Whether the system runs one extension process for every domain or several is its choice. Any
  number of booted domains per process is supported.
- The app never calls `boot`, `request` or `status`.

## 3. Host layout

### 3.1 Identifiers

| Item | Identifier |
|---|---|
| App | `org.feverdreamtv.tsync.phone` |
| File Provider extension | `org.feverdreamtv.tsync.phone.fileprovider` |
| App Group | `group.org.feverdreamtv.tsync` |
| Domain | [file-provider.md §3.3](file-provider.md#33-domain-identifier)'s identifier of its display name |

These are persistent: changing one orphans an installation's domains.

### 3.2 Paths

| Thing | Location | Written by |
|---|---|---|
| Config | `<group>/config.json` | the app only, atomically, mode 0600, after every new domain passes `check_config` |
| Home of a process's core | `<the process's own container>/Library/Application Support/tsync/` | that process's core |
| Ownership locks, data, cache | under the home, in the core's Apple layout | the owner |
| Transfer root | the process's temporary directory, which in the extension is the File Provider's temporary directory | the framework and the owner |
| Footprint log | `<group>/footprint.log` | the extension (§7) |

- The host names the config file with `$TSYNC_CONFIG_FILE` ([07 §2.7](../07-daemon-cli.md)): the
  core's home is the process's, the config is the group's.
- Every staging and destination path the callbacks pass lies in the transfer root
  ([android.md §4.1](android.md#41-what-the-host-provides) item 5).

## 4. What the host gives the core

The host environment of [android.md §4.1](android.md#41-what-the-host-provides), given once per
process before the first call:

- **home** and **config file**: §3.2;
- **trust store**: none; Network.framework verifies against the system's store, and an iOS build
  carries no other TLS implementation ([security-model.md §9.2](../algorithms/security-model.md#92-implementation-per-host));
- **transfer root**: §3.2;
- **resource bounds** (item 7), in the extension only: one executor, four may-block in flight, 1 MiB
  release growth, and a 32k-word minor heap through `OCAMLRUNPARAM`
  ([memory.md §M.5](../ocaml/memory.md#m5-a-memory-capped-host)); the app keeps the defaults;
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
- **The working set is empty**: its enumeration lists nothing and its changes are always none at one
  fixed anchor. Remote changes reach the system only when it enumerates a folder again. A change feed
  over the pulled folders is §9's first item.
- **Custom actions** are not offered: on iOS they need an actions UI extension.
- A request cannot be interrupted once in the core: a cancelled callback completes at once and the
  call's reply is dropped.

## 6. The app

- **Joining**: a setup link is opened with `setup_link`
  ([setup-link §6.1](../algorithms/setup-link.md#61-opening-a-link)); each domain it carries becomes an http-proxy domain, as
  [android-app.md §6.1](android-app.md) builds them. A test domain whose store is a local directory
  in the group may be added for trying the extension without a server.
- **Registering**: at every launch and after every change to the config, each configured domain is
  added to the File Provider by its identifier and display name.
- **Enabling**: a new domain is disabled until the user turns it on in the Files app; until then
  every callback fails with `domainDisabled`. The app says so after a join.
- **Removing**: every domain is removed at once, then the config.
- **Self-test**: drives the test domain through file coordination, so each step reaches the extension
  as the Files app's would: create 1,000 small files and a 256 MiB file, list the folder, evict the
  large file and read it back.

## 7. Memory

The extension appends one line per callback to the footprint log: the action, the process's
`phys_footprint` after it and the peak since the line before, sampled every 20 ms. The app shows the
log.

Measured in the iOS 26.5 simulator, one self-test per build, the test domain's local store:

| Peak | Debug | Release |
|---|---|---|
| first callbacks after boot | 16.2 MiB | 17.8 MiB |
| 1,000 creations and their listing | 19.0 MiB | 20.0 MiB |
| 256 MiB write, evict, read back | 20.5 MiB | 20.3 MiB |

A process that does nothing costs 8.6 MiB in the simulator; a device's figure is to be measured.

## 8. Conformance

[android.md §9](android.md#9-conformance) applies, except the command group and the handle API. In
addition:

- No file lock is held in the App Group container.
- A thousand callbacks, each on a new thread, leave the extension's footprint where one thread's
  would.
- The self-test passes with the extension below its memory limit on a device.

## 9. Not yet specified

Each becomes a section above before its code.

1. A change feed for the working set over the folders the lazy tree holds, so remote changes reach
   the system without re-enumeration.
2. A service the extension vends (`NSFileProviderServiceSource`) for the app and other extensions,
   one connection per domain, with deadlines, and the transfer root for its callers.
3. Refresh passes the app requests when the system lets it run.
4. The keystore (the keychain, after first unlock, this device only), the vault, passwords, passkeys
   and one-time codes (iOS 18), the credential provider and share extensions.
5. Camera backup with PhotoKit's change tracking.
6. Registering an `ios` frontend: domains are configured with the `android` frontend, whose rules
   this page extends.
7. Open on a device: the extension's limit on the oldest supported device; whether one process
   serves every domain; whether the Files app enumerates a folder it holds when the user opens it
   again.
