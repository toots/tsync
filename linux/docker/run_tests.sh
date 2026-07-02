#!/usr/bin/env bash
set -euo pipefail

# Build and run the test suite in the Linux dev container.

cd "$(dirname "$0")"
exec docker compose run --rm dev bash -c \
  "eval \$(opam env) && cd /workspace && dune build && dune test"
