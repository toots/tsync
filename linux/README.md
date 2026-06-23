# tsync — Linux

S3-backed FUSE filesystem. Files are mounted at `~/tsync/<domain>/` and backed by S3. Evicted files remain visible with correct size/mtime but occupy no local space; they download transparently on first access.

## Architecture

| Component | Role |
|---|---|
| `lib/s3_client.ml` | S3 operations via `aws-s3` + Lwt |
| `lib/s3_store.ml` | Upload/download/rename/delete with chunking and versioning |
| `lib/fuse_fs.ml` | FUSE operations (ocamlfuse); metadata cache; IPC handler |
| `lib/cache.ml` | Local file cache at `~/.cache/tsync/<domain>/` |
| `lib/ipc.ml` | Unix socket IPC at `~/.local/share/tsync/tsync.sock` |
| `bin/main.ml` | CLI entry point (cmdliner); runs in foreground under systemd |

## Requirements

- Linux with FUSE support (`/dev/fuse`, `libfuse3`)
- OCaml 4.14+ with opam
- An AWS account with an S3 bucket

## Setup

```bash
make install-deps   # pin and install OCaml dependencies
make configure      # interactive config → ~/.config/tsync/config.json
make install        # build, install binary, enable systemd unit
```

`tsync start` runs in the foreground — systemd manages the lifecycle (start, stop, restart on failure). Logs go to the journal:

```bash
journalctl --user -u tsync -f
```

## Docker (for testing)

```bash
cd docker
./run_tests.sh
```

Reads config from the macOS group container path (or `~/.config/tsync/`) and passes it to the container as `TSYNC_CONFIG_JSON`. Prompts interactively if no config is found.

## CLI Reference

```
tsync start   [--mount <path>] [--domain <name>]   # run in foreground (use via systemd)
tsync stop                                          # unmount and exit
tsync status

tsync evict   <path>           # remove from local cache (stays visible via S3 metadata)
tsync restore <path>           # download an evicted file
tsync pull    [path]           # download all evicted files
tsync wait    <path> [--timeout N]  # block until file is cached locally
tsync ls      [path]           # list files with local/cloud status

tsync history <path>           # list versioned copies in .trash/
tsync purge   <path>           # delete all versions for a file from .trash/

tsync auto-evict [on|off|status]  # enable/disable auto-evict after upload (persists across restarts)
```

## Versioning

When `versioning = true` in config, deleting a file copies it to `<prefix>/.trash/<domain>/<path>/<timestamp>` before removal.

## Known limitations

See [../README.md](../README.md) for limitations shared with macOS. Linux-specific:

**Single-threaded FUSE.** Runs in `Single_threaded` mode; concurrent filesystem operations queue behind the Lwt event loop. Sufficient for a personal library; would need `Multi_threaded` + per-file locking for heavy concurrent use.
