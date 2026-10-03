# tsync — known pitfalls

This directory is the knowledge base for adversarial review of the rewrite. It lists the issues met
while building tsync, extracted from the commits on `main`, the pull requests, the rewrite branch,
the OCaml implementation notes ([`../spec/ocaml/`](../spec/ocaml/README.md)) and earlier working
notes. It is descriptive, not normative: the spec in [`../spec/`](../spec/README.md) stays the
contract, and each entry here is a way the contract was broken before.

Lessons that existed only because of a library no longer used (Lwt, cohttp, conduit, the aws-s3
fork) are left out. Where such a lesson survives the library, it is stated in runtime-neutral terms,
read against fibers on a domain pool, where nothing is atomic between two statements.

| File | Covers | Entries |
|---|---|---|
| [A-abstraction.md](A-abstraction.md) | Logical and structural issues true of any implementation: durability, concurrency, namespace and conflicts, failure classification, queues, journal, store contract, caches, security, ownership, liveness, reporting. | 200 |
| [B-implementation.md](B-implementation.md) | OCaml- and implementation-specific issues: runtime and C stubs, POSIX and platform corner cases (FUSE, macOS, Android), store API quirks (S3, GCS), build and test-harness traps. | 120 |
| [C-resources.md](C-resources.md) | CPU, memory, disk, network and descriptor consumption, measured against the Raspberry Pi Zero 2 W as reference host. | 67 |

## Entry form

Each entry has an ID (`A-3.4`: category, theme, entry), then:

- **Pitfall**: the mechanism, with the numbers the history gave.
- **Check**: what a reviewer verifies in the new code.
- **Seen**: commits and PRs. `recurred ×N` marks a mistake fixed several times; `rewrite` marks
  one that already happened on the rewrite branch. Both are the strongest signal of where to look.

Each file ends with a review checklist, one line per theme.

## Most recurrent

| ID | Pitfall | Seen |
|---|---|---|
| A-10.1 | State keyed per instance (per functor application) instead of per thing | ×12 |
| A-4.1 | "Could not look" read as "absent" | ×10+ |
| A-2.1 | Check-then-act that relied on cooperative atomicity | dozens of sites, rewrite |
| B-12.5 | Tests waiting on durations instead of conditions | ×10 |
| A-10.4 | Copies of one rule drift apart | ×8, rewrite |
| B-12.1 | Suites that verified nothing and reported success | ×8 |
| A-2.5 | Store round trip under the global metadata lock | ×8, rewrite |
| A-10.8 | Item kind derived from a key's spelling | ×7 |
| C-1.1 | Fan-out width chosen by the data | ×7, rewrite |
| A-4.10 | One unappliable item blocks an ordered consumer | ×6 |
| A-12.1 | Reporting an effect that did not happen | ×6, rewrite |
| B-11.1 | Link-time registration silently drops drivers and frontends | ×5, rewrite |
| C-3.1 | Bodies copied through the OCaml heap | ×5, rewrite |

Recurrence counts are judged from the evidence, not counted mechanically: a fix and its follow-up
count once.
