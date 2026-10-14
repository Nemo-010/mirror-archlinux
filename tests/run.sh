#!/usr/bin/env bash
#
# Test entry point.
#
#   tests/run.sh static        the tree: shellcheck, actionlint, policy
#   tests/run.sh unit          the wrapper and the scripts, no network
#   tests/run.sh integration   a local registry, oras and pacman in a container
#   tests/run.sh all           all three
#
# static needs shellcheck and actionlint on PATH. integration needs docker or
# podman (CONTAINER_RUNTIME picks one) and network to pull the pinned images.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

suite="${1:-unit}"

case "$suite" in
  static | unit | integration) suites="$suite" ;;
  all) suites="static unit integration" ;;
  *)
    echo "usage: tests/run.sh [static|unit|integration|all]" >&2
    exit 2
    ;;
esac

failed_files=0
total_files=0

for s in $suites; do
  for t in "$REPO_ROOT/tests/$s"/*.sh; do
    [ -e "$t" ] || continue
    total_files=$((total_files + 1))
    printf '\n# ===== %s/%s =====\n' "$s" "$(basename "$t")"
    if ! bash "$t"; then
      failed_files=$((failed_files + 1))
    fi
  done
done

printf '\n# ===== summary =====\n'
if [ "$total_files" -eq 0 ]; then
  printf '# no test files found for suite: %s\n' "$suites"
  exit 1
fi
printf '# test files: %d, failed: %d\n' "$total_files" "$failed_files"
[ "$failed_files" -eq 0 ]
