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
<prefix>/.versions/<domain>/<path>/<timestamp-ns> # saved manifest version (modify/rename/delete)
<prefix>/.journal/<domain>/<13-digit-ms>-<uuid>   # change journal entry
<prefix>/.cursor/<domain>                         # latest journal entry key; bumped every ~2 s
```

### Config

Config path is platform-specific — see each platform's **Paths** section below. Run `tsync configure` for interactive setup. The `TSYNC_CONFIG_JSON` environment variable overrides file loading entirely.

```json
{
  "versioning": true,
  "name": "Romain's MacBook Pro",
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
          "path": "/mnt/backup/tsync",
          "main": true
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
| `versioning` | bool | Save a manifest version under `.versions/` on every modify/rename/delete |
| `name` | string | Human-readable client name, used to label conflict copies (e.g. `"report (conflicted copy from Romain's MacBook Pro).txt"`). Defaults to the hostname |
| `tls` | string | Optional. TLS backend for S3 connections: `"native"` (ocaml-tls, default) or `"openssl"`. See [TLS backend](#tls-backend) |
| `maxUploads` | int | Optional. Max files uploaded concurrently (default 4) |
| `maxDownloads` | int | Optional. Max files downloaded concurrently (default 8) |
| `domains` | domain[] | One or more domain objects |

**Domain fields:**

| Field | Type | Description |
|---|---|---|
| `name` | string | Domain name — used as the mount directory name and storage namespace segment |
| `prefix` | string | Key prefix shared by all backends for this domain (no leading/trailing slash) |
| `backends` | backend[] | One or more backends; writes fan out to all, reads use the primary (see below) |

**Backend fields (`type: "s3"`):**

| Field | Type | Description |
|---|---|---|
| `type` | `"s3"` | Backend type |
| `bucket` | string | S3 bucket name |
| `region` | string | AWS region (e.g. `us-east-1`), or the vendor region for an S3-compatible service |
| `endpoint` | string | Optional. Custom S3 endpoint host for S3-compatible services (e.g. `s3.us-east-005.backblazeb2.com` for Backblaze B2). Omit for AWS |
| `accessKeyId` | string | AWS access key ID |
| `secretAccessKey` | string | AWS secret access key |
| `main` | bool | Optional. Mark this backend as the primary (read) backend. See [Primary backend selection](#primary-backend-selection) |

**Backend fields (`type: "local"`):**

| Field | Type | Description |
|---|---|---|
| `type` | `"local"` | Backend type |
| `path` | string | Root directory for this backend; keys are stored as paths under this root |
| `main` | bool | Optional. Mark this backend as the primary (read) backend. See [Primary backend selection](#primary-backend-selection) |

Each domain is an independent namespace: `<prefix>/<domain>/`. When the config has exactly one domain, `--domain` can be omitted from CLI commands; with multiple domains it is required.

When a domain has multiple backends, all writes (uploads, deletes, copies) fan out to every backend. Reads use the **primary** backend. This supports mirroring a domain to e.g. S3 and a local NAS simultaneously.

#### Primary backend selection

Reads are served by a single primary backend, chosen in this order:

1. the first backend with `"main": true`;
2. otherwise the first `local` backend (local disk is faster and more available than the cloud);
3. otherwise the first backend listed.

`tsync configure` asks whether each backend should be the primary, defaulting to yes for `local` and no for `s3`. Marking more than one backend `main` simply uses the first; the choice only affects reads, since every write already fans out to all backends.

### TLS backend

S3 connections go through `conduit`, which can use one of two TLS implementations. tsync makes the **native** backend (`ocaml-tls`, via `tls-lwt`) a mandatory dependency and the default; the **OpenSSL** backend (via `lwt_ssl`) is an optional dependency and is only available when `lwt_ssl` is installed in the switch. Native is preferred because OpenSSL's conduit path has a per-connection error-queue bug that breaks some S3-compatible endpoints — notably Backblaze B2, which fails with `SSL routines::shutdown while in init` on the second connection.

The choice is process-global (one backend per daemon) and can be set two ways, highest priority first:

1. **CLI flag** — `tsync start --tls native|openssl` (overrides the config).
2. **Config** — the top-level `"tls": "native"|"openssl"` field (applies to every S3 command: `start`, `ls`, `versions`, `expire`, `sync`).

If neither is set, conduit's built-in default (native) is used, so B2 works out of the box. Selecting a backend that isn't compiled in fails immediately, listing what is available.

### Chunked uploads

Every file is stored as one or more 8 MB chunks. Each chunk is stored at `<prefix>/.chunks/<h1>-<h2>` where `h1` and `h2` are the xxHash3-64 of the chunk data computed with seeds 0 and 1 respectively, encoded as 16-character lowercase hex. The primary key holds a JSON manifest. Files smaller than 8 MB produce a single-chunk manifest. On re-upload, only chunks whose hash changed are uploaded — unchanged chunks are reused. Chunks are shared across all files and versions.

Hashing is done per file, not per chunk: `remote.ml`'s `upload` memory-maps the source read-only (`Unix.map_file`, so RAM isn't committed for multi-GB files — the OS pages it) and computes every chunk's `h1`/`h2` in a single C call (`Xxhash.hash_chunks_bigarray`) that releases the OCaml runtime lock **once** for the whole loop, dispatched with one `Hash_pool.detach`. Chunk uploads then stream from zero-copy slices of the mapping, bounded independently of hashing. mmap is safe against concurrent writes because those rename-replace the cache file (a new inode) rather than truncating it in place, so the mapping stays valid.

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

### Cursor flusher

Journal entries are written to the backend immediately on each mutation. The `.cursor/<domain>` key is updated separately by a background flusher that runs every ~2 seconds: it writes the cursor once per window, pointing to the latest journal entry. A burst of 50 uploads in 2 seconds produces 50 journal entries but only 1 cursor write.

### Cross-client sync

Multiple clients can mount the same domain concurrently. Each client applies the others' changes through the journal:

- **Sync poller** (`lib/file/sync_poller.ml`, started by both runtimes): a background Lwt task polls `.cursor/<domain>` every ~2 s. When the cursor changes, it lists journal entries after the last-sync marker, filters out entries carrying its own `client_uuid`, and applies each foreign entry via `File.apply_foreign_ops`. The local marker (`last-sync-<domain>` in the data dir) then advances to the newest entry.
- **`File.apply_foreign_ops`** translates a foreign journal entry into local state:
  - `put` — fetch the remote manifest, update the local `.manifest` sidecar, evict any stale cached data (next read downloads the new content).
  - `delete` — remove local cache and sidecar.
  - `mkdir` / `rmdir` — create/remove the local directory marker.
  - `rename` — move the local sidecar and cached data when the source is known locally; otherwise adopt the remote manifest of the destination.

**Safety guards.** A foreign op never touches a file with local un-uploaded changes (`is_dirty`, cleared after each successful upload) or a file currently open (`is_open`; open-handle counting lives in `File.Make` and is driven by the FUSE open/release path). A skipped change is picked up again on a later foreign op for the same file or a full resync.

**Conflict handling.** All mutations are journaled and backend renames are copy+delete, so races surface as a rename whose source has vanished from the backend. When that happens (verified with a HEAD on the source), the rename — already applied locally — degrades into publishing the file under a conflict-marked name derived from the config `name` field: `"baz (conflicted copy from <client name>).txt"`. The file's chunks are already on the backend, so publishing costs one manifest PUT per backend plus a journal `put` entry. This covers both the delete-vs-rename race (the file survives, conflict-marked) and the rename-vs-rename race (the winner's name plus the loser's conflict copy, converging on all clients). Concurrent writes to the same file are last-writer-wins: the slower client's clean local copy is evicted and converges on the backend version.

**Crash recovery.** Each mutation writes a local pending journal entry before the backend operation and deletes it after the journal entry is published; on startup, leftover pending entries are replayed. A backend operation that fails synchronously also deletes its pending entry — the error is reported to the caller, so replaying a known-failed op at every startup would be wrong.

**FileProvider integration.** On macOS the poller runs in the daemon, not the sandboxed extension. After applying foreign ops it sends `CHANGED <key>` over `notify.sock`; the extension responds with `evictItem` + `signalEnumerator`, so Finder drops stale content and re-fetches metadata.

### `tsync sync`

Brings the local filesystem in sync with the backend on demand (same journal-cursor logic as the poller, usable when no daemon is running). Also used for crash recovery.

1. Read `last_sync_key` from local state file. Empty → full resync.
2. If `oldest_journal_timestamp > last_sync_timestamp` → **full resync** (journal gap; changes were missed).
3. Otherwise → **incremental**: list journal entries after `last_sync_key`, filter out own `client_uuid`, apply each foreign entry via `File.apply_foreign_ops`.

`last_sync_key` is stored as a full backend key (`<prefix>/.journal/<domain>/<filename>`). Only the filename part is used for comparisons with the relative keys returned by `list_journal_keys`.

### Versioning

When `versioning = true`, every change that overwrites or removes a file's manifest first copies the current manifest to `<prefix>/.versions/<domain>/<path>/<timestamp-ns>`. A version is only the small manifest JSON — the data chunks it references live in `.chunks/` and are shared across every file and version, so a version is cheap to save and can be restored without transferring any content. There are three save sites: `Remote.upload` (before writing the new manifest, so a modify keeps the old one), `File.apply_delete`, and `File.rename` (versions the source path). History grows until it is trimmed with `tsync expire`.

`File.revert ?version key` restores a version: it copies the versioned manifest back to the live key on every backend, writes a journal `put` entry (so other clients converge), refreshes the local `.manifest` sidecar, and **evicts** any cached data. The restored file is therefore dataless — its bytes are fetched lazily on next open, exactly like any other evicted file. With no `version` it picks the most recent timestamp.

The CLI exposes this as `tsync versions [PATH]` (a file's history, or every deleted file when PATH is omitted — a deleted file is one with versions but no live manifest) and `tsync revert PATH [--version TS]`. Listing reads the backend directly; `revert` goes through the daemon (`revert` IPC action) so the sidecar is refreshed and, on macOS, the FileProvider extension is signalled via `CHANGED`.

### Expiry and chunk GC

`Expire.Make(C).expire ~cutoff ()` trims history and reclaims storage in a mark-and-sweep over the primary backend, with deletions fanned out to every backend (batched via `delete_multi`). **The cutoff (seconds since the epoch) bounds versions only.** (1) List `.versions/<domain>/` once and partition by the `<timestamp-ns>` suffix into expired (older than the cutoff) and surviving; delete the expired keys, plus the now-empty version directory of any path with no surviving version (a no-op on S3, which has no directory objects, but it prunes the emptied directory on a filesystem backend). (2) Mark every chunk referenced by a live manifest (`.chunks/` keys read from `<domain>/…`) or a surviving version. (3) Sweep: delete every `.chunks/` object whose key is not marked — regardless of age or cutoff. There is no chunk refcount index; step 2 reads each surviving manifest, which is fine for a manual admin command. Mark-and-sweep races with a concurrent upload (which writes chunks before its manifest), so `expire` is meant to run while clients are idle.

The CLI exposes this as `tsync expire DATE` (`YYYY-MM-DD`, parsed to local midnight). It prints the number of versions and chunks removed and chunks kept.

### Shared OCaml libraries (`lib/`)

The platform-agnostic core lives in `lib/` and is compiled into both the Linux and macOS binaries:

All library modules are parameterised by a `Conf.S` module (a first-class module produced in `bin/tsync.ml` from the parsed config and runtime paths). No config record is threaded through function arguments.

| Module | Role |
|---|---|
| `core/conf_parsing.ml` | Config loading from file or `TSYNC_CONFIG_JSON` env; prefix derivation helpers |
| `core/ipc.ml` | Unix socket IPC transport — client `send`, server loop, notify channel, auto-evict marker |
| `ipc_handler/ipc_handler.ml` | `Ipc_handler.Make(C)(F)` — the shared JSON request dispatcher used by both runtimes; runtime differences captured in a `hooks` record |
| `conf/conf.mli` | `module type S` — the functor parameter type used by all library modules |
| `backends/` | Pluggable storage backends (S3 via `aws-s3` + Lwt, local filesystem); self-registration pattern |
| `tls/tls_conf.ml` | Runtime selection of conduit's TLS backend (native / OpenSSL) for S3 |
| `xxhash/xxhash.ml` | xxHash3-64 C bindings (dual-seed for chunk fingerprinting) |
| `local_io/local_io.ml` | Paged local file read/write |
| `local_io/fs_util.ml` | Shared Lwt filesystem helpers (`mkdir_p`, `rm_rf`, `readdir_list`, …) |
| `metrics/metrics.ml` | Transfer and hashing counters (totals + rolling rate) for `tsync stats` |
| `log/` | Logging backends (printf for development, syslog for production) |
| `file/manifest.ml` | Manifest JSON serialization/deserialization; chunk key derivation |
| `file/local.ml` | Local cache paths; create/evict/rename local cache entries |
| `file/remote.ml` | Chunked upload and download against the backend. Upload mmaps the source and hashes all chunks in one pass (one runtime-lock release per file) before storing them |
| `file/hash_pool.ml` | Domainslib pool (via `lwt_domain`) that runs each file's whole-file hash off the event loop, so concurrent uploads hash in parallel |
| `file/versioning.ml` | Version key construction + `save` (copy live manifest to a timestamped version) |
| `file/expire.ml` | `Expire.Make(C).expire` — delete versions older than a cutoff, then GC unreferenced chunks |
| `file/file.ml` | `File.Make(C)(Sq)` — central file abstraction: stat, read, write, upload, download, evict, delete, rename, mkdir; dirty/open tracking; `apply_foreign_ops` and conflict-copy publishing |
| `file/sync_poller.ml` | `Sync_poller.Make(C)(F)` — background version-key poller applying foreign journal entries; `sync_once` for on-demand sync |
| `sync_queue/journal.ml` | `Journal.Make(C)` — journal entry read/write; local pending-entry tracking for crash recovery |
| `sync_queue/file_store.ml` | `File_store.Make(C)` — backend operations with journal bookkeeping; directory list/rename/delete |
| `sync_queue/sync_queue.ml` | `Sync_queue.Make(C)` — async upload queue with a bounded pool of Lwt worker tasks and per-key coalescing |
| `file_provider/file_provider.ml` | `File_provider.Make(C)` — macOS FileProvider runtime: serves the shared IPC handler with FileProvider-specific hooks |

### CLI binary (`bin/tsync.ml`)

The same `tsync` binary is used on both platforms. `bin/tsync.ml` reads runtime paths once, parses config into a `(module Conf.S)`, then applies the appropriate functors per subcommand. The active backend is selected at compile time via the `runtime` module alias:

| Module | Selected when |
|---|---|
| `runtime.fuse.ml` | `tsync_fuse` library present (Linux) |
| `runtime.file_provider.ml` | `tsync_file_provider` library present (macOS) |

```
tsync configure

tsync start   [--mount <path>] [--domain <name>] [--tls native|openssl]
tsync stop
tsync status
tsync stats

tsync evict   <path>
tsync restore <path>
tsync ls      [path] [--deleted]
tsync sync    [--domain <name>]

tsync versions [path]
tsync revert   <path> [--version <ts>]
tsync expire   <date>

tsync auto-evict [on|off|status]
tsync purge   <path>
```

`tsync configure` writes the config file interactively. It prompts for versioning, upload/download concurrency, and (when both TLS backends are built and an S3 backend is used) the TLS backend, then loops over domains (name, prefix, backends) — each backend can be marked as the primary. On macOS it writes to the group container so both the daemon and extension can read it; on Linux it writes to the XDG config dir with mode `0600`.

### IPC protocol

All daemon communication goes through a Unix socket. The socket path is runtime-specific (see platform sections below). Both runtimes serve the **same** JSON protocol via the shared `Ipc_handler` module — one JSON object per request line, one JSON object per response line.

Runtime-specific behavior (how eviction happens, whether restore materializes locally or notifies the extension, what `status` reports) is supplied through a `hooks` record passed to the handler. The file-operation actions (`stat`, `list_dir`, …) are identical on both platforms; the daemon actions (`evict`, `restore`, `revert`, `full_resync`, `status`, `stop`) run the runtime's hooks. `revert` runs `File.revert` in the shared core, then calls the runtime's `changed` hook (a no-op on FUSE, `CHANGED <key>` over `notify.sock` on macOS).

**Requests:**

```json
{"action":"stat","path":"<key>"}
{"action":"list_dir","path":"<prefix>"}
{"action":"list_all","path":"<prefix>"}
{"action":"cursor"}
{"action":"changes_since","arg":"<journal-key|>"}
{"action":"ensure_cached","path":"<key>"}
{"action":"create","path":"<key>"}
{"action":"write","path":"<key>","staging":"<local_path>"}
{"action":"delete","path":"<key>"}
{"action":"rename","path":"<dst_key>","src":"<src_key>"}
{"action":"mkdir","path":"<key_with_slash>"}
{"action":"rmdir","path":"<key_with_slash>"}
{"action":"evict","path":"<path>"}
{"action":"restore","path":"<path>"}
{"action":"revert","path":"<path>","arg":"<timestamp|>"}
{"action":"auto_evict","arg":"on|off|status"}
{"action":"full_resync"}
{"action":"status"}
{"action":"stop"}
```

For `evict`/`restore` the `path` is a filesystem path (from the CLI) that the runtime's `path_to_key` hook maps to a storage key; the file-operation actions take domain-prefixed keys directly.

**Responses:** `{"ok":true, ...}` with action-specific fields (e.g. `size`, `mtime`, `etag`, `isUploaded`, `localPath`, `dirs`, `files`), or `{"ok":false,"error":"<message>"}` on failure. The listed backend objects are manifests, so `list_dir`/`list_all` read each file's manifest to report the **logical** `size`/`mtime` and the content hash (`h1`) as `etag` — the same identity `stat` returns (empty for dirty files). `list_dir` returns directories as full keys ending in `/`, matching `list_all` and the change feed.

**Change feed** (`cursor` / `changes_since`) exposes the change journal as a delta query so the macOS FileProvider can drive `enumerateChanges` from a real sync anchor rather than re-importing. `cursor` returns the current journal cursor (`{"cursor":"<journal-key>"}`); `changes_since` returns the ops committed after a given journal key plus the new cursor (`{"cursor":"<journal-key>","ops":[{"op":"put|delete|mkdir|rmdir|rename","key":"<full-key>", ...}]}`). The query is stateless — it filters journal entries by `key > arg` and drops the caller's own `client_uuid` — so it does **not** touch the sync poller's `last-sync` marker; the OS tracks the extension's anchor independently. Op keys are returned as full storage keys (directories ending in `/`) to match the identifiers the extension uses.

**Reverse notify channel** (`notify.sock`, daemon → extension, macOS only):

```
EVICT <key>
RESTORE <key>
UPLOADED <key>
CHANGED <key>
```

`CHANGED` is sent by the sync poller after applying a foreign journal entry. The extension evicts any materialized copy of that key, then signals the **working set** (not the specific key — signalling an identifier the local DB has never seen cannot introduce it). That drives `enumerateChanges`, which pulls the journal delta via `changes_since` and upserts/removes items by their parent identifier, so newly-discovered remote files appear.

### Tests

Tests are platform-agnostic snapshot tests that run under `dune test`. Each scenario spins up a fresh daemon instance against a temporary `local` backend and real Unix socket, replays a sequence of file operations over the JSON IPC protocol, then dumps a snapshot of the resulting state — the visible tree (name, size, cache/upload status, etag), file contents, and every backend object (chunks, manifests, journal entries, version pointer). dune diffs that snapshot against a checked-in `.expected` file.

```bash
dune test                    # run all suites, fail on any snapshot diff
dune test --auto-promote     # accept current output as the new snapshots
```

The harness and the scenarios are separate so suites are cheap to add:

| Path | Role |
|---|---|
| `tests/runner/` | `tsync_test_runner` library — the harness: temp environment setup, IPC driver, deterministic snapshot dumper. Exposes `step`, `scenario`, `run`, and the two-client variants |
| `tests/base/` | `base.ml` — one representative scenario per file operation (create, copy, rename, delete, evict, restore, mkdir, rmdir); `base.expected` snapshot |
| `tests/sync/` | `sync.ml` — cross-client sync and race scenarios; `sync.expected` snapshot |
| `tests/ipc/` | `ipc.ml` — snapshots of the raw `list_dir`/`list_all` and `changes_since`/`cursor` IPC responses (the FileProvider contract); `ipc.expected` snapshot |
| `tests/versioning/` | `versioning.ml` — modify/rename/delete keep versions, and `revert` restores one dataless (run with `~versioning:true`); `versioning.expected` snapshot |
| `tests/expire/` | `expire.ml` — `expire` drops versions older than a cutoff (including a mid-scenario `Mark` boundary) and GCs unreferenced chunks while keeping live/surviving ones; `expire.expected` snapshot |
| `tests/hash/` | `hash.ml` — unit test: the whole-file chunk hasher (`Xxhash.hash_chunks_bigarray`) agrees with the single-string hash per chunk across boundary/partial/empty cases (pins chunk-key stability) |
| `tests/upload/` | `upload.ml` — end-to-end multi-chunk `Remote.upload` on a local backend: 3-chunk round-trip, dedup, concurrent identical-chunk writes, and a 0-byte file |

A scenario is declarative data — a `name` and a list of `step`s (`Write`, `Mkdir`, `Rmdir`, `Rename`, `Delete`, `Evict`, `Restore`, `Open`, `Close`, `Drain`, `Sync`). To add a suite, create a sibling directory under `tests/` with a scenario file that does `open Test_runner`, its own `.expected` snapshot, and the three dune stanzas from `tests/base/dune` (executable, `with-stdout-to` output rule, `runtest` diff rule).

**IPC-response snapshots** (`run_ipc` / `run_ipc_changes`) dump the actual JSON the daemon returns rather than a reconstructed tree, so the FileProvider-facing contract is pinned directly: `list_dir` returning directories as full keys and files with logical size + content-hash (`h1`) etags, and `changes_since` producing the working delta, the up-to-date empty response, and the stale flag (pruned-past anchor → full re-list). Only the non-deterministic fields are normalized (wall-clock mtimes, journal-key cursors, filesystem-order arrays); etags and keys are deterministic and asserted verbatim.

**Two-client scenarios** (`run_two_client_scenarios`) instantiate two complete client stacks — separate caches, data dirs, sockets, and journal identities — sharing one backend. Each step is tagged with the client it runs on (`A (Write …)`, `B Sync`), and every operation goes through the same user-facing IPC path a real client uses; nothing is injected or simulated. The snapshot shows both clients' trees and contents, each client's pending journal entries, and the backend state, so convergence (or a deliberate divergence, like an open-file guard) is visible directly. `tests/sync/` covers foreign puts/deletes/renames/overwrites, rename chains, directory propagation, concurrent creates, open-file guards, and the delete-vs-rename and rename-vs-rename races. Crash-recovery suites are the intended next addition.

---

## Part 2 — Linux FUSE

The Linux backend mounts a FUSE filesystem at `~/tsync/<domain>/` using `ocamlfuse`. The daemon runs in the foreground under systemd (or any process supervisor).

### Architecture

```
tsync start
  ├── Lwt event loop (dedicated thread) — owns all daemon state and backend I/O
  │     ├── Ipc.serve       Unix socket at ~/.local/share/tsync/tsync.sock (one Lwt task per client)
  │     ├── cursor_flusher  Lwt task: drains pending_cursor → backend every ~2 s
  │     ├── sync_poller     Lwt task: watches .cursor key, applies foreign journal entries
  │     └── Sync_queue      bounded pool of Lwt upload workers
  └── Fuse.main (Multi_threaded)
       └── FUSE ops → Lwt_preemptive.run_in_main → File.* on the loop
```

All daemon state and backend I/O live on the single Lwt event loop. FUSE runs multi-threaded; each handler bridges into the loop with `Lwt_preemptive.run_in_main`, so a slow operation blocks only its own kernel thread while the loop keeps serving others (e.g. `tsync status` stays instant during a large restore).

### Source layout (`linux/lib/fuse/`)

| File | Role |
|---|---|
| `fuse_fs.ml` | `Fuse_fs.Make(C)` — FUSE operation handlers bridged to the Lwt loop via `run_in_main`; hosts the Lwt loop (IPC server, cursor flusher, sync poller, upload workers); serves the shared `Ipc_handler` with FUSE-specific hooks |
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
- **release** (last close): if the file was written, posts a `Put` event to `Sync_queue`. The upload runs asynchronously on a Sync_queue worker; the FUSE operation returns immediately.
- **unlink / mkdir / rmdir / rename**: synchronous backend operations with journal write-ahead. `rename` handles both file and directory cases by detecting trailing `/` in the key.

### Auto-evict

After a successful upload, the daemon optionally evicts the local copy. Controlled by `tsync auto-evict on|off`; state persists as the auto-evict flag (see Paths above).

### Systemd

The daemon runs as a user systemd service. Logs via syslog (viewable with `journalctl --user -u tsync -f`).

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
  │    ├── fetchContents      download: ensure_cached → hand daemon's local path to the OS
  │    ├── createItem         file: write+upload; dir: mkdir
  │    ├── modifyItem         rename / content update / metadata-only
  │    └── deleteItem         unlink / rmdir
  ├── TsyncEnumerator         NSFileProviderEnumerator
  │    ├── enumerateItems     list_dir (per-directory) / list_all (working set)
  │    ├── enumerateChanges   changes_since(anchor) → didUpdate/didDeleteItems; anchor = journal cursor
  │    └── currentSyncAnchor  cursor (current journal key)
  └── NotifyListener          listens on notify.sock; receives EVICT / RESTORE / UPLOADED / CHANGED from daemon

OCaml daemon (tsync start, LaunchAgent via deploy-daemon.sh)
  ├── Ipc.serve               Unix socket — JSON + CLI dispatch
  ├── Sync_queue              Lwt worker pool for async upload
  ├── sync_poller             applies foreign journal entries → CHANGED → extension evict + working-set signal → enumerateChanges
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
4. Extension passes the URL to FileProvider's completion handler, which copies the content to its own storage.
5. The daemon's staged copy is dropped by `on_upload_done` (uploads) or an explicit evict; the daemon cache is only ever a transient staging area on macOS.

**Eviction (OS or user evicts a file):**

1. FileProvider calls `NSFileProviderManager.evictItem` (OS-driven).
2. `tsync evict <path>` from the CLI sends an `evict` JSON request; the FileProvider runtime's hook forwards `EVICT <key>` over `notify.sock`.
3. `NotifyListener` receives it and calls `NSFileProviderManager.evictItem`, closing the loop.

### Source layout

**OCaml (`lib/file_provider/`):**

| File | Role |
|---|---|
| `file_provider.ml` | Serves the shared `Ipc_handler` with FileProvider hooks (evict/restore/changed forward over `notify.sock`); `path_to_key` with CloudStorage path stripping |

**Swift (`macos/`):**

| File | Role |
|---|---|
| `Shared/Config.swift` | Config loading from group container (`~/Library/Group Containers/group.com.toots.tsync/config.json`) |
| `TsyncApp/AppDelegate.swift` | Registers `NSFileProviderDomain` for each configured domain |
| `TsyncFileProvider/IPC.swift` | JSON IPC client to the OCaml daemon; typed wrappers for each action |
| `TsyncFileProvider/Item.swift` | `NSFileProviderItem` implementation; `isUploaded` reflects daemon manifest state |
| `TsyncFileProvider/Enumerator.swift` | `NSFileProviderEnumerator`; per-directory `list_dir`, recursive `list_all` for working set; `enumerateChanges` replays the journal delta (`changes_since`) with the journal cursor as sync anchor |
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

`enumerateWorkingSet` calls `IPC.listAll` (the `list_all` JSON action), which returns a flat list of all files under the domain prefix via `File_store.list_all_files`. This powers Spotlight and Recents across the full directory tree, not just the root. Directory-marker keys (ending in `/`) are filtered out here — the working set holds files only, and emitting a marker would collide with the real folder from the container enumeration and surface as a duplicate `<name> 2`.

### Change tracking

The extension implements real change tracking against the journal rather than re-importing:

- **Sync anchor = journal cursor.** `currentSyncAnchor` returns the `cursor` action's value; the anchor bytes are the journal key (`"0"` is the empty-cursor sentinel, since anchors must be non-empty).
- **`enumerateChanges(from: anchor)`** calls `changes_since(anchor)` and translates the returned ops: `put`/`mkdir`/`rename`-dst → `didUpdate` (rebuilding the item, resolving file metadata via `stat`); `delete`/`rmdir`/`rename`-src → `didDeleteItems`. It finishes at the new cursor. Items carry correct parent identifiers, so additions land in the right folder regardless of which enumerator (a container or the working set) reported them.
- **Trigger.** The daemon's sync poller applies a foreign entry, then sends `CHANGED`; the extension signals the working set, which makes the OS call `enumerateChanges`. The per-key `signalEnumerator` used previously could refresh a known item but never introduce a newly-discovered one.

Item identifiers are the full storage key, with folders ending in `/` — consistent across container enumeration, `parentIdentifier`, `s3Key`, and the change feed, so each item has exactly one identity.

Item versions (`NSFileProviderItemVersion`) must be non-empty or the OS silently drops the item. `contentVersion` is the file's content hash (`Manifest.h1`, returned as `etag` by `stat` and the listings alike); a dirty file has no clean hash, so it falls back to `size:mtime`. `metadataVersion` is `content:isUploaded`, so a completing upload refreshes the item without forcing a content re-download.

IPC failures are mapped to `NSFileProviderError.serverUnreachable` (`IPC.fileProviderError`) — returning the extension's own error domain makes fileproviderd treat the failure as fatal and cache an empty listing, so a not-yet-ready daemon at startup must surface as a *retryable* error.

### Deploy

```bash
macos/deploy-daemon.sh   # build OCaml daemon, install to ~/.local/bin/tsync, load launchd plist
make -C macos generate   # regenerate tsync.xcodeproj from project.yml
make -C macos build      # xcodebuild TsyncApp (Release)
make -C macos deploy     # build + install TsyncApp to /Applications + reload LaunchAgent
```

---

## Known limitations

**Chunk GC is manual.** Chunks accumulate in `<prefix>/.chunks/` until `tsync expire <date>` collects the unreferenced ones (see [Expiry and chunk GC](#expiry-and-chunk-gc)). There is no automatic or scheduled collection, and — since the sweep marks by scanning every manifest — `expire` should run while clients are idle.

**Concurrent writes are last-writer-wins.** Cross-client changes are reconciled through the journal (see [Cross-client sync](#cross-client-sync)): concurrent renames and delete-vs-rename races produce conflict-marked copies, and no data is lost. But two clients writing the *same* file concurrently still resolve by last manifest write; the slower writer's content is superseded rather than preserved as a conflict copy. A stronger guarantee would need S3 conditional PUT (`If-None-Match`) with a retry loop. There is also a small window where a foreign rename whose journal entry is not yet visible resolves as a plain conflict copy rather than adopting the peer's chosen name.

**No background prefetch.** Files download on first open. `tsync pull` (not yet implemented) would bulk-download evicted files.

**Change tracking only sees journaled changes.** Cross-client propagation (and the macOS `enumerateChanges` feed) is driven by the change journal, so a change made directly in the bucket — outside any tsync client — writes no journal entry and is not picked up incrementally. It surfaces only on a full re-import (re-adding the domain) or `full_resync`. This matches the sync poller's existing model.

**Chunks are not encrypted at the application layer.** Enable S3 SSE-S3 or SSE-KMS on the bucket for encryption at rest.

**Linux: single metadata lock.** FUSE runs `Multi_threaded` and bridges to the Lwt loop via `run_in_main`, so reads, downloads, and uploads proceed concurrently. Metadata mutations (delete/mkdir/rmdir/rename/revert) are serialized through one global `Lwt_mutex`; switching to per-key locks would only matter under heavy concurrent metadata churn.

**macOS: extension consent required.** macOS requires one-time user consent in System Settings → General → Login Items & Extensions → File Provider Extensions before the extension activates and the CloudStorage mount appears.

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE).
