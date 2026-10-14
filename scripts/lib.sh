# Shared helpers for the scripts in this directory. Sourced, never executed.
#
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# Everything here reads its inputs as data. A target file is parsed, never
# sourced; a database is parsed field by field and every field is checked
# against its grammar before any of it reaches a path, a command line or a tag.

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck disable=SC2034 # read by the scripts that source this file
WRAPPER="$REPO_ROOT/client/pacman-oci"
# The targets directory; the integration suite points this at its own.
TARGETS_DIR="${TARGETS_DIR:-$REPO_ROOT/targets}"

#---------------------------------------------------------------------------#
# Messages
#
# die prints what was measured and what reproduces it, one item per line. In
# Actions the first line is also an error annotation, so it shows on the run's
# summary page without opening the log.
#---------------------------------------------------------------------------#
SCRIPT_NAME="${SCRIPT_NAME:-$(basename "$0")}"

# A command that ends a script under set -e says which one, where, and how,
# so no exit is ever silent. -E carries the trap into functions; a command in
# an if, while, || or && never triggers it, exactly as set -e is never
# triggered there.
set -E
trap 'printf "%s: line %s: %s ended with status %s\n" "$SCRIPT_NAME" "$LINENO" "$BASH_COMMAND" "$?" >&2' ERR

log() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
}

warn() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    printf '::warning::%s: %s\n' "$SCRIPT_NAME" "$1" >&2
  else
    printf '%s: warning: %s\n' "$SCRIPT_NAME" "$1" >&2
  fi
  shift
  while [ "$#" -gt 0 ]; do
    printf '  %s\n' "$1" >&2
    shift
  done
}

die() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    printf '::error::%s: %s\n' "$SCRIPT_NAME" "$1" >&2
  else
    printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2
  fi
  shift
  while [ "$#" -gt 0 ]; do
    printf '  %s\n' "$1" >&2
    shift
  done
  exit 1
}

need() {
  local c
  for c in "$@"; do
    command -v "$c" > /dev/null || die "$c is required and is not on PATH"
  done
}

#---------------------------------------------------------------------------#
# Targets
#
# targets/<arch>-<repo>.conf: `key = value` lines, # comments, a key may repeat
# where the list below says so. An unknown key is an error: a typo that is
# ignored is a setting that silently does nothing.
#---------------------------------------------------------------------------#
TARGET_KEYS_ONCE="arch repo verify_image verify_platform keyring enabled db_signed"
TARGET_KEYS_MANY="server db_server"

# target_check CONF -> exit 0, or die naming the line
target_check() {
  local conf="$1"
  [ -f "$conf" ] || die "no target file $conf"
  awk -v once=" $TARGET_KEYS_ONCE " -v many=" $TARGET_KEYS_MANY " -v f="$conf" '
    /^[[:space:]]*(#|$)/ { next }
    {
      line = $0
      if (line !~ /^[a-z_]+[[:space:]]*=[[:space:]]*[^[:space:]].*$/) {
        printf "%s:%d: not key = value: %s\n", f, NR, line; bad = 1; next
      }
      k = line; sub(/[[:space:]]*=.*/, "", k)
      if (index(once, " " k " ")) {
        if (seen[k]++) { printf "%s:%d: %s is given twice\n", f, NR, k; bad = 1 }
        next
      }
      if (index(many, " " k " ")) next
      printf "%s:%d: unknown key %s\n", f, NR, k; bad = 1
    }
    END { exit bad }
  ' "$conf" >&2 || die "$conf is not a valid target file" "reproduce: scripts/target check $conf"
  local arch repo
  arch="$(target_get "$conf" arch)"
  repo="$(target_get "$conf" repo)"
  [[ "$arch" =~ ^[a-z0-9]+(_[a-z0-9]+)*$ ]] || die "$conf: arch '$arch' is not a pacman architecture"
  [[ "$repo" =~ ^[a-z0-9]+([.-][a-z0-9]+)*$ ]] || die "$conf: repo '$repo' is not a repository name"
  [ "$(basename "$conf")" = "$arch-$repo.conf" ] || die "$conf must be named $arch-$repo.conf"
  [ -n "$(target_all "$conf" db_server)" ] || die "$conf has no db_server"
  case "$(target_get "$conf" db_signed)" in
    '' | yes | no) ;;
    *) die "$conf: db_signed must be yes or no" ;;
  esac
}

# target_sources CONF -> every server package bytes may come from: the
# db_servers first, then the other servers, each once
target_sources() {
  { target_all "$1" db_server; target_all "$1" server; } | awk '!seen[$0]++'
}

# target_get CONF KEY -> the value, or empty
target_get() {
  awk -v k="$2" '
    /^[[:space:]]*(#|$)/ { next }
    {
      key = $0; sub(/[[:space:]]*=.*/, "", key)
      if (key != k) next
      v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v)
      print v; exit
    }
  ' "$1"
}

# target_all CONF KEY -> every value, one per line, $repo and $arch expanded
target_all() {
  local conf="$1" key="$2" arch repo
  arch="$(target_get "$conf" arch)"
  repo="$(target_get "$conf" repo)"
  awk -v k="$key" -v arch="$arch" -v repo="$repo" '
    /^[[:space:]]*(#|$)/ { next }
    {
      key = $0; sub(/[[:space:]]*=.*/, "", key)
      if (key != k) next
      v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v)
      gsub(/\$repo/, repo, v); gsub(/\$arch/, arch, v)
      print v
    }
  ' "$conf"
}

# target_enabled CONF -> exit 0 when the target is mirrored
target_enabled() {
  case "$(target_get "$1" enabled)" in
    '' | yes) return 0 ;;
    no) return 1 ;;
    *) die "$1: enabled must be yes or no" ;;
  esac
}

# The repository a target is stored in, without the registry host.
target_repository() {
  printf '%s/%s/%s\n' "$MIRROR_NAMESPACE" "$(target_get "$1" arch)" "$(target_get "$1" repo)"
}

#---------------------------------------------------------------------------#
# Registry coordinates. Everything a script needs to run outside Actions too.
#---------------------------------------------------------------------------#
MIRROR_REGISTRY="${MIRROR_REGISTRY:-ghcr.io}"
if [ -z "${MIRROR_NAMESPACE:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
  MIRROR_NAMESPACE="$(printf '%s\n' "$GITHUB_REPOSITORY" | tr '[:upper:]' '[:lower:]')"
fi
MIRROR_NAMESPACE="${MIRROR_NAMESPACE:-}"

# The integration suite runs the same scripts against a local registry that
# speaks plain http and asks for no credential, and against a local upstream
# on plain http. Production sets none of these.
MIRROR_REGISTRY_SCHEME="${MIRROR_REGISTRY_SCHEME:-https}"
MIRROR_REGISTRY_AUTH="${MIRROR_REGISTRY_AUTH:-token}"
# shellcheck disable=SC2034 # OCI_SCHEME is read by the scripts that source this file
case "$MIRROR_REGISTRY_SCHEME" in
  https)
    OCI_SCHEME=oci
    REG_PROTO='=https'
    ;;
  http)
    OCI_SCHEME=oci+http
    REG_PROTO='=http,https'
    ;;
  *) die "MIRROR_REGISTRY_SCHEME must be https or http, not '$MIRROR_REGISTRY_SCHEME'" ;;
esac
REG_URL="$MIRROR_REGISTRY_SCHEME://$MIRROR_REGISTRY"
UPSTREAM_PROTO="${UPSTREAM_PROTO:-=https}"

# oras_args: what every oras call needs to reach the registry
oras_args() {
  printf '%s\n' --registry-config "$ORAS_CONFIG"
  if [ "$MIRROR_REGISTRY_SCHEME" = http ]; then
    printf '%s\n' --plain-http
  fi
}

# oras_login ORAS CONFIG: log in through a configuration file of its own, so
# the token never lands in ~/.docker and dies with the caller's work dir
oras_login() {
  [ "$MIRROR_REGISTRY_AUTH" != none ] || return 0
  local plain=()
  if [ "$MIRROR_REGISTRY_SCHEME" = http ]; then
    plain=(--plain-http)
  fi
  printf '%s' "$REGISTRY_TOKEN" | timeout 120 "$1" login --registry-config "$2" "${plain[@]}" \
    --username "${REGISTRY_USER:-token}" --password-stdin "$MIRROR_REGISTRY" > /dev/null
}

#---------------------------------------------------------------------------#
# Databases
#
# db_records DB OUT.tsv
#
# One line per package, tab separated:
#   filename name version arch sha256 csize builddate pgpsig
#
# ⛔ The database is unsigned for most upstreams, and any of a target's servers
# could have supplied it, so every field is checked before it is written. One
# bad field refuses the whole database: a database with one hostile name in it
# is not one to take the rest of from.
#
# ⚠ GNU tar seeks over a sparse member when extracting to a file and overwrites
# what it wrote before (riscv64, 2026-09). Extraction goes through a pipe, NUL
# bytes are dropped, and a record boundary is restored before %FILENAME%.
#---------------------------------------------------------------------------#
db_records() {
  local db="$1" out="$2" work rc
  work="$(mktemp -d)"
  rc=0
  tar -xOf "$db" --wildcards '*/desc' 2> "$work/tar.err" |
    tr -d '\000' |
    sed 's/%FILENAME%/\n&/g' > "$work/desc.txt" || rc=$?
  if [ "$rc" -ne 0 ]; then
    cat "$work/tar.err" >&2
    rm -rf "$work"
    return 1
  fi
  rc=0
  awk '
    function flush() {
      if (fn == "") return
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", fn, nm, ver, ar, sha, cs, bd, sig
      fn = nm = ver = ar = sha = cs = bd = sig = ""
    }
    /^%[A-Z0-9]+%$/ { key = $0; next }
    /^$/ { key = ""; next }
    {
      if (key == "%FILENAME%") { flush(); fn = $0 }
      else if (key == "%NAME%") nm = $0
      else if (key == "%VERSION%") ver = $0
      else if (key == "%ARCH%") ar = $0
      else if (key == "%SHA256SUM%") sha = $0
      else if (key == "%CSIZE%") cs = $0
      else if (key == "%BUILDDATE%") bd = $0
      else if (key == "%PGPSIG%") sig = sig $0
    }
    END { flush() }
  ' "$work/desc.txt" > "$out" || rc=$?
  rm -rf "$work"
  return "$rc"
}

# db_members DB -> how many package directories the archive holds
db_members() {
  tar -tf "$1" | awk -F / 'NF >= 2 && $2 == "desc" { n++ } END { print n + 0 }'
}

# db_validate RECORDS.tsv -> exit 0, or print every bad line and exit 1
#
# Only what makepkg can never produce is refused, so a port whose version holds
# a ~ is not shut out for good; a name outside the tag alphabet is stored under
# its fn- hash tag. What is refused is what turns a field into a path or an
# option: a /, a space, a leading - or ., a control character, a byte above 0x7e.
db_validate() {
  LC_ALL=C awk -F '\t' '
    function bad(why) { printf "line %d: %s: %s\n", NR, why, $0; n++ }
    NF != 8 { bad("expected 8 fields, found " NF); next }
    $1 !~ /^[A-Za-z0-9@_+][!-.0-~]*[.]pkg[.]tar([.][A-Za-z0-9]+)?$/ { bad("filename"); next }
    length($1) > 255 { bad("filename longer than 255"); next }
    $2 !~ /^[A-Za-z0-9@_+][A-Za-z0-9@._+-]*$/ { bad("name"); next }
    $3 !~ /^[!-~]+$/ { bad("version"); next }
    $4 !~ /^[A-Za-z0-9_]+$/ { bad("arch"); next }
    $5 !~ /^[0-9a-f]+$/ || length($5) != 64 { bad("sha256"); next }
    $6 !~ /^[0-9]+$/ || length($6) > 15 { bad("csize"); next }
    $7 !~ /^[0-9]+$/ || length($7) > 12 { bad("builddate"); next }
    $8 != "" && $8 !~ /^[A-Za-z0-9+\/]+=*$/ { bad("pgpsig"); next }
    index($1, $2 "-" $3 "-" $4 ".pkg.tar") != 1 { bad("filename is not name-version-arch.pkg.tar"); next }
    seen[$1]++ { bad("filename listed twice"); next }
    seen_name[$2]++ { bad("name listed twice"); next }
    END { exit n > 0 }
  ' "$1"
}

# behind A.tsv B.tsv -> "NEWER OLDER": how many packages of B were built
# after, and before, the same package in A. B is behind A when OLDER > 0.
# Measured on Arch's archived core.db, 2026-10-01 to 10-12: in every pair of
# consecutive days the newer database had no package older than the earlier
# one, and the earlier had at least one older package whenever the bytes
# differed, including the pairs whose newest build date was the same.
behind() {
  awk -F '\t' '
    FILENAME == ARGV[1] { built[$2] = $7; next }
    ($2 in built) { if ($7 + 0 > built[$2] + 0) n++; else if ($7 + 0 < built[$2] + 0) o++ }
    END { print n + 0, o + 0 }
  ' "$1" "$2"
}

# iso_now -> the time as ISO 8601 UTC, from MIRROR_NOW (seconds) when a test
# pins the clock. ISO strings of this one shape sort as the times they name.
iso_now() {
  if [ -n "${MIRROR_NOW:-}" ]; then
    date -u -d "@$MIRROR_NOW" +%Y-%m-%dT%H:%M:%SZ
  else
    date -u +%Y-%m-%dT%H:%M:%SZ
  fi
}

# fetched_not_older STAGED LIVE -> 0 when STAGED is the same time as LIVE or
# later. Both are ISO 8601 UTC of one shape, which sort as the times they name.
fetched_not_older() {
  local smaller
  smaller="$(printf '%s\n%s\n' "$1" "$2" | LC_ALL=C sort | sed -n 1p)"
  [ "$smaller" = "$2" ]
}

# stale_verdict PROMOTED_SHA UPSTREAM_SHA FETCHED_ISO TODAY TOLERANCE_DAYS
#   current  latest serves upstream's database
#   fresh    they differ, and the snapshot was fetched within the tolerance
#   stale    they differ, and it was fetched longer ago, or never
#   unknown  upstream could not be read; nothing can be said
stale_verdict() {
  local promoted="$1" upstream="$2" fetched="$3" today="$4" tolerance="$5" age
  if [ -z "$upstream" ]; then
    echo unknown
    return 0
  fi
  if [ -n "$promoted" ] && [ "$promoted" = "$upstream" ]; then
    echo current
    return 0
  fi
  if [ -z "$promoted" ] || [ -z "$fetched" ]; then
    echo stale
    return 0
  fi
  age="$("$REPO_ROOT/scripts/date-age" "$fetched" "$today")"
  if [ "$age" -gt "$tolerance" ]; then
    echo stale
  else
    echo fresh
  fi
}

#---------------------------------------------------------------------------#
# The write-once rule for package tags
#
# decide_push MANIFEST FILE SHA256 CSIZE SIG_SHA256
#   MANIFEST    the manifest the tag holds now
#   SIG_SHA256  the sha256 of the signature this file must carry, or empty
#               when the database has no %PGPSIG% for it
# prints one word:
#   present   the tag holds this file and its signature as they should be
#   repush    the package layer is right and something else is not (signature
#             missing or different, a title or media type, a layer count):
#             push again, the package blob is reused
#   needsig   no %PGPSIG% and no signature layer: fetch the .sig, then push
#   replaced  the tag holds other bytes under this name: never push
#
# ⛔ A tag whose package layer is not this file's bytes is never written
# again. The promoted database, or an older snapshot, may name those bytes,
# and a consumer handed new bytes under an old name gets a file pacman refuses
# with no fallback to another Server.
#---------------------------------------------------------------------------#
PKG_MEDIA_TYPE=application/vnd.pkgforge.archlinux.pkg.v1
SIG_MEDIA_TYPE=application/pgp-signature

decide_push() {
  local m="$1" file="$2" sha="$3" csize="$4" sig_sha="$5" count d sz mt
  if ! jq -e '.layers | type == "array"' "$m" > /dev/null; then
    echo replaced
    return 0
  fi
  read -r d sz mt <<< "$(manifest_layer "$m" "$file")"
  if [ "$d" != "sha256:$sha" ]; then
    echo replaced
    return 0
  fi
  if [ "$sz" != "$csize" ] || [ "$mt" != "$PKG_MEDIA_TYPE" ]; then
    echo repush
    return 0
  fi
  count="$(jq '.layers | length' "$m")"
  read -r d sz mt <<< "$(manifest_layer "$m" "$file.sig")"
  if [ -n "$sig_sha" ]; then
    if [ "$d" != "sha256:$sig_sha" ] || [ "$mt" != "$SIG_MEDIA_TYPE" ] || [ "$count" != 2 ]; then
      echo repush
      return 0
    fi
    echo present
    return 0
  fi
  if [ -z "$d" ]; then
    if [ "$count" = 1 ]; then
      echo needsig
    else
      echo repush
    fi
    return 0
  fi
  if [ "$mt" != "$SIG_MEDIA_TYPE" ] || [ "$count" != 2 ]; then
    echo repush
    return 0
  fi
  echo present
}

#---------------------------------------------------------------------------#
# Results
#
# reconcile_results SHARD.tsv RESULTS_DIR OUT.tsv
#
# One result line per work line, in work-line order:
#   target filename status seconds detail
# A line with no result file is a failure: the item died before writing one,
# or xargs never started it. Prints the number of lines that are not pushed or
# present.
#---------------------------------------------------------------------------#
reconcile_results() {
  local shard="$1" results="$2" outfile="$3" lines i
  lines="$(awk 'END { print NR + 0 }' "$shard")"
  : > "$outfile"
  for ((i = 1; i <= lines; i++)); do
    if [ -s "$results/$i.tsv" ]; then
      cat "$results/$i.tsv" >> "$outfile"
    else
      printf '%s\tfailed\t0\tno result was recorded\n' "$(sed -n "${i}p" "$shard" | cut -f 1,2)" >> "$outfile"
    fi
  done
  awk -F '\t' '$3 != "pushed" && $3 != "present" { n++ } END { print n + 0 }' "$outfile"
}

#---------------------------------------------------------------------------#
# Registry reads
#
# Every answer is classified exactly. A repository or manifest is absent only
# when the registry says so in its own words: 404 with NAME_UNKNOWN or
# MANIFEST_UNKNOWN. A 401, a 403, a 5xx, a body that is not the expected JSON,
# or no answer at all is an error, never "nothing there yet". Reading an error
# as an empty repository is how a mirror decides to push everything again, or
# to promote over a database it could not see.
#
# REGISTRY_USER and REGISTRY_TOKEN, when set, are exchanged for a scoped token.
# Without them the reads are anonymous, the way any consumer reads.
#---------------------------------------------------------------------------#
REG_STATUS_OK=0
REG_STATUS_ERROR=1
REG_STATUS_ABSENT=4

# registry_token REPO SCOPE -> a bearer token on stdout. SCOPE is pull or
# pull,push. Anonymous pulls on GHCR use the dummy token every public package
# accepts; anything else asks the token endpoint.
registry_token() {
  local repo="$1" scope="$2" out rc=0 tok
  if [ "$MIRROR_REGISTRY_AUTH" = none ]; then
    printf 'none\n'
    return 0
  fi
  if [ -z "${REGISTRY_TOKEN:-}" ] && [ "$scope" = pull ] && [ "$MIRROR_REGISTRY" = ghcr.io ]; then
    printf 'QQ==\n'
    return 0
  fi
  out="$(mktemp)"
  if [ -n "${REGISTRY_TOKEN:-}" ]; then
    curl -q --silent --show-error --fail --connect-timeout 20 --max-time 60 \
      --retry 3 --retry-connrefused --retry-delay 2 \
      --user "${REGISTRY_USER:-token}:$REGISTRY_TOKEN" \
      --get --data-urlencode "service=$MIRROR_REGISTRY" --data-urlencode "scope=repository:$repo:$scope" \
      --output "$out" "https://$MIRROR_REGISTRY/token" || rc=$?
  else
    curl -q --silent --show-error --fail --connect-timeout 20 --max-time 60 \
      --retry 3 --retry-connrefused --retry-delay 2 \
      --get --data-urlencode "service=$MIRROR_REGISTRY" --data-urlencode "scope=repository:$repo:$scope" \
      --output "$out" "https://$MIRROR_REGISTRY/token" || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    rm -f "$out"
    warn "no $scope token for $MIRROR_REGISTRY/$repo (curl $rc)"
    return 1
  fi
  tok="$(jq -r '.token // .access_token // empty' "$out")"
  rm -f "$out"
  [ -n "$tok" ] || return 1
  printf '%s\n' "$tok"
}

# registry_error_code BODY -> the first error code in a registry error body
registry_error_code() {
  jq -s -R -r '(fromjson? // {}) | .errors[0].code? // empty' "$1" | tr -d '\r'
}

# registry_manifest REPO REF OUT -> the manifest bytes in OUT
#   returns 0 read, 4 the registry has no such manifest, 1 could not read
registry_manifest() {
  local repo="$1" ref="$2" outfile="$3" token code rc=0 err
  token="$(registry_token "$repo" pull)" || return "$REG_STATUS_ERROR"
  code="$(curl -q --silent --show-error --connect-timeout 20 --max-time 60 \
    --retry 3 --retry-connrefused --retry-delay 2 --max-filesize 4194304 \
    --header "Authorization: Bearer $token" \
    --header 'Accept: application/vnd.oci.image.manifest.v1+json' \
    --output "$outfile" --write-out '%{http_code}' \
    "$REG_URL/v2/$repo/manifests/$ref")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    warn "no answer for $repo:$ref (curl $rc)"
    return "$REG_STATUS_ERROR"
  fi
  if [ "$code" = 404 ]; then
    err="$(registry_error_code "$outfile")"
    case "$err" in
      MANIFEST_UNKNOWN | NAME_UNKNOWN) return "$REG_STATUS_ABSENT" ;;
    esac
  fi
  if [ "$code" != 200 ]; then
    warn "$repo:$ref answered HTTP $code" "$(head -c 300 "$outfile")"
    return "$REG_STATUS_ERROR"
  fi
  if ! jq -e '.schemaVersion == 2' "$outfile" > /dev/null; then
    warn "$repo:$ref answered 200 with something that is not a manifest" "$(head -c 300 "$outfile")"
    return "$REG_STATUS_ERROR"
  fi
  case "$ref" in
    sha256:*)
      if [ "$(sha256sum "$outfile" | cut -d ' ' -f 1)" != "${ref#sha256:}" ]; then
        warn "$repo answered $ref with a manifest of another digest"
        return "$REG_STATUS_ERROR"
      fi
      ;;
  esac
  return "$REG_STATUS_OK"
}

# registry_blob REPO DIGEST OUT -> the blob in OUT, its sha256 checked
#   returns 0 read and checked, 1 anything else
registry_blob() {
  local repo="$1" digest="$2" outfile="$3" token rc=0
  case "$digest" in
    sha256:*) ;;
    *) warn "not a sha256 digest: $digest"; return 1 ;;
  esac
  token="$(registry_token "$repo" pull)" || return 1
  curl -q --fail --location --silent --show-error --proto "$REG_PROTO" --proto-redir "$REG_PROTO" --max-redirs 5 \
    --connect-timeout 20 --speed-limit 1024 --speed-time 60 \
    --retry 3 --retry-connrefused --retry-delay 2 \
    --header "Authorization: Bearer $token" \
    --output "$outfile" "$REG_URL/v2/$repo/blobs/$digest" || rc=$?
  if [ "$rc" -ne 0 ]; then
    warn "could not read blob $digest of $repo (curl $rc)"
    rm -f "$outfile"
    return 1
  fi
  if [ "$(sha256sum "$outfile" | cut -d ' ' -f 1)" != "${digest#sha256:}" ]; then
    warn "blob $digest of $repo does not hash to its digest"
    rm -f "$outfile"
    return 1
  fi
  return 0
}

# manifest_layer MANIFEST TITLE -> "DIGEST SIZE MEDIATYPE" of the one layer
# with that title, or nothing
manifest_layer() {
  jq -r --arg t "$2" '
    [.layers[]? | select(.annotations["org.opencontainers.image.title"]? == $t)]
    | if length == 1 then "\(.[0].digest) \(.[0].size) \(.[0].mediaType)" else empty end
  ' "$1"
}

# fetch_upstream URL OUT -> 0 fetched, 4 the server says it has no such file,
# 1 anything else. Large files get a stall deadline rather than a fixed one.
fetch_upstream() {
  local url="$1" outfile="$2" code rc=0
  code="$(curl -q --location --silent --show-error --max-redirs 5 \
    --proto "$UPSTREAM_PROTO" --proto-redir "$UPSTREAM_PROTO" \
    --connect-timeout 20 --speed-limit 4096 --speed-time 60 \
    --retry 2 --retry-connrefused --retry-delay 2 \
    --user-agent "mirror-archlinux (+https://github.com/${GITHUB_REPOSITORY:-pkgforge-dev/mirror-archlinux})" \
    --output "$outfile" --write-out '%{http_code}' "$url")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$outfile"
    return 1
  fi
  case "$code" in
    200) return 0 ;;
    404 | 410)
      rm -f "$outfile"
      return 4
      ;;
    *)
      rm -f "$outfile"
      return 1
      ;;
  esac
}

# Seconds since the epoch, from the environment when a test pins the clock.
now_epoch() {
  printf '%s\n' "${MIRROR_NOW:-$(date -u +%s)}"
}
