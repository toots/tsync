# Menu model — as built

> **Status: as-built snapshot (pass 1)** of `main` at `4c32fa96`. Descriptive, not normative. The
> normative text for this model is still [07 §5.8](../07-daemon-cli.md); where the two differ, see
> [linux-desktop-findings.md](linux-desktop-findings.md).
>
> **Not extracted:** the macOS side that receives the JSON form (§7) and draws it. This pass read
> the model and the Linux tray only; the macOS rendering is left to the reimplementation pass.

A pure function from owner replies to what a status menu shows: an icon name, a tooltip and a list
of rows. It knows nothing of D-Bus, mount paths or a toolkit. The Linux tray
([linux-tray.md](linux-tray.md)) calls it directly; the macOS menu receives its output as JSON
(§7). Every string a user reads in either menu is produced here.

## 1. Output

```
menu   = { icon, tooltip, entries }
entry  = Separator | Item
Item   = { label, enabled, icon?, checked?, indent, action, submenu }
action = Nothing | OpenFolder(domain) | Reveal(domain, rel) | SetPaused(bool) | ShowStats | Quit
```

- `indent` is a nesting level (0, 1, 2); how to draw it is the renderer's.
- `checked` present makes the row a checkmark row in that state.
- `submenu` marks a row that opens a menu of its own; its rows are not part of the model's output
  and are supplied by whoever fetched them (§6).
- An action names a domain and a path under it, never an absolute path: where a domain's folder is
  differs per client.
- Informational rows are `enabled` with action `Nothing`: a disabled row draws grey and reads as a
  broken command.

## 2. Input: one `status` reply per domain

A domain's status is either **unreachable** (no reply, or a reply whose `ok` is not `true`) or
built from these reply fields:

| model field | reply field | when absent |
|---|---|---|
| `uploads` | `pendingUploads` (integer) | 0 |
| `downloads` | `pendingDownloads` (integer) | 0 |
| `paused` | `paused` (boolean) | false |
| `uploading` | `uploading`: list of `{name, rel, size?}` | empty |
| `downloading` | `downloading`: list of `{name, rel, bytes, size, rate}` | empty |
| `pendingBytes` | `pendingBytes` (integer) | unknown |
| `bytesUploaded` | `bytesUploaded` (integer) | unknown |
| `uploadRate` | `uploadBytesPerSec` (number) | unknown |

- A transfer row is kept only when both `name` and `rel` are non-empty strings. Its `moved` is
  `bytes`, its `total` is `size`, its `rate` is `rate`; each may be absent.
- The owner sends no `bytes` and no `rate` for an upload.
- The owner has already dropped downloads too small or too brief to be worth a row.
- `pendingDownloads` counts chunk fetches in flight, not files.
- An unreachable domain has every count unknown and no transfers.

Derived per domain:

- **reachable**: `uploads` is known.
- **download count**: the number of `downloading` rows when there are any, else `downloads`.
- **transferring**: `uploads` + download count + `downloads` > 0.

Derived over all domains:

- **all unreachable**: no domain is reachable (true for an empty list).
- **all paused**: the list is non-empty and every domain's `paused` is known true.
- **pending bytes**: the sum of the known `pendingBytes`.
- **bytes uploaded**, **upload rate**: the value of the **first** domain, in order, that reports
  one. They are not summed (the owner reports them per process).

## 3. Formatters

**Bytes.** Units `B`, `KB`, `MB`, `GB`, `TB`, each 1024 of the previous. Divide while the value is
≥ 1024 and a larger unit exists. Under 1024: the integer and ` B`. Otherwise one decimal place.

| input | output |
|---|---|
| 0 | `0 B` |
| 999 | `999 B` |
| 1000 | `1000 B` |
| 1500 | `1.5 KB` |
| 999999 | `976.6 KB` |
| 223200000 | `212.9 MB` |
| 1070000000 | `1020.4 MB` |
| 12800000000 | `11.9 GB` |
| 2500000000000 | `2.3 TB` |

**Duration** (`eta`). Undefined for a negative, not-a-number or > 10¹² input. Truncate to whole
seconds; compute days, hours and minutes; drop the zero ones; keep the first two; join with a
space as `<n>d`, `<n>h`, `<n>m`. Nothing left (under a minute) → undefined.

| seconds | output |
|---|---|
| 0, 45 | undefined |
| 60, 90 | `1m` |
| 3600 | `1h` |
| 8000 | `2h 13m` |
| 86400 | `1d` |
| 90000 | `1d 1h` |
| 180000 | `2d 2h` |

**Ellipsis.** A text of at most 64 bytes is kept. Otherwise: start at byte 64, step back while that
byte is a UTF-8 continuation byte; if a space exists before that point at an index above 32, cut
at that space, else cut at that point; append `…`.

**File icon**, from the lower-cased extension of the name:

| extensions | icon name |
|---|---|
| `.jpg .jpeg .png .gif .webp .heic .heif .tif .tiff .bmp .svg .raw .cr2 .nef .dng` | `image-x-generic` |
| `.mp4 .mov .mkv .avi .webm .m4v .mpg .mpeg .wmv` | `video-x-generic` |
| `.mp3 .flac .wav .aac .m4a .ogg .opus .aiff .aif` | `audio-x-generic` |
| `.xls .xlsx .ods .csv` | `x-office-spreadsheet` |
| `.ppt .pptx .odp` | `x-office-presentation` |
| `.pdf .doc .docx .odt .rtf .epub` | `x-office-document` |
| `.zip .tar .gz .bz2 .xz .zst .7z .rar .dmg .iso` | `package-x-generic` |
| anything else, or none | `text-x-generic` |

Only generic names from the icon naming specification are used: a specific name a theme lacks
draws nothing.

## 4. Icon and tooltip

**Icon**, first match:

1. all unreachable (including no domains) → `tsync-error-symbolic`
2. all paused → `tsync-paused-symbolic`
3. any domain transferring → `tsync-sync-symbolic`
4. else → `tsync-idle-symbolic`

**Summary**, first match:

1. no domains → `No domains configured`
2. all unreachable → `Daemon not running`
3. with U = sum of known `uploads` and D = sum of known download counts:
   - U = 0 and D = 0 → `Paused` when all paused, else `Idle`
   - else join with ` · `: `Uploading U` (when U > 0), `Downloading D` (when D > 0), `paused`
     (when all paused)

**Tooltip**: `tsync — <summary>`.

## 5. Rows

In order:

1. **Header**, only when there are no domains: `tsync — <summary>`.
2. **Per domain**, in input order:
   - the domain row: `<name> — <detail>`, action `OpenFolder(name)`, where `<detail>` is
     `not answering` (unreachable), `Paused` or `Idle` (nothing moving), `Uploading U`,
     `Downloading D`, or `Uploading U · Downloading D`, from this domain's own counts;
   - its upload file rows, then its download file rows (below).
3. **Traffic**, when shown: a separator, the traffic line, then the rate line when there is one.
   - Traffic line: nothing when bytes uploaded is unknown; nothing when it is 0 and pending bytes
     ≤ 0; `<sent> sent` when pending bytes ≤ 0; else `<sent> sent · <pending> to go`.
   - Rate line, only when pending bytes > 0 and the upload rate > 0: `<rate>/s · <eta> left`, with
     eta of pending / rate; `<rate>/s · under a minute left` when the eta is undefined.
4. A separator.
5. **Stats**: label `Stats`, action `ShowStats`, `submenu`.
6. **Hold changes**: label `Hold changes`; `checked` = all paused; `enabled` unless all
   unreachable; action `SetPaused(not all paused)`.
7. A separator.
8. **Quit**: the caller's label, default `Quit tsync tray`; action `Quit`. The label names the
   icon, not tsync: quitting removes the icon and leaves the owners running.

**File rows**, for one list (uploads or downloads) of one domain:

- sort the transfers by `name`, bytewise;
- for each of the first **5**: a row at indent 1, label the ellipsised `name`, icon the file icon,
  action `Reveal(domain, rel)`; then, when it has any figure, a progress row at indent 2;
- when more than 5: a row at indent 1, `… and N more`, N the number not shown.

**Progress row**, joined with ` · `, parts in order, each only when known:

- `<moved> of <total>`, or `<moved>` alone, or `<total>` alone;
- `<rate>/s` when the rate > 0;
- when moved, total and a rate > 0 are known and total > moved: `<eta> left` for
  (total − moved) / rate, or `under a minute left`.

Worked example (real output of the model's test, `-> …` being the action and `(…)` the icon):

```
icon    tsync-sync-symbolic
tooltip tsync — Uploading 1 · Downloading 2
        photos — Uploading 1 · Downloading 2 -> open photos
            out.raw (image-x-generic) -> reveal photos:out.raw
            holiday.mov (video-x-generic) -> reveal photos:trips/holiday.mov
                752.0 MB of 14.5 GB · 1.5 MB/s · 2h 34m left
            notes.pdf (x-office-document) -> reveal photos:notes.pdf
                234.4 KB of 878.9 KB
        ---
        1000 B sent
        ---
        Stats >
        [ ] Hold changes -> pause true
        ---
        Quit tsync tray -> quit
```

Input for it: one domain `photos`, `pendingUploads` 1, `pendingDownloads` 9, one upload `out.raw`
with no figures, downloads `holiday.mov` (rel `trips/holiday.mov`, 788529152 of 15589124313 at
1600000 B/s) and `notes.pdf` (240000 of 900000, no rate), `bytesUploaded` 1000, `pendingBytes` 0.

Other pinned cases:

```
== daemon not running
icon    tsync-error-symbolic
tooltip tsync — Daemon not running
        photos — not answering -> open photos
        ---
        Stats >
        [ ] Hold changes (disabled)
        ---
        Quit tsync tray -> quit

== no domains
icon    tsync-error-symbolic
tooltip tsync — No domains configured
        tsync — No domains configured
        ---
        Stats >
        [ ] Hold changes (disabled)
        ---
        Quit tsync tray -> quit
```

## 6. Stats submenu

Filled from `stats` replies, one per answering owner. A reply whose `ok` is not `true` contributes
nothing.

- **Placeholder**, until the first answer: one row `Reading…`.
- **No reply at all**: one row `No daemon answering`.
- The submenu is never empty: some panels do not open an empty submenu.

Per answering owner, a separator before each one after the first:

| row | from reply fields | default |
|---|---|---|
| `<host> — <frontend>` | `server.hostname`, `server.frontend` | `?` |
| `pid <pid> · up <duration>` or `· just started` | `server.pid`, `server.uptimeSeconds` | 0 |
| `cpu <x.x>% · <rss> rss · <heap> heap` | `process.cpuPercentAvg` (already a percentage), `process.rssBytes`, `process.heapBytes` | 0 |
| `up <bytes>[ (<rate>/s)] · down <bytes>[ (<rate>/s)]` | `traffic.bytesUploaded`, `uploadBytesPerSec`, `bytesDownloaded`, `downloadBytesPerSec` | 0 |

The rate is appended only when > 0.

Then per entry of `domains`, each preceded by a separator:

| row | indent | shown when | from |
|---|---|---|---|
| `<name>` or `<name> — read-only, versioned` (either flag alone too) | 0 | always | `name`, `domainReadOnly`, `versioning` |
| the mount point, ellipsised | 1 | some frontend reports one | first `frontends[].mountPoint` |
| `cache <n> chunks · <bytes>[ of <max>][ · <pinned> pinned]` | 1 | chunks and bytes known | `cache.chunks`, `.bytes`, `.maxCache` (> 0), `.pinnedBytes` (> 0) |
| `<n> uploading · <n> downloading · <n> staged` | 1 | any part known | sum over `frontends[]` of `pendingUploads`, `pendingDownloads`, `stagedFiles` |
| `read <bytes> · written <bytes>` | 1 | any part known | sum over `frontends[]` of `bytesRead`, `bytesWritten` |
| `wal <n> pending · <n> stuck` | 1 | either > 0 (each part only when > 0) | `wal.pending`, `wal.stuck` |
| one row per backend | 1 | always | `backends[]` |

Backend row, parts joined with ` · `:

- `<name> (<role>) — <health>`: health is `reachable`, `reachable, <n> ms` (`latencyMs`, rounded),
  `unreachable`, or `unreachable: <error>` (the error ellipsised; only the error is cut, so the
  journal figures after it survive);
- `journal <n> entries`, or `journal <n> entries, <b> behind` when behind > 0 (`journal.entries`,
  `journal.behind`); absent when entries are unknown;
- corruption, from `corrupted`: `corruption check failed` when it has an `error`; `not checked`
  when `checked` is not true; `<n> corrupt — run tsync data-integrity` when checked and `chunks` > 0;
  nothing when checked and clean.

A figure the owner did not report produces no row: a frontend that keeps no counters is not drawn
as one that read nothing.

Worked example (real output):

```
        booky — fuse
        pid 102259 · up 12h 5m
        cpu 1.0% · 739.8 MB rss · 84.3 MB heap
        up 0 B · down 11.6 GB (1.5 MB/s)
        ---
        Jellyfin Media — read-only, versioned
            /home/u/tsync/Jellyfin Media
            cache 1216 chunks · 10.0 GB of 10.0 GB · 2.0 GB pinned
            0 uploading · 2 downloading · 0 staged
            read 515.4 MB · written 0 B
            http-proxy (main) — reachable, 11 ms · journal 402 entries
            cold (replica) — unreachable: connection refused · journal 88 entries, 12 behind
```

## 7. JSON form

For a client that cannot link the model:

```json
{
  "icon": "tsync-sync-symbolic",
  "tooltip": "tsync — Uploading 1 · Downloading 1",
  "rows": [
    { "label": "photos — Uploading 1 · Downloading 1", "enabled": true, "indent": 0,
      "action": { "openFolder": "photos" } },
    { "label": "out.raw", "enabled": true, "indent": 1,
      "action": { "reveal": { "domain": "photos", "rel": "out.raw" } } },
    { "label": "1.1 MB", "enabled": true, "indent": 2, "action": {} },
    { "separator": true },
    { "label": "Stats", "enabled": true, "indent": 0, "action": { "stats": true }, "submenu": true },
    { "label": "Hold changes", "enabled": true, "indent": 0,
      "action": { "setPaused": true }, "checked": false },
    { "label": "Quit tsync menu bar", "enabled": true, "indent": 0, "action": { "quit": true } }
  ],
  "submenuPlaceholder": [
    { "label": "Reading…", "enabled": true, "indent": 0, "action": {} }
  ]
}
```

(abridged from the real output.)

- `checked` and `submenu` are present only when set. A row's `icon` is never sent: it is a
  freedesktop icon name, and the reader of this JSON has no such icons.
- The Linux tray does not use this form.

## 8. Tests

One snapshot suite prints every string the model produces and compares the whole output with a
recorded copy.

**Invariant:** a change to anything a user reads in the menu shows up as a diff to be agreed to.

Cases, each a fixed input:

- two domains, one busy: sort order of file rows; bytes uploaded read once, not summed; both
  formatters;
- nothing answering: no traffic or rate line;
- paused with seven uploads: the overflow row, no rate line at rate zero;
- downloads counted with no rows (below the owner's threshold);
- downloads beside uploads: the domain's count is the number of rows, not the fetch count;
- more downloads than fit: the overflow row belongs to each list on its own;
- no domains;
- the JSON form (the only check of the wire the macOS client reads);
- the stats submenu, full, sparse, and with nothing answering;
- the formatter tables of §3.

**Binding:** every label, the order of rows, separators, icon names, the tooltip, each row's
action and its target, `enabled`, `checked`, `submenu`, the JSON field names and nesting.
**Incidental:** the layout the test prints the rows in, and the snapshot mechanism.

**Doubles:** none. The suite needs no D-Bus, no owner and no mount.
