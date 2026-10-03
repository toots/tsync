# 03 — Multi-machine synchronisation (journal, sync, conflict resolution) — OCaml implementation notes

Companion to the language-neutral spec [../03-journal-sync.md](../03-journal-sync.md). See [README.md](README.md) for how these notes are organised.
The mapping of the protocol and of the conflict tables to the code, the implementation choices
(widths, batch sizes, read bounds) and the code's deviations from the spec are in
[algorithms/wal-and-journal.md](algorithms/wal-and-journal.md) and
[algorithms/conflict-resolution.md](algorithms/conflict-resolution.md). Section numbers in
parentheses below name the concept, not a section of the current spec.


Each note names the spec concept it implements. B-I holds what stays true under any
OCaml concurrency model (including OCaml 5 direct style with effects/domains); B-II holds
what is tied to the Lwt monadic style and the functor-over-runtime pattern, with what each
becomes under effects/domains.

## B-I. Runtime-independent learnings

**B-I.1 Abstract `Entry_key.t` (§2.2).** A private record `{ms; client_uuid}` with
`of_string` as the only constructor; the type system forbids comparing a bare key to a
prefixed or month-sharded spelling — the bug class (two readers "permanently behind") it
was introduced to kill. `File_store.journal_key` is the only function producing a backend
key from it. Keep this whatever the runtime.

**B-I.2 Ops as polymorphic variants (§2.3).** ``[ `Put | `Delete | `Mkdir | `Rmdir |
`Rename of rename_op ]``: modules build and match ops without depending on `Journal`'s
definitions (untangles the module DAG); `rename_op` is a record because it has >2 fields.
The conflict tables use ordinary closed variants for `facts`/`action`/`ending`, where
exhaustiveness across the table *is* the point (`tests/unit/resolve` enumerates them).

**B-I.3 "The lock cannot be held across a request" by module scoping (§4.4, §7.6).**
Everything that changes local state lives in `File.Local`, which owns the private
`meta_mutex`; the store modules are shadowed inside it, so code under `with_meta` has no
name through which to reach the store. This is a module-system technique and survives a
move to direct style. Peer entries therefore get store answers as a data table
(`store_reads`); a missing answer is the exception
``Unread (`Marker k | `Manifest k)`` used as control flow: the read-ahead catches it,
fetches, and restarts its survey; under the lock it becomes
`Retry.failed ~kind:Transient`, so the replay pass aborts and retries instead of stepping
the entry aside.

**B-I.4 Failure classification by exception tagging (§4.1, §4.3, §7.7).** The retry loop
raises `Retry.Failed {kind; op; detail}` when out of tries; `classify_in_order` returns that
kind and `Permanent` for any other exception (`Unix_error ENOTEMPTY`, `Invalid_argument` …).
`Retry.Cancelled` = superseded; `Shutdown.Stopping` must be re-raised untouched so the
record stays for the next start; `Unix_error (ENOENT, _, _)` from an upload = staged bytes
gone, nothing owed. A catch-all handler anywhere on these paths silently changes policy —
review every `with _ ->` against this list (e.g. `get_journal_entry` swallowing all
errors; see [algorithms/wal-and-journal.md](algorithms/wal-and-journal.md) §3).

**B-I.5 State hoisted to module-global tables because functors are applied many times
(§2.10, §4.2).** `Make (C)` is applied in every module that touches the journal (queues,
replay, resync, engine, tests), so `let x = ref …` inside it is one copy *per
application*. Every fix has the same shape — a global `Hashtbl` keyed by what the state
really belongs to: the cursor debouncer by cursor object key (per-application debouncers
meant a flush in one never published another's pending bump); `Replay.stepped_aside` by
domain (the poller steps aside, the engine reports); `Wal.logs` by directory (a second log
over one dir kept its own id counter), with the two hand-offs stored alongside;
`Journal.uuid_cache`/`leases` by data dir (lease tagged by pid because a forked child
inherits the heap). The `handled` set is still per application ([algorithms/wal-and-journal.md](algorithms/wal-and-journal.md) §3). This is about
generative functor application, not Lwt: it applies to any design that instantiates
per-domain modules repeatedly. Under domains these tables additionally need
synchronisation (B-II.2).

**B-I.6 Blocking local I/O where it is cheap and hot (§2.1, §2.6).** Client uuid, folder
id leases and the last-sync mark use synchronous `Unix`/`Stdlib` I/O (called on every
journal write; ponytail comment `journal.ml:19`). uuid creation uses `link(2)` for
cross-process atomicity; the mark uses write-to-`.<pid>.tmp` + `Sys.rename`; leases use
`O_CREAT|O_EXCL`.

**B-I.7 JSON via Yojson.Basic (§2.3, §2.7).** `size` is ``` `Int (Int64.to_int size) ```
— fine with 63-bit ints, would truncate on a 32-bit target. `of_json` wraps everything in
`try … with _ -> None` so decoding is total (forward compatibility).

**B-I.8 Snapshot scenario tests (§8).** `Test_runner.run_two_client_scenarios` runs two
full clients over one backend in one process with separate data/cache dirs; steps are a
variant (`A (Write …)`, `B Sync`, ``B (Metadata `Paused)``, `A HideNewestJournalEntry`,
`A (CrashBeforeCommit …)`); output is diffed against `<exe>.expected`, never substring
assertions, and contents are shown (a split brain passes a names-only check). A green
`dune build` compiles neither the runner nor the scenario executables; run the `runtest`
aliases and read the exit status; env-only changes need `dune build --force` (dune
replays cached actions).

## B-II. Lwt- and functor-specific learnings

**B-II.1 Functor over a concurrency signature (§3).** Each component is
`Over (Io : Io.S) (deps …) = struct module Make (C : Conf.S with type 'a io = 'a Io.t) …
end`: the outer functor fixes the runtime and its dependencies' implementations, the inner
one the domain; `lib/lwt/domain/sync/sync_lwt.ml` is the only place Lwt is chosen
(`Replay.Over (Io_lwt.Core) (Io_lwt.Bounded) (File_store_lwt) (Wal_lwt)
(Staged_lwt.Manifest)`, `Sync_poller.Over (Io_lwt.Core) (Io_lwt.Clock) (File_store_lwt)
(Replay)`, queues over `Wal_lwt.Q`). *Solved*: domain logic compiled without Lwt,
testable with a fake runtime; the poller takes Replay through an inline signature exposing
only `apply_foreign`, so tests can substitute it. *Cost*: a parallel `lib/lwt/…` mirror
tree, `with type 'a io := 'a Io.t` constraints on every signature, and the per-application
state trap (B-I.5). *Under effects/domains*: `'a io` collapses to `'a`, the outer functor
and the mirror tree disappear; keep the inner per-domain parameterisation (or replace it
with a first-class record of the domain's config) and keep the dependency seams that tests
substitute.

**B-II.2 The monad marks every yield, and unlocked state depends on it.** Under Lwt a
check-then-act with no `let*` in between is atomic. These pieces of shared state rely on that, with
no lock: entry-key minting (`last_ms`), the folder-id lease counter, the cursor debouncer
(`pending`, `timer_armed`, `last_published`; the publish itself is under a mutex), the dedupe set
and `stepped_aside`, the poller's `last_version`/`last_swept`, the metadata queue's `parked` set,
the WAL hand-off slot and log registry, and in-process applied-log appends. Under effects any function call may
suspend the fiber, and under domains other code runs in parallel. Each of these needs
an explicit mechanism: `Atomic` for `last_ms`/lease `next`/counters, `Mutex` (or a single
owning fiber with a message queue) for the debouncer, dedupe set, parked set and log
registry, and one `write` per applied-log record under a per-file mutex.

**B-II.3 The poller as a detached loop (§4.3).** `Io.async` (= `Lwt.async`): an exception
escaping it goes to `Lwt.async_exception_hook`, which hosts override to log because the
default exits the process — so the loop catches everything itself and sleeps
`retry_floor`. The wait uses `Clock.with_timeout` and swallows the timeout by
`Clock.is_timeout`. `paused` is a polled closure (0.2 s tick), not a condition variable.
*Under effects*: a fiber in a switch/nursery with structured cancellation; the pause
becomes a condition the loop blocks on; an unhandled exception should fail the switch
rather than rely on a global hook.

**B-II.4 Hand-off without waiting (§4.1).** `Wal.Owed` is a mutable slot holding the
consumer's `take : 'a -> unit Lwt.t`; `signal` calls it directly, so the producer returns
only once the consumer has adopted the record (a delete right after a close finds an upload
to cancel) and never blocks when nothing drains (the record is durable). *Under
effects/domains*: the same slot must be an `Atomic.t` (swap vs. call), or become a bounded
channel whose `send` returns after enqueue — the "returns after adoption" property is what
must be kept.

**B-II.5 Bounds (§6).** `Bounded.create ~max:32` for reconcile's journal reads, created at
module scope so overlapping recoveries share one bound (a promise per entry up front was
both memory and a request storm); upload workers = `max_uploads` in the durable queue; the
metadata queue is one worker. *Under effects*: bounded fan-out becomes a semaphore around
fibers; an unbounded `Lwt_list.iter_p` becomes unbounded fibers — the same hazard.

**B-II.6 Applied-log appends (§2.7).** `Lwt_unix.openfile [O_WRONLY; O_APPEND; O_CREAT]`
plus a short-write loop (`write_all`) that fails on a 0-byte write. Because the loop can
yield between partial writes, two in-process writers could interleave; the record format
(newline-led) makes cross-process tears cost one record, and in-process safety relies on
records being small enough that one `write` completes (B-II.2).

**B-II.7 Blocking calls inside the event loop (§2.1, §2.6).** B-I.6's synchronous I/O
stalls the whole Lwt loop (every domain) for its duration; acceptable because each is a
tiny local file operation. Under domains it only stalls the calling fiber's domain, but a
blocking call inside an effects scheduler still blocks that scheduler — keep them tiny or
route them through the runtime's blocking-call offload.

## B-III. Pitfalls met in the File Provider rewrite

**B-III.1 A peer op's local facts live at its translated path (§2.7 `fid`).** A peer names the
path it saw; the local half of the op acts at that path translated through this client's moved
folders and owed renames. Anything read about the local file, its file id first, must be read where
the op acts, not at the peer's path: read at the peer's path, a delete under a folder this client
renamed finds no id (the feed drops it as unnamed, and the replica keeps the file), or finds the id
of an unrelated file now at that path (the replica drops a file that still exists). The arrival
code that does the translation is the one place that may read it; it reports the id it acted on.
And only what it acted on: a delete names the file it removed, read before removing it, and nothing
when the arrival decision kept the file (a peer's delete of a file this client moved since): naming
the kept file would make the replica drop it.
