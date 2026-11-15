# Versions and cleanup


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

## Deleted folders

A folder has no version of its own. Deleting one deletes the files in it, and with versioning on each of them is a deleted file with saved versions: `tsync versions` lists them, and `--revert` puts one back once its folder exists again.

## Cleanup

History grows until you trim it. That takes two commands, and **both only report until you add `--apply`.**

```bash
tsync expire 2026-01-01           # what would go
tsync expire 2026-01-01 --apply

tsync gc                          # what could be reclaimed
tsync gc --apply
```

**`expire`** removes versions and lapsed share links older than the date, and the entries of the change log that every machine has had a month to read. That forgets old content without freeing its space. It works with every backend.

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

### Choosing the versions that go

`expire DATE` takes every version older than the date. To keep some of them, write the list out, edit it, and expire exactly what is left:

```bash
tsync expire 2026-01-01 --export old.txt   # the versions that would go; nothing is removed
$EDITOR old.txt                            # delete a line to keep that version
tsync expire --from old.txt                # what would go
tsync expire --from old.txt --apply
```

Each line is a version as `tsync versions` prints it, so a line copied from there can be pasted in. Only the timestamp and the path count: the date and size are for reading. A list touches versions only; the change log and share links still go with `tsync expire DATE`. Running the same list again is harmless: versions already gone are counted and skipped. A list whose lines no longer match a version (a mistyped name, a file renamed since) is refused whole, naming each bad line, before anything is removed.

Writing the list reads every listed version, one request each on a bucket.

`expire` frees no space by itself. To see how much an expiry would free, give it to a `gc` dry run:

```bash
tsync gc --expire old.txt              # from a list
tsync gc --expire-before 2026-01-01    # every version older than the date
```

It reports the chunks only those versions use, which a collection after the expiry reclaims, beside what is already unused. Add `--apply` and `gc` expires those versions itself and frees their space in the same run:

```bash
tsync gc --expire old.txt --apply
```

The run remembers its versions: a run stopped by `--budget` carries on with them at the next `tsync gc --apply`, no list needed. While it is open, `gc` refuses a different expiry. `tsync gc --abort` puts every chunk back but not the versions: those already removed stay removed, and their chunks are collected by the next run.

Without a disk as main, `gc` cannot collect, so `tsync expire --from` is the way to apply a list.
