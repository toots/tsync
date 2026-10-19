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

1. **When copies arrive.** The owner is told of every path an arrival changes. A conflicted-copy
   name ([conflict-resolution §5](conflict-resolution.md#5-conflicted-copy-name)) among them
   schedules its folder, in the background.
2. **Before a read that needs it.** A format may require its folder settled before a verb reads
   it; the vault's extensions do ([extensions README §4.2](../extensions/README.md#42-the-fold)).
3. **When what it needs arrives.** A format that cannot run yet (the vault locked, a content not
   fetched) is skipped without failing anything and runs at the next of 1 or 2, or when it can
   (an unlock).

Settling one folder twice changes nothing the second time. Two clients settling one folder
concurrently leave copies that a later settling folds.

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
- **Is bounded.** Inputs above `MERGE_MAX_BYTES` each are not settled. A settling that does not
  finish within `MERGE_DEADLINE` changes nothing.

The formats an implementation offers are listed by `tsync build-info`.

### 3.1 `totp-records`

The first format: the records of the `totp` extension, `/.tsync-ext/totp/`, a fold. It is the
grouped fold with the code fields as key fields and the relabel of a record kept from a copy
([totp §3](../extensions/totp.md#3-fold)). It needs K, so it runs on an unlocked vault, and
reads come after it.

### 3.2 Later formats

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

## 6. Parameters

| name | value | rule |
|---|---|---|
| `MERGE_MAX_BYTES` | 16 MiB | per input; larger files are not settled |
| `MERGE_DEADLINE` | 5 s | a settling that does not finish by then changes nothing |

## 7. Conformance

An implementation that provides format merges MUST exhibit:

- A one-time code renamed on two machines: once the copy arrives on an unlocked owner, its folder
  is settled with no verb asked, one record remains with the newer labels, and settling again
  changes nothing.
- A code whose seed differs between two copies: two records remain, the one from the copy
  labelled `(conflicted copy from <client>)`.
- A copy that arrives on a locked owner stays until an unlock or a read settles it.
- The merge itself is unchanged: for every input, `MERGE(R, L, M)` gives the same tree with and
  without format merges (conflict-resolution §10).
