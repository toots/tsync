# tsync

S3-backed file sync with transparent on-demand download. Files live in a local directory backed by S3 — opening an evicted file downloads it transparently; only the files you actually use take local space.

| Platform | Implementation | Mount |
|---|---|---|
| [macOS](macos/) | FileProvider (NSFileProviderReplicatedExtension) | `~/Library/CloudStorage/TsyncApp-<domain>/` |
| [Linux](linux/) | FUSE (ocamlfuse) | `~/tsync/<domain>/` |

Both platforms share the same S3 key layout, chunk format, and config schema — a single bucket serves both.

## S3 key layout

```
<prefix>/<domain>/<path>                        # small files (≤ 8 MB) — raw bytes
<prefix>/<domain>/<path>                        # large files (> 8 MB) — manifest JSON
<prefix>/<domain>/<dir>/                        # empty directory marker
<prefix>/.chunks/<sha256hex>-<md5hex>           # content-addressable chunks
<prefix>/.trash/<domain>/<path>/<timestamp>     # versioned deletes
<prefix>/.journal/<domain>/<13-digit-ms>-<uuid> # change journal entries
<prefix>/.version/<domain>                      # latest journal entry key; bumped on every mutation
```

## Chunked uploads

Files larger than 8 MB are split into 8 MB chunks, each stored at `<prefix>/.chunks/<sha256hex>-<md5hex>`. The primary S3 key holds a small JSON manifest (`Content-Type: application/x-tsync-manifest+json`). On re-upload, only changed chunks are uploaded. Chunks are shared across all files and versions.

## Change journal

Every mutation is recorded in a shared S3 change journal. This enables crash recovery (intent written before action) and cross-client sync.

Journal keys (`<prefix>/.journal/<domain>/<13-digit-ms>-<uuid>`) are lexicographically sortable by time; `start_after=<last-sync-key>` in ListObjectsV2 gives "changes since last sync" without any additional index. A 60-day S3 lifecycle rule on `<prefix>/.journal/` keeps the journal from growing unbounded.

The `.version/<domain>` file holds the latest journal entry key and is updated atomically with each journal write. Clients poll it (e.g. once per second) to detect remote changes without scanning the full journal.

### Automatic sync

Each client runs a background poller that fetches `.version/<domain>` once per second. When the value changes, the client knows a remote mutation has occurred and triggers a sync to bring its local filesystem up to date. The poller itself is lightweight — a single small GET per second per domain, with no journal reads unless a change is detected.

### Entry format (NDJSON)

One S3 object per change event; one JSON line per operation. Rename emits one line with both `src` and `key`:

```json
{"op":"put","key":"foo.wav","size":12345678}
{"op":"delete","key":"bar.wav"}
{"op":"mkdir","key":"subdir/"}
{"op":"rmdir","key":"subdir/"}
{"op":"rename","src":"old.wav","key":"new.wav","size":12345678}
```

`key` and `src` are domain-relative (no S3 domain prefix, no leading `/`). Unknown `op` values are silently skipped for forward compatibility.

### `tsync sync`

Brings the local filesystem in sync with S3, applying all remote changes since the last sync — file content updates, renames, deletes, creations, and directory creation, rename, and deletion. Changes written by the local client are filtered out.

1. Read `last_sync_key` from local state. Empty = never synced → full resync.
2. List journal from the beginning (limit 1) to get `oldest_entry_key`.
3. If `oldest_entry_timestamp > last_sync_timestamp` → **full resync** (journal gap; missed changes).
4. Otherwise → **incremental**: list journal entries after `last_sync_key`, filter out own `client_uuid`, apply all changes.

**Full resync** brings the entire local filesystem in sync with S3 from scratch. Triggered automatically when the journal does not cover the gap since the last sync.

## Known limitations

**No chunk GC.** Chunks accumulate in `<prefix>/.chunks/` indefinitely. A future `tsync gc` would collect unreferenced chunks.

**No concurrent write safety.** Last manifest write wins. Correct fix: S3 conditional PUT with a retry loop.

**No background prefetch.** Files download on first open, or in bulk via `tsync pull`.

**Chunks are not encrypted.** Enable S3 SSE-S3 or SSE-KMS on the bucket for encryption at rest.

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE).
