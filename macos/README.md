# tsync

S3-backed file sync for macOS using the [FileProvider](https://developer.apple.com/documentation/fileprovider) framework. Files live at `~/Library/CloudStorage/TsyncApp-<domain>/` — the same model as iCloud Drive and Dropbox Smart Sync. Opening an evicted (placeholder) file shows a native progress indicator and downloads transparently; no 0-byte surprises.

## Architecture

| Component | Role |
|---|---|
| `TsyncApp` | Host app; runs as a background LaunchAgent; registers FileProvider domains; polls `.version/<domain>` and signals FileProvider on remote changes |
| `TsyncFileProvider` | NSFileProviderReplicatedExtension; maps S3 objects to filesystem items |
| `tsync` (CLI) | Manages domains, eviction, restore, versioning history |
| `Shared/` | Config, S3 client, Keychain credentials, versioning logic |

See [../README.md](../README.md) for the shared S3 key layout and chunk format.

## Chunked uploads

See [../README.md](../README.md) for the shared chunk format. macOS-specific: uploads and downloads run up to 8 chunks in parallel, keeping peak memory around 64 MB regardless of file size.

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

## Build targets

```
make generate       # regenerate tsync.xcodeproj from project.yml
make build          # build TsyncApp + tsync CLI (Release)
make test           # run Journal unit tests
make deploy         # build, install to /Applications, restart daemon
make configure      # interactive S3 / credentials setup
make test-lifecycle # build, install, start daemon, run integration tests against a real S3 bucket
```

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

tsync sync    [--domain <name>]   # apply remote changes locally; also recovers from crashes

tsync history <path>   # list versioned copies in .trash/
tsync purge   <path>   # delete all versions for a file from .trash/
```

## Automatic sync

`TsyncApp` polls `<prefix>/.version/<domain>` once per second. When the value changes (a remote client wrote a new file), it calls `NSFileProviderManager.signalEnumerator(for: .workingSet)` on all domains, causing the FileProvider extension to re-enumerate from S3 and apply the changes transparently.

Run `tsync sync` manually to apply incremental changes with eviction of stale local content and crash recovery (see below).

## Crash recovery

Before each S3 mutation, the extension writes a pending journal entry to `~/Library/Group Containers/group.com.toots.tsync/journal-pending/`. On successful completion the entry is deleted. Entries that survive a crash are replayed by `tsync sync`: operations not remotely modified by another client since the crash are re-executed and the local pending file is cleaned up.

## Versioning

When `versioning = true` in config.json, deleting a file copies it to the trash prefix before deletion. Restore a specific version by downloading the trash key directly with the AWS CLI or `tsync restore`.

## AWS Credentials

`tsync init` reads credentials interactively and stores them in the macOS Keychain. The extension reads from Keychain at runtime — `~/.aws/credentials` is not accessible from the sandboxed extension process.

To rotate credentials: run `tsync init` again.

## Known limitations

See [../README.md](../README.md) for limitations shared with Linux (chunk GC, concurrent writes, prefetch, encryption). macOS-specific:

**Extension consent required.** macOS requires one-time user consent in System Settings before the FileProvider extension activates. Without it the CloudStorage mount never appears.

**Keychain dependency.** AWS credentials are stored in the macOS Keychain. The sandboxed extension cannot read `~/.aws/credentials`.

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE).
