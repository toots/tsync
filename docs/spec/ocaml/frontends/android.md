# Android application — OCaml implementation notes

Companion to the language-neutral spec [../../frontends/android.md](../../frontends/android.md). See [README.md](../README.md) for how these notes are organised.


Section numbers in parentheses (§n) refer to the spec.

## B-0. Where the current code departs from the spec

The code at `4c32fa96` (Kotlin under `android/`, OCaml under `lib/app/frontends/android/`) differs from
the normative spec in these places. Each is a change to make.

- **No ownership lock (§2).** Nothing takes a per-domain lock; the desktop `tsync android` verbs never
  forward to a running owner.
- **Deferred work never resumed (§3.1).** `load_domain` in `jni/android_jni.ml` calls
  `Domain.of_config` without `~resume`, so `Deferred.make` claims the deferred directory with
  `recover:false` and never rescans; nothing calls `Domain.start_resumed`. Records a killed process
  left in `deferred-pending/<domain>/<target>` are never read again.
- **Owed metadata freezes a folder (§3.2).** `Lazy_checkout.list_children` skips the pull when
  `owed_under` finds a pure-metadata WAL record naming a direct child, and pulls nothing then. A record
  that keeps failing (retried with no cap: `attempts` is incremented, never checked) hides peers'
  changes in that folder indefinitely. Opens do not re-read the manifest; no listing is refreshed while
  displayed; no platform notification is sent after pulls or mutations; an unreachable store fails a
  listing even when the folder was pulled before.
- **Trust store (§4.2).** `ca-bundle.pem` is built once and never rebuilt.
- **Handles (§5).** A handle records `{key, size-at-open}` and reads by key, so a rewrite while open
  serves new bytes with the old size. The handle table (`Hashtbl`) is touched from the host thread
  outside the loop (B-II.1 item 6).
- **Error codes dropped (§6).** `Cli.reply` throws `Error(error)` without the code; `Ingest.children`
  turns every error into "no children", `queryChildDocuments` reports every failure as unreachable.
- **Unpaged child lookups; no exclusive creation (§6).** `Ingest.children`, `childRef`, `folderFor`,
  `freeName` and `TsyncProvider.childRef` read one `list_dir` page (default 1000) and never follow
  `next`; `freeName` then picks a taken name and `write` replaces it. The app ignores the `item` in
  mutation replies and re-lists. `freeName` + `commit` is check-then-act across requests.
- **Cleartext allowed; Auto Backup on (§7).** `android:usesCleartextTraffic="true"` (the manifest
  comment: the native core reaches plain-http LAN proxies whatever the platform says), and the form
  accepts `http://`. No `allowBackup`/backup rules exist, so Auto Backup copies
  `filesDir/.config/tsync/config.json` with its secret.
- **`isChildDocument` (§8).** `isChildOf(ref, id) = ref.startsWith("f:$id/") || ref == "d:$id"`
  (`core/.../Cli.kt`): every subfolder is rejected, so tree grants reach only the top level.
- **Picker writes and share saves are not crash-safe (§8, §9.2, §11.1).** There are no ingest intents;
  a process death between a clean close and the commit leaves an orphan the 24 h sweep deletes. The
  share activity finishes before committing.
- **Folder evict/restore are no-ops (§11.2).** The hooks are `E.F.evict` and `E.F.ensure_cached` on one
  key (a `ponytail:` comment defers the subtree walk); on a directory key nothing happens and the toast
  still says it worked.
- **Camera backup (§13).** Schema v2 has states `DONE`/`FAILED` only; `attempts` is never written.
  `BackupSweep` reads the volume generation once before its queries and stores it unconditionally when
  the volume finishes, so on API ≥ 30 an unsettled row or a failed upload is never returned by the next
  `GENERATION_MODIFIED > generation` query, and nothing re-reads `FAILED` records. First uploads replace
  whatever holds the name. `newestAdded` puts `LIMIT 1` in the sort order (rejected by recent
  MediaProvider versions); "From now on" runs on the UI thread before the permission request, so below
  API 30 it can leave `dateAdded` 0 and back everything up. `BackupSweep` loads the domain name only to
  bail out without a config.
- **Stale wording.** `Config.MAX_DOMAIN_LENGTH` (32) is justified by a socket path that no longer
  exists; the domain grammar belongs to 01-core. `test-android-device.yml` mentions "Ipc's LocalSocket".
  A local `jniLibs/.../libtsync.so` from the exec'd-binary era may linger (gitignored).

### Local app state as the code stores it

| Store | Content |
|---|---|
| `<filesDir>/staging/<epochMillis>-<uuid>` | staging bodies |
| `<filesDir>/ca-bundle.pem` | from `/apex/com.android.conscrypt/cacerts` (Android 14+) else `/system/etc/security/cacerts` |
| SharedPreferences `camera-backup` | `enabled` (false), `unmeteredOnly` (true), `whenBatteryOk` (true), `lastOutcome`, `settled` |
| SQLite `camera-backup.db` v2 | below |

```sql
CREATE TABLE media (media_id INTEGER PRIMARY KEY, volume TEXT NOT NULL,
  relative_path TEXT NOT NULL, size_bytes INTEGER NOT NULL,
  modified_seconds INTEGER NOT NULL, state TEXT NOT NULL,   -- 'DONE' | 'FAILED'
  attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT, updated_at INTEGER NOT NULL);
CREATE UNIQUE INDEX media_path ON media(relative_path);   -- relative_path = the domain target
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
  -- 'watermark.<volume>.generation', 'watermark.<volume>.dateAdded'
CREATE TABLE dirs (path TEXT PRIMARY KEY, ref TEXT NOT NULL);
```
All writes are `INSERT OR REPLACE`; an upgrade drops and recreates only `dirs`. The spec's record
(§13.2) fits v2 additively: `PENDING`/`BASELINE` go in `state`, `ALTER TABLE media ADD COLUMN` adds a
nullable `etag` and `next_attempt_at`, and `meta` gains `volume.<volume>.version` and
`fullDiscovery.<volume>` keys beside the existing watermark keys, which are kept and used as the mark.
`media_id` stays the key, as in v2. v2 rows
need no rewrite; v2 code reading a v3 row sees an unknown state as `FAILED`.

### Resource choices the spec leaves to the implementation

Four fixed `tsync-pfd-*` callback threads serve proxy descriptors, assigned round-robin per open, so
at most four reads are in flight app-wide; the browser lists pages of 200 and the provider walks pages
of 500; a camera pass stops when 512 MiB of staged bytes are owed; the blocking-job pool is capped at 16
(B-II.1 item 5). The trust bundle is built from `/apex/com.android.conscrypt/cacerts` or
`/system/etc/security/cacerts`, which hold system authorities only, as the spec requires; a private
authority comes from the backend's explicit config, never from user-installed certificates.

### Where the §15 properties are checked today

`tests/frontends/android` (spawned, one process per call, full-reply snapshots), `android_lazy`,
`android_bridge` (linked in, 8 foreign pthreads × 64 reads); `CliProtocolTest` (JVM, drives
`tsync android request`); JVM unit tests `KeysTest`, `OpenDescriptorsTest`, `PhotoNamingTest`,
`BackupPlannerTest`, `UploadRecordsTest` (Robolectric); device-only `MediaScanTest` (emulator, opt-in).
Every gradle test task fails if it executed zero tests; the device workflow fails if the reports count
zero tests. Not covered: anything in B-0.

Split in two: **B-I** holds learnings that stay valid whatever the concurrency runtime
(Lwt today, OCaml 5 effects/domains in a rewrite); **B-II** holds what is tied to Lwt and
the functor style, each with what it becomes under effects/domains. The pivotal topic —
how host (JNI) threads meet the scheduler — has a runtime-independent part (B-I.2) and a
Lwt-specific part (B-II.1).

## B-I. Runtime-independent learnings

### B-I.1 Embedding the runtime as a shared object (implements §4.1, §5)

- **Shape**: private library `tsync_android_jni` (`android_jni.ml` + `tsync_bridge.c`)
  plus executable `libtsyncjni` in `(modes shared_object)` holding `tsync_jni.c` (JNI
  marshalling only), enabled only in context `default.android`. `libtsyncjni.ml` forces
  linkage and installs the log sink; entry points self-register at module init with
  `Callback.register "tsync_jni_{check_config,boot,request,status,open,size,read,close}"`;
  C looks each up once with `caml_named_value` and caches the pointer.
- **Why `shared_object`, not `object`**: `(modes object)` links the runtime without
  `-fPIC`, which a shared library cannot hold (memory note
  ocaml-shared-object-for-plugins). Dune sets no soname and names the output after the
  executable, so `-Wl,-soname,libtsyncjni.so` and the executable name must agree: the
  loader searches by soname, and a mismatch fails at `dlopen`, not at link.
- Link flags: `-L%{ocaml-config:standard_library}/..` (lwt_unix records `-lev` and the
  cross sysroot's lib dir is not on the linker path — a transitive C dep, would apply to
  any library recording `-l`); `-Wl,-z,max-page-size=16384` (Android 15 uses 16 KB pages
  and rejects 4 K-aligned libraries); `-llog` (else `__android_log_write` is undefined
  and the failure shows at `dlopen`).
- **Runtime start is lazy**, in `ensure_runtime` on the first JNI call
  (`nativeCheckConfig` or `nativeInit`): `setenv HOME`, `setenv SSL_CERT_FILE`, **then**
  `caml_startup`. Module initialisers derive every path from HOME as they run, and a
  `Sys.getenv` raising there is `exit 2` to an unread stderr. `runtime_started` is
  unguarded C state, safe only because the Kotlin callers (`Native.ensure`,
  `Native.checkConfig`) are `@Synchronized`. The other entry points assume the runtime is
  up (Kotlin always calls `ensure` first); a rewrite should make that a checked
  precondition.
- **Totality**: every OCaml function reachable from C catches everything
  (`guard`, `try … with`) and answers a reply / error string / `-errno`. An exception
  crossing into C kills the host process, and an app has no supervisor.
- **Marshalling**:
  - Strings cross as `byte[]`: JNI `jstring` is modified UTF-8, which cannot carry
    non-BMP characters, and `NewStringUTF` on such bytes is a JNI abort.
  - `string_of_bytes` allocates an OCaml string under the runtime lock and copies with
    `GetByteArrayRegion`; replies are copied out with `SetByteArrayRegion` while still
    holding the lock (the OCaml value cannot move; that JNI call allocates nothing on the
    JVM side, so no JVM GC runs mid-copy).
  - Reads allocate a *managed* `Bigarray` of `length` bytes, call OCaml, then copy
    `served` bytes into the Java array. Not `GetPrimitiveArrayCritical`: a critical
    region forbids other JNI calls and would stall the JVM collector for as long as a
    network read takes. Cost: one extra copy per read.
  - Empty OCaml string = success for check/boot, returned to Java as `NULL`.

### B-I.2 Host threads and the OCaml runtime lock (runtime-independent half)

What holds regardless of the scheduler — these are OCaml 5 systhreads/runtime rules:

- Every JNI call arrives on a thread OCaml did not create (binder threads, the 4
  `tsync-pfd-*` HandlerThreads, WorkManager and ad-hoc `thread {}` threads). Before
  touching any OCaml value it must be **registered** (`caml_c_thread_register`) and then
  **acquire the runtime lock** (`caml_acquire_runtime_system`): registration returns with
  the lock released (it ends in a blocking section), so the acquire is not optional.
  Registration failure aborts: an unregistered thread has no `Caml_state` and segfaults
  at its first blocking section instead of raising.
- A pthread key tags each thread: `FOREIGN` (registered by the bridge, owes an
  unregister) or `RUNTIME` (the thread that ran `caml_startup`). The startup thread must
  never be registered — `caml_c_thread_register` answers 0 ("already") and the bridge
  would abort — so `tsync_bridge_init` marks it right after `caml_startup`.
- The key's destructor unregisters a dying foreign thread; without it the dead thread
  stays in the domain's thread list and `caml_thread_scan_roots` walks a C stack that no
  longer exists. Android's binder pool does reap threads, so this is reachable.
- Registration is lazy and per thread (first call), then kept for the thread's life: the
  4 descriptor threads are fixed so each registers once.
- Every entry is bracketed `tsync_enter_ocaml()` … `tsync_leave_ocaml()`
  (`caml_release_runtime_system`) with `CAMLparam0/CAMLlocal/CAMLdrop` inside the bracket.
- Only one thread runs OCaml at a time (one domain). Anything that blocks while holding
  the lock blocks every other host thread; the design below relies on the waiting call
  releasing the lock while it waits.
- **Under OCaml 5 domains** (a rewrite): a host thread still has to be registered with
  *some* domain and hold that domain's lock. If the core runs its scheduler in a separate
  domain, the host thread's work must be handed across domains (e.g. a Mutex/Condition or
  `Domain`-safe queue), and state touched both from the host thread and the scheduler
  domain becomes a real data race (see B-II.1's handle table).

### B-I.3 Log sink (implements §4.1 item 3)

`Log.set_sink` → external `tsync_log_write(rank, msg)` → `__android_log_write`
(DEBUG/INFO/WARN/ERROR, tag `tsync`); on a non-Android build it prints to stderr (the
bridge test relies on that). Installed at library init and again at boot, before
anything that can fail — the loop's dying words included.

### B-I.4 Cross-compilation and packaging

- Toolchain: opam repo `git+https://github.com/toots/opam-cross-android.git#tsync`;
  packages `ocaml-android build-libev-android build-gmp-android conf-libev-android
  cohttp-lwt-unix-android.6.2.2 conduit-lwt-unix-android digestif-android eqaf-android
  yojson-android lwt-android ppx_blob-android mem_usage-android base64-android
  tls-lwt-android x509-android mirage-crypto-pk-android cmdliner-android
  memtrace-android bigstringaf-android` (+ native `ppx_blob`). **`tls-lwt-android`, not
  `tls-android`**: conduit selects TLS by depopt and otherwise links a stub that refuses
  every https connection at *runtime*. OCaml 5.4.1; NDK API 26 (must equal `minSdk`);
  arm64-v8a only.
- Build the context path, not the bare target (the host context would want FUSE):
  `dune build -x android _build/default.android/lib/app/frontends/android/jni/libtsyncjni.so`.
- `SSL_CERT_FILE` must exist even for plain HTTP: conduit builds its authenticator when
  it builds a context, and `ca-certs` only looks at `/etc/ssl` paths Android lacks.
- `tsync-android` is an allow-empty opam package; `lib/app/frontends/dune`
  `(select frontend_android.ml from (tsync-android -> frontend_android.enabled.ml)
  (-> frontend_android.disabled.ml))` compiles the `tsync android …` verbs into the
  desktop binary when the package is present (that is what the JVM protocol test and the
  spawned tests drive). The JNI library is private so it may reach `Domain.of_config`,
  which the shipped `tsync-android` library may not.
- Gradle `:app`: AGP 8.7.3, Kotlin 2.0.21, JDK 17, compile/target SDK 35, min 26,
  `abiFilters arm64-v8a`, `versionCode = $BUILD_NUMBER` (a nightly must outrank the
  previous or install is refused as a downgrade). `stageLibrary` (before `preBuild`)
  copies the dune output into `src/main/jniLibs/arm64-v8a/` (gitignored) and runs NDK
  `llvm-strip` (drops `.symtab`/debug, keeps `.dynsym`, so `Java_*` resolve). A missing
  library skips staging (unit tests need none) unless `-PrequireDaemon` (release job).
- `:core` is a plain Kotlin/JVM module (keys, wire builders, planner, descriptor count),
  `org.json` compileOnly, so the protocol test can exec the real `tsync.exe` on a JVM
  (android.jar would shadow JDK classes the test needs).
- Signing (memory note android-nightly-signing-key): CI decodes `ANDROID_KEYSTORE_B64`,
  password `ANDROID_KEYSTORE_PASSWORD`, alias `tsync`, DN `CN=tsync`;
  `scripts/setup_android_signing.sh` creates the RSA-4096 keystore once at
  `~/.config/tsync/android-release.jks` and sets both secrets (idempotent; replacing the
  key forces every phone to reinstall). Without the env var a release build uses the
  local debug key. The workflow refuses to publish unless `apksigner` shows `CN=tsync`.
  The first release-signed install over a debug-signed one needs one uninstall.
- Local builds on the aarch64 box (memory notes android-local-build-toolchain,
  android-app-typecheck-without-aapt2): JDK 17 at `~/.local/lib/jdk-17.0.20+8`, SDK
  `~/Android/Sdk`, aarch64 adb from Fedora's rpm; aapt2 is x86_64-only, so `:app` cannot
  build — type-check with `K2JVMCompiler` + a stub `R.java`, proving the setup with a
  planted error; `:core:test` runs with `TSYNC_DAEMON=_build/default/bin/tsync.exe`.
  Prefer CI (`gh workflow run release-android.yml`); a full local build once crashed the
  machine.

### B-I.5 Tests (OCaml side)

- `android_bridge` links `tsync_android_jni` and calls the entry points directly;
  `Android_home.adopt` sets HOME/XDG in-process (the runtime reads them), seeding content
  via the spawned CLI first. `tsync_stress.c` releases the runtime lock, spawns 8
  pthreads that call `caml_named_value "tsync_jni_read"` through
  `tsync_enter_ocaml/leave`, joins them while the runtime is up (so each unregisters
  through the key destructor), then reacquires. It proves registration and loop sharing,
  which a test driven only from OCaml threads cannot.
- `android` and `android_lazy` **spawn** one process per call on purpose: an in-process
  test would pass on a frontend that only works as a daemon. Replies are snapshotted in
  full (`.expected`), with the `create` clock and minted folder ids scrubbed.

## B-II. Lwt- and functor-specific learnings

### B-II.1 JNI threads meet the Lwt scheduler (implements §4.1's threading contract)

Current mechanism:

1. `Domain_engine.start_detached` runs `Lwt_main.run` on a `Thread.create`d OCaml
   systhread and blocks the booting JNI thread on a Mutex/Condition handshake until the
   serve body calls `ready ()` (after `init`, i.e. the manifest tree; queue start and
   replay follow on the loop). Nothing joins the loop thread; it ends with the process.
   The absence of a stop is deliberate: `on_loop` must never wait on a finished loop.
2. The serve body ends in `fst (Lwt.wait ())`, a promise that never resolves, which is
   what keeps `Lwt_main.run` turning. The sweep loop that used to sit there kept it alive
   by accident; replacing it with `run_maintenance` (which only schedules `Lwt.async`
   loops and returns) would have let `Lwt_main.run` return and every later JNI call hang
   (`android_jni.ml:91-99`).
3. Each JNI entry runs `Domain_engine.on_loop f` = `Lwt_preemptive.run_in_main f`: the
   host thread (holding the runtime lock after B-I.2) posts `f` to the loop and blocks on
   a condition, **releasing the runtime lock while it waits**, so the loop thread and
   other host threads proceed. The loop thread runs `f` to completion (possibly across
   many network waits), then wakes the caller, which reacquires the lock and marshals the
   reply. So N host threads = N blocked callers, one Lwt loop doing all the work; a slow
   read blocks only its own caller.
4. Exceptions: `on_loop` captures the raw backtrace of non-`Unix_error` failures into
   `With_backtrace (exn, bt)` because `run_in_main` re-raises on the caller thread and
   would otherwise replace the backtrace with its own line. `Unix_error` passes bare (it
   is an answer; ENOENT is the hot path).
5. `Lwt_unix.set_pool_size 16` bounds the blocking-job pool (Lwt never shrinks a pool,
   so it is a memory floor; `Frontend.cap_blocking_pool`'s server range starts at twice
   that). `Frontend.use_libev ()`: the select engine cannot watch fds ≥ `FD_SETSIZE`.
   `Lwt.async_exception_hook` is replaced by a logger — the default ends the process.
6. Hazard: the handle table (`Hashtbl`) is written inside `on_loop` (open) but read by
   `size` and mutated by `close` directly on the host thread under the runtime lock. With
   systhreads a thread switch can happen at an allocation/poll point, so these accesses
   are not formally atomic w.r.t. the loop thread. Low risk (tiny critical sections) but
   a rewrite should route them through the loop or a mutex.

What it becomes under OCaml 5 effects/domains:

- `run_in_main` → an explicit hand-off: the host thread enqueues a job + a one-shot
  result cell on a thread-safe queue owned by the scheduler and blocks on a
  Mutex/Condition (or `Domain`-safe promise), releasing the domain lock (a blocking
  section) while waiting. If the scheduler lives in **another domain**, the host thread
  must be registered with the domain it runs OCaml in, and the result must be published
  with proper synchronisation (Atomic/Mutex) — cooperative Lwt no longer hides races.
- The "never-resolving promise keeps the loop alive" becomes "the scheduler's main fiber
  awaits a stop that never comes"; the trap (the loop exits when its last fiber finishes)
  is the same.
- The per-handle read-ahead stream (§5) is still needed; with real parallelism the
  read-ahead table and handle table need locks.
- The 4-callback-thread bound (Kotlin) still caps concurrent reads; the blocking pool of
  16 becomes whatever bounds blocking syscalls (a semaphore around a thread pool, or
  domain-local effects handlers for I/O).
- The monad no longer marks yield points: anything that was safe "because no `let*` lies
  between read and write" (e.g. the handler's refs, the handle counter `incr last_handle`
  inside the loop) needs review.

### B-II.2 Functor wiring

- `Android_frontend.Serve (E : Domain_engine.S) (C : Conf_lwt.S)` holds `hooks`,
  `request` (`E.Ih.handler hooks req`, continuation dropped) and `status`
  (`Diagnostics.Make(C).domain_json` → `Status_report`). The linked runtime and the CLI
  verbs both instantiate it, so neither is a second implementation of the handler.
- The engine is `Domain_engine.Make_over (Lazy_checkout_lwt) (C)`: the tree choice moved
  from a fixed binding in `file_lwt` to whoever builds the engine (commit 661d4974), so
  the pulled tree is a functor argument rather than a flag.
- `boot` builds the engine as a first-class module stored in a global ref
  (`engine : (module Domain_engine.S) option ref`) plus a record of closures
  (`served : {request; status}`); each JNI call unpacks it. Functor instantiation happens
  inside `boot` because the config (a `Conf_lwt.S` module) is only known at runtime.
  Under direct style this becomes a plain record/object built from the config.
- CLI `Make(C).run ~staging f`: sets the async hook, then
  `Lwt_main.run (start_queue-or-init; f; drain)`. `staging = Ipc_handler.mutates req` —
  the handler owns the list of mutating actions, so the frontend never restates it.

## B-III. History worth knowing

- Aug 2026: the app ran a daemon, which Android reaped (1ba3f1bb); then exec'd the binary
  per call. 47040bc1 linked the runtime for reads (per-invocation reads had an empty
  read-ahead table, so prefetch never fired). cc90f688 moved every request onto the
  linked runtime: exec'd writes and the linked upload queue were unordered, since Lwt
  mutexes only order within one process.
- e46e2286: draining after each change used `Q.stop`, which stopped the linked queue at
  the first mkdir; replaced by a per-key `settle_key` behind `await`.
- fa0a4fd5: edit-open used to start empty after a failed fetch (published truncations);
  commit moved off the descriptor handler thread.
- 6195b248: dataSync timeout crash loop (`ForegroundServiceDidNotStopInTimeException`);
  services now stop on `onTimeout`. The manifest merges
  `foregroundServiceType="dataSync"` onto WorkManager's `SystemForegroundService`, else the
  platform throws on the service's own thread, past any catch.
- 661d4974: the replicated mirror was replaced by the pulled tree after a resync wiped
  36,568 manifests and left documentIds unresolvable for 25 minutes.
- a6ba4ace: read-ahead position keyed by reader (handle), not by file.
