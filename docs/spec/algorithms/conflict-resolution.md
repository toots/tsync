# Conflict resolution between asynchronously publishing clients

This document owns what happens when two clients' changes meet: the conflict principle, the two
decision tables (a peer's op arriving, and our op publishing to a store that moved on), the facts
they read, the actions they enact, and the conflicted-copy name. How changes travel (the WAL, the
journal, the cursor, the applied log, recovery) is owned by [wal-and-journal.md](wal-and-journal.md);
this document states only what it needs from that protocol. Related rules owned elsewhere:

- folder claims, anchors, markers and trash on the store: [data-model/backend.md](../data-model/backend.md) §6;
- local state (mirror, staged edits, folder-id index, WAL): [data-model/local-cache.md](../data-model/local-cache.md)
  and [04](../04-checkout-cache.md);
- failure kinds: [failure-model.md](failure-model.md);
- versions and trash retention: [gc.md](gc.md);
- the GC interlock every publish of a chunk reference goes through (P8): [gc.md](gc.md).

---

## 1. Problem, principle, goals

One person uses several machines (clients) against one shared store. A client makes every change
to its local tree at once, with zero round trips, and publishes it later: seconds later on a good
link, days later offline. Two clients can therefore each hold changes the other has not seen. Two
moments expose this:

- **Arrival.** A peer's published op reaches a client that may hold unpublished work touching the
  same names.
- **Publish.** A client publishes its own op to a store that may have changed after the op was
  recorded.

### 1.1 The principle ("best-effort conflicts")

A clash is settled by the first rung of this ladder that applies:

1. **Immediately.** A clash is resolved the moment the peer's op arrives, or the moment a publish
   finds the store changed. Nothing is deferred and no client waits for more information.
2. **Soundly on both sides.** No data is lost, and every client ends with the same tree. Ops that do
   not clash are applied as they are.
3. **When in doubt, two copies.** Whatever of this client's is in the way and still unpublished is
   moved to a conflicted name (§4.7) or kept under its own name, and that move is published. There
   is no merge and no guessing at intent.
4. **Last resort, the winner takes all.** When both sides had already published, the store's later
   write wins everywhere, and the loser survives in version history (a file) or in the trash (a
   removed folder's content).

**The loser rule.** The loser is the side that still holds its op *unpublished* when the other's
becomes known, and the loser moves its own item and publishes that move. The winner does nothing
special. Only one side can hold an op unpublished with respect to the other's published op, so
every client computes the same loser without coordination (§5.2).

**Additions outlive removals.** An unpublished edit or addition survives a concurrent removal: an
edited file outlives a delete, and additions under a removed folder are rescued into a conflicted
copy of that folder. A removal never destroys content it did not see.

**Folders outlive files at one name.** When a file and a folder claim one name and both are
published, the folder keeps the name and the file's owner moves the file to a conflicted name. The
folder side never yields to a published file, so the outcome does not depend on arrival order.

### 1.2 Goals

- G1. Local operations never wait on the network and never fail because of a peer.
- G2. No acknowledged byte is lost: every byte is in the live tree, or (only in the rung-4 cases of
  §5.3) in version history or the trash.
- G3. **Convergence.** Once every client has published everything and applied every entry, all
  mirrors equal the store's tree: the same names, kinds and contents.
- G4. Every decision is a **pure function** of gathered facts, total over its inputs, so the policy
  can be printed exhaustively and tested apart from I/O.
- G5. Re-applying an entry, or applying entries in any order, reaches the same state (§5.2 point 4).

### 1.3 Non-goals

- Serializability or causal consistency across clients.
- Content merging, or preserving the intent of both sides beyond keeping their bytes.
- Detecting that two already-published writes to one file were concurrent when either writer did
  not record the edit's base (§5.3).

---

## 2. System model

A1. **Store.** `get`, `put`, `delete`, `head`, `list` and server-side `copy`, plus a conditional
    create on folder-marker keys that arbitrates folder names
    ([data-model/backend.md](../data-model/backend.md) §6.2). No transactions, no multi-object
    atomicity, no conditional write on file records.

A2. **No peer channel.** Clients learn of each other only through journal entries on the store.

A3. **Entry order.** Every unit of work carries an entry key (start time, client id), totally
    ordered but not causal; entries become visible out of key order. Peers apply entries in key
    order within a pass, each at most once per client (dedupe by key, [wal-and-journal.md](wal-and-journal.md) §4.4).

A4. **One owner per domain** (P1). All local state of a domain on a machine is mutated by one
    process, which serialises every check-then-act on names under one metadata lock. Arrival,
    local mutations from every frontend, recovery and the local enactments of Publish all take it.

A5. **Durable local records.** A WAL record is durable before its local half runs (P2), and
    recovery runs at owner start before anything else touches the domain.

A6. **Mostly sequential use.** A person rarely edits one item on two machines within one publish
    window. The design optimises for no clash and degrades gracefully in rare shapes.

---

## 3. State and facts

### 3.1 Items and identity

| Item | Identity | On the store |
|---|---|---|
| **File** (regular file or symlink) | its path; no stable id | a file record (manifest) at `(parent folder id, leaf)` |
| **Folder** | a folder id minted locally by its creator, final for life | a marker at `(parent id, leaf)` naming the id, and an anchor `id → (parent id, leaf)` that is authoritative ([data-model/backend.md](../data-model/backend.md) §2.6–2.7) |
| **Root** | fixed id | — |

A folder rename never changes the id. A file rename moves a record on the store (copy, then delete
the source). A folder name is claimed by conditional create; a lost claim is never resolved by
re-identifying a folder, only by the loser taking a conflicted name.

### 3.2 Operations

```
put(path, size)                        create or overwrite a file (a symlink is a put)
delete(path)
mkdir(path, folder id?)
rmdir(path, folder id?)                folder removal = retirement to the trash
rename(src, dst, is_dir, size?, folder id?)
```

An op without a folder id names the folder by path alone; readers SHOULD accept it, writers MUST
always include the id. The encoding is owned by
[03](../03-journal-sync.md) §2.3.

### 3.3 Local state the decisions read

Per client and domain, all owned by the domain owner:

- **Mirror**: each file's current record and each folder's id.
- **Staged edits**: bytes written here and not uploaded. A file is *staged* iff it has a staged
  edit. A folder is never "staged" by itself; only files are.
- **Unpublished ops**: this client's ops whose WAL record is in state INTENT or PREPARED, parked
  or not. An op whose record reached EXECUTED is *published*: its store half is done.
- **Folder-id index**: `id → local path`, and for a path its whereabouts (`Live(id)`,
  `Moved(id, now_at)`, `Removed(id)`, `Unknown`), durable because it outlives the folder.
- **View** of a path: the store record this client last installed (from a peer's entry), applied,
  or itself stored for that path, or *none*. Storing a manifest updates the view of its path even
  when the local promotion of that upload is later abandoned; publishing a file rename moves the
  view from source to destination; publishing a delete sets it to none. The view is the mirror's
  published record for the path ([04](../04-checkout-cache.md) keeps it so). It also records
  whether this client wrote it (*own*): true when this client's upload or republish stored it.
- **Base** of a staged edit: the content identity of the view the edit started from, or *unknown*;
  a frontend `write` may supply it (§4.9). A put this client publishes carries it as the op's
  `base` field ([03](../03-journal-sync.md) §2.3), omitted when unknown.
- **Expected prior record** of an unpublished `delete(p)` or file `rename(_ → d)`: the view of `p`
  (resp. `d`) at the moment the local half ran, or *none*. It is stored with the WAL record, locally
  only ([04](../04-checkout-cache.md) §2); it never reaches the journal. A record without
  it has an *unknown* expected prior.

Records are compared by **content identity**: the manifest's whole-file digest `h1`
([02](../02-remote-model.md) §2.1), the same value frontends see as `contentId`.

### 3.4 The facts rule

> Facts that come from the store are read **before** the metadata lock is taken, never while
> holding it. Facts that come from local state are read **under** the lock.

A slow link therefore delays only the entry that needs the answer, never a local operation (G1).
If, under the lock, a decision needs a store answer that was not read ahead, local state changed in
between; the entry fails as TRANSIENT/local and is read again on the next pass.

On the publish side, facts are gathered outside the lock. Some are **answers to attempts** (a folder
claim, a file move), because the store is the arbiter of those; the attempt comes first and the
decision is about what it met. A local change such a decision makes takes the lock and re-checks its
precondition.

### 3.5 Places and occupants (shared by both tables)

**Landing name.** A peer names items by *its* paths; this client may have moved things since.

- **Folder translation.** Walk the op's parent path from the root. For each segment, if this client
  moved the folder (`Moved(id, at)`) and the store still files `id` under the peer's name, the local
  folder is `at`; otherwise it is `parent + leaf`. The store check tells "the folder I moved" from "a
  new folder the peer made under the old name".
- **Owed-rename translation** (only for `put`, §4.3): the translated path is then followed through
  this client's unpublished file renames, `src → dst`, bounded by the number of such renames, so a
  peer's edit lands on the file it was made to.

**Store placement** `place(id)`: from the store's anchor of `id`: *trashed* if the anchor says in
trash; *at L* if the anchor names a parent id this client can name and `L` is that parent's local
path plus the anchor's leaf; *unknown* otherwise (no anchor, or a parent not nameable here).

**Occupant** of a local name `L`, exactly one of:

| Occupant | Meaning |
|---|---|
| `none` | nothing at `L` |
| `file` | a file record, no staged edit, and `L` is not the destination of an unpublished file rename of ours |
| `staged_file` | a staged edit at `L`, and `L` is not the destination of an unpublished file rename of ours |
| `renamed_file` | `L` is the destination of an unpublished file rename of ours (staged or not) |
| `folder(same)` | a folder holding the op's own folder id (folder ops only) |
| `folder(ours)` | a folder with another id whose presence at `L` is unpublished work of ours: an unpublished mkdir or folder rename of ours carries its id |
| `folder(published)` | a folder with another id, no unpublished mkdir or folder rename of ours carries it |
| `folder(no id)` | a folder holding no id |

**Under our removal** `removal(L)`: some ancestor of `L` is a folder `F` this client removed with
an **unpublished** rmdir (whereabouts `Removed(id)` and an unpublished rmdir of ours carries `id`).
Its **rescue folder** `R(F)` is the folder at `conflict_name(F, n)` for the smallest `n ≥ 1` whose
name is free here or holds a folder created by an unpublished mkdir of ours; the rescue creates it
when free. `rel` is `L`'s path below `F`.

**Store answers** read ahead for each op: `S(p)`, the store's current file record at each path the
op names (present or absent); `place(id)` for folder ops; the marker id at each ancestor that has
no id here (ancestor adoption, §4.1).

---

## 4. The algorithm

### 4.1 Arrival: applying a peer's entry

```
apply_entry(ops):                                  # called by the apply pass, one entry at a time
  adopt_missing_ancestor_ids(ops)                  # store reads; adopt only, never mint
  answers := read_ahead(ops)                       # every store answer §3.5 lists; no lock
  with metadata lock:
    for op in ops, in order:
      facts, place := gather(op, answers)          # local facts; a missing answer → TRANSIENT/local
      decision := ARRIVAL(facts)                   # pure, §4.3
      if clashed(decision): log(op, facts, decision)
      enact each action of decision, in order      # §4.6; each effect durable before the next
  # the pass notes the entry handled only after this returns
```

The read-ahead MAY decide speculatively to learn which answers it needs; the speculative
decisions are discarded.

**Ancestor adoption.** An op under a folder that has no id here reads the store's marker for each
id-less ancestor, top-down, and adopts the id it names, unless this client moved or removed a
folder with that id (whereabouts `Moved(id, …)` or `Removed(id)`). It never mints an id, because
minting would fork a namespace other clients already agree on.

**Missing ancestors.** An op landing under a path whose ancestors do not exist here creates them as
folders without ids (adopting ids per the previous rule). A later `mkdir` of such a folder gives it
its id (A23).

### 4.2 Arrival facts

| Op | Facts |
|---|---|
| `put(p)` | `S(p)`; `removal(L)`; `occupant(L)`, where `L` is `p` after folder and owed-rename translation |
| `delete(p)` | `S(p)`; `removal(L)`; `occupant(L)`, where `L` is `p` after folder translation only |
| `mkdir(p, id)` | `held`: `id` is held by a folder anywhere here; `place(id)`; target `T` = `place(id)` when it is *at L*, else `p` after folder translation; `removal(T)`; `occupant(T)` |
| `rmdir(p, id)` | `place(id)`; `target ∈ {by_id, at_path, held_by_another, gone}`: `by_id` if `id` is held here; else `at_path` if the translated `p` holds a folder with no id; else `held_by_another` if it holds a folder with another id; else `gone` |
| `rename dir(s→d, id)` | `ours_owed`: an unpublished op of ours carries `id`; `place(id)`; `source ∈ {at_path, by_id, gone}`: `at_path` if translated `s` is a folder not holding another id, else `by_id` if `id` is held here, else `gone` (path before id: a copy under the new name may already hold the id); target `T` = `place(id)` when *at L*, else translated `d`; `already_there`: the source location is `T`; `removal(T)`; `occupant(T)` |
| `rename file(s→d)` | `S(s)`, `S(d)`; `source_here`: `occupant(s')` is `file` or `staged_file`, where `s'` is translated `s` (a `renamed_file` at `s'` is ours, not the file the peer moved); target `T` = translated `d`; `removal(T)`; `occupant(T)` |

A `mkdir(p)` or `rmdir(p)` without an id takes the store's marker id at `p` if there is one;
otherwise `held` and `place` are false/unknown and the op acts by path.

### 4.3 The Arrival table (complete)

`decision = skip(reason) | apply([action …])`. Rows are tried top-down within an op; the first
that matches decides. The last row of each op matches everything left, so the table is total.
Actions run in list order: what is in the way yields before the op applies.

**put(p)**

| # | Situation | Decision | Why |
|---|---|---|---|
| A1 | `S(p)` absent | skip(superseded) | a later delete or rename moved it on; its entry settles the name |
| A2 | `removal(L)` | `rescue-theirs(L)` | their addition outlives our unpublished removal |
| A2a | occupant `file`; their put carries `base` b; the view V of `L` is *own*; b ≠ V; `S(p)` ≠ V | `revive-ours(L)` | concurrent published edits: their edit did not start from our published version and replaced it; the later publisher's edit becomes the conflicted copy |
| A3 | occupant `none` or `file` | `write-theirs(L)` | a plain edit |
| A4 | `staged_file` | `file-aside(L)`, `write-theirs(L)` | edit/edit, ours unpublished |
| A5 | `renamed_file` | `retarget-our-rename(L)`, `write-theirs(L)` | our rename lost the name; it carries its own staged bytes |
| A6 | `folder(ours)` | `folder-aside(L)`, `write-theirs(L)` | kind clash, our folder unpublished |
| A7 | `folder(published)` | skip(folder holds the name) | kind clash, both published: the folder wins; the file's owner yields (A19, A37, A42) |
| A8 | `folder(no id)` | `folder-aside-local(L)`, `write-theirs(L)` | an id-less folder cannot be named on the store |

**delete(p)**

| # | Situation | Decision | Why |
|---|---|---|---|
| A9 | `removal(L)` | skip(already removed here) | our removal covers it; a rescued copy stays ours |
| A10 | occupant `staged_file` or `renamed_file` | skip(ours publishes later) | our edit, or our file renamed onto the name, outlives the delete |
| A11 | `S(p)` present | as A3–A8 for `L` | the name was written again after this delete (a late or repeated entry) |
| A12 | `none` | skip(already applied) | |
| A13 | `file` | `remove-file(L)` | |
| A14 | any folder | skip(folder holds the name) | the delete named a file |

**mkdir(p, id)**

| # | Situation | Decision | Why |
|---|---|---|---|
| A15 | `held` | skip(already applied) | one id never lives at two paths |
| A16 | `place(id)` trashed | skip(removed since) | a later removal's entry settles it |
| A17 | `removal(T)` | `rescue-theirs(T)` | their new folder outlives our unpublished removal |
| A18 | occupant `none` | `make-folder(T, id)` | |
| A19 | `file` | `file-aside-published(T)`, `make-folder(T, id)` | kind clash, both published: the folder wins |
| A20 | `staged_file` | `file-aside(T)`, `make-folder(T, id)` | kind clash, our file unpublished |
| A21 | `renamed_file` | `retarget-our-rename(T)`, `make-folder(T, id)` | |
| A22 | `folder(ours)` or `folder(published)` | `folder-aside(T)`, `make-folder(T, id)` | two folders under one name: ours yields |
| A23 | `folder(no id)` | `make-folder(T, id)` | the id-less folder takes the id |

**rmdir(p, id)**

| # | Situation | Decision | Why |
|---|---|---|---|
| A24 | the store has an anchor for `id` and it is not in the trash | skip(restored since) | the folder was brought back after this removal |
| A25 | `target = gone` | skip(already applied) | |
| A26 | `target = held_by_another` | skip(held by another folder) | the name belongs to a folder the op is not about |
| A27 | `by_id` or `at_path` (folder `F`) | `rescue-ours-under(F)`, `remove-folder(F)`, `fill-vacated(F)` | our unpublished additions survive; the folder goes |

**rename dir(s→d, id)**

| # | Situation | Decision | Why |
|---|---|---|---|
| A28 | `ours_owed` | skip(ours publishes later) | our own op on this folder follows on the store (P16–P21 settle it) |
| A29 | `place(id)` trashed | skip(removed since) | rmdir beats rename from either side |
| A30 | `source = gone` | skip(nothing to move) | |
| A31 | `already_there` | skip(already applied) | |
| A32 | `removal(T)` | `rescue-theirs(T)` | the folder they moved in outlives our unpublished removal |
| A33 | occupant(T) `none` | `move-folder(T)`, `fill-vacated(source)` | staged content moves with the folder |
| A34 | `folder(same)` | `retire-stale-source` | the destination already holds this folder; the source is a copy that came back |
| A35 | `folder(ours)` or `folder(published)` | `folder-aside(T)`, `move-folder(T)`, `fill-vacated(source)` | |
| A36 | `folder(no id)` | `folder-aside-local(T)`, `move-folder(T)`, `fill-vacated(source)` | never move onto a non-empty directory |
| A37 | `file` | `file-aside-published(T)`, `move-folder(T)`, `fill-vacated(source)` | folder wins |
| A38 | `staged_file` | `file-aside(T)`, `move-folder(T)`, `fill-vacated(source)` | |
| A39 | `renamed_file` | `retarget-our-rename(T)`, `move-folder(T)`, `fill-vacated(source)` | |

**rename file(s→d)** — every row ends with the **source rule** below.

| # | Situation | Decision | Why |
|---|---|---|---|
| A40 | `S(d)` absent | (destination skipped: superseded) | the file moved on; a later entry settles it |
| A41 | `removal(T)` | `rescue-theirs(T)` | |
| A42 | occupant(T) `folder(published)` | (destination skipped: folder holds the name) | folder wins; the file's owner yields |
| A43 | `none` or `file` | `arrive(T)` | |
| A44 | `staged_file` | `file-aside(T)`, `arrive(T)` | our new file at the destination yields |
| A45 | `renamed_file` | `retarget-our-rename(T)`, `arrive(T)` | their rename onto the destination of ours: ours lost the name |
| A46 | `folder(ours)` | `folder-aside(T)`, `arrive(T)` | |
| A47 | `folder(no id)` | `folder-aside-local(T)`, `arrive(T)` | |

`arrive(T)`: if `source_here`, `move-file(s' → T)` (cached bytes and any staged edit of ours
follow the file), then, if the moved file has no staged edit and its record differs from `S(d)`,
`write-theirs(T)`; otherwise `write-theirs(T)`.

**Source rule**, after the destination: at `s'`, if the occupant is `none` or `file`: install
`S(s)` if present, else `remove-file(s')` if a file is there. A `staged_file` or `renamed_file` at
`s'` is left alone (ours publishes later).

`clashed(decision)` is true for every skip except *already applied*, *nothing to move*,
*superseded* and *already removed here*, and for every decision containing an aside, a retarget, a
rescue with something to rescue, `revive-ours`, or `retire-stale-source`. A clashed decision is logged with its
facts.

### 4.4 Publish: our own op meets a store that moved on

The metadata queue runs this for each op of a metadata record; the upload queue runs the put rows
before storing a file's manifest. Both run outside the metadata lock. Puts from whole-domain
operations (import, rsync, revert, bulk publish) do not use the put rows: they overwrite on purpose,
saving versions ([05](../05-ops-config.md)).

```
publish_op(op), rounds := 0:
  facts, place := gather_publish(op)          # may attempt a claim or a move (§4.5)
  d := PUBLISH(facts)                          # pure
  enact d.actions                              # local ones take the metadata lock and re-check
  case d.ending:
    publish      → emit op AS IT IS HERE NOW   # a folder at its current place, found by id;
                                               # a file rename with its current destination
    nothing_owed → emit nothing
    superseded   → CANCELLED: the work continues under a record of its own (written first)
    again        → rounds += 1; if rounds > MAX_CLAIM_ROUNDS: fail EXISTS; else publish_op(op)
    retry        → raise the attempt's failure unchanged (the queue acts on its kind)
publish_record(r) := concat(publish_op(op) for op in r.ops)
```

What is emitted is what the protocol publishes and records in the EXECUTED state
([wal-and-journal.md](wal-and-journal.md) §4.2). An empty result completes the record without an
entry.

**Publish facts.**

| Op | Gathered | Fact |
|---|---|---|
| put(p) (staged edit or symlink) | the store's current record at `p`; the edit's base (§3.3), or the view of `p` when the base is unknown | `base_current` if they are equal (both absent counts), else `store_moved_on`. The comparison is repeated when the replaced record is read for its version save, immediately before the manifest is written |
| delete(p) | local kind at `p`; the store's record at `p`; expected prior | a file is at `p` here: `here_again`; store absent: `store_gone`; store equals the expected prior, or the prior is unknown: `store_as_expected`; else `store_changed` |
| mkdir(p, none) | — | `no_id` |
| mkdir(p, id) | local place of `id`; `place(id)` | not held here: `gone_here`; the anchor files `id` elsewhere or in the trash: `filed_elsewhere`; else **attempt the claim** of the local place for `id`: `claimed` or `name_taken` |
| rmdir(p, none) | — | `no_id` |
| rmdir(p, id) | `place(id)`; the marker at the op's old key (the op fails if that key cannot be named) | anchor in trash: `already_trashed`; an anchor exists, or the old marker names `id`: `published`; else `never_published` |
| rename dir(s→d, id) | local place of `id`; `place(id)` | not held here: `gone_here`; anchor in trash: `trashed`; the anchor files it where it is here: `filed_here_already`; no anchor and no marker names it: `never_published`; else **attempt the claim** of the local place: `name_taken` or `claimed` |
| rename file(s→d) | the store's record at `d`; expected prior; then **attempt** the move | a record at `d` that differs from a known expected prior: `destination_taken`; else attempt (save versions of `s` and of any record at `d`, copy `s → d`, delete `s`): success `moved`; on failure: `s` still on the store `source_still_there`; else `d` present `landed`; else `source_gone(x)`, `x` = what we hold at `d`: `staged`, `published` or `absent` |

### 4.5 The Publish table (complete)

| # | Our op | Fact | Actions | Ending | Why |
|---|---|---|---|---|---|
| P1 | put | `base_current` | — | publish | the op carries the edit's `base` when known |
| P2 | put | `store_moved_on` | `revive-ours(L)` | record owed puts of ours: `S(p)` installed at `aside(L)` and republished there, and our view V republished at `L` (its op's `base` = the content identity of `S(p)`); both through the GC interlock. If V's content cannot be republished (a chunk gone from the store and not cached here), install `S(p)` at `L` instead (rung 4) | the two puts |
| `ours-aside-file(p)` | superseded | a peer's write landed first; ours is the unpublished one |
| P3 | delete | `here_again` | — | nothing_owed | a file is at the name again here; its upload publishes it |
| P4 | delete | `store_gone` | — | publish | the removal may be ours from before a crash; peers must hear it |
| P5 | delete | `store_as_expected` | `remove-from-store` | publish | |
| P6 | delete | `store_changed` | — | nothing_owed | a newer write outlives our removal; its entry installs it here |
| P7 | mkdir | `no_id` | `put-marker` | publish | the op names no id to claim with |
| P8 | mkdir | `gone_here` | — | nothing_owed | removed here since |
| P9 | mkdir | `filed_elsewhere` | — | nothing_owed | a later op of ours placed it, or a peer removed it |
| P10 | mkdir | `claimed` | — | publish | |
| P11 | mkdir | `name_taken` | `ours-aside` | again | the next round claims the conflicted name |
| P12 | rmdir | `no_id` | — | publish | nothing to retire by id; peers act by path |
| P13 | rmdir | `already_trashed` | — | nothing_owed | |
| P14 | rmdir | `never_published` | — | nothing_owed | |
| P15 | rmdir | `published` | `retire-to-trash` | publish | |
| P16 | rename dir | `gone_here` | — | nothing_owed | |
| P17 | rename dir | `trashed` | — | nothing_owed | rmdir beats rename; the peer's rmdir arriving here removes it (A27) |
| P18 | rename dir | `filed_here_already` | — | publish | |
| P19 | rename dir | `never_published` | — | nothing_owed | its mkdir publishes it where it is |
| P20 | rename dir | `name_taken` | `ours-aside-as-rename` | superseded | never write our marker over another folder's |
| P21 | rename dir | `claimed` | `move-marker` | publish | |
| P22 | rename file | `destination_taken` | `retarget-our-rename(d)` | again | a peer's write took the name first |
| P23 | rename file | `moved` | — | publish | |
| P24 | rename file | `landed` | — | publish | the move happened; what failed came after it |
| P25 | rename file | `source_still_there` | — | retry | |
| P26 | rename file | `source_gone(absent)` | — | nothing_owed | nothing to move and nothing in its place |
| P27 | rename file | `source_gone(staged)` | `queue-upload(d)` | superseded | our content publishes under its new name |
| P28 | rename file | `source_gone(published)` | `republish-here(d)` | superseded | rename vs rename or delete: ours keeps its name |

`clashed` is true for P2, P6, P11, P17, P20, P22, P26–P28.

**Late name losses.** A folder claim that loses at confirmation after its op was published
([data-model/backend.md](../data-model/backend.md) §6.2 step 3), and a placement whose
create-if-absent finds the destination taken (§6.4 step 2), are `name_taken` found after the fact.
The owner resolves both like P20: it records an unpublished folder rename of that folder (by id)
from where it is here to `aside(name)`, moves it locally, and the rename publishes through P18 or
P21. The folder keeps its id and its content; peers apply the rename like any other.

### 4.6 Actions and their enactment

Every local action runs under the metadata lock, re-checks the staged facts it relies on under the
key lock ([04](../04-checkout-cache.md) §3.2), and makes its effects durable before the next
action. An aside or rescue that moves an item reuses the local half of a rename. An action that creates owed work writes its WAL record first (INTENT for metadata, before
any local change; PREPARED for a content upload) and only then changes local state, so recovery can
finish it ([wal-and-journal.md](wal-and-journal.md) §4.7). A local move of a staged file or subtree
cancels the uploads owed under the old path and posts them again under fresh keys minted after the
record the move belongs to, so peers apply the move before the puts.

| Action | Local effect | Published as |
|---|---|---|
| `write-theirs(L)` | cancel any upload of ours at `L`; install `S` for `L` as read ahead; if `S` is absent, nothing | — |
| `remove-file(L)` | cancel the upload; drop cached bytes and the record | — |
| `make-folder(T, id)` | create the folder, or give an id-less folder at `T`, the id | — |
| `remove-folder(F)` | remove `F` recursively | — |
| `move-folder(T)` / `move-file(s'→T)` | local move; staged content moves with it | — |
| `fill-vacated(L)` | after a folder left `L`: if `S(L)` is present, install it at `L` | — |
| `file-aside(L)` | move our staged file to `aside(L)`; post its upload | the upload |
| `file-aside-published(L)` | record an unpublished rename `L → aside(L)` (with its expected prior), then move locally | that rename |
| `folder-aside(L)` | record an unpublished folder rename `L → aside(L)` carrying the folder's id, then move locally | that rename (P18 or P21); the folder's own unpublished mkdir, if any, publishes at its current place |
| `folder-aside-local(L)` | move the id-less folder to `aside(L)` locally | not published (it cannot be named on the store) |
| `retarget-our-rename(L)` | one durable WAL update rewrites every unpublished file rename of ours whose destination is `L` to destination `aside(L)` with expected prior *none*, sets it to INTENT and records `L` as the file's current local location; then move `L → aside(L)`; then PREPARED | the retargeted rename |
| `rescue-ours-under(F)` | if nothing of ours below `F` is unpublished, nothing. Else create `R(F)` (a new folder, fresh id, unpublished mkdir) if free; then, parents before children, for each unpublished item of ours below `F` at `rel`: a `staged_file` moves to `R/rel`; a `renamed_file` is retargeted to `R/rel` (as `retarget-our-rename`); a `folder(ours)` moves to `R/rel` keeping its id. A missing parent `R/…` is created as a new folder of ours | R's mkdir; the moved items' own records and uploads |
| `rescue-theirs(L)` | create `R(F)` if free. Then record an unpublished op of ours moving their item from its peer path to `R/rel` (a file rename, or a folder rename carrying their id), and install it at `R/rel`: a file as `S` read ahead (a file rename's source then follows the source rule); a folder by moving it there if its id is held here, else by making it with their id | that rename; our unpublished rmdir of `F` still retires `F` |
| `retire-stale-source` | 1. point the id at the destination in the folder-id index; 2. make the source forget the id; 3. move the source to `aside(source)` locally. This order is idempotent under a crash at any step | not published: the store already files the folder at the destination |
| `revive-ours(L)` | record owed puts of ours: `S(p)` installed at `aside(L)` and republished there, and our view V republished at `L` (its op's `base` = the content identity of `S(p)`); both through the GC interlock. If V's content cannot be republished (a chunk gone from the store and not cached here), install `S(p)` at `L` instead (rung 4) | the two puts |
| `ours-aside-file(p)` | under the lock, if our staged file is still at `p`: move it to `aside(p)` and post its upload | the upload |
| `ours-aside` (P11) | under the lock, if our folder still holds the id: move it to `aside(p)` locally | the next round claims the aside name and publishes the mkdir there |
| `ours-aside-as-rename` (P20) | as `folder-aside` | that rename |
| `queue-upload(d)` | post an upload of our staged file at `d` | the upload |
| `republish-here(d)` | put our record for `d` on the store (through the GC interlock) and post a put record for it | that put |
| `remove-from-store` | save a version of the record, then delete it | the op's entry |
| `put-marker` | anchor, then marker | the op's entry |
| `retire-to-trash` | trash entry, then anchor "in trash", then delete the live marker only if it still names this id ([data-model/backend.md](../data-model/backend.md) §6.4) | the op's entry |
| `move-marker` | new anchor and marker first (claimed), then delete the old marker only if it still names this id | the op's entry |

**Overwrites save a version.** Every action or operation that replaces or removes a file record on
the store saves a version of the replaced record first, when versioning is enabled: an upload over
an existing record, `remove-from-store`, a file rename over an existing destination (both source and
destination), `republish-here`, and revert ([05](../05-ops-config.md)). A failed version save is
logged and does not block the write ([data-model/backend.md](../data-model/backend.md) §2.9).

### 4.7 Conflicted-copy name

`aside(L)` is `conflict_name(L, n)` for the smallest `n ≥ 1` whose name is free both in the mirror
and among staged edits (the mirror does not show staged-only files, and a second conflict must not
land on the first one's copy).

- File `name.ext` → `name (conflicted copy from C).ext`, where the extension starts at the **last**
  `.` of the leaf; a leaf with no `.`, or whose only `.` is its first character, has no extension.
- Folder: the whole leaf, never split: `v1.2 (conflicted copy from C)`.
- `n ≥ 2`: `(conflicted copy n from C)`.
- `C` is the configured display name of the client doing the moving, which is the loser. The aside
  item stays in the same parent.

The name is computed only by the loser and published as its move, so peers never compute it; it
MUST nevertheless stay stable across versions of the software, because it is visible to the user.

### 4.8 Duties of the other actors

- **The local writer** (every frontend, through the owner) records every metadata op durably before
  its local half, with the expected prior record for deletes and file renames, and takes the
  metadata lock for every check-then-act on names, including file creation and writes that create a
  name.
- **The metadata publisher** publishes unpublished records in key order, one at a time, re-reading
  each record just before publishing it (an arrival may have retargeted it). Failure handling is the
  ordered queue's ([failure-model.md](failure-model.md) §7.1).
- **The uploader** runs the put rows before storing a manifest, and waits while an unpublished,
  unparked file rename with a smaller key names its path ([wal-and-journal.md](wal-and-journal.md) §4.2).
- **The apply pass** applies entries in key order and notes each handled only after all its ops are
  enacted; failures step the entry aside ([wal-and-journal.md](wal-and-journal.md) §4.4).
- **A host with a pulled tree** (folders listed from the store when browsed) MUST NOT prune local
  items whose creation is unpublished: what a client made and has not published is, by definition,
  missing from the store.

### 4.9 A local write against a stale base

A `write` from a frontend MAY carry `base`, the content identity of the version the edit was made
from ([08](../08-frontends.md)). If `base` differs from the key's current content identity here
(its staged edit if any, else its published record), the edit was made to a version this client no
longer holds, and the write is the loser (rung 3): it is staged at `aside(key)` as a new file of
this client, and the key keeps its current content. The reply names the key as it now resolves;
the conflicted copy reaches frontends through the change feed. A `write` without `base`, or with
the current base, is an ordinary edit.

---

## 5. Properties

### 5.1 No data loss: where every byte ends up

The unit is content written by a user on some client. The table is exhaustive over the arms.

| Situation | Where the loser's content lives afterwards |
|---|---|
| Our staged edit vs their put (A4) | ours at `f (conflicted copy from us)`, theirs at `f` |
| Our staged edit vs their put that landed on the store before our upload (P2) | the same |
| A frontend's write against a stale base (§4.9) | the write at `f (conflicted copy from us)`, the current content at `f` |
| Our staged edit vs their delete (A10) | ours at `f`, republished by our upload |
| Our delete vs their newer edit (A3 then P3, or P6) | their edit at `f` |
| Our staged edit vs their file rename (A43 with `source_here`) | at the new name, with our edit |
| Our staged new file vs their rename onto its name (A44) | ours aside, theirs at the name |
| Our file renamed onto a name vs their put, mkdir or rename onto it (A5, A21, A45, P22) | ours at the aside name through the retargeted rename |
| Our rename over an existing file vs their delete of it (A10) | ours at the name |
| Our folder vs their file or folder at the name (A6, A22, A35, P11, P20) | our folder aside with everything in it |
| Our published file vs their published folder at the name (A7, A19, A37, A42) | the file at `name (conflicted copy from <file owner>)` |
| Our unpublished additions under a folder they removed (A27) | in `R(F)` = `F (conflicted copy from us)`, structure kept; the published content goes to the trash |
| Their additions under a folder we removed, ours unpublished (A2, A17, A32, A41) | in `R(F)` = `F (conflicted copy from us)`; the rest goes to the trash |
| Rename vs rmdir of one folder (A29, P17, A28 + P15) | the folder and its content in the trash; unpublished additions rescued as above |
| Rename vs rename of one file (A43 without source, P28) | **both** names hold the content: each side's chosen name is kept |
| Rename vs rename of one folder (A28, P18/P21) | the rename published last places it; nothing is duplicated |
| Edit vs edit, both published, the later put carrying `base` (A2a) | the earlier edit at `f`; the later one at `f (conflicted copy from <earlier writer>)` |
| Edit vs edit, both published, no `base` | rung 4: the later upload wins; the earlier survives as the version the later upload saved |
| Removal vs addition, both published | rung 4: the addition is inside the trashed folder until expiry or restore |

**Argument.** No arrival action destroys an unpublished item of ours: every action that overwrites
or removes a name (`write-theirs`, `remove-file`, `remove-folder`, `move-*`) is preceded, in the
same decision, by an aside, retarget or rescue of whatever unpublished item sits at or below that
name; `remove-file` runs only on occupant `file`. No publish action overwrites or removes a record
the client has not seen: P5 and P23 run only when the store holds what the client expects (the
check-then-write window of §5.3 excepted), and every overwrite saves a version (§4.6).

### 5.2 Convergence

**Claim.** Once every client has discharged its records and applied every entry, all mirrors equal
the store's tree.

1. **Files converge on the store.** Every file action installs the store's *current* record for the
   names it touches (`write-theirs`, `fill-vacated`, the source rule, A11), never the record the
   entry was written with. A client that applied the last entry touching a name holds the store's
   record for it, whatever order it saw the entries in.
2. **Folders converge on the anchor.** Folder ops place folders where the store's anchor says now
   (`place(id)`) and skip when the anchor says the folder was removed or restored since.
3. **Names are arbitrated by the store**: folders by conditional create, files by the check before a
   rename or delete and by the last manifest write.
4. **The loser is computed identically.** Take clashing A-op and B-op with A's published first. B
   learns of A's op on arrival, while B's is unpublished, or on publish, when B's claim, move or
   check meets A's result. Either way B moves its item and publishes the move; A applies that move
   like any other op. A never yields for this clash, because when A published, B's op was not on
   the store. For two *published* items (A7/A19, rung 4) the rule is fixed by kind or by the store,
   not by who learns first.
5. **Idempotence.** Re-applying an entry re-gathers facts; each arm becomes a skip (*already
   applied*, *nothing to move*, *superseded*, *restored since*) or installs the store's current
   state again. At-least-once application is therefore safe, and so is application out of key order.
6. **Asides terminate.** An aside, retarget or rescue is a new op with a later key and a fresh name;
   it enters the same machinery, and each round consumes a fresh name.

**Why each side must not move its own item.** In a kind clash, if each side moved its own item
aside on seeing the other's, the two would swap names and stay divergent. Only the unpublished side
moves, and for two published items only the file moves.

### 5.3 Rung 4: what remains winner-takes-all

1. **Two published edits of one file, when a put lacks `base`** (a writer that does not record it,
   or an edit whose base is unknown) or the overwritten version cannot be republished: a receiver
   cannot tell a concurrent edit from a later one. The last manifest written wins; the earlier
   survives as a version. With `base` on the later put, A2a keeps both instead.
2. **Check-then-write windows.** P1, P5 and P22 read the store and then write it. A peer's write
   landing between the read and the write is overwritten (versioned). The store offers no conditional
   write on file records (A1), so the window is closed only by making it short: the owner publishes
   right after the check, and publishes only after catching up with the journal
   ([wal-and-journal.md](wal-and-journal.md) §4.2).
3. **Removal vs addition, both published.** The addition goes to the trash with the folder.

### 5.4 Coverage by op pair

B's op is unpublished when A's arrives (arrival), unless marked *publish*: then B publishes after A
did and before B applied A's entry. Every row ends identical on both clients and on the store.

| Row | B | A | Arms | Final tree everywhere |
|---|---|---|---|---|
| N1 | renames f over g | — | P23 | g holds f's content |
| F1 | deletes f | edits f | A3; P3 | f with A's edit |
| F1p | deletes f (publish) | edits f | P6; then A3 | f with A's edit |
| F2 | deletes f | renames f→h | A43 (no source); P4 | h |
| F3 | deletes f | creates x, renames x→f | A43; P3 | A's f |
| F4 | renames f→g | edits f | A3 (translated to g); P23 | g with A's edit |
| F5 | renames f→g | deletes f | A12; P28 | g |
| F6 | renames f→g | renames f→h | A43 (no source); P28 | h **and** g, same content |
| F7 | renames f→g | creates g | A5; P23 to the aside name | A's g, B's at `g (cc from B)` |
| F7p | renames f→g (publish) | creates g | P22; P23 | the same |
| F8 | renames f→g | creates g, renames g→h | A5, then A43 | h and `g (cc from B)` |
| F9 | edits f | edits f | A4 | A's f, B's at `f (cc from B)` |
| F9p | edits f (publish) | edits f | P2 | the same |
| F10 | edits f | renames f→g | A43 (source staged) | g with B's edit |
| F11 | creates g | renames f→g | A44 | A's g, B's as a conflicted copy |
| F12 | edits f | deletes f | A10 | f with B's edit |
| F13 | renames x over f | deletes f | A10; P23 | f with x's content |
| F14 | renames x→g | renames f→g | A45; P23 to the aside name | A's g (f's content), B's at `g (cc from B)` |
| D1 | removes d/a, then d | adds d/x | A2; P5, P15, P10, P23 | d in the trash; x at `d (cc from B)/x` |
| D2 | removes d | renames d→e | A28; P15 | d in the trash |
| D2p | renames d→e (publish) | removes d | P17; then A27 | d in the trash |
| D3 | renames d→e | adds d/x | A3 (translated to e/x); P21 | e/x |
| D4 | renames d→e | renames d→f | A28; P21; A applies B's (A33) | e (the last published) |
| D5 | renames d→e, writes e/ours | creates e, writes e/theirs | A22; P21 publishes d→`e (cc)` | A's e/theirs, `e (cc from B)/ours` |
| D6 | creates d, writes d/ours | creates d, writes d/theirs | A22; P10 at the aside name | A's d, `d (cc from B)`, each with its file |
| D7 | removes d | removes d | A25; P13 | one trash entry |
| D8 | adds d/new, d/sub, d/sub/new | removes d | A27 | d in the trash; `d (cc from B)` holds new, sub, sub/new |
| D9 | adds d/x | renames d→e | A33 | e/x |
| K1 | creates file x | creates folder x, x/in | A20 | A's folder x, B's file at `x (cc from B)` |
| K1′ | creates folder x, x/in | creates file x | A6; P10 at the aside name | A's file x, B's folder `x (cc from B)` with its file |
| K2 | file x (published) | folder x (published) | at B: A19; at A: A7 | folder x; file at `x (cc from B)` |

In D6 and K1′ B also publishes a rename entry for the aside after its mkdir was claimed at the aside
name; peers skip it as *already applied*.

### 5.5 Safety invariants

- S1. No folder id is live at two local paths: `make-folder` is skipped when `held`,
  `retire-stale-source` forgets the copy's id, and on the store the anchor decides.
- S2. A marker is never overwritten with another id: claims are conditional creates, and
  `move-marker`/`retire-to-trash` delete an old marker only if it still names this id.
- S3. Arrival never discards an unpublished item of this client (§5.1).
- S4. An entry is noted handled only after all its ops are enacted and durable.
- S5. No store request is made while holding the metadata lock.

### 5.6 Liveness

- Each arrival decision is a finite list of actions.
- `again` recurses at most `MAX_CLAIM_ROUNDS` times; each round claims a fresh name, so exhausting
  the bound means the store refuses every name (EXISTS, parked and reported).
- An entry whose later op needs a store answer created by an earlier op of the same entry fails the
  pass as TRANSIENT/local; each pass re-surveys the state the previous one left, so an entry of `k`
  ops needs at most `k` passes, re-applying its earlier ops idempotently.
- A publish that meets `source_still_there` fails with the move's own kind and is retried or parked
  by the ordered queue.

---

## 6. Crash and resume

| Interruption point | State left | On resume |
|---|---|---|
| During the arrival read-ahead | nothing changed locally except adopted ancestor ids, which are correct facts | the entry is read again next pass |
| Between two actions or two ops of one entry | a partial local change; entry not noted | the whole entry is re-applied; facts are re-gathered (§5.2 point 5) |
| Inside an aside or rescue that records owed work | the record is durable before the local move | recovery redoes the move from the record ([wal-and-journal.md](wal-and-journal.md) §4.7) and publishes it |
| Inside `retarget-our-rename` | the record says INTENT with the new destination and the file's recorded location | recovery moves the file from the recorded location to the new destination if it is absent there, then PREPARED |
| Inside `file-aside`, `ours-aside-file` (move, then post the upload) | a staged edit with no upload record | adopted by recovery with a fresh put record |
| Inside `retire-stale-source` | one of the three ordered steps done | re-application finds `folder(same)` or `already_there` and finishes the remaining steps |
| Publish: between a store attempt and the ending | the store changed; the record still owed | the facts are re-gathered: `landed`, `filed_here_already`, `already_trashed`, `store_gone` cover "the attempt already happened" |
| Publish `superseded`: the new record written, the old not completed | two records | the old one re-gathers to a publish of a redundant op or to `nothing_owed`; peers skip the redundant op as *already applied* |

Idempotence comes from re-gathering, never from logging which action of an entry ran.

---

## 7. Parameters

| Parameter | Recommended | Constraint / effect |
|---|---|---|
| Conflict-name template | `{base} (conflicted copy[ {n}] from {client}){ext}` | stable across versions; only the loser computes it |
| Client display name | configured per client | two clients with one name produce copies a person cannot tell apart |
| `MAX_CLAIM_ROUNDS` | 16 | bound on P11 rounds before EXISTS |
| Owed-rename chain bound | the number of unpublished file renames | prevents cycles in owed-rename translation |
| Versioning | per domain, optional | the only home of rung-4 file losers; off means those are lost |
| Trash and version retention | [gc.md](gc.md) | how long rung-4 losers remain recoverable |

---

## 8. Conformance

An implementation MUST keep these invariants over every two-client scenario, interleaving, role
swap and fault that [09](../09-tests.md) §8 generates, checked after quiescence (both clients
drained, both applied everything, one more pass each):

- **INV-converge.** Both mirrors and the store's tree, listed through anchors, are equal in names,
  kinds and **contents**.
- **INV-no-loss.** Every content written is in the live tree, or in the trash or version history
  only in the rung-4 situations of §5.3 (version history asserted only with versioning on).
- **INV-one-loser.** Conflicted copies bear only the name of the client that made them: the client
  whose op was unpublished relative to the other's, the file's owner for a published kind clash, and
  the author of the overwritten version for concurrent published edits (A2a; a client does not know
  a peer's display name). No conflicted copy
  appears when the two ops touch disjoint names.
- **INV-ids.** No folder id is live at two paths in any mirror; no live marker disagrees with its
  anchor after repair.
- **INV-quiet.** No owed records, no parked records and no unapplied entries remain.
- **INV-idempotent.** Re-applying any entry after quiescence, or applying the entries in another
  order within the horizon, changes nothing.
- **INV-local-first.** No local operation made a store round trip.
- **INV-swap.** The role-swapped run ends with the same tree up to the client name in conflicted
  copies.
- **INV-table.** For each fact set the decision equals §4.3/§4.5; `decide` is total; every row is
  reached at least once, and unreached rows are reported.
- **INV-rows.** Every row of §5.4 ends with the stated tree on both clients and on the store, with
  file contents compared. In particular: an edit beats a delete (F1, F12); edits and additions follow
  renames (F4, F10, D3, D9); both sides of an edit/edit, create/rename-onto, mkdir/mkdir and
  file/folder clash are kept, the copy numbered `n ≥ 2` when the name is taken; rename vs rename of
  one file keeps both names (F6); a folder renamed onto another folder's name is the copy, named
  after the renamer (D5); additions inside a removed folder are kept in its conflicted copy with
  their structure (D1, D8).

---

## 9. Rationale

- **Deferring a peer's entry until the clash resolves itself.** A stuck deferral cannot be told from
  a wedged client, and it trades convergence for waiting. Rung 1 forbids it.
- **Stress testing as the source of confidence.** Specific cases, overfitting fixes. The tables are
  the theory; a new clash is a new row and a two-client scenario.
- **Each side moves its own item aside.** The two sides swap and stay divergent (§5.2).
- **Ops as hints, the store as truth.** An entry tells a reader *which* names changed; what the
  reader installs is the store's current state. This makes application order-insensitive and
  idempotent, so late-visible and re-applied entries cannot undo later writes. A delete that
  re-read nothing removed a file a later write had restored.
- **Folders win over files when both are published.** The only store arbitration is on folder
  names, and a file and a folder can both be on the store under one name. A rule fixed by kind
  gives the same answer on every client whatever it learned first; "whoever learns second yields"
  does not, because both learn second.
- **Rescue with structure.** Flattening rescued files beside the removed folder lost the tree's
  shape and produced numbered collisions. A conflicted copy of the folder keeps both.
- **Rescue their additions on the removing side.** Letting an unpublished rmdir retire a peer's
  fresh addition put it in the trash, which to the user is loss.
- **Rename vs rename keeps both names.** Each side named the file; two copies is rung 3 without
  inventing a conflicted name nobody asked for.
- **Retarget before moving, in one durable step.** Moving first left, after a crash, a record whose
  destination a re-application then re-derived to a second aside name for a file that was no
  longer there.
- **Expected prior records.** Without them a publish cannot tell "the record I meant to remove or
  replace" from "a record a peer wrote since", and removes or overwrites content it never saw.
- **Re-identifying a folder whose name is taken.** Rejected: ids are final, so references held by
  frontends stay valid; the loser takes a conflicted name.
- **Querying the store under the lock.** It freezes local operations on a slow link. Read-ahead
  with answers as data replaces it.
- **A base version in put entries.** It turns rung 4 edit/edit into rung 3. Only the author of the
  overwritten version acts on it (A2a), so exactly one client makes the copy; the field is optional
  and ignored by readers that predate it, so mixed fleets fall back to rung 4.
- **Plausible and not taken.** A compare-and-swap on file records would close the check-then-write
  window, but not every store offers it.
