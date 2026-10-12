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

## Advanced settings

These keys have defaults that suit a normal setup. `tsync config --edit` does not ask about them;
`tsync config --edit --advanced` does, and the answer `-` removes one so that its default applies
again. A config that leaves them all out is complete.

Per domain, shared by every machine of the domain:

| Key | Default | Meaning |
|---|---|---|
| `chunkSize` | 8 MiB | How new files are cut |
| `symlinks` | `keep` | What is done with symlinks |
| `maxEntryCommands` | 256 | Most changes committed in one step. A machine may set less than the server, not more |
| `projectLease` | 30 | Seconds a machine writes a committed step to the store's tree between two checks |
| `projectQuarantine` | 300 | Seconds a machine waits before finishing a step another machine left |
| `projectSettle` | 600 | Seconds a step may wait before another machine takes it over |

When a machine reaches its storage through another machine running tsync, that server states its
values and the machine uses them for every key it leaves out. A machine configured with a
different value stops syncing the domain and says which values disagree. Machines that share an
object store directly are not told: set them alike.

Per machine:

| Key | Default | Meaning |
|---|---|---|
| `batchDelay` | 10 | Seconds a domain gathers changes before committing them |
| `projectWidth` | 8 | Writes to the store's tree in flight at once, per domain |
| `cacheChunkSize` | 16 MiB | The unit of the local cache, per domain |
| `maxChunkBuffers` | `maxUploads` | Chunk bodies held in memory |
| a backend's `link`; `headroom`, `targetDelayMs`, `minRate`, `maxRate` of the uplink or of a link | | See [uplink](#uplink) |

On a server, per domain, in the options of its `http-proxy` frontend:

| Key | Default | Meaning |
|---|---|---|
| `projectCommits` | `true` | The server writes each change committed through it to the store's tree itself. Machines behind it then never do, however slow their link. `false` leaves that to the machine that made the change |
| `maxEntryCommands` | 4096 with `projectCommits` | Most changes a machine behind this server commits in one step |

The three timings must satisfy lease < quarantine < settle. `tsync status` shows the ones that are
not the default, and says when a value comes from the server.
