# Local names: filing exact names on a disk that conflates them

This document owns where a local tree files each exact name: the canonical form, how a
collision is detected, the local effect of each namespace operation, lookup, and recovery after
a crash. It applies to the two trees that file items by path, the mirror and the staged tree
([04](../04-checkout-cache.md) §2.1); the staged tree takes the trivial form of §3.2.

Related rules owned elsewhere, referenced and not restated:

- The leaf grammar, `storable` and the escape handle: [01](../01-core.md) §2.8.
- Entry and marker formats: [04](../04-checkout-cache.md) §2.3.
- The metadata lock, under which every change below runs, and lock-free reads:
  [04](../04-checkout-cache.md) §3.2.
- The applied log, appended only once a change is durable: [03](../03-journal-sync.md) §2.9.

---

## 1. The problem

Names in tsync are byte strings, compared byte for byte ([01](../01-core.md) §2.3). A local disk
may map several of them to one slot: ignoring case (APFS and NTFS by default, ext4 casefold per
folder), up to Unicode normalisation (APFS, HFS+, ZFS `normalization=`), or by rules nobody
listed. A tree that files each name at its own spelling then loses data: a writer on a
byte-exact disk puts `X Of Y.md5` and deletes `X of Y.md5`, two names; on the
conflating disk the delete removes the file just put.

The disk's lookup is a function from names to slots. "Reaches the same slot" is therefore an
equivalence, written `n ~ m`, whose classes are the kernel of that function. tsync never states
the relation: it asks the disk.

## 2. Requirements

- **R1. Detected, never prescribed.** No code encodes a relation such as case folding or NFD.
  Every collision is found by asking the disk, in the folder concerned, at the time it matters,
  since the relation may differ per folder (ext4 casefold).
- **R2. Convergence.** Every sequence of operations that reaches the same exact state S gives the
  same local tree. Two disks with the same relation give the same local tree for S.
- **R3. No loss.** No operation on one exact name changes or removes the entry of another.
- **R4. Exact namespace untouched.** Names stay byte-exact everywhere above the local tree: in
  the store, in the log, in the merge, in every reply. Nothing is normalised on store.

## 3. The canonical form

Within one folder of one tree, let P be the exact names present. A name n is **unstorable** if
`storable(n)` is false ([01](../01-core.md) §2.8), or if the disk refuses n as a name in that
folder (ENAMETOOLONG, EILSEQ, EINVAL: a 250-byte name whose decomposed form is too long, bytes
that are not UTF-8 on a disk that requires it). Each unstorable name is a class of its own.
The storable names of P are partitioned into classes by `~`. Then:

- the bytewise least member of each class, `min(C)`, is filed at its **plain** name, n itself;
- every other member n is filed at its **escaped** name `esc(n) = .tsync-esc-<hex16(XXH3(n, 0))>`;
- every unstorable name is filed at `esc(n)`.

The local tree L is a function of S and the disk's relation, which gives R2. Invariant **I**,
which every step below preserves: a class with at least one member has `min(C)` at the plain
slot.

Two names whose escaped names coincide (a 64-bit hash collision) cannot both be filed. A
placement whose own handle, or whose demotion's target handle, is held by another name is
refused locally as EXISTS before any step is taken, and the name goes aside
([conflict-resolution](conflict-resolution.md) §4.1). Which of the two is refused depends on
order; at 64 bits this is accepted as the one exception to R2.

### 3.1 Recorded names

The **recorded name** of an entry is the only truth about which exact name it files:

| entry | recorded name |
|---|---|
| file entry (mirror) or staged edit | the manifest's `name` field |
| mirror folder | the folder marker's `name` (`.tsync-dir`); else its name marker `.tsync-name` |
| staged directory | its name marker `.tsync-name` |

An entry with none of these (a folder whose markers are missing or invalid, a file entry that
does not decode) is taken to file the name the directory listing gives for it. A listing is
otherwise never a source of names: HFS+ rewrites a name to NFD when it stores it, so the listed
spelling is not the name that was written.

A directory's name marker MAY be present at a plain slot; when present it holds the directory's
exact name. It MUST be present in an escaped directory that has no valid folder marker.

### 3.2 The staged tree

The staged tree files every component, leaf and directory, at `esc(n)`, whatever its siblings,
and every staged directory carries a name marker: a directory is made at a temporary name,
given its marker, then renamed to its handle. Two distinct names never reach one slot there, since escape handles are lowercase
ASCII and differ unless their hashes collide, so no staged step ever moves a sibling: §4 and the
promote and demote rows of §5 do not apply to it, and a staged step needs no lock beyond the one
04 §3.2 already assigns. `find` (§6) is step 2 alone. The staged tree is internal and never
shown, so nothing is lost by its names being unreadable.

- A staged directory left without edits stays: at its handle it is in no other name's way, and
  removing it would race a writer that holds only its own key lock.
- **Migration.** A staged edit or directory found at a name that is not an escape handle was
  written before this rule. Owner start, before the domain serves, moves each such entry to its
  handle with one rename, writing a directory's name marker first; its recorded name is its
  manifest's name (files), or for a directory the recorded name of the mirror folder at the same
  local path, which the old layout shared, else the listed name; an old escaped directory that
  neither names stays where it is. A file whose handle is taken is set aside
  ([04](../04-checkout-cache.md) §2.1); a directory whose handle holds edits stops the start
  with an error, and one holding none is cleared first. A staged directory without edits that
  lies at a handle a write or a move needs is cleared the same way.

## 4. Detection

The identity of a slot is the pair (device, inode) of what a lookup reaches (on NTFS, the volume
serial and file index).

- **On placing n.** Look up n's plain name. If it reaches an entry whose recorded name m ≠ n,
  then n ~ m, and by I m is the class's minimum. If it reaches nothing, n's class has no
  member. If it reaches an empty regular file, a probe a crash left behind (below), a removal
  of the class's plain holder did not finish: the probe pass and its promotion run first, with
  that probe, and the placement then starts again.
- **When the plain holder n leaves.** The departing entry can no longer answer, so the slot is
  probed: create an empty regular file at n's plain name, exclusively; if one is already there
  (a probe a crash left behind), use it; if an entry is there, the class still has its plain
  holder and nothing is promoted. For each escaped sibling e whose recorded name m is storable,
  look up m's plain name; m is in n's class iff it reaches the probe. Remove the probe. An
  unstorable n has no plain slot and is never probed.
- **The demoted flag.** Only an entry demoted by a collision can be promoted, so a folder that
  holds none skips the probe and the listing. The flag `.tsync-demoted` in a mirror folder
  is written durably before any entry of that folder is demoted, and removed only by a probe
  pass that finds no storable escaped entry left. A removal in a folder without the flag costs
  one failed lookup. A crash can leave the flag present with nothing demoted, which costs one
  pass, never absent while a demoted entry exists. Unstorable names never set it. The flag
  only says when to ask the disk; the class is still found by the probe.

A probe is never an entry: no manifest, staged edit or marker is empty. A lookup that reaches an
empty regular file at a plain name answers absent, and a listing skips it.

Internal leaves (`.tsync-dir`, `.tsync-name`, `.tsync-demoted`, `.tsync-fid-…`, temporaries) are not members.
`storable` refuses every name that begins with `.tsync-` ignoring ASCII case, so no user name
reaches an internal leaf through case folding.

## 5. Local effect of each operation

The operations on exact names, and the convergence rules of the remote namespace, are unchanged
([change-algebra](change-algebra.md)). What changes is the local effect of an operation on key k
in a tree: instead of touching the slot of k's spelling, it re-normalises k's class in each
folder it affects, which can move a sibling.

| op on n in folder F | class before | local effect |
|---|---|---|
| place n (create, write) | empty | n is filed at its plain name |
| place n | holder m, n > m | n is filed at `esc(n)` |
| place n | holder m, n < m | write n's entry at a temporary name; **demote**: move m to `esc(m)`; move n's entry to its plain name |
| place n | holder is n | rewrite in place |
| remove n, n at the plain name | {n, m…} | remove n; if the folder is flagged (§4), probe; **promote**: move `esc(min rest)` to the plain name |
| remove n, n escaped | {m, n…} | remove `esc(n)` only |
| remove n, n absent | — | if the folder is flagged, probe and promote as if n had been the plain holder |

- **A move is one rename.** A demotion or a promotion moves one entry with one `rename`; a
  folder moves with its whole subtree. A directory that moves gets its name marker rewritten to
  its exact name before it moves, whenever it has one or the destination is escaped.
- **No failure leaves a class without its holder.** Every step that can fail for want of space
  or I/O (writing an entry, a marker, the flag) comes before the demotion, so what follows the
  demotion is renames. If one of them fails, the demotion is undone (`esc(m)` moved back to the
  plain name) before the error is returned; if the undo fails too, the error is the state's to
  repair at the next start, as for a crash (§7).
- **Sidecars stay.** Records filed by a hash of the exact leaf (the file-id marker
  `.tsync-fid-…`, the ownership marker) are keyed by the name, not the slot, and do not move
  when the entry does.
- **Rename** of k from n in F to n′ in F′ (F′ may be F) is a removal of n from F and a
  placement of n′ in F′ that move the entry instead of rewriting it, its recorded name
  rewritten. Before it moves, the entry is the probe of its own slot: when n holds a plain slot
  in a flagged folder, the escaped siblings of n's class are found by looking up their plain
  names against the entry itself. When n′ ~ n (a case-only or normalisation-only rename in one
  folder), the class after the rename is the rest R plus n′: if n′ < min(R), or R is empty, the
  entry stays at the plain slot and only its stored spelling and recorded name change;
  otherwise it moves to `esc(n′)` and `esc(min R)` is promoted. Otherwise the placement of n′ in
  F′ follows the table, the entry moves with one rename, and the removal of n from F promotes as
  the table says.
- **The staged tree** files every name at its handle (§3.2), so only the first and the
  escaped-removal rows apply to it, with the handle in place of the plain name. A change of the
  mirror never moves a staged entry.

## 6. Lookup

`find F n`, in one tree:

1. look up n's plain name in F; if it reaches an entry whose recorded name is exactly n, that
   is n;
2. otherwise look up `esc(n)`; if it reaches an entry whose recorded name is exactly n, that is
   n;
3. otherwise look at the plain name again, as in step 1: a promotion that landed between steps 1
   and 2 is found there;
4. otherwise n is absent.

A path is found component by component. `find` never needs the relation. Reads take no lock
([04](../04-checkout-cache.md) §3.2), so a reader confirms the recorded name of what it opened;
a miss at a path `find` returned, or a recorded name other than n, repeats `find`. A demotion or
promotion is one rename, so n is always at one of its two names, and the repeat finds it unless
another namespace change landed meanwhile.

## 7. Crashes

An applied-log line is appended only after its change is durable ([03](../03-journal-sync.md)
§2.9), so an interrupted arrival is replayed. Every step works from what the disk holds and is
idempotent:

- a placement looks up the plain holder afresh, so a replay after a demotion finds the class as
  the demotion left it and completes the placement;
- a removal of a name already gone still probes and promotes in a flagged folder (§5 last
  row), and the flag outlives the demotion it covers, so a crash between the removal and the
  promotion is repaired by the replay;
- a probe a crash left behind is reused by the next probe of that slot and ignored by lookups
  meanwhile.

A local operation (not an arrival) follows the same steps under its local intent
([04](../04-checkout-cache.md) §2.8), which recovery replays the same way.

## 8. Ruled out

- **Insensitive names anywhere in the exact namespace.** R4.
- **Normalising names on store.** Stored names stay byte-exact.
- **Once escaped, never moved back.** `put a; put A; delete a` would leave A escaped, while
  `put A` alone files it plain: two histories, one S, two trees, against R2.
- **A probe per root.** The relation can differ per folder (ext4 casefold), and a probe at one
  folder says nothing of another.

## 9. Worked example

The arrival that motivated this, in one folder, with `Of` < `of` (0x4F < 0x6F):

1. `X of Y.md5` holds the plain name.
2. `put X Of Y.md5`: its plain name reaches the holder, recorded `… of …` ≠ `… Of …`, and
   `Of` is less: `… of …` moves to `esc(… of …)`, then `… Of …` takes the plain name.
3. `delete X of Y.md5`: it is escaped; `esc(… of …)` is removed.

The result is `X Of Y.md5` at its plain name, as `delete` then `put` gives.

## 10. Out of scope

- Which member a frontend shows when it can show only one per class.
- Resolving a user-typed path whose spelling differs from the stored name (NFC typed, NFD
  stored).
- Moving the cache to a disk with other rules, which needs a rebuild.
