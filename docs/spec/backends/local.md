# Backend driver: `local` (a directory on this machine, or a mounted network filesystem)

How the `local` driver realises [the store contract](../06-backends.md) over a POSIX filesystem, and what it relies on from the filesystem.

Implementation notes: [../ocaml/backends/local.md](../ocaml/backends/local.md).

---

## 1. Role

- The only driver with a `local_path`: the store is a tree, and in-process code may treat it as one (collection by rename, disk-space reports). That grant is what makes it the only store a collection can run on ([algorithms/gc.md](../algorithms/gc.md)).
- It hosts the collection's **reference gate** and the lock file's host-level locks for the main it serves (§6).
- The only driver with `fast_read = true`: reading a whole cache chunk costs about what a range does.
- Linkless: no `link` field, no admission, not counted, not probed by the uplink governor.
- It has a [breaker cell (01 §8)](../01-core.md#8-health-breaker), fed only by link-kind failures (§10). A local disk never trips it. A network mount that stops answering does, so reads fail over to a replica.
- No retry ladder of its own. Every call is one attempt, and the kind it fails with is for the caller.

## 2. Configuration

The backend object's generic fields are in [05 §2.1](../05-ops-config.md#21-schema-and-validation). Driver fields:

| Field | Type | Default | Meaning |
|---|---|---|---|
| `path` | string | required | The store root. It MUST be absolute, or start with `~/` (expanded to the user's home). A relative path is refused, because processes with different working directories would otherwise open different stores. The root need not exist: directories are created on the first write. |
| `verifyWrites` | bool | `true` | Read back every chunk after writing it, and file or clear its corruption marker (§9). JSON booleans and the strings `true/1/yes/on`, `false/0/no/off` (any case) are accepted; any other value MUST be refused. |
| `link` | — | — | Refused: `backend <name>: "link" names a link, and a local store has none`. |

Nothing is secret. Building a store touches no file.

## 3. Layout

- The object under key `k` is the regular file `<root>/<k>`, with `/` as the separator and no escaping. Directories exist only to hold files; they are created as needed and hold no object. No key names a directory ([06 §2.1](../06-backends.md#21-keys-and-prefixes)).
- **Confinement** is [security §5.3](../algorithms/security-model.md#53-filesystem-mapped-stores): keys are checked lexically before any system call, and resolution never follows a symbolic link at or below the root. The root itself may be reached through a symbolic link. This holds whoever supplied the key: a peer through the http-proxy, a listing of another store, a job record.
- **Temporary names** follow the one grammar of [01 §2.9](../01-core.md#29-temporary-and-reserved-local-names): every name that starts with `.tsync-tmp-` and ends with `.tmp`, file or directory, is temporary. Such names are never listed, read or reported, and are swept by age (§7). Readers SHOULD accept the pid form `.tsync-tmp-<pid>-<seq>.tmp` and a scratch directory `.tsync-tmp-scratch.tmp` at the root (meaning temporaries like any other); writers MUST NOT produce them in a store. A new temporary file uses the random form, in the directory of the target, created with exclusive create, so two writers, on one host or on two hosts sharing a mount, never share one.
- **Files that are not store objects** live beside the layout: the collection's lock files `tsync/<d>/gc-run.lock` and `tsync/<d>/gc-publish.lock` ([gc §5.4](../algorithms/gc.md#54-the-collection-interlock)), which may exist before any collection ran (the gate creates the second). Listings omit them.
- **Filesystem limit.** The key space must be prefix-free between objects and directories: keys `a` and `a/b` cannot both hold objects. A write that meets this fails REFUSED. tsync's layout never needs both.

## 4. Primitives

**Durable write** `write(path, body)`:

1. Create missing parent directories. Each directory created is made durable by fsyncing its parent.
2. Create a temporary name exclusively, write the whole body, and fsync the file.
3. Rename the temporary name onto `path`, and fsync `path`'s directory.

If any step fails, the temporary file is unlinked (best effort) and the failure is raised. If a concurrent removal of an empty parent makes step 2 or 3 fail with ENOENT, the write is retried once from step 1.

Why each fsync: the file's fsync keeps a crash from leaving the final name on an empty or torn file (rename can reach the journal before delayed allocation writes the data). The directory's fsync makes the name itself survive, so an acknowledged put, claim, copy or delete is still there after power loss (P2).

**Claim** `claim(path, body)`:

1. Stage a temporary file as in the durable write.
2. `link(temp, path)`: success → won. EEXIST → read the holder.
3. Where `link` is refused (`EPERM`, `EOPNOTSUPP`, `EMLINK`), rename without replacement (`RENAME_NOREPLACE`, `RENAME_EXCL`) where the platform offers it, with EEXIST meaning the same.
4. Where neither exists, the claim fails REFUSED. There is no fallback.
5. Unlink the temporary name, then fsync the directory.

`link` and rename-without-replacement are used, never rename, because rename replaces silently. The winner's body is complete the instant its name appears.

**Read.** A published name is only ever replaced by rename (a new inode), never written through or truncated, so the bytes of an opened file never change under a reader. A read SHOULD therefore hand out an immutable mapping of the file (P6); no snapshot is needed, since nothing truncates a store file ([01 §12](../01-core.md#12-reading-data-that-may-change-under-the-reader)). A read MAY use positioned reads into a buffer instead. Either way a read that raced a replacement returns the old body or the new, whole.

## 5. Operations

| Contract op | Realisation |
|---|---|
| `put(k, b)` | The gate (§6) for a manifest or version key; then `write(<root>/<k>, b)`; then, with `verifyWrites`, the check of §9. |
| `put_if_absent(k, b)` | `claim`. A win answers `Won`. EEXIST reads the holder: `Won` if it is byte-identical to `b` (a retransmitted link on a network filesystem can answer EEXIST to the winner), `Held(holder)` otherwise. If the holder vanished before it was read, the claim is repeated ([06 §3.3](../06-backends.md#33-put_if_absent)). |
| `get(k)` / `get_opt(k)` | Read the whole file. ENOENT → ABSENT / `none`. |
| `get_range(k, off, len)` | Read `[off, min(off + len, size))`; `off ≥ size` → empty body; ENOENT → `none`. |
| `head_opt(k)` | Status without following a symbolic link. A regular file → `{size; last_modified = mtime at full resolution; etag = none}`. ENOENT → `none`. |
| `delete(k)` | Unlink the regular file, fsync its directory, answer `true`. ENOENT → `false`. A directory is never removed through `delete`. |
| `delete_multi(ks)` | Unlink each regular file in order, then fsync each distinct parent directory once, then return. Absent keys succeed. The first failure stops the call and is raised with its kind ([06 §3.4](../06-backends.md#34-delete-and-delete_multi)). |
| `copy(src, dst)` | The gate (§6) when `dst` is a manifest or version key. `src` absent → ABSENT. Otherwise `link(src, temp)` in `dst`'s directory, `rename(temp, dst)`, fsync the directory, replacing any previous `dst`. Where a hard link is refused (`EXDEV`, `EMLINK`, `EPERM`, `EOPNOTSUPP`), read `src` and `write(dst)`. Hard links are safe because names are never written through. |
| `list_prefix(p, max)` | A walk of `<root>/<p>` that reports every regular file whose relative name is a valid key, with `{size; mtime; etag = none}`. It omits temporary names, the files of §3 that are not store objects, directories, symbolic links and other file types. It descends into directories and never follows symbolic links. ENOENT on the prefix → an empty list. Sorted by key, truncated to `max`. |
| `watch(k, last_seen)` | §8. |
| `get_many`, `list_many` | Not declared: filesystem reads are not round trips. |
| `bucket_functions` | `false`. A local copy is deleted directly, one unlink per chunk on the machine that holds it. |
| `capabilities(_)` | `{share_url = none; chunk_size = none; max_concurrency = an implementation's estimate of the device's useful concurrency, or none; verified = verifyWrites}`. |
| `fast_read` / `local_path` | `true` / the root. |

## 6. The collection's gate and locks

The driver of a collectable main hosts the interlock of [gc §5.4](../algorithms/gc.md#54-the-collection-interlock), so no writer can bypass it:

- Every `put` or `copy` whose destination is in the manifest area or the version area passes the **reference gate** before it writes: shared publish lock, promotion of the named chunks when the run record is present, a presence check of every named chunk, and a refusal naming the missing chunks ([gc §5.4](../algorithms/gc.md#54-the-collection-interlock)).
- The two lock files carry the **run lock** and the **publish lock** as host-level locks. The driver offers no exclusion across hosts beyond what the filesystem's lock manager provides (§12).

## 7. Orphaned temporary files

A crash between creating a temporary file and its rename or unlink leaves it behind. Temporary names are never listed, so they cost only space.

- Any walk of a directory by this driver MAY remove the temporary names it meets whose modification time is older than TEMP_GRACE (recommended 24 h), a temporary directory with its content.
- The domain owner's maintenance SHOULD walk each local store's domain prefix for them at least every TEMP_SWEEP_INTERVAL (recommended 7 days).
- TEMP_GRACE is measured on file times and is far longer than any write takes, so a live writer's file is never taken, whichever host it runs on.

## 8. Watch

- The watch is a directory watch ([01 §14](../01-core.md#14-directory-watch)) on the key's parent directory, never on the object: writes rename a new inode into place, so a watch on the name would follow an inode unlinked a moment later.
- A watcher whose directory was removed is dropped and reopened on the next call. A directory that cannot be watched is retried on the next call.
- **Order.** Arm the watcher first, then read the key. If its token differs from `last_seen`, return at once. Otherwise wait for an event or WATCH_INTERVAL, whichever comes first.
- On a network filesystem, notifications report only this host's changes. The watch then sleeps WATCH_INTERVAL after the read, without a notification.
- Spurious wakes are allowed.

## 9. Verified writes and corruption markers

With `verifyWrites` (the default), `put` of a key that has a corruption-marker key (a chunk under `tsync/<d>/chunks/<shard>/`; not the collection's second space, not manifests, not markers) checks what it wrote. The check sits in the driver, so it covers every way a chunk lands on this store (uploader, http-proxy peers, mirror, repair, copy forwards).

1. Read the just-written file back. Never hash the argument, which may alias a buffer its owner has reused, and would agree with itself.
2. The read fails → write the marker with `reason` and `at` ([02 §2.13](../02-remote-model.md#213-corruption-marker-verify-job-discard-job)).
3. The bytes hash to the key's leaf → if a marker exists, delete it.
4. Otherwise → write the marker with `computed`, `size` and `at`.

- A mismatch never fails the `put`: the bytes are already published, and a raised error would lose the finding. A failure to write or delete the marker fails the `put` with its kind, and the caller's repeat redoes the write and the check.
- Markers are written with the durable write and are not themselves checked.
- The order is check-then-act. The cloud side acts first because its events are at-least-once and unordered; here the writer is local and the rename already happened.
- **Strength.** The read-back usually comes from the page cache: it proves the bytes survived tsync's pipeline and the filesystem's write path, not that the medium holds them. Media decay is found by the whole-store sweep or a later read. `verified = verifyWrites`, so with checking off, "no markers" reads as "nobody looked", not "clean".

## 10. Failure kinds

Every errno is classified by [failure-model §4.1](../algorithms/failure-model.md#41-local-filesystem-errors), the same on every operation. Network-filesystem errnos (a server away) are TRANSIENT/LINK and feed the breaker cell. A failure names the operation, the key, and the system's error text.

**Bounded calls.** A blocking filesystem call that has not returned within LOCAL_STALL_TIMEOUT (recommended 60 s) fails TRANSIENT/LINK, and never holds up unrelated work while it hangs. A hung network mount thus costs the caller a bounded wait and trips the store's breaker cell.

## 11. What the driver relies on from the filesystem

- `rename` atomically replaces its target within one directory, and `link` (or rename-without-replacement) fails with EEXIST atomically. These make `put` last-writer-wins without partial reads, and `put_if_absent` a real precondition.
- An open or mapped file stays readable after its name is unlinked or replaced.
- A name renamed into place is visible to the next status or directory read on the same host.
- fsync of a file and of a directory makes data and names durable.

## 12. Network filesystems (NFS, SMB, sshfs and other FUSE mounts)

A mount is a network filesystem when the system reports it so: the filesystem type on Linux, the absence of the local-mount flag on macOS. There, the driver behaves as follows:

| Mechanism | On a network mount |
|---|---|
| Watch | Polling at WATCH_INTERVAL: other hosts' writes raise no event here. |
| Reads | Positioned reads MAY be preferred over mappings, so a vanished file or an unreachable server surfaces as the read's failure. |
| Durability | Every fsync is a server round trip. Nothing is skipped. |
| Claims | `link` where supported, then rename-without-replacement, else REFUSED. NFS: a retransmitted `link` whose first attempt succeeded can answer EEXIST, which reads back as `Won` (§5). |
| Copies | Hard links where supported, else a body copy over the wire. |
| Errors | Link-kind errnos and stalls are TRANSIENT/LINK and feed the breaker cell. |
| `max_concurrency` | None. |
| Cross-host exclusion | The collection's locks (§6) hold only as far as the filesystem's lock manager does. |

Recommended topology: one host mounts a network store and serves it to other hosts through its http-proxy frontend, rather than several hosts mounting it.

## 13. Conformance

- **Durable writes.** `put`, `put_if_absent`, `copy` and `delete` each fsync the file (where one is written) before publishing it, and the directory after. The system-call order is recorded, and the count of published files is checked so the test cannot pass vacuously.
- **Claims.** Concurrent claims on one name: exactly one `Won`, the others `Held` with the winner's body. A later claim gets the holder. A free name answers `Won` and stores the body. `delete` answers `true`, then `false`. After a delete the next claimant wins. The losers leave no temporary files.
- **Ranges.** Exact slices at the start, middle, end and whole; `[size−3, size+97)` → 3 bytes; an offset past the end → empty; an absent key → `none`. Bytes are compared, not just counted.
- **Confinement.** Keys holding `..`, `.`, empty segments or a leading `/` are refused before any file is touched. A symbolic link inside the root that points outside is never followed, for reads, writes, deletes or listings.
- **Listings.** A staged temporary file is neither listed nor deleted; a user file named `.syncthing.x.tmp` is listed; directories, symbolic links and the collection lock file are not listed; order is by key; `max_keys` is exact.
- **Delete.** A key naming a directory removes nothing. An unlink refused with `EACCES` fails `delete_multi` REFUSED.
- **Errors.** The same errno has the same kind in every operation. A simulated stalled call fails TRANSIENT/LINK within the local stall bound.
- **Gate.** A manifest put naming a chunk absent from the surviving space is refused naming it; during a run the gate promotes the named chunks.
- **Sweeping.** A temporary file older than the grace is removed by a walk; a younger one is kept.
- **Watch.** A write of the key wakes a watch within a second; a watch whose key already differs from `last_seen` returns at once; a quiet key returns at the interval; reads of the object do not wake a watch on its directory.
- **Corruption.** A good chunk files no marker and capabilities say `verified`. A scrambled body is filed under its marker key with the hash computed. A good rewrite clears the marker.
