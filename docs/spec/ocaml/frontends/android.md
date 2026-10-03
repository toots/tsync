# Android frontend and application — implementation notes

Companion to the language-neutral specs [../../frontends/android.md](../../frontends/android.md) (the frontend) and [../../frontends/android-app.md](../../frontends/android-app.md) (the application). See [README.md](../README.md) for how these notes are organised.

## 1. Where things are

| Part | Place |
|---|---|
| The lazy tree: pull, pull marker, view hold, manifest refresh (04 §3.5, §2.3) | `lib/sync/engine.ml` (`pull`, `pulled_at`, `view_hold`, `hold_views`, `refresh_file`) |
| When to pull, patience, freshness, notices' triggers (android §3.2–§3.3) | `lib/owner/pulls.ml` |
| The handler on a pulled tree (android §6) | `lib/owner/handler.ml`, wherever `t.pulls` is consulted |
| An owner with no socket (07 §3.6) | `Owner.embed`, `Owner.maintain` |
| The bridge, as OCaml calls (android §5) | `lib/frontends/android/android_host.ml` |
| The command group (android §7) | `lib/frontends/android/android_cli.ml` |
| The bridge as C calls from any thread | `lib/frontends/android/jni/tsync_bridge.{c,h}` |
| JNI marshalling, built only for Android | `lib/frontends/android/jni/tsync_jni.c`, `libtsyncjni.ml` |
| The app | `android/`: `:core` (plain JVM logic) and `:app` |

## 2. Decisions the spec leaves open

- **The tree is the frontend's.** `Frontend.t.pulled` carries the refusal text of 08 §2.1, and `Domain.build` derives `lazy_tree` from the domain's frontends. No caller chooses: a desktop one-shot owning an android domain gets the lazy tree too, and cannot replicate into a pulled mirror.
- **Freshness is keyed by folder id**, in a table of the process, on `Rt.now`. A rename keeps it.
- **A pull is detached from its waiter.** `Pulls.start` spawns the pull and hands back a promise; a listing waits on it for `pull_patience`, a mutation likewise, and a waiter that gives up leaves it running. Its completion sends the `changed` notice when the children differ or when a listing was answered outdated meanwhile.
- **What a pull leaves alone.** While any pull's listing is in flight the engine notes the paths local changes and upload commits touch (the table a rebuild uses); the pull's sweep skips them. A staged edit keeps its mirror entry untouched: the publish settles it against the store.
- **"The breaker is open"** means every main member's health cell is down. A double with an always-up cell never takes that path: the tests cover patience and `unreachable`, not the breaker.
- **Notices are a queue**, not an upcall. `Android_host.next_notice` blocks a host thread; the app runs one daemon thread on it. The core never calls into the JVM, so no core thread is ever attached to it, and the sink cannot call back into the bridge. The queue holds 1024 notices and drops the oldest.
- **The log sink is the platform's log**, written by a C stub (`tsync_log_write`), tag `tsync`.
- **`write` with `await`** polls every 100 ms (the engine's `await_upload`) until the staged edit is gone, an upload record of the key or any metadata record is retrying or parked, or the domain is paused.
- **`check_config` with a candidate** crosses the bridge as `domain NUL candidate` in one text argument.
- **Cleartext.** `Transport.cleartext_loopback_only`, set by `Android_host.init`, refuses a connection without TLS to a host that is not loopback; `check_config` and boot refuse a backend whose `url` field says so.
- **Errno** values are Linux's, as constants: the consumer is the Android host.

## 3. Embedding the runtime

- `libtsyncjni.so` is `(executable (modes shared_object))`, enabled only in context `default.android`. Dune names the output after the executable and sets no soname, and the loader searches by soname: `-Wl,-soname,libtsyncjni.so` and the executable's name must agree. `-Wl,-z,max-page-size=16384` and `-llog` are needed at `dlopen`, not at link.
- It links the local and http-proxy store drivers and the OCaml TLS implementation, not the catalog: the app configures nothing else.
- **Runtime start** is in `nativeInit`, under a C mutex: `setenv HOME`, `setenv SSL_CERT_FILE`, then `caml_startup`. Module initialisers derive every path from `HOME`, and `ca-certs` reads `SSL_CERT_FILE`. The bridge's C calls answer `-EIO` or no text until `tsync_bridge_started` ran.
- **Threads.** Every call arrives on a thread OCaml did not create. `enter_ocaml` registers it once (`caml_c_thread_register`, which returns with the runtime lock released), tags it through a pthread key, and acquires the lock; the key's destructor unregisters a dying thread. The thread that ran `caml_startup` is tagged as the runtime's and never registered.
- **Entering the scheduler.** Each entry runs its body with `Rt.run_sync`, which blocks only the calling thread and releases the runtime lock while it waits.
- **Totality.** `android_bridge.ml` wraps every registered closure; C uses the `_exn` callbacks and maps an exception to `-EIO` or no text.
- **Reads** lend the caller's buffer to OCaml as an external Bigarray for the call; JNI copies it into the Java array afterwards, outside the runtime lock, never in a critical region.

## 4. Cross-compilation

- Toolchain: [opam-cross-android](https://github.com/ocaml-cross/opam-cross-android), OCaml 5.4.1 (the desktop build asks for 5.5; the core builds with both), NDK API 26, arm64-v8a. The package list is `tsync-android.opam`.
- `ppx_deriving_yojson` is needed twice: natively, since dune runs the preprocessor in the native context, and as `ppx_deriving_yojson-android` for its runtime. The cross package of `ppx_deriving` drops its standalone driver, which wants `findlib.dynload`.
- Build the context's path, not `-x android` alone: the native context would want every desktop dependency.
  `dune build -x android _build/default.android/lib/frontends/android/jni/libtsyncjni.so`
- Bionic lacks `malloc_trim`, and declares `syncfs` from API 28 only: the stub calls the system call.
- `tls-android` suffices: the core's HTTP client is its own, nothing selects TLS by an optional dependency.

## 5. The app's build

- Gradle wrapper, AGP and Kotlin versions are in `android/`; the daemon runs on JDK 21.
- `stageCore` copies the cross-built library into a git-ignored `jniLibs`, strips it with the NDK's `llvm-strip` when `ANDROID_NDK_HOME` is set, and fails a package build when it is missing. `-PnoCore` builds the device suite's package: no core, every ABI, and a failure when a library is staged.
- `:core` is plain Kotlin/JVM, so the wire suite can spawn a real `tsync` (`TSYNC_BIN`), giving it its config in `TSYNC_CONFIG_JSON`: the desktop binary's config path is per platform.

## 6. Tests

| Suite | Checks |
|---|---|
| `tests/android/lazy_test` | the bridge in-process over a store double that pends or is down, with a peer client: freshness, peers' changes, owed work under a pull, refusals, patience, `unreachable`, recovery, view expiry and holds, notices |
| `tests/android/bridge_test` | 8 foreign threads × 64 reads through `tsync_bridge.h`, entries before boot, a spawned command refused by the host that owns the domain |
| `tests/android/cli_test` | every verb, one spawned process per call, replies in full; registered verbs = driven verbs |
| `android/` `:core:test` | wire shapes against the binary, naming, intents, ingest, config, check server, the backup planner |
| `android/` `:app:testDebugUnitTest` | the record database: schema 3, the upgrade from 2 |

Not checked by any suite: the breaker-open path of a listing, a process kill at each durable step, anything on a device.
