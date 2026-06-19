# tsync

S3-backed file sync for macOS using the [FileProvider](https://developer.apple.com/documentation/fileprovider) framework. Files live at `~/Library/CloudStorage/TsyncApp-<domain>/` — the same model as iCloud Drive and Dropbox Smart Sync. Opening an evicted (placeholder) file shows a native progress indicator and downloads transparently; no 0-byte surprises.

## Architecture

| Component | Role |
|---|---|
| `TsyncApp` | Host app; runs as a background LaunchAgent; registers FileProvider domains |
| `TsyncFileProvider` | NSFileProviderReplicatedExtension; maps S3 objects to filesystem items |
| `tsync` (CLI) | Manages domains, eviction, restore, versioning history |
| `Shared/` | Config, S3 client, Keychain credentials, versioning logic |

S3 key layout:
```
<prefix>/<domain>/<path>                        # small files (≤ 8 MB) — raw bytes
<prefix>/<domain>/<path>                        # large files (> 8 MB) — manifest JSON
<prefix>/<domain>/<dir>/                        # empty directory marker (zero-byte, Content-Type: application/x-directory)
<prefix>/.chunks/<sha256hex>-<md5hex>           # content-addressable chunks, dual-hash keyed
<prefix>/.trash/<domain>/<path>/<timestamp>     # versioned deletes
```

## Chunked uploads

Files larger than 8 MB are split into 8 MB chunks, each stored at `<prefix>/.chunks/<sha256hex>-<md5hex>`. The dual-hash key makes collisions negligible while keeping the namespace flat — renames and moves never require re-uploading chunks. The primary S3 key holds a small JSON manifest (`Content-Type: application/x-tsync-manifest+json`):

```json
{
  "v": 1,
  "size": 912465400,
  "chunkSize": 8388608,
  "chunks": [
    {"index": 0, "sha256": "13cde1e8...", "md5": "d41d8cd9...", "size": 8388608},
    ...
  ]
}
```

On re-upload, tsync computes the SHA-256 of every chunk, HEADs all chunk keys concurrently to find which already exist in S3, and uploads only the changed chunks. For a single-byte edit to an 870 MB file this means ~8 MB over the wire instead of ~870 MB. Chunks are shared across all files and versions — if two files share a region, they share the chunk.

Uploads and downloads both run up to 8 chunks in parallel. Each parallel task opens its own file handle and seeks to the correct byte offset, keeping peak memory around 64 MB regardless of file size.

## Requirements

- macOS 13+
- Xcode 15+ (for building the app extension)
- An AWS account with an S3 bucket
- A free Apple Developer account (for `com.apple.developer.fileprovider.disk` entitlement)

## Setup

### 1. Generate the Xcode project

```bash
brew install xcodegen   # if not installed
xcodegen generate
```

### 2. Sign

In Xcode, set your Apple Developer team under *Signing & Capabilities* for both `TsyncApp` and `TsyncFileProvider` targets. `CODE_SIGN_STYLE=Automatic` (used by the build scripts) then manages provisioning automatically. This is required so the extension shares the same signing identity as the stored Keychain credentials — a mismatch causes the extension to fail silently at startup.

### 3. Configure

Run the interactive setup script — it writes `config.json` to the app group container and stores AWS credentials in the Keychain:

```bash
./configure.sh
```

Config is written to `~/Library/Group Containers/group.com.toots.tsync/config.json`. AWS credentials are stored in the macOS Keychain so the sandboxed extension can read them at runtime.

### 4. Enable the extension

macOS requires explicit user consent before activating a FileProvider extension. This is a one-time step per machine:

1. Open **System Settings → General → Login Items & Extensions**
2. Click **File Provider Extensions** (or **Extensions** → **File Providers**)
3. Enable **TsyncFileProvider**

Without this step the extension process is never launched and the CloudStorage mount does not appear, even if the app is running and domains are registered.

### 5. Build and start

```bash
./deploy.sh
```

This builds a Release binary, installs it to `/Applications/TsyncApp.app` (required — macOS's FileProvider daemon only loads extensions from `/Applications/`), registers the extension with `pluginkit`, and starts the LaunchAgent. It waits until the IPC socket is up before returning.

Open Finder — `~/Library/CloudStorage/TsyncApp-MusicProduction/` appears. Drop files in; they upload to S3 automatically.

For subsequent deploys after code changes, run `./deploy.sh` again.

## CLI Reference

```
tsync start      # launchctl load the LaunchAgent
tsync stop       # launchctl unload
tsync status     # daemon status + registered domains

tsync evict   <path>          # free local space (file becomes a placeholder/cloud icon)
tsync restore <path>          # trigger download of a single placeholder
tsync pull    [path]          # download all evicted files in a directory (bulk restore)
tsync pull    [path] --force  # re-download all files, even those already local
tsync wait    <path>          # block until file is fully local (useful in scripts)
tsync ls      [path]          # list files with upload (uploaded/uploading/pending) and download (local/cloud) status

tsync history <path>   # list versioned copies in .trash/
tsync purge   <path>   # delete all versions for a file from .trash/
```

## Versioning

When `versioning = true` in config.json, deleting a file copies it to the trash prefix before deletion. Restore a specific version by downloading the trash key directly with the AWS CLI or `tsync restore`.

## AWS Credentials

`tsync init` reads credentials interactively and stores them in the macOS Keychain. The extension reads from Keychain at runtime — `~/.aws/credentials` is not accessible from the sandboxed extension process.

To rotate credentials: run `tsync init` again.

## Known limitations

**No chunk GC.** Chunks accumulate in `<prefix>/.chunks/` indefinitely as files are modified or deleted. A future `tsync gc` command would enumerate all active manifests, collect the referenced SHA-256 set, and delete any chunk not referenced by any live or trashed manifest.

**No concurrent write safety.** If two clients write the same file simultaneously, the last manifest write wins and may reference chunks the other client never finished uploading. For a personal library this is unlikely to matter. The correct fix is S3 conditional PUT (`If-Match` on the manifest key) with a retry loop.

**No background prefetch.** Files appear as placeholders after eviction or on a new machine. They download transparently on first open, or in bulk via `tsync pull`. There is no proactive prefetch.

**Chunks are not encrypted.** Data is encrypted in transit (HTTPS) and at rest if the S3 bucket has SSE enabled, but chunks are stored as raw bytes with no client-side encryption. Enable S3 SSE-S3 or SSE-KMS on the bucket for encryption at rest.

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE).
