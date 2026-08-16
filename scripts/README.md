# tsync scripts

## Performance

Collect `tsync status` once per second and graph it. Collection and graphing are
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

The log is NDJSON (one `tsync status --json` object per line, with a `t`
timestamp), so you can also process it with `jq` or anything else.


## CI credentials

`setup_ci_secrets.sh` provisions what the backend conformance job needs: a test
bucket on GCS and on S3, credentials scoped to those buckets alone, and the six
repository secrets the workflow reads. Objects expire after two days, so a run
that is cancelled before it can clean up costs nothing for long.

```sh
bash scripts/setup_ci_secrets.sh --dry-run   # what it would do
bash scripts/setup_ci_secrets.sh             # confirms before creating anything
```

Safe to re-run: everything is create-if-missing or an overwrite, and a
credential is only replaced once its successor has been proven against the live
bucket and stored, so a failure part-way never leaves CI holding a revoked key.

Needs `gh`, `gcloud` and `aws` logged in. Without the aws cli it does the GCS
half and says so.

## The chunk verifier on the CI buckets

`setup_ci_secrets.sh` also deploys the chunk verifier onto the buckets it
provisions, into terraform state of its own (`terraform/ci/`, prefix
`tsync-ci`). Two of the things tsync leans on -- the whole-store sweep and the
deletes `gc` hands over -- are a client writing an object and trusting a
function to act on it, and nothing but a deployed function proves that wiring
is there.

It deploys the verification half alone (`deploy_share = false`), so no
unauthenticated endpoint is stood up over a bucket whose credentials live in
CI. The state prefix is never the deployment's own: an apply pointed at CI
buckets with the real state is how real stores would be reached.

`DEPLOY_FUNCTIONS=0` skips it, and so does having neither `tofu` nor
`terraform` on the PATH. Conformance then reports that half as not run rather
than failing, since a bucket with no stack is a legitimate setup.

The function's code is whatever the last run of this script applied. After
changing anything under `lambda/`, re-run it -- otherwise conformance exercises
the previous code against the current wiring.
