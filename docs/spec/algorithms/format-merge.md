# Format merges

**Optional.** An implementation MAY provide format merges; one that does follows this file. With
none, every clash of contents ends as [conflict-resolution](conflict-resolution.md) says: two
files.

## 1. Problem

Two clients that edit one file concurrently end with two files: the main's at the name and the
other beside it as a conflicted copy ([conflict-resolution §1.1](conflict-resolution.md#11-the-principle)).
That is safe, and for most formats it is the only honest outcome. For some it is not what the
user wants: two people adding different lines to a shopping list, or renaming a one-time code on
two machines, made changes a program can combine without guessing. A **format merge** combines
them, so the user finds one file holding both edits, or, where both must stay, two that say so.

## 2. Where it runs

Not in the merge. The merge stays a pure function of three trees that reads no byte and makes no
store request ([conflict-resolution §3](conflict-resolution.md#3-local-state-a-merge-reads),
G4): it leaves the conflicted copy exactly as today, so nothing is at risk while a format merge
is tried. A format merge **settles** a file and its conflicted copies afterwards, in the owner,
with ordinary local operations pushed like any change.

A folder is settled for a format that applies to it (§4):

1. **When copies arrive.** The owner is told of every path an arrival changes, from the engine's
   start. A conflicted-copy name ([conflict-resolution §5](conflict-resolution.md#5-conflicted-copy-name))
   among them that is still there schedules its folder, in the background. A copy that arrives
   while its folder is being settled schedules one more settling after it: none is dropped. The
   owner's own changes, the moves of a settling included, schedule nothing.
   At owner start every format's folder that holds a copy is scheduled, so what arrived before
   the hook was set, or before a restart, is settled too.
2. **Before a read that needs it.** A format may require its folder settled before a verb reads
   it; the vault's extensions do ([extensions README §4.2](../extensions/README.md#42-the-fold)).
3. **When what it needs arrives.** A format that cannot run yet (the vault locked, a content not
   fetched) is skipped without failing anything and runs at the next of 1 or 2, or when it can
   (an unlock).

**A folder with no conflicted copy has nothing to settle.** Whether it has one is told by its
files' names alone, so such a folder is settled without reading a byte: a read that needs it
settled (2) costs a listing, however many files the folder holds.

Settling one folder twice changes nothing the second time. Two clients settling one folder
concurrently leave copies that a later settling folds. A domain this client may not write is
never settled.

## 3. A format

A format has a name, the files it applies to, and one of two shapes:

- **A fold** over a file and its conflicted copies, with no base: `settle(files) → actions`,
  moves, removals and writes within the folder. It MUST be a function of the names and the
  readable contents of the files and of nothing else (not the clock, not the client), so that two
  clients settling one state decide alike; writes whose bytes cannot be a function of them (an
  envelope draws a nonce) carry contents that are, and a later fold settles their copies.
- **A three-way merge** of one clash: `merge(base, ours, theirs) → merged | conflict`, for the
  client that kept a file aside, which alone knows the base (the before-value of the key,
  [publication §3](publication.md)). On `merged` it writes the result at the name and removes the
  copy when both still hold what was merged; otherwise the two files stay.

Either shape:

- **Keeps every change.** It drops a content only when another file of the result holds every
  change that content made, by the format's own notion of a change. Where keeping both would be a
  guess, both stay, as separate files or, for a format whose files must keep a fixed form of
  name, as two such files that say which came from where.
- **Carries its own proof.** No size or time limit is imposed on a format: the formats are ours,
  not adversarial, and a merge of two 2 GiB files is fine when its implementation is fast and
  bounded in memory. What a format MUST do instead is pass the suitability tests of §7 before it
  is registered, its scale bounds included.

The formats an implementation offers are listed by `tsync build-info`.

### 3.1 `totp-records`

The first format: the records of the `totp` extension, `/.tsync-ext/totp/`, a fold. It is the
grouped fold with the code fields as key fields and the relabel of a record kept from a copy
([totp §3](../extensions/totp.md#3-fold)). It needs K, so it runs on an unlocked vault, and
reads come after it.

### 3.2 `vault-keyring`

The vault's keyring and its copies, `/.tsync-ext/vault/`, a fold: the union of slots by key id
([vault §4.3](../extensions/vault.md#43-concurrent-changes)). It needs no K, so it settles on
arrival on a locked owner too.

### 3.3 Later formats

`lines` (text merged line by line, diff3), for ordinary files the domain lists (§4), is the
intended first three-way merge. It is not specified in this version.

## 4. Which files

- A format of an extension applies to that extension's folder, on every client that uses the
  extension ([extensions README §3](../extensions/README.md#3-opting-in)).
- Formats for ordinary files will be listed per domain, as a domain-wide setting stated by the
  main ([05 §2.1](../05-ops-config.md#21-schema-and-validation)), so the clients of one main
  settle alike; with none listed, ordinary files are never settled. A domain without
  `versioning` settles no ordinary file: removing a copy then relies on versions to give either
  side back.

## 5. What the user sees

- A settled folder is reported as the changes it made, like any local operation.
- A format that keeps both shows two files that say so (for `totp-records`, two records, one
  labelled with the client it came from).

## 6. Implementation

- **One runner.** Every fold goes through one runner: list the folder and stop there when no
  name is a conflicted copy (§2); otherwise read the folder, fold, apply the actions in order
  stopping at the first failure, then the format's follow-up writes (a relabel) for each action
  that ran. Nothing settles a folder outside it.
- **One writer of a folder at a time.** A settling and every verb that reads a folder a format
  applies to and then writes there hold that folder's lock from the read to the write, so a
  settling never moves a copy under a verb that has read the record, and a verb never writes
  over what a settling just merged. A verb that needs two such folders takes them in one order
  (an extension's before the vault's), and so does a settling.
- **A format settles with its fold alone.** It runs no verb: a settling has none of a verb's
  effects (a keystore read, forgetting K when the vault reads absent).
- **A format is a pure function and a registration.** The function (a fold or a three-way merge)
  takes bytes and answers actions or bytes; the registration names the folder or files it applies
  to and how to obtain what it needs (K). No production interface exists for tests' sake.

## 7. Suitability tests

Each format is shown suitable by a suite built on a shared **merge kit**: a test-only library,
never linked into the program, that turns a format's **fixture** into the properties below. The
fixture is the format's knowledge, written beside its tests:

- how to build a valid file of a given size from a seed;
- an edit the format can merge, and two edits that must both be kept apart;
- how to read a result's changes, to check none is lost;
- the format's function itself, called directly.

From a fixture the kit checks, for every format:

1. **Order.** The result does not depend on the order the files are given in.
2. **Idempotence.** Settling the result again changes nothing.
3. **Every change kept.** Each side's change from the base is in the result.
4. **Conflicts kept apart.** Two edits that must both be kept leave both, and a fold leaves no
   conflicted copy behind: what it keeps apart it keeps under names of the format's own form.
5. **Convergence.** Two clients settling the same state, or each other's results, end alike.
6. **Scale.** Inputs of the sizes the fixture declares (records by the thousand, files by the
   gigabyte) settle within the memory and time the fixture states, measured.

A format's own behaviour (the relabel of `totp-records`, the slot union of `vault-keyring`) is
tested in its own suite beside its fixture. The arrival trigger and the runner are tested once,
for any format, through an owner:

- A one-time code renamed on two machines: once the copy arrives on an unlocked owner, its folder
  is settled with no verb asked, one record remains with the newer labels, and settling again
  changes nothing.
- A code whose seed differs between two copies: two records remain, the one from the copy
  labelled `(conflicted copy from <client>)`.
- A copy of a record that arrives on a locked owner stays until an unlock or a read settles it;
  a copy of the keyring settles on arrival, locked or not.
- The merge itself is unchanged: for every input, `MERGE(R, L, M)` gives the same tree with and
  without format merges (conflict-resolution §10).
