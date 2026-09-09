#!/bin/sh
# Pins the sources tsync builds against and installs the dependencies of the
# opam packages named as arguments. The sole copy of that pin list: every
# workflow, linux/build.sh and linux/Makefile call this.
#
# What it is careful about is a switch restored from a CI cache. Such a switch
# already satisfies every dependency, so `opam install --deps-only` on its own
# builds nothing and the job goes on to test whatever was current the day the
# cache was written. `opam update` is what stops that: it re-fetches
# opam-repository, and it re-fetches the git pins below -- a branch pin keeps
# its version string, so without an update opam never looks at the new revision
# and has nothing to compare. `opam upgrade` then rebuilds whatever moved.
set -eu

cd "$(dirname "$0")/.."

export OPAMYES=1

opam pin -ny .
opam pin add -ny fuse3 git+https://github.com/toots/ocamlfuse.git
opam pin add -ny git+https://github.com/toots/aws-s3.git#tsync
opam pin add -ny git+https://github.com/toots/ocaml-cohttp.git#bigstring-body
opam pin add -ny git+https://github.com/janestreet/memtrace.git#master

opam update
opam upgrade -y
opam install --deps-only -y "$@"
