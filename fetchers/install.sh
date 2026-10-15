#!/usr/bin/env bash
#
# Install one or more clients for fetchers/fetcher.sh.
#
#   fetchers/install.sh [CLIENT...]
#
# CLIENT is curl-impersonate, chromium, cloak-browser or playwright. With no
# argument every client is installed. curl needs no installer: it is a system
# tool. Each client keeps its own install.sh, so this runs them in order and
# reports which ones landed.
#
# Exit status: 0 every asked client installed, 1 one did not.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

clients="${*:-$FETCHER_CLIENTS_DEFAULT}"
rc=0
for c in $clients; do
  case "$c" in
    curl) continue ;;
    curl-impersonate | chromium | cloak-browser | playwright) ;;
    *) fetcher_warn "unknown client $c"; rc=1; continue ;;
  esac
  if [ ! -x "$HERE/$c/install.sh" ]; then
    fetcher_warn "no installer for $c"
    rc=1
    continue
  fi
  if "$HERE/$c/install.sh"; then
    fetcher_log "$c is installed"
  else
    fetcher_warn "$c did not install"
    rc=1
  fi
done
exit "$rc"
