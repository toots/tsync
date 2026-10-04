# Tuning


All of this is optional.

## Chunk size

`chunkSize` (8 MiB by default, 256 KiB to 256 MiB) is the unit of upload, download and deduplication.

- **Smaller:** an edit re-uploads less. A read takes more requests.
- **Larger:** reads are fewer, bigger requests, which suits streaming. An edit re-uploads more.

Choose small for data edited in place, such as disk images and databases, and large for media written once and streamed.

Changing it affects new files only. Each file records the size it was written with.

## Cache

`maxCache` caps the disk the cache uses. Past it, the content read longest ago is dropped, in pieces, so a large file keeps the parts you are reading. Nothing is unlisted, and a dropped part is fetched again on the next read. Files kept offline and edits not yet uploaded are not counted and never dropped. Without `maxCache`, nothing is ever dropped.

`cacheChunkSize` (16 MiB by default) is how much is fetched and stored together. Reading one byte fetches the whole piece around it.

- **Larger:** better throughput for sequential reading, coarser cache.
- **Smaller:** less to fetch before the first byte.

Keep it a small multiple of `chunkSize`.

## Concurrency

| Setting | Default | Bounds |
|---|---|---|
| `maxUploads` | 4 | Files uploading at once |
| `maxChunkBuffers` | `maxUploads` | Chunks held in memory at once. Memory use is about this times the chunk size. |
| `maxDownloads` | 8 | Files downloading at once |

On a machine short of memory, lower `maxChunkBuffers` rather than `maxUploads`.

## Uplink

tsync paces its uploads so that they do not swamp your connection. While it uploads, it times a small request to each remote store. When that takes longer than usual, a queue is building in your modem, which is what makes everything else on the connection feel slow. So tsync slows down, and it speeds up again while the delay stays flat.

`tsync status` shows the result under `Uplinks`: the rate, the capacity measured and the delay.

```json
"uplink": { "maxRate": "2 MB" }
```

| Key | Default | Meaning |
|---|---|---|
| `enabled` | `true` | `false` sends as fast as the concurrency settings allow |
| `maxRate` | none | A ceiling in bytes per second, whatever the link could carry |
| `minRate` | 64 KiB | A floor, however badly the link is doing |
| `headroom` | `0.8` | The share of the measured capacity to use |
| `targetDelayMs` | `50` | The extra delay that counts as congestion |

**Links.** Every remote backend is on a link, `wan` unless it says otherwise, and backends on the same link are paced together. A NAS on your local network should not be slowed by your modem, so give it a link of its own:

```json
{ "type": "http-proxy", "name": "nas", "role": "main", "link": "lan",
  "url": "https://nas.lan:8443", "secret": "…" }
```

`links` overrides the `uplink` settings for one link, naming only what differs:

```json
"links": { "wan": { "maxRate": "500 KB" } }
```

Limits hold for the whole machine: the service and any `import` or `mirror` you run share each link.

