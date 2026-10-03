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
opam update
opam upgrade -y
opam install --deps-only -y "$@"
