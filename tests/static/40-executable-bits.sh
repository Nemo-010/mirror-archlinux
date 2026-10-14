#!/usr/bin/env bash
#
# Every script is committed executable. A workflow step that runs
# scripts/plan from a checkout whose index lost the bit fails with 126, and a
# consumer who downloads the wrapper from a raw URL gets whatever mode git had.
set -euo pipefail
# shellcheck source=../lib/harness.sh
. "$REPO_ROOT/tests/lib/harness.sh"

cd "$REPO_ROOT"
if ! git rev-parse --git-dir > /dev/null 2>&1; then
  ok "skipped: not a git checkout, the index holds the modes"
  summary
  exit 0
fi

while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in
    scripts/lib.sh) want=100644 ;;
    *) want=100755 ;;
  esac
  mode="$(git ls-files -s -- "$f" | awk '{ print $1 }')"
  if [ -z "$mode" ]; then
    fail "$f is in the git index" "git ls-files does not list it" "reproduce: git ls-files -s -- $f"
  else
    check "$f is mode $want in the index" "$want" "$mode" "git ls-files -s -- $f"
  fi
done <<< "$(shipped_scripts; printf '%s\n' tests/run.sh)"

summary
