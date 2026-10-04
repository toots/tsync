# Menu model

The status menu of tsync is one pure function, from what owners report to what a menu shows: an
icon name, a tooltip and a list of rows. It knows nothing of D-Bus, of a toolkit, or of where a
domain's folder is. Every string a user reads in a status menu is produced here, so that the
platforms cannot drift apart.

Two clients draw it: the Linux tray ([linux-tray.md](linux-tray.md)), which evaluates the model
itself, and the macOS menu ([file-provider.md §10](file-provider.md#10-menu-bar)), which receives
its output as JSON (§7) from the owner.

Inputs are the `status` and `stats` replies of the request handler
([08 §3.3](../08-frontends.md#33-actions), [07 §5.5](../07-daemon-cli.md#55-tsync-status)). This
file owns nothing of those replies; it names the fields it reads.

---

## 1. Output

```
menu   = { icon, tooltip, entries }
entry  = Separator | Item
Item   = { label, enabled, icon?, checked?, indent, action, submenu }
action = Nothing | OpenFolder(domain) | Reveal(domain, rel) | SetPaused(bool) | ShowStats | Quit
```

- `indent` is a nesting level (0, 1 or 2). How it is drawn is the renderer's.
- `checked`, when present, makes the row a checkmark row in that state.
- `submenu` marks a row that opens a menu of its own. Its rows are not part of this output; they
  are the stats rows of §6, supplied by whoever fetched them.
- An action MUST name a domain and a path under it, never an absolute path: where a domain's
  folder is differs per client.
- An informational row is `enabled` with action `Nothing`. A disabled row draws grey and reads as
  a broken command.
- `icon` on a row is a generic name of the freedesktop icon naming specification (§3).

## 2. Input: one status per domain

The caller gives the domains in configuration order, each with its name and either a `status`
reply or nothing.

A domain is **unreachable** when there is no reply, or the reply's `ok` is not `true`. Otherwise
the model reads:

| model value | reply field | when absent |
|---|---|---|
| `uploads` | `pendingUploads` (integer) | 0 |
| `downloads` | `pendingDownloads` (integer) | 0 |
| `paused` | `paused` (boolean) | false |
| `uploading` | `uploading`: list of `{name, rel, size?}` | empty |
| `downloading` | `downloading`: list of `{name, rel, bytes?, size?, rate?}` | empty |
| `pendingBytes` | `pendingBytes` (integer) | unknown |
| `sentBytes` | `traffic.upBytes` (integer) | unknown |
| `sendRate` | `traffic.upRate` (number) | unknown |

- A transfer is kept only when both `name` and `rel` are non-empty strings. `bytes` is what has
  moved, `size` the total, `rate` bytes per second; each may be absent.
- A field of another type than the table states is treated as absent. The model MUST NOT fail on
  any reply.
- **Absent is not zero.** An unknown figure produces no text; it is never printed as 0.

Derived per reachable domain:

- **download count**: the number of `downloading` transfers when there are any, else `downloads`.
  A count shown above file rows MUST equal the number of those rows' transfers.
- **transferring**: `uploads` > 0, or the download count > 0, or `downloads` > 0. A domain with a
  download row is transferring even while its fetch count reads 0 between two fetches.

Derived over all domains, **counting reachable domains only**:

- **all unreachable**: no domain is reachable. True for an empty list.
- **all paused**: at least one domain is reachable and every reachable domain is paused. An
  unreachable domain neither holds this back nor satisfies it; its own row says it is not
  answering.
- **pending bytes**, **sent bytes**, **send rate**: each the sum of the known values. A sum over no
  known value is unknown.

Traffic is reported per domain and summed here, so the totals are right whether each domain has
its own process or one process serves them all.

## 3. Formatters

**Bytes.** Units `B`, `KiB`, `MiB`, `GiB`, `TiB`, each 1024 of the previous. Divide while the value is
≥ 1024 and a larger unit exists. Under 1024: the integer and ` B`. Otherwise one decimal place.
The same formatter MUST be used wherever tsync prints a size to a user.

| input | output |
|---|---|
| 0 | `0 B` |
| 999 | `999 B` |
| 1000 | `1000 B` |
| 1500 | `1.5 KiB` |
| 999999 | `976.6 KiB` |
| 223200000 | `212.9 MiB` |
| 1070000000 | `1020.4 MiB` |
| 12800000000 | `11.9 GiB` |
| 2500000000000 | `2.3 TiB` |

**Duration.** Undefined for a negative, not-a-number or > 10¹² input. Truncate to whole seconds;
compute days, hours and minutes; drop the zero ones; keep the first two; join with a space as
`<n>d`, `<n>h`, `<n>m`. Nothing left (under a minute) → undefined.

| seconds | output |
|---|---|
| 0, 45 | undefined |
| 60, 90 | `1m` |
| 3600 | `1h` |
| 8000 | `2h 13m` |
| 86400 | `1d` |
| 90000 | `1d 1h` |
| 180000 | `2d 2h` |

**Time left**, for a remaining byte count and a rate > 0: `<duration> left`, or
`under a minute left` when the duration of remaining / rate is undefined. An estimate is never
shown as zero while bytes are still owed.

**Ellipsis.** A text of at most `LABEL_MAX` bytes is kept. Otherwise: start at byte `LABEL_MAX`,
step back while that byte is a UTF-8 continuation byte; if a space exists before that point at an
index above `LABEL_MAX / 2`, cut at that space, else cut at that point; append `…`. The result is
valid UTF-8 whenever the input is.

**File icon**, from the lower-cased extension of the transfer's `name` (the full name, never a
label that was shortened):

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

Only generic names are used: a specific name that a theme lacks draws nothing.

## 4. Icon and tooltip

**Icon**, first match:

1. all unreachable (including no domains) → `tsync-error-symbolic`
2. all paused → `tsync-paused-symbolic`
3. any domain transferring → `tsync-sync-symbolic`
4. else → `tsync-idle-symbolic`

**Summary**, first match:

1. no domains → `No domains configured`
2. all unreachable → `Daemon not running`
3. with U = the sum of `uploads` and D = the sum of download counts, over reachable domains:
   - U = 0 and D = 0 → `Paused` when all paused, else `Idle`
   - else join with ` · `: `Uploading U` (when U > 0), `Downloading D` (when D > 0), `paused`
     (when all paused)

**Tooltip**: `tsync — <summary>`.

## 5. Rows

In order:

1. **Header**, only when there are no domains: `tsync — <summary>`.
2. **Per domain**, in input order:
   - the domain row: `<name> — <detail>`, action `OpenFolder(name)`. `<detail>` is, first match:
     `not answering` (unreachable); `Paused` (paused, nothing moving); `Idle` (nothing moving);
     else `Uploading U`, `Downloading D` or `Uploading U · Downloading D` from this domain's own
     counts, followed by ` · paused` when the domain is paused;
   - its upload file rows, then its download file rows (below).
3. **Traffic**, when shown: a separator, the traffic line, then the rate line when there is one.
   - The section, separator included, is absent when it has neither line.
   - Traffic line: nothing when sent bytes is unknown; nothing when it is 0 and pending bytes is
     unknown or ≤ 0; `<sent> sent` when pending bytes is unknown or ≤ 0; else
     `<sent> sent · <pending> to go`.
   - Rate line, only when pending bytes > 0 and the send rate > 0: `<rate>/s · <time left>` for
     pending bytes at the send rate.
4. A separator.
5. **Stats**: label `Stats`, action `ShowStats`, `submenu`.
6. **Hold changes**: label `Hold changes`; `checked` = all paused; `enabled` unless all
   unreachable; action `SetPaused(not all paused)`. The action applies to every domain that
   answers ([07 §2.6](../07-daemon-cli.md#26-pause) says what a pause holds).
7. **Quit**, only when the caller gives a quit label: a separator, then a row with that label and
   action `Quit`. The label names the icon, not tsync: quitting removes the icon and leaves the
   owners running. The Linux tray passes `Quit tsync tray`; a client whose process must keep
   running passes none.

**File rows**, for one list (uploads or downloads) of one domain:

- sort the transfers by `name`, bytewise;
- for each of the first `FILE_ROWS`: a row at indent 1, label the ellipsised `name`, icon the file
  icon, action `Reveal(domain, rel)`; then, when it has any figure, a progress row at indent 2;
- when there are more: a row at indent 1, `… and N more`, N the number not shown.

**Progress row**, parts joined with ` · `, in order, each only when known:

- `<moved> of <total>`, or `<moved>` alone, or `<total>` alone;
- `<rate>/s` when the rate > 0;
- the time left for total − moved at the rate, when moved, total and a rate > 0 are known and
  total > moved.

Worked example. Input: one domain `photos`, `pendingUploads` 1, `pendingDownloads` 9, one upload
`out.raw` with no figures, downloads `holiday.mov` (rel `trips/holiday.mov`, 788529152 of
15589124313 at 1600000 B/s) and `notes.pdf` (240000 of 900000, no rate), `traffic.upBytes` 1000,
`pendingBytes` 0, quit label `Quit tsync tray`. `-> …` is the action, `(…)` the icon:

```
icon    tsync-sync-symbolic
tooltip tsync — Uploading 1 · Downloading 2
        photos — Uploading 1 · Downloading 2 -> open photos
            out.raw (image-x-generic) -> reveal photos:out.raw
            holiday.mov (video-x-generic) -> reveal photos:trips/holiday.mov
                752.0 MiB of 14.5 GiB · 1.5 MiB/s · 2h 34m left
            notes.pdf (x-office-document) -> reveal photos:notes.pdf
                234.4 KiB of 878.9 KiB
        ---
        1000 B sent
        ---
        Stats >
        [ ] Hold changes -> pause true
        ---
        Quit tsync tray -> quit
```

Nothing answering, and no domains:

```
icon    tsync-error-symbolic
tooltip tsync — Daemon not running
        photos — not answering -> open photos
        ---
        Stats >
        [ ] Hold changes (disabled)
        ---
        Quit tsync tray -> quit

icon    tsync-error-symbolic
tooltip tsync — No domains configured
        tsync — No domains configured
        ---
        Stats >
        [ ] Hold changes (disabled)
        ---
        Quit tsync tray -> quit
```

Two domains, one of them down, the other paused with two files queued: the switch reads checked
and the click would resume.

```
icon    tsync-paused-symbolic
tooltip tsync — Uploading 2 · paused
        photos — Uploading 2 · paused -> open photos
        music — not answering -> open music
        ---
        Stats >
        [x] Hold changes -> pause false
        ---
        Quit tsync tray -> quit
```

## 6. Stats submenu

A second pure function, from the `stats` replies of the owners that answered to the rows of the
Stats submenu. A reply whose `ok` is not `true` contributes nothing. A reply describes the process
that answered under `self` and the domains it owns under `domains`
([07 §5.5](../07-daemon-cli.md#55-tsync-status)); a domain it lists as `unanswered` contributes
nothing.

- **Placeholder**, shown until the first answer: one row `Reading…`.
- **No reply at all**: one row `No daemon answering`.
- The submenu MUST never be empty: some panels do not open an empty submenu.
- Every row is an informational row (§1).
- A figure the owner did not report produces no row, or no part of a row: a frontend that keeps no
  counters is not drawn as one that read nothing.

Per answering process, a separator before each one after the first:

| row | from | when a field is absent |
|---|---|---|
| `<host> — <role>` | `self.server.hostname`, `self.server.role` | `?` |
| `pid <pid> · up <duration>`, or `pid <pid> · just started` when the duration is undefined | `self.server.pid`, `self.server.uptimeSeconds` | the row is omitted without a pid; the second part without an uptime |
| `cpu <x.x>% · <rss> rss · <heap> heap` | `self.process.cpuPercentAvg` (already a percentage), `self.process.rssBytes`, `self.process.heapBytes` | that part is omitted |
| `up <bytes>[ (<rate>/s)] · down <bytes>[ (<rate>/s)]` | `self.traffic.upBytes`, `upRate`, `downBytes`, `downRate` | that part is omitted; a rate is appended only when > 0 |

Then per domain body of that reply, each preceded by a separator:

| row | indent | shown when | from |
|---|---|---|---|
| `<name>`, `<name> — read-only`, `<name> — versioned` or `<name> — read-only, versioned` | 0 | always | the body's `name`, `settings.readOnly`, `settings.versioning` |
| the mount point, ellipsised | 1 | some frontend reports one | the first `frontends[].mount` |
| `cache <n> chunks · <bytes>[ of <max>][ · <pinned> pinned]` | 1 | chunks and bytes known | `cache.chunks`, `.bytes`, `.maxCache` (> 0), `.pinnedBytes` (> 0) |
| `queue <n> files · <bytes> owed` | 1 | either known | `queues.pendingFiles`, `queues.bytesOwed` |
| `read <bytes> · written <bytes>` | 1 | either known | the sums over `frontends[]` of `bytesRead`, `bytesWritten` |
| `wal <n> pending · <n> stuck` | 1 | either > 0 (each part only when > 0) | pending is the sum of `wal.intent`, `wal.prepared` and `wal.executed`; `wal.stuck` |
| one row per backend | 1 | always | `backends[]` |

Backend row, parts joined with ` · `:

- `<name> (<role>) — <health>`, from the backend's `reach`: health is `reachable`,
  `reachable, <n> ms` (`reach.latencyMs`, rounded), `unreachable`, or `unreachable: <error>`
  (`reach.error`, when not empty). Only the error is ellipsised, so the figures after it survive.
  With no `reach`, the row is `<name> (<role>)`;
- the journal: `journal <n> entries`, or `journal <n> entries, <b> behind` when behind > 0
  (`journal.entries`, `journal.behind`); `journal counting` when the reply says `counting`; absent
  otherwise;
- corruption, from `corrupted`: `not checked` when `checked` is not true;
  `<n> corrupt — run tsync data-integrity` when checked and `chunks` > 0; nothing when checked and
  clean, or when the backend carries no `corrupted`.

Worked example:

```
        box — owner
        pid 102259 · up 12h 5m
        cpu 1.0% · 739.8 MiB rss · 84.3 MiB heap
        up 0 B · down 11.6 GiB (1.5 MiB/s)
        ---
        Media — read-only, versioned
            /home/u/tsync/Media
            cache 1216 chunks · 10.0 GiB of 10.0 GiB · 2.0 GiB pinned
            queue 0 files · 0 B owed
            read 515.4 MiB · written 5 B
            wal 3 pending · 1 stuck
            http-proxy (main) — reachable, 11 ms · journal 402 entries
            cold (replica) — unreachable: connection refused · journal 88 entries, 12 behind · 3 corrupt — run tsync data-integrity
            far (backfill) — unreachable · not checked
```

## 7. JSON form

For a client that cannot evaluate the model. The menu:

```json
{
  "icon": "tsync-sync-symbolic",
  "tooltip": "tsync — Uploading 1 · Downloading 1",
  "entries": [
    { "label": "photos — Uploading 1 · Downloading 1", "enabled": true, "indent": 0,
      "action": { "openFolder": "photos" } },
    { "label": "out.raw", "enabled": true, "indent": 1,
      "action": { "reveal": { "domain": "photos", "rel": "out.raw" } } },
    { "label": "1.1 MiB", "enabled": true, "indent": 2, "action": {} },
    { "separator": true },
    { "label": "Stats", "enabled": true, "indent": 0, "action": { "stats": true }, "submenu": true },
    { "label": "Hold changes", "enabled": true, "indent": 0,
      "action": { "setPaused": true }, "checked": false }
  ]
}
```

- An entry is `{"separator": true}` or an item with `label`, `enabled`, `indent` and `action`.
- `action` is an object with at most one key: `{}` (Nothing), `{"openFolder": <domain>}`,
  `{"reveal": {"domain", "rel"}}`, `{"setPaused": <bool>}`, `{"stats": true}`, `{"quit": true}`.
- `checked` and `submenu` are present only when set.
- A row's `icon` is not sent: it is a freedesktop name, and a reader of this form has no such
  icons. A reader that draws a file icon MUST derive it from the action's `rel`, never from the
  label, which may have been shortened.
- The stats rows are served apart, as a list of the same entries. Until they arrive, a reader
  shows the placeholder of §6, spelled as §6 spells it.
- A reader MUST ignore keys it does not know.

## 8. Conformance

One suite renders fixed inputs and compares everything a user reads.

**Invariant.** A change to anything a user reads in a status menu shows up as a difference that
someone agrees to; and both functions are total.

**Cases the suite MUST include:**

- two domains, one busy: file rows sorted; traffic and rate summed over both domains;
- one domain reporting 5 MiB sent at 1 MiB/s and another 3 MiB at 2 MiB/s with pending bytes in each:
  the line reads the sum sent, and the time left is total pending over the summed rate;
- nothing answering: no traffic or rate line, the switch disabled;
- one domain paused and one unreachable: the switch checked, the paused icon, the unreachable
  row `not answering`;
- two reachable domains, one paused: the switch unchecked, the paused domain's own row says so;
- paused with more uploads than `FILE_ROWS`: the overflow row, no rate line at rate zero;
- a fetch count of nine above two download rows, then of zero above one row: the number equals
  the rows, and the icon shows activity;
- more downloads than fit beside uploads: each list has its own overflow row;
- figures absent against figures zero: an absent figure yields no text;
- a name longer than `LABEL_MAX` with a known extension: the label is cut on a character
  boundary and the icon is that of the real extension;
- no domains; with and without a quit label;
- the JSON form of a menu containing every kind of entry and action;
- the stats rows: full, sparse, a journal still counting, nothing answering;
- the formatter tables of §3;
- replies with fields of the wrong type, and an empty object: no failure.

**Binding:** every label, the order of rows, separators, icon names, the tooltip, each row's
action and its target, `enabled`, `checked`, `submenu`, and the JSON key names and nesting.
**Incidental:** how the suite prints the rows, and how it records the expected output.

**Doubles:** none. The suite needs no bus, no owner and no mount.

## 9. Parameters

| name | recommended | protects |
|---|---|---|
| `FILE_ROWS` | 5 | the menu from being pushed off the screen by a long transfer list |
| `LABEL_MAX` | 64 bytes | the menu's width from one long file name |
