#!/bin/sh
# Installs the dependencies of the tsync packages named as arguments (10 §4.1):
# the one copy of that rule, called by every workflow and by linux/build.sh.
#
# A switch restored from a CI cache already satisfies every dependency, so an
# install alone would build against whatever was current the day the cache was
# written; the update and upgrade make it hold what a fresh switch would.
set -eu

cd "$(dirname "$0")/.."

export OPAMYES=1

opam pin -ny .
# Pinning again would fetch the new sources itself, and the update below would
# then find nothing to rebuild.
for pkg in ffmpeg-av ffmpeg-avcodec ffmpeg-avfilter ffmpeg-avutil ffmpeg-swscale; do
  opam pin list --short | grep -qx "$pkg" ||
    opam pin -ny "$pkg" git+https://github.com/savonet/ocaml-ffmpeg.git#main
done
opam update
opam upgrade -y
opam install --deps-only -y "$@"

# The gate's formatting check needs the formatter at the version the
# repository pins.
if [ "${TSYNC_FORMATTER:-}" = 1 ]; then
  opam install -y "ocamlformat.$(sed -n 's/^version=//p' .ocamlformat)"
fi
