#!/bin/sh
# Run the same build and test steps as the GitHub Actions workflow
# (.github/workflows/test.yml) locally.
#
# Usage:
#   ./scripts/local-ci.sh            # build, then run the whole test suite
#   ./scripts/local-ci.sh --deps     # also install/refresh opam dependencies first
#   ./scripts/local-ci.sh dune-tests/sleek/sleek10.t   # restrict tests to a target
#
# Optional provers (Mona, Redlog, Fixcalc) are not built by this script; tests
# that need them are skipped by dune with a warning. See docs/src/install.md.

set -e

cd "$(dirname "$0")/.."

install_deps=false
case "$1" in
  --deps) install_deps=true; shift ;;
esac

group() { printf '\n=== %s ===\n' "$1"; }

group "environment"
have() {
  if command -v "$1" >/dev/null 2>&1; then
    echo "  [ok]      $1 ($2)"
  else
    echo "  [MISSING] $1 ($2)"
  fi
}
have dune "build system"
have z3 "required by most tests"
have oc "Omega, required by most tests"
have mona "optional: set/second-order constraints"
have redcsl "optional: ParaHIP tests are skipped without it"
have fixcalc "optional: fixpoint inference tests are skipped without it"

if $install_deps; then
  group "opam dependencies"
  opam install . --deps-only
fi

group "build"
dune build @hipsleek

group "test${1:+ ($*)}"
dune test "$@"

group "done"
echo "  local CI passed"
