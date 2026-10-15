#!/usr/bin/env bash
#
# Retrieve one URL through a client that can present a browser's TLS and HTTP
# profile, with an ordered fallback and a structural check of the body.
#
#   fetchers/fetcher.sh [OPTIONS] URL OUT
#
# The default order is curl, curl-impersonate, chromium, cloak-browser,
# playwright (fetchers/lib.sh). curl is tried first, so a host that answers
# curl costs one curl call. A host that answered another client before starts
# at that client: the answer of each host is kept in the cache, and a client
# that passed a structural check is the one the next call for that host tries
# first.
#
# A client that reads the body but fails the structural check is not an answer:
# the next client is tried. A client that the server answers 404 or 410 for
# ends the call with status 4: the URL is absent, and another client would hear
# the same.
#
# OPTIONS
#   --client LIST   clients to try, in order, comma or space separated; a
#                   client name may also be given as --client NAME
#   --expect KIND   any (default), db, tar or sig: the structural check
#   --retries N     attempts per client (default 2)
#   --timeout SEC   whole-call deadline of one attempt (default 300)
#   --connect SEC   connect deadline (default 20)
#   --no-cache      do not read or write the per-host preference
#   --list          print the available clients, one per line, and exit
#   --quiet         no per-attempt line on stderr
#
# Environment: FETCHER_CLIENTS (the order), FETCHER_CACHE (the cache root),
# FETCHER_SUMMARY (a TSV log of every attempt), GITHUB_ACTIONS (annotations).
#
# Exit status: 0 the body is in OUT, 4 the server says the URL is absent, 1
# every client failed or the body did not pass its check.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

quiet="${FETCHER_QUIET:-0}"
clients="${FETCHER_CLIENTS:-}"
expect="any"
retries="${FETCHER_RETRIES:-2}"
timeout_s="${FETCHER_MAX_TIME:-300}"
connect_s="${FETCHER_CONNECT_TIMEOUT:-20}"
use_cache=1
positional=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --client)
      [ "$#" -ge 2 ] || fetcher_die "--client needs a value"
      clients="${clients:+$clients }$(printf '%s' "$2" | tr ',' ' ')"
      shift 2
      ;;
    --expect)
      [ "$#" -ge 2 ] || fetcher_die "--expect needs a value"
      expect="$2"
      shift 2
      ;;
    --retries)
      [ "$#" -ge 2 ] || fetcher_die "--retries needs a value"
      retries="$2"
      shift 2
      ;;
    --timeout)
      [ "$#" -ge 2 ] || fetcher_die "--timeout needs a value"
      timeout_s="$2"
      shift 2
      ;;
    --connect)
      [ "$#" -ge 2 ] || fetcher_die "--connect needs a value"
      connect_s="$2"
      shift 2
      ;;
    --no-cache)
      use_cache=0
      shift
      ;;
    --list)
      for c in $FETCHER_CLIENTS_DEFAULT; do
        if client_available "$c"; then printf '%s\n' "$c"; fi
      done
      exit 0
      ;;
    --quiet)
      quiet=1
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      fetcher_die "unknown option $1" "reproduce: fetchers/fetcher.sh --help"
      ;;
    *)
      positional+=("$1")
      shift
      ;;
  esac
done
while [ "$#" -gt 0 ]; do
  positional+=("$1")
  shift
done
case "$expect" in
  any | db | tar | sig) ;;
  *) fetcher_die "--expect must be any, db, tar or sig, not '$expect'" ;;
esac
case "$retries" in
  '' | *[!0-9]* | 0) fetcher_die "--retries must be a positive integer, not '$retries'" ;;
esac
case "$timeout_s$connect_s" in
  *[!0-9]*) fetcher_die "--timeout and --connect must be positive integers" ;;
esac
[ "${#positional[@]}" -eq 2 ] || fetcher_die "usage: fetchers/fetcher.sh [OPTIONS] URL OUT" \
  "reproduce: fetchers/fetcher.sh --expect db https://repo.archlinuxpower.org/base/powerpc64le/base.db base.db"
url="${positional[0]}"
out="${positional[1]}"
case "$url" in
  https://* | http://*) ;;
  *) fetcher_die "URL is http or https, not '$url'" ;;
esac

# host_of URL -> the host and port of URL, without any credential
host_of() {
  local h="${1#*://}"
  printf '%s\n' "${h%%/*}"
}

# order_for HOST: the client order for this call. The last client that passed
# for this host is first; the rest keep their default order after it.
order_for() {
  local host="$1" pref="" order="" c first=()
  if [ "$use_cache" -eq 1 ]; then
    pref="$(cat "$FETCHER_CACHE/hosts/$host" 2> /dev/null || true)"
  fi
  if [ -n "$clients" ]; then
    printf '%s\n' "$clients"
    return 0
  fi
  if [ -n "$pref" ]; then
    first+=("$pref")
  fi
  for c in $FETCHER_CLIENTS_DEFAULT; do
    case " ${first[*]-} " in
      *" $c "*) ;;
      *) order="$order $c" ;;
    esac
  done
  printf '%s\n' "${first[*]-}$order" | tr -s ' ' | sed 's/^ //; s/ $//'
}

# summary_line HOST CLIENT STATUS TRIES SECONDS DETAIL
summary_line() {
  [ -n "${FETCHER_SUMMARY:-}" ] || return 0
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$FETCHER_SUMMARY"
}

host="$(host_of "$url")"
order="$(order_for "$host")"
[ -n "${order// /}" ] || fetcher_die "no client can run here" "reproduce: fetchers/fetcher.sh --list"

if [ "$quiet" != 1 ]; then
  fetcher_log "$url -> $out, expect=$expect, clients: $order"
fi

work="$(mktemp -d)"
# shellcheck disable=SC2329 # run by the EXIT trap
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

attempted=0
absent=0
for client in $order; do
  if ! client_available "$client"; then
    summary_line "$host" "$client" skipped 0 0 "not available"
    continue
  fi
  attempt=0
  while [ "$attempt" -lt "$retries" ]; do
    attempt=$((attempt + 1))
    attempted=$((attempted + 1))
    body="$work/body"
    log="$work/log"
    rm -f "$body" "$log" "$log.code"
    started="$(date -u +%s)"
    rc=0
    FETCHER_MAX_TIME="$timeout_s" FETCHER_CONNECT_TIMEOUT="$connect_s" client_run "$client" "$url" "$body" "$log" || rc=$?
    took=$(( $(date -u +%s) - started ))
    class=0
    status_class "$client" "$log" "$rc" || class=$?
    detail="$(tail -c 200 "$log" 2> /dev/null | tr '\t\n' '  ' | sed 's/  *$//')"
    if [ -s "$log.code" ]; then
      detail="HTTP $(cat "$log.code")${detail:+; $detail}"
    fi
    if [ "$class" -eq 4 ]; then
      summary_line "$host" "$client" absent "$attempt" "$took" "$detail"
      absent=1
      break
    fi
    if [ "$class" -ne 0 ]; then
      summary_line "$host" "$client" failed "$attempt" "$took" "$detail"
      if [ "$attempt" -lt "$retries" ]; then sleep 2; fi
      continue
    fi
    why="$(body_validate "$body" "$expect" 2>&1)" || {
      summary_line "$host" "$client" bad-body "$attempt" "$took" "$why"
      if [ "$attempt" -lt "$retries" ]; then sleep 2; fi
      continue
    }
    summary_line "$host" "$client" ok "$attempt" "$took" "$detail"
    if [ "$use_cache" -eq 1 ]; then
      mkdir -p "$FETCHER_CACHE/hosts"
      printf '%s\n' "$client" > "$FETCHER_CACHE/hosts/$host"
    fi
    mv -f "$body" "$out"
    if [ "$quiet" != 1 ]; then
      fetcher_log "$client read $url (${took}s)"
    fi
    exit 0
  done
  if [ "$absent" -eq 1 ]; then
    exit 4
  fi
done

if [ "$absent" -eq 1 ]; then
  exit 4
fi
fetcher_warn "no client read $url ($attempted attempt(s))"
exit 1
