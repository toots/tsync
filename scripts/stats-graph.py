#!/usr/bin/env python3
"""Graph a tsync stats NDJSON log (see scripts/stats-collect.sh).

Prereqs (Ubuntu/Debian): sudo apt install python3-matplotlib
Usage: scripts/stats-graph.py [stats.ndjson] [out.png]

Reads whatever samples are in the log — safe to run mid-collection.
"""
import json
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

LOG = sys.argv[1] if len(sys.argv) > 1 else "stats.ndjson"
OUT = sys.argv[2] if len(sys.argv) > 2 else "stats-graph.png"

# (json key, series label, panel) — panel groups series onto shared subplots.
SERIES = [
    ("uploadMBps", "upload", "MB/s"),
    ("downloadMBps", "download", "MB/s"),
    ("hashesPerSec", "hashes/s", "Rates"),
    ("pendingUploads", "pending up", "Queues"),
    ("pendingDownloads", "pending down", "Queues"),
    ("dirtyFiles", "dirty", "Queues"),
    ("openFiles", "open", "Queues"),
    ("cpuPercent", "cpu", "CPU %"),
    ("rssMB", "rss", "Memory (MB)"),
    ("diskFreePercent", "disk free", "Disk free %"),
]

samples = []
with open(LOG) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            samples.append(json.loads(line))
        except json.JSONDecodeError:
            pass  # skip daemon messages / half-written trailing line
if not samples:
    sys.exit(f"No samples in {LOG}.")

t0 = samples[0].get("t", 0)
xs = [s.get("t", 0) - t0 for s in samples]

# Derive CPU% (cpuSeconds is cumulative) and RSS in MB.
for i, s in enumerate(samples):
    s["rssMB"] = s.get("rssBytes", 0) / 1e6
    s["uploadMBps"] = s.get("uploadBytesPerSec", 0) / 1e6
    s["downloadMBps"] = s.get("downloadBytesPerSec", 0) / 1e6
    dt = xs[i] - xs[i - 1] if i else 0
    dc = s.get("cpuSeconds", 0) - samples[i - 1].get("cpuSeconds", 0) if i else 0
    s["cpuPercent"] = 100 * dc / dt if dt > 0 else 0

panels = list(dict.fromkeys(p for _, _, p in SERIES))
fig, axes = plt.subplots(len(panels), 1, sharex=True, figsize=(10, 3 * len(panels)))
if len(panels) == 1:
    axes = [axes]
for ax, panel in zip(axes, panels):
    for key, label, p in SERIES:
        if p != panel:
            continue
        ax.plot(xs, [s.get(key, 0) for s in samples], label=label)
    ax.set_ylabel(panel)
    ax.legend(loc="upper left", fontsize="small")
    ax.grid(True, alpha=0.3)
axes[-1].set_xlabel("seconds")
fig.tight_layout()
fig.savefig(OUT, dpi=120)
print(f"Wrote {OUT} ({len(samples)} samples)")
