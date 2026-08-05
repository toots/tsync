#!/bin/sh
# Builds bin/tsync.exe in a fresh opam switch. Distro-agnostic: the caller
# installs the system libraries first, since the package names differ.
#
# Run from the repo root.
set -eu

SWITCH=${SWITCH:-tsync}
COMPILER=${COMPILER:-ocaml-base-compiler.5.5.0}

export OPAMYES=1

# bwrap has no privileges inside a CI container.
[ -d "${OPAMROOT:-$HOME/.opam}" ] || opam init --bare --disable-sandboxing
opam switch list --short | grep -qx "$SWITCH" || opam switch create "$SWITCH" "$COMPILER"
eval "$(opam env --switch="$SWITCH" --set-switch)"

opam pin -ny .
opam pin add -ny fuse3 git+https://github.com/toots/ocamlfuse.git
opam pin add -ny git+https://github.com/toots/aws-s3.git#tsync

opam install --deps-only tsync tsync-s3 tsync-fuse
# The OpenSSL TLS backend. Optional to the build, preferred at runtime.
opam install lwt_ssl

opam exec -- dune build --profile release bin/tsync.exe
