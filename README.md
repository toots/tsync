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
```

## Chunked uploads

Files larger than 8 MB are split into 8 MB chunks, each stored at `<prefix>/.chunks/<sha256hex>-<md5hex>`. The primary S3 key holds a small JSON manifest (`Content-Type: application/x-tsync-manifest+json`). On re-upload, only changed chunks are uploaded. Chunks are shared across all files and versions.

## Known limitations

**No chunk GC.** Chunks accumulate in `<prefix>/.chunks/` indefinitely. A future `tsync gc` would collect unreferenced chunks.

**No concurrent write safety.** Last manifest write wins. Correct fix: S3 conditional PUT with a retry loop.

**No background prefetch.** Files download on first open, or in bulk via `tsync pull`.

**Chunks are not encrypted.** Enable S3 SSE-S3 or SSE-KMS on the bucket for encryption at rest.

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE).
