# macOS File Provider: lessons from the fix history (2026-06-19 → 2026-09-30)

Sources: `git log --all` over `macos/`, the pre-`macos/` root Swift dirs (`Shared/`, `TsyncApp/`,
`TsyncFileProvider/`, `tsync/`), `lib/{file_provider,frontends/file_provider,app/frontends/file_provider}`,
every `ipc_handler` location, `tests/e2e/macos`; plus message greps. Diffs were read wherever a message
was terse (all squash PRs #1, #7, #30, #31, #34 and the "Fix macos"/"More"/"Try that" commits). The
as-built spec snapshot `f20b3d18:docs/spec/frontends/file-provider.md` and `findings.md` (2026-09-29)
were used to cross-check. Many fixes exist twice (branch `fileprovider-review-fixes` /
`fileprovider-rebuild-as-delta` and their cherry-picks to `main`); **main hashes are cited first**,
branch twins in brackets. Anything inferred rather than stated in a message or diff is marked
*(inference)*.

---

## 1. Timeline of designs

### Phase 0 — All-Swift, extension talks to S3 directly (2026-06-19 → 06-30)
- Commits: `14f717ca` Initial commit; `c92d0b92` "Add first journal/recovery/auto-sync implementation on macos"; `096cebe4` "Macos batch + cleanup"; `1e4939e8` "Version first to avoid a gap"; `77e88462` "Switching hash".
- Architecture: `TsyncApp` (LaunchAgent, IPCServer) registers domains; `TsyncFileProvider` is an `NSFileProviderReplicatedExtension` holding an `S3Store` built from `config.json` (App Group) + Keychain credentials; a Swift `tsync` CLI.
- Identifiers: the raw S3 key (`<prefix>/<domain>/<path>`, dirs with trailing `/`).
- Enumeration: per-directory S3 listing; `currentSyncAnchor` = a per-process timestamp ("changes each launch so FP calls enumerateChanges on startup"); `enumerateChanges` reported nothing.
- Change signalling: the CLI's `tsync sync` replayed the S3 journal, *evicted* every touched key and signalled each affected **parent directory** (`c92d0b92` CLI.swift).
- State in the extension: a WAL "local pending" journal and a 2-second `VersionFlusher` actor living inside the extension process (`096cebe4`).
- Abandoned by `95b29ed5` "Rewrite (#1)" (no body). *(inference from the diff)*: Linux already had an OCaml FUSE implementation; the rewrite moved all logic into one shared OCaml core and turned the extension into a thin client. Keeping durable state (journal WAL, version flusher) in a process the OS kills at will, and per-directory signalling, were both dropped then and never came back.

### Phase 1 — OCaml daemon + thin extension over a JSON socket; key identifiers (07-01 → 07-30)
- Commits: `95b29ed5` Rewrite (#1); `b411b18b` "Macos fixes. (#7)"; `1710e2ec` full resync; `813a87c2` import/export (#12, item versions); `1ade58ca` multi-domain; `49c514f4` Cleanup (#15); `71f2e752` "More" (paging); `21321abd` "Fix macos"; `b773aae2` http proxy frontend (#19, one socket for all domains); `792e5750` purge/reimport/reset.
- Architecture: daemon `tsync start` (OCaml, unsandboxed) serves a JSON-lines socket in the group container; extension = `IPC.swift` client; app = domain registration. **Reverse channel**: daemon connects *into* `notify.sock` that the extension was supposed to listen on, sending `UPLOADED`/`CHANGED`/`EVICT` lines.
- Identifiers: full storage key, later `tsync/<domain>/manifests/<rel>` (`f0e84c91`) — the Swift side re-derived the daemon's key layout ("Must match the daemon's Conf_parsing.domain_prefix"). Each layout change required a forced `reimportItems` gated by an `itemSchemaVersion` marker (`21321abd`, version 3).
- Enumeration: anchor became the daemon's journal cursor (`b411b18b`, `changes_since`, `stale` → `syncAnchorExpired`); working set first = recursive `list_all` files only (`95b29ed5`), then **top level only** because enumerating the tree "hangs on large domains" (`21321abd`); pages = byte offset into an in-memory listing (`71f2e752`, added after `__FILEPROVIDER_OBSERVER_TOO_MANY_ITEMS__` SIGABRTs).
- Change signalling: `NotifyListener` in the extension on `CHANGED` → `evictItem(key)` + `signalEnumerator(.workingSet)` (`b411b18b`).
- Abandoned in `717d9a96` because (stated in its comments): the notify socket "on a real machine … was never created, so every eviction, restore and change notice went nowhere for as long as the feature existed" (the extension cannot write into the group container); path identifiers made every rename a merge; the error table latched domains offline for weeks.

### Phase 2 — Opaque references, app-side relay, launchd agent + login item (07-30 → 08-30)
- Commits: `4af1bfed` Macos install, `abf71143` "Fix first run + sign", `afaed1e6` "More" (SMAppService.agent dropped), `138114f3` CI signing; `ba6ca8d2`/`ed0084b3`/`34756cfd`/`eff2c3ac` (file_provider fixes); **`717d9a96` "Full overhaul of the swift side plus good ocaml cleanup. (#30)"**; `022d7253` byte ranges (#31); `398fa8e3` tray (#34); `eec5935f` upload previews (#36).
- Processes: LaunchAgent `org.feverdreamtv.tsync.daemon` (plain plist in `~/Library/LaunchAgents`, installed by `install-agent.sh`); `TsyncApp` = login item via `SMAppService.mainApp`, sandboxed, owns domains, **SignalRelay** (one thread per domain subscribes outward to the daemon socket and calls `signalEnumerator(.workingSet)` / `evictItem` / `requestDownloadForItem`), menu bar.
- Identifiers (`ItemID.swift`): directory = `d:<folder id>` (daemon-assigned, rename-stable); file = `f:<parent folder id>/<leaf>`; root ↔ `.rootContainer`. A one-time **identity-scheme rebuild** removed and re-added every existing domain (content went dataless).
- Anchor: `<resync token>|<cursor>`; the token was read by the extension from `resync-<domain>` in the group container (`ba6ca8d2`). *(Later proven never to have worked — sandbox denial, `807e1454`.)*
- Enumeration: single `Enumerator` class; working set = top level only, remote changes at any depth via `enumerateChanges`.
- Content handoff: daemon writes fetched bytes straight into `NSFileProviderManager.temporaryDirectoryURL()` (`eff2c3ac`).
- Errors: only the daemon's `unreachable` maps to `serverUnreachable`.
- Superseded because the single enumerator answered the whole journal into every container, top-level-only working set lost changes under unbrowsed folders, and `changes_since` re-read the backend journal per enumeration (`20a26efa`, `a06abe2f`).

### Phase 3 — Two enumerators, applied-entries change feed (08-31 → 09-01)
- Commits: `20a26efa` "ipc: what changed since, answered from what this client already had"; `a06abe2f` "fileprovider: one enumerator per container contract"; `d1bea01b`, `ab4f21e7`, `c88523a1`, `f779eb51`, `1b73dd2d`, `694c3a82`.
- `DirectoryEnumerator` (items only, page = last name served) and `WorkingSetEnumerator` (changes). Change feed answered from the local `Applied_entries` log, ops carry whole item rows. First a `MaterializedSet` filter (`a06abe2f`), removed one commit later (`f779eb51`): every change is reported wherever it sits. Working set became a full depth-first walk done **by the extension**, frontier carried in the page.

### Phase 4 — Daemon-paged working set, daemon-owned anchor (09-02 → 09-08)
- Commits: `6941a5b5` + `3c1c513a` (daemon `list_all`), `bc51cd75`, `2939226c`, `9cb2f9c4`, `274cc0ab`, `5cee5ccc`, `85fd6050`, `b7e4c849`, `10a77333`, `9ba6f9d5`, `aebaeff5` (positional applied log), `807e1454` (daemon owns the anchor `"<generation>|<entry>"`), `fed3bc67`/`d863e053`/`2d819bce` (kept walk file, line cursors), `061b7ab7` (readOnly from daemon), `dbbbe079` (resync reported as ops), `1f704988`/`8fe543be` (pins).
- The extension became nearly stateless: pages and anchors are daemon cursors carried verbatim.

### Phase 5 — Hardening (09-19 → 09-21)
- `f81bb083`, `9b4c3156`, `ee2dfe5b`, `1eb17120`, `018472fc`, `d0e0c1d4`, `51c9b0f6`, `2cc2fd00`, `bdf8a44f`, `12cfb681` (all on main). Swift in `f81bb083` was explicitly *not compiled* ("there is no swiftc on the machine this was written on").

### Phase 6 — Removed for the rewrite (09-29 → 09-30)
- `f20b3d18` snapshot of the as-built spec (with `findings.md`: S6, G10, H2–H6 open macOS issues), `6acfc294` normative spec, `2f187b8a` "Remove the implementation ahead of its rewrite" deletes all of `macos/` and the OCaml frontend. On branch `rewrite`, `docs/spec/frontends/file-provider.md` carries the contract forward and resolves several open findings normatively (client deadlines, transfer-root confinement, contentVersion must not move on own upload, async readOnly probe).

---

## 2. Catalogue of substantive fixes, by theme

Format: **hash (date) subject** — symptom / root cause / fix / **lesson**.

### 2.1 Identifiers and merges

- **`21321abd` (07-21) "Fix macos"** — after the key prefix changed (`f0e84c91` moved manifests under `tsync/<domain>/manifests/`) existing domains showed wrong/empty contents. Cause: the system persists identifiers and "never re-asks the extension". Fix: `itemSchemaVersion` marker → one `reimportItems(below: .rootContainer)` per domain. **Lesson: any identifier scheme change is a migration of the system's database; ship a versioned marker and a rebuild path from day one.**
- **`717d9a96` (07-31) #30, `ItemID.swift`** — renames of folders silently re-identified the subtree. Cause (header comment): "FileProvider treats an identifier returned from `modifyItem` that differs from the one it passed in as an instruction to *merge* two items, so naming items by path makes every rename a merge — and renaming a folder silently re-identifies everything beneath it, which the system is never told about." Fix: `d:<folder id>` for directories (daemon-assigned, rename-stable), `f:<parentId>/<leaf>` for files; the extension never composes storage keys. Paid for by an identity-scheme rebuild of every domain. **Lesson: identity must be stable across rename at least for containers; a file-by-name identifier still makes every file rename a single-item merge (accepted compromise).**
- **`2939226c` [`7a9a635e`] (09-02) "a move that carries new contents retires the old name"** — a file renamed and rewritten in one `modifyItem` stayed under both names. Cause: the delete of the old ref was guarded by comparing a value to itself. Fix: any move in the contents path deletes the old ref. **Lesson: with name-derived file ids, every rename-with-content changes identity; the old id must be retired explicitly or the system treats the new id as a merge "and never asks again".**
- **`1eb17120` (09-21) "a name that is not UTF-8 names nothing, so its item cannot be written"** — lossy decoding put U+FFFD into the reference. Fix: such items are read-only. **Lesson: a name-derived identifier must round-trip byte-exactly; anything lossy must be write-protected.**
- **`85fd6050` [`35c90711`] (09-02) "a change is named by the id its folder kept, not the path it spelled"** — moved-then-renamed folders: describing an op against a mirror that moved on found nothing, the page went stale, re-enumeration "never removes what it already holds", old names stayed on the replica. Fix: name every end through the folder's kept by-path id. **Lesson: describe changes by stable ids, not paths resolved at read time; "stale → re-enumerate" does not delete what the system already has.**
- **`1b73dd2d` (08-31) "a folder's id outlives the folder"** + **`694c3a82` (09-01)** — a deleted directory's children could not be named (the removal took the marker the id was read from), the system was asked to remove a folder still holding an unreported child, declined, and the folder stayed forever. Fix: keep removed ids on disk beside the index, but only for naming removals (`lookup_id_removed`). **Lesson: removal reports need identity information that outlives the object.**
- **`d863e053` [`c0cb7487`] (09-05)** — enumeration looped forever (38k of 220k items) because one folder id sat at three mirror paths after a trash/restore. Store-level root cause fixed separately by `bb795b9c` (deletes that silently failed left markers at two paths) and `c3ae1e7c` (`.tsync-parent` anchors so a disowned marker is ignored). **Lesson: identifiers assumed unique must be checked unique; a cursor keyed on an ambiguous id can cycle.**
- **`ed0084b3` (07-30) "locate a domain's CloudStorage folder by name, not by guess"** — `is_local` reported every file cloud-only; path-based evict/restore fell through to the first domain. Cause: fileproviderd strips disallowed characters from `displayName` (`My Media` → `TsyncApp-MyMedia`) by an undocumented rule. Fix: compare alphanumeric projections in one helper. Later `64edeea6` (08-24) removed path-based routing from the wire entirely.
- **`9b4c3156` (09-21) "a rebuild is called off by the domains it rebuilt, and the wait belongs to the launch"** — the identity-scheme marker was only recorded when *every unwanted* domain was removed, including ones dropped from config that the system would not release; so "content dataless and pulled down again at each login, forever". Fix: only the domains the rebuild asked for decide. **Lesson: a one-shot migration must define "done" narrowly or it becomes a per-launch wipe.**

### 2.2 Enumeration, pages and anchors

- **`71f2e752` (07-20) "More"** — extension SIGABRT `__FILEPROVIDER_OBSERVER_TOO_MANY_ITEMS__`. Fix: paginate; later (`717d9a96`) page size from `observer.suggestedPageSize` ("the system enforcing a hundred times the size it asked for. Ask what it wants rather than guessing").
- **`21321abd` (07-21)** — working set as a recursive listing hung on large domains → reduced to top level. **Reverted in spirit** by `f779eb51` (full depth-first) and `3c1c513a` (daemon list_all); see §3.
- **`5c8270fa` (07-30) "Fix directory deletion."** — created-then-deleted items resurrected; observer's deleted/updated sets are unordered, so only a key's *last* op may be reported; directories must be stat'ed too (stat proves existence). Refined twice: **`bc51cd75` [`4c7ac816`] (09-02)** "decided by the last op that mentions an item" (rename then delete left the old name forever; rename chains reported a middle name in both sets). **Lesson: collapse ordered ops to unordered sets per identifier, counting a rename's source as a mention.**
- **`717d9a96`** — "Never report success here. Finishing at the anchor we started from claims the client is up to date, so the system stops asking — and a failure then looks exactly like 'nothing changed', for as long as the domain lives." Also: `currentSyncAnchor` failure returns nil, never an invented anchor.
- **`a06abe2f` (08-31) "one enumerator per container contract"** — `enumerateChanges` ignored its container and reported the whole journal into every folder; but for a replicated extension a directory's change enumeration "is never triggered in the first place". Pages held offsets into an in-memory listing, meaningless to a restarted extension; initial-page sentinels are valid UTF-8 (`"FPPageSortedByName "`) and must be matched explicitly or "a fresh enumeration would resume from the middle of the folder". **Lesson: pages and anchors must be self-describing for a process with no memory of issuing them.**
- **`ab4f21e7` [`60951f65`] (08-31)** — a concurrent refresh returned an empty materialized set, so an enumeration answered "domain is empty". (Code deleted next commit.)
- **`f779eb51` [`20becc5b`] (08-31) "the system is told every change and decides what it holds"** + **`d1bea01b` [`a2f053f8`]** — the MaterializedSet filter dropped a child's deletion under an unbrowsed folder; the system then refused to remove the parent and kept it. "Over-reporting a removal costs a call for an item the system does not know; under-reporting leaves the folder behind for as long as the domain lives." Also "a fresh anchor is paired with a full enumeration the way the API expects". **Lesson: do not second-guess what the system holds; report everything.**
- **`3c1c513a` [`2bddc74a`] + `6941a5b5` (09-02)** — working-set enumeration ended early with no error at ~26 pending folders: the frontier in the page overflowed the **500-byte page cap**; names containing `|` corrupted the page encoding. Fix: daemon-side ordered `list_all` with a bounded cursor.
- **`fed3bc67` [`bf033d1b`] (09-05)** — each page re-walked the mirror: "a domain of 220k items cost a minute a page and a full enumeration never finished: fileproviderd held 40k of them". Fix: first page keeps the walk in a scratch file.
- **`d863e053`** (above, cycle) → cursor `<walk>:<line>`.
- **`2d819bce` [`1eae2c1d`] (09-05)** — "every enumeration of this domain stopped at line 161,000 of 236,580": a newline in a name split a line, a short page means "listing over". Fix: one JSON entry per line, count entries not lines.
- **`807e1454` [`1ec10e90`] (09-05) "the daemon owns the anchor, and a change it cannot name does not expire it"** — (a) sandbox denied the extension reading the resync token file, so every anchor carried an empty token and reimport expired nothing (bug live since `ba6ca8d2`, 07-30); fix: daemon answers `"<generation>|<entry>"` and compares both halves; (b) an op naming an unknown folder made the whole batch stale and re-listed the domain; now dropped and counted; (c) the `changed` hint is one event per burst.
- **`aebaeff5` [`2102b6bc`] (09-02) "an entry is handled once, not skipped for arriving behind the cursor"** — two clients writing at once each lost half the other's files silently: journal keys are writer-minted timestamps and become visible out of order; both the replay mark and the change-feed anchor cut "since key". Fix: positional applied log; anchor = place in it. **Lesson: an anchor must be a position in a local, append-only log of what was handled, never a remote sort key.**
- **`57129981` [`66d98b89`] (09-05)** — a wide last line made the applied log report no head → reader asked for everything since the beginning.
- **`dbbbe079` [`d0092571`] (09-05)** — a full resync wiped the applied entries, so every reader re-listed the whole domain; now the rebuild is reported as the ops it amounts to.
- **`9b0e8d0d` (08-09)** — daemon and CLI disagreed on whether an empty journal can bridge a bookmark; empty = stale.

### 2.3 Change signalling

- **`c92d0b92` → `b411b18b` (07-03)** — per-directory/per-key signalling replaced by `signalEnumerator(.workingSet)`: "signaling the specific key can't introduce items the DB has never seen". `717d9a96`: "For a replicated extension only the working set may be signalled … Signalling a specific item is documented as ignored."
- **`ba6ca8d2` / `34756cfd` (07-30)** — "the notify socket exists only while the File Provider extension runs, and fileproviderd stops it whenever the domain goes idle"; `tsync evict` printed "Evicted" for an eviction that never happened. Fix: `Ipc.notify` reports whether anyone listened; evict/restore fail with no listener, hints stay best-effort.
- **`717d9a96` (07-31) SignalRelay** — the reverse socket was "never created" on a real machine (sandboxed extension cannot create files in the group container). Fix: app (login item, always up) subscribes outward to the daemon. **Lesson: the daemon never connects into sandboxed processes; the relay lives in the long-lived process holding an `NSFileProviderManager`.**
- **`058e08db` (08-07)** — `on_changed` was an optional argument at every hop; FUSE omitted it and served stale names. Made required as `Notify | Revalidates`; File Provider = `Notify` "because the extension keeps its own tree".
- **`cb2be7ac` (08-20)** — convergence moved to a parent process; applied changes reach the frontend as an advisory `changed` notice over its socket.
- **`9ba6f9d5` [`be0f7fe1`] (09-03)** — a peer's last ops sat unapplied until unrelated activity: the poller woke only on a cursor bump, and a bump can be lost or land behind a later one from another process. Fix: race the watch against a 60 s sweep.
- **`f81bb083` [`30c74ea8`] (09-19)** — "a relay that reconnected signalled nothing about what it had missed". Fix: signal the working set on every (re)subscribe; "Events are not replayed".
- **`ee2dfe5b` (09-21)** — relay reset backoff on the daemon's accept, which happens before the stream; a crash-looping daemon caused "a 1 Hz enumeration storm per domain". Fix: reset only after a subscription lasted as long as the longest wait. **Lesson: an ack that costs the server nothing is not health evidence.**
- **`c88523a1` [`3a813e3f`] (08-31)** — diagnostic only: log ops handed and identifiers reported, because a delete that never reached the system looked identical to one the system declined.

### 2.4 Sandbox, paths and process boundaries

- **README/`14f717ca`** — extension must ship from `/Applications/`; must be enabled under System Settings → File Provider Extensions; signing identity mismatch with Keychain "causes the extension to fail silently at startup".
- **`49c514f4` → `a3fdcb48` → `eff2c3ac` (07-13 → 07-31) content handoff** — v1 tmp file; v2 APFS clone copy of the daemon's cache ("the system may move the returned URL, and an EVICT can race"); v3 move daemon staging into the system temp dir; v4 (`eff2c3ac`): "Every fetchContents failed … that move is not permitted (EPERM) … on a locally signed build or a notarized one alike". Fix: the daemon writes bytes straight into the path the extension names under `temporaryDirectoryURL()`.
- **`717d9a96` staging for uploads** — the system unlinks the URL after the callback returns; extension hard-links/copies into *its own* container ("may read the group container but not write to it"), daemon adopts it.
- **`807e1454` / `061b7ab7` [`0bd3eccb`] (09-05/06)** — the extension cannot read files the daemon wrote in the group container either ("System Policy deny on kTCCServiceSystemPolicyAppData"): the resync token never worked and **every domain read as writable**. Fix: ask the daemon (`status.readOnly`). This corrected the #30-era belief that the extension can read the group container.
- **`eec5935f` (08-06)** — previews made by the daemon via QuickLook because to the sandboxed menu app "a file in the shared container is 'data from other apps'".
- **Live test notes** — after each deploy the daemon blocks on "TsyncApp would like to access data from other apps"; sshd lacks Full Disk Access to the group container/CloudStorage. **Open security finding S6**: daemon accepts arbitrary `staging`/`dest` paths from socket clients (confused deputy); the rewrite spec adds transfer-root confinement.

### 2.5 Versions, ranges and re-fetch

- **`813a87c2` (07-08)** — contentVersion = content hash (size:mtime fallback, symlink target folded in); metadataVersion adds upload state; both non-empty ("FileProvider drops empty version data").
- **`717d9a96`** — directory version = its own folder id (stable); `contentPolicy = .downloadLazily` makes explicit evict-on-change unnecessary (the `b411b18b` `evictItem` on `CHANGED` was dropped).
- **`022d7253` (08-01) #31 byte ranges** — `fetchPartialContents`: rounds outward to an alignment that "is not stable across reboots"; with strict versioning answer `versionNoLongerAvailable` when the version differs.
- **`45112c33` (08-01)** — `NSExtensionFileProviderDownloadPipelineDepth=8` removed: each range costs the daemon a group read plus read-ahead and "against a small chunk size on slow storage is how the backend gets buried".
- **`51c9b0f6` (09-21)** — an empty aligned range (file shorter than the size the request was built from) sent length 0 → daemon `invalid` → unknown error "the system retries forever". Fix: `versionNoLongerAvailable`.
- **Open (H3)** — contentVersion moves from `size:mtime` to `h1` when the client's own upload publishes, so the system re-fetches a just-saved file (from cache). Unfixed in the old code; rewrite spec forbids it.

### 2.6 Errors and latching

- **`b411b18b` (07-03)** — "Returning our own domain makes fileproviderd treat the failure as fatal and cache an empty listing forever." Map transport failures to `serverUnreachable`.
- **`13097407` (07-10)** read-only errors changed to `NSPOSIXErrorDomain EROFS` — **wrong**, corrected by `eff2c3ac`: FileProvider rejects `NSPOSIXErrorDomain` outright (`__FILEPROVIDER_UNSUPPORTED_ERROR__`); surfaced as a bare I/O error "for months".
- **`49c514f4` (07-13)** — all non-not-found → `serverUnreachable`. **Reversed** by `717d9a96` `DaemonError`: "kept the domain broken for weeks … `serverUnreachable` and `notAuthenticated` mean *stop and wait to be signalled* … a one-second daemon restart during an install told the system to stop trying — and the thing that was supposed to signal it afterwards had never worked either". Only the daemon's `unreachable` latches; `signalErrorResolved(.serverUnreachable)` sent on every event/resubscribe.
- **`274cc0ab` [`728a9245`] (09-02)** — the `mayAlreadyExist` stat guard treated any failure as absent; a transport error during reimport re-uploaded the file. Only `not_found` means absent.
- **`9cb2f9c4` [`22e60805`] (09-02)** — create/modify could complete with neither item nor error, "which the framework does not expect".
- **Open (H2)** — router errors omit `code` → retried as unknown forever when a domain is missing from the daemon.

### 2.7 Concurrency and races

- **`b7e4c849` [`b7fd7943`] (09-03) "one mutation at a time, reference and all"** — `mv f4 sub/` racing `mv sub sub2` put f4 in a re-created `sub` beside `sub2`, replicated everywhere. Cause: refs resolved before the mirror lock; fileproviderd sends modifyItem concurrently. Fix: serialize mutating actions including resolution.
- **`10a77333` [`d8f854af`] (09-03)** — daemon stopped answering; Finder and extension hung. Lwt sets `TCP_NODELAY` on accepted sockets; macOS answers EINVAL on an AF_UNIX socket whose peer hung up; the exception killed the accept loop. Linux returns EOPNOTSUPP so never showed it.
- **`37c0d67d` (09-01)** — daemon died at start with `Sys_error(... client-uuid: Interrupted system call)`; `Sys.file_exists` reading EINTR as absent would have minted a fresh client uuid and abandoned unfinished WAL records.
- **`d0e0c1d4` (09-21)** — cancelled fetches left a GCD thread blocked in `recv` each; "until nothing the extension did got a thread at all … nothing reports it". Fix: lock-guarded cancellable socket, shutdown on cancel.
- **`12cfb681` (09-21)** — menu poll piled up requests when the daemon was slower than 3 s.
- **`b31dbb7c` [`7059de7a`] (09-02)** — found by the two-machine live test: a peer's folder rename was skipped on any folder this client had written into (empty staged dir counted as staged).
- **Open (H6)** — no client timeout; unsynchronised `readOnlyAnswered`.

### 2.8 Lifecycle: registration, reset, purge, reimport

- **`f219dc44` (07-10)** — a missing config registered a hard-coded default domain; now none. Stale domains removed with `.removeAll`.
- **`792e5750`/`8d4f3801` (07-26)** — "Only the app owning the extension may remove a File Provider domain": reset/purge are marker files the app consumes at launch, CLI bounces the app.
- **`1710e2ec`/`71b0f81f`** — reimport = `reimportItems` plus evicting every materialized item (dropped later; replaced by generation stamp → `syncAnchorExpired`).
- **`58facb6b` (08-05)** — domain calls fail with `providerNotFound` ("is in the process of being invalidated. Retry later.") while the installer swaps the extension registration; retry.
- **`f81bb083` (09-19)** — an unreadable config was read as "no domains" so reconciliation removed every domain and its local copies; purge deleted its marker whether or not anything was removed.
- **`9b4c3156` (09-21)** — 10 s retry per call (purge paid it per domain), CLI gave up at 30 s and the app then registered domains it was asked to purge. One launch-wide deadline.
- **`2cc2fd00` (09-21)** — reset marker deleted before the removal; a refused reset was forgotten.
- **Open (H4, live test notes)** — `fileprovider reset` kills the daemon (pkill pattern matches the in-bundle binary) and never kickstarts it; after reset the domain stays empty until a GUI client touches it (`ls` over ssh reads the replica without waking fileproviderd).

### 2.9 Installation, launchd, signing

- **`f219dc44`/`0142649f` (07-10/26)** — deploy needs `pluginkit -e ignore/-r` then `-a`/`-e use` to swap the extension; plist rewritten rather than PlistBuddy-patched.
- **`abf71143` (07-30)** — "SMAppService rejects a bundled LaunchAgent whose app has no Team ID"; local builds borrow the Apple Development identity; final re-sign must preserve Xcode-merged entitlements (`com.apple.application-identifier`) or the App Group breaks.
- **`afaed1e6` (07-30)** — "`SMAppService.agent` reports `.notFound` for a correctly placed, sealed and Team-ID-signed agent in `Contents/Library/LaunchAgents`, so it never starts." Daemon moved to a plain LaunchAgent; app stays `SMAppService.mainApp`. Purge must unregister the login item or it stays in the login-items DB.
- **`138114f3` (07-30)** — CI: keychain ACL `-A` (Installer key too) or codesign/pkgbuild hangs on a prompt; bound `notarytool --wait`.
- **`c3afc1b3` (08-14)** — stale generated `.xcodeproj` silently dropped new files (no app icon). **`c20aa4a2` → `a77e5bc1` (08-14)**: a "cleanup" deleted the whole TsyncApp sources (relay, menu, login item) and was restored the same day.
- **`398fa8e3`** — Homebrew libev not on the linker path.

### 2.10 Performance

- `21321abd`/`717d9a96` recursive working set at "hundreds of megabytes of resident memory, without ever settling"; `fed3bc67` one minute per page at 220k items; `20a26efa` `changes_since` listed the whole backend journal and fetched one object per entry on every enumeration; `aa903e76`/`bac2b877` listing fan-out dropped once resolution became local; `45112c33` pipeline depth; `807e1454` an unnameable op no longer re-lists the domain; `ee2dfe5b` 1 Hz enumeration storm.

### 2.11 Menu / tray

- `8e0b871e` tray showed "Downloading 96" with no rows (materialization credited nothing); `11bb9d1f` empty Stats submenu, now answered by the daemon on open; `6707b180` icon looked up from an ellipsised label; `43fc21ca` placeholder strings owned twice; `12cfb681` poll pile-up.

---

## 3. Recurring patterns

1. **Working-set scope flipped four times**: recursive files-only (`95b29ed5`) → top level only (`21321abd`, kept in `717d9a96`) → full walk by the extension (`f779eb51`) → daemon `list_all` (`3c1c513a`) → kept walk file (`fed3bc67`, `d863e053`, `2d819bce`). Each "top level only" saved cost and lost changes under unbrowsed folders; each full walk hit a scale limit (memory, 500-byte page, minute per page, newline, cycles). Suggests: the full enumeration is mandatory, so it must be cheap and resumable from day one, done where the data is.
2. **Content handoff redone four times** (`49c514f4`, `a3fdcb48`, `eff2c3ac`, `f81bb083` cleanup on failure) — each reacting to an undocumented sandbox rule.
3. **Error mapping redone three times** (`b411b18b`, `49c514f4` [made it worse], `717d9a96`); plus `13097407` POSIX regression fixed by `eff2c3ac`. Domains "wedged" for weeks came from latching errors with no working un-latch signal.
4. **Signalling channel rebuilt three times** (CLI per-dir → extension notify.sock → app relay), then patched twice (`f81bb083` resubscribe, `ee2dfe5b` backoff). The notify.sock path silently did nothing for its entire life (~4 weeks).
5. **Anchors rebuilt five times** (startup timestamp → journal cursor → token|cursor from file [never worked, 07-30 → 09-05] → applied-entries key → positional log + daemon-owned generation). "Drift after long downtime"/missing peer changes recurred until the anchor became a local position (`aebaeff5`) and the poller got a periodic sweep (`9ba6f9d5`).
6. **Change-batch collapse fixed three times** (`5c8270fa`, `a06abe2f`, `bc51cd75`).
7. **Identity migrations caused mass re-downloads**: `21321abd` reimport, `717d9a96` rebuild, `9b4c3156` rebuild-every-login. Re-downloads also from `contentVersion` moving on own upload (H3, open).
8. **Items/folders stuck on the replica forever** recurred from different causes: removals filtered (`d1bea01b`, `f779eb51`), unnameable removed children (`1b73dd2d`), stale pages that never delete (`85fd6050`), un-retired old names (`2939226c`, `bc51cd75`), directories answered from the identifier without asking (`717d9a96`).
9. **Silent fallbacks hid failures**: `try?`-to-default config (`f219dc44`, `f81bb083`), empty token from denied read, `readOnly` default false, notify to nobody reported success (`34756cfd`), finishing at the old anchor on error. Many fixes are "make the failure loud".
10. **Two parties restating one rule drifted**: Swift re-deriving key prefixes (`f0e84c91` → removed in `717d9a96`), two IPC clients with drifted error maps (`062dfab9`), CloudStorage naming guessed twice (`ed0084b3`), daemon vs CLI bridge rule (`9b0e8d0d`), menu strings (`43fc21ca`). Each resolved by moving the rule to the daemon.
11. **Verification gap**: Swift could not be compiled on the dev box (`f81bb083` says so); several fixes (`807e1454`, `061b7ab7`) were bugs live for weeks that only a real Mac session showed. Live two-machine driver found `b7e4c849`, `b31dbb7c`, `aebaeff5`.

Overall *(inference)*: the extension trended monotonically toward statelessness (no journal, no flusher, no listing in memory, no anchor logic, no config reads), with the daemon owning every cursor and rule; nearly every regression came from state or rules kept on the Swift side or from assuming a sandbox permission.

---

## 4. Empirically established SDK / fileproviderd behaviours

| # | Behaviour | Established by |
|---|---|---|
| 1 | The system persists identifiers and does not re-ask after a scheme change; existing domains need `reimportItems` or remove/re-add | `21321abd`, `717d9a96` |
| 2 | Returning a different identifier from `modifyItem` = merge; path ids make a folder rename re-identify its subtree unannounced | `717d9a96` (ItemID.swift) |
| 3 | Replicated extensions: only `.workingSet` can be signalled; signalling an item is ignored; directory `enumerateChanges` is never triggered | `b411b18b`, `717d9a96`, `a06abe2f` |
| 4 | Too many items in one enumeration aborts the extension (`__FILEPROVIDER_OBSERVER_TOO_MANY_ITEMS__`, ~100× `suggestedPageSize`) | `71f2e752`, `717d9a96` |
| 5 | Pages/anchors capped at 500 bytes; overflow ends enumeration silently as if complete | `3c1c513a`, `6941a5b5` |
| 6 | Initial-page sentinels are valid UTF-8 (`"FPPageSortedByName "`) | `a06abe2f` |
| 7 | The extension is started/stopped at will (stopped when the domain is idle); pages/anchors outlive the issuing process | `ba6ca8d2`, `34756cfd`, `a06abe2f` |
| 8 | Finishing `enumerateChanges` at the starting anchor on error = "up to date" forever | `717d9a96` |
| 9 | A stale/expired anchor makes the system re-enumerate but it does not remove items it already holds | `85fd6050` |
| 10 | The system refuses to delete a folder that still holds a child it was never told about | `d1bea01b`, `1b73dd2d` |
| 11 | Only `NSCocoaErrorDomain`/`NSFileProviderErrorDomain` errors are accepted; POSIX rejected (`__FILEPROVIDER_UNSUPPORTED_ERROR__`); foreign domains cached as an empty listing | `b411b18b`, `eff2c3ac` |
| 12 | `serverUnreachable`/`notAuthenticated` latch until `signalErrorResolved`; other errors retried; an unknown error on a range is retried forever | `717d9a96`, `51c9b0f6` |
| 13 | A create/modify completing with neither item nor error is unexpected | `9cb2f9c4` |
| 14 | Empty version data is dropped; directory versions must be stable | `813a87c2`, `717d9a96` |
| 15 | Root item's parent must be itself; another parent makes the system invent a container | `717d9a96` |
| 16 | `item(for:)` is the existence authority; answering for a deleted folder keeps it on disk | `717d9a96` |
| 17 | Fields the provider can't store must be returned as pending or the system rewrites them (Finder tags reverted) | `717d9a96` |
| 18 | `supportsSyncingTrash` defaults true → Finder offers Move to Trash | `717d9a96` |
| 19 | The system cancels slow fetches and expects prompt completion; `Task.cancel` does not interrupt a blocking `recv` on a GCD thread | `717d9a96`, `d0e0c1d4` |
| 20 | Partial-fetch alignment is a power of two, varies across reboots; short length allowed only at EOF | `022d7253` |
| 21 | The system unlinks a `createItem`/`modifyItem` contents URL after the callback returns | `717d9a96` |
| 22 | The extension cannot move a file into `temporaryDirectoryURL()` (EPERM, signed and notarized alike) | `eff2c3ac` |
| 23 | The sandboxed extension cannot create files in the App Group container | `717d9a96` (notify.sock never existed) |
| 24 | The sandboxed extension/app cannot read files another process wrote in the group container (TCC `kTCCServiceSystemPolicyAppData`) | `807e1454`, `061b7ab7`, `eec5935f` |
| 25 | `createItem` gets a nil contents URL whenever `.contents` is not in the fields, so a nil URL does not prove the item is a directory or package | `018472fc` |
| 26 | `UTType(filenameExtension:)` gives a dynamic type conforming to nothing for packages; the directory-conforming lookup invents a type for every extension (`.txt` too) | `bdf8a44f` |
| 27 | `providerNotFound` ("in the process of being invalidated") during extension registration swap at install | `58facb6b` |
| 28 | Only the app owning the extension can remove domains | `792e5750` |
| 29 | CloudStorage folder name = `<App>-<displayName minus disallowed chars>` by an undocumented rule | `ed0084b3` |
| 30 | `SMAppService.agent` → `.notFound` for a correct bundled agent; bundled agents need a Team ID | `abf71143`, `afaed1e6` |
| 31 | Extension must live in `/Applications` and be user-enabled; pluginkit must be told to forget/re-add on redeploy | `14f717ca` README, `f219dc44` |
| 32 | A domain comes back empty after reset until a GUI client touches it; `ls` over ssh reads the replica without waking fileproviderd | live testing, spec A16.4 |
| 33 | macOS `setsockopt(TCP_NODELAY)` on a hung-up AF_UNIX socket → EINVAL (Linux: EOPNOTSUPP) | `10a77333` |
| 34 | fileproviderd issues `modifyItem` calls concurrently | `b7e4c849` |
| 35 | Large `NSExtensionFileProviderDownloadPipelineDepth` floods a slow backend with range reads | `45112c33` |
| 36 | `materializedItemsDidChange` fires often enough to overlap with working-set enumeration | `ab4f21e7` |
