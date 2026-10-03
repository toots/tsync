# A — Abstraction, logical and structural issues

This file covers mistakes that are true of any implementation in any language: step ordering and crash consistency, concurrency and exclusion, folder identity and conflicts, failure classification, durable queues, journal and change-feed semantics, store and GC contracts, caches, security boundaries, state ownership, deadlines and truthful reporting. Each entry is a mechanism tsync already paid for. Use it in adversarial review of the OCaml 5 rewrite: for each new module, find the matching theme, run every **Check**, and weigh entries flagged `recurred` and `rewrite` first. Under fibers on a domain pool nothing is atomic between two statements, so every entry that was once "safe because one thread runs everything" is live again.

## 1. Durability, crash consistency and lost writes

### A-1.1 Local record retired before its remote commit
- **Pitfall** — `exec_put` deleted the WAL record, then published the journal entry. A crash between left uploaded bytes, no entry for peers and nothing owed locally: a write that looked synced and was lost. The inline metadata finisher and the queue worker wrote "executed, entry published, cursor moved, record dropped" twice and disagreed on the last two steps; one order leaves a cursor past an entry with no record to reconcile.
- **Check** — Every queue follows intent → execute → commit → retire. Grep every record delete and confirm it follows the publish and the cursor move. The completion sequence exists once.
- **Seen** — PR #35, acd4f1f5. recurred ×2.

### A-1.2 Intent recorded after the local side effect
- **Pitfall** — A metadata op ran its local half, then wrote its WAL record. A crash between left a local change the store was never owed. Replay also re-ran the op under a second record and published the first at once.
- **Check** — The durable intent precedes any local effect. Redo of the local half is idempotent. Replay hands the existing record on; it never mints a new one.
- **Seen** — 8616490a.

### A-1.3 Resume minted a fresh identity for work it was finishing
- **Pitfall** — Recovery called `queue_put`, which mints a new entry key, so each replay published under a new key while the record kept the old one. The next start replayed it again: 295 byte-identical records piled up, and `stats` showed "144 to apply" forever through two code paths.
- **Check** — Every resume path takes its key from the record. A record whose data is gone is discarded with a log line, not replayed forever.
- **Seen** — PR #35, 8616490a. recurred ×2.

### A-1.4 Old representation removed before the new one is published
- **Pitfall** — Promotion ran `put_group`, `discard_bodies`, `Mf.write`, `delete_staged`. Between discard and marker drop, `resolve` still answered Staged for unlinked bodies; rclone's verify got ENOENT, called a 260 MB transfer corrupt and deleted its copy (old order failed 10/10, 23/30 without a retry). A sibling: the old body was forgotten before the new sidecar was written, and the upload queue read the ENOENT as "nothing owed" and abandoned the edit.
- **Check** — Make the new state fully present, flip the selector, then delete the old. Every intermediate state resolves to bytes on disk. Resolve-then-read retries once on a miss.
- **Seen** — 6933cc16, PR #46, notes (release before switch). recurred ×2.

### A-1.5 Commit record not retired by the write that invalidates it
- **Pitfall** — An upload recorded `s_published` and deferred promotion. A write in that window rebuilt the staged record without clearing it, so the next sync promoted the pre-write manifest: an acknowledged write vanished (reads back ZZZZ, not YYYY). Nine construction sites cleared the field by hand; a comment told the tenth.
- **Check** — Lifecycle is a state type (`Owed | Committed`) and writes can only produce the initial state. The promoter re-reads the record under the key lock and abandons if it is gone.
- **Seen** — 8f2c48c4, PR #46, f89a24e1. recurred ×2.

### A-1.6 Publishing content that changed under the upload
- **Pitfall** — Import chunked a source laid out for one length and could publish a mix if it changed. A write landing while a file's bytes were sent would publish a manifest for torn content. `cancel_upload` set a flag, but a manifest put already past the check still published an older edit after a newer one began.
- **Check** — Read and size from one held descriptor; re-check length after hashing. Every upload of a mutable file has cancel-on-write plus an edit-generation check under the key lock at the moment it commits.
- **Seen** — 4f1be8b3, 8f2ccafb, f1091ded, notes (04 B.0.1). recurred ×3.

### A-1.7 Failed read substituted by zeros or empty, then published
- **Pitfall** — `fill_from_staged` read any failure to open a staged body (EMFILE, EIO) as missing and uploaded zeros. Android's edit-open started from an empty file after a failed fetch, so a blip plus a save published a truncation (append mode too). Concurrent range fills [0,4) and [10,12) were merged to claim [0,12), and the zeros in the gap were persisted and republished.
- **Check** — No path substitutes zeros or empty for bytes it failed to get. An open for non-truncating write fails if the base cannot be read. A fill tracker claims only bytes it wrote.
- **Seen** — fa0a4fd5, PR #86, notes (failure-model, read-path). recurred ×3.

### A-1.8 Sole-copy data reachable by eviction or rebuild
- **Pitfall** — Staged bodies (unpublished, no other copy) and re-fetchable cache groups lived in one store under one naming; only documentation kept the cache cap from deleting staged data. Staged manifests sat beside the published projection, which a resync drops.
- **Check** — Sole-copy data lives in a store eviction and resync cannot name. A test proves staged data survives cap=0 and a full resync.
- **Seen** — 75c90fdd, 2d0f0fc9.

### A-1.9 Internal-name predicate matches user files
- **Pitfall** — `is_internal` matched any `.tmp` suffix: matching manifests were hidden and `clean_tmp` unlinked them every start. Syncthing's `.syncthing.<name>.tmp` partials were swept, so a folder pulled 12.4 GB in a loop and landed none. A user file named `.tsync-dir` was stored raw and read back as a marker: imported, uploaded, absent from every listing.
- **Check** — Generating and recognising a reserved name live in one module with one sentinel. User components matching the reserved family are escaped. Tests cover the negative cases.
- **Seen** — cfdc0752, bbf43821, 204a040b, e3225489. recurred ×3.

### A-1.10 Small state file overwritten in place
- **Pitfall** — `open_out` truncates before writing, so a crash left an empty last-sync mark, read as a domain never synced.
- **Check** — Every persisted state file is temp + fsync + rename. Empty or missing is never indistinguishable from a legitimate initial state.
- **Seen** — 5e23e54a, PR #85.

### A-1.11 Nothing fsynced
- **Pitfall** — WAL records, queue records, staged sidecars, partial records, the client uuid and directories after rename, link or unlink were never fsynced, nor were `mkdir -p` parents. A failed local `put` left its temp file. A USB bridge that reports no FUA makes this real.
- **Check** — Fsync the temp before every replace-by-rename and the directory after every name change that must survive. Clean the temp on failure. A syscall seam lets a test assert fsync-before-publish.
- **Seen** — notes (04 B.0.1, backends/local B-0, durable-queue).

### A-1.12 Torn last record glued onto the next append
- **Pitfall** — Newline-terminated records: a writer torn mid-record left no terminator, the next append glued on, and the result parsed as a key nothing wrote.
- **Check** — Append-only logs are newline-led or length-prefixed with a checksum; a torn tail is skipped, never merged.
- **Seen** — 20a26efa, PR #80.

### A-1.13 Every crash point of a multi-step mutation not enumerated
- **Pitfall** — Promotion before Executed completed a Prepared record without publishing its entry. EXECUTED kept the original ops while the queue published rewritten ones, so recovery republished the originals. Retarget moved the file before rewriting the record, so a crash re-derived a second aside name. Retire-stale-source moved and forgot before re-pointing the id.
- **Check** — For each multi-step mutation list the crash points and the recovery for each. Record the as-published form before, or atomically with, the effect. Run the crash-at-every-step harness.
- **Seen** — notes (04 B.0.1, wal-and-journal §3, conflict-resolution §2).

### A-1.14 Referent deleted after the index that names it
- **Pitfall** — Purge deleting the trash marker first strands every key under it. GC close deleting on the main before copies lets the main forget keys copies still hold: a permanent leak. Expire batches with unspecified inner order could drop a trash entry before its subtree.
- **Check** — Delete referents before the index; delete dependants before the authority that enumerates them; advance the cursor only after the whole batch is acknowledged.
- **Seen** — 9327a879, PR #42, notes (data-model/backend). recurred ×3.

### A-1.15 Marker or resume token advanced before its work
- **Pitfall** — The macOS reset marker was deleted before the removal ran, so a refused reset was forgotten; a purge deleted its marker whether or not anything was removed. Identity-scheme completion waited on every unwanted domain, including config-dropped ones, so one leftover rebuilt every domain at each login. A cursor watch moving `last_version` above the apply loses the change.
- **Check** — A pending-action marker clears only after the action is confirmed, judged only on what that action asked for. A resume token advances only after the work it covers.
- **Seen** — 2cc2fd00, f81bb083, 9b4c3156, PR #101, PR #72. recurred ×3.

### A-1.16 Orphaned staged bodies
- **Pitfall** — Delete and revert left staged bodies behind; a crash between staging a body and writing the manifest naming it left unreachable bodies.
- **Check** — Every removal drops what only it referenced. Startup runs a reachability sweep before replay can stage new bodies.
- **Seen** — f8f3f9eb, 19d2a9c7.

### A-1.17 Create then write publishes an empty file on crash
- **Pitfall** — `create` wrote a size-0 staged manifest, so a crash before `write` published an empty file. An upload minted a folder id without a Mkdir entry. Ingest renames away its input, so pointing it at a DCIM file would delete the user's photo.
- **Check** — Whole-file ingestion is one atomic call; folders are created explicitly first; an API that consumes its input is never handed user originals.
- **Seen** — PR #57.

### A-1.18 Fast path skips a slow-path invariant
- **Pitfall** — The hard-link publish skipped the length check the copy path made, risking corruption of a content-addressed body shared by every file grouping the same way. A Zero member was staged only if fully covered, so an "impossible" assertion fired 8 MB into a copy.
- **Check** — Fast paths enforce every slow-path invariant and fall back on mismatch. Every member a write loop touches is staged; coverage only decides whether to skip the read.
- **Seen** — 3adc66f3, 21610632. recurred ×2.

### A-1.19 Layout recomputed from current config
- **Pitfall** — A staged chunk's offset in its group depends on `cacheChunkSize`, which can change between runs.
- **Check** — Anything describing where bytes already sit is stored with them, never re-derived from config.
- **Seen** — PR #46.

### A-1.20 Durable path or format changed without migration
- **Pitfall** — `lane-pending/` became `deferred-pending/`; queued work was orphaned by the upgrade and repaired only by a manual `resync-remote`.
- **Check** — Any change to a durable path or format reads the old one or migrates it.
- **Seen** — 9b0f6af2, fcf7b854, PR #38.

### A-1.21 Open: content no client wrote, divergence after remount
- **Pitfall** — The stress crash mode reported seven paths holding content no client wrote; store bug vs oracle bug was never settled. Clients agreeing on folder ids still diverged after remount, suspected staged content surviving a crash. The harness seeded from thread ids and its oracle skipped renames.
- **Check** — A SIGKILL mid-write leaves old or new content, never a mix or foreign bytes. Stress harnesses use deterministic seeds and an oracle covering every op, rename included.
- **Seen** — 698cdef5, PR #38.

### A-1.22 Reaper treats "unreferenced" as "garbage"
- **Pitfall** — The startup spool sweep deleted every temp in the spool directory, so a second import unlinked the running import's spool, which lost every op since its last publish and died at seal with a bare ENOENT. A temp nobody has renamed yet, or a staged body no manifest names, is exactly what an in-progress write looks like; with two frontends on a domain one collected bytes the other was writing. A killed import's spool had no reaper at all.
- **Check** — A reaper proves the writer is dead: a pid in the name that is gone, an age cutoff for ownerless staged bodies, or running before any writer exists. Every temp artefact has a reaper.
- **Seen** — 5889d8ac, 234dcb5a, 99695932, 2cd7c353. recurred ×3.

### A-1.23 Acknowledged to the user before durable
- **Pitfall** — Android's share sheet called `finish()` before the commits ran, so a kill lost the shared files, and staging was swept after 24 h. Picker writes had no ingest intent.
- **Check** — Ingest is durable before the UI is acknowledged; every write entry point records intent.
- **Seen** — notes (android B-0).

## 2. Concurrency, atomicity and exclusion

### A-2.1 Check-then-act that relied on cooperative atomicity
- **Pitfall** — Dozens of sites were atomic only because no yield sat between check and act: pool `held`/`waiting` and the `each` cursor (two workers, one index, a NUL key published), durable-queue tables, health probe hand-out, subscriber empty-check-then-wait, entry-key `last_ms` and the folder-id lease counter (duplicate keys/ids), `temp_seq`, `try_admit`-then-`acquire`, memo caches, metrics counters "unlocked because single-threaded". On the domain pool, rsync's byte counter, a plain ref updated from parallel upload callbacks, lost updates.
- **Check** — Every shared table, counter or flag is behind a mutex, an Atomic, or confined to one fiber. Admission is one `try_acquire`. Single-flight cells are mutex-guarded promises. Callbacks from parallel work are serialised or atomic. Treat every "single-threaded" comment as a bug.
- **Seen** — 16f76240, notes (01 B.3.3, 02 B.5, 03 B-II.2, 04 B.2, http-proxy B13, android B-II.1), 94fb33ca. recurred (dozens of sites), rewrite.

### A-2.2 In-flight dedupe dependent on scheduler ordering
- **Pitfall** — The fetch and folder-walk in-flight tables worked only because the scheduler paused before the second caller looked, or because a promise could be asked whether it was "still sleeping". The walk table also kept finished work.
- **Check** — Insert before starting, start on an explicit signal after insertion, remove on every exit including errors. Nothing depends on "no yield between these lines".
- **Seen** — 715a4bbc, 5eff4a06.

### A-2.3 No per-key exclusion between body mutation and promotion
- **Pitfall** — Promotion hands staged bytes to the chunk store under a hash-derived name; a write or truncate in between tore groups in 9 of 12 runs. `with_meta` did not cover write, truncate or promotion. `Data.sync` committing outside `with_key` was left open.
- **Check** — Write, truncate, create, stage, discard and promote serialise on a per-key lock. Uploads and long reads stay outside it. Promotion re-reads state under it.
- **Seen** — b836e4bc, 291e583d, PR #46, PR #85. recurred ×2.

### A-2.4 Reference resolved outside the lock it mutates under
- **Pitfall** — An IPC handler resolved a reference to a path before taking the mirror lock. With several File Provider requests in flight, `mv f4 sub/` racing `mv sub sub2` re-created `sub` beside the renamed folder, journaled it, and every replica agreed on the wrong tree. The rewrite hit the same need and required a reentrant metadata lock.
- **Check** — Resolve and mutate in one lock hold. If helpers re-take the lock, it is reentrant or has an explicit locked/unlocked split. Tests assert the intended tree, not only convergence.
- **Seen** — b7e4c849, b7fd7943, PR #87, 5ee48495, rewrite (`Dqueue` retry called `forget` holding `t.m`; OCaml 5 raises on the second lock and the worker died). recurred ×3, rewrite.

### A-2.5 Store round trip under the global metadata lock
- **Pitfall** — The lock FUSE and IPC handlers wait on was held across network I/O: an inline cursor bump in a rename, every rename/delete/rmdir's store half and retry ladder (the mount froze while one store call failed), a version snapshot retrying a 500 for about 50 s, a peer entry's manifest fetches, store reads passed in as closures, a revert fetching and publishing under it, a new file asking an http-proxy store for its recommended chunk size (with the store down, every mutation of the domain waited for the retry ladder).
- **Check** — Read the store first, then take the lock and decide from data (tables, not callbacks). Local ops complete from local state plus a WAL record. Make holding the lock across a request fail to compile: the lock is private to the module changing local state.
- **Seen** — 88db71c8, ed04657a, 39568d9c, e8fe2452, 1cd593db, ab3811bd, 2a59d643, PR #92, 2d146f24. recurred ×8, rewrite.

### A-2.6 Buffer released while an asynchronous consumer still reads it
- **Pitfall** — `Bytes.unsafe_to_string` on a pooled buffer was passed to put; it returned to the pool while a deferred target still sent it, so the next chunk's bytes went out under this chunk's key. Size checks could not see it and dedup spread the bad bytes into every later file with that chunk. Fixed again in the mirror path.
- **Check** — A body handed to an asynchronous sender stays owned and immutable until every consumer, deferred targets and retries included, has finished. Audit every pool release against all readers.
- **Seen** — 82abb725, 2347cbcb, c8dfe860, PR #50, #51, #53. recurred ×2.

### A-2.7 Nested acquisition of the same pool
- **Pitfall** — Range-read pieces taking the download budget inside a piece slot; GC with one pool for roots and their chunks (every slot a root awaiting a chunk); a composite forwarding through `Batched` holding the caller's slot; a walk holding a stat slot across recursion; mirror probe-then-copy.
- **Check** — Never wait on a slot of a pool you already hold. Separate pools per nesting depth. A contention test forces the nesting (eight roots × eight chunks, two slots).
- **Seen** — 00585588, PR #42, notes (01 B.3.6, 02 B.2, 05 B.2, 06 B.0.3). recurred ×5.

### A-2.8 Lost wake-up
- **Pitfall** — "Record written" to "uploader sends it" used a bare condition; a signal with no waiter was lost and the upload waited for the next start. In the rewrite, holding lifted a catch-up gate without signalling it, deadlocking the rebuild that ends the hold.
- **Check** — A wake-up channel carries the work item (queue + condition). Every state change that can satisfy a wait signals it; check each hold, gate and pause transition.
- **Seen** — b6ede846, 93f40a22, 440f3ee8. recurred ×2, rewrite.

### A-2.9 Register-then-send gap for a late subscriber
- **Pitfall** — Handing a late subscriber the recovery notice after registration could race events published in between.
- **Check** — Initial state is delivered atomically with registration.
- **Seen** — 3ff7eaf7. rewrite.

### A-2.10 Several processes mutating one domain's local state
- **Pitfall** — The launcher parent converged while each forked frontend ran its own queues and `sync`/import/rsync wrote the mirror, staged tree and WAL, guarded by per-process mutexes. A peer delete in the parent discarded a staged edit a FUSE child had just written (confirmed loss). Android's exec'd verbs and its linked upload queue were unordered. The durable-queue `.owner` claim was taken by every runner and checked by none, so a Prepared record could publish twice in either order. Startup recovery per process deleted bytes another frontend was writing.
- **Check** — One owner process per domain; every mutating command (import, rsync, sync, trash, gc, export records) runs in it or holds a cross-process lock. In-process locks never stand in for cross-process exclusion. Destructive recovery runs before anything serves.
- **Seen** — cc90f688, PR #68, PR #86, PR #104, notes (07 B.4, 04 B.0.1, durable-queue), 656700ab. recurred ×4.

### A-2.11 Active work started before a fork
- **Pitfall** — Stores, with a resuming replica queue, were built before frontends forked; the daemon, FUSE and http-proxy each uploaded the same head job at a third of the link.
- **Check** — No queue, timer or worker starts before a fork. Children record work; the owner runs it.
- **Seen** — 80b5e045, PR #104.

### A-2.12 Single owner chosen by a non-unique value
- **Pitfall** — Ownership compared frontend type strings, so a domain listing one type twice had two owners. FUSE iterated a domain list though given one domain.
- **Check** — Election uses a unique identity. Configurations a component cannot honour are refused.
- **Seen** — 890ded8c, a35b9d24.

### A-2.13 Making an operation asynchronous broke callers that assumed completion
- **Pitfall** — Rename-race scenarios relied on a rename being published when its step returned; once the metadata queue took the store half, the kept log came out in either order one run in eight.
- **Check** — Any change that makes an operation asynchronous audits callers relying on completion on return; tests drain explicitly.
- **Seen** — 13541674, 6468cf84.

## 3. Namespace identity, claims and conflicts

### A-3.1 Contested name written with an unconditional put
- **Pitfall** — Two clients creating one directory both minted an id and wrote the marker; the last won and the loser's files sat on every backend, listed by nothing: an acknowledged write gone with no report. The neighbouring test missed it because the losing namespace was empty.
- **Check** — Every marker write is a store-native conditional create returning the holder; losing is an ordinary outcome. Never HEAD+PUT. Naming-race tests write content under the contested name.
- **Seen** — 284521fd, 0265e0e5, c51dba7f, PR #38. recurred ×3.

### A-3.2 Claim protocol gaps
- **Pitfall** — An old proxy ignoring `if_absent` overwrote and answered empty, read as a win. A non-transient failure, including S3's retryable 409 ConditionalRequestConflict, fell back to a plain PUT over the winner. Mkdir, move-destination and restore used plain puts. The winner was decided by physical buffer equality, so a lost-reply retry answered 412 counted as a loss.
- **Check** — Claims answer `Won | Held`, byte-identical holder = Won. No plain-put fallback on a slot. Version-check the peer's claim support; probe custom S3 endpoints for conditional create before first use.
- **Seen** — notes (data-model/backend, 02 B.4, 06 B.0.1, backends/s3), 57556da2. recurred ×2.

### A-3.3 Stale marker left by a non-atomic move trusted
- **Pitfall** — A client moved 22 folders, trashed and restored them: every marker put landed, no delete did, so each id sat at two paths; 47 trash entries named restored folders that expire would have reclaimed. Later: adoption compared only the anchor's parent, so a same-folder rename's leftover lent its id to a new directory; a claim treated any marker as a live holder.
- **Check** — Every orphanable pointer has a verifier (the folder's parent anchor), written before the old marker goes. Walk, claim, adoption, expire and GC share one marker-vs-anchor predicate. Nothing anchored elsewhere is reclaimed.
- **Seen** — c3ae1e7c, a2786afb, 82eb4dde, c964322d, bb795b9c, PR #88. recurred ×4.

### A-3.4 Destructive step cannot say whether it acted
- **Pitfall** — Every driver's delete answered alike whether or not an object existed (S3 answers 204), and a rename skipped the old-marker delete when the local index lacked the parent id. Both silences produced the duplicate-id state above.
- **Check** — Steps an invariant depends on report whether they acted; the operation fails and undoes local changes when they did not. Never skip a step because a local cache lacks data; refuse before anything moves.
- **Seen** — bb795b9c, PR #88.

### A-3.5 Identities unique only by chance or per process
- **Pitfall** — Folder ids were 64 random bits per process. Entry keys were monotonic per process only, not initialised past used keys, and any process sharing the uuid minted. Durable job names from a plain counter collided across the daemon's forks and one-shot commands.
- **Check** — Cross-client ids are client id + a leased counter (O_EXCL lease). One process mints per client uuid, initialised past every used key. Job identities are unique across every enqueuing process.
- **Seen** — addadddc, 9b0f6af2, notes (wal-and-journal §3). recurred ×3.

### A-3.6 Temporary names unique per host only
- **Pitfall** — Local-store temporaries `.tsync-tmp-<pid>-<seq>.tmp` were opened without O_EXCL, so two hosts on one NAS could share a name; nothing swept orphans in store roots.
- **Check** — Temporaries in shared stores have random names, O_EXCL, and an age sweep.
- **Seen** — notes (backends/local B-0, 01 B.3.7).

### A-3.7 Identity overwritten by a later write
- **Pitfall** — `Folder_ids.write` replaced an existing id, so a lazy listing could replace the id references already named.
- **Check** — Identity is write-once; replacement is a separate operation used only by a full rebuild.
- **Seen** — 8dfe0239.

### A-3.8 Directory materialised without its id
- **Pitfall** — A put materialised parent directories without ids; later fetches built keys from a missing parent id and skipped silently. A partial resync recorded its cursor and exited 0.
- **Check** — Every path that materialises a directory adopts the id from the store's marker and never mints. "Cannot name" is counted and reported.
- **Seen** — f32e529a.

### A-3.9 Directory move owes a caller-remembered second write
- **Pitfall** — Moving a directory needed the escaped-name marker and the folder's id marker; the caller restated the second at two sites. Missing it leaves the id resolving to the old location.
- **Check** — The move primitive updates every index keyed on the directory; no caller post-step.
- **Seen** — 65636755, ea959665. recurred ×2.

### A-3.10 Name in the body diverges from the name the location encodes
- **Pitfall** — The manifest's `name` was the listing authority; a rename moved the file but the body still said `b.tmp`, so `ls` showed an unopenable name and Syncthing re-fetched 12.4 GB indefinitely. It recurred for escaped directories' markers.
- **Check** — Derive a name from its location; store it only where the location is lossy. Rename re-stamps inside the primitive, for files and directories.
- **Seen** — 31e941ec, 7600bd60. recurred ×2.

### A-3.11 Rename onto a name another folder holds
- **Pitfall** — A folder renamed onto a peer's different folder overwrote its marker and stranded its subtree; the peer failed ENOTEMPTY every 2 s forever. Variants: source and destination holding the same id locally; a second conflict moving onto the first conflicted copy's name.
- **Check** — Every loser goes to a free conflict name. Marker removal is conditional on it still naming the moved folder. "Destination already holds this id" counts as applied.
- **Seen** — 0a300530, 8f37df8d, 5ce27035, 8f15cd53. recurred ×4.

### A-3.12 "Is this name free" consulted only the visible tree
- **Pitfall** — Two unpublished files with one leaf under a folder a peer removed were rescued onto the same conflicted name; the first was overwritten everywhere. A second conflict on one name reused the first conflict's name.
- **Check** — Free-name checks consult mirror and staging; conflict names are unique per conflict.
- **Seen** — fa63f5aa, PR #92. recurred ×2.

### A-3.13 Foreign op over unpublished local work skipped
- **Pitfall** — A peer's op on a key with a staged edit was skipped, leaving 13 vs 11 bytes under one name, both sides reporting nothing to apply. A peer rename over something written locally was skipped yet counted applied (rows F10, D9).
- **Check** — Every (peer op, local unpublished op) pair has a convergent outcome in a pure decision table, one scenario per row. "Skip and mark applied" is never an outcome; the local copy moves aside and is queued.
- **Seen** — edece309, d1d5b3db, 7e1957df, 79a43154, f5513d0b, e6f2ceb3, PR #81, PR #92. recurred ×3.

### A-3.14 Conflict-table holes
- **Pitfall** — Delete and file-rename arrivals consulted no store record, so a late delete removed a restored file. No `renamed_onto` for deletes or rename destinations. Rescue flattened files to the root and lost unpublished subfolders. A rename after a peer's rmdir pulled the folder out of the trash. A file/folder kind clash with both sides published stayed divergent; symmetric moving aside swapped the sides. Published losing writes survive only in version history.
- **Check** — Every clash has a winner both machines compute identically (later key wins). Print the table and review it. Scenarios assert identical trees and contents on both clients.
- **Seen** — PR #81, PR #85, PR #92, notes (conflict-resolution §2, 09 B0.3), spec issues 4, 5. rewrite.

### A-3.15 Arrival under a trashed ancestor
- **Pitfall** — A client that had published a folder's removal still applied a peer's earlier addition inside it, showing a file the store held in the trash.
- **Check** — The store record at a path under a trashed ancestor is absent; arrival facts consult the ancestor chain.
- **Seen** — 05f75111. rewrite.

### A-3.16 "Staged" predicate wrong for directories
- **Pitfall** — A folder counted as staged if its staged-tree directory existed, which a published upload leaves empty, so a folder ever written into never followed a peer's rename. Inversely, `Staged_manifest.exists` answered true for the directory above a staged file, so a peer's mkdir moved unpublished work aside as a file with nothing owed. The rewrite read a directory as an edit and failed EISDIR.
- **Check** — "Staged at p" means a staged manifest at p (file) or under p (folder). Test both queries where p is a directory in the staged layout.
- **Seen** — b31dbb7c, 090e269c, 7059de7a, PR #87, d60b04e1. recurred ×3, rewrite.

### A-3.17 Pending work not retargeted when its folder moves
- **Pitfall** — Queued uploads kept the old path after a folder rename, found nothing, and still published, telling peers of a file the store never had. An upload whose staged bytes were gone returned as sent. Re-queued uploads took entry keys ahead of the rename, so a peer replayed the put first and kept the source as an id-less conflicted copy.
- **Check** — A local move retargets every pending op under it after recording itself. Nothing to send means "nothing owed", publish nothing. Entry order follows causal order.
- **Seen** — 20a75592, f7920772, c61df832. recurred ×3.

### A-3.18 Queued ops resolve their target by stale path
- **Pitfall** — A queued rmdir or rename trashed or re-created a folder the store never had; an offline nested removal parked the inner rmdir forever and left a file delete unsent. An upload into a folder with an owed mkdir claimed the marker itself.
- **Check** — Queued ops resolve by id at publish time (live, moved, removed, unknown, decided in one place) and publish nothing for what the store never held. Uploads wait for their folder's owed mkdir.
- **Seen** — 5eaf92b8, 1cd593db, d1d400db, notes (wal-and-journal §3).

### A-3.19 Rebuild from remote while metadata is owed
- **Pitfall** — A full resync restated the store's tree over unpublished local metadata ops.
- **Check** — Refuse or drain first any rebuild while the WAL holds owed metadata. Lazy browsing never prunes unpublished work.
- **Seen** — d68f0ce4, PR #92.

### A-3.20 Only the first key of a rename consulted
- **Pitfall** — `List.hd (op_keys op)`: a peer's rename invalidated the new name and the mount kept serving the old; the replay filter, filled with every key and read with one, could replay a rename over a source a peer had written. Open: exact-key filters miss writes under a renamed directory; `on_changed` announces the peer's keys, not the conflicted-copy name.
- **Check** — One accessor returns every key an op touches, with subtree semantics for directories. No "primary key" accessor in invalidation or conflict checks.
- **Seen** — f8c107fa, b41e6875, PR #100, PR #102. recurred ×2.

### A-3.21 Listing yields a name twice
- **Pitfall** — readdir concatenated file and directory listings, so a name carried by a file key and a folder marker appeared twice (17 vs 16 entries on the peer).
- **Check** — Listings yield each name once; collisions are logged.
- **Seen** — 22370770.

### A-3.22 POSIX namespace contracts ignored
- **Pitfall** — rmdir removed non-empty folders; NOREPLACE overwrote and EXCHANGE did a plain rename; creations were not exclusive; the FUSE hide-rename deleted a file a holder still read; an unreached `O_CREAT` branch would have discarded staged edits.
- **Check** — Refuse what POSIX refuses (ENOTEMPTY, EEXIST under NOREPLACE); honour or refuse EXCHANGE; replaced or unlinked open files stay readable through a retention.
- **Seen** — notes (fuse B-IV, file-provider B-0), fcd5e7dc.

### A-3.23 Identifier from lossily decoded bytes used for writes
- **Pitfall** — Replacement characters from non-UTF-8 names landed in item references; a modify would write a second file and fail to delete the first.
- **Check** — Items named by lossy decoding are read-only, or references carry raw bytes.
- **Seen** — PR #101.

### A-3.24 Cycle guard by hop count
- **Pitfall** — `key_of_id` capped its climb at 256 hops, bounding real depth; a failed check triggered a full mirror walk though the real case was a deleted folder.
- **Check** — Detect cycles with a visited set. A lookup miss does not heal by a full walk.
- **Seen** — 1b08744e, PR #79.

### A-3.25 Name allocation from a partial listing
- **Pitfall** — Android child lookups read one page and ignored `next`, so `freeName` picked a taken name and `write` replaced it; `isChildOf` rejected every subfolder.
- **Check** — Page every lookup to completion. Name allocation is exclusive at the owner, never check-then-act across requests.
- **Seen** — notes (android B-0).

## 4. Failure classification: absent, unknown, transient, permanent, cancelled

### A-4.1 "Could not look" read as "absent"
- **Pitfall** — `Sys.file_exists` false on EINTR would mint a new client uuid over the live one and abandon every unfinished WAL record. A stat behind a reimport guard read every failure as not-found and re-uploaded. Any `put_if_absent` failure read as "cannot arbitrate" claimed the name without a marker. An adoption took a store failure as a free name. An unreadable macOS `config.json` read as no domains removed every domain and its local copies. `read_file_opt`, `stat_opt`, `readdir_list_quiet` and `read_last_sync_key` answered None/`[]` on any error; Android `Ingest.children` answered "no children" and name allocation overwrote a file. Status folded only errors into "0 domains, 0 processes".
- **Check** — Every read returns present / absent / failed; only an explicit not-found is absent. Grep for `with _ ->` on read paths: any destructive, creating or advancing decision under it is a bug.
- **Seen** — 274cc0ab, a9a475f8, 82eb4dde, f81bb083, 91c00a2a, 8e308e4a, 4a0602e7, 37c0d67d, PR #70, #83, #87, #97, #101, #102, notes (failure-model §2–3, 01 B.3.4, android B-0), rewrite (the integrity walk skipped an unreadable folder, so repair trashed live folders below it as orphans). recurred ×10+, rewrite.

### A-4.2 Answer derived from failures memoised
- **Pitfall** — Capabilities merged over zero answering members became `no_caps` (no share URL, default chunk size, unverified) and were memoised for the process life. The proxy driver kept a failed capabilities answer forever. With the main held, capabilities and chunk size came from a replica alone.
- **Check** — "Nobody answered" raises; it never returns a default. Nothing memoises an answer built from failures. Domain-level facts never come from a copy alone.
- **Seen** — 923ed43e, b85ea256, PR #102, notes (replication). recurred ×3.

### A-4.3 Unreadable safety marker read as the unsafe default
- **Pitfall** — An unparseable collection-run marker read as idle, removing the second-space lookup exactly mid-collection, so live chunks read as missing. Publish read the marker once and an unreadable one read as idle. A cached "idle" flag that finds nothing turns a stale cache into a false not-found.
- **Check** — Marker existence, not parse success, gates the safety path; unreadable means "a run may be open". A cached flag short-circuits only where being wrong costs performance; a miss re-reads the marker before reporting.
- **Seen** — e111e044, PR #40, notes (02 B.4). recurred ×2.

### A-4.4 A copy's miss taken as authoritative
- **Pitfall** — `walk(stop_on_miss)` answered Miss when the main was unreachable and the replica missed. The old http-proxy client, with no first-use binding, answered get, range, head and delete as absent for a domain the server did not serve; an empty store looks like mass deletion to sync.
- **Check** — A miss is authoritative only from a main, or when no earlier member failed. A driver binds once and refuses to operate on an unserved domain; "not served" is a failure.
- **Seen** — spec issue 3, 332aa06c, notes (http-proxy gaps), 1facd6a9, 96d1a72e. rewrite.

### A-4.5 Failure vocabulary defined per driver, unknown defaults to transient
- **Pitfall** — "Transient" was defined four times (S3 errors, HTTP status twice, local not at all) with three copied retry loops; a permanent 403 retried forever with no reason kept. Unrecognised exceptions defaulted to Transient and fed the breaker. The local driver leaked raw `Unix_error`, so EACCES on put retried forever while on get it was permanent. A frame-decoder `Failure` read as transient. CORRUPT and UNPREPARED shared a constructor. A failed DNS resolution reached callers raw and was classified as this client's own permanent error. Clients disagreed on 429.
- **Check** — One vocabulary (LOAD, LINK, CORRUPT, REFUSED, UNEXPLAINED) owned by the store seam; each driver maps only its own errors, at its boundary. One retry loop; out of tries it raises one typed "link failed". UNEXPLAINED stays out of the breaker.
- **Seen** — PR #35, PR #38, PR #67, 79333d45, notes (failure-model §2–3, 06 B.0.1, backends/local B-0). recurred ×4.

### A-4.6 A generic queue's classifier defaulted
- **Pitfall** — The generic queue's default classifier treated `Backend_error` as transient, so a permanent failure retried forever instead of being poisoned. An `Invalid_argument`/`Failure` taken as transient wedges an ordered queue.
- **Check** — The classifier is a required parameter. In a path where retry never ends, unknown is permanent.
- **Seen** — 626b6c85, 69544d65. recurred ×2.

### A-4.7 Failure class lost on the wire
- **Pitfall** — The http-proxy answered every escaping exception with 500, which clients retry: a rename whose source was gone cost 8 round trips and 8 ERROR lines; the small proxy host logged 196 lines over 35 keys in half an hour. The local copy blamed the destination for the source's ENOENT. Router errors carried no code, so Swift read them as `internal` and retried an unserved domain forever. A corrupt chunk mapped to `unreachable` (latches a macOS domain offline) and a down store to `internal`.
- **Check** — Permanent refusals cross the wire as 409 with a kind; every error reply carries a code. Errors name the object actually missing. Only true unreachability latches a frontend offline.
- **Seen** — 48e797b4, PR #94, notes (failure-model §2, file-provider B-0). recurred ×3.

### A-4.8 Error mapped to a code the caller retries forever
- **Pitfall** — A file shorter than the size a range was built from produced a zero-length range; the daemon rejected it as invalid, which the system retries forever.
- **Check** — "Version changed under the request" maps to a version-gone error that refetches.
- **Seen** — PR #101.

### A-4.9 Retry loop that discards the error
- **Pitfall** — A setup step retried an IAM grant 10 times over 50 s and reported "did not succeed" with no reason; the error could never succeed.
- **Check** — Retry loops keep and report the last error, and fail permanent errors on the first attempt.
- **Seen** — 27685a67.

### A-4.10 One unappliable item blocks an ordered consumer
- **Pitfall** — A peer's folder rename onto a non-empty directory failed ENOTEMPTY every 2 s for 8 hours (5,500 log lines, about 1,900 entries stuck); one rename froze a machine for two weeks. Applying one rename created the next collision. On the publish side, a rename whose source a peer removed failed identically at the head of the ordered metadata queue.
- **Check** — Link down waits at the head; "this item cannot succeed here" is parked, counted, reported in status and retried by a sweep while later work proceeds. Unexplained failures in ordered work park; they never loop.
- **Seen** — 0872ce2f, 25b767d9, 69544d65, 7e99a17a, 79333d45, 9efe236e, 9b73f41c, fa549e93, PR #92. recurred ×6.

### A-4.11 Retry re-queued at the tail of an ordered queue
- **Pitfall** — A transiently failed rmdir went to the tail and was overtaken by the later mkdir, which then conflicted with the folder being removed. A job parked by Stop stayed in the loaded set, so re-adopting its record was ignored.
- **Check** — Ordered queues retry at the head. Parking or stopping removes the job from every in-memory dedupe set.
- **Seen** — 5dcca235.

### A-4.12 Cancellation read as failure
- **Pitfall** — A deadline cancelling a request made the retry loop climb on behind a caller that had left. A probe cancelled by its deadline told health nothing, so each guarded write re-probed: 10 s per corrupted chunk in `--repair`. Bounding a stop's drain by a timeout cancelled the running job and the metadata queue recorded a permanent failure and went degraded.
- **Check** — Cancellation is its own outcome: retry loops stop, queues leave the record as it was, and a timed-out probe still records "no answer within deadline" on health. Race a drain against a deadline; never cancel it.
- **Seen** — 91c1a104, 7819f1c4, 9ea6d6c3, PR #102, notes (failure-model §3). recurred ×3.

### A-4.13 Stop confused with superseded or with failure
- **Pitfall** — The upload and metadata queues read `Retry.Cancelled` as superseded and completed the record, so a stop raising it would lose work. A catch-all in `Job_copy` caught `Stopping` and fell back to a full `Job_put`, holding the drain to the grace. Old journal reads turned Stopping and Cancelled into `None`.
- **Check** — Shutdown has its own exception, never retried, never counted as failure or cancellation. Every catch-all re-raises it first.
- **Seen** — PR #105, PR #108, c3c4a983, notes (wal-and-journal §3). recurred ×3.

### A-4.14 Batch failure handling at the wrong granularity
- **Pitfall** — A multi-object read fails whole, so one bad object lost every sibling; a listed-then-deleted key must read as an unreadable child, not be omitted. Conversely, a batch failing after retries was re-asked key by key by both the composite and the walk, each with its own retry loop: one lost request became minutes of stalling and hundreds of warnings, and the run restarted from zero.
- **Check** — Degrade to per-key only for a store's refusal of specific keys; a link loss propagates once. Retries live in one layer. Absent and unreadable stay distinct through the fallback. Partial progress is checkpointed.
- **Seen** — 6cd1d890, 0604df12.

### A-4.15 Best-effort side step fails or outlasts the primary write
- **Pitfall** — `save_version` checked existence on the primary only; a replica lacking the manifest failed the copy and the rename it preceded. Its HEAD was outside the catch, and a 500 on the copy retried about 50 s.
- **Check** — A tolerated step is wrapped whole and bounded by a deadline shorter than the ladder of the operation it precedes.
- **Seen** — 50b188da, 39568d9c, PR #92. recurred ×2.

### A-4.16 Failed parse coerced to a default
- **Pitfall** — An unreadable IPC listing entry was replaced with the domain root and grouped under it. `Item_ref`'s fallback case meant both "named by key" and "parse failed", so a reference to another domain was answered as this domain's key.
- **Check** — A failed parse is its own outcome, dropped or refused.
- **Seen** — bc679a9f, 95778fb8. recurred ×2.

### A-4.17 Legitimate absence raised as an exception
- **Pitfall** — Trash restore did `Option.get` on a parent id the client never resolved; the CLI died with a backtrace.
- **Check** — "Not yet known locally" is an outcome with guidance ("sync first").
- **Seen** — 679ba3de.

## 5. Durable queues and owed work

### A-5.1 Re-reading or re-adopting a log runs a job twice
- **Pitfall** — `resume` enqueued everything the log held, so a periodic rescan re-enqueued queued or running records. `adopt` could be offered the same record by a rescan and by the writer.
- **Check** — The queue tracks held ids from load until unlink; resume takes only others. `post` and `adopt` share one `take` path, idempotent on id.
- **Seen** — 2c07f6ab, 217de253, PR #52. recurred ×2.

### A-5.2 Unreadable record dropped silently
- **Pitfall** — An unparseable record was discarded: a write the target owed and would never receive. The first fix returned a count to the caller of `list`, but the WAL and a target queue both read records, so whichever came first swallowed it. Any failed read was treated as corrupt and deleted, conflating "completed elsewhere mid-sweep" with "unreadable under descriptor exhaustion". An unparseable record decoded as an empty Intent was deleted by reconcile.
- **Check** — Three outcomes: gone, read, unreadable (keep). Delete only on positive corruption, and set it aside. The loss signal lives on the shared log and marks the target degraded ("run mirror").
- **Seen** — d425aa2d, PR #66, PR #67, notes (durable-queue). recurred ×3.

### A-5.3 Work dropped instead of parked
- **Pitfall** — Permanently failed replica jobs were deleted (`Poison.Drop`) with "degraded" in memory only, so a restart reported the copy healthy. Past 100,000 queued, posts were not recorded. Parked upload records in a long-running process were never re-armed. A non-conditional record update let a failure note racing a completion resurrect the record.
- **Check** — Never drop durable work for capacity or permanence: park with a durable marker and report. Record updates are conditional.
- **Seen** — notes (durable-queue, replication, 04 B.0.1).

### A-5.4 Diagnostic state reset on resume
- **Pitfall** — Each restart rebuilt upload records, resetting attempts and last error, so a stuck upload never showed how long it was stuck.
- **Check** — Attempts, last error and first-failure time survive resume; thread the record, not a reconstruction.
- **Seen** — 9b0f6af2, PR #38.

### A-5.5 Durable records nobody resumes
- **Pitfall** — A one-shot import left 83 records against a 60 s settle window that drains about 29; the daemon read its log only at startup. Android built domains with `resume = false`. A daemon-less machine left a timed-out command's records to nobody. In the rewrite, records submitted by other processes waited until the owner was poked. Recovery lived only in the CLI executable, so the daemon never reconciled its own WAL.
- **Check** — Every durable log has a defined resumer in the library that owns it, rescanning at start, periodically and on poke. A one-shot command drains or leaves work to a resumer that is guaranteed to come.
- **Seen** — 8c0406ca, 3d37f32f, PR #35, PR #52, notes (android B-0, durable-queue), c5ae6639. recurred ×4, rewrite.

### A-5.6 No crash-released claim on a shared log
- **Pitfall** — Once the daemon rescanned periodically, nothing stopped two processes reading one log; "only the daemon resumes" was the only guard.
- **Check** — A process holding records in memory takes an OS-released claim (lockf/flock); sweepers read only unclaimed logs. Exactly one consumer per ordered queue.
- **Seen** — 8c0406ca, 9b0f6af2, PR #52.

### A-5.7 Rescan takes a record still being built
- **Pitfall** — A bulk publisher's batch record must be durable before the first put, but a rescan took it while uploads ran. The fix creates it already held. Old import put manifests before the batch entry and a re-run skipped existing keys without re-emitting ops, so a kill left manifests nobody announced.
- **Check** — A record is visible to runners only once its submitter releases it. A re-run after a crash re-emits announcements for work already done.
- **Seen** — 7e03f0e2, notes (durable-queue, 05 B.4). rewrite.

### A-5.8 A process accepts writes with no worker to send them
- **Pitfall** — A non-first frontend had `start` as a no-op but writable file ops: it recorded writes with no upload worker and no poller. No test covered more than one frontend per domain.
- **Check** — A process that accepts writes owns, or hands to, a queue that drains them. Every topology the config permits has a test.
- **Seen** — 6a351874, 65c5b2de, cb2be7ac.

### A-5.9 Drain implemented as stop
- **Pitfall** — "Drain after a change" called `Q.stop`, so Android's queue stopped at the first mkdir and accepted later writes without sending them. Waiting on the whole queue made a picker save wait behind a camera sweep.
- **Check** — Drain and stop are distinct. A caller awaits only what it owes under its own key, bounded by "sent or failing".
- **Seen** — e46e2286, f44d8f9f.

### A-5.10 Supersede topology used for owed operations
- **Pitfall** — The keyed queue supersedes a running job, which is right for latest-state uploads and wrong where every op is owed; multi-key copy and delete-multi jobs have no key function preserving order.
- **Check** — Supersession only for idempotent latest-state work; owed ops need order-preserving parallelism.
- **Seen** — PR #67.

### A-5.11 Replica jobs replay operations instead of converging
- **Pitfall** — `Job_put` did nothing when the key was gone, `Job_delete` deleted unconditionally. Correctness needed one global order across processes and machines: a command's Delete(k) could run after the daemon's later Put(k), leaving the copy without a key the main held.
- **Check** — A copy job converges a key to the mains' current state when it runs, bodyless, forwarding a manifest only after its chunks.
- **Seen** — notes (replication), 332aa06c.

### A-5.12 Retry counters uncapped and invisible
- **Pitfall** — An owed metadata record with uncapped retries froze a folder's listing indefinitely on Android.
- **Check** — Retry counters are capped and surfaced in status.
- **Seen** — notes (android B-0).

## 6. Journal, cursors and the change feed

### A-6.1 Journal read "since key K"
- **Pitfall** — Entry keys are the writer's millisecond, but visibility order differs (latency, retries, WAL replays under original keys). Replay (at the last-sync mark) and the change feed (at an anchor) cut at a key, so an entry visible after a newer one moved the cursor was never read: with four concurrent uploads per side each peer silently lost the other's second batch while status said "0 to apply".
- **Check** — Never dedupe by "key > cursor". Track every handled key in a positional applied log back to the retention horizon. A rebuild marks the entries it read as handled. The repro hides the newest journal object, syncs, then unhides it.
- **Seen** — aebaeff5, 2102b6bc, PR #87.

### A-6.2 Mark advanced past entries not handled
- **Pitfall** — The mark moved past entries that failed to read (`get_journal_entry` turned every error into None), and `overridden_since` could publish a stale op over a newer one. A resync bookmark advanced past folders it never fetched, so their files later arrived into directories no id named. Inversely, a spurious failure kept the mark still and every sync became a full rebuild.
- **Check** — The mark passes an entry only once applied or recorded as stepped aside. Advancement needs a complete walk; walks report what they skipped and why (fetch vs parse).
- **Seen** — beae4871, 8c0ff231, 14d94ce5, f32e529a, notes (wal-and-journal §3). recurred ×3.

### A-6.3 Notification-only wake misses lost hints
- **Pitfall** — The poller read the journal only when the cursor changed; a lost bump, or one landing behind a later bump from another process, left a peer's last ops unapplied indefinitely. The first fix raced a 60 s timeout against a wait that always returns sooner (watch 30 s, stores 2 s), so the sweep never ran.
- **Check** — The cursor is a hint. Sweep on a clock measured from the last full read. Prove every fallback timer can fire.
- **Seen** — 9ba6f9d5, 2569ed4f, be0f7fe1, PR #81, PR #87. recurred ×2.

### A-6.4 Recording a change and announcing it are separate calls
- **Pitfall** — Only the converging process notified frontends, so import and revert published silently. The fix in the journal seam missed the bulk path `write_journal_entry_body`; the notice failure logged at debug hid it.
- **Check** — Record-and-announce is one call with no alternative entry; grep every publisher path, bulk included. Delivery failures log at warning. Record locally before announcing.
- **Seen** — d48dc303, 492b878c, 20a26efa. recurred ×2.

### A-6.5 Change feed rebuilt from the store and filtered per machine
- **Pitfall** — Every `changes_since` listed the journal and fetched one object per entry on the path fileproviderd takes before each enumeration. It filtered by client uuid, so CLI changes on the same machine never reached the mount.
- **Check** — "Changes since" answers from local retained entries, noted before publishing and after applying. Filter origin per writer, not per machine.
- **Seen** — 20a26efa, PR #80.

### A-6.6 Op described lazily against the current mirror
- **Pitfall** — A Delete was named `f:<parent id>/<leaf>` from a marker the recursive delete had already removed; the op was dropped silently and the replica kept the directory forever. A file moved into a later-renamed folder spelled a path with nothing at it. The applying process is not the describing one, so an in-memory table fails.
- **Check** — Everything needed to describe an op later (both ends' folder ids) is captured durably at apply time. Removal lookups have their own contract (`lookup_id_removed`). Compare the applied log with what the frontend received.
- **Seen** — 1b73dd2d, 694c3a82, cac8f7ea, PR #81, PR #87. recurred ×3.

### A-6.7 One unnameable op stales the whole page
- **Pitfall** — An op naming a folder with no local id staled the whole batch, forcing a re-enumeration that never removes what the replica holds.
- **Check** — An unresolvable op is dropped and counted, never escalated to invalidating the feed.
- **Seen** — 85fd6050, 807e1454, PR #88. recurred ×2.

### A-6.8 Coalescing an op batch loses intermediates
- **Pitfall** — Keeping only an item's last op skipped a rename whose new name a later op touched: after `mv a b; rm b`, `a` stayed forever; after `mv a b; mv b c`, `b` was both updated and deleted. The File Provider observer takes unordered update and delete sets, so create-then-delete resurrected.
- **Check** — Each identifier is decided by the last op mentioning it in any role; a rename's source always yields a removal. Existence is confirmed by stat. Tests cover chains.
- **Seen** — bc51cd75, 5c8270fa, PR #87. recurred ×2.

### A-6.9 Old identity not retired by a move with new contents
- **Pitfall** — The old reference's delete was guarded by comparing a value to itself and never ran; a renamed-and-rewritten file stayed under the old name too.
- **Check** — Any path producing a new identity deletes the old. A guard that can be statically constant is a bug; test that the branch fires.
- **Seen** — 2939226c.

### A-6.10 Change filtering under-reports removals
- **Pitfall** — Filtering by the materialised set dropped a child's deletion when its parent was not in the set; the system declined to remove a folder holding a child it was never told about and kept it forever. A refresh already running returned at once, so callers read an empty set.
- **Check** — Over-report, removals especially. A concurrent refresh is awaited, not skipped.
- **Seen** — a06abe2f, d1bea01b, f779eb51, ab4f21e7. recurred ×4.

### A-6.11 Page tokens meaningless to another process
- **Pitfall** — File Provider pages were offsets into an in-memory listing, but the extension restarts at will. Sorting in the harness hid nondeterministic listing order.
- **Check** — Page tokens are self-describing positions in a stable order. Tests never sort output that should already be ordered.
- **Seen** — 20a26efa, a06abe2f, e2fdc38c, PR #80.

### A-6.12 Cursor carrying unbounded state
- **Pitfall** — The working set carried its DFS frontier in a 500-byte page token; it overflowed at about 26 pending folders and the enumeration ended as if complete.
- **Check** — Cursors are bounded positions in a server-owned order. Overflow is an error, never end-of-list.
- **Seen** — 6941a5b5, 3c1c513a.

### A-6.13 Resume by an identity that maps to several places
- **Pitfall** — A cursor `<container>/<name>` resolved to whichever copy of a folder id the index named; with three copies of one subtree it cycled forever (38k of 220k items).
- **Check** — Resume positions are positions in a snapshot (walk-id:line), never re-resolved identities.
- **Seen** — d863e053, PR #88.

### A-6.14 Short page read as end of listing
- **Pitfall** — Paging ended on a short page, so any defect losing one entry silently truncated the enumeration.
- **Check** — End-of-listing is an explicit flag; pages count entries collected, not lines read.
- **Seen** — 2d819bce, 3c1c513a. recurred ×2.

### A-6.15 Bare delimiter in a format carrying user names
- **Pitfall** — A `|` in a name split a page token into a non-existent folder; a newline in a name split a line, stopping enumeration at 161,000 of 236,580.
- **Check** — Serialisations carrying user names use an escaping format (JSON, length-prefixed).
- **Seen** — 3c1c513a, 2d819bce, PR #87, PR #88. recurred ×2.

### A-6.16 Journal-bridge predicate owned twice; horizon conditions
- **Pitfall** — Daemon said an empty journal meant stale, CLI said up to date. Only `tsync sync` checked bridging. A client stopped beyond 30 days skipped unpruned entries older than the horizon. Applied-log prune could drop the newest shard or shards inside the horizon and duplicated lines on retry. In the rewrite B3 fired on every young journal, and after a rebuild applied entries counted as "behind".
- **Check** — Empty is stale. The owner checks bridging every pass, including a mark older than now − H. "Behind" means "not in the applied log". Prune never removes the newest shard or anything inside the horizon.
- **Seen** — 9b0e8d0d, notes (wal-and-journal §3, 05 B.4), 131fc618, spec issues 6, 12. recurred ×2, rewrite.

### A-6.17 Entry granularity and causal order
- **Pitfall** — Import published one entry at the end (170,901 ops, 27.8 MB), invisible behind 84k deferred jobs; batching by count alone (2000) never fired for a few hundred large files. Mkdirs must precede puts naming the folder. In rsync `--move`, the Delete can reach peers before the Put.
- **Check** — Long producers publish on a count bound and an age bound (10 s), mkdir lists included. Parents and creations precede referencing entries. A change spread over several entries never exposes a lossy intermediate state.
- **Seen** — d425aa2d, ca1ee99c, PR #66, plan §6 rsync. recurred ×2, rewrite.

### A-6.18 Rebuild reported as a reset
- **Pitfall** — A full resync rebuilds from a listing, picking up direct-to-bucket changes, but invalidated nothing, so the File Provider kept serving deleted items. A rebuild that wiped the applied log expired every anchor, demanding `list_all` at 62 s per page; fileproviderd held 40k of 220k items.
- **Check** — A rebuild appends the difference it made as ordinary ops. Anything changing state outside the journal durably invalidates earlier anchors before any notify.
- **Seen** — ba6ca8d2, 1e85630b, dbbbe079, ceaae60e, PR #88. recurred ×2.

### A-6.19 Event omitted because another component "probably" emitted it
- **Pitfall** — A sweep skipped a folder whose id lived elsewhere, assuming the walk reported it; when the other copy was already held nothing was reported and a Mac kept 22 folders a resync dropped.
- **Check** — Derive events from the observed state transition.
- **Seen** — ceaae60e.

### A-6.20 Freshness hook optional, or a revalidation claim not earned
- **Pitfall** — `?on_changed` was optional through three layers; FUSE never passed it, so a peer's rename left a name that ENOENTed until remount. FUSE also stubbed the `changed` hook, so revert never invalidated the kernel. Made required, FUSE claimed Revalidates, but `entry_timeout=0` does not stop the kernel answering from a dentry already held.
- **Check** — A hook whose omission costs correctness is required and typed as a choice (`Notify | Revalidates`). A revalidation claim is proven against every cache layer; otherwise push invalidations. A test asserts the hook fires.
- **Seen** — 058e08db, 22370770, PR #38, PR #68. recurred ×3.

### A-6.21 Long-poll watch semantics
- **Pitfall** — A shared watch's token can predate a newly arrived waiter's, so holding it misses a past change. A peer too old for watch parameters answers at once and, with no header to tell, the caller spins. S3's whole-second `last_modified` cannot separate two bumps. A local watch on the object's name follows an inode rename unlinks.
- **Check** — Compare the client's token on arrival. Use opaque store tokens, never clocks. "Answered immediately, unchanged" is distinguishable from a change. Watch the containing directory; every watch returns within a bound.
- **Seen** — b28b776f, cf3684d8, PR #72. recurred ×2.

### A-6.22 Truncated listing feeding a computed answer
- **Pitfall** — The diagnostic journal listing was capped at max_keys, but the entries a client is behind on are the newest: "1001 entries+, 0 to apply" while a folder sat unapplied.
- **Check** — Truncation never feeds a computed answer; bound cost by caching.
- **Seen** — 9860fc58.

### A-6.23 Tail reader loses the head on a long record
- **Pitfall** — Finding a shard's head from its tail dropped the cut first fragment; a last entry wider than the window gave no head and the reader re-read everything.
- **Check** — Tail scanners grow the window until a whole record is found.
- **Seen** — 57129981.

### A-6.24 Watermark on the wrong field or past unsettled items
- **Pitfall** — The camera sweep advanced by `DATE_MODIFIED` while the query cut on `DATE_ADDED`, so photos were never uploaded on API 26-29. It stored the generation read at pass start, so failed photos never returned. "From now on" could leave `dateAdded` at 0 and back up everything.
- **Check** — A watermark is the field the query compares, owned by one function, advanced only past settled items.
- **Seen** — PR #57, notes (android B-0). recurred ×2.

### A-6.25 A peer op's local facts read at the peer's path
- **Pitfall** — A peer names the path it saw; the local half of its op acts at that path translated through this client's moved folders and owed renames. The file id the change feed names was read at the peer's path: a delete under a folder renamed here found no id (the feed dropped it and the replica kept the file), or the id of an unrelated file now at that path (the replica dropped a file that still exists). Naming the file the delete *would* have removed is as wrong: when the arrival decision keeps it, the replica drops a live file.
- **Check** — The arrival code that translates the path is the only reader of local facts for a peer op, and it reports what it acted on: a put's and a rename's id afterwards, a delete's only when it removed the file. No fallback reads the peer's spelling of the path.
- **Seen** — b0a14d08, rewrite.

## 7. Store contract, replication, GC and content integrity

### A-7.1 Content not verified against its key
- **Pitfall** — `chunk_remote_ok` compared sizes only, and a swapped full chunk is exactly 8 MiB, so recheck reported clean. Plain reads returned corrupted bytes; staging copied inherited bytes through `read_into`, so wrong bytes from a store were republished under new keys; resync did not re-copy a scrambled same-size chunk.
- **Check** — Hash every fetched chunk against its key before it enters the cache, is reused for staging, republished or copied to another member. Export fails only the file a corrupt chunk belongs to and exits non-zero naming it.
- **Seen** — 3f3786a4, PR #50, PR #95, notes (read-path, 09 B0.3). recurred ×3.

### A-7.2 Positive memo consulted before the corruption marker
- **Pitfall** — `chunk_exists` HEADs and trusts the key, so a corrupt chunk poisons dedup and every later file containing it inherits the bad bytes. Consulting the session "already placed" memo first would report bad bytes as stored and leave the marker with nothing to clear it.
- **Check** — Corruption marker, then memo, then store. A marked key reads absent to dedup. Tests assert which sources were consulted, not only the verdict.
- **Seen** — 2b648644, 82abb725, PR #50. recurred ×2.

### A-7.3 Repair trusts its source
- **Pitfall** — Repair copying from a "good" copy without hashing turned "2 lost" into "2 cleared".
- **Check** — Repair re-verifies the source against the key; only the verifying party clears a marker.
- **Seen** — PR #50.

### A-7.4 Verifier semantics
- **Pitfall** — Read errors escaped and aborted the sweep; bit rot arrives as EIO more than wrong bytes. A failed chunk could have been reclaimed, destroying a file's only copy. The local driver's read-back EIO failed a write that had landed. Verifying through the composite read a replica's good copy for a bad main and fanned marker writes to healthy copies.
- **Check** — Verification answers ok / mismatch / unreadable and none aborts. Corrupt chunks are kept and marked, never collected. Verification targets one member directly. Exactly-once counting comes from an atomic rename.
- **Seen** — 645c0f2a, PR #50.

### A-7.5 Two implementations of the content key
- **Pitfall** — The cloud verifier re-implements the chunk key; swapped XXH3 seeds would file every chunk as corrupt.
- **Check** — Every re-implementation of an identity function passes one shared golden file (size boundaries, streamed vs one-shot).
- **Seen** — PR #50.

### A-7.6 Keys carried without bytes cannot re-verify
- **Pitfall** — A staged partial write reusing a chunk carries a key, no bytes; a marked chunk inherited this way stays marked. Cache bodies are filed by group key, so they cannot be checked per chunk and are no recovery source.
- **Check** — Know which local copies are verifiable; ensure repair or recheck covers keys carried without bytes.
- **Seen** — PR #50, f31ba9ce.

### A-7.7 GC: a writer dedups onto a chunk the collector wrote off
- **Pitfall** — An upload HEADs each chunk, skips present ones and publishes later; mark-then-sweep could sweep an adopted chunk. Intra-domain copy, revert, republish, rsync rename, version snapshots and proxied PUTs published manifests without promoting, and the run marker was read once.
- **Check** — A manifest becomes visible only once every chunk it names is in the surviving space. The reference gate sits in the store driver around every manifest and version write. A test performs the dedup-onto-orphan race.
- **Seen** — PR #40, 96c30ced, notes (02 B.4, backends/local B-0, http-proxy B21), 2cfba26b. recurred ×3.

### A-7.8 GC: exclusion and partial views
- **Pitfall** — Two collectors from one cursor partitioned roots; the first to finish discarded while the other had unpromoted roots. Mid-collection, `chunks/` is partial, so resync would copy a partial set and stats were wrong.
- **Check** — Destructive maintenance holds a crash-released exclusion (kernel lock or lease) with its scope stated; a local lock does not exclude another host. Anything enumerating a store checks for an open collection and refuses or annotates.
- **Seen** — PR #40.

### A-7.9 GC: races in the rewrite's generation protocol
- **Pitfall** — A copy's delete job read a chunk from a shard the doom step had not emptied, skipped the delete and restored it (2/10 runs). A best-effort forward outlived a collection delete. A settle meeting the run lock deadlocked logically. An odd G could turn even under a reusing collector. A one-shot owner exited before the delayed settle. A discard request was recorded pending before written, so a poll took it as consumed. Two overlapping probes wrote one request; one deleted it and the other read that as consumption.
- **Check** — Reads falling back to the outgoing space hold the publish lock shared. A collection delete takes every forward slot first; a settle holds and retries on the run lock. Delayed work is run or durably owed before exit. Write the effect before recording it pending; absence means consumed only for a request known to exist. Probes are single-flight or nonce'd.
- **Seen** — 78e844c7, 2cfba26b, 73447607, 548fbc38, 22b9a29e, 371f15da. rewrite.

### A-7.10 Memo outlives the state that justifies it
- **Pitfall** — The process-lifetime `ensured` memo survived collections, so a manifest job could skip a deleted chunk. Evicting keys while keeping a shard "known" meant they were never relearnt. The spec put G "on the first collectable main", which a remote client cannot identify.
- **Check** — A chunk-exists memo is invalidated by a G change, or used only behind a gate that re-checks. Memo components reset together. G is the max over every main, unknown if any is unreachable.
- **Seen** — 8d57ac65, PR #67, spec issues 13, 14. recurred ×2, rewrite.

### A-7.11 Bulk delete refusals swallowed
- **Pitfall** — S3 multi-delete answers 200 with per-key errors; the driver discarded them, so a refusal equalled a delete, and once GC stopped revisiting copies it was a permanent leak under "success". The local delete swallowed per-entry errors.
- **Check** — Parse per-item results; classify "already absent" in one place; treat other refusals as transient. A work item is deleted only once every key is confirmed gone.
- **Seen** — 49edc5c6, 27685a67, notes (backends/local B-0). recurred ×2.

### A-7.12 Asynchronous delete requests: keying and durability
- **Pitfall** — A request key named cursor-first lets a later collection overwrite an unconsumed one. The main may discard only after the copy's request is durable. A function predating requests ignores one and its notification is spent. Keys are already gone from the main, so nothing meets them again unless status reports outstanding requests. An absent function accepted requests while gc reported success.
- **Check** — Request keys include the run id; the PUT is awaited before the main discards; requests are visible in status with their age and re-firable. The capability is a tri-state, opt-in, never assumed.
- **Seen** — 27685a67, PR #58.

### A-7.13 Replicas in the write path
- **Pitfall** — A write waited for mains and replicas; a cloud replica gated the journal publish, the WAL record and the release of cap-exempt staged data. Offline, the disk filled with staged bodies the local main already held.
- **Check** — Acknowledge when the mains have it; replicas catch up from a durable queue. Release of cap-exempt data never depends on a remote.
- **Seen** — 9b0f6af2.

### A-7.14 Catch-up job filled from a stale replica
- **Pitfall** — A deferred job read through the full read chain; with every main unreachable it copied another replica's older body and was consumed, leaving the target permanently stale.
- **Check** — Replication sources are mains only. "Main unreachable" retries; it never falls through to a peer copy.
- **Seen** — fcf7b854, PR #38.

### A-7.15 A non-main member written while the main is gone
- **Pitfall** — `data-integrity --verify/--repair`, gc, mirror and share wrote a named replica whatever the main's state. The first guard asked "is the main held", which expires after 30 s regardless, so a long repair wrote the replica with the main still gone.
- **Check** — One write guard for non-main members: refuse unless the main has been heard from since it went down; a fresh process probes first. Every out-of-band writer goes through it.
- **Seen** — 58a5ffaf, 91c1a104, PR #97. recurred ×2.

### A-7.16 A new path or member bypasses wrappers and overrides
- **Pitfall** — A resync `--source` took listings from one store and bodies from the whole domain via `get_many`; a resync of a read-only domain wrote a folder index. Adding `get_range`, the traffic counter missed range bytes and the pinned-member wrapper walked the composite. `--source` left health on the composite's `always_up`.
- **Check** — When a batch path or interface member is added, audit every wrapper and every override (source, read-only, health, accounting) across all I/O paths. A wrapper forwards every member.
- **Seen** — c4284b23, 7a784ebc, 055754cd, d2d5cfd6, PR #102. recurred ×3.

### A-7.17 Store contract kept only by accident
- **Pitfall** — `Backend.S` promises deleting a missing key succeeds; the proxy driver raised on 404, hidden by the server deleting through a store that never answers 404. A store returning the whole object for a range looks like one that honours it.
- **Check** — Every driver runs one conformance suite directly: absent-key delete, exact range length (more bytes is a failure). Proxies refuse ranges they cannot express.
- **Seen** — 94b0d30e, 7a784ebc, PR #76, PR #85. recurred ×2.

### A-7.18 Capability inferred, asserted, or branched on driver name
- **Pitfall** — "Is a read cheap" was derived from `local_path`, which the composite lacks; GC eligibility was decided both by `caps.gc` and `backend_type = "local"`. The object-store shell hard-coded `verified = true` and `discard = Queued`, so a bucket without the function claimed checks nobody ran.
- **Check** — Each decision has its own declared capability, answered by the composite from the member it uses. Deployment-dependent capabilities are probed, saved by the owner with an expiry, renewed. No caller branches on a driver name.
- **Seen** — f18f85db, 654d0adc, notes (backends/s3, replication), 70e8fff0, b794ad9b, caa48acc. recurred ×3.

### A-7.19 Fallback error blames the wrong store
- **Pitfall** — Reporting an archive's error when nobody answered sends the operator to the wrong machine.
- **Check** — A composite read's error names the authoritative store.
- **Seen** — b2e6f69b.

### A-7.20 Event handler non-recursion left to a filter
- **Pitfall** — Once markers moved under `tsync/`, the bucket notification filter no longer excluded the function's own writes; comments still said it did.
- **Check** — Handlers ignore their own outputs in code.
- **Seen** — 09a7e77f, 0d3fc3a1.

### A-7.21 Edge sizes and spec grammar
- **Pitfall** — An empty file had 0 chunks in one spec file while a manifest must name the empty chunk once. A mandated bind used a listing prefix that is a whole key, which the prefix grammar refuses.
- **Check** — Push 0 bytes and an exact chunk multiple through every layer. Every mandated wire request passes the spec's own grammar.
- **Seen** — spec issues 1, 2, 9. rewrite.

## 8. Caches, the mirror and rebuilds

### A-8.1 Name lookups fall through to the store
- **Pitfall** — A mirror miss fell through to a backend GET (85-115 ms); shell probes for `.git` made `zsh -i -c exit` take 1.43 s. A deny-memo was added, then found to cache the wrong reasons; removing the fallback took misses to 0.34 ms. A fixture published with raw `Remote.upload`, which never writes the mirror.
- **Check** — stat, lookup and readdir never touch the network; a name the mirror lacks does not exist. Fixtures publish through the path that writes the mirror.
- **Seen** — 038e70a3, e38f7a55, aa903e76, PR #70, PR #73. recurred ×2.

### A-8.2 Negative cache of local facts, under the wrong mark
- **Pitfall** — The absence cache remembered misses due to "folder not known yet" or "body mid-write", returning ENOENT until a peer published. An entry applied during the fetch was recorded under the advanced mark and survived its invalidation.
- **Check** — Negative-cache only "store says absent", keyed to the applied mark read before the fetch.
- **Seen** — 0eeb3588, 5abef187.

### A-8.3 Partial cache body taken as whole
- **Pitfall** — Safe order: extent record before bytes, record an interval after its bytes land, evict body before record. `is_local` read a partial body as present; a forced refetch topped up in place without marking incomplete, so a crash left a short body that looked whole. Concurrent fills could lose an interval.
- **Check** — "Whole" is proven by absence of the partial record; at every crash point the record claims no more than the disk. Interval updates are single-writer with no wait in between.
- **Seen** — b0ea0213, 9f41023b, PR #76. recurred ×2.

### A-8.4 Cache state out of step with eviction and pins
- **Pitfall** — `enforce_cap` unlinked body and record but left in-memory intervals, so a fill loaded before eviction published a record claiming evicted bytes. A pin taken after the fetch lost to a cap sweep in between.
- **Check** — Each body has a generation checked under a per-body lock by fill, publish and evict. Pin before fetching.
- **Seen** — notes (read-path-and-cache).

### A-8.5 Version-validated cache paired across stores
- **Pitfall** — A folder index paired each body with the listing's version, but a read could fall through to a replica after a transient error, so a replica body was recorded under the main's version and served from then on.
- **Check** — Body and version come from the same store in the same read; index only where a read lands in one place. Derived objects are known to every namespace walker.
- **Seen** — 01ef21bd, PR #70.

### A-8.6 Size and mtime cannot detect a replacement
- **Pitfall** — S3 reports whole seconds, so a same-length rewrite within a second is invisible. A manifest's double mtime against nanosecond filesystems re-copied files every run. `contentVersion` as `size:mtime` moved on publish without a content change.
- **Check** — Validity uses an opaque version or etag; "no version" is distinct from "empty version" and disables the cache. "Same file" is a content hash.
- **Seen** — a69f219a, f1766969, b6be8491, notes (file-provider B-0). recurred ×3.

### A-8.7 Rebuild clears before it refills
- **Pitfall** — Android resync wiped 36,568 manifests and left ids unresolvable for 25 minutes. A full resync unlinked every mirror manifest (minutes, empty tree served), dropped the still-valid chunk cache and emptied the applied entries. Android's no-op `full_resync` left ids unresolvable afterwards (open).
- **Check** — Rebuild in place and sweep by generation afterwards; content-addressed caches survive; no empty intermediate view. Everything belonging to a projection is cleared together.
- **Seen** — 661d4974, 1b08744e, c8e21256, 1e85630b, dbbbe079, PR #79. recurred ×3.

### A-8.8 Read state keyed by file, not by reader
- **Pitfall** — A player opening one file twice shared one position entry, so neither was prefetched. Per-range Android processes started with empty read-ahead tables. FUSE re-resolved the key on every read, mixing versions after a peer update; Android served new bytes with the size at open.
- **Check** — A handle pins a manifest version; read-ahead state is per handle in a long-lived process.
- **Seen** — a6ba4ace, 47040bc1, notes (04 B.0.1, android, fuse B-IV). recurred ×3.

### A-8.9 Recency refreshed only on write
- **Pitfall** — The cap evicts by mtime and only writes set it, so a body read daily was coldest.
- **Check** — Reads refresh recency, throttled.
- **Seen** — 6c654bc9.

## 9. Security boundaries

### A-9.1 Multi-key request authorised by its first key
- **Pitfall** — get-multi and delete-multi were routed and signature-checked by the first key, then run whole; two domains share a bucket by prefix, so one domain's secret could read or delete another's objects.
- **Check** — Authorise every key against the route that signed; any foreign key refuses the whole request.
- **Seen** — 283cc49b, PR #70.

### A-9.2 Signature not covering the query
- **Pitfall** — Range parameters travel as query parameters; unsigned, a captured request replays with another offset.
- **Check** — The signature covers the full target, query included.
- **Seen** — 055754cd.

### A-9.3 Key and path confinement
- **Pitfall** — The local driver joined keys onto its root unnormalised, so a signed `tsync/<d>/../../<path>` read, wrote and deleted outside the store; mirror, backfill and GC used the same join. Domains named `shares`, `corrupted`, `/`, `..` broke prefix confinement; an empty domain put a marker where nothing lists. Keys ending in `/` became directories. Symlinks under a root were followed. The rewrite parsed keys by searching for `/chunks/` and raised on every put in a domain named `chunks`.
- **Check** — Protected names are private types from validating constructors that refuse anything readers cannot produce. Keys are parsed by segment. The local driver refuses `..` and follows no symlink. Test domains named after every area.
- **Seen** — bfd2761d, notes (security-model, backends/local B-0, 06 B.0.1), 4bb9490c, f1519aa3. recurred ×2, rewrite.

### A-9.4 Share scope and routing
- **Pitfall** — A share was written to the first route whose secret signed it and read from the first share-enabled route. A token names no domain, so a multi-domain listener served a second domain's link from the first. Share keys routed to any verifying route with no check of the manifest's domain, so any secret could list, overwrite and delete every share. `--token` overwrote another share. The rewrite's `Key.share` accepted any leaf.
- **Check** — Writer and reader resolve location through one function. Manifests carry their domain; every read checks it against the route, with no default fallback. One token grammar owner; a chosen token never overwrites; shares are never listed; parsed once.
- **Seen** — 7e8f89ef, ca6ed151, PR #68, PR #90, notes (security-model), f86a018c, dcec9d85, 617ff6f2. recurred ×3, rewrite.

### A-9.5 Per-domain options leaking across a shared listener
- **Pitfall** — One domain enabling shares enabled them for every domain that left it unset; `/stats` accepted any secret and reported every domain.
- **Check** — Per-domain authorisations come from each domain's binding; only listener-scoped values are inherited, refused when ambiguous. Status is scoped to the authenticated domain.
- **Seen** — f23937e0, notes (security-model). rewrite.

### A-9.6 Privileged consumer trusting client-written requests
- **Pitfall** — The bucket function can delete any chunk and its request body is client-written; IAM alone does not bound it. The lambda did not check a file share's key against its domain.
- **Check** — Validate every key: chunk-shaped and under the requester's prefix; refuse on sight without retry. Narrowest IAM (delete, never create).
- **Seen** — 27685a67, PR #58, notes (security-model).

### A-9.7 Unbounded or unauthenticated server input
- **Pitfall** — The old server read the whole body before routing and auth, had no header/idle/keep-alive timeout or connection cap; claims, deletes and copies bypassed admission. `wait=nan` passed the clamp; an unparseable `max_keys` listed everything. In the rewrite, an abandoned TLS handshake held a fiber until the header timeout.
- **Check** — Authenticate headers before any body. Bound header size and time, idle, connections and handshakes. Every data op passes admission. Numeric parameters parse strictly; NaN and negatives are refused.
- **Seen** — notes (security-model, http-proxy B21), 7319e7d6, 46c84804. rewrite.

### A-9.8 Local IPC and transfer-path trust
- **Pitfall** — Only the IPC server created its socket directory 0700; the queue could create it 0755 first. Peer credentials were not checked. Client-given `staging`/`dest` paths were opened O_CREAT without O_EXCL or O_NOFOLLOW. `allow_other` ran without `default_permissions`. The config was written then chmodded 0600. Android backup copied the secret.
- **Check** — Private directories and secrets are created with their final mode. Check the peer uid. Confine client paths to their staging area with O_NOFOLLOW|O_EXCL. `default_permissions` with `allow_other`.
- **Seen** — notes (security-model, 07 B.4), 824dd1f9, 9c95195a.

### A-9.9 Injection in served pages
- **Pitfall** — Share data was inlined into `<script>` unescaped; placeholder substitution ran twice; shared files were served inline without a sandbox CSP; the stats page kept the secret in `sessionStorage`.
- **Check** — Escape JSON for script context, substitute in one pass, sandbox CSP or attachment for user content, secrets in memory only.
- **Seen** — notes (security-model), fe5b0e87.

### A-9.10 A request refused mid-body leaves the connection open
- **Pitfall** — The HTTP server marked a request body consumed before checking its length or reading it, and kept the connection alive when it was consumed. A body refused partway (413 over the limit, 408 too slow, 400 for a bad length) left its unread bytes on a connection the server went on reading as the next request: responses desynchronised, and a sender could smuggle a request inside a body, for example to the unauthenticated `/s/` endpoints.
- **Check** — A connection is reused only after its request's body was read to its end; any failure while reading it, or a handler that never read it, closes the connection.
- **Seen** — rewrite (review of PR #114).

## 10. State ownership, single owners for rules, and types

### A-10.1 State keyed per instance instead of per thing
- **Pitfall** — Per-domain state lived in functor applications made in 5 to 17 places: 5 WAL logs over one directory, each with its own id counter; manifest memos missing each other's reads; download pools admitting twice the budget; cursor debouncers that never flushed each other; a handled set per application so daemon and `tsync sync` re-applied each other's entries; a chunk-cache byte count stale after another view evicted; a second queue consumer racing the first. Taking a functor's result instead of the functor gave every domain one store and compiled.
- **Check** — For every table, counter, pool, debouncer or log, decide whether it is per process, domain or store root, and memoise on that key. Ask "one per what?" of each module- or functor-level `Hashtbl.create`/`ref`. A new consumer on a shared hand-off replaces the old.
- **Seen** — 2dd93e17, 802769c4, 170266d9, 4b60fb43, 80feef14, ab654632, ea959665, 73edcded, 15f02279, 0e5ceaab, 8f2ccafb, 82e0adea, 7718009d, notes (02 B.2, 03 B-I.5, 04 B.1, 07 B.2/B.4). recurred ×12.

### A-10.2 Global timer table keyed too coarsely
- **Pitfall** — The process-global cursor debouncer was keyed by cursor name; a bump armed in one scenario fired in the next against a wiped root, so that scenario applied nothing (11 of 48 runs under load).
- **Check** — Deferred-action keys identify everything the action touches (domain + store root), or the timer is flushed at teardown.
- **Seen** — 44f3383c.

### A-10.3 Per-operation state at module level
- **Pitfall** — rsync kept pending ops in a module-level list a second run would clear.
- **Check** — Per-operation state lives in the operation's value.
- **Seen** — 28bb9e3e.

### A-10.4 Copies of one rule drift apart
- **Pitfall** — Field specs drifted between backend and frontend; `"1"` meant true for one field and false for another across nine readers; `?totals=true` meant false; a blank answer was `""` or omitted; `default-domain` with no argument cleared the setting. Size printers disagreed (8M vs 8.0 MB, decimal vs 1024). An error map matched `"not found"` against `"not found: ..."`. In the rewrite: formatting drifted between status, narration and gc; "still trashed" was re-derived four times; import re-spelled `Names.is_under`; mirror and share each sorted by read rank; gcs and s3 duplicate claim resolution, range checks and bulk-delete paging. Bucket-function constants mirrored OCaml by comment.
- **Check** — Each rule (parse, format, validate, error spelling, capability merge) has one owner module both sides call. A printer round-trips through the parser. Reading a setting never mutates it. Review new code for re-spelled predicates and parallel sibling-driver code.
- **Seen** — ce0f5b35, c8dfe860, aeae984d, 0dd4edbb, PR #38, #41, #48, #50, 92950c91, 5b9c9c68, ce9d5e8e, a6b946ee, 92bf8da0, rewrite (the CLI's Ctrl-C cancel addressed the owner without the domain its request named, refused on the macOS shared socket). recurred ×9, rewrite.

### A-10.5 Config writer and parser disagree; unknown keys ignored
- **Pitfall** — A removed or mistyped key was ignored, so a ceiling meant to spare a store read as none; `"mountPoin"` mounted at the default. Non-strings were stringified and odd bools fell back to defaults. Duplicate backend names shared a log directory. `configure` never ran `validate_roles` and the wizard accepted overrides the parser refuses, so it could not reload its own output. The backend-key check ran only if `Domain` was initialised first.
- **Check** — One strict validator: unknown keys, wrong types and duplicates refused at every level, naming the JSON path. Every writer validates with it. Registries populate before parsing.
- **Seen** — 80b5e045, PR #104, PR #108, notes (05 B.4, replication, file-provider B-0), 29a6a905, 4fe6ec7f. recurred ×3.

### A-10.6 "Is this listing entry a child" decided per caller
- **Pitfall** — Listings include the directory key of an empty namespace, a write under its staging name and the folder index. Four callers decided differently: count and share counted the directory key as a file; `sync --full` counted it broken and never advanced, so every sync resynced the domain; GC's parser aborted on the index; mirror copied the index. The local driver's walk listed staged temps as objects and resync replicated half-written bodies; a polluted replica spread them further.
- **Check** — One predicate, owned by the naming module, used by every walker (driver walk, GC, mirror, count, share, resync); each new internal object kind registers there. Consumers of other stores' listings filter again.
- **Seen** — f18188b5, 8c0ff231, f1766969, c4284b23, 22819312, 1606d0b8, e796b766, PR #70. recurred ×6.

### A-10.7 Population and walks written twice
- **Pitfall** — Resync and lazy browse each filed a fetched child (name, id index, mirror write). `rebuild_mirror` had its own walk that diverged. "Is this key a directory in the mirror" was spelled in four places.
- **Check** — One function files a child; one walk.
- **Seen** — ac236bea, PR #70, notes. recurred ×2.

### A-10.8 Item kind derived from a key's spelling
- **Pitfall** — Folder vs file was read off a trailing separator: a directory rename read back as a file; a record with no ops parsed to nothing and was dropped; import appended a separator others did not; a parent check raised `Invalid_argument`; Android's root listing raised whenever it had a subdirectory; forty sites hand-built keys.
- **Check** — Kind is carried by type or constructor. A fact is spelled once on the wire. A record naming nothing is logged.
- **Seen** — 4f09476f, 61c66680, 487721a1, ffb83708, 90ce1e32, d6f9b114, 93b75364. recurred ×7.

### A-10.9 Distinct address spaces as one string type
- **Pitfall** — Logical and backend keys were both strings; two were built with the wrong constructor and worked only because spellings matched. The entry key had three spellings; `last-sync-<domain>` was written prefixed and bare and only basenaming made it work; four catch-alls hid it.
- **Check** — Each address space and persistent identifier is an abstract type with one parser and one printer, rejecting near-misses. Convert only at explicit boundaries. Look for `Filename.basename` and catch-alls papering over drift.
- **Seen** — 9c899df2, aa7ef162, b995a378, 14223710, PR #35. recurred ×4.

### A-10.10 Closed sets as compared strings
- **Pitfall** — The store role was a variant at parse time and a string later; five sites compared literals, so a typo would silently exclude a store from a fan-out or collection.
- **Check** — Closed sets are variants end to end; only the codec spells them.
- **Seen** — 45ea944b.

### A-10.11 Path-to-location parsed in many places
- **Pitfall** — Six parsers turned a string into domain + key. `share` resolved against the default domain; `ls` read an absolute path outside the domain as relative inside; trash never resolved; a `domain:path` form could capture local names with a colon; a failed resolution exited 0.
- **Check** — One location type from one resolver (also used by completion) that picks the domain from the path. Failed resolution exits non-zero.
- **Seen** — c804c378, a2d85eb8, bd4be598, 6b11759e, 3702b616, PR #74, PR #84. recurred ×5.

### A-10.12 Key layout prefixes hard-coded by routers
- **Pitfall** — Corruption markers and job requests live beside a domain's root; a route matching only `tsync/<domain>/` answered them 404.
- **Check** — The layout owns every prefix a domain uses; routers and access checks ask it.
- **Seen** — ab5075ea.

### A-10.13 Periodic maintenance declared twice
- **Pitfall** — The daemon and Android each had a sweep loop; Android omitted the deferred rescan and never ran the cap's periodic pass, which catches growth from downloads in a read-only process. The first unified version dropped that trigger. `On_demand` was consulted by nothing and sweep results were discarded.
- **Check** — One declared schedule, triggers as data, one driver for every host, exposed in status. Sweeps are isolated from each other.
- **Seen** — fd0240f2, b6d4bc5f, 5caef2c7, 47040bc1, PR #79. recurred ×3.

### A-10.14 Pause consulted by one loop, held per process
- **Pitfall** — Pause held uploads only: renames, deletes and peer entries still changed the tree. Pause was a per-process ref, so the converging parent never saw `tsync pause`, and it did not persist.
- **Check** — One persistent pause switch owned by the owner, consulted by every state-changing loop; test each loop's check.
- **Seen** — bde81092, notes (07 B.2). recurred ×2.

### A-10.15 A destructive walk built on a listing that does not list what it removes
- **Pitfall** — `rmdir` of a non-empty folder deleted every file under it, then removed its subfolders from `list_tree`, which recurses into folders but lists only files. No subfolder was removed, the final `rmdir` failed "not empty", and the client got an error after its files were already gone; a nested empty folder failed the same way.
- **Check** — A recursive removal walks the tree itself, level by level, and removes each folder after its contents. A listing's contract (files only, or every entry) is in its name or its interface, and a test removes a tree holding folders, empty ones included.
- **Seen** — rewrite (review of PR #114).

## 11. Deadlines, health, liveness and shutdown

### A-11.1 Request without a deadline
- **Pitfall** — An unplugged LAN host sits in SYN_SENT; the proxy driver's single 300 s budget ran eight times per cycle, GCS had no timeout, S3 never passed `connect_timeout_ms`. A GCS request with no timeout stopped a queue three times. The CLI's IPC send and Swift `sendSync` had none, hanging stop and status. A FUSE read on a dead link blocked laptop suspend. A store-server long-poll held stop for the whole grace. A menu latch released only on success froze the menu.
- **Check** — Every request has a short deadline to first byte and a body-phase stall bound, one policy across drivers. Reads have a deadline shorter than the frontend's (15 s, EIO; the fetch may continue for the cache). Long-polls end on stop. Latches release in `finally`.
- **Seen** — PR #49, PR #54, 110862db, PR #92, notes (failure-model §2, file-provider B-0, fuse B-II.8, backends/s3), bb5227c3. recurred ×4, rewrite.

### A-11.2 Total-time budget used as a stall detector
- **Pitfall** — A 60 s timeout wrapped whole requests: eight 8 MiB reads over 1.5 MB/s each ran past it and refetched forever (260 MB in 20 min). Body sends did not reset the timer, so 32 × 8 MB forwards expired together and the queue fell to 0 B/s. Stall timers, breaker, metrics windows and token freshness used the wall clock.
- **Check** — Timeouts measure silence in both directions on the monotonic clock. Requests whose size over rate can exceed the timeout are admitted by rate, not count. Credential expiry uses a monotonic deadline.
- **Seen** — PR #96, PR #104, 55ca68f8, notes (01 B.3.4, backends/gcs), 7319e7d6. recurred ×3.

### A-11.3 Per-read idle timeout lets a trickling peer block forever
- **Pitfall** — A file manager's context menu swept every daemon socket on the UI thread (150 ms per silent socket); a daemon sending bytes without a newline reset the timeout on each chunk and froze the file manager.
- **Check** — Requests have an overall deadline. UI threads never do socket I/O to other processes.
- **Seen** — 043f0aa4, 9d93eeee.

### A-11.4 Nested deadlines that do not compose
- **Pitfall** — The status client gave up at 2 s on a daemon spending 30 s on three probe deadlines; `cold_timeout` was probe timeout + a copied 2 s grace, so its case still timed out. Per-call 10 s retries in a purge summed past the CLI's 30 s, which then removed the marker while the app re-registered the domains.
- **Check** — Each outer deadline is computed from shared inner constants and inner waits are strictly shorter. One deadline per operation, owned by its initiator; subordinates check it before acting.
- **Seen** — 91c00a2a, 927f5871, 5bd06afc, 9b4c3156, PR #101, PR #102. recurred ×4.

### A-11.5 Failover waits out a dead member's ladder
- **Pitfall** — A read climbed a dead main's whole ladder (about a minute) before the replica, past the 15 s read deadline, so every read failed EIO. Giving up inside the driver broke domains with nowhere else to go. "Anywhere else" ignored archives, so main + archive had no failover. A single-member domain could ask through the full ladder for about 40 minutes.
- **Check** — Per-member health: down after about 1 s of consecutive failures, backoff 30 s doubling to 5 min, one caller probes. The walk skips held members with any fallback behind (archives count) and always asks the last. The driver never refuses.
- **Seen** — 5db2e286, a5c9c5bd, b85ea256, 38512e35, PR #97, PR #102. recurred ×4.

### A-11.6 Breaker fed the wrong evidence
- **Pitfall** — Throttling and server-busy counted as link loss. Local stores shared an always-up cell, so a stale NFS mount never tripped.
- **Check** — Only link evidence (connect failure, stall, DNS) trips a breaker; throttling slows down. Network-mounted filesystem stores get their own cell.
- **Seen** — notes (failure-model §2, 01 B.3.7).

### A-11.7 A stalled queue says nothing
- **Pitfall** — Deferred queues stopped three times in a day with 549-781 jobs held, no CPU, no traffic, no log line, while status called the backend reachable; found by counting records and gdb. Conversely, a replica looked stuck for days ("1519 queued, none finished in 60 s") while its head job uploaded a 15 GB file's 1500 chunks: 100 GB owed behind 640 KB of records.
- **Check** — Every worker pool has a watchdog "work owed, nothing progressing for N s" at warn, with depth and parked count; in-job progress counts. Health never derives from reachability alone. Test the watchdog firing and staying quiet.
- **Seen** — fadc9668, 110862db, PR #36, PR #54, PR #110. recurred ×3.

### A-11.8 Background task failure unobserved or unpolicied
- **Pitfall** — Worker tasks were stored and awaited only by `stop`, so failures were never looked at. A detached record delete with no handler killed headless processes. A logging-only hook left a daemon whose sync socket failed to bind running unreachable. An escaping exception killed the daemon and the restart erased the evidence.
- **Check** — Every spawned fiber has an owner and an explicit policy: essential services fatal with non-zero exit, incidental ones logged and contained. No stored handle only shutdown reads.
- **Seen** — fadc9668, 64bf2e07, PR #56, PR #108, notes (07 B.4), 9b539eb9. recurred ×3.

### A-11.9 A dead component inside a live process
- **Pitfall** — The parent never restarted a dead child; an OOM-killed FUSE or proxy process stayed a zombie with the unit active. An accept loop died when setsockopt(TCP_NODELAY) answered EINVAL on a unix socket whose peer left; status hung and looked like a File Provider deadlock. An external unmount ended FUSE for good.
- **Check** — The supervisor restarts any owner that ends, with backoff. Accept loops survive any per-connection error. No TCP options on unix sockets.
- **Seen** — d8f854af, notes (file-provider B10–B11, 07 B.4).

### A-11.10 Readiness not signalled on every exit
- **Pitfall** — A serve function returning early left the main thread waiting on a broadcast from a dead thread, silently.
- **Check** — Readiness and completion signals fire in `finally`.
- **Seen** — d9bdf468.

### A-11.11 Failure after fork leaves orphans
- **Pitfall** — The last frontend group runs in the daemon's process, so an exception there escaped before forked siblings were signalled. Android raised from `start` after every other frontend had forked.
- **Check** — Validate every declaration before the first fork; any post-fork failure reaps children.
- **Seen** — 55240d55, d10d3bca. recurred ×2.

### A-11.12 Stop that hangs, double-closes or loses progress
- **Pitfall** — A restart could hang for the whole backlog (backoffs to 300 s, serial reaping), bounded only by SIGKILL; it looked fast only because the daemon died on ENOENT unlinking a socket two owners removed. Children were signalled only when reaped. A copy cut short fell back to a full upload. In-memory cursor bumps were flushed after both queues settled, so one stuck upload lost every finished upload's bump. The File Provider router never requested shutdown and drained sequentially.
- **Check** — One process-wide stop signal and a grace (10 s); backoffs end on it, queues take no new work, unfinished jobs stay on disk in their cheapest resumable form. Budget about 80% of the grace so the final publication flush runs. Stop reaches descendants at once; reaping is concurrent. One owner closes each resource. Hosts drain domains concurrently.
- **Seen** — 9ea6d6c3, c3c4a983, PR #105, PR #108, notes (07 B.4, fuse B-III), fcd5e7dc. recurred ×4.

### A-11.13 Cancellation too coarse to stop
- **Pitfall** — Ctrl-C on `data-integrity` did nothing until its walk ended; further Ctrl-C was swallowed.
- **Check** — Long loops check cancellation per folder, page, shard or write batch; long reads race cancel; a second interrupt ends the CLI.
- **Seen** — 4dad1f1c, 607ec6f2. rewrite.

### A-11.14 Silence indistinguishable from a wedge
- **Pitfall** — GC reported per root; a 100k-chunk manifest took minutes silently and was reported wedged. A stats probe rode the retry ladder for about 90 s. Rewrite commands sat silent for 4 minutes.
- **Check** — Long operations report per-item progress by default. Diagnostic probes have their own short deadline.
- **Seen** — f1b54f1a, 64ff31ed, 07385f4f, 15fc991c, f4756160, fd9b2b70. recurred ×2, rewrite.

### A-11.15 Retry loop with no time floor
- **Pitfall** — With the poller's wait being the store's watch, a failure returning at once would spin.
- **Check** — Every loop driven by a blocking call has a minimum delay on its failure path.
- **Seen** — b28b776f.

### A-11.16 Backoff reset on a cheap acknowledgement
- **Pitfall** — The relay reset backoff when the daemon accepted a subscription, before streaming; a crashlooping daemon was retried at 1 Hz forever, each retry triggering an enumeration storm.
- **Check** — Reset backoff only after health that costs the peer something (uptime past the longest wait).
- **Seen** — ee2dfe5b, PR #101.

### A-11.17 Liveness timeouts shorter than legitimate silence
- **Pitfall** — An uplink owner dropped a lessee after 6 s, but lessees probe up to 10 s before renewing; the returning lessee got a newcomer's share and the link was oversubscribed. Job rows retired by `kill(0)` are fooled by pid reuse.
- **Check** — Liveness timeouts exceed the longest legitimate silence. Pair pid liveness with a silence timeout from the reporter's cadence.
- **Seen** — PR #108, PR #60.

### A-11.18 Refusal after the response is committed
- **Pitfall** — The share read bound refused past its queue after status and content-length were on the wire, so clients got a truncated file.
- **Check** — Admission happens before headers; afterwards backpressure waits.
- **Seen** — fe6c0cf2.

### A-11.19 A background build that fails once stays failed
- **Pitfall** — The file-id index built in the background resolved a promise made once per mirror. When the build raised, the promise was rejected but the state stayed "building": no later lookup started another build, each re-raised the first error until restart, and every marker change kept queuing for a build that would never apply it.
- **Check** — A failed attempt returns to a state from which the next caller starts a fresh one; a promise belongs to one attempt, not to the object that may need several.
- **Seen** — rewrite (review of PR #114); rewrite (resource inventory: replaying the changes made during the build, or the spawn itself, could still raise past the reset). recurred ×2.

## 12. Truthful reporting, accounting and rate control

### A-12.1 Reporting an effect that did not happen
- **Pitfall** — A notify to a stopped extension went nowhere and `tsync evict` printed "Evicted". `expire` exited 0 after `Error:`; `cache --evict /nonsense` exited 0; rsync of a single file enumerated zero children and succeeded; `sync --full` and `trash --purge` skipped the drain. Copy onto an existing destination kept the old one and answered success. `tsync stop` printed "Stopped" without signalling. Android evict/restore toasted success as no-ops. In the rewrite a dry-run repair printed "509 anchored" and a cancelled verification reported done.
- **Check** — Replies state confirmed effects only; IPC sends report delivery, and a caller with a user waiting fails on non-delivery. Zero work on a non-empty request is an error. Every failure sets non-zero exit; exits go through the drain. Dry runs speak in the conditional; cancelled is not done.
- **Seen** — 34756cfd, 044f9e9b, 652baed4, bd4be598, PR #60, PR #84, notes (backends/local, android, file-provider, 07 B.4), 4bd1d2be, 607ec6f2, rewrite (`rsync --move` said a file with an unpublished edit was not copied, copied its stale store version and deleted the source). recurred ×7, rewrite.

### A-12.2 "Nothing found" indistinguishable from "nothing checked"
- **Pitfall** — `verifyChunks` asked config whether a function was deployed; a stale answer meant "no corruption" with nothing checked. A domain filter matching nothing deployed a function that never fired. A verifier lacking read rights also lists zero markers. A campaign where no store accepted requests, or a request count frozen over polls, means nobody is consuming.
- **Check** — Reports distinguish clean, unchecked and probe-failed; aggregates require every member to report positively; otherwise exit non-zero. Liveness comes from observed draining, not config.
- **Seen** — e1851ee1, 19e27a64, c8dfe860, caa03c0e, 27685a67, PR #50. recurred ×4.

### A-12.3 Capability answered by a constant
- **Pitfall** — The http-proxy answered `is_local` "no" always; `ls` called every file cloud even with manifest mirrored and chunks cached.
- **Check** — Capability queries answer from real state; status columns are tested for both answers.
- **Seen** — 0b7a01ad, 7aa1fc9e, 3b743cbe. recurred ×3.

### A-12.4 "Not served here" reported as "down"
- **Pitfall** — Status knocked on a per-domain socket for every domain, so a proxy-only domain read as a daemon that was down; one-shot job reports went to that socket and never showed. Every process answered for the whole domain. `Diagnostics.merge` kept non-domain keys from the first report only.
- **Check** — Discovery is resolved by whoever holds the domain × frontend matrix. "Not served" and "down" differ. One process assembles each machine report, merging by pid.
- **Seen** — 00ee950a, fab1c2fe, aa43b0dd, a0b1de78, PR #60. recurred ×4.

### A-12.5 Transfer accounting credits the wrong bytes
- **Pitfall** — The tray credited local reassembly reads as pulls. `ensure_fetched` answered one boolean for "waited" and "transferred", so readers joining a fetch were charged the whole group: 128 KB for a 16 KB read with one GET. Pulled bytes dropped readers who waited on another's fetch.
- **Check** — Credit only bytes this caller put on the wire; "did I wait" is a separate field.
- **Seen** — 8e0b871e, 00585588, 9f41023b, 3e8f12cc. recurred ×3.

### A-12.6 Progress measured in the wrong unit
- **Pitfall** — A copy's ETA from job count could not time a replica owing one large file; present chunks check instantly and promised minutes for hours of work.
- **Check** — Progress uses the unit dominating cost (bytes sent), from the running job's own pace.
- **Seen** — f6c85477, 2c36720b. rewrite.

### A-12.7 Rate grows without demand
- **Pitfall** — A sender with little to send saw flat delay and was granted more every step: a fresh daemon reached terabytes a second within a minute and read capacity off its first real load. A body waiting out a debt on an idle link counted as demand.
- **Check** — A delay-based controller grows only when it held a sender back and bytes are completing.
- **Seen** — 80b5e045, notes (uplink-governor).

### A-12.8 Capacity misestimated
- **Pitfall** — A step with no queue only shows the link kept up with what was offered; two steps with one body in flight read a few-MB/s link as 20 MB/s; one probe behind one body ended a ramp early; a body longer than the window was credited as a burst at its end. The decrease floor was dead because the ceiling clip came after it. A tick with no samples read as "no queue".
- **Check** — Bound capacity by what completed (≤ 2× achieved); end ramps on two consecutive over-target ticks; spread credit over the body's duration; apply the floor after the ceiling; "no samples" is unknown.
- **Seen** — 80b5e045, c3c4a983, 859ecf1f, notes (uplink-governor). recurred ×3.

### A-12.9 Delay baseline shared or drifting
- **Pitfall** — The baseline was the fastest reply over all stores on a link; when a near store went down the far store's distance read as queueing and the rate sat at the floor for up to 10 minutes. After 10 minutes a standing queue became the baseline.
- **Check** — One bounded baseline window per path.
- **Seen** — PR #108, notes (uplink-governor). recurred ×2.

### A-12.10 Admission accounting asymmetric or unfair
- **Pitfall** — Bodies ≤ 64 KiB skipped the queue whenever the budget covered them and could starve a waiting chunk forever. Retries were not re-admitted and elapsed time included backoff. Foreground and disabled admissions released bytes never taken. Floors oversubscribed (n × min_rate). Every start re-ramped from 256 KiB/s.
- **Check** — Any bypass of a fair queue is bounded (passes the head by at most its own size in total). Admit every attempt, release only what was taken, cap the sum of floors, persist the operating point, keep the law pure with `now` as an argument.
- **Seen** — PR #108, notes (uplink-governor), 2c6882c0, a9867521, e2d722cb.

### A-12.11 Guards no test watches
- **Pitfall** — Mutation checks found guards whose removal changed no test: replay telling published from unpublished entries, dropping a rewritten chunk from the corruption set, the GC lock always granted, readahead never firing, a resync clearing nothing, s3 transient retry, double stop of an IPC subscription and unflushed replies, Executed reached on the way to Completed, inode-tree batch leftovers. statfs was unexercised until late. rsync followed symlinks and dropped empty directories until a live suite caught it.
- **Check** — Each guard has a test that fails when it is removed. Tree-copy tests cover symlinks, empty dirs, single files and re-runs. A suite asserts that it ran something.
- **Seen** — 73edcded, 5eff4a06, 110695c4, ab654632, ab53edd3, dc1472ef, 674b0ec7, 62b52a6e, 170266d9, e16a9d76, ebde3345, a6ba4ace, PR #82.

### A-12.12 Subscriber teardown by exception and double stop
- **Pitfall** — A subscriber connection was two loops raced, the winner cancelling the loser; a client leaving arrived only as an undocumented exception from `read_line`. Waking the stop promise twice raised, guarded by a flag nobody tested.
- **Check** — Peer disconnect is a value. Stop is idempotent. The read side signals the write side and the two are joined, not cancelled from outside.
- **Seen** — 674b0ec7, 62b52a6e.

## Review checklist

1. **Durability** — Does every record retire only after its remote commit and cursor move? Is the intent durable before any local effect? Is the new state present before the old is removed, at every crash point? Is every state file temp + fsync + rename, with the directory fsynced? Can any path publish zeros or empty for bytes it failed to read? Can eviction, resync or a temp sweep reach sole-copy data or user files?
2. **Concurrency** — Which check-then-act sequences assume no yield between them? Is any lock held across a store round trip, and is a reference resolved outside the lock that mutates it? Is every buffer owned until its last asynchronous reader finishes? Does any fan-out take a slot of a pool it already holds? Does every state change that can satisfy a wait signal it? Which process owns each piece of mutable local state?
3. **Identity and conflicts** — Is every contested name claimed by conditional create, losing as an ordinary outcome? Do readers check markers against anchors through one predicate? Is every conflict name free across mirror and staging? Does every (peer op, local unpublished op) pair have a convergent row, never "skip"? Do pending ops follow their folder when it moves?
4. **Failure classes** — Can "could not look" ever reach an absent branch that creates, deletes or advances? Is any answer built from failures memoised? Who classifies, and is unknown permanent where retries never end? Does a permanent item park instead of blocking an ordered queue? Are cancellation and stop distinct from failure everywhere?
5. **Durable queues** — Is resume idempotent on record id? Is an unreadable record kept and the target marked degraded? Is work parked, never dropped? Does every log have a resumer, and is a record invisible until its submitter releases it?
6. **Journal and feed** — Is anything read "since key K"? Does the mark pass only handled entries? Does every notification-driven waiter also sweep on a clock that can fire? Is everything needed to describe an op captured at apply time? Are cursors bounded positions in a stable order, with explicit end?
7. **Stores, replication, GC** — Is every chunk hashed against its key before use? Is the corruption marker consulted before any positive memo? Is the GC reference gate in the driver around every manifest write? Are mains the only replication source, and is a non-main write refused while the main is down? Did a new interface member or batch path reach every wrapper and override?
8. **Caches** — Do lookups ever leave the mirror? Is a negative entry a store fact under the pre-fetch mark? Is a partial body ever taken as whole? Are cached bodies validated by an opaque version from the same store? Does a rebuild ever expose an empty view?
9. **Security** — Is every key of a multi-key request authorised? Does the signature cover the query? Are names private types parsed by segment, refusing `..` and reserved areas? Do shares carry and check their domain? Is every server input bounded before the body and every handshake timed?
10. **Ownership and types** — For each table, counter, pool or debouncer: one per what? Is each rule (child predicate, path resolver, parser, formatter, validator) owned once? Is kind carried by type, never by spelling? Does every config writer validate with the strict parser?
11. **Deadlines and lifecycle** — Does every request have a first-byte deadline and a silence-based stall bound on the monotonic clock? Do outer deadlines derive from inner constants? Does failover skip a down member before its ladder ends? Does every spawned fiber have an observed failure policy and every queue a stall watchdog? Does stop end backoffs, leave work owed and still flush publication state?
12. **Reporting and control** — Does each reply state only confirmed effects, with non-zero exit on failure or zero work? Is "unchecked" distinct from "clean"? Is "not served" distinct from "down"? Are only wire bytes credited? Does the rate law grow only when it held a sender back, per-path baseline, symmetric admission?
