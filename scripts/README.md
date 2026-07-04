# tsync perf scripts

Collect `tsync stats` once per second and graph it. Collection and graphing are
separate so a crash never loses data and you can graph mid-run.

## Prerequisites

Only the grapher needs anything (matplotlib); the collector is pure shell.

| OS / distro        | Install                                  |
|--------------------|------------------------------------------|
| Ubuntu / Debian    | `sudo apt install python3-matplotlib`    |
| Fedora / RHEL      | `sudo dnf install python3-matplotlib`    |
| Arch               | `sudo pacman -S python-matplotlib`       |
| macOS (Homebrew)   | `brew install python-matplotlib`         |
| Any (pip/venv)     | `python3 -m venv .venv && .venv/bin/pip install matplotlib` |

## Usage

```sh
# 1. Collect (crash-safe: each second is flushed to disk as it's written).
scripts/stats-collect.sh stats.ndjson        # Ctrl-C to stop
# run it detached on a remote box:
nohup scripts/stats-collect.sh stats.ndjson >/dev/null 2>&1 &

# 2. Graph — safe to run anytime, including while collecting.
scripts/stats-graph.py stats.ndjson snapshot.png
```

Both scripts take optional args:

- `stats-collect.sh [log-file] [tsync-binary]` — defaults `stats.ndjson`, `tsync`. Appends, never truncates.
- `stats-graph.py [log-file] [out.png]` — defaults `stats.ndjson`, `stats-graph.png`.

The log is NDJSON (one `tsync stats --json` object per line, with a `t`
timestamp), so you can also process it with `jq` or anything else.
