# Bodies, mapping and memory — OCaml implementation notes

Learnings from the OCaml 5 rewrite (branch `rewrite`), measured on a copy of a real domain: 305,754
store objects, 258,440 file manifests, 1.2 GB of manifests. Not normative: the spec only asks that
bodies move as off-heap buffers ([01 §10](../01-core.md#10-http-request-discipline)), that data
which may change under a reader is never mapped ([01 §12](../01-core.md#12-reading-data-that-may-change-under-the-reader)),
and that each process reports its memory ([07 §5.5](../07-daemon-cli.md#55-tsync-status)).

## M.1 Bodies are bigstrings, end to end

- `Tsync_core.Bigstring.t` (a `char` `Bigarray.Array1`) is the type of every data body: store
  contract, HTTP client and server, cache and staged reads and writes, the file operations, FUSE
  buffers, ZIP members. A `string` body is copied at every hop and lives on the OCaml heap, where the
  collector scans and moves it; a bigstring is allocated once, outside the heap.
- Small metadata (manifests, folder markers, anchors, journal entries, cursors, JSON) stays a
  `string`, converted where it leaves the store. `Manifest.of_body` checks the magic on the
  bigstring and converts only a real manifest: the composite asks `chunk_names` of every body it
  copies, chunks included, and converting those would copy every chunk to the heap.
- Views, not copies: `Bigstring.sub` shares memory. A FUSE write hands the kernel's buffer to the
  file operations as a view (the worker waits for the scheduler, so the buffer outlives the call);
  a read blits into the kernel's buffer with `Bigarray.Array1.blit`. Bulk frames decode into views
  of the answer.
- Copies to and from `bytes`, and comparison, are one C call each (`memcpy`, `memcmp` in
  `sys_stubs.c`), not a loop over characters.
- Sockets read and write bigstrings directly: `Unix.read_bigarray` / `single_write_bigarray`
  (OCaml ≥ 5.2), `Ssl.read_into_bigarray` / `write_bigarray`. ocaml-tls works on strings, so the
  native TLS path copies once per record; OpenSSL does not.

## M.2 mmap: only data that cannot change under the mapping

- The local store maps the objects it reads (`Fs.map_fd`): they are replaced by rename and never
  modified in place, so a mapping stays valid even if the file is deleted, and a range read is a
  view of the mapping with no read at all.
- A store root on a network filesystem is read with positioned reads instead
  (`Fs.read_fd_bigstring`), decided once per store by `statfs`: an NFS or SMB server can fault a
  mapped page (`SIGBUS`), which a positioned read turns into an error.
- Never mapped: user files (import, rsync sources), live staged bodies (they change size under a
  reader), cache bodies read per kernel request (one `mmap` per 128 KiB read costs more than the
  `pread` it saves; the page cache serves both).
- Measured: a full rebuild reading 258k manifests through mappings kept file-backed resident memory
  at 3–4 MiB throughout. Mappings of small objects are released as the collector finalizes their
  bigarrays, and their pages are the kernel's to reclaim; the owner held about 800 mappings, far
  from `vm.max_map_count`.

## M.3 Measuring: what each number means

`Tsync_core.Usage.sample` is what every process reports in its `stats` process block, and what
`tests/bench/rebuild_mem` samples:

| Field | Source | Meaning |
|---|---|---|
| `privateBytes` | `mem_usage` | resident memory no other process shares: the figure that matters |
| `anonymousBytes` | Linux `RssAnon`, macOS `task_vm_info.internal` | live allocations: the OCaml heap plus malloc'd memory (bigstrings, C stubs, runtime) |
| `fileBackedBytes` | Linux `RssFile`, macOS `task_vm_info.external` | mapped files the kernel pages in; reclaimable, not the process's to free |
| `heapBytes`, `topHeapBytes` | `Gc.quick_stat` | the OCaml major heap now and at its largest; cheap, never walks the heap |

`anonymous − heap` is memory outside the OCaml heap. A high `topHeapBytes` with many major
collections and little retained heap is a garbage storm, not a leak.

## M.4 Rebuild findings (258,440 manifests)

| Change | Peak private | After compaction | Heap after compaction | Time |
|---|---|---|---|---|
| unbounded prefetch in `fold_tree` (as first written) | ≈ 1.8 GB (rehearsal owner) | — | — | ≈ 4 min |
| bounded lookahead | 887 MiB | 690 MiB | 81 MiB | 206 s |
| + one-pass batching of the rebuild's diffs | 667 MiB | 528 MiB | 80 MiB | 174 s |
| + `MALLOC_ARENA_MAX=2` | 522 MiB | 325 MiB | 80 MiB | 172 s |
| default allocator, `malloc_trim` after compaction | 765 MiB | 155 MiB | 81 MiB | 172 s |

- **Prefetch must be bounded by position, not by concurrency.** A semaphore bounded the fetches in
  flight, but not the finished listings waiting to be visited; on a wide tree every listing, with
  its manifest bodies, waited in memory. The walk now keeps an explicit stack and fetches only the
  next `width` folders in visit order.
- **No `List.filteri` batching.** Splitting a 258k-element list into batches of 64 by filtering the
  remainder for each batch was quadratic; its garbage drove the heap past 1.6 GB and 700 major
  collections. Batch in one pass.
- **Freed memory stays with glibc until trimmed.** With the heap back to 80 MiB, 450 MiB of
  anonymous memory stayed resident under the default allocator, 245 MiB with two arenas: freed
  blocks held in per-thread arenas (OCaml 5 mallocs large blocks individually, and the scheduler
  runs on several domains). `malloc_trim(0)` after compaction returned 564 MiB at once, leaving
  155 MiB private for an 81 MiB heap: retention, not live data. A rebuild ends with `Gc.compact`
  and `Usage.trim` (`malloc_trim` on Linux, `malloc_zone_pressure_relief` on macOS), and the owner
  trims at every housekeeping pass.
- Peaks vary by about 100 MiB between identical runs with scheduling; compare retained figures.
