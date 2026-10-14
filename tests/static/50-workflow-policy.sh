#!/usr/bin/env bash
#
# Every workflow keeps the shape that makes the mirror safe to leave alone.
#
# Push access to this repository is the mirror's trust root: any workflow on
# any branch can ask for packages: write. These rules keep that write narrow
# and visible:
#   - permissions: {} at the top, and each job asks for what it needs
#   - shell: bash by default, so every run: block has -eo pipefail
#   - timeout-minutes on every job, so a hang ends in minutes, not six hours
#   - actions pinned by commit, and checkouts that keep no token on disk
#   - no ${{ inputs, matrix, needs or event }} inside a run: block, where a
#     value would become shell code; those go through env:
#   - no pull_request_target or workflow_run trigger, which run with a write
#     token on code from elsewhere
#   - no use of the packages DELETE API anywhere: nothing is ever deleted
#   - no unquoted `if: !`, which YAML reads as a tag
#   - nothing needs the jobs that watch the others
set -euo pipefail
# shellcheck source=../lib/harness.sh
. "$REPO_ROOT/tests/lib/harness.sh"

cd "$REPO_ROOT"
found=0
for wf in .github/workflows/*.yml; do
  [ -e "$wf" ] || continue
  found=$((found + 1))

  if grep -qE '^permissions:[[:space:]]*\{\}[[:space:]]*$' "$wf"; then
    ok "$wf: top-level permissions: {}"
  else
    fail "$wf: top-level permissions: {}" "every job asks for its own; the top level grants nothing" "reproduce: grep -n '^permissions' $wf"
  fi
  bad="$(grep -nE 'permissions:[[:space:]]*(write-all|read-all)' "$wf" || [ "$?" -eq 1 ])"
  if [ -z "$bad" ]; then
    ok "$wf: no blanket write-all or read-all"
  else
    fail "$wf: no blanket write-all or read-all" "$bad" "reproduce: grep -n 'permissions:' $wf"
  fi

  if awk '/^defaults:/ { d = 1; next } d && /^  run:/ { r = 1; next } d && r && /^    shell: bash[[:space:]]*$/ { found = 1 } /^[a-z]/ { d = 0; r = 0 } END { exit !found }' "$wf"; then
    ok "$wf: defaults run shell bash"
  else
    fail "$wf: defaults run shell bash" "an unspecified shell runs bash -e without pipefail" "reproduce: grep -n -A2 '^defaults' $wf"
  fi

  missing="$(awk '
    /^jobs:/ { in_jobs = 1; next }
    in_jobs && /^[a-z]/ { in_jobs = 0 }
    in_jobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { if (job != "" && !t) print job; job = $1; t = 0; next }
    in_jobs && /^    timeout-minutes:/ { t = 1 }
    END { if (job != "" && !t) print job }
  ' "$wf")"
  if [ -z "$missing" ]; then
    ok "$wf: every job has timeout-minutes"
  else
    fail "$wf: every job has timeout-minutes" "missing: $missing" "reproduce: grep -n timeout-minutes $wf"
  fi

  unpinned="$(grep -nE '^[[:space:]]*(-[[:space:]]*)?uses:' "$wf" | grep -vE 'uses:[[:space:]]*[^@[:space:]]+@[0-9a-f]{40}([[:space:]]|$)' || [ "$?" -eq 1 ])"
  if [ -z "$unpinned" ]; then
    ok "$wf: every action is pinned by commit"
  else
    fail "$wf: every action is pinned by commit" "$unpinned" "reproduce: grep -n 'uses:' $wf"
  fi

  checkouts="$(grep -c 'uses: actions/checkout@' "$wf" || [ "$?" -eq 1 ])"
  kept="$(grep -c 'persist-credentials: false' "$wf" || [ "$?" -eq 1 ])"
  check "$wf: every checkout keeps no token on disk" "${checkouts:-0}" "${kept:-0}" "grep -n -A2 'actions/checkout' $wf"

  interpolated="$(awk '
    /^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*[|>]/ { inrun = 1; ind = -1; next }
    /^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*[^|>[:space:]]/ { if ($0 ~ /\$\{\{[^}]*(inputs|matrix|needs|github\.event|github\.head_ref|steps\.[A-Za-z0-9_-]+\.outputs)/) print FILENAME ":" NR ": " $0; next }
    inrun {
      if ($0 ~ /^[[:space:]]*$/) next
      match($0, /^[[:space:]]*/)
      if (ind < 0) ind = RLENGTH
      if (RLENGTH < ind) { inrun = 0 }
      else if ($0 ~ /\$\{\{[^}]*(inputs|matrix|needs|github\.event|github\.head_ref|steps\.[A-Za-z0-9_-]+\.outputs)/) print FILENAME ":" NR ": " $0
    }
  ' "$wf")"
  if [ -z "$interpolated" ]; then
    ok "$wf: no untrusted value is expanded inside a run: block"
  else
    fail "$wf: no untrusted value is expanded inside a run: block" "$interpolated" "reproduce: grep -n '\${{' $wf"
  fi

  bad="$(grep -nE '^[[:space:]]*(pull_request_target|workflow_run)[[:space:]]*:' "$wf" || [ "$?" -eq 1 ])"
  if [ -z "$bad" ]; then
    ok "$wf: no pull_request_target or workflow_run trigger"
  else
    fail "$wf: no pull_request_target or workflow_run trigger" "$bad" "reproduce: grep -nE 'pull_request_target|workflow_run' $wf"
  fi

  bad="$(grep -nE "^[[:space:]]*if:[[:space:]]*!" "$wf" || [ "$?" -eq 1 ])"
  if [ -z "$bad" ]; then
    ok "$wf: no unquoted if: !"
  else
    fail "$wf: no unquoted if: !" "$bad" "an if: starting with ! must be inside \${{ }}" "reproduce: grep -n 'if: !' $wf"
  fi

  bad="$(awk '
    /^[[:space:]]*needs:/ {
      if ($0 ~ /(keepalive|staleness|schedules)/) print FILENAME ":" NR ": " $0
      inneeds = ($0 ~ /needs:[[:space:]]*$/)
      next
    }
    inneeds && /^[[:space:]]*-[[:space:]]/ { if ($0 ~ /(keepalive|staleness|schedules)/) print FILENAME ":" NR ": " $0; next }
    { inneeds = 0 }
  ' "$wf")"
  if [ -z "$bad" ]; then
    ok "$wf: nothing needs the jobs that watch the others"
  else
    fail "$wf: nothing needs the jobs that watch the others" "$bad" "reproduce: grep -n needs: $wf"
  fi
done
if [ "$found" -eq 0 ]; then
  fail "there are workflows" "no .github/workflows/*.yml" "reproduce: ls .github/workflows"
fi

#---------------------------------------------------------------------------#
# Nothing is ever deleted: no script or workflow calls the packages DELETE API.
#---------------------------------------------------------------------------#
deleters="$(grep -rnE '(-X|--method|--request)[[:space:]=]*DELETE|\bDELETE\b.*packages|oras[^#]*(manifest|blob)[[:space:]]+delete|delete-package-versions' scripts .github/workflows client || [ "$?" -eq 1 ])"
if [ -z "$deleters" ]; then
  ok "no script or workflow deletes a package or a version"
else
  fail "no script or workflow deletes a package or a version" "$deleters" "reproduce: grep -rn DELETE scripts .github client"
fi

summary
