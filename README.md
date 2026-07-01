# tsync

Cloud-backed file sync with transparent on-demand download. Files live in a local directory backed by a remote storage backend — opening an evicted file downloads it transparently; only files you actually use take local space.

| Platform | Mount | Implementation |
|---|---|---|
| Linux | `~/tsync/<domain>/` | FUSE (`ocamlfuse`) |
| macOS | `~/Library/CloudStorage/TsyncApp-<domain>/` | FileProvider (`NSFileProviderReplicatedExtension`) |

Both platforms share the same storage layout, chunk format, journal format, and config schema. The same configured backends serve both simultaneously.

---

## Part 1 — Shared implementation

### Storage key layout

```
<prefix>/<domain>/<path>                          # file — raw bytes (≤ 8 MB) or manifest JSON (> 8 MB)
<prefix>/<domain>/<dir>/                          # directory marker — zero-byte object
<prefix>/.chunks/<h1>-<h2>                        # content-addressable chunk
<prefix>/.trash/<domain>/<path>/<timestamp-ms>    # versioned delete copy
<prefix>/.journal/<domain>/<13-digit-ms>-<uuid>   # change journal entry
<prefix>/.version/<domain>                        # latest journal entry key; bumped every ~2 s
```

### Config

Config path is platform-specific — see each platform's **Paths** section below. Run `tsync configure` for interactive setup. The `TSYNC_CONFIG_JSON` environment variable overrides file loading entirely.

```json
{
  "versioning": true,
  "domains": [
    {
      "name": "media",
      "prefix": "tsync",
      "backends": [
        {
          "type": "s3",
          "bucket": "my-bucket",
          "region": "us-east-1",
          "accessKeyId": "AKIA...",
          "secretAccessKey": "..."
        },
        {
          "type": "local",
          "path": "/mnt/backup/tsync"
        }
      ]
    },
    {
      "name": "photos",
      "prefix": "tsync",
      "backends": [
        {
          "type": "s3",
          "bucket": "my-bucket",
          "region": "us-east-1",
          "accessKeyId": "AKIA...",
          "secretAccessKey": "..."
        }
      ]
    }
  ]
}
```

**Top-level fields:**

| Field | Type | Description |
|---|---|---|
| `versioning` | bool | Copy deleted files to `.trash/` before removing |
| `domains` | domain[] | One or more domain objects |

**Domain fields:**

| Field | Type | Description |
|---|---|---|
| `name` | string | Domain name — used as the mount directory name and storage namespace segment |
| `prefix` | string | Key prefix shared by all backends for this domain (no leading/trailing slash) |
| `backends` | backend[] | One or more backends; writes fan out to all, reads use the first |

**Backend fields (`type: "s3"`):**

| Field | Type | Description |
|---|---|---|
| `type` | `"s3"` | Backend type |
| `bucket` | string | S3 bucket name |
| `region` | string | AWS region (e.g. `us-east-1`) |
| `accessKeyId` | string | AWS access key ID |
| `secretAccessKey` | string | AWS secret access key |

**Backend fields (`type: "local"`):**

| Field | Type | Description |
|---|---|---|
| `type` | `"local"` | Backend type |
| `path` | string | Root directory for this backend; keys are stored as paths under this root |

Each domain is an independent namespace: `<prefix>/<domain>/`. When the config has exactly one domain, `--domain` can be omitted from CLI commands; with multiple domains it is required.

When a domain has multiple backends, all writes (uploads, deletes, copies) fan out to every backend. Reads use the first backend (primary). This supports mirroring a domain to e.g. S3 and a local NAS simultaneously.

### Chunked uploads

Every file is stored as one or more 8 MB chunks. Each chunk is stored at `<prefix>/.chunks/<h1>-<h2>` where `h1` and `h2` are the xxHash3-64 of the chunk data computed with seeds 0 and 1 respectively, encoded as 16-character lowercase hex. The primary key holds a JSON manifest (`Content-Type: application/x-tsync-manifest+json`). Files smaller than 8 MB produce a single-chunk manifest. On re-upload, only chunks whose hash changed are uploaded — unchanged chunks are reused. Chunks are shared across all files and versions.

Manifest format:

```json
{
  "v": 1,
  "size": 25165824,
  "chunkSize": 8388608,
  "mtime": 1700000000.0,
  "h1": "a3f1c2e4b5d6e7f8",
  "h2": "1b2c3d4e5f6a7b8c",
  "chunks": [
    { "index": 0, "h1": "...", "h2": "...", "size": 8388608 },
    { "index": 1, "h1": "...", "h2": "...", "size": 8388608 },
    { "index": 2, "h1": "...", "h2": "...", "size": 8388608 }
  ]
}
```

`h1`/`h2` at the manifest level are derived from the full set of chunk hashes (not the file content directly), providing a stable file identity for deduplication.

### Change journal

Every mutation is recorded as a journal entry in the backend before the mutation is applied (write-ahead). This enables crash recovery and cross-client sync.

Journal keys are lexicographically sortable by time. `start_after=<last-sync-key>` in `ListObjectsV2` gives "changes since last sync" without any secondary index. A 60-day S3 lifecycle rule on `<prefix>/.journal/` keeps the journal bounded.

**Entry format (NDJSON):** one object per change event, one JSON line per operation.

```json
{"op":"put","key":"Albums/foo.wav","size":12345678}
{"op":"delete","key":"Albums/bar.wav"}
{"op":"mkdir","key":"Albums/New Folder/"}
{"op":"rmdir","key":"Albums/Old Folder/"}
{"op":"rename","src":"old.wav","key":"new.wav","size":12345678,"is_dir":false}
```

`key` and `src` are domain-relative (no backend prefix, no leading `/`). Unknown `op` values are silently skipped for forward compatibility.

### Version flusher

Journal entries are written to the backend immediately on each mutation. The `.version/<domain>` key is updated separately by a background flusher that runs every ~2 seconds: it writes the version key once per window, pointing to the latest journal entry. A burst of 50 uploads in 2 seconds produces 50 journal entries but only 1 version write.

### `tsync sync`

Brings the local filesystem in sync with the backend, applying all remote changes since the last sync. Also used for crash recovery.

1. Read `last_sync_key` from local state file. Empty → full resync.
2. If `oldest_journal_timestamp > last_sync_timestamp` → **full resync** (journal gap; changes were missed).
3. Otherwise → **incremental**: list journal entries after `last_sync_key`, filter out own `client_uuid`, evict locally-cached files touched by foreign entries.

`last_sync_key` is stored as a full backend key (`<prefix>/.journal/<domain>/<filename>`). Only the filename part is used for comparisons with the relative keys returned by `list_journal_keys`.

### Versioning

When `versioning = true`, deleting a file first copies it to `<prefix>/.trash/<domain>/<path>/<timestamp-ms>`. Trash objects can be listed and restored via the AWS CLI or `tsync history`/`tsync purge`.

### Shared OCaml libraries (`lib/`)

The platform-agnostic core lives in `lib/` and is compiled into both the Linux and macOS binaries:

All library modules are parameterised by a `Conf.S` module (a first-class module produced in `bin/tsync.ml` from the parsed config and runtime paths). No config record is threaded through function arguments.

| Module | Role |
|---|---|
| `core/conf_parsing.ml` | Config loading from file or `TSYNC_CONFIG_JSON` env; prefix derivation helpers |
| `core/ipc.ml` | Unix socket IPC — server loop, CLI text protocol, `command` type |
| `conf/conf.mli` | `module type S` — the functor parameter type used by all library modules |
| `backends/` | Pluggable storage backends (S3 via `aws-s3` + Lwt, local filesystem); self-registration pattern |
| `xxhash/xxhash.ml` | xxHash3-64 C bindings (dual-seed for chunk fingerprinting) |
| `local_io/local_io.ml` | Paged local file read/write |
| `log/` | Logging backends (printf for development, syslog for production) |
| `file/manifest.ml` | Manifest JSON serialization/deserialization; chunk key derivation |
| `file/local.ml` | Local cache paths; create/evict/rename local cache entries |
| `file/remote.ml` | Chunked upload and download against the backend |
| `file/versioning.ml` | Copy-to-trash before delete |
| `file/file.ml` | `File.Make(C)(Sq)` — central file abstraction: stat, read, write, upload, download, evict, delete, rename, mkdir |
| `sync_queue/journal.ml` | `Journal.Make(C)` — journal entry read/write; local pending-entry tracking for crash recovery |
| `sync_queue/file_store.ml` | `File_store.Make(C)` — backend operations with journal bookkeeping; directory list/rename/delete |
| `sync_queue/sync_queue.ml` | `Sync_queue.Make(C)` — async upload queue backed by OCaml `Domain` workers |
| `file_provider/file_provider.ml` | `File_provider.Make(C)` — macOS FileProvider IPC server (JSON + CLI dual-dispatch) |

### CLI binary (`bin/tsync.ml`)

The same `tsync` binary is used on both platforms. `bin/tsync.ml` reads runtime paths once, parses config into a `(module Conf.S)`, then applies the appropriate functors per subcommand. The active backend is selected at compile time via the `runtime` module alias:

| Module | Selected when |
|---|---|
| `runtime.fuse.ml` | `fuse3` library present (Linux) |
| `runtime.file_provider.ml` | macOS group container path available |
| `runtime.noop.ml` | Neither (build-time stub) |

```
tsync configure

tsync start   [--mount <path>] [--domain <name>]
tsync stop
tsync status

tsync evict   <path>
tsync restore <path>
tsync ls      [path]
tsync sync    [--domain <name>]

tsync auto-evict [on|off|status]
tsync history <path>
tsync purge   <path>
```

`tsync configure` writes the config file interactively. It prompts for versioning, then loops over domains (name, prefix, backends) — each domain supports multiple backends. On macOS it writes to the group container so both the daemon and extension can read it; on Linux it writes to the XDG config dir with mode `0600`.

### IPC protocol

All daemon communication goes through a Unix socket. The socket path is runtime-specific (see platform sections below). Lines starting with `{` are dispatched as JSON (FileProvider protocol); all other lines use the CLI text protocol.

**CLI text protocol** (both platforms):

```
STOP
STATUS
EVICT <path>
RESTORE <path>
AUTO_EVICT on|off|status
FULL_RESYNC
```

**JSON protocol** (macOS FileProvider only):

```json
{"action":"stat","path":"<key>"}
{"action":"list_dir","path":"<prefix>"}
{"action":"list_all","path":"<prefix>"}
{"action":"ensure_cached","path":"<key>"}
{"action":"create","path":"<key>"}
{"action":"write","path":"<key>","staging":"<local_path>"}
{"action":"evict","path":"<key>"}
{"action":"delete","path":"<key>"}
{"action":"rename","path":"<dst_s3key>","src":"<src_s3key>"}
{"action":"mkdir","path":"<s3key_with_slash>"}
{"action":"rmdir","path":"<s3key_with_slash>"}
```

**Reverse notify channel** (`notify.sock`, daemon → extension, macOS only):

```
EVICT <key>
UPLOADED <key>
```

---

## Part 2 — Linux FUSE

The Linux backend mounts a FUSE filesystem at `~/tsync/<domain>/` using `ocamlfuse`. The daemon runs in the foreground under systemd (or any process supervisor).

### Architecture

```
tsync start
  ├── Ipc.serve          Unix socket at ~/.local/share/tsync/tsync.sock
  ├── version_flusher    Thread: drains pending_version_key → backend every ~2 s
  └── Fuse_fs.mount      ocamlfuse main loop (single-threaded)
       └── FUSE ops → File.* → Sync_queue → backend
```

### Source layout (`linux/lib/fuse/`)

| File | Role |
|---|---|
| `fuse_fs.ml` | `Fuse_fs.Make(C)` — FUSE operation handlers; IPC handler; version flusher thread; instantiates `Sync_queue`, `File`, `File_store` |
| `path_ops.ml` | FUSE path operation record type |
| `internal_ops.ml` | `Internal_ops.Make(F)` — mutation handlers (create, write, unlink, mkdir, rmdir, rename) |
| `hidden_ops.ml` | `Hidden_ops.Make(F)` — `.fuse_hidden*` file handlers (local-only, never mirror to backend) |

### Paths

| Item | Default path | Override |
|---|---|---|
| Config | `~/.config/tsync/config.json` | `$XDG_CONFIG_HOME/tsync/config.json` or `TSYNC_CONFIG_JSON` |
| Cache root | `~/.cache/tsync/` | `$XDG_CACHE_HOME/tsync/` |
| Data dir | `~/.local/share/tsync/` | `$XDG_DATA_HOME/tsync/` |
| IPC socket | `~/.local/share/tsync/tsync.sock` | (follows data dir) |
| Notify socket | `~/.local/share/tsync/notify.sock` | (follows data dir) |
| Auto-evict flag | `~/.local/share/tsync/auto-evict` | (follows data dir) |

The data dir also holds the client UUID, last-sync state, and local pending journal entries for crash recovery.

Each cached file lives at `<cache_root>/<domain>/<path>`. A `.manifest` sidecar file (`<cache_root>/<domain>/<path>.manifest`) persists across eviction: `getattr` can return correct size and mtime for evicted files without a backend HEAD request.

### FUSE operation flow

- **getattr / readdir**: served from the local manifest cache.
- **open / read**: triggers `File.ensure_cached` on first access of an evicted file — downloads from backend synchronously.
- **release** (last close): if the file was written, posts a `Put` event to `Sync_queue`. The upload runs on a Domain worker thread; the FUSE operation returns immediately.
- **unlink / mkdir / rmdir / rename**: synchronous backend operations with journal write-ahead. `rename` handles both file and directory cases by detecting trailing `/` in the key.

### Auto-evict

After a successful upload, the daemon optionally evicts the local copy. Controlled by `tsync auto-evict on|off`; state persists as the auto-evict flag (see Paths above).

### Systemd

The daemon runs as a user systemd service. Logs via syslog (viewable with `journalctl --user -u tsync -f`).

### Lifecycle test

```bash
cd linux
./test_lifecycle.sh              # build + run all cases against a configured backend
./test_lifecycle.sh --skip-build 1 3   # skip build, run cases 1 and 3
```

Reads config from `$XDG_CONFIG_HOME/tsync/config.json` or `TSYNC_CONFIG_JSON`. Sets up AWS credentials from config if not already present in `~/.aws/`.

---

## Part 3 — macOS FileProvider

The macOS backend uses `NSFileProviderReplicatedExtension`. Files appear at `~/Library/CloudStorage/TsyncApp-<domain>/` — the same model as iCloud Drive and Dropbox Smart Sync. The OS manages local storage; the extension is only called when the OS needs to fetch or push data.

### Architecture

```
TsyncApp (LaunchAgent)
  └── registers NSFileProviderDomain per configured domain
  └── AppDelegate.registerDomains()

TsyncFileProvider (extension, sandboxed)
  ├── TsyncExtension          NSFileProviderReplicatedExtension
  │    ├── fetchContents      download: ensure_cached → local path → evict after hand-off
  │    ├── createItem         file: write+upload; dir: mkdir
  │    ├── modifyItem         rename / content update / metadata-only
  │    └── deleteItem         unlink / rmdir
  ├── TsyncEnumerator         NSFileProviderEnumerator
  │    ├── enumerateItems     list_dir (per-directory) / list_all (working set)
  │    └── enumerateChanges   anchor-expired → full re-enumeration
  └── NotifyListener          listens on notify.sock; receives EVICT / UPLOADED from daemon

OCaml daemon (tsync start, LaunchAgent via deploy-daemon.sh)
  ├── Ipc.serve               Unix socket — JSON + CLI dispatch
  ├── Sync_queue              Domain workers for async upload
  └── on_upload_done          → Ipc.notify_uploaded → notify.sock → extension signalEnumerator
```

### Data flow

**Write (user creates/modifies a file):**

1. FileProvider receives `createItem` or `modifyItem` with `newContents: URL`.
2. Extension hard-links the content URL into a staging directory (`stageContent`); falls back to copy if cross-device.
3. Extension calls `IPC.writeFile(key:, staging:)` (JSON IPC).
4. Daemon renames staging file into its local cache, marks dirty, posts to `Sync_queue`.
5. `Sync_queue` worker uploads in the background; on completion calls `on_upload_done`.
6. `on_upload_done` clears the dirty manifest and sends `UPLOADED <key>` to `notify.sock`.
7. `NotifyListener` receives it and calls `NSFileProviderManager.signalEnumerator` → FileProvider re-fetches item metadata.

**Read (user opens an evicted file):**

1. FileProvider calls `fetchContents` on the extension.
2. Extension calls `IPC.ensureCached(key:)` (JSON IPC).
3. Daemon downloads from the backend into its local cache; returns local path.
4. Extension passes the URL to FileProvider's completion handler.
5. FileProvider copies the content to its own storage; extension calls `IPC.evictItem` (fire-and-forget) to free the daemon's cache copy.

**Eviction (OS or user evicts a file):**

1. FileProvider calls `NSFileProviderManager.evictItem` (OS-driven) or extension calls it (after upload).
2. Extension also sends `EVICT <key>` via `Ipc.send` to the daemon CLI protocol.
3. Daemon calls `File.evict` to remove its local cache copy.
4. Daemon sends `EVICT <key>` to `notify.sock`, closing the loop.

### Source layout

**OCaml (`lib/file_provider/`):**

| File | Role |
|---|---|
| `file_provider.ml` | IPC server; JSON action handlers; CLI command handlers; `path_to_key` with CloudStorage path stripping |

**Swift (`macos/`):**

| File | Role |
|---|---|
| `Shared/Config.swift` | Config loading from group container (`~/Library/Group Containers/group.com.toots.tsync/config.json`) |
| `TsyncApp/AppDelegate.swift` | Registers `NSFileProviderDomain` for each configured domain |
| `TsyncFileProvider/IPC.swift` | JSON IPC client to the OCaml daemon; typed wrappers for each action |
| `TsyncFileProvider/Item.swift` | `NSFileProviderItem` implementation; `isUploaded` reflects daemon manifest state |
| `TsyncFileProvider/Enumerator.swift` | `NSFileProviderEnumerator`; per-directory `list_dir`, recursive `list_all` for working set |
| `TsyncFileProvider/Extension.swift` | `NSFileProviderReplicatedExtension`; `NotifyListener` on `notify.sock` |

### Paths

| Item | Path |
|---|---|
| Config | `~/Library/Group Containers/group.com.toots.tsync/config.json` |
| Cache root | `~/Library/Caches/tsync/` |
| Data dir | `~/Library/Group Containers/group.com.toots.tsync/tsync/` |
| IPC socket | `~/Library/Group Containers/group.com.toots.tsync/tsync/tsync.sock` |
| Notify socket | `~/Library/Group Containers/group.com.toots.tsync/tsync/notify.sock` |

The group container (`~/Library/Group Containers/group.com.toots.tsync/`) is the only location accessible to both the sandboxed extension and the daemon. Both read config from there; the extension routes all backend operations through the daemon and never needs credentials directly.

The extension only needs the non-credential fields (`prefix`, `versioning`, `domains`) — all backend operations go through the daemon, which reads the full config including credentials.

### `isUploaded` and upload state

`TsyncItem.isUploaded` reflects the manifest state read from the daemon:
- **`false`**: manifest is `Dirty` — file written locally, upload in progress.
- **`true`**: manifest is `Clean` (upload complete) or file exists only in the backend (not cached).

Finder shows a progress indicator while `isUploaded = false`. The `UPLOADED` notification on `notify.sock` triggers `signalEnumerator` → FileProvider re-fetches the item → indicator clears.

### Working set

`enumerateWorkingSet` calls `IPC.listAll` (the `list_all` JSON action), which returns a flat list of all files under the domain prefix via `File_store.list_all_files`. This powers Spotlight and Recents across the full directory tree, not just the root.

### Deploy

```bash
macos/deploy-daemon.sh   # build OCaml daemon, install to ~/.local/bin/tsync, load launchd plist
make -C macos generate   # regenerate tsync.xcodeproj from project.yml
make -C macos build      # xcodebuild TsyncApp (Release)
make -C macos deploy     # build + install TsyncApp to /Applications + reload LaunchAgent
```

### Lifecycle test

```bash
cd macos
./test_lifecycle.sh              # deploy daemon + build app + run all cases
./test_lifecycle.sh --skip-build # skip build, run all cases against running daemon
./test_lifecycle.sh 1 3          # run only cases 1 and 3
```

Reads config from the group container.

---

## Known limitations

**No chunk GC.** Chunks accumulate in `<prefix>/.chunks/` indefinitely. A future `tsync gc` would collect unreferenced chunks by scanning all manifests.

**No concurrent write safety.** Last manifest write wins. Correct fix: S3 conditional PUT (`If-None-Match`) with a retry loop.

**No background prefetch.** Files download on first open. `tsync pull` (not yet implemented) would bulk-download evicted files.

**Chunks are not encrypted at the application layer.** Enable S3 SSE-S3 or SSE-KMS on the bucket for encryption at rest.

**Linux: single-threaded FUSE.** Runs in `Single_threaded` mode; concurrent filesystem operations queue behind the Lwt event loop. Sufficient for personal use; would need `Multi_threaded` + per-file locking for heavy concurrent access.

**macOS: extension consent required.** macOS requires one-time user consent in System Settings → General → Login Items & Extensions → File Provider Extensions before the extension activates and the CloudStorage mount appears.

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE).
