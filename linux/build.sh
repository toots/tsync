#!/bin/sh
# Builds bin/tsync.exe in an opam switch, creating it when the CI cache did not
# carry one in. Distro-agnostic: the caller installs the system libraries
# first, since their package names differ. Run from the repo root.
set -eu

SWITCH=${SWITCH:-tsync}
COMPILER=${COMPILER:-ocaml-base-compiler.5.5.0}

export OPAMYES=1
# In a CI container the checkout belongs to another uid, which git refuses to
# read from, and `opam pin` shells out to git.
git config --global --add safe.directory "$(pwd)" 2>/dev/null || true
# Installs a depext the caller missed instead of stopping at a prompt; needs
# root, which the CI containers run as.
export OPAMCONFIRMLEVEL=unsafe-yes

# `config` marks an opam root: a directory half-restored from a CI cache is
# not one. bwrap has no privileges inside a CI container.
[ -f "${OPAMROOT:-$HOME/.opam}/config" ] || opam init --bare --disable-sandboxing
opam switch list --short | grep -qx "$SWITCH" || opam switch create "$SWITCH" "$COMPILER"
eval "$(opam env --switch="$SWITCH" --set-switch)"

# A release ships both TLS implementations, OpenSSL the default.
./scripts/opam_deps.sh tsync tsync-tls tsync-ssl tsync-fuse

# Sources, build trees and logs, which are most of a switch and nothing the
# next run needs: every CI job caches a root, within one budget.
opam clean -y

opam exec -- dune build --profile release bin/tsync.exe

# fuse §2 and 05 tls: a release has the mount and both implementations, and an
# optional library that failed to build would leave it without them quietly.
info=$(./_build/default/bin/tsync.exe build-info)
echo "$info"
echo "$info" | grep -Eq '^frontends:.*\bfuse\b'
echo "$info" | grep -Eq '^tls:.*\bopenssl\b'
echo "$info" | grep -Eq '^tls:.*\bnative\b'
