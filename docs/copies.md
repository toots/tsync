# Keep more than one copy


A domain can have several backends. Each has a **role**:

| `role` | Written | Read | Use it for |
|---|---|---|---|
| `main` | On every write; the write waits for it | First | The source of truth. Several are allowed: all receive every write, the first one listed serves reads. |
| `replica` | Every write, in the background | When no main answers | A complete second copy that can stand in for the main. |
| `backfill` | Every write, in the background | Never | A backup that covers what you write from now on, without copying what already exists. |
| `readOnly` | Never | When the mains do not have the file, or are unreachable | An old store you are moving away from and still want to read. |

A bucket, plus a local disk that fills in over time:

```json
"backends": [
  { "type": "s3",    "name": "cloud",  "role": "main", "bucket": "…",
    "accessKeyId": "…", "secretAccessKey": "…" },
  { "type": "local", "name": "backup", "role": "backfill", "path": "/mnt/backup" }
]
```

Rules, checked when the config is read:

- A `replica` or `backfill` needs a `main` to be a copy of.
- A domain with no `main` must have a `readOnly` store, and is then read-only whatever `readOnly` says.
- Backend names are unique within a domain, ignoring case.
- Every machine that writes the domain should list the same replicas and backfills. A copy only receives the writes of machines that know about it.

## Catching up

A write returns as soon as the mains have it. Replicas and backfills are brought up to date afterwards, so writing runs at the speed of the main, and a slow or unreachable copy never holds up your work.

What each copy is owed is recorded on disk before the write is reported done. Losing the network or the power loses none of it: it resumes at the next start. `tsync status` shows the backlog on the copy's `copies` line.

Until a copy has caught up, that write exists only on the mains.

A copy that keeps failing for a reason that waiting will not fix, such as a wrong credential, has its work parked rather than retried forever. Status shows it as `parked`. Fix the cause, then:

```bash
tsync retry
```

## When the main is unreachable

**Reads carry on from a replica.** A store that fails everything asked of it is set aside after about a second, and reads go to the next one. tsync tries it again after 30 seconds, then at doubling intervals up to 5 minutes, and puts it back the moment it answers. Status shows the store as `HELD DOWN` and the domain as `MAIN OFFLINE`.

**Writes wait.** A replica written on its own would hold something the source of truth never had. Your edits stay queued on your machine, as in any outage, and are published when the main is back. For the same reason `mirror`, `gc`, `share` and `data-integrity --verify` or `--repair` refuse to write to a copy while a main is down, and say so.

Reads never fall back to a `backfill`.

If a file cannot be found because a store could not be asked, you get the error, not "no such file".

## `replica` or `backfill`?

`replica` is the full guarantee and costs a full copy.

`backfill` is for when copying what already exists is not worth it: tens of terabytes in the main, a metered link, an archive tier. It starts empty and covers what you write from then on. Whatever it holds is whole: a file appears there only once all of its content is there. What is missing is entire files, never parts of one.

Promoting a backfill that has been filled completely is a one-word change: `"role": "replica"`.

## `tsync mirror`

Copies what one backend holds to the others. It only adds: nothing is deleted on a destination.

```bash
tsync mirror                      # from the first main to every other backend
tsync mirror --source backup      # from the named one
tsync mirror --path photos/2024   # one file or folder, with its content
tsync mirror --skip-chunks        # everything but file content
```

Use it to fill a copy added to an existing domain, to refill a main from a replica (`--source <replica>`; writing *to* a main is always allowed), or to repair a copy that fell behind. It can be stopped and rerun, and a rerun copies only what is still missing.

## Data integrity

Stored content is cut into chunks, and a chunk's name is the hash of its bytes. So any store can tell a damaged chunk with nothing but the chunk: hash it and compare with the name. That catches what a size check cannot, such as the right number of wrong bytes.

Who checks depends on the store:

- **`local`** re-reads each chunk as it writes it (`verifyWrites`, on by default).
- **`s3` and `gcs`** are checked by a function the bucket triggers on every new object, so nothing is downloaded to be checked. It comes with the [Terraform config](../terraform/README.md).

```bash
tsync data-integrity             # what is wrong, and which stores nobody is checking
tsync data-integrity --detail    # every finding
tsync data-integrity --verify    # have each bucket re-check everything it holds
tsync data-integrity --repair    # fix what can be fixed
tsync data-integrity --repair --dry-run
```

The command exits 1 when anything is wrong. It tells "checked and clean" from "not checked"; both would otherwise read as zero problems.

It also checks the domain's folder tree for entries that an interrupted operation left behind, and `--repair` tidies those.

`--repair` rewrites a damaged chunk from another backend's copy, after hashing that copy too, since a second copy can be wrong as well. `--source NAME` restricts it to one backend. Where no good copy exists it names the chunks instead of claiming a repair; saving the affected file again, or importing it again with `--force-rehash`, uploads fresh content.

On a `local` main, `tsync gc --verify` re-hashes every chunk a file still uses. This is how to find bit rot on a disk. It reads everything, so it is slow on a large store.
