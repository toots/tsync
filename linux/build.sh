#!/bin/sh
# Builds bin/tsync.exe and linux/tray/main.exe in an opam switch, creating it if
# the CI cache did not carry one in. Distro-agnostic: the caller installs the
# system libraries first, since the package names differ.
# opam's depexts cover the rest -- conf-dbus pulls the dbus headers the tray
# needs, the way fuse3 pulls libfuse3's.
#
# Run from the repo root.
set -eu

SWITCH=${SWITCH:-tsync}
COMPILER=${COMPILER:-ocaml-base-compiler.5.5.0}

export OPAMYES=1
# `opam pin -ny .` shells out to git, and in a CI container the checkout belongs
# to a different uid than the one building, which git refuses to read from.
git config --global --add safe.directory "$(pwd)" 2>/dev/null || true
# Let opam install any depext the caller missed rather than stopping at an
# interactive prompt. Needs root, which is what the CI containers run as.
export OPAMCONFIRMLEVEL=unsafe-yes

# `config` is opam's root marker: the directory alone can exist and be empty or
# half-restored from a CI cache, which opam then rejects as an invalid root.
# bwrap has no privileges inside a CI container.
[ -f "${OPAMROOT:-$HOME/.opam}/config" ] || opam init --bare --disable-sandboxing
opam switch list --short | grep -qx "$SWITCH" || opam switch create "$SWITCH" "$COMPILER"
eval "$(opam env --switch="$SWITCH" --set-switch)"

# tsync-tls and tsync-ssl are the two TLS backends. tsync alone would pull the
# first, and a released build ships both: OpenSSL is preferred at runtime and
# native is what the endpoints OpenSSL trips over fall back to.
"$(dirname "$0")/../scripts/opam_deps.sh" \
  tsync tsync-tls tsync-ssl tsync-s3 tsync-fuse tsync-tray

# Sources, build trees and logs opam keeps for its own convenience, which are
# most of what a switch weighs and none of what the next run needs. The CI jobs
# cache this root, and it has to fit alongside every other job's.
opam clean -y

opam exec -- dune build --profile release bin/tsync.exe linux/tray/main.exe \
  linux/dolphin/ml/libtsync_mounts.so linux/dolphin/ml/libtsync_mounts_fake.so

# The Dolphin plugin, which cmake builds against Qt and KDE Frameworks. Not
# conditional on those being installed: a plugin quietly skipped leaves a
# package built around a file that is not there, and the caller installing the
# system libraries first is what this script already asks for. The mount rules
# come from the object dune just built, named rather than guessed at.
ml=$PWD/_build/default/linux/dolphin/ml
# The prefix has to be named: the packages install through cmake so the rpath is
# rewritten, and cmake's default of /usr/local would rewrite it to a directory
# nothing searches.
cmake -S linux/dolphin -B linux/dolphin/build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DTSYNC_ML_SO="$ml/libtsync_mounts.so" \
  -DTSYNC_FAKE_ML_SO="$ml/libtsync_mounts_fake.so"
cmake --build linux/dolphin/build --parallel
ctest --test-dir linux/dolphin/build --output-on-failure
