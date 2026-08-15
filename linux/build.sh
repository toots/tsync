#!/bin/sh
# Builds bin/tsync.exe and linux/tray/main.exe in a fresh opam switch. Distro-agnostic:
# the caller installs the system libraries first, since the package names differ.
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

opam pin -ny .
opam pin add -ny fuse3 git+https://github.com/toots/ocamlfuse.git
opam pin add -ny git+https://github.com/toots/aws-s3.git#tsync
opam pin add -ny git+https://github.com/toots/ocaml-cohttp.git#bigstring-body

# A branch pin keeps its version string, so a restored opam root already
# holding an older build of these satisfies the dependency and nothing rebuilds.
# Only reached when the cache carried one in: on a fresh switch they are absent
# and the install below fetches the current revision.
for pkg in fuse3 aws-s3 aws-s3-lwt cohttp cohttp-lwt cohttp-lwt-unix; do
  if opam list --installed --short | grep -qx "$pkg"; then
    opam reinstall -y "$pkg"
  fi
done

# tsync-tls and tsync-ssl are the two TLS backends. tsync alone would pull the
# first, and a released build ships both: OpenSSL is preferred at runtime and
# native is what the endpoints OpenSSL trips over fall back to.
opam install --deps-only tsync tsync-tls tsync-ssl tsync-s3 tsync-fuse tsync-tray

opam exec -- dune build --profile release bin/tsync.exe linux/tray/main.exe
