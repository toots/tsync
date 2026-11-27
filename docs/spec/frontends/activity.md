# The Activity screen

Scope: the Activity destination of the Android and iOS apps, and the panel of the macOS status
item: what the app is doing and what went wrong, per domain, as a screen of its own and not as
text. [android-app §10.5](android-app.md#105-activity), [ios-app §2.1](ios-app.md#21-activity)
and [file-provider §10](file-provider.md#10-menu-bar) say what differs on each platform.

## 1. Sources

While the screen is visible, every `status_poll`, and not at all otherwise, the app asks the domain
it shows (§2) for two replies through the owner, and builds every element below from their fields:

- `status`: `paused`, `readOnly`, `failing`, `uploading[]` and `downloading[]` (`name`, `rel`,
  `bytes`, `size`, `rate`), `pendingUploads`, `pendingDownloads`, `pendingBytes`, `newMachines`.
- `stats` (`arg: frontend`): the domain's body (`sync`, `setAside`, `mainOffline`, `cache`, `queues`,
  `backends[]`, `settings`) and the process's `self` (`recentErrors`, `process`).

The app parses both and shows no JSON and no text report. A field it does not know is ignored; a
field missing or of another type is a row not shown, never a domain that did not answer. A `stats`
reply that does not list the domain, or lists it as unanswered, is a domain that did not answer
(§4). Sizes, rates, durations, counts and times are formatted by the platform for the user's
locale; times as relative ("2 min ago").

The screen holds still between answers:

- A failed answer leaves the last one on screen until `stale_after` has passed since it; only then
  is the domain not answering (§4).
- Transfer rates, store latencies and copy rates show an average, each new answer weighing
  `smoothing` against the value shown, matched by file or store name; a new name shows its raw value.
- Rows keep their place by name, not by position in the reply.

## 2. One domain

The screen shows one domain at a time. With more than one listed, a segmented picker of their names
sits at the top; the choice is kept across visits, and a domain no longer listed falls back to the
first. Under it, top to bottom:

### 2.1 State

A badge and one sentence, the first that holds:

| Badge | When | Sentence |
|---|---|---|
| Paused | `paused` | Changes stay on this device until you resume. |
| Not syncing | `failing`, or `sync.cannotFollow` | the reason, and "retried until it works" (`cannotFollow`: "can't follow change *n*: *reason*") |
| Store offline | `mainOffline` | Opening files and uploading wait for the main store. |
| Read-only | `readOnly` | This domain can't be changed from this device. |
| Syncing | uploads or downloads pending, or `sync.pending` > 0 | *n* to upload, *m* to download |
| Up to date | otherwise | — |

The badge is coloured: neutral for Up to date and Syncing, amber for Paused, Read-only and Store
offline, red for Not syncing. **Pause** or **Resume** (`pause`) sits beside it.

### 2.2 Transfers

- **Uploading**: each file of `uploading[]` by name, with a progress bar when its size is known and
  its rate; then "*n* more waiting, *size* to send" from `pendingUploads` and `pendingBytes`.
- **Downloading**: each of `downloading[]` the same way.
- Nothing moving and nothing waiting: the section is one line, "Nothing to transfer".

### 2.3 Problems

Each problem is a row with an icon, a sentence and, where one exists, its action. None: "No
problems".

- **Uploads waiting to be retried**: `queues.parked`, with `queues.lastError`, and **Retry now**
  (`retry`).
- **Unreadable records set aside**: `setAside` > 0, "kept and never run".
- **A new machine**: for each name of `newMachines`, "*name* can now unlock this vault", and one
  **Mark as seen** for them all, which sends the domain's `vault_machines`: listing the machines
  acknowledges them ([vault §6.3](../extensions/vault.md#63-machines)).
- **A store**: held down or unreachable, or holding corrupted chunks (§2.4), named.

### 2.4 Stores

One card per entry of `backends[]`: its name and role (main, replica, backfill, read-only), and:

- **Connection**: "Connected, *latency* ms" when `health` is up and `reach` reachable; "Unreachable:
  *error*"; "Paused after *n* failures, for *duration*: *reason*" when `health` is down.
- **Space**: a gauge of `disk` used against its total, when the store reports one.
- **Copying**: for a store owed copies (`copies.owed` > 0), "*n* to copy" and its rate, and the
  current job's file with a progress bar of `checked` against `chunks`.
- **Corrupted**: "*n* damaged chunks" when `corrupted` is checked and non-zero; "Not checked" stays
  out of view.

### 2.5 This device

- **Cache**: a gauge of `cache.bytes` against `cache.maxCache` (no gauge without a limit), and the
  part kept offline (`pinnedBytes`).
- **Memory**: the owner process's own RAM from `self.process`, for the curious, in smaller type.

### 2.6 Details

A row that opens the domain's settings in force (`settings`): versioning, read-only, the extensions
and where each setting comes from, as labelled rows. It has **Copy report**, which copies both
replies as indented JSON for a bug report; the JSON is never shown.

## 3. Below the domain

- **Recent warnings and errors**: `self.recentErrors` of level `warn` and `err`, newest first, at most
  `shown_errors`, each with its relative time; more behind **Show all**. They are the process's, not
  a domain's: the same whichever domain is picked, without duplicates (same time and message).
- Each app's own rows, where its section says: Android's failed saves, and camera backup on an app
  that has it: its status line and **Back up now**.

## 4. A domain that does not answer

Its page is "Not answering: *reason*", with the last answer's time when there was
one; it is asked again at the next poll.

## 5. Parameters

| Parameter | Recommended | Constraint |
|---|---|---|
| `status_poll` | 2 s | only while the screen is visible |
| `stale_after` | 10 s | several `status_poll` |
| `smoothing` | 0.3 | weight of the newest answer, in (0, 1] |
| `shown_errors` | 5 | |

## 6. Conformance

- The screen shows no JSON and no text report; Copy report puts both replies on the clipboard.
- With the server away, the state is Not syncing or Store offline with the reason, the store's card
  says Unreachable, and Problems lists it.
- A file uploading shows a progress bar that moves; Pause turns the badge to Paused and holds it;
  Resume lets it go.
- A parked upload shows Retry now, and Retry now clears it once the store is back.
- A machine enrolled elsewhere shows under Problems by its name; Mark as seen removes it, and it
  stays removed at the next poll.
- With two domains, the picker switches every section, Details included, to the chosen one.
- Stopping the owner for less than `stale_after` changes nothing on screen.
- Leaving the screen stops the polling: the owner's log shows no `status` request after it.
