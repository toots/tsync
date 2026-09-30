# 01 — Foundation layer: lib/core, lib/local, lib/lwt — OCaml implementation notes

Companion to the language-neutral spec [../01-core.md](../01-core.md). See [README.md](README.md) for how these notes are organised.


## B.1 Runtime-independent OCaml learnings (valid under Lwt or OCaml 5 direct style)

**EINTR and the stdlib (spec §6.3).** OCaml's `Sys.set_signal` installs handlers without
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

### B.2.1 The signatures (implements spec §6.1)

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

`Fs.Make (Io) (Syscalls) (PRIMITIVES) : Fs.S` adds the logic (spec §6.4). `Bounded.Make (Io) : Bounded.S`
(spec §5.1). There is **no** `Fs` inside `Io`; a module that needs files takes an `Fs.S` or a narrower
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

### B.2.3 The layering as built (implements spec §6.2)

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
| The monad marks suspension points | G1 atomicity was visible: no `let*` ⇒ no yield | lost: any call may perform an effect and yield. Audit the critical sections of B.3.3; keep them free of effectful calls or wrap in `Eio.Mutex` | lost entirely between domains: every table in B.3.3 needs `Mutex`/`Atomic` or confinement to one domain |
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
B.3.3 item has been made domain-safe.

## B.3 Where each spec concept lives, and where the code departs from it

### B.3.1 Module map

| Spec concept | OCaml |
|---|---|
| XXH3 dual seed, chunk key (§3.1–3.2) | `Xxhash` (vendored header, `lib/core/xxhash_stubs.c`), `Chunks.key_of_body`, `Chunks.is_chunk_key` |
| chunking, range to pieces (§3.4) | `Chunks.count/index_of/offset_of/length_of/pieces` |
| upload chunk source | `Chunk_source.t = Stored of key \| Mapped of (unit -> bigstring) \| Filled of {len; fill}`, decided before any I/O |
| chunk size choice (§3.5) | `Conf.chunk_size`, else backend `capabilities.chunk_size`, else `Conf.default_chunk_size`; memoised once per process in `Remote` (`resolved_chunk_size`) |
| shard function (§3.6) | `Chunk_layout` (`fanout`, `shard_name`, `shard_of`, `relative_path`, `marker_key`, `is_marker_key`, `shard_of_job`) |
| logical keys (§2.4) | `Logical_key.Make` (`to_string`, `leaf`, `parent`, `file_in`/`dir_in` raising `Invalid_argument`, `rel_of_string`) |
| stored keys (§2.6) | `Stored_key` (abstract; `listed`, `namespace`, `child_key`, `index_key`, `anchor_key`, `trash_namespace`, `share_key`, `parent_folder_id`, `folder_id_of`, `path_in`, `is_dir_key`, `is_internal`, `is_child_object`) |
| folder marker / anchor bodies | `Folder` (Yojson.Basic, compact) |
| item references (§2.7) | `Item_ref` (polymorphic variant with `` `Bad ``) |
| mirror escaping (§2.8) | `Stored_key.escape`, `escape_path`, `name_max = 250`, `dir_name_leaf`, `folder_marker_leaf` |
| temporary names (§2.9) | `Filename.temp_in`, `temp_path`, `scratch_leaf`, `is_temp_name`, `temp_owner` (and a duplicate test in the inotify C stub) |
| random ids (§2.10) | `Id.short` (two `Random.State.int64 < 2^32`, `%08Lx%08Lx`, private state tagged with the pid and reseeded after fork, seeded from `/dev/urandom` with a pid+time fallback), `Id.token n` (raises without `/dev/urandom`) |
| pools (§5.1) | `Bounded.Make` (`create ?max_waiting ?name ~max`, `shared ~key`, `use`, `use_or ~busy`, `map_with`, `iter_with`, `filter_map_with`, `each ~width next`, `totals`) |
| local filesystem helpers (§6.4) | `Fs.Make`: `mkdir_p`, `atomic_write`, `atomic_write_at ~size`, `reserve`, `pwrite_all`, `copy_file`, `read_file_opt`, `readdir_list_quiet`, `stat_opt`, `lstat_kind`, `rm_rf`, `unlink_quiet`, `reap_older_than`, `zero`; synchronous `mkdir_p_sync`, `open_and_unlink`, `pid_alive`, `disk_space`, `load_average` |
| retry ladder (§7) | `Retry` (`Failed {kind = Transient \| Permanent; op; detail}`, `Cancelled`, `classify`, `classify_in_order`, `backoff`, `held`, `Make.with_retry`, `default_attempts = 8`) |
| `until-held` | `Health_wait.until_held` |
| breaker (§8) | `Health` (`check`, `lost`, `answered`, `probe_lost`, `on_held`/`off`, `describe`, `timed_out`/`timeouts`, `json`; tunables `trip_after`, `trip_span`, `hold_initial`, `hold_max`, `probe_timeout`; test hooks `expire`, `hold_length`) |
| stop (§9) | `Shutdown` (`Stopping`, `request`, `requested`, `on_request`, `grace`, `reset`, `Sleep`) |
| HTTP discipline (§10) | `Http_client.Make` over a cohttp `Connection_cache` pool (`Redial` = `Connection.Retry`), `call`, `call_retry`, `call_text`, `failed`, `excerpt` |
| IPC framing (§11) | `Ipc.Make` (`serve ?subs ?until ~path handler`, `send ?timeout`, `Subs` with `max_queued = 256`), blocking `Ipc.send`/`Ipc.request` for the CLI |
| spilling (§12) | `Spool`, `Listing` (records of int32-LE-length strings and 8-byte LE int64s), `Hashtbl_mmap` |
| snapshots (§12) | `Bigstring.open_snapshot`, `map_file` (`MAP_PRIVATE`, read-only fd), `Device.clone` (Linux `FICLONE` from a fresh `O_EXCL` 0600 file; macOS `clonefile`) |
| ZIP64 (§13) | `Zip_stream` (golden dump `tests/unit/zip/zip_test.expected`) |
| platform facts (§14) | `Device.max_concurrency`, `Descriptors.raise_to`, `Watch.open_dir/fd/drain/close`, `Watch_lwt.wait` |
| glob (§17) | `Glob.of_pattern`, `Glob.matches` |

Modules with no spec counterpart in 01 (owned elsewhere or pure plumbing): `Metrics`
(10 one-second buckets, `human_bytes` base 1024), `Job_progress` / `Job_report` (the report
line is specified in 07), `Change_notice` (the `changed` line is specified in 07; 0.2 s flush,
512 keys per batch), `Log` (levels debug < info < warn < err, default `info`, `recent ()` keeps
the last 50 warn/err newest first, `Daemon.init` logs to syslog facility DAEMON ident `tsync`
with LOG_PID and LOG_PERROR only on a tty, else stderr as `YYYY-MM-DD HH:MM:SS LEVEL msg`),
`Field_spec` (config field specs: `bool` accepts true/1/yes/on and false/0/no/off
case-insensitively, else the default; `mask` renders a set secret as `***`), `Tls_conf`
(`available`, `current`, `apply`), `Desktop_mounts.mount_points` (Linux mountinfo parsing with
octal escapes and `fuse.*` types sourced `tsync`; total, for a C caller), `Runtime`
(`default_paths`, socket paths, `restart_service`, `log_command`).

### B.3.2 In-memory formats (implementation choices, not contracts)

- **`Hashtbl_mmap`**: a blob region (file-backed shared mapping of an unlinked temp file,
  initially `max 4096 (64·n)` bytes, doubled with `ftruncate` + remap) of appended records
  `[u32le klen][u32le vlen][key][value]`, and a slot array (anonymous int64 Bigarray, power of
  two ≥ `max 16 (2·n)`) holding `offset + 1` (0 = empty). Linear probing from
  `Hashtbl.hash key land mask`; slots double when `4·count > 3·slots`, rehashed from slots.
  `replace` always appends; superseded records are never reclaimed, so heavy rebinding grows
  the blob. No removal.
- **Durable-queue record ids and claims**: `%020Ld-%08d-%d` (µs since epoch, a per-`Records.t`
  sequence, pid); claim lock `<dir>.owner` held with `lockf F_TLOCK` on an fd kept open. The
  queue's rules are in [../algorithms/durable-queue.md](../algorithms/durable-queue.md).

### B.3.3 Shared mutable state that relies on cooperative scheduling

Every item below is mutated without a lock because Lwt never switches tasks between two
statements without a bind. A runtime with preemption or parallelism must lock or confine each.

| State | Module | Reliance |
|---|---|---|
| `held`, `waiting`, waiter queue; `named` registry; `shared_pools` | Bounded | check-then-act |
| the job source cursor in `each` | Bounded | pop and advance |
| `jobs`, `loaded`, `slots` (`cancel`/`pending`/`failures`), `active`, `parked`, `outcomes`, `failures`, `degraded`, `running`; `owned`, registry and rescan lists; `Records` `seq`, `dropped` | Durable_queue | lock-free mutation; the `recording` mutex only orders writes |
| every field of a `Health.t`; watcher table | Health | read-modify-write; single probe hand-out |
| `hooks`, `requested_`, `next_hook` | Shutdown | idempotent flip and hook drain |
| buckets, totals | Metrics, Job_progress | increments |
| `job`, `ticks`, `live`, `stop`, `warned` | Job_report | flags |
| subscriber list and queues; `woken` in `serve` | Ipc | empty-check-then-wait; double-resolve guard |
| `cache` (pool generation) | Http_client | compare-and-replace |
| `table`, `pending`, `scheduled`, `warned` | Change_notice | set plus scheduled flag |
| `recent_q`, `min_level`, `prefix`, sink | Log | push/pop |
| `clonable` memo, `warned_no_clone` | Bigstring | memo |
| PRNG state | Id | not thread-safe |
| `temp_seq` | Filename | increment |
| blob, slots, count | Hashtbl_mmap | not thread-safe by design |
| TLS backend | Tls_conf | set once |
| `resolved_chunk_size` | Remote | set once |

`lockf` claims are per process, so the in-process `owned` table is the only thing that stops two
threads of one process double-claiming.

### B.3.4 Where the code departs from the spec

Each item is a place where the OCaml code at the time of writing does something the spec
forbids or does not require; the spec section says what is correct.

- **Glob (§17).** `Glob.match_from` tries the rest of a pattern after `**/` at every character
  offset, not only at segment starts, so `**/.git` matches `foo.git` and `a/repo.git`. `**`
  inside a segment crosses `/`. Only `tsync import --only/--exclude` uses it
  (`lib/domain/ops/import.ml`), matching each pattern against the path and its basename.
- **Clocks (§4).** `Io_lwt.Clock.now` is monotonic (`CLOCK_MONOTONIC` stub), but
  `Io_lwt.Clock.with_stall_timeout` (behind `Http_client`), `Health.now` and `Metrics.now_sec`
  use `Unix.gettimeofday`.
- **Stall timer (§10).** The timer is reset after headers are built and on each response body
  piece; bytes of the request body going out are not heard.
- **Breaker evidence (§8, failure model §6).** `Retry.with_retry` calls `Health.lost` on every
  `Transient` failure, which includes 429, 503 and unclassified exceptions inside a request;
  `Retry-After` is not read.
- **Absent versus failed (§6.4).** `Fs.read_file_opt` answers `None`, `stat_opt`/`is_directory`
  answer `None`/`false`, `lstat_kind` answers `` `Missing ``, and `readdir_list_quiet` answers
  `[]` on any failure.
- **Validation (§2.1–2.2, §2.7).** `Stored_key.listed` is the identity; no layer checks key
  segments; domain names are not validated in `Conf_parsing`; `Item_ref.parse` accepts any
  non-empty id and a leaf containing `/` (everything after the first `/`), and a `` `Bad ``
  reference is answered `not_found`.
- **Mirror escape collisions (§2.8).** Two unstorable leaves with the same seed-0 hash share a
  handle; nothing checks.
- **Chunk size bounds (§3.5).** No clamp on a configured or store-recommended chunk size, and
  none on a manifest's chunk size when reading.
- **Random ids (§2.10).** `Id.short` falls back to pid and time when `/dev/urandom` is
  unreadable.
- **Snapshots (§12).** When cloning fails in a directory, `Bigstring.open_snapshot` maps the
  live file (warning once per process), so a concurrent truncate is a SIGBUS.
- **Directory watch (§14.3).** On macOS kqueue cannot report names, so `Watch.drain` cannot
  discard the reader's own scratch files and the self-wake loop remains there.
- **IPC (§11).** `serve` runs one task per connection with no bound, reads lines with no length
  limit and no partial-line deadline, and swallows per-connection exceptions. `Ipc.send` (the
  CLI's blocking call) has no timeout and leaks its fd on an exception.
- **Spool.** `Spool.create ~dir ~name` names the file `dir/.tsync-tmp-<pid>-<n>.tmp`; `name`
  does not appear in it. `Spool.seal` uses a non-LargeFile `stat` (fine on 64-bit only).

### B.3.5 Hosts

How each host instantiates this layer (process roles are specified in 07):

| Host | Uses / swaps |
|---|---|
| Linux daemon | syslog via `Log.Daemon.init`, log prefix `"[<domain>] "`; raises the fd limit to 8192 before forking frontends; `Shutdown.request` on unmount or signal; recovering durable queues; `rescan_all` when a one-shot command leaves work behind |
| macOS daemon | one process for all domains on `tsync.sock` in the app-group container; syslog with LOG_PERROR into `~/Library/Logs/tsync-daemon.log`; fd limit raised from launchd's 256 |
| Android | runtime embedded in the app; `Log.set_sink` to logcat first; Lwt blocking-call pool capped at 16 threads; everything reachable from JNI total |
| http-proxy frontend | one listener for all its domains; reports `Log.recent ()` over HTTP; `Zip_stream` for share downloads |
| one-shot commands | blocking `Ipc.send`/`request`; queues started without recover (claiming their dirs); `Job_report` every 10 s; `settle_all` (≤ 60 s) and `Change_notice.settle` before exit |
| Linux file-manager extensions | `Desktop_mounts.mount_points` across a C boundary |
| tests | Clock/Files/Send/Pool/Transport doubles; `Shutdown.reset`, `set_stall_warning_interval`, `Health.expire` |

### B.3.6 Resource strategies (implementation choices, not spec)

Spec P6 leaves these to the implementation. What the OCaml code does, and why:

- **Pools (`Bounded`).** A pool stands for a resource (memory for bodies, round trips in
  flight, a device's command queue), not a kind of work; its width belongs to whoever knows what
  shares that resource. `acquire` takes a slot if fewer than `width` are held, else answers
  `Busy` if a `max_waiting` cap is reached, else waits; `release` hands the slot straight to the
  oldest waiter (FIFO, no barging). Widths below 1 become 1. `each ~width next` runs `width`
  workers pulling `next ()`; the first failure stops them and is re-raised. Named pools report
  `(name, in flight, waiting, width)` to status, summed by name. Habits worth keeping: take the
  slot before the resource it guards; never wait for a slot of a pool you already hold one of
  (the mirror's probe-then-copy deadlocked that way); pull workers for data-sized sources rather
  than a promise per element (mirror memory went from 140 to 16 words per object). A
  scheduler-wide bound is not a substitute: it bounds concurrency, not working set.
- **HTTP sockets.** At most 32 sockets per endpoint, idle ones closed after 60 s
  (`keep_idle_ns`, `max_parallel`); the work bound is the caller's pool.
- **Spills.** `Spool` appends to a temp file, closes it, then maps it (mapping a file still open
  for append is unsound); `Listing` records are fields of int32-LE-length strings and 8-byte LE
  int64s, re-walkable, refusing appends after sealing; `Hashtbl_mmap` (B.3.2) keeps data-sized
  key sets off the heap. Spools of dead processes are reaped by pid.
- **Device concurrency.** `Device.max_concurrency`: on Linux the queue depth of the block device
  under the mount (`device/queue_depth`, else `queue/nr_requests`, of the whole disk for a
  partition), as `max 2 (min 64 (4·depth))`; on macOS by `df -P` + `diskutil info`: rotational
  over USB/FireWire 4, rotational 8, SSD over USB 16, SSD 64, unknown external 8. Asked once per
  store. USB mass storage takes one command at a time; NVMe hundreds.
- **Descriptor limit.** `Descriptors.raise_to ~target` clamps to the hard limit and halves the
  request until `setrlimit` accepts it (launchd starts processes with 256; the Linux daemon asks
  for 8192 before forking frontends).
- **Watch drain.** `TSYNC_WATCH_DRAIN_PASSES = 64` reads per wake.
- **Metrics.** Rates over 10 one-second buckets.
- **Advisory IPC sends.** `Ipc.Make.send ?timeout = 2.`.

### B.3.7 Further departures from the round-2 spec

- A local-filesystem store uses the shared `Health.always_up` cell, so a stale NFS mount never
  trips and network-filesystem errnos are not classified as link failures.
- The local store writes pid-form temporaries (`.tsync-tmp-<pid>-<seq>.tmp`) and can list
  directory keys; the spec's store uses random-form temporaries and lists no directory markers.
- `Bigstring.open_snapshot` is used for every mapped read; the spec only requires snapshots for
  files that can change in place.
