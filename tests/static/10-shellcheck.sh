#!/usr/bin/env bash
#
# Every shell file passes shellcheck, the wrapper as POSIX sh.
#
# The wrapper runs under whatever /bin/sh a consumer has (bash on Arch, dash
# and busybox elsewhere), so a bashism in it is a bug that only shows on
# someone else's machine.
set -euo pipefail
# shellcheck source=../lib/harness.sh
. "$REPO_ROOT/tests/lib/harness.sh"

if ! command -v shellcheck > /dev/null 2>&1; then
  fail "shellcheck is on PATH" "the static suite needs it" "reproduce: scripts/install-test-tools ./bin && PATH=\$PWD/bin:\$PATH tests/run.sh static"
  summary
  exit 1
fi

cd "$REPO_ROOT"
files="$(
  shipped_scripts
  printf '%s\n' tests/run.sh tests/lib/harness.sh
  for d in tests/static tests/unit tests/integration; do
    if [ -d "$d" ]; then
      find "$d" -name '*.sh' | sort
    fi
  done
)"

while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in
    client/pacman-oci) shell='sh' ;;
    *) shell='bash' ;;
  esac
  out="$(shellcheck -x --source-path=SCRIPTDIR -s "$shell" "$f" 2>&1)" && rc=0 || rc=$?
  if [ "$rc" -eq 0 ]; then
    ok "shellcheck -s $shell $f"
  else
    fail "shellcheck -s $shell $f" "$(printf '%s\n' "$out" | sed -n 1,20p)" "reproduce: shellcheck -x --source-path=SCRIPTDIR -s $shell $f"
  fi
done <<< "$files"

summary
