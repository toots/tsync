# Conflict resolution between asynchronously publishing clients

This document owns what a client does when its pending changes meet the main's: the principle, how
tsync's items map onto the keys and values of the theory, how a merge is enacted on local state,
the conflicted-copy name, a local write against a stale base, and the outcome of every pair of
clashing operations.

The merge itself (the three-way table, the repair rules and their proofs) is owned by
[change-algebra.md](change-algebra.md) §7 and is not restated. How changes travel (before-values,
uploads, the log, fetch and push) is owned by [publication.md](publication.md). Related rules owned
elsewhere:

- the per-object tree on the main: [data-model/backend.md](../data-model/backend.md);
- local state (mirror, staged edits, folder-id index, before-values):
  [data-model/local-cache.md](../data-model/local-cache.md) and [04](../04-checkout-cache.md);
- failure kinds: [failure-model.md](failure-model.md);
- versions and their retention: [gc.md](gc.md).

---

## 1. Problem, principle, goals

One person uses several machines (clients) against one main. A client makes every change to its
local tree at once, with zero round trips, and publishes it later: seconds later on a good link,
days later offline. Two clients can therefore each hold changes the other has not seen. They meet
at one moment only: an **arrival**, when a client that holds pending changes merges entries its
peers committed ([publication.md](publication.md) §4.4). A push never meets a conflict: it is
refused whenever the head moved, and the client arrives first.

### 1.1 The principle

1. **The main wins.** A value an entry committed stays where it is, on every client.
2. **Nothing the client wrote is lost.** A file content that loses a clash is kept beside the
   winner under a conflicted-copy name (§5), and that copy is published like any other change.
3. **An edit outlives a delete, and a removal never destroys what it did not see.** A file the
   client edited survives a peer's delete of it; a folder that received a file survives its
   removal, from either side.
4. **No merge of contents, no guess at intent.** Two contents for one name are two files. Two
   folders created at one name are one folder: a folder has no content of its own.

Only the client that arrives second acts. The first to commit learns of the clash as ordinary
entries: the conflicted copy the other client published.

### 1.2 Goals

- G1. Local operations never wait on the network and never fail because of a peer.
- G2. No acknowledged byte is lost: every content written is in the live tree, at its name or at a
  conflicted-copy name in the same folder.
- G3. **Convergence.** Once every client has an empty pending set and has arrived at the head, all
  local trees equal the main's tree: the same names, kinds and contents (Theorem 10).
- G4. The merge is a **pure function** of three states, total over its inputs, so the policy can
  be enumerated on small trees and tested apart from I/O.

### 1.3 Non-goals

- Content merging, or preserving the intent of both sides beyond keeping their bytes.
- Following a file through a rename made on another client (§6).
- Version history as a home for a loser: no clash leaves a content only in history.

---

## 2. Keys and values

| Theory | tsync |
|---|---|
| folder identity | a folder id ([01](../01-core.md) §2.5), minted by the creating client, final for life; the root's id is fixed |
| name | a leaf name, compared bytewise |
| file key $(d, a)$ | (folder id, leaf name): a regular file or a symlink |
| folder key $i$ | a folder id other than the root's |
| a file's value | its manifest ([02](../02-remote-model.md) §2.6) |
| a folder's value | (parent folder id, leaf name) |
| ∅ | no file at that name; no folder with that id |
| fresh name | `aside(name)` in the same folder (§5) |
| temporary place | a temporary name of the local tree ([01](../01-core.md) §2.9); never published |

- **Equality of file values.** Two manifests are equal when their **content identity** is: the
  pair of whole-file digests `h1`, `h2` ([02](../02-remote-model.md) §2.1). Size is implied; the
  modification time is carried with the content and is not compared. Changing a file's time alone
  is not a change.
- A staged edit whose manifest is not built yet has no identity and differs from every value. Two
  clients writing the same bytes can therefore end with a conflicted copy holding those bytes,
  when the arrival comes before the upload. An implementation MAY compute the identity of a staged
  edit at the merge to avoid it.
- The identity is a function of the bytes and of the chunk size they are cut at. The clients of
  one main cut alike ([01](../01-core.md) §3.5), so equal bytes have equal identities.
- A file has no identity of its own in the theory. A file rename is a removal at one key and a
  creation at another; the local file id ([01](../01-core.md) §2.7) is a local convenience (§6).

---

## 3. Local state a merge reads

All owned by the domain owner ([04](../04-checkout-cache.md)):

- **$L$**: the mirror overlaid with the staged edits. A file key's local value is its staged edit
  when it has one, else its mirror entry.
- **Before-values**, from which $R$ is derived ([publication.md](publication.md) §3.2).
- **Folder-id index**: `id → local path`, so a key is found whatever the folder's current path.

**The facts rule.**

> Everything a merge reads from the main is read before the metadata lock is taken. Everything it
> reads from local state is read under the lock.

Entries carry every value the merge installs, so a merge makes no store request and a slow link
delays no local operation.

---

## 4. Enacting a merge

`MERGE(R, L, M)` gives $N$ ([change-algebra.md](change-algebra.md) Definition 7). The owner then
changes $L$ to $N$ under the metadata lock, with its result recorded first
([publication.md](publication.md) §4.4).

### 4.1 File keys

For each file key $k$ where $N(k) \neq L(k)$, and for each fresh key the merge made:

| Merge outcome at $k$ | Local action |
|---|---|
| the main's value, nothing local to keep (first row; fifth row with $L(k) = ∅$) | install the manifest as the mirror entry, or remove the mirror entry when the value is ∅ |
| the same change (third row) | install the main's manifest; a staged edit with that identity is released |
| the main's value, the local one kept aside (fifth row; R2 on a file) | move the local file to `aside(k)` as a local rename does (staged edit, base entry, file id and open handles follow it), then install the main's manifest at $k$ |
| the local value kept (second and fourth rows) | nothing changes locally |

- **Staged facts are re-checked under the key lock** ([04](../04-checkout-cache.md) §3.2). The
  owner takes the key lock of every file key the merge changes before it writes the arrival
  record. A write that staged an edit at $k$ after the merge read $L(k)$ makes the decision for
  $k$ stale: it is taken again for that key with the new local value. The arrival record holds
  the decisions as they stand once every such lock is held.
- A file moved aside keeps its staged bytes and its upload record under the new key. Its command is
  a creation at the fresh key, pushed like any other.
- A read handle open on a replaced or removed file keeps the content it had
  ([04](../04-checkout-cache.md) §3.3).
- **A move the main made.** When one arrival removes the file at one key and creates a file of the
  same content identity at another, and the local file at the first key has no staged edit, the
  owner MUST enact both as one local move: the file id and the cached bytes follow, and the feed
  reports a rename. $N$ is the same either way.
- **A name the local tree cannot hold.** When the main's value would land on an escape handle that
  another name of the same folder already uses ([01](../01-core.md) §2.8), the owner installs it at
  `aside(k)` instead, as a change of its own: $k$ is ∅ locally with the main's value as its
  before-value, and the fresh key holds the content. The next push publishes that rename.

### 4.2 Folder keys

For each folder key $i$ where $N(i) \neq L(i)$: create the folder, move it, or remove it. A folder
restored by R1 comes back with its id; a folder moved by R2 keeps its id and everything in it.

**A folder merged into another** ([change-algebra.md](change-algebra.md) Definition 8) stands where
the main's folder is, so it is not moved: the local folder takes the main's id where it is, and
what it holds stays in it, staged edits, file ids and open handles included; an upload queued
under the old id's keys is posted again under the new. The remaining changes
are taken from the local tree so re-identified: a file whose name the main's folder holds with
another content is moved aside within it, and the main's files are installed beside the local
ones. The local folder's view, if a lazy tree held one, is dropped: the main's folder is pulled
before it is pushed to ([publication.md](publication.md) §4.11). Hosts are told of the old id's
removal, of the new id's creation at the same path, and of every item beneath it, whose file ids
are unchanged.

### 4.3 Order

The changes are a difference of two trees and are applied to the local tree in an order Theorem 3
allows: a folder exists before anything is placed in it, a place is freed before it is occupied
again, a folder is empty before it is removed, and a cycle is broken through a temporary place.
Folders merged into another (§4.2) are re-identified first, outermost first. Files kept aside
(§4.1) are moved next: their fresh names are free in the tree as it stands. A
temporary place is never recorded as a before-value and never reported in the change feed; an
implementation SHOULD keep it out of listings.

### 4.4 After the merge

Before-values are set so that $R = M$: a key where $N$ and $M$ differ has the main's value as its
before-value; every other key has none. The new pending set follows from that and is pushed by the
next cycle.

A merge that changed anything beyond installing the main's values is **clashed**, and is logged
with the keys concerned and the three values of each.

### 4.5 Duties of the other actors

- **The local writer** (every frontend, through the owner) records the before-value of a clean key
  before changing it, and takes the metadata lock for every check-then-act on names, including a
  write that creates a name ([publication.md](publication.md) §4.1).
- **The uploader** never writes a manifest or a tree record ([publication.md](publication.md)
  §4.2).
- **A host with a lazy tree** merges a pulled folder with its pending commands on that folder; it
  never drops a local item whose creation is pending ([04](../04-checkout-cache.md) §3.5).

---

## 5. Conflicted-copy name

`aside(L)` is `conflict_name(L, n)` for the smallest `n ≥ 1` whose name is free in the folder,
in $N$ as computed so far and in $L$ (staged edits included), so that moving a file aside is
always possible as the first step of an enactment (§4.3). Once a folder is merged into another
(§4.2), $L$ is read as re-identified: what the folder held counts under the main's folder.

- File `name.ext` → `name (conflicted copy from C).ext`, where the extension starts at the **last**
  `.` of the leaf; a leaf with no `.`, or whose only `.` is its first character, has no extension.
- Folder: the whole leaf, never split: `v1.2 (conflicted copy from C)`.
- `n ≥ 2`: `(conflicted copy n from C)`.
- `C` is the configured display name of the client computing the merge. The copy stays in the same
  folder.

A folder that R1 restores when its former place is taken, and a key that R2 moves, take this name.
The name is computed only by the client that merges and is published as its change, so peers never
compute it; it MUST nevertheless stay stable across versions of the software, because it is visible
to the user.

---

## 6. File renames

A peer edits a file this client renamed, or the reverse. The theory keeps both: the old name holds
the edit, the new name holds the content as it was when renamed
([change-algebra.md](change-algebra.md) §9). Nothing is lost, and there are two files where one
was meant.

An implementation MAY refine the merge with its local file ids: when $M$ changes the content at a
key whose file this client moved to another key, and the moved file is unedited, it MAY install the
main's content at the file's new key and leave the old key removed. This is a choice of $N$ that
Theorem 8 permits. It MUST NOT be applied when the moved file has a staged edit, and it is not
required.

---

## 7. A local write against a stale base

A `write` from a frontend MAY carry `base`: the `contentId` of the version the edit was made
from, which is the digest `h1` of its content identity ([08](../08-frontends.md) §2.3). An empty
`base` is no `base`. If `base` differs from the key's current `content_id` here
([04](../04-checkout-cache.md) §3.4), the edit was made to a version this client no
longer holds. The write is staged at `aside(key)` as a new file of this client, and the key keeps
its current content. The reply names the key as it now resolves; the conflicted copy reaches
frontends through the change feed. A `write` without `base`, or with the current base, is an
ordinary edit.

This is a local decision: it happens before the write becomes part of $L$, and nothing of `base`
is published.

---

## 8. Properties

### 8.1 Where every byte ends up

The unit is content written by a user on some client. B is the client that arrives with the change
pending; A committed first.

| Situation | Afterwards, on every client |
|---|---|
| Both edit one file | A's at `f`, B's at `f (conflicted copy from B)` |
| B edits, A deletes | B's edit at `f` |
| B deletes, A edits | A's edit at `f` |
| Both create one name with different content | A's at the name, B's aside |
| B renames onto a name A wrote | A's at the name, B's aside |
| B creates a file, A a folder, one name (or the reverse) | A's at the name, B's aside with everything in it |
| Both create a folder with one name | one folder, A's, with both sides' content; a name both wrote with different contents holds A's, B's aside |
| B adds under a folder A removed | the folder is back, with B's addition |
| B removes a folder A added to | the folder stays, with A's addition; B's removals of what it saw are kept |
| Both rename one folder differently | A's name; one folder |
| B renames a folder, A adds to it or edits in it | the folder at B's name, with A's change |
| Each moves one folder into the other's | A's move; B's is dropped |
| Both make the same change | that change, once; no copy |
| A frontend's write against a stale base (§7) | the write at `f (conflicted copy from B)`, the current content at `f` |

**Argument.** Theorem 8, property 4: every file content the client wrote is in $N$, at its key or
at a fresh key in the same folder, and that folder is present. §4.1 moves the local file before it
installs the main's value, under the key lock, so no staged edit is discarded.

### 8.2 Convergence

Theorem 10. The client that merges publishes what the merge left pending; the other clients take
it as the main's value. No two clients compute the same merge, so nothing depends on two clients
choosing the same loser.

### 8.3 Coverage by operation pair

B's change is pending when A's entry arrives. Every row ends identical on both clients and on the
main. `cc` abbreviates "conflicted copy".

| Row | B | A | Final tree everywhere |
|---|---|---|---|
| N1 | deletes f, creates f | — | f with B's content; one write, no copy |
| N2 | renames f over g | — | g holds f's content |
| F1 | deletes f | edits f | f with A's edit |
| F2 | deletes f | renames f→h | h |
| F3 | deletes f | creates x, renames x→f | A's f |
| F4 | renames f→g | edits f | f with A's edit, g with the content B renamed (§6) |
| F5 | renames f→g | deletes f | g |
| F6 | renames f→g | renames f→h | h and g, same content |
| F7 | renames f→g | creates g | A's g, B's at `g (cc from B)` |
| F8 | renames f→g | creates g, renames g→h | h and g |
| F9 | edits f | edits f | A's f, B's at `f (cc from B)` |
| F10 | edits f | renames f→g | f with B's edit, g with the content A renamed (§6) |
| F11 | creates g | renames f→g | A's g, B's at `g (cc from B)` |
| F12 | edits f | deletes f | f with B's edit |
| F13 | renames x over f | deletes f | f with x's content |
| F14 | renames x→g | renames f→g | A's g, B's at `g (cc from B)` |
| F15 | edits f to c | edits f to c | f with c; no copy |
| D1 | removes d/a, then d | adds d/x | d with x; a removed |
| D2 | removes d | renames d→e | e |
| D3 | renames d→e | adds d/x | e/x |
| D4 | renames d→e | renames d→f | f |
| D5 | renames d→e, writes e/ours | creates e, writes e/theirs | A's e/theirs, `e (cc from B)/ours` |
| D6 | creates d, writes d/ours | creates d, writes d/theirs | A's d with ours and theirs |
| D7 | removes d | removes d | d removed |
| D8 | adds d/new, d/sub, d/sub/new | removes d | d with new, sub, sub/new |
| D9 | adds d/x | renames d→e | e/x |
| D10 | moves d into e | moves e into d | A's move; d holds e |
| D11 | swaps the names of d and e | — | swapped; no temporary name in the entry |
| D12 | creates d, writes d/f | creates d, writes d/f with other content | A's d with A's f, B's at `f (cc from B)` |
| D13 | creates d and d/sub, writes d/sub/ours | creates d and d/sub, writes d/sub/theirs | A's d and d/sub, with ours and theirs |
| D14 | creates d, moves e into it | creates d | A's d holding e |
| K1 | creates file x | creates folder x, x/in | A's folder x, B's file at `x (cc from B)` |
| K2 | creates folder x, x/in | creates file x | A's file x, B's folder `x (cc from B)` with its file |

### 8.4 Safety invariants

- S1. No folder id is at two local paths, and no place holds two items: $N$ is well-formed.
- S2. A merge never discards a staged edit (§4.1).
- S3. The local tree is changed by a merge only under the metadata lock, with its result recorded
  first.
- S4. No store request is made while holding the metadata lock.

---

## 9. Parameters

| Parameter | Recommended | Constraint / effect |
|---|---|---|
| Conflict-name template | `{base} (conflicted copy[ {n}] from {client}){ext}` | stable across versions; only the merging client computes it |
| Client display name | configured per client | two clients with one name produce copies a person cannot tell apart |
| File-rename refinement (§6) | off | optional |
| Versioning | per domain, optional | history only; no clash depends on it |

---

## 10. Conformance

An implementation MUST keep these invariants over every two-client scenario, interleaving, role
swap and fault that [09](../09-tests.md) §8 generates, checked after quiescence (both clients with
an empty pending set, both arrived at the head, one more cycle each):

- **INV-converge.** Both local trees and the main's tree, read by state, are equal in names, kinds
  and **contents**.
- **INV-no-loss.** Every content written is in the live tree.
- **INV-one-loser.** Conflicted copies bear only the name of the client that arrived second. No
  conflicted copy appears when the two sides change disjoint keys, nor when they make the same
  change.
- **INV-ids.** No folder id is at two paths in any local tree; every tree the log defines is
  well-formed.
- **INV-quiet.** No before-value, no in-flight record and no parked upload remains.
- **INV-local-first.** No local operation made a store round trip.
- **INV-swap.** The role-swapped run ends with the same tree up to the client name in conflicted
  copies and up to which side's value holds each clashing key.
- **INV-merge.** For every pair of small trees and every $R$, the implemented merge equals
  Definition 7 and satisfies the five properties of Theorem 8.
- **INV-rows.** Every row of §8.3 ends with the stated tree on both clients and on the main, with
  file contents compared.
- **INV-own.** A single client, with no peer, never produces a conflicted copy, whatever sequence
  of operations and crashes it goes through.

---

## 11. Rationale

- **The main wins, whatever the kinds.** A rule fixed by kind (a folder outlives a file) needs
  both sides to act; with one side arriving at a decided state, "what is committed stays" is the
  only rule every client can apply alone.
- **The second to arrive is the only one that acts.** If each side moved its own item aside on
  seeing the other's, the two would swap names and stay divergent.
- **Merge two creations of one folder.** Each side mints its own id, but both made the same
  change: a folder at that name. Keeping both would turn a race, or a lazy tree that had not yet
  read the folder, into a conflicted copy holding a part of the user's files. A folder that
  existed before is not merged: its id is known to every client, and a move that brought it there
  meant that folder.
- **Restore a folder under its own id.** Additions made under a removed folder stay keyed by it;
  one command brings the folder back and they are where they were. A copy of the folder under
  another name would need every addition moved.
- **A removal that saw nothing is undone, not trashed.** A committed removal means the folder was
  empty on the main; there is nothing to keep in a trash, and file history is version history.
- **Keep both sides of a file rename against an edit.** Following the file needs a shared file
  identity, which only some hosts have; two files lose nothing.
- **A base on local writes only.** A frontend that edits a snapshot (a File Provider upload) can
  say what it started from; the owner settles that before the write is part of the local tree.
  Published commands carry their guard already.
- **Querying the store under the lock.** It freezes local operations on a slow link. Entries that
  carry their values replace it.
