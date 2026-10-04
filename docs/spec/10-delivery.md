# 10 — Delivery

Scope: where the checks of [09](09-tests.md) run, what a commit must pass before anything built from
it is published, which artifacts are released and how, and how a build obtains its dependencies.
09 owns what a check is and its tier; this file owns when each tier runs and what it gates.

---

## 1. Principles

- **Nothing is published from a commit that has not passed the gate (§3) on that commit.** A release
  runs after the gate, never alongside it, and builds the commit the gate passed, not the branch head.
- **Packaging is checked before merge.** Every release build and its install test run on every pull
  request and push to the development branch, publishing nothing; a change that breaks a package is red on its own pull request.
- **A job proves what it did** (09 §10.1). A build asserts the components it was meant to contain
  (§4.3); a suite that ran nothing fails; a check missing a credential it requires fails and names it.
- **Each rule has one home.** Installing dependencies (§4.1), publishing to the nightly release
  (§5.1) and provisioning secrets (§6) are each one script or one shared action.
- **A failing job explains itself.** Every job has a timeout far below the platform's cap, and a job
  that fails on state it built keeps that state as an artifact.

## 2. Workflows and triggers

| Workflow | Runs on | Gates | Publishes |
|---|---|---|---|
| `test`, the gate (§3) | every push, every pull request, the merge queue | merging, every release | nothing |
| `conformance` (§3.3) | manual dispatch | nothing automatically | nothing |
| `release-deb`, `release-rpm`, `release-macos`, `release-android` | every pull request and push to the development branch, without publishing; `test` passing on `main`; manual dispatch | — | the nightly release, only for a commit of `main` that passed `test` |
| `test-android-device` (§3.4) | manual dispatch; a pull request labelled `android-device` | nothing automatically | nothing |
| `release-repo` | a package release publishing; manual dispatch on `main` | — | the apt and dnf repositories |

- A newer `test` run for the same ref cancels the older one. A release workflow is serialised per ref
  and never cancelled: a cancelled publish or deploy leaves the release or the site half-written.
- A release is triggered only by a gate run for a push to this repository. A pull request's gate
  run triggers none, whatever its head branch is named: a fork's branch called `main` is not `main`.
- A release triggered by the gate builds that run's `head_sha`. Nothing triggered from a branch
  other than `main`, including a manual dispatch, publishes or deploys.

## 3. The gate

### 3.1 Contents

`test` is hermetic: it needs no secret and runs on forks. It MUST:

1. **Linux**: build everything with the FUSE frontend and both TLS implementations, assert them from
   `tsync build-info` (§4.3), check that the sources are formatted, and run every hermetic check of tiers Pure through Multi-process and the
   Platform tier for FUSE (09 §2), including a real mount driven by file-system calls.
2. **macOS**: build everything, run the same hermetic tiers, then build the Swift targets unsigned
   and run their tests, including the extension-side client against an owner started from this
   build (09 §5.9).
3. **Bucket functions**: run the share handler and chunk verifier tests against an S3 double and a
   GCS emulator.
4. **Cross-implementation vectors** (09 §4.4): check that every second implementation of a format
   (the bucket functions' chunk key and delete-request key) produces the golden values the OCaml
   suite generates. A disagreement makes a verifier file every chunk as corrupt, or ignore every
   delete request.
5. **Android**: build the desktop binary with the `android` frontend, assert it from
   `tsync build-info`, and run the frontend's hermetic checks (09 §5.9: the command group spawned once
   per call, the lazy tree, the bridge called from foreign threads). Then run the app's JVM suites
   ([android-app §12](frontends/android-app.md#12-build)), the wire suite against that binary. No
   device and no cross toolchain: the gate stays fast and runs on forks.
6. **User install**: in a separate job, install `tsync` as a user would (`opam install tsync`) and
   assert the default resolution of the TLS alternative.

### 3.2 What it does not run

The Live store and Whole system tiers (09 §2) are not in the gate: they need credentials, cost
money, or report findings rather than regressions.

### 3.3 Live stores

`conformance` runs the store contract against the real GCS and S3 services, by manual dispatch:
per push it dominated the CI object-store spend. It is one job, since a run works under a prefix
named after the run id and a second job would sweep the first one's objects. It fails naming every
missing required secret and the script that provisions them (§6). The bucket-side verifier function
is optional: without it the suite reports that half "not run". It SHOULD be dispatched before a
driver change is merged.

### 3.4 Android devices

`test-android-device` runs the app's instrumented suite on an emulator: what exists only on a
device (the media store, the documents provider seen through the platform's resolver). It is opt-in,
since an emulator boot costs minutes. The emulator's ABI is not the one the core is cross-built for,
so this suite's package carries no core library, and the job fails if one is staged: its absence is
deliberate, never an accident of the checkout. The job fails when the reports count zero tests.

## 4. Builds

### 4.1 Dependencies

- One script, `scripts/opam_deps.sh <packages>`, installs tsync's OCaml dependencies: it pins the
  checkout, updates and upgrades the switch, and installs the named packages' dependencies. Every
  job that builds tsync calls it with its package list, the container release build included; the
  only exception is the gate's user-install job (§3.1 item 6), whose point is to not use it.
- The Android cross switch is installed by the same script, from the cross-compilation repository
  the workflow registers first; the package list lives in the repository (the dependencies of the
  `tsync-android` package), not in the workflow.
- System libraries are installed by the job, since their package names differ per platform.
- A job MAY restore its switch from a cache: the script's update and upgrade make a restored switch
  hold what a fresh one would. The switch is saved right after the install, so a failed job neither
  loses the cache nor saves a half-built switch. On macOS the cache key also names the Homebrew
  versions of the formulae the switch links against: a newer formula moves its Cellar directory and
  breaks a restored link.

### 4.2 Release builds

- A release ships both TLS implementations, OpenSSL the default, and uses the release profile.
- A Linux release includes the FUSE frontend; a macOS release includes the File Provider app.
- An Android release cross-builds the core for the app's one ABI at the app's minimum platform
  level, from the commit being released, and packages it
  ([android-app §12](frontends/android-app.md#12-build)). The package build fails without it.

### 4.3 Optional components

A build skips an optional library whose dependency is missing, without an error. Every build meant
to contain a component asserts it from `tsync build-info` before it is tested or packaged.

## 5. Releases

| Artifact | Built on | Install test |
|---|---|---|
| `.deb` | Debian stable and Ubuntu latest, amd64 and arm64, in containers | install the package on the image it was built for and run the binary |
| `.rpm` | the latest Fedora release, amd64 and arm64, in containers | as for `.deb` |
| `tsync.pkg` | macOS, Apple silicon | check the package signature and that Gatekeeper accepts the notarized package |
| `tsync-arm64-v8a.apk` | Linux, cross-compiled | check that the package holds the core library for its ABI, aligned for 16 KB pages, and that its signer is the tsync key (§5.4) |

### 5.1 The nightly release

One rolling prerelease, `nightly`. A single shared action publishes to it: it creates the release
when missing (release workflows race to), replaces the artifacts of the same name and records the
commit they were built from.

### 5.2 Repositories

After a package release publishes, `release-repo` rebuilds the apt and dnf repositories from what the
nightly release holds, signs them with the repository key, checks that `tsync` installs from them,
and deploys them to Pages. A rebuild is idempotent: two triggers in a row produce the same site.

### 5.3 macOS signing

The signing assets come from secrets into a throwaway keychain whose keys every signing tool may use
without a prompt; a prompt hangs the runner until its timeout. The contents are signed with the
Developer ID Application identity and the package with the Developer ID Installer identity, then
notarized and stapled. `CFBundleVersion` is the workflow's run number. On a push or pull request
without the secrets (a fork), the job builds and tests the app unsigned and reports the signing half
"not run".

### 5.4 Android signing

Every published APK is signed with the one tsync key: a phone refuses a build signed by another key
as an update, and every user would have to reinstall. The keystore comes from secrets; the version
code is the workflow's run number, so each build outranks the one before. The job checks the
certificate of the APK it built against the keystore's and refuses to publish any other. On a pull
request, or without the secrets (a fork), the job builds with a throwaway key, runs the same checks
except the signer's, and reports the signing half "not run".

## 6. Secrets

- Every secret a workflow needs is provisioned by a script in `scripts/`: `setup_ci_secrets.sh` for
  the live stores, `setup_repo_signing.sh` for the repository key and `setup_android_signing.sh`
  for the Android keystore (created once; replacing it forces every phone to reinstall). The macOS signing secrets are
  the exception: their certificate is exported by hand, so `macos/RELEASING.md` states the steps.
- A job that requires a secret fails naming each missing one and its script; a job on a fork, which
  receives no secrets, skips the steps that need them and says so.

## 7. Not delivered

- **Linux tray** (TODO): `main` shipped `tsync-tray` in both packages; the rewrite does not build it.

## 8. Where the workflows depart

- `release-android` and `test-android-device` have never run: neither the cross build on a Linux
  runner nor the instrumented suite on an emulator has been seen passing or failing.
- No check drives a real FUSE mount (§3.1 item 1): the end-to-end FUSE test of `main` was not
  rewritten.
- The bucket-side verifier function is not exercised by `conformance`: the rewritten store tests do
  not read `TSYNC_CI_*_VERIFY_FUNCTION`.

## Conformance

- No artifact on the nightly release or in a repository was built from a commit whose gate failed or
  did not run, or from a branch other than `main`.
- Every release build and install test runs on every pull request and push to the development
  branch.
- Every build that claims a component asserts it from `tsync build-info`.
- Exactly one script installs OCaml dependencies, and every building job other than the user-install
  job calls it.
- Every job declares a timeout.
- A published APK is signed with the tsync key and carries the core library built from its own
  commit; the device suite fails when it ran zero tests.
