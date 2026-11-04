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
# Pinned to a commit, as duppy is in tsync.opam: a bump changes the files every
# CI cache key hashes, so a cached switch never holds an older one.
ffmpeg=git+https://github.com/savonet/ocaml-ffmpeg.git#6144d04d83b28d11cb3ce792b701e18e0a40ad4b
for pkg in ffmpeg-av ffmpeg-avcodec ffmpeg-avfilter ffmpeg-avutil ffmpeg-swscale; do
  opam pin -ny "$pkg" "$ffmpeg"
done
opam update
opam upgrade -y
opam install --deps-only -y "$@"

# The gate's formatting check needs the formatter at the version the
# repository pins.
if [ "${TSYNC_FORMATTER:-}" = 1 ]; then
  opam install -y "ocamlformat.$(sed -n 's/^version=//p' .ocamlformat)"
fi
