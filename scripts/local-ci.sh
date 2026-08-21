#!/bin/sh
# Build and test HIP/SLEEK.
#
# This script is the single source of truth for the build+test steps: the
# GitHub Actions workflow (.github/workflows/test.yml) invokes it directly,
# so a local run and a CI run cannot drift apart. The workflow additionally
# installs the opam dependencies and the external provers before calling it.
#
# Usage:
#   ./scripts/local-ci.sh            # build, then run the whole test suite
#   ./scripts/local-ci.sh --deps     # also install/refresh opam dependencies first
#   ./scripts/local-ci.sh dune-tests/sleek/sleek10.t   # restrict tests to a target
#
# `dune test` does not currently pass on master. Rather than promote the stale
# cram baselines, a full run compares the set of failing targets against
# scripts/known-test-failures.txt and only fails on a difference, so that new
# regressions are caught while the existing divergences stay visible. A restricted
# run (with a target argument) skips that comparison and reports dune's own verdict.
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

if [ $# -gt 0 ]; then
  # Restricted run: known-test-failures.txt describes a *full* run, so comparing
  # against it here would report every unrun target as "fixed". Defer to dune.
  dune test "$@"
  group "done"
  echo "  local CI passed"
  exit 0
fi

known_failures=scripts/known-test-failures.txt
test_log=$(mktemp)
expected_f=$(mktemp)
actual_f=$(mktemp)
trap 'rm -f "$test_log" "$expected_f" "$actual_f"' EXIT

set +e
dune test >"$test_log" 2>&1
dune_status=$?
set -e
cat "$test_log"

group "known failures"

# dune reports each failing cram test and expect test as a File header followed
# immediately by the diff:
#   File "<path>", line 1, characters 0-0:
#   diff --git a/... b/...
# Compiler warnings use the same File header but are followed by a source excerpt,
# so the "diff" line is what distinguishes a failure from a warning. Matching on
# the header alone reports every warned-about .ml file as a failing target.
awk '\
  prev ~ /^File "/ && /^diff / { p = prev; sub(/^File "/, "", p); sub(/".*/, "", p); print p } \
  { prev = $0 }' "$test_log" | sort -u > "$actual_f"
if [ -f "$known_failures" ]; then
  grep -vE '^[[:space:]]*(#|$)' "$known_failures" | sort -u > "$expected_f"
else
  echo "  note: $known_failures not found, treating every failure as new"
  : > "$expected_f"
fi

# A non-zero dune status with nothing parseable means the run broke in a way this
# comparison cannot describe (build error, crash). Never let that pass silently.
if [ "$dune_status" -ne 0 ] && [ ! -s "$actual_f" ]; then
  echo "  dune test failed but no per-target failures could be parsed."
  echo "  See the log above; treating as a failure."
  exit 1
fi

new_failures=$(comm -13 "$expected_f" "$actual_f")
now_passing=$(comm -23 "$expected_f" "$actual_f")

if [ -n "$new_failures" ]; then
  echo "  NEW FAILURES (regressions, not listed in $known_failures):"
  echo "$new_failures" | sed 's/^/    /'
fi

if [ -n "$now_passing" ]; then
  echo "  NO LONGER FAILING (delete these lines from $known_failures):"
  echo "$now_passing" | sed 's/^/    /'
fi

if [ -n "$new_failures" ] || [ -n "$now_passing" ]; then
  exit 1
fi

echo "  $(wc -l < "$expected_f" | tr -d ' ') known failure(s), unchanged"

group "done"
echo "  local CI passed"
