# Getting started

## Configure a first domain

A **domain** is one synced folder: a name, the stores that hold its data (**backends**), and the ways it is presented on this machine (**frontends**).

```bash
tsync config --edit
```

On a machine with no config, the prompts go in this order. Press Enter to accept the value in brackets.

**This machine**

| Prompt | What to answer |
|---|---|
| `client name` | A name for this machine. It appears in the name of conflicted copies. Defaults to the hostname. |
| `uploads at once`, `chunk buffers`, `downloads at once` | Enter. See [tuning](tuning.md). |
| `govern uploads to the network's capacity` | Enter. See [uplink](tuning.md#uplink). |
| `TLS implementation` | Enter. |

**The domain**

| Prompt | What to answer |
|---|---|
| `domain name` | The folder's name, for instance `media`. |
| `versioning` | Enter for yes: previous versions are kept ([versions, trash and cleanup](history.md)). |
| `symlinks` | Enter for `keep`. See [symlinks](config.md#symlinks). |
| `read-only` | Enter for no. |
| `chunk size`, `cache chunk size` | Enter. |
| `cache limit` | How much disk the local cache may use. Defaults to 1 GiB; raise it if you work with large files. |

**Its backends.** A new domain goes straight to its first one.

| Prompt | What to answer |
|---|---|
| `type` | `local`, `s3`, `gcs` or `http-proxy`. See [backend types](config.md#backend-types). |
| `backend name` | A label of your choice, for instance `disk`. Commands use it in `--source`. |
| `role` | `main` for the first one. The others are in [keep more than one copy](copies.md). |
| `link` | Remote stores only. Enter. See [uplink](tuning.md#uplink). |
| `fill from the deployment in directory` | `s3` and `gcs` only. If you provisioned the bucket with [terraform/](../terraform/README.md), give that directory and the bucket, credentials and share URL are filled in. Otherwise Enter and type them. |
| the store's own fields | A path, or a bucket and its credentials. Secrets are not echoed. |

The list is then shown. Enter moves on; `a` adds another backend.

**Its frontends.** One yes-or-no question for each way this machine can present the domain:

| Question | Asked on | Default for a new domain |
|---|---|---|
| `mount it as a folder on this machine (fuse)` | Linux | yes |
| `show it in Finder on this machine (file_provider)` | macOS | yes |
| `serve it to other machines over HTTPS (http-proxy)` | both | no |

So on a new domain, Enter twice gives you a folder. Saying yes to the server asks for its port, secret and certificate ([run tsync as a server](server.md)). Each frontend's remaining options sit behind one more question, `other options`, which defaults to no.

**The last menu** lists your domains:

```
Domains:
  1. media: 1 backends
a number to edit that domain, [a]dd, [r]emove N, [g]lobals, [w]rite, [q]uit:
```

Type `w` to write the file. Nothing is saved before that, and `q` leaves without saving.

The result, for a folder backed by another disk:

```json
{
  "domains": [
    {
      "name": "media",
      "versioning": true,
      "symlinks": "keep",
      "maxCache": "1 GiB",
      "backends": [
        { "type": "local", "name": "disk", "role": "main", "path": "/mnt/pool" }
      ],
      "frontends": ["fuse"]
    }
  ]
}
```

You can edit the file by hand instead; `tsync build-info` says where it is. Run `tsync config --edit` again later to change it: type a domain's number, then go through the same prompts, where Enter keeps the current value.

**The config is checked strictly.** A key tsync does not know, a missing required key or a value of the wrong type is an error that names the place:

```
tsync: domains[0].backends[0]: unknown key(s) "bukcet"
```

`tsync config` prints the domains as tsync read them, with secrets shown as `***`. Run it after editing by hand: if it prints, the file is valid.

The file holds credentials. tsync writes it readable by you alone and refuses to start a service on one that other users can read.

## Start it

A background service runs tsync; you do not keep a terminal open.

tsync has no restart command of its own: the service belongs to your system's service manager, and that is what restarts it after a config change.

| Install | Start | Restart after a config change |
|---|---|---|
| Linux package | `sudo systemctl enable --now tsync@$USER` | `sudo systemctl restart tsync@$USER` |
| Linux from source | done by `make install` | `systemctl --user restart tsync` |
| macOS | done by the installer | `launchctl kickstart -k gui/$UID/org.feverdreamtv.tsync.daemon` |

The Linux package's unit is a template that takes the user to run as. Once enabled it starts at boot, with nobody logged in.

Then look:

```bash
tsync status
```

Your folder is at `~/tsync/<domain>/` on Linux. On macOS it is in Finder's sidebar under **Locations**, and on disk under `~/Library/CloudStorage/`.

`tsync stop` stops the service and unmounts. A stop takes seconds whatever is still uploading: unfinished work is recorded on disk and continues at the next start. `tsync start` runs tsync in the foreground, which is what the service does.

If the service will not start, `tsync logs` says why. A config error makes it exit without being restarted in a loop.

## Put your files in

Copy them into the folder, like anywhere else. Or use one of two commands that upload straight to the store without filling the local cache.

### `tsync import`

Uploads a directory's content into the domain at the same relative paths.

```bash
tsync import ~/Pictures
tsync import ~/Pictures --exclude '*.tmp' --exclude '**/.git'
tsync import ~/Music --only '*.flac'
```

- A file the domain already has is skipped, **even if its content differs**. That makes a rerun after an interruption cheap. `--force-rehash` uploads such files again.
- Empty folders are imported.
- Symlinks follow the domain's [`symlinks`](config.md#symlinks) setting.
- Identical content is stored once.

`--only` selects what to import; `--exclude` then removes from that. Both can be repeated. A pattern is tried against each entry's path relative to the directory and against its name alone, so `node_modules` matches at any depth.

| Pattern | Matches |
|---|---|
| `*` | Any characters except `/` |
| `?` | One character except `/` |
| `**/` at the start or between slashes | Any number of directories, including none |
| `/**` at the end | Everything below |
| anything else | Itself. There is no escaping, no `[abc]` and no `{a,b}`. |

### `tsync rsync`

Copies between a local path and a domain, or within a domain, and sends only what differs. One side is written `DOMAIN:PATH`, or `:PATH` for the default domain.

```bash
tsync rsync ~/Pictures media:photos          # local into the domain
tsync rsync media:photos/2019 /mnt/usb/2019  # domain to local
tsync rsync media:drafts media:archive/2024  # inside the domain
tsync rsync --move ~/Scans media:scans       # delete each source once copied
tsync rsync -n ~/Pictures media:photos       # say what would happen, change nothing
```

Unlike `import`, it compares content and replaces a destination file that differs. It compares bytes, never modification times. A copy within a domain moves no data: the new file points at the same stored chunks.

A side is in a domain when it starts with `:` or with a configured domain's name and a colon. Anything else is a local path.

## Day to day

Use the folder. Opening a file fetches it; saving one uploads it in the background. None of that involves a command.

### Offline and online-only

A file is in one of three states:

| State | Meaning |
|---|---|
| online-only | Listed, with no content on this machine. Reading it needs the store. |
| cached | Content is here because something read it. The cache drops it when it needs room. |
| available offline | Content is here and is kept, for 10 days. Asking again extends it. Not counted against the cache limit. |

You change the state from the file manager:

| Where | Entries |
|---|---|
| Finder | *Make Available Offline*, *Make Online Only*, *Copy Share URL* |
| Dolphin, with `tsync-dolphin` | *Make Available Offline* or *Keep Offline Longer*, *Make Online Only*, *Copy Share Link* |
| Android app | *Make available offline*, *Keep offline longer*, *Remove download* |

Or from a terminal:

```bash
tsync cache --fetch trip-2024             # make available offline, for 10 days
tsync cache --fetch --keep 30d trip-2024  # ...or for as long as you say
tsync cache --evict photos/2019 old.iso   # make online only
```

On a folder, each applies to everything below it. The command prints one line per path with the number of files, and exits 1 if anything failed.

A file with changes that have not been uploaded yet always keeps its content, whatever you ask.

### See what is going on

```bash
tsync status          # one report for the whole machine
tsync status -w 2     # redrawn every 2 seconds
tsync status --json   # the same data for a script
tsync logs -f         # follow the service log
```

The report is quiet when things are fine. A line in capitals is something to look at; [the status report](commands.md#the-status-report) explains each.

The tray icon on Linux and the menu bar item on macOS show the same thing at a glance: which files are moving, how much is left, and a *Hold changes* switch.

### Pause

```bash
tsync pause     # hold every change of the domain
tsync resume
```

A paused domain publishes nothing, applies nothing from other machines and copies nothing to replicas. You can still read files and edit them: edits are kept locally and go out on `resume`. The pause survives a restart and a reboot.

### Long commands

`import`, `rsync`, `mirror`, `sync`, `gc`, `expire` and `data-integrity` run inside the service when it is up, and the command you typed follows along and prints the result.

- Progress is shown while they run. `-v` adds a sentence for every step and decision; `-q` shows only the result.
- Ctrl-C asks the job to stop at its next safe point. A second Ctrl-C returns your prompt at once; the job still stops cleanly.
- Closing the terminal does not stop the job. `tsync status` lists it under `Jobs`, whoever started it.
- With no service running, the command does the work itself.
