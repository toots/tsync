# Command reference

## Commands

Every command takes `-v` (narrate each step), `-q` (no progress) and `--help`. Commands that act on a domain take `-d NAME` / `--domain NAME`.

**Which domain.** With one domain configured, it is that one. With several, pass `--domain`, or set a default:

```bash
tsync default-domain media     # set
tsync default-domain           # print
tsync default-domain --clear
```

`tsync status` always covers every domain.

**Paths inside a domain** are spelled the same way in every command (`cache`, `versions`, `share`, `export`, `mirror --path`, `rsync`):

| Spelling | Means |
|---|---|
| `photos/2024/a.jpg` | That path in the domain the command acts on |
| `media:photos/2024/a.jpg` | That path in the domain `media`. `media:` alone is its root. |
| `:photos/2024/a.jpg` | The same as the first, written out. `rsync` needs it to tell a domain path from a local one. |
| `/home/you/tsync/media/photos/2024/a.jpg` | A path under a domain's mount point names that domain (Linux) |

A command acts on one domain: paths naming two, or one that differs from `--domain`, are refused.

**Service**

| Command | Does |
|---|---|
| `tsync status [--json] [-w SECONDS]` | Report on everything tsync runs on this machine |
| `tsync logs [-f] [-n N]` | Show the service log; the last 200 lines by default |
| `tsync stop` | Stop it |
| `tsync start [--mount PATH] [--tls native\|openssl]` | Run in the foreground. `--mount` works with a single domain. |
| `tsync pause`, `tsync resume` | Hold or release every change of a domain |
| `tsync retry` | Run parked work again now |

**Setup**

| Command | Does |
|---|---|
| `tsync config` | Print the domains as read, secrets masked |
| `tsync config --edit` | Create or change the config through prompts |
| `tsync config --edit --advanced` | The same, also asking about the [advanced settings](tuning.md#advanced-settings); answer `-` to remove one |
| `tsync default-domain [NAME] [--clear]` | See above |
| `tsync build-info` | What this binary includes, and where it keeps things |

**Files**

| Command | Does |
|---|---|
| `tsync cache --fetch [--keep DUR] PATH…` | Make files or folders available offline |
| `tsync cache --evict PATH…` | Make them online only |
| `tsync import DIR [--only GLOB] [--exclude GLOB] [--force-rehash]` | Upload a directory into the domain |
| `tsync rsync SRC DST [--move] [-n]` | Copy or move between a local path and a domain, or within one |
| `tsync export [PATH…] DIR [--source NAME] [-j N]` | Write files from the stores to a directory |
| `tsync share [PATH] [--expires DUR] [--token HEX]` | Print a public link |
| `tsync share --revoke TOKEN\|URL` | Stop a link |
| `tsync share --clear-cache` | Delete prepared share downloads |
| `tsync versions [PATH]` | List a file's versions, or every deleted file |
| `tsync versions --revert PATH [--version TS]` | Put a version back |

**Stores**

| Command | Does |
|---|---|
| `tsync sync [--full]` | Pick up other machines' changes and publish this one's now; `--full` reads the store's whole tree |
| `tsync mirror [--source NAME] [--path P \| --skip-chunks]` | Copy from one backend to the others |
| `tsync data-integrity [--detail] [--verify \| --repair [--dry-run] [--source NAME]]` | Report on the tree and the chunks, re-check the chunks, or repair them |
| `tsync void-entry N` | Pass a damaged entry of the change log that no machine can read |
| `tsync expire DATE [--apply]` | Remove history older than `YYYY-MM-DD` |
| `tsync gc [--apply] [--verify] [--budget SECONDS]` | Reclaim unused chunks |
| `tsync gc --status \| --abort` | Look at, or abandon, an open run |
| `tsync gc --probe \| --outstanding \| --retry-outstanding` | The delete requests handed to bucket copies |

**macOS only**

| Command | Does |
|---|---|
| `tsync fileprovider reimport` | Have Finder list the domain again |
| `tsync fileprovider reset` | Remove the domain from Finder and add it back |
| `tsync fileprovider purge` | Uninstall |

**Exit status.** 0 on success. 1 when something failed or, for `data-integrity`, was found wrong; the reason is one sentence on stderr. 2 when the invocation itself is refused: arguments that contradict each other, paths naming two domains, a command that cannot apply to this domain. 124 for a mistake on the command line.

`pause-uploads` and `resume-uploads` are older names for `pause` and `resume`.

## The status report

```
tsync on nas — 1 domain, 3 processes, up 11m 11s, load 0.4

Domain media
  settings         versioning on, symlinks keep, chunk 8.0 MiB (default), cache chunk 16.0 MiB
  concurrency      4 uploads, 4 chunk buffers, 8 downloads
  cache            7494 chunks, 9.9 GiB of 10.0 GiB
  Frontend fuse       pid 101  /home/you/tsync/media
  Backend cloud (s3, main)  bucket media-bucket
    link             wan
    reachable        yes (51 ms)
    corrupted        not checked — no verification has run
    traffic          up 0 B (0 B/s), down 92 B (4 B/s)

Processes
  …
Uplinks
  wan        steady, 2.8 MiB/s (measured)
```

Each domain shows its settings, its cache, its frontends and its backends. Then come the processes, the links, any long command in progress under `Jobs`, and the latest warnings.

A healthy report is short. These lines appear only when there is something to say:

| Line | Meaning | What to do |
|---|---|---|
| `PAUSED` | Changes are held | `tsync resume` |
| `uploads … pending` | Files waiting to upload, and how much | Nothing; it is working |
| `MAIN OFFLINE` | No main answers. Reads use a replica if there is one; edits wait. | Bring the main back |
| `HELD DOWN` | This backend failed repeatedly and is being left alone for the time shown | It is retried on its own |
| `UNREACHABLE` | This backend did not answer, with the reason | Check the network or the credentials |
| `copies … owed` | A replica or backfill is behind by that many objects | Nothing; it catches up |
| `(… parked)` | Work for a copy was set aside after failing for good | Fix the cause, then `tsync retry` |
| `pending … to commit` | Changes made here and not published yet | Nothing; they go within seconds once uploaded |
| `projection` | Who writes this machine's changes to the store's tree: this machine, or the server it reaches its storage through | Nothing |
| `projecting` | Changes committed here are still being written to the store's tree, where a new machine and shares read them | Nothing; it catches up |
| `PARKED` | An upload failed for good, with the error | Fix the cause, then `tsync retry` |
| `CANNOT FOLLOW` | The store holds a change this machine cannot read, with the reason. Nothing is picked up or published until it is dealt with. | Upgrade tsync here; if the entry is damaged, `tsync void-entry N` on any machine |
| `CORRUPTED` | A store found damaged chunks | `tsync data-integrity --repair` |
| `corrupted  not checked` | Nothing verifies this store | See [data integrity](copies.md#data-integrity) |
| `SET ASIDE` | Local records that could not be read were kept and skipped | Report it |
| `NOT ANSWERING` | A tsync process is not responding | `tsync logs`; restart the service |

## Logs

tsync keeps no log files of its own. It logs to the system, and `tsync logs` reads it back.

| Platform | Reads | Notes |
|---|---|---|
| Linux | The systemd journal: `journalctl -t tsync` | Needs systemd-journald. Without it, the log is wherever your init system sends the service's stderr. |
| macOS | `~/Library/Logs/tsync-daemon.log` | Nothing rotates this file. |

On macOS the File Provider extension is started by the system and logs separately:

```bash
log show --last 1h --predicate 'subsystem == "org.feverdreamtv.tsync"'
```

The most recent warnings and errors are also at the end of `tsync status`, and of a server's status page.
