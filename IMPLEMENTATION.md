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
      "symlinks": "keep",
      "backends": [
        {
          "type": "s3",
          "name": "aws",
          "bucket": "my-bucket",
          "region": "us-east-1",
          "accessKeyId": "AKIA...",
          "secretAccessKey": "..."
        },
        {
          "type": "local",
          "name": "nas",
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
          "name": "aws",
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
| `tls` | string | Optional. TLS backend for S3 connections: `"openssl"` (faster, default when available) or `"native"` (ocaml-tls fallback). See [TLS backend](#tls-backend) |
| `maxUploads` | int | Optional. Max concurrent upload operations (default 4) — bounds both how many files the upload workers process at once and, via the shared chunk buffer pool, how many chunk reads/uploads run concurrently across all of them combined. See [Chunked uploads](#chunked-uploads) |
| `maxDownloads` | int | Optional. Max files downloaded concurrently (default 8) |
| `domains` | domain[] | One or more domain objects |

**Domain fields:**

| Field | Type | Description |
|---|---|---|
| `name` | string | Domain name — used as the mount directory name and storage namespace segment |
| `prefix` | string | Key prefix shared by all backends for this domain (no leading/trailing slash) |
| `symlinks` | string | Required. Symlink policy: `"keep"` — import stores symlinks as symlink objects and they can be created live through the mount; `"follow"` — import dereferences to target content (broken links skipped); `"skip"` — import ignores symlinks. Under `follow`/`skip`, live creation through the mount is rejected with `EPERM` |
| `backends` | backend[] | One or more backends; writes fan out to all, reads use the primary (see below) |

**Backend fields (`type: "s3"`):**

| Field | Type | Description |
|---|---|---|
| `type` | `"s3"` | Backend type |
| `name` | string | Required. Backend name, unique within the domain — selects backends on the CLI (e.g. `resync-remote --source`) |
| `bucket` | string | S3 bucket name |
| `region` | string | AWS region (e.g. `us-east-1`), or the vendor region for an S3-compatible service |
| `endpoint` | string | Optional. Custom S3 endpoint host for S3-compatible services (e.g. `s3.us-east-005.backblazeb2.com` for Backblaze B2). Omit for AWS |
| `accessKeyId` | string | AWS access key ID |
| `secretAccessKey` | string | AWS secret access key |
| `main` | bool | Optional. Mark this backend as the primary (read) backend. See [Primary backend selection](#primary-backend-selection) |
| `unsignedPayload` | bool | Optional. Skip per-chunk SHA256 payload signing (`UNSIGNED-PAYLOAD`), trading the request body's integrity signature for lower CPU use. Safe over TLS, where the transport already authenticates the body. Default `false` |

**Backend fields (`type: "local"`):**

| Field | Type | Description |
|---|---|---|
| `type` | `"local"` | Backend type |
| `name` | string | Required. Backend name, unique within the domain — selects backends on the CLI (e.g. `resync-remote --source`) |
| `path` | string | Root directory for this backend; keys are stored as paths under this root |
| `main` | bool | Optional. Mark this backend as the primary (read) backend. See [Primary backend selection](#primary-backend-selection) |

**Backend fields (`type: "ssh"`):**

Stores blobs on a remote machine over plain OpenSSH — nothing to install on the remote beyond sshd, POSIX sh and GNU coreutils. Each operation runs a short shell snippet on the remote host, with data piped over stdin/stdout. Connection multiplexing (`ControlMaster`/`ControlPersist`) is enabled automatically, so after the first connection each operation is a cheap channel open on the shared connection. Per-host settings (port, identity file, user, ...) belong in `~/.ssh/config`.

| Field | Type | Description |
|---|---|---|
| `type` | `"ssh"` | Backend type |
| `name` | string | Required. Backend name, unique within the domain — selects backends on the CLI (e.g. `resync-remote --source`) |
| `host` | string | SSH destination, e.g. `"user@linuxbox"` or a `~/.ssh/config` host alias |
| `path` | string | Root directory on the remote host; keys are stored as paths under this root |
| `main` | bool | Optional. Mark this backend as the primary (read) backend. See [Primary backend selection](#primary-backend-selection) |

**Backend fields (`type: "exec"`):**

Escape hatch behind the `ssh` type: the same storage-over-a-command backend, but with a fully arbitrary command line. The shell snippet is appended as the final argument, so `"command": ["ssh", "-p", "2222", "-i", "/path/key", "user@host"]` gives SSH with custom options, and `["sh", "-c"]` runs against the local machine.

| Field | Type | Description |
|---|---|---|
| `type` | `"exec"` | Backend type |
| `name` | string | Required. Backend name, unique within the domain — selects backends on the CLI (e.g. `resync-remote --source`) |
| `command` | string[] | Command and arguments to spawn for each operation; a POSIX-sh snippet is appended as the final argument |
| `path` | string | Root directory (as seen by the command) for this backend; keys are stored as paths under this root |
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

S3 connections go through `conduit`, which can use one of two TLS implementations. tsync makes the **native** backend (`ocaml-tls`, via `tls-lwt`) a mandatory dependency; the **OpenSSL** backend (via `lwt_ssl`) is an optional dependency and is only available when `lwt_ssl` is installed in the switch. **OpenSSL is much faster in general and is used by default whenever it is compiled in.** The **native** backend is a robust fallback: it can solve connection problems that OpenSSL's conduit path causes on some S3-compatible endpoints, where a per-connection error-queue bug breaks the transfer — notably Backblaze B2, which fails with `SSL routines::shutdown while in init` on the second connection. Switch to native with `--tls native` if you hit such an endpoint.

The choice is process-global (one backend per daemon) and can be set two ways, highest priority first:

1. **CLI flag** — `tsync start --tls native|openssl` (overrides the config).
2. **Config** — the top-level `"tls": "native"|"openssl"` field (applies to every S3 command: `start`, `ls`, `versions`, `expire`, `sync`).

If neither is set, the preferred available backend is used: OpenSSL when it is compiled in (for performance), otherwise native. Selecting a backend that isn't compiled in fails immediately, listing what is available.

### Chunked uploads

Every file is stored as one or more 8 MB chunks. Each chunk is stored at `<prefix>/.chunks/<h1>-<h2>` where `h1` and `h2` are the xxHash3-64 of the chunk data computed with seeds 0 and 1 respectively, encoded as 16-character lowercase hex. The primary key holds a JSON manifest. Files smaller than 8 MB produce a single-chunk manifest. On re-upload, only chunks whose hash changed are uploaded — unchanged chunks are reused. Chunks are shared across all files and versions.

Hashing happens inline with the upload of each chunk. `remote.ml`'s `upload` opens the file once, stats it, then launches every chunk's task at once via `Lwt_list.map_p` — concurrency is bounded not by batching, but by a shared `Buffer_pool` sized to `maxUploads`: each chunk task blocks on acquiring a pooled buffer until one frees, so real concurrent chunk work is capped at `maxUploads` regardless of how many files are uploading at once. Each chunk is read from the file with a positioned `pread` (no separate `lseek`, and no per-chunk `open`/`close`: one fd is opened per file, shared safely across concurrently-reading chunks), hashed (both seeds, on the event loop — XXH3 on 8 MB is sub-millisecond), and uploaded only if a HEAD check finds its key absent from the backend; a per-session table memoizes chunks already confirmed present or just uploaded, so a repeated chunk (same content in another file, or a retry) skips the HEAD round trip. There's no upfront listing of existing chunks — that would scale with the size of the whole historical chunk store rather than with the upload actually being done. Once every chunk is stored, the collected entries become the manifest, which is written last. The upload is cancellable at chunk granularity: a `bool ref` cancel flag is polled before each chunk and raises `Cancelled` when set — the sync queue's per-key cancel (`Sync_queue.cancel_put`, flipped on a concurrent write) is that same flag. A concurrent in-place truncation surfaces as a short read, which also aborts the upload. Peak memory is `maxUploads` chunk-sized buffers, shared process-wide (not per file), allocated lazily on first use of each pool slot.

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

**Symlink manifest** — when `symlinks: "keep"` is configured, a symlink is stored as a chunkless manifest with a `"symlink"` field holding the link target. No chunk objects are written; `size` is the byte length of the target string (POSIX convention). The manifest is the single source of truth: FUSE `getattr` returns `S_LNK`, `readlink` returns the target, `tsync export` recreates the link, and FileProvider exposes it as a symbolic link item (`symlinkTargetPath` on the item; the enumeration and stat IPC responses carry a `symlinkTarget` field).

Symlinks enter the store two ways: `tsync import` on a tree containing links, and live creation through the mount — `ln -s` on FUSE (the `symlink` operation) or symlink creation in Finder/FileProvider (`createItem` with a `.symbolicLink` template), both of which go through the `symlink` IPC action (`{"action":"symlink","path":<key>,"target":<target>}`) into `File.symlink`. The journal records a plain `put`; the manifest carries the symlink-ness, so no dedicated journal op exists and foreign clients apply it like any other manifest update.

`File.symlink` enforces the policy: under `follow` or `skip` it fails with `EPERM`, keeping the invariant that a non-`keep` domain never contains symlink objects — a link can't slip in through the mount past the import policy.

```json
{
  "v": 1,
  "size": 8,
  "chunkSize": 8388608,
  "mtime": 1700000000.0,
  "chunks": [],
  "symlink": "real.txt"
}
```

(`h1`/`h2` are present in the stored JSON — they are fixed constants derived from hashing an empty chunk list — but carry no semantic meaning for symlinks.)

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

1. `--full` given, or `last_sync_key` empty → full resync.
2. If `oldest_journal_timestamp > last_sync_timestamp` → **full resync** (journal gap; changes were missed).
3. Otherwise → **incremental**: list journal entries after `last_sync_key`, filter out own `client_uuid`, apply each foreign entry via `File.apply_foreign_ops`.

A **full resync** invokes the daemon's `full_resync` IPC action, then advances `last_sync_key` to the current cursor. On FUSE the hook wipes the local cache tree (next `getattr`/`readdir` re-pulls live from the backend); on macOS it sends `RESYNC` over `notify.sock` so the extension calls `reimportItems`. `tsync sync --full` forces this on demand — the only way to pick up out-of-band bucket changes (see [Known limitations](#known-limitations)).

`last_sync_key` is stored as a full backend key (`<prefix>/.journal/<domain>/<filename>`). Only the filename part is used for comparisons with the relative keys returned by `list_journal_keys`.

### `tsync recheck` — verify/repair remote state from the local cache

`Recheck.Make(C).run` walks every `.manifest` sidecar in the local cache (sorted) and verifies the remote state file by file, repairing what it can. Files with a `Dirty` sidecar (upload pending) are skipped. Two paths, both in `Remote`:

- **Cached file** (`recheck_cached`): the local data is re-hashed chunk by chunk (the local file is the source of truth, so a file modified behind the daemon's back is detected). Each chunk is verified on the primary backend with a HEAD — existence *and* size, since chunk keys are content-addressed a size mismatch means a corrupt object — and re-uploaded (overwritten) from local data when wrong. The remote manifest is then compared on `h1`/`h2`/`size` and republished when missing, dirty or different. When the re-hash disagrees with the sidecar, the sidecar is rewritten (`local_stale`).
- **Evicted file** (`recheck_evicted`): chunks are HEAD+size-verified from the sidecar manifest; without local data a bad chunk is **unrepairable** and reported. A missing/bad remote manifest is republished from the sidecar, but only when every chunk checks out — never over missing chunks.

Chunk checks run concurrently (bounded by `maxUploads`, reusing the upload buffer pool for the cached path); files are sequential. Repairs write to every backend (`put_all`), verification reads the primary only — the same split uploads use. No journal entries are written: content and keys are unchanged, other clients need no notification. The CLI prints one line per file (`ok` / `FIXED …` / `BAD …` / `SKIP …`) plus a summary, and exits non-zero when anything was unrepairable.

### `tsync resync-remote` — sync one backend from another

`Mirror.Make(C).resync ?source ()` brings every other configured backend up to date with the source backend (default: the primary; `--source NAME` selects another by its configured name). It lists everything the daemon writes — `<prefix>/<domain>/` (manifests, directory markers), `.chunks/`, `.journal/<domain>/`, `.versions/<domain>/` and the cursor key — and copies each object that is missing on a destination or has a different size there. The chunk store is shared across domains on the same bucket; mirroring all of it is deliberate (chunks are content-addressed, extra copies only help other domains).

It is **additive only**: objects deleted on the source are not deleted on the destinations. Deletes normally fan out to all backends; resync exists for a backend that was down, drifted, or was added to the config later. Copies run concurrently, bounded by `maxUploads`. The CLI prints each copied key and a per-destination summary (`aws -> nas: 12 objects checked, 3 copied (25165824 bytes)`).

### `tsync import` / `tsync export` — folder in, folder out

`Import.Make(C).run ~src` seeds a domain from an existing folder. For every file under `src` (recursively, sorted): upload it with the normal chunked path (`Remote.upload` — hashed, deduplicated, manifest published to all backends), then write the manifest sidecar in the local cache. No local data file is created — imported files read as not cached and are fetched from the backend on demand, which avoids assuming the local filesystem supports symlinks (required for some FS-backed backends). Directories are created in the manifest tree and as backend markers. A key already in the domain (local sidecar or remote manifest) is never overwritten — it is reported as skipped. All resulting ops (`mkdir` + `put`) are published as a **single journal entry**, so other clients pick the import up incrementally; batching also avoids the ms-timestamped entry-key collision that per-file entries would risk. The optional `~exclude` parameter takes a list of shell glob patterns (via `tsync_glob`, backed by `path_glob`); an entry is excluded if any pattern matches either its relative path or its basename, so `*.tmp` prunes any such file anywhere in the tree and `node_modules` prunes any directory of that name along with its contents.

`Export.Make(C).run ~dst` writes every file of the domain to a plain folder, reading manifests directly (no daemon needed). The file set is the union of the backend listing and the local sidecar tree (the latter adds local-only files whose upload is still pending). Per file: if the local cache holds the data (including dirty, not-yet-uploaded content) it is copied from there; otherwise the file is recomposed from remote chunks via `Remote.download_chunks` **straight to the destination — the local cache is deliberately not populated**. mtimes are preserved (cache stat, or the manifest's mtime). A dirty sidecar with no local data, or a key that vanished remotely, is reported as `MISSING` and the CLI exits non-zero.

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
| `local_io/local_io.ml` | Local file read/write: path-based (open/close per call) for occasional callers, and positioned `pread`/`pwrite` for callers holding their own long-lived fd (see FUSE's `Fd_cache`) |
| `local_io/fs_util.ml` | Shared Lwt filesystem helpers (`mkdir_p`, `rm_rf`, `readdir_list`, …) |
| `metrics/metrics.ml` | Transfer and hashing counters (totals + rolling rate) for `tsync stats` |
| `log/` | Logging backends (printf for development, syslog for production) |
| `file/manifest.ml` | Manifest JSON serialization/deserialization; chunk key derivation |
| `file/local.ml` | Local cache paths; create/evict/rename local cache entries |
| `file/remote.ml` | Chunked upload and download against the backend. Upload opens the source file once, reads chunks concurrently through a `maxUploads`-sized buffer pool, hashes and stores each, then writes the manifest |
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
tsync sync    [--domain <name>] [--full]
tsync recheck [--domain <name>]
tsync resync-remote [--domain <name>] [--source <backend-name>]
tsync import  <dir> [--domain <name>]
tsync export  <dir> [--domain <name>]

tsync versions [path]
tsync revert   <path> [--version <ts>]
tsync expire   <date>

tsync auto-evict [on|off|status]
tsync purge   <path>
```

`tsync configure` writes the config file interactively. It prompts for versioning, upload/download concurrency, and (when both TLS backends are built and an S3 backend is used) the TLS backend, then loops over domains (name, prefix, backends) — each backend gets a name (required, defaults to its type) and can be marked as the primary. On macOS it writes to the group container so both the daemon and extension can read it; on Linux it writes to the XDG config dir with mode `0600`.

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
RESYNC
```

`RESYNC` (no key) is sent by the daemon's `full_resync` hook. The extension responds with `NSFileProviderManager.reimportItems(below: .rootContainer)`, forcing the OS to re-scan the whole tree — this is how a full re-sync picks up changes made directly in the bucket, which write no journal entry.

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
| `tests/recheck/` | `recheck.ml` — `tsync recheck` scenarios: backend damage injected behind the daemon's back (missing/corrupt chunk, missing manifest, stale local data, dirty skip, evicted files), then `Recheck` prints per-file status lines and the snapshot shows the repaired (or unrepairable) bucket state |
| `tests/resync/` | `resync.ml` — `tsync resync-remote` scenarios: damage injected on the secondary backend (`OnSecondary …`), then `ResyncRemote` copies missing/size-mismatched objects from the primary; snapshots show both buckets |
| `tests/import_export/` | `import_export.ml` — `tsync import`/`tsync export` scenarios: seeding a domain from a folder (symlinked cache, batched journal entry, dedup against existing chunks, existing keys skipped) and exporting cached/evicted/dirty files (evicted files recomposed from chunks without repopulating the cache); snapshots include the exported tree's bytes |
| `tests/hash/` | `hash.ml` — unit test: the whole-file chunk hasher (`Xxhash.hash_file_chunks`) agrees with the single-string hash per chunk across boundary/partial/empty cases (pins chunk-key stability), and a cancelled state returns `None` |
| `tests/upload/` | `upload.ml` — end-to-end multi-chunk `Remote.upload` on a local backend: 3-chunk round-trip, dedup, concurrent identical-chunk writes, and a 0-byte file |

A scenario is a `name` and a list of `step`s. Every scenario runs with two local backends (writes fan out to both, as in a mirrored config); the secondary's bucket is dumped only for scenarios that use it. To add a suite, create a sibling directory under `tests/` with a scenario file that does `open Test_runner`, its own `.expected` snapshot, and the three dune stanzas from `tests/base/dune` (executable, `with-stdout-to` output rule, `runtest` diff rule).

| Step | Description |
|------|-------------|
| `Write` | Write a file through IPC (normal upload path) |
| `Mkdir` / `Rmdir` | Create / remove a directory |
| `Rename` | Rename a file or directory |
| `Delete` | Delete a file |
| `Evict` | Drop the local cached data, keeping the sidecar |
| `Restore` | Pull the cached data back down |
| `Open` / `Close` | Mark a file as open/closed (FUSE open-file guard) |
| `DirtyWrite` | Write local data without uploading (simulates FUSE write-then-close) |
| `ModifyCache` | Tamper with cached data behind the daemon's back |
| `Drain` | Wait for all queued uploads to finish; also advances the ms clock so journal entry keys stay deterministic |
| `Sync` | Run `Sync_poller.sync_once`: consume foreign journal entries |
| `Mark` / `Expire` | Record a time boundary, then prune versions older than it |
| `RevertVersion` | Restore a saved version to the live path |
| `DeleteRemoteChunk` | Remove a chunk from the primary backend (simulates corruption) |
| `CorruptRemoteChunk` | Overwrite a chunk with garbage |
| `DeleteRemoteManifest` | Remove a file's manifest object |
| `OnSecondary` | Apply a backend-damage step to the secondary backend instead |
| `Recheck` | Run `Recheck.run` over the whole domain and print per-file status |
| `ResyncRemote` | Copy missing/damaged objects from primary to other backends |
| `ImportDir` | Seed the domain from a temp folder (upload, symlink into cache, batch journal entry) |
| `ImportDirExclude` | Like `ImportDir` but with `--exclude` glob patterns |
| `ExportDir` | Write the whole domain to a temp folder |

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
| `fd_cache.ml` | `Fd_cache.Make(F)` — one cached fd per open file, refcounted across concurrent opens of the same key, released on last close. Backs `read`/`write` with positioned `pread`/`pwrite` instead of an open/seek/close per FUSE call |

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

- **open**: triggers `File.ensure_cached` on first access of an evicted file — downloads from backend synchronously — then `Fd_cache.acquire` opens (or, if another handle on the same key is already open, reuses) the cache file's fd for the FUSE handle's lifetime.
- **getattr / readdir**: served from the local manifest cache; `getattr` on a file with no local sidecar (never cached, or just after a full resync) falls back to fetching the backend manifest so it reports the real logical size rather than ENOENT.
- **read / write**: go straight to the cached fd via positioned `pread`/`pwrite`, run under `Async_none` (see `local_io.ml`) since the fd is always one of our own recently-touched cache files and essentially always page-cache-resident — this skips Lwt's worker-thread dispatch entirely for what would otherwise be a guaranteed-fast call.
- **release** (last close): `Fd_cache.release` drops the reference, closing the fd once nothing else holds it open. If the file was written, posts a `Put` event to `Sync_queue`. The upload runs asynchronously on a Sync_queue worker; the FUSE operation returns immediately.
- **unlink / mkdir / rmdir / rename**: synchronous backend operations with journal write-ahead. `rename` handles both file and directory cases by detecting trailing `/` in the key.
- **readlink / symlink**: served from the manifest's `symlink` field. `symlink` (`ln -s` on the mount) stores a symlink manifest via `File.symlink`; rejected with `EPERM` unless the domain policy is `keep` (see [Symlinks](#config)).

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
  │    ├── createItem         file: write+upload; dir: mkdir; symlink: symlink IPC action
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

**Change tracking only sees journaled changes.** Cross-client propagation (and the macOS `enumerateChanges` feed) is driven by the change journal, so a change made directly in the bucket — outside any tsync client — writes no journal entry and is not picked up incrementally. It surfaces only on a full re-import (re-adding the domain) or `tsync sync --full`, which invokes `full_resync` — wiping the FUSE cache or driving `reimportItems` on macOS. This matches the sync poller's existing model.

**Chunks are not encrypted at the application layer.** Enable S3 SSE-S3 or SSE-KMS on the bucket for encryption at rest.

**Linux: single metadata lock.** FUSE runs `Multi_threaded` and bridges to the Lwt loop via `run_in_main`, so reads, downloads, and uploads proceed concurrently. Metadata mutations (delete/mkdir/rmdir/rename/revert) are serialized through one global `Lwt_mutex`; switching to per-key locks would only matter under heavy concurrent metadata churn.

**macOS: extension consent required.** macOS requires one-time user consent in System Settings → General → Login Items & Extensions → File Provider Extensions before the extension activates and the CloudStorage mount appears.

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE).
