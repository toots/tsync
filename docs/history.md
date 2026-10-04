# Versions, trash and cleanup


## Versions

With `"versioning": true`, every change, rename and delete of a file keeps the version it replaces.

```bash
tsync versions                     # every deleted file that has saved versions
tsync versions notes/todo.txt      # one file's versions, newest first
tsync versions --revert notes/todo.txt                         # the latest saved version
tsync versions --revert notes/todo.txt --version 1759612345000000000
```

The listing shows a timestamp, a date and a size per version; `--version` takes the timestamp from the first column. Reverting works on a deleted file too.

A revert is instant and downloads nothing: a version is a short list of chunks, and the chunks are still in the store. The file comes back online-only. The content it replaces becomes a version in turn.

## Trash

Deleting a folder moves it to the trash as a whole.

```bash
tsync trash                        # list trashed folders
tsync trash --restore projects/old # put one back where it was
tsync trash --purge projects/old   # what deleting it for good would remove
tsync trash --purge projects/old --apply
```

A restore is refused if something else now has the name; move that first. Other machines see the folder return like any other change.

## Cleanup

History and trash grow until you trim them. That takes two commands, and **both only report until you add `--apply`.**

```bash
tsync expire 2026-01-01           # what would go
tsync expire 2026-01-01 --apply

tsync gc                          # what could be reclaimed
tsync gc --apply
```

**`expire`** removes versions, trashed folders, journal entries and lapsed share links older than the date. That forgets old content without freeing its space. It works with every backend.

**`gc`** deletes the chunks nothing refers to any more, and that is what frees space. It goes by references alone and knows nothing of dates.

`gc` needs a `main` that is a `local` store on the machine you run it on. It works by renaming directories, which a filesystem can do and a bucket cannot. So:

- With a disk as main, run it on the machine that has the disk. For a domain served by a tsync server, that is the server.
- It then also deletes the same chunks from the domain's replicas and backfills, buckets included.
- With only a bucket as main, `gc` has nothing it can collect, and says so. `expire` still works.

`gc` is safe to run while machines are using the domain. A large store can be collected in sittings:

```bash
tsync gc --apply --budget 1800   # stop after about 30 minutes; the next run continues
tsync gc --status                # is a run open, and how far along
tsync gc --abort                 # abandon the open run, putting every chunk back
```

A run may stay open as long as you like: reads and writes work throughout. While one is open, `tsync mirror` refuses, except with `--skip-chunks`.

**Deletes on a bucket copy.** An `s3` or `gcs` replica or backfill does not delete chunks one request at a time. `gc` writes the list as a small object, and the bucket's own function carries it out. Nothing to configure if the bucket came from the [Terraform config](../terraform/README.md).

```bash
tsync gc --probe               # is each bucket's function deployed?
tsync gc --outstanding         # delete requests no function has carried out yet
tsync gc --retry-outstanding   # hand them over again
```

A request nobody carried out means the copy still holds chunks nothing uses: wasted space, not lost data. Nothing retries on its own, so check `--outstanding` after fixing a function.
