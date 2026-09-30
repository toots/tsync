# OCaml implementation notes

These notes are for someone re-implementing tsync **in OCaml**. They record what the current
code learned. The language-neutral spec is in the parent directory; each note names the spec
concept it implements.

The current code runs on Lwt, with the logic written as functors over a small concurrency
signature and applied once per process under `lib/lwt/`. A rewrite may use OCaml 5 effects and
domains in direct style instead, so that pattern is itself an implementation detail. Every file
therefore separates two kinds of note:

- **Runtime-independent** (B.1 / B-I): still valid under OCaml 5 direct style. C stubs and the
  runtime lock, EINTR surfacing as `Sys_error` strings, bigarrays and `mmap`, per-process `lockf`,
  randomness after `fork`, totality at FFI boundaries (JNI, shared objects), dune `select` /
  `enabled_if` / optional libraries, cross-compilation, type-level guards.
- **Lwt- and functor-specific** (B.2 / B-II): what the functor and the monad solved and what they
  cost, each translated to its effects/domains equivalent where possible.

| Subsystem | Notes |
|---|---|
| Foundation, the concurrency signatures and the Lwt binding | [01-core.md](01-core.md) |
| Remote data model | [02-remote-model.md](02-remote-model.md) |
| Journal & sync | [03-journal-sync.md](03-journal-sync.md) |
| Checkout & cache | [04-checkout-cache.md](04-checkout-cache.md) |
| Config & whole-domain ops | [05-ops-config.md](05-ops-config.md) |
| Backends | [06-backends.md](06-backends.md) |
| Daemon & CLI | [07-daemon-cli.md](07-daemon-cli.md) |
| Frontends (FUSE binding, KIO plugin via shared object) | [08-frontends.md](08-frontends.md) |
| Test harness mechanics and dune traps | [09-tests.md](09-tests.md) |
| Backend drivers | [local](backends/local.md), [s3 and object-store common](backends/s3.md), [gcs](backends/gcs.md), [http-proxy](backends/http-proxy.md) |
| FUSE (libfuse binding, KIO plugin via shared object) | [frontends/fuse.md](frontends/fuse.md) |
| http-proxy server | [frontends/http-proxy.md](frontends/http-proxy.md) |
| macOS (platform and QuickLook stubs, the accept-loop failure) | [frontends/file-provider.md](frontends/file-provider.md) |
| Android (cross-compilation, JNI, embedding the runtime) | [frontends/android.md](frontends/android.md) |

## The lessons that matter most

1. **The monad marks every yield point, and the code relies on it.** With no `let*` between two
   statements, nothing else runs between them. Pools, durable queues, health tracking, memo
   tables and debouncers change shared state without locks because of that. Under effects, any call
   may yield; under domains, nothing is atomic. Each spec file's §6.1 lists the affected state. Audit
   those lists before choosing a runtime. ([01 §B.2.5](01-core.md))
2. **Bound fan-outs by construction.** An unbounded `Lwt_list.map_p` over a data-sized list is the
   same trap as an unbounded `Fiber.List.map`. Take pool slots before the resource. Never nest a pool
   inside itself. ([01](01-core.md), [05](05-ops-config.md))
3. **Applying a functor once is what makes its registries process singletons.** Under direct style
   they become top-level values. Under domains they also need `Mutex`, `Atomic` or `Domain.DLS`.
4. **Positioned I/O stubs block the loop under Lwt.** Under Eio, run them in a systhread or use
   io_uring.
5. **An exception escaping into C kills the host process.** Everything reachable from JNI or a
   shared object must be total. ([08](08-frontends.md), [frontends/android.md](frontends/android.md))
6. **dune can report success having done nothing.** Cached test actions replay with `--force`, and
   `dune build` does not compile the scenario runner. A failing scenario step can still exit 0.
   ([09](09-tests.md))

## Migration order, if moving off Lwt

This order comes from an earlier exploration of the scheduler seam. Details are in
[01 §B.2.5](01-core.md).

1. Make the concurrency interface direct-style while still on Lwt.
2. Move HTTP off cohttp-lwt. This is the expensive part: cohttp, conduit, the S3 client, and
   `lib/app` with its direct Lwt references.
3. Swap the scheduler outright. Never run two schedulers permanently.

Keep bounded pools regardless. Assume one main worker plus blocking threads until every item on
the §6.1 lists has been made domain-safe.
