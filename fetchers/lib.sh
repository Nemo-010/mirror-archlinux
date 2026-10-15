# Shared helpers for the fetchers in this directory. Sourced, never executed.
#
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# The interface of a client is the same for every one:
#
#   <client> <url> <out>
#
# It writes the body to <out> and exits 0 when it read it, 4 when the server
# answered 404 or 410, and anything else otherwise. Nothing else is assumed
# about the reason. fetcher.sh picks the clients, in an order, and stops at the
# first body that passes the structural check its caller asked for.

FETCHER_HOME="${FETCHER_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
FETCHER_CACHE="${FETCHER_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/mirror-archlinux/fetcher}"

# Extra request headers ("Name: Value"), set by fetcher.sh --header. curl and
# curl-impersonate get them as --header; the browser clients read them from
# FETCHER_HEADERS, one per line.
HEADERS=()

# The clients, in the order auto mode tries them: the cheapest first, so a
# host that answers curl costs one curl call, and a host that answers only a
# full Chromium pays for it. A host with a known answer starts at the client
# that answered it last.
# shellcheck disable=SC2034 # read by fetcher.sh and drift.sh
FETCHER_CLIENTS_DEFAULT="curl curl-impersonate chromium cloak-browser playwright"

fetcher_log() {
  printf 'fetcher: %s\n' "$*" >&2
}

fetcher_warn() {
  printf 'fetcher: warning: %s\n' "$*" >&2
}

fetcher_die() {
  printf 'fetcher: %s\n' "$*" >&2
  exit 1
}

# fetcher_cache_dir SUB -> that directory under the cache root, made
fetcher_cache_dir() {
  local d="$FETCHER_CACHE/$1"
  mkdir -p "$d"
  printf '%s\n' "$d"
}

# body_magic FILE -> the first four bytes in hex
body_magic() {
  od -An -tx1 -N4 "$1" | tr -d ' \n'
}

# body_validate FILE EXPECT -> 0 when FILE is what EXPECT names, else prints why
#   any   not empty, and not an HTML document
#   sig   one OpenPGP signature packet, under 64 KiB (lib.sh sig_packet)
#   db    a tar archive, zstd or gzip, that holds a package desc member
#   tar   a tar archive, zstd or gzip, whatever its members
body_validate() {
  local file="$1" expect="$2" size magic first
  [ -f "$file" ] || { echo "no file"; return 1; }
  size="$(wc -c < "$file" | tr -d ' ')"
  [ "$size" -gt 0 ] || { echo "empty"; return 1; }
  case "$expect" in
    any)
      # An origin that answers 200 with a page has not served the file that
      # was asked for. No database, signature or package file starts with an
      # HTML document, so this is refused whatever the caller expected.
      if head -c 4096 -- "$file" | grep -qiE '<!doctype html|<html|</html>'; then
        echo "an HTML document"
        return 1
      fi
      return 0
      ;;
    sig)
      first="$(od -An -tx1 -N1 "$file" | tr -d ' \n')"
      if [ "$size" -ge 65536 ]; then echo "signature of $size bytes"; return 1; fi
      case "$first" in
        88 | 89 | c2) ;;
        *) echo "no OpenPGP signature packet (first byte $first)"; return 1 ;;
      esac
      return 0
      ;;
    db | tar) ;;
    *) echo "unknown expect '$expect'"; return 1 ;;
  esac
  magic="$(body_magic "$file")"
  case "$magic" in
    28b52ffd | 1f8b*) ;;
    *) echo "not a zstd or gzip archive (magic $magic)"; return 1 ;;
  esac
  if ! tar -tf "$file" > /dev/null 2>&1; then
    echo "it does not read as a tar archive"
    return 1
  fi
  if [ "$expect" = db ]; then
    # grep without -q reads to the end, so the tar on the left is never sent
    # SIGPIPE and `set -o pipefail` does not read a missing desc as failure.
    if ! tar -tf "$file" 2> /dev/null | grep '/desc$' > /dev/null; then
      echo "the archive holds no package desc member"
      return 1
    fi
  fi
  return 0
}

# client_available NAME -> 0 when NAME can run here. The answer is kept for
# FETCHER_AVAILABLE_TTL seconds (default 300; 0 asks every time, and
# FETCHER_NO_AVAILABLE_CACHE=1 asks every time too), because a browser probe
# starts node or python and costs more than the fetch it guards.
client_available() {
  local name="$1" script rc=0 stamp now ttl="${FETCHER_AVAILABLE_TTL:-300}" cache
  case "$name" in
    curl) command -v curl > /dev/null 2>&1; return $? ;;
    curl-impersonate | chromium | cloak-browser | playwright) ;;
    *) return 1 ;;
  esac
  case "$ttl" in
    '' | *[!0-9]*) ttl=0 ;;
  esac
  cache="$FETCHER_CACHE/available/$name"
  if [ "$ttl" -gt 0 ] && [ "${FETCHER_NO_AVAILABLE_CACHE:-0}" -eq 0 ] && [ -r "$cache" ]; then
    now="$(date -u +%s)"
    stamp=""
    read -r stamp rc < "$cache" || true
    case "$stamp" in
      '' | *[!0-9]*) ;;
      *) [ $((now - stamp)) -lt "$ttl" ] && return "$rc" ;;
    esac
  fi
  script="$FETCHER_HOME/$name/available"
  rc=1
  if [ -x "$script" ]; then
    if "$script"; then rc=0; else rc=1; fi
  fi
  if [ "$ttl" -gt 0 ] && [ "${FETCHER_NO_AVAILABLE_CACHE:-0}" -eq 0 ] && mkdir -p "$FETCHER_CACHE/available" 2> /dev/null; then
    printf '%s\t%s\n' "$(date -u +%s)" "$rc" > "$FETCHER_CACHE/available/.$name.$$"
    mv -f "$FETCHER_CACHE/available/.$name.$$" "$FETCHER_CACHE/available/$name" 2> /dev/null || true
  fi
  return "$rc"
}

# retry_delay ATTEMPT -> the whole seconds to wait before ATTEMPT: 2, 4, 8,
# 16, then 30. retry_sleep adds up to 0.9 s of jitter, so two callers that
# back off from the same host do not retry in lockstep.
retry_delay() {
  local attempt="$1" delay=2 i=1
  while [ "$i" -lt "$attempt" ] && [ "$delay" -lt 30 ]; do
    delay=$((delay * 2))
    i=$((i + 1))
  done
  [ "$delay" -le 30 ] || delay=30
  printf '%s\n' "$delay"
}

retry_sleep() {
  sleep "$(retry_delay "$1").$((RANDOM % 10))"
}

# client_known NAME -> 0 when NAME is a client this manager can run. A client
# that is not available here is still known: only a name no build defines is
# refused.
client_known() {
  case "$1" in
    curl | curl-impersonate | chromium | cloak-browser | playwright) return 0 ;;
    *) return 1 ;;
  esac
}

# client_run NAME URL OUT LOG [REFERER] -> the client's own status. The body
# lands in OUT; the client's own output lands in LOG. Every client is wrapped
# in a hard stop of FETCHER_MAX_TIME + 5 s, so a browser that hangs ends within
# the same deadline curl has. The headers of HEADERS and REFERER, if given,
# reach the client.
client_run() {
  local name="$1" url="$2" out="$3" log="$4" referer="${5:-}" secs="${FETCHER_MAX_TIME:-300}" dead=() cap=() hdrs=() h
  dead=(timeout -k 5 "$((secs + 5))")
  if [ "${FETCHER_MAX_BYTES:-0}" -gt 0 ]; then
    cap=(--max-filesize "$FETCHER_MAX_BYTES")
  fi
  for h in "${HEADERS[@]}"; do
    [ -n "$h" ] || continue
    hdrs+=(--header "$h")
  done
  if [ -n "$referer" ]; then
    hdrs+=(--referer "$referer")
  fi
  case "$name" in
    curl)
      "${dead[@]}" curl -q --location --silent --show-error --max-redirs 5 \
        --proto '=https,http' --proto-redir '=https,http' \
        --connect-timeout "${FETCHER_CONNECT_TIMEOUT:-20}" \
        --speed-limit 1024 --speed-time 60 \
        --max-time "$secs" "${cap[@]}" "${hdrs[@]}" \
        --output "$out" --write-out '%{http_code}' "$url" > "$log.code" 2> "$log"
      ;;
    curl-impersonate)
      FETCHER_MAX_TIME="$secs" "${dead[@]}" "$FETCHER_HOME/curl-impersonate/fetch.sh" \
        "$url" "$out" "${HEADERS[@]}" > "$log" 2>&1
      ;;
    chromium | cloak-browser)
      FETCHER_MAX_TIME="$secs" "${dead[@]}" node "$FETCHER_HOME/$name/fetch.mjs" "$url" "$out" "$referer" > "$log" 2>&1
      ;;
    playwright)
      FETCHER_MAX_TIME="$secs" "${dead[@]}" "$FETCHER_HOME/playwright/venv/bin/python" \
        "$FETCHER_HOME/playwright/fetch.py" "$url" "$out" "$referer" > "$log" 2>&1
      ;;
    *)
      echo "unknown client $name" > "$log"
      return 127
      ;;
  esac
}

# status_class LOG RC -> 0 read, 4 absent, 1 anything else. A client that
# writes the HTTP status to LOG.code reports it; every other client maps its
# own exit status, 4 meaning absent. An HTTP answer is authoritative: a 403
# body is not a body, whatever the file holds.
status_class() {
  local log="$1" rc="$2" code=""
  if [ -f "$log.code" ]; then
    code="$(cat "$log.code")"
    case "$code" in
      200) return 0 ;;
      404 | 410) return 4 ;;
      *) return 1 ;;
    esac
  fi
  case "$rc" in
    0) return 0 ;;
    4) return 4 ;;
    *) return 1 ;;
  esac
}

# body_sha256 FILE -> the sha256 of FILE, lowercase hex
body_sha256() {
  sha256sum "$1" | cut -d ' ' -f 1
}
