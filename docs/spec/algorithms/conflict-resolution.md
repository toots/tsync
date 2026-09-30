# Conflict resolution between asynchronously publishing clients

This document specifies, independently of any implementation, how clients that share one
tree through a dumb object store settle concurrent changes. Each client writes locally
first and publishes later. How changes travel is covered in
[wal-and-journal.md](wal-and-journal.md): the write-ahead record, the published journal,
the cursor, and the applied log. This document owns everything that happens when two
clients' changes meet. Concrete names appear only in §11.

---

## 1. Problem, goals, non-goals

One person uses several machines (clients) against one shared store. A client makes every
change to its local tree at once, with zero round trips, and publishes it later: seconds
later on a good link, days later offline. Two clients can therefore each hold changes the
other has not seen. Two moments expose this:

- **Arrival.** A peer's published operation reaches a client that still holds unpublished
  work touching the same names.
- **Publish.** A client publishes its own operation to a store that changed after the
  operation was recorded.

The algorithm decides, at each moment, what happens to both sides' work.

### 1.1 The principle ("best-effort conflicts")

Clashes are settled by the first rung of this ladder that applies:

1. **Immediately.** A clash is resolved the moment the peer's operation arrives, or the
   moment a publish finds the store changed. Nothing is deferred, and the client never
   waits for more information. A peer entry is never held back to see what comes next.
2. **Soundly on both sides.** No data is lost, and every client ends with the same tree.
   Operations that do not clash converge through the simplest implementation, which is
   to apply them as they are.
3. **When in doubt, two conflicted copies.** Whatever of this client's is in the way, and
   is still unpublished, is renamed to `X (conflicted copy from <this client>)`, and that
   rename or upload is published. There is no merge and no guessing at intent.
4. **Last resort: the winner takes all.** This applies to two writes to one file that
   both sides had *already published*. The later write wins everywhere, and the loser
   survives only in version history.

Rung 3 has one structural rule that makes it converge without coordination:
**the loser is the side that still holds its op unpublished when the other's becomes
known, and the loser renames itself**. The winner does nothing special. Every client
computes the same winner because only one side can be in the "still unpublished" state
with respect to the other's published op. §5.2 gives the argument.

### 1.2 Goals

- G1. Local operations never wait on the network and never fail because of a peer.
- G2. No acknowledged byte is lost, where "lost" means absent from the tree, the trash,
  and version history alike. §5.1 lists where every byte goes, and §8 lists the
  exceptions.
- G3. **Convergence.** Once all clients have published everything and applied every
  entry, all mirrors equal the store's tree: the same names, kinds and contents.
- G4. Every decision is a **pure function** of gathered facts, so the policy can be read,
  printed exhaustively and tested apart from I/O.
- G5. A failing entry does not block progress beyond itself, except when the link is at
  fault.

### 1.3 Non-goals

- General concurrent correctness, serializability, or causal consistency across clients.
  The user mostly avoids concurrency, so best effort is the accepted bar.
- Content merging (three-way merge, operational transforms), or any attempt to preserve
  the *intent* of both sides beyond keeping their bytes.
- Detecting that two already-published writes to one file were concurrent rather than
  sequential. The published entry does not carry the information needed.
- Preserving tree *shape* for rescued data. Files rescued from a removed folder are
  flattened (§8).
- Multi-user semantics, permissions, and locking.
- Stress testing as a source of confidence. The tables are the theory, and a new clash
  becomes a new table arm plus a two-client scenario.

---

## 2. System model and assumptions

A1. **Store.** A key-value object store with `get`, `put`, `delete`, `head`, sorted
    `list`, and a server-side `copy`. It offers **conditional create**
    (`put-if-absent`) on at least the folder-marker keys. That primitive is the only
    arbitration point for names. A store that cannot arbitrate falls back to a plain
    `put`, so the last writer wins and the claim race described in §2 of the store model
    returns. The store has no transactions and no multi-object atomicity. Single-object
    read-after-write consistency is assumed. Listings may show entries out of order.

A2. **No peer-to-peer channel.** Clients learn of each other only through published
    journal entries on the store (see [wal-and-journal.md](wal-and-journal.md)).

A3. **Entry order.** Each unit of work carries an **entry key**: the wall-clock
    millisecond at which it started, plus the client id. The order of keys is total.
    It carries no causality: two clients' keys in the same millisecond have no true
    order, and an entry can become visible after entries with larger keys. Peers apply
    entries in key order, each exactly once per client (dedupe by key).

A4. **Clocks** are only assumed not to be wildly skewed. Resolution never compares
    timestamps across clients, except through entry-key order.

A5. **Failures** are crash-stop with a durable local disk. The write-ahead record of an
    op is durable before its local half runs, and restart runs recovery (see the
    replication document). Links fail transiently and for long periods.

A6. **One applier per tree.** The model assumes a single actor applies peer entries and
    mutates a client's tree under one lock. The current implementation violates this
    with several processes per machine (F7, §8).

A7. **Mostly sequential use.** A person rarely edits one item on two machines inside
    one publish window. The design optimises for the case without a clash and accepts
    graceful degradation in rare cases.

---

## 3. State

### 3.1 Items and identity

| Item | Identity | Located by |
|---|---|---|
| **File** (regular file or symlink) | its **path** alone; no stable id | on the store, `(parent folder id, leaf name)`; in ops, the domain-relative path |
| **Folder** | a **folder id** minted locally by the creating client, unique (client prefix + leased counter), **final for life** | on the store, a *marker* object at `(parent id, leaf)` naming the id, plus an *anchor* (`id → parent, name`) that is authoritative. A marker the anchor disagrees with is stale and ignored. |
| **Root** | fixed id | — |

Consequences:

- A folder rename or move never changes the folder's id, and its contents' store keys
  hang off the id, so a folder moves in O(1).
- A file rename moves an object on the store (copy + delete) and is arbitrated by
  whether the source still exists.
- A name is **claimed** by conditionally creating the marker. A taken name is never
  resolved by re-identifying a folder. The loser takes a conflicted name instead.

### 3.2 Operations (the vocabulary exchanged between clients)

```
put(path, size)                      create or overwrite a file (a symlink is a put)
delete(path)
mkdir(path, folder id?)
rmdir(path, folder id?)              folder removal = retirement to the trash
rename(src, dst, is_dir, size?, folder id?)
```

Directory ops carry the folder id, because applying a removal destroys the local
evidence the id could otherwise be read from. `id?` is absent only in legacy entries.
An entry holds one or more ops (usually one; imports batch).

### 3.3 Local state that resolution reads

Durable, per client:

- **Mirror.** For each file its current record (manifest), and for each folder its
  id. These are the published view as this client knows it, plus this client's own
  local changes.
- **Staged content.** Bytes written here and not yet uploaded, per file path. A file is
  *staged* iff it has such bytes. A folder is staged iff some file below it is staged,
  at any depth; an empty leftover directory does not count (§9.4).
- **Owed metadata.** The ordered list of this client's recorded-but-unpublished
  metadata ops (delete, mkdir, rmdir, rename), from the write-ahead log.
- **Owed uploads.** Staged files queued for upload, each under a record.
- **Folder-id index.** `id → local path`, and `path → whereabouts`, which is one of
  `Live(id)`, `Moved(id, now_at)`, `Removed(id)` or `Unknown`. The index is durable
  because the process that applies an entry is not the one that later describes it.
  An in-memory table fails (§9.5).

Volatile, per entry being applied:

- **Store answers.** The marker id at a folder key, and the current manifest of a file
  the peer names, fetched before the lock is taken (§4.1).

"Published" vs "unpublished" is *derived*: an op is unpublished while its record is owed.
A file is unpublished-content while it is staged.

### 3.4 The facts rule

> Facts that come from the store are read **before** the local lock is taken, and never
> while holding it. Facts that come from local state are read **under** the lock.

A slow link therefore delays only the entry that needs the answer, and never a local
operation (G1). If, under the lock, a decision turns out to need a store answer that
was not read ahead, local state changed in between. The entry then fails as a
*transient* error and is read again on the next pass, so the store is never queried with
the lock held.

On the publish side, facts are gathered outside the lock. Some are **answers to
attempts**: the claim of a name, or the move of a file object. The store is the arbiter
of those, so the attempt comes first and the decision is about what it met. Any local
change such a decision makes takes the lock itself and re-checks its precondition.

---

## 4. The algorithm

### 4.1 Arrival: applying a peer's entry

```
apply_peer_entry(ops):
  owed := owed_metadata()                         # snapshot, no lock
  for op in ops: adopt_missing_ancestor_ids(op)   # store reads; adopt only, never mint
  answers := {}
  repeat:                                         # read-ahead, no lock
    try  for op in ops: decide(gather(op, owed, answers))  # speculative
         break
    on Unread(q): answers[q] := read_store(q)     # marker id at a folder key, or
                                                  # current manifest of a named file
  for op in ops whose speculative decision writes theirs:
    prefetch its manifest into answers
  with metadata lock:
    owed := owed_metadata()                       # re-read under the lock
    for op in ops, in order:
      facts, place := gather(op, owed, answers)   # Unread here -> transient failure
      decision := ARRIVAL(facts)                  # pure, §4.3
      if clashed(decision): log(op, facts, decision)
      enact each action of decision, in order     # §4.5
  # the caller notes the entry as applied only after this returns
```

**Ancestor adoption.** A put implicitly creates parent directories that have no id, and
without an id nothing under them can be named. The client therefore reads the store's
marker for each id-less ancestor, top-down, and adopts that id. It never adopts an id
for a folder this client moved or removed with that same id (whereabouts
`Moved(id,…)`/`Removed(id)` while nothing is at the path). It never mints an id here,
because minting would fork a namespace the other clients already agree on.

**Path translation.** A peer names items by *its* paths, while this client may have
moved things since.

- **Folders.** The client walks the op's parent path upward. If this client moved a
  folder on the path (`Moved(id, at)`) *and the store still files `id` under the peer's
  name*, the local folder is `at`. Otherwise it is `parent + leaf`, resolved
  recursively. The store check distinguishes "the same folder that I moved" from "a new
  folder the peer made under the old name".
- **Files, for `put` only.** The path is also followed through this client's owed file
  renames (`src → dst` chains, bounded by the number of owed renames). A peer's edit
  therefore lands on the file it was made to (F4).

  `delete` and the source of a `rename` are **not** followed through owed renames.
  Because of that, a peer's delete of `f` misses a file this client renamed away from
  `f`, and the rename outlives the delete (F5).

### 4.2 Arrival facts

`place` covers where the op lands here (`at`, and for moves `from`), plus the id of any
folder of ours in the way. It is carried to enactment but never read by the decision.

| Op | Facts (booleans or enums) | How determined |
|---|---|---|
| `put(p)` | `renamed_onto`: an owed file rename of ours has `dst = p`, and none has `src = p`. `folder ∈ {absent, holds_id, holds_no_id}`: a local folder sits at the landing name. `staged`: staged bytes at the landing name. | landing name = the translated path of `p`, after following owed renames |
| `delete(p)` | `staged` at the translated path | |
| `mkdir(p, id)` | `lives_elsewhere`: `id` is already held at another local path. `staged_file`: a staged file at the name. `another_folder`: a folder holding a *different* id at the name. | |
| `rmdir(p, id)` | `target ∈ {by_id, at_path, held_by_another}`: `by_id` if `id` is found anywhere locally; else `at_path` unless the path holds another id, in which case `held_by_another` | |
| `rename dir(s→d, id)` | `ours_owed`: an owed mkdir/rmdir/dir-rename of ours carries `id`. `source ∈ {at_path, by_id, gone}`: `at_path` if `s` is a local folder not holding another id; else `by_id` if `id` is found; else `gone`. `destination ∈ {free, same_folder, another_folder}`: from the id held at translated `d`, where "no id to compare" counts as `free`. `already_there`: source location = destination. | path checked before id, because a copy under the new name may already hold the id |
| `rename file(s→d)` | `source_here`: a record exists at translated `s`. `staged_destination`: staged bytes at translated `d`. | |

### 4.3 The Arrival table (complete)

`decision = skip(reason) | apply([action…])`. Actions are enacted in list order: what is
in the way steps aside before the op itself applies. Rule precedence is top-down within
an op. The product of all facts is 65 situations, all listed in §4.3.1.

| # | Their op | Situation | Outcome | Rationale | Rows |
|---|---|---|---|---|---|
| A1 | put | none of the following | `write-theirs` | a plain edit | — |
| A2 | put | `renamed_onto` | `retarget-our-rename`, then the `folder` aside of A3/A4 if any, then `write-theirs` | our renamed file carries its own staged bytes, so it is not set aside twice | F7, F8 |
| A3 | put | `folder = holds_id` | `folder-aside(published)`, then `file-aside` if `staged ∧ ¬renamed_onto`, then `write-theirs` | kind clash: our unpublished folder yields the name | K1′ |
| A4 | put | `folder = holds_no_id` | `folder-aside(local only)`, then as A3 | an id-less folder cannot be named on the store | — |
| A5 | put | `staged ∧ ¬renamed_onto` | `file-aside`, then `write-theirs` | edit/edit with ours unpublished | F9 |
| A6 | delete | `staged` | `skip(ours publishes later)` | an edit outlives a removal; our upload republishes the file | F12 |
| A7 | delete | `¬staged` | `remove-file` | | — |
| A8 | mkdir | `lives_elsewhere` | `skip(already applied)` | a rename moved it here earlier; making it again would put one id at two paths | — |
| A9 | mkdir | otherwise | `file-aside` if `staged_file`; `folder-aside(published)` if `another_folder`; then `make-folder(id)` | kind clash, or two folders created under one name | K1, D5, D6 |
| A10 | rmdir | `held_by_another` | `skip(held by another)` | the name belongs to a folder the op is not about | — |
| A11 | rmdir | `by_id` or `at_path` | `rescue-staged-under`, then `remove-folder` | unpublished adds survive beside the folder; the folder goes | D7, D8 |
| A12 | rename dir | `ours_owed` (precedence 1) | `skip(ours publishes later)` | our own op on this folder follows on the store, and the one that lands last is what everyone ends with | D2, D4 |
| A13 | rename dir | `source = gone` (precedence 2) | `skip(nothing to move)` | | — |
| A14 | rename dir | `already_there` (precedence 3) | `skip(already applied)` | | — |
| A15 | rename dir | `destination = same_folder` | `retire-stale-source` | the destination already holds this folder, so the source is a copy that came back | — |
| A16 | rename dir | `destination = another_folder` | `folder-aside(published)`, then `move-folder` | our folder at the destination yields | D5 mirrored |
| A17 | rename dir | `destination = free` | `move-folder` (staged files move with it) | | D3 mirrored, D9 |
| A18 | rename file | — | `file-aside` if `staged_destination`, then `move-file` if `source_here`, else `adopt-theirs-at-destination` | our staged bytes follow their file (F10); our new file at the destination yields (F11) | F2, F6, F10, F11 |

`clashed` (worth a log line) is true for `skip(ours publishes later | held by another)`
and for any decision containing `retarget-our-rename`, `folder-aside`, `file-aside` or
`retire-stale-source`.

#### 4.3.1 Every situation (the printed product)

```
put        renamed_onto × folder{absent,holds_id,holds_no_id} × staged   12 situations
           (renamed_onto ⇒ never file-aside; folder ≠ absent ⇒ folder-aside first
            after any retarget)
delete     staged                                                         2
mkdir      lives_elsewhere × staged_file × another_folder                 8
           (lives_elsewhere dominates: 4 situations skip)
rmdir      target                                                         3
rename dir ours_owed × source{3} × destination{3} × already_there        36
           (ours_owed: 18 skip; else source=gone: 6 skip; else already_there:
            6 skip; else 6 decided by destination)
rename file source_here × staged_destination                              4
                                                                   total 65
```

Some fact combinations cannot occur in a consistent local state. A staged file and a
folder cannot both hold one name in a healthy mirror, and `already_there` implies
`source ≠ gone`. The table still decides them, so `decide` is total.

### 4.4 Publish: our own op meets a store that moved on

The ordered metadata publisher runs this for each op of an owed record, outside the
lock. File content (put) is published by the upload path and always ends in `publish`.

```
publish_op(op):
  facts, place := gather_publish(op)              # may attempt a claim or a move
  d := PUBLISH(facts)                             # pure
  enact d.actions
  case d.ending:
    publish      -> emit op AS IT IS HERE NOW     # a folder is published at its
                                                  # current local place, found by id
    nothing_owed -> emit nothing
    superseded   -> finish this record; the work continues under a record of its own
    again        -> publish_op(op)                # something moved out of the way
    retry        -> raise the attempt's failure   # the queue classifies it (§6)
publish_record(r) := concat(publish_op(op) for op in r.ops)
                     # an empty result completes the record without an entry
```

**Publish facts.**

| Op | How gathered | Fact |
|---|---|---|
| put | — | `put` |
| delete(p) | the local kind at `p` | `a_file_here_again` if a file is at `p` now, else `gone_here` |
| mkdir(p, none) | — | `no_id` |
| mkdir(p, id) | local place of `id`, else `p` if it holds `id` | none: `gone_here`. The store's anchor puts `id` elsewhere: `filed_elsewhere`. Otherwise **attempt the claim** of the name for `id`: `claimed` or `name_taken`. |
| rmdir(p, none) | — | `no_id` (logged) |
| rmdir(p, id) | the store anchor of `id` and the marker at the old key; the op fails if the old key cannot be named | anchor in trash: `already_trashed`. Else if an anchor exists anywhere or the old marker names `id`: `published`. Else `never_published`. |
| rename dir(s→d, id) | local place of `id` | gone here: `gone_here`. The store anchors it where it is here: `filed_here_already`. Never on the store: `never_published`. Another id holds the destination's marker: `name_taken`. Else `free`. |
| rename file(s→d) | **attempt**: save a version of `s`, copy `s→d` on the store, rewrite the recorded leaf | success: `moved`. On failure: `s` still on the store gives `source_still_there`; else `d` present gives `landed`; else `source_gone(x)`, where `x` is what we hold at `d`: `staged`, `published` or `absent`. |

### 4.5 The Publish table (complete, 23 situations)

| # | Our op | Fact | Actions | Ending | Rationale | Rows |
|---|---|---|---|---|---|---|
| P1 | put | — | — | publish | the upload carries its own arbitration: last manifest written wins | — |
| P2 | delete | `a_file_here_again` | — | nothing_owed | a peer's file outlived our removal, or we recreated it and its upload publishes it | F1, F3 |
| P3 | delete | `gone_here` | `remove-from-store` (version saved first) | publish | | F2 |
| P4 | mkdir | `no_id` | `put-marker` | publish | legacy | — |
| P5 | mkdir | `gone_here` / `filed_elsewhere` | — | nothing_owed | it was removed here, or a later op of ours already placed it | D8 (`d/sub`) |
| P6 | mkdir | `claimed` | — | publish | | — |
| P7 | mkdir | `name_taken` | `ours-aside` (local move to a conflict name, only if still holding `id`) | **again** | the same id gets a name of its own, claimed on the next pass | D6, K1′ |
| P8 | rmdir | `no_id` | — | publish | legacy | — |
| P9 | rmdir | `already_trashed` / `never_published` | — | nothing_owed | | D7 |
| P10 | rmdir | `published` | `retire-to-trash` | publish | | D1, D2 |
| P11 | rename dir | `gone_here` / `never_published` | — | nothing_owed | | — |
| P12 | rename dir | `filed_here_already` | — | publish | | D5, D6, K1′ |
| P13 | rename dir | `name_taken` | `ours-aside-as-rename` (a new owed rename to a conflict name) | superseded | never write our marker over another folder's | — |
| P14 | rename dir | `free` | `move-marker` | publish | | D4 |
| P15 | rename file | `moved` | — | publish | | N1, F4, F7 |
| P16 | rename file | `landed` | — | publish | the move happened; what failed came after it | — |
| P17 | rename file | `source_still_there` | — | retry | | — |
| P18 | rename file | `source_gone(absent)` | — | nothing_owed | nothing to move and nothing to publish in its place; retrying would hold the queue forever | — |
| P19 | rename file | `source_gone(staged)` | `queue-upload` of `d` | superseded | ours clashes with nothing under its new name | — |
| P20 | rename file | `source_gone(published)` | `republish-here` (put our record at `d`, with its own entry) | superseded | | F5, F6 |

P3, P5, P9 and P11 each cover two facts, so the fact count is 23. `clashed` is true for
every `nothing_owed`, `superseded` and `again` ending.

**Disagreement between the prose spec and the code.** The code's comment and
§4.5 of `03-journal-sync.md` cite F5/F6 against P19 (`source_gone(staged)`). In the
pinned scenarios, F5 and F6 both reach **P20**: B's renamed file had been published
before the rename, so what B holds at `d` is published, not staged. P19 is reached only
when a file renamed while still staged loses its source. That wording is loose, but no
behaviour differs.

### 4.6 Actions and their enactment

"Aside" means: pick the smallest `n ≥ 1` such that `conflict_name(item, n)` is free both
in the mirror **and** among staged files (the mirror does not show staged files, and a
second conflict must not land on the first one's copy). Then move the item there
locally. A local move of a staged file or subtree cancels the owed uploads under the old
path and queues them again under the new one, **after** any rename record the move is
part of. That way peers replay the move before the puts.

| Action | Local effect | How peers learn of it |
|---|---|---|
| `retarget-our-rename` | move our file at the name aside; rewrite every owed file-rename record whose `dst` is the name to target the aside name (the record keeps its key) | the retargeted rename |
| `folder-aside(published)` | record a new owed folder rename `current local path → aside name` carrying our id, then move locally (intent recorded before the move). The publisher later resolves the source by id (P12/P14). | that rename; the folder's own owed mkdir, if any, is published later at its current place (P6/P12) |
| `folder-aside(local only)` | move the id-less folder aside locally | not published |
| `file-aside` | move our staged file aside and queue its upload under the aside name | the upload |
| `rescue-staged-under(F)` | for each staged file under `F` at any depth, in path order: move it to `aside(parent(F)/leaf)` | the uploads |
| `write-theirs` | cancel our upload at the name; install the **store's current** record for the name, as read ahead. If the store has none, do nothing. | — |
| `adopt-theirs-at-destination` | as `write-theirs`, for the rename's destination | — |
| `remove-file` | cancel the upload; drop cached bytes, staged bytes and the record | — |
| `make-folder(id)` | create the folder and record the op's id (final since the peer's mkdir) | — |
| `remove-folder` | remove the local folder recursively | — |
| `move-folder` / `move-file` | local move `from → at` (staged content moves with it) | — |
| `retire-stale-source` | move the source aside, make it **forget** the shared id, and point the id back at the destination | not published: the store already files the folder at the destination |
| `remove-from-store` | save a version, delete the file record on the store | the op's entry |
| `put-marker` | anchor, then marker | the op's entry |
| `retire-to-trash` | trash marker (name, id, path), then anchor → trash, then delete the live marker only if it still names this id | the op's entry |
| `move-marker` | new anchor + marker **first**, then delete the old marker only if it still names this id | the op's entry |
| `ours-aside` | under the lock, if our folder still holds the id, move it aside locally | the claim on the next pass publishes the mkdir at the aside name |
| `ours-aside-as-rename` | as `folder-aside(published)` | that rename |
| `queue-upload` | queue our staged file at `d` for upload | the upload |
| `republish-here` | put our record at `d`, publish a put entry, bump the cursor | that entry |

**Conflict name (parameter).** File `name.ext` becomes
`name (conflicted copy from C).ext`, where the extension starts at the *last* `.` of
the leaf. A folder keeps its whole leaf (`v1.2 (conflicted copy from C)`), because
splitting would file a subtree under a mangled name. For `n ≥ 2` the name is
`(conflicted copy n from C)`. `C` is the name of the client doing the moving aside,
which is the loser. The aside item stays in the same parent.

### 4.7 Duties of the other actors

- **The local writer** (the frontends) records every metadata op durably before its
  local half, and keeps owed ops in their recorded order. File content becomes an owed
  upload on close. The writer must share the metadata lock with the applier. File
  writes currently do not take that lock (F7, §8).
- **The metadata publisher** publishes owed ops in recorded order, one at a time. It
  re-reads a record just before publishing it, because an Arrival
  `retarget-our-rename` may have rewritten it. A link failure keeps the op at the head
  of the queue. Any other failure parks it and lets later ops pass. The published entry
  carries the **rewritten** ops (a folder is published where it is now), under the
  original key.
- **The uploader** publishes staged content. Its publish saves a version of the
  manifest it replaces, which is where a winner-takes-all loser survives.
- **The poller** applies peer entries in key order and marks each as applied only after
  all its ops are enacted. A non-link failure *steps the entry aside*: it stays
  unapplied, later entries proceed, it is retried on every pass, and status reports it.
- **Browsing clients** that list folders from the store (lazy checkout) must not prune
  local items that are owed. What a client made and has not published is, by
  definition, missing from the store.
- **Peers never cooperate directly.** Every rule above is local. The only shared state
  is the store, with its conditional create on markers.

---

## 5. Properties and why they hold

### 5.1 No data loss: where every byte ends up

The unit is *content written by a user on some client*. The table below is exhaustive
over the arms of both tables.

| Situation | Where the loser's content lives afterwards |
|---|---|
| Our staged edit vs their put (A5, F9) | ours at `f (conflicted copy from us)` everywhere, and theirs at `f` |
| Our staged edit vs their delete (A6, F12) | ours at `f` everywhere, because our upload republishes it |
| Our staged edit vs their file rename (A18, F10) | at the new name, with our edit |
| Our staged new file vs their rename onto it (A18, F11) | ours aside, theirs at the name |
| Our file renamed onto a name vs their put there (A2, F7/F8) | ours aside via the retargeted rename |
| Our folder vs their file or folder at the name (A3, A9, A16, K1/K1′/D5/D6) | our folder aside with everything in it, published as a rename or upload |
| Our staged adds under a folder they removed (A11, D8) | beside the folder, **flattened**, as conflicted copies, at the parent of the removed folder. Unpublished empty subfolders vanish (P5). |
| Their adds under a folder we removed (D1) | **only inside the trashed folder** (P10 retires the whole subtree, including their add); gone from the live tree on both sides until someone restores it or it expires |
| Their or our rename vs the other's rmdir (D2 and its mirror) | the folder with its contents in the trash |
| Our delete vs their edit (F1) | their edit at `f` (P2) |
| Our rename vs their delete (F5) | ours at the new name (P20) |
| Rename vs rename of one file (F6) | **both** names hold the content (P20 republishes ours) |
| Folder rename vs folder rename (D4) | the rename published last wins; the other survives as a stale, disowned marker only |
| Edit vs edit with **both already published** | the last upload wins everywhere. The earlier content survives only as a version the later upload saved, if versioning is enabled and the best-effort save succeeded. |
| Our delete of a file whose edit was published concurrently | `remove-from-store` saves a version first; same caveat |
| A file rename that overwrites a destination on the store | only the *source* is versioned before the move; the destination's prior content is versioned only if some earlier publish saved it |

**Argument.** The Arrival table never destroys staged bytes. Every action that
overwrites or removes a name (`write-theirs`, `adopt-theirs…`, `remove-file`,
`remove-folder`, `move-*`) is preceded, in the same decision, by an aside of whatever
staged content sits at that name or under it. `remove-file` runs only when nothing is
staged there. Published content is on the store, where removal saves a version and
folder removal is a trash retirement, so it is recoverable until expiry. The exceptions
are the rows in bold. The last three rows depend on optional versioning.

### 5.2 Convergence

**Claim.** Suppose the clashes are limited to the rows of §7.1 of `03-journal-sync.md`
(reproduced in §5.4). Then once every client has drained its owed work and applied every
entry, all mirrors equal the store's tree.

**Sketch.**

1. **File contents converge on the store.** `write-theirs` installs the store's
   *current* record, never the one the entry was written with. Any client that applies
   the last entry touching a name therefore holds the store's current record for it,
   whatever order it saw the entries in.
2. **Names are arbitrated by the store.** Folders are claimed by conditional create,
   and a loser takes a conflicted name and publishes that as its own op. Files are
   arbitrated by the last manifest write, or by source existence for a move.
3. **The winner is computed identically everywhere.** Take an A-op and a B-op that
   clash, with A's published first. B learns of A's op either on arrival, while B's op
   is still owed (Arrival), or on publish (the claim or move meets A's result). Either
   way it is B that moves its item aside, and it publishes the aside as an ordinary op.
   A applies that op like any other. A never renames itself for this clash, because
   when A published, B's op did not exist on the store yet. Only one side can hold an
   op unpublished with respect to the other's published op, so there is exactly one
   loser.
4. **Idempotence by facts.** Re-applying an entry (after a crash, or a lost dedupe
   record) re-gathers facts, and most arms become skips or no-ops: `already applied`,
   `nothing to move`, `write-theirs` of the current record, a move whose source is
   absent. This is why "at-least-once" application is safe in the common case. §8
   gives the exceptions.
5. **An aside is a new op with a later key.** It enters the same machinery, so the
   argument applies inductively. It terminates because the conflict name is fresh.

**Why "move the loser aside on each side" is wrong.** In a kind clash (file vs folder),
if *each* side moved *its own* item aside on seeing the other's, the two sides would
swap names and stay divergent. Only the side that is still unpublished may move.

### 5.3 Convergence holds only while one side is unpublished

1. **Both published, same file.** This is winner-takes-all (rung 4). It converges on
   the last upload. The loser is not kept as a conflicted copy, because a received put
   carries no base version. The receiver cannot tell "edited concurrently with mine" from
   "edited after seeing mine".
2. **Both published, kind clash (file vs folder at one name).** **Undecided.** The store
   can hold both, because a file record and a folder marker live under different keys,
   but a mirror cannot. No table arm covers this, and the clients can disagree
   permanently about what the name is. Every later op on that path then means something
   different per client. A fix needs a winner that both compute, such as the later
   entry key, plus a published aside of the loser by the side that loses.
3. **Writes into a folder being moved aside** can land at its old path.

### 5.4 Coverage by op pair

Rows are named after the two-client scenarios. B's op is unpublished when A's arrives,
and B publishes afterwards. Every listed row ends identical on both clients, and the
file *contents* were verified against the golden output.

| Row | B (unpublished) | A (arrives) | Arms | Final tree everywhere |
|---|---|---|---|---|
| N1 | renames f over g | — | P15 | g holds f's content |
| F1 | deletes f | edits f | A1; P2 | f with A's edit |
| F2 | deletes f | renames f→h | A18 (adopt); P3 | h |
| F3 | deletes f | creates x, renames x→f | A18 (move); P2 | A's f |
| F4 | renames f→g | edits f | A1 (translated to g); P15 | g with A's edit |
| F5 | renames f→g | deletes f | A7 (misses g); P20 | g |
| F6 | renames f→g | renames f→h | A18 (adopt h); P20 | h **and** g, same content |
| F7 | renames f→g | creates g | A2; P15 to the aside name | A's g, B's at `g (cc from B)` |
| F8 | renames f→g | creates g, renames it g→h | A2, then A18; P15 | h and `g (cc from B)` |
| F9 | edits f | edits f | A5 | A's f, B's at `f (cc from B)` |
| F10 | edits f | renames f→g | A18 (move) | g with B's edit |
| F11 | creates g | renames f→g | A18 (aside + move) | A's g, B's as a conflicted copy |
| F12 | edits f | deletes f | A6 | f with B's edit |
| D1 | removes d/a and d | adds d/x | A1 writes nothing (d has no id here); P10 | d **in the trash** with x inside |
| D2 | removes d | renames d→e | A12; P10 | folder in the trash (stale marker at e, disowned) |
| D3 | renames d→e | adds d/x | A1 (translated to e/x); P14 | e/x |
| D4 | renames d→e | renames d→f | A12; P14; A applies B's: A17 | e (the last published) |
| D5 | renames d→e, writes e/ours | creates e, writes e/theirs | A9 (folder aside); P14 publishes d→`e (cc)`, then P12 | A's e/theirs, `e (cc from B)/ours` |
| D6 | creates d, writes d/ours | creates d, writes d/theirs | A9; P6 at the aside name, P12 | A's d, `d (cc from B)`, each with its file |
| D7 | removes d | removes d | A11 (no-op); P9 | one trash entry |
| D8 | adds d/new, d/sub, d/sub/new | removes d | A11; P5 for d/sub | d in trash; `new (cc from B)` and `new (cc 2 from B)` at the root |
| D9 | adds d/x | renames d→e | A17 | e/x |
| K1 | creates file x | creates folder x, x/in | A9 (file aside) | A's folder x, B's file at `x (cc from B)` |
| K1′ | creates folder x, x/in | creates file x | A3; P6 at the aside name, P12 | A's file x, B's folder `x (cc from B)` with its file |

In D6 and K1′, B publishes a redundant rename entry (`x → x (cc)`) after its mkdir was
already published at the aside name (P12). Peers skip it as `already applied`.

**Publish-side races** (B publishes after A, before B applies A):

- Rename vs delete: P20, and both converge.
- Rename vs rename: P20, leaving both names.
- Create vs create of one file: P1, and the last upload wins.
- Rename onto another folder's name: P13, and the renamer's copy takes the conflicted name.
- Mkdir vs mkdir: P7, giving one folder and one conflicted copy.
- Mkdir then rmdir vs a peer's mkdir: P7, then P10; `retire-to-trash` leaves the other
  folder's marker alone.
- An offline mkdir later renamed onto a taken name: P7, then P11; no third folder.

**Cells without a pinned row.** These are derived from the tables. "Reasoned" means the
outcome follows from the arms and converges. "Suspected" means reading the code
suggests a divergence that no test covers. A rewrite should add scenarios for all of
them.

| B (unpublished) | A (arrives) | Arms | Status |
|---|---|---|---|
| deletes f | deletes f | A7 (no-op); P3 publishes a second delete | reasoned: converges |
| deletes g | renames f over g | A18 (move); P2 | reasoned: g = f's content |
| renames d→e | removes d | A11 by id at e; P11 | reasoned: folder in trash. **While one side is unpublished, rmdir beats rename from either side.** With both published in the order rmdir then rename, P14 re-anchors the folder out of the trash, and the rename wins (untested). |
| creates folder e | renames d→e | A16; P6 at the aside name | reasoned (mirror of D5) |
| removes old d, creates new d | removes old d (by id) | A10 | reasoned |
| **renames x over existing f (x published)** | deletes f | A7 removes our renamed file locally, because `delete` does not consult owed renames; our rename publishes via P15 | **suspected divergence**: the store and A hold f = x's content, while B's mirror has no f until a full resync. Fix: give `delete` a `renamed_onto` fact that skips it, as `put` has. |
| **renames x→g (x published)** | renames f→g | A18 moves theirs over our renamed file locally (no `renamed_onto` for rename destinations); P15 then moves x over g on the store | **suspected divergence**: B has g = f's content, while the store and A have g = x's content. f's content survives only as a version saved by A's move. Fix: the F7 treatment, `retarget-our-rename`, for rename destinations too. |
| file vs folder at one name, **both published** | — | none | undecided (§5.3) |
| a folder at `d`, their file rename or delete targeting `d` | — | none (kind clash through rename or delete) | undecided; the enactment probably fails and the entry steps aside forever |

### 5.5 Safety invariants

- S1. No folder id is live at two paths in any mirror. `make-folder` is skipped when
  `lives_elsewhere`, `retire-stale-source` makes the copy forget the id, and on the
  store the anchor decides.
- S2. A marker is never overwritten with another id. The claim is a conditional create,
  and `move-marker`/`retire-to-trash` delete an old marker only if it still names this
  id.
- S3. Staged bytes are never discarded by Arrival (§5.1). The one exception is the
  cross-process race of F7.
- S4. An entry is marked applied only after all its ops are enacted.
- S5. No store request is made while holding the metadata lock.

### 5.6 Liveness

- Each Arrival decision is a finite list of actions. `again` in Publish recurses at most
  once per aside, since the aside name is fresh by construction.
- An entry that fails on this client's own account steps aside and does not block later
  entries. A link failure blocks the pass on purpose, to preserve order.
- An entry whose later op needs a store answer created only by an earlier op of the same
  entry fails the pass as `Unread`. The read-ahead surveyed pre-entry state. The next
  pass surveys post-op state, so an entry of `k` ops needs at most `k` passes, each
  after the poller's retry floor. The earlier ops are re-applied idempotently.
- A publish that meets `source_still_there` retries at the head of the queue. If the
  failure is on this client's account, the op parks.

---

## 6. Failure, crash and resume

| Interruption point | State left | On resume |
|---|---|---|
| During the Arrival read-ahead | nothing changed locally, except adopted ancestor ids, which are correct facts | entry re-read next pass |
| Between two actions of one decision, or two ops of one entry | partial local change; entry not marked applied | the whole entry is re-applied; facts re-gathered (§5.2 point 4) |
| Inside `folder-aside(published)` | intent recorded **before** the local move | recovery redoes the move (idempotent: only if the source is present and the destination absent) and publishes the rename |
| Inside `file-aside` / `rescue` (move, then queue the upload) | a staged file at the aside name with no upload record | recovery adopts every staged file that no record names and queues it |
| Inside `retarget-our-rename` (move, then rewrite the records) | **Suspected gap.** The file is at `aside(n)` while the owed rename still targets the original name. | Re-application re-derives `renamed_onto` from the unrewritten record, finds `aside(1)` taken, and picks `aside(2)` for a move of an absent source (a no-op). The record then targets a name the file is not at. Not tested. A crash-safe version records the retarget first (rewrite the record, then move), or makes the pair one durable step. |
| Inside `retire-stale-source` (move aside, forget the id, re-point the id) | the id can point at the aside copy | re-application finds the source by id at the copy, still `same_folder`, and retires it again as `aside(2)`: churn, no loss. Not tested. |
| Publish: between the store attempt and the ending | store changed, record still owed | re-gathered on restart. `landed` covers "moved, but the rest failed"; `filed_here_already` covers "marker moved". |
| Publish `superseded`: the new record written, the old one not yet finished | two records | the old one re-gathers to P14/P12/P16 or P2 and publishes a harmless redundant op |
| Store orderings | — | anchor before marker; new marker before old-marker delete; trash marker before anchor before live-marker delete; version saved before a file move or delete. A crash leaves at worst a *stale* marker, which readers skip via the anchor, and never an unlisted folder. |

Idempotence is by re-gathering, not by logging each action. The design never records
"action k of entry E done".

---

## 7. Parameters

| Parameter | Current value | Effect and trade-off |
|---|---|---|
| Conflict-name template | `{base} (conflicted copy[ {n}] from {client}){ext}`; the extension starts at the last `.`; folders are not split | human-readable and deterministic. Must stay stable, because both sides must produce the *same* string: only the loser names it, and publishes the name. |
| Client display name | configured per client | appears in names. Two clients with the same name make copies indistinguishable to a person (but not to the algorithm). |
| `n` selection | smallest `n ≥ 1` free in the mirror and among staged files | local-only freedom check. A peer's unseen item at that name is caught later by the same tables. |
| Rescue destination | the removed folder's *parent*, leaf only (flattened) | simple, and keeps the files visible. It loses the subfolder structure and produces numbered collisions. |
| Owed-rename chain bound | the number of owed renames | prevents cycles when following `src→dst` |
| Versioning | per domain, optional; the save is best effort with a ~10 s deadline | the only home of rung-4 losers. Off means those are lost. |
| Trash / version expiry | retention cutoff | how long D1-style survivors and version-history losers remain recoverable |
| Retry floor after a failed pass | 2 s | the latency of `Unread` re-reads and transient failures |
| Step-aside classification | a link failure blocks; everything else steps aside or parks | order preservation vs a single bad entry wedging a client (one ENOTEMPTY rename once blocked a client for 8+ hours) |

---

## 8. Known gaps

| Gap | Source | Effect | A correct version needs |
|---|---|---|---|
| Several processes mutate one tree, each with its own lock; file writes do not take the metadata lock even within one process | findings F7 | a peer delete that gathered "not staged" can then discard bytes a concurrent write staged, which is **data loss** and contradicts A6 | one arbiter per tree: a cross-process lock around apply that writes also take, or a single mutating process |
| Re-application is not idempotent for `delete` or `rename` | findings F4 (the applied-log byte prune can forget handled keys inside the dedupe window) | an old delete re-applied after a later put removes the file locally, and nothing brings it back | never forget a key inside the window. Or make `delete`/`rename` facts consult the store, for example applying a delete only if the store no longer holds the name. |
| An unreadable journal entry reads as "gone" | findings F6 | a transient read failure hides a peer's newer entry during crash recovery's "overridden since" filter, so a stale unpublished op of ours is published over the peer's change. Recoverable only from versions. | distinguish "absent" from "failed" and abort the pass on failure |
| Rmdir vs add: the add survives only in the trash (D1) | tests A6 | loss from the user's point of view, which contradicts rung 2 | at publish time, the rmdir side (the unpublished side) can list the store's folder and rescue unseen children beside it before retiring, as A11 does for its own staged adds |
| Rescued files are flattened to the parent (D8) | tests A6 | the structure is lost; numbered copies | rescue the subtree as `d (conflicted copy from C)/…` |
| Rename vs rename of one file keeps both names (F6); stale comments promise a conflicted copy | tests A6 | duplication, which is not loss, but it is not what the principle says | decide: either keep both (and document it), or have the loser (P20) publish at `dst (conflicted copy)` and delete nothing |
| Revert installs an old version without versioning the replaced content | tests A6 | the replaced content can be lost | save a version before a revert |
| Published losers are silent (§5.3.1) | conflict-gaps | a winner-takes-all overwrite is invisible | carry the base version in each put entry. A receiver whose published version is neither the base nor theirs has seen a concurrent edit, and makes a conflicted copy of its own version. |
| Kind clash with both sides published (§5.3.2) | conflict-gaps | permanent divergence | a deterministic winner by entry-key order, with the loser published aside by whichever side detects the clash with the later key |
| Two suspected divergences (§5.4 "cells without a pinned row") | this analysis | as described there | a `renamed_onto` check on `delete` and on rename destinations |
| Crash between the move and the record rewrite in `retarget-our-rename` (§6) | this analysis | the record can target an aside name the file is not at | rewrite the record before moving |
| Silent guards | memory: foreign-dir-rename-staged-guard | an op "applied" with no effect and no error | log every skip whose reason is not `already applied` or `nothing to move` (this is what `clashed` does), and define "staged" for a folder as "a staged file below it" |

---

## 9. Alternatives and design history

9.1 **Defer peer entries until the clash resolves itself.** The user rejected this:
"never defer the poller". Deferral trades convergence for waiting, and a stuck
deferral is indistinguishable from a wedged client.

9.2 **Stress testing as the source of confidence.** Rejected as "a band-aid: specific
cases, overfitting fixes". The tables came first. Reading the printed product against
the ladder found four wrong rows (F10, F11, F12, D9) and a rename that wedged the queue.

9.3 **Each side moves its own item aside.** Rejected, because the two sides swap and
stay divergent (§5.2). The unpublished side yields, and publishes the yield.

9.4 **Staged folder = its directory exists in the staged tree.** Replaced by "a staged
file lies below it". An empty leftover directory silently skipped a peer's folder
rename on any folder this client had ever written into (commit `7059de7a`).

9.5 **Name folders by path in ops.** Replaced by carrying the folder id. A recursive
delete removed the local marker the id was read from, the child ops became unnameable,
and they were silently dropped. The fix also persisted a by-path id entry on disk,
because the applying process is not the describing one (commit `cac8f7ea`).

9.6 **Re-id a folder whose name is taken.** Rejected. Ids are final, so frontend
references stay valid, and a taken name becomes a conflicted name
(commits `6b3f96c5`, `addadddc`).

9.7 **Retry a failing entry at the head forever.** Replaced by step-aside for failures
on the client's own account, after an ENOTEMPTY folder rename (two local folders
holding one id) blocked a client for eight hours. Directory conflicts are now all
settled as a local name change (commits `9b73f41c`, `fa549e93`).

9.8 **Query the store under the lock.** Replaced by read-ahead + `Unread` → transient
retry (commits `e8fe2452`, `ab3811bd`), so a slow link never holds up local operations.

9.9 **Plausible and not taken.**
- A three-way content merge. It contradicts rung 3.
- Vector clocks or version vectors per file. These would solve §5.3.1, but every entry
  would have to carry and maintain them.
- A server-side compare-and-swap on manifests (If-Match). This would turn rung 4 into
  rung 3 for published edits, but not every store offers it.

---

## 10. Property-based test plan

The goal is to check the tables against the principle, not only against each other.

### 10.1 Model

- A small abstract tree: at most 3 names at the root and 1 folder level, and 2–3
  distinct contents. Contents are tokens, so byte accounting is exact.
- Two clients, A and B, plus a store model. The store has conditional create on
  markers, anchors, versioning on or off, and a trash.
- The real system under test is driven through its operation and apply interfaces. Link
  and pause controls give the interleavings.

### 10.2 Generators

1. **Base tree.** A random tree, published and applied by both clients.
2. **Op for each side.** An op from `{put, delete, mkdir, rmdir, rename file, rename dir,
   symlink, write inside folder}`. Arguments are biased towards **colliding** names: the
   same name, a rename destination equal to the other side's name or source, a parent
   of the other side's name, and the same leaf with a different kind. Optionally, short
   chains of 2–3 ops per side.
3. **Interleaving class.**
   - I1: B's op unpublished when A's arrives (Arrival).
   - I2: B publishes after A published, before applying A's entry (Publish).
   - I3: both published before either applies (the §5.3 cases).
   - I4: I1 with B's content staged vs already uploaded.
4. **Faults.**
   - A crash before or after each enactment action, and between the publish attempt and
     the ending, followed by recovery.
   - A duplicated delivery of one entry (re-apply).
   - An entry that becomes visible late (out of key order).
   - A transient store failure during the read-ahead.
5. **Role swap.** Every generated case is also run with A and B exchanged.

### 10.3 Invariants to assert after quiescence

Quiescence means: both drained, both applied everything, then one more pass each.

- **INV-converge.** A's tree, B's tree, and the store's tree as listed through anchors
  are equal in names, kinds and **contents**. Contents must be compared, because a split
  brain can pass a names-only check.
- **INV-no-loss.** Every content token written by either side is in the live tree,
  **or** the case's oracle class allows it in the trash (only D1-like shapes), **or**
  in version history (only I3 edit/edit, delete vs published edit, and rename over a
  destination; asserted only when versioning is on). Any other location, or none, is a
  failure.
- **INV-one-loser.** Conflicted copies bear only the name of the client whose op was
  unpublished relative to the other's. No conflicted copy appears when the two ops
  touch disjoint names.
- **INV-ids.** No folder id is live at two paths in any mirror, and no live marker
  disagrees with its anchor after repair.
- **INV-quiet.** No owed records, no parked ops, and no stepped-aside entries, except
  for cases the oracle classes as undecided (§5.3.2), which must be reported rather
  than silently passed.
- **INV-idempotent.** Re-applying any entry after quiescence changes nothing. F4
  predicts that this fails for delete; keep it as an expected failure until fixed.
- **INV-local-first.** No local op in the run made a store round trip.
- **INV-swap.** The role-swapped run ends with the same tree, up to the client name in
  conflicted copies.
- **INV-table.** For each gathered fact set, the decision equals the documented table.
  `decide` is total over the fact product.

### 10.4 Coverage assertions (the run must prove it tested something)

- Count every Arrival situation (65) and every Publish situation (23) reached by an
  actual run. Fail unless each consistent situation was reached at least once, and list
  the unreached ones. The inconsistent combinations of §4.3.1 are listed explicitly as
  excluded.
- Count the cases per interleaving class and per fault point. A zero anywhere fails the
  suite.
- Shrink failures to a minimal op pair and a minimal base tree, and emit them as a new
  two-client scenario row.

---

## 11. Mapping to the current implementation

This is the only section with concrete names. Section references point into the
`docs/spec` files.

| Abstract | Concrete | Spec |
|---|---|---|
| Arrival table, Publish table, `clashed` | `Resolve.Arrival.decide`, `Resolve.Publish.decide`, `clashed` in `lib/domain/checkout/file/resolve.ml`; printed by `tests/unit/resolve` | 03 §3.7, §4.4, §4.5 |
| Arrival fact gathering, path translation, enactment | `Local.Peer_entry.gather`, `local_folder`, `renamed_since`, `renamed_onto`, `enact`, `apply_one`, `apply` in `lib/domain/checkout/file/file.ml` | 03 §4.4; 04 §4.8 |
| Read-ahead, ancestor adoption, `Unread` | `Foreign.read_ahead`, `adopt_ancestor_ids`, `adopt_folder_id`, `fill`, exception `Unread` → `Retry.Transient` | 03 §4.4; 04 §4.8 |
| Publish fact gathering and enactment, "as it is here now" | `Backend_half.gather_*`, `enact`, `as_published`, `backend_op`/`backend_ops` in `file.ml` | 03 §4.5; 04 §4.9 |
| Conflict name, aside, folder aside published | `conflict_key`, `aside_name`, `move_aside`, `publish_aside` in `file.ml` | 03 §2.9 |
| Rescue | `Peer_entry.rescue_staged` | 04 §4.8 |
| Retire stale source | `Peer_entry.retire_stale_copy` (`Folders.forget`, `Folders.reparent`) | 03 §4.4 |
| Retarget our rename | `Peer_entry.retarget_our_rename` + `W.update_ops` | 03 §4.4 |
| Owed metadata, owed uploads, intent → prepared | `W.owed_metadata`, `owing`, `hand_over`, `queue_put`, `rename_local` | 03 §4.1; 04 §4.6 |
| Folder-id index, whereabouts | `Folders.lookup_id`, `key_of_id`, `whereabouts` (`Live`/`Moved`/`Removed`/`Unknown`) | 04 §4.13 |
| Claim, anchor, marker, trash | `St.claim_folder`, `placed`, `get_anchor`, `put_folder_marker`, `retire_to_trash`, `remove_old_marker` | 02 §2.8, §4.3, §4.4 |
| Metadata publisher, park, step aside | `Meta_queue`, `Retry.classify_in_order`, `Replay.apply_foreign` `stepping_aside` | 03 §4.1, §4.3, §7.7 |
| Crash recovery (redo, adopt unrecorded) | `redo_local`, `Replay.reconcile`, `adopt_unrecorded` | 03 §4.6 |
| Versions | `save_version` (only when `Conf.versioning`) | 02 §2.11 |
| Two-client rows N1…K1′ | `tests/scenario/conflicts/conflicts.ml` (+ `.expected`) | 03 §7.1, §8 |
| Publish-side races | `tests/scenario/sync`: `delete_rename_race`, `rename_rename_race`, `concurrent_create`, `dir_rename_onto_foreign_dir`, `concurrent_mkdir_then_write`, `concurrent_mkdir_then_rmdir`, `offline_mkdir_renamed_onto_a_taken_name`, `foreign_dir_rename_of_own_folder` | 03 §8 |
| Local-first and step-aside behaviour | `tests/scenario/meta_offline`; lazy listing keeps owed items: `tests/scenario/lazy_owed` | 03 §8 |
| Blind spots | `docs/spec/09-tests.md` §A6; findings F4, F6, F7 in `docs/spec/findings.md` | — |
