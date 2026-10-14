#!/usr/bin/env bash
#
# No pipeline in a script ends in a reader that stops early.
#
# Under pipefail, `producer | awk '... exit'`, `| head`, `| grep -q` or
# `| grep -m` can close the pipe while the producer is still writing; the
# producer dies of SIGPIPE (status 141), the pipeline fails, and set -e ends
# the script. Whether it happens depends on how fast the two sides run, so it
# passes most of the time. Measured 2026-10-13: `oras version | awk '... exit'`
# in scripts/install-oras ended a promote run with no message of its own.
# Read everything and decide at the end instead.
set -euo pipefail
# shellcheck source=../lib/harness.sh
. "$REPO_ROOT/tests/lib/harness.sh"

cd "$REPO_ROOT"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in
    client/pacman-oci) continue ;; # POSIX sh, no pipefail: an early reader is harmless there
  esac
  hits="$(awk '
    /^[[:space:]]*#/ { next }
    /\|[[:space:]]*(head([[:space:]]|$)|grep[[:space:]]+-[A-Za-z]*[qm])/ { print FILENAME ":" NR ": " $0; next }
    /\|[[:space:]]*awk[^|]*[{;][[:space:]]*exit[[:space:]]*[};]/ { print FILENAME ":" NR ": " $0 }
  ' "$f")"
  if [ -z "$hits" ]; then
    ok "$f: no pipeline ends in a reader that stops early"
  else
    fail "$f: no pipeline ends in a reader that stops early" "$hits" "reproduce: grep -nE '\\| *(head|grep -q|awk.*exit)' $f"
  fi
done <<< "$(shipped_scripts)"

summary
