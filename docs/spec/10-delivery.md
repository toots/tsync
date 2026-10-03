# 10 — Delivery (as `main` builds it)

This file restates the continuous integration and release workflows of `main` as they are, defects
marked **[defect]**. The next commit rewrites it as the normative spec; the diff between the two is
the review. The stress workflow is left out.

---

## 1. Workflows

| Workflow | Trigger | Jobs |
|---|---|---|
| `test` | push to `main`, every pull request, the merge queue; a newer run for the same ref cancels the older | `lambda-s3`, `lambda-gcs`, `linux`, `macos` |
| `conformance` | manual dispatch only: per push it dominated the CI object-store spend | `conformance` |
| `release-deb` | `test` completing successfully on `main`; manual dispatch | `deb`, a 2×2 matrix of image and architecture |
| `release-rpm` | as `release-deb` | `rpm`, a 2×2 matrix |
| `release-macos` | as `release-deb` | `macos` |
| `release-android` | as `release-deb` | `apk` |
| `release-repo` | `release-deb` or `release-rpm` completing on `main`; manual dispatch | `publish` |
| `test-android-device` | manual dispatch, or the `android-device` label on a pull request | `emulator` |

## 2. `test`

- **lambda-s3**: the Python share handler and chunk verifier against a mocked S3 (`moto`), then two
  cross-implementation checks: the chunk key the verifier computes, and the delete-request key it
  parses, each compared with a golden file the OCaml suite generates
  (`tests/unit/hash/hash.expected`, `tests/unit/gc_job/gc_job.expected`). If the two disagree the
  verifier files every chunk as corrupt, or ignores every delete request.
- **lambda-gcs**: the store and verifier tests against `fake-gcs-server`.
- **linux**: installs system libraries, installs the OCaml dependencies of every package through
  `scripts/opam_deps.sh`, builds, runs `dune test`, then the FUSE end-to-end test (`make -C linux
  e2e`, a real mount and a second client under a scratch directory), then the Android unit and IPC
  contract tests (Gradle) against the daemon this job built.
- **macos**: installs Homebrew libraries, the OCaml dependencies through the same script, builds, runs
  `dune test`, then builds the Swift targets unsigned and runs their tests, whose protocol tests start
  the daemon built above against a local store.
- **[defect]** No job declares a timeout; a hang holds the runner until the platform's six-hour cap.
- **[defect]** The packaging steps are not exercised before merge: a change that breaks a `.deb`,
  `.rpm`, `.pkg` or `.apk` is found only by the release run after it lands on `main`.

## 3. `conformance`

- One job, against the real GCS and S3 buckets, because a run works under a prefix named after the
  run id and a second job would sweep the first one's objects.
- Skipped on pull requests from forks, which receive no secrets.
- Fails naming every missing required secret and the script that provisions them
  (`scripts/setup_ci_secrets.sh`). The bucket-side verifier function is optional: without it the
  suite reports that half "not run".
- **[defect]** Nothing runs it before a release: a driver regression against the real services is
  found only when someone dispatches it.

## 4. Builds and dependencies

- `scripts/opam_deps.sh <packages>` pins the checkout, updates and upgrades the switch, and installs
  the named packages' dependencies. Every job of `test`, `conformance` and `release-macos` calls it.
- setup-ocaml caches only the compiler; each job additionally restores and saves its own switch,
  saving right after the install so a failed job neither loses the cache nor saves a half-built one.
  The macOS key includes the Homebrew versions of the formulae the switch links against, since a
  bumped formula moves its Cellar directory and breaks the restored link.
- The container-based Linux release jobs build through `linux/build.sh`, which creates the switch,
  updates, upgrades and installs its own package list, cleans the switch and builds with the release
  profile. **[defect]** A second spelling of the dependency installation rule.
- `release-android` installs a cross toolchain and a hand-written package list from an
  `opam-cross-android` branch, keyed on the workflow file.
- **[defect]** No build asserts that an optional component (the FUSE frontend, a TLS
  implementation) was built; an optional library whose dependency is missing is skipped silently.

## 5. Releases

- Every release workflow checks out `workflow_run.head_sha`, so it builds the commit `test` passed.
- **deb, rpm**: containers of Debian 13 and Ubuntu 26.04, or Fedora 43 and 44, on amd64 and arm64;
  `linux/build.sh`, then the package script, then an install test of the package (`verify.sh`), then
  the nightly publish. Each ships `tsync` and the KDE tray `tsync-tray`.
- **macOS**: Homebrew and OCaml dependencies, signing assets imported from secrets into a throwaway
  keychain whose keys every tool may use without a prompt, `package.sh` (build, sign, `pkgbuild`,
  notarize, staple), then the nightly publish. `CFBundleVersion` is the run number. Timeout 60
  minutes.
- **Android**: cross-builds the JNI library, unpacks the signing keystore from a secret (failing when
  absent), builds the release APK, and refuses an APK not signed by the tsync key, since a different
  key makes every phone reinstall. Timeout 120 minutes.
- **nightly**: one rolling prerelease. The shared action `publish-nightly` creates it if missing,
  tolerating the race between release workflows, and replaces the artifacts it is given.
- **repositories**: `release-repo` rebuilds the apt and dnf sites from the nightly release, signs
  them, checks that `tsync` and `tsync-tray` install from them, and deploys to Pages. Serialised and
  never cancelled. **[defect]** A manual dispatch from any branch deploys that branch's site.
- Release workflows each have their own concurrency group, serialised and not cancelled.

## 6. Device tests

`test-android-device` boots an x86_64 emulator, refuses a checkout carrying arm64 native libraries
(they would make the test APK uninstallable), grants media permissions from the script, runs the
instrumented suite, and fails when the reports count zero tests, because the runner reports success
when no device matched.
