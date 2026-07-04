#!/bin/sh
# Append one tsync stats sample per second to an NDJSON log.
# Crash-safe: each line is flushed as it's written, so a machine crash only
# loses the in-flight second. Graph anytime with scripts/stats-graph.py.
#
# Usage: scripts/stats-collect.sh [log-file] [tsync-binary]
#   log defaults to stats.ndjson, appends (does not truncate).
LOG="${1:-stats.ndjson}"
TSYNC="${2:-tsync}"
exec "$TSYNC" stats --json -w 1 >>"$LOG"
