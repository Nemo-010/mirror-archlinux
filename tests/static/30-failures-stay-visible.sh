#!/usr/bin/env bash
#
# No step may hide a failure, and every network call has a deadline.
#
# The sibling repository published nothing for 37 days behind runs that
# reported green. Each link in that chain was one of the constructs refused
# here: an error swallowed with || true, stderr thrown away, a step allowed to
# fail. A call with no deadline is the same failure, slower: it holds a slot
# until the job's six hours run out.
set -euo pipefail
# shellcheck source=../lib/harness.sh
. "$REPO_ROOT/tests/lib/harness.sh"

cd "$REPO_ROOT"
targets="$(
  shipped_scripts
  if [ -d .github/workflows ]; then
    find .github/workflows -name '*.yml' | sort
  fi
)"

# Patterns that make a failure invisible. Extended regex, matched on code, not
# on comment lines.
SWALLOW='continue-on-error|\|\|[[:space:]]*(true|:)([[:space:];)]|$)|set[[:space:]]+\+e|2>[[:space:]]*/dev/null|&>[[:space:]]*/dev/null|>[[:space:]]*/dev/null[[:space:]]+2>&1|2>&-'

while IFS= read -r f; do
  [ -n "$f" ] || continue
  hits="$(grep -nE "$SWALLOW" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' || [ "$?" -eq 1 ])"
  if [ -z "$hits" ]; then
    ok "$f hides no failure"
  else
    fail "$f hides no failure" "$hits" "reproduce: grep -nE '$SWALLOW' $f"
  fi
done <<< "$targets"

#---------------------------------------------------------------------------#
# Every curl has a connect deadline and a whole-transfer one, or a stall
# deadline for downloads whose size makes a fixed one wrong. A curl command
# spans lines joined by a trailing backslash; the check reads the joined line.
#---------------------------------------------------------------------------#
while IFS= read -r f; do
  [ -n "$f" ] || continue
  calls="$(awk '
    /^[[:space:]]*#/ { next }
    { line = (cont ? line " " : "") $0 }
    /\\$/ { cont = 1; sub(/\\$/, "", line); next }
    { cont = 0; l = line; sub(/reproduce:.*/, "", l); if (l ~ /(^|[[:space:];(|&!])curl[[:space:]]+-/) print FILENAME ":" NR ": " line; line = "" }
  ' "$f")"
  [ -n "$calls" ] || continue
  bad="$(printf '%s\n' "$calls" | awk '!/--connect-timeout/ || (!/--max-time/ && !/--speed-time/)')"
  if [ -z "$bad" ]; then
    ok "$f: every curl has a connect deadline and a transfer or stall deadline"
  else
    fail "$f: every curl has a connect deadline and a transfer or stall deadline" "$bad" \
      "reproduce: grep -n 'curl ' $f"
  fi
done <<< "$targets"

#---------------------------------------------------------------------------#
# oras has no deadline of its own (measured in v1.3.4: only a TLS handshake
# timeout), so every oras call in a script sits under timeout(1). lib.sh
# oras_login puts its own call under one.
#---------------------------------------------------------------------------#
while IFS= read -r f; do
  case "$f" in
    scripts/*) ;;
    *) continue ;;
  esac
  bad="$(awk '
    /^[[:space:]]*#/ { next }
    /"\$ORAS"|\$\{ORAS\}|\$ORAS[[:space:]]|(^|[[:space:];(|&!])oras[[:space:]]+(push|pull|tag|manifest|blob|repo|login|cp|attach|discover|resolve)([[:space:]]|$)/ {
      if ($0 !~ /timeout[[:space:]]/ && $0 !~ /^[[:space:]]*oras_login[[:space:]]/) print FILENAME ":" NR ": " $0
    }
  ' "$f")"
  if [ -z "$bad" ]; then
    ok "$f: every oras call has a deadline"
  else
    fail "$f: every oras call has a deadline" "$bad" "reproduce: grep -n oras $f"
  fi
done <<< "$targets"

summary
