#!/usr/bin/env bash
#
# Every target file parses, names a database server and a package server, and
# pins its verify image by digest with a tag Renovate can follow.
set -euo pipefail
# shellcheck source=../lib/harness.sh
. "$REPO_ROOT/tests/lib/harness.sh"

cd "$REPO_ROOT"
found=0
for conf in targets/*.conf; do
  [ -e "$conf" ] || continue
  found=$((found + 1))
  out="$(SCRIPT_NAME=target bash -c '. scripts/lib.sh; target_check "$1"' _ "$conf" 2>&1)" && rc=0 || rc=$?
  if [ "$rc" -eq 0 ]; then
    ok "$conf parses"
  else
    fail "$conf parses" "$out" "reproduce: bash -c '. scripts/lib.sh; target_check $conf'"
  fi

  image="$(SCRIPT_NAME=target bash -c '. scripts/lib.sh; target_get "$1" verify_image' _ "$conf")"
  if [ -z "$image" ]; then
    ok "$conf names no verify image, so it is never verified in a container"
  elif printf '%s\n' "$image" | grep -Eq '^[a-z0-9.-]+(/[a-z0-9._-]+)+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$'; then
    ok "$conf pins its verify image as name:tag@sha256"
  else
    fail "$conf pins its verify image as name:tag@sha256" "verify_image = $image" \
      "a digest alone gives Renovate no tag to follow, a tag alone is not a pin" \
      "reproduce: grep verify_image $conf"
  fi

  for key in server db_server; do
    bad="$(SCRIPT_NAME=target bash -c '. scripts/lib.sh; target_all "$1" "$2"' _ "$conf" "$key" | grep -v '^https://' || [ "$?" -eq 1 ])"
    if [ -z "$bad" ]; then
      ok "$conf: every $key is https"
    else
      fail "$conf: every $key is https" "$bad" "reproduce: grep '^$key' $conf"
    fi
  done
done
if [ "$found" -eq 0 ]; then
  fail "there is a target to mirror" "no targets/*.conf" "reproduce: ls targets"
fi

summary
