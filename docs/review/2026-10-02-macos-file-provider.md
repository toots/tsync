# macOS File Provider: extraction, adversarial pass and history (2026-10-02)

Companion to [`docs/spec/frontends/file-provider.md`](../spec/frontends/file-provider.md). Work was done
on Linux, without compiling or running any Swift. Three passes:

1. **Extraction**: the normative behaviour of `main`'s Swift app (`macos/`), its extension and the
   daemon side they talk to (`lib/app/frontends/file_provider`, `ipc_handler.ml`). This is the first
   commit of the spec file on this branch; the diff against it is the record of pass 2.
2. **Adversarial pass**: checked against Apple's FileProvider headers (macOS 26.5 SDK, which keeps
   the 13–15 availability macros), Apple documentation, the FruitBasket sample and Apple-engineer forum
   answers. Kept: what is simple and survives long downtime. Removed or changed: everything below.
3. **History**: every macOS fix in `git log --all` (7 design phases, June–September 2026) and every
   macOS PR (#7 through #103, plus issue #93).

The research behind passes 2 and 3 is in [`2026-10-02-macos-file-provider-research/`](2026-10-02-macos-file-provider-research/): `sdk-facts.md` (header quotes with sources and availability), `history-lessons.md` (phases, fix catalogue, empirical SDK behaviour) and `gh-lessons.md` (per-PR lessons).

---

## 1. What the adversarial pass changed

Classification: **SDK** = contradicts the documented framework; **drift** = the replica can
diverge silently and never repair; **bug** = wrong behaviour; **ad hoc** = complexity with no
need.

### 1.1 Drift

| # | As built | Problem | Spec now |
|---|---|---|---|
| D1 | `fetchContents` calls `ensure_cached`, then a separate `stat` for the item | The content can change in between: the system records version B with A's bytes and never fetches B. Same for partial fetches. `documentSize` may not match the bytes (Apple forum: re-upload after every fetch) | The reply carries the item whose bytes were written (§6.9) |
| D2 | Applied log pruned by age (horizon), whatever the File Provider consumed | A Mac off longer than the horizon comes back to a stale anchor and a full scan. At 220k items that scan never finished (#88). Apple: working-set expiry is "a very expensive scan of all the items known by the system" | Feed watermark: retention keeps every entry after the last anchor the extension asked from (§5) |
| D3 | An anchor with an empty entry is served from the oldest kept entry | If shards were dropped since it was issued, changes are skipped silently | Stale once any shard was dropped (§5) |
| D4 | A `list_all` resume against a remade walk continues at the same line | Lines shift, so items are skipped or repeated. An unchanged skipped item is never enumerated again | `stale` → page expired → the system restarts (§5) |
| D5 | Menu offers Quit | Quitting stops the relay: no remote change reaches Finder until the next login | No quit (§2, §10) |
| D6 | The app reconciles only at launch | A config change or reset needs an app restart, which is why reset killed processes | Reconcile on launch, on every relay acknowledgement, and on `reset` (§9.1) |
| D7 | A newly added domain is not signalled | Its enumeration waits for a user to open Finder (the "empty after reset" memory note) | Signalled on add (§9.1 step 9) |
| D8 | `unnamed` ops dropped and counted | An item silently missing until a reimport | Stated as an owner invariant; `unnamed` is a defect surfaced in status (§7) |

### 1.2 SDK adherence

| # | As built | Documented rule | Spec now |
|---|---|---|---|
| S1 | File identifier `f:<parent id>/<leaf>`; a rename returns a new identifier | "The item returned should carry the itemIdentifier of the item with which the item will be merged… [the system will] remove the other one from disk" (modifyItem header). Identifiers must be stable and path-independent | Stable per-machine file ids `i:<file id>` (§6.1). This deletes the source-retiring logic in change batches, the write-then-delete for "move + new contents", and the lossy-name read-only rule's reason for existing. **Needs core changes, see §3** |
| S2 | contentVersion = etag, else `size:mtime` while staged | A changed contentVersion "will trigger a redownload". It flips on publish, so the file just saved is fetched again | `contentId` computed on adoption (§6.3; already in the rewrite spec) |
| S3 | metadataVersion = content + `:1/:0` for upload state | "The system will store this version, but otherwise ignore it" | metadataVersion = contentVersion |
| S4 | Staging by hard link | The header says clone it into the container. A lingering hard link makes eviction fail with EMLINK | Clone, copy as fallback (§6.6) |
| S5 | `read_only`/`denied`/`invalid` → Cocoa write errors | Non-resolvable errors are retried forever. A write refused for good (read-only domain, bad name) loops | `cannotSynchronize` on mutations: no retry until the item is edited again or signalled resolved (§6.10) |
| S6 | `exists` → bare `filenameCollision` | Build it with `fileProviderErrorForCollisionWithItem:` | The refusal carries the occupying item when known (§6.10) |
| S7 | Removal with `.removeAll` (reset, purge, identity rebuild) | `.preserveDirtyUserData` exists (macOS 12) and returns where the data went | Always preserve dirty data, and show the location (§9.1) |
| S8 | Read-only probe: synchronous, no deadline, from enumerator creation and callbacks; unsynchronised cell | `enumerator(for:)` "expected to complete quickly"; no blocking on callback queues | No probe: the row carries `readOnly` (§6.2) |
| S9 | Offline actions relayed as `evict`/`restore` events to the app | The extension holds a manager and can evict and request downloads itself | Done in the extension. No event, no dependence on the app; the `root` translation bug in the relay is gone with it (§6.7) |
| S10 | Daemon as a plain `~/Library/LaunchAgents` plist | `SMAppService.agent` with `BundleProgram` is the documented replacement. `.notFound` means "never registered" (Quinn), not "broken". Legacy plists still work but need `AssociatedBundleIdentifiers` | Bundled agent registered by the app; legacy plist allowed as a fallback, with the association key (§11). **Retry on the Mac**: the earlier failure may have been `Program` vs `BundleProgram` |
| S11 | Root item synthesised in the extension | Fine per SDK, but it needed the read-only probe | `stat("root")` like any item |

### 1.3 Bugs fixed by the spec

- Reset runs `pkill -f /Applications/TsyncApp.app`, which also matches the owner (its binary is in
  the bundle). `tsync restart` does the same. Spec: never signal by process name (§9.3, §9.4).
- The relay passes `ref` raw as the identifier, so `root` is never `.rootContainer`. This disappears
  with S9.
- No client deadlines, and the menu's poll latch is held forever by a wedged owner. Already in the
  rewrite spec, kept.
- Router refusals carry no `code`. Kept from the rewrite spec.
- `create`/`write`/`rename` replace an existing destination silently. Spec: `exclusive`/`noreplace`
  → `exists` → collision.
- `baseVersion` is ignored. Spec: `base` on `write`. Conflict resolution follows Apple's recommended
  pattern: the item keeps the server version and the local edit becomes a new item through the
  working set.
- `mayAlreadyExist` with offered contents returned the server item. The system would have taken it as
  "accepted your bytes" over a possibly different local file. Spec: `write(ref, base)`, a no-op when
  the content is identical.

### 1.4 Ad hoc, removed

- **Availability from the replica.** The owner located the replica folder by an undocumented
  name-projection rule and read `SF_DATALESS`. Removed: availability is the chunk store's, and Finder
  shows materialisation itself. §3.4 is deleted.
- **Destination root declared by the app's subscription** (rewrite spec). It made every download fail
  while the app was down. The App Group is the documented trust boundary for the socket ("In macOS,
  use app groups to enable IPC … between a sandboxed app and a nonsandboxed app"), so path rules
  suffice (§4.4).
- **`evict`/`restore`/`resync` events.** `resync` was handled exactly like `changed`; the other two
  went with S9. The events left are `changed`, `recovered` and `reset`.
- **The `preview` verb.** No client sends it.
- **Identity-scheme record** kept, bumped to 2 for S1. Existing domains are rebuilt once: content goes
  dataless and is fetched again on access.

### 1.5 Considered and not adopted

- **Pins as `contentPolicy = downloadEagerlyAndKeepDownloaded`** (macOS 13; the native "keep
  downloaded", inherited down folders). Pin state is not a journal op, so it never reaches the change
  feed, and pin expiry would need its own notifications. A pinned file already reads offline from the
  owner's pinned cache. Worth revisiting if pins become feed-visible.
- **Completing writes only after the upload publishes** (an Apple engineer prefers it; the header
  allows early completion on macOS). It would make local edits wait on the network, against the core
  principle.
- **`disconnect(reason:)` for an owner outage.** It is documented for updates and log-out only.
- **Streaming progress on the bulk connection** instead of `download_progress` polling plus a
  separate `ping`. One mechanism would give progress and liveness together. It is a core change to
  bulk actions ([failure-model §8.2](../spec/algorithms/failure-model.md)). Proposed, not written.
- **A periodic working-set signal** as a safety net. Not needed while the relay re-signals on every
  connection and the queue drops only redundant `changed` events.

### 1.6 Still open

- **Delete on a stale base.** The framework offers `deletionRejected` (the system re-creates the item).
  Today a delete of a file a peer changed since the system last saw it removes the newer version,
  which then survives only in version history. Adopting it needs `base` on `delete` and a refusal code.
- **Double storage.** A materialised file lives in the replica and in the chunk cache. This is a core
  design choice, unchanged.
- **App Group naming.** `group.` IDs prompt on macOS 15 unless every claiming binary embeds a profile.
  The app and the extension do. The owner still prompts once because it touches the extension's
  container. A `TEAMID.` group would orphan installs, so it is not done.

---

## 2. Lessons from the history

Seven designs in fourteen weeks. They moved steadily toward an extension with no state and no rules
of its own. Nearly every regression came from one of three sources:

- state or rules kept on the Swift side;
- two places restating one rule;
- a silent fallback (`try?` defaults, a notify to nobody reporting success, finishing at the old
  anchor).

### 2.1 What kept breaking

| Theme | Rebuilt | What finally held |
|---|---|---|
| Working-set scope | 4× (recursive → top level → extension walk → owner `list_all` → kept walk) | The full enumeration is mandatory, so it must be cheap and resumable from day one, and done where the data is |
| Anchors | 5× (startup timestamp → journal key → token read from a file the sandbox denied, broken 07-30 → 09-05 → applied key → positional log) | A position in a local, append-only log of what was handled; owned and compared by the owner |
| Content handoff | 4× | The owner writes into the system's temporary directory; the extension never moves files there |
| Error mapping | 3× (all-unreachable made domains "broken for weeks"; POSIX errors were rejected outright) | Only `unreachable` latches; only Cocoa and File Provider domains |
| Signalling channel | 3× (CLI per folder → extension `notify.sock`, which never existed for four weeks → app relay) | The long-lived app subscribes outward; it re-signals on reconnect and backs off on uptime |
| Change-batch collapse | 3× | Decided per identifier by the last op; simpler still with stable ids |
| Identity migrations | 3 mass re-downloads, one of them at every login | Define "done" narrowly; record a scheme only for what was asked |

### 2.2 SDK behaviour learned empirically (and now documented in §12 of the spec)

- The system persists identifiers and does not re-ask after a scheme change.
- Only the working set can be signalled. Directory change enumeration is never called.
- Pages and anchors are capped at 500 bytes. An oversized page ends the enumeration silently, as if
  it were complete.
- The initial-page sentinels are valid UTF-8.
- Finishing at the starting anchor on error means "up to date" forever.
- A stale anchor makes the system re-enumerate, but the re-enumeration does not remove items it
  already holds.
- The system will not delete a folder holding a child it was never told about.
- Errors outside the Cocoa and File Provider domains are rejected.
- An unknown error is retried forever, including an invalid zero-length range.
- Empty version data is dropped.
- The extension cannot create files in the group container, read files other processes wrote there,
  or move files into its temporary directory.
- `modifyItem` calls arrive concurrently.
- `Task.cancel` does not interrupt a blocking `recv`; cancelled fetches drained the thread pool.
- `providerNotFound` comes back while an installer swaps the extension.
- `SMAppService.agent` reported `.notFound`.
- macOS answers `EINVAL` to `TCP_NODELAY` on a Unix socket whose peer hung up, which killed the
  accept loop and looked like a File Provider deadlock.

### 2.3 Process lessons

- **The Swift side was never compiled where it was written.** Several bugs lived for weeks until a
  real Mac session found them: the denied resync token, the read-only flag, `notify.sock`. The #101
  runtime checklist was never run.
- **Three views must be compared, by content**: the store, the owner's mirror (`tsync ls`) and the
  replica. Do it on two machines, asserting the intended tree rather than mere convergence, and run
  each suite twice. The live driver found the mutation race, the journal key race and the staged-guard
  bug, none of which a snapshot test sees.
- **Over SSH**, reads go to the replica without waking fileproviderd, while writes do reach it. Only a
  GUI-session client (`open`, Finder) starts a first enumeration.

### 2.4 For the implementation on the Mac

- Make `AppDelegate`, `Extension` and `StatusMenu` testable. All three were outside the test target.
- First run the #101 checklist and the §14 lifecycle properties, especially the downtime one: stop the
  owner and the app for longer than the horizon, then assert a change enumeration rather than a scan.
- Verify on the Mac:
  - Can the extension evict and request downloads through its own manager from inside
    `performAction`?
  - Does `SMAppService.agent` with `BundleProgram` register? **No** (checked 2026-10-02):
    backgroundtaskmanagementd refuses it with "SMAppService target executable must be sandboxed
    because the app is sandboxed". The per-user agent is the only path (§11).
  - What does `remove(mode: .preserveDirtyUserData)` return?
  - Can the extension unlink leftovers in its temporary directory?
  - Does the upload badge clear when an upload publishes, with metadataVersion = contentVersion
    (both unchanged by the publish)? If the system skips an update whose versions it already holds,
    `isUploaded` never reaches Finder; the fallback is a metadataVersion that appends the upload
    state.

---

## 3. Changes made elsewhere

Stable file ids and the feed retention reach the core; they were made in the follow-up commits of
this review, each rule in the file that owns it:

| File | Change |
|---|---|
| [01-core §2.7](../spec/01-core.md) | `i:<file id>` in the item-reference grammar; what a file id is |
| [data-model/local-cache](../spec/data-model/local-cache.md) | file ids on mirror file entries; feed watermark and dropped-shard record |
| [04 §2.3](../spec/04-checkout-cache.md) | the file-id marker encoding |
| [03 §2.7](../spec/03-journal-sync.md) | applied-log ops carry the file's local `fid` |
| [wal-and-journal §4.8](../spec/algorithms/wal-and-journal.md), [05 §4](../spec/05-ops-config.md) | retention held back by the watermark; a rebuild stamps no generation and rebuilds the reverse folder index itself |
| [08](../spec/08-frontends.md) | `i:` in replies; `readOnly` row field; `stat` by parent and name; `write` by `ref`, identical content a no-op; content replies carry `item`; `exists` carries the occupant; rename onto its own place a no-op; feed watermark and empty-anchor rule; a cursor on another walk answers `{stale:true}`; `tempDir` and the surface hooks removed |
| [security-model §7.3](../spec/algorithms/security-model.md) | a host whose socket only its clients reach may declare no roots |
| [07](../spec/07-daemon-cli.md) | watermark and dropped-shard paths; no quit row on macOS |
| [09](../spec/09-tests.md) | feed and paging scenarios; `<file-N>` alias |

Still to refresh once an implementation exists: [ocaml/frontends/file-provider.md](../spec/ocaml/frontends/file-provider.md), whose section references follow the old numbering.

---

## 4. Second pass, before implementing

Made against the spec as left by §3, before any macOS code was written:

| Change | Why | Where |
|---|---|---|
| Whole-domain page cursor is `<walk>:<byte offset>` | A line index forced every page to scan the kept walk from its start: about 24 GB read for one 220k-item enumeration | [08 §2.5, §3.7](../spec/08-frontends.md) |
| One change-feed consumer per domain, stated | The watermark and the kept walk are single slots; a second consumer would unprotect the first's anchor and remake its walk | [08 §3.6](../spec/08-frontends.md) |
| File ids minted when an entry is written, backfilled at owner start | Minting on first report made `stat` and `list_all` write durably, once per file on the first enumeration after an upgrade | [04 §2.3, §4.10](../spec/04-checkout-cache.md), [local-cache](../spec/data-model/local-cache.md) |
| WAL records carry `fids`, copied as `fid` into the applied log | An own delete removes the file's marker long before its entry is published and noted, so the feed could not name the deleted file: it stayed in the replica | [04 §2.8](../spec/04-checkout-cache.md) |
| A non-UTF-8 name no longer makes an item read-only | `d:` and `i:` references carry no name, so the lossy decoding names the item exactly | [08 §2.3](../spec/08-frontends.md), [file-provider §6.2](../spec/frontends/file-provider.md) |
| One router-level subscription; the macOS service stays up with no domain | With one relay per registered domain, a fresh install never had a connection to learn of its first domain | [08 §3.8](../spec/08-frontends.md), [07 §3.1](../spec/07-daemon-cli.md), [file-provider §8, §9.1, §11](../spec/frontends/file-provider.md) |
| `menu` example follows the menu model's JSON; `menu_stats` defined | The example used fields the model does not have | [file-provider §10](../spec/frontends/file-provider.md) |
| The staged manifest records a whole body's digest as `h1`; `write_whole` of the current content changes nothing; a stale-base write's reply names the original key | `content_id` was otherwise recomputed from the whole body on every `stat`; 04 §4.3 contradicted conflict-resolution §4.9 on what the reply names | [04 §2.5, §4.3](../spec/04-checkout-cache.md) |
| A symlink's row carries `contentId`; its contentVersion is `"l:"` + that | The extension would otherwise hash the target itself, restating the owner's digest rule in Swift with a bundled xxHash | [08 §2.3](../spec/08-frontends.md), [file-provider §6.3](../spec/frontends/file-provider.md) |
| `share` takes `ref` as well as `rel` | Copy Share URL (file-provider §6.7) shares an item the extension knows only by reference | [08 §3.3](../spec/08-frontends.md) |
| The owner's agent is the per-user definition the package writes; purge removes it | Checked on the Mac: a sandboxed app may register only sandboxed agents, so the bundled agent is refused | [file-provider §9.1, §9.4, §11, §12](../spec/frontends/file-provider.md) |
| A durable record lets owner start skip the file-id backfill after one complete pass | Measured on a 241k-file mirror: re-reading every marker kept each start from serving for minutes | [04 §2.1, §4.10](../spec/04-checkout-cache.md) |
| A first `list_all` page is bulk | Measured on a 241k-file mirror: the walk outlasts the request deadline, so every first page answered "still in progress" and the working set was never listed | [08 §3.3](../spec/08-frontends.md), [file-provider §4.3](../spec/frontends/file-provider.md) |
