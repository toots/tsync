# 10 — Delivery

Scope: where the checks of [09](09-tests.md) run, what a commit must pass before anything built from
it is published, which artifacts are released and how, and how a build obtains its dependencies.
09 owns what a check is and its tier; this file owns when each tier runs and what it gates.

---

## 1. Principles

- **Nothing is published from a commit that has not passed the gate (§3) on that commit.** A release
  runs after the gate, never alongside it, and builds the commit the gate passed, not the branch head.
- **Packaging is checked before merge.** Every release build and its install test run on every push
  and pull request, publishing nothing; a change that breaks a package is red on its own pull request.
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
| `release-deb`, `release-rpm`, `release-macos` | every push and pull request, without publishing; `test` passing on `main`; manual dispatch | — | the nightly release, only for a commit of `main` that passed `test` |
| `release-repo` | a package release publishing; manual dispatch on `main` | — | the apt and dnf repositories |

- A newer `test` run for the same ref cancels the older one. A release workflow is serialised per ref
  and never cancelled: a cancelled publish or deploy leaves the release or the site half-written.
- A release triggered by the gate builds that run's `head_sha`. Nothing triggered from a branch
  other than `main`, including a manual dispatch, publishes or deploys.

## 3. The gate

### 3.1 Contents

`test` is hermetic: it needs no secret and runs on forks. It MUST:

1. **Linux**: build everything with the FUSE frontend and both TLS implementations, assert them from
   `tsync build-info` (§4.3), and run every hermetic check of tiers Pure through Multi-process and the
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
5. **User install**: in a separate job, install `tsync` as a user would (`opam install tsync`) and
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

## 4. Builds

### 4.1 Dependencies

- One script, `scripts/opam_deps.sh <packages>`, installs tsync's OCaml dependencies: it pins the
  checkout, updates and upgrades the switch, and installs the named packages' dependencies. Every
  job that builds tsync calls it with its package list, the container release build included; the
  only exception is the gate's user-install job (§3.1 item 5), whose point is to not use it.
- System libraries are installed by the job, since their package names differ per platform.
- A job MAY restore its switch from a cache: the script's update and upgrade make a restored switch
  hold what a fresh one would. The switch is saved right after the install, so a failed job neither
  loses the cache nor saves a half-built switch. On macOS the cache key also names the Homebrew
  versions of the formulae the switch links against: a newer formula moves its Cellar directory and
  breaks a restored link.

### 4.2 Release builds

- A release ships both TLS implementations, OpenSSL the default, and uses the release profile.
- A Linux release includes the FUSE frontend; a macOS release includes the File Provider app.

### 4.3 Optional components

A build skips an optional library whose dependency is missing, without an error. Every build meant
to contain a component asserts it from `tsync build-info` before it is tested or packaged.

## 5. Releases

| Artifact | Built on | Install test |
|---|---|---|
| `.deb` | Debian stable and Ubuntu latest, amd64 and arm64, in containers | install the package on the image it was built for and run the binary |
| `.rpm` | the two latest Fedora releases, amd64 and arm64, in containers | as for `.deb` |
| `tsync.pkg` | macOS, Apple silicon | check the package signature and that Gatekeeper accepts the notarized package |
| Android APK | TODO (§7) | — |

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

## 6. Secrets

- Every secret a workflow needs is provisioned by a script in `scripts/`: `setup_ci_secrets.sh` for
  the live stores, `setup_repo_signing.sh` for the repository key, and one per signing identity.
- A job that requires a secret fails naming each missing one and its script; a job on a fork, which
  receives no secrets, skips the steps that need them and says so.

## 7. Not delivered

- **Android** (TODO): no app, APK release or device test exists after the rewrite. When it returns,
  the APK is signed with the one tsync key and refused otherwise (a different key makes every phone
  reinstall), and the device suite fails when it ran zero tests.
- **Linux tray** (TODO): `main` shipped `tsync-tray` in both packages; the rewrite does not build it.

## 8. Where the workflows depart

- `conformance` on the `rewrite` branch is the gate and also runs the live GCS contract on every push.
  §2 splits them: the hermetic gate as `test`, the live stores by dispatch.
- `scripts/opam_deps.sh`, `scripts/setup_repo_signing.sh` and `scripts/setup_ci_secrets.sh` are not on
  the `rewrite` branch, and `linux/build.sh` spells its own installation.
- No release workflow for macOS exists on `rewrite`.

## Conformance

- No artifact on the nightly release or in a repository was built from a commit whose gate failed or
  did not run, or from a branch other than `main`.
- Every release build and install test runs on every pull request.
- Every build that claims a component asserts it from `tsync build-info`.
- Exactly one script installs OCaml dependencies, and every building job other than the user-install
  job calls it.
- Every job declares a timeout.
