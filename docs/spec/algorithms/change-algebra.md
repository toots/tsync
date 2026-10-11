# A change algebra for asynchronous file synchronisation

This document is the theory behind publication and conflict handling. It
defines the objects, states every claim the design relies on, and sketches a
proof of each.

The vocabulary and the shape of the theory come from the algebraic theory of
filesystems of E. P. Csirmaz and L. Csirmaz, and the tree of identified
folders from Kleppmann et al. The state used here is keyed by folder
identity, which neither source does in this form, so the proofs are given
here and are not inherited. Section 11 relates each result to its source.

The proofs are sketches. They show why a claim holds and what it depends on,
so that an implementation can be checked against them. Theorem 3 and the five
properties of Theorem 8 have also been checked on every pair and every triple
of small trees (section 12, case 22), with no counter-example.

This document owns the model: keys, values, commands, batches, the merge and
the properties claimed of them. How tsync realises it is owned elsewhere: the
protocol by [publication.md](publication.md), the enactment of a merge and the
names it gives by [conflict-resolution.md](conflict-resolution.md), the formats
by [03](../03-journal-sync.md).

## 1. Setting

A **client** has a local tree $L$ that applications use directly. Local
operations are immediate and never wait for the network.

A **main** is the one store that holds the shared tree. Every change by every
client is published to it.

**Replicas** are other stores filled from the main, one way. Nothing but that
replication writes to them.

Assumptions:

- **A1. One main.** Each shared tree has exactly one main.
- **A2. Atomic append.** The main is a numbered log, and offers one atomic
  step: create entry $n+1$ if it does not exist. It checks nothing else.
- **A3. Replicas follow.** A replica is written only by replication from the
  main.
- **A4. Content is immutable.** File content is stored in objects named by a
  hash of their bytes.
- **A5. Folders have identities.** A folder is created with an identity that
  is unique across all clients and never changes. Renaming or moving a folder
  keeps its identity.
- **A6. Clients follow the rules.** Every client is well-intended: it creates
  an entry only as section 6 allows.

A2 is provided by a store that can create an object only if it is absent,
directly or through a proxy in front of it. Where neither exists, the
deployment must have a single writer. tsync requires the conditional create of
every store it pushes to ([publication.md](publication.md) §2), so the last
case does not arise there.

Two deployments are covered.

- **Shared.** Several clients publish to one main through A2. This is the
  general case and uses the whole theory.
- **Single writer.** One client writes the main and no other does. The
  concurrent case of section 7 never arises.

A client may also read from a replica when the main is unreachable. Section
9 shows this is safe.

The goal:

> When every client has published all its changes and observed all of the
> main's, every local tree equals the main's tree, and every replica
> converges to it.

## 2. The incident that motivated this

An application saved a file by deleting it and creating it again:

```python
if os.path.exists(path):
    os.remove(path)
with open(path, 'wb') as f:
    f.write(content)
```

This happened on a single-writer deployment. No other client was involved.

1. The local delete erased the client's record of what the main held at that
   name.
2. The create was recorded as "new file, nothing expected at this name".
3. The delete was processed, saw a file at the name again, and yielded to it.
   Nothing was sent.
4. The upload found a file on the main where it expected none, concluded that
   another client had written it, and published the content under a
   "conflicted copy" name.

The client took its own earlier version for a peer's. The error is in the
algebra of one client's own operations: the delete and the create were
treated as two independent changes, each with its own expectation, where
they are one change whose expectation is that of the delete. Proposition 2
states this precisely.

## 3. Model

**Definition 1 (keys).** There are folder identities, one of which is the
root, and names. A *place* is a pair (folder identity, name). There are two
kinds of key:

- a **folder key** is a folder identity $i$ other than the root;
- a **file key** is a place $(d, a)$.

**Definition 2 (state).** A state $\Phi$ gives a value to every key, with
finitely many non-empty:

- for a folder key $i$: the place $(p, a)$ where the folder is, or
  $\varnothing$ if it does not exist;
- for a file key $(d, a)$: a content hash, or $\varnothing$.

A present folder *occupies* the place that is its value. A present file
occupies the place that is its key.

The folder half of the state is the tree of [K21, section 3.1]:

> We can represent the tree as a set of (parent, meta, child) triples [...]
> in a filesystem, the parent and child are the inodes of a directory and a
> file within it, respectively, and the metadata contains the filename of
> the child.

**Definition 3 (well-formed).** A state is well-formed if:

- **W1.** Every occupied place $(d, a)$ has $d$ present, or $d$ the root.
- **W2.** No place is occupied twice.
- **W3.** From every present folder, following parents reaches the root.

**Definition 4 (command).** A command is $\langle k, x, y \rangle$: a key,
the value before, the value after. It is *applicable* to $\Phi$ if
$\Phi(k) = x$ and the state with $y$ at $k$ is well-formed. The value $x$ is
the **guard**.

This is the command of [C23, Definition 1], on other keys:

> A filesystem command is a triplet $\sigma = \langle n, x, y \rangle$, where
> $n \in N$ is the node on which $\sigma$ acts, $x$ is the content at node
> $n$ before $\sigma$ is executed (the contextual information,
> precondition), and $y$ is the new content.

and the reason for the guard is theirs [C23, II.B]:

> enriching filesystem commands with additional contextual information — in
> this case, the previous content at the affected node — makes them amenable
> to algebraic manipulation.

| Operation | Command |
|:---|:---|
| create a file | $\langle (d,a), \varnothing, f \rangle$ |
| delete a file | $\langle (d,a), f, \varnothing \rangle$ |
| write | $\langle (d,a), f, f' \rangle$ |
| create a folder | $\langle i, \varnothing, (p,a) \rangle$, with $i$ new |
| remove a folder | $\langle i, (p,a), \varnothing \rangle$ |
| rename or move a folder | $\langle i, (p,a), (q,b) \rangle$ |
| rename or move a file | a delete at one key and a create at another |

**A folder rename is one command on one key.** Nothing beneath the folder is
touched, because what it contains is keyed by its identity. This is what A5
buys, and it is why a folder rename is not a delete and a create.

A *null* command has $x = y$. The *inverse* of $\langle k, x, y \rangle$ is
$\langle k, y, x \rangle$. Commands are applied left to right; $A \circ B$ is
"$A$, then $B$"; $A\,\Phi$ is the result of applying $A$ to $\Phi$.
$A \sqsubseteq B$ ($B$ *extends* $A$) means that $B$ has the same effect as
$A$ on every state where $A$ applies.

## 4. The algebra of one client's operations

**Lemma 1 (laws).**

1. Two commands on different keys, when applicable in both orders, give the
   same state in both orders.
2. Two commands on one key fuse:
   $\langle k, x, y \rangle \circ \langle k, y, z \rangle \sqsubseteq \langle k, x, z \rangle$.
3. A null command can be dropped.

*Proof.* A command writes one key, so (1) is immediate. For (2), where the
left side applies, the right side reads the same $x$ and produces the same
final state, which is well-formed. (3) is immediate. $\square$

The state is a flat map, so the algebra is as simple as it can be. The tree
does not constrain *what* a set of commands does. It constrains only the
*order* in which they can be applied, which is section 5.

**Definition 5 (difference).**
$\mathit{diff}(\Phi, \Psi) = \{\langle k, \Phi(k), \Psi(k) \rangle : \Phi(k) \neq \Psi(k)\}$.

**Proposition 2 (history does not matter).** Let $S$ be any sequence of local
operations with $S\,R = L$. Fusing the commands of $S$ key by key and
dropping null results gives exactly $\mathit{diff}(R, L)$. The guard of each
fused command is the guard of the first command on its key.

*Proof.* On a key $k$, the commands of $S$ form a chain from $R(k)$ to
$L(k)$, each reading what the previous one wrote. By law 2 the chain fuses
to $\langle k, R(k), L(k) \rangle$, which is dropped by law 3 exactly when
the key is unchanged. $\square$

This is the central engineering consequence:

> The pending change $P$ is not recorded. It is $\mathit{diff}(R, L)$, where
> $R$ is the main's state as the client knows it. Simplifying a batch of
> pending operations and deriving the batch from $R$ and $L$ are the same
> thing.

**The incident.** Delete then create is
$\langle k, v, \varnothing \rangle \circ \langle k, \varnothing, w \rangle \sqsubseteq \langle k, v, w \rangle$:
one write, guarded by $v$. The failure in section 2 came from changing
$R(k)$ to $\varnothing$ at the local delete, which turned the guard into
$\varnothing$.

| Local history | Pending change |
|:---|:---|
| create; delete | nothing |
| write; write | $\langle k, v, w_2 \rangle$ |
| delete; create | $\langle k, v, w \rangle$ |
| write temp; delete target; rename temp onto target | $\langle \mathit{target}, v, w \rangle$ |
| rename a folder twice | $\langle i, (p,a), (p,c) \rangle$ |
| rename a folder, then back | nothing |

## 5. Order and batches

A set of pending commands cannot be applied in any order: each intermediate
state must be well-formed. The constraints, read off Definition 3:

- **O1.** A folder exists before anything is placed in it (W1).
- **O2.** A folder is empty before it is removed (W1).
- **O3.** A place is freed before it is occupied again (W2).
- **O4.** A folder is moved out of another before that other is moved into
  it (W3).

These constraints can form a cycle. Swapping the names of two folders is
one: each needs the other to go first. So is a folder taking the place of
its parent while the parent moves into it. A cycle is broken by moving one
folder to a *temporary place*: a fresh name under the root.

**Theorem 3 (the difference can be applied).** Let $R$ and $L$ be
well-formed and $P = \mathit{diff}(R, L)$ be non-empty. Then at least one of
these holds:

1. some command of $P$ is applicable to $R$;
2. some folder with a command in $P$, not at a temporary place, can be moved
   to a temporary place.

Repeating this reaches $L$, using at most one temporary place per folder
that $P$ moves.

*Proof sketch.* Suppose no command of $P$ is applicable. A file removal or a
file edit is always applicable, so $P$ has none.

Suppose $P$ places something (creates a file, creates or moves a folder).
Take the placement $\sigma$ whose target is closest to the root in $L$. The
folder it targets and all that folder's ancestors have no command in $P$:
they are present in $L$, so their command would be a placement closer to the
root. Hence the target folder is present in $R$ (W1 holds), and its chain of
ancestors is the same in $R$ and in $L$, so $\sigma$ creates no cycle (W3
holds). So $\sigma$ is blocked by W2: its place is occupied in $R$ by
another key, which does not occupy it in $L$ and therefore has a command in
$P$. That key is not a file, since a file removal is applicable. It is a
folder, and its place is not temporary because it is a place of $L$. Moving
it to a temporary place is always allowed: the root exists, the name is
fresh, and a folder directly under the root closes no cycle.

Otherwise $P$ only removes folders. Take the deepest one in $R$. What it
contains in $R$ is absent from $L$, so it would have a removal in $P$: a
file removal is applicable, and a folder removal would be deeper. So the
folder is empty and its removal is applicable.

Each step either commits a command of $P$, which then leaves $P$ for good,
or moves a folder to a temporary place, which happens at most once per
folder. $\square$

**Theorem 3 is about applying changes one at a time to a real tree**: a local
file system, or records kept one per key. A temporary place exists only
there. It is never part of a pending set and never part of what is
published.

**Definition 6 (batch).** A subset $B \subseteq P$ is a *batch* if $R$, with
the keys of $B$ set to their values in $L$, is well-formed. That state is
written $B\,R$.

**Proposition 4 (batches).** $P$ itself is a batch. If $B$ is a batch, then
$\mathit{diff}(B\,R, L) = P \setminus B$.

*Proof.* $P\,R = L$, which is well-formed. The second claim is immediate from
Definition 5: the keys of $B$ now agree with $L$. $\square$

A batch is a *set*, not a sequence: it is the difference between two trees.
Whoever applies it to a real tree orders it for that tree, by Theorem 3.

## 6. The system

### 6.1 The main

The main is a numbered log of entries $e_1, e_2, \dots$. An entry is a batch
with its author. $M_n$ is the tree after entries $1$ to $n$. By A2, entry
$n+1$ is created by at most one client. The *head* is the number of the last
entry.

### 6.2 What a client stores

- $L$, the full local tree, always current with what the user sees.
- The **before-values**: for each key where the client's tree differs from
  what it last knew of the main, the main's value at that key.
- $h$, the number of the last entry it has merged.
- At most one **in-flight batch**: a batch it is trying to commit, with the
  entry number it expects.

$R$ is not stored. It is $L$ with the before-values put back:
$R(k)$ is the before-value of $k$ if there is one, and $L(k)$ otherwise. The
pending set is read off the same table: one command
$\langle k, \mathit{before}(k), L(k) \rangle$ per before-value. This is
exactly enough to hold one changeset and the last known state of the main.

### 6.3 Rules

- **Local.** Before a local operation changes a key that has no
  before-value, record its current value as the before-value. Then change
  $L$. If a key's value returns to its before-value, drop the before-value.
- **Upload.** File content is stored on the main, by hash, at any time. It is
  not part of a commit.
- **Fetch.** Read the head. If it is $h$, there is nothing to do. Otherwise
  read the entries after $h$; the last value they give each key is $M$ on
  the keys that changed.
- **Merge.** In one local step: compute $N$ by section 7, change $L$ to $N$,
  set the before-values so that $R = M$, and set $h$ to the head.
- **Push.** Choose a batch $B$ whose content is uploaded. Record it as
  in-flight for entry $h+1$. Create entry $h+1$ with $B$. If created: drop
  the before-values of $B$ whose keys still hold the committed value, set
  the others to the committed value, set $h := h+1$, and clear the in-flight
  record. If the entry exists already: fetch and merge.

A fetch followed by a merge is an *arrival*.

**Fetching and merging can always be done and never fail. A push is
attempted only from a state that has merged the head, and is refused if the
head has moved.**

### 6.4 Results

**Proposition 5 ($R$ changes only on observed facts).** A local operation
does not change $R$. $R$ changes only in Push, when an entry is created, and
in Merge.

*Proof.* A local operation on a key without a before-value first records the
current value, so $R(k)$ is unchanged when $L(k)$ changes. On a key with a
before-value, $R(k)$ is that value and is not touched. $\square$

This is the property whose violation caused the incident, now true by
construction: a delete records the before-value, and the create that follows
finds it there.

**Proposition 6 (the main is safe).**

1. Every $M_n$ is well-formed.
2. Every committed command $\langle k, x, y \rangle$ replaced a value $x$
   that its author knew.

*Proof.* Entry $n+1$ is created by a client with $h = n$, so its $R$ is
$M_n$, and by A2 no other entry $n+1$ exists. Its batch $B$ gives
$M_{n+1} = B\,R$, which is well-formed by Definition 6. Each command's
guard is the author's $R(k) = M_n(k)$. $\square$

The main checks nothing about trees. A client at the head knows the main
exactly, so the check it makes on its own $R$ is the check on the main.

**Proposition 7 (a crash loses nothing and invents no conflict).** After a
crash with an in-flight batch for entry $h+1$, the next fetch decides: if
entry $h+1$ exists with this client as author, the batch was committed;
otherwise it was not. Every other entry after $h$ is a peer's.

*Proof.* The in-flight record is durable before the entry is created, and by
A2 the entry is created once or not at all. A client creates entry $h+1$
only from position $h$, so it has no other entry after $h$. $\square$

**Uploads and concurrency are separate.** An upload can take hours; a commit
is one small write. Because content is named by its hash (A4), uploading it
early can never conflict with anything, and an upload is never wasted: if
the file loses a merge, the same content becomes the conflicted copy. The
only window in which two clients can interfere is the creation of one entry,
and A2 closes it.

**A refused push costs little.** If the entries that got ahead touch nothing
this client has pending, the merge changes $L$ only where the peers changed
it, the pending set is the same, and the same batch is pushed again with no
new upload.

**Batch time is the client's choice.** The main advances in discrete steps,
one entry at a time. How long a client lets changes accumulate before it
pushes is its own decision; a few tens of seconds suits a person at work.
Nothing in the theory depends on the value. A long period without a
connection is the same thing with a very long batch time: the pending set
grows, and one arrival and one push bring the client back.

## 7. The concurrent case

A client at position $h$ fetches and finds entries after $h$. After the step
of Proposition 7 they are all peers' entries. Let $M$ be the main at the
head.

### 7.1 The problem

Let $P = \mathit{diff}(R, L)$ and $Q = \mathit{diff}(R, M)$. We look for a
merged state $N$, a new pending set $P'$ and a local correction $P_L$ with

$$P'\,M \;=\; P_L\,L \;=\; N.$$

Because every command has an inverse, this is solved by any well-formed $N$:
take $P' = \mathit{diff}(M, N)$ and $P_L = \mathit{diff}(L, N)$, both
applicable by Theorem 3. In particular $N = L$ is a solution that passes
every guard and destroys the peers' work. So the algebra does not choose
$N$. A rule must, and the rule is: **the main wins, and what the client
loses is kept under another name.**

The client therefore only has to compute $N$, then set $L := N$ and
$R := M$. The new pending set follows by itself.

### 7.2 Where the two sides can clash

A command of $P$ and a command of $Q$ clash in four ways.

- **(a) Same key.** Both changed one key, differently.
- **(b) Removed folder.** One side removed a folder; the other placed
  something in it.
- **(c) Same place.** Two different keys now occupy one place.
- **(d) Cycle.** Folder moves from both sides that close a cycle together.

Clashes (a) and (b) are the two conflict shapes of [C23, Definition 8]:

> The commands $\sigma, \tau \in \bigcup_i A_i$ are in conflict if either
> a) they are different commands on the same node, or
> b) the node of $\sigma$ is above the node of $\tau$, $\sigma$ creates a
> non-directory and $\tau$ creates non-empty content.

Clash (c) is part of their (a) when keys are paths; it becomes separate once a
folder is a key of its own. Clash (d) is the concurrent-move problem of [K21]:

> two concurrent operations may be safe individually, but introduce a cycle
> when combined.

Two changes do *not* clash that would in a path-keyed model: a peer renames
or moves a folder while this client changes what is inside it. The content
is keyed by the folder's identity, which the rename does not change.

### 7.3 The merge

**Definition 7 (merge).** $N$ is computed in two steps.

*Step 1, key by key.* With $r = R(k)$, $l = L(k)$, $m = M(k)$:

| Case | $N_1(k)$ |
|:---|:---|
| $l = r$: only they changed, or nobody | $m$ |
| $m = r$: only we changed | $l$ |
| $l = m$: the same change | $m$ |
| all differ, $m = \varnothing$, $k$ a file key | $l$ |
| all differ, otherwise | $m$; and if $k = (d, a)$ is a file key with $l \neq \varnothing$, also $l$ at a fresh key $(d, a')$ |

The third row takes the main's value: the two are equal as values, and where a
value carries more than what equality compares (a file's modification time),
the main's is the one every client ends with. The fourth row is "an edit
outlives a delete". The fifth is the conflicted copy.

*Step 2, repair.* $N_1$ may violate Definition 3. Apply the first rule that
applies, in the order R1, R2, R3, until none applies:

- **R1 (missing folder).** A place is occupied in a folder $d$ that is
  absent. Restore $d$: at the place it had in $M$ if it had one; otherwise
  at the place it had in $R$ if that is free and its folder present;
  otherwise at a fresh name in its nearest ancestor in $R$ that is present.
- **R2 (same place).** Two keys occupy one place. The one whose value comes
  from $M$ stays. The other moves to a fresh name in the same folder.
- **R3 (cycle).** Some folder on a cycle has a value that comes from $L$ and
  is present in $M$. Set it to its value in $M$. A folder that R1 restored is
  absent from $M$ and is never the one chosen: R1 would restore it again.

A *fresh name* is free in $N$ as computed so far and in $L$, and generated
only by this client. Being free in $L$ lets the client move a file aside
before it changes anything else in its tree.

The order of the rules matters only for names: applying them in another order
gives the same tree up to which fresh name each loser gets.

Naming the loser apart is what [K21, section 3.5] also recommends for (c):

> In practice, the collision would be resolved by making the filenames
> distinct, e.g. by appending a replica identifier to the filenames.

and resolving every clash in favour of the state already decided is the
construction of [C23, III.G] for a replica that changed during a merge:

> making sure that the returned merger $M^*$ contains $M$. (This can be
> achieved e.g., by constructing the merger via conflict resolution and
> making sure that each conflict is resolved in favor of a command in $M$.)

What R1 does for clash (b) deserves a note. When a peer removed a folder in
which this client added files, the folder comes back with one command, and
the additions stay where they are, keyed by its identity. When this client
removed a folder in which a peer added files, the same rule restores it
locally.

**Theorem 8 (properties of the merge).**

1. **Well-formed.** The repair ends, and $N$ is well-formed.
2. **Identity.** If $M = R$ then $N = L$. If $L = R$ then $N = M$.
3. **The main is preserved.** If $M(k) \neq \varnothing$ then
   $N(k) = M(k)$, unless $M(k) = R(k)$ and the client changed $k$.
4. **Nothing local is lost.** Every file content the client wrote
   ($L(k) \neq R(k)$, $L(k) \neq \varnothing$) is in $N$, at $k$ or at a
   fresh key in the same folder, and that folder is present.
5. **Confined.** Every key where $N$ differs from $M$ has a command in $P$,
   is a fresh key the merge made, or is a folder restored by R1.

*Proof sketch.* (1) R3 lowers the number of folder values taken from $L$,
and a cycle always has one that is present in $M$: $M$ has no cycle, $L$ has
none, and a folder the client created is reached only through folders it
placed. That a cycle through a folder R1 restored also has one is checked on
small trees only (section 12, case 22). R1 only restores folders
that exist in $R$ or $M$, of which there are finitely many. R2 moves a key
to a name nothing else uses. When none applies, W1 to W3 hold. (2) Step 1
gives $L$, respectively $M$, which is well-formed, so step 2 does nothing.
(3) Step 1 gives $m$ whenever $m \neq r$ and $m \neq \varnothing$. R2 moves
only the key that is not from $M$, R3 resets to $M$, R1 touches only absent
folders. (4) Step 1 keeps $l$ at $k$, or at a fresh key in the same folder
when the main wins. R2 may move it again, within the folder. R1 keeps the
folder. (5) By inspection of both steps. $\square$

Property 3 is the merge's form of Proposition 6(2): the merge never replaces
a value of the main that the client had not seen.

**What is deliberately not kept.** When both sides rename or move one folder
differently, the main's place wins and the client's rename is dropped.
Nothing is lost, since the content follows the identity. [C23, III.E] notes
of its own rolled-back commands that they "can only be reintroduced in a
different form"; for a rename there is nothing to reintroduce.

**Proposition 9 (a removal never destroys what it did not see).** If a
client's removal of a folder is pending when a peer commits something in
that folder, the removal is never committed, and at the client's next
arrival the folder is restored locally.

*Proof.* The peer's entry moved the head, so a push that holds the removal
is refused, and the client must merge first (section 6.3). In the merge,
step 1 gives $\varnothing$ for the folder and R1 restores it, so the removal
is no longer pending. $\square$

## 8. Convergence and progress

**Theorem 10 (convergence).** If every client has an empty pending set and
has arrived at the main's last position $h$, every local tree equals $M_h$.

*Proof.* After arrival $R = M_h$ (section 6). $P = \mathit{diff}(R, L)$ is
empty, so $L = R$. $\square$

**Theorem 11 (progress).** Suppose local operations stop. Then every client
reaches an empty pending set after finitely many commits and arrivals.

*Proof sketch.* A push is refused only if another client created the entry, so
some client always advances. For termination, follow each change a user made.
It commits once, or a merge alters it once per clash. After clash (a) or (c)
it sits at a fresh name, which no peer writes, so it cannot meet (a) or (c)
again. It can meet (b) again only if a peer's removal of the folder commits
first, and (d) only against a peer's move; there are finitely many such user
changes and each commits once. So the number of alterations is bounded.
$\square$

This sketch is the weakest proof in this document.

**Replicas.** By A3 a replica is a function of the main's log, so it
converges to the main by ordinary one-way replication. No conflict can
arise at a replica.

## 9. Reading from a replica

**Proposition 12.** Suppose a client reads only content objects from a
replica, never the tree and never the log. Then every result above still
holds, and the client reads either the right bytes or nothing.

*Proof.* By A4 a content object is named by the hash of its bytes, so a
replica that lags can lack an object but cannot hold a different one under
the same name. Nothing read from the replica enters $R$, a guard, or an
arrival. $\square$

The rule this imposes: **whatever sets $R$ or checks a guard is answered by
the main, never by a replica.** A lagging replica would show an older value
than $R$, which the client would take for a peer's change.

While the main is unreachable, local operations continue and $P$ grows. A
client does not see changes that peers publish in the meantime.

## 10. The single-writer deployment

With one client, the head moves only by that client's commits. A fetch finds
nothing, section 7 never runs, and every push is accepted. The theory
reduces to sections 3 to 6: record before-values, upload, commit batches.

The same rules run, the append included. On a store that cannot provide A2,
a client would check the head and then create the entry in two steps; should
a second client write the main against the assumption, the two may create the
same entry number. This is the one thing the single-writer assumption is there
to exclude.

The incident of section 2 occurred in this deployment. It is a failure of
Proposition 5 alone: a local delete changed $R$.

## 11. Relation to the sources

**Keyed by path or by identity.** [C16] and [C23] key the state by path:
the nodes form a fixed tree, a directory is a value like any other, and all
directories are equal. Their results are proved for that model. A state
keyed as in section 3 projects to a path-keyed state, and the two theories
agree on every change that renames no folder.

They differ on folder renames, which is the point of A5. The sources leave
moves out of the algebra. [C16, section 2.2]:

> in this model we will not consider a move (rename) command. This turns out
> to be useful because this would be the only command that affects
> filesystems at two nodes at once

and [R01]:

> Because the algebraic laws governing move are complex, we recommend that
> move be introduced only after reconciliation

With folders as keys, a folder move affects one key, and the objection does
not arise. A file has no shared identity, so a file rename remains a delete
and a create on two keys, as the sources recommend. By A4 the create uploads
nothing.

| Here | Source | Relation |
|:---|:---|:---|
| Definition 4 | [C23, Definition 1] | the same command, on other keys |
| Proposition 2 | [C16, Theorem 27]; [C23, Theorem 4(c)] | easier here: the map is flat |
| Definition 5, Theorem 3 | [C23, Theorem 6] | theirs always applies in some order; ours may need a temporary place |
| O1 to O3 | [C23, Definition 2] | O1, O2 are their order; O3 is new |
| O4, R3, clash (d) | [K21] | the cycle check, without their operation log: A2 gives the order |
| Clashes (a), (b) | [C23, Definition 8] | the same |
| The merge | [C23, III.E and III.G] | theirs discards what loses; ours renames it |

**A known limit: a file rename against an edit.** A peer edits a file that
this client renamed from $a$ to $b$. The delete at $a$ meets the edit, and
the main wins, so $a$ returns with the new content; the create at $b$ is
kept with the old content. Nothing is lost, and there are two files where
one was meant. A client that tracks files by a local identity can do better,
by applying the peer's edit to the file it now holds at $b$. That is a
refinement of step 1 which Theorem 8 permits; it is not required.

## 12. Cases a test suite should cover

Each follows from a numbered result.

1. Delete then create of one name, publication held: one write, guarded by
   the old content (Propositions 2 and 5).
2. Write temp, delete target, rename onto target: one write.
3. Create then delete, never published: no before-value remains and nothing
   is sent.
4. A folder renamed with content inside: one command, and no command for
   the content (Definition 4).
5. Two folders swap names, applied to a local tree: one temporary place, and
   none in the published batch (Theorem 3, Definition 6).
6. A folder takes its parent's place while the parent moves into it: the
   same.
7. A crash after an entry is created and before the client records it: the
   next fetch recognises it; a further local write to the same name makes no
   conflicted copy (Proposition 7).
8. A crash before the entry is created: the batch is still pending and is
   pushed again.
9. A push refused because of an unrelated commit: the same batch is
   committed at the next number, with no new upload (section 6.4).
10. Two clients upload different content for one name: both uploads
    complete; the second to commit gets a conflicted copy, with no new
    upload.
11. Both sides write one file: the main's version at the name, the client's
    in a conflicted copy (clash a).
12. A peer deletes a file the client edited: the edit stays under its name.
13. The client deletes a file a peer edited: the file returns locally.
14. A peer renames a folder in which the client created a file: no clash;
    the file is in the renamed folder (section 7.2).
15. A peer removes a folder in which the client created a file: the folder
    returns with the file in it (R1).
16. The client removes a folder in which a peer created a file: the removal
    is undone locally (Proposition 9).
17. Both sides create a folder with one name: both exist, the client's under
    a fresh name, each with its own content (R2).
18. Both sides rename one folder differently: the main's name, no copy.
19. Each side moves one folder into the other's: the client's move is
    dropped (R3).
20. Both sides make the same change: nothing is sent and nothing is copied.
21. A read from a lagging replica during an outage: right bytes or absence,
    and no change to $R$ (Proposition 12).
22. Every triple $(R, L, M)$ of well-formed trees over a small universe (two
    or three folders, one or two names, two contents): the five properties of
    Theorem 8, the pending set equal to $\mathit{diff}(M, N)$, and the same
    $N$ up to fresh names under every order of R1 to R3. Every pair of such
    trees: the difference applied in an order Theorem 3 gives passes only
    through well-formed trees and reaches its target, and every subset of it
    taken as a batch is one.

## 13. Open questions

1. Is the progress argument (Theorem 11) sound, and is there a cleaner
   measure?
2. The repair of the merge is confluent up to fresh names on every triple of
   small trees (section 12, case 22). A proof for all trees is missing.
3. R1 restores a removed folder under its own identity. Is there a case
   where a new identity would be the better outcome?
4. Does anything a conflict policy could use get lost by deriving $P$ from
   states, apart from file renames?
5. Content is uploaded before the entry that names it. Whatever removes
   unreferenced content must not let an entry name content it removed. tsync
   settles this at the commit: [gc.md](gc.md) §5.4.

## References

- **[C16]** E. P. Csirmaz. *Algebraic File Synchronization: Adequacy and
  Completeness.* arXiv:1601.01736, 2016.
  <https://arxiv.org/abs/1601.01736>
- **[C23]** E. P. Csirmaz, L. Csirmaz. *Synchronizing Many Filesystems in
  Near Linear Time.* Future Internet 15(6), 2023. arXiv:2302.09666.
  <https://arxiv.org/abs/2302.09666>
- **[R01]** N. Ramsey, E. Csirmaz. *An Algebraic Approach to File
  Synchronization.* FSE 2001.
  <https://www.cis.upenn.edu/~bcpierce/courses/dd/papers/ramsey-sync.pdf>
- **[K21]** M. Kleppmann, D. P. Mulligan, V. B. F. Gomes, A. R. Beresford.
  *A highly-available move operation for replicated trees.* IEEE TPDS, 2021.
  <https://martin.kleppmann.com/papers/move-op.pdf>
- **[BP98]** S. Balasubramaniam, B. C. Pierce. *What is a File
  Synchronizer?* MobiCom 1998. The origin of the split into update detection
  and reconciliation used by [C16]; not read for this document.
