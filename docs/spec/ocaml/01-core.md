# 01 — Foundation layer: lib/core, lib/local, lib/lwt — OCaml implementation notes

Companion to the language-neutral spec [../01-core.md](../01-core.md). See [README.md](README.md) for how these notes are organised.


## B.1 Runtime-independent OCaml learnings (valid under Lwt or OCaml 5 direct style)

**EINTR and the stdlib (spec §4.2).** OCaml's `Sys.set_signal` installs handlers without
SA_RESTART (sa_flags = SA_ONSTACK), and `runtime/sys.c` never retries: an interrupted call surfaces as
`Sys_error "<path>: Interrupted system call"` — a *string*, invisible to any `Unix_error (EINTR,_,_)`
handler. `Sys.file_exists` answers `false` on any failure including EINTR. `tsync_stdlib`
(`lib/local/stdlib/tsync_stdlib.ml`, no `.mli` because the shadowed functions are `external`s) is
`-open`ed by every library and shadows `open_in*`, `open_out*`, `close_in/out`, `Sys.{is_directory,
is_regular_file, remove, rename, readdir, mkdir, rmdir, chdir, getcwd}` with an EINTR retry that
matches both spellings (`Sys_error` by suffix `= Unix.error_message EINTR`), and rebuilds
`Sys.file_exists` on `Unix.stat`. Channel reads/writes are fine (`runtime/io.c` loops). `In_channel`/
`Out_channel` are not covered. Under OCaml 5 this is unchanged (and Eio's own file API retries EINTR,
but any stdlib/Unix call outside it still needs the shim).

**C stubs.**
* Release the runtime lock (`caml_release_runtime_system`) around anything that can block on disk
  (statvfs, positioned pread/pwrite, fallocate) — copy OCaml strings to C buffers first (heap may move);
  bigarray data never moves, so a bigstring pointer stays valid with the lock released and a page fault
  on a mapping cannot deadlock the runtime. Keep it held for cheap calls (`clock_gettime` vDSO, FICLONE
  ioctl, clonefile, inotify/kqueue setup/drain) — releasing costs more than the call. Under OCaml 5 with
  domains the same rules apply per domain (`caml_release_runtime_system` releases the domain lock).
* Save `errno` before reacquiring the lock; use `caml_uerror` so errors arrive as `Unix_error`.
* Loop on EINTR inside stubs (positioned I/O, reserve, watch drain).
* Bound loops that run in C with the lock held (`TSYNC_WATCH_DRAIN_PASSES = 64`): an event that never
  clears (a kqueue registration missing EV_CLEAR) otherwise spins forever with nothing able to time it out.
* inotify buffer must be aligned for `struct inotify_event`; a too-small buffer gets EINVAL, never a partial event.
* Platform branches: one C file with `#if __linux__/__APPLE__` when only the syscall names differ
  (descriptors, watch, reserve); separate per-OS OCaml libraries + dune `select` when the approach differs
  (device: sysfs vs `diskutil`). Android is Linux with bionic: `getloadavg` only from API 29 (guarded out).
  Windows branches fail at runtime rather than breaking the build (`ponytail` notes).
* The xxHash C library is vendored single-header with `XXH_INLINE_ALL` (no system lib to find/cross-build).
  XXH3 state is a custom block with a finaliser freeing the C state.

**Bigarray / off-heap bytes.** Chunk bodies (8 MiB) are `Bigstringaf.t` (= `Bigarray.Array1` of char)
so the GC neither scans nor copies them; hashing has a bigstring variant so bodies are never copied to a
`string` to be named. FUSE buffers are passed straight in as the same type. `Unix.map_file` **extends**
a file that is shorter than the mapping when the fd is writable — map a read-only fd so a short file
raises instead of growing (`Bigstring.map_file`). A mapping of a file that another writer truncates is a
SIGBUS (process death), hence reflink snapshots. A `map_file` result is a small heap object (test asserts).

**Off-heap tables.** `Hashtbl_mmap` keeps data-sized key sets (mirror's held set) in an unlinked temp
file mapping + a Bigarray slot array; the fd is closed by a `Gc.finalise` on the table. Mirror memory fell
from 140 to 16 live words per object with streaming + off-heap sets (memory note mirror-per-object-retention).
`Listing` spills records to a spool and walks the mapping. Both stay valid under OCaml 5 (Bigarrays are
shareable across domains but not synchronised).

**POSIX record locks are per process.** `lockf` merges with a lock the same process already holds, and
closing *any* fd to the file drops every lock the process holds on it — so `Durable_queue` answers "do I
own this claim" from an in-process table (`owned`) and keeps one fd open for the claim's lifetime. Under
domains, this table needs a mutex.

**Randomness and fork.** Use a private `Random.State` (global `Random` is only as seeded as whichever
module called `self_init` first — link-order dependent) and tag it with the pid; reseed from
`/dev/urandom` in a forked child (commit a42c99e5). Under OCaml 5, `Random` state is per-domain
(split); a private state shared between domains needs a lock or `Random.State.split` per domain.

**Exceptions as vocabulary.** `Retry.Failed {kind; op; detail}`, `Retry.Cancelled`, `Shutdown.Stopping`
have `Printexc.register_printer` renderings so logs read `"op: detail (transient)"` and
`"stopping: left for the next start"`. Type-level choices worth keeping: `Logical_key.t` and
`Stored_key.t` are abstract (no `of_string` for stored keys; logical keys carry prefix and kind as
fields, never re-derived from a string); `Item_ref.t` is a polymorphic variant with a `` `Bad `` case so
parsing is total; small enums are polymorphic variants to avoid module dependencies.

**Totality at FFI boundaries.** Anything reachable from C (Android JNI, `Desktop_mounts.mount_points`
for file-manager extensions) wraps in `try … with _ ->` a neutral answer: an escaping OCaml exception
kills the host process.

**dune layout.**
* `tsync_stdlib` (no deps but unix) → `tsync_io` (signatures, `Fs`/`Bounded`/`Syscalls`/`Filename`,
  statvfs + monotonic clock stubs) → `tsync_device` (clone/queue depth via `select` between
  `tsync_linux_device`/`tsync_macos_device` gated by `enabled_if (= %{system} linux|macosx)`, plus one-file
  descriptors/watch stubs) → `tsync_core` (`-open Tsync_stdlib -open Tsync_io -open Tsync_device`,
  xxhash stubs, syslog via `(select log_syslog_provider.ml from (syslog -> ….available.ml) (-> ….stub.ml))`
  so the library builds without syslog) → `tsync_io_lwt` → `tsync_core_lwt`.
* `tsync_runtime` selects `runtime.linux.ml`/`runtime.macos.ml`; `tsync_desktop_mounts` is Linux-only
  and private (a public library cannot depend on a private one).
* `Tls_conf`: which conduit TLS backends exist is fixed at conduit build time by optional deps (packages
  `tsync-tls` → ocaml-tls "native", `tsync-ssl` → lwt_ssl "openssl"; the opam file requires one). OpenSSL
  preferred (faster); native kept because OpenSSL's per-connection error-queue bug breaks some
  S3-compatible endpoints (Backblaze B2). Unknown name raises; known-but-not-built warns and falls back.
  Selection must happen before domains build connections, so it is logged where applied.
* `(implicit_transitive_deps false)`: every stanza lists what it compiles against; `-open` flags are what
  keep short names working after library moves (see the `lwt-agnostic-library` skill, whose paths
  `lib/io`, `lib/lwt/io`, `lib/utils` are stale: now `lib/local/io`, `lib/lwt/local/io`, `lib/core`).

**Verification habits** (skill + CLAUDE.md): `dune build --force` for cached test actions; perturb a
relocated rule and confirm a suite reddens (e.g. `reap_older_than` and the up-front `ftruncate` in
`atomic_write_at` stayed green under perturbation — known coverage gaps).

## B.2 Lwt / functor-specific learnings, and their effects/domains translation

### B.2.1 The signatures (implements spec §3.1)

`lib/local/io/io.ml`:

```ocaml
module type S = sig
  type 'a t                 (* a promise *)
  type 'a u                 (* its resolver *)
  val return : 'a -> 'a t
  val bind : 'a t -> ('a -> 'b t) -> 'b t
  val map : ('a -> 'b) -> 'a t -> 'b t
  val catch : (unit -> 'a t) -> (exn -> 'a t) -> 'a t
  val finalize : (unit -> 'a t) -> (unit -> unit t) -> 'a t   (* runs after, re-raises *)
  val fail : exn -> 'a t
  val wait : unit -> 'a t * 'a u
  val wakeup_later : 'a u -> 'a -> unit
  val async : (unit -> unit t) -> unit    (* detached; must not raise *)
  val join : unit t list -> unit t        (* concurrent *)
  val map_p : ('a -> 'b t) -> 'a list -> 'b list t
  val iter_p : ('a -> unit t) -> 'a list -> unit t
end
```

Deliberately minimal: *what modules turned out to use*, not what a scheduler offers. `wait`/`u` are
required (pools are built from an unresolved promise + resolver). Sequential combinators
(`iter_s`, `map_s`, `filter_map_s`, `fold_left_s`, `let*`, `let+`) are derived in `Io_syntax.Make`, never
added to `S`. No filesystem in `S` ("waiting and reading a disk are different questions").

Companion signatures, each separate so a module takes only what it uses:

```ocaml
(* lib/local/io/clock.ml *)
module type S = sig
  type 'a io
  val now : unit -> float                    (* monotonic seconds, arbitrary origin *)
  val sleep : float -> unit io
  val with_timeout : float -> (unit -> 'a io) -> 'a io        (* fails with scheduler's timeout *)
  val with_stall_timeout : float -> ((unit -> unit) -> 'a io) -> 'a io  (* times out on silence *)
  val pick : 'a io list -> 'a io             (* first to finish; the rest are CANCELLED *)
  val is_cancelled : exn -> bool
  val is_timeout : exn -> bool
end
external monotonic_now : unit -> float   (* CLOCK_MONOTONIC *)

(* lib/local/io/lock.ml *)
module type S = sig
  type 'a io  type mutex  type condition
  val mutex : unit -> mutex
  val with_lock : mutex -> (unit -> 'a io) -> 'a io
  val is_locked : mutex -> bool       val has_waiters : mutex -> bool   (* reporting only *)
  val condition : unit -> condition
  val wait : condition -> unit io     (* carries nothing; re-read state *)
  val signal : condition -> unit      val broadcast : condition -> unit
end

(* lib/local/io/syscalls_intf.ml — what a platform owes, in Unix names/arg order *)
module type S = sig
  type 'a io  type fd
  val file_exists, stat, lstat, readlink, symlink ?to_dir, rename, unlink, link, mkdir, rmdir,
      openfile, close, read, write, pread (~file_offset), pwrite, pwrite_string, utimes, fsync
  module LargeFile : sig val stat, lstat, fstat, ftruncate, lseek end
end
(* Syscalls.Make (Io) (Sys) : S + retry_eintr — every call retried on Unix_error EINTR. *)

(* lib/local/io/fs_intf.ml *)
module type PRIMITIVES = sig
  type 'a io  type fd
  val read_file_opt : string -> string option io
  val write_file : string -> string -> unit io
  val readdir_list : string -> string list io          (* no . / .. *)
  val bread / bwrite : fd -> Bigstringaf.t -> int -> int -> int io   (* at fd position *)
  val pread / pwrite : fd -> Bigstringaf.t -> file_offset:int -> int -> int -> int io
                          (* positioned; need not yield — under Lwt they block *)
  val reserve : size:int64 -> fd -> unit io            (* EOPNOTSUPP/ENOSYS if unsupported *)
end
```

`Fs.Make (Io) (Syscalls) (PRIMITIVES) : Fs.S` adds the logic (see §3.3). `Bounded.Make (Io) : Bounded.S`
(§3.4). There is **no** `Fs` inside `Io`; a module that needs files takes an `Fs.S` or a narrower
signature it declares itself (e.g. `Durable_queue.FILES`, `Listing.SPOOL`, `Spool.APPEND`).

### B.2.2 Functor inventory in this layer

| functor | parameters | yields |
|---|---|---|
| `Syscalls.Make` | Io, Syscalls.S | EINTR-retrying syscalls |
| `Fs.Make` | Io, Syscalls.S, PRIMITIVES | `Fs.S` |
| `Bounded.Make` | Io | pool |
| `Retry.Make` | Io, Clock | `LOOP.with_retry` |
| `Shutdown.Sleep` | Io, Clock | stop-aware sleep |
| `Health_wait.Make` | Io, Clock | `until_held` |
| `Durable_queue.Make` | Io, Clock, Lock, FILES | `S` (containing `Make (J : JOB) : QUEUE`) |
| `Spool.Make` | Io, Fs.S, APPEND | spool |
| `Listing.Make` | Io, SPOOL | listing |
| `Http_client.Make` | Io, Clock, Retry.LOOP, POOL | pooled HTTP client |
| `Ipc.Make` | Io, Lock, Clock, TRANSPORT | async send, server, Subs |
| `Job_report.Make` | Io, Clock, Bounded.S, SEND, LINK | reporter |
| `Logical_key.Make`, `Item_ref.Make`, `Chunk_layout.Make` | a first-class "domain" (`domain_prefix` / `chunk_prefix`) | namers |

Pure (no functor): `Chunks`, `Chunk_source`, `Stored_key`, `Folder`, `Id`, `Xxhash`, `Glob`,
`Zip_stream`, `Metrics`, `Health`, `Job_progress`, `Hashtbl_mmap`, `Bigstring`, `Field_spec`, `Log`,
`Shutdown` (core), `Retry` vocabulary.

### B.2.3 The layering as built (implements spec §4.1)

1. **Logic modules are functors** over the smallest set of signatures they use
   (`Io.S` always; `Clock.S`, `Lock.S`, `Syscalls.S`, `Fs.S`/narrower file signatures, `Bounded.S`,
   and domain-specific ones such as `POOL`, `TRANSPORT`, `SEND`). Anything that is a loop, a recursion or
   a sequence of calls is logic; one call the platform or process makes is a parameter. The *process's*
   own concerns (counters, reporters, link governors) are also parameters when they would otherwise
   drag in a dependency.
2. **Pure vocabulary sits above the functor** in the same module (e.g. `Retry.kind/classify/backoff`,
   `Fs.disk_space`, `Durable_queue.claim/release`), so consumers that only need names don't link a scheduler.
3. **One binding library per concern under `lib/lwt/`** applies each functor **once per process**:
   `Io_lwt.Core` (Lwt), `Io_lwt.Clock`, `Io_lwt.Lock` (Lwt_mutex / Lwt_condition), `Io_lwt.Unix_syscalls`
   (Lwt_unix), `Io_lwt.Fs_primitives` (+ C stubs `positioned_stubs.c`, `reserve_stubs.c`),
   `Io_lwt.Bounded = Bounded.Make(Core)`, `Io_lwt.Fs`. Then `Retry_lwt`, `Durable_queue_lwt`,
   `Http_client_lwt` (POOL = cohttp Connection_cache), `Ipc_lwt` (TRANSPORT = Lwt_io unix sockets with
   `set_tcp_nodelay:false`), `Spool_lwt`, `Listing_lwt`, `Job_report_lwt`, `Metrics_lwt` (Lwt engine
   stats), `Uplink_lwt`, and higher up `Backend_lwt`, `Remote_lwt`, `Checkout_lwt`, `Sync_lwt`… Domain
   modules name their functor `Over` (e.g. `Remote.Over (Core)(Bounded)(Syscalls)(Layout)…`). The
   `.mli` of the binding uses `module type of Tsync_io.X.Make (Core)` so it restates nothing.
   Only `lib/lwt/**` (and, not yet functorised, `lib/app`) says `Lwt`.
4. **Applied once ⇒ process singletons.** Registries in functor bodies (named Bounded pools, durable
   queue settle/rescan registries, Backend driver registry, Change_notice table) are per application;
   applying twice would split them. A rewrite needs process-global registries.
5. **Raw descriptors never leak into the functor**: conversions to a real OS fd happen in `PRIMITIVES`.
6. **Scheduling assumptions baked into every functor body** (must be preserved by any replacement):
   * Single-threaded cooperative execution: nothing runs between two suspension points. Code relies on
     it (e.g. `Bounded.each` advances the job source between binds; `Ipc.Subs` checks an empty queue then
     waits without a race; `Durable_queue` mutates tables without locks). One main worker, blocking
     calls may block the loop (positioned pread/pwrite and reserve are **synchronous** under Lwt).
   * Cancellation: `Clock.pick` cancels the losers (Lwt.Canceled propagates into pending sleeps/IO);
     `is_cancelled` distinguishes it. `with_timeout` fails with a scheduler-specific exception recognised
     by `is_timeout`. Retry must not retry a cancellation.
   * `wakeup_later` resolves a promise without running its continuation re-entrantly; waking twice is an
     error (Ipc guards with a flag).
   * `async` tasks must not raise (Lwt's async exception hook is fatal).
   * `Lock.wait` on a condition carries no value; waiters re-read state.
7. Libraries are grouped by dune library: `tsync_stdlib` (EINTR shim, opened by everything),
   `tsync_io` (the signatures + Fs/Bounded/Syscalls/Filename/Clock/Lock + statvfs/clock stubs),
   `tsync_device`, `tsync_core` (vocabulary, `-open Tsync_stdlib Tsync_io Tsync_device`),
   `tsync_io_lwt`, `tsync_core_lwt`.

### B.2.4 Lwt binding specifics (`lib/lwt/local/io/io_lwt.ml`, `lib/lwt/core/*`)

* `Core` = `Lwt.return/bind/map/catch/finalize/fail/wait/wakeup_later/async/join`, `Lwt_list.map_p/iter_p`.
* `Clock.now = monotonic_now` (C `clock_gettime(CLOCK_MONOTONIC)`), `sleep = Lwt_unix.sleep`,
  `with_timeout = Lwt_unix.with_timeout` (raises `Lwt_unix.Timeout`), `with_stall_timeout` = `Lwt.pick
  [f alive; watchdog]` where the watchdog sleeps exactly until `last_heard + s` (wall clock!) and re-arms,
  `pick = Lwt.pick`, `is_cancelled e = (e = Lwt.Canceled)`.
* `Lock` = `Lwt_mutex` / `unit Lwt_condition.t`.
* `Fs_primitives`: `read_file_opt`/`write_file` via `Lwt_io.with_file`; `readdir_list` materialises
  `Lwt_unix.files_of_directory` (wrapped whole in the EINTR retry, so an interrupted opendir/readdir
  restarts the listing); `bread/bwrite = Lwt_bytes.read/write`; positioned pread/pwrite and `reserve`
  are C stubs returned as already-resolved promises (**they block the loop**).
* `Durable_queue_lwt.Files.read_file` distinguishes ENOENT (`` `Gone ``) from other errors.
* `Http_client_lwt.Pool` = `Cohttp_lwt_unix.Connection_cache` (`Redial` = `Connection.Retry`), body sent
  `` `Passthrough `` from the bigstring, response streamed calling `alive` per piece.
* `Ipc_lwt.Transport` = `Lwt_io` over `ADDR_UNIX` with `~set_tcp_nodelay:false` on both connect and
  `establish_server_with_client_address` (Lwt tries TCP_NODELAY on every accepted connection and
  tolerates only EOPNOTSUPP; macOS answers EINVAL when the peer already left, which killed the accept
  loop — memory note lwt-unix-server-nodelay-einval). `send_lwt` named apart from blocking `Ipc.send`.
* `Metrics_lwt.stats` reports `Lwt_engine` readable/writable fd counts, timers, and
  `Lwt_unix.pool_size` (a stalled server shows descriptors that never drain).
* `Watch_lwt`: wraps the watch fd once with `Lwt_unix.of_unix_file_descr ~blocking:false` (a fresh
  wrapper per wait would register fresh engine state), `wait_read`, then `drain`; loops if only own scratch.
* `Uplink_lwt` registers a `Shutdown.on_request` hook cancelling bodies waiting for the link.
* Every domain subsystem has a mirror file under `lib/lwt/<same path>/<name>_lwt.ml` that applies its
  `Over` functor once (e.g. `Remote.Over (Core)(Bounded)(Syscalls)(Layout)(Manifests)(Versions)
  (Collection)(Corruption)`); a few carry small adapters (Files = `Io_lwt.Fs` + cache layout).

### B.2.5 Lwt pitfalls met, and what each becomes under OCaml 5 effects/domains

| Lwt learning | problem the functor/monad solved or caused | under effects (Eio/Picos, direct style) | under domains (parallel) |
|---|---|---|---|
| Functor over `Io.S` applied once in `lib/lwt` | kept Lwt out of logic; cost: every module is a functor, `'a io` everywhere, `with type … :=` gymnastics, a mirror tree of ~1000 lines of applications, tests use Lwt directly (1019 refs) | functors unnecessary: logic calls `Eio`/effects directly or through a plain module; keep the *narrow capability records* only where tests need doubles (Clock, Files, Transport, Send, Pool) | same, plus capability records must be thread-safe |
| The monad marks suspension points | G1 atomicity was visible: no `let*` ⇒ no yield | lost: any call may perform an effect and yield. Audit the §3.2 critical sections; keep them free of effectful calls or wrap in `Eio.Mutex` | lost entirely between domains: every table in §3.2's list needs `Mutex`/`Atomic` or confinement to one domain |
| `Lwt.wait` + `wakeup_later` (`'a u`) needed for pools | not derivable from bind; pools built on it | `Eio.Promise.create`/`resolve`, or `Eio.Semaphore` for `Bounded` | `Eio.Semaphore`/`Mutex` are domain-safe; hand-rolled queues are not |
| `Lwt_list.map_p` unbounded fan-out; `Bounded.map_with` bounds in-flight, not offered | a fan-out whose width the data chooses allocates a promise+closure per element up front (mirror: 140 words/object) | unbounded `Fiber.List.map` spawns a fiber per element — same trap; use `Fiber.List.map ~max_fibers` or a semaphore, and pull workers (`Bounded.each`) for data-sized sources | a global scheduler bounds width, **not** working set: keep explicit pools (memory note duppy-scheduler-exploration) |
| Nesting a pool inside itself deadlocks (mirror probe→copy) | slots taken in sequence on the same pool | identical with semaphores | identical |
| `Lwt.pick` cancels losers with `Lwt.Canceled`; `Retry` must not retry it | cancellation as an exception at the next bind | `Eio.Fiber.first`/`Switch` cancellation raises `Eio.Cancel.Cancelled`; `finally`/`Switch.on_release` release slots; `is_cancelled` maps to that | cancellation is per fiber/switch; cross-domain cancellation needs a switch owned by the canceller |
| `Lwt.async` exceptions are fatal (async_exception_hook) | every detached loop catches all | `Fiber.fork_daemon`/`fork` under a switch: an escaping exception fails the switch — still catch inside | same |
| Waking a resolver twice raises (`Invalid_argument`) | `Ipc.serve` guards with `woken` flag | `Promise.resolve` twice also raises; use `try_resolve` | needs atomic guard |
| Lwt installs a SIGCHLD handler in `Lwt_main.run` ⇒ EINTR everywhere | motivated tsync_stdlib | Eio installs its own handling; EINTR still possible for raw `Unix` calls — keep the shim | same |
| `Lwt_unix` blocking-call thread pool never shrinks | Android caps it at 16 (memory floor, not ceiling) | Eio offloads with `Eio_unix.run_in_systhread` (its own pool) — size it deliberately | domains + a domainslib pool; don't block a domain running fibers |
| Positioned pread/pwrite C stubs block the loop (`Lwt.return (stub …)`) | Lwt only offers `Bytes` pread; regular files are "always ready" so no job | run in systhread or use io_uring (`Eio_linux`), which supports bigstring positioned I/O | parallel reads truly concurrent; keep G1 around them |
| `Lwt_io.read_line` raises at EOF | how a departed client reaches IPC loops | `Eio.Buf_read.line` raises `End_of_file` similarly | — |
| `Lwt_unix.with_timeout` exception identity | `is_timeout` is scheduler-owned | `Eio.Time.with_timeout_exn` raises `Eio.Time.Timeout` | — |
| `Lwt_mutex`/`Lwt_condition` are FIFO and cheap | G3 ordering | `Eio.Mutex` (FIFO), `Eio.Condition` (broadcast-only; use `await_no_mutex` loops) — `signal` has no direct equivalent, use broadcast + re-check | domain-safe but must cover all shared state |
| Registries in functor bodies are per application | "applied once" gives process singletons | plain top-level values | top-level values need `Mutex`/`Atomic`/`Domain.DLS` |
| Synchronous escapes inside the monad (`Unix.lockf`, `Unix.openfile` in `with_claim`, `Bigstring.map_file`, `Device.clone`, `Ipc.send` for CLI) | block the loop briefly, accepted | still block the fiber's domain; wrap long ones in systhread | fine per domain |

The recommended migration order recorded in memory (duppy-scheduler-exploration, 2026-09-21): (1) make
the concurrency interface direct-style while still on Lwt (needs OCaml 5; `tsync-libs` currently allows
`>= 4.14`; `Lwt_direct` availability unverified), (2) move HTTP off cohttp-lwt (the expensive part:
cohttp/conduit/S3 client, `lib/app` with ~378 direct Lwt refs), (3) swap the scheduler outright — never
run two permanently. Keep `Bounded` regardless; assume one main worker plus blocking threads unless every
§3.2 item has been made domain-safe.
