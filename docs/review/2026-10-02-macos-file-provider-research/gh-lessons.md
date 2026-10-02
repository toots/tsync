# macOS integration: lessons from the project's GitHub issues and PRs

Scope: 108 PRs and 1 issue (#93) on GitHub as of 2026-10-02. None of them has a comment or a review comment, so the PR bodies are the whole record. PRs #7, #30, #31 and #34 have empty bodies; for those only the commit headlines and touched files are available.

Coverage gap: no PR or issue covers macOS packaging, launchd, code signing or notarisation. That work went straight to `main` as commits (84 commits on `main` touch `macos/`), so whatever was learned there is in `git log`, not on GitHub.

---

## Per PR / issue

### #7 Macos fixes (2026-07-04, merged)
- **Body:** empty. Touched `Enumerator.swift`, `Extension.swift`, `IPC.swift`, `Item.swift` and `ipc_handler.ml`, plus the IPC snapshot test.
- **Lesson:** early fixes to the enumerator and IPC with no written rationale. `IPC.swift` turned out to be dead code later (#41).

### #30 Full overhaul of the swift side plus good ocaml cleanup (2026-07-31, merged)
- **Body:** empty. Brought in the current layout: `Shared/` (Config, DaemonClient, DaemonError, ItemID), `TsyncApp/` (AppDelegate, SignalRelay), the File Provider extension (Enumerator, Extension, Item), `TsyncTests`, `project.yml`, and `tests/e2e/macos`. On the OCaml side: `lib/file_provider`, `ipc_handler`, `ipc_error`, `item_ref` and `folder_ids`.
- **Lesson:** this is where the app/extension/daemon split was set: a sandboxed extension talks JSON over a unix socket to an unsandboxed daemon, and the app relays daemon signals to the system (`SignalRelay`). Item identity comes from `item_ref` / `folder_ids` (`f:<folder-id>/<leaf>`, `d:<id>`).

### #31 Implement byte range read on file provider (2026-08-01, merged)
- **Body:** empty. Added `PartialRange.swift`, `Info.plist` changes (partial-content fetching), `fetch_range` in the daemon, and tests.
- **Lesson:** partial fetch (`NSFileProviderPartialContentFetching`) works when it is backed by a daemon range read. #101 later found an edge case: a zero-length range sent to the daemon made the system retry forever.

### #34 Add macos system tray icon (2026-08-05, merged)
- **Body:** empty. Added `StatusMenu.swift`, plus pause support in the daemon (`sync_queue`) and a `tests/pause` test.

### #36 Show what is uploading in the menu bar, with previews (2026-08-06, merged)
- **Problem:** the menu showed only a count of pending uploads (482 pending with no bytes moving), so a slow queue and a wedged queue looked the same.
- **What was done:** `Sync_queue` keeps an `active` table, so the menu lists the files in flight with bytes sent, bytes owed and an ETA. The daemon makes QuickLook thumbnails (`RepresentationTypeThumbnail`). Clicking a row reveals the file instead of opening it.
- **Apple lessons:**
  - The menu bar app is sandboxed. To it, a file in the shared container is "data from other apps": opening one raises a permission prompt and leaves the app stuck in a prompt/relaunch cycle. So anything that reads file bodies (previews) has to run in the unsandboxed daemon.
  - QuickLook types a file by its extension, and staged bodies are named by uuid. The daemon hardlinks the body under its real name; a symlink does not work because the generators resolve it and find the uuid again.
  - Get folder URLs from `NSFileProviderManager.getUserVisibleURL`, never by rebuilding the Finder path (its spelling is undocumented). The URL is security-scoped and has to be claimed before use.
  - Reveal rather than open: opening launches whatever owns the type and may pull down a body that is still uploading.

### #38 Collapse the drifted backend seams (2026-08-07, merged)
- **macOS part:** `?on_changed` was an optional argument threaded through the sync layers. File Provider passed one, fuse never did, and nothing noticed. It is now required, typed `Notify | Revalidates`.
- **Lesson:** "how a frontend learns about changes it did not make" has to be a required, typed part of the frontend contract. File Provider is the `Notify` kind: it keeps its own view, which must be signalled.

### #41 Consolidation review (2026-08-09, merged)
- **macOS part:** `macos/TsyncFileProvider/IPC.swift` was dead code. It compiled only because `project.yml` lists the whole directory, and its error map had already drifted (it matched `"not found"` while the daemon sends `"not found: …"`). Separately, the daemon and the CLI disagreed on whether an empty journal can bridge a bookmark.
- **Lesson:** error matching across the Swift/OCaml boundary drifts unless it has one owner. This led to `DaemonError.isNotFound` (#87).

### #48 Linux system-tray status icon (2026-08-13, merged)
- **macOS part:** `tsync-tray` copies the layout and strings of `macos/TsyncApp/StatusMenu.swift` exactly. `Tray_model` is pure and snapshot-tested, and the test also runs on the macOS runner so drift shows up there.
- **Open:** `human_bytes` is decimal in the menus but 1024-based in `Metrics`, to be settled separately. The icons are placeholders.
- **Lesson:** the menu-model logic is duplicated, with a pure OCaml model on Linux and Swift on macOS. A redesign could have the daemon render the menu model and keep both trays thin.

### #56 Bound unbounded fan-outs (2026-08-16, merged)
- **macOS part:** the headless and file-provider frontends had no `async_exception_hook`, so a filesystem error in a detached record delete killed the process. Fixed.

### #60 Report a running command to the daemon (2026-08-17, merged)
- **macOS part:** on macOS one process answers for several domains. `Diagnostics.merge` kept non-`domains` keys from the first report only, and plain concatenation would list a job once per domain, so the merge dedupes by pid.
- **Open (stated in the PR):** "the macOS File Provider path and multi-domain socket routing are not exercised by CI on Linux". Only synthetic unit tests cover it.
- **Lesson:** the macOS daemon has a different process shape from Linux (one process, many domains). Every aggregation has to handle that, and Linux CI never sees it.

### #68 Make http-proxy a full frontend (2026-08-20, merged)
- **macOS part:** the launcher runs convergence (reconcile, poller, sweeps) in one process per domain, and pushes what it applies to frontends as an advisory `changed` notice on the `Ipc_handler` hook. File Provider already implemented that hook; fuse had stubbed it.
- **Lesson:** convergence belongs to the domain, not to a frontend. The File Provider frontend is a consumer of the same change notices.

### #74 Copy a share link from Dolphin's context menu (2026-08-27, merged)
- **macOS part:** the share action gained a path (`rel`) form. The reference form stays because the macOS FileProvider holds item ids, not paths.
- **Lesson:** IPC requests need to accept both identities: a reference for File Provider, a path for desktop menus. #89 extends this to stat and restore.

### #79 Isolate cleanup code, per layer (2026-08-31, merged)
- **macOS part:** `Folder_ids.key_of_id` stopped doing a full mirror walk on a lookup miss. Rebuilding the folder-id index after a resync now happens only in the File Provider `full_resync` hook (`file_provider.ml:93`). Android has no such rebuild ("the File Provider rewrite is where the handshake is being settled").
- **Lesson:** keeping item identity valid across a full resync is part of the frontend contract, and only macOS implements it. #85 lists "the folder-id rebuild living only in the File Provider hook" as an open decision.

### #80 fileprovider: overhaul item listing (2026-08-31, merged)
- **Problems:** five silent bugs.
  1. `enumerateChanges` ignored its container and reported the whole domain's journal into every folder enumerator.
  2. `currentSyncAnchor` and `changes_since` each did a full S3 LIST plus a GET per entry, and fileproviderd calls them before every enumeration.
  3. Change rows were thrown away and re-fetched one `stat` at a time.
  4. The feed filtered by client uuid, which is per machine, so changes the CLI made locally never reached Finder.
  5. The page token was an offset into an in-memory listing, which means nothing to the next process the system hands it to.
- **What was done:**
  - The change feed is answered locally from an `Applied_entries` log, written before publishing and after applying.
  - One `Item_row` shape for list, stat and change; a change carries the whole item.
  - `list_dir` is paged by name cursor (`after`/`limit`/`next`).
  - Mutations reply with the item they made.
  - Two enumerators: directory enumerators give items only, the working set carries all changes.
- **Apple lessons:**
  - A replicated extension may signal nothing but the working set, so a directory's `enumerateChanges` is unreachable in practice.
  - Page tokens and anchors are persisted by the system and replayed to later processes, so they must be stateless cursors, never offsets into memory.
  - The initial-page sentinels (`"FPPageSortedByName "` etc.) are valid UTF-8 and must be matched explicitly, or a fresh enumeration resumes mid-folder.
  - `currentSyncAnchor` is on the hot path and must be cheap and local.
  - Trash is deliberately off: tsync's trash holds folders only, so the trash container would show trashed folders and lose trashed files.
- **Later reversed:** `MaterializedSet` filtering was undone in #81.

### #81 fileprovider: two-way filesystem operations (2026-09-01, merged)
- **Problem:** a directory deleted on one machine stayed on the other for good. Two machines writing the same file held different bytes under one name, each reporting nothing left to apply.
- **Root cause:** `changes_since` names a `Delete` as `f:<parent-folder-id>/<leaf>`, reading the folder id from the mirror marker that the recursive delete had already removed. The op was dropped silently. The system then got an `Rmdir` for a folder that still held a child it had never been told about, and declined it. Separately, a foreign op arriving on top of a staged local edit was skipped.
- **What was done:** folder ids outlive the folder (on-disk `by-path` entries, because the applying process is not the describing process). A local staged edit moves aside to a conflict copy. The extension shrank by 246 lines by following the framework.
- **Apple lessons (important):**
  - The materialized set is a hint, not a filter. Tell the system every change and let it decide; dropping a removal under an unbrowsed folder left the folder on disk.
  - Follow Apple's documented sequence: `currentSyncAnchor`, then a full item enumeration, then changes from that anchor. A fresh anchor paired with a partial enumeration promises coverage that was not delivered.
  - **Never return a cached or previous anchor from `currentSyncAnchor`.** Two attempts (with and without a resync-token guard) stopped sync outright: the system reads "same anchor" as "nothing new" and stops asking.
  - A deleted item must be describable after it is gone, so the identity mapping has to outlive the object.
  - `deleteItem` declines removing a directory whose children it was never told about.
- **Methodology:** keep three views apart (source mount, daemon mirror via `tsync ls`, replica on disk). Compare file contents, not names. Run each suite twice, because the bugs were intermittent.
- **Open:** a published losing write is overwritten (it survives only in version history). A file-vs-dir name clash diverges permanently. File and dir conflict suites were 3/4 each. The dir clash was addressed later in #92; the published losing write still stands.

### #83 stdlib: an interrupted syscall is not an answer (2026-09-01, merged)
- **macOS part:** EINTR retry shadowing reaches `file_provider_frontend.ml`. The PR notes that a green macOS `dune build` does not compile fuse or s3; the reverse holds for File Provider on Linux.

### #85 lib: named signatures, fewer libraries (2026-09-02, merged)
- **Open:** "The macOS File Provider and Android JNI frontends do not compile on the machine this was done on". The Swift side was checked only by grep. Left as open decisions: the folder-id rebuild living only in the File Provider hook, and the file/dir kind-clash retry loop.

### #87 fileprovider: review fixes for the working-set series (2026-09-02, merged)
- **Defects (Apple-facing):**
  - The working-set full enumeration walked the tree itself and carried pending folders in the page token. **The page token is capped at 500 bytes**: at about 26 pending folders it overflowed and the enumeration ended early with no error, so the system took a partial tree as the whole domain. The token also used `|` as a field separator, which a filename can contain. Fix: the daemon answers `list_all`, paged by a bounded `<container id>/<name>` cursor.
  - `ChangeBatch` reported only an item's last op, so `mv a b; rm b` left `a` on the replica for good. Now each identifier is decided by the last op that mentions it, as the item or as what a rename left behind.
  - `modifyItem` with a move plus new contents had a self-compare guard, so the old reference was never deleted and the system saw a merge.
  - `existingFile` treated every stat failure as absent, so a transport error during reimport re-uploaded files (defeating the `mayAlreadyExist` guard). Now only `not_found` means absent, owned once by `DaemonError.isNotFound`.
  - `createItem` and `modifyItem` could complete with neither an item nor an error.
- **Sync layer, found by a live Mac/Linux test:**
  - The journal key cursor race: client-minted millisecond keys plus readers cutting at a key lost late-visible entries. Replaced by a positional applied log with dedupe.
  - Change descriptions are now built against by-path ids, not the current mirror.
  - **Lwt's accept loop died on `setsockopt(TCP_NODELAY)` returning `EINVAL` on macOS** (unix socket, peer already gone). The File Provider and Finder hung behind it.
  - A reference resolved outside the meta lock raced the extension's concurrent requests, so mutations are serialised.
  - The poller woke only on a cursor change; it now also sweeps every minute.
  - The foreign dir rename staged-guard bug.
- **Lessons:**
  - The extension sends several requests concurrently, so the daemon must serialise mutations or resolve references under the lock.
  - Budget the 500-byte token; put state in the daemon, not in tokens.
  - Never let a callback complete without an item or an error.
  - Classify transport errors separately from not-found.
- **Tests:** Swift 52/52 on the Mac; live convergence in about 45 s, five runs in a row.

### #88 File Provider: rebuilds over the change feed, and one parent per folder id (2026-09-06, merged)
- **Problem:** fileproviderd held 40k of the domain's 220k items, drifting for weeks.
- **Root cause:**
  - The working-set `list_all` cost a full mirror walk per page (~62 s per page), so it never finished. It was demanded after every `tsync sync --full`, because the rebuild wiped the applied log and expired the anchor, and the system reconciled against a partial listing.
  - Folder ids had two parents after lost marker deletes, so the item cursor looped.
- **What was done:**
  - A rebuild appends its diff to the applied log as ordinary ops (chunks of 64), so the anchor survives a resync.
  - The daemon owns the sync anchor `<generation>|<entry>`; the extension passes it back verbatim. Only `tsync fileprovider reimport` bumps the generation.
  - A change the daemon cannot name is dropped and counted instead of expiring the whole anchor.
  - `list_all` caches a sorted listing and pages by line number: ~0.35 s per page, 236k items in about 9 minutes.
  - On the store side: `.tsync-parent` anchors per folder and `delete` returns whether it removed something.
- **Apple / sandbox lessons:**
  - **The sandboxed extension cannot read files the daemon wrote.** The on-disk resync token was denied by System Policy and had never worked. The extension also read `config.json` for the read-only flag, was denied, and so treated every domain as writable. Fix: everything goes over IPC (the `status` action carries the flag).
  - Anchor expiry (`syncAnchorExpired`) forces a full working-set enumeration, which is very expensive on large domains. Design so the anchor practically never expires: a rebuild becomes a delta, not a reset.
  - The full enumeration must be fast per page and stable under concurrent change. Paging over a snapshot works; an item cursor over a mutable tree does not.

### #89 Pinned cache chunks with deadlines, and offline actions in every menu (2026-09-08, merged)
- **What was done:** explicit fetches become pins with a deadline (10 days by default). `availability` has three states (online-only, cached, pinned). Finder, Dolphin and Android all offer Make Available Offline / Keep Offline Longer / Make Online Only. Items can be named by path as well as by reference.
- **Open:** "Swift needs a compile on the Mac" (not verified in the PR). Not done: re-fetching a pinned file after an upstream change, and pinning a folder so later additions are pinned. Also fixed a `status_ask` race on macOS CI (the test connected after bind but before listen).
- **Lesson:** offline state is tsync's own (a pin with a deadline) and runs alongside the system's materialisation and eviction. A redesign should decide whether the "offline" UI maps onto File Provider's own download/evict APIs or stays a custom menu action.

### #92 Local file operations never wait on the network (2026-09-17, merged)
- **macOS part:** indirect. Folder ids are minted locally and final from creation, so every reference (File Provider, Android) stays valid. Reads have a 15 s store deadline. Name clashes become conflicted copies.
- **Lesson:** identity has to be stable from creation, with no later "adoption" that renames an id. The File Provider item identifier depends on it.

### Issue #93 Stress run for the metadata-offline work (opened 2026-09-17, OPEN)
- Not macOS-specific. The post-merge stress workflow has not been run. The `shared/` oracle was weakened (it now accepts any body ever written, so a lost update passes), and vanished paths are never judged. Open.

### #101 macos: review fixes (2026-09-19, merged)
- **First round:**
  - An unreadable `config.json` was reconciled as "no domains" and every domain was removed with `.removeAll`.
  - The purge marker is now deleted only once removals succeed.
  - The socket sets `SO_NOSIGPIPE`.
  - Replies are decoded lossily, because the daemon passes raw name bytes and one non-UTF-8 name blanked a whole page.
  - Fetch temp files are removed on failure or cancel.
  - `createItem` makes a directory for package templates (`.logicx`, `.band`, `.rtfd`).
- **Second round:**
  - One undeletable leftover domain kept the identity scheme unrecorded, which **rebuilt every domain at each login forever** (contents made dataless and re-downloaded).
  - The retry on a provider still invalidating cost up to 10 s per call, which blew the CLI's 30 s budget and broke the purge-marker contract. Now one deadline per launch.
  - The relay reset its backoff on subscription accept. A crashlooping daemon under launchd caused a 1 Hz working-set signal storm per domain. Now the backoff resets only after the subscription has lasted.
  - Lossy names land in the reference too, so such items are made read-only.
  - A nil contents URL does not mean "directory" (it is also nil when `.contents` is not among the changed fields). An offer of contents settles it.
- **Third round:**
  - `Task.cancel()` does not interrupt a thread blocked in `recv`. Those threads come from a small global pool, so cancelled fetches exhausted it silently. Fix: the descriptor is published to a lock-guarded box that the cancellation handler shuts down.
  - A zero-length range is answered with `versionNoLongerAvailable`; sent to the daemon it was an unknown error the system retried forever.
  - The reset marker now outlives a failed removal.
  - Packages are typed explicitly via the directory UTType lookup, accepted only when declared, because the lookup invents dynamic types.
  - `StatusMenu.poll` waits for the previous answer.
- **Apple lessons (important):**
  - `NSFileProviderManager` domain add/remove is fallible and slow ("still invalidating"). Reconcile the domain list idempotently, with persistent markers that survive failures, and never treat a read failure as "zero domains".
  - Changing the domain identity scheme rebuilds domains: content goes dataless and is re-downloaded. Record completion only for what was asked.
  - Signalling the working set is not free: each signal triggers an enumeration. Rate-limit the relay.
  - Swift cancellation does not reach blocking syscalls. Use non-blocking or interruptible IPC.
  - Unknown errors are retried forever by the system. Map edge cases to specific `NSFileProviderError` codes (`versionNoLongerAvailable`, `notAuthenticated`, `serverUnreachable`, …).
  - The UTType for directories needs explicit handling for packages.
  - The temp directory for fetched contents: it is untested whether the extension may unlink there.
- **Open (PR checklist, only the Xcode build and tests ticked):** none of the runtime checks were run:
  - corrupt config survives
  - purge failure behaviour
  - no rebuild on second launch
  - reset after failed removal
  - `killall tsync` during copy
  - daemon restart re-signals, and crashloop backoff
  - `.rtfd` round trip
  - leftover temp file after cancel
  - repeated cancels leave the extension responsive (`ensure_cached` has no daemon-side deadline)
  - a non-UTF-8 name lists and is read-only

  `AppDelegate`, `Extension` and `StatusMenu` are not in the test target.

### #103 A signature, a fixture and a lookup are each written once (2026-09-21, merged)
- "Swift and Kotlin are untouched." No macOS content.

---

## Recurring themes

1. **The sandbox shapes the app/daemon split.** Both the app and the extension are sandboxed. Anything that reads daemon-written files fails: the resync token (#88), `config.json` read-only flag (#88), and file bodies for previews (#36, which caused prompt/relaunch loops). The rule: all state crosses over IPC, and only the unsandboxed daemon touches files.
2. **Anchors and page tokens.** These caused the most bugs:
   - Tokens are persisted and replayed across processes, so they must be stateless (#80).
   - The 500-byte cap truncated enumerations silently (#87).
   - The sentinels are UTF-8 strings (#80).
   - A cached or old anchor from `currentSyncAnchor` stops sync (#81, reverted twice).
   - Anchor expiry forces a full working-set enumeration, which was unaffordable on a 220k-item domain (#88).
   - Final design: the daemon owns `<generation>|<entry>` over an append-only applied log, and resyncs become deltas.
3. **Working-set-only signalling.** Directory `enumerateChanges` is effectively unreachable. The working set carries every change, the materialized set is a hint not a filter, and the system must be told every change (#80, #81).
4. **Identity must outlive objects and be final from creation.** Deletes must be describable after the folder is gone (#81). Duplicate folder ids with two parents looped the enumeration (#88). Local minting with final ids (#92). The folder-id rebuild after a resync exists only in the File Provider hook (#79, #85).
5. **Silent failure is the default.** The system drops or declines things with no error: a declined rmdir, a partial enumeration taken as complete, a stale anchor read as "nothing new", unknown errors retried forever, callbacks completing with neither item nor error. Mitigations: instrument `deleteItem` and the change batch (#81), count dropped changes (#88), compare file contents across the three views.
6. **Concurrency between extension and daemon.** The extension sends concurrent requests (so mutations are serialised, #87). Cancellation does not reach blocking `recv` (pool exhaustion, #101). Lwt's accept loop died on a macOS `EINVAL` (#87). A crashlooping daemon plus an eager relay caused a signal storm (#101).
7. **Domain lifecycle is fragile.** Add/remove is slow and fallible, an identity-scheme change rebuilds everything, and purge/reset markers have to survive failures (#101).
8. **Verification gap.**
   - Linux CI does not build Swift.
   - The macOS CI job builds OCaml but not fuse or s3.
   - Many PRs say the Swift side was "grepped" or "needs a compile on the Mac" (#85, #89), or that multi-domain routing on macOS was covered only by synthetic tests (#60).
   - `AppDelegate`, `Extension` and `StatusMenu` are outside the test target (#101).
9. **Process-shape difference.** On macOS one daemon process serves several domains (#60 merge/dedupe), while the Linux launcher forks per frontend group (#68). Aggregation code has to handle both.
10. **Duplicated UI model.** The Swift `StatusMenu` and the OCaml `Tray_model` must stay string-identical (#48), and the offline actions are reimplemented in Finder, Dolphin and Android (#89).

## Open / unresolved

- **#101 runtime checklist, all unchecked:** corrupt-config survival, purge failure, no-rebuild on relaunch, reset after failed removal, `killall tsync` mid-copy, daemon restart and crashloop backoff, `.rtfd` round trip, temp-file cleanup after cancel (the extension may not be allowed to unlink there, in which case cleanup moves to the daemon), repeated-cancel responsiveness (`ensure_cached` has no daemon-side deadline), and non-UTF-8 names.
- **Package create with `.contents` omitted** (#101): if the system ever omits `.contents` on a package create, an empty file results. Flagged to watch.
- **Trash container disabled** (#80): tsync's trash holds folders only, so enabling it would lose trashed files. `Item_row` carries the flag for later.
- **Published losing write overwritten** (#81, restated as "Not promised" in #92): the loser survives only in version history.
- **`MaterializedSet` rebuilt per activation** (#80, `ponytail:` note). The set itself was later removed as a filter in #81.
- **Folder-id rebuild after a resync** lives only in the File Provider hook; Android has none (#79, #85). "the File Provider rewrite is where the handshake is being settled".
- **Pins** (#89): no re-fetch of a pinned file after an upstream change, no folder pinning, and the Swift side was not compiled in the PR.
- **Multi-domain macOS diagnostics merge** (#60): never exercised against a real macOS daemon.
- **Tray:** decimal vs binary `human_bytes` mismatch, and placeholder icons (#48).
- **Issue #93 (open):** the stress run was never done, and the `shared/` oracle is weakened.
- **No GitHub record of macOS packaging, launchd, signing or notarisation.** Those lessons, if any, live only in direct commits on `main`.
