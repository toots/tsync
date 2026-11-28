# Menu model

The status menu of tsync is one pure function, from what owners report to what a menu shows: an
icon name, a tooltip and a list of rows. It knows nothing of D-Bus, of a toolkit, or of where a
domain's folder is. Every string a user reads in a status menu is produced here, so that the
platforms cannot drift apart.

Three clients draw it: the Linux tray ([linux-tray.md](linux-tray.md)) and the Windows tray
([cloud-files.md §15](cloud-files.md#15-tray)), which evaluate the model themselves, and the macOS menu ([file-provider.md §10](file-provider.md#10-menu-bar)), which receives
its output as JSON (§8) from the owner.

Inputs are the `status`, `stats`, `totp_list` and `passwords_list` replies of the request handler
([08 §3.3](../08-frontends.md#33-actions), [07 §5.5](../07-daemon-cli.md#55-tsync-status),
[totp §5](../extensions/totp.md#5-commands)). This file owns nothing of those replies; it names
the fields it reads.

---

## 1. Output

```
menu   = { icon, tooltip, entries }
entry  = Separator | Item
Item   = { label, enabled, icon?, checked?, indent, action, submenu }
action = Nothing | OpenFolder(domain) | Reveal(domain, rel) | SetPaused(bool) | ShowStats
       | ShowCodes | CopyCode(domain, id) | Unlock(domain)
       | ShowPasswords | CopyPassword(domain, id)
       | SeenMachines(domain) | CopyReport | Quit
```

- `indent` is a nesting level (0, 1 or 2). How it is drawn is the renderer's.
- `checked`, when present, makes the row a checkmark row in that state.
- `submenu` marks a row that opens a menu of its own. Its rows are not part of this output; they
  are the stats rows of §6 or the codes rows of §7, supplied by whoever fetched them.
- An action MUST name a domain and a path under it, never an absolute path: where a domain's
  folder is differs per client.
- An informational row is `enabled` with action `Nothing`. A disabled row draws grey and reads as
  a broken command.
- `icon` on a row is a generic name of the freedesktop icon naming specification (§3).
- `SeenMachines(domain)` sends that domain's `vault_machines`, which acknowledges every machine
  it lists ([vault §6.3](../extensions/vault.md#63-machines)); the next poll drops their rows.
- `CopyReport` puts the `status` and `stats` replies the client last received on the clipboard,
  as indented JSON, for a bug report. No row ever shows that JSON.

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
| `readOnly` | `readOnly` (boolean) | false |
| `uploading` | `uploading`: list of `{name, rel, size?}` | empty |
| `downloading` | `downloading`: list of `{name, rel, bytes?, size?, rate?}` | empty |
| `pendingBytes` | `pendingBytes` (integer) | unknown |
| `failing` | `failing` (string): the domain's sync fails | not failing |
| `sentBytes` | `traffic.upBytes` (integer) | unknown |
| `sendRate` | `traffic.upRate` (number) | unknown |
| `newMachines` | `newMachines`: list of strings, the machines that joined the domain's vault ([vault §6.3](../extensions/vault.md#63-machines)) | empty |
| `mount` | `mount` (string): where the domain's files are on this machine | unknown |
| `extensions` | `extensions`: list of strings, the extensions in force | empty |

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

**Progress bar**, for `moved` of `total` with total > 0: `BAR_CELLS` characters, the first
⌊`BAR_CELLS` × moved / total⌋ of them `▰` (at most `BAR_CELLS`) and the rest `▱`, then a space and
the integer percentage ⌊100 × moved / total⌋, at most 100, and `%`. It is text because a menu
row can draw nothing else on every platform.

| moved / total | output |
|---|---|
| 0 / 100 | `▱▱▱▱▱▱▱▱▱▱ 0%` |
| 788529152 / 15589124313 | `▱▱▱▱▱▱▱▱▱▱ 5%` |
| 240000 / 900000 | `▰▰▱▱▱▱▱▱▱▱ 26%` |
| 100 / 100 | `▰▰▰▰▰▰▰▰▰▰ 100%` |

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

1. all unreachable (including no domains), or any domain failing → `tsync-error-symbolic`. Here and
   in the summary a paused domain is not failing: its row reads `Paused` (§5), and the icon and the
   summary never report a failure no row explains
2. all paused → `tsync-paused-symbolic`
3. any domain transferring → `tsync-sync-symbolic`
4. else → `tsync-idle-symbolic`

**Summary**, first match:

1. no domains → `No domains configured`
2. all unreachable → `Daemon not running`
3. any domain failing → `Not syncing`
4. all paused → `Paused`
5. with U = the sum of `uploads` and D = the sum of download counts, over reachable domains:
   - U = 0 and D = 0 → `Up to date`
   - else `Syncing: <waiting>`, `<waiting>` being `U to upload` (when U > 0) and `D to download`
     (when D > 0), joined with `, `

**Tooltip**: `tsync — <summary>`.

## 5. Rows

In order:

1. **Header**, only when there are no domains: `tsync — <summary>`.
2. **Per domain**, in input order:
   - the domain row: `<name> — <state>`, action `OpenFolder(name)`;
   - when the domain answers and the row says more than `Files`, its **contents** row at indent 1,
     action `Nothing`: what the domain holds, then ` · ` and the ellipsised `mount` when it is
     known. What it holds is `Files`,
     followed by the words of the extensions it knows, in this order, joined as an English list
     (`Files and passwords`, `Files, passwords and one-time codes`): `passwords` for `passwords`,
     `one-time codes` for `totp`, and `an encrypted vault` for `vault` when neither of the other
     two is in force. An extension it does not know adds nothing;
   - when the state has a sentence, a row at indent 1 with it, action `Nothing`. The states are those of the mobile
     apps ([activity.md §2.1](activity.md#21-state)), first match:

     | state | when | sentence |
     |---|---|---|
     | `Not answering` | unreachable | — |
     | `Paused` | `paused` | `Changes stay on this machine and downloads wait until you resume.` |
     | `Not syncing` | `failing` | `<failing>. Retried until it works.` |
     | `Read-only` | `readOnly` | `This domain can't be changed from this machine.` |
     | `Syncing` | transferring | `<waiting>` (§4) from this domain's own counts |
     | `Up to date` | otherwise | — |

     A state says what the domain is doing in a user's words; the sentence says what that means
     for them. A cause the owner reports is shown, never reduced to a word;
   - for each name in its `newMachines`, in order, a row at indent 1
     `<name> can now unlock this vault`, icon `computer`, action `Nothing`; then, when there is
     any, one row at indent 1 `Mark as seen`, action `SeenMachines(name)`. They show until the
     machines are listed, by that row or by `tsync vault machines`;
   - when its `vaultBackupOverdue`, a row at indent 1 `The vault's backup is overdue`, icon
     `dialog-warning`, action `Nothing` ([vault §8.3](../extensions/vault.md#83-scheduled-backups));
   - its upload file rows, then its download file rows (below).
3. **Traffic**, when shown: a separator, the traffic line, then the rate line when there is one.
   - The section, separator included, is absent when it has neither line.
   - Traffic line: nothing when sent bytes is unknown; nothing when it is 0 and pending bytes is
     unknown or ≤ 0; `<sent> sent` when pending bytes is unknown or ≤ 0; else
     `<sent> sent · <pending> to go`.
   - Rate line, only when pending bytes > 0 and the send rate > 0: `<rate>/s · <time left>` for
     pending bytes at the send rate.
4. A separator.
5. **Details**: label `Details`, action `ShowStats`, `submenu`.
   **One-time codes**, only when the caller gives a non-empty list of **code domains** (the
   domains that use `totp`, [extensions README §3](../extensions/README.md#3-opting-in), and whose codes this
   client can copy): label
   `One-time codes`, action `ShowCodes`, `submenu`.
   **Passwords**, only when the caller gives a non-empty list of **password domains** (the domains
   that use `passwords`, and whose passwords this client can copy): label `Passwords`, action
   `ShowPasswords`, `submenu`.
6. **Pause syncing**: label `Pause syncing`; `checked` = all paused; `enabled` unless all
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

- the progress bar (§3), when moved and a total > 0 are known;
- `<moved> of <total>`, or `<moved>` alone, or `<total>` alone;
- `<rate>/s` when the rate > 0;
- the time left for total − moved at the rate, when moved, total and a rate > 0 are known and
  total > moved.

Worked example. Input: one domain `photos`, `pendingUploads` 1, `pendingDownloads` 9, one upload
`out.raw` with no figures, downloads `holiday.mov` (rel `trips/holiday.mov`, 788529152 of
15589124313 at 1600000 B/s) and `notes.pdf` (240000 of 900000, no rate), `mount`
`/home/u/tsync/photos`, `extensions` `["vault", "passwords"]`, `newMachines` `["Pixel 8"]`,
`traffic.upBytes` 1000, `pendingBytes` 0, quit label `Quit tsync tray`. `-> …` is the action,
`(…)` the icon:

```
icon    tsync-sync-symbolic
tooltip tsync — Syncing: 1 to upload, 2 to download
        photos — Syncing -> open photos
            Files and passwords · /home/u/tsync/photos
            1 to upload, 2 to download
            Pixel 8 can now unlock this vault (computer)
            Mark as seen -> seen photos
            out.raw (image-x-generic) -> reveal photos:out.raw
            holiday.mov (video-x-generic) -> reveal photos:trips/holiday.mov
                ▱▱▱▱▱▱▱▱▱▱ 5% · 752.0 MiB of 14.5 GiB · 1.5 MiB/s · 2h 34m left
            notes.pdf (x-office-document) -> reveal photos:notes.pdf
                ▰▰▱▱▱▱▱▱▱▱ 26% · 234.4 KiB of 878.9 KiB
        ---
        1000 B sent
        ---
        Details >
        [ ] Pause syncing -> pause true
        ---
        Quit tsync tray -> quit
```

Nothing answering, and no domains:

```
icon    tsync-error-symbolic
tooltip tsync — Daemon not running
        photos — Not answering -> open photos
        ---
        Details >
        [ ] Pause syncing (disabled)
        ---
        Quit tsync tray -> quit

icon    tsync-error-symbolic
tooltip tsync — No domains configured
        tsync — No domains configured
        ---
        Details >
        [ ] Pause syncing (disabled)
        ---
        Quit tsync tray -> quit
```

Two domains, one of them down, the other paused with two files queued: the switch reads checked
and the click would resume.

```
icon    tsync-paused-symbolic
tooltip tsync — Paused
        photos — Paused -> open photos
            Changes stay on this machine and downloads wait until you resume.
        music — Not answering -> open music
        ---
        Details >
        [x] Pause syncing -> pause false
        ---
        Quit tsync tray -> quit
```

## 6. Details submenu

A second pure function, from the `stats` replies of the owners that answered to the rows of the
Details submenu. It says what each store and the cache are doing in a user's words, as the mobile
Activity screen does ([activity.md §2.3–2.5](activity.md#23-problems)); a process's own figures
(pid, cpu, heap, chunk counts) are for a bug report, and reach one only through `CopyReport`.

A reply whose `ok` is not `true` contributes nothing. A reply describes the process that answered
under `self` and the domains it owns under `domains`
([07 §5.5](../07-daemon-cli.md#55-tsync-status)); a domain it lists as `unanswered` contributes
nothing.

- **Placeholder**, shown until the first answer: one row `Reading…`.
- **No reply at all**: one row `No daemon answering`.
- **Replies with nothing to show**: one row `Nothing reported`, before Copy report.
- The submenu MUST never be empty: some panels do not open an empty submenu.
- Every row is an informational row (§1), but `Copy report`.
- A figure the owner did not report produces no row, or no part of a row: a frontend that keeps no
  counters is not drawn as one that read nothing.
- A count *n* is followed by its noun in the singular when *n* is 1, else in the plural.

**Per domain**, over every reply in order and each reply's domains in order, a separator before
each one after the first:

| row | indent | shown when | from |
|---|---|---|---|
| `<name>`, or `<name> — <traits>`, the traits `read-only` and `keeps versions` joined with `, ` | 0 | always | the body's `name`, `settings.readOnly`, `settings.versioning` |
| `Cache: <bytes>[ of <max>][, <pinned> kept offline]` | 1 | bytes known | `cache.bytes`, `.maxCache` (> 0), `.pinnedBytes` (> 0) |
| `To upload: <n> files[, <bytes>]` | 1 | the count > 0 | `queues.pendingFiles`, `queues.bytesOwed` |
| `<n> uploads waiting to be retried` | 1 | the count > 0 | `queues.parked` |
| `<n> changes to apply` | 1 | the count > 0 | `sync.pending` |
| `Can't follow change <n>` | 1 | an entry cannot be followed | `sync.cannotFollow.entry` |
| one row per backend | 1 | always | `backends[]` |

Backend row: `<name> (<role>): <connection>`, then ` · <damage>` when there is one.

- `<role>` is the backend's `role`, `readOnly` read as `read-only`; `?` when absent, as is a name.
- `<connection>`, from `reach`: `connected`, `connected, <n> ms` (`reach.latencyMs`, rounded),
  `unreachable`, or `unreachable: <error>` (`reach.error` when not empty, ellipsised). With no
  `reach`, the row is `<name> (<role>)`.
- `<damage>`, from `corrupted`, only when `checked` is true and `chunks` > 0:
  `<n> damaged chunks — run tsync data-integrity`. A store not checked says nothing.

**This device**, after the domains: a separator, then

- per reply, in order, `Service for <names>: running <duration>`, `<names>` the reply's domain
  names joined with `, ` (`Service: …` when it lists none); `running` and the duration from `self.server.uptimeSeconds`, or
  `just started` when it is undefined; then ` · <rss> memory` from `self.process.rssBytes`. With
  neither figure there is no row; with one, the row has that part alone;
- one traffic row, `Sent <bytes>[ (<rate>/s)] · received <bytes>[ (<rate>/s)]`, each the sum of
  the known `self.traffic` values (`upBytes`, `upRate`, `downBytes`, `downRate`) over the replies;
  a part is omitted when none is known, a rate appended only when > 0, and no row with neither part.

The section, separator included, is absent when it has no row.

**Copy report**, only when the caller asks for it: a separator and a row `Copy report`, action
`CopyReport`. The Linux and Windows trays ask for it; the macOS owner renders none.

Worked example:

```
        Media — read-only, keeps versions
            Cache: 10.0 GiB of 10.0 GiB, 2.0 GiB kept offline
            To upload: 1 file, 4.0 KiB
            1 upload waiting to be retried
            3 changes to apply
            http-proxy (main): connected, 11 ms
            cold (replica): unreachable: connection refused · 3 damaged chunks — run tsync data-integrity
            far (backfill): unreachable
        ---
        Service for Media: running 12h 5m · 739.8 MiB memory
        Sent 0 B · received 11.6 GiB (1.5 MiB/s)
        ---
        Copy report -> copy report
```

## 7. Codes submenu

A third pure function, from one `totp_list` reply (or failure) per code domain, in configuration
order, to the rows of the One-time codes submenu. It never shows a code: a row names a record,
and its action makes the client ask the owner for the current code when it is clicked, so a code
is never drawn stale and never travels in a menu.

- **Placeholder**, shown until the replies arrive: one row `Reading…`.
- **Per domain**, a header row `<domain>` (informational, `vault` naming the domain, which a
  client marks with the vault's appearance, [vault §8.1](../extensions/vault.md#81-appearance)) when
  there is more than one code domain, then, first match:
  - a reply refused `locked`: a row `Locked — unlock…`, action `Unlock(domain)`;
  - a reply refused `not_found` (no vault): a row `No vault — run tsync vault init` (informational);
  - another failure or no reply: a row `not answering` (informational);
  - a reply with no record: a row `No codes` (informational);
  - else one row per record, in the reply's order, label `<issuer> — <account>`, or the one that
    is not empty, ellipsised to `LABEL_MAX`; action `CopyCode(domain, id)`.
- Records the reply lists as `corrupt` add one informational row
  `<n> unreadable — run tsync totp list`.
- Rows sit at indent 1 under a header, else 0. The submenu MUST never be empty.

Worked example, two code domains, one locked:

```
        work
            ACME Co — john@example.com -> copy work:3f2a…
            GitHub — me -> copy work:9c1e…
        home
            Locked — unlock… -> unlock home
```

### 7.1 Passwords submenu

A fourth pure function, from one `passwords_list` reply (or failure) per password domain, in
configuration order, to the rows of the Passwords submenu. As with codes, no row carries a
password: a row names a login, and `CopyPassword` makes the client ask the owner `passwords_get`
for that one record when it is clicked, and copy its `password` under the rules of a code
([security-model §10.6](../algorithms/security-model.md#106-vault-keys-and-passphrases)): onto
the clipboard marked sensitive, never logged, never kept.

- **Placeholder**, shown until the replies arrive: one row `Reading…`.
- **Per domain**, a header row `<domain>` (informational, `vault` naming the domain) when there is
  more than one password domain, then, first match:
  - a reply refused `locked`: a row `Locked — unlock…`, action `Unlock(domain)`;
  - a reply refused `not_found` (no vault): a row `No vault — run tsync vault init` (informational);
  - another failure or no reply: a row `not answering` (informational);
  - a reply with no login: a row `No passwords` (informational);
  - else one row per record of `kind` `login`, in the reply's order, label `<title> — <username>`,
    or the one that is not empty, ellipsised to `LABEL_MAX`; action `CopyPassword(domain, id)`.
    Notes and passkeys have no row: neither has a password.
- Rows sit at indent 1 under a header, else 0. The submenu MUST never be empty.

```
        work
            GitHub — me -> copy password work:51c0…
            Bank -> copy password work:77e2…
        home
            Locked — unlock… -> unlock home
```

## 8. JSON form

For a client that cannot evaluate the model. The menu:

```json
{
  "icon": "tsync-sync-symbolic",
  "tooltip": "tsync — Syncing: 1 to upload, 1 to download",
  "entries": [
    { "label": "photos — Syncing", "enabled": true, "indent": 0,
      "action": { "openFolder": "photos" } },
    { "label": "Files and passwords", "enabled": true, "indent": 1, "action": {} },
    { "label": "1 to upload, 1 to download", "enabled": true, "indent": 1, "action": {} },
    { "label": "out.raw", "enabled": true, "indent": 1,
      "action": { "reveal": { "domain": "photos", "rel": "out.raw" } } },
    { "label": "1.1 MiB", "enabled": true, "indent": 2, "action": {} },
    { "separator": true },
    { "label": "Details", "enabled": true, "indent": 0, "action": { "stats": true }, "submenu": true },
    { "label": "Pause syncing", "enabled": true, "indent": 0,
      "action": { "setPaused": true }, "checked": false }
  ]
}
```

- An entry is `{"separator": true}` or an item with `label`, `enabled`, `indent` and `action`.
- `action` is an object with at most one key: `{}` (Nothing), `{"openFolder": <domain>}`,
  `{"reveal": {"domain", "rel"}}`, `{"setPaused": <bool>}`, `{"stats": true}`,
  `{"codes": true}`, `{"copyCode": {"domain", "id"}}`, `{"unlock": <domain>}`,
  `{"seenMachines": <domain>}`, `{"copyReport": true}`, `{"passwords": true}`,
  `{"copyPassword": {"domain", "id"}}`, `{"quit": true}`.
- `checked` and `submenu` are present only when set.
- A row's `icon` is not sent: it is a freedesktop name, and a reader of this form has no such
  icons. A reader that draws a file icon MUST derive it from the action's `rel`, never from the
  label, which may have been shortened.
- The stats rows and the codes rows are served apart, each as a list of the same entries. Until
  they arrive, a reader shows the placeholder of §6 or §7, spelled as they spell it.
- A reader MUST ignore keys it does not know.

## 9. Conformance

One suite renders fixed inputs and compares everything a user reads.

**Invariant.** A change to anything a user reads in a status menu shows up as a difference that
someone agrees to; and both functions are total.

**Cases the suite MUST include:**

- two domains, one busy: file rows sorted; traffic and rate summed over both domains;
- one domain reporting 5 MiB sent at 1 MiB/s and another 3 MiB at 2 MiB/s with pending bytes in each:
  the line reads the sum sent, and the time left is total pending over the summed rate;
- nothing answering: no traffic or rate line, the switch disabled;
- one domain paused and one unreachable: the switch checked, the paused icon, the unreachable
  row `Not answering`;
- one domain failing with pending uploads beside one uploading: the error icon, `Not syncing` in
  the tooltip and on the failing domain's row with its reason beneath, the other domain's own count on its row;
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
- a domain's contents row: no extension and no mount (no row), each known extension alone and
  together, `vault` alone, an unknown extension, with and without a mount; a new machine with its Mark as seen row;
- the passwords rows: one domain and two; locked, no vault, not answering, no logins; notes and
  passkeys left out; a label longer than `LABEL_MAX`; no row of any menu carries a password; no
  password domain gives no `Passwords` row;
- the details rows: full, sparse, an entry that cannot be followed, counts of one, two replies,
  a reply with nothing to show, nothing answering; with and without Copy report; no row carries a pid, a cpu figure or a
  chunk count;
- the codes rows: one domain and two; locked, no vault, not answering, no codes, unreadable;
  records, a label longer than `LABEL_MAX`;
  no code domain gives no `One-time codes` row; no row
  of any menu carries a code;
- the formatter tables of §3, the progress bar's included;
- replies with fields of the wrong type, and an empty object: no failure.

**Binding:** every label, the order of rows, separators, icon names, the tooltip, each row's
action and its target, `enabled`, `checked`, `submenu`, and the JSON key names and nesting.
**Incidental:** how the suite prints the rows, and how it records the expected output.

**Doubles:** none. The suite needs no bus, no owner and no mount.

## 10. Parameters

| name | recommended | protects |
|---|---|---|
| `FILE_ROWS` | 5 | the menu from being pushed off the screen by a long transfer list |
| `LABEL_MAX` | 64 bytes | the menu's width from one long file name |
| `BAR_CELLS` | 10 | a progress row from being wider than its file's name |
